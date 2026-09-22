--[[
    LeaderboardSetup (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 13:33:36
]]
--[[
	LeaderboardSetup (Script) — ServerScriptService

	Gives every player a leaderstats folder with a single "$$$" stat —
	the currency balance SellHandler pays out into — plus an Upgrades
	folder holding one value per upgrade the player owns: a BoolValue
	for a flat-price upgrade (e.g. dash), or an IntValue for a tiered
	one's current tier (e.g. grab's "grabTier" — see UpgradeData/
	ShopHandler for what "owning" one does, and why tiered upgrades
	store a number instead of just true/false). Also gives every player
	a PetMimicConfig folder (MinSize/MaxSize NumberValues, Name/Color
	StringValues) — always created, regardless of whether they own the
	petMimic upgrade, same as leaderstats/Upgrades themselves; see
	PetMimicHandler/PetConfigClient for what reads and writes it — and a
	Stash folder (three numbered slot folders, each with Kind/Size/Color
	values) on the same "always created regardless of ownership" terms;
	see StashHandler, which is the only thing that ever writes it, and
	StashClient, which is the only thing that ever reads it. All four
	persist through a single DataStore entry per player: loaded on join,
	autosaved periodically as a crash safety net, and saved on leave and
	on server shutdown.

	Adding the stash to that entry needed no version bump: a save written
	before it existed simply has no `stash` key, and applyStash treats a
	nil one exactly like an empty one — the same way sanitizePetConfig
	already handles a save from before PetMimicConfig existed.

	The old store held a bare number (cash). Now that a save is
	{cash, upgrades} instead, an old entry is the wrong shape for
	GetAsync's caller here to make sense of — so this writes to a new
	store name (hydra_playerdata_store) rather than
	hydra_currency_store, which resets everyone's balance once on
	deploy. That's a one-time cost for not having to special-case
	"is this a number or a table" on every load from here on. Future
	resets go back to just bumping DATASTORE_VERSION as before.

	Requires "Enable Studio Access to API Services" (Game Settings >
	Security) to actually read/write while testing in Studio; without it
	every load/save below just fails quietly and falls back to 0
	cash / no upgrades.
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local BadgeService = game:GetService("BadgeService")
local Rep = game:GetService("ReplicatedStorage")

local UpgradeData = require(Rep:WaitForChild("UpgradeData"))

-- the stash's slot layout and kind list (see StashHandler/StashClient
-- for the feature itself). Used below only for the two things this
-- script actually owns: building the Stash folder every player gets, and
-- throwing out a corrupted/hand-edited save entry before it ever reaches
-- a slot value — the same guard sanitizePetConfig applies to the pet
-- config.
local StashData = require(Rep:WaitForChild("StashData"))

-- id .. "Tier" -> max valid tier, for every tiered upgrade in UpgradeData.
-- Used in onPlayerAdded below to clamp a loaded save's tier value back
-- down if a content update ever ships fewer tiers than some players'
-- saves were written against (grab going from 5 tiers down to 4 is what
-- prompted this — see ShopClient's currentTier() for the client-side
-- half of this same guard; this is the half that actually corrects the
-- stored number so it doesn't come back out-of-range on every future load).
local maxTierByFieldName = {}
for _, upgrade in ipairs(UpgradeData) do
	if upgrade.tiers then
		maxTierByFieldName[upgrade.id .. "Tier"] = #upgrade.tiers
	end
end

local DATASTORE_NAME = "hydra_playerdata_store"
local DATASTORE_VERSION = 1 -- bump to reset everyone's data; see note above

local MILLIONAIRE_BADGE_ID = 3176970008807555
local MILLIONAIRE_THRESHOLD = 1000000

-- defaults for a pet mimic's config, both for a player who's never
-- configured one and as the fallback for anything that comes back the
-- wrong shape from a corrupted/edited save. MUST match PetMimicHandler's
-- own copies of these same four values — duplicated here rather than
-- required from there for the same reason LEG_LIFT_FRAC etc. get
-- duplicated between MimicFuse/MimicLegsClient: this is a plain Script,
-- not a ModuleScript, so nothing else can require() out of it anyway.
local DEFAULT_PET_MIN_SIZE = 0
local DEFAULT_PET_MAX_SIZE = 0
local DEFAULT_PET_NAME = "<3"
local DEFAULT_PET_COLOR = "#FF98DC"

local playerDataStore = DataStoreService:GetDataStore(DATASTORE_NAME .. "_v" .. DATASTORE_VERSION)

-- tells ShopClient to rebuild its button list from scratch after a
-- reset, since it only checks the Upgrades folder once at build time —
-- clearing the folder server-side alone wouldn't un-grey anything
local resetShopUI = Rep:FindFirstChild("ResetShopUI") or Instance.new("RemoteEvent")
resetShopUI.Name, resetShopUI.Parent = "ResetShopUI", Rep

local AUTOSAVE_INTERVAL = 120 -- seconds; crash safety net between the join/leave save points below
local SAVE_RETRIES = 3

-- DataStore calls fail occasionally even outside outages, so every call
-- through here gets a few retries rather than silently losing data on
-- the first hiccup
local function attempt(fn)
	for i = 1, SAVE_RETRIES do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		if i < SAVE_RETRIES then
			task.wait(1)
		end
	end
	return false
end

-- Luau's utf8 library iterates by *codepoint*, not by user-perceived
-- "symbol" — a single glyph like a flag (🇺🇸) or a family emoji
-- (👨‍👩‍👧‍👦) is actually several codepoints stitched together via
-- zero-width joiners, variation selectors, skin-tone modifiers, or
-- paired regional-indicator letters. Kept as its own copy rather than a
-- shared module — same reasoning as DEFAULT_PET_* above — but MUST be
-- kept in sync with PetMimicHandler's and PetConfigClient's copies of
-- the same logic.
local ZWJ = 0x200D
local VARIATION_SELECTOR_16 = 0xFE0F
local COMBINING_MARK_MIN, COMBINING_MARK_MAX = 0x0300, 0x036F
local REGIONAL_INDICATOR_MIN, REGIONAL_INDICATOR_MAX = 0x1F1E6, 0x1F1FF
local SKIN_TONE_MIN, SKIN_TONE_MAX = 0x1F3FB, 0x1F3FF

local function isContinuation(cp, prevCp)
	if cp == ZWJ then return true end
	if cp == VARIATION_SELECTOR_16 then return true end
	if cp >= COMBINING_MARK_MIN and cp <= COMBINING_MARK_MAX then return true end
	if cp >= SKIN_TONE_MIN and cp <= SKIN_TONE_MAX then return true end
	if prevCp == ZWJ then return true end
	if prevCp and prevCp >= REGIONAL_INDICATOR_MIN and prevCp <= REGIONAL_INDICATOR_MAX
		and cp >= REGIONAL_INDICATOR_MIN and cp <= REGIONAL_INDICATOR_MAX then
		return true
	end
	return false
end

local function splitIntoSymbols(str)
	if not utf8.len(str) then
		return nil
	end
	local starts, prevCp = {}, nil
	for pos, cp in utf8.codes(str) do
		if not (prevCp and isContinuation(cp, prevCp)) then
			table.insert(starts, pos)
		end
		prevCp = cp
	end
	return starts
end

local function truncateToSymbols(str, maxSymbols)
	local starts = splitIntoSymbols(str)
	if not starts then
		return str:sub(1, maxSymbols)
	end
	if #starts <= maxSymbols then
		return str
	end
	return str:sub(1, starts[maxSymbols + 1] - 1)
end

-- clamps/validates a loaded (or client-submitted, via PetMimicHandler)
-- pet config down to something safe to actually put in a Value instance
-- — guards the same "a corrupted/hand-edited save shouldn't be able to
-- crash or exploit anything reading it back" case the Upgrades
-- typeof()-branch in onPlayerAdded below guards for upgrades. Returns
-- four already-sanitized values, never nil, always falling back to the
-- DEFAULT_PET_* constants above for anything that doesn't check out.
local function sanitizePetConfig(raw)
	raw = raw or {}
	local minSize = tonumber(raw.minSize) or DEFAULT_PET_MIN_SIZE
	local maxSize = tonumber(raw.maxSize) or DEFAULT_PET_MAX_SIZE
	minSize = math.clamp(math.floor(minSize + 0.5), 0, 999)
	maxSize = math.clamp(math.floor(maxSize + 0.5), 0, 999)
	if minSize > maxSize then
		minSize, maxSize = maxSize, minSize
	end

	local name = typeof(raw.name) == "string" and raw.name or DEFAULT_PET_NAME
	name = truncateToSymbols(name, 3)
	if name == "" then
		name = DEFAULT_PET_NAME
	end

	local color = typeof(raw.color) == "string" and raw.color or DEFAULT_PET_COLOR
	if not color:match("^#%x%x%x%x%x%x$") then
		color = DEFAULT_PET_COLOR
	end

	return minSize, maxSize, name, color
end

-- One Folder per stash slot, each holding the three values a stashed
-- ball is fully described by (see StashHandler, which is the only thing
-- that ever writes them, and StashClient, which is the only thing that
-- ever reads them). Always created — all MAX_SLOTS of them, for every
-- player, regardless of what stash tier they own (the tier is what
-- actually gates how many are USABLE; see StashData.MAX_SLOTS' own
-- comment) — same "always exists, defaults if nothing was saved"
-- reasoning as leaderstats/Upgrades/PetMimicConfig themselves.
--
-- An empty slot is Kind == "", never a missing folder: StashClient
-- connects to each slot's Kind.Changed exactly once at startup, so slots
-- appearing and disappearing under it would mean re-wiring connections
-- on every absorb.
--
-- Slots are named "1".."3" rather than "Slot1".."Slot3" so both sides
-- can address one by plain number (tostring(index)) without a naming
-- convention to keep in sync.
local function buildStashFolder()
	local stash = Instance.new("Folder")
	stash.Name = StashData.FOLDER_NAME

	for index = 1, StashData.MAX_SLOTS do
		local slot = Instance.new("Folder")
		slot.Name = tostring(index)

		local kind = Instance.new("StringValue")
		kind.Name, kind.Value = "Kind", ""

		local size = Instance.new("NumberValue")
		size.Name, size.Value = "Size", 0

		local color = Instance.new("Color3Value")
		color.Name, color.Value = "Color", Color3.new(1, 1, 1)

		-- radiant is an attribute on an ordinary ball rather than a kind
		-- of its own, so it can't be carried by Kind and needs its own
		-- value — without it a stashed radiant ball comes back plain,
		-- quietly costing its owner the RADIANT_SELL_MULTIPLIER it was
		-- worth. Only ever true for kind "ball" (see StashHandler).
		local radiant = Instance.new("BoolValue")
		radiant.Name, radiant.Value = "Radiant", false

		kind.Parent, size.Parent, color.Parent, radiant.Parent = slot, slot, slot, slot
		slot.Parent = stash
	end

	return stash
end

-- Applies a loaded save's stash to an already-built folder. Every entry
-- is validated rather than trusted, same reasoning as sanitizePetConfig
-- above: an unknown kind (one removed from StashData between builds, or
-- a hand-edited save) and a non-numeric or non-positive size are both
-- dropped outright, leaving that slot empty, rather than becoming a slot
-- the player can click but never actually deploy.
--
-- Stored as a dict keyed by the slot number as a STRING, not an array —
-- a player holding only slot 3 would be an array with two nil holes,
-- which JSON encoding silently truncates.
local function applyStash(stash, raw)
	if typeof(raw) ~= "table" then return end

	for index = 1, StashData.MAX_SLOTS do
		local entry = raw[tostring(index)]
		local slot = stash:FindFirstChild(tostring(index))
		if slot and typeof(entry) == "table" and StashData.isKind(entry.kind) then
			local size = tonumber(entry.size)
			if size and size > 0 then
				slot.Size.Value = size
				-- pcall'd: fromHex throws outright on a malformed string,
				-- and a bad color shouldn't cost the player the whole ball
				local ok, color = pcall(Color3.fromHex, entry.color)
				slot.Color.Value = (ok and color) or Color3.new(1, 1, 1)
				-- `== true` rather than a truthiness test: a save written
				-- before this field existed has it nil. No kind clamp — every
				-- kind is stashable radiant now, and whether a given one can
				-- actually be respawned that way is BallManager's question
				-- (see _G.BallManagerRadiantSupported, which StashHandler
				-- asks before taking one and QueueStashDeploy falls back on
				-- when an old save asks for a kind whose radiant script has
				-- since been removed)
				slot.Radiant.Value = entry.radiant == true
				slot.Kind.Value = entry.kind -- last, same ordering StashHandler's writeSlot uses, so a client watching Kind never sees a half-written entry
			end
		end
	end
end

-- inverse of applyStash — only occupied slots are written out, so an
-- empty stash saves as an empty table rather than three placeholder
-- entries
local function serializeStash(stash)
	local saved = {}
	if not stash then return saved end

	for index = 1, StashData.MAX_SLOTS do
		local slot = stash:FindFirstChild(tostring(index))
		if slot and slot.Kind.Value ~= "" then
			saved[tostring(index)] = {
				kind = slot.Kind.Value,
				size = slot.Size.Value,
				color = slot.Color.Value:ToHex(),
				radiant = slot.Radiant.Value or nil, -- nil rather than false so an ordinary ball doesn't spend a key on it in every save
			}
		end
	end

	return saved
end

local function save(player, cash, upgrades, petMimicConfig, stash)
	if not (cash and upgrades) then return end

	-- generic by design: stores whatever each child's own .Value is,
	-- not a hardcoded `true` — a flat-price upgrade's BoolValue still
	-- saves as true, but a tiered upgrade's IntValue now saves its
	-- actual tier number instead of collapsing it down to "owned or
	-- not". onPlayerAdded below reads the type back off the saved
	-- value itself to know which kind of Instance to recreate, so a
	-- new tiered upgrade never needs a change here.
	local saved = {}
	for _, upgrade in ipairs(upgrades:GetChildren()) do
		saved[upgrade.Name] = upgrade.Value
	end

	-- petMimicConfig may be nil for a player from before this feature
	-- shipped who somehow hasn't rejoined since (onPlayerAdded always
	-- creates the folder on join, so this is mostly a defensive nil
	-- guard, not an expected case)
	local savedPet = petMimicConfig and {
		minSize = petMimicConfig.MinSize.Value,
		maxSize = petMimicConfig.MaxSize.Value,
		name = petMimicConfig.PetName.Value,
		color = petMimicConfig.Color.Value,
	}

	attempt(function()
		-- UpdateAsync rather than SetAsync: guards against this call
		-- racing a save already in flight for the same key
		playerDataStore:UpdateAsync(player.UserId, function()
			-- stash, like petMimicConfig above, may legitimately be nil for
			-- a player who joined before it existed — serializeStash
			-- returns an empty table for that rather than erroring, so a
			-- missing folder just saves as an empty stash
			return { cash = cash.Value, upgrades = saved, petMimic = savedPet, stash = serializeStash(stash) }
		end)
	end)
end

-- exposed for PetMimicHandler to call right after a player submits a
-- pet config change — same _G-hook pattern this script's own
-- WipePlayerData uses, for the same reason (a plain Script, not a
-- ModuleScript, so nothing else can require() the local save() above
-- directly). Just re-gathers the same five instances save()'s other
-- three call sites (autosave/PlayerRemoving/BindToClose) already do
-- and defers to it — this isn't a new save path, just a fourth trigger
-- for the existing one.
_G.SavePlayerData = function(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	local cash = leaderstats and leaderstats:FindFirstChild("$$$")
	local upgrades = player:FindFirstChild("Upgrades")
	local petMimicConfig = player:FindFirstChild("PetMimicConfig")
	local stash = player:FindFirstChild(StashData.FOLDER_NAME)
	save(player, cash, upgrades, petMimicConfig, stash)
end

-- wipes both copies of a player's data: the datastore entry (so a
-- rejoin loads fresh) and, if they're currently in the server, the
-- live leaderstats/Upgrades instances too (so the current session
-- reflects it immediately without needing a rejoin), firing
-- ResetShopUI after so the client re-greys/re-enables buttons to
-- match. Takes a userId rather than a Player so it works for someone
-- who isn't in the game right now — RemoveAsync doesn't need them to
-- be, and AdminCommands' !wipedata is expected to be used on offline
-- players too.
local function wipeUserData(userId)
	attempt(function()
		playerDataStore:RemoveAsync(userId)
	end)

	local player = Players:GetPlayerByUserId(userId)
	if not player then return end

	local leaderstats = player:FindFirstChild("leaderstats")
	local cash = leaderstats and leaderstats:FindFirstChild("$$$")
	local upgrades = player:FindFirstChild("Upgrades")
	local petMimicConfig = player:FindFirstChild("PetMimicConfig")
	if cash then cash.Value = 0 end
	if upgrades then upgrades:ClearAllChildren() end
	if petMimicConfig then
		petMimicConfig.MinSize.Value = DEFAULT_PET_MIN_SIZE
		petMimicConfig.MaxSize.Value = DEFAULT_PET_MAX_SIZE
		petMimicConfig.PetName.Value = DEFAULT_PET_NAME
		petMimicConfig.Color.Value = DEFAULT_PET_COLOR
	end
	-- emptied rather than destroyed, same as the two above: StashClient
	-- holds a direct reference to each slot's Kind (it connects to
	-- Kind.Changed once at startup), so tearing the folder down would
	-- leave those connections pointing at orphaned instances. Clearing
	-- the values instead fires those same connections and the previews
	-- tear themselves down normally.
	--
	-- Deliberately does NOT drop anything back onto the board — a wipe is
	-- a wipe, the same way it doesn't refund cash for the upgrades it just
	-- cleared.
	local stash = player:FindFirstChild(StashData.FOLDER_NAME)
	if stash then
		for index = 1, StashData.MAX_SLOTS do
			local slot = stash:FindFirstChild(tostring(index))
			if slot then
				slot.Kind.Value = "" -- first, so StashClient tears the preview down before the rest of the entry goes
				slot.Size.Value = 0
				slot.Color.Value = Color3.new(1, 1, 1)
				slot.Radiant.Value = false
			end
		end
	end
	-- doesn't reach into the world to despawn an already-alive pet
	-- mimic — it just won't come back once it next falls/gets defused,
	-- since PetMimicHandler's _G.RespawnPetMimic re-checks ownership
	-- (Upgrades:FindFirstChild("petMimic"), now gone) before spawning a
	-- replacement

	resetShopUI:FireClient(player)
