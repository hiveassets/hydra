--[[
    Mimic (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-25 02:23:34
]]
--[[
	Mimic (ModuleScript) — place in ReplicatedStorage → Behaviours
	(ReplicatedStorage.Behaviours.Mimic).

	Replaces MimicFuse, which lived inside the Mimic template and ran on
	the server. Delete that script; this is the whole of it. The legs are
	still drawn by MimicLegsClient, which watches this orb's MimicActive
	attribute exactly as it always did.

	A mimic launches and settles looking exactly like an ordinary orb — a
	random colour and its size on the label. After five seconds it wakes:
	"??" on the label, legs sprout, it pushes itself up onto them, and it
	wanders the platform. Now and then it hunts a smaller orb, stands over
	it, and eats it for half its price. A bomb, or being shoved off the
	edge, turns it back into an ordinary orb of the same size.

	WHAT THE SERVER HEARS

	Three things, ids only (see Board's mimic section):
	  MIMIC_WAKE    it woke — the mimic badge, and permission to eat
	  MIMIC_ATE     it caught this orb — half the orb's size, paid out
	  MIMIC_REVERT  it's an ordinary orb now
	Everything else — the whole creature — is this client's.

	WHAT DIDN'T CHANGE

	Every number in the movement, hunting and balance sections below is
	MimicFuse's, and so is the shape of the physics: the body stays a real
	unanchored part, walked by a force-capped velocity servo so a shove
	actually moves it, held at standing height by a Y-only position servo,
	and turned by a torque-capped orientation servo so a hit can make it
	stagger. The numbers two scripts share (the wake delay, the leg sprout
	time, the standing height) moved to BoardConfig.MIMIC.

	WHAT WENT AWAY

	  * The pet-mimic early return. A pet mimic won't be this module at
	    all (step 7).
	  * BadgeService calls and the BadgeAwarded relay — the server awards
	    the badge when it hears MIMIC_WAKE.
	  * SellService.mimicAbsorb and its PendingSell/Sold attribute dance.
	    The board claims the prey, floats it in and removes it (ClientBoard's
	    absorb); the server pays when it hears MIMIC_ATE.
	  * The long comment about network ownership. There's no network in
	    it any more.
	  * The Logs line. Plan decision 3: mimics are never named in the game
	    until the pet mimic is unlocked.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Rep = game:GetService("ReplicatedStorage")
local CG = require(Rep:WaitForChild("CollisionGroups"))

local Mimic = {}

-- ── config: wake-up ───────────────────────────────────────────────────
-- WAKE_DELAY, LEGS_SPROUT_TIME, LEG_LIFT_FRAC, WAKE_MIN_Y and MAX_RADIUS
-- are in BoardConfig.MIMIC, because MimicLegsClient or the server read
-- them too.
-- BODY_RISE_TIME (the body pushing itself up onto its legs, once they've
-- all landed) is there too now: MimicLegsClient holds the feet planted
-- for exactly that long. The fallback covers an older BoardConfig.

-- ── config: wander/hunt ───────────────────────────────────────────────
-- Speeds and ranges are per point of body size, tuned at size 5.
local WALK_SPEED_PER_SIZE = 2
local CHASE_SPEED_PER_SIZE = 4
local TURN_SPEED = 4              -- radians/sec
local WANDER_RADIUS = 50          -- from the spot it woke at
local WORLD_BOUND_RADIUS = 50     -- no target it picks is ever further than this from the centre
local IDLE_MIN, IDLE_MAX = 1, 3   -- seconds between wander legs
local LOOK_AROUND_CHANCE = 0.35
local LOOK_AROUND_MAX_TURN = math.rad(110)
local HUNT_CHANCE = 0.3           -- rolled at each idle and every HUNT_RECHECK_INTERVAL mid-wander
local HUNT_RECHECK_INTERVAL = 1
local HUNT_RADIUS_PER_SIZE = 5.6
local EAT_OVERLAP_DIST_PER_SIZE = 0.2
local ARRIVE_DIST_PER_SIZE = 0.6
local EAT_STOP_TIME = 0.25
local EAT_STOP_ACCEL = 60

-- ── config: physics-driven movement ───────────────────────────────────
local WALK_MAX_FORCE = 9000
local STAND_MAX_FORCE = 40000
local STAND_RESPONSIVENESS = 25
local ORIENT_MAX_TORQUE = 25000
local ORIENT_RESPONSIVENESS = 15
local ORIENT_RECOVERY_RESPONSIVENESS = 40
local STAND_FORCE_SAFETY = 3
local MOVE_ACCEL = 18
local WALK_FORCE_SAFETY = 2.5

-- ── config: balance recovery ──────────────────────────────────────────
local RECOVERY_TILT_THRESHOLD = math.rad(12)
local RECOVERY_VELOCITY_THRESHOLD = 10

-- ── config: organic wander ────────────────────────────────────────────
local WANDER_NOISE_STRENGTH = 0.5
local WANDER_NOISE_FREQ = 0.35
local SPEED_VARIATION = 0.25
local SPEED_NOISE_FREQ = 0.6

local ARRIVE_STOP_MARGIN = 1.2
local ARRIVE_BRAKE_INSET = 1.5

-- ── dormant ───────────────────────────────────────────────────────────
-- Five seconds of being an orb. Returns false if it stopped being able
-- to wake in that time.
--
-- What cancels a wake:
--   * it left the board (sold can't happen — a dormant mimic isn't
--     sellable — but a collapse or a resync can take it);
--   * the board reported it falling, or it's below WAKE_MIN_Y after
--     having reached the platform. The board and the server handle the
--     fall itself: a dormant mimic splits like the orb it's passing for;
--   * it's drifted past MAX_RADIUS. It then simply never wakes.
--
-- The clock only runs while the board is running, so an AFK pause holds
-- it rather than letting a mimic wake up the moment you come back.
local function sleep(ctx)
	local cfg = ctx.config.MIMIC
	local part = ctx.part
	local reachedPlatform = false

	local function stillAsleep()
		if not ctx.alive() or ctx.state() == "falling" then
			return false
		end
		local pos = part.Position
		if pos.Y >= cfg.WAKE_MIN_Y then
			reachedPlatform = true
		elseif reachedPlatform then
			return false
		end
		-- It launches from underneath the platform, so it's below
		-- WAKE_MIN_Y for its first moments by design; that's why the Y
		-- check only bites once it has been above the line.
		return Vector3.new(pos.X, 0, pos.Z).Magnitude <= cfg.MAX_RADIUS
	end

	local elapsed = 0
	while elapsed < cfg.WAKE_DELAY do
		if not stillAsleep() then
			return false
		end
		local dt = RunService.Heartbeat:Wait()
		if ctx.running() then
			elapsed += dt
		end
	end

	-- ...and then it waits until it's actually resting on something. Its
	-- time is up, but if it's mid-bounce or has been knocked into the air
	-- it holds on until it lands. Waking in mid-air was what had it
	-- measure the air as its floor and stand on it forever. Same gate as
	-- the splitter's: frames AND time, so it can't pass at the top of an
	-- arc at any framerate.
	local groundedFrames, groundedTime = 0, 0
	while true do
		if not stillAsleep() then
			return false
		end
		local dt = RunService.Heartbeat:Wait()
		if math.abs(part.AssemblyLinearVelocity.Y) <= cfg.GROUNDED_VY then
			if groundedFrames > 0 then
				groundedTime += dt
			end
			groundedFrames += 1
		else
			groundedFrames, groundedTime = 0, 0
		end
		if groundedFrames >= cfg.GROUNDED_FRAMES and groundedTime >= cfg.GROUNDED_TIME and ctx.running() then
			return stillAsleep()
		end
	end
end

-- ── awake ─────────────────────────────────────────────────────────────
local function live(ctx)
	local cfg = ctx.config.MIMIC
	local part = ctx.part
	local folder = ctx.folder
	local bodySize = ctx.size -- the ledger's, which is what the server compares prey against

	-- The server marks it awake (and awards the badge). Sent first, so
	-- nothing it does from here can arrive before the ledger knows.
	ctx.report(ctx.ops.MIMIC_WAKE, ctx.id)

	local groundRayParams = RaycastParams.new()
	groundRayParams.FilterType = Enum.RaycastFilterType.Exclude
	groundRayParams.FilterDescendantsInstances = { part }

	-- What it's standing on at (x, z): a ray straight down from a body's
	-- height above where the body is RIGHT NOW, over GROUND_RAY_REACH.
	-- nil means there's nothing under it at all.
	--
	-- The original looked down from where it first WOKE (floorY + a few
	-- sizes), over a short reach, and when that missed it answered "the
	-- floor is wherever I measured it at wake". Wake in mid-air, or get
	-- knocked high enough, and the answer was the air, forever. Reading
	-- from the body's current height means a knock upward still finds the
	-- platform below it, and the long reach means only a real drop into
	-- nothing comes back empty. Starting a body's height up still lets it
	-- step onto anything no taller than that, as the original could.
	local function groundYAt(worldX, worldZ)
		local origin = Vector3.new(worldX, part.Position.Y + bodySize, worldZ)
		local result = Workspace:Raycast(origin, Vector3.new(0, -cfg.GROUND_RAY_REACH, 0), groundRayParams)
		return result and result.Position.Y or nil
	end

	-- The floor under it right now, by raycast rather than trusting
	-- Position.Y - size/2: residual bounce can leave it very slightly
	-- embedded at the moment it wakes, and the rise below would then aim
	-- too low. It only wakes once it's resting on something, so this
	-- finds it; the fallback is for a floor the ray can't see.
	local floorY = groundYAt(part.Position.X, part.Position.Z) or (part.Position.Y - bodySize / 2)
	local STAND_HEIGHT = bodySize / 2 + bodySize * cfg.LEG_LIFT_FRAC
	local bodyY = floorY + STAND_HEIGHT
	local wakePos = part.Position

	-- How high to hold the body. The legs decide: MimicLegsClient
	-- publishes FootY, the average height of the ground its feet are
	-- actually on, every frame it has them planted, and the body rides
	-- STAND_HEIGHT above that. Step a foot up onto an orb and that side's
	-- share lifts the body; lose the orb and it settles back. Before the
	-- legs are down (or on a client whose legs script hasn't caught up)
	-- it falls back on the floor under the body's own centre, which is
	-- what it always used to go by.
	local function legsGroundY(fallback)
		local footY = part:GetAttribute("FootY")
		if typeof(footY) == "number" then
			return footY
		end
		return fallback
	end

	local WALK_SPEED = WALK_SPEED_PER_SIZE * bodySize
	local CHASE_SPEED = CHASE_SPEED_PER_SIZE * bodySize
	local HUNT_RADIUS = HUNT_RADIUS_PER_SIZE * bodySize
	local EAT_OVERLAP_DIST = EAT_OVERLAP_DIST_PER_SIZE * bodySize
	local ARRIVE_DIST = ARRIVE_DIST_PER_SIZE * bodySize

	-- Tells MimicLegsClient which orb is being hunted, so its foot
	-- raycasts ignore it the same way groundYAt does. Made before
	-- MimicActive goes up, so it's there when the legs look for it.
	local huntedPreyValue = Instance.new("ObjectValue")
	huntedPreyValue.Name = "HuntedPrey"
	huntedPreyValue.Parent = part

	-- MimicLegsClient keys off this; SellClient and StashClient already
	-- leave anything named Mimic alone.
	part:SetAttribute("MimicActive", true)

	do
		local display = part:FindFirstChild("display")
		local label = display and display:FindFirstChild("numDisplay")
		if label then
			label.Text = "??"
		end
	end

	-- Its own collision group: collides with everything as normal except
	-- whichever orb is in MimicPrey — the one it's standing over to eat.
	part.CanCollide = true
	part.CollisionGroup = CG.MimicBody

	local mimicAttachment = Instance.new("Attachment")
	mimicAttachment.Name = "MimicRoot"
	mimicAttachment.Parent = part

	-- The mover: an invisible anchored part whose height is the standing
	-- servo's target and whose rotation is the orientation servo's. It
	-- never drags the body sideways.
	local mover = Instance.new("Part")
	mover.Name = "MimicMover"
	mover.Size = Vector3.new(0.2, 0.2, 0.2)
	mover.Transparency = 1
	mover.CanCollide, mover.CanQuery, mover.CastShadow = false, false, false
	mover.Anchored = true
	mover.CFrame = part.CFrame
	mover.Parent = part

	local moverAttachment = Instance.new("Attachment")
	moverAttachment.Name = "MimicMoverTarget"
	moverAttachment.Parent = mover

	-- Both force caps scale with mass past the flat numbers, so a big
	-- mimic can still lift itself and still brake its own walk.
	local walkMaxForce = math.max(WALK_MAX_FORCE, part.AssemblyMass * MOVE_ACCEL * WALK_FORCE_SAFETY)
	local standForce = math.max(STAND_MAX_FORCE, part.AssemblyMass * Workspace.Gravity * STAND_FORCE_SAFETY)

	local walkVelocity = Instance.new("LinearVelocity")
	walkVelocity.Name = "MimicWalkVelocity"
	walkVelocity.Attachment0 = mimicAttachment
	walkVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	walkVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	walkVelocity.ForceLimitsEnabled = true
	walkVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	walkVelocity.MaxAxesForce = Vector3.new(walkMaxForce, 0, walkMaxForce) -- never vertical: that's the height servo's job
	walkVelocity.VectorVelocity = Vector3.new(0, 0, 0)
	walkVelocity.Parent = part

	local alignPos = Instance.new("AlignPosition")
	alignPos.Name = "MimicAlignPosition"
	alignPos.Attachment0 = mimicAttachment
	alignPos.Attachment1 = moverAttachment
	alignPos.RigidityEnabled = false
	alignPos.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	alignPos.MaxAxesForce = Vector3.new(0, standForce, 0)
	alignPos.ForceRelativeTo = Enum.ActuatorRelativeTo.World -- world up, even while the body is tilted mid-stagger
	alignPos.Responsiveness = STAND_RESPONSIVENESS
	alignPos.Parent = part

	local alignOrient = Instance.new("AlignOrientation")
	alignOrient.Name = "MimicAlignOrientation"
	alignOrient.Attachment0 = mimicAttachment
	alignOrient.Attachment1 = moverAttachment
	alignOrient.RigidityEnabled = false
	alignOrient.MaxTorque = ORIENT_MAX_TORQUE
	alignOrient.Responsiveness = ORIENT_RESPONSIVENESS
	alignOrient.Parent = part

	-- The hunt's own state, torn down however it ends.
	local prey, preyGroup = nil, nil

	local function releasePrey()
		groundRayParams.FilterDescendantsInstances = { part }
		huntedPreyValue.Value = nil
		if prey and prey.Parent and preyGroup then
			prey.CollisionGroup = preyGroup
		end
		prey, preyGroup = nil, nil
	end

	-- Whenever the behaviour stops — reverted, collapsed, removed — the
	-- rig goes. The rig is parented to the orb, so a destroyed orb takes
	-- it anyway; this matters for the two cases where the orb lives on (a
	-- revert, and a collapse freeze).
	--
	-- It does NOT retract the legs. Only a revert does that (see below).
	-- A collapse freezes the board a second before it wipes it, and the
	-- wipe's highlight is meant to light the whole creature up, legs and
	-- all — so the legs stay standing, frozen with everything else, until
	-- the wipe takes the orb and them with it.
	ctx.onStop(function()
		releasePrey()
		walkVelocity:Destroy()
		alignPos:Destroy()
		alignOrient:Destroy()
		mover:Destroy()
		mimicAttachment:Destroy()
		huntedPreyValue:Destroy()
	end)

	-- ── turning back into an orb ──────────────────────────────────────
	-- The only two ways out while it lives: a bomb (via setDefuse, run
	-- synchronously by the blast before its push) and the platform edge.
	-- The ledger hears first, then the orb is handed back to the board as
	-- a plain orb of the same size and colour. MimicActive going false —
	-- in the onStop above — is what retracts the legs.
	local reverted = false
	local function revert()
		if reverted then
			return
		end
		reverted = true
		ctx.report(ctx.ops.MIMIC_REVERT, ctx.id)
		ctx.effects.soundOn(part, ctx.config.SOUNDS.mimicRevert)
		-- What retracts the legs: MimicLegsClient pulls them back into the
		-- body the moment this goes false.
		part:SetAttribute("MimicActive", false)
		ctx.becomeBall()
	end
	ctx.setDefuse(revert)

	-- ── a thrown orb knocks it back ───────────────────────────────────
	-- An orb thrown with the grab upgrade (GrabClient stamps it ThrownAt)
	-- that hits the body, still moving properly, knocks the mimic back
	-- along the orb's path, and it flashes magenta at half strength, legs
	-- and all. One knock per throw: the stamp is spent on the hit.
	--
	-- Physics all the way. The hit is a real impulse, sized by the ORB, so
	-- mass does what mass does: a light mimic goes further than a heavy
	-- one. What stops it is its own legs. The walk servo stays on the whole
	-- time — it never lets go and never takes over — but while the mimic is
	-- sliding its grip drops to KNOCK_SLIP_GRIP, so the force it can put
	-- down decelerates the body steadily instead of cancelling the knock
	-- outright. It carries on wanting to walk wherever it was walking; the
	-- body simply can't get there until its feet catch up. Grip comes back
	-- once it's moving within KNOCK_RECOVERED_SPEED of what it wants.
	local slipping = false
	local slipForce = Vector3.new(1, 0, 1) * (part.AssemblyMass * cfg.KNOCK_SLIP_GRIP)
	local gripForce = walkVelocity.MaxAxesForce

	local function setSlipping(value)
		if slipping == value then
			return
		end
		slipping = value
		walkVelocity.MaxAxesForce = value and slipForce or gripForce
	end

	local knockConnection = part.Touched:Connect(function(other)
		if reverted or not ctx.alive() then
			return
		end
		local thrownAt = other:GetAttribute("ThrownAt")
		if not thrownAt or os.clock() - thrownAt > cfg.KNOCK_WINDOW then
			return
		end
		if ctx.kindOf(other) ~= "ball" then
			return
		end
		local orbVelocity = other.AssemblyLinearVelocity
		if orbVelocity.Magnitude < cfg.KNOCK_MIN_ORB_SPEED then
			return -- a throw that's already rolled to a crawl just bumps it, like any orb
		end
		other:SetAttribute("ThrownAt", nil)

		-- Along the orb's path; straight away from it if the orb somehow
		-- arrived moving vertically.
		local direction = Vector3.new(orbVelocity.X, 0, orbVelocity.Z)
		if direction.Magnitude < 0.01 then
			local away = part.Position - other.Position
			direction = Vector3.new(away.X, 0, away.Z)
		end
		if direction.Magnitude < 0.01 then
			return
		end

		local orbSize = other:GetAttribute("TargetSize") or other.Size.X
		local mass = part.AssemblyMass
		-- The impulse the orb delivers, trimmed only if it would send this
		-- mimic faster than KNOCK_MAX_SPEED.
		local impulse = cfg.KNOCK_IMPULSE_PER_SIZE * orbSize
		impulse = math.min(impulse, cfg.KNOCK_MAX_SPEED * mass)

		setSlipping(true)
		part:ApplyImpulse(direction.Unit * impulse)

		ctx.effects.fadeOut(part, cfg.KNOCK_COLOR, cfg.KNOCK_FLASH_TIME, nil, cfg.KNOCK_FLASH_TRANSPARENCY)

		-- A small, fixed shake: the throw landed. Deliberately not scaled
		-- by the orb or the mimic. The fallbacks mean an older BoardConfig
		-- without these settings still gets a shake.
		ctx.effects.shake(
			cfg.KNOCK_SHAKE_AMPLITUDE or 0.25,
			cfg.KNOCK_SHAKE_TIME or 0.2,
			cfg.KNOCK_SHAKE_FREQUENCY or 25,
			cfg.KNOCK_SHAKE_ROTATION or 0.8
		)
	end)
	ctx.onStop(function()
		knockConnection:Disconnect()
	end)

	-- Called every frame something is steering it: gives it its grip back
	-- once the body has caught up with where it's trying to go.
	local function updateGrip()
		if not slipping then
			return
		end
		local actual = part.AssemblyLinearVelocity
		local intended = walkVelocity.VectorVelocity
		if (Vector3.new(actual.X, 0, actual.Z) - intended).Magnitude <= cfg.KNOCK_RECOVERED_SPEED then
			setSlipping(false)
		end
	end

	local function stillMimic()
		return ctx.alive() and not reverted
	end

	-- The edge. A shove can carry the real body anywhere, and
	-- WORLD_BOUND_RADIUS only limits where it AIMS, so this watches where
	-- it actually IS for the rest of its life.
	task.spawn(function()
		while stillMimic() do
			local pos = part.Position
			if Vector3.new(pos.X, 0, pos.Z).Magnitude > cfg.MAX_RADIUS then
				revert()
				return
			end
			RunService.Heartbeat:Wait()
		end
	end)

	-- ── legs sprout ───────────────────────────────────────────────────
	-- Held still while MimicLegsClient grows the legs out, each one
	-- overlapping the next, until the last foot lands.
	do
		local t = 0
		while t < cfg.LEGS_SPROUT_TIME do
			if not stillMimic() then
				return
			end
			t += RunService.Heartbeat:Wait()
		end
	end

	-- ── push-up ───────────────────────────────────────────────────────
	-- Then rises onto them, by moving the mover and letting the height
	-- servo carry the real body after it.
	ctx.effects.flatSound(ctx.config.SOUNDS.mimicWake)
	do
		local restY = part.Position.Y
		local BODY_RISE_TIME = cfg.BODY_RISE_TIME or 0.6
		local t = 0
		while t < BODY_RISE_TIME do
			if not stillMimic() then
				return
			end
			local dt = RunService.Heartbeat:Wait()
			t = math.min(t + dt, BODY_RISE_TIME)
			local alpha = 1 - (1 - t / BODY_RISE_TIME) ^ 2 -- ease-out
			local targetY = legsGroundY(floorY) + STAND_HEIGHT
			mover.CFrame = CFrame.new(wakePos.X, restY + (targetY - restY) * alpha, wakePos.Z)
		end
	end

	-- ── movement ──────────────────────────────────────────────────────
	local heading = 0
	local velocity = Vector3.new(0, 0, 0) -- the walk controller's eased intent; persists across moves so momentum carries
	local noiseSeed = math.random() * 1000

	local function isKnocked()
		local tiltDot = math.clamp(part.CFrame.UpVector:Dot(Vector3.new(0, 1, 0)), -1, 1)
		local actualVel = part.AssemblyLinearVelocity
		local velMismatch = (Vector3.new(actualVel.X, 0, actualVel.Z) - velocity).Magnitude
		return math.acos(tiltDot) > RECOVERY_TILT_THRESHOLD or velMismatch > RECOVERY_VELOCITY_THRESHOLD
	end

	local function updateBalance()
		alignOrient.Responsiveness = isKnocked() and ORIENT_RECOVERY_RESPONSIVENESS or ORIENT_RESPONSIVENESS
	end

	local function stepVelocity(desiredVel, dt, accel)
		local delta = desiredVel - velocity
		local maxDelta = (accel or MOVE_ACCEL) * dt
		if delta.Magnitude > maxDelta then
			delta = delta.Unit * maxDelta
		end
		velocity += delta

		if velocity.Magnitude > 0.05 then
			-- negated, or it walks backwards
			local desiredHeading = math.atan2(-velocity.X, -velocity.Z)
			local diff = (desiredHeading - heading + math.pi) % (2 * math.pi) - math.pi
			heading += math.clamp(diff, -TURN_SPEED * dt, TURN_SPEED * dt)
		end

		updateGrip()
		walkVelocity.VectorVelocity = Vector3.new(velocity.X, 0, velocity.Z)

		-- Standing height comes from its feet (legsGroundY above). With
		-- nothing under the body at all, it stops holding itself up and
		-- falls, and the board takes it from there — an awake mimic that
		-- goes over the edge is gone, the way a bomb is. Feet still
		-- planted back on the platform don't hold it up over open air.
		local pos = part.Position
		local groundY = groundYAt(pos.X, pos.Z)
		alignPos.Enabled = groundY ~= nil
		local standY = groundY and (legsGroundY(groundY) + STAND_HEIGHT) or pos.Y
		mover.CFrame = CFrame.new(mover.Position.X, standY, mover.Position.Z) * CFrame.Angles(0, heading, 0)
	end

	local function clampToWorldBounds(pos)
		local fromOrigin = Vector3.new(pos.X, 0, pos.Z)
		if fromOrigin.Magnitude <= WORLD_BOUND_RADIUS then
			return pos
		end
		local clamped = fromOrigin.Unit * WORLD_BOUND_RADIUS
		return Vector3.new(clamped.X, pos.Y, clamped.Z)
	end

	local function randomWanderTarget()
		local angle = math.random() * 2 * math.pi
		local dist = math.random() * WANDER_RADIUS
		return clampToWorldBounds(Vector3.new(wakePos.X + math.cos(angle) * dist, bodyY, wakePos.Z + math.sin(angle) * dist))
	end

	-- Smaller plain orbs in range that the board says are free to take,
	-- picked at random rather than nearest so it doesn't read as too
	-- mechanically optimal. Never a radiant one. And never at all when the
	-- board is down to its last orb: that's the orb there is to sell.
	local function findPrey()
		if not ctx.running() or ctx.plainOrbCount() <= 1 then
			return nil
		end
		local myPos = part.Position
		local candidates = {}
		for _, other in ipairs(folder:GetChildren()) do
			if other ~= part and other:IsA("BasePart") and not other:GetAttribute("IsRadiant") then
				local id, size = ctx.absorbable(other)
				if id and size < bodySize then
					local distFromOrigin = Vector3.new(other.Position.X, 0, other.Position.Z).Magnitude
					if (other.Position - myPos).Magnitude <= HUNT_RADIUS and distFromOrigin <= WORLD_BOUND_RADIUS then
						table.insert(candidates, other)
					end
				end
			end
		end
		if #candidates == 0 then
			return nil
		end
		return candidates[math.random(1, #candidates)]
	end

	-- Walks toward `target` (a point, or a function returning one each
	-- frame, nil meaning "give up") with eased velocity, organic heading
	-- and pace noise that fade out on approach, and a braking curve sized
	-- off current speed. MimicFuse's moveTo, line for line; see there for
	-- the long history behind each piece.
	local elapsedWalkTime = 0
	local function moveTo(target, speed, noiseScale, arriveDist, requireStop, interrupt)
		noiseScale = noiseScale or 1
		arriveDist = arriveDist or 0.5
		if requireStop == nil then
			requireStop = true
		end
		local isLive = type(target) == "function"
		while true do
			if not stillMimic() then
				return false
			end
			local dt = RunService.Heartbeat:Wait()
			if not stillMimic() then
				return false
			end
			if interrupt and interrupt(dt) then
				return false
			end
			elapsedWalkTime += dt

			local targetPos = target
			if isLive then
				targetPos = target()
				if not targetPos then
					return false
				end
			end

			local pos = part.Position
			local toTarget = Vector3.new(targetPos.X - pos.X, 0, targetPos.Z - pos.Z)
			local dist = toTarget.Magnitude
			if dist < arriveDist and (not requireStop or velocity.Magnitude < 0.5) then
				return true
			end

			local brakeTarget = requireStop and arriveDist or (arriveDist - ARRIVE_BRAKE_INSET)
			local distToRing = math.max(dist - brakeTarget, 0)
			local stopSpeedCap = math.sqrt(2 * MOVE_ACCEL * distToRing / ARRIVE_STOP_MARGIN)
			local arriveScale = math.min(stopSpeedCap / speed, 1)

			local headingNoise = math.noise(elapsedWalkTime * WANDER_NOISE_FREQ, noiseSeed) * WANDER_NOISE_STRENGTH * arriveScale * noiseScale
			local speedNoise = 1 + SPEED_VARIATION * noiseScale * arriveScale * math.noise(elapsedWalkTime * SPEED_NOISE_FREQ, noiseSeed + 100)

			local dir = dist > 0.01 and (CFrame.Angles(0, headingNoise, 0) * toTarget.Unit) or Vector3.new(0, 0, 0)
			local desiredVel = dist > 0.01 and (dir * speed * arriveScale * speedNoise) or Vector3.new(0, 0, 0)
			stepVelocity(desiredVel, dt)
			updateBalance()
		end
	end

	-- ── the hunt ──────────────────────────────────────────────────────
	-- Chases the orb down, stops over it, and hands it to the board to
	-- float up into the body. Bails cleanly at any point the orb stops
	-- being fair game — sold, taken by a splitter, knocked off — or the
	-- mimic itself is defused or the board stops running.
	local function eat(target)
		-- For the length of the hunt the prey is in MimicPrey, so the body
		-- can walk right over it instead of stopping against it, and both
		-- ground raycasts ignore it so the body doesn't climb up onto it.
		prey, preyGroup = target, target.CollisionGroup
		target.CollisionGroup = CG.MimicPrey
		huntedPreyValue.Value = target
		groundRayParams.FilterDescendantsInstances = { part, target }

		local function livePreyPos()
			if target.Parent ~= folder or not ctx.absorbable(target) then
				return nil
			end
			return target.Position
		end

		if not moveTo(livePreyPos, CHASE_SPEED, 0.4, EAT_OVERLAP_DIST, false) then
			return releasePrey()
		end
		if not stillMimic() or not livePreyPos() then
			return releasePrey()
		end
		local delta = target.Position - part.Position
		if Vector3.new(delta.X, 0, delta.Z).Magnitude > EAT_OVERLAP_DIST + 1 then
			return releasePrey()
		end

		-- A quick eased stop rather than a freeze, so it doesn't slide off
		-- the orb while it eats.
		do
			local stopT = 0
			while stopT < EAT_STOP_TIME and velocity.Magnitude > 0.05 do
				if not stillMimic() then
					return releasePrey()
				end
				local dt = RunService.Heartbeat:Wait()
				stopT += dt
				stepVelocity(Vector3.new(0, 0, 0), dt, EAT_STOP_ACCEL)
				updateBalance()
			end
		end
		velocity = Vector3.new(0, 0, 0)
		walkVelocity.VectorVelocity = Vector3.new(0, 0, 0)

		-- Last chance to back out, and the last check before anything
		-- is committed: an AFK pause that landed during the stop, or the
		-- orb taken in the same moment.
		if not ctx.running() or not ctx.absorbable(target) then
			return releasePrey()
		end

		local restCF = mover.CFrame

		-- Committed. The board claims it and steers it up into the body
		-- under a magenta fade, then flashes it out with the sell cue. The
		-- orb stays a live physics body throughout (`physical`): it keeps
		-- whatever it was doing and is pulled in harder and harder, on the
		-- EAT_EASING curve, rather than frozen and carried. It stays in
		-- MimicPrey, so it passes into the body rather than bouncing off.
		-- And it does that whatever happens to the mimic in the
		-- meantime, because the server is being told right now and pays
		-- for it. The follow function reads the body live, and the board
		-- keeps the last position if the body goes.
		local preyId = ctx.absorb(target, function()
			return part.Parent and part.Position or nil
		end, cfg.EAT_TIME, "MimicPending", {
			shrink = false,
			physical = true,
			fadeColor = cfg.EAT_COLOR,
			easingStyle = cfg.EAT_EASING_STYLE,
			easingDirection = cfg.EAT_EASING_DIRECTION,
			flashColor = cfg.EAT_COLOR,
			-- the prey ends up inside the body: draw the flash on the
			-- body's near side so the body doesn't hide it
			flashInFront = bodySize / 2 + 0.5,
			sound = ctx.config.SOUNDS.sell,
		})
		if not preyId then
			return releasePrey()
		end
		ctx.report(ctx.ops.MIMIC_ATE, ctx.id, preyId)

		-- It's the board's now; there's nothing to restore on it.
		prey, preyGroup = nil, nil

		-- Stands over it while it goes.
		local t = 0
		while t < cfg.EAT_TIME do
			if not stillMimic() then
				return releasePrey()
			end
			t += RunService.Heartbeat:Wait()
			updateBalance()
		end

		mover.CFrame = restCF
		releasePrey()
	end

	-- ── main loop ─────────────────────────────────────────────────────
	while stillMimic() do
		-- An idle pause between wander legs, sometimes spent turning to
		-- look somewhere else.
		local idleFor = IDLE_MIN + math.random() * (IDLE_MAX - IDLE_MIN)
		local idleT = 0
		local lookHeading = (math.random() < LOOK_AROUND_CHANCE)
			and (heading + (math.random() * 2 - 1) * LOOK_AROUND_MAX_TURN) or nil
		while idleT < idleFor do
			if not stillMimic() then
				return
			end
			local dt = RunService.Heartbeat:Wait()
			idleT += dt
			stepVelocity(Vector3.new(0, 0, 0), dt)
			if lookHeading then
				local diff = (lookHeading - heading + math.pi) % (2 * math.pi) - math.pi
				heading += math.clamp(diff, -TURN_SPEED * dt, TURN_SPEED * dt)
				mover.CFrame = CFrame.new(mover.Position) * CFrame.Angles(0, heading, 0)
			end
			updateBalance()
		end

		local found = (math.random() < HUNT_CHANCE) and findPrey() or nil
		if found then
			eat(found)
		else
			-- Keeps rolling for prey every HUNT_RECHECK_INTERVAL while it
			-- ambles, so an orb that lands in range mid-walk gets noticed.
			local recheckT = 0
			local foundMidWander = nil
			moveTo(randomWanderTarget(), WALK_SPEED, nil, ARRIVE_DIST, nil, function(dt)
				recheckT += dt
				if recheckT < HUNT_RECHECK_INTERVAL then
					return false
				end
				recheckT = 0
				if math.random() < HUNT_CHANCE then
					foundMidWander = findPrey()
				end
				return foundMidWander ~= nil
			end)
			if foundMidWander and stillMimic() then
				eat(foundMidWander)
			end
		end
	end
end

function Mimic.start(ctx)
	if not sleep(ctx) then
		return
	end
	live(ctx)
end

return Mimic