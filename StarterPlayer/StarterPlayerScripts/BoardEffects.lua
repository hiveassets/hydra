--[[
    BoardEffects (ModuleScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Exported: 2026-09-25 02:23:34
]]
--[[
    BoardEffects (ModuleScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Exported: 2026-09-24 20:25:14
]]
--[[
    BoardEffects (ModuleScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Exported: 2026-09-23 02:07:55
]]
--[[
    BoardEffects (ModuleScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Exported: 2026-09-22 18:28:58
]]
--[[
	BoardEffects (ModuleScript) — place in StarterPlayerScripts
	(StarterPlayer.StarterPlayerScripts.BoardEffects).

	Every noise and every flash the board makes, in one place, played
	locally.

	WHY THIS EXISTS AT ALL

	These used to travel. BallManager, BombFuse, SellService and
	DashHandler fired a SoundEvents RemoteEvent and SoundClient built the
	Sound at the other end — the relay existed because a server-side
	Sound:Play() has to replicate before anyone hears it, which is
	audibly late. Now the thing making the noise is already on your
	machine, so there's nothing to relay: the ball that was just sold and
	the sound of it being sold are the same frame.

	The one relay that stays is other players' dash (see DashHandler),
	because that's a sound about something you can actually see happen.

	SellClient's own flash/sound helpers were the same code as this,
	written a second time for its click prediction. They're the same
	functions now.
]]

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local Workspace = game:GetService("Workspace")

local Rep = game:GetService("ReplicatedStorage")
local Config = require(Rep:WaitForChild("BoardConfig"))

local BoardEffects = {}

local FLASH_IMAGE = "rbxassetid://131187911056182"
local FLASH_SCALE = 2          -- tuned against a 5-stud ball
local FLASH_SHRINK_TIME = 0.4
local FLASH_RECOLOR_DELAY = 0.03 -- white pops first, then the real colour

-- ── sounds ────────────────────────────────────────────────────────────

-- A sound that belongs somewhere in the world, hung off a throwaway
-- anchored part — used for things whose source has just stopped
-- existing (a ball that was sold), where there's no instance left to
-- parent to.
function BoardEffects.soundAt(position, sound, pitch)
	local anchor = Instance.new("Part")
	anchor.Anchored, anchor.CanCollide, anchor.CanQuery, anchor.Transparency = true, false, false, 1
	anchor.Size, anchor.Position, anchor.Parent = Vector3.new(0.1, 0.1, 0.1), position, Workspace

	local s = Instance.new("Sound")
	s.SoundId = sound.id
	s.Volume = sound.volume or 1
	s.PlaybackSpeed = pitch or sound.speed or 1
	s.Parent = anchor
	s:Play()
	s.Ended:Connect(function()
		anchor:Destroy()
	end)

	-- Ended never fires for a sound that fails to load, so nothing here
	-- is allowed to outlive a generous timeout.
	task.delay(10, function()
		if anchor.Parent then
			anchor:Destroy()
		end
	end)
end

-- A sound that has to land on an exact frame — an explosion — made
-- ahead of time and parked on the thing that will go off.
--
-- soundAt builds a brand-new Sound at the moment it's needed, and a new
-- Sound can't start until it has loaded its asset, even one
-- PreloadAsync has already cached. That costs a few frames, which is
-- nothing for a sell and very audible under a flash that lasts 0.1s. The
-- old BombFuse primed its boom at spawn for exactly this reason; the
-- port dropped it on the assumption that the preload was enough. It
-- isn't: the preload fetches the asset, the priming readies the Sound.
--
-- Returns the Sound; hand it to playPrimedAt when the moment comes. If
-- the part is destroyed first (sold, stashed), the Sound goes with it.
function BoardEffects.primeSound(part, sound)
	local s = Instance.new("Sound")
	s.Name = "Primed_" .. (sound.id:gsub("%W", ""))
	s.SoundId = sound.id
	s.Volume = 0
	s.Parent = part
	-- Played silently and stopped, which makes it load now instead of
	-- when it's wanted.
	s:Play()
	s:Stop()
	s.Volume = sound.volume or 1
	s.PlaybackSpeed = sound.speed or 1
	return s
end

-- Plays a primed Sound where something just happened, moved onto its own
-- throwaway anchor first so it outlives the part it was waiting on.
-- Falls back to an ordinary soundAt if the primed one has gone missing.
function BoardEffects.playPrimedAt(primed, position, fallback)
	if not (primed and primed.Parent) then
		if fallback then
			BoardEffects.soundAt(position, fallback)
		end
		return
	end
	local anchor = Instance.new("Part")
	anchor.Anchored, anchor.CanCollide, anchor.CanQuery, anchor.Transparency = true, false, false, 1
	anchor.Size, anchor.Position, anchor.Parent = Vector3.new(0.1, 0.1, 0.1), position, Workspace

	primed.Parent = anchor
	primed.TimePosition = 0
	primed:Play()
	primed.Ended:Connect(function()
		anchor:Destroy()
	end)
	task.delay(10, function()
		if anchor.Parent then
			anchor:Destroy()
		end
	end)
end

-- A sound attached to something that's still around and may be moving.
function BoardEffects.soundOn(part, sound, pitch)
	local s = Instance.new("Sound")
	s.SoundId = sound.id
	s.Volume = sound.volume or 1
	s.PlaybackSpeed = pitch or sound.speed or 1
	s.Parent = part
	s:Play()
	s.Ended:Connect(function()
		s:Destroy()
	end)
end

-- A cue that repeats on the same object — a bomb's flicker tick, which
-- fires twelve times on one part. Keeps a single Sound there and
-- restarts it instead of building a fresh instance per tick: a new
-- Sound has to resolve its asset before it can play, so a rapid series
-- of them clips and drifts, where a restarted one is already loaded and
-- lands exactly on the beat. The old SoundEvents relay called this
-- "attachedReused" and did it for the same reason.
function BoardEffects.soundReusedOn(part, sound, pitch)
	local name = "Cue_" .. (sound.id:gsub("%W", ""))
	local s = part:FindFirstChild(name)
	if not (s and s:IsA("Sound")) then
		s = Instance.new("Sound")
		s.Name = name
		s.SoundId = sound.id
		s.Parent = part
	end
	s.Volume = sound.volume or 1
	s.PlaybackSpeed = pitch or sound.speed or 1
	s.TimePosition = 0
	s:Play()
	return s
end

-- Flat, positionless, for things with no place in the world: the
-- collapse alarm, the countdown tick.
local flatSounds = {}

function BoardEffects.flatSound(sound, pitch)
	local s = flatSounds[sound.id]
	if not s then
		s = Instance.new("Sound")
		s.SoundId = sound.id
		s.Parent = SoundService
		flatSounds[sound.id] = s
	end
	s.Volume = sound.volume or 1
	s.PlaybackSpeed = pitch or sound.speed or 1
	s:Play()
end

local loops = {}

function BoardEffects.startLoop(sound)
	local s = loops[sound.id]
	if not s then
		s = Instance.new("Sound")
		s.SoundId = sound.id
		s.Looped = true
		s.Parent = SoundService
		loops[sound.id] = s
	end
	s.Volume = sound.volume or 1
	if not s.IsPlaying then
		s:Play()
	end
end

function BoardEffects.stopLoop(sound)
	local s = loops[sound.id]
	if s then
		s:Stop()
	end
end

-- ── flash ─────────────────────────────────────────────────────────────

-- The billboard pop a ball leaves behind when it stops existing. Starts
-- white for a frame, settles into `color`, then shrinks away.
--
-- alwaysOnTop is off by default so the flash respects depth like the
-- rest of the scene; the collapse passes true, because that freeze
-- desaturates everything through a ColorCorrectionEffect and an
-- ordinary flash would read as washed-out white instead of magenta.
function BoardEffects.flash(position, size, color, alwaysOnTop, startColor, scaleMultiplier)
	local anchor = Instance.new("Part")
	anchor.Anchored, anchor.CanCollide, anchor.CanQuery, anchor.Transparency = true, false, false, 1
	anchor.Size, anchor.Position, anchor.Parent = Vector3.new(0.1, 0.1, 0.1), position, Workspace

	local scale = size * FLASH_SCALE * (scaleMultiplier or 1)
	local gui = Instance.new("BillboardGui")
	gui.Adornee, gui.Size = anchor, UDim2.new(scale, 0, scale, 0)
	gui.AlwaysOnTop = alwaysOnTop or false
	gui.Parent = anchor

	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency, img.BorderSizePixel = 1, 0
	img.Size, img.Image = UDim2.new(1, 0, 1, 0), FLASH_IMAGE
	img.ImageColor3, img.ImageTransparency = startColor or Color3.new(1, 1, 1), 0
	img.ScaleType, img.ZIndex, img.Parent = Enum.ScaleType.Fit, 10, gui

	task.delay(FLASH_RECOLOR_DELAY, function()
		if img.Parent then
			img.ImageColor3 = color
		end
	end)

	local shrink = TweenService:Create(
		gui,
		TweenInfo.new(FLASH_SHRINK_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
		{ Size = UDim2.new(0, 0, 0, 0) }
	)
	shrink:Play()
	shrink.Completed:Connect(function()
		if anchor.Parent then
			anchor:Destroy()
		end
	end)
end

-- ── explosions ────────────────────────────────────────────────────────
-- Every explosion is drawn by BoardEffects.explosion — a plain bomb, a
-- radiant bomb, and the radiant splitter's and merger's send-offs — so
-- they can only ever look like each other. Three pieces:
--
--   * the fireball: a neon sphere that expands (Exponential Out) and
--     fades (Quad Out, most of the way at once and then trailing off),
--     starting a quarter of the way in so its colour reads first;
--   * the flash: a billboard on top of everything at the centre, which
--     collapses to nothing (Exponential In) instead of blinking out;
--   * the inside view. A sphere can't be seen from inside — Roblox only
--     draws a part's outside faces — so a blast bigger than the view used
--     to vanish around the camera. While the camera is inside the
--     fireball, the screen is filled with the fireball's colour at its
--     transparency instead, which is what being inside a solid ball of
--     colour looks like, and the flash is drawn again over that fill so
--     it still reads.

local overlay -- the ScreenGui the inside view draws into, made on first use

local function getOverlay()
	if overlay and overlay.Parent then
		return overlay
	end
	local player = game:GetService("Players").LocalPlayer
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end
	overlay = Instance.new("ScreenGui")
	overlay.Name = "ExplosionOverlay"
	overlay.IgnoreGuiInset = true -- matches WorldToViewportPoint, which measures from the true top of the screen
	overlay.ResetOnSpawn = false
	overlay.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	overlay.Parent = playerGui
	return overlay
end

local function makeFlash(position, scale, image, startColor, time, endColor, recolorAt)
	local anchor = Instance.new("Part")
	anchor.Anchored, anchor.CanCollide, anchor.CanQuery, anchor.Transparency =
		true, false, false, 1
	anchor.Size, anchor.Position = Vector3.new(0.1, 0.1, 0.1), position
	anchor.Parent = Workspace

	local gui = Instance.new("BillboardGui")
	gui.Adornee, gui.Size, gui.AlwaysOnTop = anchor, UDim2.new(scale, 0, scale, 0), true
	gui.Parent = anchor

	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency, img.BorderSizePixel = 1, 0
	img.Size, img.Image = UDim2.new(1, 0, 1, 0), image
	img.ImageColor3, img.ImageTransparency = startColor, 0
	img.ScaleType, img.ZIndex = Enum.ScaleType.Fit, 10
	img.Parent = gui
	img:SetAttribute("GreyOnCollapse", true)

	if endColor and recolorAt then
		task.delay(recolorAt, function()
			if img.Parent then
				img.ImageColor3 = endColor
			end
		end)
	end

	local shrink = TweenService:Create(gui,
		TweenInfo.new(time, Enum.EasingStyle.Exponential, Enum.EasingDirection.In),
		{ Size = UDim2.new(0, 0, 0, 0) })
	shrink.Completed:Connect(function()
		if anchor.Parent then
			anchor:Destroy()
		end
	end)
	shrink:Play()

	return gui, img
end

-- The inside view on its own, for any sphere that can get big enough to
-- swallow the camera: while the camera is inside `part`, the screen is
-- filled with the part's colour at the part's transparency. Follows the
-- part as it moves, grows, shrinks, recolours and fades, and cleans
-- itself up when the part is destroyed. The magnet's telegraph uses it;
-- an explosion does the same thing inline, with the flash on top.
function BoardEffects.fillWhileInside(part)
	local screen = getOverlay()
	if not screen then
		return
	end

	local fill = Instance.new("Frame")
	fill.Name = "InsideFill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BorderSizePixel = 0
	fill.Visible = false
	fill.ZIndex = 1
	fill.Parent = screen

	local step
	step = RunService.RenderStepped:Connect(function()
		if not part.Parent then
			step:Disconnect()
			fill:Destroy()
			return
		end
		local camera = Workspace.CurrentCamera
		local inside = camera ~= nil
			and part.Transparency < 1
			and (camera.CFrame.Position - part.Position).Magnitude < part.Size.X / 2
		fill.Visible = inside
		if inside then
			fill.BackgroundColor3 = part.Color
			fill.BackgroundTransparency = part.Transparency
		end
	end)
end

-- opts:
--   position                 where it goes off
--   radius, time             the fireball's final radius and how long it lasts
--   colorFn(elapsed)         its colour every frame; or
--   startColor, endColor     one tween between the two over 65% of `time`
--                            (a plain bomb's orange to red)
--   flashScale, flashImage, flashTime
--   flashColor               the flash's colour (white if not given)
--   flashEndColor, flashRecolorAt
--                            optionally switch it partway (a plain bomb's
--                            white pop to yellow)
function BoardEffects.explosion(opts)
	local position, radius, time = opts.position, opts.radius, opts.time

	-- ── the fireball ──────────────────────────────────────────────────
	local ball = Instance.new("Part")
	ball.Name = "ExplosionSphere"
	ball.Shape, ball.Anchored, ball.CanCollide, ball.CanQuery, ball.CanTouch =
		Enum.PartType.Ball, true, false, false, false
	ball.CastShadow = false
	ball.Material = Enum.Material.Neon
	ball.Color = opts.colorFn and opts.colorFn(0) or opts.startColor
	ball.Size, ball.Position = Vector3.new(1, 1, 1), position
	ball.Parent = Workspace

	TweenService:Create(ball,
		TweenInfo.new(time, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
		{ Size = Vector3.new(radius, radius, radius) * 2 }):Play()

	local fade = TweenService:Create(ball,
		TweenInfo.new(time * 0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Transparency = 1 })
	task.delay(time * 0.25, function()
		if ball.Parent then
			fade:Play()
		end
	end)

	if opts.endColor and not opts.colorFn then
		TweenService:Create(ball,
			TweenInfo.new(time * 0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Color = opts.endColor }):Play()
	end

	-- ── the flash ─────────────────────────────────────────────────────
	local flashGui, flashImg = makeFlash(
		position,
		opts.flashScale,
		opts.flashImage,
		opts.flashColor or Color3.new(1, 1, 1),
		opts.flashTime,
		opts.flashEndColor,
		opts.flashRecolorAt
	)

	-- ── the inside view ───────────────────────────────────────────────
	-- A full-screen fill in the fireball's colour, and the flash drawn
	-- again on top of it at the size the billboard would be, both shown
	-- only while the camera is inside the fireball. Driven from
	-- RenderStepped so the check uses the camera the frame is drawn with.
	local screen = getOverlay()
	local fill, screenFlash
	if screen then
		fill = Instance.new("Frame")
		fill.Name = "ExplosionFill"
		fill.Size = UDim2.fromScale(1, 1)
		fill.BorderSizePixel = 0
		fill.Visible = false
		fill.ZIndex = 1
		fill.Parent = screen

		screenFlash = Instance.new("ImageLabel")
		screenFlash.Name = "ExplosionFlash"
		screenFlash.BackgroundTransparency = 1
		screenFlash.AnchorPoint = Vector2.new(0.5, 0.5)
		screenFlash.Image = opts.flashImage
		screenFlash.ScaleType = Enum.ScaleType.Fit
		screenFlash.Visible = false
		screenFlash.ZIndex = 2
		screenFlash.Parent = screen
	end

	local elapsed = 0
	local step
	step = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		if opts.colorFn and ball.Parent then
			ball.Color = opts.colorFn(elapsed)
		end
		if not fill then
			return
		end

		local camera = Workspace.CurrentCamera
		local inside = camera ~= nil
			and ball.Parent ~= nil
			and ball.Transparency < 1
			and (camera.CFrame.Position - position).Magnitude < ball.Size.X / 2
		fill.Visible = inside
		if not inside then
			screenFlash.Visible = false
			return
		end
		fill.BackgroundColor3 = ball.Color
		fill.BackgroundTransparency = ball.Transparency

		-- The billboard's size is in studs; on screen that's studs divided
		-- by how many studs the view spans at that depth.
		local point, onScreen = camera:WorldToViewportPoint(position)
		local studs = flashGui.Parent and flashGui.Size.X.Scale or 0
		if onScreen and point.Z > 0 and studs > 0 then
			local viewHeight = camera.ViewportSize.Y
			local studsAcross = 2 * point.Z * math.tan(math.rad(camera.FieldOfView) / 2)
			local pixels = studs / studsAcross * viewHeight
			screenFlash.Position = UDim2.fromOffset(point.X, point.Y)
			screenFlash.Size = UDim2.fromOffset(pixels, pixels)
			screenFlash.ImageColor3 = flashImg.ImageColor3
			screenFlash.Visible = true
		else
			screenFlash.Visible = false
		end
	end)

	task.delay(math.max(time, opts.flashTime or 0), function()
		step:Disconnect()
		if ball.Parent then
			ball:Destroy()
		end
		if fill then
			fill:Destroy()
			screenFlash:Destroy()
		end
	end)
end

-- ── highlight ─────────────────────────────────────────────────────────

-- The beat before a ball goes: a solid fill fading in over `duration`.
-- Returns the Highlight so the caller can keep recolouring it (a
-- radiant ball's fade tracks its own rainbow rather than freezing on
-- whatever hue the sale started on).
-- A mimic's legs are separate parts in a Model under its body (see
-- MimicLegsClient), and a Highlight on the body covers the body alone —
-- so a bomb's hit, the collapse or a knock lit up a floating head. This
-- gives the legs a copy of whatever highlight the body just got, tweened
-- the same way, and removes it whenever the original goes: when the
-- caller destroys it, when a fade finishes, or when the orb itself does.
--
-- Any other orb has no MimicLegs and this does nothing. Legs that sprout
-- AFTER a highlight was made don't get one, which only matters for a fade
-- that happens to straddle the exact moment a mimic wakes.
local function mirrorOntoLegs(highlight, part, tweenInfo, goal)
	local legs = part:FindFirstChild("MimicLegs")
	if not (legs and legs:IsA("Model")) then
		return
	end
	local copy = highlight:Clone()
	copy.Parent = legs -- no Adornee: a Highlight lights up the Model it's parented to
	highlight.Destroying:Connect(function()
		if copy.Parent then
			copy:Destroy()
		end
	end)
	if tweenInfo then
		TweenService:Create(copy, tweenInfo, goal):Play()
	end
end

function BoardEffects.fadeIn(part, color, duration, alwaysOnTop)
	local highlight = Instance.new("Highlight")
	highlight.FillColor = color
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.DepthMode = alwaysOnTop and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded
	highlight.Parent = part

	local info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	mirrorOntoLegs(highlight, part, info, { FillTransparency = 0 })
	TweenService:Create(highlight, info, { FillTransparency = 0 }):Play()

	return highlight
end

-- The mirror image: lands at full colour and fades off, then cleans
-- itself up. Used for "that just happened to this orb" feedback — a
-- bomb marking everything its blast caught — where fadeIn is for "this
-- is about to happen to it".
--
-- Exponential-out by default, because a hit should read as an impact:
-- almost all the colour is gone in the first fifth of the time and the
-- rest is a tail. A Quad fade over the same 0.5s reads as a glow rather
-- than a hit.
--
-- startTransparency (default 0, fully solid) is where the fill starts:
-- a thrown orb's knock on a mimic flashes at half strength.
function BoardEffects.fadeOut(part, color, duration, easingStyle, startTransparency)
	local highlight = Instance.new("Highlight")
	highlight.FillColor = color
	highlight.FillTransparency = startTransparency or 0
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = part

	local info = TweenInfo.new(
		duration,
		easingStyle or Enum.EasingStyle.Exponential,
		Enum.EasingDirection.Out
	)
	mirrorOntoLegs(highlight, part, info, { FillTransparency = 1 })
	local tween = TweenService:Create(highlight, info, { FillTransparency = 1 })

	-- Destroyed on completion rather than left at transparency 1: a
	-- Highlight still costs something to render, and a busy board can
	-- take several blasts before any of these would have been cleaned
	-- up by the orb itself being sold.
	tween.Completed:Connect(function()
		if highlight.Parent then
			highlight:Destroy()
		end
	end)
	tween:Play()

	return highlight
end

BoardEffects.SOUNDS = Config.SOUNDS

-- ── screen shake ──────────────────────────────────────────────────────
-- Nudges the camera around for a moment. Two details make this behave
-- rather than fight everything else:
--
-- 1. It's bound at Camera + 1, so it runs AFTER the default camera
--    module has set CFrame for the frame and multiplies its offset onto
--    the result. Setting camera.CFrame from Heartbeat instead gets
--    overwritten before anything is drawn, which is why naive screen
--    shake in Roblox so often does nothing at all.
-- 2. The offset comes from math.noise rather than math.random, so
--    consecutive frames are related to each other. Per-frame random is
--    a buzz; noise is a shake.
--
-- Overlapping calls don't stack — the strongest one wins and restarts
-- the clock. Two bombs going off together should not be twice the
-- earthquake, and a long weak shake shouldn't swallow a short sharp one.

local shakeConnection
local shakeAmplitude, shakeDuration, shakeElapsed, shakeSeed = 0, 0, 0, 0

local SHAKE_BINDING = "BoardShake"

-- math.noise is nominally [-1, 1] but in practice almost never leaves
-- [-0.5, 0.5]. Without this the `amplitude` argument would mean about
-- half what it looks like it means, and every caller would end up
-- compensating with a number that reads wrong in the config.
local SHAKE_NOISE_GAIN = 2

local function stopShake()
	if shakeConnection then
		RunService:UnbindFromRenderStep(SHAKE_BINDING)
		shakeConnection = false
	end
	shakeAmplitude = 0
end

function BoardEffects.shake(amplitude, duration, frequency, rotation)
	if amplitude <= 0 or duration <= 0 then
		return
	end

	-- A weaker shake arriving mid-shake is ignored outright; a stronger
	-- one takes over.
	local remaining = shakeAmplitude > 0
		and shakeAmplitude * (1 - math.clamp(shakeElapsed / shakeDuration, 0, 1))
		or 0
	if amplitude <= remaining then
		return
	end

	shakeAmplitude = amplitude
	shakeDuration = duration
	shakeElapsed = 0
	shakeSeed = math.random() * 1000
	frequency = frequency or 20
	rotation = rotation or 0.8

	if shakeConnection then
		return -- already bound; the numbers above are all it needs
	end
	shakeConnection = true

	RunService:BindToRenderStep(SHAKE_BINDING, Enum.RenderPriority.Camera.Value + 1, function(dt)
		local camera = Workspace.CurrentCamera
		if not camera or shakeAmplitude <= 0 then
			stopShake()
			return
		end

		shakeElapsed += dt
		if shakeElapsed >= shakeDuration then
			stopShake()
			return
		end

		-- Quadratic decay: the shake is mostly over well before it
		-- formally ends, which keeps the tail from reading as a rattle.
		local remainingFraction = 1 - (shakeElapsed / shakeDuration)
		local strength = shakeAmplitude * remainingFraction * remainingFraction

		local t = shakeElapsed * frequency
		local gain = strength * SHAKE_NOISE_GAIN
		local x = math.noise(t, shakeSeed, 0) * gain
		local y = math.noise(t, shakeSeed, 1) * gain
		local roll = math.noise(t, shakeSeed, 2) * gain * rotation

		camera.CFrame = camera.CFrame * CFrame.new(x, y, 0) * CFrame.Angles(0, 0, math.rad(roll))
	end)
end

-- ── warm-up ───────────────────────────────────────────────────────────
-- The first sell of a session used to flash nothing at all. The image
-- hasn't been decoded yet at that point, and a flash only exists for
-- 0.4s — by the time it's ready there's nothing left to draw it on.
-- Every later flash looked right because the first one had paid for it.
--
-- SoundClient preloads this same image for the bomb, but it does it
-- behind a list of thirty-odd sounds, so whether it's ready in time is
-- a race against how fast the player gets to their first sale. This
-- asks for the handful the board itself needs, first, on its own
-- thread.
task.spawn(function()
	local warm = { FLASH_IMAGE }
	-- The bomb's flash is a different image from the sell flash, and it
	-- has the same first-time problem: a blast lasts 0.1s, which is not
	-- long enough to decode an image in.
	if Config.BOMB and Config.BOMB.FLASH_IMAGE then
		table.insert(warm, Config.BOMB.FLASH_IMAGE)
	end
	for _, sound in pairs(Config.SOUNDS) do
		table.insert(warm, sound.id)
	end
	pcall(function()
		ContentProvider:PreloadAsync(warm)
	end)
end)

return BoardEffects