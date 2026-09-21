--[[
    BombFuse (Script)
    Path: ReplicatedStorage → Bomb
    Parent: Bomb
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-20 22:14:29
]]
--[[
	BombFuse (Script) — place inside the Bomb template in ReplicatedStorage
	(ReplicatedStorage.Bomb.BombFuse).

	Flickers, then detonates: real explosion physics, an expanding VFX
	ball, a billboard flash, and sound — all fired through SoundEvents so
	clients build/play sounds themselves instead of waiting on the
	server's Sound:Play() to replicate.

	Also the only place a (board) mimic ever gets defused: any
	MimicActive mimic caught inside the blast radius gets stripped back
	into a plain ball (see revertMimic) right before the impulse pass
	below, so the same explosion that defuses it is what sends it
	flying. A pet mimic (IsPetMimic attribute -- see PetMimicFuse's own
	header) is completely exempt from bombs, full stop: it's skipped by
	both the revertMimic check and the impulse check below, so a blast
	never defuses it, never touches its MimicActive, and never sends it
	flying -- same as a player's own character. Gameplay call, not a
	cosmetic one: letting bombs knock out a player's own pet mimic was
	funny but bad for gameplay, so it's now a non-event for them. See
	the two IsPetMimic checks in explode() below.
]]

local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local TS = game:GetService("TweenService")

local bomb = script.Parent
local folder = bomb.Parent -- already parented into Workspace.Balls by BallManager

local ballT = Rep:WaitForChild("Ball") -- what a defused mimic gets renamed to, below

-- flicker
local OFF, ON = Color3.fromRGB(27, 41, 53), Color3.fromRGB(255, 0, 0)
local PHASES = { { gap = 0.125, n = 16 }, { gap = 0.0625, n = 8 } } -- slow, then fast right before detonation

-- real explosion physics — the VFX below is cosmetic only and never touches these
local RADIUS_PER_SIZE, IMPULSE_PER_SIZE = 6, 5000

-- VFX: no min/max caps, scales directly (and smaller) with bomb size
local VFX_SCALE, VFX_TIME = 0.5, 0.3
local VFX_START, VFX_END = Color3.fromRGB(127, 68, 0), Color3.fromRGB(127, 0, 0)
local FLASH_SCALE, FLASH_TIME = 0.6, 0.1
local FLASH_IMAGE = "rbxassetid://131187911056182" -- keep in sync with SoundClient's preload

local FLICKER_SND, FLICKER_VOL = "rbxassetid://12221976", 1
local BOOM_SND, BOOM_VOL = "rbxassetid://12222084", 1

-- same RemoteEvent BallManager creates
local se = Rep:WaitForChild("SoundEvents")

-- Same idea RadiantBombFuse uses for its own boom: create and prime the
-- Sound immediately (well before detonation) instead of asking clients
-- to build one fresh via SoundEvents at explode() time -- that round
-- trip (and the client having to load the asset on demand) is what
-- caused the audible delay before the boom actually played. It's
-- parented to the bomb for now purely so it's primed against a live
-- Instance; explode() below reparents it to its own standalone anchor
-- before the bomb itself is destroyed.
local boomSound = Instance.new("Sound")
boomSound.SoundId = BOOM_SND
boomSound.Volume = BOOM_VOL
boomSound.Parent = bomb

-- Prime the Sound instance without producing an audible cue.
boomSound.Volume = 0
boomSound:Play()
boomSound:Stop()
boomSound.Volume = BOOM_VOL

-- ── flicker ─────────────────────────────────────────────────────────
-- true only while this bomb is still around AND not already claimed by
-- a sell. bomb.Parent alone isn't enough: SellService sets PendingSell
-- the instant a sell starts, but doesn't actually Destroy() the bomb
-- until after its 0.3s pre-sell highlight fade (see PRE_SELL_DELAY
-- there) — during that fade the bomb is still parented, so a Parent-only
-- check would let the fuse run right through a sell in progress and
-- detonate a bomb that's already been paid out and is on its way out.
local function stillLive()
	return bomb.Parent ~= nil and not bomb:GetAttribute("PendingSell")
end

