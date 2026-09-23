--[[
    SellService (ModuleScript)
    Path: ServerScriptService
    Parent: ServerScriptService
    Exported: 2026-09-23 02:07:54
]]
--[[
    SellService (ModuleScript)
    Path: ServerScriptService
    Parent: ServerScriptService
    Exported: 2026-09-22 18:28:56
]]
--[[
	SellService (ModuleScript) — ServerScriptService, sibling of Board
	and BoardService.

	Money, badges and words. Everything this module used to do that you
	could SEE — highlights fading in, flashes, sounds, the pre-sell beat
	before a ball was destroyed — now happens on the client that owns the
	ball, so what's left here is the part that has to be true rather than
	the part that has to look right.

	WHAT CHANGED FROM THE OLD FILE

	  * distributePayout paid every player in the server. Payouts now go
	    to the one player whose board it happened on, and the AFK
	    half-rate is gone with it — AFK pauses your own board instead
	    (see AFKHandler).
	  * checkSellBadges awarded to everyone present. Same story: badges
	    go to whoever earned them.
	  * The mimic and pet-mimic log lines are gone entirely. Mimics
	    aren't named anywhere in the game until the pet mimic is
	    unlocked, and a server-wide log would have given that away now
	    that the wake badge is per-player.
	  * The "automated system" lines (the collapse alert, the fine, the
	    quip, the bribe's reaction) go to the player they're about, not
	    the whole server. They're already drawn client-side by
	    SellClient's DisplaySystemMessage, so this is FireClient instead
	    of FireAllClients and nothing else.
	  * The Logs channel is still server-wide, and every line names the
	    player it's about — including the ones that used to be anonymous,
	    like the orb-cap auto-sell.

	This module also owns SellBroadcast and the Logs channel itself now,
	which SellHandler used to. SellHandler is deleted: with ids going
	over the board remote instead of Instances over SellRequest, there
	was nothing left in it.
]]

local Players = game:GetService("Players")
local Rep = game:GetService("ReplicatedStorage")
local TCS = game:GetService("TextChatService")
local BadgeService = game:GetService("BadgeService")

local Config = require(Rep:WaitForChild("BoardConfig"))

-- ── chat plumbing ─────────────────────────────────────────────────────

local sellBroadcast = Rep:FindFirstChild("SellBroadcast") or Instance.new("RemoteEvent")
sellBroadcast.Name, sellBroadcast.Parent = "SellBroadcast", Rep

-- Fired to a player the moment a badge actually lands, so client-side
-- gating (ShopClient's requiresBadge entries) updates without waiting
-- for a rejoin.
local badgeAwarded = Rep:FindFirstChild("BadgeAwarded") or Instance.new("RemoteEvent")
badgeAwarded.Name, badgeAwarded.Parent = "BadgeAwarded", Rep

local LOG_CHANNEL = "Logs"

-- Channel tabs are off by default; SellClient needs this on to render
-- the Logs tab at all.
local tabsConfig = TCS:FindFirstChildOfClass("ChannelTabsConfiguration")
if tabsConfig then
	tabsConfig.Enabled = true
end

local textChannels = TCS:WaitForChild("TextChannels")
local logsChannel = textChannels:FindFirstChild(LOG_CHANNEL) or Instance.new("TextChannel")
logsChannel.Name, logsChannel.Parent = LOG_CHANNEL, textChannels

-- Adds the player as a TextSource so the tab appears, then takes send
-- permission straight back off — membership shouldn't mean anyone can
-- post into the log. pcall'd because AddUserAsync can reject for a
-- player who's mid-leave or whose chat is restricted, and none of that
-- should take this module down.
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

-- ── styling ───────────────────────────────────────────────────────────

local SYS_MSG_COLOR = "#cccccc"
local SYS_MSG_SIZE = 14

local AMOUNT_COLORS = {
	sell = "#FFFF00",
	auto = "#00FFFF",
	penalty = "#FF00FF",
	defuse = "#FF0000",
}

local function styleMessage(text)
	return string.format('<font color="%s" size="%d">%s</font>', SYS_MSG_COLOR, SYS_MSG_SIZE, text)
end

local SellService = {}

function SellService.money(amount, style)
	return string.format('<font color="%s"><b>$%d</b></font>', AMOUNT_COLORS[style or "sell"], amount)
end

-- A line in the server-wide log. Everyone sees these; that's the point
-- of the channel.
function SellService.log(message)
	sellBroadcast:FireAllClients(styleMessage(message), LOG_CHANNEL)
end

-- A line only this player sees, in main chat, unstyled so it renders at
-- normal size. `ping` plays the short cue the automated system's lines
-- have always had.
function SellService.tell(player, message, ping)
	sellBroadcast:FireClient(player, message, nil, ping == true)
end

-- ── money ─────────────────────────────────────────────────────────────

local function cashOf(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	return leaderstats and leaderstats:FindFirstChild("$$$")
end

function SellService.pay(player, amount)
	if amount <= 0 then
		return
	end
	local cash = cashOf(player)
	if cash then
		cash.Value += amount
	end
end

-- Takes a share of a balance, never below zero. Rounded down, so a
-- player with nothing loses nothing.
function SellService.fine(player, fraction)
	local cash = cashOf(player)
	if not cash then
		return 0
	end
	local penalty = math.floor(cash.Value * fraction)
	cash.Value = math.max(0, cash.Value - penalty)
	return penalty
end

-- ── badges ────────────────────────────────────────────────────────────

-- [userId] = { [badgeId] = true } — AwardBadge is idempotent server-side,
-- so this isn't needed for correctness. It's here because a busy board
-- can ask for the same badge many times a second, and every one of those
-- is a web call.
local awardedThisSession = {}

function SellService.badge(player, badgeId)
	local userId = player.UserId
	local owned = awardedThisSession[userId]
	if not owned then
		owned = {}
		awardedThisSession[userId] = owned
	end
	if owned[badgeId] then
		return
	end
	owned[badgeId] = true

	task.spawn(function()
		local ok, err = pcall(BadgeService.AwardBadge, BadgeService, userId, badgeId)
		if not ok then
			warn("[SellService] AwardBadge failed for", userId, ":", err)
			return
		end
		if player.Parent then
			badgeAwarded:FireClient(player, badgeId)
		end
	end)
end

Players.PlayerRemoving:Connect(function(player)
	awardedThisSession[player.UserId] = nil
end)

-- The "sold an orb worth at least this much" milestones. `amount` must
-- be ONE ball's payout, never a batch total — a bulk sell passes its
-- biggest single amount, which clears exactly the same tiers as testing
-- every ball would.
function SellService.sellBadges(player, amount)
	for _, tier in ipairs(Config.SELL_BADGE_THRESHOLDS) do
		if amount >= tier.amount then
			SellService.badge(player, tier.badge)
		end
	end
end

-- ── log lines ─────────────────────────────────────────────────────────

local function who(player)
	return string.format("<b>%s (@%s)</b>", player.DisplayName, player.Name)
end

-- `entry` is the board's own ledger entry, so the kind, size and
-- radiance in the line are the same ones that decided the payout.
function SellService.sellLine(player, entry, amount)
	if entry.kind == "bomb" then
		return string.format(
			entry.radiant and "%s defused a <b>radiant</b> bomb for %s" or "%s defused a bomb for %s",
			who(player),
			SellService.money(amount, "defuse")
		)
	elseif entry.kind == "magnet" then
		return string.format(
			entry.radiant and "%s degaussed a <b>radiant</b> magnet for %s" or "%s degaussed a magnet for %s",
			who(player),
			SellService.money(amount, "defuse")
		)
	elseif amount == 0 then
		return string.format("%s tried to sell their only orb, but it wasn't worth anything...", who(player))
	end

	return string.format(
		entry.radiant and "%s sold a <b>radiant</b> orb for %s" or "%s sold an orb for %s",
		who(player),
		SellService.money(amount, "sell")
	)
end

-- The orb cap firing used to read "max orbs reached !!! smallest orb was
-- auto-sold for $x", with no idea whose board it was — fine when there
-- was only one. Now it names the owner like every other line.
function SellService.autoSellLine(player, amount, radiant)
	return string.format(
		radiant
			and "%s's board hit the max orbs !!!! their smallest orb was <b>radiant</b> and auto-sold for %s"
			or "%s's board hit the max orbs !!!! their smallest orb auto-sold for %s",
		who(player),
		SellService.money(amount, "auto")
	)
end

function SellService.bulkSellLine(player, count, total, worthless)
	if worthless and count == 1 then
		return string.format("%s tried to sell their only orb, but it wasn't worth anything...", who(player))
	elseif count == 1 then
		-- a box that only caught one orb reads exactly like a plain click
		-- on that orb, rather than as a one-item "bulk sold"
		return string.format("%s sold an orb for %s", who(player), SellService.money(total, "sell"))
	end
	return string.format("%s bulk sold some orbs for %s", who(player), SellService.money(total, "sell"))
end

-- ── the automated system ──────────────────────────────────────────────
-- Three beats, same as before: an alert as the collapse starts, then the
-- consequence and a quip once the fine actually lands. Each goes to the
-- one player whose board it is.

local STAR = '<font color="#FF00FF"><b>★</b>  · </font> '

local COLLAPSE_ALERT_LINES = {
	"critical mass has been detected, wiping your board ...",
	"imminent pillar collapse has been detected, wiping your board ...",
	"perpetual motion has been detected, wiping your board ...",
}

-- %d%% gets filled in with the penalty percentage
local COLLAPSE_PENALTY_LINES = {
	"youre getting hit with a %d%% fine for that (sorry)",
	"i gotta take %d%% of your money as compensation",
	"our policy says i have to take %d%% of your balance",
	"deducting %d%% from your balance (sorry)",
	"deducting %d%% from your balance (i'm probably gonna pocket like 3/4ths of this)", -- easter egg
}

local COLLAPSE_QUIPS = {
	"try to keep that orb queue below 150 pls",
	"dont do that again . im watching u",
	"i kow it sucks but last time we let the queue pile up someone made trillions ...",
	"don't worry, ur not the first and wont be the last",
	"id listen to the little voice in the queue counter if i were u",
	"you can press ALT to cycle through counters at the top if that helps",
	"consider buying the defuser to prevent bombs from detonating",
	"consider buying the defuser to prevent magnets from activating",
	"consider buying the ... nevermind u cant sell splitter orbs",
	"consider buying the ... nevermind u cant sell merger orbs",
	"assuming this is your first collapse,, enjoy your new badge !! (dont do that again)",
	"i do accept bribes if u want me to go away for a bit (shhhhhh)",
	"radiant orbs pay out triple if that makes selling more appealing ?",
	"u can make that money back ... probably",
}

local function pick(pool)
	return pool[math.random(#pool)]
end

function SellService.collapseAlert(player)
	SellService.tell(player, STAR .. pick(COLLAPSE_ALERT_LINES), true)
end

-- Returns how long the quip takes to arrive, because the collapse
-- itself waits for it: the board stays grey and frozen until the
-- automated system has finished talking (see Board's collapse
-- sequence).
function SellService.collapsePenalty(player)
	local percent = Config.COLLAPSE_PENALTY_FRACTION * 100

	SellService.tell(player, STAR .. string.format(pick(COLLAPSE_PENALTY_LINES), percent), true)

	SellService.log(string.format(
		"<b>an automated system</b> detected an imminent pillar collapse on %s's board and intervened, deducting <font color=\"#FF00FF\"><b>%d%%</b></font> of their balance as punishment",
		who(player),
		percent
		))

	-- a beat before the quip so the two lines don't land on the same
	-- cadence every time. math.random(2, 2.5) can't do this — with two
	-- arguments it only ever returns whole numbers, so the old version
	-- always waited exactly 2 seconds.
	local beat = 2 + math.random() * 0.5

	task.spawn(function()
		task.wait(beat)
		if player.Parent then
			SellService.tell(player, STAR .. pick(COLLAPSE_QUIPS), true)
		end
	end)

	return beat
end

local BRIBE_REACTION_LINES = {
	"ooooh money",
}

local BRIBE_QUIPS = {
	"dont mind if i do",
}

function SellService.bribeAnnounce(player)
	SellService.log(string.format(
		"%s bribed the automated system !!! collapses on their board are <font color=\"#FF00FF\">disabled</font> for %d seconds",
		who(player),
		Config.BRIBE_DURATION
		))

	SellService.tell(player, STAR .. pick(BRIBE_REACTION_LINES), true)

	task.spawn(function()
		task.wait(2 + math.random() * 0.5)
		if player.Parent then
			SellService.tell(player, STAR .. pick(BRIBE_QUIPS), true)
		end
	end)
end

return SellService
