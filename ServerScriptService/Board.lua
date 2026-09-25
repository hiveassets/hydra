--[[
    Board (ModuleScript)
    Path: ServerScriptService
    Parent: ServerScriptService
    Exported: 2026-09-24 20:25:13
]]
--[[
    Board (ModuleScript)
    Path: ServerScriptService
    Parent: ServerScriptService
    Exported: 2026-09-23 02:07:54
]]
--[[
    Board (ModuleScript)
    Path: ServerScriptService
    Parent: ServerScriptService
    Exported: 2026-09-23 00:26:21
]]
--[[
    Board (ModuleScript)
    Path: ServerScriptService
    Parent: ServerScriptService
    Exported: 2026-09-22 18:28:56
]]
--[[
	Board (ModuleScript) — place in ServerScriptService
	(ServerScriptService.Board), alongside BoardService, SellService and
	the rest of the server scripts.

	One player's board, as the server understands it. No Instances, no
	physics, no remotes: a list of balls, a launch queue, the rolls that
	decide what spawns, the ball cap, and the collapse state machine.
	BoardService owns the remotes and hands messages in; the client owns
	everything you can actually see.

	THE LEDGER

	self.balls maps a numeric id to an entry:

		{
			id, kind, size, radiant, color,
			state    = "queued" | "live" | "gone",
			launchAt = server time this ball leaves the spawn point,
			bornAt   = server time it was created,
			growingUntil = for a split half, when it finishes growing in
			           on the client (nil for everything else),
		}

	A merger also carries bornSize, the size it spawned at: each merge
	takes a fifth of THAT off its size (see onMerge).

	A splitter's budget is its size: every split takes SHRINK_PER_SPLIT
	off it here, and the split that would take it to its floor spends it
	(see onSplit). There's no separate uses counter to drift out of step
	with the size a stash slot would store.

	The size in that entry is the only size that exists as far as money
	is concerned. The client never sends one, and nothing here reads one
	from a message. That single rule is what stops "sell my size-1e9
	ball", and it's worth keeping in mind whenever this file grows a new
	event handler.

	THE QUEUE IS A CLOCK, NOT A LOOP

	Every queued ball is stamped with the exact server time it should
	launch, each one GAP after the last. The client holds it until then,
	so the stagger is identical everywhere without a message per launch,
	and the queue LENGTH is just "how many stamps are still in the
	future" — which is what the collapse threshold watches. There's no
	drain loop that can fall behind or get scheduled twice.

	WHAT COUNTS AS TOO SOON

	A ball can't be reported as fallen before it has physically had time
	to launch, arc and come back down past the platform. That's the only
	timing check phase 1 needs, because in phase 1 nothing else can
	remove a ball. Phase 3 adds a budget per special (a splitter only
	gets so many splits, a bomb detonates on a known clock), and phase 4
	adds the rate and value monitoring described in the plan.
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Rep = game:GetService("ReplicatedStorage")
local Config = require(Rep:WaitForChild("BoardConfig"))
local Rules = require(Rep:WaitForChild("BoardRules"))
local Protocol = require(Rep:WaitForChild("BoardProtocol"))

local ToClient = Protocol.ToClient
local CollapsePhase = Protocol.Collapse

local Board = {}
Board.__index = Board

local TICK = 0.1 -- how often the queue is pruned and the overflow re-checked

-- Board.new(player, bridge)
--
-- `bridge` is everything a board needs from the rest of the server,
-- passed in rather than required, so this file has no opinion about
-- chat, payouts or badges:
--   send(op, ...)            -- to this player's client
--   pay(amount)              -- add to their balance
--   fine(fraction)           -- take a share of it, clamped at 0
--   log(message)             -- a line in the server-wide Logs channel
--   tell(message)            -- a line only this player sees, in main chat
--   badge(badgeId)           -- award, once, safely
function Board.new(player, bridge)
	local self = setmetatable({}, Board)

	self.player = player
	self.bridge = bridge

	self.balls = {}
	self.nextId = 1
	self.queue = {}          -- ids in launch order, pruned as their stamps pass
	self.lastLaunchAt = 0

	self.lastSpecialAt = -Config.SPECIAL_COOLDOWN -- lets the first roll happen immediately
	self.lastRadiantAt = -Config.RADIANT_COOLDOWN
	self.bribeUntil = 0

	self.collapsing = false
	self.paused = false
	self.pausedAt = nil      -- when, so the launch queue's clock can be held still
	self.alive = true

	self.countdownActive = false
	self.countdownGeneration = 0
	self.overflowSince = nil
	self.lastTelegraphSecond = nil

	self.awardedFallBadge = false

	self.random = Random.new()

	task.spawn(function()
		while self.alive do
			task.wait(TICK)
			if self.alive then
				self:_tick()
			end
		end
	end)

	return self
end

function Board:destroy()
	self.alive = false
	self.balls = {}
	self.queue = {}
end

-- ── small helpers ─────────────────────────────────────────────────────

local function now()
	return Workspace:GetServerTimeNow()
end

-- Rules' dice-rolling functions take a rand rather than calling
-- math.random themselves (see BoardRules' header). This is the only
-- place in the game that passes a real one in.
function Board:_rand()
	return function()
		return self.random:NextNumber()
	end
end

function Board:_send(...)
	self.bridge.send(...)
end

function Board:entry(id)
	if typeof(id) ~= "number" then
		return nil
	end
	return self.balls[id]
end

-- TWO DIFFERENT QUESTIONS, AND THEY USED TO BE ONE
--
-- `isLive` is the strict one: the launch stamp has passed AND the ball
-- has had LAUNCH_TO_LIVE on top of that to actually rise onto the
-- platform. That grace period is an anti-duplication guard and belongs
-- to FALLS specifically, because a fall is one of the few events that
-- creates value — it turns one ball into two. A client claiming a ball
-- fell before it could plausibly have got anywhere is claiming money,
-- so it's refused.
--
-- `isOnBoard` is the loose one: the stamp has passed, full stop. A ball
-- that is visibly on screen, even mid-rise, is something the player can
-- legitimately click.
--
-- Selling, box-selling and stashing all used the strict one, and that
-- was a bug. None of them create value: the price and the stashed size
-- both come out of this ledger, so selling a ball 0.2s into its rise
-- pays exactly what selling it a second later would. All the grace
-- period did there was refuse a click the player had every right to
-- make — and because the client hides a sold ball the instant it's
-- clicked, a refusal left the ball gone on screen but still sitting in
-- this table, where ensureBall counted it as a ball the board already
-- had. Sell fast enough and the board would empty out and stay empty.
--
-- It also doesn't wait on _pruneQueue's next tick to see the state flip
-- to "live": it reads the clock directly, so there's no extra 100ms
-- window where the answer depends on when a timer last ran.
function Board:isLive(entry)
	return entry ~= nil
		and entry.state == "live"
		and now() >= entry.launchAt + Config.LAUNCH_TO_LIVE
end

function Board:isOnBoard(entry)
	return entry ~= nil
		and entry.state ~= "gone"
		and now() >= entry.launchAt
end

-- Balls actually ON the board — not counting anything still waiting in
-- the launch queue. That distinction matters in both places this is
-- used: the orb cap is about how crowded the platform is (counting the
-- queue made it fire at 50 queued rather than 50 in play), and the
-- only-orb rule is about what's left to sell right now.
--
-- ensureBall deliberately counts differently; see its own loop.
function Board:liveBallCount()
	local count = 0
	for _, entry in pairs(self.balls) do
		if entry.kind == "ball" and entry.state == "live" then
			count += 1
		end
	end
	return count
end

function Board:queueLength()
	self:_pruneQueue()
	return #self.queue
end

-- Anything whose stamp has passed is on the board now, not in the
-- queue. Rebuilt rather than shuffled in place: the queue tops out
-- around OVERFLOW_THRESHOLD entries and this runs ten times a second,
-- so the clearer version is the right trade.
function Board:_pruneQueue()
	local t = now()
	local waiting = {}
	for _, id in ipairs(self.queue) do
		local entry = self.balls[id]
		if entry and entry.state == "queued" then
			if entry.launchAt <= t then
				entry.state = "live"
			else
				table.insert(waiting, id)
			end
		end
	end
	self.queue = waiting
end

-- ── spawning ──────────────────────────────────────────────────────────

-- opts:
--   forceBall  -- skip the special and radiant rolls entirely (the
--                 bootstrap ball should never come out as anything else)
--   radiant    -- force radiant rather than rolling for it
--   kind       -- force a kind (admin summon; phase 3)
--   color      -- carry a colour through rather than rolling one
--
-- `batch`, when given, collects the outgoing payload instead of sending
-- it. Only the admin summon uses it, and only because "!summon ball 5
-- 200" would otherwise be 200 separate remote fires in one frame.
function Board:queueSpawn(size, opts, batch)
	opts = opts or {}

	-- `whilePaused` is for results of something that already happened. A
	-- split reported a moment before an AFK pause landed is a split the
	-- client has already animated — the orb is gone on screen — so its
	-- halves still get queued. They wait out the pause in the queue like
	-- everything else and come out on resume.
	if not self.alive or self.collapsing or (self.paused and not opts.whilePaused) then
		return nil
	end

	local rand = self:_rand()
	local t = now()

	local kind = opts.kind or "ball"
	if not opts.kind and not opts.forceBall then
		-- Gated on the shared cooldown AND on the board already having
		-- some activity, so a brand-new player can't get a special the
		-- very first time they knock the starter ball off.
		if self:liveBallCount() >= Config.SPECIAL_MIN_BALLS
			and t - self.lastSpecialAt >= Config.SPECIAL_COOLDOWN
		then
			local rolled = Rules.rollSpecial(rand)
			if rolled then
				kind = rolled
				self.lastSpecialAt = t
			end
		end
	end

	-- The radiant overlay rolls on top of whatever the slot was going to
	-- spawn — but only for a kind that has a radiant form implemented.
	--
	-- This gate was missing and didn't matter until now: with specials
	-- off, `kind` was always "ball", which supports radiant. The moment
	-- the bomb came back, the roll could have produced a radiant bomb —
	-- an orb with no radiant behaviour to run, whose colour loop would
	-- fight the fuse's own flicker for the same property, and which
	-- sells for 6x instead of 2x. Paying triple for a variant that
	-- doesn't exist yet.
	--
	-- radiantSupported is the seam for step 6: each radiant variant
	-- turns on by returning true for its kind there, and nothing else in
	-- this file changes.
	local radiant = opts.radiant == true

	if radiant and not Rules.radiantSupported(kind) then
		-- An explicit request (an admin summon) for a combination that
		-- doesn't exist. Clamped rather than refused, because queueSpawn
		-- is the one place every spawn goes through and it should never
		-- be the thing that stops a board restocking. Board:summon
		-- checks this up front and says so properly.
		if RunService:IsStudio() then
			warn(("[Board] dropped radiant from a '%s' — no radiant form for that kind yet"):format(kind))
		end
		radiant = false
	end

	if not radiant
		and not opts.forceBall
		and Rules.radiantSupported(kind)
		and t - self.lastRadiantAt >= Config.RADIANT_COOLDOWN
	then
		if Rules.rollRadiant(rand) then
			radiant = true
			self.lastRadiantAt = t
		end
	end

	-- `immediate` jumps the queue instead of taking the next stamp after
	-- it. Only a stash deploy uses it, and it matters: a deploy is an
	-- explicit request for an orb you already own, so waiting out forty
	-- organic spawns to get it back would make the stash feel broken.
	-- It deliberately doesn't touch lastLaunchAt either, so it slots in
	-- alongside the queue rather than pushing everything else back.
	local launchAt
	if opts.at then
		-- An explicit stamp, from a caller laying out its own run of
		-- launches: !summon builds a staggered block starting now, so
		-- its orbs land ahead of anything already waiting. Like
		-- `immediate` it deliberately leaves lastLaunchAt alone, so the
		-- organic queue carries on from where it was rather than being
		-- pushed back by the summon.
		launchAt = opts.at
	elseif opts.immediate then
		launchAt = t
	else
		launchAt = math.max(t, self.lastLaunchAt + Config.GAP)
		self.lastLaunchAt = launchAt
	end

	local entry = {
		id = self.nextId,
		kind = kind,
		size = Rules.clampSize(size or 5),
		radiant = radiant,
		color = opts.color or Rules.randomColor(rand),
		state = "queued",
		launchAt = launchAt,
		bornAt = t,
		-- Until then it's still growing in on the client — anchored, not
		-- yet a solid orb — and the cap never picks it (see _enforceCap).
		growingUntil = opts.growingUntil,
	}
	-- A merger's budget is measured in fifths of the size it was born
	-- at (see BoardRules.mergerAfterMerge). A deploy from the stash is a
	-- new birth at whatever size it was pocketed at — which is what the
	-- old MergerFuse did too, reading its size fresh as it woke.
	if kind == "merger" then
		entry.bornSize = entry.size
	end
	self.nextId += 1
	self.balls[entry.id] = entry
	table.insert(self.queue, entry.id)

	local payload = {
		id = entry.id,
		kind = entry.kind,
		size = entry.size,
		radiant = entry.radiant,
		color = entry.color,
		launchAt = entry.launchAt,
		-- carried through so the client can mark a returning orb with
		-- the cyan glow that pairs with the absorb — a deploy otherwise
		-- looks exactly like an organic spawn, which is deliberate for
		-- everything except that one visual
		stashed = opts.stashed or nil,
		-- an orb growing out of another one rather than launching; see
		-- BoardProtocol's SPAWN for what the client does with these
		emergeFrom = opts.emergeFrom,
		emergeCount = opts.emergeCount,
		bornSize = entry.bornSize,
	}

	if batch then
		table.insert(batch, payload)
	else
		self:_send(ToClient.SPAWN, { payload })
	end

	self:_checkOverflow()
	return entry
end

-- The board is never allowed to sit empty: the last ball being sold or
-- falling off queues a fresh one. Queued balls count, so a split's two
-- replacements don't read as an empty board for the moment they're
-- still in the air.
function Board:ensureBall()
	if self.collapsing or self.paused then
		return
	end
	for _, entry in pairs(self.balls) do
		if entry.kind == "ball" and entry.state ~= "gone" then
			return
		end
	end
	self:queueSpawn(nil, { forceBall = true })
end

function Board:_forget(id, reason)
	local entry = self.balls[id]
	if not entry or entry.state == "gone" then
		return
	end
	entry.state = "gone"
	if reason then
		self:_send(ToClient.REMOVE, id, reason)
	end
	self.balls[id] = nil
end

-- ── the ball cap ──────────────────────────────────────────────────────

-- Over the cap, the smallest ball on the board is sold automatically and
-- the owner is paid for it. Specials don't count and are never picked.
function Board:_enforceCap()
	if self.collapsing then
		return -- the board's being wiped for nothing anyway
	end

	-- "live", not "not gone": a ball that hasn't launched yet isn't on
	-- the platform and shouldn't count toward how full it is, nor be
	-- eligible to be sold out from under a queue that hasn't even
	-- delivered it.
	--
	-- A held ball still counts toward how crowded the board is — it's
	-- sitting right there in front of the player — but is never the one
	-- picked. Having the orb you're carrying vanish out of your hands
	-- because the cap ticked over is the kind of thing you'd assume was
	-- a bug even after someone explained it.
	--
	-- A split half that's still growing in is the same: it counts, but it
	-- isn't picked. The old BallManager excluded its Growing balls for
	-- exactly this reason — an orb that hasn't finished appearing
	-- shouldn't be sold out from under the player.
	local t = now()
	local count, smallest = 0, nil
	for _, entry in pairs(self.balls) do
		if entry.kind == "ball" and entry.state == "live" then
			count += 1
			local growing = entry.growingUntil ~= nil and t < entry.growingUntil
			if not entry.held and not growing and (not smallest or entry.size < smallest.size) then
				smallest = entry
			end
		end
	end

	if count > Config.MAX_BALLS and smallest then
		local amount = Rules.sellValue("ball", smallest.size, smallest.radiant, count)
		self.bridge.pay(amount)
		self.bridge.log(self.bridge.autoSellLine(self.player, amount, smallest.radiant))
		self:_forget(smallest.id, "autoSell")
		self:ensureBall()
	end
end

-- ── overflow and collapse ─────────────────────────────────────────────

function Board:bribe()
	if self.collapsing then
		return false, "a collapse is already in progress"
	end
	self.bribeUntil = now() + Config.BRIBE_DURATION
	self:_cancelCountdown()
	return true
end

function Board:_bribed()
	return self.bribeUntil > 0 and now() < self.bribeUntil
end

function Board:_cancelCountdown()
	if not self.countdownActive then
		return
	end
	self.countdownActive = false
	self.countdownGeneration += 1
	self.overflowSince = nil
	self:_send(ToClient.COLLAPSE, CollapsePhase.CANCEL)
end

function Board:_checkOverflow()
	if self.collapsing or not self.alive then
		return
	end

	local length = self:queueLength()

	if length > Config.OVERFLOW_THRESHOLD and not self:_bribed() then
		if not self.countdownActive then
			self.countdownActive = true
			self.countdownGeneration += 1
			self.overflowSince = now()
			self.lastTelegraphSecond = nil
		end

		local left = math.ceil(Config.OVERFLOW_SUSTAIN - (now() - self.overflowSince))
		if left <= 0 then
			self.countdownActive = false
			self:collapse()
		elseif left ~= self.lastTelegraphSecond then
			-- One message per whole second rather than one per tick: the
			-- client drives its own countdown label and tick sound off
			-- these, and the grade ramp runs locally over the whole
			-- window rather than being stepped from here.
			self.lastTelegraphSecond = left
			self:_send(ToClient.COLLAPSE, CollapsePhase.TELEGRAPH, left)
		end
	elseif self.countdownActive then
		self:_cancelCountdown()
	end
end

function Board:collapse()
	if self.collapsing or not self.alive then
		return false, "a collapse is already in progress"
	end
	self.collapsing = true
	self.countdownActive = false
	self.overflowSince = nil

	-- Everything still queued is dropped outright. The client's own copy
	-- of the queue is cleared by the CUT below, so there's nothing to
	-- send a removal for.
	for _, id in ipairs(self.queue) do
		local entry = self.balls[id]
		if entry then
			entry.state = "gone"
			self.balls[id] = nil
		end
	end
	table.clear(self.queue)

	self:_send(ToClient.COLLAPSE, CollapsePhase.CUT)
	self.bridge.collapseAlert()

	task.spawn(function()
		task.wait(Config.PRE_COLLAPSE_DELAY)
		if not self.alive then
			return
		end

		-- Count what's about to be wiped before wiping it, so the wait
		-- below matches the animation the client is about to play.
		local wiped = 0
		for _, entry in pairs(self.balls) do
			if entry.state ~= "gone" then
				wiped += 1
			end
		end

		self:_send(ToClient.COLLAPSE, CollapsePhase.WIPE)

		-- A collapse takes the stash with it. Off-board is otherwise a
		-- way to sit one out for free, and the toolbar should drain
		-- alongside the board rather than before or after it — which is
		-- why this fires here, with the wipe, and not at the top.
		self.bridge.collapseWipe()

		-- The ledger drops them immediately; the client takes a couple of
		-- seconds to play the wipe out, and nothing in between can pay
		-- anyone, because none of these ids exist any more.
		for id in pairs(self.balls) do
			self.balls[id] = nil
		end

		local wipeTime = math.max(0, wiped - 1) * Config.COLLAPSE_SELL_GAP + Config.PRE_SELL_DELAY
		task.wait(wipeTime + Config.PRE_PENALTY_DELAY)
		if not self.alive then
			return
		end

		self.bridge.fine(Config.COLLAPSE_PENALTY_FRACTION)
		self.bridge.badge(Config.BADGES.collapse)

		-- The penalty is two chat lines with a beat between them, and
		-- the world stays grey until the second one has landed. The old
		-- code got this by accident, because applyCollapsePenalty did
		-- its own task.wait inline and blocked the whole sequence;
		-- spawning the quip instead made the colour come back about two
		-- seconds early. The beat comes back from the call now, so the
		-- pacing is deliberate rather than a side effect of where a
		-- wait happened to sit.
		local quipBeat = self.bridge.collapsePenalty() or 0

		task.wait(quipBeat + Config.POST_COLLAPSE_DELAY)
		self:_send(ToClient.COLLAPSE, CollapsePhase.RESOLVE)
		task.wait(Config.COLLAPSE_FADE_TIME)

		self.collapsing = false
		self.lastLaunchAt = 0 -- a fresh board shouldn't inherit the old queue's stagger
		self:ensureBall()
	end)

	return true
end

-- ── events from the client ────────────────────────────────────────────

-- A settled ball fell off the platform (or wandered out of bounds). The
-- only event in the game that creates value, which is why every check
-- here matters more than the ones around it.
function Board:onFell(id)
	local entry = self:entry(id)
	if not self:isLive(entry) then
		return false, "not a live ball"
	end
	if now() < entry.launchAt + Config.MIN_TIME_BEFORE_FALL then
		-- Refused as a fall, but the ball is still dropped from the
		-- ledger. The client has already lost it — it watched the thing
		-- go over the edge — so leaving the entry here would strand a
		-- ball that exists only on this side: counted against the orb
		-- cap forever, eventually auto-sold for money nobody earned,
		-- while the board on screen looks emptier than the count says.
		--
		-- What the refusal actually denies is the REPLACEMENT, which is
		-- the only part worth anything. A player who somehow manages a
		-- genuinely early fall loses one orb for it; ensureBall covers
		-- them if it was the last one.
		self:_forget(id)
		self:ensureBall()

		-- Studio only: if this ever fires during normal play, the floor
		-- above is too high and orbs are being quietly lost rather than
		-- replaced. Worth knowing while testing; not worth a line in a
		-- live server's log for every exploiter poking at it.
		if RunService:IsStudio() then
			warn(("[Board] refused a fall for orb %d — it was only %.2fs old")
				:format(id, now() - entry.launchAt))
		end

		return false, "too soon"
	end
	if self.collapsing or self.paused then
		return false, "board is not running"
	end

	local rand = self:_rand()
	self:_forget(id) -- no REMOVE message: the client is the one that watched it fall

	-- A mimic that falls off before it ever woke splits exactly like the
	-- orb it was passing for — that was the original design, not an
	-- accident of it. One that's awake is a creature that walked off the
	-- edge, and simply goes, the way a bomb does.
	local fallsLikeABall = entry.kind == "ball" or (entry.kind == "mimic" and not entry.awake)

	if fallsLikeABall then
		if entry.radiant then
			-- A radiant doesn't split. It comes back as a radiant of a
			-- slightly different size, with one ordinary ball alongside it.
			local radiantSize, jitter = Rules.radiantRespawn(entry.size, rand)
			self:queueSpawn(radiantSize, { forceBall = true, radiant = true })
			self:queueSpawn(jitter, { forceBall = true })
		else
			local a, b = Rules.fallReplacements(entry.size, rand)
			self:queueSpawn(a)
			self:queueSpawn(b)
		end

		if not self.awardedFallBadge then
			self.awardedFallBadge = true
			self.bridge.badge(Config.BADGES.fall)
		end
	end

	self:ensureBall()
	return true
end

-- A splitter touched an orb. The second event in the game that can
-- create value — a 4 or a 5 splits into two 3s — so both orbs are held
-- to the STRICT predicate, the same one a fall is (see isLive). The
-- client applies that same check, plus a margin, before it ever starts
-- pulling an orb in, so in normal play this never refuses anything.
--
-- What the client sent is two ids. Everything else comes from here: the
-- halves' sizes from the ledger's size for the orb, their colour and
-- radiance from its entry, and the splitter's remaining budget from its
-- own ledger size. A client that says "I split orb 41" cannot also say
-- what that was worth.
function Board:onSplit(splitterId, ballId)
	if self.collapsing then
		return false, "board is not running"
	end
	-- Deliberately NOT refused while paused. A split reported a moment
	-- before an AFK pause landed has already happened on screen: the orb
	-- converged into the splitter and is gone. Refusing it would strand
	-- that orb on this ledger and cost a resync for nothing. The client
	-- stops starting new splits the moment it's paused; this only ever
	-- sees the ones already in flight.

	local splitter = self:entry(splitterId)
	if not (splitter and splitter.kind == "splitter" and self:isLive(splitter)) then
		return false, "not a live splitter"
	end
	local ball = self:entry(ballId)
	if not (ball and ball.kind == "ball" and self:isLive(ball)) then
		return false, "not a live orb"
	end
	if ball.size <= Config.SPLITTER.MIN_SPLIT_SIZE then
		return false, "too small to split"
	end

	-- The budget. The split that would take the splitter to its floor is
	-- still a split — it just spends it, and the client plays the send-off
	-- instead of the shrink. Forgotten without a REMOVE: the client is
	-- already animating it away.
	local nextSize, spent = Rules.splitterAfterSplit(splitter.size)
	if spent then
		self:_forget(splitterId)
	else
		splitter.size = nextSize
	end

	-- No REMOVE for the orb either: it's the one converging into the
	-- splitter on the client right now.
	self:_forget(ballId)

	-- Stamped for now, not for the end of the convergence. The client
	-- holds them until its own convergence has finished, so they appear
	-- the moment the orb lands inside the splitter whatever the ping was
	-- — and from here they're live and can be split or fall like any
	-- other orb once they've had the usual grace.
	local t = now()
	local growingUntil = t + Config.SPLITTER.CONVERGE_TIME + Config.GROW_TIME

	local a, b = Rules.splitHalves(ball.size)
	local batch = {}
	for _, size in ipairs({ a, b }) do
		self:queueSpawn(size, {
			forceBall = true,       -- a half is never a fresh roll
			radiant = ball.radiant, -- a radiant orb splits into two radiant halves
			color = ball.color,
			at = t,
			whilePaused = true,
			emergeFrom = ballId,
			emergeCount = 2,
			growingUntil = growingUntil,
		}, batch)
	end
	if #batch > 0 then
		self:_send(ToClient.SPAWN, batch)
	end

	self:ensureBall()
	self:_enforceCap()
	return true
end

-- A merger touched two orbs at once. A stock merge is value-neutral —
-- the sizes simply add — but it still goes through the STRICT predicate,
-- because radiance carries: merge a size-3 radiant with a size-50 plain
-- orb and the result is a radiant 53, which sells for three times as
-- much. That's value, so it's held to what a fall is held to.
--
-- Same shape as onSplit otherwise: ids in, everything else from here.
function Board:onMerge(mergerId, idA, idB)
	if self.collapsing then
		return false, "board is not running"
	end
	-- Not refused while paused, for the reason onSplit gives.

	local merger = self:entry(mergerId)
	if not (merger and merger.kind == "merger" and self:isLive(merger)) then
		return false, "not a live merger"
	end
	if idA == idB then
		return false, "the same orb twice"
	end
	local a, b = self:entry(idA), self:entry(idB)
	if not (a and a.kind == "ball" and self:isLive(a)) or not (b and b.kind == "ball" and self:isLive(b)) then
		return false, "not two live orbs"
	end
	local minSize = Config.MERGER.MIN_MERGE_SIZE
	if a.size <= minSize or b.size <= minSize then
		return false, "too small to merge"
	end

	local nextSize, spent = Rules.mergerAfterMerge(merger.size, merger.bornSize or merger.size)
	if spent then
		self:_forget(mergerId) -- the client is already playing its send-off
	else
		merger.size = nextSize
	end

	-- Both are converging into the merger on the client right now.
	self:_forget(idA)
	self:_forget(idB)

	local t = now()
	self:queueSpawn(Rules.mergeSize(a.size, b.size), {
		forceBall = true, -- a result is never a fresh roll
		radiant = a.radiant or b.radiant, -- either one is enough
		color = Rules.mixColor(a.color, a.size, b.color, b.size),
		at = t,
		whilePaused = true,
		-- keyed by the first id, which is where the client wrote down
		-- the merger's position
		emergeFrom = idA,
		emergeCount = 1,
		growingUntil = t + Config.MERGER.CONVERGE_TIME + Config.GROW_TIME,
	})

	self:ensureBall()
	self:_enforceCap()
	return true
end

-- ── the mimic ─────────────────────────────────────────────────────────
-- The client runs the whole creature. The server hears about the three
-- moments that matter to the ledger or the player's account: it woke (a
-- badge, and permission to eat), it ate (money), and it turned back into
-- an orb (a change of kind).

-- A mimic woke up. Marks it awake, which is what onMimicAte checks, and
-- awards the mimic badge — to this player alone, for a mimic on their own
-- board (plan decision 2). That badge is also the pet mimic's shop gate.
--
-- Idempotent on purpose: a resync rebuilds an awake mimic from scratch,
-- dormant, and it wakes a second time. That has to be a quiet yes, not a
-- refusal that costs another resync.
function Board:onMimicWake(id)
	local entry = self:entry(id)
	if not (entry and entry.kind == "mimic" and self:isOnBoard(entry)) then
		return false, "not a mimic on this board"
	end
	if entry.awake then
		return true
	end
	-- The client can't start the clock before the orb launched, so it can
	-- never truthfully report this sooner. The slack only covers the error
	-- in its estimate of server time.
	if now() < entry.launchAt + Config.MIMIC.WAKE_DELAY - 0.5 then
		return false, "too soon to wake"
	end

	entry.awake = true
	if not self.awardedMimicBadge then
		self.awardedMimicBadge = true
		self.bridge.badge(Config.BADGES.mimicWake)
	end
	return true
end

-- A mimic caught an orb. Held to the strict predicate, because it's
-- money: the orb is turned into half its value in cash, straight away.
-- Everything the mimic's own hunt already required, the ledger checks
-- again with its own sizes — awake, a plain orb, not radiant, smaller
-- than the mimic.
--
-- No Logs line. Plan decision 3: mimics are never named in the game until
-- the pet mimic is unlocked, and with per-player badges a line in Logs
-- would give the secret away to anyone who hadn't met one yet.
function Board:onMimicAte(mimicId, preyId)
	if self.collapsing then
		return false, "board is not running"
	end
	-- Not refused while paused, for the reason onSplit gives: the client
	-- stops starting new hunts the moment it's paused, and one that was
	-- already committed has already played out on screen.

	local mimic = self:entry(mimicId)
	if not (mimic and mimic.kind == "mimic" and mimic.awake and self:isLive(mimic)) then
		return false, "not an awake mimic"
	end
	local prey = self:entry(preyId)
	if not (prey and prey.kind == "ball" and self:isLive(prey)) then
		return false, "not a live orb"
	end
	if prey.radiant then
		return false, "a mimic never eats a radiant orb"
	end
	if prey.size >= mimic.size then
		return false, "the orb isn't smaller than the mimic"
	end

	-- The same "last small orb is worth nothing" rule a sell has. The
	-- mimic already refuses to hunt the last orb on the board, so in
	-- normal play this never bites; it's here so the rule can't be
	-- sidestepped by a client that ignores it. Paying nothing rather than
	-- refusing keeps the two sides in agreement about the orb being gone.
	local amount = Rules.mimicValue(prey.size)
	if Rules.isWorthlessOnlyBall(self:liveBallCount(), prey.size) then
		amount = 0
	end

	self:_forget(preyId) -- the client is already floating it up into the mimic
	-- Paid, but not counted toward the $50 / $100 sell badges: those are
	-- for orbs the player sold, and the original's mimicAbsorb never
	-- touched them either.
	self.bridge.pay(amount)

	self:ensureBall()
	self:_enforceCap()
	return true, amount
end

-- An awake mimic turned back into a plain orb: a bomb caught it, or it
-- was shoved off the edge of the platform. From here it's an ordinary orb
-- of the same size and colour — sellable, grabbable, stashable, and it
-- splits if it falls. That's the original design, and it's the one way a
-- mimic ever becomes worth money in its own right.
function Board:onMimicRevert(id)
	local entry = self:entry(id)
	-- Already an orb: both sides agree, so that's a yes. The client
	-- guards against reporting twice, but a bomb and the platform edge
	-- can both reach for the same mimic in one frame, and agreeing is
	-- never worth a board rebuild.
	if entry and entry.kind == "ball" then
		return true
	end
	if not (entry and entry.kind == "mimic" and self:isOnBoard(entry)) then
		return false, "not a mimic on this board"
	end
	if not entry.awake then
		return false, "only an awake mimic can turn back"
	end
	entry.kind = "ball"
	entry.awake = nil
	return true
end

-- Sells one ball at the price the ledger says it's worth. `check` is
-- BoardService's upgrade gate (defuser/degausser); it's passed in rather
-- than read here so this file stays out of the Upgrades folder.
function Board:onSell(id, check)
	local entry = self:entry(id)
	if not self:isOnBoard(entry) then
		return false, "not a ball on this board"
	end
	if self.collapsing or self.paused then
		return false, "board is not running"
	end

	local allowed, reason = check(entry)
	if not allowed then
		return false, reason
	end

	local amount = Rules.sellValue(entry.kind, entry.size, entry.radiant, self:liveBallCount())
	self:_forget(id) -- the client already hid it the moment it was clicked

	self.bridge.pay(amount)
	self.bridge.sellBadges(amount)
	self.bridge.log(self.bridge.sellLine(self.player, entry, amount))

	self:ensureBall()
	self:_enforceCap()
	return true, amount
end

-- The box-select counterpart: one payout, one log line, and every id
-- checked exactly the way a single sell is.
function Board:onSellBox(ids, check)
	-- Every exit from here returns a third value: how many orbs the
	-- client hid that this ledger still holds. That count, and only that
	-- count, is what decides whether the board gets rebuilt.
	if typeof(ids) ~= "table" then
		-- No way to know what they hid, so assume the worst.
		return false, "malformed", 1
	end
	if self.collapsing or self.paused then
		-- The whole selection is hidden on their side and still here on
		-- ours. (A collapse is about to wipe the board anyway, and
		-- reject() sits that case out on its own.)
		return false, "board is not running", #ids
	end

	local liveBalls = self:liveBallCount()
	local total, sold, largest = 0, 0, 0
	local worthless = false

	-- Ids this ledger STILL HOLDS that didn't sell. Deliberately not
	-- "ids that didn't sell": an id the ledger has already dropped is an
	-- orb both sides agree is gone, which is an ordinary race between a
	-- marquee and a falling orb rather than anything to repair. Only an
	-- orb the client hid while this side kept it is a real divergence.
	local stranded = 0

	for _, id in ipairs(ids) do
		if sold >= 300 then -- sanity cap against a forged giant array
			break
		end
		local entry = self:entry(id)
		if entry then
			if self:isOnBoard(entry) and entry.kind == "ball" and not entry.radiant and check(entry) then
				local amount = Rules.sellValue("ball", entry.size, false, liveBalls)
				if amount == 0 then
					worthless = true
				end
				total += amount
				largest = math.max(largest, amount)
				sold += 1
				self:_forget(id)
			else
				stranded += 1
			end
		end
	end

	if sold == 0 then
		-- Nothing sold, and if nothing was stranded either then every
		-- orb in the selection had already left this board too — a
		-- marquee dragged across orbs on their way off the edge. No
		-- payout, no log line, and nothing to repair.
		return false, "nothing to sell", stranded
	end

	self.bridge.pay(total)
	self.bridge.sellBadges(largest)
	self.bridge.log(self.bridge.bulkSellLine(self.player, sold, total, worthless))

	self:ensureBall()
	self:_enforceCap()

	-- The third return is the count above: orbs the client hid that this
	-- ledger still holds. That's the divergence that stops a board
	-- restocking, and BoardService turns a non-zero count into a resync.
	--
	-- In normal play it's always 0 — the marquee filters to exactly what
	-- this loop accepts (plain, non-radiant, settled or rising, not
	-- already selling) — so it's the backstop for a crafted client, or
	-- for the two filters drifting apart in a later phase.
	return true, total, stranded
end

-- Something left the board for a reason that pays nobody: a bomb went
-- off, a magnet finished, a splitter used itself up. Bookkeeping only,
-- and it can't create anything, so there's nothing here to cheat.
-- The player picked a ball up. There's nothing to authorise: carrying
-- an orb doesn't change what it's worth, and a grab that this board
-- would refuse is a grab the player's own client already refused. The
-- flag exists purely so the orb cap looks elsewhere (see _enforceCap).
function Board:onHold(id)
	local entry = self:entry(id)
	if not entry or entry.state == "gone" then
		return false, "unknown"
	end
	-- Deliberately not gated on isLive's grace period, unlike the events
	-- that move money: an orb can be grabbed the instant it appears, and
	-- refusing the flag for the first fraction of a second would leave
	-- exactly the ball in the player's hands eligible for the cap.
	entry.held = true
	return true
end

function Board:onRelease(id)
	local entry = self:entry(id)
	if not entry then
		return false, "unknown"
	end
	entry.held = nil
	return true
end

-- ── stash ─────────────────────────────────────────────────────────────
-- An orb leaving the board for a player's pocket. Worth nothing by
-- itself: the size goes into the slot exactly as the ledger has it, and
-- the money only ever happens later, if and when somebody sells the orb
-- it comes back as.
--
-- `check` is StashHandler's own validator (is this kind stashable at
-- all, can it come back radiant), passed in rather than read here so
-- this file doesn't need to know what a stash slot is — the same shape
-- onSell uses for the defuser gate.
function Board:onStash(id, check)
	local entry = self:entry(id)
	if not self:isOnBoard(entry) then
		return false, "not a ball on this board"
	end
	if self.collapsing or self.paused then
		return false, "board is not running"
	end

	local allowed, reason = check(entry)
	if not allowed then
		return false, reason
	end

	local snapshot = {
		kind = entry.kind,
		-- Whole numbers only in a slot. Everything's already whole except
		-- a merger partway through its budget (a 7 steps down by 1.4), and
		-- it's reborn at whatever size comes back out anyway.
		size = Rules.clampSize(entry.size),
		color = entry.color,
		radiant = entry.radiant,
	}

	self:_forget(id) -- the client has already played the pull and removed it
	self:ensureBall()

	return true, snapshot
end

-- ...and coming back out. It re-enters through the launch queue like
-- everything else rather than appearing in front of the player, which
-- is the whole design of the feature: a stash moves an orb through
-- TIME, never through space.
function Board:deployFromStash(kind, size, color, radiant)
	if self.collapsing or self.paused then
		return false, "board is not running"
	end
	if radiant and not Rules.radiantSupported(kind) then
		-- Refused at the stash, so reaching this means a save written
		-- against a build that still had that behaviour. Hand it back
		-- plain rather than stranding it in the slot forever: the
		-- radiance is already lost either way.
		radiant = false
	end

	self:queueSpawn(size, {
		kind = kind,
		color = color,
		radiant = radiant,
		forceBall = true, -- a deploy is never a fresh roll
		immediate = true,
		stashed = true,
	})
	return true
end

-- Tell a client its claim about an orb was refused, so it can put its
-- board back. This matters because of the order everything happens in:
-- a client hides a sold orb on the click and plays a stash pull before
-- it asks, so a refusal that goes unanswered leaves the orb gone there
-- and still counted here — the softlock from phase 2b.
--
-- The client doesn't try to repair one orb from this; it asks for the
-- whole ledger back. That's heavier than it needs to be and completely
-- immune to being subtly wrong, which is the right trade for a path
-- that shouldn't run at all.
--
-- Skipped during a collapse: the board is being wiped and re-stocked
-- anyway, so a resync would only fight the animation.
function Board:reject(id, reason)
	if self.collapsing then
		return
	end

	-- An id this ledger no longer holds is NOT a divergence — it's
	-- agreement. The client hid an orb that this side had already
	-- removed: it fell a beat before the click landed, or the cap
	-- auto-sold it. Both sides now think that orb is gone, which is
	-- exactly right, and rebuilding the whole board would cost a very
	-- visible hiccup to change nothing.
	--
	-- This guard is the difference between repairing a real divergence
	-- and punishing an ordinary race. Without it, every bulk sell that
	-- happened to catch a falling orb resynced the board.
	if typeof(id) == "number" and self.balls[id] == nil then
		return
	end

	self:_send(ToClient.REJECT, id, reason)
end

function Board:onExpired(id)
	local entry = self:entry(id)
	if not entry then
		return false, "unknown"
	end

	-- Only a special ever expires. A plain orb always leaves by a route
	-- that either pays for it or replaces it — sold, stashed, fallen,
	-- auto-sold — so a plain orb arriving here is an orb being quietly
	-- deleted, which is never something this game wants to do and is
	-- always a bug on the client rather than an attack (it destroys the
	-- player's own money).
	--
	-- Refused silently, and deliberately without a REJECT: a rejection
	-- now costs a full board resync, which is a heavy price for
	-- something that has already done no damage. The Studio warn is the
	-- trail to follow instead.
	if entry.kind == "ball" then
		if RunService:IsStudio() then
			warn(("[Board] %s's client tried to expire plain orb %d — only specials expire")
				:format(self.player.Name, id))
		end
		return false, "a plain orb can't expire"
	end

	self:_forget(id)
	self:ensureBall()
	return true
end

-- Everything currently on the board, for a client that just joined,
-- respawned, or reloaded in Studio. Sent as spawn entries with their
-- original launch stamps — anything already past is launched
-- immediately by the client, which is exactly right for a ball that
-- should already be sitting there.
function Board:snapshot()
	local entries = {}
	for _, entry in pairs(self.balls) do
		if entry.state ~= "gone" then
			table.insert(entries, {
				id = entry.id,
				kind = entry.kind,
				size = entry.size,
				radiant = entry.radiant,
				color = entry.color,
				launchAt = entry.launchAt,
				bornSize = entry.bornSize,
			})
		end
	end
	table.sort(entries, function(a, b)
		return a.launchAt < b.launchAt
	end)
	return entries
end

function Board:resend()
	self:_send(ToClient.RESET)
	local entries = self:snapshot()
	if #entries > 0 then
		self:_send(ToClient.SPAWN, entries)
	end
	self:ensureBall()
end

-- ── admin ─────────────────────────────────────────────────────────────

function Board:summon(kind, size, count, radiant)
	if self.collapsing then
		return false, "can't summon during a collapse"
	end

	-- Checked against the kinds that actually have a template, so a typo
	-- comes back as a message in chat rather than as an orb that spawns
	-- looking like a plain ball and behaving like nothing. Worth having
	-- now: phase 3 is tested almost entirely through this command.
	if not Config.LOOK[kind] then
		local known = {}
		for name in pairs(Config.LOOK) do
			table.insert(known, name)
		end
		table.sort(known)
		return false, ("unknown kind '%s' — try one of: %s"):format(tostring(kind), table.concat(known, ", "))
	end

	if radiant and not Rules.radiantSupported(kind) then
		return false, ("there's no radiant %s yet"):format(kind)
	end

	count = math.clamp(count or 1, 1, 300)

	-- A summon goes to the FRONT of the launch queue: you asked for these
	-- orbs, so they shouldn't wait out a backlog of organic spawns first.
	--
	-- That's done with stamps rather than by reordering anything. Each
	-- summoned orb gets an explicit time starting from now and stepping
	-- by the usual gap, which puts every one of them earlier than
	-- whatever is already pending — and the client sorts its own queue by
	-- stamp, so they come out first without either side being told about
	-- a "front". Still staggered, because fifty orbs materialising in one
	-- frame is a pile, not a summon.
	--
	-- Before this they went through the ordinary path, which stamps from
	-- lastLaunchAt and therefore put them BEHIND everything queued. On a
	-- busy board a summon could take several seconds to show up, which
	-- read as the command not working.
	--
	-- Successive summons stagger against each other too, not just
	-- internally. Two `!summon`s a moment apart would otherwise both
	-- start from now and stamp orbs at identical times, landing them in
	-- the same frame on top of each other at the spawn point — which is
	-- exactly what testing a special looks like.
	local startAt = math.max(now(), (self.lastSummonAt or 0) + Config.GAP)

	local batch = {}
	for index = 1, count do
		-- forceBall here means "don't roll for anything" — an admin
		-- asked for a specific kind, so neither the special roll nor the
		-- radiant roll gets a say.
		self:queueSpawn(size, {
			kind = kind,
			radiant = radiant,
			forceBall = true,
			at = startAt + (index - 1) * Config.GAP,
		}, batch)
	end
	self.lastSummonAt = startAt + (count - 1) * Config.GAP
	-- A big enough summon tips the board into a collapse partway through
	-- the loop above, which clears the ledger — so the batch would be
	-- describing balls the server has already forgotten. Sending it
	-- would put orbs on screen that can never be sold.
	if #batch > 0 and not self.collapsing then
		self:_send(ToClient.SPAWN, batch)
	end
	return true
end

function Board:clear()
	if self.collapsing then
		return false, "a collapse is already in progress"
	end
	for id in pairs(self.balls) do
		self:_forget(id, "adminClear")
	end
	table.clear(self.queue)
	self.lastLaunchAt = 0
	self:ensureBall()
	return true
end

-- ── pause ─────────────────────────────────────────────────────────────

-- The whole board stops: nothing launches, nothing spawns, nothing
-- falls, the orb cap doesn't fire and a collapse countdown stands down.
-- AFK is what calls this today (see AFKHandler).
--
-- The launch queue is a clock, so pausing has to hold that clock still
-- — otherwise every stamp would come due while the player was away and
-- fifty orbs would launch in one frame on their return, straight into
-- the orb cap. On resume, every pending stamp moves forward by however
-- long the pause lasted. The client does exactly the same arithmetic to
-- its own copies off the same two messages, so neither side has to
-- re-send anything.
function Board:setPaused(paused)
	paused = paused == true
	if paused == self.paused then
		return
	end
	self.paused = paused

	if paused then
		self.pausedAt = now()
		self:_cancelCountdown()
	else
		local delta = self.pausedAt and (now() - self.pausedAt) or 0
		self.pausedAt = nil
		if delta > 0 then
			for _, id in ipairs(self.queue) do
				local entry = self.balls[id]
				if entry and entry.state == "queued" then
					entry.launchAt += delta
					if entry.growingUntil then
						entry.growingUntil += delta
					end
				end
			end
			self.lastLaunchAt += delta
		end
	end

	self:_send(ToClient.PAUSE, paused)

	if not paused then
		self:ensureBall()
	end
end

-- ── the tick ──────────────────────────────────────────────────────────

function Board:_tick()
	if self.paused then
		-- Deliberately everything: pruning the queue while paused would
		-- quietly mark balls as launched that the client is still
		-- holding back, and the cap and the overflow check have no
		-- business firing on a board nobody is playing.
		return
	end
	self:_pruneQueue()
	self:_checkOverflow()
	self:_enforceCap()
end

return Board