--[[
    BallManager (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-20 20:00:08
]]
--[[
	BallManager (Script) — ServerScriptService

	Keeps a ball on the platform. Balls launch from below the map with no
	collision, regain it partway up, and split into 2 new balls once a
	*settled* ball falls back through the platform (or is destroyed some
	other way first, e.g. knocked out of the world by a bomb — see the
	comment on the Parent check in onHB). Oversized balls grow in
	visually. Every queued spawn has a small chance to come out as a
	bomb instead (fuse/detonation live in BombFuse, not here).

	One shared Heartbeat watches every ball/bomb/mimic (never one
	connection each), and one queue staggers launches so a split reads as
	a quick burst instead of both children popping in at once.
	Special-ball rolls (bomb, magnet, mimic — see SPECIAL_KINDS) are gated
	behind a shared cooldown (SPECIAL_COOLDOWN) so only one special, of any kind, can
	spawn every 10 seconds — the gate is shared across every kind, not
	per-kind, so adding more kinds doesn't raise the overall special rate.
	Rolls also require at least 2 balls already on the board (see
	ballCount/queueSpawn), so a brand-new player can't get a special the
	very first time they knock the lone starter ball off the platform.

	The spawn sound fires whenever a new ball actually lands in the Balls
	folder — the bootstrap ball and a regular fall-off duplication alike
	(splitBall) — but not a SplitterFuse-caused split (spawnSplitResult);
	see the ChildAdded listener and its silentSpawns marker — not
	per-frame, not tied to any Y threshold — and plays from the map's
	fixed spawnsymbol part rather than the ball itself. Regular balls get
	SND_ID; anything else (bombs, magnets, and any future special) gets
	SPECIAL_SND_ID instead.

	Regular balls are capped at MAX_BALLS in play at once (bombs/specials
	don't count against it); crossing the cap auto-sells the smallest one
	through SellService, the same shared sell routine SellHandler uses for
	player-initiated sells — see enforceBallCap.

	MAX_BALLS only caps how many balls exist at once, not how many are
	queued to launch — once the platform's crowded enough that settled
	balls start knocking each other off, each knock-off triggers a split,
	which queues 2 more, which can knock off more, etc., and the queue
	backs up far faster than enforceBallCap's one-at-a-time auto-sell can
	drain it. That runaway queue is also free money (every auto-sell pays
	out), so once it crosses OVERFLOW_THRESHOLD the whole board gets
	wiped for $0 instead — see triggerCollapse. Once every ball from the
	wipe is actually gone, everyone also gets charged a flat $5000
	"world saved" penalty (via SellService.applyCollapsePenalty), so a
	collapse isn't a pure non-event for anyone still standing on an
	empty board. It also owns SpinScale, a shared NumberValue the
	decorative Spin/SpinModel pieces read every heartbeat, so a collapse
	can freeze and un-freeze their rotation too.

	Radiant is not one of the weighted SPECIAL_KINDS below — it's rolled
	independently (RADIANT_CHANCE/RADIANT_COOLDOWN) as an overlay on top
	of whatever this spawn slot would have produced anyway, ball OR
	special alike, rather than a slice of SPECIAL_TOTAL_CHANCE. Every
	radiant behavior script (RadiantFuse for a plain ball, RadiantBombFuse
	for a bomb, and so on) lives grouped together in a "radiant" folder
	under ReplicatedStorage (see radiantFolder below) rather than loose
	at the top level. A plain ball's radiant overlay works by cloning
	RadiantFuse onto it the instant its roll succeeds, rather than baking
	a second template the way bombs/magnets/splitters/mergers still are —
	see spawnBall's `radiant` param. A special ball's own overlay works
	differently, since its normal behavior script (BombFuse, MagnetFuse,
	etc.) is baked directly into ITS template and therefore already
	riding along on every Clone(): going radiant means swapping that
	stock script out for its "Radiant" .. fuseName counterpart (from that
	same radiant folder) instead of cloning one in on top — see
	applyRadiantOverlay. Each SPECIAL_KINDS entry only actually becomes
	eligible for this roll once its own radiant script exists
	(kind.radiantSupported, checked once at startup) — bomb is the first
	kind that has one (RadiantBombFuse); the rest fall back to their
	stock behavior until they get their own.

	A radiant ball that falls off doesn't just teleport back to spawn —
	the falling instance itself gets converted into a regular ball of
	the same size in place (letting void cleanup take it, same as any
	other falling ball), while a fresh radiant is queued at a jittered
	size (RADIANT_RESPAWN_DELTAS) alongside a genuinely new regular ball
	queued in beside it — both go through the same launch queue/stagger
	as any other spawn, rather than the radiant popping in immediately —
	see scheduleRadiantRespawn.
]]

local RS = game:GetService("RunService")
local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local TS = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local BadgeService = game:GetService("BadgeService")

-- THE single source of truth for every collision group in the game, and
-- for every "these two don't collide" rule between them — see its own
-- header. Requiring it is what registers every group and applies every
-- rule, so this script no longer registers or pairs anything itself; the
-- *_GROUP constants below are now just names read off it.
local CG = require(Rep:WaitForChild("CollisionGroups"))

-- config
local SPAWN_POS = Vector3.new(0, -25, 0)
local GROW_Y, COL_Y, FALL_Y = -15, 0.5, - 1      -- grow-tween start / regain collision / re-split
local MAX_DIST_FROM_ORIGIN = 1000                -- straight-line (3D) distance from (0,0,0) beyond which a settled ball also re-splits, same trigger as falling below FALL_Y
local BASE_APEX_HEIGHT, APEX_HEIGHT_PER_STUD, H_SPEED = 36.7, 0.5, 4  -- apex height in studs above SPAWN_POS for a BASE-size (5-stud) ball — matches the old LAUNCH_V=120 flat launch's apex exactly (v^2/2g at default 196.2 gravity), so small balls arc the same as before — plus extra apex height per stud of size beyond BASE (matches the radius that extra stud of size adds, so a bigger ball gets exactly enough headroom to grow into without clipping), max horizontal kick — see launchVel for how these become an actual launch velocity
local GAP = 0.125                                -- seconds between queued launches
local SIZE_VAR, MIN_SIZE, GROW_AT = 2, 3, 8      -- split size jitter, size floor, grow-in cutoff
local GROW_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local MERGE_POP_UP_SPEED, MERGE_POP_H_SPEED = 60, 20 -- upward speed / max random horizontal speed (studs/s) given to a merge result the instant it finishes growing, so it hops instead of just sitting there — see spawnMergeResult
local SPLIT_POP_UP_SPEED, SPLIT_POP_H_SPEED = 60, 20 -- same shape as MERGE_POP_UP_SPEED/H_SPEED above, for spawnSplitResult's own grow-then-shoot-out hop — its own pair (rather than reusing the merge one) so the two stay independently tunable even though they start out equal
local SND_ID, SND_VOL = "rbxassetid://12221967", 1   -- regular ball, fired on ChildAdded, see below
local SPECIAL_SND_ID, SPECIAL_VOL = "rbxassetid://73276365795189", 1 -- any non-regular variant (bomb now, more later)


-- ── special ball config ────────────────────────────────────────────────────────────────────────────────────────────────────

local SPECIAL_TOTAL_CHANCE = 0.15   -- 15% of cleared rolls become some special, no matter how many kinds exist

local BOMB_WEIGHT = 5         -- 1/20 chance
local MAGNET_WEIGHT = 3       -- 1/33.3 chance
local MIMIC_WEIGHT = 0.05     -- 1/2000 chance
local SPLITTER_WEIGHT = 2     -- 1/50 chance
local MERGER_WEIGHT = 1       -- 1/100 chance

-- Radiant is deliberately NOT one of the weighted SPECIAL_KINDS below —
-- it's rolled independently, as an overlay on top of whatever base ball
-- variant would have spawned anyway, so every ball variant automatically
-- gets a radiant version for free instead of needing its own entry in
-- the special-kind pool. See queueSpawn's own radiant roll.
local RADIANT_CHANCE = 0.05                      -- 5% of ball spawns roll radiant, independent of SPECIAL_TOTAL_CHANCE above
local RADIANT_COOLDOWN = 10                      -- seconds between radiant spawns; its own cooldown, separate from SPECIAL_COOLDOWN below

local RADIANT_RESPAWN_DELTAS = { -1, 2 }         -- a radiant ball that falls off respawns 1 stud smaller or 2 studs bigger (50/50) — see scheduleRadiantRespawn
local SPECIAL_COOLDOWN = 10                      -- seconds between special-ball rolls; SHARED across every kind in SPECIAL_KINDS (not per-kind) — only one special total every SPECIAL_COOLDOWN seconds, no matter how many kinds exist
local MAX_BALLS = 50                             -- regular balls only; bombs/specials don't count against this
local BASE_DENSITY = 0.2                         -- template's density at size == BASE; see densityFor below
-- Names only. What each of these groups actually passes through is
-- declared once, in ReplicatedStorage.CollisionGroups' own GROUPS table
-- (each entry carries the explanation that used to live on these lines),
-- so there is exactly one place to read or change it. These locals are
-- kept purely so the ~40 assignment sites further down this file don't
-- all have to be rewritten — CG.Balls and BALLS_GROUP are the same
-- string. A typo like CG.Ballz errors on the spot rather than silently
-- assigning a group that has no rules.
local BALLS_GROUP = CG.Balls
local SPLITTER_ACTIVE_GROUP = CG.SplitterActive
local MERGER_ACTIVE_GROUP = CG.MergerActive
local SPLIT_GROWING_GROUP = CG.SplitGrowing
local RADIANT_PULL_GROUP = CG.RadiantPull
local BG_GROUP = CG.BG
local VISITOR_GROUP = CG.Visitor

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

-- badges
local FALL_BADGE_ID = 1937874786736578 -- awarded to every player in the server once a ball genuinely falls off the platform
local COLLAPSE_BADGE_ID = 3848961087513729 -- awarded to every player once a collapse's applyCollapsePenalty fires
local FALL_BADGE_Y = -10 -- ball must drop below this before FALL_BADGE_ID fires; clears any bounce/settle noise near FALL_Y (-1)

-- overflow collapse (see header) — tune OVERFLOW_THRESHOLD to taste;
-- 150 queued launches is well past anything a normal split cascade
-- should reach
local OVERFLOW_THRESHOLD = 150

-- how long a bribe (see UpgradeData/ShopHandler) suppresses the
-- overflow-collapse trigger for — see checkOverflow and
-- _G.BallManagerBribe below. ShopHandler/SellService keep their own
-- copies of this same number purely for the purchase's chat wording;
-- this is the only copy that actually governs the timing.
local BRIBE_DURATION = 30

-- OVERFLOW_THRESHOLD alone used to be a one-shot trip-wire: the instant
-- #queue ticked past it, even for a single frame, triggerCollapse fired.
-- That's fine for a genuine AFK-farm runaway (queue climbs and stays
-- climbing because nothing's draining it), but a legitimate active-play
-- burst — several radiant balls' stronger push knocking a bunch of
-- settled balls off at once — can also spike #queue past the threshold
-- for a moment before processQueue's own drain (1/GAP = 10 launches/sec)
-- and enforceBallCap bring it back down on their own. A single high
-- snapshot can't tell those two apart; OVERFLOW_SUSTAIN can, by
-- requiring the overflow to still be there after some real time has
-- passed rather than reacting to the very first over-threshold reading.
-- See startCollapseCountdown/checkOverflow below.
local OVERFLOW_SUSTAIN = 3        -- seconds #queue must stay above OVERFLOW_THRESHOLD, continuously, before it actually collapses
local COLLAPSE_SELL_GAP = 0.05    -- delay between each ball's forced $0 sell, smallest to largest
local PRE_COLLAPSE_DELAY = 1      -- beat between the freeze (anchor/mute/desaturate) and the first sell
local PRE_PENALTY_DELAY = 1       -- beat between every ball actually being gone and the $5000-everyone penalty
local POST_COLLAPSE_DELAY = 1     -- beat between the penalty and the fade back to normal
local COLLAPSE_FADE_TIME = 1      -- audio/color/spin fade-back duration
local COLLAPSE_CONTRAST_BOOST = 0.4 -- added on top of whatever Contrast the CC node has during the collapse itself — same as the original file; unrelated to the telegraph's own ramp below
local COLLAPSE_ALARM_SND_ID = "rbxassetid://12221990"
local COLLAPSE_ALARM_VOL = 1      -- tweak to taste
local COLLAPSE_ALARM_SPEED = 0.7  -- PlaybackSpeed, not volume — pitches the alarm down

-- ── collapse telegraph (sustained-overflow countdown) ──────────────
-- Fires the whole time #queue is sitting above OVERFLOW_THRESHOLD, for
-- the same OVERFLOW_SUSTAIN window that already had to elapse before a
-- collapse actually triggered — see startCollapseCountdown/
-- cancelCollapseCountdown near checkOverflow below. HudUI drives the
-- toolbar's collapseCountdown label off the CollapseCountdown attribute
-- this sets; SoundClient plays the per-tick ping and the tension loop
-- off the "flatPitched"/"loopStart"/"loopStop" SoundEvents kinds this
-- fires alongside it.
local COLLAPSE_TICK_SND_ID, COLLAPSE_TICK_VOL = "rbxassetid://12222170", 1 -- same id/kind SoundClient already pre-warms as a flatPitched sound
local COLLAPSE_TELEGRAPH_SATURATION_BOOST = -1 -- how far Saturation ramps from baseline over the countdown, peaking the instant it hits 0 — negative here, so the buildup drains color rather than boosting it, foreshadowing the full-grey cut at 0
local COLLAPSE_TELEGRAPH_CONTRAST_BOOST = 5     -- same idea for Contrast, ramped smoothly tick-to-tick instead of applied as an instant jump
local COLLAPSE_TELEGRAPH_TINT_COLOR = Color3.fromRGB(255, 0, 255) -- pure magenta
local COLLAPSE_TELEGRAPH_TINT_INTENSITY = 0.5      -- 0..1 — how far toward COLLAPSE_TELEGRAPH_TINT_COLOR the CC node's TintColor gets lerped at the peak of the countdown (1 = fully that color the instant it hits 0, 0 = no tint at all); tweak to taste
local COLLAPSE_TELEGRAPH_SHAKE_INTENSITY = 0.25  -- 0..1-ish — how hard the camera shakes at the peak of the countdown, same ramp/cancel timing as the color values above. No natural unit (CollapseEffectsClient turns it into a jitter magnitude); kept here rather than on the client so every telegraph tuning value lives in one place
local COLLAPSE_TELEGRAPH_CANCEL_FADE_TIME = 0.5  -- how long cancelCollapseCountdown eases the CC node and camera shake back to baseline when the queue recovers on its own — deliberately quicker than COLLAPSE_FADE_TIME (a genuine collapse's own fade-back): aborting mid-buildup should read as a quick "false alarm, stand down", not the same leisurely ease a real collapse resolves with
local COLLAPSE_TELEGRAPH_CANCEL_DEBOUNCE = 0.2   -- seconds the queue must stay at/under OVERFLOW_THRESHOLD before checkOverflow actually cancels the telegraph — see checkOverflow for why this exists
local COLLAPSE_TENSION_SND_ID, COLLAPSE_TENSION_VOL = "rbxassetid://87758060178138", 0.7

-- safety net for splitBall's source ball (see there): how long to wait
-- before destroying it ourselves if Roblox's own void cleanup
-- (FallenPartsDestroyHeight) never got around to it — generous on
-- purpose, well past how long any genuine fall off the platform takes
-- under gravity, so this never fires for a real fall.
local VOID_FALLBACK_TIMEOUT = 5

-- setup: templates + shared folder/remote, created once
local ballT, bombT, magnetT, mimicT, splitterT, mergerT = Rep:WaitForChild("Ball"), Rep:WaitForChild("Bomb"), Rep:WaitForChild("Magnet"), Rep:WaitForChild("Mimic"), Rep:WaitForChild("Splitter"), Rep:WaitForChild("Merger")

-- every radiant-specific behavior script (RadiantFuse, RadiantBombFuse,
-- and any future Radiant<Kind>Fuse) lives grouped together in this
-- folder rather than loose under ReplicatedStorage — FindFirstChild,
-- not WaitForChild, since going radiant is optional per-kind (see
-- applyRadiantOverlay/spawnBall's own radiant handling below): a
-- missing folder just means nothing currently supports radiant, same
-- as a missing individual script inside it already meant before this
-- folder existed.
local radiantFolder = Rep:FindFirstChild("radiant")
local BASE = ballT.Size.X -- assumes a uniform (cube/sphere) size

local bf = WS:FindFirstChild("Balls") or Instance.new("Folder")
bf.Name, bf.Parent = "Balls", WS
bf:SetAttribute("CollisionRegainY", COL_Y) -- read by SplitterFuse: a splitter activates the instant it crosses this same threshold, not on its own separate timer

-- Collision groups (registration AND every non-collidable pairing) are
-- owned by ReplicatedStorage.CollisionGroups now, not by this script —
-- requiring it at the top of this file is what set all of it up, so the
-- ~60 lines of RegisterCollisionGroup/IsCollisionGroupRegistered/
-- CollisionGroupSetCollidable calls that used to live here are gone. The
-- one part that was never configuration stays: tagging the templates, so
-- every clone starts life in the Balls group before it ever enters
-- Workspace or participates in physics.
for _, template in ipairs({ballT, bombT, magnetT, mimicT, splitterT, mergerT}) do
	if template:IsA("BasePart") then
		template.CollisionGroup = BALLS_GROUP
	end
end

local function prepareBallPhysics(obj)
	-- This is deliberately done before parenting. CanCollide may be enabled
	-- later by onHB, so the collision group must already be correct at that
	-- moment.
	obj.CollisionGroup = BALLS_GROUP
	obj.CanCollide = false
end

local spawnSymbol = WS:WaitForChild("spawnsymbol") -- fixed part; spawn sound plays from here, not the ball itself

-- exposes when this server instance actually started (a Unix-epoch
-- timestamp, same space as os.time()) so clients can compute a real
-- "server age" as workspace:GetServerTimeNow() - this attribute —
-- GetServerTimeNow() alone is just the current Unix timestamp, not time
-- since the server started, which is what HudUI's server-age display
-- mode actually wants.
WS:SetAttribute("ServerStartTime", os.time())
WS:SetAttribute("Collapsing", false) -- mirrors the local `collapsing` flag below for clients (see HudUI's server-age mode)

-- shared with Spin/SpinModel (the decorative spinning pieces) — they
-- read this every heartbeat and scale their own rotation by it; we own
-- creating it and are the only thing that ever writes to it (0 at the
-- moment a collapse starts, tweened back to 1 during the fade-back — see
-- triggerCollapse). Normal value is 1: full speed, untouched.
local spinScale = WS:FindFirstChild("SpinScale") or Instance.new("NumberValue")
spinScale.Name, spinScale.Value, spinScale.Parent = "SpinScale", 1, WS

-- BombFuse + SoundClient both WaitForChild this by name; we own creating it
local se = Rep:FindFirstChild("SoundEvents") or Instance.new("RemoteEvent")
se.Name, se.Parent = "SoundEvents", Rep

-- Fired for every collapse-telegraph/collapse color-grade change instead
-- of the server tweening Lighting.ColorCorrectionEffect directly. A
-- server-driven tween on a replicated instance has to travel server
-- Heartbeat -> network -> client render, and that hop isn't synced to
-- the client's own frame timing, so it reads as jitter under any real
-- network variance. CollapseEffectsClient (new LocalScript, ships
-- separately) owns all the actual tweening locally instead, which is
-- perfectly smooth since nothing has to cross the network mid-tween.
-- It's also the right place to hang future client-only effects like
-- camera shake or FOV changes, which the server can't touch at all.
local vfx = Rep:FindFirstChild("CollapseVisualEffects") or Instance.new("RemoteEvent")
vfx.Name, vfx.Parent = "CollapseVisualEffects", Rep

-- shared with SellHandler; owns payout/broadcast/sound for any sell,
-- player-initiated or (below) auto-sold for the ball cap
local SellService = require(script.Parent:WaitForChild("SellService"))
local MusicManager = require(script.Parent:WaitForChild("MusicManager")) -- only used here for its MasterVolume knob, see collapse mute below

-- instance -> {state="ascending"/"settled", kind="ball"/"bomb"/"mimic", grown=bool}
local tracked = {}
local hbConn

-- balls that shouldn't replay the spawn sound when they land in bf — set
-- by spawnBall/spawnSplitResult for split children, read (and cleared)
-- by bf.ChildAdded below. Deliberately a plain Lua table, not an
-- Attribute: an Attribute lives on the Instance itself, and Clone()
-- copies whatever the source (ballT) currently has, so any stray
-- attribute on the template would silently leak onto every future ball.
-- Weak-keyed so a destroyed/sold ball's entry doesn't linger.
local silentSpawns = setmetatable({}, { __mode = "k" })

-- ball -> function that immediately snaps a still-growing split/merge
-- result (see spawnSplitResult/spawnMergeResult) to its final state:
-- real size, real CollisionGroup, unanchored, velocity handed off.
-- Normally this happens on its own once the grow/shrink tween finishes
-- (or the task.delay fallback fires if Completed never does), but
-- GrabHandler needs to force it early — see _G.FinalizeBallGrowth below
-- for why. Weak-keyed so a ball that finishes/gets destroyed without
-- ever being grabbed doesn't linger here.
local growingResults = setmetatable({}, { __mode = "k" })

local queue = {}     -- FIFO of {size, color, bomb}
local queuing = false

-- exposes the launch queue's live length to clients (HudUI's queue-count
-- display mode) via an attribute on the shared Balls folder, since that's
-- already the one instance both scripts reference. Kept in sync at every
-- site that mutates `queue` below, rather than replicating the queue
-- itself — clients only ever need the count, never its contents.
local function syncQueueCount()
	bf:SetAttribute("QueueCount", #queue)
end
local lastSpecialTime = -SPECIAL_COOLDOWN -- lets the very first roll happen right away
local lastRadiantTime = -RADIANT_COOLDOWN -- same, but for the independent radiant overlay roll (see queueSpawn)

local spawningEnabled = true -- gates queueSpawn; flipped off for the duration of a collapse
local collapsing = false     -- true from the moment the sustained overflow trips triggerCollapse until the board's back to normal

-- ── growth-finalize watchdog ──────────────────────────────────────────
-- obj -> os.clock() time by which its grow MUST have been finalized (see
-- growingResults above). Every split/merge result registers here the
-- moment it starts growing; restoreGroup clears the entry again the
-- moment it finishes normally, so in the common case this loop never
-- touches anything.
--
-- This exists because of WHO OWNS the timers that normally finish a
-- growing result. spawnSplitResult/spawnMergeResult (and their *Kind
-- variants) are called through _G by SplitterFuse/MergerFuse/
-- RadiantSplitterFuse/RadiantMergerFuse, so although the code lives in
-- this script it RUNS on the calling fuse's thread — and in Roblox a
-- connection or a task.delay is owned by the script whose thread created
-- it, not by the script it was written in. The grow tween's Completed
-- connection, the sizeConn CFrame re-pin AND the
-- task.delay(GROW_TWEEN.Time + 0.1) fallback that used to live in those
-- functions were therefore all owned by the splitter/merger, and
-- destroying a Script kills its threads and drops its connections (the
-- same mechanism triggerCollapse/neutralize rely on). A splitter/merger
-- destroyed during the 0.6s its results are still growing took all three
-- with it, leaving each result exactly as it was spawned: Anchored, in
-- SPLIT_GROWING_GROUP, flagged Growing, half-sized, pinned to the dead
-- parent's centre. onHB can't see it fall (anchored), enforceBallCap
-- skips Growing balls, every splitter/merger scan skips them too — so it
-- sat there until a player sold it.
--
-- This loop is owned by THIS script and created once, at load, so it
-- survives any fuse dying. It replaces the per-result task.delay rather
-- than adding to it: that task.delay could never have covered this case.
local GROW_FINALIZE_GRACE = 0.1 -- slack past GROW_TWEEN.Time before stepping in; same margin the old per-result task.delay used
local GROW_WATCH_INTERVAL = 0.1 -- sweep interval; deliberately not per-frame — this is a rare-failure net, not bookkeeping
local growDeadlines = setmetatable({}, { __mode = "k" }) -- weak-keyed, same as growingResults

task.spawn(function()
	while true do
		task.wait(GROW_WATCH_INTERVAL)
		if next(growDeadlines) ~= nil then
			local now = os.clock()
			for obj, deadline in pairs(growDeadlines) do
				if not obj.Parent then
					-- sold/destroyed mid-grow: nothing to finalize, stop watching
					growDeadlines[obj] = nil
					growingResults[obj] = nil
				elseif now >= deadline and not collapsing then
					-- mid-collapse is skipped rather than cleared:
					-- triggerCollapse just anchored the whole board on
					-- purpose, and unanchoring one ball back out of that
					-- freeze is the last thing wanted. collapseSell gets it
					-- within a couple of seconds either way, and the Parent
					-- branch above then drops the entry.
					local finalize = growingResults[obj]
					growDeadlines[obj] = nil
					if finalize then
						growingResults[obj] = nil
						finalize() -- snaps size/CFrame, unanchors, restores the collision group, re-attaches any deferred fuse
					end
				end
			end
		end
	end
end)

-- os.clock() timestamp of when a bought bribe's immunity window ends;
-- 0 means no bribe is currently active. Checked by checkOverflow below,
-- set by _G.BallManagerBribe (see its own header, further down where
-- cancelCollapseCountdown/checkOverflow already exist for it to call)
local bribeActiveUntil = 0

-- ── collapse telegraph state ────────────────────────────────────────
-- collapseCountdownActive is true for the same window overflowSince
-- used to cover (queue continuously over OVERFLOW_THRESHOLD, not yet
-- OVERFLOW_SUSTAIN seconds), just driven by an actual ticking coroutine
-- now instead of a single elapsed-time check — see
-- startCollapseCountdown/cancelCollapseCountdown near checkOverflow.
-- telegraphBaseSaturation/Contrast/Tint are the CC node's TRUE values
-- from right before the telegraph started ramping them up;
-- triggerCollapse reads these back (rather than re-reading cc directly,
-- which by then would just see wherever the ramp happened to land) so
-- its own end-of-collapse fade restores the real baseline. All nil
-- whenever no telegraph is active. There's no server-side tween object
-- to track anymore — the server only ever fires target values/durations
-- over the vfx RemoteEvent; CollapseEffectsClient owns the actual
-- tween and cancelling its own in-flight one before starting the next.
-- collapseCountdownGeneration is bumped every startCollapseCountdown —
-- its own ticking coroutine only keeps ticking while its OWN captured
-- generation is still the current one, not just while
-- collapseCountdownActive is true. That second check matters: if the
-- queue drops under threshold (cancelCollapseCountdown sets active =
-- false) and then climbs back over it again (startCollapseCountdown
-- sets active = true again) before the first coroutine's task.wait(1)
-- has woken up, that stale coroutine would otherwise see
-- collapseCountdownActive back at true, assume nothing happened, and
-- keep ticking right alongside the new one — two coroutines both
-- setting CollapseCountdown and firing the tick sound independently
-- (the double-tick-sound bug this comment is here to prevent a repeat
-- of). Generation-matching catches that: the stale coroutine's captured
-- number no longer equals the counter once a newer telegraph bumped it,
-- so it stops itself even though the shared boolean alone looks "active"
-- again.
local collapseCountdownActive = false
local collapseCountdownGeneration = 0
local telegraphBaseSaturation, telegraphBaseContrast, telegraphBaseTint = nil, nil, nil

-- Mutually-recursive pieces (onHB -> splitBall -> queueSpawn ->
-- processQueue -> spawnBall/spawnBomb -> startHB -> onHB; queueSpawn ->
-- triggerCollapse -> ensureBall -> queueSpawn), so they're declared up
-- front and assigned below in whatever order reads best.
local spawnBall, spawnBomb, spawnMagnet, spawnMimic, spawnSplitter, spawnMerger, queueSpawn, queueRadiant, processQueue, splitBall, onHB, startHB, triggerCollapse, ensureBall

-- same RemoteEvent ShopClient listens on to learn a badge landed
-- without waiting for its next shop open (see ShopClient's
-- badgeAwardedEvent) — WaitForChild rather than creating it here since
-- some other script (e.g. whatever fires it for the mimic-wake case)
-- may own its lifetime; either creation order still resolves fine.
local badgeAwardedEvent = Rep:WaitForChild("BadgeAwarded")

-- shared badge-award tail: wrapped in pcall + task.spawn since it's a
-- yielding web call and shouldn't block or ever error out its caller.
-- AwardBadge is idempotent server-side, so no need to check
-- UserHasBadgeAsync first. Fires badgeAwardedEvent to the player right
-- after a successful award so any client-side gating (e.g. ShopClient's
-- requiresBadge entries) updates immediately instead of only on their
-- next rejoin — GetPlayerByUserId guards the case where they've
-- already left by the time this (async) call resolves.
local function awardBadge(userId, badgeId)
	task.spawn(function()
		local ok, err = pcall(BadgeService.AwardBadge, BadgeService, userId, badgeId)
		if not ok then
			warn("[BallManager] AwardBadge failed for", userId, ":", err)
			return
		end

		local player = Players:GetPlayerByUserId(userId)
		if player then
			badgeAwardedEvent:FireClient(player, badgeId)
		end
	end)
end

-- userId -> true once we've handed them to AwardBadge for FALL_BADGE_ID
-- this server session. AwardBadge is idempotent server-side, so this
-- isn't needed for correctness — it's here because a split cascade can
-- drop many balls per second, and without it every single one would
-- re-fire an AwardBadge call for every player currently in the server.
local awardedFallBadge = {}

-- awards FALL_BADGE_ID to every player currently in the server, called
-- once a ball has genuinely fallen clear of the platform (both onHB
-- paths below — caught via FALL_Y, or already Destroyed before we got
-- there — gate on FALL_BADGE_Y first). Presence-based rather than
-- attribution-based, so no per-ball tracking of any kind is needed —
-- just a GetPlayers() loop, and only ever once per player thanks to
-- awardedFallBadge above.
local function awardFallBadgeToAll()
	for _, player in ipairs(Players:GetPlayers()) do
		if not awardedFallBadge[player.UserId] then
			awardedFallBadge[player.UserId] = true
			awardBadge(player.UserId, FALL_BADGE_ID)
		end
	end
end

-- for the FALL_Y branch only: splitBall leaves the source ball
-- untracked and still falling under gravity (see splitBall) rather
-- than destroying it outright, so its Y hasn't reached FALL_BADGE_Y
-- yet at the moment this is called — just past FALL_Y (-1). Waits a
-- couple Heartbeats for it to actually clear FALL_BADGE_Y (or for it
-- to disappear some other way) before awarding. Short-lived and only
-- ever running for the ball(s) currently mid-fall, never a per-frame
-- cost across the settled pile — the immediate-Destroyed onHB path
-- doesn't need this at all, since Position there is already its final
-- value and can be checked once, directly.
local function watchFallBadge(obj)
	task.spawn(function()
		while obj.Parent and obj.Position.Y >= FALL_BADGE_Y do
			RS.Heartbeat:Wait()
		end
		awardFallBadgeToAll()
	end)
end

-- luminance-weighted grey, same "flat desaturation" look
-- ColorCorrectionEffect's Saturation = -1 produces, used below to grey
-- out anything that bypasses that effect (see collapse-desaturate)
local function toGrey(c)
	local l = c.R * 0.299 + c.G * 0.587 + c.B * 0.114
	return Color3.new(l, l, l)
end

-- awards COLLAPSE_BADGE_ID to every player currently in the server —
-- called right where triggerCollapse fires the penalty itself, so it
-- lines up with "the world got saved" rather than the collapse
-- starting or the board finishing its wipe.
local function awardCollapseBadgeToAll()
	for _, player in ipairs(Players:GetPlayers()) do
		awardBadge(player.UserId, COLLAPSE_BADGE_ID)
	end
end

-- a dormant mimic (mimicT.Name, never having woken — MimicActive never
-- set true) that's confirmed falling off the platform should split
-- exactly like a regular ball would, instead of just disappearing —
-- this IS the "hasn't woken up yet" conversion the game design wants;
-- MimicFuse's own WAKE_MIN_Y check is what cancels its wake attempt at
-- the very same Y<FALL_Y instant this fires for. Deliberately checked
-- here, inside onHB itself, rather than having MimicFuse rename the
-- mimic on its own separately-polling Heartbeat connection: two
-- scripts racing to be the one that reacts first to the same
-- Y<FALL_Y frame is exactly the kind of connection-order-dependent bug
-- that only shows up sometimes. A currently-awake mimic (MimicActive
-- true, renamed to mimicT.Name by MimicFuse on wake) is deliberately
-- excluded — that one should just disappear via void cleanup, same as
-- a bomb, not split.
-- A splitter ball (splitterT.Name == "Splitter") never matches this, so a
-- splitter that falls off the platform just keeps falling to void cleanup
-- untouched — same as a bomb — with no extra case needed here.
local function fallsLikeABall(obj, d)
	return obj.Name == ballT.Name or (d.kind == "mimic" and not obj:GetAttribute("MimicActive"))
end

-- a pet mimic (IsPetMimic attribute — set once, up front, by spawnPetMimic
-- below, and never cleared) never enters the fallsLikeABall path above at
-- all, whether dormant or awake: it's owned by a specific player and is
-- meant to just come back looking exactly like it did when they bought
-- it, not get folded into the regular ball economy by splitting into two
-- ordinary, sellable-by-anyone balls. Checked before fallsLikeABall at
-- both call sites below.
local function isPetMimic(obj)
	return obj:GetAttribute("IsPetMimic") == true
end

-- routes a dying pet mimic (fallen off dormant, defused by a bomb — see
-- BombFuse's revertMimic — or shoved past MIMIC_MAX_RADIUS by
-- PetMimicFuse's own watcher, which mirrors MimicFuse's) to a respawn
-- instead of ever becoming a ball. All three of those triggers just flip
-- MimicActive off (if it was ever on) and otherwise leave the instance
-- exactly where onHB already tracks it — same as an ordinary ball that's
-- about to fall through the platform — so this is the one place that
-- actually decides what "a pet mimic is gone" means, regardless of which
-- of the three triggered it.
--
-- Waits for Y < FALL_BADGE_Y (not the sooner FALL_Y) before actually
-- destroying/respawning, mirroring watchFallBadge below it: gives it the
-- same beat to visibly tumble/fly off the platform under real physics
-- (an explosion's impulse especially) before vanishing, instead of
-- popping out of existence the instant it crosses FALL_Y.
local function schedulePetMimicRespawn(obj)
	local ownerId = obj:GetAttribute("OwnerId")
	task.spawn(function()
		-- obj may already be destroyed (Parent nil) by the time this ever
		-- gets called — same "hard knock cleared the void in one Heartbeat
		-- gap" case the Parent==nil branch above handles for a regular
		-- ball. GetAttribute still works after Destroy(), but Position
		-- isn't guaranteed to keep updating past that point, so this only
		-- polls while it's still genuinely parented; already-gone just
		-- respawns immediately instead of waiting on a Y that'll never
		-- update again.
		while obj.Parent and obj.Position.Y >= FALL_BADGE_Y do
			RS.Heartbeat:Wait()
		end
		if obj.Parent then
			obj:Destroy()
		end
		-- set by PetMimicHandler; guarded in case that script hasn't run
		-- yet somehow — see its own header for why that's not actually a
		-- real race in practice (it always defines this before the first
		-- SpawnPetMimic call, and a respawn can only ever be needed after
		-- at least one of those already happened)
		if _G.RespawnPetMimic then
			_G.RespawnPetMimic(ownerId)
		end
	end)
end

-- converts a radiant ball that's confirmed falling off the platform
-- into a plain regular ball of the same size, in place, instead of
-- Destroy()-ing it — same "cheaper than destroying it ourselves, void
-- cleanup handles it for free" reasoning splitBall's source ball
-- relies on (see there), so this never reads as a teleport back to
-- spawn. RadiantFuse is explicitly Destroy()'d first — renaming alone
-- wouldn't stop its color loop, since it keys off Parent/PendingSell,
-- not Name (see its own stillLive()) — everything else here just
-- mirrors what spawnBall/setDisplay set up for a normal ball (color,
-- numDisplay text), so it doesn't visually read as radiant for the
-- instant before void cleanup gets it. Inlines the same random-color
-- and display-text logic randColor()/setDisplay() use below rather
-- than calling them directly — both are declared further down the
-- file, after this point, so they're not valid upvalues to reach for
-- here.
local function convertRadiantToRegular(obj, size)
	local fuse = obj:FindFirstChild("RadiantFuse")
	if fuse then
		fuse:Destroy()
	end
	obj:SetAttribute("IsRadiant", false)
	obj.Name = ballT.Name -- already true under the overlay model, kept as a defensive no-op
	obj.CollisionGroup = BALLS_GROUP
	obj.Color = Color3.fromHSV(math.random(), 0.5 + math.random() * 0.5, 0.75 + math.random() * 0.25)

	local display = obj:FindFirstChild("display")
	local label = display and display:FindFirstChild("numDisplay")
	if label then
		label.Text = tostring(math.round(size))
	end
end

-- routes a radiant ball that's confirmed falling off the platform (dead
-- Parent caught in the same-Heartbeat-gap edge case, or a genuine
-- FALL_Y crossing) to a resize-and-relaunch instead of splitBall's
-- usual two-child split — checked ahead of fallsLikeABall at both onHB
-- call sites below, same precedence isPetMimic already gets. Waits for
-- Y < FALL_BADGE_Y before acting, same beat-to-visibly-fall reasoning
-- schedulePetMimicRespawn uses.
--
-- Three things happen once it's actually clear of the platform: the
-- falling instance itself becomes a regular ball of the same size
-- (convertRadiantToRegular, above) rather than being destroyed and
-- relaunched from spawn; a fresh radiant is queued (queueRadiant) at
-- currentSize + a RADIANT_RESPAWN_DELTAS roll, same as before but
-- staggered through the launch queue like every other spawn instead of
-- popping in immediately; and a second, genuinely new regular ball
-- queues in alongside it, jittered the same SIZE_VAR way splitBall
-- jitters its own replacement balls — so a radiant falling off reads
-- as "it dropped one, and two more showed up" instead of a single ball
-- just reappearing bigger/smaller.
local function scheduleRadiantRespawn(obj)
	local currentSize = obj:GetAttribute("TargetSize") or BASE
	task.spawn(function()
		while obj.Parent and obj.Position.Y >= FALL_BADGE_Y do
			RS.Heartbeat:Wait()
		end
		if obj.Parent then
			convertRadiantToRegular(obj, currentSize)
		end

		local delta = RADIANT_RESPAWN_DELTAS[math.random(#RADIANT_RESPAWN_DELTAS)]
		local newRadiantSize = math.max(currentSize + delta, MIN_SIZE)
		queueRadiant(newRadiantSize)

		-- same jitter formula splitBall uses for its own replacement
		-- balls, and same randColor() formula inlined for the same
		-- not-yet-in-scope reason convertRadiantToRegular above inlines
		-- it — queueSpawn itself IS safe to call directly here, since
		-- it's one of the functions forward-declared at the top of the
		-- file (see the `local spawnBall, ..., queueSpawn, ...` line)
		local jitter = math.max(math.round(currentSize + (math.random() * SIZE_VAR * 2 - SIZE_VAR)), MIN_SIZE)
		local jitterColor = Color3.fromHSV(math.random(), 0.5 + math.random() * 0.5, 0.75 + math.random() * 0.25)
		queueSpawn(jitter, jitterColor)
	end)
end

-- ── heartbeat: the only per-frame cost in this script ──────────────────
onHB = function()
	for obj, d in pairs(tracked) do
		if not obj.Parent then
			-- normally FALL_Y below catches a settled ball on its way
			-- down, but a hard knock (bomb impulse, especially on a big
			-- ball) can rocket it past FALL_Y *and* Roblox's own void
			-- cleanup (Workspace.FallenPartsDestroyHeight) inside a
			-- single gap between heartbeats — worse under lag, when that
			-- gap is wider. It's already destroyed by the time we get
			-- here instead of caught mid-fall, so split it now instead
			-- of just dropping it. GetAttribute still works after
			-- Destroy() — only Parent/replication get cut, not reads —
			-- which is also how a sold ball opts out below: a "Sold"
			-- attribute set right before Destroy() (see SellHandler)
			-- means selling removes a ball outright instead of
			-- triggering this replacement path. fallsLikeABall (not a
			-- bare Name check) for the same reason the FALL_Y branch
			-- below uses it — see that comment.
			if d.state == "settled" and not obj:GetAttribute("Sold") then
				if isPetMimic(obj) then
					schedulePetMimicRespawn(obj)
				elseif d.radiant then
					scheduleRadiantRespawn(obj)
				elseif fallsLikeABall(obj, d) then
					if obj.Position.Y < FALL_BADGE_Y then
						awardFallBadgeToAll()
					end
					splitBall(obj)
				end
			end
			tracked[obj] = nil

		elseif d.state == "ascending" then
			local y = obj.Position.Y

			-- grow-in starts independently of when collision comes back.
			-- Mimics get this too — they look and behave exactly like a
			-- regular ball for the first few seconds visually (grow-in
			-- tween), but stay named mimicT.Name the whole time (see
			-- MimicFuse) — grow-in doesn't care about Name at all, kept
			-- keyed on d.kind here instead.
			if (d.kind == "ball" or d.kind == "mimic" or d.kind == "petMimic" or d.kind == "splitter" or d.kind == "merger" or d.kind == "bomb") and not d.grown and y > GROW_Y then
				d.grown = true
				local sz = obj:GetAttribute("TargetSize")
				if sz > GROW_AT then
					-- Collision must NOT come back until this tween actually
					-- finishes. GROW_TWEEN's duration is fixed regardless of
					-- size, but ascent speed still increases somewhat with
					-- size (APEX_HEIGHT_PER_STUD), so a big ball can cross
					-- COL_Y well before it's done growing. Enabling CanCollide mid-tween used to mean the
					-- ball kept expanding into the platform/pile *while
					-- already solid* — that's what produced the clip-through/
					-- stuck-under-platform glitches on oversized balls.
					-- colliderReady gates the check below until Completed fires.
					d.colliderReady = false
					local growTween = TS:Create(obj, GROW_TWEEN, { Size = Vector3.new(sz, sz, sz) })
					-- kept on d (not just this local) so _G.FinalizeBallAscent
					-- can Cancel() it if a grab finalizes this ball early —
					-- see that function's own comment below.
					d.growTween = growTween
					growTween.Completed:Connect(function()
						d.colliderReady = true
						d.growTween = nil
						growTween:Destroy()
					end)
					growTween:Play()
				end
			end

			-- Latched, not re-tested every frame. The old condition was
			-- `y > COL_Y and d.colliderReady ~= false`, which silently
			-- required BOTH to be true in the SAME frame. For anything with
			-- TargetSize > GROW_AT, colliderReady stays false for the whole
			-- 0.6s grow tween, leaving only ~0.2s of the launch arc where
			-- both hold. Under load that window closes, y drops back under
			-- COL_Y, and since y never rises again the object is stranded in
			-- "ascending" permanently: CanCollide never comes back, it falls
			-- straight through the platform, and (for a splitter/merger) its
			-- Fuse keeps scanning and splitting the whole way down with a
			-- ground reference far below FALL_Y. Latching the crossing means
			-- a late-finishing grow tween still settles the object.
			if y > COL_Y then
				d.reachedColY = true
			end

			-- d.colliderReady is nil (not false) for anything that never
			-- needed a grow tween, so this reads as "ready" by default.
			if d.reachedColY and d.colliderReady ~= false then
				-- Splitters/mergers must never be promoted back into BALLS_GROUP.
				-- SplitterFuse/MergerFuse also re-pin their own group every
				-- Heartbeat, but this keeps BallManager from creating a
				-- one-frame race at COL_Y.
				if d.kind == "splitter" then
					-- Splitters are already in this group from spawn time; keep the
					-- assignment here as a defensive invariant at activation.
					obj.CollisionGroup = SPLITTER_ACTIVE_GROUP
				elseif d.kind == "merger" then
					-- Same defensive invariant as the splitter branch above —
					-- mergers are already in this group from spawn time.
					obj.CollisionGroup = MERGER_ACTIVE_GROUP
				else
					obj.CollisionGroup = BALLS_GROUP
				end
				-- Ownership is left on Roblox's automatic assignment here too —
				-- forcing server ownership on every settle was what made pushing
				-- feel unresponsive. See spawnBall's comment.
				obj.CanCollide = true
				d.state = "settled"
			end

			-- only other state is "settled": a settled ball falling back
			-- through the platform, OR wandering past MAX_DIST_FROM_ORIGIN
			-- studs from (0,0,0) — a straight-line radius, not just X/Z —
			-- is what triggers a split. fallsLikeABall (not a bare Name
			-- check): a dormant mimic that's falling off without ever
			-- having woken splits exactly like an ordinary ball (see its
			-- own comment above for why that's decided here rather than
			-- by a Name change MimicFuse would have to apply on its own,
			-- racy, Heartbeat). BombFuse's revertMimic renaming a defused
			-- one back to ballT.Name covers the OTHER conversion case
			-- directly, no helper needed for that path. Only a currently-
			-- awake mimic (MimicActive true, named mimicT.Name) is
			-- excluded — that one just disappears via void cleanup
			-- instead, same as a bomb.
		elseif obj.Position.Y < FALL_Y or obj.Position.Magnitude > MAX_DIST_FROM_ORIGIN then
			tracked[obj] = nil
			if isPetMimic(obj) then
				schedulePetMimicRespawn(obj)
			elseif d.radiant then
				scheduleRadiantRespawn(obj)
			elseif fallsLikeABall(obj, d) then
				watchFallBadge(obj)
				splitBall(obj) -- bombs (and an awake mimic) just keep falling; void cleanup handles them
			end
		end
	end

	if next(tracked) == nil then
		hbConn:Disconnect()
		hbConn = nil
	end
end

startHB = function()
	-- `.Connected`, not just a nil check: this is reached through
	-- _G.SpawnSplitResult/SpawnMergeResult too, so hbConn can end up owned
	-- by whichever fuse happened to call track() first after `tracked` last
	-- went empty. Destroying that fuse drops the connection but leaves a
	-- non-nil, dead hbConn here that `hbConn or ...` would never replace.
	if not hbConn or not hbConn.Connected then
		hbConn = RS.Heartbeat:Connect(onHB)
	end
end

-- ── spawning ────────────────────────────────────────────────────────
local function randColor()
	return Color3.fromHSV(math.random(), 0.5 + math.random() * 0.5, 0.75 + math.random() * 0.25)
end

-- counts regular balls actually in the folder right now — used to gate
-- special rolls so a brand-new player can't get a special the very
-- first time they knock a ball off (splitBall's 2 replacement
-- queueSpawn calls aren't forceBall, so without this a 1-ball board
-- could roll special on its very first split). Not filtered by
-- Split/PendingSell/Held the way enforceBallCap is — this is just a
-- coarse "is there already some real activity on the board" check, not
-- an exact in-play count.
local function ballCount()
	local n = 0
	for _, obj in ipairs(bf:GetChildren()) do
		if obj.Name == ballT.Name then
			n += 1
		end
	end
	return n
end

-- Vertical launch speed is derived from the actual apex height we want
-- the ball to reach (v = sqrt(2 * g * h), read off the live Workspace
-- gravity rather than a hardcoded value), instead of tacking a flat
-- extra velocity onto a base speed per stud of size. That old approach
-- scaled VELOCITY linearly with size, but height ∝ velocity^2, so it
-- actually made apex height blow up quadratically — a size-1000+ ball
-- ended up launched thousands of studs into the sky, easily enough to
-- trip MAX_DIST_FROM_ORIGIN before it ever got the chance to settle.
-- Here the apex HEIGHT itself is what scales with size, linearly, so a
-- bigger ball reliably arcs up, clears the platform, and comes back
-- down on top of it instead of overshooting into orbit. Horizontal
-- kick is randomized so queued spawns don't stack dead-center.
local function launchVel(size)
	local a = math.random() * math.pi * 2
	local h = math.random() * H_SPEED
	local apexHeight = BASE_APEX_HEIGHT + math.max(size - BASE, 0) * APEX_HEIGHT_PER_STUD
	local vy = math.sqrt(2 * WS.Gravity * apexHeight)
	return Vector3.new(math.cos(a) * h, vy, math.sin(a) * h)
end

-- shared tail for both spawners: velocity + tracking + heartbeat. Called
-- last so each spawner's own attribute/Parent ordering (see spawnBomb)
-- stays intact either way.
local function track(obj, size, data)
	obj.AssemblyLinearVelocity = launchVel(size)
	tracked[obj] = data
	startHB()
end

-- Self-healing registration for regular balls.
--
-- `tracked` is an internal Lua table, while the Balls folder is the actual
-- source of truth for what exists. SplitterFuse and MergerFuse create/remove
-- balls from other scripts, and under a heavily loaded server their scheduler
-- turns can differ. If a regular Ball ever reaches the folder without getting
-- into `tracked`, onHB can never see it again, so pushing it below FALL_Y will
-- not call splitBall().
--
-- Do not scan the whole folder every Heartbeat: that would add exactly the
-- per-frame work that makes this problem worse. Instead, reconcile once when a
-- regular ball is added, after the current scheduler turn has finished.
local function registerRegularBallIfNeeded(obj)
	if not obj or not obj.Parent or obj.Name ~= ballT.Name then return end
	if obj:GetAttribute("Split") or obj:GetAttribute("Sold") then return end
	if tracked[obj] then return end

	-- Split/Merge results are already settled from BallManager's perspective
	-- even while their visual size tween is running. Ordinary spawned balls are
	-- ascending until onHB reaches COL_Y.
	if obj:GetAttribute("Growing") then
		tracked[obj] = { state = "settled", kind = "ball", grown = true }
	else
		tracked[obj] = { state = "ascending", kind = "ball", grown = false }
	end

	startHB()
end

-- "display" BillboardGui + "numDisplay" TextLabel are expected to live on
-- the Ball template already (Studio-side) — only called from spawnBall,
-- never spawnBomb, so special variants' labels are never touched. Still
-- guarded with FindFirstChild so a template missing the GUI just no-ops
-- instead of erroring. TargetSize itself never changes post-spawn, so the
-- text (which reads off TargetSize) is still just set once — but the
-- part's actual visual Size very much does keep changing after this is
-- called (the ascend grow-tween for an oversized ball, and the 0->size
-- grow tween every split/merge result plays), so the billboard's scale is
-- driven off the part's live Size by the shared driver below instead of
-- being set once off the (not-yet-reached) target — same reasoning that
-- already applied to splitters/mergers, just generalized to every kind.
--
-- DISPLAY_ANCHOR_SIZE/X/Y capture the look that was tuned by hand at a
-- ball size of 5 (X scale 5, Y scale 1.5). DISPLAY_Y_PER_X preserves that
-- exact aspect ratio (1.5/5 = 0.3). DISPLAY_GROWTH_RATE controls how much
-- the display grows per stud of ball growth away from the anchor size —
-- 0.5 means the display only grows/shrinks half as fast as the ball
-- itself, so a size-10 ball (5 studs past the anchor) gets an X scale of
-- 5 + 5*0.5 = 7.5 instead of scaling 1:1 with the ball.
local DISPLAY_ANCHOR_SIZE, DISPLAY_ANCHOR_X, DISPLAY_ANCHOR_Y = 5, 5, 1.5
local DISPLAY_Y_PER_X = DISPLAY_ANCHOR_Y / DISPLAY_ANCHOR_X -- 0.3
local DISPLAY_GROWTH_RATE = 0.5

-- obj -> the size its display was last painted at. Lets the shared driver
-- below skip the overwhelmingly common case — a part whose Size hasn't
-- moved since last frame — without even looking its display up, and keeps
-- an idle board from re-writing (and re-replicating) the same UDim2 every
-- frame. Weak-keyed, same as growingResults/growDeadlines.
local displayScaleAt = setmetatable({}, { __mode = "k" })

local function setDisplayScale(obj, size)
	local display = obj:FindFirstChild("display")
	if display then
		local xScale = DISPLAY_ANCHOR_X + (size - DISPLAY_ANCHOR_SIZE) * DISPLAY_GROWTH_RATE
		display.Size = UDim2.new(xScale, 0, xScale * DISPLAY_Y_PER_X, 0)
	end
	-- recorded even when there's no display to paint, so a display-less part
	-- stops being probed every frame too
	displayScaleAt[obj] = size
end

-- ── shared display-scale driver ───────────────────────────────────────
-- Splitters and mergers resize themselves after spawning (SplitterFuse /
-- MergerFuse shrink them over their active lifetime), magnets keep tweening
-- their own Size, and every regular ball/mimic/split-result/merge-result
-- grows in visually right after spawn (see the comment above setDisplay).
-- None of them can be sized from a single target size at spawn, so the
-- display has to track the part's live Size.
--
-- That used to be a per-part obj:GetPropertyChangedSignal("Size"), hooked up
-- by one bind call in each spawner. Every spawner did call it, and it still
-- only ever worked on splitters/mergers, because of the same thread-ownership
-- rule the growth-finalize watchdog above exists for: a connection belongs to
-- the script whose THREAD created it, not the script it was written in.
-- spawnSplitResult/spawnMergeResult (and their *Kind variants) are called
-- through _G from SplitterFuse/MergerFuse/RadiantSplitterFuse/
-- RadiantMergerFuse, so every split/merge result's display connection was
-- owned by the splitter/merger that produced it — and those are built to
-- shrink to a floor and vanish within seconds, at which point the connection
-- was dropped and that ball's billboard froze at whatever size it had reached
-- mid-grow. spawnBall is exposed to the same thing less obviously: it runs
-- off processQueue, whose thread belongs to whichever script first deferred
-- it, and via onHB -> splitBall -> queueSpawn that can be a fuse too (hbConn
-- is created by whoever calls startHB first — see its own comment). Splitters
-- and mergers were the reliable case because spawnSplitter/spawnMerger are
-- the two that are never reached off a fuse thread.
--
-- So the binding isn't per-part any more. One Heartbeat, connected here at
-- load on THIS script's own thread, repaints every part in the folder whose
-- Size has moved since the last frame. That covers every kind by
-- construction — including pet mimics, which only ever got a one-shot
-- setDisplayScale and never a live binding at all, and including any kind a
-- future spawner forgets to opt in — and nothing else on the board dying can
-- take it down. displayScaleAt above keeps the idle cost at one table lookup
-- per part per frame; bf tops out around MAX_BALLS plus specials, and
-- enforceBallCap/checkOverflow already walk the same folder.
RS.Heartbeat:Connect(function()
	for _, obj in ipairs(bf:GetChildren()) do
		if obj:IsA("BasePart") then
			local size = obj.Size.X
			if displayScaleAt[obj] ~= size then
				setDisplayScale(obj, size)
			end
		end
	end
end)

-- Paints obj's display once, right now, at its current Size. The driver above
-- is what keeps it in step from here on, so this is only about the first
-- frame: several spawners set their display up BEFORE parenting into bf (see
-- spawnSplitter/spawnMerger), and without this they'd show for one frame at
-- whatever size the template happens to carry.
local function primeDisplayScale(obj)
	setDisplayScale(obj, obj.Size.X)
end

local function setDisplay(obj, size)
	local display = obj:FindFirstChild("display")
	local label = display and display:FindFirstChild("numDisplay")
	if label then
		label.Text = tostring(math.round(size))
	end
	primeDisplayScale(obj)
end

-- Roblox mass = density * size^3, so with a flat density every ball's
-- mass grows cubically with size (square-cube law) — fine at small
-- sizes, but past ~50-60 studs it turns pushing a ball into a wall of
-- immovable mass. Scaling density down by (BASE/size)^2 cancels two of
-- those three powers of size, leaving mass = BASE_DENSITY * BASE^2 *
-- size — linear in size instead of cubic. Balls still get heavier as
-- they grow, just not explosively so. Clamped above 0.01 (Roblox's
-- CustomPhysicalProperties floor) so absurdly large balls don't clip to
-- zero density.
local function densityFor(size)
	return math.max(BASE_DENSITY * (BASE / size) ^ 1.8, 0.01)
end

-- Reads the clone's current (template-inherited) friction/elasticity so
-- only density changes — everything else about how the ball feels
-- (grip, bounciness) stays exactly as set up in Studio.
local function applyDensity(obj, size)
	local props = obj.CurrentPhysicalProperties
	obj.CustomPhysicalProperties = PhysicalProperties.new(
		densityFor(size), props.Friction, props.Elasticity, props.FrictionWeight, props.ElasticityWeight
	)
end

-- Only ever called by processQueue, never directly, so launches stay staggered.
-- `silent`, if ever passed true via queueSpawn, marks the ball so the
-- spawn-sound ChildAdded listener skips it. Nothing currently sets this —
-- splitBall's fall-off replacements play the sound normally; only a
-- SplitterFuse-caused split (spawnSplitResult, a separate code path that
-- doesn't go through spawnBall at all) is silenced. Kept as a param in
-- case a future silent spawn path needs it.
--
-- `radiant`, if true, overlays radiant behavior onto this same ball
-- instead of spawning a separate template: RadiantFuse (a standalone
-- script in ReplicatedStorage, same storage convention as PetMimicFuse —
-- NOT baked into any one template, since every ball variant needs to be
-- able to roll radiant) gets cloned in, and IsRadiant is set for
-- anything else (SellService/SellClient's payout multiplier, future
-- per-variant logic) that wants to key off it. numDisplay's text is left
-- completely alone here — RadiantFuse cycles its color instead (see its
-- own header). Falling off the platform is the one behavioral
-- divergence — see scheduleRadiantRespawn, which onHB routes to (via
-- d.radiant) instead of the usual splitBall two-child split.
-- ── radiant overlay for SPECIAL balls (bomb, magnet, mimic, splitter,
-- merger) ────────────────────────────────────────────────────────────
-- The ball-only radiant overlay above (see spawnBall's own `radiant`
-- param) works by cloning RadiantFuse onto a plain ball. A special
-- ball's own behavior script (BombFuse, MagnetFuse, etc.) is baked
-- directly into its template rather than cloned in by BallManager, so
-- every clone comes with its normal fuse already attached — going
-- radiant means swapping that stock fuse for a radiant-specific one,
-- not adding on top of it, since the two behaviors are meant to be
-- mutually exclusive (a bomb is never running both BombFuse and
-- RadiantBombFuse at once).
--
-- `fuseName` is that special's own behavior script's Name exactly as
-- it sits on the template (e.g. "BombFuse") — its radiant counterpart
-- is expected to live in ReplicatedStorage's "radiant" folder as
-- "Radiant" .. fuseName, same folder RadiantFuse itself lives in (see
-- radiantFolder above), rather than a second baked-in template. Must
-- be called BEFORE `obj` is ever parented somewhere that runs scripts
-- (i.e. before obj.Parent = bf) — a Script only starts running once
-- parented into a live container, and `obj` is still just a
-- freshly-made Clone() at the point every spawner below calls this, so
-- swapping its children here is free/invisible.
local function applyRadiantOverlay(obj, fuseName)
	local stockFuse = obj:FindFirstChild(fuseName)
	if stockFuse then
		stockFuse:Destroy()
	end

	local radiantFuse = radiantFolder and radiantFolder:FindFirstChild("Radiant" .. fuseName)
	if radiantFuse then
		radiantFuse:Clone().Parent = obj
	else
		warn(("[BallManager] ReplicatedStorage.radiant.Radiant%s is missing — %s spawned radiant with no radiant behavior script"):format(fuseName, obj.Name))
	end

	obj:SetAttribute("IsRadiant", true)
end

spawnBall = function(size, color, silent, radiant)
	size = size or BASE
	local vis = math.min(size, GROW_AT)

	local ball = ballT:Clone()
	ball.Anchored = false
	prepareBallPhysics(ball)
	ball.Size = Vector3.new(vis, vis, vis)
	ball.Color = color or randColor()
	ball.CFrame = CFrame.new(SPAWN_POS)
	if silent then
		silentSpawns[ball] = true -- read (and cleared) by bf.ChildAdded below
	end
	ball.Parent = bf
	-- Ownership is left on Roblox's automatic assignment (nearest player's
	-- client simulates it) so pushing stays responsive. AFK/ball contact is
	-- already prevented structurally by the AFKPlayers/Balls collision-group
	-- split in AFKHandler, not by pinning ownership to the server here.
	ball:SetAttribute("TargetSize", size)
	setDisplay(ball, size)
	applyDensity(ball, size)

	if radiant then
		ball:SetAttribute("IsRadiant", true)
		local fuse = radiantFolder and radiantFolder:FindFirstChild("RadiantFuse")
		if fuse then
			fuse:Clone().Parent = ball
		else
			warn("[BallManager] ReplicatedStorage.radiant.RadiantFuse is missing — ball spawned radiant with no behavior script")
		end
		-- numDisplay's text is left exactly as setDisplay above wrote it —
		-- RadiantFuse cycles its color, not its content (see RadiantFuse's
		-- own header for why this replaced the old "$$" override)
	end

	-- No Touched connection here (or anywhere else in this file) — see
	-- awardFallBadgeToAll/watchFallBadge above. A per-ball .Touched
	-- listener, even added only once a ball settles, generates enough
	-- touch-pair overhead once the platform's full of overlapping balls
	-- to stall Heartbeat, which is what let balls miss the COL_Y/FALL_Y
	-- checks and fall straight through in the first place. FALL_BADGE_ID
	-- is presence-based (everyone in the server, once a ball clears
	-- FALL_BADGE_Y) so no per-ball attribution tracking is needed at all.
	track(ball, size, { state = "ascending", grown = false, kind = "ball", radiant = radiant or nil })
	return ball
end

-- ── where a growing result sits ───────────────────────────────────────
-- Every result spawner below takes `centerPos`: the CENTRE of the
-- splitter/merger that produced it, captured by that fuse at the moment
-- of the touch. Results emerge from the middle of their parent, not from
-- its feet.
--
-- They used to be bottom-pinned instead — the fuses passed their own
-- bottom (centre minus radius) and the grow kept the result's bottom
-- welded to that line. That was never about where results should appear;
-- it was about the platform. A part grown from size 0 by tweening Size
-- expands equally in every direction around a fixed centre, so a result
-- centred on its parent spends the whole grow with its lower half sunk
-- into the floor — and it's Anchored throughout, so nothing pushes back
-- until restoreGroup unanchors it and the depenetration solver fires it
-- off the platform. That's not hypothetical for a merge: a merge result
-- is 4/3 of both sources combined, so two size-10 mergers make a size-27
-- result whose radius alone is well past the height of the merger's own
-- centre.
--
-- So the centre is used as asked, and raised only when it would put the
-- result's own bottom under the platform line — COL_Y, the same surface
-- reference every spawner here already clamped to. Centred on its parent
-- in the normal case; resting on the floor when it's simply too big to
-- be. Recomputed per frame against the result's CURRENT size, so a big
-- result starts centred (while it's still small) and eases up onto the
-- floor as it grows, rather than snapping.
local function resultCenterY(centerY, currentSize)
	-- the raw floor guard this replaces also caught a parent that was
	-- airborne or had fallen through the platform: a result placed down
	-- there is born "fallen", onHB reads it as a settled ball under FALL_Y
	-- on its very next pass and fires splitBall for 2 replacements, and
	-- because it's anchored for its grow it never reaches void cleanup
	-- either. The fuses all gate on being grounded before they consume
	-- anything now; this is still the belt-and-braces floor behind that.
	return math.max(centerY, COL_Y + currentSize / 2)
end

-- Exposed for SplitterFuse (see its own header) — now the mirror image of
-- spawnMergeResult below rather than its own separate shape: SplitterFuse's
-- own absorb-then-spawn animation already eases the touched ball down to
-- nothing (converging into the splitter) before calling this, so — same as
-- a merge result — this always starts at size 0 and grows outward from
-- `centerPos` (the splitter's own centre — see resultCenterY above), with
-- the same manual hop-arc spawnMergeResult uses, just shot outward along
-- `hopDir` (a horizontal unit vector — the two split halves are each given
-- an opposite `hopDir` by SplitterFuse so the pair visibly shoots apart)
-- instead of a fully random-per-ball direction. See spawnMergeResult's own
-- comment for why the hop has to be simulated by hand while the ball's
-- anchored for the grow. Tracked straight into `tracked` as already
-- "settled" so it falls/splits/merges later through the normal onHB path
-- exactly like any other ball, with no further help from SplitterFuse.
local function spawnSplitResult(centerPos, size, color, hopDir)

	local ball = ballT:Clone()
	prepareBallPhysics(ball)
	-- SPLIT_GROWING_GROUP, not BALLS_GROUP, and CanCollide left true (see
	-- that group's own comment above) — this half spawns right where the
	-- splitter was standing, likely overlapping whatever else is nearby
	-- (its sibling half included), so it needs the same "stay off other
	-- balls while still resting on the platform" treatment a growing
	-- merge result gets.
	ball.CollisionGroup = SPLIT_GROWING_GROUP
	ball.CanCollide = true
	ball.Anchored = true -- pinned for the centre-pinned grow + manual hop below; released by restoreGroup once fully grown
	ball.Size = Vector3.new(0, 0, 0)
	ball.Color = color
	ball.CFrame = CFrame.new(centerPos.X, resultCenterY(centerPos.Y, 0), centerPos.Z)
	ball:SetAttribute("TargetSize", size)
	ball:SetAttribute("Growing", true) -- excludes this ball from enforceBallCap while it's still non-collidable/mid-tween (see restoreGroup below and enforceBallCap's own filter) — a ball that hasn't even finished visually landing shouldn't be eligible to be auto-sold out from under the player
	silentSpawns[ball] = true -- SplitterFuse-caused split — read (and cleared) by bf.ChildAdded below
	ball.Parent = bf
	setDisplay(ball, size)
	applyDensity(ball, size)

	-- hop speed randomized (same as spawnMergeResult's own hopH), but the
	-- direction comes from the caller instead of a fresh random angle per
	-- ball — see header. hopVX/hopVZ are the constant horizontal velocity
	-- components; the vertical side follows ordinary v0*t - 1/2*g*t^2
	-- below, computed by hand since the ball is anchored and can't get
	-- this from real physics yet.
	-- how long the manual arc below actually stays airborne: v0*t - 1/2*g*t^2
	-- returns to 0 at t = 2*v0/g. At the stock numbers that's ~0.61s against a
	-- 0.6s GROW_TWEEN — i.e. the arc touches down within a single frame of the
	-- grow finishing, so the last Size step routinely lands past touchdown. The
	-- arc is CLAMPED to this below rather than reset to zero (see sizeConn), so
	-- a half that touches down keeps the horizontal distance it travelled
	-- instead of teleporting back onto its sibling.
	local hopFlightTime = 2 * SPLIT_POP_UP_SPEED / WS.Gravity

	-- hop speed randomized (same as spawnMergeResult's own hopH), but floored so
	-- this half is guaranteed to clear its own radius (plus a stud of slack) by
	-- touchdown. Both halves spawn on the exact same point and are given
	-- opposite hopDirs, so an unfloored roll near 0 left them still overlapping
	-- when restoreGroup unanchored them into BALLS_GROUP — two solid
	-- interpenetrating spheres going live in the same frame, which the
	-- depenetration solver resolves by firing them off the platform.
	local minHopH = (size / 2 + 1) / hopFlightTime
	local hopH = math.max(minHopH, math.random() * SPLIT_POP_H_SPEED)
	local hopVX, hopVZ = hopDir.X * hopH, hopDir.Z * hopH
	local growStart = os.clock()
	local landed = false -- true once the manual arc below has already settled back at floor level

	-- re-pins the ball's CFrame every time the grow tween touches Size:
	-- X/Z stay at centerPos plus the hop's horizontal drift, Y is
	-- resultCenterY (the splitter's own centre, raised only if this half
	-- would otherwise grow down through the platform) plus the hop's
	-- vertical arc — so it grows outward from the splitter's middle AND
	-- shoots outward at the same time instead of one then the other.
	local sizeConn
	sizeConn = ball:GetPropertyChangedSignal("Size"):Connect(function()
		local currentSize = ball.Size.X
		local elapsed = os.clock() - growStart
		-- arcT freezes at touchdown instead of the whole hop resetting to zero.
		-- The old `landed and 0` snapped X/Z straight back to centerPos, which
		-- put both halves back on the same column at full size right before they
		-- were unanchored.
		local arcT = math.min(elapsed, hopFlightTime)
		if elapsed >= hopFlightTime then
			landed = true
		end
		local hopY = math.max(SPLIT_POP_UP_SPEED * arcT - 0.5 * WS.Gravity * arcT * arcT, 0)
		ball.CFrame = CFrame.new(centerPos.X + hopVX * arcT, resultCenterY(centerPos.Y, currentSize) + hopY, centerPos.Z + hopVZ * arcT)
	end)

	-- once eased up to its real, much larger size, it's safely past the
	-- overlap risk with its sibling/the splitter — rejoin normal
	-- ball-vs-ball collision and hand it back to ordinary physics.
	--
	-- Not safe to rely on grow.Completed alone — same reasoning as
	-- spawnMergeResult: under load this ball can get destroyed or the
	-- tween interrupted before Completed ever fires, leaving it
	-- permanently stuck non-collidable/anchored. restoreGroup is
	-- idempotent and guarded on ball.Parent, so calling it twice (once
	-- from Completed, once from the fallback) is safe.
	local grow = TS:Create(ball, GROW_TWEEN, { Size = Vector3.new(size, size, size) })
	local popped = false -- restoreGroup can legitimately run twice (Completed + the fallback timer) — this keeps the velocity handoff a one-shot
	local function restoreGroup()
		if sizeConn then
			sizeConn:Disconnect()
			sizeConn = nil
		end
		if ball.Parent then
			ball.Anchored = false
			if ball.CollisionGroup == SPLIT_GROWING_GROUP then
				ball.CollisionGroup = BALLS_GROUP
			end
			if not popped then
				popped = true
				-- hand the manual arc's current velocity off to real
				-- physics so the hop continues seamlessly instead of
				-- restarting — if it had already landed, it's just
				-- resting, no velocity to preserve.
				if landed then
					ball.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
				else
					local elapsed = os.clock() - growStart
					local vY = SPLIT_POP_UP_SPEED - WS.Gravity * elapsed
					ball.AssemblyLinearVelocity = Vector3.new(hopVX, vY, hopVZ)
				end
			end
		end
		ball:SetAttribute("Growing", nil)
		growingResults[ball] = nil
		growDeadlines[ball] = nil -- finished normally; nothing for the watchdog to rescue
	end
	grow.Completed:Connect(function()
		restoreGroup()
		grow:Destroy()
	end)
	grow:Play()
	-- Watched by this script's own growth-finalize watchdog (see
	-- growDeadlines) instead of a task.delay created here: this function
	-- runs on the calling splitter/merger's thread, so a task.delay
	-- scheduled from here dies with that script — which is precisely the
	-- case this fallback has to survive.
	growDeadlines[ball] = os.clock() + GROW_TWEEN.Time + GROW_FINALIZE_GRACE

	-- see growingResults' own comment: lets a grab that lands mid-grow
	-- force this straight to its final size/group/position instead of
	-- leaving it half-grown while GrabHandler's CollisionGroup change
	-- fights the still-playing tween and the still-anchored ball.
	growingResults[ball] = function()
		if not ball.Parent then return end
		grow:Cancel()
		ball.Size = Vector3.new(size, size, size)
		ball.CFrame = CFrame.new(centerPos.X, resultCenterY(centerPos.Y, size), centerPos.Z)
		restoreGroup()
	end

	tracked[ball] = { state = "settled", kind = "ball", grown = true }
	startHB()

	return ball
end
_G.SpawnSplitResult = spawnSplitResult

-- Generalizes spawnSplitResult above to any kind, not just a plain ball —
-- added so RadiantSplitterFuse (ReplicatedStorage.radiant.RadiantSplitterFuse)
-- can split specials too — every kind on the board now: bomb, magnet, mimic,
-- splitter and merger alike, not just plain balls the way a stock splitter is
-- limited to. Magnets are the one kind that doesn't take the path below (see
-- the early return, and spawnMagnetResult's own comment: a magnet is placed
-- rather than grown, because MagnetFuse owns its position from the first
-- frame). Same centre-pinned grow-from-zero + manual hop arc as
-- spawnSplitResult (see that function's own comment for the full
-- reasoning — duplicated here rather than factored out, so this stays a
-- single, easy-to-follow function instead of one with a kind-branch
-- threaded through every line of the hop math), just cloning the right
-- template for `kind` and reapplying THAT kind's own spawn-time setup —
-- collision group for splitter/merger (never BALLS_GROUP, same as
-- spawnSplitter/spawnMerger), the numDisplay skip for bomb/splitter/merger,
-- primeDisplayScale for splitter — instead of always assuming
-- ballT/plain-ball defaults.
--
-- `radiant`, if true, spawns this result already-radiant via the same
-- applyRadiantOverlay/RadiantFuse-clone paths spawnBall/spawnBomb/etc. use,
-- so a caller (RadiantSplitterFuse) can guarantee one of several results is
-- radiant without a second pass over it after the fact.
--
-- kind: "ball" | "bomb" | "magnet" | "mimic" | "splitter" | "merger".
local KIND_TEMPLATES = { ball = ballT, bomb = bombT, magnet = magnetT, mimic = mimicT, splitter = splitterT, merger = mergerT }
local KIND_FUSENAME = { bomb = "BombFuse", magnet = "MagnetFuse", mimic = "MimicFuse", splitter = "SplitterFuse", merger = "MergerFuse" }
local KIND_ACTIVE_GROUP = { splitter = SPLITTER_ACTIVE_GROUP, merger = MERGER_ACTIVE_GROUP }

-- ── deferred fuses ────────────────────────────────────────────────────
-- Splitters and mergers are the only two kinds whose behavior script keys
-- off HEIGHT rather than a timer: SplitterFuse/MergerFuse (and their
-- radiant counterparts) sit dormant only until the part crosses COL_Y.
-- For a normally-spawned one that's most of a launch arc away — it starts
-- at SPAWN_POS, far below the map — which is exactly the window their
-- "looks like an ordinary ball for its first second" design assumes.
--
-- A split/merge RESULT has no launch arc. It's placed directly ON the
-- platform, already above COL_Y, so its fuse woke on its very first frame
-- — while the result was still Anchored at size 0 with its grow tween
-- barely started. Everything downstream of that went wrong at once:
--
--   * The grounded gate both fuses use to avoid absorbing before they've
--     come to rest is satisfied trivially by an anchored part, whose
--     AssemblyLinearVelocity is flatly 0 — so it passed after two frames
--     instead of holding the fuse back the way it does for a real landing.
--   * A just-woken result sits in the middle of the pile its parent
--     splitter/merger was standing in, and the touch test is
--     `dist <= r1 + r2` — with r1 near 0 mid-grow, an ordinary ball's own
--     radius alone is enough to match. So it started consuming the pile
--     immediately, one every COOLDOWN (0.1s).
--   * Every one of those shrinks it (SHRINK_PER_SPLIT, or a fifth of its
--     own size per merge), so it crossed its own MIN_SPLITTER_SIZE/
--     MIN_MERGER_SIZE floor and ran its vanish sequence within about a
--     second of spawning. That's the "the result just disappears" bug:
--     a merged merger dies in five merges, i.e. half a second.
--   * Meanwhile each of those events fires its own 0.15s resize tween at
--     the same Size property the grow tween is still animating, while
--     sizeConn re-pins CFrame off every Size change — so the visual is a
--     fight between two tweens on top of that.
--
-- So for these two kinds the fuse is detached before the result is
-- parented and re-attached by restoreGroup, once the result is full size,
-- unanchored, in its real collision group and carrying its hop velocity —
-- i.e. in exactly the state a normally-spawned splitter is in at the
-- moment its own fuse would have woken. The fuse then wakes on its next
-- frame (it's above COL_Y, as it should be), and the grounded gate does
-- its real job, because the part is now genuinely moving and has to
-- actually land first.
--
-- Not applied to bomb or mimic results: BombFuse and MimicFuse both run
-- off their own timers from the instant they start, so starting during
-- the grow is exactly the "a split bomb's timer starts from tick zero"
-- behavior that's wanted, and a mimic's wake is seconds out either way.
-- Magnet results never reach this path at all (see spawnMagnetResult).
local KIND_DEFER_FUSE = { splitter = true, merger = true }

-- Pulls every behavior script off `obj` and hands them back for
-- reattachment later. Parent = nil rather than Destroy: the script keeps
-- existing, inert and unrun, and parenting it back starts it fresh. Every
-- BaseScript child rather than a lookup by name, so this doesn't have to
-- know whether the clone ended up with the stock fuse or a radiant one
-- swapped in over it (see applyRadiantOverlay). If the result is destroyed
-- mid-grow, restoreGroup skips the reattach and the detached scripts are
-- simply collected, having never run.
local function detachFuses(obj)
	local detached = {}
	for _, child in ipairs(obj:GetChildren()) do
		if child:IsA("BaseScript") then
			child.Parent = nil
			table.insert(detached, child)
		end
	end
	return detached
end

-- idempotent on purpose: restoreGroup can legitimately run more than once
-- (grow Completed, its fallback timer, a grab finalizing the growth early)
local function attachFuses(obj, detached)
	if not detached then return end
	for _, fuse in ipairs(detached) do
		if fuse.Parent == nil then
			fuse.Parent = obj
		end
	end
end

-- ── magnet results: the one kind that does NOT go through the
-- centre-pinned grow + hop arc both spawnSplitResultKind and
-- spawnMergeResultKind use for everything else.
--
-- A magnet's entire lifecycle — grow-in, rise, wander, telegraph, pull,
-- shrink, self-destruct — belongs to MagnetFuse (see its own header), and
-- that script takes ownership of the magnet's POSITION the moment it
-- starts running: it unanchors the part and steers it with a rigid
-- AlignPosition toward a rise/wander target. Handing a magnet the normal
-- result treatment would mean this function and MagnetFuse both writing
-- the same part's position every frame — the anchored per-frame CFrame
-- re-pin here against the constraint there — which is the exact
-- two-systems-disagree wobble RadiantMagnetFuse's own header describes
-- running into with its orbit.
--
-- So a magnet result is simply PLACED at the splitter's/merger's feet
-- (the same centerPos every other result grows from) in precisely the
-- state spawnMagnet leaves a freshly-rolled magnet in — anchored, at the
-- GROW_AT-capped visual size, TargetSize set before parenting so
-- MagnetFuse reads the real size on its first line — and MagnetFuse
-- corrects the position itself from there, rising straight up out of the
-- pile it was born in. That "its behavior fixes its own position" is why
-- there's nothing here to tween, hop, or restore a collision group for.
--
-- Deliberately NOT tracked (no track()/tracked/startHB), exactly like
-- spawnMagnet: onHB has no magnet branch, and a magnet that never settles
-- or falls would otherwise sit in `tracked` forever. Nothing downstream
-- needs it there — the magnet destroys itself at the end of its pull.
local function spawnMagnetResult(centerPos, size, color, radiant)
	-- placed at its parent's centre like every other result, through the
	-- same resultCenterY clamp — see its own comment. The clamp matters a
	-- little less here (a magnet rises out of wherever it's placed rather
	-- than resting there), but a magnet born under the platform still
	-- spends its whole rise clipping up through it.

	local vis = math.min(size, GROW_AT)

	local magnet = magnetT:Clone()
	magnet.Anchored = true -- MagnetFuse unanchors it itself, once its own travel rig is built
	prepareBallPhysics(magnet)
	magnet.Size = Vector3.new(vis, vis, vis)
	-- centred on its parent, same as every other result
	magnet.CFrame = CFrame.new(centerPos.X, resultCenterY(centerPos.Y, vis), centerPos.Z)
	magnet:SetAttribute("TargetSize", size)
	primeDisplayScale(magnet) -- MagnetFuse keeps tweening Size after this; the shared driver keeps the display in pace with it

	-- a split/merge result inherits the color of what went in, unlike a
	-- rolled magnet — but MagnetFuse/RadiantMagnetFuse both overwrite Color
	-- on their very first frame with their own idle loop, so this only ever
	-- shows for that one frame. Set anyway for consistency with every other
	-- kind, and in case a future magnet fuse ever leaves Color alone.
	magnet.Color = color

	if radiant then
		applyRadiantOverlay(magnet, "MagnetFuse")
	end

	silentSpawns[magnet] = true -- splitter/merger-caused, same as every other result — see bf.ChildAdded
	magnet.Parent = bf -- MagnetFuse starts running here and owns everything from this point on

	return magnet
end

local function spawnSplitResultKind(centerPos, size, color, hopDir, kind, radiant)
	kind = kind or "ball"

	-- magnets take their own path entirely — placed, not grown-and-hopped,
	-- because MagnetFuse owns their position from its first frame. See
	-- spawnMagnetResult's own comment; `hopDir` is deliberately unused for
	-- this kind, since the magnet flies off under its own rise/wander
	-- instead of being fanned out with its siblings.
	if kind == "magnet" then
		return spawnMagnetResult(centerPos, size, color, radiant)
	end

	local template = KIND_TEMPLATES[kind] or ballT


	local obj = template:Clone()
	prepareBallPhysics(obj)
	obj.CollisionGroup = SPLIT_GROWING_GROUP
	obj.CanCollide = true
	obj.Anchored = true -- pinned for the centre-pinned grow + manual hop below; released by restoreGroup once fully grown
	obj.Size = Vector3.new(0, 0, 0)
	obj.Color = color
	obj.CFrame = CFrame.new(centerPos.X, resultCenterY(centerPos.Y, 0), centerPos.Z)
	obj:SetAttribute("TargetSize", size)
	obj:SetAttribute("Growing", true)

	-- Radiant BEFORE parenting, same as every other spawner in this file
	-- (spawnBall/spawnBomb/spawnSplitter all apply it pre-parent). Applying
	-- it after parenting, as this used to, gave the stock fuse a real
	-- scheduler turn to start running before applyRadiantOverlay destroyed
	-- it out from under itself.
	if radiant then
		if kind == "ball" then
			obj:SetAttribute("IsRadiant", true)
			local fuse = radiantFolder and radiantFolder:FindFirstChild("RadiantFuse")
			if fuse then
				fuse:Clone().Parent = obj
			else
				warn("[BallManager] ReplicatedStorage.radiant.RadiantFuse is missing — split result spawned radiant with no behavior script")
			end
		else
			applyRadiantOverlay(obj, KIND_FUSENAME[kind])
		end
	end

	-- held back until this result has actually finished growing — see
	-- KIND_DEFER_FUSE's own comment for what happened when it didn't
	local deferredFuses = KIND_DEFER_FUSE[kind] and detachFuses(obj) or nil

	silentSpawns[obj] = true
	obj.Parent = bf

	-- setDisplay/skip and density follow each kind's own spawnX rules —
	-- bomb/splitter/merger never get a size readout (see spawnBomb/
	-- spawnSplitter/spawnMerger's own comments); splitter's display instead
	-- tracks its own live Size the whole time it's shrinking (see the
	-- shared display-scale driver); every kind gets density.
	if kind == "ball" or kind == "mimic" then
		setDisplay(obj, size)
	elseif kind == "splitter" then
		primeDisplayScale(obj)
	end
	applyDensity(obj, size)

	-- identical hop/grow shape to spawnSplitResult — see its own comment
	-- for the full breakdown of every line below
	local hopFlightTime = 2 * SPLIT_POP_UP_SPEED / WS.Gravity
	local minHopH = (size / 2 + 1) / hopFlightTime
	local hopH = math.max(minHopH, math.random() * SPLIT_POP_H_SPEED)
	local hopVX, hopVZ = hopDir.X * hopH, hopDir.Z * hopH
	local growStart = os.clock()
	local landed = false

	local sizeConn
	sizeConn = obj:GetPropertyChangedSignal("Size"):Connect(function()
		local currentSize = obj.Size.X
		local elapsed = os.clock() - growStart
		local arcT = math.min(elapsed, hopFlightTime)
		if elapsed >= hopFlightTime then
			landed = true
		end
		local hopY = math.max(SPLIT_POP_UP_SPEED * arcT - 0.5 * WS.Gravity * arcT * arcT, 0)
		obj.CFrame = CFrame.new(centerPos.X + hopVX * arcT, resultCenterY(centerPos.Y, currentSize) + hopY, centerPos.Z + hopVZ * arcT)
	end)

	local grow = TS:Create(obj, GROW_TWEEN, { Size = Vector3.new(size, size, size) })
	local popped = false
	local function restoreGroup()
		if sizeConn then
			sizeConn:Disconnect()
			sizeConn = nil
		end
		if obj.Parent then
			obj.Anchored = false
			if obj.CollisionGroup == SPLIT_GROWING_GROUP then
				obj.CollisionGroup = KIND_ACTIVE_GROUP[kind] or BALLS_GROUP
			end
			if not popped then
				popped = true
				if landed then
					obj.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
				else
					local elapsed = os.clock() - growStart
					local vY = SPLIT_POP_UP_SPEED - WS.Gravity * elapsed
					obj.AssemblyLinearVelocity = Vector3.new(hopVX, vY, hopVZ)
				end
			end
			-- last, so a splitter/merger result's fuse starts against a
			-- part that is already full size, unanchored, in its real
			-- collision group and carrying its hop velocity — see
			-- KIND_DEFER_FUSE
			attachFuses(obj, deferredFuses)
		end
		obj:SetAttribute("Growing", nil)
		growingResults[obj] = nil
		growDeadlines[obj] = nil -- finished normally; nothing for the watchdog to rescue
	end
	grow.Completed:Connect(function()
		restoreGroup()
		grow:Destroy()
	end)
	grow:Play()
	-- Watched by this script's own growth-finalize watchdog (see
	-- growDeadlines) instead of a task.delay created here: this function
	-- runs on the calling splitter/merger's thread, so a task.delay
	-- scheduled from here dies with that script — which is precisely the
	-- case this fallback has to survive.
	growDeadlines[obj] = os.clock() + GROW_TWEEN.Time + GROW_FINALIZE_GRACE

	growingResults[obj] = function()
		if not obj.Parent then return end
		grow:Cancel()
		obj.Size = Vector3.new(size, size, size)
		obj.CFrame = CFrame.new(centerPos.X, resultCenterY(centerPos.Y, size), centerPos.Z)
		restoreGroup()
	end

	tracked[obj] = { state = "settled", kind = kind, grown = true }
	startHB()

	return obj
end
_G.SpawnSplitResultKind = spawnSplitResultKind


-- Exposed for MergerFuse (see its own header) — same shape as
-- spawnSplitResult above, just for one result instead of two: places a
-- regular ball directly at `centerPos`, already fully collidable, no
-- ascend-from-below arc. Starts at size 0 — MergerFuse's own convergence
-- animation already eases the two source balls down to nothing before
-- calling this, same as SplitterFuse's own absorb animation does for the
-- one ball it converges — and eases UP to its real `size` with the same
-- GROW_TWEEN oversized balls already grow in with.
--
-- `centerPos` is the MERGER'S OWN CENTRE (per MergerFuse) — the result
-- grows outward around it, so it emerges from the merger's middle rather
-- than its feet. Growing a part from size 0 by tweening Size alone grows
-- equally in every direction around a fixed centre, which is exactly what
-- that wants, except when the result is big enough for its lower half to
-- reach through the platform — see resultCenterY, which is what the
-- per-frame repositioning below actually pins to. Anchored for the
-- duration of the grow so nothing (gravity, an overlapping ball) fights
-- that repositioning; released back to normal physics once it reaches its
-- real size.
--
-- The little upward/horizontal "hop" (MERGE_POP_UP_SPEED/H_SPEED) has
-- to run DURING the grow, not after — but the ball is anchored for the
-- whole grow (see above), so real physics/gravity can't move it; a
-- plain AssemblyLinearVelocity would just sit there doing nothing.
-- Instead the hop is simulated by hand — the same projectile formula
-- gravity would apply — and added on top of the centre-pin every frame
-- (see sizeConn), so it visibly arcs while it's still growing. The
-- instant it's unanchored (restoreGroup), whatever velocity that manual
-- arc was at gets handed to real physics so the motion continues
-- seamlessly instead of restarting from a standstill.
--
-- Tracked straight into `tracked` as already "settled" so it falls/
-- splits/merges later through the normal onHB path exactly like any
-- other ball, with no further help from MergerFuse.
local function spawnMergeResult(centerPos, size, color)

	local ball = ballT:Clone()
	prepareBallPhysics(ball)
	-- SPLIT_GROWING_GROUP, not BALLS_GROUP, and CanCollide left true —
	-- see that group's own comment above. The merge result spawns right
	-- where the merger was standing, likely overlapping whatever else
	-- is nearby, so it needs the same "stay off other balls while still
	-- resting on the platform" treatment a growing split-half gets.
	ball.CollisionGroup = SPLIT_GROWING_GROUP
	ball.CanCollide = true
	ball.Anchored = true -- pinned for the centre-pinned grow + manual hop below; released by restoreGroup once fully grown
	ball.Size = Vector3.new(0, 0, 0)
	ball.Color = color
	ball.CFrame = CFrame.new(centerPos.X, resultCenterY(centerPos.Y, 0), centerPos.Z)
	ball:SetAttribute("TargetSize", size)
	ball:SetAttribute("Growing", true) -- excludes this ball from enforceBallCap while it's still non-collidable/mid-tween (see restoreGroup below and enforceBallCap's own filter) — a ball that hasn't even finished visually landing shouldn't be eligible to be auto-sold out from under the player
	silentSpawns[ball] = true -- MergerFuse-caused merge — read (and cleared) by bf.ChildAdded below
	ball.Parent = bf
	setDisplay(ball, size)
	applyDensity(ball, size)

	-- hop direction/speed, randomized once — same shape launchVel uses
	-- for a fresh spawn's own horizontal kick. hopVX/hopVZ are the
	-- constant horizontal velocity components; the vertical side follows
	-- ordinary v0*t - 1/2*g*t^2 below, computed by hand since the ball
	-- is anchored and can't get this from real physics yet.
	local hopAngle = math.random() * math.pi * 2
	local hopH = math.random() * MERGE_POP_H_SPEED
	local hopVX, hopVZ = math.cos(hopAngle) * hopH, math.sin(hopAngle) * hopH
	local growStart = os.clock()
	-- same touchdown time the split result computes — see spawnSplitResult's
	-- own comment. Only one ball comes out of a merge, so the old reset-to-zero
	-- couldn't stack it on a sibling the way it could for a split pair; it just
	-- teleported the result back to the merger's feet and killed the hop. Fixed
	-- the same way here so both paths behave identically.
	local hopFlightTime = 2 * MERGE_POP_UP_SPEED / WS.Gravity
	local landed = false -- true once the manual arc below has already settled back at floor level

	-- re-pins the ball's CFrame every time the grow tween touches Size:
	-- X/Z stay at centerPos plus the hop's horizontal drift, Y is
	-- resultCenterY (the merger's own centre, raised only if the result
	-- would otherwise grow down through the platform) plus the hop's
	-- vertical arc — so it grows from the merger's middle AND hops at
	-- the same time instead of one then the other.
	local sizeConn
	sizeConn = ball:GetPropertyChangedSignal("Size"):Connect(function()
		local currentSize = ball.Size.X
		local elapsed = os.clock() - growStart
		-- arcT freezes at touchdown rather than resetting the hop to zero — see
		-- spawnSplitResult's own comment.
		local arcT = math.min(elapsed, hopFlightTime)
		if elapsed >= hopFlightTime then
			landed = true
		end
		local hopY = math.max(MERGE_POP_UP_SPEED * arcT - 0.5 * WS.Gravity * arcT * arcT, 0)
		ball.CFrame = CFrame.new(centerPos.X + hopVX * arcT, resultCenterY(centerPos.Y, currentSize) + hopY, centerPos.Z + hopVZ * arcT)
	end)

	-- once eased up to its real, much larger size, it's safely past the
	-- overlap risk with whatever it spawned on top of — rejoin normal
	-- ball-vs-ball collision and hand it back to ordinary physics.
	--
	-- Not safe to rely on grow.Completed alone — same reasoning as
	-- spawnSplitResult above: under load this ball can get destroyed or
	-- the tween interrupted before Completed ever fires, leaving it
	-- permanently stuck non-collidable/anchored. restoreGroup is
	-- idempotent and guarded on ball.Parent, so calling it twice (once
	-- from Completed, once from the fallback) is safe.
	local grow = TS:Create(ball, GROW_TWEEN, { Size = Vector3.new(size, size, size) })
	local popped = false -- restoreGroup can legitimately run twice (Completed + the fallback timer) — this keeps the velocity handoff a one-shot
	local function restoreGroup()
		if sizeConn then
			sizeConn:Disconnect()
			sizeConn = nil
		end
		if ball.Parent then
			ball.Anchored = false
			if ball.CollisionGroup == SPLIT_GROWING_GROUP then
				ball.CollisionGroup = BALLS_GROUP
			end
			if not popped then
				popped = true
				-- hand the manual arc's current velocity off to real
				-- physics so the hop continues seamlessly instead of
				-- restarting — if it had already landed, it's just
				-- resting, no velocity to preserve.
				if landed then
					ball.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
				else
					local elapsed = os.clock() - growStart
					local vY = MERGE_POP_UP_SPEED - WS.Gravity * elapsed
					ball.AssemblyLinearVelocity = Vector3.new(hopVX, vY, hopVZ)
				end
			end
		end
		ball:SetAttribute("Growing", nil)
		growingResults[ball] = nil
		growDeadlines[ball] = nil -- finished normally; nothing for the watchdog to rescue
	end
	grow.Completed:Connect(function()
		restoreGroup()
		grow:Destroy()
	end)
	grow:Play()
	-- Watched by this script's own growth-finalize watchdog (see
	-- growDeadlines) instead of a task.delay created here: this function
	-- runs on the calling splitter/merger's thread, so a task.delay
	-- scheduled from here dies with that script — which is precisely the
	-- case this fallback has to survive.
	growDeadlines[ball] = os.clock() + GROW_TWEEN.Time + GROW_FINALIZE_GRACE

	-- see growingResults' own comment for the general shape. This one
	-- matters more than the split-result version: this ball stays
	-- Anchored=true for its whole grow (see above), and
	-- BasePart:SetNetworkOwner errors outright on an anchored part.
	-- GrabHandler calls SetNetworkOwner as part of granting a hold, so
	-- a grab landing before this ball's grow tween finishes used to
	-- throw mid-request — after heldBy/CollisionGroup/Held were already
	-- set on the server but before ownership or the holder's own
	-- collision group ever got applied, leaving the ball permanently
	-- "held" by nobody: ungrabbable, unsellable, and stuck until that
	-- player happened to respawn, go AFK, or leave (see GrabHandler's
	-- safety nets). Forcing straight to the final, unanchored, correctly
	-- grouped state here — before GrabHandler ever touches
	-- CollisionGroup/NetworkOwner — is what actually closes that hole.
	growingResults[ball] = function()
		if not ball.Parent then return end
		grow:Cancel()
		ball.Size = Vector3.new(size, size, size)
		ball.CFrame = CFrame.new(centerPos.X, resultCenterY(centerPos.Y, size), centerPos.Z)
		restoreGroup()
	end

	tracked[ball] = { state = "settled", kind = "ball", grown = true }
	startHB()

	return ball
end
_G.SpawnMergeResult = spawnMergeResult

-- Generalizes spawnMergeResult above to any kind, not just a plain ball —
-- added so RadiantMergerFuse (ReplicatedStorage.radiant.RadiantMergerFuse)
-- can merge specials too — every kind on the board now: two bombs become one
-- bigger bomb, two magnets one bigger magnet, and so on — not just plain
-- balls the way a stock merger is limited to. Magnets take the same early
-- return out of this function that they take out of spawnSplitResultKind
-- (see spawnMagnetResult). Exactly the same relationship spawnSplitResultKind has to
-- spawnSplitResult, and the same reasoning for duplicating rather than
-- factoring out: the centre-pinned grow-from-zero and the hand-simulated
-- hop arc stay one easy-to-follow function each instead of one with a
-- kind-branch threaded through every line of the hop math.
--
-- Differs from spawnSplitResultKind only in where the hop points: a merge
-- produces ONE result, so its direction is a fresh random angle (same as
-- spawnMergeResult's own), not a caller-supplied `hopDir` used to fan
-- several results apart.
--
-- `radiant`, if true, spawns this result already-radiant via the same
-- applyRadiantOverlay/RadiantFuse-clone paths every other spawner uses —
-- so a merged bomb can come out as a radiant bomb without a second pass
-- over it after the fact. A bomb result is a brand-new Bomb clone either
-- way, so its fuse starts from tick zero: that's the "merged bombs reset
-- the timer" behavior, with nothing to reset by hand.
--
-- kind: "ball" | "bomb" | "magnet" | "mimic" | "splitter" | "merger".
local function spawnMergeResultKind(centerPos, size, color, kind, radiant)
	kind = kind or "ball"

	-- same magnet exception spawnSplitResultKind makes, for the same reason
	-- — see spawnMagnetResult's own comment
	if kind == "magnet" then
		return spawnMagnetResult(centerPos, size, color, radiant)
	end

	local template = KIND_TEMPLATES[kind] or ballT


	local obj = template:Clone()
	prepareBallPhysics(obj)
	obj.CollisionGroup = SPLIT_GROWING_GROUP
	obj.CanCollide = true
	obj.Anchored = true -- pinned for the centre-pinned grow + manual hop below; released by restoreGroup once fully grown
	obj.Size = Vector3.new(0, 0, 0)
	obj.Color = color
	obj.CFrame = CFrame.new(centerPos.X, resultCenterY(centerPos.Y, 0), centerPos.Z)
	obj:SetAttribute("TargetSize", size)
	obj:SetAttribute("Growing", true)

	-- Radiant BEFORE parenting — see spawnSplitResultKind's own copy of this
	-- block for why that ordering matters
	if radiant then
		if kind == "ball" then
			obj:SetAttribute("IsRadiant", true)
			local fuse = radiantFolder and radiantFolder:FindFirstChild("RadiantFuse")
			if fuse then
				fuse:Clone().Parent = obj
			else
				warn("[BallManager] ReplicatedStorage.radiant.RadiantFuse is missing — merge result spawned radiant with no behavior script")
			end
		else
			applyRadiantOverlay(obj, KIND_FUSENAME[kind])
		end
	end

	-- held back until this result has actually finished growing — see
	-- KIND_DEFER_FUSE's own comment
	local deferredFuses = KIND_DEFER_FUSE[kind] and detachFuses(obj) or nil

	silentSpawns[obj] = true -- merger-caused merge — read (and cleared) by bf.ChildAdded below
	obj.Parent = bf

	-- setDisplay/skip and density follow each kind's own spawnX rules —
	-- bomb/splitter/merger never get a size readout; splitter's and merger's
	-- displays instead track their own live Size the whole time they're
	-- shrinking (see the shared display-scale driver); every kind gets density.
	if kind == "ball" or kind == "mimic" then
		setDisplay(obj, size)
	elseif kind == "splitter" or kind == "merger" then
		primeDisplayScale(obj)
	end
	applyDensity(obj, size)

	-- identical hop/grow shape to spawnMergeResult — see its own comment for
	-- the full breakdown of every line below
	local hopAngle = math.random() * math.pi * 2
	local hopH = math.random() * MERGE_POP_H_SPEED
	local hopVX, hopVZ = math.cos(hopAngle) * hopH, math.sin(hopAngle) * hopH
	local growStart = os.clock()
	local hopFlightTime = 2 * MERGE_POP_UP_SPEED / WS.Gravity
	local landed = false

	local sizeConn
	sizeConn = obj:GetPropertyChangedSignal("Size"):Connect(function()
		local currentSize = obj.Size.X
		local elapsed = os.clock() - growStart
		local arcT = math.min(elapsed, hopFlightTime)
		if elapsed >= hopFlightTime then
			landed = true
		end
		local hopY = math.max(MERGE_POP_UP_SPEED * arcT - 0.5 * WS.Gravity * arcT * arcT, 0)
		obj.CFrame = CFrame.new(centerPos.X + hopVX * arcT, resultCenterY(centerPos.Y, currentSize) + hopY, centerPos.Z + hopVZ * arcT)
	end)

	local grow = TS:Create(obj, GROW_TWEEN, { Size = Vector3.new(size, size, size) })
	local popped = false
	local function restoreGroup()
		if sizeConn then
			sizeConn:Disconnect()
			sizeConn = nil
		end
		if obj.Parent then
			obj.Anchored = false
			if obj.CollisionGroup == SPLIT_GROWING_GROUP then
				obj.CollisionGroup = KIND_ACTIVE_GROUP[kind] or BALLS_GROUP
			end
			if not popped then
				popped = true
				if landed then
					obj.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
				else
					local elapsed = os.clock() - growStart
					local vY = MERGE_POP_UP_SPEED - WS.Gravity * elapsed
					obj.AssemblyLinearVelocity = Vector3.new(hopVX, vY, hopVZ)
				end
			end
			-- last, same as spawnSplitResultKind's own — see KIND_DEFER_FUSE
			attachFuses(obj, deferredFuses)
		end
		obj:SetAttribute("Growing", nil)
		growingResults[obj] = nil
		growDeadlines[obj] = nil -- finished normally; nothing for the watchdog to rescue
	end
	grow.Completed:Connect(function()
		restoreGroup()
		grow:Destroy()
	end)
	grow:Play()
	-- Watched by this script's own growth-finalize watchdog (see
	-- growDeadlines) instead of a task.delay created here: this function
	-- runs on the calling splitter/merger's thread, so a task.delay
	-- scheduled from here dies with that script — which is precisely the
	-- case this fallback has to survive.
	growDeadlines[obj] = os.clock() + GROW_TWEEN.Time + GROW_FINALIZE_GRACE

	-- see growingResults' own comment, and spawnMergeResult's note on why
	-- this one matters more than the split-result version: this object stays
	-- Anchored for its whole grow, and SetNetworkOwner errors outright on an
	-- anchored part, so a grab landing mid-grow has to be able to force it
	-- straight to its final state first.
	growingResults[obj] = function()
		if not obj.Parent then return end
		grow:Cancel()
		obj.Size = Vector3.new(size, size, size)
		obj.CFrame = CFrame.new(centerPos.X, resultCenterY(centerPos.Y, size), centerPos.Z)
		restoreGroup()
	end

	tracked[obj] = { state = "settled", kind = kind, grown = true }
	startHB()

	return obj
end
_G.SpawnMergeResultKind = spawnMergeResultKind

-- Exposed for GrabHandler (same _G convention as SpawnSplitResult/
-- SpawnMergeResult above). A split/merge result is already CanCollide
-- = true and tracked as "settled" the instant it's parented (see both
-- spawn functions' own comments) — deliberately so it doesn't read as
-- ungrabbable while sitting right there in plain view, same reasoning
-- that keeps a launched ball's usual CanCollide gate out of this path
-- entirely. That's exactly what makes it grabbable mid-tween, though:
-- CollisionGroup is still SPLIT_GROWING_GROUP (or the ball is still
-- Anchored, for a merge result) until its own shrink/grow finishes.
-- Rather than blocking the grab during that window — which is the one
-- fix this is deliberately NOT — GrabHandler calls this first so the
-- grab always lands on a ball that's already fully settled by the time
-- CollisionGroup/NetworkOwner get touched. No-ops for anything that
-- isn't currently mid-grow.
_G.FinalizeBallGrowth = function(ball)
	local finalize = growingResults[ball]
	if finalize then
		growingResults[ball] = nil
		finalize()
	end
end

-- Exposed for GrabHandler, same _G convention as FinalizeBallGrowth right
-- above — but for the OTHER "not actually settled yet" state: an ordinary
-- spawned ball still mid-launch (tracked "ascending", CanCollide false,
-- possibly still mid grow-in tween). Normally onHB flips it to "settled"
-- on its own once it rises past COL_Y (and its own grow tween, if any,
-- finishes) — see that branch above. This does the exact same two
-- things (CollisionGroup, CanCollide) immediately instead of waiting on
-- the ball's height/tween, and finishes an in-progress grow tween by
-- cancelling it and snapping straight to TargetSize rather than playing
-- it out, so the ball is grabbable the instant it's requested instead of
-- reading as ungrabbable for however long is left of its launch arc.
-- No-op for anything not currently "ascending" (already settled, or
-- never tracked by BallManager at all — e.g. not a real ball).
_G.FinalizeBallAscent = function(obj)
	local d = tracked[obj]
	if not d or d.state ~= "ascending" then return end

	if d.growTween then
		pcall(function() d.growTween:Cancel() end)
		d.growTween = nil
	end

	local sz = obj:GetAttribute("TargetSize")
	if sz then
		obj.Size = Vector3.new(sz, sz, sz)
	end
	d.grown = true
	d.colliderReady = true

	-- same group assignment onHB's own y > COL_Y branch uses
	if d.kind == "splitter" then
		obj.CollisionGroup = SPLITTER_ACTIVE_GROUP
	elseif d.kind == "merger" then
		obj.CollisionGroup = MERGER_ACTIVE_GROUP
	else
		obj.CollisionGroup = BALLS_GROUP
	end
	obj.CanCollide = true
	d.state = "settled"
end

-- Exposed for SplitterFuse (and, identically, MergerFuse) — lets it
-- Destroy() a ball it just split/merged without onHB's own "not
-- obj.Parent" branch mistaking that for an unexpected fall (a hard
-- knock rocketing a ball past FALL_Y and void cleanup in the same
-- Heartbeat gap — see that branch's own comment) and firing off ITS
-- fallback splitBall() too, which would double every splitter-triggered
-- split into 4 balls instead of 2, or spawn a stray extra ball out of
-- one half of a merger's pair. Deliberately a dedicated hook rather
-- than reusing SellHandler's "Sold" attribute for this — "Sold" may
-- carry payout/UI meaning elsewhere that a splitter/merger-caused
-- removal was never meant to trigger.
_G.BallManagerUntrack = function(obj)
	tracked[obj] = nil
end

-- ── orphaned-claim reaper ─────────────────────────────────────────────
-- A splitter/merger claims what it's about to consume by flagging it
-- SplitPending/MergePending, untracking it here, anchoring it, and
-- tweening it down to nothing — then, a third of a second later, its own
-- task.spawn destroys the claimed part and spawns the results. That
-- second half runs inside the splitter's/merger's OWN script, so anything
-- that destroys the special mid-window takes the follow-up thread with it
-- (destroying a Script kills its threads — the same mechanism
-- triggerCollapse leans on to freeze the board). Ways that happens: the
-- special hits its size floor and vanishes, a collapse strips it, a
-- radiant magnet flings it off the platform, a player sells it.
--
-- What's left behind is a part that is anchored, invisible (size 0), no
-- longer in `tracked`, and flagged Pending forever: every other
-- splitter/merger scan skips it on that flag, enforceBallCap skips it
-- (not by name, once it's a special — and a plain ball there is
-- genuinely stuck at size 0), it can't fall to void cleanup because it's
-- anchored, and nothing else in this script was ever going to look at it
-- again. It just sits there occupying the board.
--
-- So this sweeps for them. A claim is only ever a fraction of a second
-- long (SPLIT_CONVERGE_TIME/CONVERGE_TIME are both 0.3), so anything
-- still wearing the flag CLAIM_GRACE seconds later has definitively lost
-- its claimer — the grace window is an order of magnitude past the real
-- thing, so a legitimate in-flight claim can never be caught by it.
--
-- Deliberately a low-frequency timer of its own rather than another
-- branch inside onHB: this is a rare-failure net, not per-frame
-- bookkeeping, and onHB already skips these parts by virtue of them
-- being untracked. Timestamps live in a weak-keyed table so a part that
-- resolves normally (the overwhelmingly common case) is forgotten
-- without this ever touching it.
local CLAIM_GRACE = 3 -- seconds a Split/MergePending flag may persist before its claimer is presumed dead
local CLAIM_SWEEP_INTERVAL = 2
local claimSeenAt = setmetatable({}, { __mode = "k" })

task.spawn(function()
	while true do
		task.wait(CLAIM_SWEEP_INTERVAL)

		local now = os.clock()
		for _, obj in ipairs(bf:GetChildren()) do
			if obj:IsA("BasePart")
				and (obj:GetAttribute("SplitPending") or obj:GetAttribute("MergePending"))
			then
				local seen = claimSeenAt[obj]
				if not seen then
					claimSeenAt[obj] = now
				elseif now - seen >= CLAIM_GRACE then
					-- no results are spawned in its place: the claimer that
					-- would have done that is gone, and inventing them here
					-- would be this script guessing at a split/merge it never
					-- saw the terms of. Untrack first for the same reason
					-- SplitterFuse does — so onHB's "not obj.Parent" branch
					-- doesn't read this removal as an unexpected fall and fire
					-- splitBall's replacements off the back of it.
					claimSeenAt[obj] = nil
					tracked[obj] = nil
					growingResults[obj] = nil
					obj:Destroy()
				end
			end
		end
	end
end)

-- Same launch/collision handling as a ball, now including the same
-- grow-in tween too (see onHB's kind check). BombFuse (cloned in as a
-- child of the template) owns the fuse/detonation entirely once this
-- gets it airborne, and never cares about the bomb's current visual
-- Size at all — it reads size purely off the TargetSize attribute
-- below, which is always the real final size regardless of how far the
-- grow-in tween has gotten, so the blast radius/impulse math is
-- completely unaffected by adding the tween here. TargetSize is set
-- BEFORE parenting — unlike the ball, which sets it after — so BombFuse
-- sees the real size the instant it starts running.
-- `radiant`, if true, swaps the stock BombFuse this clone came with for
-- RadiantBombFuse instead (see applyRadiantOverlay above) — done here,
-- before parenting, so BombFuse never gets a chance to start running in
-- the first place.
spawnBomb = function(size, radiant)
	size = size or BASE
	local vis = math.min(size, GROW_AT)

	local bomb = bombT:Clone()
	bomb.Anchored = false
	prepareBallPhysics(bomb)
	bomb.Size = Vector3.new(vis, vis, vis)
	bomb.CFrame = CFrame.new(SPAWN_POS)
	bomb:SetAttribute("TargetSize", size)
	primeDisplayScale(bomb) -- same ascend grow-tween as a ball; the shared driver keeps the display in step with it, not the not-yet-reached target

	if radiant then
		applyRadiantOverlay(bomb, "BombFuse")
	end

	bomb.Parent = bf
	-- Left on automatic ownership — see spawnBall's comment.

	track(bomb, size, { state = "ascending", grown = false, kind = "bomb" })
	return bomb
end

-- Unlike spawnBall/spawnBomb, this never touches track()/tracked/startHB
-- at all — a magnet has no gravity and no collision (Anchored = true,
-- CanCollide = false), so there's no ascend/settle/fall-through physics
-- for onHB to ever watch here, and therefore no colliderReady-style gate
-- to hang a grow-in tween off of the way onHB does for every tracked
-- kind. It still gets the same GROW_AT vis cap on spawn as everything
-- else, though — MagnetFuse itself (which owns the magnet's entire
-- lifecycle end to end, see its own header) is what tweens it the rest
-- of the way up to TargetSize, right at the start of its own script.
-- Every bit of a magnet's motion (rise, wander, pull, shrink, color
-- loop) lives entirely in MagnetFuse (cloned in as a child of the
-- template, same pattern as BombFuse) — this just places it and hands
-- off.
-- `radiant` — same deal as spawnBomb's own param: swaps stock
-- MagnetFuse for RadiantMagnetFuse (once that script exists — see
-- applyRadiantOverlay) before this is ever parented anywhere that runs
-- scripts.
spawnMagnet = function(size, radiant)
	size = size or BASE
	local vis = math.min(size, GROW_AT)

	local magnet = magnetT:Clone()
	magnet.Anchored = true
	prepareBallPhysics(magnet)
	magnet.Size = Vector3.new(vis, vis, vis)
	magnet.CFrame = CFrame.new(SPAWN_POS)
	magnet:SetAttribute("TargetSize", size)
	primeDisplayScale(magnet) -- MagnetFuse keeps tweening Size after this; the shared driver keeps the display in pace with it

	if radiant then
		applyRadiantOverlay(magnet, "MagnetFuse")
	end

	magnet.Parent = bf

	return magnet
end

-- Same launch/collision/grow-in physics as a regular ball (see onHB's
-- kind checks above). Stays named mimicT.Name (special spawn sound, not
-- sellable, not cap-eligible) for its ENTIRE dormant life, not just the
-- launch/settle animation — a mimic really is a distinct thing the
-- whole time it's asleep, not a disguised ball. Two things ever change
-- that: MimicFuse's own wake sequence a few seconds later (sprouting
-- legs, wandering, absorbing smaller balls — Name stays mimicT.Name
-- throughout, since it's now genuinely an active mimic, not a ball
-- pretending to be one); or, if it's instead confirmed to be falling
-- off the platform without ever having woken, onHB above converts it
-- into a regular ball at that exact instant so it splits like one would
-- (see fallsLikeABall) instead of just disappearing. BombFuse catching
-- it in a blast while awake is the third path (see there). TargetSize/
-- color/display are set here, upfront, exactly like spawnBall.
-- `radiant` — same deal as spawnBomb's own param (swaps stock MimicFuse
-- for RadiantMimicFuse, once that script exists). Applied before
-- parenting, same as everywhere else — see applyRadiantOverlay.
spawnMimic = function(size, radiant)
	size = size or BASE
	local vis = math.min(size, GROW_AT)

	local mimic = mimicT:Clone()
	mimic.Anchored = false
	prepareBallPhysics(mimic)
	mimic.Size = Vector3.new(vis, vis, vis)
	mimic.Color = randColor()
	mimic.CFrame = CFrame.new(SPAWN_POS)
	mimic:SetAttribute("TargetSize", size)
	setDisplay(mimic, size)
	applyDensity(mimic, size)

	if radiant then
		applyRadiantOverlay(mimic, "MimicFuse")
	end

	mimic.Parent = bf
	-- Left on automatic ownership — see spawnBall's comment.

	track(mimic, size, { state = "ascending", grown = false, kind = "mimic" })
	return mimic
end

-- Same launch/collision/grow-in physics as a regular ball (see onHB's
-- kind checks above) — it really is just a regular ball for its first
-- second of life, per design. SplitterFuse (cloned in as a child of the
-- template, same pattern as BombFuse/MagnetFuse) owns everything from
-- there: the wake-up, the pulse, and the split-on-contact behavior. This
-- function never needs to know about any of that. TargetSize/display/
-- density are set exactly like spawnBall's, so it looks and grows in
-- identically until SplitterFuse takes over.
-- `radiant` — same deal as spawnBomb's own param (swaps stock
-- SplitterFuse for RadiantSplitterFuse, once that script exists).
spawnSplitter = function(size, radiant)
	size = size or BASE
	local vis = math.min(size, GROW_AT)

	local splitter = splitterT:Clone()
	splitter.Anchored = false
	prepareBallPhysics(splitter)

	-- A splitter belongs to its dedicated collision group from the instant it
	-- exists. Do NOT leave it in BALLS_GROUP while it is ascending: that makes
	-- the splitter depend on the shared Heartbeat reaching COL_Y before its
	-- collision identity is correct, which is exactly the kind of one-frame
	-- physics race that becomes visible under server load. It still starts with
	-- CanCollide=false, so the group change is harmless until the normal COL_Y
	-- activation below.
	splitter.CollisionGroup = SPLITTER_ACTIVE_GROUP

	splitter.Size = Vector3.new(vis, vis, vis)
	splitter.CFrame = CFrame.new(SPAWN_POS)
	splitter:SetAttribute("TargetSize", size)
	primeDisplayScale(splitter)

	if radiant then
		applyRadiantOverlay(splitter, "SplitterFuse")
	end

	splitter.Parent = bf
	-- Left on automatic ownership — see spawnBall's comment.
	-- Deliberately no setDisplay call — a splitter's numDisplay is left
	-- exactly as the template has it, same as spawnBomb/spawnMagnet
	-- never touching theirs either. It shrinks/vanishes over its life
	-- (see SplitterFuse), so a size readout set once at spawn would just
	-- go stale.
	applyDensity(splitter, size)

	track(splitter, size, { state = "ascending", grown = false, kind = "splitter" })
	return splitter
end

-- Polar opposite of spawnSplitter, in every way that matters here: same
-- launch/collision/grow-in physics as a regular ball for its first
-- second of life (see onHB's kind checks above), same dedicated
-- collision group assigned from the instant it exists rather than at
-- COL_Y (see spawnSplitter's own comment for why that race matters),
-- same TargetSize/density set up front, same deliberate skip of
-- setDisplay. MergerFuse (cloned in as a child of the template, same
-- pattern as BombFuse/MagnetFuse/SplitterFuse) owns everything from
-- COL_Y on: the wake-up, the pulse, and the merge-on-contact behavior.
-- `radiant` — same deal as spawnBomb's own param (swaps stock
-- MergerFuse for RadiantMergerFuse, once that script exists).
spawnMerger = function(size, radiant)
	size = size or BASE
	local vis = math.min(size, GROW_AT)

	local merger = mergerT:Clone()
	merger.Anchored = false
	prepareBallPhysics(merger)

	-- A merger belongs to its dedicated collision group from the instant
	-- it exists — see spawnSplitter's own comment above for why this
	-- can't wait for COL_Y. Still starts with CanCollide=false, so the
	-- group change is harmless until the normal COL_Y activation below.
	merger.CollisionGroup = MERGER_ACTIVE_GROUP

	merger.Size = Vector3.new(vis, vis, vis)
	merger.CFrame = CFrame.new(SPAWN_POS)
	merger:SetAttribute("TargetSize", size)
	primeDisplayScale(merger)

	if radiant then
		applyRadiantOverlay(merger, "MergerFuse")
	end

	merger.Parent = bf
	-- Left on automatic ownership — see spawnBall's comment.
	-- Deliberately no setDisplay call — see spawnSplitter's own comment;
	-- a merger shrinks/vanishes over its life too (see MergerFuse), so a
	-- size readout set once at spawn would just go stale here as well.
	applyDensity(merger, size)

	track(merger, size, { state = "ascending", grown = false, kind = "merger" })
	return merger
end

-- ── pet mimic ──────────────────────────────────────────────────────
-- fixed spawn size for every pet mimic regardless of owner — UpgradeData's
-- "petMimic" entry is a flat $20000 price, not tiered/scaled by size the
-- way grab is, so there's nothing to read a size out of.
local PET_MIMIC_SIZE = 2

-- Launches/settles exactly like a board mimic — same ascend -> grow-in ->
-- settle physics, reusing onHB's existing "mimic" kind handling above
-- (see the grow-in check just above spawnMimic, now also matching
-- kind=="petMimic") — the one place their paths actually diverge is what
-- happens once one falls/gets defused: isPetMimic()/schedulePetMimicRespawn
-- above route it to a respawn instead of ever letting fallsLikeABall turn
-- it into a regular, sellable ball.
--
-- IsPetMimic/OwnerId are attributes set BEFORE parenting, same ordering
-- reasoning as spawnBomb's TargetSize-before-parent — PetMimicFuse (cloned
-- in below, NOT MimicFuse; see MimicFuse's own top-of-script bail-out for
-- IsPetMimic mimics) reads both the instant it starts running.
--
-- numDisplay is set straight to whatever the player's own custom pet name
-- currently is (passed in as `nameText` — PetMimicHandler reads it off
-- their PetMimicConfig folder), not left showing a size number the way an
-- ordinary dormant mimic briefly does — a pet mimic never has a size
-- number to hide in the first place, so there's no "swap on wake" moment
-- for PetMimicFuse to do the way MimicFuse does.
--
-- Exposed as _G.SpawnPetMimic — PetMimicHandler calls this both for a
-- fresh purchase and for every respawn afterward (see
-- schedulePetMimicRespawn above). Returns the instance so the caller can
-- track it (and know when it's gone, via AncestryChanged).
local function spawnPetMimic(ownerId, color, nameText)
	local vis = math.min(PET_MIMIC_SIZE, GROW_AT)

	local mimic = mimicT:Clone()
	mimic:SetAttribute("IsPetMimic", true)
	mimic:SetAttribute("OwnerId", ownerId)

	mimic.Anchored = false
	prepareBallPhysics(mimic)
	mimic.Size = Vector3.new(vis, vis, vis)
	mimic.Color = color or randColor()
	mimic.CFrame = CFrame.new(SPAWN_POS)
	mimic:SetAttribute("TargetSize", PET_MIMIC_SIZE)
	setDisplayScale(mimic, PET_MIMIC_SIZE)

	local display = mimic:FindFirstChild("display")
	local label = display and display:FindFirstChild("numDisplay")
	if label then
		label.Text = nameText or "<3"
	end

	local fuse = Rep:FindFirstChild("PetMimicFuse")
	if fuse then
		fuse:Clone().Parent = mimic
	else
		warn("[BallManager] ReplicatedStorage.PetMimicFuse is missing — pet mimic spawned with no behavior script")
	end

	mimic.Parent = bf
	-- Left on automatic ownership — see spawnBall's comment.
	track(mimic, PET_MIMIC_SIZE, { state = "ascending", grown = false, kind = "petMimic" })
	return mimic
end

_G.SpawnPetMimic = spawnPetMimic

-- special ball kinds: add a new entry here (name, a WEIGHT — its share
-- of SPECIAL_TOTAL_CHANCE relative to every other kind's weight, not an
-- independent chance of its own — and a spawn function mirroring
-- spawnBomb's signature: takes size, returns the instance) and it's
-- automatically covered by the shared cooldown/roll machinery in
-- queueSpawn/processQueue — no other changes needed elsewhere. Order
-- doesn't matter. Unlike the old flat-chance table, adding a kind here
-- does NOT raise the odds that a roll produces *some* special — it only
-- gives that new kind a slice of the same SPECIAL_TOTAL_CHANCE pie,
-- shrinking everyone else's slice slightly to make room. See the
-- normalization loop right below the table.
-- `fuseName` is each kind's own behavior script Name exactly as it
-- sits on its template (see e.g. BombFuse's header) — this is what
-- applyRadiantOverlay uses to find/replace it when this kind rolls (or
-- is summoned) radiant. `spawn` now takes (size, radiant) rather than
-- just size, radiant defaulting to falsy for every existing call site
-- that never passes it.
local SPECIAL_KINDS = {
	{ name = "bomb", weight = BOMB_WEIGHT, fuseName = "BombFuse", spawn = function(size, radiant) return spawnBomb(size, radiant) end },
	{ name = "magnet", weight = MAGNET_WEIGHT, fuseName = "MagnetFuse", spawn = function(size, radiant) return spawnMagnet(size, radiant) end },
	{ name = "mimic", weight = MIMIC_WEIGHT, fuseName = "MimicFuse", spawn = function(size, radiant) return spawnMimic(size, radiant) end },
	{ name = "splitter", weight = SPLITTER_WEIGHT, fuseName = "SplitterFuse", spawn = function(size, radiant) return spawnSplitter(size, radiant) end },
	{ name = "merger", weight = MERGER_WEIGHT, fuseName = "MergerFuse", spawn = function(size, radiant) return spawnMerger(size, radiant) end },
}

-- Radiant is no longer ball-exclusive (see RADIANT_CHANCE/RADIANT_COOLDOWN
-- in queueSpawn) — any kind above CAN roll/be summoned radiant, but only
-- once its own "Radiant" .. fuseName script actually exists in
-- ReplicatedStorage's "radiant" folder (see radiantFolder/
-- applyRadiantOverlay above). Checked once here, at startup, rather
-- than re-probing ReplicatedStorage on every roll — a kind with no
-- radiant script yet just never gets selected for one, same "add the
-- script and it's automatically covered, no code change needed
-- elsewhere" philosophy the rest of this table already follows. Plain
-- balls are handled separately (spawnBall's own `radiant` param +
-- RadiantFuse) and are always eligible, so they don't need an entry
-- here at all.
for _, kind in ipairs(SPECIAL_KINDS) do
	kind.radiantSupported = radiantFolder ~= nil and radiantFolder:FindFirstChild("Radiant" .. kind.fuseName) ~= nil
end

-- normalize weights -> actual roll chances, once, at startup. Every
-- kind's chance ends up as (its weight / total weight) * SPECIAL_TOTAL_CHANCE,
-- so the full table always sums to exactly SPECIAL_TOTAL_CHANCE no
-- matter how many kinds are listed above or what their individual
-- weights are — this is what queueSpawn's roll (acc += kind.chance)
-- actually reads from, same as before.
do
	local totalWeight = 0
	for _, kind in ipairs(SPECIAL_KINDS) do
		totalWeight += kind.weight
	end
	assert(totalWeight > 0, "BallManager: SPECIAL_KINDS total weight must be > 0")
	for _, kind in ipairs(SPECIAL_KINDS) do
		kind.chance = (kind.weight / totalWeight) * SPECIAL_TOTAL_CHANCE
	end
end

-- kind name -> spawner, for AdminCommands' !summon (see there). Built
-- straight off SPECIAL_KINDS (plus "ball" itself, which isn't in that
-- list) rather than a separate hardcoded lookup, so a new entry added
-- to SPECIAL_KINDS above is automatically summonable here too — no
-- second place to remember to update. "radiant" is no longer its own
-- kind name here — !summon now takes an "r" flag on top of any kind
-- instead (see AdminCommands' handleSummon and _G.BallManagerSummon's
-- own `radiant` param below).
local KIND_SPAWNERS = { ball = spawnBall }
for _, kind in ipairs(SPECIAL_KINDS) do
	KIND_SPAWNERS[kind.name] = kind.spawn
end

-- kind name -> its SPECIAL_KINDS entry, nil for "ball" itself. Used by
-- BallManagerSummon below to build the exact same {size, special}
-- queue-entry shape processQueue already expects, without re-rolling
-- which kind it is.
local SPECIAL_KIND_BY_NAME = {}
for _, kind in ipairs(SPECIAL_KINDS) do
	SPECIAL_KIND_BY_NAME[kind.name] = kind
end

-- Exposed for StashHandler, which has to know BEFORE taking something
-- whether it could ever give it back radiant — a radiant kind with no
-- "Radiant" .. fuseName script would deploy as an IsRadiant-flagged
-- object with no behavior (applyRadiantOverlay only warns), so it
-- refuses the stash rather than discovering that later. Reads the same
-- table every roll and every summon reads, so there's no second answer
-- to the question anywhere.
--
-- A plain ball is always true: its overlay is RadiantFuse, which isn't
-- in SPECIAL_KINDS at all and is handled by spawnBall's own `radiant`
-- param. Anything unrecognised is false rather than an error — the
-- caller is asking a question, not asserting the kind exists.
_G.BallManagerRadiantSupported = function(kindName)
	if kindName == "ball" then
		return true
	end
	local special = SPECIAL_KIND_BY_NAME[kindName]
	return special ~= nil and special.radiantSupported == true
end

-- exposed for AdminCommands' !summon. Unlike an organic queueSpawn
-- call, this skips the special-roll entirely (the kind's already
-- chosen by whoever typed the command, not rolled) and the
-- SPECIAL_COOLDOWN gate (that's there to pace random rolls, not an
-- explicit admin request) — but it now goes through the same launch
-- queue/stagger as everything else instead of spawning immediately,
-- landing at the FRONT of that queue (table.insert position 1, not
-- the back) so a summon shows up next — ahead of whatever's already
-- queued — rather than waiting behind it. `count` (defaults to 1)
-- queues that many identical entries, inserted back-to-front so the
-- queue still reads in the order summoned (the first one summoned
-- ends up frontmost, i.e. soonest). Still no-ops mid-collapse
-- (spawningEnabled) and still triggers a collapse of its own if
-- `count` pushes the queue past OVERFLOW_THRESHOLD, same as any other
-- queueSpawn — an admin summon isn't exempt from the same board-size
-- consequences an organic overflow would have.
-- `radiant`, if true, is the "r" flag AdminCommands' !summon parses out
-- right after the kind name (e.g. "!summon bomb r 5 10") — same overlay
-- every organic roll can produce (see queueSpawn), just explicitly
-- requested instead of rolled. Rejected up front for "ball" itself only
-- if... actually a plain ball is always radiant-eligible (see
-- spawnBall's own radiant handling), so only a SPECIAL kind needs the
-- radiantSupported check below — asking for a radiant kind whose own
-- "Radiant" .. fuseName script doesn't exist yet in ReplicatedStorage
-- fails loudly here instead of silently spawning a radiant-flagged
-- object with no actual radiant behavior (applyRadiantOverlay would
-- just warn and move on, which is fine for an organic roll that can
-- never happen in the first place thanks to radiantSupported gating
-- queueSpawn's own roll, but an explicit admin request deserves a real
-- error instead of a silent no-op-looking result).
_G.BallManagerSummon = function(kindName, size, count, radiant)
	local spawner = KIND_SPAWNERS[kindName]
	if not spawner then
		return false, "unknown kind: " .. tostring(kindName)
	end
	if not spawningEnabled then
		return false, "can't summon during a collapse"
	end

	local special = SPECIAL_KIND_BY_NAME[kindName] -- nil for "ball" itself

	if radiant and special and not special.radiantSupported then
		return false, "no radiant behavior is set up for kind: " .. tostring(kindName)
	end

	count = count or 1

	for i = count, 1, -1 do
		table.insert(queue, 1, { size = size, special = special, radiant = radiant or nil })
	end
	syncQueueCount()

	if #queue > OVERFLOW_THRESHOLD then
		triggerCollapse() -- clears the queue itself (synchronously) — nothing left to defer processQueue for
		return true
	end

	if not queuing then
		-- same synchronous-set-before-defer reasoning as queueSpawn: if
		-- this were set inside processQueue instead, a burst of calls
		-- before the deferred processor actually starts would each see
		-- queuing as still false and each schedule their own
		queuing = true
		task.defer(processQueue)
	end

	return true
end

-- ── stash deploys ─────────────────────────────────────────────────────
-- Exposed for StashHandler: a ball coming back out of a player's stash.
--
-- Deliberately shaped as a QUEUE INSERT rather than a spawner of its
-- own, and that's the whole design of the feature rather than an
-- implementation detail. An earlier version placed the ball directly
-- above its owner's head with its own grow and its own launch arc, and
-- the result was that a stash played as a strictly better grab: pocket a
-- ball, walk it anywhere, put it back down in front of you. Routing a
-- deploy through the launch queue instead means a stashed ball comes
-- back the way every other ball arrives — from the spawn point, on the
-- same arc, at the same stagger — so the stash moves a ball through TIME
-- (hold it across a collapse, save it for later) rather than through
-- SPACE. There is nothing to tune here to make it feel better; the
-- absence of placement control is the point.
--
-- Front of the queue (position 1), exactly like _G.BallManagerSummon
-- above: a deploy is an explicit request and shows up next rather than
-- waiting behind whatever organic spawns happen to be pending. It also
-- shares that function's overflow handling — a deploy is not exempt from
-- tipping the board into a collapse, same as a summon isn't.
--
-- `stashed = true` on the entry is what carries the cyan flash and the
-- fade-out highlight through to the other side: processQueue fires
-- SellService.stashDeploy on whatever instance the spawn returns (see
-- there). It has to ride the queue entry rather than being applied by
-- StashHandler at request time, because at request time the ball doesn't
-- exist yet — it's spawned later, by the queue, possibly seconds later.
--
-- Everything about how the ball itself grows and launches is left
-- entirely to the ordinary spawners: the stash contributes a kind, a
-- size and a color, and nothing else.
--
-- kind: "ball" | "bomb" | "magnet" | "splitter" | "merger" (never
-- "mimic" — StashData has no entry for one, so a mimic can't be stashed
-- and therefore can't be deployed). Returns (true), or (false, reason)
-- when the board can't take it right now, so the caller can leave the
-- slot filled and let the player try again.
_G.QueueStashDeploy = function(kind, size, color, radiant)
	if not spawningEnabled then
		return false, "can't deploy during a collapse"
	end

	local special = SPECIAL_KIND_BY_NAME[kind] -- nil for "ball" itself, which is the only kind that carries its color through
	if kind ~= "ball" and not special then
		return false, "unknown kind: " .. tostring(kind)
	end

	-- `color` is only read by spawnBall; every special's own spawn takes
	-- (size, radiant) and colors itself from its template, which is why a
	-- stashed bomb or splitter comes back in its template's colors rather
	-- than whatever tint it happened to have.
	--
	-- `radiant` comes straight back out for every kind — a radiant bomb
	-- stashed is a radiant bomb deployed. spawnBall applies its own
	-- overlay unconditionally (RadiantFuse is always there), and a
	-- special's overlay goes on the same way an explicitly summoned
	-- radiant one does.
	--
	-- Except when that kind has no "Radiant" .. fuseName script, which is
	-- the radiantSupported check _G.BallManagerSummon has to make too:
	-- applyRadiantOverlay only warns in that case, so honoring the flag
	-- would deploy an IsRadiant-flagged object with no behavior at all.
	-- StashHandler refuses to STASH one of those in the first place (see
	-- there), so reaching this with an unsupported kind means a save
	-- written against a build that still had the script. Dropped to a
	-- plain deploy rather than refused: the radiance is already lost
	-- either way, and handing the ball back beats stranding it in a slot
	-- forever.
	local wantsRadiant = radiant == true
	if wantsRadiant and special and not special.radiantSupported then
		wantsRadiant = false
	end

	table.insert(queue, 1, { size = size, color = color, special = special, radiant = wantsRadiant or nil, stashed = true })
	syncQueueCount()

	if #queue > OVERFLOW_THRESHOLD then
		triggerCollapse() -- clears the queue itself (synchronously) — nothing left to defer processQueue for
		return true
	end

	if not queuing then
		queuing = true -- set before the defer, same reasoning as queueSpawn/BallManagerSummon
		task.defer(processQueue)
	end

	return true
end

-- exposed for AdminCommands' !clear. Runs every ball currently on the
-- board through SellService.collapseSell — the same per-ball wipe
-- triggerCollapse uses below (magenta highlight/flash, $0, no chat
-- line), staggered by COLLAPSE_SELL_GAP the same way — just without
-- the rest of triggerCollapse's freeze/mute/desaturate/penalty
-- cinematic, since an admin-requested clear isn't the "board
-- overflowed" moment that's built around. No manual respawn needed
-- afterward: once collapseSell's own Destroy() empties the folder,
-- bf.ChildRemoved -> ensureBall (see bootstrap at the bottom of this
-- file) brings the baseline ball back on its own, same as any other
-- empty-board case. No-ops during an active collapse (triggerCollapse
-- already owns wiping the board itself).
_G.BallManagerClear = function()
	if collapsing then return false, "a collapse is already in progress" end
	table.clear(queue)
	queuing = false
	syncQueueCount()

	-- pet mimics sit out an admin clear the same way they sit out a
	-- collapse below (see triggerCollapse's own freeze loop) — they're a
	-- purchased, persistent thing tied to a specific player, not part of
	-- the pool of balls this is meant to sweep
	local toClear = {}
	for _, obj in ipairs(bf:GetChildren()) do
		if not isPetMimic(obj) then
			table.insert(toClear, obj)
		end
	end
	for i, obj in ipairs(toClear) do
		task.spawn(SellService.collapseSell, obj)
		if i < #toClear then
			task.wait(COLLAPSE_SELL_GAP)
		end
	end

	return true
end

-- ── launch queue: staggers spawns instead of popping them in at once ──
-- checkOverflow (below) starts/cancels the telegraph these two drive;
-- see its own doc comment for when each gets called.
--
-- Cancels the telegraph WITHOUT collapsing — the queue recovered under
-- OVERFLOW_THRESHOLD on its own before the countdown reached 0. Eases
-- the CC node back to its true pre-telegraph values and stops the
-- tension loop; the HUD countdown itself just clears its attribute and
-- HudUI hides the label immediately, no fade needed there. Safe to call
-- when no telegraph is running (checkOverflow's else-branch calls this
-- unconditionally every time the queue is at/under the threshold).
local function cancelCollapseCountdown()
	if not collapseCountdownActive then return end
	collapseCountdownActive = false
	WS:SetAttribute("CollapseCountdown", nil)
	se:FireAllClients("loopStop", COLLAPSE_TENSION_SND_ID)

	if telegraphBaseSaturation then
		-- Tells clients to ease their own local CC back to baseline —
		-- see CollapseEffectsClient. No tween object to track here
		-- anymore; the client owns cancelling its own in-flight tween
		-- before starting this one (same "only one tween at a time"
		-- rule we used to have to enforce here ourselves).
		vfx:FireAllClients("telegraphCancel", COLLAPSE_TELEGRAPH_CANCEL_FADE_TIME, telegraphBaseSaturation, telegraphBaseContrast, telegraphBaseTint)
	end
	telegraphBaseSaturation, telegraphBaseContrast, telegraphBaseTint = nil, nil, nil
end

-- Starts the telegraph: ticks the HUD countdown down from
-- OVERFLOW_SUSTAIN seconds, ramping the CC node and playing the tension
-- loop as it goes, and actually calls triggerCollapse itself once it
-- reaches 0 — checkOverflow no longer computes elapsed time on its own,
-- it just starts/stops this. No-ops if a telegraph is already running
-- (repeated queue growth while already counting down shouldn't restart
-- the clock — same "don't re-arm" intent OVERFLOW_SUSTAIN always had).
local function startCollapseCountdown()
	if collapseCountdownActive then return end
	collapseCountdownActive = true
	collapseCountdownGeneration += 1
	local myGeneration = collapseCountdownGeneration -- see the state-vars comment above for why this, not just collapseCountdownActive, guards every check below

	-- reuse an existing effect if the map already has one (Studio-side
	-- color grading, etc.) instead of fighting it with a second one.
	-- The server never writes to this instance's properties anymore
	-- (see the vfx RemoteEvent above) — it only exists here so there's
	-- a stable, replicated source of the map's true baseline values for
	-- clients to find and read.
	local cc = Lighting:FindFirstChildOfClass("ColorCorrectionEffect") or Instance.new("ColorCorrectionEffect")
	cc.Parent = Lighting
	telegraphBaseSaturation, telegraphBaseContrast, telegraphBaseTint = cc.Saturation, cc.Contrast, cc.TintColor

	se:FireAllClients("loopStart", COLLAPSE_TENSION_SND_ID, COLLAPSE_TENSION_VOL)

	-- Tells clients to ramp their own local CC from baseline to the
	-- full peak values across the entire OVERFLOW_SUSTAIN window in one
	-- smooth local tween — see CollapseEffectsClient. Sending the
	-- already-computed target values (rather than the raw boost
	-- constants) keeps the client script a dumb tweener with no tuning
	-- knobs of its own to keep in sync with these.
	vfx:FireAllClients(
		"telegraphStart",
		OVERFLOW_SUSTAIN,
		telegraphBaseSaturation + COLLAPSE_TELEGRAPH_SATURATION_BOOST,
		telegraphBaseContrast + COLLAPSE_TELEGRAPH_CONTRAST_BOOST,
		telegraphBaseTint:Lerp(COLLAPSE_TELEGRAPH_TINT_COLOR, COLLAPSE_TELEGRAPH_TINT_INTENSITY),
		COLLAPSE_TELEGRAPH_SHAKE_INTENSITY
	)

	task.spawn(function()
		local secondsLeft = math.ceil(OVERFLOW_SUSTAIN)
		while collapseCountdownActive and collapseCountdownGeneration == myGeneration and secondsLeft > 0 do
			WS:SetAttribute("CollapseCountdown", secondsLeft) -- HudUI's collapseCountdown label ticks off this
			se:FireAllClients("flatPitched", COLLAPSE_TICK_SND_ID, COLLAPSE_TICK_VOL)

			task.wait(1)
			if collapseCountdownActive and collapseCountdownGeneration == myGeneration then
				secondsLeft -= 1
			end
		end

		if collapseCountdownActive and collapseCountdownGeneration == myGeneration then
			collapseCountdownActive = false
			triggerCollapse() -- clears the queue itself (synchronously) — nothing left to defer processQueue for
		end
	end)
end

-- Sustained-overflow check (see OVERFLOW_SUSTAIN above): called both
-- whenever the queue grows (queueSpawn/queueRadiant, below) and
-- whenever it drains (processQueue's own loop, below), so a burst that
-- recovers on its own — processQueue draining it, enforceBallCap
-- thinning the board — gets noticed and un-arms just as promptly as a
-- genuine runaway gets caught. Only ever reads #queue at the moment
-- it's called, so it stays cheap enough to call on every single
-- enqueue/dequeue rather than needing its own polling loop.
--
-- The cancel side is debounced (COLLAPSE_TELEGRAPH_CANCEL_DEBOUNCE),
-- unlike the original overflowSince-based version this replaced: a
-- queue that's still genuinely climbing can legitimately dip back to
-- exactly OVERFLOW_THRESHOLD for a moment (processQueue drains one
-- item every GAP seconds while more keep enqueuing) without that dip
-- meaning the overflow actually resolved. The old version could afford
-- to reset its internal timer on every such dip for free — nothing
-- user-visible depended on it. Now that a dip instantly tears down and
-- restarts the whole telegraph (tick sound, CC ramp, tension loop), an
-- immediate reset on every momentary dip was replaying the tick sound
-- every time the queue re-crossed the line — the debounce below waits
-- a beat and re-checks before actually cancelling, so a queue that
-- crosses back over before the beat is up just keeps its existing
-- telegraph running (startCollapseCountdown no-ops since it's already
-- active) instead of restarting it.
local function checkOverflow()
	if #queue > OVERFLOW_THRESHOLD then
		if bribeActiveUntil > 0 and os.clock() < bribeActiveUntil then
			-- bribed: a sustained overflow doesn't even start telegraphing
			-- while this window is open — see _G.BallManagerBribe below
			return
		end
		startCollapseCountdown()
	elseif collapseCountdownActive then
		local myGeneration = collapseCountdownGeneration
		task.delay(COLLAPSE_TELEGRAPH_CANCEL_DEBOUNCE, function()
			-- re-check everything at fire time, not just trust the snapshot
			-- from when this was scheduled: the telegraph may have already
			-- ended on its own (collapsing done, or a later checkOverflow's
			-- own debounce beat this one to cancelling first), restarted
			-- into a new generation, or the queue may have climbed back
			-- over the threshold again by now
			if collapseCountdownActive and collapseCountdownGeneration == myGeneration and #queue <= OVERFLOW_THRESHOLD then
				cancelCollapseCountdown()
			end
		end)
	end
end

-- exposed for the bribe shop entry (see UpgradeData/ShopHandler).
-- Doesn't touch the queue itself at all (unlike the old queueClear this
-- replaced) — it just buys BRIBE_DURATION seconds during which
-- checkOverflow above won't even start telegraphing a sustained
-- overflow, let alone let one run all the way to triggerCollapse.
-- Cancels an already-running telegraph outright too, same as the queue
-- recovering under OVERFLOW_THRESHOLD on its own — a player who just
-- paid to avoid a collapse shouldn't have to sit through the countdown
-- anyway. No-ops mid-collapse, same as every other _G entry here — once
-- triggerCollapse has actually fired there's nothing left to save.
_G.BallManagerBribe = function()
	if collapsing then return false, "a collapse is already in progress" end
	bribeActiveUntil = os.clock() + BRIBE_DURATION
	cancelCollapseCountdown()

	-- checkOverflow otherwise only ever runs off a queue mutation
	-- (queueSpawn/processQueue's own drain) — if the queue happens to
	-- sit perfectly still, over threshold, for the entire bribe window
	-- (nothing new queued, nothing draining), nothing would otherwise
	-- re-check it the instant the window closes. This re-arms things
	-- right on schedule instead of waiting on an unrelated queue change.
	task.delay(BRIBE_DURATION, checkOverflow)

	return true
end

processQueue = function()
	while #queue > 0 do
		local r = table.remove(queue, 1)
		syncQueueCount()
		checkOverflow() -- queue just shrank — let a burst that's now draining un-arm before OVERFLOW_SUSTAIN elapses; may itself call triggerCollapse, which is why the spawn below is guarded
		if not collapsing then -- checkOverflow just above may have tripped triggerCollapse (wipes/freezes the board) — don't spawn r into that
			local spawned
			if r.special then
				spawned = r.special.spawn(r.size, r.radiant)
			else
				spawned = spawnBall(r.size, r.color, r.silent, r.radiant)
			end

			-- a ball coming back out of somebody's stash (see
			-- _G.QueueStashDeploy above) gets the cyan flash and the
			-- fade-out highlight that mark it as deployed rather than
			-- organically spawned. Applied HERE, not at request time,
			-- because this is the first moment the instance exists — the
			-- entry may have sat in the queue for seconds before reaching
			-- the front. Guarded on `spawned` because a kind whose spawner
			-- ever returns nothing shouldn't take the queue down with it.
			-- the kind goes along so stashDeploy can skip its highlight for
			-- the kinds that draw themselves with one (splitter, merger)
			if r.stashed and spawned then
				SellService.stashDeploy(spawned, r.special and r.special.name or "ball")
			end
		end
		if #queue > 0 then
			task.wait(GAP)
		end
	end
	queuing = false
end

queueSpawn = function(size, color, forceBall, silent)
	if not spawningEnabled then return end -- collapsing (or mid-collapse) — no new launches until it's done

	-- rolled once per request, at queue time, so the queue already knows
	-- ball vs special (and which kind) before anything launches. Gated
	-- behind SPECIAL_COOLDOWN so a roll can't even succeed while a
	-- special is still active/recent — this check is shared across every
	-- kind in SPECIAL_KINDS, not per-kind, so it's still only one special
	-- total every SPECIAL_COOLDOWN seconds no matter how many kinds exist.
	-- forceBall skips the roll entirely — used by ensureBall so the
	-- baseline "at least one ball in play" spawn is never special.
	-- Also requires at least 2 balls already on the board — otherwise a
	-- brand-new player could get a special the very first time they
	-- knock the lone starter ball off (splitBall's own replacement
	-- queueSpawn calls aren't forceBall).
	local special = nil
	if not forceBall and ballCount() >= 2 and os.clock() - lastSpecialTime >= SPECIAL_COOLDOWN then
		local roll, acc = math.random(), 0
		for _, kind in ipairs(SPECIAL_KINDS) do
			acc += kind.chance
			if roll < acc then
				special = kind
				break
			end
		end
	end
	if special then
		lastSpecialTime = os.clock()
	end

	-- Radiant roll: independent of the special roll above, its own
	-- RADIANT_CHANCE/RADIANT_COOLDOWN — an overlay on top of WHATEVER
	-- this slot ends up spawning, ball or special alike, as long as
	-- that particular kind actually has a radiant behavior script set
	-- up for it yet (kind.radiantSupported, computed once at startup —
	-- see SPECIAL_KINDS' own setup above). A plain ball (special == nil)
	-- is always eligible; a special is only eligible once its own
	-- "Radiant" .. fuseName script exists in ReplicatedStorage — until
	-- then it's silently excluded from this roll the same way any kind
	-- with 0 weight would be, no special-casing needed here. forceBall
	-- skips this too, same reasoning as the special roll: the
	-- guaranteed bootstrap ball should never come out as anything but
	-- a plain ball.
	local radiant = false
	if not forceBall and (not special or special.radiantSupported) and os.clock() - lastRadiantTime >= RADIANT_COOLDOWN then
		if math.random() < RADIANT_CHANCE then
			radiant = true
			lastRadiantTime = os.clock()
		end
	end

	table.insert(queue, { size = size, color = color, special = special, radiant = radiant, silent = silent })
	syncQueueCount()
	checkOverflow()
	if collapsing then return end -- checkOverflow just tripped triggerCollapse — queue's already cleared, nothing left to defer processQueue for

	if not queuing then
		-- set synchronously here, not inside processQueue: task.defer
		-- means processQueue won't actually start until the current
		-- synchronous code (e.g. splitBall's loop) finishes. If the flag
		-- were only set once processQueue started, every queueSpawn call
		-- before that point would still see queuing as false and each
		-- schedule its own deferred processor.
		queuing = true
		task.defer(processQueue)
	end
end

-- Used only by scheduleRadiantRespawn's replacement radiant: same FIFO/
-- stagger/OVERFLOW_THRESHOLD path as queueSpawn, but skips the roll
-- entirely — this slot is already decided to be a radiant, not a
-- candidate for the ball-vs-special coinflip — and doesn't touch
-- lastSpecialTime, since a guaranteed radiant respawn was never a roll
-- that "used up" the shared special cooldown. Kept separate from
-- queueSpawn rather than folded in as another parameter, since the two
-- have different rules for what belongs in `special`.
queueRadiant = function(size)
	if not spawningEnabled then return end -- collapsing (or mid-collapse) — no new launches until it's done

	table.insert(queue, { size = size, special = { spawn = function(sz) return spawnBall(sz, nil, false, true) end } })
	syncQueueCount()
	checkOverflow()
	if collapsing then return end -- checkOverflow just tripped triggerCollapse — queue's already cleared, nothing left to defer processQueue for

	if not queuing then
		queuing = true
		task.defer(processQueue)
	end
end

-- ── splitting ──────────────────────────────────────────────────────
splitBall = function(ball)
	-- read by BallCountUI client-side: a ball that's already spawned its
	-- 2 replacements shouldn't keep counting just because it physically
	-- lingers, still falling, until Roblox's own void cleanup
	-- (FallenPartsDestroyHeight) gets around to removing it. Only
	-- matters for the FALL_Y branch in onHB, where the ball is still
	-- parented when this runs — the other call site (a ball already
	-- destroyed before onHB caught it) has already dropped off every
	-- client's replicated Balls folder by this point regardless.
	ball:SetAttribute("Split", true)

	local size = ball:GetAttribute("TargetSize") or BASE
	-- rounded to a whole number: TargetSize is what both the on-ball
	-- size display (setDisplay's math.round) and the grab-tier maxSize
	-- checks (GrabClient/GrabHandler) compare against. Leaving jitter
	-- continuous meant a ball could display as "10" while its real
	-- TargetSize was something like 10.4 — reading as exactly size 10
	-- but actually too big to grab at a maxSize-10 tier. Rounding here
	-- keeps TargetSize and the displayed number in exact agreement.
	local jitter = math.max(math.round(size + (math.random() * SIZE_VAR * 2 - SIZE_VAR)), MIN_SIZE)

	-- queue both replacements first so "balls in play" never reads as
	-- zero, even for a frame. One child keeps the exact source size, the
	-- other gets the jitter. Each queued spawn plays its own sound once
	-- it actually lands in bf — see the ChildAdded listener below. (Not
	-- silenced: only a SplitterFuse-caused split via spawnSplitResult is
	-- — this fall-off duplication is a different thing.)
	queueSpawn(size, randColor())
	queueSpawn(jitter, randColor())

	-- source ball is already untracked + still unanchored, so it
	-- normally just keeps falling — void cleanup (FallenPartsDestroyHeight)
	-- removes it for free, cheaper than destroying it ourselves here.
	-- That assumes it's genuinely still falling, though: a ball that
	-- crossed FALL_Y because it got wedged under the platform instead
	-- (e.g. a throw/drop released at point-blank range into the floor —
	-- see GrabClient's finalizeRelease) can end up resting on something
	-- down there rather than continuing to fall, with nothing left
	-- tracking it and no way to ever reach FallenPartsDestroyHeight on
	-- its own — sitting there forever as an inert leftover that still
	-- occupies a ball slot. This is a pure safety net for that case: it
	-- never fires for a genuine fall off the edge, since void cleanup
	-- always gets there first.
	task.delay(VOID_FALLBACK_TIMEOUT, function()
		if ball.Parent then
			ball:Destroy()
		end
	end)
end

-- caps regular balls in play at MAX_BALLS; bombs/specials are excluded
-- from both the count and eligibility, via the same Name check used
-- everywhere else. Split-flagged balls are excluded too — they've
-- already spawned their 2 replacements and are just falling toward
-- void cleanup (see splitBall), so counting them inflates "in play"
-- past what's actually true, which is what let the cap trip a couple
-- balls early. PendingSell balls (mid cyan-highlight fade-in, see
-- SellService.sellWithHighlight) are excluded the same way — they're
-- already committed to being sold. Held balls (see GrabHandler) are
-- excluded too, so a ball a player is actively carrying can't get
-- auto-sold out of their hands the instant the cap ticks over. Growing
-- balls (see spawnSplitResult/spawnMergeResult) are excluded the same
-- way — they're still sitting in SPLIT_GROWING_GROUP mid-tween, and a
-- fresh split half is disproportionately likely to be exactly the
-- globally-smallest ball, so without this exclusion enforceBallCap was
-- a prime way to interrupt that tween before it could restore the
-- ball's collision group (see spawnSplitResult's restoreGroup comment).
-- Runs off TargetSize — the same source numDisplay and SellService both
-- use — so "smallest" always matches what's on screen.
-- SellService.sellWithHighlight tags the ball Sold immediately (well
-- before it's actually destroyed), so this doesn't trigger onHB's
-- split-replacement fallback either.
local function enforceBallCap()
	if collapsing then return end -- board's being wiped for $0 anyway — don't also auto-sell into the cap mid-collapse

	local count, smallest, smallestSize = 0, nil, nil

	for _, obj in ipairs(bf:GetChildren()) do
		if obj.Name == ballT.Name and not obj:GetAttribute("Split") and not obj:GetAttribute("PendingSell") and not obj:GetAttribute("Held") and not obj:GetAttribute("Growing") then
			count += 1
			local size = obj:GetAttribute("TargetSize") or BASE
			if not smallestSize or size < smallestSize then
				smallest, smallestSize = obj, size
			end
		end
	end

	if count > MAX_BALLS and smallest then
		task.spawn(SellService.sellWithHighlight, smallest) -- delayed cyan fade-in, then the actual sell
	end
end

-- ── overflow collapse ─────────────────────────────────────────────────
-- Wipes every ball/bomb currently in play for $0 once the launch queue
-- backs up past OVERFLOW_THRESHOLD (see header for why the queue, not
-- MAX_BALLS, is what's watched). The freeze/mute/desaturate/disable
-- block below has no yields in it at all, so Lua can't interleave
-- anything else partway through it — that's what actually makes those
-- happen "at the same time" rather than just approximately together.
triggerCollapse = function()
	if collapsing then return end
	collapsing = true
	WS:SetAttribute("Collapsing", true) -- HudUI freezes/counts down its server-age display off this
	spawningEnabled = false

	-- Neutralize any in-flight telegraph immediately, not via the eased
	-- cancelCollapseCountdown above — that one's for a recovered queue
	-- and eases the CC node back to baseline; this is the collapse
	-- itself starting, which needs an instant cut (below), not a fade.
	-- If this collapse instead came from somewhere that bypasses the
	-- telegraph entirely (e.g. BallManagerSummon's own immediate-overflow
	-- check further down), collapseCountdownActive is already false and
	-- this is a no-op. Whichever path got here, checkOverflow starts
	-- a fresh telegraph from scratch next time the queue actually
	-- overflows again post-collapse — no separate "fresh start" reset
	-- needed here the way overflowSince used to need. No client tween to
	-- cancel from here either — the "collapseCut" event fired below
	-- tells CollapseEffectsClient to cancel its own in-flight ramp
	-- itself before applying the instant cut.
	collapseCountdownActive = false
	WS:SetAttribute("CollapseCountdown", nil)
	se:FireAllClients("loopStop", COLLAPSE_TENSION_SND_ID) -- "temporary audio... stops playing as the collapse happens"

	table.clear(queue)
	queuing = false -- processQueue's own while-loop sees the now-empty queue and stops itself on its next check; this just skips deferring a redundant one
	syncQueueCount()

	spinScale.Value = 0 -- decorative spin pieces stop dead, same instant as everything else in this block

	se:FireAllClients("flatPitched", COLLAPSE_ALARM_SND_ID, COLLAPSE_ALARM_VOL, COLLAPSE_ALARM_SPEED)
	SellService.collapseAlert() -- alert chat line now lands right as the collapse starts, not later when the penalty hits

	-- heartbeat's whole job is tracking ascent/settle/fall-through for
	-- balls that are about to be anchored anyway — leaving it running
	-- would fight the CanCollide=false set below (a still-"ascending"
	-- entry crossing COL_Y would flip collision back on) and could fire
	-- a bogus split off a now-frozen ball's stale position. Nothing
	-- spawns again until spawningEnabled flips back on, so there's
	-- nothing for it to pick back up in the meantime — EXCEPT a pet
	-- mimic's own entry, which is kept (not wiped with everything else):
	-- it never gets anchored/frozen by the loop below (see there), stays
	-- fully alive and moving straight through the collapse, and still
	-- needs onHB watching it in case it falls off mid-freeze — losing
	-- that tracking here would mean it could fall right through the
	-- platform without ever triggering schedulePetMimicRespawn.
	local survivingTracked = {}
	for obj, d in pairs(tracked) do
		if isPetMimic(obj) then
			survivingTracked[obj] = d
		end
	end
	tracked = survivingTracked
	if hbConn then
		hbConn:Disconnect()
		hbConn = nil
	end
	if next(tracked) ~= nil then
		startHB() -- a live pet mimic survived the wipe above; keep onHB running for it through the freeze
	end

	for _, obj in ipairs(bf:GetChildren()) do
		-- a pet mimic sits out the whole collapse cinematic — it's a
		-- purchased, persistent, per-player thing, not board inventory,
		-- so freezing/desaturating/eventually collapseSell-ing it away for
		-- $0 the way every other ball on the board gets wiped would be
		-- destroying something the player paid for as a side effect of an
		-- unrelated ball-cap overflow. It just keeps doing whatever
		-- PetMimicFuse already has it doing (following/idling/hunting)
		-- straight through the freeze.
		if isPetMimic(obj) then
			continue
		end

		-- Anchored is supposed to force server ownership on its own, but
		-- that only takes effect once the Anchored property itself has
		-- replicated — until then, whichever client currently owns this
		-- ball's physics (Roblox auto-assigns ownership to whoever's
		-- nearest) keeps simulating its flight locally, off the server's
		-- now-stale velocity. SetNetworkOwner(nil) forces that handoff
		-- immediately instead of waiting on Anchored to carry it, so
		-- every client's freeze lands on the exact same position the
		-- server does — otherwise collapseSell's later positional flash
		-- can visibly land wherever the server froze it while a laggier
		-- client's own render is still a beat behind. pcall guards
		-- SetNetworkOwner's own restrictions (e.g. it errors on a part
		-- that isn't a physics assembly's root) — worst case here is just
		-- a slightly later handoff via Anchored itself, not a hard stop.
		pcall(function() obj:SetNetworkOwner(nil) end)
		obj.Anchored = true
		obj.CanCollide = false
		-- strips scripts unconditionally now rather than gating on
		-- obj.Name ~= ballT.Name: a dormant mimic is named ballT.Name
		-- too (see spawnMimic), so a name-gated strip would leave its
		-- MimicFuse fuse alive and able to wake it mid-freeze. An
		-- ordinary regular ball has no BaseScript children to begin
		-- with, so running this unconditionally is a no-op for it —
		-- this still only ever actually strips something off a
		-- bomb/mimic/magnet/future-special, same as before.
		for _, child in ipairs(obj:GetChildren()) do
			if child:IsA("BaseScript") then
				child:Destroy()
			end
		end
	end

	-- recursive lookup in case ambience lives a level deeper than
	-- directly under Workspace. Music itself is no longer server-owned
	-- at all — MusicManager's header explains why: each client starts
	-- its own private, unreplicated layer Sounds from TimePosition 0
	-- to keep them sample-synced, and the only shared state is the
	-- replicated NumberValues under ReplicatedStorage.MusicState that
	-- every client's MusicClient reads. So muting for a collapse means
	-- zeroing MusicState.MasterVolume, not hunting for a Sound/
	-- SoundGroup instance that doesn't exist server-side — this
	-- overrides every layer at once (each layer's Sound scales by
	-- MasterVolume on the client) without fighting MusicManager's own
	-- per-layer target volumes, since those are a separate multiplier.
	local ambience = WS:FindFirstChild("ambience", true)
	local musicState = Rep:WaitForChild("MusicState")
	local masterVolumeValue = musicState:WaitForChild("MasterVolume")
	local origAmbienceVol = ambience and ambience.Volume
	local origMusicVolume = masterVolumeValue.Value
	if ambience then ambience.Volume = 0 end
	MusicManager.SetMasterVolume(0)

	-- Neither of these two writes above, nor their fade-back at the end
	-- of this function, can accidentally un-mute a player who's hit the
	-- topbar's own Mute button: that mute is tracked client-side only
	-- (MusicClient's isMuted), and MusicClient re-forces both
	-- masterGroup.Volume and ambience.Volume back to 0 on every change
	-- for as long as that client is muted — including changes driven by
	-- this collapse. This script has no notion of any individual
	-- client's mute state, nor does it need one; it only ever expresses
	-- the shared, everyone-hears-it collapse mute/restore.

	-- collapse-desaturate: BombFuse's explosion flash and MagnetFuse's
	-- pull shine both render AlwaysOnTop, which bypasses the
	-- ColorCorrectionEffect set up just below — without this they'd
	-- stay full color for the whole freeze instead of desaturating with
	-- everything else (the magnet shine especially, since it can
	-- outlive a bomb's fuse-strip by a couple seconds; see GreyOnCollapse
	-- in both scripts). One-shot: nothing new can be created while
	-- collapsing (spawningEnabled is false, and any fuse script still
	-- alive was just killed by the strip above), and no restore is
	-- needed either — every object one of these lives on gets wiped by
	-- collapseSell within the next couple of seconds regardless.
	for _, desc in ipairs(WS:GetDescendants()) do
		if desc:IsA("ImageLabel") and desc:GetAttribute("GreyOnCollapse") then
			desc.ImageColor3 = toGrey(desc.ImageColor3)
		end
	end

	-- reuse an existing effect if the map already has one (Studio-side
	-- color grading, etc.) instead of fighting it with a second one —
	-- original Saturation/Contrast captured before overwriting so the
	-- fade-back at the end restores whatever was actually there before,
	-- not a hardcoded "normal"
	local cc = Lighting:FindFirstChildOfClass("ColorCorrectionEffect") or Instance.new("ColorCorrectionEffect")
	cc.Parent = Lighting
	-- Prefer the telegraph's own stashed baseline when there is one,
	-- falling back to reading cc directly when no telegraph preceded
	-- this collapse (e.g. BallManagerSummon's immediate-overflow path).
	-- Either way this now reads the server's own untouched copy of cc —
	-- the server never writes to it anymore (see the vfx RemoteEvent
	-- above), so both branches land on the same true baseline.
	local origSaturation = telegraphBaseSaturation or cc.Saturation
	local origContrast = telegraphBaseContrast or cc.Contrast
	local origTint = telegraphBaseTint or cc.TintColor
	telegraphBaseSaturation, telegraphBaseContrast, telegraphBaseTint = nil, nil, nil -- consumed; nil again so the next telegraph captures fresh
	-- Instant cut, no tween — tells clients to jump straight to full
	-- grey the moment the collapse itself starts. The telegraph's own
	-- magenta build-up (client-side by now) has done its job; clients
	-- reset TintColor back to origTint here too so this cut reads as
	-- genuinely grey instead of grey-tinted-magenta.
	vfx:FireAllClients("collapseCut", origContrast + COLLAPSE_CONTRAST_BOOST, origTint) -- same contrast math as the original file — independent of whatever the telegraph ramped Contrast up to, since origContrast is the true pre-telegraph baseline

	task.spawn(function()
		task.wait(PRE_COLLAPSE_DELAY)

		-- snapshot + sort once up front, smallest to largest — destroying
		-- balls mid-loop can't reshuffle what's left to iterate this way
		local toSell = {}
		for _, obj in ipairs(bf:GetChildren()) do
			if not isPetMimic(obj) then -- see the freeze loop above for why
				table.insert(toSell, obj)
			end
		end
		table.sort(toSell, function(a, b)
			return (a:GetAttribute("TargetSize") or 0) < (b:GetAttribute("TargetSize") or 0)
		end)

		-- snapshot who's exempt from the penalty (AFKHandler's grace
		-- period) right now, as the clearing loop below is starting,
		-- rather than leaving that attribute check for
		-- applyCollapsePenalty to do on its own later — that later
		-- moment sits right at the tight beat between "board's empty"
		-- and "penalty applied" (PRE_PENALTY_DELAY), where any extra
		-- synchronous work is the most likely to read as a stutter.
		-- Doing it here instead spreads it out across the several
		-- seconds the sell loop below is already staggered over.
		local penaltyExempt = SellService.snapshotCollapseExemptions()

		-- a collapse takes everyone's STASH with it too, not just what's
		-- sitting on the board — a stashed ball is off-board and otherwise
		-- untouchable, which would make the stash a way to sit out a
		-- collapse for free. Fired here rather than back at the top of
		-- this function so the toolbar drains alongside the board rather
		-- than before it. StashHandler owns the timing from here: it tells
		-- every client to play the left-to-right wipe, then clears the
		-- slot values once that animation is actually over. Guarded the
		-- same way every other cross-script _G hook in this file is, in
		-- case StashHandler hasn't finished starting up.
		if _G.StashCollapseWipe then
			_G.StashCollapseWipe()
		end

		-- pendingSells tracks every collapseSell dispatched below, not just
		-- the loop's own dispatch order — collapseSell's own PRE_SELL_DELAY
		-- fade means the last-dispatched ball is still visibly around for a
		-- beat after this loop itself finishes, so "every ball's actually
		-- gone" has to wait on that too, not just on the loop returning.
		local pendingSells = 0

		for i, obj in ipairs(toSell) do
			if obj.Parent then
				pendingSells += 1
				task.spawn(function() -- own PRE_SELL_DELAY fade shouldn't block this loop's 0.1s stagger
					SellService.collapseSell(obj) -- $0, red highlight fade-in then flash — covers bombs too, not just regular balls
					pendingSells -= 1
				end)
			end
			if i < #toSell then
				task.wait(COLLAPSE_SELL_GAP)
			end
		end

		while pendingSells > 0 do
			task.wait()
		end

		-- board's genuinely empty now — the $5000-everyone "world saved"
		-- penalty (clamped at 0 per-player, see SellService) and its chat
		-- line, bookended by the same beat-before/beat-after pacing as the
		-- rest of the sequence
		task.wait(PRE_PENALTY_DELAY)
		SellService.applyCollapsePenalty(penaltyExempt)
		awardCollapseBadgeToAll()
		task.wait(POST_COLLAPSE_DELAY)

		if ambience then
			TS:Create(ambience, TweenInfo.new(COLLAPSE_FADE_TIME), { Volume = origAmbienceVol }):Play()
		end
		-- tweened directly on the NumberValue rather than via
		-- MusicManager.SetMasterVolume (that setter is an instant jump,
		-- no tween support) — every client sees this ease back the same
		-- way ordinary property replication delivers any other tween
		TS:Create(masterVolumeValue, TweenInfo.new(COLLAPSE_FADE_TIME), { Value = origMusicVolume }):Play()
		vfx:FireAllClients("collapseResolve", COLLAPSE_FADE_TIME, origSaturation, origContrast) -- eases the client's local CC back to true baseline over the same window everything else here resolves on
		TS:Create(spinScale, TweenInfo.new(COLLAPSE_FADE_TIME), { Value = 1 }):Play() -- decorative spin pieces ease back up to full speed over the same window

		task.wait(COLLAPSE_FADE_TIME)

		spawningEnabled = true
		collapsing = false
		WS:SetAttribute("Collapsing", false) -- HudUI resumes ticking its server-age display off this
		ensureBall() -- board's empty and spawning's back on — same bootstrap the script starts with
	end)
end

-- plays once per object that actually appears in the folder — covers the
-- initial bootstrap ball and a regular fall-off duplication (splitBall)
-- alike, but NOT a SplitterFuse-caused split (spawnSplitResult): that one
-- marks its ball in silentSpawns before parenting it into bf specifically
-- so it's skipped here — falling off the platform and getting cut by a
-- splitter are different things, only the latter stays quiet. Anything
-- that isn't a regular ball by name (bombs now, other variants later)
-- gets the special sound instead — no per-variant branch to grow.
--
-- isRegularBall (Name-based) still gates the cap/registration below: a
-- radiant ball is a genuine ball economically now (sellable, counts
-- toward MAX_BALLS, auto-registered) — it just also gets the special
-- sound via the separate IsRadiant attribute check, same as any other
-- ball-shaped exception would.
bf.ChildAdded:Connect(function(obj)
	local isRegularBall = obj.Name == ballT.Name
	local isSpecialSounding = not isRegularBall or obj:GetAttribute("IsRadiant")

	if silentSpawns[obj] then
		silentSpawns[obj] = nil -- one-shot marker
	else
		se:FireAllClients("attached", spawnSymbol, isSpecialSounding and SPECIAL_SND_ID or SND_ID, isSpecialSounding and SPECIAL_VOL or SND_VOL)
	end

	if isRegularBall then
		enforceBallCap()

		-- Some spawners parent first and finish bookkeeping immediately after
		-- parenting (spawnBall), while split/merge results finish their setup
		-- before parenting. Deferring this reconciliation makes both paths safe.
		task.defer(registerRegularBallIfNeeded, obj)
	end
end)

-- ── bootstrap ─────────────────────────────────────────────────────
ensureBall = function()
	-- "in play" = NORMAL balls only: folder children named ballT.Name
	-- (via ballCount()) + still-queued requests that aren't special
	-- (r.special == nil), so a split's replacements (already queued
	-- above) never look like zero balls. Deliberately excludes bombs/
	-- magnets/mimics — a special sitting on the board doesn't guarantee
	-- the board will ever empty on its own (e.g. a magnet that never
	-- gets grabbed, or a mimic that never wakes and never falls), so
	-- counting it here would let it permanently block this failsafe.
	-- During a collapse this still fires (every ball destroyed trips
	-- ChildRemoved below), but queueSpawn no-ops while spawningEnabled
	-- is false, so it can't refill the board mid-wipe.
	local normalInPlay = ballCount()
	for _, r in ipairs(queue) do
		if not r.special then
			normalInPlay += 1
		end
	end
	if normalInPlay == 0 then
		queueSpawn(nil, nil, true) -- forceBall: never let the baseline spawn be a bomb
	end
end

ensureBall()
bf.ChildRemoved:Connect(ensureBall)