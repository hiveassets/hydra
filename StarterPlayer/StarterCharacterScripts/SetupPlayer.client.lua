--[[
    SetupPlayer (LocalScript)
    Path: StarterPlayer → StarterCharacterScripts
    Parent: StarterCharacterScripts
    Properties:
        Disabled: false
    Exported: 2026-09-23 02:07:56
]]
--[[
    SetupPlayer (LocalScript)
    Path: StarterPlayer → StarterCharacterScripts
    Parent: StarterCharacterScripts
    Properties:
        Disabled: false
    Exported: 2026-09-22 20:42:27
]]
local Character = script.Parent
local Humanoid = Character:WaitForChild("Humanoid")

-- Disable states that could interfere with your custom systems
local STATES_TO_DISABLE = {
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.Physics,
	Enum.HumanoidStateType.Climbing,
}

for _, state in ipairs(STATES_TO_DISABLE) do
	Humanoid:SetStateEnabled(state, false)
end

-- Disable auto jump
Humanoid.AutoJumpEnabled = false