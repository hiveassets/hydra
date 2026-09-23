--[[
    ShopClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-23 00:26:24
]]
--[[
    ShopClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-22 18:28:59
]]
--[[
	ShopClient (LocalScript) — StarterPlayerScripts

	Client side of the upgrade shop. Pressing 2 slides shopOuter on/off
	screen. shopInner's contents are still only ever built once (not
	re-yielded-on every toggle) — the "shop" ScreenGui's Enabled now
	toggles alongside that slide instead of staying on throughout: it
	starts false (so nothing can flash on screen while the game loads),
	flips true the instant the shop opens, and back to false only once
	the close tween actually finishes.

	The upgrade list comes from UpgradeData (the same module
	ShopHandler reads server-side), so adding an upgrade there is
	enough for it to show up here too — this script just turns each
	entry into a clone of ReplicatedStorage's shopButton template.

	A `{ divider = true }` entry skips the button entirely and clones
	ReplicatedStorage's shopDivider instead — purely visual, no price/
	click/ownership handling at all. See the top of buildShop's loop.
	Like any other entry, a divider can also carry `requiresBadge`
	(one specific badge) or `requiresAnyBadge` (an array — passes once
	the player owns at least one of them), which are checked before the
	divider/button branch so an ungated divider never renders while the
	badge-gated entries around it are hidden. See passesBadgeGate.

	A price of 0 (the free "sprint" tutorial upgrade — see UpgradeData)
	is shown as "FREE" instead of "$0"; see formatPrice.

	A repeatable/dynamic-price entry (bribe, has `dynamicPrice` instead
	of `price`/`tiers`) never gets marked owned, so its click handler
	stays wired up across purchases instead of being skipped past the
	first one. Its price is recomputed straight off the (already
	replicated) Players list every time it's asked for — see
	upgrade.dynamicPrice itself, in UpgradeData — rather than tracking
	any single attribute the way the old queueClear did. It's also
	gated by a global cooldown ShopHandler owns, mirrored onto
	ReplicatedStorage's BribeCooldownUntil attribute; while on cooldown
	its price text is replaced with "on cooldown ..." instead of a
	dollar amount. Its description lines are static like any other
	upgrade's. An optional `priceColor` on any upgrade entry (bribe
	and pet mimic use magenta) overrides the shop's default cyan price
	text, including on its greyed "(owned)" tag.

	Ownership (for greying out already-bought upgrades) is read off the
	player's Upgrades folder, which LeaderboardSetup populates on join
	before this ever gets a chance to render — see its header.

	Buttons the player can't currently afford grey out the same way an
	owned/maxed button does (price stays its usual cyan) — see
	setButtonGreyed/refreshButtonAffordability. Affordability is
	re-checked on every money change, on every QueueCount change (for
	queueClear specifically), and after every purchase.
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local Rep = game:GetService("ReplicatedStorage")
local RS = game:GetService("RunService")
local TS = game:GetService("TweenService")
local BadgeService = game:GetService("BadgeService")
local ContentProvider = game:GetService("ContentProvider")

local player = Players.LocalPlayer

