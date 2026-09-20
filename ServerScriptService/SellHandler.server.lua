--[[
    SellHandler (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-20 20:00:08
]]
--[[
	SellHandler (Script) — ServerScriptService

	Server side of player-initiated sells. SellClient fires SellRequest
	with whatever ball the player clicked while in sell mode; this
	validates it's a real, currently-live regular ball sitting in
	Workspace.Balls, then hands it to SellService.sellWithHighlight,
	which pays out and broadcasts the chat line immediately, then
	fades in a highlight for a beat — for every client except the
	seller, whose own client has already predicted the ball's removal
	locally (see SellClient) — before the ball is actually destroyed.
	Same routine BallManager's ball-cap auto-sell uses, so a manual
	sell and an auto-sell behave identically other than the highlight
	color and the chat line.

	A player currently flagged AFK (see AFKHandler, a sibling script)
	is rejected outright, before any of the checks below — same
	never-trust-the-client treatment as everything else here.

	A bomb is also accepted, but ONLY from a player who currently owns
	the "defuser" upgrade (a plain BoolValue under their Upgrades
	folder, exactly like any other flat-price upgrade — see
	UpgradeData/ShopHandler) — checked fresh on every request rather
	than trusted from the client, same as everything else validated
	below. A magnet works exactly the same way, gated on "demagnetizer"
	instead — see the isMagnet check below, which mirrors isBomb's in
	every way but the upgrade id it looks for. Any other special
	variant (or a bomb/magnet from a player who doesn't own the
	matching upgrade) still gets rejected by name, so this stays
	specific to those two rather than opening the door to every current
	and future special ball. SellService.sellWithHighlight itself is
	what actually pays the 2x-size/red-flash sell out differently from
	a regular one for both — see its header.

	SellHandler owns creating SellRequest and SellBroadcast; SellService
	and BallManager just wait on them (see SellService's header). That
	creation has to happen BEFORE requiring SellService below — its
	module body WaitForChild's SellBroadcast at require-time, so
	requiring it first would deadlock this script waiting on a remote
	that the very next lines were supposed to create.

	SellBoxRequest is the bulk-sell counterpart to SellRequest: SellClient
	fires it once, with an array of ball references, whenever the player
	click-drags a selection box over the board instead of clicking a
	single ball (see SellClient's header for the box-select UX itself).
	Every entry gets the same never-trust-the-client re-validation a
	single SellRequest target gets below — live, currently sitting in
	Workspace.Balls, not already PendingSell — just applied per-array-
	entry instead of to one target. Deliberately narrower than
	SellRequest though: only plain, non-radiant balls are accepted here,
	nothing named bombT.Name or magnetT.Name gets through the filter at
	all, so there's no defuser/demagnetizer branch to mirror from the
	single-sell handler below — a box sell is a "bunch of orbs" or
	nothing. A radiant ball (IsRadiant attribute — see BallManager) is
	excluded the same deliberate way: it's still ballT.Name, so the Name
	check alone wouldn't catch it, hence the explicit IsRadiant check
	below right next to it — a radiant orb is meant to be cashed out
	individually via a plain SellRequest (see sellWithHighlight's own
	radiant handling), never swept up anonymously in a bulk sell. The
	whole batch is handed to SellService.sellBoxWithHighlight, which pays
	out and broadcasts a single combined chat line, then fades in the
	same per-ball highlight sellWithHighlight uses before destroying each
	one — see its own header.

	Also sets up the "Logs" TextChannel that SellClient routes the
	routine sell-log lines into (see LOG_CHANNEL in SellService) — this
	has to happen here rather than in SellClient because
	TextChannel:AddUserAsync only works from a server Script. Every
	player gets added so their client actually gets a tab for it, but
	CanSend is forced off on each TextSource the instant it's added, so
	membership doesn't reopen the ability to send.
]]

local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local TCS = game:GetService("TextChatService")
local Players = game:GetService("Players")

-- same create-if-missing pattern BallManager uses for SoundEvents
local sellRequest = Rep:FindFirstChild("SellRequest") or Instance.new("RemoteEvent")
sellRequest.Name, sellRequest.Parent = "SellRequest", Rep

local sellBroadcast = Rep:FindFirstChild("SellBroadcast") or Instance.new("RemoteEvent")
sellBroadcast.Name, sellBroadcast.Parent = "SellBroadcast", Rep

-- bulk-sell counterpart to sellRequest — see the header above. Created
-- here too rather than lazily on first use, same reasoning as the other
-- two: one place owns remote creation for this whole feature
local sellBoxRequest = Rep:FindFirstChild("SellBoxRequest") or Instance.new("RemoteEvent")
sellBoxRequest.Name, sellBoxRequest.Parent = "SellBoxRequest", Rep

-- channel tabs are off by default; SellClient relies on this being on
-- to render the Logs tab at all
local ChannelTabsConfig = TCS:FindFirstChildOfClass("ChannelTabsConfiguration")
if ChannelTabsConfig then
	ChannelTabsConfig.Enabled = true
end

local textChannels = TCS:WaitForChild("TextChannels")
local logsChannel = textChannels:FindFirstChild("Logs") or Instance.new("TextChannel")
logsChannel.Name, logsChannel.Parent = "Logs", textChannels

-- adds the player as a TextSource (so their tab shows up) then
-- immediately strips send permission back off — pcall'd since
-- AddUserAsync can reject/error for a player who's mid-leave or whose
-- chat is otherwise restricted, and none of that should take this
-- script down
local function addToLogs(player)
	local ok, source = pcall(function()
		return logsChannel:AddUserAsync(player.UserId)
	end)
	if ok and source then
		source.CanSend = false
	end
end

Players.PlayerAdded:Connect(addToLogs)
for _, player in ipairs(Players:GetPlayers()) do
	addToLogs(player)
end

local SellService = require(script.Parent:WaitForChild("SellService"))

local bf = WS:WaitForChild("Balls")
local ballT = Rep:WaitForChild("Ball") -- name check below excludes any special variant that isn't explicitly allowed
local bombT = Rep:WaitForChild("Bomb") -- one of the special variants that IS sellable, and only for a defuser owner (see below)
local magnetT = Rep:WaitForChild("Magnet") -- same deal as bombT, gated on "demagnetizer" instead of "defuser" (see below)

sellRequest.OnServerEvent:Connect(function(player, target)
	-- reject anything that isn't a live ball/bomb currently sitting in
	-- the shared folder — covers forged/stale references and blocks a
	-- second sell attempt on something already sold
	if typeof(target) ~= "Instance" or not target:IsA("BasePart") or target.Parent ~= bf then
		return
	end

	-- AFKHandler flags a player AFK on request and is the source of
	-- truth for the attribute; checked fresh here same as
	-- defuser/demagnetizer below, never trusted from whatever
	-- SellClient predicted
	if player:GetAttribute("AFK") then
		return
	end

	local isBomb = target.Name == bombT.Name
	local isMagnet = target.Name == magnetT.Name
	if target.Name ~= ballT.Name and not isBomb and not isMagnet then
		-- any other special variant, present or future, stays unsellable.
		-- A radiant ball needs no case here — it's ballT.Name (an
		-- IsRadiant attribute, not a distinct Name — see BallManager) so
		-- it already passes via the plain ballT.Name check, same as any
		-- other ball.
		return
	end

	if isBomb then
		-- re-checked fresh here rather than trusted from the client —
		-- SellClient is only supposed to let a bomb into sell mode at
		-- all once this is owned, but that's a UX nicety, not
		-- enforcement
		local upgrades = player:FindFirstChild("Upgrades")
		if not (upgrades and upgrades:FindFirstChild("defuser")) then
			return
		end
	end

	if isMagnet then
		-- exact same reasoning/enforcement as the isBomb check above,
		-- just gated on "demagnetizer" instead of "defuser"
		local upgrades = player:FindFirstChild("Upgrades")
		if not (upgrades and upgrades:FindFirstChild("demagnetizer")) then
			return
		end
		-- demagnetizer only cashes a magnet out before it goes live —
		-- Pulling is set by MagnetFuse the instant the pull itself
		-- starts (see its header), so a magnet already mid-pull is
		-- rejected here regardless of what SellClient predicted
		if target:GetAttribute("Pulling") then
			return
		end
	end
	-- already mid pre-sell highlight (this request, another player's
	-- click, or the ball-cap auto-sell) — sellWithHighlight guards
	-- against this itself, but checking here too skips even queuing a
	-- redundant task.spawn
	if target:GetAttribute("PendingSell") then
		return
	end

	task.spawn(SellService.sellWithHighlight, target, player)
end)

-- purely a sanity cap against a forged giant array arriving in one
-- request — every entry below still has to pass the exact same
-- live-ball/parent/PendingSell checks a single SellRequest target does,
-- so this only guards against wasted iteration on obvious garbage, not
-- against a legitimately large on-screen selection (a box big enough to
-- catch this many balls at once isn't realistic on a normal board)
local MAX_BOX_SELL = 300

sellBoxRequest.OnServerEvent:Connect(function(player, targets)
	-- same AFK gate as sellRequest above, checked before anything else
	if player:GetAttribute("AFK") then
		return
	end

	if typeof(targets) ~= "table" then
		return
	end

	-- re-validated fresh here exactly like sellRequest's single target
	-- above — real, currently-live, not already mid-sell — just applied
	-- per entry. Only ballT.Name gets through: no bomb/magnet branch to
	-- mirror from the single-sell handler above, since box select never
	-- offers those as selectable in the first place (see SellClient) —
	-- so a client that somehow slips one in here just has it silently
	-- dropped by the Name check rather than needing its own
	-- defuser/demagnetizer re-check. A radiant ball passes the Name
	-- check (it's still ballT.Name — an IsRadiant attribute, not a
	-- distinct Name, same as everywhere else in this file), so it gets
	-- its own explicit exclusion right here rather than being caught by
	-- the Name filter — a client that slips one into the array (box
	-- select isn't supposed to offer one as selectable at all, see
	-- SellClient) just has it silently dropped, same as a bomb or
	-- magnet would be.
	local valid = {}
	for _, target in ipairs(targets) do
		if #valid >= MAX_BOX_SELL then
			break
		end
		if
			typeof(target) == "Instance"
			and target:IsA("BasePart")
			and target.Parent == bf
			and target.Name == ballT.Name
			and not target:GetAttribute("IsRadiant")
			and not target:GetAttribute("PendingSell")
		then
			valid[#valid + 1] = target
		end
	end

	if #valid == 0 then
		return
	end

	task.spawn(SellService.sellBoxWithHighlight, valid, player)
end)