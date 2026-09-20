--[[
    MusicManagerLoader (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-20 20:00:08
]]
--[[
	MusicManagerLoader (Script) — ServerScriptService

	MusicManager is a ModuleScript so other scripts can optionally pull
	its tuning API (SetMasterVolume / SetLayerVolume / SetPlaybackSpeed).
	ModuleScripts don't execute on their own, so this one-line loader is
	what actually starts the dynamic music system on server boot —
	require it once here and never again.
]]

require(script.Parent:WaitForChild("MusicManager"))