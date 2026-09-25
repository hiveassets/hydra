--[[
    BoardClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-25 02:23:34
]]
--[[
    BoardClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-24 20:25:14
]]
--[[
    BoardClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-23 02:07:55
]]
--[[
    BoardClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-22 18:28:58
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

	The watchdog is the client half of the one in BoardServiceLoader: if
	the server never finished starting, ClientBoard sits waiting for
	remotes that will never appear, and every other client script sits
	waiting for the board. Saying so beats a screen with nothing on it.
]]

local ClientBoard = require(script.Parent:WaitForChild("ClientBoard"))

-- Roblox's own backpack bar sits along the bottom of the screen, right
-- where the toolbar is, and ` opens it on top of everything. Nothing in
-- this game is a Tool, so there's never anything in it — turn it off.
-- Done here because this script runs once per session, first thing.
pcall(function()
	game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end)

local started = false

task.delay(5, function()
	if not started then
		warn(
			"[BoardClient] the board hasn't started after 5 seconds — ReplicatedStorage.BoardRemotes "
				.. "never appeared, which means BoardService never finished starting on the SERVER. "
				.. "Check the server side of the Output, not this one."
		)
	end
end)

ClientBoard.start()
started = true