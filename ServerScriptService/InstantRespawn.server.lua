--[[
    InstantRespawn (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-25 02:23:33
]]
--[[
    InstantRespawn (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-23 02:07:54
]]
--[[
    InstantRespawn (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 20:42:24
]]
game.Players.RespawnTime = 0

game.Players.PlayerAdded:Connect(function(p)
	p.CharacterAdded:Connect(function(c)
		c:WaitForChild("ForceField"):Destroy()
	end)
end)