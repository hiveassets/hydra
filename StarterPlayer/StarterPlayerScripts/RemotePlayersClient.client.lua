--[[
    RemotePlayersClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-25 02:23:36
]]
--[[
    RemotePlayersClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-24 20:25:15
]]
--[[
    RemotePlayersClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-23 02:07:56
]]
--[[
    RemotePlayersClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-22 18:28:59
]]
--[[
	RemotePlayersClient (LocalScript) — place in StarterPlayerScripts
	(StarterPlayer.StarterPlayerScripts.RemotePlayersClient).

	Makes everyone else a bystander: they can't touch your orbs, and they
	render faintly so it's obvious they aren't part of your board.

	WHY THIS IS NEEDED

	Your orbs are parts your own machine created, so only your machine
	simulates them. Another player's character, though, is a real
	replicated object standing in the same world — and on YOUR machine it
	is solid. So they walk past, your orbs get shoved, and nothing
	whatsoever happens on their screen. A push that exists for only one
	person is worse than no push at all.

	WHAT IT DOES

	  1. LocalTransparencyModifier, first, so the visual lands even if
	     anything below it fails. If other players are faint but still
	     solid, this script is running and the collision half is what's
	     wrong — which is worth knowing at a glance.
	  2. CanCollide = false on every part of their character. The blunt
	     way, and the one with no moving parts: no collision group has to
	     exist, be registered, or have replicated for it to work. An
	     earlier version also tried a RemotePlayers collision group on top
	     of this; it never held, and this alone works, so it's gone.
	  3. No name or health bar over them. Their Humanoid's
	     DisplayDistanceType goes to None, locally.

	Every one of those is local only. The server and the other player
	never see any of it. Your own character is untouched, because pushing
	orbs around is the game.

	WHY IT KEEPS REAPPLYING

	The server owns these characters. DisablePlayerCollisions sets their
	group on spawn, AFKHandler swaps it on every AFK toggle, and the
	avatar pipeline keeps adding and replacing parts for a while after a
	character appears — accessories, layered clothing, swapped body
	parts. All of that replicates down on top of whatever this client
	decided. So this reapplies on CharacterAdded, on anything added
	afterwards, every frame for the first second (when the avatar is
	still settling), and on a slow sweep forever after. That's the same
	belt-and-braces AFKHandler runs on the server, for the same reason.

	THE HUMANOID TURNS COLLISION BACK ON

	None of the above is fast enough on its own, because the thing most
	likely to switch a part back to solid isn't the server at all: it's
	their Humanoid, on your machine. A Humanoid keeps its own body's
	collision the way it wants it, and re-asserts that when its state
	changes — and a dash changes state (running to freefall and back, with
	gravity cancelled for a tenth of a second). For that moment their
	torso and head were solid again on your screen, and a player dashing
	through your pile shoved it. The slow sweep put it right a second
	later, which is exactly the "only when they dash" pattern.

	So their parts are also forced back to non-collidable on every
	Stepped — the instant before each physics step — which is the last
	word before anything can collide. It's a handful of parts per player,
	a trivial cost.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Rep = game:GetService("ReplicatedStorage")

local Config = require(Rep:WaitForChild("BoardConfig"))

local localPlayer = Players.LocalPlayer

local TRANSPARENCY = Config.REMOTE_PLAYER_TRANSPARENCY
local SETTLE_FRAMES = 60   -- reapply every frame for about a second after a character appears
local RECONCILE_INTERVAL = 1

-- Prints one line per character saying what actually stuck. Turn it off
-- off now that it's behaving.
local DEBUG = false

local descendantConns = {} -- [player] = connection for their current character

local function claim(instance)
	if instance:IsA("Decal") or instance:IsA("Texture") then
		-- A face sits on top of the part and ignores the modifier below,
		-- so it would stay solid on an otherwise ghostly head.
		instance.Transparency = TRANSPARENCY
		return
	end

	-- 3. no name or health bar
	if instance:IsA("Humanoid") then
		instance.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		return
	end

	if not instance:IsA("BasePart") then
		return
	end

	-- 1. cosmetic, and first on purpose (see the header)
	instance.LocalTransparencyModifier = TRANSPARENCY

	-- 2. the guarantee
	instance.CanCollide = false
end

-- Returns how many parts it touched, for the debug line.
local function claimCharacter(character)
	if not character then
		return 0
	end

	local parts = 0
	claim(character)
	for _, desc in ipairs(character:GetDescendants()) do
		if desc:IsA("BasePart") then
			parts += 1
		end
		claim(desc)
	end
	return parts
end

-- True if anything about this character has drifted back: a solid part,
-- or a name tag the server's spawn turned back on. Cheap: stops at the
-- first thing that's wrong.
local function needsReclaim(character)
	for _, desc in ipairs(character:GetDescendants()) do
		if desc:IsA("BasePart") then
			if desc.CanCollide then
				return true
			end
		elseif desc:IsA("Humanoid") then
			if desc.DisplayDistanceType ~= Enum.HumanoidDisplayDistanceType.None then
				return true
			end
		end
	end
	return false
end

local function watch(player)
	if player == localPlayer then
		return
	end

	local function onCharacter(character)
		local previous = descendantConns[player]
		if previous then
			previous:Disconnect()
		end

		-- Connected BEFORE the sweep below, not after: a part parented
		-- in between the two would be missed by both, and right after a
		-- character appears is exactly when parts are streaming in.
		descendantConns[player] = character.DescendantAdded:Connect(claim)

		local parts = claimCharacter(character)

		if DEBUG then
			print(("[RemotePlayers] %s: %d parts, CanCollide off, name hidden, transparency %.2f")
				:format(player.Name, parts, TRANSPARENCY))
		end

		-- The avatar keeps replacing parts for a moment after this, and a
		-- replacement arrives solid. Rather than guess how long that
		-- takes, just keep putting it right for a second.
		task.spawn(function()
			for _ = 1, SETTLE_FRAMES do
				if player.Character ~= character then
					return
				end
				if needsReclaim(character) then
					claimCharacter(character)
				end
				RunService.Heartbeat:Wait()
			end
		end)
	end

	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		onCharacter(player.Character)
	end
end

Players.PlayerAdded:Connect(watch)
for _, player in ipairs(Players:GetPlayers()) do
	watch(player)
end

Players.PlayerRemoving:Connect(function(player)
	local conn = descendantConns[player]
	if conn then
		conn:Disconnect()
		descendantConns[player] = nil
	end
end)

-- Every physics step, before it runs: whatever their Humanoid (or
-- anything else) switched back on since the last one goes off again
-- before it can touch an orb. See "THE HUMANOID TURNS COLLISION BACK ON"
-- in the header.
local remoteParts = {} -- [player] = { BasePart, ... } for their current character

local function collectParts(player, character)
	local parts = {}
	for _, desc in ipairs(character:GetDescendants()) do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end
	remoteParts[player] = parts
end

RunService.Stepped:Connect(function()
	for player, parts in pairs(remoteParts) do
		local character = player.Character
		if not character or player.Parent == nil then
			remoteParts[player] = nil
		else
			local stale = false
			for _, part in ipairs(parts) do
				if part.Parent == nil or not part:IsDescendantOf(character) then
					stale = true
				elseif part.CanCollide then
					part.CanCollide = false
				end
			end
			if stale then
				collectParts(player, character)
			end
		end
	end
end)

-- Kept current as parts come and go: a new character, and anything the
-- avatar pipeline adds after it.
local function trackCharacter(player, character)
	collectParts(player, character)
	character.DescendantAdded:Connect(function(desc)
		if desc:IsA("BasePart") and player.Character == character then
			local parts = remoteParts[player]
			if parts then
				table.insert(parts, desc)
			end
		end
	end)
end

for _, player in ipairs(Players:GetPlayers()) do
	if player ~= localPlayer then
		player.CharacterAdded:Connect(function(character)
			trackCharacter(player, character)
		end)
		if player.Character then
			trackCharacter(player, player.Character)
		end
	end
end
Players.PlayerAdded:Connect(function(player)
	if player == localPlayer then
		return -- never your own character
	end
	player.CharacterAdded:Connect(function(character)
		trackCharacter(player, character)
	end)
end)
Players.PlayerRemoving:Connect(function(player)
	remoteParts[player] = nil
end)

-- The backstop, forever. The server reassigns these characters on
-- respawn and on every AFK toggle, and those writes land here on their
-- own schedule — so rather than chase each cause, notice anything
-- that's drifted back and put it right.
task.spawn(function()
	while true do
		task.wait(RECONCILE_INTERVAL)
		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= localPlayer then
				local character = player.Character
				if character and needsReclaim(character) then
					claimCharacter(character)
					if DEBUG then
						print(("[RemotePlayers] %s drifted back to solid — reapplied"):format(player.Name))
					end
				end
			end
		end
	end
end)