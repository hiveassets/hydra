--[[
    BoardService (ModuleScript)
    Path: ServerScriptService
    Parent: ServerScriptService
    Exported: 2026-09-22 14:24:25
]]
--[[
	BoardService (ModuleScript) — place in ServerScriptService
	(ServerScriptService.BoardService). Started by BoardServiceLoader,
	the same one-line loader pattern MusicManager already used.

	The door between every client and its own Board. It owns the two
	remotes, one board per player, and the checks every incoming message
	has to pass before a Board ever sees it.

	WHY A MODULE AND NOT A SCRIPT

	The old code reached across script boundaries with 19 `_G` hooks
	(_G.SpawnSplitResult, _G.BallManagerBribe, _G.QueueStashDeploy...),
	each one guarded at the call site with "in case that script hasn't
	loaded yet". A ModuleScript has none of that: ShopHandler,
	AdminCommands and AFKHandler just require this and call
	BoardService.get(player). If this module hasn't finished loading,
	require yields until it has, rather than handing back a nil to
	check for.

	WHAT EVERY MESSAGE GOES THROUGH

	  1. Is this player's board awake? (Not mid-collapse, not paused.)
	  2. Are they under the rate limit? (See EVENT_RATE_LIMIT.)
	  3. Is the payload the right shape?
	  4. Does the Board's own ledger agree it's possible?

	Only step 4 knows about sizes and prices, and it's the only step that
	reads anything about the ball, which is exactly the point: the
	message says what happened, the ledger says what that's worth.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local Rep = game:GetService("ReplicatedStorage")

local Config = require(Rep:WaitForChild("BoardConfig"))
local Protocol = require(Rep:WaitForChild("BoardProtocol"))
local Board = require(ServerScriptService:WaitForChild("Board"))
local SellService = require(ServerScriptService:WaitForChild("SellService"))

local ToServer = Protocol.ToServer

local toServer, toClient = Protocol.remotes(true)

local BoardService = {}

local boards = {}      -- [player] = Board
local rateWindow = {}  -- [player] = { second = os.clock() rounded, count = n }

-- ── upgrade gates ─────────────────────────────────────────────────────
-- Checked fresh on every request rather than trusted from the client,
-- exactly as SellHandler used to: the client hiding an option is a
-- convenience, never enforcement.
local function owns(player, upgradeId)
	local upgrades = player:FindFirstChild("Upgrades")
	return upgrades ~= nil and upgrades:FindFirstChild(upgradeId) ~= nil
end

local function sellCheckFor(player)
	return function(entry)
		if entry.kind == "ball" then
			return true
		elseif entry.kind == "bomb" then
			if not owns(player, "defuser") then
				return false, "defuser not owned"
			end
			return true
		elseif entry.kind == "magnet" then
			if not owns(player, "demagnetizer") then
				return false, "degausser not owned"
			end
			return true
		end
		-- splitters, mergers, mimics and anything added later stay
		-- unsellable unless something explicitly allows them
		return false, "not sellable"
	end
end

-- ── the bridge each board gets ───────────────────────────────────────
-- Everything a Board needs from the rest of the server, with the player
-- already bound, so Board itself never touches chat, badges or
-- leaderstats (see its header).
local function makeBridge(player)
	return {
		send = function(...)
			toClient:FireClient(player, ...)
		end,
		pay = function(amount)
			SellService.pay(player, amount)
		end,
		fine = function(fraction)
			SellService.fine(player, fraction)
		end,
		log = function(message)
			SellService.log(message)
		end,
		tell = function(message)
			SellService.tell(player, message)
		end,
		badge = function(badgeId)
			SellService.badge(player, badgeId)
		end,
		sellBadges = function(amount)
			SellService.sellBadges(player, amount)
		end,
		money = SellService.money,
		sellLine = SellService.sellLine,
		bulkSellLine = SellService.bulkSellLine,
		autoSellLine = SellService.autoSellLine,
		collapseAlert = function()
			SellService.collapseAlert(player)
		end,
		collapsePenalty = function()
			-- returns the beat before the quip, which the collapse waits
			-- out before fading back to colour
			return SellService.collapsePenalty(player)
		end,
		collapseWipe = function()
			BoardService._fireCollapseWipe(player)
		end,
	}
end

-- ── boards ────────────────────────────────────────────────────────────

function BoardService.get(player)
	return boards[player]
end

function BoardService.forEach(fn)
	for player, board in pairs(boards) do
		fn(player, board)
	end
end

-- ── collapse subscribers ──────────────────────────────────────────────
-- Anything that has to be taken along with the board when it collapses
-- registers here. The stash is the only one today.
--
-- Subscription rather than a direct call, so this module doesn't have
-- to know StashHandler exists — StashHandler already requires this one,
-- and two modules requiring each other is a deadlock rather than a
-- design.
local collapseSubscribers = {}

function BoardService.onCollapseWipe(fn)
	table.insert(collapseSubscribers, fn)
end

function BoardService._fireCollapseWipe(player)
	for _, fn in ipairs(collapseSubscribers) do
		local ok, err = pcall(fn, player)
		if not ok then
			warn("[BoardService] a collapse subscriber errored: " .. tostring(err))
		end
	end
end

-- Stops or restarts one player's board. AFKHandler calls this; a
-- deliberate pause button would call exactly the same thing.
function BoardService.setPaused(player, paused)
	local board = boards[player]
	if board then
		board:setPaused(paused)
	end
end

local function addPlayer(player)
	if boards[player] then
		return
	end
	boards[player] = Board.new(player, makeBridge(player))
	-- Deliberately nothing spawns yet. The client asks for its board
	-- with READY once it's actually listening; a ball launched before
	-- then would be one the client never heard about.
end

local function removePlayer(player)
	local board = boards[player]
	if board then
		board:destroy()
		boards[player] = nil
	end
	rateWindow[player] = nil
end

-- ── rate limit ────────────────────────────────────────────────────────
-- A blunt per-second cap, and deliberately so for now: phase 4 replaces
-- it with per-event limits plus the value-per-minute reporting from the
-- plan. This is here to stop a stuck loop or a lazy exploit from
-- burying the server, not to catch anything clever.
local function underRateLimit(player)
	local second = math.floor(os.clock())
	local window = rateWindow[player]
	if not window or window.second ~= second then
		rateWindow[player] = { second = second, count = 1 }
		return true
	end
	window.count += 1
	return window.count <= Config.EVENT_RATE_LIMIT
end

-- ── incoming ──────────────────────────────────────────────────────────

local handlers = {}

handlers[ToServer.READY] = function(_player, board)
	board:resend()
end

handlers[ToServer.FELL] = function(_player, board, id)
	board:onFell(id)
end

handlers[ToServer.SELL] = function(player, board, id)
	if player:GetAttribute("AFK") then
		return
	end
	board:onSell(id, sellCheckFor(player))
end

handlers[ToServer.SELL_BOX] = function(player, board, ids)
	if player:GetAttribute("AFK") then
		return
	end
	board:onSellBox(ids, sellCheckFor(player))
end

handlers[ToServer.EXPIRED] = function(_player, board, id)
	board:onExpired(id)
end

handlers[ToServer.HOLD] = function(_player, board, id)
	board:onHold(id)
end

handlers[ToServer.RELEASE] = function(_player, board, id)
	board:onRelease(id)
end

-- The client watched the throw, because it owns the physics. The server
-- checks the half it can still see: that the thrower was standing on the
-- pad in the middle of the platform. It's a badge, so this is a
-- plausibility check rather than a proof — and the thrower has had a
-- second or two to wander, hence the slack.
handlers[ToServer.TRICK_SHOT] = function(player, _board)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end

	local position = hrp.Position
	local fromCentre = Vector2.new(position.X, position.Z).Magnitude
	if fromCentre > Config.TRICK_ZONE_RADIUS + Config.TRICK_ZONE_SERVER_SLACK then
		return
	end

	SellService.badge(player, Config.BADGES.trickShot)
end

toServer.OnServerEvent:Connect(function(player, op, ...)
	if typeof(op) ~= "string" then
		return
	end

	local board = boards[player]
	if not board then
		return
	end

	if not underRateLimit(player) then
		return
	end

	local handler = handlers[op]
	if not handler then
		return
	end

	handler(player, board, ...)
end)

-- HudUI's "server age" display reads this. BallManager used to set it;
-- it's the one thing that file owned which genuinely belongs to the
-- server rather than to a board.
workspace:SetAttribute("ServerStartTime", os.time())

Players.PlayerAdded:Connect(addPlayer)
Players.PlayerRemoving:Connect(removePlayer)

-- covers anyone already in the server when this starts (Studio's Play
-- Solo, or a hot reload)
for _, player in ipairs(Players:GetPlayers()) do
	addPlayer(player)
end

return BoardService
