--[[
    MimicFuse (Script)
    Path: ReplicatedStorage → Mimic
    Parent: Mimic
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 13:33:37
]]
--[[
	MimicFuse (Script) — place inside the Mimic template in ReplicatedStorage
	(ReplicatedStorage.Mimic.MimicFuse).

	A mimic spawns and launches exactly like a regular ball (BallManager's
	spawnMimic handles that — same ascend/grow-in/settle physics as
	spawnBall, see its own comment there) and looks identical to one too:
	random color, numDisplay showing its size. All this script does is
	wait out that "asleep" window, then take over completely once it
	wakes: swap the display to "??", and leave the body fully unanchored
	and physics-simulated (instead of anchoring it) the whole time — it
	can be bumped by other balls and can bump them right back — while
	still being steered, and start wandering the platform — occasionally
	ambling for a smaller ball, standing over it, and absorbing it
	(SellService.mimicAbsorb) for half its price.

	Movement is genuinely physics-driven, not scripted-position-driven:
	horizontal walking is a force-capped VELOCITY servo (LinearVelocity)
	that only ever nudges the body's velocity toward wherever it wants to
	walk, and never corrects positional error — so something shoving the
	mimic actually displaces it, and it just resumes walking from
	wherever it ends up instead of snapping/dragging back to a scripted
	spot. Standing height stays a position servo (AlignPosition, Y axis
	only) so it doesn't sink through the floor, and facing is a
	torque-capped AlignOrientation that can visibly stagger under a hit
	before self-righting — see the "config: physics-driven movement" and
	"config: balance recovery" sections below for the knobs.

	THE LEGS ARE NOT DRAWN BY THIS SCRIPT ANYMORE. They used to be:
	anchored parts this server script CFrame'd directly every Heartbeat,
	right alongside owning the body's real physics. That put the body and
	the legs on two DIFFERENT replication paths to every client — the
	body (unanchored, physics-simulated) replicates through Roblox's
	physics replicator, which buffers/interpolates; the legs (anchored,
	CFrame set in a script) replicate
	as plain property writes, which land faster and more consistently.
	Same server frame, two different pipes, two different latencies —
	that's what read as "the legs lag behind the head" (or, depending on
	which side happened to be slower for a given client, the reverse).
	No amount of tuning the Align constraints fixes that; it's a mismatch
	between replication systems, not physics tuning.

	The actual fix: legs are now rendered PER-CLIENT by a companion
	LocalScript (MimicLegsClient, meant to live in StarterPlayerScripts —
	see that script's own header) that reads mimic.CFrame every
	RenderStepped — i.e. whatever this client currently has for the body,
	already-lagged or not — and positions its own, local-only leg parts
	off of that. Nothing about leg placement crosses the network anymore,
	so legs can never race the body they're attached to; they're derived
	from it, every frame, on the same machine that's rendering both.
	This script no longer creates, destroys, or touches leg parts at all.

	The body is left on Roblox's automatic per-player network ownership,
	same as every other ball — it is deliberately NOT pinned to the
	server via SetNetworkOwner. That was tried, on the theory that a
	single consistent physics authority mattered for steering/collision/
	absorb decisions; it doesn't, because all of that logic (findPrey,
	moveTo, eat, SellService.mimicAbsorb) runs in this server Script
	regardless of which machine is actually stepping the body's physics —
	a server Script always reads/writes replicated Position/attributes/
	constraints no matter who owns them. What pinning ownership DID break:
	Roblox leans on its automatic ownership system to merge touching
	physics assemblies onto a shared owner so contacts resolve properly;
	opting the mimic out of that (while every ball it might collide with
	stays on automatic ownership) meant hits from other balls often
	didn't impart a physics impulse to it at all. Leaving ownership
	automatic fixes that, and costs nothing here since nothing below
	depends on it.

	MimicActive is what this whole script's aliveness hangs off of: true
	from the moment it wakes, until BombFuse's revertMimic flips it back
	to false — the ONLY thing that ever does (see BombFuse's own
	comment). Every loop below re-checks it and just stops the instant
	it goes false. BombFuse handles the display/name/physics teardown it
	already knew about; a small watcher below (see the wake-up section)
	additionally releases the mover/Align constraints added here the
	moment MimicActive goes false, since BombFuse has no idea those
	exist. MimicLegsClient watches the same attribute independently on
	each client to tear down its own local leg parts — this script
	doesn't need to do anything for that.

	A board-wipe collapse (BallManager.triggerCollapse) needs no special
	handling here either: it strips every non-Ball object's BaseScript
	children before wiping the board, which kills this script outright
	the same way it kills BombFuse's fuse — see triggerCollapse's own
	comment. MimicLegsClient notices the mimic disappearing from the
	folder and cleans up on its own.
]]

local RS = game:GetService("RunService")
local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local BadgeService = game:GetService("BadgeService")
local Players = game:GetService("Players")

local mimic = script.Parent
local folder = mimic.Parent -- already parented into Workspace.Balls by BallManager

-- a pet mimic (see BallManager's spawnPetMimic/UpgradeData's "petMimic"
-- entry) clones the exact same Mimic template as a board mimic — which
-- means this script gets cloned in right alongside it, same as it would
-- for any other mimic — but everything below (wander/hunt against the
-- WHOLE board, half-price absorb, magenta flash, reverting to a plain
-- sellable ball on death) is the wrong behavior for something a specific
-- player bought and is meant to keep. PetMimicFuse (cloned in
-- separately, directly onto the mimic instance itself, by spawnPetMimic)
-- owns a pet mimic's entire life instead — this just steps aside for it,
-- immediately, before touching anything.
if mimic:GetAttribute("IsPetMimic") then
	return
end

