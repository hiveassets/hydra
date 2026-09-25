--[[
    RadiantBomb (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-25 02:23:34
]]
--[[
	RadiantBomb (ModuleScript) — place in ReplicatedStorage → Behaviours
	(ReplicatedStorage.Behaviours.RadiantBomb).

	Replaces RadiantBombFuse, which lived in ReplicatedStorage.radiant and
	was swapped into a bomb in place of BombFuse when it rolled radiant.
	ClientBoard makes the same swap now: a radiant bomb runs this module
	and never Bomb (see BoardConfig.RADIANT_BEHAVIOUR).

	A bomb with a fuse twice as long, that halfway through collapses into
	a point of light, floats up off the platform hauling every plain orb
	up after it, and then goes off with a push that grows exponentially
	with its size. BoardConfig.RADIANT_BOMB has every number, and its
	header has the differences from a plain bomb in one place.

	WHAT WENT AWAY

	  * The PendingSell watchers. Two separate listeners existed to undo
	    the shrink, the density ramp and the lift if a sale landed partway,
	    because the server held a sold bomb on screen for 0.3s before
	    destroying it. The board takes a sold orb off the frame it's
	    clicked now, so there's nothing left to put back.
	  * The primed pull and boom Sounds, created at spawn and silently
	    played so the assets would be loaded later. BoardEffects preloads
	    every board sound at startup.
	  * Network ownership. The original went to some lengths never to
	    write the bomb's position or velocity from the server, so players
	    could still shove it. It's a local part: nothing to hand over.
	  * NumberValue tween drivers for the shine's entrance and wobble.
	    They're computed from elapsed time, as the magnet's are.

	WHAT DIDN'T CHANGE

	The collision-group swap before the shrink, the minimum size it
	shrinks to, the constant-mass density ramp, the friction ramp, the
	VectorForce lift with its ramp-in and its drag, the shine's shape, the
	tick speed-up — all of it is as it was, because each of those was
	fixing a real physics problem that a local part has just the same.

	The one number that did move is VFX_SCALE, from 0.5 to 1. The
	original built its fireball with the same units bug a plain bomb's
	had — a sphere half the size of the blast — and the plain bomb's was
	fixed in step 1. See BoardConfig.BOMB.VFX_SCALE.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Rep = game:GetService("ReplicatedStorage")
local CG = require(Rep:WaitForChild("CollisionGroups"))
local Blast = require(script.Parent:WaitForChild("Blast"))

local RadiantBomb = {}

-- ── the fuse's timeline ───────────────────────────────────────────────
-- Worked out once, up front, because the halfway pull has to know when
-- the middle of the REAL fuse is, and the speed-up makes the real fuse
-- shorter than the sum of its ticks.

local function tickSpeedFor(cfg, remaining)
	if remaining >= cfg.TICK_SPEEDUP_WINDOW then
		return 1
	end
	local frac = 1 - math.clamp(remaining, 0, cfg.TICK_SPEEDUP_WINDOW) / cfg.TICK_SPEEDUP_WINDOW
	return cfg.TICK_SPEEDUP_MAX ^ frac
end

local function timeline(cfg)
	local baseTotal = 0
	for _, phase in ipairs(cfg.PHASES) do
		baseTotal += phase.gap * phase.n
	end

	-- The sped-up tail, integrated numerically. It's a one-off per bomb
	-- and 200 steps is well past the precision anything here needs.
	local window = math.min(cfg.TICK_SPEEDUP_WINDOW, baseTotal)
	local steps = 200
	local step = window / steps
	local tail = 0
	for i = 0, steps - 1 do
		local remaining = window - (i + 0.5) * step
		tail += step / tickSpeedFor(cfg, remaining)
	end

	local total = (baseTotal - window) + tail
	local halfway = total / 2 - cfg.PULL_SHRINK_TIME / 2
	return baseTotal, total, halfway
end

-- ── the halfway pull ──────────────────────────────────────────────────
local function halfwayPull(ctx, pullDuration, rainbowAt)
	local cfg = ctx.config.RADIANT_BOMB
	local part = ctx.part
	local size = ctx.size -- the LEDGER size: pull strength and shine size come from this

	if not ctx.alive() then
		return
	end

	-- Out of contact with every orb BEFORE the shrink starts, not after.
	-- A sphere colliding with the pile while its own size changes under it
	-- is exactly the shape the solver throws across the map. RadiantPull
	-- passes through orbs and stays solid against the platform.
	CG.assign(part, CG.RadiantPull)

	local startSize = part.Size.X
	local baseProps = part.CurrentPhysicalProperties
	-- Proportional to real mass (the sphere-volume constant cancels out
	-- of the ratio below), so density can be raised exactly as fast as
	-- volume falls.
	local baseMass = baseProps.Density * startSize ^ 3

	-- Size only — see RADIANT_BOMB's float block in BoardConfig for why
	-- the original's density term is gone.
	local liftScale = math.clamp(size / cfg.SIZE_REF, cfg.LIFT_SCALE_MIN, cfg.LIFT_SCALE_MAX)

	local shrinkRange = math.max(startSize - cfg.PULL_MIN_SIZE, 0.001)

	local function applyPullPhysics()
		local current = math.max(part.Size.X, cfg.PULL_MIN_SIZE)
		local t = math.clamp((startSize - current) / shrinkRange, 0, 1)
		part.CustomPhysicalProperties = PhysicalProperties.new(
			math.clamp(baseMass / current ^ 3, 0.01, cfg.PULL_MAX_DENSITY),
			baseProps.Friction + (cfg.PULL_FRICTION - baseProps.Friction) * t,
			baseProps.Elasticity + (cfg.PULL_ELASTICITY - baseProps.Elasticity) * t,
			baseProps.FrictionWeight + (cfg.PULL_FRICTION_WEIGHT - baseProps.FrictionWeight) * t,
			baseProps.ElasticityWeight + (cfg.PULL_ELASTICITY_WEIGHT - baseProps.ElasticityWeight) * t
		)
	end

	-- The float. Not created until the shrink has landed: through the
	-- shrink the bomb is still an ordinary part sitting on the platform,
	-- and it leaves the ground at the same instant the shine and the pull
	-- cue fire.
	--
	-- F = m * (g + drag * (target - v)): cancel gravity, thrust toward a
	-- straight-up target speed, and bleed off anything else (a shove, a
	-- blast) through the same drag term. Ramped in from nothing over
	-- LIFT_RAMP_TIME so it lifts off rather than snapping into the air.
	local liftAttachment, liftForce, liftElapsed = nil, nil, 0

	local function startLift()
		liftAttachment = Instance.new("Attachment")
		liftAttachment.Name = "RadiantPullLiftAttachment"
		liftAttachment.Parent = part

		liftForce = Instance.new("VectorForce")
		-- StashClient looks for exactly this name to refuse a bomb that
		-- has started floating (see StashData.RADIANT_PULL_LIFT_FORCE).
		liftForce.Name = cfg.LIFT_FORCE_NAME
		liftForce.Attachment0 = liftAttachment
		liftForce.RelativeTo = Enum.ActuatorRelativeTo.World
		liftForce.ApplyAtCenterOfMass = true
		liftForce.Force = Vector3.zero
		liftForce.Parent = part
	end

	local function applyLift(dt)
		if not liftForce then
			return
		end
		-- Anchored (an AFK pause, or the collapse freeze), its mass reads as
		-- infinite and the force below as NaN, which the solver would apply
		-- the moment it's unanchored. No lift while it's pinned.
		if part.Anchored then
			liftForce.Force = Vector3.zero
			return
		end
		liftElapsed += dt
		local mass = part.AssemblyMass
		local target = Vector3.new(0, cfg.PULL_RISE_SPEED * liftScale, 0)
		local full = mass * (Vector3.new(0, Workspace.Gravity, 0) + (target - part.AssemblyLinearVelocity) * cfg.PULL_DRAG)
		local ramp = 1 - math.exp(-liftElapsed / cfg.LIFT_RAMP_TIME)
		liftForce.Force = full * ramp
	end

	-- Everything this started, torn down however the bomb leaves: sold,
	-- stashed mid-shrink, collapsed, or gone off. The shine is parented to
	-- the part and goes with it.
	local physics
	ctx.onStop(function()
		if physics then
			physics:Disconnect()
		end
		if liftForce and liftForce.Parent then
			liftForce:Destroy()
		end
		if liftAttachment and liftAttachment.Parent then
			liftAttachment:Destroy()
		end
	end)

	-- ── the shrink ────────────────────────────────────────────────────
	-- Size only, around the centre, so it lifts off cleanly rather than
	-- peeling itself off the floor. Exponential In: nearly all the visible
	-- travel is at the end. Stops at PULL_MIN_SIZE; the bomb goes
	-- invisible the moment it lands there, so the last stretch is never
	-- seen.
	local shrinkElapsed = 0
	local shrinking = true
	physics = RunService.Heartbeat:Connect(function(dt)
		if shrinking then
			shrinkElapsed = math.min(shrinkElapsed + dt, cfg.PULL_SHRINK_TIME)
			local alpha = TweenService:GetValue(
				shrinkElapsed / cfg.PULL_SHRINK_TIME,
				Enum.EasingStyle.Exponential,
				Enum.EasingDirection.In
			)
			local s = startSize + (cfg.PULL_MIN_SIZE - startSize) * alpha
			part.Size = Vector3.new(s, s, s)
		end
		applyPullPhysics()
		applyLift(dt)
	end)
	applyPullPhysics()

	while shrinkElapsed < cfg.PULL_SHRINK_TIME do
		RunService.Heartbeat:Wait()
		if not ctx.alive() then
			return
		end
	end
	shrinking = false

	-- ── the pull ──────────────────────────────────────────────────────
	part.Transparency = 1
	startLift()
	applyLift(0)

	ctx.effects.soundOn(part, ctx.config.SOUNDS.radiantBombPull)

	-- The size readout has no business showing through the shine.
	local display = part:FindFirstChild("display")
	if display then
		display:Destroy()
	end

	local gui = Instance.new("BillboardGui")
	gui.Adornee, gui.AlwaysOnTop = part, true
	gui.Parent = part

	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency, img.BorderSizePixel = 1, 0
	img.Size, img.Image = UDim2.new(1, 0, 1, 0), ctx.config.BOMB.FLASH_IMAGE
	img.ImageColor3, img.ImageTransparency = rainbowAt(os.clock(), cfg.PULL_HUE_CYCLE_TIME), 0
	img.ScaleType, img.ZIndex = Enum.ScaleType.Fit, 10
	img.Parent = gui
	img:SetAttribute("GreyOnCollapse", true)

	local shineBase = size * cfg.SHINE_SCALE
	local elapsed = 0

	while true do
		local dt = RunService.Heartbeat:Wait()
		-- Ends when the bomb does: detonation removes the part, and so do
		-- a sale, a stash and a collapse.
		if not ctx.alive() then
			return
		end
		elapsed += dt

		img.ImageColor3 = rainbowAt(os.clock(), cfg.PULL_HUE_CYCLE_TIME)

		local entrance = cfg.SHINE_ENTRANCE_START + (1 - cfg.SHINE_ENTRANCE_START) * TweenService:GetValue(
			math.clamp(elapsed / cfg.SHINE_ENTRANCE_TIME, 0, 1),
			cfg.SHINE_ENTRANCE_STYLE,
			Enum.EasingDirection.Out
		)
		local osc = cfg.SHINE_OSC_MIN + (cfg.SHINE_OSC_MAX - cfg.SHINE_OSC_MIN)
			* (0.5 - 0.5 * math.cos(elapsed * cfg.SHINE_OSC_HZ * math.pi * 2))

		-- Timed to land on zero at the fuse's own detonation instant. The
		-- bomb has no clock of its own for this; pullDuration is worked out
		-- from the fuse's timeline.
		local timeLeft = pullDuration - elapsed
		local exit = 1
		if timeLeft <= cfg.SHINE_EXIT_TIME then
			exit = 1 - TweenService:GetValue(
				1 - math.clamp(timeLeft, 0, cfg.SHINE_EXIT_TIME) / cfg.SHINE_EXIT_TIME,
				cfg.SHINE_EXIT_STYLE,
				Enum.EasingDirection.In
			)
		end

		local shine = shineBase * entrance * osc * exit
		gui.Size = UDim2.new(shine, 0, shine, 0)

		-- Plain orbs only, radiant ones included, and never one in your
		-- hands. No distance falloff, like a magnet's. It builds as the
		-- bomb climbs, so a small one still hauls its orbs up with it
		-- rather than floating off without them (see PULL_RAMP_GRAVITY).
		local climb = TweenService:GetValue(
			math.clamp(elapsed / math.max(pullDuration, 0.01), 0, 1),
			cfg.PULL_RAMP_STYLE,
			Enum.EasingDirection.In
		)
		local pullAccel = cfg.PULL_ACCEL * size + cfg.PULL_RAMP_GRAVITY * Workspace.Gravity * climb
		local position = part.Position
		for _, other in ipairs(ctx.folder:GetChildren()) do
			if other ~= part
				and other:IsA("BasePart")
				and ctx.looksLikeOrb(other)
				and not other:GetAttribute("Held")
			then
				local toBomb = position - other.Position
				local distance = toBomb.Magnitude
				if distance > 0.01 then
					other.AssemblyLinearVelocity += (toBomb / distance) * pullAccel * dt
				end
			end
		end
	end
end

-- ── detonation ────────────────────────────────────────────────────────
local function explode(ctx, litColorAt, primedBoom)
	if not ctx.alive() then
		return
	end

	local cfg = ctx.config.RADIANT_BOMB
	local size = ctx.size -- the LEDGER size
	local position = ctx.part.Position

	-- Bookkeeping first, as a plain bomb does: gone, paid nobody,
	-- replaced nothing.
	ctx.report(ctx.ops.EXPIRED, ctx.id)

	-- The boom now, while the primed sound is still on the part — removing
	-- the part would take it along. The bomb itself has to be gone before
	-- the blast, which would otherwise push it.
	ctx.effects.playPrimedAt(primedBoom, position, ctx.config.SOUNDS.radiantBombBoom)
	ctx.remove()

	Blast.detonate(ctx, {
		position = position,
		radius = size * cfg.RADIUS_PER_SIZE,
		-- Exponential in size, but never softer than a plain bomb of the
		-- same size: the original curve dips under the plain one from
		-- about size 2 to 20, and a radiant bomb pushing weaker than an
		-- ordinary one is never right. So it's whichever is bigger —
		-- a plain bomb's push up to about 20, the runaway curve past it.
		impulse = math.max(
			size * cfg.IMPULSE_PER_SIZE,
			cfg.SIZE_REF * cfg.IMPULSE_PER_SIZE * cfg.IMPULSE_GROWTH ^ (size - cfg.SIZE_REF)
		),
		-- carries on the flicker's own hue, so the fireball picks up from
		-- the colour of the last lit tick
		colorFn = litColorAt,
		vfxScale = cfg.VFX_SCALE,
		vfxTime = cfg.VFX_TIME,
		flashScale = cfg.FLASH_SCALE,
		flashTime = cfg.FLASH_TIME,
		-- (the boom has already played, above)
		shakeSize = size,
	})
end

function RadiantBomb.start(ctx)
	local cfg = ctx.config.RADIANT_BOMB
	local part = ctx.part

	-- Readied now so it lands on the flash; see BoardEffects.primeSound.
	local primedBoom = ctx.effects.primeSound(part, ctx.config.SOUNDS.radiantBombBoom)

	-- Each bomb starts at its own point on the colour wheel, so two on
	-- the board don't flash in lockstep. Every rainbow this bomb shows —
	-- the lit tick, the shine, the fireball — is offset by the same roll.
	local hueOffset = math.random()
	local function rainbowAt(clock, cycle)
		return Color3.fromHSV(((clock % cycle) / cycle + hueOffset) % 1, 1, 1)
	end

	-- The lit tick's hue only moves while a tick is actually lit, so it
	-- doesn't cycle ahead unseen through the dark ticks.
	local litElapsed = 0
	local function litColor()
		return rainbowAt(litElapsed, cfg.FLASH_HUE_CYCLE_TIME)
	end

	-- SellClient colours a radiant bomb's sale off this rather than off
	-- the part, which spends half its time on the dark navy tick.
	part:SetAttribute("RadiantFlashColor", litColor())
	part.Color = cfg.OFF_COLOR

	local lit = false
	local litLoop = RunService.Heartbeat:Connect(function(dt)
		if lit then
			litElapsed += dt
			part.Color = litColor()
			part:SetAttribute("RadiantFlashColor", part.Color)
		end
	end)
	ctx.onStop(function()
		litLoop:Disconnect()
	end)

	local baseTotal, total, halfway = timeline(cfg)
	local baseElapsed, elapsed = 0, 0
	local pullStarted = false

	for _, phase in ipairs(cfg.PHASES) do
		for _ = 1, phase.n do
			if not ctx.alive() then
				return
			end

			-- The same multiplier speeds up the flicker and pitches up the
			-- tick, so what you see and what you hear stay together.
			local tickSpeed = tickSpeedFor(cfg, math.max(baseTotal - baseElapsed, 0))
			local wait = phase.gap / tickSpeed
			task.wait(wait)
			if not ctx.alive() then
				return
			end
			baseElapsed += phase.gap
			elapsed += wait

			lit = not lit
			if lit then
				part.Color = litColor()
				part:SetAttribute("RadiantFlashColor", part.Color)
				ctx.effects.soundReusedOn(part, ctx.config.SOUNDS.bombFlicker, tickSpeed)
			else
				part.Color = cfg.OFF_COLOR
			end

			if not pullStarted and elapsed >= halfway then
				pullStarted = true
				-- From the end of the shrink to the fuse's detonation.
				local pullDuration = total - (halfway + cfg.PULL_SHRINK_TIME)
				task.spawn(halfwayPull, ctx, pullDuration, rainbowAt)
			end
		end
	end

	litLoop:Disconnect()

	explode(ctx, function(sinceBoom)
		-- the fireball is lit the whole time, so the hue keeps moving
		return rainbowAt(litElapsed + sinceBoom, cfg.FLASH_HUE_CYCLE_TIME)
	end, primedBoom)
end

return RadiantBomb