-- gates any UpgradeData entry carrying a `requiresBadge` or
-- `requiresAnyBadge` field (bribe, pet mimic, and the divider under
-- them — see UpgradeData's own comments on those entries) out of the
-- shop entirely, not just greyed out, until the player actually owns
-- the badge (or, for requiresAnyBadge, at least one of them).
--
-- UserHasBadgeAsync is a yielding web call, and buildShop() used to call
-- it fresh every time the shop opened — that's what made opening the
-- shop feel laggy, since setShopOpen() calls buildShop() (and therefore
-- waited on this web request) before the tween even started.
--
-- Instead: kick off one background check per badge id (see
-- primeBadgeCache below) and cache the result here. playerOwnsBadge()
-- itself never yields — it just reads whatever's in the cache so far,
-- defaulting to "doesn't own it yet" until the real answer comes back.
-- badgeCheckInFlight stops the same badge id from firing off multiple
-- redundant web requests if buildShop() runs again (e.g. a rebuild on
-- reset) before the first check has resolved.
local badgeOwnershipCache = {} -- badgeId -> true/false once known
local badgeCheckInFlight = {} -- badgeId -> true while a check is out

local function primeBadgeCache(badgeId)
	if badgeOwnershipCache[badgeId] ~= nil or badgeCheckInFlight[badgeId] then
		return
	end
	badgeCheckInFlight[badgeId] = true

	task.spawn(function()
		local ok, hasBadge = pcall(function()
			return BadgeService:UserHasBadgeAsync(player.UserId, badgeId)
		end)
		badgeOwnershipCache[badgeId] = ok and hasBadge or false
		badgeCheckInFlight[badgeId] = nil
		-- deliberately NOT rebuilding the shop here even if this turns
		-- out true — see badgeAwardedEvent below for why. This initial
		-- check only covers "already had the badge coming into this
		-- session"; badgeAwardedEvent covers "earns it mid-session".
	end)
end

local function playerOwnsBadge(badgeId)
	if badgeOwnershipCache[badgeId] == nil then
		primeBadgeCache(badgeId)
		return false
	end
	return badgeOwnershipCache[badgeId]
end

-- true if `upgrade` has no badge gate, or the player clears every gate
-- it has: `requiresBadge` needs that one badge; `requiresAnyBadge`
-- needs at least one badge from its list (owning several is fine —
-- it's either/or, not exactly-one). Never yields, same as
-- playerOwnsBadge — everything reads from the cache.
local function passesBadgeGate(upgrade)
	if upgrade.requiresBadge and not playerOwnsBadge(upgrade.requiresBadge) then
		return false
	end

	if upgrade.requiresAnyBadge then
		local ownsAny = false
		for _, badgeId in ipairs(upgrade.requiresAnyBadge) do
			-- no early exit: every id still goes through playerOwnsBadge
			-- so any not-yet-primed one gets its background check kicked
			-- off
			if playerOwnsBadge(badgeId) then
				ownsAny = true
			end
		end
		if not ownsAny then
			return false
		end
	end

	return true
end

-- fired server-side (see MimicFuse's wake-up section) the instant
-- AwardBadge actually confirms a badge for this player — the real
-- moment of truth, no polling/guessing needed. Just updates the cache
-- here; the actual UI response (rebuild now vs. wait for next open)
-- is handled below, once buildShop/shopOpen exist — see that
-- connection for why.
local badgeAwardedEvent = Rep:WaitForChild("BadgeAwarded")
badgeAwardedEvent.OnClientEvent:Connect(function(badgeId)
	badgeOwnershipCache[badgeId] = true
end)
local UpgradeData = require(Rep:WaitForChild("UpgradeData"))

-- start badge checks now, at script load, instead of waiting for the
-- first buildShop() call — by the time the player actually presses "2"
-- for the first time, these have almost always already resolved, so
-- even the very first shop open is instant
for _, upgrade in ipairs(UpgradeData) do
	if upgrade.requiresBadge then
		primeBadgeCache(upgrade.requiresBadge)
	end
	if upgrade.requiresAnyBadge then
		for _, badgeId in ipairs(upgrade.requiresAnyBadge) do
			primeBadgeCache(badgeId)
		end
	end
end
local buyUpgrade = Rep:WaitForChild("BuyUpgrade")
local shopButtonTemplate = Rep:WaitForChild("shopUpgrade")

-- bounded, unlike every other WaitForChild in this file — this template
-- has to actually be placed in ReplicatedStorage by hand in Studio (see
-- UpgradeData's header on the divider entry shape), so a build that
-- forgets it shouldn't hang the entire script waiting forever. Missing
-- after the timeout just means divider entries get skipped in buildShop
-- below instead of the shop never opening at all.
local shopDividerTemplate = Rep:WaitForChild("shopDivider", 5)
if not shopDividerTemplate then
	warn("ShopClient: ReplicatedStorage.shopDivider not found — divider entries will be skipped")
end

-- see ToolbarPanels' own header — lets the shop close itself the moment
-- sell mode or the mimic panel opens, and tells them to do the same
-- when the shop opens, so only one of the three is ever active at once
local ToolbarPanels = require(Rep:WaitForChild("ToolbarPanels"))

-- shared open/close toggle cue now lives centrally in ToolbarPanels (see
-- its header — it was previously a Sound parented to PlayerGui here,
-- which isn't a supported location for background audio and is why this
-- toggle went silent); notifyOpened/notifyClosed below play it, so this
-- file only preloads/keeps its own purchase sound now.
--
-- Purchase sound is the same sell sound SoundClient plays on a sell (see
-- its PRELOAD_IDS), just re-triggered here at a different pitch/volume.
-- Played directly client-side rather than round-tripping through
-- SoundEvents/BallManager — nothing but this client needs to hear it, so
-- there's no reason to involve the server at all.
local PURCHASE_SOUND_ID = "rbxassetid://139583503249540"
local PURCHASE_SOUND_PITCH = 1.3
local PURCHASE_SOUND_VOLUME = 0.5

-- used to be a fresh Instance.new("Sound") -> Play() -> Destroy() on
-- every single purchase, which is exactly why playback was delayed/
-- irregular: a brand new instance has to resolve and stream the asset in
-- from scratch before Play() actually makes noise, and that load time
-- isn't consistent. Preloading the id up front and keeping ONE
-- persistent Sound (reset TimePosition + Play again, instead of
-- recreating the instance) means it's already buffered and plays
-- immediately and consistently every time.
ContentProvider:PreloadAsync({ PURCHASE_SOUND_ID })

local purchaseSound = Instance.new("Sound")
purchaseSound.SoundId = PURCHASE_SOUND_ID
purchaseSound.Volume = PURCHASE_SOUND_VOLUME
purchaseSound.PlaybackSpeed = PURCHASE_SOUND_PITCH
purchaseSound.Parent = player:WaitForChild("PlayerGui")

local function playPurchaseSound()
	purchaseSound.TimePosition = 0
	purchaseSound:Play()
end

local gui = player:WaitForChild("PlayerGui"):WaitForChild("shop")
local shopOuter = gui:WaitForChild("shopOuter")
local shopInner = shopOuter:WaitForChild("shopInner")
local shopTitle = shopOuter:WaitForChild("shopTitle")

-- toolbar button that mirrors the "2" keybind: clicking it opens/closes
-- the shop exactly like the key does, and it lights up yellow while
-- the shop is open so the toolbar reflects state either input drives
local toolbarContainer = player:WaitForChild("PlayerGui"):WaitForChild("toolbar"):WaitForChild("toolbarContainer")
local shopButton = toolbarContainer:WaitForChild("2.shopButton")
local shopButtonText = shopButton:WaitForChild("text")
local shopButtonNumber = shopButton:WaitForChild("number")

local TOOLBAR_HIGHLIGHT_COLOR = Color3.fromRGB(255, 255, 0)
-- captured once at startup rather than hardcoded, so whatever color
-- these labels were authored with in Studio is what they revert to
local shopButtonTextColor = shopButtonText.TextColor3
local shopButtonNumberColor = shopButtonNumber.TextColor3

local function setShopButtonHighlighted(active)
	shopButtonText.TextColor3 = active and TOOLBAR_HIGHLIGHT_COLOR or shopButtonTextColor
	shopButtonNumber.TextColor3 = active and TOOLBAR_HIGHLIGHT_COLOR or shopButtonNumberColor
end

-- AFKHandler owns the "AFK" attribute (see its header). Active = false
-- is what actually blocks the click (Roblox GuiButtons stop firing
-- MouseButton1Click etc. once Active is false); the dimmed text is
-- just the visual tell to go with it, same 0.5 transparency this
-- script already uses for greyed-out upgrade buttons
-- (setButtonGreyed). The "2" keybind isn’t routed through this button
-- at all, so it needs its own guard — see the InputBegan handler below.
local function setShopButtonDisabled(disabled)
	shopButton.Active = not disabled
	shopButtonText.TextTransparency = disabled and 0.5 or 0
	shopButtonNumber.TextTransparency = disabled and 0.5 or 0
end

local upgrades = player:WaitForChild("Upgrades") -- BoolValue per owned upgrade id, see LeaderboardSetup
local money = player:WaitForChild("leaderstats"):WaitForChild("$$$") -- IntValue, see LeaderboardSetup

-- keeps shopTitle showing the player's current money next to the
-- "shop" title, so it's readable without glancing at the leaderboard
local function updateShopTitle()
	shopTitle.Text = string.format("shop  |  $%d", money.Value)
end

updateShopTitle()
money.Changed:Connect(updateShopTitle)

local SLIDE_TIME = 0.25
local CLOSED_SCALE_OFFSET = 0.4 -- how far past OPEN_POS.X.Scale the closed position sits (1.0 -> 1.2)

-- whatever position shopOuter was authored at in Studio is treated as
-- OPEN (x scale 1.0); CLOSED is derived from it rather than hardcoded,
-- so moving shopOuter around in Studio doesn't also require updating a
-- constant here
local OPEN_POS = shopOuter.Position
local CLOSED_POS = UDim2.new(
	OPEN_POS.X.Scale + CLOSED_SCALE_OFFSET, OPEN_POS.X.Offset,
	OPEN_POS.Y.Scale, OPEN_POS.Y.Offset
)
shopOuter.Position = CLOSED_POS -- starts off-screen too, belt-and-suspenders with Enabled below

-- gui.Enabled now does the actual hiding (see setShopOpen below); starting
-- it false means the shop can't flash into view for a frame while the
-- game is still loading, before this script has even set shopOuter's
-- Position above. Kept in addition to the off-screen Position rather than
-- instead of it, since re-enabling still relies on that Position being
-- correct the moment it's flipped back on.
gui.Enabled = false

local OPEN_INFO = TweenInfo.new(SLIDE_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
local CLOSE_INFO = TweenInfo.new(SLIDE_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)

local shopOpen = false
local slideTween

local PRICE_COLOR_NORMAL = "0,255,255"

-- shared "can't buy this" visual: dims the name/lines and tints the
-- background black. Used both for owned/maxed buttons (permanent) and
-- for ones the player can't currently afford (reversible — see
-- refreshButtonAffordability below). `original` is only read on the
-- reversible path, to know what to restore to when ungreying.
local function setButtonGreyed(button, greyed, original, priceText, priceColor)
	button.AutoButtonColor = not greyed
	button.BackgroundColor3 = greyed and Color3.new(0, 0, 0) or original.color
	button.BackgroundTransparency = greyed and 0.5 or original.transparency

	local nameLabel = button:FindFirstChild("upgradeName")
	if nameLabel then
		nameLabel.TextTransparency = greyed and 0.5 or 0
	end

	local priceLabel = button:FindFirstChild("upgradePrice")
	if priceLabel then
		priceLabel.TextTransparency = greyed and 0.5 or 0
		priceLabel.Text = string.format('<b><font color="rgb(%s)">%s</font></b>', priceColor, priceText)
	end

	for _, lineName in ipairs({ "upgradeLine1", "upgradeLine2", "upgradeLine3" }) do
		local lineLabel = button:FindFirstChild(lineName)
		if lineLabel then
			lineLabel.TextTransparency = greyed and 0.5 or 0
		end
	end
end

-- permanent: once owned/maxed, a button stays greyed no matter what
-- money does, so there's no `original` to ever revert to. priceColor is
-- optional (falls back to the default cyan) so an entry with its own
-- color, like pet mimic's magenta, keeps it on the "(owned)" tag too.
local function markOwned(button, tagText, priceColor)
	setButtonGreyed(button, true, nil, tagText or "(owned)", priceColor or PRICE_COLOR_NORMAL)
end

-- "FREE" for a price of 0 (the sprint tutorial upgrade), a normal
-- dollar amount otherwise. Note a 0 price is still a real number, not
-- nil, so it never gets mistaken for refreshButtonAffordability's
-- "unavailable" case — and it's always affordable, so it never greys out.
local function formatPrice(price)
	if price == 0 then
		return "FREE"
	end
	return string.format("$%d", price)
end

-- reversible: re-run on every money change for any not-yet-owned
-- button, so it un-greys the instant the player can afford it again.
-- `entry` is one of the tables buildShop puts in spawnedButtons.
--
-- entry.priceColor lets a specific upgrade override the default cyan
-- price text (see UpgradeData's priceColor field — bribe uses this for
-- magenta). entry.getPrice() returning nil (rather than a number) means
-- "not purchasable right now for a reason other than cost" — currently
-- only bribe's cooldown does this — and greys the button out labelled
-- with entry.unavailableText instead of a dollar amount.
local function refreshButtonAffordability(entry)
	if entry.divider or entry.owned then return end
	local color = entry.priceColor or PRICE_COLOR_NORMAL
	local price = entry.getPrice()
	if not price then
		setButtonGreyed(entry.button, true, entry.original, entry.unavailableText or "unavailable", color)
		return
	end
	local canAfford = money.Value >= price
	setButtonGreyed(entry.button, not canAfford, entry.original, formatPrice(price), color)
end

-- tiered-upgrade button refresh: line3 shows something about the tier
-- currently owned (line1/line2 are static text, set once in buildShop
-- like any other upgrade). Price itself is handled by
-- refreshButtonAffordability instead, since it needs to be recolored on
-- every money change, not just on tier-up. Called at build time and
-- again after each successful tier purchase.
--
-- What that line actually SAYS comes from the UpgradeData entry's own
-- optional `tierLine3(tier, upgrade)` (see its header), not from a
-- branch here — a stash tier is a slot count, a grab tier is a max ball
-- size, and neither of those is the shop's business to know. An entry
-- with no tierLine3 falls back to grab's original wording, so grab is
-- unaffected by this having been generalized. Renamed from
-- updateGrabButtonDisplay for the same reason: it was never actually
-- grab-specific, it was just the only tiered upgrade at the time.
local function updateTierButtonDisplay(button, upgrade, tier)
	local line3Label = button:FindFirstChild("upgradeLine3")
	if not line3Label then return end

	if upgrade.tierLine3 then
		line3Label.Text = upgrade.tierLine3(tier, upgrade)
		return
	end

	line3Label.Text = tier > 0
		and string.format("- current max: %d", upgrade.tiers[tier].maxSize)
		or "- current max: 0"
end

-- entries buildShop has spawned: { button, owned, original, getPrice }
-- per button, so a rebuild (after a reset) can clear exactly those and
-- nothing else shopInner might hold (e.g. a UIListLayout), and so
-- refreshButtonAffordability has what it needs for each button
local spawnedButtons = {}

local function buildShop()
	for _, entry in ipairs(spawnedButtons) do
		-- only the bribe-style (dynamicPrice) entries set this (see
		-- below) — the polling connection lives independently of the
		-- button, so destroying the button alone would leave it
		-- ticking away pointing at a clone nothing still references
		if entry.connection then
			entry.connection:Disconnect()
		end
		entry.button:Destroy()
	end
	table.clear(spawnedButtons)

	for _, upgrade in ipairs(UpgradeData) do
		if not passesBadgeGate(upgrade) then
			continue
		end

		if upgrade.divider then
			if shopDividerTemplate then
				local divider = shopDividerTemplate:Clone()
				divider.Parent = shopInner
				table.insert(spawnedButtons, { button = divider, divider = true })
			end
			continue
		end

		local button = shopButtonTemplate:Clone()
		local original = { color = button.BackgroundColor3, transparency = button.BackgroundTransparency }

		local nameLabel = button:FindFirstChild("upgradeName")
		if nameLabel then
			nameLabel.Text = upgrade.name
		end

		-- line1/line2 are always static description text; line3 is too
		-- for a flat-price upgrade, but a tiered one leaves it blank in
		-- UpgradeData and fills it in below instead (see
		-- updateTierButtonDisplay)
		local line1Label = button:FindFirstChild("upgradeLine1")
		if line1Label then
			line1Label.Text = upgrade.line1
		end

		local line2Label = button:FindFirstChild("upgradeLine2")
		if line2Label then
			line2Label.Text = upgrade.line2
		end

		-- priceColor is read for every entry (not just the dynamicPrice
		-- branch below) so a flat-price upgrade like pet mimic can carry
		-- its own price text color too
		local entry = { button = button, owned = false, original = original, priceColor = upgrade.priceColor }

		if upgrade.tiers then
			-- :IsA("IntValue") guard is defensive: if a save/load round
			-- trip through LeaderboardSetup ever hands this back as the
			-- wrong ClassName, treating it as 0 (rather than trusting
			-- .Value on whatever it actually is) keeps buildShop from
			-- erroring out partway through — which previously meant the
			-- shop-open keybind below never even got wired up
			local function currentTier()
				local tv = upgrades:FindFirstChild(upgrade.id .. "Tier")
				return (tv and tv:IsA("IntValue")) and tv.Value or 0
			end

			-- re-reads the tier fresh every time (rather than closing
			-- over a local counter) so it stays correct even if
			-- something else ever changes it out from under this button
			entry.getPrice = function()
				local nextTierData = upgrade.tiers[currentTier() + 1]
				return nextTierData and nextTierData.price
			end

			local tier = currentTier()
			updateTierButtonDisplay(button, upgrade, tier)

			if tier >= #upgrade.tiers then
				entry.owned = true
				markOwned(button, "(max)")
			else
				button.MouseButton1Click:Connect(function()
					local nowTier = currentTier()
					if nowTier >= #upgrade.tiers then return end
					if money.Value < upgrade.tiers[nowTier + 1].price then return end -- already greyed out

					local ok = buyUpgrade:InvokeServer(upgrade.id)
					if ok then
						playPurchaseSound()
						local newTier = nowTier + 1
						updateTierButtonDisplay(button, upgrade, newTier)
						if newTier >= #upgrade.tiers then
							entry.owned = true
							markOwned(button, "(max)")
						else
							refreshButtonAffordability(entry)
						end
					end
				end)
			end
		elseif upgrade.dynamicPrice then
			local line3Label = button:FindFirstChild("upgradeLine3")
			if line3Label then
				line3Label.Text = upgrade.line3
			end

			entry.priceColor = upgrade.priceColor
			entry.unavailableText = "(on cooldown ...)"

			-- The cooldown is per player now rather than server-wide —
			-- one person buying a bribe has nothing to do with anyone
			-- else's board. ShopHandler tracks it authoritatively and
			-- mirrors it onto this attribute on the PLAYER purely for
			-- this check; it never reads it back.
			local function onCooldown()
				local cooldownUntil = player:GetAttribute("BribeCooldownUntil")
				return cooldownUntil and cooldownUntil > os.time()
			end

			-- nil here (rather than a number) is what tells
			-- refreshButtonAffordability to show entry.unavailableText
			-- instead of a price — see there. Otherwise recomputed fresh
			-- every time it's asked for, same idea as the tiered
			-- branch's getPrice above.
			entry.getPrice = function()
				if onCooldown() then return nil end
				return upgrade.dynamicPrice(player)
			end

			-- never marked owned — repeatable is the whole point, so
			-- unlike buyFlat's handler below this never gets skipped
			-- past after the first successful purchase
			button.MouseButton1Click:Connect(function()
				local price = entry.getPrice()
				if not price or money.Value < price then return end -- already greyed out either way

				local ok = buyUpgrade:InvokeServer(upgrade.id)
				if ok then
					playPurchaseSound()
					refreshButtonAffordability(entry)
				end
			end)

			-- Nothing here changes off a single attribute the way
			-- QueueCount used to drive queueClear's button — this
			-- entry's price depends on the whole server's average cash,
			-- and its cooldown clears on its own after a fixed delay
			-- rather than flipping an attribute back off. A lightweight
			-- once-a-second poll (only while the shop's actually open,
			-- so a closed shop isn't computing this for nothing) keeps
			-- both honest instead of drifting stale until the next
			-- unrelated refresh (a purchase, or the local player's own
			-- money changing). Disconnected alongside the button on
			-- rebuild, same as the QueueCount connection this replaces
			-- — see the entry.connection cleanup at the top of buildShop.
			local lastPoll = 0
			entry.connection = RS.Heartbeat:Connect(function()
				if not shopOpen then return end
				local now = os.clock()
				if now - lastPoll < 1 then return end
				lastPoll = now
				refreshButtonAffordability(entry)
			end)
		else
			local line3Label = button:FindFirstChild("upgradeLine3")
			if line3Label then
				line3Label.Text = upgrade.line3
			end

			entry.getPrice = function() return upgrade.price end

			if upgrades:FindFirstChild(upgrade.id) then
				entry.owned = true
				markOwned(button, nil, upgrade.priceColor)
			else
				-- only wired up for upgrades not already owned at build time —
				-- an upgrade bought this session gets its handler skipped via
				-- the FindFirstChild guard below instead of being disconnected
				button.MouseButton1Click:Connect(function()
					if upgrades:FindFirstChild(upgrade.id) then return end
					if money.Value < upgrade.price then return end -- already greyed out

					local ok = buyUpgrade:InvokeServer(upgrade.id)
					if ok then
						playPurchaseSound()
						entry.owned = true
						markOwned(button, nil, upgrade.priceColor)
					end
				end)
			end
		end

		button.Parent = shopInner
		table.insert(spawnedButtons, entry)
	end

	for _, entry in ipairs(spawnedButtons) do
		refreshButtonAffordability(entry)
	end
end

buildShop()

-- react to a badge landing mid-session, now that buildShop/shopOpen
-- both exist. badgeOwnershipCache is already updated by the
-- connection above by the time this runs (script-load order, not
-- event order, decides that — but Connect callbacks on the same
-- event fire in the order they were made, so it's guaranteed here).
-- If the shop is closed, do nothing: setShopOpen's buildShop() call
-- on the next open already reads the fresh cache, no extra work
-- needed. If the shop is open right now, rebuild immediately so the
-- new entry appears without the player having to close and reopen —
-- earning a badge is rare enough that the one-time rebuild
-- flicker this causes is worth trading for not looking broken.
badgeAwardedEvent.OnClientEvent:Connect(function()
	if shopOpen then
		buildShop()
	end
end)

-- re-grey/un-grey every not-yet-owned button whenever money changes,
-- so affordability always reflects the player's current balance
money.Changed:Connect(function()
	for _, entry in ipairs(spawnedButtons) do
		refreshButtonAffordability(entry)
	end
end)

-- server-driven reset (see LeaderboardSetup's resetPlayerData/_G hooks):
-- Upgrades folder is already cleared by the time this fires, so a
-- straight rebuild is enough to un-grey everything
local resetShopUI = Rep:WaitForChild("ResetShopUI")
resetShopUI.OnClientEvent:Connect(buildShop)

local function setShopOpen(open)
	shopOpen = open

	if open then
		-- re-run so any badge earned since the last open (or since
		-- join) shows up without needing a rejoin. playerOwnsBadge()
		-- reads from badgeOwnershipCache rather than calling
		-- UserHasBadgeAsync directly, so this no longer yields/hitches —
		-- see primeBadgeCache above.
		buildShop()
		gui.Enabled = true -- flip on right away so the slide-in is visible; the matching flip-off on close waits for the tween instead (see below)
		ToolbarPanels.notifyOpened("shop") -- tells sell/mimic to close themselves; also hides the leaderboard and plays the toggle cue
	else
		ToolbarPanels.notifyClosed("shop") -- restores the leaderboard (if shop's still the one holding it hidden) and plays the toggle cue
	end

	setShopButtonHighlighted(open)

	if slideTween then
		slideTween:Cancel()
	end
	slideTween = TS:Create(shopOuter, open and OPEN_INFO or CLOSE_INFO, { Position = open and OPEN_POS or CLOSED_POS })
	slideTween:Play()

	if not open then
		-- don't disable until shopOuter has actually finished sliding off
		-- screen, or the panel would just vanish mid-tween instead of
		-- sliding out. Captures this specific tween so a reopen-before-
		-- close-finishes (which Cancels this tween and starts a fresh one
		-- above) can't have this stale callback turn the gui back off
		-- right after the reopen turned it on; playbackState is only
		-- Completed on a tween that actually ran to the end, never on one
		-- that got Cancel()'d.
		local closingTween = slideTween
		closingTween.Completed:Connect(function(playbackState)
			if playbackState == Enum.PlaybackState.Completed and not shopOpen and slideTween == closingTween then
				gui.Enabled = false
			end
		end)
	end
end

-- the other side of the same handshake: close the shop the instant
-- sell mode or the mimic panel opens, so the three act as one
-- exclusive group instead of stacking
ToolbarPanels.PanelOpened:Connect(function(id)
	if id ~= "shop" and shopOpen then
		setShopOpen(false)
	end
end)

-- AFKHandler owns this attribute (see its header) — closes the shop
-- if it happened to be open, and disables the toolbar button for as
-- long as AFK stays on (see setShopButtonDisabled above)
player:GetAttributeChangedSignal("AFK"):Connect(function()
	local afk = player:GetAttribute("AFK")
	setShopButtonDisabled(afk)
	if afk and shopOpen then
		setShopOpen(false)
	end
end)

UIS.InputBegan:Connect(function(input, processed)
	if processed then return end
	-- Active = false on the button (see setShopButtonDisabled) only
	-- blocks the click; the "2" key bypasses the button entirely, so
	-- it needs the same AFK check spelled out here
	if input.KeyCode == Enum.KeyCode.Two and not player:GetAttribute("AFK") then
		setShopOpen(not shopOpen)
	end
end)

-- same toggle the "2" key drives, just from a click instead of a
-- keypress — setShopOpen already handles the highlight, tween, and
-- leaderboard side effects, so the button doesn't need to know about
-- any of that
shopButton.MouseButton1Click:Connect(function()
	setShopOpen(not shopOpen)
end)