local ballT = game:GetService("ReplicatedStorage"):WaitForChild("Ball") -- name check below is what a mimic hunts for
local mimicT = game:GetService("ReplicatedStorage"):WaitForChild("Mimic") -- what a mimic is named for its ENTIRE dormant life, not just before wake — it only ever becomes ballT.Name in one of two places outside this script: BallManager's onHB, right at the instant it's confirmed to be falling off the platform without ever having woken (see WAKE_MIN_Y/WORLD_BOUND_RADIUS below — that's what stops the wake attempt; BallManager is what then converts it so it splits like a real ball instead of just disappearing), or BombFuse's revertMimic, if a bomb catches it while awake. This script itself renames mimic.Name = mimicT.Name once on wake (see wake-up section below) purely to restore the name if BallManager somehow renamed it and it's still here — normally a no-op since Name is already mimicT.Name at that point.

-- shared with SellHandler/BallManager; owns the actual payout,
-- broadcast, and highlight-then-destroy beat for an absorb — see
-- SellService.mimicAbsorb
local SellService = require(ServerScriptService:WaitForChild("SellService"))

-- collision groups: lets the mimic's body walk fully OVERTOP the one
-- ball it's actively eating, without touching collision for anything
-- else on the board. Plain CanCollide toggling can't do this cleanly —
-- CanCollide is global, so flipping the prey's off would also let every
-- OTHER ball/mimic pass through it, not just this hunter. Two named
-- groups + a single collision rule between them does exactly the one
-- pairing that needs to change: CG.MimicBody still collides normally
-- with everything else on the board; only MimicBody vs. MimicPrey is
-- turned off, and only the ball actually being hunted is ever put in
-- MimicPrey (see eat() below), for only as long as the hunt lasts.
--
-- Both groups and that single rule are declared in
-- ReplicatedStorage.CollisionGroups, so every mimic on the board shares
-- one definition instead of each copy of this script racing to register
-- the same two groups for itself.
local CG = require(Rep:WaitForChild("CollisionGroups"))

-- ── config: sound ──────────────────────────────────────────────────
-- fired through the same SoundEvents RemoteEvent BallManager/BombFuse/
-- DashHandler already use (see SoundClient's own header) — these two
-- events are genuinely server-authoritative (wake and revert both only
-- ever happen once, decided here), so they go through the remote
-- rather than being played locally the way MimicLegsClient's leg-growth
-- and footstep sounds are (those are purely cosmetic per-client
-- renders with no single authoritative moment to hang a server fire
-- off of — see that script's own sound section).
local se = game:GetService("ReplicatedStorage"):WaitForChild("SoundEvents")

-- fired at the same moment AwardBadge actually succeeds below (wake-up
-- section), targeted at just that one player, so ShopClient can cache
-- "yes they own this badge" the instant it's true server-side instead
-- of finding out later via its own UserHasBadgeAsync poll. Must exist
-- as a RemoteEvent under ReplicatedStorage — create one there named
-- exactly "BadgeAwarded" if it doesn't exist yet.
local badgeAwardedEvent = game:GetService("ReplicatedStorage"):WaitForChild("BadgeAwarded")
local WAKE_ALARM_SOUND = "rbxassetid://12221990" -- overflow collapse alarm, reused here as the mimic's own wake-up cue — fired at the start of the "push-up" section below (once the body actually starts rising), not the instant MimicActive first goes true; kept in sync with SoundClient's PRELOAD_IDS list by hand, same as BombFuse's FLASH_IMAGE (see SoundClient's header)
local WAKE_ALARM_VOLUME = 0.4
local REVERT_SOUND = "rbxassetid://12222152" -- bomb defuse sfx, reused here as the "converts back into a regular ball" cue — fired from the single shared watcher below (see its own comment) so it covers BOTH ways MimicActive can flip false, not just a bomb catching it

-- ── config: wake-up ─────────────────────────────────────────────────
local MIMIC_WAKE_BADGE_ID = 3684816254175058 -- awarded to every player currently in the game the instant a mimic wakes
local WAKE_DELAY = 5             -- seconds spent looking/acting like a plain ball before waking up
local WAKE_MIN_Y = -5            -- mirrors BallManager's own FALL_Y — a dormant mimic is named/tracked exactly like a regular ball (see the wake-up section) and BallManager splits it the same way a regular ball splits once it falls back through the platform below this Y, same as any other ball. That means a dormant mimic can be mid-fall (or already re-split into two ordinary replacement balls) by the time WAKE_DELAY elapses; stillAsleep below refuses to let it wake up once it's dropped this far, rather than sprouting legs and standing up in open air below the map.
local LEGS_SPROUT_TIME = 1.0     -- total time all of the mimic's legs take to sprout out, one after another, before the body starts rising. This script does nothing to the body's height for this whole span — it just holds still while MimicLegsClient grows its legs out client-side. MUST match MimicLegsClient's own LEGS_SPROUT_TIME, since that's what actually paces the per-leg animation this is standing in for.
local BODY_RISE_TIME = 0.6       -- how long the body then takes to rise from settled height to standing height, once every leg has finished sprouting. Client-side legs don't need to know this value — MimicLegsClient's per-frame foot IK just tracks the ground under the rising hip on its own, at whatever pace this actually happens.
local LEG_LIFT_FRAC = 1.3          -- clearance the body rides above the floor once standing, as a FRACTION of body size — scales with the mimic instead of a fixed stud gap, since leg length (LEG_SEGMENT_FRAC over in MimicLegsClient) scales with body size too, so a bigger mimic's longer legs should actually stand it proportionally taller. MUST match MimicLegsClient's own LEG_LIFT_FRAC, since that's what determines how tall its legs actually reach. Tune to taste.

-- ── config: wander/hunt ─────────────────────────────────────────────
local WALK_SPEED_PER_SIZE = 2    -- studs/sec of ambling speed, PER POINT of bodySize — used to be a flat 10 (upped from 6 alongside the longer legs/larger stance, so a bigger mimic actually read as covering ground faster instead of taking the same old pace on longer legs), but a flat number is itself just as size-blind as the "same old pace" it was fixing: it was tuned looking at a size-5 mimic (10 = 2 * 5), so anything bigger still paced like a size 5 despite its longer legs/larger stance, and anything smaller looked comically fast for its size. WALK_SPEED itself is derived from this once bodySize is known — see the wake-up section below — using size 5 as the reference point this was actually tuned/played at.
local CHASE_SPEED_PER_SIZE = 4   -- studs/sec while beelining for prey, per point of bodySize — same reasoning as WALK_SPEED_PER_SIZE, at the same 2x-of-walk ratio the old flat 10/20 pair had (20 = 4 * 5 at size 5). CHASE_SPEED is likewise derived once bodySize is known.
local TURN_SPEED = 4             -- radians/sec the body reorients to face its heading
local WANDER_RADIUS = 50         -- studs from the spot it woke up at, that it roams within
local WORLD_BOUND_RADIUS = 50    -- hard cap: nothing below ever sends the mimic farther than this from the world origin (0, 0), regardless of where it woke up or what it's chasing
local MIMIC_MAX_RADIUS = 55      -- hard cap on the mimic's ACTUAL position (not a scripted target) — set to platform radius if changed. Bigger than WORLD_BOUND_RADIUS on purpose: WORLD_BOUND_RADIUS only clamps where THIS script is willing to aim its own wander/hunt targets, while this is the genuine "off the platform" line — the same threshold stillAsleep() below already used pre-wake (previously a bare literal there), now shared with the post-wake watcher near the wake-up section, so a mimic reverts to a normal ball at the same distance whether or not it's woken up yet.
local IDLE_MIN, IDLE_MAX = 1, 3  -- seconds paused between wander legs
local LOOK_AROUND_CHANCE = 0.35  -- odds, rolled fresh at the start of each idle pause, that it spends this pause turning to glance somewhere else instead of just standing still — purely cosmetic, never moves the body
local LOOK_AROUND_MAX_TURN = math.rad(110) -- max radians either direction off its current heading that a look-around can turn to
local HUNT_CHANCE = 0.3          -- odds, rolled at each idle pause AND periodically during an in-progress wander leg (see HUNT_RECHECK_INTERVAL), that it goes hunting instead of ambling
local HUNT_RECHECK_INTERVAL = 1  -- seconds between prey re-checks while a wander leg is already underway, so a ball that spawns in (or wanders into range) mid-leg gets noticed and interrupts the wander, instead of only ever being checked for right before a fresh wander leg starts
local HUNT_RADIUS_PER_SIZE = 5.6 -- studs of notice/chase range, PER POINT of bodySize — used to be a flat 28 (tuned at size 5: 28 = 5.6 * 5), which left a big mimic noticing prey at a range that hadn't grown along with its body/legs, and a small mimic sensing prey from disproportionately far away. HUNT_RADIUS is derived from this once bodySize is known.
local EAT_OVERLAP_DIST_PER_SIZE = 0.2 -- studs, center-to-center, that the chase converges to once collision against this specific prey is disabled (see the collision-group setup near the top of the file), PER POINT of bodySize — used to be a flat 1 (tuned at size 5: 1 = 0.2 * 5), small on purpose so the body ends up standing right OVER the ball instead of stopping beside it at the old collision-limited standoff distance. Left flat, a big mimic's much wider body converged to the same tiny 1-stud center gap as a size 5's — which the chase could end up satisfying while still noticeably off-center relative to the bigger body — while a small mimic converged tighter than its own body really needed. EAT_OVERLAP_DIST is derived from this once bodySize is known.
local ARRIVE_DIST_PER_SIZE = 0.6 -- studs of "close enough, count as arrived" clearance around a wander/idle target, PER POINT of bodySize — replaces moveTo's own bare flat 0.5 default, which stayed the same regardless of how big (and how fast — see WALK_SPEED_PER_SIZE) a given mimic actually is. A bigger mimic carries more momentum at its own bigger WALK_SPEED, so even with the braking curve in moveTo sized correctly, the REAL physics body's actual velocity still lags fractionally behind the SCRIPTED one it's chasing — WALK_MAX_FORCE/walkMaxForce, however safety-margined, is a finite force, not an instant snap — enough that a big mimic can coast a stud or more past a tight, flat arrival ring before its scripted velocity has actually decayed to "arrived". Once it's genuinely past a ring that tight, toTarget flips a full 180° and moveTo's still-live braking math immediately commands a real, non-zero walk-BACK velocity to correct — which is exactly what read as "walks up, overshoots slightly, turns around, walks back" instead of just arriving and settling. Widening the ring so it scales with the same momentum that causes the overshoot keeps typical overshoot INSIDE arriveDist instead of past it, so moveTo's arrival check fires while the body's still coasting forward, before the far side ever triggers a reversed command. ARRIVE_DIST is derived from this once bodySize is known, same pattern as EAT_OVERLAP_DIST above — used for ordinary wander/idle walking, NOT for the chase (that already passes its own EAT_OVERLAP_DIST explicitly).
local CROUCH_TIME = 0.3          -- matches SellService's PRE_SELL_DELAY, so the body-still float-up below and the magenta fade-in land together
local EAT_STOP_TIME = 0.25       -- seconds the chase's leftover momentum takes to ease down to a stop once the hunt commits, instead of being snapped to zero instantly. See the eat()-commit comment below for why an instant snap read as the mimic freezing solid the moment it grabbed prey.
local EAT_STOP_ACCEL = 60        -- studs/sec^2 the commit-stop above eases velocity down at — deliberately much sharper than ordinary MOVE_ACCEL (walking-speed braking would let the body drift noticeably off the now-stationary prey mid-absorb), but still a ramp, not a snap, so it reads as a quick, smooth deceleration rather than a freeze.

-- ── config: physics-driven movement ──────────────────────────────────
-- the body stays fully unanchored/physics-simulated. Horizontal walking
-- is a VELOCITY servo (LinearVelocity, force-capped) rather than a
-- position servo: it only ever pushes the body's velocity toward the
-- walk controller's intended velocity, and never tries to correct
-- positional error caused by something shoving it — so a hit that
-- outmuscles WALK_MAX_FORCE for a frame actually displaces the mimic,
-- and it just resumes walking from wherever it ends up, instead of
-- snapping/dragging back to where it "should" be. Standing height stays
-- a POSITION servo (AlignPosition, Y axis only, via the invisible
-- "mover" part — see the wake-up section) so it doesn't sink through the
-- floor or get crushed flat, and facing is a torque-capped
-- AlignOrientation so a solid hit can visibly stagger/twist the body
-- before it rights itself — see the "config: balance recovery" section
-- below for how the self-righting reaction sharpens in the moment,
-- instead of just eventually catching up once the disturbance is over.
local WALK_MAX_FORCE = 9000              -- newtons cap on the horizontal velocity servo — deliberately soft, so another ball colliding with the mimic can actually shove it off course instead of the servo just overpowering the hit
local STAND_MAX_FORCE = 40000            -- newtons cap on the vertical height servo — kept strong so it doesn't sink through the floor or get crushed down by whatever it's standing near
local STAND_RESPONSIVENESS = 25          -- how eagerly the height servo chases standing height; high enough that walking still feels controlled rather than sluggish
local ORIENT_MAX_TORQUE = 25000          -- newtons-studs cap on the turning pull — soft enough that a solid bump can visibly twist the body before it self-rights
local ORIENT_RESPONSIVENESS = 15         -- how eagerly AlignOrientation chases its target heading, normally
local ORIENT_RECOVERY_RESPONSIVENESS = 40 -- how eagerly it chases that heading instead, for as long as isKnocked() is true — a sharper, more urgent self-righting reaction than the calm baseline above
local STAND_FORCE_SAFETY = 3             -- multiplier over the body's own weight (AssemblyMass * workspace.Gravity) that the standing-height servo's actual force cap is guaranteed to clear — see standForce below. STAND_MAX_FORCE alone is a flat number tuned against a typical mimic's mass; a part's mass scales with its volume (~bodySize^3), so a big enough mimic (a size-15 body was the one that surfaced this — see standForce's own comment) weighs enough that a flat 40000N stops being able to out-muscle gravity at all, and the body just sits at its settled height forever instead of rising onto its legs.

-- moved up from the "movement" section below (it's still that section's
-- own constant, and still only ever consumed there by stepVelocity) so
-- it's in scope here for walkMaxForce's computation just below — that
-- needs MOVE_ACCEL to size WALK_MAX_FORCE against, and Lua locals have
-- to exist before whatever reads them.
local MOVE_ACCEL = 18   -- studs/sec^2 cap on how fast the walk controller's own commanded `velocity` can change — see stepVelocity in the movement section below
local WALK_FORCE_SAFETY = 2.5 -- multiplier over the raw force (mass * MOVE_ACCEL) required to actually brake the body at MOVE_ACCEL, that WALK_MAX_FORCE is guaranteed to clear — see walkMaxForce below. Same shape of problem as STAND_FORCE_SAFETY above, just sideways instead of vertical: WALK_MAX_FORCE alone is a flat number, and mass scales with bodySize^3, so a big enough mimic's momentum at WALK_SPEED simply outmuscles a flat 9000N — the real, physics-simulated body then can't actually decelerate as fast as the SCRIPTED `velocity` value eases toward zero on approach, and coasts on past wherever moveTo's braking curve expected it to have already stopped, on its own leftover momentum. That's what read as walking up to a target, overshooting it, and turning back around to correct, instead of arriving and settling — the same softness that deliberately lets a shove displace the mimic (see WALK_MAX_FORCE's own comment) was, past a certain mass, also too soft to brake the mimic's own walk.

-- ── config: balance recovery ──────────────────────────────────────────
-- what actually reads as "reacting to being pushed" in the moment —
-- see isKnocked() and updateBalance below. (MimicLegsClient has its own,
-- client-side copy of this same tilt/velocity-mismatch check, purely so
-- its feet can scramble to catch the body in the moment too — the two
-- checks are independent and don't need to agree frame-to-frame, since
-- one drives real physics recovery and the other is cosmetic.)
local RECOVERY_TILT_THRESHOLD = math.rad(12) -- body tilt (off true vertical) beyond which it's treated as knocked off balance
local RECOVERY_VELOCITY_THRESHOLD = 10       -- studs/sec of mismatch between the body's ACTUAL velocity and the walk controller's INTENDED velocity that also counts as knocked — catches a shove along the ground even when it hasn't tipped the body at all

-- ── config: organic wander ────────────────────────────────────────────
-- both fade out on approach (see moveTo) so a wandering path still
-- actually arrives at its target instead of orbiting it
local WANDER_NOISE_STRENGTH = 0.5   -- radians of max heading drift off the straight line to the target, so the walk curves and wavers instead of beelining
local WANDER_NOISE_FREQ = 0.35      -- how quickly the heading drift wanders over time — low, so it reads as a lazy amble, not a jitter
local SPEED_VARIATION = 0.25        -- +/- fraction of speed that wavers over time, so pace isn't perfectly constant
local SPEED_NOISE_FREQ = 0.6        -- how quickly the speed waver evolves

-- ── wake-up wait ────────────────────────────────────────────────────
-- mirrors BombFuse's stillLive pattern: true only while the mimic is
-- still around, hasn't been claimed by something else in the meantime,
-- and hasn't fallen back off the platform after having reached it. A
-- dormant mimic stays named mimicT.Name (NOT a regular ball — not
-- sellable, not cap-eligible) for its whole time asleep; the Y/radius
-- checks below are purely what CANCELS the wake attempt. The actual
-- conversion into a regular ball (so it splits instead of just
-- disappearing) happens over in BallManager's onHB, right at the same
-- Y<FALL_Y instant this cancels the wake for — see the comment there
-- for why it lives in that script instead of here (avoids a race
-- between two separately-polling Heartbeat connections).
--
-- hasReachedPlatform gates the Y check specifically: SPAWN_POS sits at
-- Y = -25, deliberately BELOW WAKE_MIN_Y, and every ball (mimics
-- included) launches up through the platform from underground — so at
-- the very first Heartbeat after spawn, pos.Y is already below
-- WAKE_MIN_Y, same as a ball that's fallen OFF the platform would be.
-- Checking pos.Y < WAKE_MIN_Y unconditionally from script start reads
-- the initial launch itself as a fall and kills the wake sequence on
-- its first frame, before it ever climbs into view — mirrors why
-- BallManager's own FALL_Y check only ever applies once a ball is
-- "settled", never during its "ascending" climb from the same launch.
-- Once pos.Y has crossed WAKE_MIN_Y at least once, this latches true
-- and a SUBSEQUENT drop back below WAKE_MIN_Y is a genuine fall.
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
	while t < WAKE_DELAY do
		if not stillAsleep() then return end
		t += RS.Heartbeat:Wait()
	end
end
if not stillAsleep() then return end

-- ── wake up ─────────────────────────────────────────────────────────
local bodySize = mimic:GetAttribute("TargetSize") or mimic.Size.X

-- a single raycast straight down from the body's own XZ, used to keep
-- the body's standing height responsive to terrain (stepping over a
-- crate/ledge should still visibly lift the body) without needing this
-- script to know anything about individual foot placement anymore —
-- that per-foot detail lives entirely in MimicLegsClient now. This is a
-- coarser approximation than the old per-foot-average height (a single
-- point under the body's center, not 4 independent feet), which is the
-- trade-off for not running leg IK server-side purely to inform body
-- height; MimicLegsClient's own per-foot raycasts still handle the
-- fine-grained "one foot found a step, others didn't" case cosmetically.
local groundRayParams = RaycastParams.new()
groundRayParams.FilterType = Enum.RaycastFilterType.Exclude
groundRayParams.FilterDescendantsInstances = { mimic }

-- one-time-only: the TRUE floor under the mimic right now, found by
-- raycasting rather than trusting mimic.Position.Y - bodySize/2
-- blindly. A mimic can still be very slightly airborne, or slightly
-- embedded, the instant its wake timer elapses — residual bounce/
-- settle physics from BallManager's own ascend -> settle sequence,
-- especially amid a busy server start where a lot is spawning/settling
-- at once — and either one throws this single measurement off enough
-- that the BODY_RISE_TIME lift just below computes a target height too
-- close to (or even below) where the body already is. Nothing ever
-- re-measures floorY after this point, so that reads as "woke up
-- without ever visibly pushing itself off the ground", stuck with its
-- body against the floor for the rest of its life. The ray origin
-- anchors off mimic.Position.Y itself (not floorY — that's what this
-- is computing) since it only needs to start comfortably above
-- wherever the mimic currently happens to be, not exactly at the
-- floor.
local function measureFloorY()
	local origin = Vector3.new(mimic.Position.X, mimic.Position.Y + bodySize * 3, mimic.Position.Z)
	local result = WS:Raycast(origin, Vector3.new(0, -(bodySize * (6 + LEG_LIFT_FRAC)), 0), groundRayParams)
	return result and result.Position.Y or (mimic.Position.Y - bodySize / 2)
end

-- already settled by now (floorY is now raycast-measured, not just
-- trusted — see measureFloorY above); flat-platform assumption for
-- this starting reference point only. STAND_HEIGHT is how far above
-- whatever it's standing on the body rides once it's up on its
-- (client-rendered) legs — MUST stay in lockstep with MimicLegsClient's
-- own idea of standing height (built from the same LEG_LIFT_FRAC), or
-- the body will visibly float above/sink below where the legs plant.
local floorY = measureFloorY()
local STAND_HEIGHT = bodySize / 2 + bodySize * LEG_LIFT_FRAC
local bodyY = floorY + STAND_HEIGHT
local wakePos = mimic.Position

-- scaled off the *_PER_SIZE config above, now that bodySize is known —
-- see those constants' own comments for why a flat number was wrong
-- for anything but a size-5 mimic. MUST keep WALK_SPEED_PER_SIZE in
-- sync with MimicLegsClient's own STRIDE_LEAD_REFERENCE_SPEED_PER_SIZE,
-- same as the old flat 10 had to match that script's old flat
-- STRIDE_LEAD_REFERENCE_SPEED — see that script's own comment.
local WALK_SPEED = WALK_SPEED_PER_SIZE * bodySize
local CHASE_SPEED = CHASE_SPEED_PER_SIZE * bodySize
local HUNT_RADIUS = HUNT_RADIUS_PER_SIZE * bodySize
local EAT_OVERLAP_DIST = EAT_OVERLAP_DIST_PER_SIZE * bodySize
local ARRIVE_DIST = ARRIVE_DIST_PER_SIZE * bodySize

local function groundYAt(worldX, worldZ)
	local origin = Vector3.new(worldX, floorY + bodySize * 3, worldZ) -- comfortably above anything it might be standing on
	local result = WS:Raycast(origin, Vector3.new(0, -(bodySize * (6 + LEG_LIFT_FRAC)), 0), groundRayParams)
	return result and result.Position.Y or floorY
end

mimic:SetAttribute("MimicActive", true) -- BombFuse watches for this; the only thing that ever flips it back off. MimicLegsClient watches it independently on each client to start/stop rendering legs.

-- award the mimic wake-up badge to everyone currently in the game, once
-- per player, right as this mimic actually wakes. badgeAwardedEvent only
-- fires on a CONFIRMED success — AwardBadge can fail/hiccup same as any
-- other BadgeService call, and telling a client they own a badge they
-- might not actually have would let ShopClient show/sell an upgrade the
-- player hasn't really unlocked.
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(function()
		local success, err = pcall(function()
			BadgeService:AwardBadge(player.UserId, MIMIC_WAKE_BADGE_ID)
		end)
		if success then
			badgeAwardedEvent:FireClient(player, MIMIC_WAKE_BADGE_ID)
		else
			warn(("MimicFuse: failed to award badge %d to %s: %s"):format(MIMIC_WAKE_BADGE_ID, player.Name, tostring(err)))
		end
	end)
end

-- defensive, not normally load-bearing: a dormant mimic stays named
-- mimicT.Name for its whole time asleep (see mimicT's own declaration
-- above), so this is almost always already a no-op by the time it
-- wakes. Only exception is the exact race this is guarding against —
-- BallManager's onHB and this script's own wake-cancel both watch for
-- the same Y<FALL_Y instant, and if onHB's Heartbeat happened to fire
-- first that frame and already converted this to ballT.Name right as
-- WAKE_DELAY was also expiring, this puts it back — though in
-- practice stillAsleep() above will have already caught the same fall
-- and returned before execution ever reaches here.
mimic.Name = mimicT.Name

do
	local display = mimic:FindFirstChild("display")
	local label = display and display:FindFirstChild("numDisplay")
	if label then
		label.Text = "??"
	end
end

-- the body stays unanchored and physics-simulated from here on — unlike
-- MagnetFuse's anchor-and-script approach, this mimic keeps real physics
-- running underneath it (gravity, collisions with other balls, getting
-- knocked around) rather than ever having its CFrame snapped directly.
-- It's steered by a velocity servo horizontally and a height/heading
-- servo (via the separate, invisible "mover" part) vertically/rotationally
-- — see "config: physics-driven movement" above for why those are two
-- different kinds of control, and for why that split is what actually
-- lets it be pushed around instead of dragged back into place. Position
-- itself is untouched here — it stays at its physics-settled height
-- until the grow-in loop below lifts it, rather than snapping straight
-- up before it's visually standing.
mimic.CanCollide = true
mimic.CollisionGroup = CG.MimicBody -- see the group setup near the top of the file; this only ever changes how it collides with whichever ball is in CG.MimicPrey at the time (nothing, by default) — every other collision (other balls, other mimics, the floor) behaves exactly as before

-- NOT calling mimic:SetNetworkOwner(nil) here on purpose — see this
-- script's header ("The body is left on Roblox's automatic..."). Pinning
-- it to the server used to make the body stop reacting to collisions
-- with other (automatically-owned) balls entirely.

local mimicAttachment = Instance.new("Attachment")
mimicAttachment.Name = "MimicRoot"
mimicAttachment.Parent = mimic

-- lets MimicLegsClient know which ball (if any) is currently being
-- hunted, so its own foot-placement raycast can exclude it the same way
-- groundYAt above excludes it for body height — see eat() below, which
-- is the only thing that ever sets/clears this. An ObjectValue rather
-- than an attribute since attributes don't support Instance references.
local huntedPreyValue = Instance.new("ObjectValue")
huntedPreyValue.Name = "HuntedPrey"
huntedPreyValue.Parent = mimic

-- the mover: an invisible, anchored, non-colliding part. It never drags
-- the body's horizontal position around — see "config: physics-driven
-- movement" above — it only feeds (a) the vertical height servo's
-- target Y, via alignPos below, and (b) AlignOrientation's target
-- heading, via its own rotation.
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

-- horizontal locomotion: a VELOCITY servo, not a position servo. It only
-- ever targets a desired velocity (set every frame in stepVelocity
-- below) and never references any position, so there's nothing here to
-- drag the body back toward after a shove — see the config comment above.
-- WALK_MAX_FORCE alone is a flat cap tuned against a typical-size
-- mimic's mass — see WALK_FORCE_SAFETY's own comment above for why that
-- silently stops being enough to brake a big enough mimic's own
-- momentum, the same way STAND_MAX_FORCE alone stopped being enough to
-- lift one against gravity. Taking the larger of the flat cap and
-- (actual mass * MOVE_ACCEL * WALK_FORCE_SAFETY) leaves small mimics
-- untouched (the flat cap already clears what MOVE_ACCEL demands of
-- their mass by a wide margin) while guaranteeing a big one can still
-- always actually decelerate as fast as its own walk controller asks.
local walkMaxForce = math.max(WALK_MAX_FORCE, mimic.AssemblyMass * MOVE_ACCEL * WALK_FORCE_SAFETY)

local walkVelocity = Instance.new("LinearVelocity")
walkVelocity.Name = "MimicWalkVelocity"
walkVelocity.Attachment0 = mimicAttachment
walkVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
walkVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
walkVelocity.ForceLimitsEnabled = true
walkVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
walkVelocity.MaxAxesForce = Vector3.new(walkMaxForce, 0, walkMaxForce) -- zero on Y: this constraint never touches vertical velocity — that's the height servo's job alone, so it doesn't fight gravity/falling
walkVelocity.VectorVelocity = Vector3.new(0, 0, 0)
walkVelocity.Parent = mimic

-- standing height: the one thing still allowed to be a position servo,
-- since "hold itself roughly at leg height above the ground" is a
-- constant job rather than a one-off walk command. Restricted to the Y
-- axis only (MaxAxesForce below) so it has zero opinion about X/Z and
-- can never pull the body sideways back toward anything.
-- STAND_MAX_FORCE is a flat cap, tuned against a typical-size mimic's
-- mass; it silently stopped being enough once actual mass (which grows
-- with bodySize^3, not bodySize) outgrew whatever that typical mass was
-- — a size-15 mimic's own weight could out-muscle the flat cap outright,
-- so the height servo just lost the tug-of-war against gravity and the
-- body never left its settled, freshly-landed height. Taking the larger
-- of the flat cap and (actual weight * STAND_FORCE_SAFETY) leaves small
-- mimics untouched (the flat cap already clears their weight by a wide
-- margin) while guaranteeing a big one can still always lift itself.
local standForce = math.max(STAND_MAX_FORCE, mimic.AssemblyMass * WS.Gravity * STAND_FORCE_SAFETY)

local alignPos = Instance.new("AlignPosition")
alignPos.Name = "MimicAlignPosition"
alignPos.Attachment0 = mimicAttachment
alignPos.Attachment1 = moverAttachment
alignPos.RigidityEnabled = false
alignPos.ForceLimitMode = Enum.ForceLimitMode.PerAxis
alignPos.MaxAxesForce = Vector3.new(0, standForce, 0)
alignPos.ForceRelativeTo = Enum.ActuatorRelativeTo.World -- explicit: the Y-only force limit above must mean WORLD up, not the body's own (possibly tilted, mid-stagger) local Y — otherwise a stagger tilts the constrained axis right along with the body
alignPos.Responsiveness = STAND_RESPONSIVENESS
alignPos.Parent = mimic

local alignOrient = Instance.new("AlignOrientation")
alignOrient.Name = "MimicAlignOrientation"
alignOrient.Attachment0 = mimicAttachment
alignOrient.Attachment1 = moverAttachment
alignOrient.RigidityEnabled = false
alignOrient.MaxTorque = ORIENT_MAX_TORQUE
alignOrient.Responsiveness = ORIENT_RESPONSIVENESS -- overridden per-frame in updateBalance while isKnocked() is true
alignOrient.Parent = mimic

-- BombFuse's revertMimic (see this script's header) already tears down
-- the display/name/physics it knows about when it flips MimicActive
-- false, but it doesn't know about the mover/Align setup added here —
-- without this, they'd keep quietly tugging the revived ball toward
-- wherever the mover last was. Runs independently of wherever the rest
-- of the script happens to be (idle pause, mid-walk, mid-eat), so it
-- doesn't depend on catching every early-return path.
--
-- This is also the one place both ways MimicActive can ever go false —
-- BombFuse's revertMimic, or this script's own off-platform revert
-- below — funnel through, so it's the right spot to fire the "converts
-- back into a regular ball" sound cue exactly once regardless of which
-- path triggered it, rather than duplicating the fire call in both.
task.spawn(function()
	while mimic:GetAttribute("MimicActive") do
		RS.Heartbeat:Wait()
	end
	se:FireAllClients("attached", mimic, REVERT_SOUND) -- see "config: sound" above
	alignPos.Enabled, alignOrient.Enabled, walkVelocity.Enabled = false, false, false
	mover:Destroy()
end)

-- keeps the "past the platform radius reverts to a normal ball" rule in
-- force for this mimic's ENTIRE life, not just before it wakes:
-- stillAsleep() above already cancels a wake attempt once a dormant
-- mimic drifts beyond MIMIC_MAX_RADIUS, but that check only ever runs
-- pre-wake. An AWAKE mimic is real, unanchored, physics-simulated body —
-- it can be shoved arbitrarily far by other balls/mimics colliding with
-- it, and WORLD_BOUND_RADIUS (see "config: wander/hunt") only clamps
-- where THIS script is willing to aim its OWN wander/hunt targets; it
-- does nothing to stop an external shove from carrying the real body
-- past that clamp. Without a standing watch here, a bumped mimic could
-- end up sitting well outside the platform, fully awake, forever.
--
-- Reverting is done by hand here rather than through BombFuse's
-- revertMimic (the only OTHER thing that ever flips MimicActive false —
-- see this script's header): revertMimic is what a bomb's fuse reaches
-- for, tied to that specific trigger. Going past the platform edge is a
-- different trigger with the same end state, so this mirrors the same
-- three effects a caller can observe from outside this script — name
-- reverted to a real, sellable ball, the "??" display swapped back to
-- showing its size, and MimicActive flipped false — and the flip itself
-- is what tears down everything else: the watcher just above releases
-- the mover/Align constraints, and MimicLegsClient independently watches
-- MimicActive on each client to destroy its own local legs.
task.spawn(function()
	while mimic:GetAttribute("MimicActive") do
		local pos = mimic.Position
		if Vector3.new(pos.X, 0, pos.Z).Magnitude > MIMIC_MAX_RADIUS then
			mimic.Name = ballT.Name
			local display = mimic:FindFirstChild("display")
			local label = display and display:FindFirstChild("numDisplay")
			if label then
				label.Text = tostring(math.floor(bodySize + 0.5))
			end
			mimic:SetAttribute("MimicActive", false)
			return
		end
		RS.Heartbeat:Wait()
	end
end)

-- ── legs sprout ─────────────────────────────────────────────────────
-- the body stays put at its physics-settled height for LEGS_SPROUT_TIME
-- while MimicLegsClient grows its legs out client-side, one after
-- another (see that script's own sprout section). This script does
-- nothing to the mover here on purpose — it's just left wherever it was
-- set right after wake-up (mover.CFrame = mimic.CFrame, above), so
-- AlignPosition holds the body still through the whole sprout instead
-- of rising while legs are still stretching out from stubs.
do
	local t = 0
	while t < LEGS_SPROUT_TIME do
		if not mimic:GetAttribute("MimicActive") then return end
		t += RS.Heartbeat:Wait()
	end
end

-- ── push-up ─────────────────────────────────────────────────────────
-- now that every leg has finished sprouting, the body rises onto them
-- rather than teleporting: over BODY_RISE_TIME it climbs from its
-- original physics-settled height up to standing height. Nothing here
-- needs to coordinate this pace with MimicLegsClient — its per-frame
-- foot IK tracks the ground under the hip regardless of how fast the
-- hip actually rises, so the two just naturally read as the body
-- pushing itself up on already-planted legs.
se:FireAllClients("flatPitched", WAKE_ALARM_SOUND, WAKE_ALARM_VOLUME) -- see "config: sound" above — fired here, at the start of the actual rise, rather than at the instant MimicActive first went true (which is still LEGS_SPROUT_TIME away from anything visibly happening)
do
	local restY = mimic.Position.Y
	local t = 0
	while t < BODY_RISE_TIME do
		if not mimic:GetAttribute("MimicActive") then return end
		local dt = RS.Heartbeat:Wait()
		t = math.min(t + dt, BODY_RISE_TIME)
		local alpha = 1 - (1 - t / BODY_RISE_TIME) ^ 2 -- ease-out

		-- moves the MOVER; AlignPosition pulls the real, unanchored body
		-- up to follow it, rather than teleporting the body directly
		mover.CFrame = CFrame.new(wakePos.X, restY + (bodyY - restY) * alpha, wakePos.Z)
	end
end

-- ── movement ────────────────────────────────────────────────────────
-- the body is unanchored (see the wake-up section above) and pulled
-- toward the `mover` part by the Align constraints created there —
-- everything below only ever moves `mover`, never mimic.CFrame
-- directly. Two things keep this from reading as robotic: `velocity`
-- is a smoothed heading/speed that's only allowed to change by
-- MOVE_ACCEL per second, so starting, stopping, and switching targets
-- ease in/out instead of snapping onto a new direction; and moveTo
-- below layers slow drifting noise onto both heading and speed, so a
-- walk curves and wavers on its way to a target instead of beelining
-- at a dead-constant pace.
local heading = 0 -- radians around Y; only ever changed by stepVelocity below
local velocity = Vector3.new(0, 0, 0) -- current eased XZ ground velocity; persists across moveTo calls and idle pauses so momentum carries through instead of resetting each time
-- MOVE_ACCEL itself now lives up in the "config: physics-driven
-- movement" section, alongside WALK_MAX_FORCE/WALK_FORCE_SAFETY — see
-- the comment there for why it had to move.
local noiseSeed = math.random() * 1000 -- unique per mimic, so multiple mimics wandering at once don't drift in lockstep
local ARRIVE_STOP_MARGIN = 1.2 -- safety multiplier over the physically-required braking distance, so discrete-frame stepping doesn't eat into the margin and cause a last-second overshoot anyway
local ARRIVE_BRAKE_INSET = 1.5 -- studs INSIDE the arrival ring that the braking curve actually aims to reach zero velocity at, rather than aiming for the ring itself. Braking to exactly zero exactly ON the ring (dist == arriveDist) used to mean desiredVel decayed to ~0 right as dist approached arriveDist — velocity dropped under the 0.5 "arrived" threshold a frame or two before dist actually dropped under arriveDist, and once velocity's near-zero the (distance-proportional) desiredVel is near-zero too, so it never closed that last sliver of distance: the mimic would visibly stop just outside eating range and sit there forever. Aiming the brake at a point inset INSIDE the ring instead guarantees there's still real forward velocity left at the moment dist actually crosses under arriveDist, so the "arrived" check reliably fires instead of stalling on the boundary. ONLY actually applied for requireStop=false callers (see moveTo below) — that's the one case this was written for (eat()'s chase, arriveDist=EAT_OVERLAP_DIST=1); a requireStop=true walker still needs `velocity` to genuinely decay near the ring itself, not past it, or it never satisfies its own "and velocity < 0.5" arrival clause and just orbits the target instead.

-- true whenever the body currently reads as knocked off balance —
-- either tipped past RECOVERY_TILT_THRESHOLD, or its ACTUAL velocity has
-- pulled away from the walk controller's INTENDED velocity (`velocity`
-- above) by more than RECOVERY_VELOCITY_THRESHOLD. The velocity check is
-- what catches a shove along flat ground that never tips the body at
-- all — a hit can knock it sideways without unbalancing it visually.
local function isKnocked()
	local tiltDot = math.clamp(mimic.CFrame.UpVector:Dot(Vector3.new(0, 1, 0)), -1, 1)
	local tiltAngle = math.acos(tiltDot)
	local actualVel = mimic.AssemblyLinearVelocity
	local velMismatch = (Vector3.new(actualVel.X, 0, actualVel.Z) - velocity).Magnitude
	return tiltAngle > RECOVERY_TILT_THRESHOLD or velMismatch > RECOVERY_VELOCITY_THRESHOLD
end

-- the one piece of "reacting to being pushed" that's real physics, not
-- cosmetic: sharpens AlignOrientation's self-righting pull while knocked
-- off balance, instead of leaving it at the calm baseline the whole
-- time. Called every frame from the movement loops below in place of
-- what used to be the leg-stepping update.
local function updateBalance(dt)
	local knocked = isKnocked()
	alignOrient.Responsiveness = knocked and ORIENT_RECOVERY_RESPONSIVENESS or ORIENT_RESPONSIVENESS
end

-- eases `velocity` toward desiredVel (capped by MOVE_ACCEL) and feeds it
-- straight to the walkVelocity servo for this frame — the real body's
-- actual velocity is only ever nudged toward this by walkVelocity's
-- capped force, never snapped or position-corrected onto it, which is
-- what leaves room for a shove to actually move the body (see the
-- "config: physics-driven movement" comment above). Heading follows the
-- intended travel direction once moving fast enough for that to be
-- meaningful, rather than snapping to face wherever the target happens
-- to be; it still only feeds AlignOrientation's target via the mover's
-- rotation, same as before.
-- accel (optional): overrides MOVE_ACCEL for this call's easing rate.
-- Every caller except eat()'s post-commit stop leaves this nil and gets
-- ordinary walking-speed easing; that one case wants a sharper ramp
-- down to zero than normal walking would give (see EAT_STOP_ACCEL's own
-- comment), without needing a second copy of this whole function.
local function stepVelocity(desiredVel, dt, accel)
	local delta = desiredVel - velocity
	local maxDelta = (accel or MOVE_ACCEL) * dt
	if delta.Magnitude > maxDelta then
		delta = delta.Unit * maxDelta
	end
	velocity += delta

	if velocity.Magnitude > 0.05 then
		-- negated: atan2(velocity.X, velocity.Z) points CFrame.Angles(0, heading, 0)'s
		-- LookVector 180° opposite the travel direction, which is what read as the
		-- mimic (body AND legs, since MimicLegsClient derives its CFrame from this
		-- every frame) walking backwards
		local desiredHeading = math.atan2(-velocity.X, -velocity.Z)
		local diff = (desiredHeading - heading + math.pi) % (2 * math.pi) - math.pi -- shortest signed turn
		heading += math.clamp(diff, -TURN_SPEED * dt, TURN_SPEED * dt)
	end

	walkVelocity.VectorVelocity = Vector3.new(velocity.X, 0, velocity.Z)

	-- Y re-sampled from the ground under the body's CURRENT position
	-- every frame (not the fixed wake-up bodyY) — see groundYAt's
	-- comment above for why. AlignPosition is what actually carries the
	-- real body there; this only ever moves the scripted target.
	local pos = mimic.Position
	local standY = groundYAt(pos.X, pos.Z) + STAND_HEIGHT
	mover.CFrame = CFrame.new(mover.Position.X, standY, mover.Position.Z) * CFrame.Angles(0, heading, 0)
end

-- pulls a position back onto the WORLD_BOUND_RADIUS circle (in the XZ
-- plane, centered on the world origin) if it lies beyond it — applied
-- to every wander/hunt target below so nothing this script sends the
-- mimic to can end up farther out than that, regardless of wander
-- radius, wake position, or prey location
local function clampToWorldBounds(pos)
	local fromOrigin = Vector3.new(pos.X, 0, pos.Z)
	if fromOrigin.Magnitude <= WORLD_BOUND_RADIUS then return pos end
	local clamped = fromOrigin.Unit * WORLD_BOUND_RADIUS
	return Vector3.new(clamped.X, pos.Y, clamped.Z)
end

local function randomWanderTarget()
	local angle = math.random() * 2 * math.pi
	local dist = math.random() * WANDER_RADIUS
	return clampToWorldBounds(Vector3.new(wakePos.X + math.cos(angle) * dist, bodyY, wakePos.Z + math.sin(angle) * dist))
end

-- smaller, live, non-mid-sale regular balls within HUNT_RADIUS AND
-- within WORLD_BOUND_RADIUS of the origin — same criteria
-- SellService.sellWithHighlight/collapseSell already respect
-- (Split/PendingSell/Sold excluded), plus the size/distance checks this
-- is for. Picks randomly among whatever qualifies rather than always
-- the nearest, so a mimic's hunting doesn't read as too mechanically
-- optimal.
--
-- A radiant ball (IsRadiant attribute — see BallManager) is never a
-- candidate — a mimic doesn't target or absorb radiant balls at all,
-- full stop. Checked alongside the size/distance cutoffs rather than
-- folded into the totalViable count above it: totalViable is about
-- whether the board still has A ball left for players at all, and a
-- radiant ball sitting there untouched by every mimic still counts
-- toward that, so it stays counted there even though it can never
-- itself become a candidate here.
--
-- Also refuses to hunt AT ALL once the board has one or zero eatable
-- balls left on it — totalViable counts every live, non-mid-sale
-- regular ball anywhere on the board, not just the ones within THIS
-- mimic's HUNT_RADIUS/size cutoff, since the rule is about not
-- extinguishing the board's last ball, not about this mimic's own
-- reach. Without this, a mimic left alone with the one remaining ball
-- would just amble over and eat it, leaving nothing on the board for
-- anyone to sell.
local function findPrey()
	local myPos = mimic.Position
	local totalViable = 0
	local candidates = {}
	for _, obj in ipairs(folder:GetChildren()) do
		if obj ~= mimic and obj:IsA("BasePart") and obj.Name == ballT.Name
			and not obj:GetAttribute("Split") and not obj:GetAttribute("PendingSell") and not obj:GetAttribute("Sold") then
			totalViable += 1
			local theirSize = obj:GetAttribute("TargetSize") or obj.Size.X
			local distFromOrigin = Vector3.new(obj.Position.X, 0, obj.Position.Z).Magnitude
			if not obj:GetAttribute("IsRadiant") and theirSize < bodySize and (obj.Position - myPos).Magnitude <= HUNT_RADIUS and distFromOrigin <= WORLD_BOUND_RADIUS then
				table.insert(candidates, obj)
			end
		end
	end
	if totalViable <= 1 or #candidates == 0 then return nil end
	return candidates[math.random(1, #candidates)]
end

-- walks the body toward target at speed, easing velocity and heading
-- toward it every Heartbeat (see stepVelocity above), until it's within
-- half a stud and has slowed to a near-stop. Returns false (without
-- finishing the walk) the instant MimicActive goes false — e.g. a bomb
-- defused this mimic mid-stride — so every caller below can just check
-- the return value instead of separately re-checking the attribute
-- themselves.
--
-- `target` is either a fixed Vector3 (wander/idle targets, which really
-- are just a fixed point) or a function that returns a fresh Vector3
-- (or nil) each frame — eat() below passes a function so the chase
-- keeps re-aiming at the prey's actual current position every frame
-- instead of the spot it happened to be standing in when the chase
-- started. A live target function returning nil means it's no longer
-- valid (sold, absorbed by something else, etc.) and ends the walk the
-- same way MimicActive going false does.
--
-- noiseScale (default 1) dials how much organic wander/waver gets
-- layered onto the straight line to the target — eat() below passes a
-- smaller value so a hunt still reads as more purposeful than an amble.
--
-- arriveDist (default 0.5, but no current caller actually relies on the
-- default — see ARRIVE_DIST_PER_SIZE's own comment for why a flat 0.5
-- read as overshoot-and-turn-around) is how close to `target`'s exact
-- position counts as "arrived". Wandering passes ARRIVE_DIST, scaled to
-- this mimic's own size/speed/momentum — eat() below passes
-- EAT_OVERLAP_DIST, a small but nonzero center-to-center distance, safe
-- to actually reach now that collision against the targeted prey is
-- disabled (see the collision-group setup near the top of the file) —
-- the old collision-limited standoff distance is gone.
--
-- requireStop (default true): also requires the WALK CONTROLLER's own
-- commanded velocity (not real physics velocity) to have eased under 0.5
-- before counting as arrived — good for wandering, where there's no rush
-- and a natural glide-to-a-stop looks better than snapping still. eat()
-- below passes false, since prey is a live, real physics ball that's
-- never perfectly stationary (it's still rolling slightly, or getting
-- jostled by other balls elsewhere on the board), and eat() also layers a
-- little noise/waver onto the chase — either of those can keep
-- re-nudging the commanded velocity just enough that it never actually
-- settles under 0.5 even once position has genuinely converged, which
-- would stall the chase forever a hair short of "arrived".
-- This does NOT skip the braking taper below (see arriveScale) — that
-- taper applies to every caller, chase included. It's the only thing
-- actually decelerating the real, physics-simulated body on approach;
-- eat()'s own explicit velocity-zeroing on commit only stops the WALK
-- CONTROLLER from asking for more speed; it does nothing about whatever
-- momentum the real body already has. Skipping the taper for the chase
-- let the body hit EAT_OVERLAP_DIST still carrying full CHASE_SPEED, and
-- that momentum then carried it clean past/around the prey while the
-- (now-zeroed) walk force slowly fought it back down — read as the mimic
-- circling its prey for a while instead of catching it.
-- interrupt (optional): a function(dt) polled every frame, same cadence as
-- everything else in this loop. Returning true stops the walk early — same
-- codepath as MimicActive going false, i.e. this returns false without
-- finishing. Only the wander leg in the main loop below passes one (to
-- re-check findPrey mid-walk instead of only before a wander leg starts);
-- eat()'s chase leaves it nil since that's already a live per-frame target
-- with its own validity check baked into livePreyPos.
local elapsedWalkTime = 0 -- free-running clock feeding the noise below; never resets, so consecutive moveTo calls don't all start wandering from the same phase
local function moveTo(target, speed, noiseScale, arriveDist, requireStop, interrupt)
	noiseScale = noiseScale or 1
	arriveDist = arriveDist or 0.5
	if requireStop == nil then requireStop = true end
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

		-- reads the body's real (physics-simulated) position, not the
		-- mover's — the mover no longer tracks horizontal position at
		-- all (see stepVelocity above), and using the real position here
		-- is what makes a shove actually change the walk: the next frame
		-- re-aims from wherever the body really ended up, rather than
		-- from an imaginary un-shoved track
		local pos = mimic.Position
		local toTarget = Vector3.new(targetPos.X - pos.X, 0, targetPos.Z - pos.Z)
		local dist = toTarget.Magnitude
		if dist < arriveDist and (not requireStop or velocity.Magnitude < 0.5) then
			return true
		end

		-- desired speed is capped at whatever speed the body could still be
		-- doing right now and still brake to ~0 by the time it reaches the
		-- arrival ring, decelerating at up to MOVE_ACCEL — standard "arrival"
		-- steering (speedCap = sqrt(2*accel*distance)), not speed scaled
		-- linearly against some fixed radius. That distinction fixes two
		-- different failures a fixed-radius version hit. Sizing a fixed
		-- radius to always brake safely from top `speed` makes it huge —
		-- comparable to the whole HUNT_RADIUS at CHASE_SPEED — so a chase
		-- spent nearly its entire approach throttled down proportionally to
		-- remaining distance; against prey that's drifting even a little,
		-- that throttled speed can match the prey's own speed well before
		-- actually catching it, and the gap just stops closing — read as
		-- the mimic getting stuck trailing a slow-rolling ball instead of
		-- catching it. Sizing the cap off the body's CURRENT speed instead
		-- of top `speed` avoids that: the cap only bites once stopping
		-- distance and remaining distance are actually comparable, which is
		-- a much smaller zone in practice, while still always being just
		-- tight enough to prevent overshoot — the actual reason braking
		-- exists — regardless of how fast the body happens to be going.
		-- Measured from a point ARRIVE_BRAKE_INSET studs INSIDE the
		-- arriveDist ring rather than the ring itself: braking to exactly 0
		-- exactly ON the ring leaves no velocity budget to actually cross
		-- it, so the mimic can stall just outside eating range forever.
		-- Insetting the aim point keeps a little velocity left over right as
		-- dist crosses under arriveDist.
		-- The inset only ever gets applied for callers that DON'T require a
		-- full stop (requireStop=false — i.e. eat()'s chase, the one case
		-- ARRIVE_BRAKE_INSET was actually introduced for). For a
		-- requireStop=true walker (every ordinary wander/idle target,
		-- default arriveDist=0.5), `arriveDist - ARRIVE_BRAKE_INSET` is
		-- negative (0.5 - 1.5), and the old math.max(..., 0) clamp forced
		-- brakeTarget to 0 instead of letting it go negative — which
		-- doesn't restore the pre-inset behavior, it makes it worse:
		-- distToRing collapses to plain `dist`, so stopSpeedCap (and thus
		-- `velocity`) only reaches ~0 once dist itself is within a
		-- fraction of a stud of the EXACT target position, not the
		-- arriveDist ring. Between heading noise and discrete-frame
		-- stepping, the body could get close but essentially never land
		-- inside that sliver — so requireStop's "velocity < 0.5" half of
		-- the arrival check never passed, and the mimic just orbited the
		-- target forever instead of ever counting as arrived. Using
		-- brakeTarget = arriveDist directly for requireStop=true walkers
		-- restores the simple, correct behavior: velocity decays to ~0
		-- right as dist crosses the arriveDist ring, same as before
		-- ARRIVE_BRAKE_INSET existed.
		local brakeTarget = requireStop and arriveDist or (arriveDist - ARRIVE_BRAKE_INSET)
		local distToRing = math.max(dist - brakeTarget, 0)
		local stopSpeedCap = math.sqrt(2 * MOVE_ACCEL * distToRing / ARRIVE_STOP_MARGIN)
		local arriveScale = math.min(stopSpeedCap / speed, 1) -- tapers speed down on approach instead of walking at full speed right up to a dead stop

		-- organic path: nudges the straight-line heading with slow,
		-- drifting Perlin noise so the walk curves and wavers instead of
		-- beelining with laser precision, and lets pace waver a little
		-- too instead of holding one dead-constant speed. Both fade out
		-- via arriveScale on approach, so a wandering path still actually
		-- arrives at the target instead of orbiting it.
		local headingNoise = math.noise(elapsedWalkTime * WANDER_NOISE_FREQ, noiseSeed) * WANDER_NOISE_STRENGTH * arriveScale * noiseScale
		-- arriveScale factored in here too now — this wasn't fading out on
		-- approach before, even though the comment above always claimed
		-- both did. speedNoise could add up to +25% on top of whatever
		-- arriveScale had just capped desiredVel down to, right as the
		-- braking curve was trying to bring it to zero — that leftover
		-- speed is what carried the body past the target before it had to
		-- turn back and correct, i.e. the walk-up-and-overshoot look.
		local speedNoise = 1 + SPEED_VARIATION * noiseScale * arriveScale * math.noise(elapsedWalkTime * SPEED_NOISE_FREQ, noiseSeed + 100)

		local dir = dist > 0.01 and (CFrame.Angles(0, headingNoise, 0) * toTarget.Unit) or Vector3.new(0, 0, 0)
		local desiredVel = dist > 0.01 and (dir * speed * arriveScale * speedNoise) or Vector3.new(0, 0, 0)
		stepVelocity(desiredVel, dt)
		updateBalance(dt)
	end
end

-- chases prey down, floats it up into the body in time with SellService's
-- own magenta fade-in, and lets SellService.mimicAbsorb handle the actual
-- payout/broadcast/destroy. Bails out cleanly (no float-up, no absorb)
-- if prey stops being valid at any point along the way — sold by a
-- player, knocked off, claimed by another mimic (should there ever be
-- more than one loose at once), or this mimic itself gets defused
-- mid-chase.
local function eat(prey)
	-- prey goes into CG.MimicPrey for the duration of this hunt, so
	-- the mimic's body can walk its own center right up over the prey's
	-- instead of standing distance stopping at their combined collision
	-- radius (see the collision-group setup near the top of the file).
	-- Every exit below except a successful absorb (which destroys prey
	-- outright — nothing left to restore) routes through abort(), so a
	-- chase that gets cut short never leaves a still-alive ball
	-- permanently unable to collide with its hunter.
	local originalPreyGroup = prey.CollisionGroup
	prey.CollisionGroup = CG.MimicPrey
	huntedPreyValue.Value = prey -- lets MimicLegsClient exclude this ball from foot-placement raycasts too — see its own declaration above

	-- groundYAt's raycast is meant for genuine terrain (stepping up over a
	-- crate/ledge) — it wasn't excluding the hunted prey itself, so as the
	-- chase's XZ converges onto the prey, that same raycast starts landing
	-- on the TOP of the prey ball and the height servo auto-lifts the body
	-- up onto it as if it were ground. That's the wrong kind of "moving up
	-- to meet something below it" — standing height should track real
	-- terrain only. Excluding prey here for the hunt's duration keeps the
	-- body at its genuine standing height throughout the chase and the eat
	-- that follows, instead of the body itself climbing up onto the prey.
	groundRayParams.FilterDescendantsInstances = { mimic, prey }

	local function abort()
		groundRayParams.FilterDescendantsInstances = { mimic }
		huntedPreyValue.Value = nil
		if prey.Parent then
			prey.CollisionGroup = originalPreyGroup
		end
		return
	end

	-- a live target function, not a one-time snapshot of prey.Position:
	-- prey is a real physics-simulated ball and can keep rolling/getting
	-- bumped while it's being chased, so re-reading its position every
	-- frame is what actually lets the mimic catch it instead of
	-- beelining for wherever it happened to be standing when the chase
	-- started and then giving up once it arrives at that now-stale spot.
	-- Also doubles as the mid-chase validity check: it goes nil (ending
	-- the chase) the moment the prey stops being a fair target, same
	-- criteria used everywhere else here.
	local function livePreyPos()
		if prey.Parent ~= folder or prey:GetAttribute("PendingSell") then return nil end
		return prey.Position
	end

	-- requireStop=false: prey is a live target that's rarely ever
	-- perfectly still, and the noiseScale=0.4 waver below adds its own
	-- small perpetual correction on top of that — either can keep the
	-- walk controller's commanded velocity from ever settling under 0.5
	-- even once position has genuinely converged, which used to stall
	-- the chase a hair short of "arrived" forever. Arriving on position
	-- alone is fine here because the very next lines explicitly zero
	-- velocity themselves the moment the chase commits, rather than
	-- waiting on it to ease down naturally (see moveTo's own comment).
	if not moveTo(livePreyPos, CHASE_SPEED, 0.4, EAT_OVERLAP_DIST, false) then return abort() end
	if not mimic:GetAttribute("MimicActive") then return abort() end
	if prey.Parent ~= folder or prey:GetAttribute("PendingSell") then return abort() end
	-- horizontal-only, matching moveTo's own arrival criteria — checking
	-- the raw 3D distance here would include the standing-height vertical
	-- gap between the mimic's standing height and the prey ball sitting at
	-- ground level, which is always bigger than this threshold and would
	-- reject every single hunt right after a successful chase
	local delta = prey.Position - mimic.Position
	local horizDist = Vector3.new(delta.X, 0, delta.Z).Magnitude
	if horizDist > EAT_OVERLAP_DIST + 1 then return abort() end -- moveTo's own arrival threshold is generous; re-check for real before committing

	-- eases any residual walk-servo push down to nothing over EAT_STOP_TIME,
	-- rather than killing it outright the instant the hunt commits. Without
	-- SOME cutoff here, whatever velocity the chase last happened to be
	-- carrying keeps being fed to walkVelocity all through the float-up
	-- below (nothing else ever clears it once moveTo's loop stops calling
	-- stepVelocity) — the body would visibly keep sliding off of the ball
	-- instead of settling and staying planted directly over it while it
	-- eats. But snapping `velocity` straight to zero in one frame (the old
	-- behavior) is its own visible glitch the other way: eat()'s chase
	-- deliberately arrives without waiting for velocity to settle (see
	-- moveTo's requireStop=false above), so there's often real leftover
	-- speed right at commit, and killing it instantly reads as the whole
	-- body freezing solid mid-stride the moment it grabs prey. Riding that
	-- same velocity down to zero over a short window instead — at
	-- EAT_STOP_ACCEL, sharper than ordinary walking so it doesn't have
	-- time to drift far — keeps the slide-prevention this was added for
	-- while reading as a quick, smooth stop rather than a freeze.
	do
		local stopT = 0
		while stopT < EAT_STOP_TIME and velocity.Magnitude > 0.05 do
			if not mimic:GetAttribute("MimicActive") then return abort() end
			local dt = RS.Heartbeat:Wait()
			stopT += dt
			stepVelocity(Vector3.new(0, 0, 0), dt, EAT_STOP_ACCEL)
			updateBalance(dt)
		end
	end
	-- explicit final zero as a safety net — guarantees a clean stop even
	-- if the loop above exited on the EAT_STOP_TIME timeout with a sliver
	-- of velocity still above the 0.05 threshold, rather than leaving that
	-- residue to bleed into the float-up below.
	velocity = Vector3.new(0, 0, 0)
	walkVelocity.VectorVelocity = Vector3.new(0, 0, 0)

	local restCF = mover.CFrame -- the scripted target, not the real (possibly still-settling) body CFrame

	-- fired now, not at the end of any animation — its own PRE_SELL_DELAY
	-- fade (== CROUCH_TIME here) is what the float-up loop below is timed
	-- against, same "both land together" reasoning as CROUCH_TIME's own
	-- comment. Prey gets destroyed by this, so its CollisionGroup never
	-- needs restoring past this point.
	task.spawn(SellService.mimicAbsorb, prey)

	-- the body itself no longer crouches down onto prey — the prey rising
	-- up into it already reads clearly as "being eaten" on its own, and
	-- doing both at once looked busier without adding real information.
	-- mover.CFrame is left at restCF the whole time below; only the prey
	-- moves. Anchored here purely so this loop's own CFrame writes are
	-- the only thing moving it for its last moments; it's about to be
	-- destroyed by SellService.mimicAbsorb regardless, so nothing needs
	-- to unanchor it again.
	local preyStartPos = prey.Position
	prey.Anchored = true

	local t = 0
	while t < CROUCH_TIME do
		if not mimic:GetAttribute("MimicActive") then return end
		local dt = RS.Heartbeat:Wait()
		t += dt
		local alpha = math.clamp(t / CROUCH_TIME, 0, 1)
		if prey.Parent then
			prey.CFrame = CFrame.new(preyStartPos:Lerp(mimic.Position, alpha))
		end
		updateBalance(dt)
	end

	mover.CFrame = restCF
	groundRayParams.FilterDescendantsInstances = { mimic }
	huntedPreyValue.Value = nil
end

-- ── main loop ───────────────────────────────────────────────────────
while mimic:GetAttribute("MimicActive") do
	-- idle-then-decide pause between wander legs, so it reads as
	-- ambling rather than a nonstop speed-walk
	local idleFor = IDLE_MIN + math.random() * (IDLE_MAX - IDLE_MIN)
	local idleT = 0
	-- rolled once per pause, not re-rolled every frame — a target heading
	-- to ease toward for this whole idle, or nil for an ordinary idle that
	-- just stands still. stepVelocity's own heading update only ever
	-- fires while actually moving (velocity.Magnitude > 0.05), which is
	-- ~0 the whole time here, so it never touches `heading` on its own
	-- during a stationary idle — safe to steer it by hand below.
	local lookHeading = (math.random() < LOOK_AROUND_CHANCE)
		and (heading + (math.random() * 2 - 1) * LOOK_AROUND_MAX_TURN) or nil
	while idleT < idleFor do
		if not mimic:GetAttribute("MimicActive") then return end
		local dt = RS.Heartbeat:Wait()
		idleT += dt
		stepVelocity(Vector3.new(0, 0, 0), dt) -- coasts any leftover momentum to a natural stop rather than snapping still
		if lookHeading then
			local diff = (lookHeading - heading + math.pi) % (2 * math.pi) - math.pi -- shortest signed turn
			heading += math.clamp(diff, -TURN_SPEED * dt, TURN_SPEED * dt)
			-- stepVelocity above already moved the mover to this frame's
			-- standing height using the OLD heading; re-stamp just the
			-- rotation with the value we just turned it to, rather than
			-- waiting a frame for it to catch up.
			mover.CFrame = CFrame.new(mover.Position) * CFrame.Angles(0, heading, 0)
		end
		updateBalance(dt)
	end

	local prey = (math.random() < HUNT_CHANCE) and findPrey() or nil
	if prey then
		eat(prey)
	else
		-- keep re-rolling HUNT_CHANCE/findPrey every HUNT_RECHECK_INTERVAL
		-- while this wander leg is in progress, not just once before it
		-- started — a wander leg can run for several seconds (WANDER_RADIUS
		-- at WALK_SPEED), and without this a ball spawning in, or wandering
		-- into HUNT_RADIUS, mid-leg had to wait for the mimic to finish
		-- ambling to its random destination before it was ever noticed.
		local recheckT = 0
		local foundMidWander = nil
		moveTo(randomWanderTarget(), WALK_SPEED, nil, ARRIVE_DIST, nil, function(dt)
			recheckT += dt
			if recheckT < HUNT_RECHECK_INTERVAL then return false end
			recheckT = 0
			if math.random() < HUNT_CHANCE then
				foundMidWander = findPrey()
			end
			return foundMidWander ~= nil
		end)
		if foundMidWander and mimic:GetAttribute("MimicActive") then
			eat(foundMidWander)
		end
	end
end