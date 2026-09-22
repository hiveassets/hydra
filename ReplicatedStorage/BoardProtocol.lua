--[[
    BoardProtocol (ModuleScript)
    Path: ReplicatedStorage
    Parent: ReplicatedStorage
    Exported: 2026-09-22 15:18:20
]]
--[[
	BoardProtocol (ModuleScript) — place directly in ReplicatedStorage
	(ReplicatedStorage.BoardProtocol).

	The names of the two remotes the board talks over, and the names of
	every message that crosses them. Both sides require this, so a typo
	is a nil index at the line that has it rather than a message that
	silently never arrives.

	TWO REMOTES, NOT TWENTY

	The old code created a RemoteEvent per feature (SellRequest,
	SellBoxRequest, StashRequest, StashDeploy, DashRequest, ...), each
	with its own create-if-missing dance and its own handler. The board
	uses one remote in each direction with an op name as the first
	argument, because every message has to go through the same
	validation, rate limiting and "is this player's board even awake"
	checks anyway. One door, one guard.

	IDS, NOT INSTANCES

	Every message about a ball carries its numeric id, never the part.
	The parts live on the client now, and a client-created Instance
	doesn't exist on the server — passing one through a remote arrives as
	nil. The id is the only thing both sides can name a ball with.

	WHAT THE CLIENT IS ALLOWED TO DECIDE

	Client to server messages report that something HAPPENED — a ball
	fell, a ball was sold, a splitter touched something. None of them
	carry a size, a price or a payout. The server looks the id up in its
	own ledger and works out the rest. That's the whole security model in
	one sentence, and this file is where it's easiest to check that it
	still holds: if a field ever appears here that decides money, it's a
	bug.
]]

local BoardProtocol = {}

BoardProtocol.FOLDER_NAME = "BoardRemotes"
BoardProtocol.TO_SERVER = "ToServer"
BoardProtocol.TO_CLIENT = "ToClient"

-- ── client to server ──────────────────────────────────────────────────
BoardProtocol.ToServer = {
	-- (id) a settled ball fell off the platform or wandered out of bounds
	FELL = "fell",
	-- (id) the player sold one ball in sell mode
	SELL = "sell",
	-- ({id, id, ...}) the player box-selected and sold several at once
	SELL_BOX = "sellBox",
	-- (id) something the board was tracking is gone for a reason that
	-- pays nobody and replaces nothing: a bomb went off, a magnet
	-- finished its pull, a splitter used itself up. Bookkeeping only.
	EXPIRED = "expired",
	-- () the client finished starting up and wants the board it should
	-- already have (a respawn, a rejoin, a script restart in Studio)
	READY = "ready",
	-- (id) this ball is in the player's hands. The only thing the server
	-- does with it is stop the orb cap auto-selling a ball out of
	-- someone's grip — grabbing needs no permission, since a carried
	-- ball is worth exactly what it was worth on the ground.
	HOLD = "hold",
	-- (id) ...and it isn't any more, thrown or dropped.
	RELEASE = "release",
	-- () the player threw a ball from the middle pad and it cleared the
	-- platform without touching anything. Worth a badge, nothing else.
	TRICK_SHOT = "trickShot",
}

-- ── server to client ──────────────────────────────────────────────────
BoardProtocol.ToClient = {
	-- ({entry, entry, ...}) balls to launch. Each entry is
	-- { id, kind, size, radiant, color, launchAt } where launchAt is a
	-- workspace:GetServerTimeNow() timestamp — the client holds it until
	-- then, so the stagger between launches is identical on every
	-- machine without the server having to send one message per launch.
	SPAWN = "spawn",
	-- (id, reason) the ledger says this ball is gone. reason is one of
	-- "autoSell", "collapse", "adminClear".
	REMOVE = "remove",
	-- (phase, ...) see Collapse below
	COLLAPSE = "collapse",
	-- () wipe everything and start over from an empty board (admin
	-- clear, or a desync the server noticed)
	RESET = "reset",
	-- (id, reason) a message about this ball was refused. The client
	-- puts the ball back the way the server thinks it is. Should be
	-- rare enough to warn about.
	REJECT = "reject",
	-- (paused) the board stops: nothing launches, nothing falls,
	-- nothing spawns, and every ball freezes where it is. AFK is what
	-- fires this today (see AFKHandler), and it's also the shape a
	-- deliberate pause would take, which a single-player game can
	-- afford to have.
	--
	-- Both sides hold the launch queue's clock still for the duration
	-- and shift every pending stamp forward by however long the pause
	-- lasted, so a ball that was two seconds from launching is still
	-- two seconds from launching when you come back.
	PAUSE = "pause",
}

BoardProtocol.Collapse = {
	-- (secondsLeft) fired once a second while the queue is over the line
	TELEGRAPH = "telegraph",
	-- () the queue recovered on its own; stand down
	CANCEL = "cancel",
	-- () it's happening: freeze the board, cut to grey
	CUT = "cut",
	-- () sell every ball for nothing, smallest first
	WIPE = "wipe",
	-- () the fine has landed; fade back to normal
	RESOLVE = "resolve",
}

-- Returns the two remotes, creating them if they aren't there yet.
-- Called with create = true from the server (which owns their lifetime)
-- and without it from the client, which waits instead.
function BoardProtocol.remotes(create)
	local Rep = game:GetService("ReplicatedStorage")

	local folder
	if create then
		folder = Rep:FindFirstChild(BoardProtocol.FOLDER_NAME)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = BoardProtocol.FOLDER_NAME
			folder.Parent = Rep
		end
	else
		folder = Rep:WaitForChild(BoardProtocol.FOLDER_NAME)
	end

	local function remote(name)
		if not create then
			return folder:WaitForChild(name)
		end
		local existing = folder:FindFirstChild(name)
		if existing then
			return existing
		end
		local event = Instance.new("RemoteEvent")
		event.Name = name
		event.Parent = folder
		return event
	end

	return remote(BoardProtocol.TO_SERVER), remote(BoardProtocol.TO_CLIENT)
end

return BoardProtocol