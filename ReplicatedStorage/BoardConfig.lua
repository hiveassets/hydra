--[[
    BoardConfig (ModuleScript)
    Path: ReplicatedStorage
    Parent: ReplicatedStorage
    Exported: 2026-09-20 22:14:29
]]
--[[
	BoardConfig (ModuleScript) — place directly in ReplicatedStorage
	(ReplicatedStorage.BoardConfig).

	Every tuning number the board uses, in one place, readable by both
	sides. This is the file you open to change how the game feels.

	WHY ONE SHARED FILE

	Under the old setup a number that both sides needed had to be written
	twice and kept in sync by hand — BOMB_SELL_MULTIPLIER lived in both
	SellService and SellClient, ONLY_BALL_FREE_MAX_SIZE in both, BRIBE's
	duration in three places, LEG_LIFT_FRAC in two. Every one of those
	carried a "keep in sync by hand" comment, which is a bug waiting for
	the day somebody changes one and not the other. Now the server reads
	the value to pay out with and the client reads the same value to
	label the price with, from here.

	Nothing in this file is secret. An exploiter can read every number in
	it, exactly as they could read the old copies that lived in
	LocalScripts. Prices being public is fine; what matters is that the
	SERVER is the one that applies them (see Board/BoardService).

	WHAT DOESN'T LIVE HERE

	Anything only one side ever needs and nobody else should have an
	opinion about: purely visual timings inside one client script, the
	exact easing of a tween, asset ids for sounds only the client plays.
	Those stay next to the code that uses them. The test is simple — if
	both sides read it, or if it decides money, it belongs here.
]]

local BoardConfig = {}

-- ── phase flags ───────────────────────────────────────────────────────
-- Specials (bomb/magnet/mimic/splitter/merger) come back one at a time
-- in phase 3. Until then the roll below is skipped entirely rather than
-- the weights being zeroed, so there's no chance of a stray special
-- appearing from a rounding edge.
BoardConfig.SPECIALS_ENABLED = false

-- ── launch and settle ────────────────────────────────────────────────
BoardConfig.SPAWN_POS = Vector3.new(0, -25, 0)
BoardConfig.GROW_Y = -15        -- grow-in tween starts once a ball rises past this
BoardConfig.COL_Y = 0.5         -- collision comes back here; also the platform surface reference
BoardConfig.FALL_Y = -1         -- a settled ball below this has fallen off
BoardConfig.FALL_BADGE_Y = -10  -- ...and below this it has definitely fallen, clear of any bounce near FALL_Y
BoardConfig.MAX_DIST_FROM_ORIGIN = 1000 -- a settled ball this far from (0,0,0) counts as fallen too

-- Apex height in studs above SPAWN_POS for a BASE-size ball, plus extra
-- height per stud of size beyond BASE. Matches the radius those extra
-- studs add, so a bigger ball gets exactly enough headroom to grow into
-- without clipping. See BoardRules.launchVelocity for how these become
-- a velocity, and why the apex HEIGHT scales rather than the speed.
BoardConfig.BASE_APEX_HEIGHT = 36.7
BoardConfig.APEX_HEIGHT_PER_STUD = 0.5
BoardConfig.H_SPEED = 4         -- max random horizontal kick on launch

BoardConfig.GAP = 0.125         -- seconds between queued launches (8 a second)

-- ── sizes ─────────────────────────────────────────────────────────────
-- The Ball template's own size in Studio. The client checks the real
-- template against this on startup and warns if they've drifted apart,
-- because the server has no way to look at the template itself.
BoardConfig.BASE_SIZE = 5
BoardConfig.MIN_SIZE = 3        -- floor for any ball size
BoardConfig.SIZE_VAR = 2        -- jitter applied to one of the two balls a fall produces
BoardConfig.GROW_AT = 8         -- balls bigger than this spawn small and grow in
BoardConfig.GROW_TIME = 0.6     -- how long that grow-in takes
BoardConfig.BASE_DENSITY = 0.2  -- density at BASE size; see BoardRules.densityFor
BoardConfig.MAX_BALLS = 50      -- regular balls in play; specials don't count

-- How long a growing split/merge result may take to finalise before the
-- client steps in and finishes it by hand. Only ever reached if a tween
-- was interrupted.
BoardConfig.GROW_FINALIZE_GRACE = 0.1

-- Safety net for a ball that crossed FALL_Y but came to rest on
-- something below the platform instead of continuing to fall: the client
-- destroys it itself this long after it was reported. Generous on
-- purpose, well past how long a real fall takes.
BoardConfig.VOID_FALLBACK_TIMEOUT = 5

-- ── special rolls (dormant until phase 3) ─────────────────────────────
BoardConfig.SPECIAL_TOTAL_CHANCE = 0.15 -- share of cleared rolls that become some special
BoardConfig.SPECIAL_COOLDOWN = 10       -- seconds between special rolls, shared across every kind
BoardConfig.SPECIAL_MIN_BALLS = 2       -- board must already have this many balls before a special can roll

BoardConfig.SPECIAL_WEIGHTS = {
	bomb = 5,
	magnet = 3,
	mimic = 0.05,
	splitter = 2,
	merger = 1,
}

-- ── radiant ───────────────────────────────────────────────────────────
-- Rolled independently of the special roll, as an overlay on whatever
-- the slot was going to spawn anyway.
BoardConfig.RADIANT_CHANCE = 0.05
BoardConfig.RADIANT_COOLDOWN = 10
BoardConfig.RADIANT_RESPAWN_DELTAS = { -1, 2 } -- a radiant that falls comes back 1 smaller or 2 bigger

