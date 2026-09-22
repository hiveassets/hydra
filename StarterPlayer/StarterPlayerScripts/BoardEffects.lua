--[[
    BoardEffects (ModuleScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Exported: 2026-09-22 15:18:20
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

-- ── highlight ─────────────────────────────────────────────────────────

-- The beat before a ball goes: a solid fill fading in over `duration`.
-- Returns the Highlight so the caller can keep recolouring it (a
-- radiant ball's fade tracks its own rainbow rather than freezing on
-- whatever hue the sale started on).
function BoardEffects.fadeIn(part, color, duration, alwaysOnTop)
	local highlight = Instance.new("Highlight")
	highlight.FillColor = color
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.DepthMode = alwaysOnTop and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded
	highlight.Parent = part

	TweenService:Create(
		highlight,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ FillTransparency = 0 }
	):Play()

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
function BoardEffects.fadeOut(part, color, duration, easingStyle)
	local highlight = Instance.new("Highlight")
	highlight.FillColor = color
	highlight.FillTransparency = 0
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = part

	local tween = TweenService:Create(
		highlight,
		TweenInfo.new(
			duration,
			easingStyle or Enum.EasingStyle.Exponential,
			Enum.EasingDirection.Out
		),
		{ FillTransparency = 1 }
	)

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
