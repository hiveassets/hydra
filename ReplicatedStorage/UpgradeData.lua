--[[
    UpgradeData (ModuleScript)
    Path: ReplicatedStorage
    Parent: ReplicatedStorage
    Exported: 2026-09-22 14:24:25
]]
--[[
	UpgradeData (ModuleScript) — ReplicatedStorage

	Single source of truth for every purchasable upgrade: id, display
	name, price, and three description lines (line1/line2/line3),
	mapped onto ShopClient's upgradeName/upgradePrice/upgradeLine1/
	upgradeLine2/upgradeLine3 labels. ShopHandler reads this to
	validate purchases and grant them; ShopClient reads it to populate
	the shop UI. Both requiring the same list means adding an upgrade
	here is enough for it to show up in the shop and be purchasable —
	no separate client/server list to keep in sync by hand.

	`id` is what actually gets stored under the player's Upgrades
	folder (see ShopHandler/LeaderboardSetup) and persisted to the
	datastore. Rename `name` freely without touching saved data;
	changing `id` after players own it orphans their purchase.

	Three shapes of entry:

	  - flat-price (e.g. sprint, dash, defuser): has `price`, stored as a
	    BoolValue named `id` once bought — exactly as before. sprint is
	    the free one (`price = 0`, which ShopClient shows as "$free"):
	    it's the shop's tutorial purchase, and Sprint (LocalScript)
	    checks for its BoolValue before letting Shift do anything, the
	    same way DashClient checks for dash's. defuser
	    is otherwise a normal flat-price entry, but its BoolValue is
	    also read by SellHandler/SellClient (not just ShopHandler/
	    ShopClient) — owning it is what allows bombs into sell mode at
	    all, rather than granting an ability the way dash does.

	  - tiered (e.g. grab, stash): has `tiers` instead of `price` — an
	    ordered array of per-tier tables, each carrying at minimum a
	    `price`, plus whatever that upgrade's own consumers need out of
	    a tier (grab's carry `maxSize`; stash's carry nothing else at
	    all, since a stash tier IS just "one more slot"). One shop
	    button covers the whole progression; buying it purchases
	    whatever the next unowned tier is. Stored as a single IntValue
	    named `id.."Tier"` holding the highest tier index owned
	    (absent/0 = none owned yet). See ShopHandler's tiered branch and
	    ShopClient's updateTierButtonDisplay for how that IntValue gets
	    read/written. GrabHandler/GrabClient read `tiers[tier].maxSize`
	    to know the biggest ball a given tier can pick up;
	    StashHandler/StashClient just count the tier itself.

	    A tiered entry can also carry `tierLine3`, a function of
	    (tier, upgrade) returning the text ShopClient should put in
	    line3 for the tier currently owned — that's the one line on a
	    tiered button that isn't static, so it lives here next to the
	    tiers it describes rather than as a branch inside ShopClient.
	    Omitting it falls back to grab's own "- current max: N" wording
	    (see updateTierButtonDisplay), so an existing entry that doesn't
	    define one is unaffected.

	  - repeatable/dynamic-price (bribe): has `dynamicPrice` (a
	    zero-argument function of the whole server's average cash,
	    see bribePrice below) instead of `price`/`tiers`, and
	    `repeatable = true` instead of ever being marked owned.
	    Nothing gets written under the player's Upgrades folder for
	    it — ShopHandler should re-run its effect (_G.BallManagerBribe(),
	    see BallManager) on every purchase rather than checking/setting
	    a Bool/IntValue, and ShopClient should never grey its button out
	    or hide it once bought. Unlike a tiered/flat entry's price,
	    bribePrice takes no external input — it reads Players/leaderstats
	    directly (already fully replicated to every client, the same as
	    the leaderboard itself), so ShopClient and ShopHandler each
	    compute the identical number independently without anything new
	    needing to be threaded through a remote or attribute. bribe is
	    additionally gated by a global, server-wide cooldown that
	    ShopHandler owns entirely (not tracked here — see its header);
	    ShopClient reads that cooldown off ReplicatedStorage's
	    BribeCooldownUntil attribute to grey the button and swap its
	    price text for "(on cooldown ...)" (see ShopClient's dynamicPrice
	    branch). `priceColor` (an "R,G,B" string, same shape as any
	    other rgb() color in this file) lets an entry override the
	    shop's default cyan price text — bribe and petMimic use this for
	    magenta. Any entry shape can carry it, not just dynamic ones.

	Any entry — flat-price, tiered, repeatable, or a divider — can
	also carry `requiresBadge` (currently used by bribe and
	petMimic) — ShopClient's buildShop skips the entry entirely (not
	just greying it out) until the player owns that badge, re-checked
	fresh on every rebuild. petMimic reuses MIMIC_WAKE_BADGE_ID, the
	same badge MimicFuse already awards to everyone in the server the
	instant any board mimic wakes up — "encountering a mimic" is what
	unlocks the option to buy your own. Once bought, PetMimicHandler
	(ServerScriptService) is what actually spawns/respawns/persists it —
	this entry existing here is only what makes it purchasable and
	sets its price; see that script's header for the rest.

	`requiresAnyBadge` is the "either/or" version: an array of badge ids,
	and the entry shows once the player owns at least one of them (one
	or several — all of them isn't required). Same skip-entirely, same
	fresh re-check on every rebuild as `requiresBadge`; an entry can
	carry both, in which case both gates have to pass.

	A `{ divider = true }` entry isn't an upgrade at all — it's a
	marker for ShopClient's buildShop to clone ReplicatedStorage's
	shopDivider (a purely visual instance, no purchase logic) in place
	of a shop button, so the list's ordering doubles as the shop's
	visual layout. The one below sits right after the badge-gated
	section at the top (bribe, petMimic) so that section reads as
	visually separate from the real upgrades under it. Giving a
	divider its own badge gate (it uses `requiresAnyBadge` with both
	of that section's badges) gates the divider itself, not just the
	entries around it — so it only shows once at least one entry above
	it does.
]]

-- badge ids for the entries gated by `requiresBadge`/`requiresAnyBadge`
-- below, named once so the divider's either/or gate can't drift from
-- the entries it's meant to mirror
local BRIBE_BADGE_ID = 3848961087513729
local MIMIC_BADGE_ID = 3684816254175058 -- same badge MimicFuse awards on any board mimic's wake

-- Price for the bribe entry below: 1% of the buyer's OWN balance,
-- rounded to the nearest BRIBE_STEP, floored at BRIBE_MIN_PRICE, with
-- no ceiling — a rich player should never find this cheap. Recomputed
-- fresh on every call, never cached.
--
-- It used to read the average balance across the whole server, which
-- made sense when everyone shared one board and one collapse. With a
-- board each, what it costs you to keep YOUR board from collapsing
-- should depend on what YOU have.
local BRIBE_MIN_PRICE = 1000
local BRIBE_STEP = 1000 -- always rounds to a multiple of this, so it reads as a round number

-- leaderstats is replicated, so the client and the server each work
-- this out independently and land on the same number without anything
-- being sent over.
local function bribePrice(player)
	local leaderstats = player and player:FindFirstChild("leaderstats")
	local cash = leaderstats and leaderstats:FindFirstChild("$$$")
	local balance = cash and cash.Value or 0

	local rounded = math.floor((balance / 100) / BRIBE_STEP + 0.5) * BRIBE_STEP
	return math.max(BRIBE_MIN_PRICE, rounded)
end

local UpgradeData = {
	{
		id = "bribe",
		name = "bribe",
		-- dynamic, not flat/tiered — see bribePrice above and the
		-- header note on this entry's shape. Takes no arguments (unlike
		-- a tiered entry's price lookup) — average server cash is read
		-- straight off the already-replicated Players list inside
		-- bribePrice itself.
		dynamicPrice = bribePrice,
		-- never stored as owned; buyable over and over. ShopHandler
		-- should call _G.BallManagerBribe() on every purchase instead
		-- of checking/writing a Bool/IntValue, and ShopClient should
		-- never grey this button out for being "owned" — a global
		-- cooldown (tracked entirely on ShopHandler's side, see its
		-- header) is what actually gates repeat purchases.
		repeatable = true,
		requiresBadge = BRIBE_BADGE_ID,
		-- magenta price text instead of the shop's usual cyan, matching
		-- the collapse telegraph's own tint — see ShopClient's
		-- priceColor handling
		priceColor = "255,0,255",
		line1 = "- <b><font color='rgb(255,255,0)'>disables</font></b> collapses",
		line2 = "- lasts for 30 sec.",
		line3 = "- priced dynamically",
	},
	{
		id = "petMimic",
		name = "pet mimic",
		price = 100000,
		-- same badge MimicFuse awards on any board mimic's wake — see
		-- this module's own header for why that's the gate rather than
		-- a dedicated badge. ShopClient hides this button entirely
		-- (not just greys it out) until the player owns it.
		requiresBadge = MIMIC_BADGE_ID,
		-- magenta price text like bribe's — the two badge-gated entries
		-- above the divider share the color. Works on a flat-price entry
		-- the same as a dynamic one; see ShopClient's priceColor handling.
		priceColor = "255,0,255",
		line1 = "- press <b><font color='rgb(255,255,0)'>3</font></b> for config",
		line2 = "- eats orbs",
		line3 = "- follows you around",
	},
	{
		-- purely visual — see header. Closes off the badge-gated
		-- section above (bribe, petMimic) from the real upgrades below.
		-- Shows if the player owns either badge, or both — hidden only
		-- when neither of those entries is visible.
		divider = true,
		requiresAnyBadge = { BRIBE_BADGE_ID, MIMIC_BADGE_ID },
	},
	{
		id = "sprint",
		name = "sprint",
		-- free, and deliberately first among the ungated upgrades: it's
		-- the shop's tutorial purchase. Every new player can afford it
		-- immediately, so buying it walks them through opening the shop
		-- and clicking a button before any real money is ever at stake.
		-- price = 0 is what ShopClient turns into "$free".
		price = 0,
		line1 = "- hold <b><font color='rgb(255,255,0)'>SHIFT</font></b> to run",
		line2 = "- good for pushing",
		line3 = "- basically essential",
	},
	{
		id = "dash",
		name = "dash",
		price = 250,
		line1 = "- press <b><font color='rgb(255,255,0)'>F</font></b> to dash",
		line2 = "- launch orbs",
		line3 = "- one sec. cooldown",
	},
	{
		id = "stash",
		name = "stash",
		-- Tiered, but nothing like grab's tiers: a stash tier IS just
		-- "one more slot", so these carry a price and nothing else.
		-- StashHandler/StashClient read the tier NUMBER (via the
		-- stashTier IntValue ShopHandler writes) as the count of
		-- usable slots; neither ever indexes into this array for
		-- anything the way GrabHandler does for maxSize. Deliberately
		-- cheap at tier 1 — one slot is a toy, and it's the later
		-- tiers that are worth paying for.
		tiers = {
			-- absolute price to reach that tier, not an incremental
			-- cost on top of the previous one — see ShopHandler's
			-- tiered branch
			{ price = 500 },
			{ price = 1000 },
			{ price = 4000 },
		},
		-- line3 is the one non-static line on a tiered button (see the
		-- header): ShopClient calls this at build time and again after
		-- every successful purchase. `tier` is how many are currently
		-- owned, 0 included.
		tierLine3 = function(tier, upgrade)
			return string.format("- %d/%d slots owned", tier, #upgrade.tiers)
		end,
		line1 = "- press <b><font color='rgb(255,255,0)'>R</font></b> to stash",
		line2 = "- <b><font color='rgb(255,255,0)'>LMB</font></b> / <b><font color='rgb(255,255,0)'>Q</font></b> to spawn",
		line3 = "", -- filled in dynamically by tierLine3 above (ShopClient)
	},
	{
		id = "grab",
		name = "grab",
		-- absolute price to reach that tier, not an incremental cost on
		-- top of the previous one — see ShopHandler's tiered branch
		tiers = {
			{ maxSize = 15,  price = 2500 },
			{ maxSize = 30, price = 10000 },
			{ maxSize = 40, price = 20000 },
			{ maxSize = 50, price = 40000 },
		},
		line1 = "- <b><font color='rgb(255,255,0)'>LMB</font></b> / <b><font color='rgb(255,255,0)'>E</font></b> to grab",
		line2 = "- release to throw",
		line3 = "", -- filled in dynamically by updateTierButtonDisplay (ShopClient); no tierLine3 here, so it takes that function's own "- current max: N" fallback
	},
	{
		id = "defuser",
		name = "defuser",
		-- flat-price, same shape as dash. Owning this is what
		-- SellHandler/SellClient check before a bomb is allowed into
		-- sell mode at all — see their headers.
		price = 2500,
		line1 = "- sell bombs",
		line2 = "- <b><font color='rgb(255,255,0)'>2x</font></b> money",
		line3 = "- stop explosions",
	},
	{
		id = "demagnetizer",
		name = "degausser",
		-- flat-price, exact same shape as defuser above. Owning this is
		-- what SellHandler/SellClient check before a magnet is allowed
		-- into sell mode at all — see their headers. Same 2x payout, same
		-- red sell flash as a defused bomb (see SellService's
		-- MAGNET_SELL_MULTIPLIER and its reuse of DEFUSER_FLASH_COLOR).
		price = 5000,
		line1 = "- sell magnets",
		line2 = "- <b><font color='rgb(255,255,0)'>2x</font></b> money",
		line3 = "- only before pull",
	},
}

return UpgradeData