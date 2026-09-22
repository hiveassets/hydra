--[[
    PetMimicHandler (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 13:33:36
]]
--[[
	PetMimicHandler (Script) — ServerScriptService, sibling of
	ShopHandler, BallManager, and LeaderboardSetup

	Owns everything about a pet mimic that isn't "what does it actually
	do while it's alive" (that's PetMimicFuse) or "how does it get
	spawned/respawned/tracked by the ball economy" (that's BallManager):

	  - SetPetMimicEnabled, the RemoteFunction PetConfigClient invokes
	    when the player flips its on/off toggle — this is the ONLY
	    thing that actually spawns or despawns a pet mimic now. Owning
	    "petMimic" just unlocks the toggle (and the rest of the config
	    panel) in PetConfigClient; it no longer spawns anything by
	    itself, either on join (already owned, loaded from the
	    datastore by LeaderboardSetup) or mid-session (just bought,
	    via ShopHandler's generic buyFlat branch — same as
	    dash/defuser). Turning it on spawns from the center exactly
	    the way ownership alone used to; turning it off despawns
	    exactly like the player leaving does (see despawnForPlayer)
	  - resetting every player's PetMimicConfig.Enabled to false the
	    moment they join (see onPlayerAdded/getOrCreateEnabledValue),
	    regardless of what it was left at last session — deliberately
	    NOT one of the four values
	    LeaderboardSetup persists (see its header's DEFAULT_PET_* for
	    why those four specifically are duplicated there), since the
	    point of this toggle is that a mimic never just appears
	    unasked-for at the start of a session; the player has to go
	    turn it on again themselves every time
	  - _G.RespawnPetMimic, called by BallManager's
	    schedulePetMimicRespawn once a dead/defused pet mimic actually
	    clears FALL_BADGE_Y — spawns a fresh one for the same owner,
	    re-checking they still own the upgrade AND still have it
	    enabled first (ownership covers !wipedata clearing their
	    Upgrades folder out from under a still-alive pet — see
	    LeaderboardSetup's wipeUserData; the enabled check covers the
	    player toggling it off while their previous pet was mid-fall,
	    which despawnForPlayer's direct Destroy() doesn't itself go
	    through this path to catch)
	  - _G.PetMimicAbsorb, called by PetMimicFuse's pullIn instead of
	    it task.spawn'ing SellService.petMimicAbsorb on itself — fires
	    a BindableEvent connected here so the actual payout thread is
	    rooted in this persistent script instead of in PetMimicFuse,
	    which despawnForPlayer can Destroy() out from under an absorb
	    that's already mid-flight (see the relay's own comment further
	    down for why a bare exposed function isn't enough to fix that,
	    and why it used to leave the prey ball permanently PendingSell
	    and stuck highlighted)
	  - UpdatePetMimicConfig, the RemoteFunction PetConfigClient invokes
	    whenever the player edits their pet's size range/name/color —
	    validates, writes it to their PetMimicConfig folder (which
	    LeaderboardSetup creates/persists — this script never touches
	    the datastore directly), and, if they have a currently-alive
	    pet mimic, recolors and renames it immediately. PetMimicFuse
	    reads MinSize/MaxSize live off that same folder every hunt
	    check, so those two apply to an already-awake pet with no
	    respawn needed — Color and the numDisplay name are both
	    properties set once at spawn and never polled afterwards, so
	    pushing both onto the live body here is what makes the rest of
	    a config change apply immediately too, instead of just the size
	    range.

	alivePetMimics tracks at most one live instance per owner (keyed by
	UserId, not Player — a respawn can legitimately happen for someone
	who's since left, see _G.RespawnPetMimic's own guard) so a
	double-invoke of SetPetMimicEnabled(true), or a join-time reset
	racing a same-session toggle, can't ever spawn a second one for the
	same player.
]]

local Players = game:GetService("Players")
local Rep = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local UpgradeData = require(Rep:WaitForChild("UpgradeData"))
local SellService = require(ServerScriptService:WaitForChild("SellService"))

