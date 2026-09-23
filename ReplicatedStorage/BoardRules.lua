--[[
    BoardRules (ModuleScript)
    Path: ReplicatedStorage
    Parent: ReplicatedStorage
    Exported: 2026-09-23 00:26:23
]]
--[[
    BoardRules (ModuleScript)
    Path: ReplicatedStorage
    Parent: ReplicatedStorage
    Exported: 2026-09-22 18:28:58
]]
--[[
	BoardRules (ModuleScript) — place directly in ReplicatedStorage
	(ReplicatedStorage.BoardRules).

	The game's arithmetic, with no state and no Instances: given some
	numbers, what comes out. Split sizes, merge sizes, sell prices,
	density, launch velocity.

	WHY IT'S SHARED, AND WHAT THAT DOES AND DOESN'T MEAN

	The server uses these to decide what actually happens and what
	actually gets paid. The client uses the same ones to show a price
	label before you click, and to predict a split so the animation can
	start immediately instead of waiting for the server to answer. Both
	sides agreeing is the whole point: the client can show the right
	number without being trusted for it.

	Anything that ROLLS A DICE takes `rand` as an argument rather than
	calling math.random itself. That keeps this module pure, and it keeps
	the honest line visible: only the server ever passes a real random
	function in. A client that called these with its own rand would just
	be making up numbers nobody asked it for — the outcome still comes
	back from the server.
]]

local Config = require(script.Parent:WaitForChild("BoardConfig"))

local BoardRules = {}

-- ── sizes ─────────────────────────────────────────────────────────────

-- Whole numbers, always. TargetSize is what the on-ball readout shows
-- and what every size check compares against, so leaving jitter
-- continuous would let a ball display "10" while actually being 10.4:
-- reading as size 10 but too big for a maxSize-10 grab tier.
local function clampSize(size)
	return math.max(math.round(size), Config.MIN_SIZE)
end

BoardRules.clampSize = clampSize

-- What a ball is SHOWN at when it spawns. Anything bigger than GROW_AT
-- comes in small and grows the rest of the way, so an oversized ball
-- doesn't appear fully formed inside the platform.
function BoardRules.visualSize(size)
	return math.min(size, Config.GROW_AT)
end

-- Roblox mass is density * size^3, so a flat density makes mass grow
-- cubically with size — fine when small, a wall of immovable mass past
-- 50 or 60 studs. Scaling density down by (BASE/size)^1.8 cancels most
-- of that, leaving mass close to linear in size: balls still get heavier
-- as they grow, just not explosively. Clamped above Roblox's own 0.01
-- density floor so absurd sizes don't land on zero.
function BoardRules.densityFor(size, baseSize)
	baseSize = baseSize or Config.BASE_SIZE
	return math.max(Config.BASE_DENSITY * (baseSize / size) ^ 1.8, 0.01)
end

-- Vertical speed comes from the apex height we actually want (v =
-- sqrt(2gh)), read off live gravity rather than a hardcoded number.
-- The obvious alternative — add a flat bit of extra speed per stud of
-- size — scales VELOCITY linearly, and height goes as velocity squared,
-- so apex height blows up quadratically and a size-1000 ball ends up
-- thousands of studs in the sky, tripping MAX_DIST_FROM_ORIGIN before it
-- ever settles. Here the HEIGHT is what scales, linearly, so a big ball
-- reliably clears the platform and comes back down onto it.
function BoardRules.launchVelocity(size, gravity, rand, baseSize)
	baseSize = baseSize or Config.BASE_SIZE
	local angle = rand() * math.pi * 2
	local horizontal = rand() * Config.H_SPEED
	local apex = Config.BASE_APEX_HEIGHT + math.max(size - baseSize, 0) * Config.APEX_HEIGHT_PER_STUD
	local vy = math.sqrt(2 * gravity * apex)
	return Vector3.new(math.cos(angle) * horizontal, vy, math.sin(angle) * horizontal)
end

-- ── what a fall produces ─────────────────────────────────────────────

-- A ball that falls off the platform is replaced by two: one the same
-- size, one jittered by up to SIZE_VAR either way. This is the only
-- place in the game where value is created out of nothing, which is
-- exactly why the server is the one that calls it.
function BoardRules.fallReplacements(size, rand)
	local jitter = clampSize(size + (rand() * Config.SIZE_VAR * 2 - Config.SIZE_VAR))
	return clampSize(size), jitter
end

