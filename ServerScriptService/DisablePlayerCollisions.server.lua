--[[
    DisablePlayerCollisions (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-25 02:23:33
]]
--[[
    DisablePlayerCollisions (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-23 02:07:54
]]
--[[
    DisablePlayerCollisions (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 18:28:56
]]
--[[
	DisablePlayerCollisions (Script) — place in ServerScriptService.

	Moves every player's character into the Players collision group so
	players walk through each other. The group and its rules are declared
	in ReplicatedStorage.CollisionGroups; nothing here registers a group
	or touches PhysicsService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CG = require(ReplicatedStorage:WaitForChild("CollisionGroups"))

-- Only claim parts still in Default, so anything another script has
-- already moved (AFKPlayers, GrabHolder, ...) keeps its group.
local function claim(part)
	if part:IsA("BasePart") and part.CollisionGroup == CG.Default then
		CG.assign(part, CG.Players)
	end
end

local function onCharacter(chr)
	for _, desc in ipairs(chr:GetDescendants()) do
		claim(desc)
	end
	-- accessories, tools and anything else that shows up after spawn
	chr.DescendantAdded:Connect(claim)
end

local function onPlayer(plr)
	plr.CharacterAdded:Connect(onCharacter)
	if plr.Character then
		onCharacter(plr.Character)
	end
end

Players.PlayerAdded:Connect(onPlayer)
for _, plr in ipairs(Players:GetPlayers()) do
	onPlayer(plr)
end