--[[
    PetMimicFuse (Script)
    Path: ReplicatedStorage
    Parent: ReplicatedStorage
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-25 02:23:33
]]
--[[
    PetMimicFuse (Script)
    Path: ReplicatedStorage
    Parent: ReplicatedStorage
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-23 02:07:54
]]
--[[
    PetMimicFuse (Script)
    Path: ReplicatedStorage
    Parent: ReplicatedStorage
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 18:28:56
]]
--[[
	PetMimicFuse (Script) — place directly in ReplicatedStorage
	(ReplicatedStorage.PetMimicFuse, a SIBLING of the Mimic template, NOT a
	child of it). BallManager's spawnPetMimic clones this and parents it
	onto each pet mimic instance itself, the same moment it clones the
	Mimic template — it is NOT part of that template, unlike MimicFuse/
	MimicLegsClient, because it should only ever run on a mimic a player
	actually bought (IsPetMimic attribute), never on an ordinary board
	mimic. MimicFuse (which DOES still get cloned in automatically, since
	it lives inside the Mimic template) checks for that same attribute at
	its very top and bails out immediately when it's set — see the
	comment there.

	This is the pet-mimic sibling of MimicFuse: same physics-driven
	movement engine (unanchored body, LinearVelocity walk servo,
	AlignPosition height servo, AlignOrientation facing servo, balance
	recovery — see MimicFuse's own header for the full "why" on all of
	that, unchanged here) wired up to a completely different brain:

	  - wakes after PET_WAKE_DELAY (2s), not MimicFuse's 5s
	  - numDisplay is never touched here — BallManager's spawnPetMimic
	    already set it to the owner's custom pet name at spawn, and it
	    never needs to "swap" the way a board mimic's does, since it was
	    never showing a size to begin with. A later rename doesn't touch
	    it from here either — PetMimicHandler's UpdatePetMimicConfig
	    handler pushes a renamed live mimic's numDisplay directly,
	    the same way it already did for Color, so this script still
	    never needs to read/write it itself
	  - no MIMIC_WAKE_BADGE_ID award on wake — the shop gate for buying a
	    pet mimic in the first place (UpgradeData's petMimic entry) is
	    that same badge, so by definition anyone with a pet mimic already
	    has it
	  - instead of ambling the whole platform and randomly rolling
	    whether to hunt, it tries to stay within FOLLOW_DIST studs of its
	    owner, and walks toward the nearest ball in its configured size
	    range the instant one shows up within HUNT_RADIUS (widened well
	    past a board mimic's own hunt range, since this pet is meant to
	    be parking itself in the middle of a cluster, not committing to
	    a single target clear across the platform) — see
	    getOwnerRoot/getTargetRange, which read the owner's live
	    PetMimicConfig Values every check, so a config change from
	    PetConfigClient applies immediately to an already-awake pet, no
	    respawn needed
	  - absorbing is its own always-running loop, entirely separate from
	    the walking-toward-a-target above: every qualifying ball that
	    comes within the much tighter ABSORB_RANGE of wherever the pet
	    currently is gets pulled in the instant it's noticed, gated only
	    by ABSORB_COOLDOWN between one pull starting and the next — not
	    by how far away the thing it happens to be walking toward is, or
	    by waiting out the previous catch's own pull-in animation (that
	    now runs on its own coroutine per ball, see pullIn, so several
	    can be mid-suck-in around the pet at once). This is what turns
	    "chase one ball, absorb it, chase the next" into "walk into a
	    cluster and everything in reach keeps disappearing at a steady
	    clip" — the walk-toward-nearest-target logic just has to get the
	    pet somewhere in range of a cluster in the first place; the
	    absorb loop is what actually empties it out once it's there
	  - absorbing prey pays full price with the CYAN auto-sell flash
	    (SellService.petMimicAbsorb), not half price with the magenta
	    mimic flash, and the prey visibly shrinks to size 1 (expo-out
	    ease) WHILE it's pulled in towards the mimic's body, instead of
	    floating in at its full original size the way a board mimic's
	    catch does
	  - dying (bomb blast, or wandering past MIMIC_MAX_RADIUS) never
	    reverts this into a plain sellable ball — it just flips
	    MimicActive off and lets BallManager's own onHB/
	    schedulePetMimicRespawn (isPetMimic-gated) notice it falling past
	    FALL_BADGE_Y and respawn a fresh one for the same owner. Falling
	    off dormant (never having woken) is ALSO funneled through that
	    same BallManager path directly, not handled here at all — see
	    isPetMimic() there.

	OwnerId (set by spawnPetMimic, before this script starts) is this
	pet's only link back to who owns it — everything else (config,
	following target) is looked up fresh through it every time, rather
	than cached, so a config edit or the owner's character respawning
	mid-life is picked up on the very next check instead of needing this
	script to restart.
]]

local RS = game:GetService("RunService")
local WS = game:GetService("Workspace")
local Players = game:GetService("Players")
local Rep = game:GetService("ReplicatedStorage")

local mimic = script.Parent
local folder = mimic.Parent -- already parented into Workspace.Balls by BallManager's spawnPetMimic

local ballT = Rep:WaitForChild("Ball") -- name check below is what this hunts for, same as MimicFuse
local ownerId = mimic:GetAttribute("OwnerId")

-- the actual payout/broadcast/highlight-then-destroy beat for an
-- absorb is SellService.petMimicAbsorb (the cyan/full-price sibling of
-- SellService.mimicAbsorb, added alongside this script), but pullIn
-- below calls it through _G.PetMimicAbsorb rather than requiring
-- SellService and task.spawn'ing it directly from here — see that
-- relay's own comment in PetMimicHandler for why task.spawn'ing it on
-- this script used to leave a stuck, unsellable ball behind whenever
-- the mimic was despawned mid-absorb