-- A radiant ball that falls doesn't split. It comes back as a fresh
-- radiant, a little smaller or a little bigger, alongside one ordinary
-- ball jittered the same way an ordinary fall's replacement is — so it
-- reads as "it dropped one, and two more showed up" rather than a single
-- ball reappearing at a different size.
function BoardRules.radiantRespawn(size, rand)
	local deltas = Config.RADIANT_RESPAWN_DELTAS
	local delta = deltas[math.max(1, math.min(#deltas, math.floor(rand() * #deltas) + 1))]
	local jitter = clampSize(size + (rand() * Config.SIZE_VAR * 2 - Config.SIZE_VAR))
	return clampSize(size + delta), jitter
end

-- ── splitter and merger arithmetic (used from phase 3) ───────────────

-- Whole-number halving, except in (MIN_SIZE, 5], which can't halve into
-- two pieces that are both still legal — anything in that band becomes
-- two MIN_SIZEs instead. Slightly more size comes out than went in for a
-- 4 or a 5; that's the one place a stock splitter isn't conservative.
function BoardRules.splitHalves(size)
	if size <= 5 then
		return Config.MIN_SIZE, Config.MIN_SIZE
	end
	local a = math.floor(size / 2)
	return a, size - a
end

function BoardRules.mergeSize(a, b)
	return a + b
end

-- A radiant splitter is a net multiplier on purpose: three results at
-- two thirds each is double what went in.
function BoardRules.radiantSplitThird(size)
	return math.max(Config.MIN_SIZE, math.round(size * (2 / 3)))
end

-- The mirror of that on the merge side: the combined size plus a third
-- of itself.
function BoardRules.radiantMergeSize(a, b)
	local combined = a + b
	return math.round(combined + combined / 3)
end

-- How many times a splitter or merger can act before it hits its own
-- size floor and vanishes. The server uses these as a budget: a
-- splitter that has spent them can't be reported as splitting again, no
-- matter what a client claims.
function BoardRules.splitterUses(size, shrinkPerSplit, floor)
	shrinkPerSplit = shrinkPerSplit or Config.SPLITTER.SHRINK_PER_SPLIT
	floor = floor or Config.SPLITTER.FLOOR
	return math.max(1, math.ceil((size - floor) / shrinkPerSplit))
end

-- What a splitter of `size` is worth after one more split, and whether
-- that split is its last. The split that would take it to FLOOR or below
-- is the one that spends it — it still happens, the splitter just plays
-- its send-off instead of shrinking. Shared so the client's animation
-- and the server's budget can't disagree about which split is the last.
function BoardRules.splitterAfterSplit(size)
	local cfg = Config.SPLITTER
	local nextSize = size - cfg.SHRINK_PER_SPLIT
	return nextSize, nextSize <= cfg.FLOOR
end

function BoardRules.mergerUses(size, shrinkFraction, floor)
	shrinkFraction = shrinkFraction or (1 / 5)
	floor = floor or 3
	local steps = (1 / shrinkFraction) * (1 - floor / math.max(size, 1))
	return math.max(1, math.ceil(steps))
end

-- ── prices ────────────────────────────────────────────────────────────

-- Both halves have to hold: it's the only orb left in play AND it never
-- grew past ONLY_BALL_FREE_MAX_SIZE. A last orb bigger than that sells
-- for its ordinary value.
function BoardRules.isWorthlessOnlyBall(liveBalls, size)
	return (liveBalls or 2) <= 1 and size <= Config.ONLY_BALL_FREE_MAX_SIZE
end

-- kind: "ball" | "bomb" | "magnet" (mimics and pet mimics have their own
-- helper below; splitters and mergers are never sellable).
-- liveBalls is only consulted for a plain ball, and may be nil when the
-- caller doesn't care about the only-orb rule.
function BoardRules.sellValue(kind, size, radiant, liveBalls)
	local m = Config.SELL_MULTIPLIERS

	if kind == "bomb" then
		return math.round(size * (radiant and m.radiantBomb or m.bomb))
	elseif kind == "magnet" then
		return math.round(size * (radiant and m.radiantMagnet or m.magnet))
	end

	if BoardRules.isWorthlessOnlyBall(liveBalls, size) then
		return 0
	end
	return math.round(size * (radiant and m.radiantBall or m.ball))
end

-- A board mimic's catch pays a fraction of the ordinary price; a pet
-- mimic's pays the lot (see the pet mimic's price in UpgradeData — it's
-- bought, not found).
function BoardRules.mimicValue(size)
	return math.ceil(size * Config.MIMIC_SELL_FRACTION)
end

function BoardRules.petMimicValue(size)
	return math.round(size)
end

-- ── rolls (server only, by construction — see the header) ────────────

-- Returns a special kind name, or nil for an ordinary ball. Weights are
-- shares of SPECIAL_TOTAL_CHANCE relative to each other, not chances of
-- their own, so adding a kind to the table doesn't make specials as a
-- whole any more common — it just takes a slice out of the same pie.
function BoardRules.rollSpecial(rand)
	if not Config.SPECIALS_ENABLED then
		return nil
	end

	local total = 0
	for _, weight in pairs(Config.SPECIAL_WEIGHTS) do
		total += weight
	end
	if total <= 0 then
		return nil
	end

	local roll, acc = rand(), 0
	for kind, weight in pairs(Config.SPECIAL_WEIGHTS) do
		acc += (weight / total) * Config.SPECIAL_TOTAL_CHANCE
		if roll < acc then
			return kind
		end
	end
	return nil
end

function BoardRules.rollRadiant(rand)
	return rand() < Config.RADIANT_CHANCE
end

-- Whether a kind can exist in its radiant form. A plain orb always can;
-- the specials each need their own radiant behaviour, and until phase 3
-- puts those back none of them are on the board at all.
--
-- The stash asks this BEFORE taking something, rather than discovering
-- it at deploy time: an orb that can't be handed back the way it went in
-- is worse than one that was never taken.
function BoardRules.radiantSupported(kind)
	if kind == "ball" then
		return true
	end
	return false
end

-- Balls are coloured at spawn by the server rather than the client, for
-- one reason: colour is part of what a stash slot stores, so it has to
-- survive a round trip through the ledger. Radiant balls overwrite it
-- immediately with their own colour loop.
function BoardRules.randomColor(rand)
	return Color3.fromHSV(rand(), 0.5 + rand() * 0.5, 0.75 + rand() * 0.25)
end

return BoardRules