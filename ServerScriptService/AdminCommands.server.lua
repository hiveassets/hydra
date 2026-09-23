--[[
    AdminCommands (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-23 02:07:54
]]
--[[
    AdminCommands (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 18:28:56
]]
--[[
	AdminCommands (Script) — ServerScriptService

	Chat-driven admin commands, gated to a fixed allowlist of user ids
	(ADMIN_USER_IDS below). Two commands:

	!summon <kind> [r] [size] [count]
		Calls straight into BallManager's summon hook (_G.BallManagerSummon,
		see there) for whatever kind was typed — "ball", or any name in
		BallManager's SPECIAL_KINDS list (bomb/magnet/mimic/splitter/merger
		today). That hook is built off SPECIAL_KINDS itself rather than a
		copy of it, so a new special added there is summonable here
		immediately with no change needed in this file — "retroactive" is
		BallManager's job, not this script's.

		An optional literal "r" right after <kind> (e.g.
		"!summon ball r 5 10", to summon 10 radiant balls of size 5) makes
		the summon radiant — this replaces the old, ball-only
		"!summon radiant [size] [count]" syntax entirely; radiant is now a
		modifier on any kind rather than a kind of its own. A plain ball
		is always radiant-eligible; a special kind is only radiant-eligible
		once its own radiant behavior script exists in ReplicatedStorage
		(BallManager's kind.radiantSupported — bomb is the first kind that
		has one). Asking for "r" on a kind that doesn't have one yet fails
		with a clear error instead of silently doing nothing.

		[size] must be a positive whole number if given; omitting it
		summons at DEFAULT_SUMMON_SIZE. [count] must likewise be a
		positive whole number if given; omitting it summons 1. These
		summons go into the front of BallManager's own launch queue now
		(ahead of whatever's already queued) rather than spawning
		immediately/independently of it, so a big [count] still respects
		the normal launch stagger and can still trigger an overflow
		collapse the same way an organic queue buildup would.

	!wipedata [username|userid]
		Wipes a player's saved data via LeaderboardSetup's
		_G.WipePlayerData (see there), which works whether or not that
		player is currently in the server — it just removes the DataStore
		entry, and additionally resets their live stats if they happen to
		be online. With no argument, wipes the command's own runner. This
		is the real (non-Studio-only) replacement for the old
		_G.ResetPlayerData/_G.ResetAllPlayerData Command Bar helpers that
		used to live in LeaderboardSetup — those are gone now that this
		exists.

	!clear
		Destroys every ball currently on the board via BallManager's
		_G.BallManagerClear (see there). BallManager already refills an
		empty board on its own (same bootstrap logic that starts the game
		with a ball in the first place), so this doesn't need to — and
		can't — softlock anything.

	!money [username|userid] <+/-amount>
		Adjusts a player's balance via LeaderboardSetup's
		_G.AdjustPlayerCash (see there), which — like !wipedata's
		_G.WipePlayerData — works whether or not the target is currently
		in the server. The sign is optional (a bare 4000 is treated as
		+4000); a leading - deducts instead. The username is likewise
		optional — with only one argument given, it's taken as the
		amount and applied to the command's own runner, same as
		!wipedata's no-argument case. Amount must otherwise be a whole
		number. A balance is clamped at 0 rather than going negative, so
		a -amount larger than the player's current balance just zeroes
		it out rather than erroring.

	All of these rely on _G hooks set up by BallManager and
	LeaderboardSetup respectively. Those are other Scripts under
	ServerScriptService that run independently of this one, so each call
	site checks the hook actually exists (in case this script's Chatted
	handler somehow fires before that other script's top-level code has
	run) rather than assuming it's always there.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

-- Replaces the old _G.BallManagerSummon / _G.BallManagerClear hooks.
-- A require yields until the module is ready instead of handing back a
-- nil to check for, so the "hasn't loaded yet" branches below are gone.
local BoardService = require(ServerScriptService:WaitForChild("BoardService"))

-- add every admin's UserId here (not username — names can change,
-- ids don't)
local ADMIN_USER_IDS = {
	[272284194] = true, -- hive (lead dev)
}

local function isAdmin(player)
	return ADMIN_USER_IDS[player.UserId] == true
end

-- Simplest possible feedback channel. Swap this out for however the
-- game already surfaces messages to a single player (a StarterGui
-- notification RemoteEvent, etc.) if it has one — kept as a plain
-- print here so this script has zero dependency on anything else to
-- be useful immediately.
local function reply(player, message)
	print(("[AdminCommands] -> %s: %s"):format(player.Name, message))
end

local DEFAULT_SUMMON_SIZE = 5 -- used when !summon is given a kind but no size
local DEFAULT_SUMMON_COUNT = 1 -- used when !summon is given a kind but no count

-- !summon <kind> [r] [size] [count]
local function handleSummon(player, args)
	local kind = args[1]
	if not kind then
		reply(player, "Usage: !summon <kind> [r] [size] [count]")
		return
	end

	-- "r" is a literal, case-insensitive token right after <kind> —
	-- checked before ever trying to read a size out of that slot, so
	-- "!summon ball r 5 10" and "!summon ball 5 10" both parse size/count
	-- out of the right positions regardless of whether "r" is present.
	local nextArg = 2
	local radiant = false
	if args[nextArg] and args[nextArg]:lower() == "r" then
		radiant = true
		nextArg += 1
	end

	local sizeStr, countStr = args[nextArg], args[nextArg + 1]

	local size = DEFAULT_SUMMON_SIZE
	if sizeStr then
		size = tonumber(sizeStr)
		if not size or size ~= math.floor(size) or size <= 0 then
			reply(player, "Size must be a positive whole number.")
			return
		end
	end

	local count = DEFAULT_SUMMON_COUNT
	if countStr then
		count = tonumber(countStr)
		if not count or count ~= math.floor(count) or count <= 0 then
			reply(player, "Count must be a positive whole number.")
			return
		end
	end

	-- Summons land on the admin's OWN board now. Targeting someone
	-- else's is a phase 2 addition (!summon @name bomb).
	local board = BoardService.get(player)
	if not board then
		reply(player, "You don't have a board right now.")
		return
	end

	local ok, err = board:summon(kind, size, count, radiant)
	local label = radiant and ("radiant " .. kind) or kind
	if ok then
		if count == 1 then
			reply(player, ("Summoned %s at size %d."):format(label, size))
		else
			reply(player, ("Summoned %dx %s at size %d."):format(count, label, size))
		end
	else
		reply(player, err or ("Couldn't summon kind: " .. tostring(kind)))
	end
end

-- Resolves a chat argument to a userId: numeric strings are taken as
-- a userId directly, anything else is looked up as a username (works
-- for offline players too — GetUserIdFromNameAsync doesn't require
-- them to be in the server). Returns nil + a reason on failure.
local function resolveUserId(input)
	local asNumber = tonumber(input)
	if asNumber then
		return math.floor(asNumber)
	end

	local ok, result = pcall(Players.GetUserIdFromNameAsync, Players, input)
	if ok then
		return result
	end
	return nil, "couldn't find a user named '" .. input .. "'"
end

-- !wipedata [username|userid]
local function handleWipeData(player, args)
	local target = args[1]
	local userId

	if target then
		local err
		userId, err = resolveUserId(target)
		if not userId then
			reply(player, err or "Couldn't resolve that user.")
			return
		end
	else
		userId = player.UserId -- no argument: wipe the runner's own data
	end

	if not _G.WipePlayerData then
		reply(player, "Wipe isn't available right now (LeaderboardSetup hasn't loaded).")
		return
	end

	_G.WipePlayerData(userId)
	reply(player, "Wiped data for user " .. userId .. ".")
end

-- !money [username|userid] <amount>
local function handleMoney(player, args)
	-- username is optional (self if omitted, like !wipedata's own
	-- argument), so a lone arg is ambiguous between "amount, no
	-- username" and "username, no amount" — resolved by treating a
	-- single arg as the amount, same as the doc comment promises
	local target, amountStr = args[1], args[2]
	if not amountStr then
		target, amountStr = nil, args[1]
	end
	if not amountStr then
		reply(player, "Usage: !money [username|userid] <+/-amount>")
		return
	end

	-- sign is optional — a bare "4000" is assumed +; "-2000" still
	-- deducts
	local sign, digits = amountStr:match("^([+%-]?)(%d+)$")
	if not digits then
		reply(player, "Amount must be a whole number, e.g. 4000 or -2000.")
		return
	end

	local amount = tonumber(digits)
	if sign == "-" then
		amount = -amount
	end

	local userId, err
	if target then
		userId, err = resolveUserId(target)
		if not userId then
			reply(player, err or "Couldn't resolve that user.")
			return
		end
	else
		userId = player.UserId -- no username: apply to the command runner
	end

	if not _G.AdjustPlayerCash then
		reply(player, "Money isn't available right now (LeaderboardSetup hasn't loaded).")
		return
	end

	local ok, resultOrErr = _G.AdjustPlayerCash(userId, amount)
	if ok then
		reply(player, ("%s %d for user %d. New balance: %d."):format(
			amount >= 0 and "Added" or "Removed", math.abs(amount), userId, resultOrErr))
	else
		reply(player, resultOrErr or "Couldn't adjust that balance.")
	end
end

-- !clear
local function handleClear(player, args)
	local board = BoardService.get(player)
	if not board then
		reply(player, "You don't have a board right now.")
		return
	end

	local ok, err = board:clear()
	if ok then
		reply(player, "Cleared the board.")
	else
		reply(player, err or "Couldn't clear the board.")
	end
end

local COMMANDS = {
	summon = handleSummon,
	wipedata = handleWipeData,
	clear = handleClear,
	money = handleMoney,
}

local function onChatted(player, message)
	if not isAdmin(player) then return end
	if message:sub(1, 1) ~= "!" then return end

	local args = {}
	for word in message:gmatch("%S+") do
		table.insert(args, word)
	end

	local commandName = table.remove(args, 1):sub(2):lower()
	local handler = COMMANDS[commandName]
	if handler then
		handler(player, args)
	end
end

local function onPlayerAdded(player)
	player.Chatted:Connect(function(message)
		onChatted(player, message)
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)

-- covers admins already in-game when this script starts (e.g. Studio Run/Play Solo)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end