-- CG.MimicPrey is the same group MimicFuse puts a board mimic's prey in
-- — shared by name from the one declaration, not re-declared separately,
-- so a pet mimic and a board mimic mid-hunt at the same time can't end
-- up with two different groups doing the same job.
--
-- CG.PetMimicBody is this script's own group, NOT shared with MimicFuse
-- — a pet mimic's body is assigned to it below (see the "wake up"
-- section) rather than to MimicBody, so pet mimics only ever physically
-- collide with each other. They don't shove board mimics around (or get
-- shoved by one) mid-hunt on the same platform, and they don't collide
-- with regular balls, players, terrain, or anything else in the game
-- either. That's fine because a pet mimic's standing height already
-- comes entirely from AlignPosition's raycast-driven servo (groundYAt/
-- measureFloorY above), never from physically resting on anything, so
-- there's nothing lost by not colliding with the world.
--
-- That "collides with nothing but its own kind" rule is one line in
-- ReplicatedStorage.CollisionGroups now (passesThroughEverything on the
-- PetMimicBody entry), which replaces the loop this script used to run
-- over PhysicsService:GetRegisteredCollisionGroups() at wake. That loop
-- could only ever exclude groups that happened to already be registered
-- by the time THIS PARTICULAR pet woke up; the module resolves the rule
-- against the full declaration up front, so every pet gets the same
-- complete set regardless of spawn timing.
--
-- NOT assigned to the mimic here — see the "wake up" section further
-- down for why this has to wait until AlignPosition's standing servo is
-- actually about to take over.
local CG = require(Rep:WaitForChild("CollisionGroups"))

-- ── config: sound (same cues/ids MimicFuse uses, see its own header) ──
local se = Rep:WaitForChild("SoundEvents")
local WAKE_ALARM_SOUND = "rbxassetid://12221831"
local WAKE_ALARM_VOLUME = 0.3
local REVERT_SOUND = "rbxassetid://12222152"

-- ── config: wake-up ─────────────────────────────────────────────────
local PET_WAKE_DELAY = 2         -- seconds spent dormant before waking — MUCH shorter than a board mimic's 5s (MimicFuse's WAKE_DELAY), since this is expected to happen every respawn, not just once in a while
local WAKE_MIN_Y = -5            -- mirrors BallManager's own FALL_Y/MimicFuse's own copy — see stillAsleep below
-- Read from BoardConfig now: MimicLegsClient paces the sprout from there,
-- and a pet that rose on its own 1.0s would stand up before its last leg
-- was out.
local LEGS_SPROUT_TIME = require(Rep:WaitForChild("BoardConfig")).MIMIC.LEGS_SPROUT_TIME
local BODY_RISE_TIME = 0.6
local LEG_LIFT_FRAC = 1.3        -- MUST match MimicLegsClient's own LEG_LIFT_FRAC

-- ── config: pet size (always PET_MIMIC_SIZE=2 from BallManager, so
-- unlike MimicFuse these are flat numbers, not *_PER_SIZE — nothing here
-- ever needs to scale with a variable body size the way a board mimic's
-- config does) ─────────────────────────────────────────────────────
local WALK_SPEED = 16
local CHASE_SPEED = 32
local TURN_SPEED = 16
local FOLLOW_DIST = 7             -- studs — tries to stay within this of its owner
local WORLD_BOUND_RADIUS = 50     -- same hard cap MimicFuse uses for its own wander/hunt targets
local WORLD_BOUND_SAFE_MARGIN = 2 -- studs of buffer kept between the pet's own body and WORLD_BOUND_RADIUS
local WORLD_BOUND_SAFE_RADIUS = WORLD_BOUND_RADIUS - WORLD_BOUND_SAFE_MARGIN -- both clampToWorldBounds (the pet's own movement) and scanForPrey (what it's willing to chase/absorb) key off this, not WORLD_BOUND_RADIUS directly, so the body never walks into the last 2 studs and prey sitting out there is left alone as "inedible" rather than getting chased right up to the edge
local MIMIC_MAX_RADIUS = 55       -- same "genuinely off the platform" threshold MimicFuse uses — past this, it dies and respawns instead of continuing to follow
local HUNT_RADIUS = 45            -- decides how far away a ball can be before the pet starts walking toward it at all, not how close it needs to get before absorbing it (see ABSORB_RANGE below), so it's fine for this to reach well outside FOLLOW_DIST
local ABSORB_RANGE = 15           -- studs — an area effect around the pet's CURRENT position, not a point-blank overlap the old single-target chase required; anything qualifying that's this close gets pulled in on its own, gated only by ABSORB_COOLDOWN, regardless of what the pet happens to be walking toward. This is the radius that actually determines how fast a cluster empties out (HUNT_RADIUS above only decides how far away the pet is willing to go looking for one in the first place), so this is the one to widen further if absorbing still feels slow
local ABSORB_COOLDOWN = 0.25      -- minimum gap between one pull starting and the next (see the absorb loop below) — this, not travel time or the per-ball pull-in animation, is what paces how fast a cluster empties out
local HUNT_RECHECK_INTERVAL = 0.5 -- checked more often than MimicFuse's 1s — a pet mimic should react quickly to something entering range near its owner
local IDLE_PAUSE = 0.4            -- brief pause once it's arrived within FOLLOW_DIST (or has no owner to follow) before checking again, so it doesn't spin every single frame doing nothing

