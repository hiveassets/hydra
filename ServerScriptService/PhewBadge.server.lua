--[[
    PhewBadge (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-25 02:23:33
]]
--[[
    PhewBadge (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-23 02:07:54
]]
--[[
    PhewBadge (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 18:28:56
]]
-- BadgeAwarder.server.lua
-- Place in ServerScriptService

local BadgeService = game:GetService("BadgeService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local BADGE_ID = 254171751284681
local START_DISTANCE = 65   -- must be this far from (0,0) horizontally to begin tracking
local FAIL_Y = -5           -- dropping below this kills tracking (player's dead)
local AWARD_DISTANCE = 52   -- getting back within this horizontal distance awards the badge

local tracking = {} -- [player] = true/false

local function checkPlayer(player)
	local character = player.Character
	if not character then return end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local pos = root.Position
	local horizontalDist = math.sqrt(pos.X ^ 2 + pos.Z ^ 2)

	if not tracking[player] then
		if horizontalDist >= START_DISTANCE then
			tracking[player] = true
		end
		return
	end

	if pos.Y < FAIL_Y then
		tracking[player] = false -- dead, stop checking
		return
	end

	if horizontalDist <= AWARD_DISTANCE then
		tracking[player] = false
		if not BadgeService:UserHasBadgeAsync(player.UserId, BADGE_ID) then
			local ok, err = pcall(function()
				BadgeService:AwardBadge(player.UserId, BADGE_ID)
			end)
			if not ok then
				warn("Failed to award badge to " .. player.Name .. ": " .. tostring(err))
			end
		end
	end
end

local function onPlayerAdded(player)
	tracking[player] = false
	player.CharacterAdded:Connect(function()
		tracking[player] = false
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player)
	tracking[player] = nil
end)

RunService.Heartbeat:Connect(function()
	for _, player in ipairs(Players:GetPlayers()) do
		checkPlayer(player)
	end
end)