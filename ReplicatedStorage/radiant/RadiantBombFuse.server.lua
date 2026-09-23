--[[
    RadiantBombFuse (Script)
    Path: ReplicatedStorage → radiant
    Parent: radiant
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-23 00:26:22
]]
--[[
	RadiantBombFuse (Script) — place in ReplicatedStorage.radiant (NOT
	nested under the Bomb template — this lives alongside RadiantFuse
	and any other radiant behavior script in that shared "radiant"
	folder, rather than loose at the top level of ReplicatedStorage).

	This is the full radiant replacement for BombFuse, not an add-on to
	it: BallManager's applyRadiantOverlay destroys the stock BombFuse a
	radiant bomb was cloned in with (see spawnBomb's own `radiant`
	param) and clones this in instead, so a radiant bomb runs ONLY this
	script, never both. Everything from BombFuse's own header still
	applies conceptually (flicker then detonate, real explosion physics
	vs. cosmetic VFX, board-mimic-only defusing, pet mimics fully
	exempt) — this file duplicates that logic rather than requiring
	BombFuse, so it stays a single self-contained script the same way
	BombFuse is. The four things that actually differ, per the design
	notes:

	  1. Idle tick is BombFuse's own fixed navy OFF, same as a plain
	     bomb — but each flash-tick pops up to a shared, clock-driven
	     RAINBOW hue (see flashRainbow below) instead of BombFuse's fixed
	     red, so only the flash itself cycles color while idle stays
	     identical to a plain bomb. Same on/off cadence PHASES already
	     drives.
	  2. The fuse itself takes 2x as long to burn down: PHASES below
	     doubles both phases' tick COUNTS (not their gap), so the same
	     slow-then-fast cadence just runs twice as many ticks before
	     ever reaching detonation.
	  3. Halfway through the (now-doubled) burn-down, by elapsed time
	     rather than tick count, this pulls every ball on the board
	     toward the bomb. The bomb itself first eases down to size 0
	     (purely cosmetic — pull strength and flash size are both still
	     driven off the bomb's TargetSize, untouched by this), then pops
	     into the pull shine, recolored rainbow instead of MagnetFuse's
	     own red-blue-shine, running right alongside the rest of the
	     fuse (not blocking it) until detonation actually happens. See
	     triggerHalfwayPull.
	  4. explode()'s impulse scales EXPONENTIALLY with size instead of
	     linearly (see radiantImpulseMagnitude) — blast RADIUS is left
	     alone (still RADIUS_PER_SIZE, identical to a plain bomb), so a
	     big radiant bomb reaches exactly as far as a plain one would;
	     it just hits absurdly harder once something's in range.
	  5. Every light tick now also pops Reflectance to 0.5 (back to 0 on
	     the dark tick right after) instead of leaving it flat, so the
	     rainbow flash itself gets a little shinier than the idle navy —
	     same on/off cadence as the color swap, see flicker().
	  6. From the moment the halfway pull actually starts (== the instant
	     its shrink finishes, same moment PULL_START_SND/the shine fire)
	     the bomb itself goes invisible — literally MagnetFuse's own
	     "ball goes invisible, shine is the only visible thing" switch.
	     It stays fully physical throughout, though: rather than dropping
	     CanCollide outright, it moves into its own collision group
	     (PULL_COLLISION_GROUP, == CG.RadiantPull, declared in
	     ReplicatedStorage.CollisionGroups) for the duration, exactly
	     the way an awake splitter/merger does. That group passes through every ball
	     the bomb is pulling in — so it never shoves or depenetrates
	     against them — while staying solid against Default, which is the
	     platform and the players. So the collapsing bomb keeps its
	     weight and can still be pushed around right up until it goes
	     off.
	     Keeping it physical is only safe because the shrink no longer
	     runs all the way to a degenerate collision shape — see
	     PULL_MIN_SIZE and the constant-mass density ramp below, which is
	     what actually stops a near-point sphere from spazzing out.
	     Gravity IS cancelled, but only from the moment the pull actually
	     starts -- not during the shrink that telegraphs it, where the
	     bomb is still a perfectly ordinary part sitting on the platform
	     -- and not as a way of hiding the tiny-and-erratic problem
	     above. Instead of hanging motionless it gets an upward thrust
	     against linear air drag, so it eases up to a rise speed and
	     floats off the platform, hauling the whole board of balls up
	     after it until it detonates in midair. That thrust (gravity
	     cancellation included) starts at 0 the instant the float begins
	     and climbs exponentially to its target maximum over
	     LIFT_RAMP_TIME, rather than snapping straight to full strength
	     on the first frame; and the target maximum itself -- both the
	     rise speed and the force used to reach it -- scales with this
	     bomb's own size and density (linearly, then clamped -- see
	     LIFT_SCALE_MIN/MAX), so bigger/denser radiant bombs float up
	     proportionally harder than smaller/lighter ones instead of
	     every bomb sharing one fixed rise speed, without an outlier
	     size ever flinging one violently. See PULL_RISE_SPEED/
	     PULL_DRAG/LIFT_RAMP_TIME/LIFT_SCALE_MIN/MAX and applyLift.
	  7. The pull's own shine now also pops in oversized and eases down to
	     its normal size, then eases back down to size 0 at the very end —
	     same shape as MagnetFuse's own SHINE_ENTRANCE/SHINE_EXIT. The
	     exit half is timed off a computed pullDuration (elapsed time from
	     "pull starts" to the fuse's own nominal detonation instant)
	     rather than a fixed self-destruct clock, since unlike a magnet
	     this bomb doesn't own its own end-of-pull timer — flicker() hits
	     zero on the fuse independently and explode() is what actually
	     ends things. See triggerHalfwayPull's pullDuration param and
	     PULL_SHINE_EXIT_TIME.
	  8. FLICKER_SND's playback speed ramps up exponentially to 2x over
	     the final TICK_SPEEDUP_WINDOW seconds before detonation (see the
	     pitch calc in flicker()), instead of playing flat throughout.

	Sell price (6x instead of a plain bomb's 2x, once "defuser" is
	owned) lives in SellService, not here — see its
	RADIANT_BOMB_SELL_MULTIPLIER, keyed off the same IsRadiant
	attribute BallManager's applyRadiantOverlay sets.

	Sell COLOR (the highlight/flash a radiant bomb sells with) also
	lives in SellService, not here — but since bomb.Color itself spends
	roughly half its time on the flat OFF navy between ticks (see
	flicker()), this script keeps a RadiantFlashColor attribute mirroring
	flashRainbow(litAccum) — the flash tick's own rainbow hue, and
	nothing else — so SellService always has a genuinely rainbow color
	to read regardless of which tick this bomb happens to be sold on.
]]

local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local TS = game:GetService("TweenService")
local RS = game:GetService("RunService")

local bomb = script.Parent
local folder = bomb.Parent -- already parented into Workspace.Balls by BallManager

local ballT = Rep:WaitForChild("Ball") -- what a defused mimic gets renamed to, below, and what every pullable ball is named (radiant balls included — Name stays ballT.Name under the overlay model)

-- the RadiantPull group, and every rule about what it passes through,
-- is declared in ReplicatedStorage.CollisionGroups — see
-- setPullCollisionGroup below
local CG = require(Rep:WaitForChild("CollisionGroups"))

-- ── rainbow color loops ─────────────────────────────────────────────
-- Only the LIGHT tick still cycles rainbow (used by flicker's on-tick,
-- the halfway pull's shine, and the explosion VFX/flash). The dark/idle
-- tick is no longer part of the rainbow at all -- it's just BombFuse's
-- own fixed OFF navy, so a radiant bomb reads exactly like a plain one
-- between flickers and only shows color on the flash.
--
-- Two clocks now, not three:
--   * PULL_HUE_CYCLE_TIME drives the pull shine only, continuously, off
--     the same real-time os.clock() it always has.
--   * FLASH_HUE_CYCLE_TIME drives flicker()'s own flash-tick color, and
--     that same clock (litAccum, below) also drives the explosion VFX
--     ball, so both read the exact same hue at the same moment instead
--     of drifting independently. This clock only advances while the
--     bomb is actually showing a lit (rainbow) tick or the explosion
--     VFX is live, and freezes for the duration of every dark/OFF tick
--     in between, so it doesn't silently cycle ahead while nothing
--     rainbow is even visible. See litAccum.
--
-- Both clocks get the same randomized per-bomb offset baked in (see
-- hueOffset) so every rainbow use on THIS bomb -- flicker's flash tick,
-- the pull shine, and the explosion VFX -- reads the same hue at the
-- same moment as each other, while a different radiant bomb elsewhere
-- on the board (its own random offset) doesn't end up cycling in lockstep
-- with this one.
local PULL_HUE_CYCLE_TIME = 3 -- seconds for one full hue rotation
local FLASH_HUE_CYCLE_TIME = 1.5 -- seconds of *lit* time for one full hue rotation
local LIGHT_V = 1 -- HSV Value for the light/flash end of the cycle
local RAINBOW_S = 1
local OFF = Color3.fromRGB(27, 41, 53) -- same as BombFuse's own OFF -- the dark tick is no longer a rainbow sample

-- rolled once per bomb at script start, so this bomb's whole rainbow
-- cycle (flash tick, pull shine, explosion VFX) starts at a random point
-- in the hue wheel instead of every radiant bomb on the board reading
-- the same color at the same moment
local hueOffset = math.random()

local function hueFromClock(clockValue, cycleTime)
	return ((clockValue % cycleTime) / cycleTime + hueOffset) % 1
end
-- pull billboard shine
local function pullRainbow()
	return Color3.fromHSV(hueFromClock(os.clock(), PULL_HUE_CYCLE_TIME), RAINBOW_S, LIGHT_V)
end
-- flicker's own flash-tick color -- litElapsed is accumulated lit-only
-- time, not os.clock(), so the loop pauses while the tick is OFF
local function flashRainbow(litElapsed)
	return Color3.fromHSV(hueFromClock(litElapsed, FLASH_HUE_CYCLE_TIME), RAINBOW_S, LIGHT_V)
end

-- RadiantFlashColor: mirrors flashRainbow(litAccum) into an attribute
-- every time the flash tick's color is actually computed (see both
-- call sites in flicker() below), so SellService -- or anything else
-- that needs this bomb's rainbow sell color -- has something to read
-- that isn't bomb.Color itself. bomb.Color spends roughly half its
-- time sitting on the flat OFF navy between ticks, which would read
-- as "not rainbow" if this bomb got sold mid-dark-tick. This
-- attribute is only ever written from a lit moment, so it always
-- holds the most recent flash-tick hue rather than ever momentarily
-- going navy itself. Set once up front too, so it's valid from the
-- instant this bomb exists, before flicker() ever ticks.
bomb:SetAttribute("RadiantFlashColor", flashRainbow(0))

-- shared accumulated *lit* time backing flashRainbow -- top-level (not
-- local to flicker()) so the explosion VFX can read the exact same
-- clock flicker() is driving, instead of keeping its own. flicker()
-- owns writing it (ticks it up while a flash tick is lit); vfx() keeps
-- writing it during the explosion so the VFX ball continues the same
-- rotation rather than resetting.
local litAccum = 0

-- tick sound speedup — FLICKER_SND ramps from normal speed up to
-- TICK_SPEEDUP_MAX playback speed, on an exponential curve, over the
-- final TICK_SPEEDUP_WINDOW seconds before detonation (see flicker())
local TICK_SPEEDUP_WINDOW = 2
local TICK_SPEEDUP_MAX = 1.5

-- The final speed-up window uses the same multiplier for both the tick
-- sound PlaybackSpeed and the interval between visual flickers.
local function tickSpeedForRemaining(remaining)
	if remaining >= TICK_SPEEDUP_WINDOW then
		return 1
	end
	local frac = 1 - math.clamp(remaining, 0, TICK_SPEEDUP_WINDOW) / TICK_SPEEDUP_WINDOW
	return TICK_SPEEDUP_MAX ^ frac
end

-- flicker — same slow-then-fast shape as BombFuse's own PHASES, just
-- with both phases' tick COUNTS doubled (not their gap), so the fuse
-- takes exactly 2x as long to burn down at the same on/off cadence a
-- plain bomb flickers at
local PHASES = { { gap = 0.125, n = 32 }, { gap = 0.0625, n = 16 } }

-- real explosion physics — the VFX below is cosmetic only and never
-- touches these. RADIUS_PER_SIZE is identical to a plain bomb's — only
-- the impulse curve diverges, see radiantImpulseMagnitude below
local RADIUS_PER_SIZE, IMPULSE_PER_SIZE = 6, 5000
-- exponential impulse growth per stud above BOMB_SIZE_REF (tune to
-- taste — this is deliberately steep, per "incredibly powerful at
-- large sizes")
local RADIANT_IMPULSE_GROWTH = 1.15
local BOMB_SIZE_REF = 1.5 -- matches a plain bomb's impulse exactly at this size; diverges (exponentially) above/below it

-- VFX: no min/max caps, scales directly (and smaller) with bomb size
local VFX_SCALE, VFX_TIME = 0.5, 0.3
local FLASH_SCALE, FLASH_TIME = 0.6, 0.1
local FLASH_IMAGE = "rbxassetid://131187911056182" -- same asset BombFuse's own flash()/SoundClient's preload use

local FLICKER_SND, FLICKER_VOL = "rbxassetid://12221976", 1
local BOOM_SND, BOOM_VOL = "rbxassetid://120604429155099", 2

-- same RemoteEvent BallManager creates
local se = Rep:WaitForChild("SoundEvents")

-- ── halfway pull config — mirrors MagnetFuse's own pull constants,
-- under this script's own names so the two stay independently tunable ──
-- how long the bomb takes to visually ease down to PULL_MIN_SIZE before
-- the pull shine takes over -- purely cosmetic, see triggerHalfwayPull
local PULL_SHRINK_TIME = 1.5
local PULL_ACCEL = 32 -- pull acceleration per stud of the bomb's (fixed) TargetSize, applied every frame — no distance falloff, same "uniform regardless of distance" shape MagnetFuse's own pull uses

-- ── keeping a collapsing bomb physically sane ──────────────────────
-- The bomb stays collidable (against the platform and players) for the
-- whole pull now, so the old "it's out of physics entirely, nothing can
-- misbehave" escape hatch is gone and the erratic-when-tiny problem has
-- to be solved properly instead. Three things do that, and they're
-- listed in order of how much they actually matter:
--
--   1. PULL_MIN_SIZE — the shrink stops here instead of at literally 0.
--      This is the real fix. A sphere easing toward zero radius is a
--      near-degenerate collision shape, and Roblox's solver resolves
--      penetration on one of those by inventing an enormous separating
--      velocity: one frame of overlap with the floor and the bomb is
--      launched across the map. Below roughly half a stud the solver
--      stops being trustworthy at all, so the shrink simply never goes
--      there. The bomb is set fully transparent the instant the shrink
--      lands anyway, so nothing about this is visible — the ball still
--      reads as having collapsed to a point and vanished.
--   2. The density ramp — mass is held CONSTANT as the bomb shrinks
--      rather than falling off with the cube of its size, by raising
--      density exactly as fast as volume drops (see pullDensityFor).
--      Density starts at the bomb's own normal value, so nothing about
--      how it feels to push changes at the moment the shrink begins;
--      by the time it's at PULL_MIN_SIZE it's as heavy as it was at
--      full size. Heavy things absorb bogus impulses instead of being
--      flung by them, and a player's push still lands the same.
--      PULL_MAX_DENSITY is Roblox's own CustomPhysicalProperties
--      ceiling — a big enough bomb wants more mass than that and just
--      gets clamped, which is fine: 100 density at PULL_MIN_SIZE is
--      already far heavier than anything else on the board.
--   3. The friction/elasticity ramp — friction goes to Roblox's max and
--      elasticity to zero over the same shrink, both with high weights
--      so the bomb's own values dominate whatever it's touching. A tiny
--      dense sphere is a near-frictionless bearing by default; this
--      makes it settle and stay put instead of skittering off across
--      the platform, and stops it bouncing on contact.
local PULL_MIN_SIZE = 0.75 -- studs; the floor the shrink eases to instead of 0
local PULL_MAX_DENSITY = 100 -- Roblox's CustomPhysicalProperties density ceiling
local PULL_FRICTION, PULL_FRICTION_WEIGHT = 2, 100 -- Roblox's own maxima
local PULL_ELASTICITY, PULL_ELASTICITY_WEIGHT = 0, 100 -- dead stop on contact, no bounce
-- collision group the bomb switches into for the whole pull. Declared,
-- along with everything it passes through, in
-- ReplicatedStorage.CollisionGroups; requiring that module is what
-- registers it, so by the time this script runs the group always exists
-- — there is no second copy of this string anywhere left to keep in
-- sync, and no unregistered-group case to fall back from.
local PULL_COLLISION_GROUP = CG.RadiantPull

-- ── floating up ────────────────────────────────────────────────────
-- Gravity is cancelled for the whole pull and replaced with a constant
-- upward thrust working against linear air drag, so the collapsing bomb
-- lifts off the platform and climbs away from it, dragging every ball
-- it's pulling up after it. Both live in the single VectorForce
-- applyLift maintains (see triggerHalfwayPull), which is a constraint
-- the engine simulates as part of its normal physics step on whichever
-- machine already owns the part -- exactly like gravity itself -- so
-- unlike writing AssemblyLinearVelocity from here it never claims
-- network ownership for the server and never stops players pushing the
-- bomb around.
--
-- The two constants are the whole feel of it:
--   * PULL_RISE_SPEED is the terminal rise speed in studs/sec, BEFORE
--     the size/density scaling below is applied -- the thrust and the
--     drag cancel out here, so this (times liftMassScale, see below) is
--     simply how fast a given bomb ends up climbing. Total height
--     gained is roughly this times the time it spends in the pull --
--     which is the fuse's own remaining pullDuration and does NOT
--     include PULL_SHRINK_TIME, since the lift only starts once the
--     shrink has landed. That's a bit under 2.5 seconds at the default
--     PHASES, minus a stud or so for the ramp-up.
--   * PULL_DRAG is the drag coefficient (1/sec): how quickly it reaches
--     that speed, and equally how quickly any push a player lands on it
--     bleeds away. 1/PULL_DRAG is the time constant, so the default
--     settles within about a second.
-- Drag deliberately applies on all three axes, not just Y, so a shove
-- still moves the bomb but doesn't send it sailing off the board.
local PULL_RISE_SPEED = 48
local PULL_DRAG = 2

-- ── liftoff ramp ─────────────────────────────────────────────────────
-- The lift force doesn't snap straight to full strength the instant the
-- pull starts (== the instant startLift() is called, see below) -- it
-- begins at 0 and climbs exponentially toward its target maximum over
-- LIFT_RAMP_TIME, so the very first instant of the float reads as a
-- gentle liftoff (briefly still under roughly normal gravity) rather
-- than an instant snap into full thrust. This is a pure multiplier on
-- the force applyLift already computes -- see rampFrac in applyLift
-- below -- and never touches PULL_DRAG's own separate job of settling
-- the bomb onto PULL_RISE_SPEED.
local LIFT_RAMP_TIME = 1 -- seconds; time constant of the exponential ramp

-- ── size/density scaling ─────────────────────────────────────────────
-- Both the target maximum (PULL_RISE_SPEED) and the force used to reach
-- it scale with THIS bomb's own size and density -- so every radiant
-- bomb floats up proportionally to itself instead of every one sharing
-- one fixed rise speed/force regardless of scale. This is deliberately
-- LINEAR in size and density (see liftMassScale in triggerHalfwayPull),
-- not the bomb's actual mass (which is density * size^3, cubic in
-- size) -- scaling the target speed by real mass compounds with the
-- mass term the force formula already multiplies by, so a modestly
-- bigger bomb ends up with a wildly, explosively large target and gets
-- flung rather than floated. LIFT_SCALE_MIN/MAX then clamp the result,
-- so even an outlier bomb size can't push the multiplier past a sane
-- range. A bomb at BOMB_SIZE_REF with LIFT_REF_DENSITY gets
-- liftMassScale == 1 (identical feel to before this change).
local LIFT_REF_DENSITY = 0.7 -- Roblox's default Plastic density
local LIFT_SCALE_MIN, LIFT_SCALE_MAX = 0.5, 2.5
local PULL_START_SND, PULL_START_VOL, PULL_START_PITCH = "rbxassetid://126727806160402", 1.1, 0.9 -- same asset MagnetFuse's own ACTIVE_SND uses for its pull-start cue
local PULL_SHINE_OSC_MIN, PULL_SHINE_OSC_MAX = 0.9, 1.1 -- same multiples MagnetFuse's own pullShine oscillates between
local PULL_SHINE_OSC_HZ = 8 -- ...at the same rate MagnetFuse's own shine does, for as long as the pull lasts
-- entrance pop — same shape as MagnetFuse's own SHINE_ENTRANCE_START/TIME:
-- the shine pops in oversized and eases down to its normal 1x scale,
-- instead of holding flat at its base size from the first frame
local PULL_SHINE_ENTRANCE_START, PULL_SHINE_ENTRANCE_TIME = 3, 0.5
local PULL_SHINE_ENTRANCE_STYLE = Enum.EasingStyle.Quad
-- exit shrink — same shape as MagnetFuse's own SHINE_EXIT_TIME/STYLE:
-- holds flat (osc still layers on top) until this many seconds remain,
-- then eases 1x -> 0x. Unlike a magnet (which self-destructs exactly at
-- its own SHRINK_TIME), this is timed against a computed pullDuration
-- (see triggerHalfwayPull/flicker()) so it still lands on exactly 0 the
-- instant the fuse's own nominal detonation time hits, rather than the
-- bomb owning a fixed self-contained clock of its own
local PULL_SHINE_EXIT_TIME = 0.5
local PULL_SHINE_EXIT_STYLE = Enum.EasingStyle.Exponential	

-- Keep the pull cue local to this bomb. The Sound is created and primed
-- immediately, so the actual pull transition only needs to restart this
-- existing instance; no SoundEvents round-trip is involved.
local pullSound = Instance.new("Sound")
pullSound.SoundId = PULL_START_SND
pullSound.Volume = PULL_START_VOL
pullSound.PlaybackSpeed = PULL_START_PITCH
pullSound.Parent = bomb

-- Prime the Sound instance without producing an audible cue.
pullSound.Volume = 0
pullSound:Play()
pullSound:Stop()
pullSound.Volume = PULL_START_VOL

-- Same idea for the boom: created and primed immediately (well before
-- detonation) rather than requested fresh via SoundEvents at explode()
-- time, so the asset is already loaded and playback isn't delayed. It's
-- parented to the bomb for now purely so it's primed against a live
-- Instance; explode() below reparents it to its own standalone anchor
-- before the bomb itself is destroyed.
local boomSound = Instance.new("Sound")
boomSound.SoundId = BOOM_SND
boomSound.Volume = BOOM_VOL
boomSound.Parent = bomb

boomSound.Volume = 0
boomSound:Play()
boomSound:Stop()
boomSound.Volume = BOOM_VOL

-- ── stillLive: same shape/reasoning as BombFuse's own — PendingSell is
-- set the instant a sell starts (see SellService.sellWithHighlight) but
-- the bomb isn't actually Destroy()'d until after its highlight fade,
-- so Parent alone isn't enough to know a sell isn't already underway
local function stillLive()
	return bomb.Parent ~= nil and not bomb:GetAttribute("PendingSell")
end

-- ── moves the bomb into PULL_COLLISION_GROUP for the duration of the
-- pull and hands back a function that puts its original group back.
--
-- This used to check IsCollisionGroupRegistered first and, on a miss,
-- fall back to simply dropping CanCollide — because the group was
-- registered by BallManager and this script had no say in whether
-- BallManager actually got there first (or at all). That race no longer
-- exists: requiring ReplicatedStorage.CollisionGroups at the top of this
-- file is what registers the group, so it is always there by the time
-- this runs, and the fallback (which lost exactly the platform/player
-- interaction this whole pull behavior is built around) is gone with it.
-- CG.assign is still used rather than a bare assignment so a genuinely
-- unexpected failure warns instead of erroring out mid-fuse. ──
local function setPullCollisionGroup()
	local originalGroup = bomb.CollisionGroup
	CG.assign(bomb, PULL_COLLISION_GROUP)

	return function()
		if bomb.Parent then
			bomb.CollisionGroup = originalGroup
		end
	end
end

-- ── halfway pull: a shrink-then-pull shape recolored rainbow, fired
-- once (via task.spawn from flicker() below) alongside the rest of the
-- fuse rather than in place of it ──
local function triggerHalfwayPull(size, pullDuration)
	if not stillLive() then return end

	-- The collision group swap happens BEFORE the shrink starts, not
	-- after it finishes. A physically-live sphere colliding with other
	-- balls while its own Size eases down is exactly the kind of
	-- near-degenerate collision shape that can make Roblox's physics
	-- solver blow up -- a bogus velocity spike that flings the part
	-- somewhere random. Since the eventual pull shine and the explode()
	-- VFX/flash both key off bomb.Position, a flung bomb shows up in the
	-- wrong spot. PULL_COLLISION_GROUP takes the shrinking bomb out of
	-- contact with every ball on the board (see the RadiantPull entry in
	-- ReplicatedStorage.CollisionGroups) while leaving it solid against the
	-- platform and the players, which is the interaction worth keeping.
	--
	-- Gravity is left alone for the shrink and only cancelled once the
	-- pull proper begins (see startLift's call site below), and even
	-- then the bomb is never anchored and never has its velocity
	-- written from here -- see the
	-- PULL_RISE_SPEED/PULL_DRAG block up top and applyLift below. A
	-- single VectorForce does all of it: it holds up the bomb's own
	-- weight, adds the thrust that carries it into the air, and supplies
	-- the drag that caps its climb and settles any push a player lands
	-- on it. The "gets erratic once it's tiny" problem is handled
	-- separately, on its own merits, by PULL_MIN_SIZE and the
	-- constant-mass/high-friction ramp below (see their comments) --
	-- floating is a deliberate effect here, not a workaround for it.
	local restorePhysics = setPullCollisionGroup()

	-- baseProps/baseMass are captured here, at full size, so the ramp
	-- below starts from exactly the values the bomb already had. baseMass
	-- drops the sphere-volume constant (4/3 * pi / 8) since it cancels
	-- out on both sides of pullDensityFor's division -- what's tracked is
	-- density * size^3, which is proportional to real mass and all the
	-- ratio needs.
	local baseProps = bomb.CurrentPhysicalProperties
	local baseMass = baseProps.Density * (size ^ 3)

	-- how hard THIS bomb floats, relative to a bomb at BOMB_SIZE_REF /
	-- LIFT_REF_DENSITY -- see that comment up top for why this is
	-- linear in size and density rather than baseMass (real mass,
	-- cubic in size). Read by applyLift below to scale both the target
	-- rise speed and the force used to reach it.
	local liftMassScale = math.clamp(
		(size / BOMB_SIZE_REF) * (baseProps.Density / LIFT_REF_DENSITY),
		LIFT_SCALE_MIN, LIFT_SCALE_MAX)

	-- density that keeps the bomb's mass at baseMass for a given current
	-- size: at currentSize == size this returns baseProps.Density
	-- unchanged, and it climbs cubically from there as the bomb collapses.
	local function pullDensityFor(currentSize)
		return math.clamp(baseMass / (currentSize ^ 3), 0.01, PULL_MAX_DENSITY)
	end

	-- 0 at full size, 1 once the bomb is down at PULL_MIN_SIZE -- drives
	-- the friction/elasticity blend so the bomb grips harder and bounces
	-- less the smaller it gets, rather than flipping over all at once
	local shrinkRange = math.max(size - PULL_MIN_SIZE, 0.001)
	local function shrinkProgress(currentSize)
		return math.clamp((size - currentSize) / shrinkRange, 0, 1)
	end

	-- applied every Heartbeat for the whole pull (not just the shrink):
	-- the tween drives Size, this reads Size back and keeps the physical
	-- properties matched to it. Writing CustomPhysicalProperties is a
	-- property change, not a physics write, so unlike a direct velocity
	-- or CFrame write it never pulls network ownership onto the server
	-- and never blocks player pushes.
	local function applyPullPhysics()
		local currentSize = math.max(bomb.Size.X, PULL_MIN_SIZE)
		local t = shrinkProgress(currentSize)
		bomb.CustomPhysicalProperties = PhysicalProperties.new(
			pullDensityFor(currentSize),
			baseProps.Friction + (PULL_FRICTION - baseProps.Friction) * t,
			baseProps.Elasticity + (PULL_ELASTICITY - baseProps.Elasticity) * t,
			baseProps.FrictionWeight + (PULL_FRICTION_WEIGHT - baseProps.FrictionWeight) * t,
			baseProps.ElasticityWeight + (PULL_ELASTICITY_WEIGHT - baseProps.ElasticityWeight) * t
		)
	end

	-- The lift is NOT created here. The collision group swap above has to
	-- happen before the shrink (the solver needs the bomb out of contact
	-- with the balls while its collision shape is changing size), but the
	-- float is a property of the pull itself, not of the telegraph that
	-- precedes it: through the whole shrink the bomb is still an ordinary
	-- part sitting on the platform under ordinary gravity, and it only
	-- leaves the ground at the same instant everything else about the
	-- pull fires -- the shine, PULL_START_SND, the bomb going invisible.
	-- startLift() below is called from there; until then liftForce is nil
	-- and applyLift is a no-op.
	local liftAttach, liftForce, liftStartClock

	-- the one force doing all the flying. ApplyAtCenterOfMass keeps it
	-- from ever torquing the bomb, and RelativeTo World means "up" stays
	-- up no matter how the sphere is rolling when the pull starts.
	-- liftStartClock is stamped here too -- it's the zero point applyLift
	-- ramps its force up from, see below.
	local function startLift()
		liftAttach = Instance.new("Attachment")
		liftAttach.Name = "RadiantPullLiftAttachment"
		liftAttach.Parent = bomb

		liftForce = Instance.new("VectorForce")
		liftForce.Name = "RadiantPullLiftForce"
		liftForce.Attachment0 = liftAttach
		liftForce.RelativeTo = Enum.ActuatorRelativeTo.World
		liftForce.ApplyAtCenterOfMass = true
		liftForce.Force = Vector3.zero
		liftForce.Parent = bomb

		liftStartClock = os.clock()
	end

	-- F = m * (g_up + drag * (targetVelocity - v)), i.e. cancel gravity,
	-- then thrust toward a straight-up PULL_RISE_SPEED * liftMassScale
	-- with a drag term proportional to how far off that the bomb
	-- currently is. The two balance exactly at the target, so
	-- PULL_RISE_SPEED * liftMassScale really is the speed it ends up
	-- climbing at, and any horizontal velocity (a player shove, whatever
	-- it was doing when the pull started) is bled off by the same term.
	-- liftMassScale (captured above, from this bomb's own size/density)
	-- is what makes a big dense bomb climb proportionally harder than a
	-- small light one instead of every radiant bomb sharing one fixed
	-- target regardless of scale.
	--
	-- That full force is then scaled by rampFrac, which climbs from 0
	-- exponentially toward 1 over LIFT_RAMP_TIME seconds of real time
	-- since startLift() stamped liftStartClock -- so the force (and with
	-- it, gravity cancellation) starts at literally 0 the instant the
	-- float begins and builds up from there, rather than snapping
	-- straight to full strength on the very first frame.
	--
	-- Mass and gravity are both re-read every frame rather than captured
	-- once: bomb.AssemblyMass moves as applyPullPhysics ramps density,
	-- and Workspace.Gravity is a value a live game can change out from
	-- under this. Recomputing costs nothing and means the bomb's float
	-- never drifts out of trim.
	local function applyLift()
		if not liftForce then return end -- still in the shrink; gravity is untouched
		local mass = bomb.AssemblyMass
		local velocity = bomb.AssemblyLinearVelocity
		local target = Vector3.new(0, PULL_RISE_SPEED * liftMassScale, 0)
		local fullForce = mass * (Vector3.new(0, WS.Gravity, 0) + (target - velocity) * PULL_DRAG)

		local rampFrac = 1 - math.exp(-(os.clock() - liftStartClock) / LIFT_RAMP_TIME)
		liftForce.Force = fullForce * rampFrac
	end

	-- puts the bomb back exactly as it was -- its own collision group,
	-- its own physical properties, and gravity back in charge of it.
	-- Only ever needed on the sale paths below: a bomb that detonates
	-- normally is Destroy()'d by explode(), which takes the constraint
	-- and its attachment down with it. The lift half is a no-op on a
	-- sale that lands during the shrink, since it was never created.
	local function restorePullPhysics()
		restorePhysics()
		bomb.CustomPhysicalProperties = baseProps
		if liftForce and liftForce.Parent then liftForce:Destroy() end
		if liftAttach and liftAttach.Parent then liftAttach:Destroy() end
		liftForce, liftAttach = nil, nil
	end

	local physicsConn = RS.Heartbeat:Connect(function()
		applyPullPhysics()
		applyLift()
	end)
	applyPullPhysics()

	-- shrink: the ball itself eases down to PULL_MIN_SIZE as the telltale that
	-- the pull is about to start, instead of a separate telegraph part.
	-- This is purely cosmetic — `size` (the bomb's TargetSize, captured
	-- by flicker() before this was even called) is what actually drives
	-- the pull's strength below and the flash/blast size at explode()
	-- time, so shrinking the bomb's own Size here doesn't touch either.
	-- flicker()'s own Heartbeat loop keeps driving bomb.Color throughout,
	-- so the ball keeps flickering its normal rainbow tick while it shrinks.
	--
	-- Size only -- Position is deliberately left alone. The bomb is
	-- unanchored, and a direct server-side Position write (which is what
	-- tweening Position on an unanchored part actually is, every frame
	-- for the duration) forces network ownership onto the server, which
	-- freezes the part and blocks player pushes for as long as it keeps
	-- happening -- exactly what this change is trying to give back.
	-- Letting Size shrink toward the ball's own Position (its center)
	-- means it shrinks in place rather than staying bottom-anchored, so
	-- it lifts off cleanly instead of appearing to peel itself off the
	-- floor -- which suits the float perfectly, and never fights the
	-- engine for authority over a part the players are meant to be
	-- shoving around.
	--
	-- PULL_MIN_SIZE, not 0 -- see its own comment up top. The bomb goes
	-- fully transparent the moment this lands, so the last three quarters
	-- of a stud are never seen; Exponential/In means practically all the
	-- visible travel happens at the very end regardless.
	local shrink = TS:Create(bomb,
		TweenInfo.new(PULL_SHRINK_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.In),
		{ Size = Vector3.new(PULL_MIN_SIZE, PULL_MIN_SIZE, PULL_MIN_SIZE) })

	-- a demagnetizer-style sale landing mid-shrink shouldn't let this
	-- keep playing out its full PULL_SHRINK_TIME — same reasoning as
	-- MagnetFuse's own pendingSellConn — and puts the bomb's Size back
	-- to normal so it doesn't sit mid-shrink through the sell highlight
	-- fade (see stillLive's own PendingSell note). The collision group
	-- and the ramped-up density/friction get put back at the same time --
	-- a bomb restored to full size while still carrying a shrunken
	-- bomb's mass would be an immovable wall for the length of that fade,
	-- which is exactly the sort of thing a player would notice.
	local sellConn = bomb:GetAttributeChangedSignal("PendingSell"):Connect(function()
		if bomb:GetAttribute("PendingSell") then
			shrink:Cancel()
			physicsConn:Disconnect()
			bomb.Size = Vector3.new(size, size, size)
			restorePullPhysics()
		end
	end)

	shrink:Play()
	task.wait(PULL_SHRINK_TIME)
	sellConn:Disconnect()

	if not stillLive() then
		physicsConn:Disconnect()
		restorePullPhysics()
		return
	end

	-- the bomb itself goes fully invisible for the rest of the pull, same
	-- switch MagnetFuse's own magnet flips the instant its pull starts.
	-- This is what actually sells "collapsed into a point" now that the
	-- shrink stops at PULL_MIN_SIZE rather than at 0 -- the remaining
	-- three quarters of a stud are still there physically (holding the
	-- bomb's full mass, climbing away from the platform, pushable by
	-- players) but there's nothing to see. The collision group was already
	-- swapped before the shrink (see above), so visibility and the lift
	-- are what's left to flip here.
	bomb.Transparency = 1

	-- gravity goes off and the float begins at this exact instant, not
	-- when the shrink started -- see the `local liftAttach, liftForce`
	-- comment above. The already-running physicsConn picks it up on the
	-- very next Heartbeat; this first call just means it doesn't spend a
	-- frame in freefall waiting for it.
	startLift()
	applyLift()

	-- pull-start cue + shine: literally BombFuse's own flash() shape,
	-- left alive (parented to the bomb) for as long as the pull runs
	-- instead of flashing once and disappearing — same idea as
	-- MagnetFuse's own pullShine, simplified to a steady rainbow cycle
	-- rather than a white/yellow pop into a red/blue flicker
	pullSound.TimePosition = 0
	pullSound.Volume = PULL_START_VOL
	pullSound.PlaybackSpeed = PULL_START_PITCH
	pullSound:Play()

	-- the bomb's own "display" BillboardGui (numeric size readout) has
	-- no business showing through the pull flash -- delete it the
	-- instant the pull flash itself is created
	local display = bomb:FindFirstChild("display")
	if display then display:Destroy() end

	local shineGui = Instance.new("BillboardGui")
	shineGui.Adornee, shineGui.AlwaysOnTop, shineGui.Parent = bomb, true, bomb
	local shineScale = size * 0.8
	shineGui.Size = UDim2.new(shineScale * PULL_SHINE_OSC_MIN, 0, shineScale * PULL_SHINE_OSC_MIN, 0) -- corrected on the very next Heartbeat

	local shineImg = Instance.new("ImageLabel")
	shineImg.BackgroundTransparency, shineImg.BorderSizePixel = 1, 0
	shineImg.Size, shineImg.Image = UDim2.new(1, 0, 1, 0), FLASH_IMAGE
	shineImg.ImageColor3, shineImg.ImageTransparency = pullRainbow(), 0
	shineImg.ScaleType, shineImg.Parent = Enum.ScaleType.Fit, shineGui
	shineImg.ZIndex = 10
	-- AlwaysOnTop bypasses the normally-composited render a collapse's
	-- ColorCorrectionEffect desaturates — this attribute is what lets
	-- BallManager's triggerCollapse find and grey it out in step with
	-- everything else, same as BombFuse's own flash image
	shineImg:SetAttribute("GreyOnCollapse", true)

	-- entrance pop — same shape as MagnetFuse's own pullShine entrance: a
	-- NumberValue eased PULL_SHINE_ENTRANCE_START -> 1 once, read back
	-- every Heartbeat below (alongside the oscillation) so the shine
	-- starts big and settles down to its normal size instead of holding
	-- flat from the first frame
	local entranceDriver = Instance.new("NumberValue")
	entranceDriver.Value = PULL_SHINE_ENTRANCE_START
	local entranceTween = TS:Create(entranceDriver,
		TweenInfo.new(PULL_SHINE_ENTRANCE_TIME, PULL_SHINE_ENTRANCE_STYLE, Enum.EasingDirection.Out),
		{ Value = 1 })
	entranceTween:Play()

	-- size jitter — same shape as MagnetFuse's own pullShine oscillation:
	-- a NumberValue tweened PULL_SHINE_OSC_MIN <-> PULL_SHINE_OSC_MAX
	-- forever (Sine InOut, looped, reversed) at PULL_SHINE_OSC_HZ, read
	-- back every Heartbeat below to recombine shineGui.Size around the
	-- base shineScale instead of holding it flat
	local oscDriver = Instance.new("NumberValue")
	oscDriver.Value = PULL_SHINE_OSC_MIN
	local oscTween = TS:Create(oscDriver,
		TweenInfo.new(1 / (PULL_SHINE_OSC_HZ * 2), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Value = PULL_SHINE_OSC_MAX })
	oscTween:Play()

	-- pull + shine-color/size loop: runs until the bomb is gone — either
	-- sold (stillLive() catches PendingSell) or detonated (explode()
	-- below Destroy()s the bomb first thing, which is what actually
	-- ends this loop and, via BillboardGui parenting, takes shineGui
	-- down with it)
	--
	-- pullElapsed tracks real time since the pull actually started (this
	-- point), compared against pullDuration (the fuse's own computed time
	-- from here to its nominal detonation instant — see flicker()) to
	-- drive the exit shrink below the same way MagnetFuse's own SHINE_EXIT
	-- compares its elapsed/SHRINK_TIME clock, except this bomb has no
	-- self-destruct timer of its own to piggyback on
	local pullElapsed = 0
	local pullConn
	pullConn = RS.Heartbeat:Connect(function(dt)
		if not stillLive() then
			pullConn:Disconnect()
			physicsConn:Disconnect()
			entranceTween:Cancel()
			oscTween:Cancel()
			if shineGui.Parent then shineGui:Destroy() end
			-- collision group and physical properties go back to normal
			-- too. On a detonation the bomb is already Destroy()'d and
			-- this is a no-op; on a sale it matters, for the same reason
			-- the mid-shrink sellConn above restores them.
			restorePullPhysics()
			return
		end

		pullElapsed += dt
		shineImg.ImageColor3 = pullRainbow()

		-- exit shrink: flat until PULL_SHINE_EXIT_TIME seconds remain
		-- (per pullDuration), then eases 1x -> 0x, timed to hit exactly 0
		-- on the same nominal instant explode() actually fires
		local timeLeft = pullDuration - pullElapsed
		local exitMult = 1
		if timeLeft <= PULL_SHINE_EXIT_TIME then
			local exitFrac = 1 - math.clamp(timeLeft, 0, PULL_SHINE_EXIT_TIME) / PULL_SHINE_EXIT_TIME
			exitMult = 1 - TS:GetValue(exitFrac, PULL_SHINE_EXIT_STYLE, Enum.EasingDirection.In)
		end

		local jitteredSize = shineScale * entranceDriver.Value * oscDriver.Value * exitMult
		shineGui.Size = UDim2.new(jitteredSize, 0, jitteredSize, 0)

		local pos = bomb.Position
		for _, obj in ipairs(folder:GetChildren()) do
			if obj ~= bomb and obj.Name == ballT.Name and not obj:GetAttribute("Held") then
				local toBomb = pos - obj.Position
				local dist = toBomb.Magnitude
				if dist > 0.01 then
					obj.AssemblyLinearVelocity += (toBomb / dist) * PULL_ACCEL * size * dt
				end
			end
		end
	end)
end

-- ── explosion VFX: expanding neon ball, cycling rainbow instead of
-- BombFuse's fixed orange -> red, then fades — same shape otherwise.
-- Colored off the same flash color loop as flicker()
-- (litAccum keeps advancing here, since the explosion is lit the whole
-- time it's on screen) rather than its own independent clock ──
local function vfx(pos, blastRadius)
	local r = blastRadius * VFX_SCALE

	local ball = Instance.new("Part")
	ball.Shape, ball.Anchored, ball.CanCollide, ball.CanQuery = Enum.PartType.Ball, true, false, false
	ball.Material, ball.Color = Enum.Material.Neon, flashRainbow(litAccum)
	ball.Size, ball.Position, ball.Parent = Vector3.new(1, 1, 1), pos, WS

	local expand = TS:Create(ball,
		TweenInfo.new(VFX_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
		{ Size = Vector3.new(r, r, r) * 2 })
	local fade = TS:Create(ball,
		TweenInfo.new(VFX_TIME * 0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Transparency = 1 })

	local hueConn = RS.Heartbeat:Connect(function(dt)
		if ball.Parent then
			litAccum += dt
			ball.Color = flashRainbow(litAccum)
		end
	end)

	expand:Play()
	task.delay(VFX_TIME * 0.25, function()
		if ball.Parent then fade:Play() end
	end)
	expand.Completed:Connect(function()
		hueConn:Disconnect()
		if ball.Parent then ball:Destroy() end
	end)
end

-- ── billboard flash — same shape as BombFuse's own flash(), popping to
-- pure white instead of BombFuse's white -> yellow ──
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
	img.ImageColor3, img.ImageTransparency = Color3.new(1, 1, 1), 0
	img.ScaleType, img.Parent = Enum.ScaleType.Fit, gui
	img.ZIndex = 10
	img:SetAttribute("GreyOnCollapse", true)

	task.delay(FLASH_TIME, function()
		if anchor.Parent then anchor:Destroy() end
	end)
end

-- ── mimic defuse (board mimics only) — identical to BombFuse's own
-- revertMimic; duplicated here since this script fully replaces
-- BombFuse rather than requiring it (see this file's own header) ──
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

-- ── exponential impulse curve — matches a plain bomb's linear
-- (size * IMPULSE_PER_SIZE) exactly at BOMB_SIZE_REF, then grows
-- exponentially above/below it, per "explosion power scales
-- exponentially, not linearly" ──
local function radiantImpulseMagnitude(size)
	local baseline = BOMB_SIZE_REF * IMPULSE_PER_SIZE
	return baseline * (RADIANT_IMPULSE_GROWTH ^ (size - BOMB_SIZE_REF))
end

-- ── detonation — same shape as BombFuse's own explode(), just the
-- rainbow VFX/flash above and the exponential impulse curve swapped in;
-- blast RADIUS is untouched (still linear, RADIUS_PER_SIZE) ──
local function explode()
	if not stillLive() then return end

	local size = bomb:GetAttribute("TargetSize") or bomb.Size.X
	local pos = bomb.Position
	local blastRadius = size * RADIUS_PER_SIZE
	local impulseMagnitude = radiantImpulseMagnitude(size)

	-- boomSound is already loaded and primed (see its creation up top) —
	-- move it off the bomb onto its own standalone anchor at the blast
	-- position before the bomb itself is destroyed, then play it from
	-- there, same "already-primed local Sound" approach pullSound uses
	-- for the pull-start cue, instead of requesting a fresh Sound from
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

	for _, part in ipairs(folder:GetChildren()) do
		if part:IsA("BasePart") then
			local offset = part.Position - pos
			local dist = offset.Magnitude

			if dist <= blastRadius and part:GetAttribute("MimicActive") and not part:GetAttribute("IsPetMimic") then
				revertMimic(part)
			end

			if not part.Anchored and dist <= blastRadius and not part:GetAttribute("IsPetMimic") then
				local dir = (dist > 0.01) and (offset / dist) or Vector3.new(0, 1, 0)
				local falloff = 1 - dist / blastRadius
				part:ApplyImpulse(dir * impulseMagnitude * falloff)
			end
		end
	end
end

-- ── flicker — same shape as BombFuse's own flicker(), navy OFF between
-- ticks same as a plain bomb, flashing up to the cycling rainbow hue
-- instead of fixed red on each tick, and fires triggerHalfwayPull once
-- real elapsed TIME crosses the midpoint of the whole burn-down ──
local function flicker()
	-- The base fuse lasts 5 seconds (32 * .125 + 16 * .0625). During the
	-- final speed-up window, both the tick sound and the visual cadence
	-- accelerate together, so the actual fuse duration is shorter.
	local baseTotalTime = 0
	for _, phase in ipairs(PHASES) do
		baseTotalTime += phase.gap * phase.n
	end

	local baseSpeedupStart = math.max(baseTotalTime - TICK_SPEEDUP_WINDOW, 0)

	-- Integrate the accelerated portion of the timeline so halfway/pull
	-- timing is based on the same accelerated duration as the tick loop.
	local integratedSpeedupTime = 0
	local integrationSteps = 200
	local step = TICK_SPEEDUP_WINDOW / integrationSteps
	for i = 0, integrationSteps - 1 do
		local remaining = TICK_SPEEDUP_WINDOW - (i + 0.5) * step
		integratedSpeedupTime += step / tickSpeedForRemaining(remaining)
	end

	local totalTime = baseSpeedupStart + integratedSpeedupTime
	local halfwayTime = totalTime / 2 - (PULL_SHRINK_TIME / 2)

	local isLight = false
	local elapsed = 0
	local baseElapsed = 0
	local halfwayFired = false
	-- litAccum (shared, top-level) is updated every Heartbeat while a
	-- tick is actually showing the flash -- not stepped once per tick --
	-- so the hue visibly rotates in real time for as long as the flash
	-- is up, and holds completely still through every dark/OFF tick.
	-- Reset here since this is the one and only burn-down for this bomb.
	litAccum = 0
	bomb.Color = OFF

	local flashConn
	flashConn = RS.Heartbeat:Connect(function(dt)
		if isLight then
			litAccum += dt
			bomb.Color = flashRainbow(litAccum)
			bomb:SetAttribute("RadiantFlashColor", bomb.Color)
		end
	end)
	local function stopFlashLoop()
		flashConn:Disconnect()
	end

	for _, phase in ipairs(PHASES) do
		for _ = 1, phase.n do
			if not stillLive() then stopFlashLoop(); return false end

			-- baseElapsed follows the original fuse clock. elapsed follows
			-- real time after applying the acceleration to the wait itself.
			local baseRemaining = math.max(baseTotalTime - baseElapsed, 0)
			local tickSpeed = tickSpeedForRemaining(baseRemaining)
			local actualWait = phase.gap / tickSpeed

			task.wait(actualWait)
			if not stillLive() then stopFlashLoop(); return false end

			baseElapsed += phase.gap
			elapsed += actualWait

			isLight = not isLight
			bomb.Color = isLight and flashRainbow(litAccum) or OFF

			if isLight then
				bomb:SetAttribute("RadiantFlashColor", bomb.Color)
				-- The sound playback speed and visual flicker rate use the
				-- exact same multiplier.
				se:FireAllClients("attachedReused", bomb, FLICKER_SND, FLICKER_VOL, tickSpeed)
			end

			if not halfwayFired and elapsed >= halfwayTime then
				halfwayFired = true
				local size = bomb:GetAttribute("TargetSize") or bomb.Size.X

				-- Time from the pull actually starting (after its shrink)
				-- to the accelerated fuse's detonation instant.
				local pullDuration = totalTime - (halfwayTime + PULL_SHRINK_TIME)

				task.spawn(triggerHalfwayPull, size, pullDuration)
			end
		end
	end

	stopFlashLoop()
	return stillLive()
end

-- ── run ───────────────────────────────────────────────────────────
if flicker() then
	explode()
end