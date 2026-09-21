--[[
    CollisionGroups (ModuleScript)
    Path: ReplicatedStorage
    Parent: ReplicatedStorage
    Exported: 2026-09-20 22:14:29
]]
--[[
	CollisionGroups (ModuleScript) — place directly in ReplicatedStorage
	(ReplicatedStorage.CollisionGroups).

	THE single source of truth for collision groups in this game. Every
	group that exists, and every "these two don't collide" rule, is
	declared once in the GROUPS table below — nowhere else. No other
	script calls PhysicsService:RegisterCollisionGroup or
	CollisionGroupSetCollidable ever again; they just require this and
	read names off it:

		local CG = require(ReplicatedStorage:WaitForChild("CollisionGroups"))
		part.CollisionGroup = CG.Balls          -- or CG.assign(part, CG.Balls)

	WHY THIS EXISTS (the problems it actually fixes)

	  * Registration order. Every script used to pcall-register the
	    groups it cared about, because sibling script execution order
	    isn't guaranteed and assigning an unregistered group name throws
	    on every single assignment (see AFKHandler's old comment about
	    exactly that failure). That whole class of race is gone:
	    registration happens inside this module, at require time, so ANY
	    script that has a reference to a group name has — by definition,
	    since it got the name from here — already caused every group and
	    every rule to be set up. There is no "which script ran first"
	    question left to answer.

	  * Name drift. "Balls" was spelled out as a literal in six places
	    and as three differently-named constants (BALLS_GROUP,
	    BALL_GROUP, HELD_BALL_GROUP's counterpart...). A typo in any of
	    them is silent: the assignment just fails or lands in a group
	    with no rules, and two overlapping balls violently depenetrate
	    somewhere far away from the typo. CG.Ballz now errors on the
	    spot, at the line that has the typo (see the metatable at the
	    bottom).

	  * Adding anything new. A new group used to mean touching
	    BallManager's registration block, its collidability block, the
	    script that assigns it, and any script that needed to not
	    collide with it. Now it's one entry in GROUPS below.

	HOW A RULE IS DECLARED

	Each entry lists what it PASSES THROUGH (i.e. does not collide
	with). Rules are symmetric, so you only ever have to say it once,
	from whichever side reads more naturally — "an AFK player passes
	through balls" and "balls pass through AFK players" produce exactly
	the same pairing, so pick one and don't write both.

	Three ways to name what you pass through:

	    passesThrough = { "SomeGroup" }        -- one specific group
	    passesThrough = { Tag "Ball" }         -- every group with that tag
	    passesThroughSelf = true               -- ...and your own kind
	    passesThroughEverything = true         -- everything except yourself

	A Tag never pairs a group with itself — that's what passesThroughSelf
	is for. This matters: two awake splitters DO currently collide with
	each other while both passing through everything ball-ish, and that
	distinction has to survive (see SplitterActive below).

	The tags are the part that makes this scale. Tag a new group `Ball`
	and every existing passthrough group ignores it automatically; add a
	new passthrough group and it ignores every ball-ish group
	automatically. Neither side has to be edited to learn about the
	other.

	SERVER VS CLIENT

	Registration and rules are server-only (PhysicsService can only be
	written from the server). The client still gets the names and the
	helpers, which is all GrabClient's optimistic local carry needs —
	groups themselves replicate down from the server on their own.

	DEBUGGING

	CollisionGroups.dump() prints every group, its tags, and its
	resolved non-collidable pairs. Run it from the command bar when
	something is colliding that shouldn't be (or vice versa) — it's the
	real matrix as applied, not a re-reading of the table below.
]]

local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")

-- Roblox's own hard ceiling. Checked at startup so blowing past it
-- surfaces here, with a list of what's using the budget, rather than
-- as a cryptic registration error.
local MAX_ROBLOX_GROUPS = 32

-- marker used by the GROUPS table below — `Tag "Ball"` reads as English
-- and is impossible to confuse with a plain group-name string
local function Tag(name)
	return { __tag = name }
end

-- ── every collision group in the game ───────────────────────────────
-- Order doesn't matter. `doc` is for humans (and dump()); `owner` is
-- the script that's expected to actually put things in the group, so
-- there's always an answer to "who moved this part into that?".
local GROUPS = {
	{
		name = "Default",
		builtin = true, -- Roblox's own; never registered, never removed
		doc = "The platform, map geometry, and anything no other group has claimed. Player characters are NOT resting here any more — their normal state is Players.",
		owner = "Roblox",
	},

	-- ── balls and the board ─────────────────────────────────────────
	{
		name = "Balls",
		tags = { Tag "Ball" },
		doc = "Resting state of every economy object BallManager spawns: balls, bombs, magnets, mimics, radiants. Templates are tagged with this before cloning, so a clone is in it before it ever touches physics.",
		owner = "BallManager (prepareBallPhysics / onHB's COL_Y settle)",
		passesThrough = { Tag "Scenery" },
	},
	{
		name = "SplitGrowing",
		tags = { Tag "Passthrough" },
		doc = "A freshly split half or merge result, from size 0 until its grow tween settles it. Non-collidable against balls and its own kind (it spawns overlapping whatever the splitter/merger was standing in), but still solid against Default so it rests on the platform instead of falling through mid-tween.",
		owner = "BallManager (spawnSplitResult / spawnMergeResult / spawnSplitResultKind)",
		passesThrough = { Tag "Ball", Tag "Passthrough" },
		passesThroughSelf = true,
	},

	-- ── awake specials ──────────────────────────────────────────────
	-- These three share the Passthrough tag: each one passes through
	-- every ball-ish group AND through the other passthrough groups,
	-- while staying solid against Default (the platform) and Players,
	-- which is the interaction each of them is built around.
	{
		name = "SplitterActive",
		tags = { Tag "Passthrough" },
		doc = "An awake splitter. Assigned from spawn, not at COL_Y, so its collision identity is never one frame behind its physics.",
		owner = "BallManager (spawnSplitter) + SplitterFuse/RadiantSplitterFuse's re-pin",
		passesThrough = { Tag "Ball", Tag "Passthrough" },
		passesThroughSelf = true
	},
	{
		name = "MergerActive",
		tags = { Tag "Passthrough" },
		doc = "An awake merger. Polar opposite of SplitterActive, same collision shape — it touch-detects by distance, so it must not physically collide with what it's measuring.",
		owner = "BallManager (spawnMerger) + MergerFuse's re-pin",
		passesThrough = { Tag "Ball", Tag "Passthrough" },
		passesThroughSelf = true
	},
	{
		name = "RadiantPull",
		tags = { Tag "Passthrough" },
		doc = "A radiant bomb for the duration of its halfway pull. Passes through everything it's hauling in (and through other pulling bombs) while staying solid against Default, so it keeps its weight, rests on the platform and can still be shoved by players right up until it detonates.",
		owner = "RadiantBombFuse (triggerHalfwayPull / setPullCollisionGroup)",
		passesThrough = { Tag "Ball", Tag "Passthrough", Tag "Scenery" },
		passesThroughSelf = true,
	},

	-- ── mimics ──────────────────────────────────────────────────────
	{
		name = "MimicBody",
		doc = "An awake board mimic's body. Only ever differs from Default in one pairing — MimicPrey — so a hunting mimic can walk its own center over the one ball it's eating without changing collision for anything else on the board.",
		owner = "MimicFuse (wake-up section)",
		passesThrough = { "MimicPrey", "SplitterActive", "MergerActive" },
	},
	{
		name = "MimicPrey",
		doc = "The single ball a mimic (board or pet) is currently absorbing, for the duration of that hunt only. Restored to its original group by MimicFuse's abort() on any exit except a successful absorb.",
		owner = "MimicFuse's eat() / PetMimicFuse's pullIn()",
		-- NOTE: deliberately untagged, matching today's behavior — a ball
		-- in here is NOT Ball-tagged, so for the length of a hunt it
		-- regains collision against AFK players, splitters, mergers, etc.
		-- Adding `tags = { Tag "Ball" }` here is the one-line fix if you
		-- ever decide that's wrong; it's left alone so this module changes
		-- nothing about how the game currently plays.
	},
	{
		name = "PetMimicBody",
		doc = "A bought pet mimic's body. Collides with nothing in the game except other pet mimics — safe because its standing height comes entirely from AlignPosition's raycast servo, never from physically resting on anything. Only switched in at wake, once that servo is about to take over; any earlier and it falls through the platform on spawn.",
		owner = "PetMimicFuse (wake-up section)",
		-- replaces PetMimicFuse's old runtime loop over
		-- GetRegisteredCollisionGroups, which could only ever exclude
		-- groups that happened to be registered by the time that
		-- particular pet woke up. Resolved here against the full
		-- declaration instead, so it's complete and identical for every
		-- pet regardless of spawn timing.
		passesThroughEverything = true,
	},

	-- ── players and carrying ────────────────────────────────────────
	-- The three PlayerBody groups (Players, AFKPlayers, GrabHolder) are the
	-- states a character can be in. Each passes through every PlayerBody
	-- group, itself included, so players never collide with each other no
	-- matter which state either one is in. Against everything else they
	-- behave exactly as Default did.
	{
		name = "Players",
		tags = { Tag "PlayerBody" },
		doc = "Every BasePart of a player's character in its normal state. Solid against the platform and everything ball-ish exactly like Default, but passes through other player characters so players can't block or shove each other.",
		owner = "DisablePlayerCollisions (on spawn) + whatever restores a character after AFK / carrying",
		passesThrough = { Tag "PlayerBody" },
		passesThroughSelf = true,
	},
	{
		name = "AFKPlayers",
		tags = { Tag "PlayerBody" },
		doc = "Every BasePart of a character flagged AFK. Can't push, be pushed by, or stand on anything ball-ish, and passes through other players like everyone else, but still collides with the platform as normal.",
		owner = "AFKHandler (setCharacterAFK + its reconcile pass)",
		passesThrough = { Tag "Ball", Tag "Passthrough", "HeldBall", Tag "PlayerBody" },
		passesThroughSelf = true,
	},
	{
		name = "HeldBall",
		doc = "A ball currently being carried. Note it is NOT in Balls while held, which is why AFKPlayers has to name it separately above.",
		owner = "GrabHandler (RequestGrab) + GrabClient's optimistic local flip",
		passesThrough = { Tag "Ball", "GrabHolder" },
	},
	{
		name = "GrabHolder",
		tags = { Tag "PlayerBody" },
		doc = "Every BasePart of the character currently carrying a ball, so the ball they're holding doesn't shove them around. Reverted to Players (or AFKPlayers, if they went AFK mid-carry) on release.",
		owner = "GrabHandler (clearHold) + GrabClient's optimistic local flip",
		passesThrough = { Tag "PlayerBody" },
		passesThroughSelf = true,
	},

	-- ── scenery / background dressing ───────────────────────────────
	{
		name = "BG",
		tags = { Tag "Scenery" },
		doc = "bgpillarcollider parts and the ambient balls PillarBallDecor spawns on top of them. Purely decorative — economy balls should never interact with it.",
		owner = "PillarBallDecor",
	},
	{
		name = "Visitor",
		tags = { Tag "Scenery" },
		doc = "visitorPillarCollider parts. Same reasoning as BG.",
		owner = "whatever owns visitorPillarCollider",
	},
}

-- ────────────────────────────────────────────────────────────────────
-- Everything below is machinery. Adding a group means editing the table
-- above and nothing else.
-- ────────────────────────────────────────────────────────────────────

local CollisionGroups = {}

local byName = {}   -- name -> def
local byTag = {}    -- tag name -> { def, ... }
local resolved = {} -- name -> { otherName = true } (non-collidable pairs, as applied)

for _, def in ipairs(GROUPS) do
	assert(type(def.name) == "string", "CollisionGroups: every entry needs a name")
	assert(not byName[def.name], ("CollisionGroups: duplicate group %q"):format(def.name))
	byName[def.name] = def

	for _, tag in ipairs(def.tags or {}) do
		local tagName = tag.__tag
		assert(tagName, ("CollisionGroups: %q has a malformed tag — use Tag \"Name\""):format(def.name))
		byTag[tagName] = byTag[tagName] or {}
		table.insert(byTag[tagName], def)
	end
end

do
	local count = 0
	for _ in pairs(byName) do
		count += 1
	end
	assert(
		count <= MAX_ROBLOX_GROUPS,
		("CollisionGroups: %d groups declared, Roblox allows %d — merge some before adding more"):format(count, MAX_ROBLOX_GROUPS)
	)
end

-- expands one entry's passesThrough/passesThroughSelf/
-- passesThroughEverything into a concrete set of group names. Tags
-- never include the group itself (see the header); an explicitly named
-- group always does, so naming yourself directly works too.
local function resolveTargets(def)
	local targets = {}

	if def.passesThroughEverything then
		for name in pairs(byName) do
			if name ~= def.name then
				targets[name] = true
			end
		end
	end

	for _, entry in ipairs(def.passesThrough or {}) do
		if type(entry) == "table" and entry.__tag then
			local members = byTag[entry.__tag]
			assert(members, ("CollisionGroups: %q passes through tag %q, which no group has"):format(def.name, entry.__tag))
			for _, member in ipairs(members) do
				if member.name ~= def.name then
					targets[member.name] = true
				end
			end
		else
			assert(
				byName[entry],
				("CollisionGroups: %q passes through %q, which isn't a declared group"):format(def.name, tostring(entry))
			)
			targets[entry] = true
		end
	end

	if def.passesThroughSelf then
		targets[def.name] = true
	end

	return targets
end

-- resolved is built on both server and client (it's just table work, no
-- PhysicsService involved) so dump() and the query helpers below answer
-- the same thing on either side.
for _, def in ipairs(GROUPS) do
	resolved[def.name] = resolveTargets(def)
end
-- mirror it, so resolved[a][b] and resolved[b][a] always agree — the
-- engine treats these pairs as symmetric and so should anything reading
-- this table back
for name, targets in pairs(resolved) do
	for other in pairs(targets) do
		resolved[other] = resolved[other] or {}
		resolved[other][name] = true
	end
end

-- ── server-side setup: runs exactly once, at first require ──────────
local function registerAll()
	for _, def in ipairs(GROUPS) do
		if not def.builtin then
			-- pcall because RegisterCollisionGroup errors if the group
			-- already exists (a Studio session that somehow gets here
			-- twice, or a group registered by a plugin/map script). The
			-- IsCollisionGroupRegistered check right after is what
			-- actually confirms it's usable, rather than trusting the
			-- pcall's success alone.
			pcall(function()
				PhysicsService:RegisterCollisionGroup(def.name)
			end)
			assert(
				PhysicsService:IsCollisionGroupRegistered(def.name),
				("CollisionGroups: failed to register %q"):format(def.name)
			)
		end
	end
end

local function applyRules()
	for name, targets in pairs(resolved) do
		for other in pairs(targets) do
			PhysicsService:CollisionGroupSetCollidable(name, other, false)
		end
	end
end

if RunService:IsServer() then
	registerAll()
	applyRules()
end

-- ── names ───────────────────────────────────────────────────────────
-- CG.Balls == "Balls". Going through this rather than writing the
-- literal is what turns a typo into an immediate error (see the
-- metatable at the bottom) instead of a silent physics bug.
for name in pairs(byName) do
	CollisionGroups[name] = name
end

-- ── helpers ─────────────────────────────────────────────────────────

-- true if `name` is a group this module declares. Use this instead of
-- `CollisionGroups[name] ~= nil`, which errors on an unknown name by
-- design.
function CollisionGroups.exists(name)
	return byName[name] ~= nil
end

-- what the engine currently thinks, as opposed to what this module
-- declares — only really differs on the client during the first moments
-- of a session, before groups have replicated down.
function CollisionGroups.isRegistered(name)
	return PhysicsService:IsCollisionGroupRegistered(name)
end

-- Safe assignment. Assigning a CollisionGroup throws if the group isn't
-- registered in this context yet, which on the server can't happen
-- (requiring this module registered everything) but on the client is a
-- real if brief startup window. Warns and returns false rather than
-- taking the caller's whole thread down with it.
function CollisionGroups.assign(part, groupName)
	if not part or not part:IsA("BasePart") then
		return false
	end
	assert(byName[groupName], ("CollisionGroups.assign: unknown group %q"):format(tostring(groupName)))

	local ok, err = pcall(function()
		part.CollisionGroup = groupName
	end)
	if not ok then
		warn(("[CollisionGroups] couldn't move %s into %q — %s"):format(part:GetFullName(), groupName, tostring(err)))
	end
	return ok
end

-- Every BasePart under `root` (and `root` itself, if it is one). This is
-- the character-wide version AFKHandler/GrabHandler/GrabClient each used
-- to keep their own copy of — assigning only the HumanoidRootPart leaves
-- collision quietly still happening through an arm, leg or accessory.
function CollisionGroups.assignDescendants(root, groupName)
	if not root then
		return
	end
	if root:IsA("BasePart") then
		CollisionGroups.assign(root, groupName)
	end
	for _, desc in ipairs(root:GetDescendants()) do
		if desc:IsA("BasePart") then
			CollisionGroups.assign(desc, groupName)
		end
	end
end

-- true if these two groups are declared non-collidable. Handy in a
-- guard or an assert when a script wants to be sure of a pairing it
-- depends on without hardcoding the expectation twice.
function CollisionGroups.passThrough(a, b)
	assert(byName[a] and byName[b], "CollisionGroups.passThrough: unknown group")
	return (resolved[a] and resolved[a][b]) == true
end

-- the declaration for one group (name, doc, owner, tags) — read-only by
-- convention; don't mutate what comes back
function CollisionGroups.info(name)
	return byName[name]
end

-- every declared group name, sorted
function CollisionGroups.list()
	local names = {}
	for name in pairs(byName) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- prints the real, resolved matrix — what's actually been applied, not a
-- re-reading of the GROUPS table. First stop whenever something is
-- colliding that shouldn't be.
function CollisionGroups.dump()
	local out = { "[CollisionGroups] " .. tostring(#GROUPS) .. " groups declared" }
	for _, name in ipairs(CollisionGroups.list()) do
		local def = byName[name]
		local tags = {}
		for _, tag in ipairs(def.tags or {}) do
			table.insert(tags, tag.__tag)
		end

		local others = {}
		for other in pairs(resolved[name] or {}) do
			table.insert(others, other)
		end
		table.sort(others)

		table.insert(out, ("  %s%s\n      owner: %s\n      passes through: %s"):format(
			name,
			#tags > 0 and (" [" .. table.concat(tags, ", ") .. "]") or "",
			def.owner or "(unspecified)",
			#others > 0 and table.concat(others, ", ") or "(nothing — collides with everything)"
			))
	end
	print(table.concat(out, "\n"))
end

-- Unknown key = hard error, right at the line that got it wrong. This is
-- the whole reason to read names off this module instead of typing
-- string literals: `CG.Ballz` stops the script here, where the typo is,
-- rather than silently assigning nothing and surfacing as two balls
-- exploding apart somewhere else entirely. Use CollisionGroups.exists()
-- for an actual "is this a group?" question.
setmetatable(CollisionGroups, {
	__index = function(_, key)
		error(
			("CollisionGroups: %q is not a group or function — check the spelling, or add it to the GROUPS table in ReplicatedStorage.CollisionGroups"):format(tostring(key)),
			2
		)
	end,
	__newindex = function()
		error("CollisionGroups: this module is read-only — declare groups in its GROUPS table instead", 2)
	end,
})

return CollisionGroups