-- ── selling ───────────────────────────────────────────────────────────
BoardConfig.SELL_MULTIPLIERS = {
	ball = 1,
	radiantBall = 3,
	bomb = 2,
	radiantBomb = 6,
	magnet = 2,
	radiantMagnet = 6,
}

-- The "last orb on the board isn't worth anything" rule only applies to
-- an orb this size or smaller. It exists to stop the last orb being
-- flipped for free money on a board that immediately respawns one, not
-- to strand someone holding a genuinely valuable last orb. 5 is the Ball
-- template's own base size, so this reads as "never grew past spawn
-- size".
BoardConfig.ONLY_BALL_FREE_MAX_SIZE = 5

BoardConfig.MIMIC_SELL_FRACTION = 0.5 -- what a board mimic's catch pays, relative to a normal sell
BoardConfig.PRE_SELL_DELAY = 0.3      -- the highlight fade before a ball actually goes

-- ── collapse ──────────────────────────────────────────────────────────
BoardConfig.OVERFLOW_THRESHOLD = 150 -- queued launches
BoardConfig.OVERFLOW_SUSTAIN = 3     -- ...that have to stay over the line this long, continuously
BoardConfig.COLLAPSE_PENALTY_FRACTION = 0.1
BoardConfig.COLLAPSE_SELL_GAP = 0.05 -- between each ball's forced $0 sell, smallest first
BoardConfig.PRE_COLLAPSE_DELAY = 1   -- beat between the freeze and the first sell
BoardConfig.PRE_PENALTY_DELAY = 1    -- beat between the board being empty and the fine
BoardConfig.POST_COLLAPSE_DELAY = 1  -- beat between the fine and the fade back
BoardConfig.COLLAPSE_FADE_TIME = 1

BoardConfig.BRIBE_DURATION = 30      -- how long a bribe suppresses the collapse trigger
BoardConfig.BRIBE_COOLDOWN = 120     -- per player, between bribe purchases

-- ── badges ────────────────────────────────────────────────────────────
-- Every badge the board itself awards. Kept here rather than in the
-- scripts that award them, because two of them also gate shop entries
-- (see UpgradeData's requiresBadge) and those ids have to agree.
BoardConfig.BADGES = {
	fall = 1937874786736578,
	collapse = 3848961087513729,   -- also the bribe's shop gate
	mimicWake = 3684816254175058,  -- also the pet mimic's shop gate
	millionaire = 3176970008807555,
	sellTier1 = 4491513065757921,
	sellTier2 = 3248473547490503,
}

BoardConfig.SELL_BADGE_THRESHOLDS = {
	{ amount = 50, badge = BoardConfig.BADGES.sellTier1 },
	{ amount = 100, badge = BoardConfig.BADGES.sellTier2 },
}

BoardConfig.MILLIONAIRE_THRESHOLD = 1000000

-- ── other players ─────────────────────────────────────────────────────
-- How see-through everyone else is on your screen. 0.8 is "20% opaque":
-- clearly there, clearly not part of your board. They can't touch your
-- orbs (see RemotePlayersClient), and looking solid while being unable
-- to interact reads as a bug rather than a design.
BoardConfig.REMOTE_PLAYER_TRANSPARENCY = 0.8

-- ── anti-cheat margins ───────────────────────────────────────────────
-- A ball can't be reported as fallen before it has physically had time
-- to get out of the launch and back down past FALL_Y. Under plain
-- gravity that round trip is about a second; this is deliberately well
-- under that, because a bomb's impulse can genuinely fling a ball off
-- early. It's a floor against nonsense, not a simulation.
BoardConfig.MIN_TIME_BEFORE_FALL = 0.4

-- How long after its scheduled launch the server treats a queued ball as
-- actually on the board. Roughly the time it takes to rise past COL_Y.
BoardConfig.LAUNCH_TO_LIVE = 0.3

-- Client to server messages allowed per second, per player, before the
-- rest of that second's messages are dropped. Generous: a busy split
-- cascade is only a handful a second, and Roblox itself cuts off around
-- 500. Phase 4 replaces this with per-event limits and reporting.
BoardConfig.EVENT_RATE_LIMIT = 40

-- ── sounds the board plays (client-side) ──────────────────────────────
BoardConfig.SOUNDS = {
	spawn = { id = "rbxassetid://12221967", volume = 1 },
	spawnSpecial = { id = "rbxassetid://73276365795189", volume = 1 },
	sell = { id = "rbxassetid://139583503249540", volume = 1 },
	collapseAlarm = { id = "rbxassetid://12221990", volume = 1, speed = 0.7 },
	collapseSell = { id = "rbxassetid://12222170", volume = 1 },
	collapseTick = { id = "rbxassetid://12222170", volume = 1 },
	collapseTension = { id = "rbxassetid://87758060178138", volume = 0.7 },
	collapseMessage = { id = "rbxassetid://135083591486620", volume = 1 },
}

-- ── collapse visuals (client-side, but shared so one file owns tuning) ─
BoardConfig.COLLAPSE_VISUALS = {
	contrastBoost = 0.4,             -- added on top of the map's own Contrast during the collapse itself
	telegraphSaturation = -1,        -- how far Saturation ramps over the countdown (negative drains colour)
	telegraphContrast = 5,
	telegraphTint = Color3.fromRGB(255, 0, 255),
	telegraphTintIntensity = 0.5,    -- 0..1, how far toward that tint the grade lerps at the peak
	telegraphShake = 0.25,           -- camera shake at the peak of the countdown
	telegraphCancelFade = 0.5,       -- quicker than COLLAPSE_FADE_TIME on purpose: a false alarm should read as "stand down"
	flashColor = Color3.fromRGB(255, 0, 255),
}

return BoardConfig
