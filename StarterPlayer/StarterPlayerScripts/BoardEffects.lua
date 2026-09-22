--[[
    BoardEffects (ModuleScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Exported: 2026-09-22 13:33:38
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

BoardEffects.SOUNDS = Config.SOUNDS

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
	for _, sound in pairs(Config.SOUNDS) do
		table.insert(warm, sound.id)
	end
	pcall(function()
		ContentProvider:PreloadAsync(warm)
	end)
end)

return BoardEffects