-- confirms "petMimic" is actually a real, current upgrade id rather than
-- hardcoding the string a second time — if UpgradeData's entry is ever
-- renamed, this fails loudly (nil index below) instead of silently
-- never spawning anything
local PET_MIMIC_ID = nil
for _, upgrade in ipairs(UpgradeData) do
	if upgrade.id == "petMimic" then
		PET_MIMIC_ID = upgrade.id
		break
	end
end
assert(PET_MIMIC_ID, "PetMimicHandler: UpgradeData has no \"petMimic\" entry")

-- same create-if-missing pattern ShopHandler/BallManager/SellHandler use
-- for their own remotes
local updateConfig = Rep:FindFirstChild("UpdatePetMimicConfig") or Instance.new("RemoteFunction")
updateConfig.Name, updateConfig.Parent = "UpdatePetMimicConfig", Rep

local setEnabled = Rep:FindFirstChild("SetPetMimicEnabled") or Instance.new("RemoteFunction")
setEnabled.Name, setEnabled.Parent = "SetPetMimicEnabled", Rep

-- MUST match LeaderboardSetup's own copies of these same four values —
-- see its header for why they're duplicated instead of shared
local DEFAULT_PET_MIN_SIZE = 0
local DEFAULT_PET_MAX_SIZE = 0
local DEFAULT_PET_NAME = "<3"
local DEFAULT_PET_COLOR = "#FF98DC"

local function hexToColor3(hex)
	local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
	if not r then
		return hexToColor3(DEFAULT_PET_COLOR) -- caller already validated, but stay safe against a bad DEFAULT_PET_COLOR edit too
	end
	return Color3.fromRGB(tonumber(r, 16), tonumber(g, 16), tonumber(b, 16))
end

-- Enabled is deliberately NOT one of the four values LeaderboardSetup
-- loads/persists (see DEFAULT_PET_* above) — it always starts false for
-- everyone on join (see ensureEnabledValue, called from onPlayerAdded),
-- so getOrCreateEnabledValue here just needs *a* BoolValue to exist,
-- never caring what it's currently set to. Split into its own function
-- (rather than folding the reset into onPlayerAdded directly) so
-- setEnabled's handler below can also reach for it on a config folder
-- that, for whatever reason, doesn't have one yet without accidentally
-- stomping the value it's about to write.
local function getOrCreateEnabledValue(petMimicConfig)
	local enabledValue = petMimicConfig:FindFirstChild("Enabled")
	if not enabledValue then
		enabledValue = Instance.new("BoolValue")
		enabledValue.Name = "Enabled"
		enabledValue.Value = false
		enabledValue.Parent = petMimicConfig
	end
	return enabledValue
end