-- returns false if the bomb vanished (or started selling) mid-flicker
local function flicker()
	local c = OFF
	bomb.Color = c

	for _, phase in ipairs(PHASES) do
		for _ = 1, phase.n do
			if not stillLive() then return false end
			task.wait(phase.gap)
			if not stillLive() then return false end

			c = (c == OFF) and ON or OFF
			bomb.Color = c
			if c == ON then
				-- "attachedReused": SoundClient keeps one Sound per bomb
				-- and restarts it, instead of a new instance per click
				se:FireAllClients("attachedReused", bomb, FLICKER_SND, FLICKER_VOL)
			end
		end
	end
	return stillLive()
end

-- ── explosion VFX: expanding neon ball, orange -> red, then fades ────
local function vfx(pos, blastRadius)
	local r = blastRadius * VFX_SCALE

	local ball = Instance.new("Part")
	ball.Shape, ball.Anchored, ball.CanCollide, ball.CanQuery = Enum.PartType.Ball, true, false, false
	ball.Material, ball.Color = Enum.Material.Neon, VFX_START
	ball.Size, ball.Position, ball.Parent = Vector3.new(1, 1, 1), pos, WS

	local expand = TS:Create(ball,
		TweenInfo.new(VFX_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
		{ Size = Vector3.new(r, r, r) * 2 })
	-- kept separate from the fade so orange -> red stays visible instead of getting buried by it
	local recolor = TS:Create(ball,
		TweenInfo.new(VFX_TIME * 0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Color = VFX_END })
	local fade = TS:Create(ball,
		TweenInfo.new(VFX_TIME * 0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Transparency = 1 })

	expand:Play()
	recolor:Play()
	task.delay(VFX_TIME * 0.25, function() -- delayed so the color shift reads before it fades
		if ball.Parent then fade:Play() end
	end)
	expand.Completed:Connect(function()
		if ball.Parent then ball:Destroy() end
	end)
end

-- ── billboard flash ───────────────────────────────────────────────
local function flash(pos, blastRadius)
	local anchor = Instance.new("Part")
	anchor.Anchored, anchor.CanCollide, anchor.CanQuery, anchor.Transparency = true, false, false, 1
	anchor.Size, anchor.Position, anchor.Parent = Vector3.new(0.1, 0.1, 0.1), pos, WS

	local scale = blastRadius * FLASH_SCALE
	local gui = Instance.new("BillboardGui")
	gui.Adornee, gui.Size, gui.AlwaysOnTop, gui.Parent = anchor, UDim2.new(scale, 0, scale, 0), true, anchor

	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency, img.BorderSizePixel = 1, 0
	img.Size, img.Image = UDim2.new(1, 0, 1, 0), FLASH_IMAGE
	img.ImageColor3, img.ImageTransparency = Color3.new(1, 1, 1), 0 -- starts white
	img.ScaleType, img.Parent = Enum.ScaleType.Fit, gui
	img.ZIndex = 10
	-- AlwaysOnTop (above) bypasses the normally-composited render that a
	-- collapse's ColorCorrectionEffect desaturates — this attribute is
	-- what lets BallManager's triggerCollapse find and grey this out in
	-- step with everything else instead of it staying full color
	img:SetAttribute("GreyOnCollapse", true)

	task.delay(0.03, function()
		if img.Parent then img.ImageColor3 = Color3.fromRGB(255, 255, 0) end
	end)
	task.delay(FLASH_TIME, function()
		if anchor.Parent then anchor:Destroy() end
	end)
end

-- ── mimic defuse (board mimics only) ─────────────────────────────
-- The only way a BOARD mimic ever turns back into a normal ball (see
-- MimicFuse's header). Never called for a pet mimic (IsPetMimic) --
-- see the explode() call site below and this file's header for why.
--
-- MimicFuse sets MimicActive true the instant a board
-- mimic wakes up and starts wandering, and this is the only thing that
-- ever sets it back to false — MimicFuse's own wander loop polls that
-- attribute every step and just stops the moment it flips, so nothing
-- here needs to reach into that script directly.
--
-- Deliberately does NOT apply any impulse itself: it just strips the
-- mimic back down to a plain, unanchored ball (destroying its legs,
-- restoring its size display, renaming it back to Ball) and leaves it
-- unanchored right where explode()'s own impulse pass below is about
-- to look — since that pass checks `not part.Anchored` on the very
-- same objects in the very same iteration, a just-defused mimic gets
-- caught by it same as anything else in range, which is where "likely
-- launched off the platform" actually comes from.
local function revertMimic(part)
	local legs = part:FindFirstChild("MimicLegs")
	if legs then
		legs:Destroy()
	end

	local size = part:GetAttribute("TargetSize") or part.Size.X
	local display = part:FindFirstChild("display")
	local label = display and display:FindFirstChild("numDisplay")
	if label then
		label.Text = tostring(math.round(size))
	end

	part:SetAttribute("MimicActive", false)
	part.Name = ballT.Name
	part.Anchored = false
	part.CanCollide = true
	part.CanQuery = true
end

-- ── detonation ────────────────────────────────────────────────────
local function explode()
	-- same stillLive check flicker() uses — covers a sell that lands in
	-- the gap between flicker() returning true and explode() being
	-- called (no yield between them, but cheap enough to just check again
	-- rather than assume that gap is truly zero-width)
	if not stillLive() then return end

	local size = bomb:GetAttribute("TargetSize") or bomb.Size.X
	local pos = bomb.Position
	local blastRadius = size * RADIUS_PER_SIZE -- real radius, unaffected by VFX scaling

	-- boomSound is already loaded and primed (see its creation up top) —
	-- move it off the bomb onto its own standalone anchor at the blast
	-- position before the bomb itself is destroyed, then play it from
	-- there, same "already-primed local Sound" approach RadiantBombFuse
	-- uses for its own boom, instead of requesting a fresh Sound from
	-- clients via SoundEvents at the moment it's needed
	local soundAnchor = Instance.new("Part")
	soundAnchor.Anchored, soundAnchor.CanCollide, soundAnchor.CanQuery, soundAnchor.Transparency = true, false, false, 1
	soundAnchor.Size, soundAnchor.Position, soundAnchor.Parent = Vector3.new(0.1, 0.1, 0.1), pos, WS
	boomSound.Parent = soundAnchor
	boomSound:Play()
	task.delay(boomSound.TimeLength > 0 and boomSound.TimeLength or 3, function()
		if soundAnchor.Parent then soundAnchor:Destroy() end
	end)

	bomb:Destroy()
	vfx(pos, blastRadius)
	flash(pos, blastRadius)

	-- only affects balls/bombs/mimics in the same folder; impulse (not
	-- velocity) naturally accounts for each object's mass
	for _, part in ipairs(folder:GetChildren()) do
		if part:IsA("BasePart") then
			local offset = part.Position - pos
			local dist = offset.Magnitude

			-- a live, in-range mimic gets handled BEFORE the impulse
			-- check right below — same reasoning as before: same part,
			-- same iteration, so whichever branch runs here is what lets
			-- the impulse check right after actually catch it.
			--
			-- Pet mimics (IsPetMimic) are skipped entirely here — bombs
			-- have no effect on them at all now (no defuse, no dormancy,
			-- no MimicActive flip), so PetMimicFuse's teardown watcher
			-- and MimicLegsClient's leg-retract loop never fire off a
			-- blast. Only a board mimic gets the full revertMimic
			-- treatment and comes out the other side a plain sellable
			-- ball.
			if dist <= blastRadius and part:GetAttribute("MimicActive") and not part:GetAttribute("IsPetMimic") then
				revertMimic(part)
			end

			-- pet mimics are exempt from the blast impulse entirely, the
			-- same way a player's own character never gets launched by a
			-- bomb either -- only the MimicActive->false handling above
			-- applies to them, never this push
			if not part.Anchored and dist <= blastRadius and not part:GetAttribute("IsPetMimic") then
				local dir = (dist > 0.01) and (offset / dist) or Vector3.new(0, 1, 0)
				local falloff = 1 - dist / blastRadius -- full at center, zero at the edge
				part:ApplyImpulse(dir * size * IMPULSE_PER_SIZE * falloff)
			end
		end
	end
end

-- ── run ───────────────────────────────────────────────────────────
if flicker() then
	explode()
end