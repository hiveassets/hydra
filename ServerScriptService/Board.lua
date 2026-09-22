--[[
    Board (ModuleScript)
    Path: ServerScriptService
    Parent: ServerScriptService
    Exported: 2026-09-22 13:33:36
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
			uses     = how many splits/merges a splitter/merger has left
			           (phase 3; nil for everything else),
		}

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

-- A ball is only "live" once its launch stamp has passed and it has had
-- LAUNCH_TO_LIVE to actually rise onto the platform. Anything the
-- client claims about a ball before that is refused.
function Board:isLive(entry)
	return entry ~= nil
		and entry.state == "live"
		and now() >= entry.launchAt + Config.LAUNCH_TO_LIVE
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
	if not self.alive or self.collapsing or self.paused then
		return nil
	end

	opts = opts or {}
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

	local radiant = opts.radiant == true
	if not radiant and not opts.forceBall and t - self.lastRadiantAt >= Config.RADIANT_COOLDOWN then
		if Rules.rollRadiant(rand) then
			radiant = true
			self.lastRadiantAt = t
		end
	end

	local launchAt = math.max(t, self.lastLaunchAt + Config.GAP)
	self.lastLaunchAt = launchAt

	local entry = {
		id = self.nextId,
		kind = kind,
		size = Rules.clampSize(size or 5),
		radiant = radiant,
		color = opts.color or Rules.randomColor(rand),
		state = "queued",
		launchAt = launchAt,
		bornAt = t,
	}
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
	local count, smallest = 0, nil
	for _, entry in pairs(self.balls) do
		if entry.kind == "ball" and entry.state == "live" then
			count += 1
			if not entry.held and (not smallest or entry.size < smallest.size) then
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

	if entry.kind == "ball" then
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

-- Sells one ball at the price the ledger says it's worth. `check` is
-- BoardService's upgrade gate (defuser/degausser); it's passed in rather
-- than read here so this file stays out of the Upgrades folder.
function Board:onSell(id, check)
	local entry = self:entry(id)
	if not self:isLive(entry) then
		return false, "not a live ball"
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
	if typeof(ids) ~= "table" then
		return false, "malformed"
	end
	if self.collapsing or self.paused then
		return false, "board is not running"
	end

	local liveBalls = self:liveBallCount()
	local total, sold, largest = 0, 0, 0
	local worthless = false

	for _, id in ipairs(ids) do
		if sold >= 300 then -- sanity cap against a forged giant array
			break
		end
		local entry = self:entry(id)
		if self:isLive(entry) and entry.kind == "ball" and not entry.radiant then
			local allowed = check(entry)
			if allowed then
				local amount = Rules.sellValue("ball", entry.size, false, liveBalls)
				if amount == 0 then
					worthless = true
				end
				total += amount
				largest = math.max(largest, amount)
				sold += 1
				self:_forget(id)
			end
		end
	end

	if sold == 0 then
		return false, "nothing to sell"
	end

	self.bridge.pay(total)
	self.bridge.sellBadges(largest)
	self.bridge.log(self.bridge.bulkSellLine(self.player, sold, total, worthless))

	self:ensureBall()
	self:_enforceCap()
	return true, total
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

function Board:onExpired(id)
	local entry = self:entry(id)
	if not entry then
		return false, "unknown"
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
	count = math.clamp(count or 1, 1, 300)

	local batch = {}
	for _ = 1, count do
		-- forceBall here means "don't roll for anything" — an admin
		-- asked for a specific kind, so neither the special roll nor the
		-- radiant roll gets a say.
		self:queueSpawn(size, { kind = kind, radiant = radiant, forceBall = true }, batch)
	end
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