-- at most one live pet mimic per owner, keyed by UserId (not Player —
-- _G.RespawnPetMimic can legitimately fire for someone who's since left)
local alivePetMimics = {}

local function spawnForPlayer(player)
	local petMimicConfig = player:FindFirstChild("PetMimicConfig")
	local colorHex = (petMimicConfig and petMimicConfig.Color.Value) or DEFAULT_PET_COLOR
	local nameText = (petMimicConfig and petMimicConfig.PetName.Value) or DEFAULT_PET_NAME

	if not _G.SpawnPetMimic then
		warn("[PetMimicHandler] BallManager hasn't defined _G.SpawnPetMimic yet — dropping this spawn")
		return
	end

	local mimic = _G.SpawnPetMimic(player.UserId, hexToColor3(colorHex), nameText)
	if not mimic then return end

	alivePetMimics[player.UserId] = mimic
	mimic.AncestryChanged:Connect(function()
		if not mimic:IsDescendantOf(workspace) and alivePetMimics[player.UserId] == mimic then
			alivePetMimics[player.UserId] = nil
		end
	end)
end

-- shared by PlayerRemoving and setEnabled's disable branch — despawns
-- whatever's currently alive for this owner (if anything) the same
-- direct way both cases want: cleared from alivePetMimics BEFORE the
-- Destroy() call so spawnForPlayer's own AncestryChanged listener
-- (firing synchronously off that same Destroy()) sees the entry already
-- gone instead of racing to clear it itself. A plain Destroy() with no
-- MimicActive flip first means this never routes through BallManager's
-- fall-based schedulePetMimicRespawn the way an actual in-hunt death
-- does — same as a player leaving, this is meant to just remove the
-- mimic, not kill-then-queue-a-respawn for it.
local function despawnForPlayer(userId)
	local mimic = alivePetMimics[userId]
	alivePetMimics[userId] = nil
	if mimic and mimic.Parent then
		mimic:Destroy()
	end
end

-- relay for PetMimicFuse's absorb payout — see this script's header.
-- PetMimicFuse's pullIn used to task.spawn(SellService.petMimicAbsorb,
-- ...) directly on itself, which ties that thread's lifetime to
-- PetMimicFuse's own Script instance: Destroy()'ing a script (e.g.
-- despawnForPlayer above, mid-absorb) terminates every thread it
-- spawned along with it, INCLUDING ones already past the point of no
-- return — petMimicAbsorb sets PendingSell and starts its highlight
-- tween synchronously, then yields on task.wait(PRE_SELL_DELAY), and a
-- kill there means the ball:Destroy() at the end of that function
-- never runs. The prey is left with PendingSell stuck true and a fully
-- opaque Highlight frozen on it forever — SellHandler and every other
-- absorb path bail out on PendingSell, so at that point the only way
-- to clear it is an admin command.
--
-- A plain exposed function (an earlier version of this fix, calling
-- straight into a function defined here) does NOT actually fix that:
-- calling a function is not a script boundary — pullIn would still be
-- executing on ITS OWN already-running thread at the point it calls
-- in, so a task.spawn made from inside that call is still spawned "by"
-- PetMimicFuse's thread group as far as Destroy()'s cleanup is
-- concerned, no matter which script the function's code happens to be
-- written in. The only thing that actually reroutes a thread's owning
-- script is a signal dispatch: Roblox runs each Event:Connect'd
-- handler on a fresh thread rooted in whichever script made that
-- :Connect() call, independent of whoever fired it. So this is a
-- BindableEvent, connected here (making every resulting handler
-- thread belong to this persistent script), not a bare function call —
-- PetMimicFuse only ever Fire()s it, never runs the handler itself.
local petAbsorbRelay = Instance.new("BindableEvent")
petAbsorbRelay.Name = "PetMimicAbsorbRelay"
petAbsorbRelay.Parent = script -- server-internal plumbing, not for any client to see or fire

petAbsorbRelay.Event:Connect(function(prey, ownerId)
	SellService.petMimicAbsorb(prey, ownerId)
end)

_G.PetMimicAbsorb = function(prey, ownerId)
	petAbsorbRelay:Fire(prey, ownerId)
end

