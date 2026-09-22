--[[
    BoardServiceLoader (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 14:24:25
]]
--[[
	BoardServiceLoader (Script) — place in ServerScriptService
	(ServerScriptService.BoardServiceLoader).

	BoardService is a ModuleScript so ShopHandler, AFKHandler and
	AdminCommands can require it and call into a board directly (this is
	what replaced the old `_G` hooks). ModuleScripts don't run on their
	own, so this one line is what actually starts it on server boot.

	Exactly the same shape, and the same reason, as MusicManagerLoader —
	which this rewrite deletes, since music is a client decision now.

	The watchdog below exists because of how this fails: BoardService
	requires SellService, and if ANY module in that chain yields forever
	(a script left on its pre-rewrite source, a remote that nobody
	creates any more), the whole server side of the board simply never
	starts. No error, no board, no balls — just silence, and an
	"Infinite yield possible" warning somewhere further up the Output
	that's easy to miss among the ones it causes. This says it plainly
	instead.
]]

local loaded = false

task.delay(5, function()
	if not loaded then
		warn(
			"[BoardServiceLoader] BoardService still hasn't finished starting after 5 seconds, "
				.. "so this server has no boards and no balls. Something it requires is yielding forever. "
				.. "Scroll UP in the Output for the first 'Infinite yield possible' line — the script it "
				.. "names is the one to fix. The usual cause is a script that still has its pre-rewrite source."
		)
	end
end)

require(script.Parent:WaitForChild("BoardService"))
loaded = true