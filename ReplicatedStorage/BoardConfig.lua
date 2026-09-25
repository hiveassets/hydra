--[[
    BoardConfig (ModuleScript)
    Path: ReplicatedStorage
    Parent: ReplicatedStorage
    Exported: 2026-09-25 02:23:34
]]
--[[
    BoardConfig (ModuleScript)
    Path: ReplicatedStorage
    Parent: ReplicatedStorage
    Exported: 2026-09-24 20:25:14
]]
--[[
    BoardConfig (ModuleScript)
    Path: ReplicatedStorage
    Parent: ReplicatedStorage
    Exported: 2026-09-23 02:07:55
]]
--[[
    BoardConfig (ModuleScript)
    Path: ReplicatedStorage
    Parent: ReplicatedStorage
    Exported: 2026-09-23 00:26:23
]]
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
--   splitter  2      ← step 3, live
--   merger    1      ← step 4, live
--   mimic     0.05   ← step 5, live
--
-- The radiant variants (step 6) aren't kinds of their own; they're the
-- radiant overlay rolling on top of one of these, gated by
-- BoardRules.radiantSupported, which reads RADIANT_BEHAVIOUR below.
BoardConfig.SPECIAL_WEIGHTS = {
	bomb = 5,
	magnet = 3,
	mimic = 0.05,
	splitter = 2,
	merger = 1,
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
--   noHighlights true if the board never lays a Highlight over it: not
--                the bomb's red hit flash, not the cyan stash pull, not
--                the cyan glow it comes back out of the stash in. A
--                splitter or merger is recognisable by its own pulse, and
--                a fill colour over the top of it drowns that out. It's
--                a tool on the board rather than something things happen
--                TO. (The collapse's magenta is left alone: that's the
--                whole board going, and everything should read the same.)
BoardConfig.LOOK = {
	ball     = { template = "Ball",     ledgerColor = true,  showsSize = true,  selfDriven = false },
	bomb     = { template = "Bomb",     ledgerColor = false, showsSize = false, selfDriven = false },
	magnet   = { template = "Magnet",   ledgerColor = false, showsSize = false, selfDriven = true },
	mimic    = { template = "Mimic",    ledgerColor = true,  showsSize = true,  selfDriven = false },
	splitter = { template = "Splitter", ledgerColor = false, showsSize = false, selfDriven = false, noHighlights = true },
	merger   = { template = "Merger",   ledgerColor = false, showsSize = false, selfDriven = false, noHighlights = true },
}

-- Whether the board may lay a Highlight over an orb of this kind. The one
-- place that question is answered, so the bomb, the stash and anything
-- later all agree.
function BoardConfig.highlightable(kind)
	local look = kind and BoardConfig.LOOK[kind]
	return not (look and look.noHighlights)
end

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
	VFX_START = Color3.fromRGB(255, 136, 0), -- full brightness; these used to be halved to tame the neon
	VFX_END = Color3.fromRGB(255, 0, 0),

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

	-- Which kinds take the push but not the flash is LOOK's noHighlights
	-- (see BoardConfig.highlightable), shared with the stash's highlights.

	-- ── screen shake ──────────────────────────────────────────────────
	-- Amplitude is roughly the peak camera offset in studs, scaled by
	-- the bomb's size so a big one lands harder.
	--
	-- Linear in size. A root curve was tried first and the small end felt
	-- right, but everything above about size 20 came out limp — the
	-- curve flattens exactly where the bombs get interesting.
	--
	--   size    3 → 0.30      size   50 → 2.65
	--   size    5 → 0.40      size  100 → 5.15
	--   size   20 → 1.15      size  400 → 20.15
	--
	-- The low end is within a few hundredths of where the root curve had
	-- it, so what felt good there is unchanged; everything from 10 up
	-- hits harder, and much harder past 50.
	--
	-- No ceiling. There used to be one at 5 studs (size 97), past which
	-- every bomb shook the same; now a bigger bomb always shakes harder.
	-- The radiant splitter and merger set their own small shake outright
	-- (RADIANT_SPLITTER.BLAST_SHAKE_AMPLITUDE) and aren't on this curve.
	SHAKE_BASE = 0.15,     -- floor, so a tiny bomb still registers
	SHAKE_PER_SIZE = 0.05, -- studs per unit of size — the main tuning knob
	SHAKE_TIME = 0.45,
	SHAKE_FREQUENCY = 20, -- noise cycles a second: higher is a rattle, lower is a heave
	SHAKE_ROTATION = 0.8, -- degrees of camera roll per stud of offset
}