-- called by BallManager's schedulePetMimicRespawn once a dead/defused
-- pet mimic actually clears FALL_BADGE_Y. Re-checks ownership (rather
-- than trusting "it existed before, so it must still be owned") to
-- cover !wipedata clearing someone's Upgrades folder while their pet
-- mimic happened to still be alive and wandering — see
-- LeaderboardSetup's wipeUserData comment on this.
_G.RespawnPetMimic = function(ownerId)
	alivePetMimics[ownerId] = nil

	local player = Players:GetPlayerByUserId(ownerId)
	if not player then return end -- owner's gone; nothing to respawn for

	local upgrades = player:FindFirstChild("Upgrades")
	if not (upgrades and upgrades:FindFirstChild(PET_MIMIC_ID)) then return end -- no longer owned

	-- also covers the player toggling it off while this previous
	-- instance was mid-fall/mid-defuse — despawnForPlayer's own direct
	-- Destroy() (from setEnabled's disable branch) doesn't go anywhere
	-- near BallManager, so this is the only place a stale respawn tied
	-- to an already-disabled pet gets caught before spawning a fresh one
	-- nobody asked for anymore
	local petMimicConfig = player:FindFirstChild("PetMimicConfig")
	local enabledValue = petMimicConfig and petMimicConfig:FindFirstChild("Enabled")
	if not (enabledValue and enabledValue.Value) then return end

	spawnForPlayer(player)
end

-- Luau's utf8 library iterates by *codepoint*, not by user-perceived
-- "symbol" — a single glyph like a flag (🇺🇸) or a family emoji
-- (👨‍👩‍👧‍👦) is actually several codepoints stitched together via
-- zero-width joiners, variation selectors, skin-tone modifiers, or
-- paired regional-indicator letters. The functions below group
-- codepoints into those visual units so a "3 symbols" cap means 3
-- glyphs, not 3 raw codepoints (which would let a single emoji sequence
-- blow way past what's actually meant to fit in the name).
local ZWJ = 0x200D
local VARIATION_SELECTOR_16 = 0xFE0F
local COMBINING_MARK_MIN, COMBINING_MARK_MAX = 0x0300, 0x036F
local REGIONAL_INDICATOR_MIN, REGIONAL_INDICATOR_MAX = 0x1F1E6, 0x1F1FF
local SKIN_TONE_MIN, SKIN_TONE_MAX = 0x1F3FB, 0x1F3FF

-- true if `cp` should be folded into the symbol `prevCp` belongs to,
-- rather than starting a new one of its own
local function isContinuation(cp, prevCp)
	if cp == ZWJ then return true end -- the joiner itself always attaches to what precedes it
	if cp == VARIATION_SELECTOR_16 then return true end
	if cp >= COMBINING_MARK_MIN and cp <= COMBINING_MARK_MAX then return true end
	if cp >= SKIN_TONE_MIN and cp <= SKIN_TONE_MAX then return true end
	if prevCp == ZWJ then return true end -- being joined onto the running symbol
	if prevCp and prevCp >= REGIONAL_INDICATOR_MIN and prevCp <= REGIONAL_INDICATOR_MAX
		and cp >= REGIONAL_INDICATOR_MIN and cp <= REGIONAL_INDICATOR_MAX then
		return true -- second half of a two-letter flag pair
	end
	return false
end

-- byte offset each new symbol starts at, or nil if str isn't valid UTF-8
-- (utf8.codes errors mid-iteration on malformed input, so this is
-- checked up front rather than pcall'd around the loop)
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

-- truncates str to at most maxSymbols user-perceived symbols. Falls
-- back to a plain byte-sub for non-UTF-8 input, same failure mode the
-- old string:sub(1, n) had for that case.
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

-- validates a client-submitted config edit the same way
-- LeaderboardSetup's sanitizePetConfig validates a loaded save — kept as
-- its own separate copy rather than shared, since one runs against
-- untrusted remote input and the other against the player's own
-- datastore entry, and conflating "trusted enough to load" with "trusted
-- enough to accept live from the client" is exactly the kind of thing
-- that quietly stops being true later if they're ever merged
local function validateConfig(raw)
	if typeof(raw) ~= "table" then return nil end

	local minSize = tonumber(raw.minSize)
	local maxSize = tonumber(raw.maxSize)
	if not (minSize and maxSize) then return nil end
	minSize = math.clamp(math.floor(minSize + 0.5), 0, 999)
	maxSize = math.clamp(math.floor(maxSize + 0.5), 0, 999)
	if minSize > maxSize then
		minSize, maxSize = maxSize, minSize
	end

	local name = typeof(raw.name) == "string" and truncateToSymbols(raw.name, 3) or ""
	if name == "" then
		name = DEFAULT_PET_NAME
	end

	local color = typeof(raw.color) == "string" and raw.color:upper() or ""
	if not color:match("^#%x%x%x%x%x%x$") then
		color = DEFAULT_PET_COLOR
	end

	return { minSize = minSize, maxSize = maxSize, name = name, color = color }
end

-- returns (true) on success or (false, reason) — same convention
-- buyUpgrade uses — so PetConfigClient can tell a rejected/malformed
-- submission apart from a successful one instead of both just silently
-- no-opping
updateConfig.OnServerInvoke = function(player, raw)
	local petMimicConfig = player:WaitForChild("PetMimicConfig", 5)
	if not petMimicConfig then
		return false, "not ready yet"
	end

	local cfg = validateConfig(raw)
	if not cfg then
		return false, "invalid config"
	end

	petMimicConfig.MinSize.Value = cfg.minSize
	petMimicConfig.MaxSize.Value = cfg.maxSize
	petMimicConfig.PetName.Value = cfg.name
	petMimicConfig.Color.Value = cfg.color

	-- PetMimicFuse reads MinSize/MaxSize straight off this same folder
	-- live, every hunt check, so those two apply to an already-awake pet
	-- with no further action needed. Color and the displayed name are
	-- both properties set once at spawn time (BallManager's
	-- spawnPetMimic) and never re-read afterwards, so both need to be
	-- pushed onto the currently-alive instance directly here, the same
	-- way — mimic.Color is what MimicLegsClient's own live color-sync
	-- listens for (see that script's attachLegs), so recoloring the
	-- body here is also what keeps already-grown legs in sync, not just
	-- the body itself.
	local mimic = alivePetMimics[player.UserId]
	if mimic and mimic.Parent then
		mimic.Color = hexToColor3(cfg.color)

		local display = mimic:FindFirstChild("display")
		local numDisplay = display and display:FindFirstChild("numDisplay")
		if numDisplay then
			numDisplay.Text = cfg.name
		end
	end

	return true
end

-- returns (true) on success or (false, reason) — same convention as
-- UpdatePetMimicConfig above. The only place a mimic actually gets
-- spawned or despawned from now on; see this script's header for why
-- owning "petMimic" no longer does either by itself.
setEnabled.OnServerInvoke = function(player, wantEnabled)
	local petMimicConfig = player:WaitForChild("PetMimicConfig", 5)
	if not petMimicConfig then
		return false, "not ready yet"
	end

	local upgrades = player:FindFirstChild("Upgrades")
	if not (upgrades and upgrades:FindFirstChild(PET_MIMIC_ID)) then
		return false, "not owned"
	end

	-- coerce rather than trust the remote payload's type — PetConfigClient
	-- only ever sends a boolean, but this is untrusted client input same
	-- as UpdatePetMimicConfig's raw table above
	wantEnabled = wantEnabled == true

	local enabledValue = getOrCreateEnabledValue(petMimicConfig)
	enabledValue.Value = wantEnabled

	if wantEnabled then
		if not alivePetMimics[player.UserId] then
			spawnForPlayer(player)
		end
	else
		despawnForPlayer(player.UserId)
	end

	return true
end

-- ── join wiring ─────────────────────────────────────────────────────
local function onPlayerAdded(player)
	local petMimicConfig = player:WaitForChild("PetMimicConfig", 10)
	if not petMimicConfig then return end

	-- always starts off — see this script's header for why this one
	-- deliberately isn't among the values LeaderboardSetup persists.
	-- Ownership itself no longer spawns anything (that used to happen
	-- here, gated on the Upgrades folder); the player has to open the
	-- config panel and flip the toggle themselves every session before
	-- SetPetMimicEnabled above ever spawns them a mimic.
	local enabledValue = getOrCreateEnabledValue(petMimicConfig)
	enabledValue.Value = false
end

Players.PlayerAdded:Connect(onPlayerAdded)

-- despawns a live pet mimic the instant its owner leaves, rather than
-- letting it idle around ownerless (PetMimicFuse's getOwnerRoot would've
-- just come back nil with no character to follow) until either the
-- owner rejoins or it eventually falls/gets defused on its own.
-- despawnForPlayer's Destroy() also tears down PetMimicFuse's script
-- along with it (it's cloned directly onto the mimic — see that
-- script's header), so its hunt loop stops right here too, with nothing
-- left to explicitly signal. _G.RespawnPetMimic's own "player not
-- found" guard still covers a respawn that was already scheduled/in
-- flight the moment this fires.
Players.PlayerRemoving:Connect(function(player)
	despawnForPlayer(player.UserId)
end)

-- covers players already in-game when this script starts (e.g. Studio Run/Play Solo)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end