end

-- exposed for AdminCommands' !wipedata (see there). Not Studio-gated
-- like the old _G.ResetPlayerData/_G.ResetAllPlayerData this
-- replaces — wiping a live player's data on request is the real
-- intended use now, not just a Studio testing convenience.
_G.WipePlayerData = wipeUserData

-- adjusts a player's balance by a signed delta, clamped so it never
-- goes below 0. Same "works whether or not they're in the server"
-- shape as wipeUserData above, for the same reason: AdminCommands'
-- !money is expected to be usable on offline players too.
--
-- Online: bumps the live leaderstats value directly. That alone is
-- enough to persist it, since it's the exact same cash Instance every
-- other save path (autosave/leave/BindToClose) already saves off of —
-- this doesn't need its own DataStore write.
--
-- Offline: goes through UpdateAsync (not GetAsync-then-SetAsync) so a
-- concurrent autosave/leave save for that key can't race this and
-- clobber one or the other's write; same reasoning as save()'s own
-- UpdateAsync call above. A player with no prior save (old == nil)
-- adjusts from a base of 0.
--
-- Returns (ok, newBalance) on success, or (false, errorReason) on
-- failure (currently only the offline DataStore path can fail).
local function adjustUserCash(userId, delta)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		local leaderstats = player:FindFirstChild("leaderstats")
		local cash = leaderstats and leaderstats:FindFirstChild("$$$")
		if not cash then
			return false, "that player's balance isn't loaded yet"
		end
		cash.Value = math.max(0, cash.Value + delta)
		return true, cash.Value
	end

	local newBalance
	local ok = attempt(function()
		playerDataStore:UpdateAsync(userId, function(old)
			old = old or {}
			newBalance = math.max(0, (old.cash or 0) + delta)
			old.cash = newBalance
			return old
		end)
	end)
	if not ok then
		return false, "couldn't reach the DataStore, try again"
	end
	return true, newBalance