-- ── config: physics-driven movement (identical shape to MimicFuse's own
-- "config: physics-driven movement"/"config: balance recovery" sections
-- — see there for the full reasoning on why walking is a velocity servo,
-- standing height is a position servo, and facing is a torque-capped
-- orientation servo instead of everything just being CFrame'd directly) ──
local WALK_MAX_FORCE = 9000
local STAND_MAX_FORCE = 40000
local STAND_RESPONSIVENESS = 25
local ORIENT_MAX_TORQUE = 25000
local ORIENT_RESPONSIVENESS = 15
local ORIENT_RECOVERY_RESPONSIVENESS = 40
local STAND_FORCE_SAFETY = 3
local MOVE_ACCEL = 12        -- ordinary follow-the-owner walking — kept low on purpose so idle wandering/following still reads as smooth, physical motion instead of snapping onto a new heading
local CHASE_MOVE_ACCEL = 50  -- chase-only override (see moveTo's `accel` param) — much higher so a sharp reversal while hunting doesn't take multiple seconds to complete; tune this one, not MOVE_ACCEL, if chase turning still feels off
local WALK_FORCE_SAFETY = 2.5
local RECOVERY_TILT_THRESHOLD = math.rad(12)
local RECOVERY_VELOCITY_THRESHOLD = 10
local WANDER_NOISE_STRENGTH = 0.5
local WANDER_NOISE_FREQ = 0.35
local SPEED_VARIATION = 0.25
local SPEED_NOISE_FREQ = 0.6

-- ── wake-up wait (identical shape to MimicFuse's stillAsleep — see its
-- own comment) ──────────────────────────────────────────────────────
local hasReachedPlatform = false
local function stillAsleep()
	if mimic.Parent == nil or mimic:GetAttribute("Sold") then return false end
	local pos = mimic.Position
	if pos.Y >= WAKE_MIN_Y then
		hasReachedPlatform = true
	elseif hasReachedPlatform then
		return false
	end
	if Vector3.new(pos.X, 0, pos.Z).Magnitude > MIMIC_MAX_RADIUS then return false end
	return true
end

do
	local t = 0
	while t < PET_WAKE_DELAY do
		if not stillAsleep() then return end
		t += RS.Heartbeat:Wait()
	end
end
if not stillAsleep() then return end

-- ── wake up ─────────────────────────────────────────────────────────
local bodySize = mimic:GetAttribute("TargetSize") or mimic.Size.X

local groundRayParams = RaycastParams.new()
groundRayParams.FilterType = Enum.RaycastFilterType.Exclude
groundRayParams.FilterDescendantsInstances = { mimic }

-- balls currently mid pull-in (see pullIn, further down) get excluded
-- from the ground raycast the same way the old single-target chase
-- excluded its one committed prey — otherwise a ball floating up into
-- the mimic's body mid-absorb could get hit as "the ground" out from
-- under the pet. Several can be excluded at once now, since several can
-- be mid-pull-in at once.
local activePulls = {}
local function refreshGroundRayFilter()
	local filter = { mimic }
	for prey in pairs(activePulls) do
		filter[#filter + 1] = prey
	end
	groundRayParams.FilterDescendantsInstances = filter
end

-- the TRUE floor under the mimic right now, found by raycasting rather
-- than trusting mimic.Position.Y - bodySize/2 blindly — see MimicFuse's
-- identical fix/comment for the full "why" (a pet mimic's much shorter
-- PET_WAKE_DELAY, 2s vs. a board mimic's 5s, makes it even more likely
-- to still have residual settle-bounce the instant this fires,
-- especially right after a fresh spawn/respawn). Origin anchors off
-- mimic.Position.Y itself (not floorY — that's what this is computing),
-- since it only needs to start comfortably above wherever the mimic
-- currently happens to be. Returns nil (not a fallback) on a miss, so
-- the retry loop below can tell "genuinely nothing under it yet" apart
-- from "found the floor at some Y".
local function measureFloorY()
	local origin = Vector3.new(mimic.Position.X, mimic.Position.Y + bodySize * 3, mimic.Position.Z)
	local result = WS:Raycast(origin, Vector3.new(0, -(bodySize * (6 + LEG_LIFT_FRAC)), 0), groundRayParams)
	return result and result.Position.Y
end

-- UNLIKE MimicFuse, this can't just take a single one-time measurement
-- here and trust it — a board mimic never wakes until well after
-- BallManager has finished building the platform (it's only ever
-- spawned into an already-running board), but a pet mimic can wake
-- because its owner was already sitting in the game the instant the
-- server started (PetMimicHandler's onPlayerAdded loop, run for
-- everyone already present, fires before this script's own
-- PET_WAKE_DELAY wait even begins). That races BallManager's own
-- startup: if the platform genuinely doesn't exist under this mimic
-- yet, measureFloorY's raycast comes back with nothing to hit, and the
-- old single-shot fallback (mimic.Position.Y - bodySize/2) silently
-- accepted whatever height the mimic happened to be sitting/settling
-- at as "the floor" — which, mid-launch or mid-settle with nothing
-- solid below it yet, reads as the body waking up already flush with
-- the ground and never visibly pushing itself up onto its legs. So
-- this retries across Heartbeats instead of accepting a miss
-- immediately, giving BallManager's platform time to actually finish
-- building before this commits to a floor height. FLOOR_MEASURE_TIMEOUT
-- is generous for the same reason LOOKUP_TIMEOUT is generous elsewhere
-- in this project — long enough that a slow server start never trips
-- it, short enough that a genuinely missing platform still surfaces a
-- (now visibly wrong, but at least not silently-wrong-forever) mimic
-- within a few seconds rather than hanging the wake sequence.
local FLOOR_MEASURE_TIMEOUT = 5
local floorY
do
	local t = 0
	while not floorY do
		if not stillAsleep() then return end
		floorY = measureFloorY()
		if not floorY then
			if t >= FLOOR_MEASURE_TIMEOUT then
				floorY = mimic.Position.Y - bodySize / 2 -- last resort: platform still hasn't shown up under the raycast after a generous wait, so fall back rather than hang forever
				break
			end
			t += RS.Heartbeat:Wait()
		end
	end
end
local STAND_HEIGHT = bodySize / 2 + bodySize * LEG_LIFT_FRAC
local bodyY = floorY + STAND_HEIGHT
local wakePos = mimic.Position

local function groundYAt(worldX, worldZ)
	local origin = Vector3.new(worldX, floorY + bodySize * 3, worldZ)
	local result = WS:Raycast(origin, Vector3.new(0, -(bodySize * (6 + LEG_LIFT_FRAC)), 0), groundRayParams)
	return result and result.Position.Y or floorY
end

mimic:SetAttribute("MimicActive", true) -- watched by BombFuse's revertMimic branch, MimicLegsClient, and this script's own teardown watcher below

mimic.CanCollide = true -- BallManager's onHB already flipped this true once during ascend; restated here as a safety net, same as MimicFuse's own wake sequence does

-- Isolated into its own collision group HERE, not any earlier — Balls
-- and the platform/terrain itself are BOTH just sitting in the plain
-- "Default" group (BallManager never gives either one anything custom),
-- so there's no group-level way to tell "a regular ball" apart from
-- "the floor" during the dormant ascend/settle/wake-delay stretch above.
-- The mimic genuinely needs real Default-group collision through all of
-- that just to physically land and settle on the platform in the first
-- place, exactly like any other ball — switching it into
-- CG.PetMimicBody any earlier than this (tried once, it fell
-- straight through the platform on spawn) pulls that support out from
-- under it before anything else is holding it up. It's safe to switch
-- right here specifically because AlignPosition's raycast-driven
-- standing servo (built just below) is about to take over that job
-- immediately — from this point on the mimic no longer needs to
-- physically rest on anything, so losing Default-group collision costs
-- nothing, and this happens well before the pet ever starts walking
-- into balls it needs to not collide with.
mimic.CollisionGroup = CG.PetMimicBody

-- Pins physics simulation for this mimic to the SERVER for the rest of
-- its life. Left alone, an unanchored part like this gets automatic
-- network ownership from the engine — almost always handed to whichever
-- player is nearest, which given FOLLOW_DIST is basically always its own
-- owner. That means the actual AlignPosition/LinearVelocity simulation
-- would be running on THEIR client, not here — so every mimic.Position
-- read on this server script (this one included) is only ever as fresh
-- as whatever that client last replicated back, and Roblox stops sending
-- those updates once the client-side simulation looks idle/near-zero
-- velocity ("physics sleep"). That's the actual cause of absorbed balls
-- freezing at wherever the mimic was the instant the pull started: it's
-- not a stale snapshot in pullIn, it's mimic.Position itself going stale
-- upstream of it — which is also why pullIn's own "read mimic.Position
-- live every frame" fix (below) couldn't have worked; a live read of a
-- frozen value is still frozen. SetNetworkOwner(nil) forces the server
-- itself to be the one simulating, so every read of mimic.Position from
-- here on is the true current position, no replication lag or sleep
-- state involved.
mimic:SetNetworkOwner(nil)

local mimicAttachment = Instance.new("Attachment")
mimicAttachment.Name = "MimicRoot"
mimicAttachment.Parent = mimic

local huntedPreyValue = Instance.new("ObjectValue")
huntedPreyValue.Name = "HuntedPrey"
huntedPreyValue.Parent = mimic

local mover = Instance.new("Part")
mover.Name = "MimicMover"
mover.Size = Vector3.new(0.2, 0.2, 0.2)
mover.Transparency = 1
mover.CanCollide, mover.CanQuery, mover.CastShadow = false, false, false
mover.Anchored = true
mover.CFrame = mimic.CFrame
mover.Parent = mimic

local moverAttachment = Instance.new("Attachment")
moverAttachment.Name = "MimicMoverTarget"
moverAttachment.Parent = mover

-- sized off CHASE_MOVE_ACCEL (the larger of the two), not MOVE_ACCEL — the
-- servo's force ceiling has to cover whichever accel is actually asking the
-- most of it, and that's chase, not ordinary walking. Sizing off the lower
-- walking value here would leave chase right back where it started: a fast
-- scripted target with a force ceiling too soft to actually keep up with it.
local walkMaxForce = math.max(WALK_MAX_FORCE, mimic.AssemblyMass * CHASE_MOVE_ACCEL * WALK_FORCE_SAFETY)

local walkVelocity = Instance.new("LinearVelocity")
walkVelocity.Name = "MimicWalkVelocity"
walkVelocity.Attachment0 = mimicAttachment
walkVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
walkVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
walkVelocity.ForceLimitsEnabled = true
walkVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
walkVelocity.MaxAxesForce = Vector3.new(walkMaxForce, 0, walkMaxForce)
walkVelocity.VectorVelocity = Vector3.new(0, 0, 0)
walkVelocity.Parent = mimic

local standForce = math.max(STAND_MAX_FORCE, mimic.AssemblyMass * WS.Gravity * STAND_FORCE_SAFETY)

local alignPos = Instance.new("AlignPosition")
alignPos.Name = "MimicAlignPosition"
alignPos.Attachment0 = mimicAttachment
alignPos.Attachment1 = moverAttachment
alignPos.RigidityEnabled = false
alignPos.ForceLimitMode = Enum.ForceLimitMode.PerAxis
alignPos.MaxAxesForce = Vector3.new(0, standForce, 0)
alignPos.ForceRelativeTo = Enum.ActuatorRelativeTo.World
alignPos.Responsiveness = STAND_RESPONSIVENESS
alignPos.Parent = mimic

local alignOrient = Instance.new("AlignOrientation")
alignOrient.Name = "MimicAlignOrientation"
alignOrient.Attachment0 = mimicAttachment
alignOrient.Attachment1 = moverAttachment
alignOrient.RigidityEnabled = false
alignOrient.MaxTorque = ORIENT_MAX_TORQUE
alignOrient.Responsiveness = ORIENT_RESPONSIVENESS
alignOrient.Parent = mimic

-- same shape as MimicFuse's own teardown watcher — the ONLY thing that
-- ever flips MimicActive false for a pet mimic is BombFuse's revertMimic
-- branch or this script's own past-radius watcher below, and either way
-- this is what releases the mover/Align constraints they don't know
-- about, and fires the single "reverted" sound cue regardless of which
-- path triggered it.
task.spawn(function()
	while mimic:GetAttribute("MimicActive") do
		RS.Heartbeat:Wait()
	end
	se:FireAllClients("attached", mimic, REVERT_SOUND)
	alignPos.Enabled, alignOrient.Enabled, walkVelocity.Enabled = false, false, false
	mover:Destroy()
end)

-- past-platform-edge watcher — same trigger MimicFuse's own has, but the
-- pet-mimic ending: just flip MimicActive off and let BallManager's
-- schedulePetMimicRespawn (still tracking this instance the whole time —
-- see isPetMimic there) notice it falling past FALL_BADGE_Y and bring a
-- fresh one back. No renaming, no display restore — there's nothing to
-- restore it TO; it's not becoming a ball.
task.spawn(function()
	while mimic:GetAttribute("MimicActive") do
		local pos = mimic.Position
		if Vector3.new(pos.X, 0, pos.Z).Magnitude > MIMIC_MAX_RADIUS then
			mimic:SetAttribute("MimicActive", false)
			return
		end
		RS.Heartbeat:Wait()
	end
end)

-- ── legs sprout / push-up (identical shape to MimicFuse's own — see
-- there for why the body holds still through LEGS_SPROUT_TIME before
-- rising over BODY_RISE_TIME) ────────────────────────────────────────
do
	local t = 0
	while t < LEGS_SPROUT_TIME do
		if not mimic:GetAttribute("MimicActive") then return end
		t += RS.Heartbeat:Wait()
	end
end

se:FireAllClients("flatPitched", WAKE_ALARM_SOUND, WAKE_ALARM_VOLUME)
do
	local restY = mimic.Position.Y
	local t = 0
	while t < BODY_RISE_TIME do
		if not mimic:GetAttribute("MimicActive") then return end
		local dt = RS.Heartbeat:Wait()
		t = math.min(t + dt, BODY_RISE_TIME)
		local alpha = 1 - (1 - t / BODY_RISE_TIME) ^ 2
		mover.CFrame = CFrame.new(wakePos.X, restY + (bodyY - restY) * alpha, wakePos.Z)
	end
end

-- ── movement (identical engine to MimicFuse's own — see its "config:
-- physics-driven movement" section and the movement functions
-- themselves for the full reasoning; unchanged here) ──────────────────
local heading = 0
local velocity = Vector3.new(0, 0, 0)
local noiseSeed = math.random() * 1000
local ARRIVE_STOP_MARGIN = 1.2
local ARRIVE_BRAKE_INSET = 1.5
local BOUND_BRAKE_DECEL = 80  -- studs/s^2 the world-border brake sheds OUTWARD speed at — deliberately much harder than CHASE_MOVE_ACCEL (50) so it can still shed a full CHASE_SPEED (32) outward run in ~6.4 studs, comfortably inside the WORLD_BOUND_SAFE_RADIUS buffer, while still reading as a visible brake over several frames rather than an instant velocity clip

local function isKnocked()
	local tiltDot = math.clamp(mimic.CFrame.UpVector:Dot(Vector3.new(0, 1, 0)), -1, 1)
	local tiltAngle = math.acos(tiltDot)
	local actualVel = mimic.AssemblyLinearVelocity
	local velMismatch = (Vector3.new(actualVel.X, 0, actualVel.Z) - velocity).Magnitude
	return tiltAngle > RECOVERY_TILT_THRESHOLD or velMismatch > RECOVERY_VELOCITY_THRESHOLD
end

local function updateBalance(dt)
	local knocked = isKnocked()
	alignOrient.Responsiveness = knocked and ORIENT_RECOVERY_RESPONSIVENESS or ORIENT_RESPONSIVENESS
end

local function stepVelocity(desiredVel, dt, accel)
	local delta = desiredVel - velocity
	local maxDelta = (accel or MOVE_ACCEL) * dt
	if delta.Magnitude > maxDelta then
		delta = delta.Unit * maxDelta
	end
	velocity += delta

	-- world-border brake — takes priority over whatever moveTo call is
	-- actually driving this tick (chase, follow-owner, idle wander noise,
	-- balance-recovery correction — all of it funnels through this one
	-- function before ever reaching the physics servo). clampToWorldBounds/
	-- scanForPrey's own WORLD_BOUND_SAFE_RADIUS filtering above keeps the
	-- pet from ever being TOLD to go past the border in the first place,
	-- but that's a soft target-selection guard, not a hard one — momentum
	-- from a fast CHASE_MOVE_ACCEL turn, wander noise, or getting bumped by
	-- another pet mid-cluster could still coast the body across the line
	-- while this ring is still accel-limiting its way toward a smaller
	-- commanded velocity. So this caps the OUTWARD-pointing component of
	-- `velocity` itself against a stopping-distance curve (same shape as
	-- moveTo's own arrival-braking math below), keyed off BOUND_BRAKE_DECEL
	-- and however much runway is left before WORLD_BOUND_SAFE_RADIUS — the
	-- cap shrinks smoothly as the body closes in, so outward speed visibly
	-- bleeds off and the pet corrects itself over several frames instead of
	-- coasting at full speed and snapping to zero in one tick right at the
	-- ring. BOUND_BRAKE_DECEL is picked hard enough that even a full
	-- CHASE_SPEED outward run is fully shed well inside the ring, so this
	-- still guarantees the body never actually reaches WORLD_BOUND_RADIUS —
	-- it just no longer looks like hitting a wall on the way there. Inward
	-- and tangential motion are untouched, so the pet slides along the
	-- border instead of freezing dead against it.
	do
		local pos = mimic.Position
		local fromOrigin = Vector3.new(pos.X, 0, pos.Z)
		local distFromOrigin = fromOrigin.Magnitude
		if distFromOrigin > 0 then
			local outward = fromOrigin.Unit
			local outwardSpeed = velocity.X * outward.X + velocity.Z * outward.Z
			if outwardSpeed > 0 then
				local remaining = math.max(WORLD_BOUND_SAFE_RADIUS - distFromOrigin, 0)
				local maxOutwardSpeed = math.sqrt(2 * BOUND_BRAKE_DECEL * remaining)
				if outwardSpeed > maxOutwardSpeed then
					velocity -= outward * (outwardSpeed - maxOutwardSpeed)
				end
			end
		end
	end

	if velocity.Magnitude > 0.05 then
		-- negated: atan2(velocity.X, velocity.Z) points CFrame.Angles(0, heading, 0)'s
		-- LookVector 180° opposite the travel direction, which is what read as the
		-- mimic (body AND legs, since MimicLegsClient derives its CFrame from this
		-- every frame) walking backwards
		local desiredHeading = math.atan2(-velocity.X, -velocity.Z)
		local diff = (desiredHeading - heading + math.pi) % (2 * math.pi) - math.pi
		heading += math.clamp(diff, -TURN_SPEED * dt, TURN_SPEED * dt)
	end

	walkVelocity.VectorVelocity = Vector3.new(velocity.X, 0, velocity.Z)

	local pos = mimic.Position
	local standY = groundYAt(pos.X, pos.Z) + STAND_HEIGHT
	mover.CFrame = CFrame.new(mover.Position.X, standY, mover.Position.Z) * CFrame.Angles(0, heading, 0)
end

local function clampToWorldBounds(pos)
	local fromOrigin = Vector3.new(pos.X, 0, pos.Z)
	if fromOrigin.Magnitude <= WORLD_BOUND_SAFE_RADIUS then return pos end
	local clamped = fromOrigin.Unit * WORLD_BOUND_SAFE_RADIUS
	return Vector3.new(clamped.X, pos.Y, clamped.Z)
end

local elapsedWalkTime = 0
-- accel (optional): overrides MOVE_ACCEL for this call's easing rate, same
-- shape as stepVelocity's own accel override — used by the chase call
-- below to swap in CHASE_MOVE_ACCEL instead of ordinary walking's MOVE_ACCEL.
-- Also feeds the arrival-braking math right below (stopSpeedCap), not just
-- stepVelocity itself — braking distance depends on how fast this call can
-- actually decelerate, so a call using a different accel needs its braking
-- curve sized against that same accel, not the global default.
local function moveTo(target, speed, noiseScale, arriveDist, requireStop, interrupt, accel)
	noiseScale = noiseScale or 1
	arriveDist = arriveDist or 0.5
	if requireStop == nil then requireStop = true end
	accel = accel or MOVE_ACCEL
	local isLive = typeof(target) == "function"
	while true do
		if not mimic:GetAttribute("MimicActive") then return false end
		local dt = RS.Heartbeat:Wait()
		if not mimic:GetAttribute("MimicActive") then return false end
		if interrupt and interrupt(dt) then return false end
		elapsedWalkTime += dt

		local targetPos = target
		if isLive then
			targetPos = target()
			if not targetPos then return false end
		end

		local pos = mimic.Position
		local toTarget = Vector3.new(targetPos.X - pos.X, 0, targetPos.Z - pos.Z)
		local dist = toTarget.Magnitude
		if dist < arriveDist and (not requireStop or velocity.Magnitude < 0.5) then
			return true
		end

		local brakeTarget = requireStop and arriveDist or (arriveDist - ARRIVE_BRAKE_INSET)
		local distToRing = math.max(dist - brakeTarget, 0)
		local stopSpeedCap = math.sqrt(2 * accel * distToRing / ARRIVE_STOP_MARGIN)
		local arriveScale = math.min(stopSpeedCap / speed, 1)

		local headingNoise = math.noise(elapsedWalkTime * WANDER_NOISE_FREQ, noiseSeed) * WANDER_NOISE_STRENGTH * arriveScale * noiseScale
		local speedNoise = 1 + SPEED_VARIATION * noiseScale * arriveScale * math.noise(elapsedWalkTime * SPEED_NOISE_FREQ, noiseSeed + 100)

		local dir = dist > 0.01 and (CFrame.Angles(0, headingNoise, 0) * toTarget.Unit) or Vector3.new(0, 0, 0)
		local desiredVel = dist > 0.01 and (dir * speed * arriveScale * speedNoise) or Vector3.new(0, 0, 0)
		stepVelocity(desiredVel, dt, accel)
		updateBalance(dt)
	end
end

-- ── owner/config lookups — read fresh every call, never cached, so a
-- config edit (PetConfigClient -> PetMimicHandler) or the owner's
-- character respawning mid-life is picked up on the very next check
-- instead of needing this pet to be re-spawned ────────────────────────
local function getOwnerRoot()
	local player = Players:GetPlayerByUserId(ownerId)
	local char = player and player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function getTargetRange()
	local player = Players:GetPlayerByUserId(ownerId)
	local cfg = player and player:FindFirstChild("PetMimicConfig")
	local minV = cfg and cfg:FindFirstChild("MinSize")
	local maxV = cfg and cfg:FindFirstChild("MaxSize")
	return (minV and minV.Value) or 0, (maxV and maxV.Value) or 0
end

-- true if some OTHER still-active pet mimic already has `obj` sitting in
-- its own HuntedPrey (the wide-radius walk-toward pick each pet's own
-- main loop below writes there) — every pet mimic lives as a sibling in
-- this same folder, so this is just a sibling scan, no registry needed.
-- Only ever consulted from findTarget's own scanForPrey pass (see
-- excludeClaimed below), never from findAbsorbable's tight-radius one —
-- this is about two owners' pets not both beelining clear across a
-- cluster for the exact same single far-off ball, not about stopping
-- them from both feeding once they're already standing in the same
-- crowd; a ball already within ABSORB_RANGE of two different pets should
-- still just go to whichever one's absorb-loop cooldown fires first
-- (same as it already does today), not get artificially reserved for
-- neither.
local function isClaimedByAnotherPetMimic(obj)
	for _, other in ipairs(folder:GetChildren()) do
		if other ~= mimic and other:GetAttribute("IsPetMimic") and other:GetAttribute("MimicActive") then
			local huntedByOther = other:FindFirstChild("HuntedPrey")
			if huntedByOther and huntedByOther.Value == obj then
				return true
			end
		end
	end
	return false
end

-- shared by findTarget (wide, HUNT_RADIUS) and findAbsorbable (tight,
-- ABSORB_RANGE) below — everything about what counts as "qualifying prey
-- right now" lives here once, so the two callers can never quietly drift
-- out of sync on size range/Split/PendingSell/Sold/world-bound filtering
-- and only ever differ on how far away they're willing to look (and, now,
-- on whether another pet mimic's own current target is fair game —
-- see excludeClaimed/isClaimedByAnotherPetMimic above).
--
-- Picks whichever qualifying ball is CLOSEST to the pet, not a random
-- one among them — unlike MimicFuse's own findPrey (which picks randomly
-- on purpose, so a board mimic's hunting doesn't read as too
-- mechanically optimal), a pet mimic is the owner's own configured tool,
-- so always going for the nearest bite reads as intentional rather than
-- as an oversight in how it chases/absorbs.
--
-- Also refuses to return anything AT ALL once the board has one or zero
-- eatable balls left on it — same totalViable carve-out MimicFuse's own
-- findPrey applies for a board mimic (see its comment there), extended
-- to a pet mimic too (both the walk-toward-it and the instant-absorb
-- sides of it): totalViable counts every live, non-mid-sale regular ball
-- anywhere on the board, not just the ones within `radius`/the owner's
-- configured size window, since the rule is about not extinguishing the
-- board's last ball for everyone else, not about this pet's own reach or
-- its owner's configured range. Deliberately NOT affected by
-- excludeClaimed either — a ball being someone else's current target
-- doesn't stop counting as "still on the board" for that purpose.
--
-- A radiant ball (IsRadiant attribute — see BallManager) is excluded
-- from ever being `nearest`, same as MimicFuse's own findPrey excludes
-- one from its candidates — a pet mimic never targets or absorbs a
-- radiant ball either, board mimic or pet, no exceptions. Still counted
-- toward totalViable above, same reasoning as findPrey's: that count is
-- about whether the board has A ball left at all, not about what this
-- pet is willing to eat.
local function scanForPrey(radius, excludeClaimed)
	local minSize, maxSize = getTargetRange()
	if maxSize <= 0 then return nil end
	local myPos = mimic.Position
	local totalViable = 0
	local nearest, nearestDist = nil, nil
	for _, obj in ipairs(folder:GetChildren()) do
		if obj ~= mimic and obj:IsA("BasePart") and obj.Name == ballT.Name
			and not obj:GetAttribute("Split") and not obj:GetAttribute("PendingSell") and not obj:GetAttribute("Sold") then
			totalViable += 1
			local theirSize = obj:GetAttribute("TargetSize") or obj.Size.X
			-- both radius checks below (HUNT_RADIUS via findTarget,
			-- ABSORB_RANGE via findAbsorbable) are really asking "how much
			-- open space is between the pet and this thing", not "how far
			-- apart are the two centers" — comparing raw center-to-center
			-- dist against a fixed radius silently assumes a point-sized
			-- ball. That's fine for ordinary sizes, but once a ball's own
			-- radius stops being negligible next to ABSORB_RANGE, its
			-- surface can already be well within reach while its center
			-- still reads as outside ABSORB_RANGE, so findAbsorbable never
			-- returns it and the pet just sits there pressed up against a
			-- big ball it can visibly touch but can never actually trigger
			-- a pull-in on. Subtracting the ball's own radius converts
			-- `dist` into the gap to its near surface instead, so the
			-- comparison stays accurate regardless of how big it is.
			local theirRadius = theirSize / 2
			local dist = (obj.Position - myPos).Magnitude
			local gap = dist - theirRadius
			local distFromOrigin = Vector3.new(obj.Position.X, 0, obj.Position.Z).Magnitude
			if not obj:GetAttribute("IsRadiant")
				and theirSize >= minSize and theirSize <= maxSize
				and gap <= radius
				and distFromOrigin <= WORLD_BOUND_SAFE_RADIUS
				and (nearestDist == nil or dist < nearestDist)
				and not (excludeClaimed and isClaimedByAnotherPetMimic(obj)) then
				nearest, nearestDist = obj, dist
			end
		end
	end
	if totalViable <= 1 then return nil end
	return nearest
end

-- the wide-radius lookup the main loop below walks toward — this is
-- purely a waypoint pick now, not a commitment to eat that specific
-- ball (see the absorb loop's own findAbsorbable, which is what
-- actually eats things). excludeClaimed=true here is what keeps two
-- different owners' pet mimics from both locking onto the same single
-- ball and beelining across the whole board for it — whichever pet
-- claimed it first (by writing it to its own HuntedPrey, see the main
-- loop below) keeps it; everyone else's findTarget skips straight past
-- to their own next-nearest option instead of piling onto the same one.
local function findTarget()
	return scanForPrey(HUNT_RADIUS, true)
end

-- the tight-radius lookup the absorb loop below actually eats from —
-- deliberately separate from findTarget/HUNT_RADIUS: this only ever
-- returns something already close enough to pull in this instant,
-- regardless of what the pet happens to be walking toward at the time.
-- excludeClaimed=false here on purpose — once a ball's actually inside
-- ABSORB_RANGE it's fair game for whichever nearby pet's cooldown fires
-- first (pullIn's own synchronous PendingSell claim, not this, is what
-- already keeps two pets from double-absorbing the same one), so this
-- shouldn't reserve it for whichever pet merely has it as a far-off
-- HuntedPrey waypoint.
local function findAbsorbable()
	return scanForPrey(ABSORB_RANGE, false)
end

-- starts pulling `prey` in — payout/broadcast/highlight/destroy is
-- SellService.petMimicAbsorb's job, via the _G.PetMimicAbsorb relay
-- (see PetMimicHandler and the require-site comment up top for why
-- it's routed through there instead of task.spawn'd directly on this
-- script); this just plays the same shrink-to-size-1-while-floating-
-- into-the-body visual the old blocking version ended on, except now on
-- its own coroutine, so it runs ALONGSIDE the pet's ongoing walk/hunt
-- loop and alongside any other ball also mid-pull-in at the same time,
-- instead of the whole pet standing still and waiting out one catch
-- before it can even look for the next
local PET_ABSORB_TIME = 0.3 -- kept in sync with SellService's own PRE_SELL_DELAY by hand
local function pullIn(prey)
	-- PetMimicBody passing through everything (see the collision-group
	-- note near the top of this file) is what lets this CFrame straight
	-- through the mimic's own body without the two shoving each other
	-- apart as it arrives
	prey.CollisionGroup = CG.MimicPrey

	-- petMimicAbsorb checks-and-sets PendingSell itself, synchronously,
	-- before _G.PetMimicAbsorb's Fire() call even returns (a
	-- BindableEvent's connected handler starts running immediately, up
	-- to its own first yield, the moment Fire() is called — and
	-- petMimicAbsorb doesn't yield until its own
	-- task.wait(PRE_SELL_DELAY)) — so by the time control comes back
	-- here, this ball is already claimed and can't be picked up again
	-- by this same pet's next absorb-loop tick, or by SellHandler/
	-- BallManager/another mimic racing it
	if not _G.PetMimicAbsorb then
		warn("[PetMimicFuse] PetMimicHandler hasn't defined _G.PetMimicAbsorb yet — dropping this absorb")
		return
	end
	_G.PetMimicAbsorb(prey, ownerId)

	-- anchored purely so nothing but this coroutine's own CFrame/Size
	-- writes move or resize it for its last moments; it's about to be
	-- destroyed by petMimicAbsorb regardless
	local preyStartPos = prey.Position
	local preyStartSize = prey.Size
	prey.Anchored = true

	activePulls[prey] = true
	refreshGroundRayFilter()

	task.spawn(function()
		local t = 0
		while t < PET_ABSORB_TIME do
			if not mimic:GetAttribute("MimicActive") then break end
			local dt = RS.Heartbeat:Wait()
			t += dt
			local alpha = math.clamp(t / PET_ABSORB_TIME, 0, 1)
			local sizeAlpha = 1 - 2 ^ (-10 * alpha) -- expo-out — fast at first, easing smoothly into size 1 right as it reaches the body
			if prey.Parent then
				-- mimic.Position read live every frame (not just the
				-- start position) so a prey caught while the pet is
				-- still mid-stride gets dragged to wherever the body
				-- actually ends up, not where it was the instant this
				-- pull started. This is only actually live because of
				-- the SetNetworkOwner(nil) call up in the wake-up
				-- section — see its comment; without that, this read
				-- looks live but is quietly working off a stale,
				-- possibly-frozen replicated position instead.
				prey.CFrame = CFrame.new(preyStartPos:Lerp(mimic.Position, alpha))
				prey.Size = preyStartSize:Lerp(Vector3.new(1, 1, 1), sizeAlpha)
			end
		end
		activePulls[prey] = nil
		refreshGroundRayFilter()
	end)
end

-- ── absorb loop: runs independently of the walk-toward-a-target logic
-- in the main loop below, for as long as this pet is awake. Deliberately
-- NOT folded into the main loop's own HUNT_RECHECK_INTERVAL cadence —
-- that interval only governs how often it's worth re-picking a walking
-- destination, and gating actual eating behind it too would mean up to
-- half a second of "yes, in range, just not looking yet" on every catch.
-- ABSORB_COOLDOWN alone paces this, checked every Heartbeat, so a pull
-- starts the instant something qualifying is close enough and the
-- previous pull's own cooldown has elapsed — not tied to travel time,
-- not tied to any one ball's own PET_ABSORB_TIME animation (which, since
-- pullIn backgrounds it, was never blocking this loop to begin with).
task.spawn(function()
	local cooldownT = ABSORB_COOLDOWN -- starts "ready" so the very first qualifying ball in range doesn't sit out a full cooldown it never actually needed
	while mimic:GetAttribute("MimicActive") do
		local dt = RS.Heartbeat:Wait()
		if not mimic:GetAttribute("MimicActive") then break end
		cooldownT += dt
		if cooldownT >= ABSORB_COOLDOWN then
			local prey = findAbsorbable()
			if prey then
				cooldownT = 0
				pullIn(prey)
			end
		end
	end
end)

