--[[
    ShopHandler (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 13:33:36
]]
--[[
	ShopHandler (Script) — ServerScriptService, sibling of SellHandler,
	BallManager, and LeaderboardSetup

	Server side of the upgrade shop. ShopClient invokes BuyUpgrade with
	an upgrade id; this looks the id up in UpgradeData (the same shared
	list ShopClient reads to build the menu), checks the player can
	actually afford it and doesn't already own it, then deducts the
	cost and grants it.

	"Owning" a flat-price upgrade is nothing more than a BoolValue
	under the player's Upgrades folder named after the upgrade's id.
	LeaderboardSetup creates that folder alongside leaderstats on join
	and is what actually persists it to the datastore (see the rename
	note there). This script doesn't need to know how, or whether, an
	upgrade does anything once owned — e.g. DashClient just checks for
	its own BoolValue client-side.

	A tiered upgrade (has `tiers` instead of `price` — see
	UpgradeData's grab entry) works the same way but stores an IntValue
	named `id.."Tier"` instead of a BoolValue: buying one always means
	"buy whatever the next tier up is". GrabHandler is the one that
	actually reads the resulting tier IntValue to gate what size ball a
	player can pick up — this script only owns selling the tiers.

	A repeatable/dynamic-price upgrade (has `dynamicPrice` and
	`repeatable = true` instead of `price`/`tiers` — currently just
	bribe) never touches the Upgrades folder at all: there's nothing to
	own, so nothing to check or write. Price is recomputed fresh every
	purchase via the upgrade's own zero-argument dynamicPrice function
	(bribe's reads Players/leaderstats directly — see UpgradeData), and
	the "grant" is just re-running the upgrade's effect —
	_G.BallManagerBribe(), which disables the overflow-collapse trigger
	for a while — rather than flipping a value on. See buyBribe below.

	buyBribe checks _G.BallManagerBribe's own return value rather than
	assuming it always succeeds — it can come back false if a collapse
	already tripped before the purchase landed, in which case buyBribe
	refunds the price and skips arming the cooldown/announcing, instead
	of charging for and "announcing" a bribe that didn't actually do
	anything.

	buyBribe is also the one branch here gated by something beyond
	afford/own/maxed: a global, server-wide cooldown (bribeCooldownUntil)
	that blocks every player's purchases for BRIBE_COOLDOWN_SECONDS once
	anyone buys one. That cooldown is tracked authoritatively as a plain
	local here, never read back from anywhere client-writable — the
	matching BribeCooldownUntil attribute this script sets on Rep is
	only a replicated mirror for ShopClient's own display (greying the
	button, swapping its price text to "(on cooldown ...)" — see its
	header), not something this script ever trusts back. A successful
	bribe also fires the chat/log lines players see — see
	SellService.bribeAnnounce, required below alongside UpgradeData.

	Owns creating BuyUpgrade, the same create-if-missing pattern
	SellHandler/BallManager use for their own remotes.
]]

local Rep = game:GetService("ReplicatedStorage")

local UpgradeData = require(Rep:WaitForChild("UpgradeData"))
-- shared with SellHandler/BallManager; owns the chat/log lines a
-- successful bribe fires (see SellService.bribeAnnounce, called from
-- buyBribe below)
local SellService = require(script.Parent:WaitForChild("SellService"))

-- id -> upgrade data, built once so a buy request doesn't scan the
-- whole list every time. Skips id-less entries (currently just the
-- divider — see UpgradeData) since byId[nil] = ... is a runtime error
-- in Lua, not a no-op; a divider was never something a client could
-- ask to buy anyway, so it has nothing to look up here.
local byId = {}
for _, upgrade in ipairs(UpgradeData) do
	if upgrade.id then
		byId[upgrade.id] = upgrade
	end
end

-- same create-if-missing pattern BallManager/SellHandler use for their remotes
local buyUpgrade = Rep:FindFirstChild("BuyUpgrade") or Instance.new("RemoteFunction")
buyUpgrade.Name, buyUpgrade.Parent = "BuyUpgrade", Rep

-- shared by both branches below: deducts price and returns true, or
-- returns false without touching cash if the player can't afford it
local function tryCharge(cash, price)
	if cash.Value < price then
		return false
	end
	cash.Value -= price
	return true
end

-- tiered branch: buying always means "purchase whatever the next tier
-- up is". currentTier comes from the id.."Tier" IntValue (0/missing =
-- none owned); reuses/creates that same IntValue rather than one
-- BoolValue per tier, so GrabHandler only ever has one number to read
local function buyTier(upgrade, upgrades, cash)
	local tierName = upgrade.id .. "Tier"
	local tierValue = upgrades:FindFirstChild(tierName)
	-- :IsA guard is defensive — see ShopClient/GrabHandler's identical
	-- check. If this ever comes back the wrong ClassName from a
	-- restore, treat it as tier 0 rather than trusting .Value on it;
	-- the branch below then just recreates it correctly as an IntValue
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
			tierValue:Destroy() -- wrong ClassName from a bad restore — replace it outright
		end
		tierValue = Instance.new("IntValue")
		tierValue.Name, tierValue.Value, tierValue.Parent = tierName, 1, upgrades
	end

	return true
end

-- global, server-wide cooldown for the bribe entry (see its header note
-- above) — gates *when* it's buyable at all, on top of whatever it
-- costs (see UpgradeData's bribePrice). bribeCooldownUntil is an
-- os.time() timestamp; 0 means no cooldown is active. Mirrored onto Rep
-- purely for ShopClient's display — see the header note above for why
-- that mirror is never read back here.
local BRIBE_COOLDOWN_SECONDS = 120
local bribeCooldownUntil = 0
Rep:SetAttribute("BribeCooldownUntil", 0)

-- repeatable/dynamic-price branch (bribe, see UpgradeData): no
-- ownership check and nothing written to the Upgrades folder — price
-- is recomputed fresh every single purchase via the upgrade's own
-- dynamicPrice(), and a successful buy just re-runs BallManagerBribe
-- rather than granting anything persistent. Also gated by the global
-- cooldown above, checked before anything else since it's the cheapest
-- possible rejection. "not ready yet" if BallManager hasn't exposed the
-- global yet (script-order race on server start), same shape as the
-- OnServerInvoke guard below rather than silently charging for an
-- effect that can't fire.
local function buyBribe(upgrade, player, cash)
	if os.time() < bribeCooldownUntil then
		return false, "on cooldown"
	end

	if not _G.BallManagerBribe then
		return false, "not ready yet"
	end

	local price = upgrade.dynamicPrice()
	if not tryCharge(cash, price) then
		return false, "can't afford"
	end

	-- _G.BallManagerBribe returns false (a collapse is already in
	-- progress) rather than actually disabling anything if a collapse
	-- has already tripped by the time this fires — most likely to
	-- happen precisely when a player panic-buys the bribe while the
	-- telegraph is already counting down and loses the race. Trusting
	-- it unconditionally used to charge the player, arm the cooldown,
	-- and announce success even then, so the collapse played out anyway
	-- right on top of a "collapses have been disabled" log line. Refund
	-- and bail out the same way buyTier/buyFlat already do for their
	-- own failure cases, instead of pretending it worked.
	local ok, reason = _G.BallManagerBribe()
	if not ok then
		cash.Value += price
		return false, reason or "couldn't bribe"
	end

	bribeCooldownUntil = os.time() + BRIBE_COOLDOWN_SECONDS
	Rep:SetAttribute("BribeCooldownUntil", bribeCooldownUntil)

	SellService.bribeAnnounce(player)

	return true
end

-- flat-price branch: unchanged behavior, just pulled out into its own
-- function alongside buyTier
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

-- returns (true) on a successful purchase, or (false, reason) so
-- ShopClient can tell the difference between "can't afford it" and
-- "already owned"/"maxed out" instead of both just silently doing
-- nothing
buyUpgrade.OnServerInvoke = function(player, upgradeId)
	local upgrade = typeof(upgradeId) == "string" and byId[upgradeId]
	if not upgrade then
		return false, "invalid upgrade"
	end

	-- generous timeout rather than a bare FindFirstChild: a buy request
	-- fired the instant a player joins could in principle race
	-- LeaderboardSetup's onPlayerAdded, even though in practice the UI
	-- itself won't be clickable that fast
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