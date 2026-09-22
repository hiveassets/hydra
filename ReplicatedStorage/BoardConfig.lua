--[[
    BoardConfig (ModuleScript)
    Path: ReplicatedStorage
    Parent: ReplicatedStorage
    Exported: 2026-09-22 18:28:58
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
-- in phase 3. The master switch is on from step 1; which kinds can
-- actually roll is SPECIAL_WEIGHTS below, where everything that hasn't
-- landed yet sits at 0.
--
-- Turning this back off is the one-line way to get a plain-ball board
-- again if a special ever misbehaves mid-playtest.
BoardConfig.SPECIALS_ENABLED = true

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

-- Anything this far down is gone, whatever state the board thought it
-- was in. The state machine only watches for a SETTLED ball dropping
-- below the platform, which misses the ball that gets deflected on the
-- way up and never rises past it at all — that one would otherwise fall
-- forever, unreported and unreplaced, while the ledger still counted it
-- against the orb cap.
BoardConfig.VOID_Y = -120

-- ...and this is where it's actually destroyed, which is a separate
-- question from where the fall gets REPORTED above.
--
-- They used to be the same line, and an orb simply blinked out of
-- existence on crossing it. The platform sits at the origin with a clear
-- view straight down past the edge, so what you saw was an orb vanishing
-- in mid-air for no reason. Splitting the two lets the report stay where
-- it was — replacements arrive on exactly the same beat as before — while
-- the orb itself carries on down well out of sight before it goes.
--
-- Worth knowing if you retune this: Workspace.FallenPartsDestroyHeight
-- (-500 by default) will destroy the part out from under the shrink if
-- this gets close to it. At -250 the orb is doing about 310 studs a
-- second, so the exit finishes around -353 — comfortable margin, and if
-- it ever isn't, the orb simply goes without the animation rather than
-- anything breaking.
BoardConfig.VOID_EXIT_Y = -50

-- How long the orb takes to shrink away once it crosses that line.
-- There's no highlight and no flash with it: a fall isn't an event, it's
-- an orb leaving, and anything more than the shrink made it look like
-- something had happened.
BoardConfig.VOID_EXIT_TIME = 1

-- ── special rolls (dormant until phase 3) ─────────────────────────────
BoardConfig.SPECIAL_TOTAL_CHANCE = 0.15 -- share of cleared rolls that become some special
BoardConfig.SPECIAL_COOLDOWN = 10       -- seconds between special rolls, shared across every kind
BoardConfig.SPECIAL_MIN_BALLS = 2       -- board must already have this many balls before a special can roll

-- Phase 3 brings the specials back ONE AT A TIME, and a kind at weight
-- 0 never rolls. So this table is the switchboard for that: each step
-- restores its own kind's weight and nothing else, and the board stays
-- playable in between. The numbers in the comment are what each one
-- goes back to — don't re-derive them, they're the originals.
--
--   bomb      5      ← step 1, live
--   magnet    3      ← step 2, live
--   splitter  2      ← step 3
--   merger    1      ← step 4
--   mimic     0.05   ← step 5
--
-- The radiant variants (step 6) aren't kinds of their own; they're the
-- radiant overlay rolling on top of one of these, gated by
-- BoardRules.radiantSupported.
BoardConfig.SPECIAL_WEIGHTS = {
	bomb = 5,
	magnet = 3,
	mimic = 0,
	splitter = 0,
	merger = 0,
}

-- ── what each kind looks like ─────────────────────────────────────────
-- One row per kind: which template it's cloned from, and the two things
-- the board is allowed to paint over afterwards.
--
-- THE TEMPLATE OWNS THE LOOK. The board owns size, position, collision
-- and physics, and nothing else. Reflectance, material, surface types,
-- decals, the billboard's own settings — none of that is ever written
-- by ClientBoard, so whatever you set on the template in Studio is what
-- shows up. That's deliberate: a special is recognisable at a glance
-- BECAUSE it looks different, and a launch routine that normalised
-- every orb would quietly undo the thing that makes the board readable.
--
--   template     the Instance name in ReplicatedStorage. The behaviour
--                module under Behaviours shares this name.
--   ledgerColor  true if the board paints it with the colour the server
--                rolled. Only orbs that are SUPPOSED to be a random
--                colour: a bomb painted lilac stops reading as a bomb.
--                A mimic is true precisely because it has to pass for
--                an ordinary orb.
--   showsSize    true if the board writes the size into its numDisplay.
--                A bomb shows "!!" and a magnet "><" instead — baked
--                into the template, swapped for a price by SellClient
--                in sell mode, and written back by it afterwards. A
--                mimic shows a number, for the same reason it takes a
--                random colour.
--
-- The server never touches any of this; it only ever deals in the kind
-- NAME. A client that swapped a template changes what its own orb looks
-- like, not what the ledger says it is or what it pays.
--   selfDriven   true if the behaviour owns where this orb is. The board
--                skips the whole launch-and-settle path for it: no
--                launch velocity, stays anchored, and the per-frame ball
--                physics never touches it. A magnet rises, wanders and
--                then holds position under its own control, and would be
--                fought the whole way by a step loop trying to settle it
--                onto the platform and switch its collision back on.
BoardConfig.LOOK = {
	ball     = { template = "Ball",     ledgerColor = true,  showsSize = true,  selfDriven = false },
	bomb     = { template = "Bomb",     ledgerColor = false, showsSize = false, selfDriven = false },
	magnet   = { template = "Magnet",   ledgerColor = false, showsSize = false, selfDriven = true },
	mimic    = { template = "Mimic",    ledgerColor = true,  showsSize = true,  selfDriven = false },
	splitter = { template = "Splitter", ledgerColor = false, showsSize = false, selfDriven = false },
	merger   = { template = "Merger",   ledgerColor = false, showsSize = false, selfDriven = false },
}

-- ── bomb ──────────────────────────────────────────────────────────────
-- Every number here came straight off BombFuse; nothing is retuned.
-- The two PHASES are the fuse: 16 flickers at 0.125s then 8 at 0.0625s,
-- which is the 2.5s total the anti-cheat notes in the plan refer to.
BoardConfig.BOMB = {
	OFF_COLOR = Color3.fromRGB(27, 41, 53),
	ON_COLOR = Color3.fromRGB(255, 0, 0),
	PHASES = {
		{ gap = 0.125, n = 16 },
		{ gap = 0.0625, n = 8 },
	},

	-- The real blast. Radius scales with the bomb's ledger size, and the
	-- push is an impulse rather than a velocity so a big orb takes the
	-- same hit as a small one relative to its mass.
	RADIUS_PER_SIZE = 6,
	IMPULSE_PER_SIZE = 5000,

	-- The VFX ball now covers exactly the area the force reaches.
	--
	-- It never used to, and the reason is a units bug rather than a
	-- taste decision. A Ball part's Size is its DIAMETER, and the old
	-- code built it as `Vector3.new(r, r, r) * 2` with `r = radius *
	-- 0.5` — so the sphere's diameter came out equal to the blast
	-- radius, which made its radius half of it. Every explosion since
	-- has drawn at half the size it actually hit, which is why orbs
	-- visibly outside the fireball still went flying.
	--
	-- At 1 the sphere's diameter is twice the blast radius, so its edge
	-- sits exactly where the falloff reaches zero. Lower it to shrink
	-- the fireball inside the real blast again; the force never reads
	-- this number.
	VFX_SCALE = 1,
	VFX_TIME = 0.3,
	VFX_START = Color3.fromRGB(127, 68, 0),
	VFX_END = Color3.fromRGB(127, 0, 0),

	FLASH_SCALE = 0.6,
	FLASH_TIME = 0.1,
	FLASH_IMAGE = "rbxassetid://131187911056182",
	FLASH_START = Color3.new(1, 1, 1),
	FLASH_COLOR = Color3.fromRGB(255, 255, 0),
	FLASH_RECOLOR_AT = 0.03,

	-- ── getting hit ───────────────────────────────────────────────────
	-- Everything the blast catches flashes red and fades, so you can see
	-- what it reached rather than inferring it from what moved. Only the
	-- orbs that were actually pushed light up, so the highlight and the
	-- impulse always agree.
	HIT_COLOR = Color3.fromRGB(255, 0, 0),
	HIT_FADE_TIME = 0.5,

	-- Kinds that take the push but not the flash. A splitter or a merger
	-- is a tool sitting on the board rather than something the blast
	-- happened TO, and marking it as damaged reads as a state change it
	-- hasn't had.
	HIT_FLASH_EXCLUDES = {
		splitter = true,
		merger = true,
	},

	-- ── screen shake ──────────────────────────────────────────────────
	-- Amplitude is roughly the peak camera offset in studs, scaled by
	-- the bomb's size so a big one lands harder.
	--
	-- Linear in size. A root curve was tried first and the small end felt
	-- right, but everything above about size 20 came out limp — the
	-- curve flattens exactly where the bombs get interesting.
	--
	--   size    3 → 0.30      size   50 → 2.65
	--   size    5 → 0.40      size  100 → 5.00 (capped)
	--   size   20 → 1.15      size  400 → 5.00 (capped)
	--
	-- The low end is within a few hundredths of where the root curve had
	-- it, so what felt good there is unchanged; everything from 10 up
	-- hits harder, and much harder past 50.
	--
	-- Linear has to saturate somewhere, and with these numbers that's
	-- size 97. Past it every bomb shakes identically. Raising SHAKE_MAX
	-- moves that line — at 5 studs the camera is already being thrown a
	-- long way, so if size 100 and size 400 need to feel different,
	-- that's the number to push rather than SHAKE_PER_SIZE.
	SHAKE_BASE = 0.15,     -- floor, so a tiny bomb still registers
	SHAKE_PER_SIZE = 0.05, -- studs per unit of size — the main tuning knob
	SHAKE_MAX = 5,         -- ceiling; also where the linear curve goes flat
	SHAKE_TIME = 0.45,
	SHAKE_FREQUENCY = 20, -- noise cycles a second: higher is a rattle, lower is a heave
	SHAKE_ROTATION = 0.8, -- degrees of camera roll per stud of offset
}

-- ── magnet ────────────────────────────────────────────────────────────
-- Every number lifted from MagnetFuse unchanged. The magnet rises,
-- wanders to a random point, telegraphs, then pulls every plain orb
-- toward itself while shrinking away to nothing.
BoardConfig.MAGNET = {
	-- Rise height and wander radius both scale off a size-10 magnet, so
	-- that one still rises to exactly 25 and wanders out to exactly 65 —
	-- the flat values these replaced — and every other size moves
	-- linearly off that anchor.
	SIZE_REF = 10,
	RISE_Y_BASE = 25,
	RISE_Y_PER_SIZE = 0.5,
	WANDER_RADIUS_BASE = 65,
	WANDER_RADIUS_PER_SIZE = 2,

	RISE_TIME = 2,
	RISE_STYLE = Enum.EasingStyle.Exponential,
	WANDER_TIME = 3,
	WANDER_STYLE = Enum.EasingStyle.Sine,
	-- The rise starts at once, the sideways move waits. An Out ease puts
	-- the magnet well clear of the floor almost immediately, and starting
	-- the wander any sooner shows it sliding along underground.
	WANDER_START_DELAY = 0.1,

	-- Idle colour: pure red to pure blue and back, the whole time it's
	-- visible, so it reads as live from the moment it appears.
	COLOR_A = Color3.new(1, 0, 0),
	COLOR_B = Color3.new(0, 0, 1),
	COLOR_CYCLE_TIME = 0.5, -- one leg; it reverses, so a full cycle is twice this

	-- The warning sphere: the inverse of the bomb's fireball. Starts big
	-- and invisible, shrinks onto the magnet while fading IN. Timed to
	-- finish exactly as the magnet arrives, because it's the only warning
	-- there is and nothing dangerous may happen until it has played out.
	TELEGRAPH_COLOR = Color3.fromRGB(255, 255, 0),
	TELEGRAPH_RADIUS_PER_SIZE = 3,
	TELEGRAPH_TIME = 2,

	-- The pull. SHRINK_TIME is how long the magnet takes to go from its
	-- arrival size to nothing, the same for every size — a bigger magnet
	-- loses more studs a second rather than lasting longer.
	SHRINK_TIME = 2,
	PULL_ACCEL = 10, -- per stud of the magnet's CURRENT size, per second, with no distance falloff

	-- The shine that replaces the magnet once it turns invisible. Its
	-- size is three curves multiplied together: a one-shot pop in, a
	-- permanent oscillation, and a final ease to nothing timed to land on
	-- zero the same frame the magnet goes.
	SHINE_SCALE = 1, -- multiple of the ARRIVAL size, not a flat stud count
	SHINE_OSC_MIN = 0.9,
	SHINE_OSC_MAX = 1.1,
	SHINE_OSC_HZ = 8,
	SHINE_ENTRANCE_START = 3,
	SHINE_ENTRANCE_TIME = 0.5,
	SHINE_ENTRANCE_STYLE = Enum.EasingStyle.Quad,
	SHINE_EXIT_TIME = 0.5,
	SHINE_EXIT_STYLE = Enum.EasingStyle.Quad,
	SHINE_WHITE_TIME = 0.03, -- pops white this long...
	SHINE_POP_DELAY = 0.1,   -- ...then yellow until here, then the flicker takes over
	SHINE_FLICKER_HZ = 4,    -- snaps between COLOR_A and COLOR_B this often, no fade
	SHINE_YELLOW = Color3.new(1, 1, 0),
	SHINE_WHITE = Color3.new(1, 1, 1),
	FLASH_IMAGE = "rbxassetid://131187911056182", -- the bomb's flash image, reused
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
	trickShot = 776457600018699,
	sellTier1 = 4491513065757921,
	sellTier2 = 3248473547490503,
}

BoardConfig.SELL_BADGE_THRESHOLDS = {
	{ amount = 50, badge = BoardConfig.BADGES.sellTier1 },
	{ amount = 100, badge = BoardConfig.BADGES.sellTier2 },
}

BoardConfig.MILLIONAIRE_THRESHOLD = 1000000

-- ── grab ──────────────────────────────────────────────────────────────
BoardConfig.GRAB_RANGE = 20          -- studs from the player to the ball's surface
BoardConfig.THROW_SPEED = 90         -- every throw releases at full strength
BoardConfig.HOLD_CLEARANCE = 3       -- studs between the bottom of a carried ball and the player
BoardConfig.REGRAB_DELAY = 0.35      -- ignore a just-thrown ball as a target for this long

-- The trick-shot badge: a throw released from the small pad in the
-- middle of the platform that then clears the edge without touching
-- anything. The client watches the throw (it owns the physics); the
-- server checks the player was actually standing on the pad, which is
-- the one half of it the server can still see.
BoardConfig.TRICK_ZONE_RADIUS = 5
BoardConfig.TRICK_SHOT_Y = -10
BoardConfig.TRICK_ZONE_SERVER_SLACK = 12 -- how far they're allowed to have wandered by the time the report lands

-- ── stash ─────────────────────────────────────────────────────────────
-- The absorb: the orb flies into the player and shrinks away while a
-- cyan highlight fades in over it. Deliberately half the length of a
-- sell's own fade — a sell's beat is a warning that something is
-- leaving, and a stash isn't warning anyone about anything, it's the
-- player's own input landing.
BoardConfig.STASH_RANGE = 20
BoardConfig.STASH_PULL_TIME = 0.15
BoardConfig.STASH_END_SIZE = 1 -- not 0: a part tweened to literally nothing renders as a speck for its last frame
BoardConfig.STASH_FLASH_SIZE = 6 -- fixed, NOT the orb's own size: this is feedback on an input, not a readout of what left
BoardConfig.STASH_COLOR = Color3.fromRGB(0, 255, 255)
BoardConfig.STASH_DEPLOY_GLOW_TIME = 0.6 -- matches the spawn grow, so the glow is gone about when the orb reaches full size

-- ── other players ─────────────────────────────────────────────────────
-- How see-through everyone else is on your screen. 0.8 is "20% opaque":
-- clearly there, clearly not part of your board. They can't touch your
-- orbs (see RemotePlayersClient), and looking solid while being unable
-- to interact reads as a bug rather than a design.
BoardConfig.REMOTE_PLAYER_TRANSPARENCY = 0.8

-- ── anti-cheat margins ───────────────────────────────────────────────
-- A ball can't be reported as fallen before it has physically had time
-- to get out of the launch and back down past FALL_Y. It's a floor
-- against nonsense, not a simulation.
--
-- Don't raise this without doing the arithmetic. An undisturbed ball
-- takes about a second, but that isn't the bound that matters: a ball
-- becomes settled the moment it rises past COL_Y, roughly 0.27s after
-- launch, and a deflection off a crowded board can put it under FALL_Y
-- about 0.12s after that. So the real floor is a hair under 0.4 — which
-- is where this started, and refusing legitimate falls at the margin
-- costs the player an orb every time it happens. 0.25 keeps the
-- nonsense out with room to spare, and the launch queue is what
-- actually caps how fast orbs can be duplicated anyway.
BoardConfig.MIN_TIME_BEFORE_FALL = 0.25

-- How long after its scheduled launch the server treats a queued ball as
-- having had time to reach the platform. This is a FALL guard and
-- nothing else — see Board.isLive and Board.isOnBoard, which are two
-- different questions for two different kinds of event.
BoardConfig.LAUNCH_TO_LIVE = 0.3

-- ── staying in sync ───────────────────────────────────────────────────
-- The server's ledger and the client's parts are supposed to agree at
-- all times, and every disagreement so far has been a bug worth fixing
-- at the source. These two are the net under that: whatever goes wrong,
-- the board comes back on its own within a couple of seconds instead of
-- sitting there dead.

-- The board is never legitimately empty — the server queues a
-- replacement the moment the last ball leaves. So if this client has no
-- balls at all for this long, the two sides have diverged and the
-- client asks for the ledger back. Comfortably longer than a launch
-- gap plus a round trip, so ordinary play never trips it.
BoardConfig.EMPTY_BOARD_GRACE = 2.5

-- Never ask for a resync more often than this, whatever asks for it. A
-- resync is cheap but it re-spawns every ball, so a loop that asked for
-- one every frame would be worse than whatever it was fixing.
BoardConfig.RESYNC_COOLDOWN = 3

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
	-- Deliberately not the sell cue: a stash pays nothing, and reusing
	-- that sound made pocketing an orb read as selling it. Still a
	-- placeholder (it's the mimic revert cue) — swap it when there's a
	-- real one.
	stash = { id = "rbxassetid://12222054", volume = 0.6, speed = 1.3 },
	collapseAlarm = { id = "rbxassetid://12221990", volume = 1, speed = 0.7 },
	collapseSell = { id = "rbxassetid://12222170", volume = 1 },
	collapseTick = { id = "rbxassetid://12222170", volume = 1 },
	collapseTension = { id = "rbxassetid://87758060178138", volume = 0.7 },
	collapseMessage = { id = "rbxassetid://135083591486620", volume = 1 },

	-- The bomb. Both of these used to go out through SoundEvents so that
	-- every client built its own Sound rather than waiting on the
	-- server's Play() to replicate — a whole mechanism that existed
	-- because the bomb was a server object. It's a local part on a local
	-- board now, so they're just sounds.
	bombFlicker = { id = "rbxassetid://12221976", volume = 1 },
	bombBoom = { id = "rbxassetid://12222084", volume = 1 },

	-- The magnet. The spawn cue used to go out as a "positional" event
	-- rather than an "attached" one, specifically because the magnet
	-- instance might not have replicated to a given client yet at the
	-- moment it fired — an Instance argument that hasn't arrived reads as
	-- nil there and the sound was silently dropped. Nothing replicates
	-- now, so that whole hazard is gone.
	magnetSpawn = { id = "rbxassetid://12221842", volume = 0.2, speed = 4 },
	magnetPull = { id = "rbxassetid://12222095", volume = 0.7, speed = 3 },
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