-- ── main loop: follow the owner within FOLLOW_DIST, or walk toward the
-- nearest qualifying ball once one's within HUNT_RADIUS. This is now
-- ONLY about positioning — actual eating is entirely the absorb loop's
-- job (see above), running the whole time this loop is doing anything
-- else, so a target found here is a waypoint to close distance on, not
-- something this loop itself commits to catching.
while mimic:GetAttribute("MimicActive") do
	local target = findTarget()
	if target then
		huntedPreyValue.Value = target

		-- arriveDist is comfortably inside ABSORB_RANGE (not a
		-- point-blank overlap the way the old single-target chase
		-- needed) — this only has to get the pet close enough for the
		-- absorb loop to start pulling this, and whatever else is
		-- nearby, in; it doesn't need to walk exactly onto it, and
		-- doesn't need requireStop either, since there's no longer a
		-- stop-and-crouch beat to plant itself for
		local function liveTargetPos()
			if target.Parent ~= folder or target:GetAttribute("PendingSell") then return nil end
			local pos = target.Position
			-- target itself can drift past WORLD_BOUND_SAFE_RADIUS after it
			-- was already picked (scanForPrey only filters at selection
			-- time) — without this check moveTo just keeps returning a
			-- live, non-nil position out past the border forever, and since
			-- the pet's own body is hard-capped from ever crossing that
			-- ring (see stepVelocity's world-border brake), it parks right
			-- at the edge "watching" a target it can physically never
			-- close the last few studs on instead of ever re-picking.
			-- Returning nil here instead makes moveTo bail out immediately,
			-- same as an absorbed/despawned target, so the loop below falls
			-- through to findTarget() and grabs whatever's next
			if Vector3.new(pos.X, 0, pos.Z).Magnitude > WORLD_BOUND_SAFE_RADIUS then return nil end
			return pos
		end
		-- CHASE_MOVE_ACCEL here, not the default MOVE_ACCEL — a chase needs
		-- to snap onto a new nearest target fast; ordinary walking (the
		-- follow-owner moveTo call below) deliberately leaves this
		-- unspecified so it keeps easing at MOVE_ACCEL's slower, smoother rate
		moveTo(liveTargetPos, CHASE_SPEED, 0.4, ABSORB_RANGE * 0.5, false, nil, CHASE_MOVE_ACCEL)
		-- moveTo returning (whether "arrived", or the live target
		-- vanished out from under it because the absorb loop already
		-- ate it) just falls through to the top of this while loop,
		-- which re-runs findTarget() and picks wherever's nearest next
	else
		huntedPreyValue.Value = nil

		local recheckT = 0
		local foundMidWalk = nil
		local ownerTargetFn = function()
			local root = getOwnerRoot()
			return root and clampToWorldBounds(root.Position) or nil
		end
		moveTo(ownerTargetFn, WALK_SPEED, nil, FOLLOW_DIST, true, function(dt)
			recheckT += dt
			if recheckT < HUNT_RECHECK_INTERVAL then return false end
			recheckT = 0
			foundMidWalk = findTarget()
			return foundMidWalk ~= nil
		end)

		if not (foundMidWalk and mimic:GetAttribute("MimicActive")) then
			-- either already within FOLLOW_DIST, or there's no owner/
			-- character to follow right now — a short pause instead of
			-- immediately re-looping, so this doesn't spin a fresh
			-- moveTo call (and its own findTarget-recheck machinery)
			-- every single Heartbeat while just standing there
			local idleT = 0
			while idleT < IDLE_PAUSE and mimic:GetAttribute("MimicActive") do
				local dt = RS.Heartbeat:Wait()
				idleT += dt
				stepVelocity(Vector3.new(0, 0, 0), dt)
				updateBalance(dt)
			end
		end
	end
end