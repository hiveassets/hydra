--[[
    BoardClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-20 22:14:29
]]
--[[
	BoardClient (LocalScript) — place in StarterPlayerScripts
	(StarterPlayer.StarterPlayerScripts.BoardClient).

	Starts the board. That's the whole script.

	ClientBoard is a ModuleScript so SellClient, MusicClient and
	CollapseEffectsClient can require it and talk to the board directly,
	the same reason BoardService is a module on the server. Modules don't
	run by themselves, so something has to press the button once — this
	is it, and it's the same shape as the loader on the server side.
]]

local ClientBoard = require(script.Parent:WaitForChild("ClientBoard"))

ClientBoard.start()
