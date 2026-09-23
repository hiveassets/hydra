--[[
    RemotePlayersClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-23 00:26:24
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

	THREE MECHANISMS, ON PURPOSE

	The first version of this file used one: move their parts into a
	collision group that passes through anything ball-ish. That should
	work — GrabClient already flips collision groups from the client, and
	groups and their rules replicate down from the server — but it didn't
	hold in testing, so this version doesn't bet everything on it.

	  1. LocalTransparencyModifier, first, so the visual lands even if
	     everything below it fails. If other players are faint but still
	     solid, this script is running and the collision half is what's
	     wrong — which is worth knowing at a glance.
	  2. CanCollide = false. The blunt one, and the one with the fewest
	     moving parts: no group has to exist, be registered, or have
	     replicated for it to work.
	  3. The RemotePlayers collision group, when it's actually available.
	     Still worth doing — it's the one that survives anything that
	     re-enables CanCollide, and it says what's meant rather than just
	     what's switched off.

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
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Rep = game:GetService("ReplicatedStorage")

local Config = require(Rep:WaitForChild("BoardConfig"))
local CG = require(Rep:WaitForChild("CollisionGroups"))

local localPlayer = Players.LocalPlayer

local TRANSPARENCY = Config.REMOTE_PLAYER_TRANSPARENCY
local REMOTE_GROUP = "RemotePlayers"
local SETTLE_FRAMES = 60   -- reapply every frame for about a second after a character appears
local RECONCILE_INTERVAL = 1

-- Prints one line per character saying what actually stuck. Turn it off
-- once this is behaving; while it's on, it's the fastest way to tell
-- "the script never ran" apart from "the group didn't take".
local DEBUG = true

-- CG.exists rather than CG.RemotePlayers: reading a name the module
-- doesn't declare is a deliberate error (that's how it catches typos),
-- and an error here would take the transparency down with it. This way
-- a missing group entry degrades to mechanisms 1 and 2 instead.
local groupDeclared = CG.exists(REMOTE_GROUP)

if not groupDeclared then
	warn(
		"[RemotePlayers] ReplicatedStorage.CollisionGroups has no \"" .. REMOTE_GROUP .. "\" entry, so other "
			.. "players are being made non-collidable the blunt way instead. Add the entry to get the tidy version."
	)
end

local descendantConns = {} -- [player] = connection for their current character

local function claim(instance)
	if instance:IsA("Decal") or instance:IsA("Texture") then
		-- A face sits on top of the part and ignores the modifier below,
		-- so it would stay solid on an otherwise ghostly head.
		instance.Transparency = TRANSPARENCY
		return false
	end

	if not instance:IsA("BasePart") then
		return false
	end

	-- 1. cosmetic, and first on purpose (see the header)
	instance.LocalTransparencyModifier = TRANSPARENCY

	-- 2. the guarantee
	instance.CanCollide = false

	-- 3. the tidy version, when it's available
	local grouped = false
	if groupDeclared and CG.isRegistered(REMOTE_GROUP) then
		if instance.CollisionGroup == REMOTE_GROUP then
			grouped = true
		else
			grouped = CG.assign(instance, REMOTE_GROUP)
		end
	end

	return grouped
end

-- Returns how many parts it touched and how many made it into the
-- group, for the debug line.
local function claimCharacter(character)
	if not character then
		return 0, 0
	end

	local parts, grouped = 0, 0
	claim(character)
	for _, desc in ipairs(character:GetDescendants()) do
		if desc:IsA("BasePart") then
			parts += 1
			if claim(desc) then
				grouped += 1
			end
		else
			claim(desc)
		end
	end
	return parts, grouped
end

-- True if anything about this character has drifted back to solid.
-- Cheap: stops at the first part that's wrong.
local function needsReclaim(character)
	for _, desc in ipairs(character:GetDescendants()) do
		if desc:IsA("BasePart") then
			if desc.CanCollide then
				return true
			end
			if groupDeclared and CG.isRegistered(REMOTE_GROUP) and desc.CollisionGroup ~= REMOTE_GROUP then
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

		local parts, grouped = claimCharacter(character)

		if DEBUG then
			print(("[RemotePlayers] %s: %d parts, %d in the group, CanCollide off, transparency %.2f")
				:format(player.Name, parts, grouped, TRANSPARENCY))
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