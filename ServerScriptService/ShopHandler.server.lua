--[[
    ShopHandler (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-23 02:07:54
]]
--[[
    ShopHandler (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 18:28:56
]]
--[[
	ShopHandler (Script) — ServerScriptService, sibling of Board,
	BoardService and LeaderboardSetup

	Server side of the upgrade shop. ShopClient invokes BuyUpgrade with
	an id; this looks it up in UpgradeData (the same list the client
	reads to build the menu), checks the player can afford it and doesn't
	already own it, then charges and grants it.

	Owning a flat-price upgrade is nothing more than a BoolValue under
	the player's Upgrades folder named after the id. A tiered one stores
	an IntValue named `id.."Tier"` holding the highest tier owned.
	LeaderboardSetup creates that folder on join and persists it. This
	script doesn't need to know what an upgrade DOES once owned — dash
	is checked by DashClient, grab by GrabClient, stash by StashHandler.

	WHAT CHANGED IN THE REWRITE

	Only the bribe, and only because a bribe is about a board:

	  * It used to reach BallManager through `_G.BallManagerBribe`, with
	    the usual "in case that script hasn't loaded yet" guard. It now
	    requires BoardService and calls bribe() on that player's own
	    board, so a bribe suppresses collapses on THEIR board and
	    nobody else's.
	  * The cooldown used to be one global timer: whoever bought a bribe
	    locked everyone out of buying one for two minutes. With a board
	    each that makes no sense, so it's per player now, mirrored onto
	    an attribute on the PLAYER (rather than on ReplicatedStorage) for
	    ShopClient to grey the button with. That mirror is never read
	    back here — the local table below is the only authority.
	  * The price is 1% of the buyer's own balance rather than 1% of the
	    server average, which is the number that was always intended.
	    See UpgradeData's bribePrice.
]]

local Players = game:GetService("Players")
local Rep = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local UpgradeData = require(Rep:WaitForChild("UpgradeData"))
local Config = require(Rep:WaitForChild("BoardConfig"))
local BoardService = require(ServerScriptService:WaitForChild("BoardService"))
local SellService = require(ServerScriptService:WaitForChild("SellService"))

-- id -> upgrade, built once so a buy doesn't scan the list. Skips
-- id-less entries (the divider), which were never buyable anyway.
local byId = {}
for _, upgrade in ipairs(UpgradeData) do
	if upgrade.id then
		byId[upgrade.id] = upgrade
	end
end

local buyUpgrade = Rep:FindFirstChild("BuyUpgrade") or Instance.new("RemoteFunction")
buyUpgrade.Name, buyUpgrade.Parent = "BuyUpgrade", Rep

local BRIBE_COOLDOWN_ATTRIBUTE = "BribeCooldownUntil"

-- [player] = os.time() the next bribe is allowed. Weak-keyed so a
-- player leaving doesn't leave an entry behind.
local bribeCooldownUntil = setmetatable({}, { __mode = "k" })

-- shared by both branches: deducts and returns true, or returns false
-- having touched nothing
local function tryCharge(cash, price)
	if cash.Value < price then
		return false
	end
	cash.Value -= price
	return true
end

-- Tiered: buying always means "the next tier up". Reuses one IntValue
-- rather than a BoolValue per tier, so consumers only ever have one
-- number to read.
local function buyTier(upgrade, upgrades, cash)
	local tierName = upgrade.id .. "Tier"
	local tierValue = upgrades:FindFirstChild(tierName)
	-- :IsA guard is defensive — a save that comes back the wrong
	-- ClassName reads as tier 0 rather than erroring on .Value, and the
	-- branch below then replaces it properly.
	local currentTier = (tierValue and tierValue:IsA("IntValue")) and tierValue.Value or 0

	local nextTierData = upgrade.tiers[currentTier + 1]
	if not nextTierData then
		return false, "maxed out"
	end

	if not tryCharge(cash, nextTierData.price) then
		return false, "can't afford"
	end

	if tierValue and tierValue:IsA("IntValue") then
		tierValue.Value = currentTier + 1
	else
		if tierValue then
			tierValue:Destroy() -- wrong ClassName from a bad restore; replace it outright
		end
		tierValue = Instance.new("IntValue")
		tierValue.Name, tierValue.Value, tierValue.Parent = tierName, 1, upgrades
	end

	return true
end

-- Repeatable and dynamically priced (just the bribe): nothing is ever
-- written to the Upgrades folder, because there's nothing to own. The
-- price is recomputed on every purchase and the "grant" is re-running
-- the effect.
local function buyBribe(upgrade, player, cash)
	local until_ = bribeCooldownUntil[player]
	if until_ and os.time() < until_ then
		return false, "on cooldown"
	end

	local board = BoardService.get(player)
	if not board then
		return false, "not ready yet"
	end

	local price = upgrade.dynamicPrice(player)
	if not tryCharge(cash, price) then
		return false, "can't afford"
	end

	-- bribe() comes back false if a collapse has already tripped by the
	-- time this lands — most likely exactly when somebody panic-buys
	-- during the countdown and loses the race. Refund rather than
	-- charging for, and announcing, something that didn't happen.
	local ok, reason = board:bribe()
	if not ok then
		cash.Value += price
		return false, reason or "couldn't bribe"
	end

	local nextAllowed = os.time() + Config.BRIBE_COOLDOWN
	bribeCooldownUntil[player] = nextAllowed
	player:SetAttribute(BRIBE_COOLDOWN_ATTRIBUTE, nextAllowed)

	SellService.bribeAnnounce(player)

	return true
end

local function buyFlat(upgrade, upgrades, cash)
	if upgrades:FindFirstChild(upgrade.id) then
		return false, "already owned"
	end

	if not tryCharge(cash, upgrade.price) then
		return false, "can't afford"
	end

	local owned = Instance.new("BoolValue")
	owned.Name, owned.Value, owned.Parent = upgrade.id, true, upgrades

	return true
end

-- Returns true, or (false, reason) so ShopClient can tell "can't afford
-- it" apart from "already owned" instead of both silently doing nothing.
buyUpgrade.OnServerInvoke = function(player, upgradeId)
	local upgrade = typeof(upgradeId) == "string" and byId[upgradeId]
	if not upgrade then
		return false, "invalid upgrade"
	end

	-- generous timeout rather than a bare FindFirstChild: a buy fired
	-- the instant someone joins could in principle race
	-- LeaderboardSetup, even though the UI isn't clickable that fast
	local upgrades = player:WaitForChild("Upgrades", 5)
	local leaderstats = player:WaitForChild("leaderstats", 5)
	local cash = leaderstats and leaderstats:FindFirstChild("$$$")
	if not (upgrades and cash) then
		return false, "not ready yet"
	end

	if upgrade.tiers then
		return buyTier(upgrade, upgrades, cash)
	elseif upgrade.repeatable then
		return buyBribe(upgrade, player, cash)
	end

	return buyFlat(upgrade, upgrades, cash)
end

Players.PlayerAdded:Connect(function(player)
	player:SetAttribute(BRIBE_COOLDOWN_ATTRIBUTE, 0)
end)

for _, player in ipairs(Players:GetPlayers()) do
	player:SetAttribute(BRIBE_COOLDOWN_ATTRIBUTE, 0)
end
