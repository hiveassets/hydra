--[[
    InstantRespawn (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 14:24:25
]]
game.Players.RespawnTime = 0

game.Players.PlayerAdded:Connect(function(p)
	p.CharacterAdded:Connect(function(c)
		c:WaitForChild("ForceField"):Destroy()
	end)
end)