end

_G.AdjustPlayerCash = adjustUserCash

-- awards the $1,000,000 badge the first time a player's cash reaches
-- MILLIONAIRE_THRESHOLD. AwardBadge itself is safe to call on someone
-- who already owns the badge (it just no-ops), but it's still a network
-- call to Roblox's servers, so awardedThisSession guards against firing
-- it on every subsequent cash change once a player's already past the
-- threshold (e.g. every autosave-interval tick, or every sale once
-- they're sitting above $1M).
local awardedThisSession = {} -- [userId] = true

local function tryAwardMillionaireBadge(player, cashValue)
	if cashValue < MILLIONAIRE_THRESHOLD then return end
	if awardedThisSession[player.UserId] then return end
	awardedThisSession[player.UserId] = true

	attempt(function()
		BadgeService:AwardBadge(player.UserId, MILLIONAIRE_BADGE_ID)
	end)
end

local function onPlayerAdded(player)
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"

	local cash = Instance.new("IntValue")
	cash.Name = "$$$"
	cash.Value = 0

	-- one Instance per saved upgrade entry — a BoolValue for a
	-- flat-price upgrade, an IntValue for a tiered one's tier number.
	-- Which one gets created is read straight off the saved value's
	-- own type (boolean vs number), so this doesn't need a list of
	-- which upgrade ids are tiered — it just mirrors whatever save()
	-- actually wrote out. ShopHandler creates BoolValues/IntValues the
	-- same way when an upgrade's first bought, so a fresh purchase and
	-- a loaded one always end up the same shape.
	local upgrades = Instance.new("Folder")
	upgrades.Name = "Upgrades"

	-- one Value per pet-mimic config field — PetConfigClient reads these
	-- directly (plain replicated Values, no remote needed for reads,
	-- same as it reading Upgrades/leaderstats) and PetMimicHandler both
	-- reads them live (a hunting pet mimic re-checks its size range
	-- every check, not just at spawn) and writes them when the player
	-- submits a change through PetConfigClient's remote. The custom pet
	-- name is stored under "PetName", not "Name" — every Instance
	-- already has a built-in Name PROPERTY (its own instance name),
	-- which always wins over a same-named child when dot-indexed, so
	-- petMimicConfig.Name would silently return the string
	-- "PetMimicConfig" instead of this child, erroring the instant
	-- something tried .Value on it. Always created, even for a player
	-- who's never bought/configured a pet mimic — same "always exists,
	-- defaults if nothing was saved" reasoning as leaderstats/Upgrades
	-- themselves.
	local petMimicConfig = Instance.new("Folder")
	petMimicConfig.Name = "PetMimicConfig"
	local petMinSize, petMaxSize, petName, petColor =
		Instance.new("NumberValue"), Instance.new("NumberValue"), Instance.new("StringValue"), Instance.new("StringValue")
	petMinSize.Name, petMaxSize.Name, petName.Name, petColor.Name = "MinSize", "MaxSize", "PetName", "Color"
	petMinSize.Value, petMaxSize.Value, petName.Value, petColor.Value =
		DEFAULT_PET_MIN_SIZE, DEFAULT_PET_MAX_SIZE, DEFAULT_PET_NAME, DEFAULT_PET_COLOR
	petMinSize.Parent, petMaxSize.Parent, petName.Parent, petColor.Parent =
		petMimicConfig, petMimicConfig, petMimicConfig, petMimicConfig

	-- three empty slot folders, always — see buildStashFolder's own
	-- comment for why every player gets all of them regardless of which
	-- stash tier (if any) they actually own
	local stash = buildStashFolder()

	local ok, loaded = attempt(function()
		return playerDataStore:GetAsync(player.UserId)
	end)
	if ok and loaded then
		cash.Value = loaded.cash or 0
		for id, value in pairs(loaded.upgrades or {}) do
			local instance
			if typeof(value) == "boolean" then
				instance = Instance.new("BoolValue")
			elseif typeof(value) == "number" then
				local maxTier = maxTierByFieldName[id]
				if maxTier and value > maxTier then
					value = maxTier
				end
				instance = Instance.new("IntValue")
			end
			if instance then
				instance.Name, instance.Value, instance.Parent = id, value, upgrades
			end
		end

		-- sanitizePetConfig handles both "never saved before" (loaded.petMimic
		-- is nil, `raw or {}` inside it falls through to every default) and
		-- a saved-but-corrupted/hand-edited entry the same way
		local minSize, maxSize, name, color = sanitizePetConfig(loaded.petMimic)
		petMinSize.Value, petMaxSize.Value, petName.Value, petColor.Value = minSize, maxSize, name, color

		-- same deal for the stash: a nil loaded.stash (never saved before)
		-- and a corrupted one both just leave the already-built folder's
		-- slots empty — see applyStash
		applyStash(stash, loaded.stash)
	end

	cash.Parent = stats
	stats.Parent = player
	upgrades.Parent = player
	petMimicConfig.Parent = player
	stash.Parent = player

	-- catches a player who already crossed $1,000,000 before this
	-- feature existed (or on a prior session) as soon as their saved
	-- balance loads back in, not just the moment they cross it live
	tryAwardMillionaireBadge(player, cash.Value)

	-- SellHandler pays into cash.Value directly rather than through a
	-- remote this script listens on, so watching the Value itself is
	-- the one place that sees every increase regardless of source
	cash:GetPropertyChangedSignal("Value"):Connect(function()
		tryAwardMillionaireBadge(player, cash.Value)
	end)

	-- periodic save for as long as the player's around, so a crash
	-- between now and PlayerRemoving loses at most one interval's worth
	task.spawn(function()
		while player.Parent do
			task.wait(AUTOSAVE_INTERVAL)
			save(player, cash, upgrades, petMimicConfig, stash)
		end
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)

Players.PlayerRemoving:Connect(function(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	local cash = leaderstats and leaderstats:FindFirstChild("$$$")
	local upgrades = player:FindFirstChild("Upgrades")
	local petMimicConfig = player:FindFirstChild("PetMimicConfig")
	local stash = player:FindFirstChild(StashData.FOLDER_NAME)
	save(player, cash, upgrades, petMimicConfig, stash)
	awardedThisSession[player.UserId] = nil
end)

game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		local leaderstats = player:FindFirstChild("leaderstats")
		local cash = leaderstats and leaderstats:FindFirstChild("$$$")
		local upgrades = player:FindFirstChild("Upgrades")
		local petMimicConfig = player:FindFirstChild("PetMimicConfig")
		local stash = player:FindFirstChild(StashData.FOLDER_NAME)
		save(player, cash, upgrades, petMimicConfig, stash)
	end
end)

-- covers players already in-game when this script starts (e.g. Studio Run/Play Solo)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end