-- ── hitstop ───────────────────────────────────────────────────────────
-- Every orb a blast reaches freezes where it is for a beat, trembling,
-- and THEN takes the hit — the fighting-game trick that makes an impact
-- read as heavy. Every explosion does it: a plain bomb, a radiant bomb,
-- and the radiant splitter's and merger's send-offs.
--
-- How long it holds and how hard it trembles both come from the push
-- that orb is about to take — the blast's impulse after falloff, so the
-- orb at the centre of a big bomb freezes longest and one at the edge
-- barely at all. That push is measured against FULL_IMPULSE (a size-20
-- bomb's push at point-blank) and bent by CURVE: under 1 lifts the
-- small end, so a little bomb still visibly catches.
--
--   push                        freeze   tremble
--   size-5 bomb, point-blank    0.11s    0.25 studs
--   size-5 bomb, half radius    0.08s    0.19
--   size-20 bomb, point-blank   0.18s    0.45 (the maximum)
--
-- While frozen it's anchored with collision off, so nothing else can
-- knock it about; its speed from before the blast is kept and handed
-- back, with the push on top, when it lets go. The tremble eases out as
-- the freeze runs down.
BoardConfig.HITSTOP = {
	FULL_IMPULSE = 100000,
	CURVE = 0.5,
	MIN_TIME = 0.03,
	MAX_TIME = 0.18,
	MIN_SHAKE = 0.05, -- studs
	MAX_SHAKE = 0.45,
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
	-- Per stud of the magnet's CURRENT size, per second, no distance falloff.
	--
	-- 20, not MagnetFuse's 10, and the formula is otherwise identical. The
	-- same number pulls noticeably weaker on a local board, because the
	-- old one wasn't really applying it as written. The server added the
	-- pull to its OWN copy of each orb's velocity, which only caught up
	-- with the real physics now and then, and wrote that back over the
	-- top — so friction with the platform, which on your own machine eats
	-- tens of studs/s² off an orb sliding along it, mostly never got a
	-- say. Locally the physics is honest and friction takes its cut every
	-- step. Doubling it is a first guess at where it felt right; this is
	-- the number to tune, and RADIANT_MAGNET.PULL_ACCEL keeps its 3x.
	PULL_ACCEL = 20,

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

-- ── splitter ──────────────────────────────────────────────────────────
-- Every number lifted from SplitterFuse unchanged. A splitter launches
-- and settles like any orb, wakes as it crosses COL_Y, then pulls any
-- plain orb it touches into itself and splits it in two, shrinking a
-- little with every split until it uses itself up.
--
-- Both sides read SHRINK_PER_SPLIT and FLOOR: the client to animate the
-- shrink and know when to play the send-off, the server to spend the
-- budget. The server's copy is the one that counts.
BoardConfig.SPLITTER = {
	-- dormant → awake: the wake is the COL_Y crossing, same as a ball
	-- regaining collision; splitting also waits for it to be at rest
	-- (see GROUNDED_VY) and for the board to call it settled.
	DEFAULT_COLOR = Color3.fromRGB(152, 0, 255),
	PULSE_COLOR = Color3.fromRGB(255, 0, 255),
	PULSE_TIME = 3, -- one pop-and-decay cycle of the saw-wave pulse

	-- the budget
	SHRINK_PER_SPLIT = 2,
	FLOOR = 5,         -- the split whose shrink would land at or below this spends the splitter
	SHRINK_TIME = 0.15, -- the small ease down after each split, and the final ease to FLOOR
	COOLDOWN = 0.1,     -- at most one split per this long, and one per frame

	-- An orb bigger than this can be split. A 3 is the floor and is
	-- ignored completely — no pull, no cooldown, no shrink.
	MIN_SPLIT_SIZE = 3,

	-- Vertical speed that still counts as "at rest", held for this many
	-- frames in a row AND at least this long. The wake happens on the way
	-- UP through the platform at ~66 studs/s, right inside the settled
	-- pile, and without this it would split whatever it came up under
	-- before it had landed.
	--
	-- Both, because this runs at the player's framerate now, not the
	-- server's fixed 60. The apex of an arc spends about 0.015s under
	-- GROUNDED_VY whatever the framerate: at 240fps that's several frames
	-- (so a frame count alone passes mid-air), and at 20fps a single
	-- frame covers more than that (so a time alone could pass on one
	-- lucky sample). Two frames spanning 1/30s rules out the apex at any
	-- framerate, and something actually resting passes within a few
	-- hundredths of a second.
	GROUNDED_VY = 1.5,
	GROUNDED_FRAMES = 2,
	GROUNDED_TIME = 1 / 30,

	-- The touched orb converges into the splitter's centre, shrinking to
	-- nothing, and the halves appear as it lands. The halves' spawn is
	-- held on the client until this has played out, which is what hides
	-- the round trip.
	CONVERGE_TIME = 0.3,

	-- the send-off, once the budget is spent
	VANISH_TIME = 1,
	VANISH_FLASH_COLOR = Color3.fromRGB(255, 0, 255),
	VANISH_FLASH_START = Color3.new(0, 0, 0),
	VANISH_FLASH_SCALE = 2,

	-- a gentle horizontal pull back toward (0, 0) while awake, stronger
	-- the further out it drifts
	CENTER_PULL_RADIUS = 50,
	CENTER_PULL_MIN_ACCEL = 2,
	CENTER_PULL_MAX_ACCEL = 5,
}

-- ── merger ────────────────────────────────────────────────────────────
-- Every number lifted from MergerFuse unchanged. The splitter's mirror:
-- it waits for TWO orbs touching it at once and turns them into one,
-- sizes simply added. Same lifecycle (see Behaviours → Absorber), its
-- own colours and its own budget.
BoardConfig.MERGER = {
	DEFAULT_COLOR = Color3.fromRGB(152, 255, 0),
	PULSE_COLOR = Color3.fromRGB(0, 255, 255),
	PULSE_TIME = 3,

	-- The budget. Each merge takes a fifth of the merger's ORIGINAL size
	-- off it, so the steps are equal whatever size it spawned at, and the
	-- merge whose shrink would land at or below FLOOR is its last. That's
	-- exactly the 5th for anything big enough; a small one runs out
	-- sooner because the floor bites first (a 10 is worth 4).
	SHRINK_FRACTION = 1 / 5,
	FLOOR = 3,
	SHRINK_TIME = 0.15,
	COOLDOWN = 0.1,

	-- An orb bigger than this can be merged. Deliberately one BELOW the
	-- splitter's floor of 3: a 3 can never be split again, so a merge is
	-- the only way it gets back into play as something bigger. Since no
	-- orb is ever smaller than 3, in practice every orb qualifies.
	MIN_MERGE_SIZE = 2,

	-- Identical to the splitter's, for the identical reason.
	GROUNDED_VY = 1.5,
	GROUNDED_FRAMES = 2,
	GROUNDED_TIME = 1 / 30,

	CONVERGE_TIME = 0.3,

	VANISH_TIME = 1,
	VANISH_FLASH_COLOR = Color3.fromRGB(0, 255, 0), -- lime, the splitter's magenta's opposite
	VANISH_FLASH_START = Color3.new(0, 0, 0),
	VANISH_FLASH_SCALE = 2,

	CENTER_PULL_RADIUS = 50,
	CENTER_PULL_MIN_ACCEL = 2,
	CENTER_PULL_MAX_ACCEL = 5,
}

-- ── mimic ─────────────────────────────────────────────────────────────
-- The numbers more than one script reads. Everything that only the
-- Mimic behaviour cares about (walk speeds, hunt radius, balance
-- recovery...) stays in that module, lifted from MimicFuse unchanged.
BoardConfig.MIMIC = {
	-- How long it passes for an ordinary orb before waking. The server
	-- reads this too: a wake reported sooner is refused.
	WAKE_DELAY = 5,

	-- MimicFuse and MimicLegsClient each had their own copy of these two,
	-- with a comment on both saying they MUST match. Now there's one.
	LEG_LIFT_FRAC = 1.3,    -- how high the body rides once standing, as a fraction of its size

	-- The sprout. A new leg starts every LEG_SPROUT_INTERVAL seconds; each
	-- one grows its upper segment, then its lower one. LEGS_SPROUT_TIME —
	-- how long the body holds still before it rises — is worked out from
	-- these just below this table, so it always covers the last foot
	-- landing: (LEG_COUNT - 1) x interval + upper + lower = 1.5s.
	LEG_COUNT = 3,
	LEG_SPROUT_INTERVAL = 0.5,
	LEG_UPPER_GROW_TIME = 0.25,
	LEG_LOWER_GROW_TIME = 0.25,
	-- Then the body pushes itself up onto its planted feet over this long.
	-- MimicLegsClient holds the feet where they landed for the same span.
	BODY_RISE_TIME = 0.6,

	-- A dormant mimic this far below the platform, or this far from the
	-- centre, is past waking. Falling is the board's business (it splits
	-- like an orb); drifting out just means it never wakes.
	WAKE_MIN_Y = -5,
	MAX_RADIUS = 55, -- an AWAKE one this far out turns back into a plain orb

	-- The eat: the prey floats up into the body under a magenta fade,
	-- then flashes out. Same colour the old mimicAbsorb used.
	EAT_TIME = 0.3,
	EAT_COLOR = Color3.fromRGB(255, 0, 255),
	-- How hard the prey is steered into the body over EAT_TIME. The orb
	-- stays a physics body; this curve goes from no steering (it carries
	-- on rolling, bouncing, falling as it was) to total (it arrives on
	-- time). Exponential In leaves it almost alone for the first half and
	-- then takes it hard, so most of the pull happens late. Raise EAT_TIME
	-- if it reads as a snap rather than a pull.
	EAT_EASING_STYLE = Enum.EasingStyle.Exponential,
	EAT_EASING_DIRECTION = Enum.EasingDirection.In,

	-- It only wakes once it's actually resting on something. Waking in
	-- mid-air — still bouncing, or knocked up — measured the "floor" from
	-- wherever it happened to be, and it stood on the air from then on.
	-- Same gate the splitter and merger use: vertical speed under
	-- GROUNDED_VY for GROUNDED_FRAMES frames spanning GROUNDED_TIME.
	GROUNDED_VY = 1.5,
	GROUNDED_FRAMES = 2,
	GROUNDED_TIME = 1 / 30,

	-- How far down it looks for ground from wherever its body is right
	-- now. The original looked from where it first woke, over a short
	-- reach, and fell back to "the floor is where I am" when it missed —
	-- the other half of standing on the air. Nothing within this reach
	-- means there's nothing under it: it stops holding itself up and
	-- falls.
	GROUND_RAY_REACH = 300,

	-- ── a thrown orb knocks it back ───────────────────────────────────
	-- Carried orbs pass through everything now, so walking an orb into a
	-- mimic doesn't shove it any more. Throwing one at it does instead:
	-- an orb that hits it within KNOCK_WINDOW seconds of leaving your
	-- hands, still moving at KNOCK_MIN_ORB_SPEED or more, knocks it back
	-- along the orb's path, and it flashes magenta. One knock per throw.
	--
	-- It's physics, start to finish. The hit is a real impulse on the
	-- body — KNOCK_IMPULSE_PER_SIZE per point of the ORB's size — so the
	-- same orb sends a small, light mimic much further than a big one.
	-- The speed that gives is capped at KNOCK_MAX_SPEED.
	--
	-- After that, what slows it down is its legs. Its walk servo never
	-- turns off; while it's sliding from a knock, the force it can put
	-- down drops to what KNOCK_SLIP_GRIP (studs/s², per unit of its mass)
	-- allows, so it decelerates steadily while it scrambles to get back to
	-- walking. Full grip comes back once it's moving within
	-- KNOCK_RECOVERED_SPEED of what it's trying to do. Lower grip = a
	-- longer skid; the distance is roughly speed² ÷ (2 × grip).
	KNOCK_WINDOW = 3,
	KNOCK_MIN_ORB_SPEED = 10,
	KNOCK_IMPULSE_PER_SIZE = 60,
	KNOCK_MAX_SPEED = 80,
	KNOCK_SLIP_GRIP = 60,
	KNOCK_RECOVERED_SPEED = 2,
	KNOCK_COLOR = Color3.fromRGB(255, 0, 255),
	KNOCK_FLASH_TRANSPARENCY = 0.25,
	KNOCK_FLASH_TIME = 0.5,

	-- A small screen shake on every hit, the same whatever the orb or the
	-- mimic — feedback that the throw landed, not a measure of how hard.
	-- For scale: the smallest bomb (size 3) shakes at about 0.3, so this
	-- sits just under it. Uses the bomb's shake (BoardEffects.shake), so a
	-- bomb going off at the same moment simply wins.
	KNOCK_SHAKE_AMPLITUDE = 0.25, -- roughly the peak camera offset, in studs
	KNOCK_SHAKE_TIME = 0.2,
	KNOCK_SHAKE_FREQUENCY = 25,   -- a quick rattle rather than a heave
	KNOCK_SHAKE_ROTATION = 0.8,   -- degrees of camera roll per stud of offset
}

-- Read by the Mimic behaviour (and the pet mimic): hold still this long
-- while the legs come out.
BoardConfig.MIMIC.LEGS_SPROUT_TIME = (BoardConfig.MIMIC.LEG_COUNT - 1) * BoardConfig.MIMIC.LEG_SPROUT_INTERVAL
	+ BoardConfig.MIMIC.LEG_UPPER_GROW_TIME
	+ BoardConfig.MIMIC.LEG_LOWER_GROW_TIME

-- ── emerging results ──────────────────────────────────────────────────
-- An orb that comes out of another orb instead of the spawn point: the
-- two halves of a split today, a merge result in step 4. Lifted from
-- BallManager's spawnSplitResult, which is in the first export after
-- all (commit dbc3713).
--
-- It grows from nothing at the place the special was standing WHEN IT
-- ACTED, hopping outward on a hand-simulated arc while it grows, then is
-- handed to ordinary physics with the arc's velocity so the hop carries
-- on seamlessly. Anchored and non-colliding with other orbs until then.
BoardConfig.EMERGE = {
	POP_UP_SPEED = 60, -- studs/s upward at the start of the hop
	POP_H_SPEED = 20,  -- max random outward speed; floored so siblings always clear each other

	-- A freshly emerged orb can't be absorbed again for this long. It's
	-- born inside the reach of whatever made it.
	IMMUNITY = 0.75,

	-- A split whose answer never came back (it was refused) leaves its
	-- emerge site behind; this is how long before it's thrown away.
	SITE_TIMEOUT = 10,
}

-- ── radiant ───────────────────────────────────────────────────────────
-- Rolled independently of the special roll, as an overlay on whatever
-- the slot was going to spawn anyway.
BoardConfig.RADIANT_CHANCE = 0.05
BoardConfig.RADIANT_COOLDOWN = 10
BoardConfig.RADIANT_RESPAWN_DELTAS = { -1, 2 } -- a radiant that falls comes back 1 smaller or 2 bigger

-- Which kinds have a radiant form, and the behaviour module that runs it
-- (ReplicatedStorage → Behaviours → <name>). A radiant special runs this
-- INSTEAD of its stock module, never as well, exactly as the old
-- Radiant<Kind>Fuse replaced <Kind>Fuse.
--
-- This table is the whole switch. BoardRules.radiantSupported reads it,
-- so a kind listed here can roll radiant, be summoned radiant, and be
-- stashed and deployed radiant; a kind missing from it never is. A plain
-- orb is always radiant-capable and isn't listed, because its radiance
-- is only a colour loop the board runs itself. The mimic has no radiant
-- form and never had one.
BoardConfig.RADIANT_BEHAVIOUR = {
	bomb = "RadiantBomb",
	magnet = "RadiantMagnet",
	splitter = "RadiantSplitter",
	merger = "RadiantMerger",
}

-- The six stops a radiant orb's colour loops through, 3s for the round
-- trip. The radiant magnet's idle colour is the same loop.
BoardConfig.RADIANT_COLORS = {
	Color3.fromRGB(255, 0, 0),
	Color3.fromRGB(255, 255, 0),
	Color3.fromRGB(0, 255, 0),
	Color3.fromRGB(0, 255, 255),
	Color3.fromRGB(0, 0, 255),
	Color3.fromRGB(255, 0, 255),
}
BoardConfig.RADIANT_CYCLE_TIME = 3

-- ── radiant bomb ──────────────────────────────────────────────────────
-- Every number lifted from RadiantBombFuse unchanged. Against a plain
-- bomb it differs in five ways:
--
--   * The fuse is twice as long: the same two phases with twice the
--     ticks each (5s), and the last TICK_SPEEDUP_WINDOW seconds speed up
--     to TICK_SPEEDUP_MAX, the tick sound's pitch and the flicker's
--     cadence together. That brings the real fuse in at about 4.6s.
--   * The flicker's lit tick is a rainbow hue rather than red. The hue
--     only moves while a tick is lit, so it doesn't race ahead unseen.
--   * Halfway through, it shrinks to nothing, goes invisible, floats up
--     off the platform and drags every plain orb up after it until it
--     goes off. See PULL_*.
--   * The blast reaches exactly as far as a plain bomb's, but its push
--     grows exponentially with size: IMPULSE_GROWTH per size above
--     SIZE_REF. Left alone that curve dips UNDER a plain bomb's between
--     about size 2 and 20 (a 10 would push half as hard), so a radiant
--     bomb takes whichever of the two is bigger: exactly a plain bomb's
--     push up to about 20, then it runs away — a 30 about 2.7x, a 50
--     about 26x.
--   * The explosion is a rainbow fireball and a white flash, with its
--     own louder boom.
BoardConfig.RADIANT_BOMB = {
	OFF_COLOR = Color3.fromRGB(27, 41, 53), -- a plain bomb's own; only the lit tick is rainbow
	PHASES = {
		{ gap = 0.125, n = 32 },
		{ gap = 0.0625, n = 16 },
	},
	TICK_SPEEDUP_WINDOW = 2, -- the last this-many seconds of the base fuse...
	TICK_SPEEDUP_MAX = 1.5,  -- ...ramp exponentially up to this speed

	-- The flash tick's hue: a full turn per this much LIT time. Each bomb
	-- starts at its own random point on the wheel.
	FLASH_HUE_CYCLE_TIME = 1.5,

	-- the blast
	RADIUS_PER_SIZE = 6,     -- identical to a plain bomb's
	IMPULSE_PER_SIZE = 5000, -- ...and this is a plain bomb's too, used as the baseline below
	SIZE_REF = 1.5,          -- the size at which the two curves agree
	IMPULSE_GROWTH = 1.15,   -- per size above SIZE_REF
	-- 1, not the original's 0.5: it had the same units bug a plain bomb's
	-- fireball had, drawing a sphere half the size of the blast. See
	-- BOMB.VFX_SCALE; that one was fixed in step 1.
	VFX_SCALE = 1,
	VFX_TIME = 0.3,
	FLASH_SCALE = 0.6,
	FLASH_TIME = 0.1,

	-- ── the halfway pull ──────────────────────────────────────────────
	-- Fires at the midpoint of the real (sped-up) fuse, less half the
	-- shrink, so the shrink straddles the middle.
	PULL_SHRINK_TIME = 1.5,
	PULL_ACCEL = 32, -- per stud of the bomb's LEDGER size, per second, no distance falloff
	-- ...and it builds as the bomb floats. On its own, PULL_ACCEL x size is
	-- weaker than gravity for anything under about size 6 (a size 3 pulls
	-- at 96 studs/s², gravity is 196), so a small radiant bomb floated off
	-- and left the orbs it was meant to be hauling on the floor. On top of
	-- it, the pull gains up to PULL_RAMP_GRAVITY x gravity, from nothing
	-- when the float starts to all of it at detonation, eased in
	-- (PULL_RAMP_STYLE, In) so the start of the float is unchanged and it
	-- takes hold as it climbs. At the end every radiant bomb out-pulls
	-- gravity by at least half again, so anything it has hold of comes up
	-- with it.
	PULL_RAMP_GRAVITY = 1.5,
	PULL_RAMP_STYLE = Enum.EasingStyle.Exponential,

	-- Keeping a collapsing sphere sane while it's still a physics body:
	-- it never shrinks below PULL_MIN_SIZE (a near-zero collision shape
	-- is what the solver flings across the map), its mass is held
	-- constant as it shrinks (density rises as volume falls, capped at
	-- Roblox's ceiling), and friction goes up and bounce goes to nothing.
	PULL_MIN_SIZE = 0.75,
	PULL_MAX_DENSITY = 100,
	PULL_FRICTION = 2,
	PULL_FRICTION_WEIGHT = 100,
	PULL_ELASTICITY = 0,
	PULL_ELASTICITY_WEIGHT = 100,

	-- Floating. Gravity is cancelled and replaced by thrust toward a
	-- straight-up PULL_RISE_SPEED, against linear drag PULL_DRAG, all
	-- ramped in from nothing over LIFT_RAMP_TIME. The target speed scales
	-- with the bomb's size, size / SIZE_REF, clamped to
	-- LIFT_SCALE_MIN..MAX — which in practice is the maximum for anything
	-- from size 4 up.
	--
	-- The original scaled it by the bomb's density too, against
	-- LIFT_REF_DENSITY. That worked there because BallManager never gave a
	-- bomb the size-scaled density orbs get, so every bomb had the
	-- template's. ClientBoard gives every kind that density, which falls
	-- steeply with size, so the density term shrank the lift as bombs got
	-- BIGGER: about 1 at size 5, 0.55 at size 10, the 0.5 floor from 11
	-- up. And because the gravity cancellation ramps in with the thrust,
	-- at 0.55 it takes about 1.6s just to leave the ground — the whole
	-- length of the pull. At 2.5 it's off the floor in about 0.6s.
	-- Size alone gives back what the original actually did.
	PULL_RISE_SPEED = 48,
	PULL_DRAG = 2,
	LIFT_RAMP_TIME = 1,
	LIFT_SCALE_MIN = 0.5,
	LIFT_SCALE_MAX = 2.5,

	-- The shine it turns into: pops in at 3x, settles, wobbles, and eases
	-- to nothing on the instant the fuse runs out.
	PULL_HUE_CYCLE_TIME = 3,
	SHINE_SCALE = 0.8, -- of the ledger size
	SHINE_OSC_MIN = 0.9,
	SHINE_OSC_MAX = 1.1,
	SHINE_OSC_HZ = 8,
	SHINE_ENTRANCE_START = 3,
	SHINE_ENTRANCE_TIME = 0.5,
	SHINE_ENTRANCE_STYLE = Enum.EasingStyle.Quad,
	SHINE_EXIT_TIME = 0.5,
	SHINE_EXIT_STYLE = Enum.EasingStyle.Exponential,

	-- StashClient refuses to pocket a radiant bomb once this exists on
	-- it, the same way it refuses a magnet that's Pulling. The name is
	-- StashData.RADIANT_PULL_LIFT_FORCE's and must stay that.
	LIFT_FORCE_NAME = "RadiantPullLiftForce",
}

-- ── radiant magnet ────────────────────────────────────────────────────
-- Every number lifted from RadiantMagnetFuse unchanged. The rise, the
-- wander and the telegraph are a plain magnet's (BoardConfig.MAGNET).
-- What differs:
--
--   * Its idle colour is the radiant orb loop, starting at a random
--     point, and the telegraph wears whatever colour it's showing.
--   * The pull is three times as strong and lasts three times as long.
--   * It pulls EVERYTHING on the board, specials included — only
--     itself and whatever you're holding are spared.
--   * It doesn't hold still while it pulls. It orbits the middle at its
--     wander radius, speeding up the whole time, so a big orb caught in
--     it gets flung rather than just dragged.
--   * Its shine opens white like a plain magnet's, then cycles rainbow.
BoardConfig.RADIANT_MAGNET = {
	PULL_ACCEL = 60,         -- 3x a plain magnet's (see MAGNET.PULL_ACCEL for why that's 20 now)
	PULL_DURATION = 6,       -- 3x a plain magnet's SHRINK_TIME
	ORBIT_START_SPEED = 0.5, -- rad/s
	ORBIT_ACCEL = 0.5,       -- rad/s², for the whole pull
	ORBIT_EASE_TIME = 1.5,   -- the speed eases in from nothing over this long
	ORBIT_EASE_STYLE = Enum.EasingStyle.Sine,

	PULL_HUE_CYCLE_TIME = 3,
	SHINE_SCALE = 1,
	SHINE_OSC_MIN = 0.9,
	SHINE_OSC_MAX = 1.1,
	SHINE_OSC_HZ = 8,
	SHINE_ENTRANCE_START = 3,
	SHINE_ENTRANCE_TIME = 0.5,
	SHINE_ENTRANCE_STYLE = Enum.EasingStyle.Quad,
	SHINE_EXIT_TIME = 0.5,
	SHINE_EXIT_STYLE = Enum.EasingStyle.Quad,
	SHINE_WHITE_TIME = 0.15,
}

-- ── radiant splitter and merger ───────────────────────────────────────
-- Every number lifted from RadiantSplitterFuse and RadiantMergerFuse.
-- Each is its stock counterpart (the same lifecycle, the same grounded
-- gate, cooldown, convergence and centre pull) with these differences:
--
--   * They take anything. Plain orbs, radiant orbs, bombs, magnets that
--     haven't started pulling, mimics awake or asleep, splitters and
--     mergers — everything in RADIANT_ABSORBS. What they never touch is
--     a radiant SPECIAL, which is also what stops a radiant splitter and
--     a radiant merger eating each other.
--   * What goes in decides what comes out. A splitter turns a bomb into
--     three bombs; a merger turns two mimics into one mimic. The merger
--     only takes a pair of the SAME kind.
--   * They make value. The splitter's three results are each ⅔ the size
--     of what went in (double, in total); the merger's one result is the
--     two sizes added plus a third on top.
--   * Results can come out radiant. Each of the splitter's rolls
--     RESULT_RADIANT_CHANCE on its own; the merger's rolls once. If what
--     went in was radiant, the results always are. Either way only for a
--     kind that has a radiant form (so never a mimic).
--   * The merger lasts twice as long: each merge costs a TENTH of the
--     size it was born at, not a fifth.
--   * They're rainbow from the moment they appear — the splitter's wheel
--     turns backwards, the merger's forwards — and they hum.
--   * When the budget runs out they go off: a real blast, BLAST_RADIUS_SIZE
--     bombs' worth of reach with BLAST_IMPULSE_SIZE bombs' worth of push,
--     whatever size the special started at.
BoardConfig.RADIANT_ABSORBS = {
	ball = true,
	bomb = true,
	magnet = true,
	mimic = true,
	splitter = true,
	merger = true,
}

-- A magnet can be taken until its pull starts, which the client knows
-- from its Pulling attribute and the server works out from the clock:
-- WANDER_START_DELAY + WANDER_TIME after it launched. The server allows
-- this much on top, to cover the report being in flight and a magnet
-- that came out of a split and launched a convergence late.
BoardConfig.RADIANT_MAGNET_TAKE_SLACK = 1

local function extend(base, overrides)
	local copy = table.clone(base)
	for key, value in pairs(overrides) do
		copy[key] = value
	end
	return copy
end

local RADIANT_ABSORBER_SHARED = {
	HUE_CYCLE_TIME = 3,
	BLAST_RADIUS_SIZE = 5,
	BLAST_IMPULSE_SIZE = 10,
	-- A send-off rather than a weapon, so barely any camera shake: a
	-- smallest-bomb shake is about 0.3.
	BLAST_SHAKE_AMPLITUDE = 0.08,
	BLAST_SHAKE_TIME = 0.25,
	-- 1, not the original's 0.5 — the same units fix as RADIANT_BOMB's
	VFX_SCALE = 1,
	VFX_TIME = 0.3,
	FLASH_SCALE = 0.6,
	FLASH_TIME = 0.1,
}

BoardConfig.RADIANT_SPLITTER = extend(BoardConfig.SPLITTER, extend(RADIANT_ABSORBER_SHARED, {
	RESULT_COUNT = 3,
	RESULT_RADIANT_CHANCE = 0.25, -- each of the three, on its own
	HUE_DIRECTION = -1,           -- backwards round the wheel
}))

BoardConfig.RADIANT_MERGER = extend(BoardConfig.MERGER, extend(RADIANT_ABSORBER_SHARED, {
	SHRINK_FRACTION = 1 / 10,     -- of its born size, per merge: twice the stock merger's life
	RESULT_RADIANT_CHANCE = 0.5,  -- its one result
	HUE_DIRECTION = 1,
}))

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

-- The client's own copy of that check, for events it starts itself (a
-- splitter absorbing an orb), adds this on top. The server checks when
-- the message ARRIVES, which is always later than when the client
-- decided, so this only has to cover the error in the client's estimate
-- of server time. Without it, an orb the client just saw settle could be
-- a few milliseconds short on the server's clock, the split refused, and
-- the board rebuilt over nothing.
BoardConfig.LIVE_MARGIN = 0.1

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
-- rest of that second's messages are dropped. Roblox itself cuts off
-- around 500. Phase 4 replaces this with per-event limits and reporting.
--
-- This was 40, on the assumption that a busy board sends a handful a
-- second. With specials it doesn't: a splitter or merger can act ten
-- times a second each, and every orb that goes over the edge is a
-- message too. And a dropped message is not harmless here — every one of
-- them is something the client has ALREADY done (an orb pulled into a
-- splitter, an orb gone over the edge), so dropping it leaves an orb the
-- server still counts and nobody can see. That's what stopped the board
-- restocking after a sell-everything. BoardService now rebuilds the
-- board if it ever has to drop one, but the limit shouldn't be what a
-- legitimate board runs into.
BoardConfig.EVENT_RATE_LIMIT = 120

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

	-- The splitter. Played where the absorbed orb was, the moment it's
	-- touched — same place and moment the old "positional" relay used.
	split = { id = "rbxassetid://101410298856316", volume = 1 },

	-- The merger. Played at the merger's centre, where both orbs are
	-- headed — the same place the old positional relay played it.
	merge = { id = "rbxassetid://86932397872773", volume = 1 },

	-- The mimic. The wake cue is the collapse alarm, reused, played flat
	-- as the body starts to rise; the revert cue is the bomb-defuse sound,
	-- played on the orb it turns back into.
	mimicWake = { id = "rbxassetid://12221990", volume = 0.4 },
	mimicRevert = { id = "rbxassetid://12222152", volume = 1 },

	-- The radiant bomb. Its flicker tick is the plain bomb's, pitched up
	-- over the last two seconds; the pull cue and the boom are its own.
	radiantBombPull = { id = "rbxassetid://126727806160402", volume = 1.1, speed = 0.9 },
	radiantBombBoom = { id = "rbxassetid://120604429155099", volume = 2 },

	-- The radiant magnet's pull cue. Its spawn cue is the plain magnet's.
	radiantMagnetPull = { id = "rbxassetid://117163159149291", volume = 1 },

	-- The radiant splitter and merger: a low hum for as long as either is
	-- on the board, and the blast they go out on.
	radiantAbsorberHum = { id = "rbxassetid://139726170556835", volume = 0.1 },
	radiantAbsorberBoom = { id = "rbxassetid://137086138620952", volume = 0.9 },
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