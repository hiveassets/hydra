--[[
    ClientBoard (ModuleScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Exported: 2026-09-23 02:07:55
]]
--[[
    ClientBoard (ModuleScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Exported: 2026-09-23 00:26:23
]]
--[[
    ClientBoard (ModuleScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Exported: 2026-09-22 18:28:58
]]
--[[
	ClientBoard (ModuleScript) — place in StarterPlayerScripts
	(StarterPlayer.StarterPlayerScripts.ClientBoard). Started by
	BoardClient, and required directly by SellClient, MusicClient,
	CollapseEffectsClient and anything else that needs to know what's on
	the board.

	Your board, on your machine. Every ball here is a part this script
	created locally, so it exists for you and nobody else: no
	replication, no network ownership, no other client's physics
	authority to wait on. Pushing a ball is your own machine's physics
	step, which is the entire point of the rewrite.

	WHAT THIS DOES AND DOESN'T DECIDE

	It decides where balls ARE. It never decides what they're WORTH.
	Every ball here arrived because the server said to spawn it, with a
	size the server chose, and it leaves either because the server said
	so or because this script told the server what happened to it and the
	server agreed. See Board (ServerScriptService) for the other half.

	The one deliberate exception is a sale: the ball disappears the
	instant you click, before the server has answered. That's a player's
	own action on their own board, the server settles the money a moment
	later, and a refusal is only possible for a client that's lying — in
	which case it was going to be refused anyway.

	THE LAUNCH QUEUE IS A CLOCK

	Spawn messages carry the server time each ball should launch, one
	GAP after the last. This script holds them until then. That's why the
	stagger looks the same on every machine without a message per ball,
	and why a laggy moment can't bunch five launches into one frame.

	WHY THE FOLDER IS STILL CALLED "Balls"

	SellClient, HudUI, StashClient and MimicLegsClient all look up
	workspace.Balls and read attributes off it. Creating the local
	folder under the same name, with the same attributes (QueueCount and
	friends), means those scripts keep working with small edits instead
	of rewrites. The folder is local now, which is exactly why nothing
	about it replicates.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Rep = game:GetService("ReplicatedStorage")
local Config = require(Rep:WaitForChild("BoardConfig"))
local Rules = require(Rep:WaitForChild("BoardRules"))
local Protocol = require(Rep:WaitForChild("BoardProtocol"))
local CG = require(Rep:WaitForChild("CollisionGroups"))

local BoardEffects = require(script.Parent:WaitForChild("BoardEffects"))

local ToServer = Protocol.ToServer
local ToClient = Protocol.ToClient
local CollapsePhase = Protocol.Collapse

local ClientBoard = {}

-- ── state ─────────────────────────────────────────────────────────────

local entries = {}                                     -- [id] = entry
local byPart = setmetatable({}, { __mode = "k" })      -- [part] = entry
local waiting = {}                                     -- entries whose launch time hasn't come yet
local emergeSites = {}                                 -- [consumed orb's id] = where its results come out; see emergeAt
local folder
local collapsing = false
local paused = false
local pausedAt = nil
local started = false

local toServer, toClient
local ballTemplate
local spawnSymbol
local baseSize = Config.BASE_SIZE

local random = Random.new()
local function rand()
	return random:NextNumber()
end

-- Fired for anything else that cares about a collapse — the colour
-- grading in CollapseEffectsClient, the music duck in MusicClient. A
-- BindableEvent rather than a RemoteEvent: nothing about a collapse
-- crosses the network any more, it's this player's board.
ClientBoard.collapse = Instance.new("BindableEvent")

-- ── display ───────────────────────────────────────────────────────────
-- The billboard over a ball has to track the part's live Size, because
-- almost nothing on the board is a fixed size for its whole life: balls
-- grow in, splitters shrink, magnets pulse. One loop that repaints
-- whatever actually changed beats a per-part property listener, which
-- is what the old code ended up with after its per-part connections
-- kept dying with the scripts that made them.

local DISPLAY_ANCHOR_SIZE, DISPLAY_ANCHOR_X, DISPLAY_ANCHOR_Y = 5, 5, 1.5
local DISPLAY_Y_PER_X = DISPLAY_ANCHOR_Y / DISPLAY_ANCHOR_X
local DISPLAY_GROWTH_RATE = 0.5 -- the label grows half as fast as the ball does

local displayScaleAt = setmetatable({}, { __mode = "k" })

local function setDisplayScale(part, size)
	local display = part:FindFirstChild("display")
	if display then
		local xScale = DISPLAY_ANCHOR_X + (size - DISPLAY_ANCHOR_SIZE) * DISPLAY_GROWTH_RATE
		display.Size = UDim2.new(xScale, 0, xScale * DISPLAY_Y_PER_X, 0)
	end
	displayScaleAt[part] = size
end

local function setDisplayText(part, size)
	local display = part:FindFirstChild("display")
	local label = display and display:FindFirstChild("numDisplay")
	if label then
		label.Text = tostring(math.round(size))
	end
	setDisplayScale(part, part.Size.X)
end

-- ── radiant ───────────────────────────────────────────────────────────
-- The radiant colour cycle stays here rather than becoming a behaviour
-- module. It isn't a kind — it's an overlay that can ride on any of
-- them — and it's needed from phase 1, before the runner below exists.

local RADIANT_COLORS = {
	Color3.fromRGB(255, 0, 0),
	Color3.fromRGB(255, 255, 0),
	Color3.fromRGB(0, 255, 0),
	Color3.fromRGB(0, 255, 255),
	Color3.fromRGB(0, 0, 255),
	Color3.fromRGB(255, 0, 255),
}
local RADIANT_CYCLE_TIME = 3
local RADIANT_SEGMENT = RADIANT_CYCLE_TIME / #RADIANT_COLORS
local radiantTweenInfo = TweenInfo.new(RADIANT_SEGMENT, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut)

local function startRadiantLoop(entry)
	entry.part.Color = RADIANT_COLORS[1]
	task.spawn(function()
		local index = 1
		while entry.behavioursAlive and entry.part.Parent do
			index = (index % #RADIANT_COLORS) + 1
			TweenService:Create(entry.part, radiantTweenInfo, { Color = RADIANT_COLORS[index] }):Play()
			task.wait(RADIANT_SEGMENT)
		end
	end)
end

-- ── bookkeeping ───────────────────────────────────────────────────────

local function send(...)
	if toServer then
		toServer:FireServer(...)
	end
end

local function syncQueueCount()
	folder:SetAttribute("QueueCount", #waiting)
end

-- ── stopping a behaviour ──────────────────────────────────────────────
-- Behaviours are polled rather than notified: a module checks ctx.alive()
-- around its own yields and returns once it goes false. That's enough for
-- the module's own loops, and not enough for anything it started that
-- runs on its own — a TweenService tween, a part it parented somewhere.
-- Those keep going after the module has stopped caring.
--
-- ctx.onStop registers them and this runs them. Every route an orb can
-- leave by ends up here, so a module's cleanup happens whether it was
-- sold, stashed, auto-sold, collapsed, fell out of the world, or was
-- removed by the server.
local function stopBehaviours(entry)
	entry.behavioursAlive = false

	local cleanups = entry.behaviourCleanups
	if not cleanups then
		return
	end
	entry.behaviourCleanups = nil

	for _, cleanup in ipairs(cleanups) do
		-- One bad cleanup shouldn't stop the others, and certainly
		-- shouldn't take down whatever was removing the orb.
		local ok, err = pcall(cleanup)
		if not ok then
			warn(("[ClientBoard] a %s cleanup errored: %s"):format(tostring(entry.kind), tostring(err)))
		end
	end
end

local function forget(entry)
	stopBehaviours(entry)
	entries[entry.id] = nil
	if entry.part then
		byPart[entry.part] = nil
		if entry.part.Parent then
			entry.part:Destroy()
		end
	end
end

-- ── resync ────────────────────────────────────────────────────────────
-- READY makes the server RESET this board and re-send its whole ledger,
-- which is what this client asks for on startup. It's also the repair
-- for any disagreement: rather than reasoning about which side is
-- wrong, throw away what's here and rebuild from the authority.
--
-- It isn't free — every ball is re-created at its launch position, so a
-- resync mid-play is a visible hiccup — but it is total, and a hiccup
-- beats a board that has quietly stopped working.

local lastResyncAt = -math.huge

-- A request inside the cooldown is DEFERRED to the end of it, not
-- dropped. It used to be dropped, which meant a second divergence within
-- three seconds of the first — two refused splits in a busy moment, say —
-- was simply never repaired: the orb stayed counted on the server and
-- missing here for good. One deferred request stands in for any number
-- asked for during the same cooldown; the resync it triggers repairs all
-- of them at once.
local resyncDeferred = false

local function requestResync(why)
	local t = os.clock()
	local wait = lastResyncAt + Config.RESYNC_COOLDOWN - t
	if wait > 0 then
		if not resyncDeferred then
			resyncDeferred = true
			task.delay(wait, function()
				resyncDeferred = false
				lastResyncAt = os.clock()
				warn(("[ClientBoard] asking the server to resend the board (held back by the cooldown): %s"):format(why))
				send(ToServer.READY)
			end)
		end
		return false
	end
	lastResyncAt = t
	warn(("[ClientBoard] asking the server to resend the board: %s"):format(why))
	send(ToServer.READY)
	return true
end

local function serverNow()
	return Workspace:GetServerTimeNow()
end

function ClientBoard.idOf(part)
	local entry = byPart[part]
	return entry and entry.id
end

function ClientBoard.entryOf(part)
	return byPart[part]
end

function ClientBoard.get(id)
	return entries[id]
end

function ClientBoard.ballCount()
	local count = 0
	for _, entry in pairs(entries) do
		if entry.kind == "ball" and entry.part and entry.part.Parent then
			count += 1
		end
	end
	return count
end

function ClientBoard.queueCount()
	return #waiting
end

function ClientBoard.isCollapsing()
	return collapsing
end

function ClientBoard.isPaused()
	return paused
end

-- ── carrying ──────────────────────────────────────────────────────────
-- Grabbing is entirely local: the ball is a part on this machine, the
-- player is simulated on this machine, and nothing about picking one up
-- changes what it's worth. The server is told only so the orb cap
-- doesn't auto-sell a ball out of the player's hands.

function ClientBoard.hold(part)
	local entry = byPart[part]
	if not entry then
		return false
	end
	entry.held = true
	-- Also an attribute, because other scripts ask the PART rather than
	-- the board — StashClient checks it before pocketing something, so
	-- an orb can't be taken out of your own hands.
	part:SetAttribute("Held", true)
	send(ToServer.HOLD, entry.id)
	return true
end

function ClientBoard.release(part)
	local entry = byPart[part]
	if not entry then
		return false
	end
	entry.held = nil
	part:SetAttribute("Held", nil)
	send(ToServer.RELEASE, entry.id)
	return true
end

-- ── stash ─────────────────────────────────────────────────────────────

-- The absorb: the orb flies into the player and shrinks away under a
-- cyan highlight, then flashes and is gone. Returns its id so the caller
-- can tell the server which orb went; nil if this one can't be taken.
--
-- The whole animation used to run on the server, on a replicated part,
-- frame by frame — every step of it travelling to every client in the
-- game so that one player could watch their own orb get pocketed. It's
-- all local now, which is why it starts on the frame the key is pressed.
function ClientBoard.stashAbsorb(part)
	local entry = byPart[part]
	if not entry or entry.selling or entry.stashing or collapsing or paused then
		return nil
	end
	-- Already spoken for: an orb mid-way into a splitter, or a splitter
	-- playing its send-off. The ledger has already dropped both, so a
	-- stash would be a message about an orb that no longer exists.
	if entry.claimed or entry.retiring then
		return nil
	end
	-- Self-driven orbs are exempt from the state check, the same way they
	-- are for selling. A magnet is never "settled" — it's off rising and
	-- wandering under its own control — and requiring that state here is
	-- what made magnets unstashable. What actually closes the window is
	-- its Pulling attribute, which StashClient checks: you can pocket a
	-- magnet right up until it becomes a live hazard, exactly as you can
	-- sell one.
	if not entry.selfDriven and entry.state ~= "settled" and entry.state ~= "ascending" then
		return nil
	end

	entry.stashing = true

	-- Stops the behaviour AND tears down what it left running. That
	-- second part matters far more here than anywhere else: this
	-- animation lerps the part's Size and CFrame for 0.15s, and a magnet
	-- caught early is still inside its own 0.6s grow tween — two things
	-- writing Size every frame, with the grow winning. The telegraph
	-- sphere is the same story in reverse: it's a separate part, so
	-- moving the magnet leaves it hanging in mid-air.
	stopBehaviours(entry)

	local id = entry.id
	local size = entry.size
	local startPos = part.Position
	local startSize = part.Size

	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false -- so it can't be re-targeted mid-flight

	-- Skipped for kinds whose own look shouldn't be painted over (see
	-- LOOK's noHighlights); the pull and the flash on arrival still say
	-- what happened.
	local highlight = Config.highlightable(entry.kind)
		and BoardEffects.fadeIn(part, Config.STASH_COLOR, Config.STASH_PULL_TIME)
		or nil

	task.spawn(function()
		local elapsed = 0
		while elapsed < Config.STASH_PULL_TIME do
			local dt = RunService.Heartbeat:Wait()
			if not part.Parent then
				return
			end
			elapsed += dt

			local alpha = math.clamp(elapsed / Config.STASH_PULL_TIME, 0, 1)
			-- expo-out: quick off the mark, easing into its final size
			-- right as it arrives
			local sizeAlpha = 1 - 2 ^ (-10 * alpha)

			-- the target is re-read rather than captured: the player can
			-- keep running, and the orb should follow them rather than
			-- converge on where they were standing when the key landed
			local character = Players.LocalPlayer.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart")
			local target = hrp and hrp.Position or startPos

			part.CFrame = CFrame.new(startPos:Lerp(target, alpha))
			part.Size = startSize:Lerp(
				Vector3.new(Config.STASH_END_SIZE, Config.STASH_END_SIZE, Config.STASH_END_SIZE),
				sizeAlpha
			)
		end

		local arrivedAt = part.Parent and part.Position or startPos
		if highlight and highlight.Parent then
			highlight:Destroy()
		end
		forget(entry)

		-- A fixed flash size rather than the orb's own: this is feedback
		-- on an input landing, not a readout of what left the board, so a
		-- size-400 orb shouldn't white out the screen while a size-3 one
		-- barely registers.
		BoardEffects.flash(arrivedAt, Config.STASH_FLASH_SIZE, Config.STASH_COLOR)
		BoardEffects.soundAt(arrivedAt, Config.SOUNDS.stash)
	end)

	return id, size
end

function ClientBoard.reportTrickShot()
	send(ToServer.TRICK_SHOT)
end

-- ── absorbing ─────────────────────────────────────────────────────────
-- A special pulling an orb into itself: a splitter today, a merger in
-- step 4. The board owns this rather than the special, because the orb
-- is the board's and has to leave cleanly whatever happens to the
-- special that took it — a splitter can be stashed, spent or collapsed
-- mid-pull, and the orb still has to finish going.

-- Whether a special may take this orb right now, and if so its id and
-- ledger size. Every condition here mirrors something the server will
-- check when the report arrives, because a refusal after the orb has
-- started converging costs a resync:
--
--   * a plain orb (radiant included), not a special
--   * settled — not rising, not still growing in, not falling
--   * old enough that Board.isLive will agree, by the server's clock plus
--     a margin (LIVE_MARGIN). A ball settles about 0.27s after launch and
--     the server's grace is 0.3s, so without this a splitter sitting in
--     the pile would take orbs the server hasn't counted as landed yet.
--   * not already claimed, held, being sold or being stashed
--   * past its immunity, if it has just emerged from something
local function absorbable(part)
	local entry = byPart[part]
	if not entry or entry.kind ~= "ball" or entry.state ~= "settled" then
		return nil
	end
	if entry.claimed or entry.held or entry.selling or entry.stashing or entry.retiring then
		return nil
	end
	if part:GetAttribute("Held") then
		return nil
	end
	if entry.immuneUntil and os.clock() < entry.immuneUntil then
		return nil
	end
	if serverNow() < entry.launchAt + Config.LAUNCH_TO_LIVE + Config.LIVE_MARGIN then
		return nil
	end
	return entry.id, entry.size
end

-- Claims the orb and pulls it into `target` over `duration`, shrinking it
-- to nothing, then removes it from the board. Returns its id, or nil if
-- it can't be taken. The claim is synchronous, so nothing else — another
-- splitter, the next frame of this one, a sell click — can take the same
-- orb once this has returned.
--
-- `pendingAttribute` goes on the part for scripts that ask the part
-- rather than the board (StashClient checks SplitPending/MergePending).
--
-- The target is a POSITION, captured by the caller when it acted — not
-- the special's part. Nothing here depends on the special still existing.
local function absorb(part, target, duration, pendingAttribute)
	local entry = byPart[part]
	if not entry or entry.claimed then
		return nil
	end
	entry.claimed = true
	if pendingAttribute then
		part:SetAttribute(pendingAttribute, true)
	end

	-- Anchored so the pull reads cleanly rather than fighting gravity and
	-- momentum; off the raycast so it can't be grabbed, sold or stashed
	-- mid-pull.
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false

	local startPos = part.Position
	local startSize = part.Size.X

	task.spawn(function()
		local elapsed = 0
		while elapsed < duration do
			local dt = RunService.Heartbeat:Wait()
			-- Removed by something else — a server REMOVE, a resync. Its
			-- remover has already dealt with it.
			if entries[entry.id] ~= entry or not part.Parent then
				return
			end
			-- Frozen where it is: the wipe takes it with everything else.
			if collapsing then
				return
			end
			elapsed += dt

			local alpha = math.clamp(elapsed / duration, 0, 1)
			local move = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
			local shrink = TweenService:GetValue(alpha, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)
			local size = startSize * (1 - shrink)
			part.Size = Vector3.new(size, size, size)
			part.CFrame = CFrame.new(startPos:Lerp(target, move))
		end

		if entries[entry.id] == entry then
			forget(entry)
		end
	end)

	return entry.id
end

-- ── emerging ──────────────────────────────────────────────────────────
-- Where the results of an absorb come out. The special writes this down
-- at the moment it acts, keyed by the consumed orb's id, and the server's
-- SPAWN names that same id back as `emergeFrom`.
--
-- This is the lesson of the first attempt at this step: that version had
-- the server name the SPECIAL and the client look up its live part when
-- the results launched, which meant keeping the splitter alive and
-- waiting on it, and a pile of machinery for when it wasn't. The client
-- already knows exactly where the splitter was when it acted — it's
-- holding that position when it reports. So it keeps it, and nothing
-- about the results depends on the splitter any more.
--
-- `delay` is how long the results are held back: the length of the
-- convergence, so they appear as the orb lands and not before.
local function emergeAt(sourceId, position, count, delay)
	local site = {
		position = position,
		readyAt = serverNow() + (delay or 0),
		count = math.max(count or 1, 1),
		used = 0,
		angle = rand() * math.pi * 2,
	}
	emergeSites[sourceId] = site

	-- A refused split never sends its halves, so its site would sit here
	-- forever. Harmless, but not free.
	task.delay(Config.EMERGE.SITE_TIMEOUT, function()
		if emergeSites[sourceId] == site then
			emergeSites[sourceId] = nil
		end
	end)
end

-- Where a growing result's centre sits: on the point it emerged from,
-- raised only when that would put its own bottom under the platform. A
-- part grown by tweening Size expands around a fixed centre, so a result
-- centred on a small splitter would otherwise spend its grow half-sunk
-- into the floor and get fired off it by the solver when it went live.
-- Recomputed per frame against the CURRENT size, so a big result starts
-- centred and eases up onto the floor as it grows. Straight from
-- BallManager's resultCenterY.
local function resultCenterY(centerY, currentSize)
	return math.max(centerY, Config.COL_Y + currentSize / 2)
end

-- ── behaviours ────────────────────────────────────────────────────────
-- A special's behaviour is a ModuleScript in ReplicatedStorage →
-- Behaviours, named after the kind's template (Bomb, Magnet, ...), with
-- a single `start(ctx)`. The runner spawns it when the orb launches and
-- then leaves it alone: stopping is `ctx.alive()` going false, which
-- every module polls around its own yields. That's the same shape the
-- old fuse scripts had, except a fuse used to be a Script living inside
-- the part, dying with it, and reaching BallManager through _G.
--
-- Nothing here knows what any particular special does. Adding one in a
-- later step is a module plus a weight in SPECIAL_WEIGHTS — or, for one
-- that consumes other orbs, a module plus the absorb/emerge pair the
-- splitter introduced, which the merger will share.

local behaviourCache = {} -- [kind] = module, or false for "there isn't one"

local function behaviourFor(kind)
	local cached = behaviourCache[kind]
	if cached ~= nil then
		return cached or nil
	end

	local look = Config.LOOK[kind]
	local name = look and look.template
	local behaviours = name and Rep:FindFirstChild("Behaviours")
	local module = behaviours and behaviours:FindFirstChild(name)

	if not (module and module:IsA("ModuleScript")) then
		-- Not an error: a kind with no module is one whose step hasn't
		-- landed yet, and its weight should be 0 anyway.
		behaviourCache[kind] = false
		return nil
	end

	local ok, result = pcall(require, module)
	if not ok or type(result) ~= "table" or type(result.start) ~= "function" then
		warn(("[ClientBoard] behaviour module %s is unusable: %s"):format(
			name,
			ok and "it has no start(ctx)" or tostring(result)
			))
		behaviourCache[kind] = false
		return nil
	end

	behaviourCache[kind] = result
	return result
end

local function startBehaviour(entry)
	local module = behaviourFor(entry.kind)
	if not module then
		return
	end

	local part = entry.part
	local ctx = {
		id = entry.id,
		kind = entry.kind,
		-- The LEDGER's size, never the part's. A module that read the
		-- part would be reading a number the client could have changed;
		-- this one came from the server.
		size = entry.size,
		radiant = entry.radiant,
		-- A merger's budget is measured against this, not its current
		-- size. The server sends it with every spawn and resync, so a
		-- rebuilt merger steps down the same way the ledger does.
		bornSize = entry.bornSize or entry.size,

		part = part,
		folder = folder,
		ops = ToServer,
		config = Config,
		rules = Rules,
		effects = BoardEffects,

		-- The stop signal, polled rather than pushed. False the moment
		-- the orb is sold, stashed, auto-sold, collapsed or removed by
		-- the server: forget() clears the flag on every one of those
		-- routes, so a module only ever has to ask.
		alive = function()
			return entry.behavioursAlive and part.Parent ~= nil
		end,

		report = function(...)
			send(...)
		end,

		remove = function()
			forget(entry)
		end,

		-- Register something to tear down whenever this behaviour stops,
		-- by whatever route. A module's own loops only need alive(), but
		-- anything it hands to something else to run — a TweenService
		-- tween, a part parented outside its own control flow — outlives
		-- it and needs this.
		onStop = function(cleanup)
			if not entry.behavioursAlive then
				-- Already stopped, so nothing is coming back to run it.
				-- Spawned rather than called inline so a module
				-- registering during its own teardown can't recurse.
				task.spawn(cleanup)
				return
			end
			local list = entry.behaviourCleanups
			if not list then
				list = {}
				entry.behaviourCleanups = list
			end
			table.insert(list, cleanup)
		end,

		-- What kind another part on this board is, or nil if it isn't a
		-- tracked orb at all. Behaviours need this to treat each other
		-- differently — a blast flashes orbs but not splitters, and
		-- step 5's mimic will care a great deal about what it's looking
		-- at. Reads the board's own table rather than the part's Name,
		-- which is only ever the template's and can be changed locally.
		kindOf = function(other)
			local otherEntry = byPart[other]
			return otherEntry and otherEntry.kind or nil
		end,

		-- Whether the board is running at all. A special that acts on
		-- other orbs stops acting the moment this goes false — an AFK
		-- pause or a collapse — though it can keep pulsing.
		running = function()
			return not paused and not collapsing
		end,

		-- Whether this orb has landed on the platform in the board's own
		-- terms (risen past COL_Y and finished growing in) and is old
		-- enough that the server will agree it's live. A splitter doesn't
		-- split before this.
		live = function()
			return entry.state == "settled"
				and serverNow() >= entry.launchAt + Config.LAUNCH_TO_LIVE + Config.LIVE_MARGIN
		end,

		-- The board's state for this orb ("settled", "falling", ...). For
		-- diagnostics; behaviours decide things with live() instead.
		state = function()
			return entry.state
		end,

		-- See absorbable / absorb / emergeAt above.
		absorbable = absorbable,
		absorb = absorb,
		emergeAt = emergeAt,

		-- This orb is on its way out under its own power — a splitter
		-- playing its send-off after the ledger has already let it go.
		-- Nothing can sell, stash or grab it from here.
		retire = function()
			entry.retiring = true
			part.CanQuery = false
		end,
	}

	task.spawn(function()
		local ok, err = pcall(module.start, ctx)
		if not ok then
			warn(("[ClientBoard] the %s behaviour errored on orb %d: %s")
				:format(entry.kind, entry.id, tostring(err)))

			-- A behaviour that died partway can't be trusted to have
			-- reported its own removal, and an orb the server still
			-- counts but this client has abandoned is exactly the
			-- softlock shape from phase 2b. Hand it back as expired, the
			-- way the module should have.
			if entry.behavioursAlive then
				send(ToServer.EXPIRED, entry.id)
				forget(entry)
			end
		end
	end)
end

-- ── spawning ──────────────────────────────────────────────────────────

-- Which template a kind is cloned from. Cached per kind, and anything
-- missing falls back to a plain orb with a warn rather than erroring
-- the launch — a board that spawns the wrong-looking orb is worth far
-- more than one that stops spawning.
local templates = {}

local function templateFor(kind)
	local cached = templates[kind]
	if cached then
		return cached
	end

	local look = Config.LOOK[kind]
	local name = look and look.template
	local template = name and Rep:FindFirstChild(name)
	if not (template and template:IsA("BasePart")) then
		-- Loud, because the symptom is subtle: the orb still spawns, still
		-- behaves correctly and still pays correctly — it just looks like
		-- a plain ball, with the plain ball's reflectance, surfaces and
		-- size readout instead of its own.
		warn(("[ClientBoard] no BasePart named %s in ReplicatedStorage for kind '%s' — falling back to a plain orb, which will look wrong")
			:format(tostring(name), tostring(kind)))
		template = ballTemplate
	end

	templates[kind] = template
	return template
end

local function launch(entry)
	local size = entry.size
	local visual = Rules.visualSize(size)
	local look = Config.LOOK[entry.kind]

	-- Everything written below is something the BOARD owns: where the
	-- orb is, how big it is, what it collides with, what it weighs, and
	-- which ledger entry it is. Everything else — reflectance, material,
	-- surface types, the billboard's own setup — is left exactly as the
	-- template has it, which is what makes a bomb look like a bomb.
	-- A self-driven kind is placed and then left entirely to its
	-- behaviour: anchored, no launch velocity, and skipped by the step
	-- loop. A magnet rises and wanders under its own control, and the
	-- ordinary path would spend the whole time trying to settle it onto
	-- the platform and switch its collision back on underneath it.
	local selfDriven = (look and look.selfDriven) == true

	-- An orb emerging from another orb (a split half) starts at nothing
	-- where the special was standing, and grows and hops outward from
	-- there — see stepEmerge. Anchored and solid against the platform for
	-- the whole grow, but in SplitGrowing, so it passes through the orbs
	-- it was born in the middle of, its sibling included.
	local emerge = entry.emerge

	local part = templateFor(entry.kind):Clone()
	if emerge then
		part.Anchored = true
		part.CollisionGroup = CG.SplitGrowing
		part.CanCollide = true
		part.CanQuery = false -- can't be grabbed, sold or stashed until it's a real orb
		part.Size = Vector3.new(0, 0, 0)
		part.CFrame = CFrame.new(emerge.position.X, resultCenterY(emerge.position.Y, 0), emerge.position.Z)
	else
		part.Anchored = selfDriven
		part.CollisionGroup = CG.Balls
		part.CanCollide = false -- comes back at COL_Y, see the heartbeat
		part.Size = Vector3.new(visual, visual, visual)
		part.CFrame = CFrame.new(Config.SPAWN_POS)
	end

	-- Only for kinds that are meant to be a random colour. A bomb or a
	-- magnet is recognised by its own colour scheme, and painting the
	-- ledger's roll over it made a bomb spawn lilac for the frame before
	-- its fuse took the colour back.
	if not look or look.ledgerColor then
		part.Color = entry.color
	end

	part:SetAttribute("BallId", entry.id)
	part:SetAttribute("TargetSize", size)
	if entry.radiant then
		part:SetAttribute("IsRadiant", true)
	end

	-- Likewise the readout. A bomb's label is "!!" and a magnet's is
	-- "><", baked into the template; writing the size over it at spawn
	-- left the static label gone until sell mode happened to restore it.
	-- The scale still applies to every kind — that's the billboard
	-- tracking the orb's size, not the text.
	if not look or look.showsSize then
		setDisplayText(part, size)
	else
		setDisplayScale(part, part.Size.X)
	end

	-- Mass stays roughly linear in size rather than cubic, so a big ball
	-- is heavy without being a wall (see BoardRules.densityFor).
	local props = part.CurrentPhysicalProperties
	part.CustomPhysicalProperties = PhysicalProperties.new(
		Rules.densityFor(size, baseSize),
		props.Friction,
		props.Elasticity,
		props.FrictionWeight,
		props.ElasticityWeight
	)

	part.Parent = folder
	if emerge then
		-- The hop is simulated by hand while the orb is anchored for its
		-- grow, then handed to real physics as a velocity. Its outward
		-- speed is random, and floored when it has siblings, so two
		-- halves given opposite directions always clear each other's
		-- radius by touchdown — unfloored, a roll near 0 left them
		-- overlapping when they went solid, and the solver fired them
		-- both off the platform.
		--
		-- Only when it has siblings. A merge result is alone, and the
		-- floor scales with size: a size-98 result would have been fired
		-- off at 80 studs a second to clear a sibling that doesn't exist.
		local cfg = Config.EMERGE
		local flight = 2 * cfg.POP_UP_SPEED / Workspace.Gravity
		local minSpeed = (emerge.count or 1) > 1 and (size / 2 + 1) / flight or 0
		local speed = math.max(minSpeed, rand() * cfg.POP_H_SPEED)
		emerge.hop = emerge.dir * speed
		emerge.flight = flight
		emerge.startedAt = os.clock()
	elseif not selfDriven then
		part.AssemblyLinearVelocity = Rules.launchVelocity(size, Workspace.Gravity, rand, baseSize)
	end

	entry.part = part
	entry.selfDriven = selfDriven
	-- "driven" is its own state rather than a lie about being settled, so
	-- anything that tests the state gets an honest answer. Selling knows
	-- about it; grabbing deliberately doesn't, which is what keeps a
	-- magnet from being picked up mid-flight. "emerging" is the same
	-- idea for a split half that hasn't finished growing in.
	if emerge then
		entry.state = "emerging"
	else
		entry.state = selfDriven and "driven" or "ascending"
	end
	entry.grown = emerge ~= nil -- an emerging orb does its own grow
	entry.behavioursAlive = true
	byPart[part] = entry

	if entry.radiant then
		startRadiantLoop(entry)
	end

	-- After the part is fully built and parented: a behaviour's first
	-- act can be to recolour or move it, and it shouldn't race the setup
	-- above.
	if entry.kind ~= "ball" then
		startBehaviour(entry)
	end

	-- A result is silent: the special that made it already played its
	-- own sound, and the old BallManager skipped the spawn cue for these
	-- for the same reason.
	if emerge then
		return
	end

	-- The spawn cue comes from the map's fixed spawn symbol rather than
	-- the ball, so a burst of launches doesn't smear across the floor.
	local special = entry.kind ~= "ball" or entry.radiant
	BoardEffects.soundAt(
		spawnSymbol and spawnSymbol.Position or Config.SPAWN_POS,
		special and Config.SOUNDS.spawnSpecial or Config.SOUNDS.spawn
	)

	-- An orb coming back out of the stash is the absorb run backwards:
	-- it launches as a solid cyan shape and resolves into its real
	-- colour as it rises. Everything else about it — the arc, the
	-- stagger, the grow — is an ordinary spawn, deliberately.
	-- The flash at the spawn point still plays for every kind; only the
	-- glow over the orb itself is skipped where LOOK says so.
	if entry.stashed then
		BoardEffects.flash(part.Position, Config.STASH_FLASH_SIZE, Config.STASH_COLOR, true)
	end
	if entry.stashed and Config.highlightable(entry.kind) then
		local glow = Instance.new("Highlight")
		glow.FillColor = Config.STASH_COLOR
		glow.FillTransparency = 0 -- opaque to start; the fade is what reveals the orb
		glow.OutlineTransparency = 1
		glow.DepthMode = Enum.HighlightDepthMode.Occluded
		glow.Parent = part

		local fade = TweenService:Create(
			glow,
			TweenInfo.new(Config.STASH_DEPLOY_GLOW_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ FillTransparency = 1 }
		)
		fade.Completed:Connect(function()
			glow:Destroy()
		end)
		fade:Play()
	end
end

local function addSpawnEntries(list)
	for _, data in ipairs(list) do
		if not entries[data.id] then
			local entry = {
				id = data.id,
				kind = data.kind,
				size = data.size,
				radiant = data.radiant,
				color = data.color,
				launchAt = data.launchAt,
				stashed = data.stashed,
				bornSize = data.bornSize, -- a merger's; see BoardRules.mergerAfterMerge
				state = "queued",
			}

			-- Growing out of an orb this client consumed. Looked up by
			-- the consumed orb's id in what the special wrote down when it
			-- acted (see emergeAt). If it isn't there — a resync, or a
			-- site that timed out — the orb simply launches normally,
			-- which is still an orb on the board.
			local site = data.emergeFrom and emergeSites[data.emergeFrom]
			if site then
				site.used += 1
				local count = math.max(data.emergeCount or site.count, 1)
				local angle = site.angle + (site.used - 1) * (math.pi * 2 / count)
				entry.emerge = {
					position = site.position,
					readyAt = site.readyAt,
					dir = Vector3.new(math.cos(angle), 0, math.sin(angle)),
					count = count,
				}
				if site.used >= count then
					emergeSites[data.emergeFrom] = nil
				end
			end

			entries[entry.id] = entry
			table.insert(waiting, entry)
		end
	end

	-- Stamps arrive in order in the normal case; a snapshot after a
	-- rejoin doesn't, so sort rather than assume.
	table.sort(waiting, function(a, b)
		return a.launchAt < b.launchAt
	end)
	syncQueueCount()
end

-- ── the heartbeat ─────────────────────────────────────────────────────
-- One loop for the whole board. It does exactly four things: launch
-- anything whose time has come, bring collision back once a ball is
-- clear of the platform, notice a settled ball falling off, and repaint
-- any billboard whose ball changed size.

local function stepLaunches()
	if paused or #waiting == 0 then
		return
	end

	local t = Workspace:GetServerTimeNow()
	local launched = 0
	local index = 1
	while index <= #waiting do
		local entry = waiting[index]
		if entry.launchAt > t then
			break -- sorted by stamp, so nothing after this is due either
		end
		if entry.emerge and entry.emerge.readyAt > t then
			-- Due by the server's stamp, but the orb it's coming out of is
			-- still converging. Stepped over rather than waited on, so a
			-- held half never holds up the ordinary launches behind it.
			index += 1
		else
			table.remove(waiting, index)
			if entries[entry.id] then -- still ours; a collapse may have dropped it
				launch(entry)
				launched += 1
			end
		end
	end

	if launched > 0 then
		syncQueueCount()
	end
end

-- Tells the server a ball went over the edge, exactly once, and leaves
-- the part falling so it reads as an orb going over rather than
-- blinking out. Client-created parts aren't reliably swept up by
-- FallenPartsDestroyHeight, and one that wedged under the platform
-- would never reach it anyway, so this cleans up after itself.
local function reportFall(entry)
	if entry.state == "falling" then
		return
	end
	entry.state = "falling"

	-- HudUI's ball count and SellClient's own only-orb check both read
	-- this attribute to mean "on its way out, don't count it". Without
	-- it a ball that's already been replaced keeps counting for the
	-- seconds it spends falling.
	if entry.part then
		entry.part:SetAttribute("Split", true)
	end

	-- The server decides what a fall is worth and what replaces it. All
	-- this says is that it happened.
	send(ToServer.FELL, entry.id)

	task.delay(Config.VOID_FALLBACK_TIMEOUT, function()
		if entries[entry.id] == entry then
			forget(entry)
		end
	end)
end

-- ── falling out of the world ──────────────────────────────────────────
-- The send-off for an orb that went over the edge. It used to simply
-- blink out the moment it crossed the void line, which with a clear view
-- straight down past the platform read as an orb vanishing in mid-air.
--
-- It shrinks away to nothing and goes. That's the whole thing.
--
-- It took two passes to get here. A flash barely registered, which makes
-- sense — a flash is a fixed-size billboard seen from a few hundred
-- studs away. A magenta highlight over the shrink read as an event, and
-- a fall isn't one: nobody was paid and nothing was taken, an orb just
-- left. The shrink alone says that, and it's the orb itself doing it,
-- so distance scales it the way distance scales everything else.
--
-- No sound, for the same reason. A busy board sends a couple of orbs
-- over the edge a second and each is hundreds of studs away by now.
local function voidExit(entry)
	-- The orb is still falling through this, so the step loop keeps
	-- reaching it frame after frame. Only the first one counts.
	if entry.voiding then
		return
	end

	local part = entry.part
	if not part or not part.Parent then
		forget(entry)
		return
	end

	entry.voiding = true
	stopBehaviours(entry)

	-- Quad IN, so the orb holds its size for most of it and then
	-- collapses at the end. Easing out instead would dump most of the
	-- size in the first few frames and leave a speck hanging there for
	-- the rest, which reads as a stutter rather than a disappearance.
	TweenService:Create(
		part,
		TweenInfo.new(Config.VOID_EXIT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Size = Vector3.new(0, 0, 0) }
	):Play()

	task.delay(Config.VOID_EXIT_TIME, forget, entry)
end

-- One frame of an emerging orb: grow from nothing while hopping outward
-- on a hand-simulated arc, then hand over to real physics with the arc's
-- velocity. The numbers are BallManager's spawnSplitResult's — the same
-- 0.6s Quad-out grow, the same v0·t − ½gt² hop — but unlike the original
-- it never stops moving outward: it lands and rolls on rather than
-- dying on the spot.
--
-- Driven from the board's own heartbeat rather than a tween plus a
-- property listener, which is what the original had to do and why it
-- needed a watchdog for the tween that never completed.
local function stepEmerge(entry, part)
	local emerge = entry.emerge
	local cfg = Config.EMERGE
	local gravity = Workspace.Gravity

	local elapsed = os.clock() - emerge.startedAt
	local growAlpha = math.clamp(elapsed / Config.GROW_TIME, 0, 1)
	local size = entry.size * TweenService:GetValue(growAlpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	-- Only the vertical arc stops at touchdown. The outward travel keeps
	-- going the whole time — the original clamped both, which is why a
	-- half that landed a frame before it finished growing sat dead still.
	local arcT = math.min(elapsed, emerge.flight)
	local hopY = math.max(cfg.POP_UP_SPEED * arcT - 0.5 * gravity * arcT * arcT, 0)
	local origin = emerge.position

	part.Size = Vector3.new(size, size, size)
	part.CFrame = CFrame.new(
		origin.X + emerge.hop.X * elapsed,
		resultCenterY(origin.Y, size) + hopY,
		origin.Z + emerge.hop.Z * elapsed
	)

	if growAlpha < 1 then
		return
	end

	-- Fully grown: a real orb from here on, settled already — it's on the
	-- platform and it's never going to rise past COL_Y the way a launched
	-- one does.
	part.Anchored = false
	part.CollisionGroup = CG.Balls
	part.CanQuery = true

	-- Handed over still moving outward, whether it's landed yet or not,
	-- so it rolls on in the direction the splitter threw it and friction
	-- slows it down from there. Vertical speed only if it's still in the
	-- air; once it's down, driving it into the floor would just bounce it.
	local vy = 0
	if elapsed < emerge.flight and hopY > 0.05 then
		vy = cfg.POP_UP_SPEED - gravity * elapsed
	end
	part.AssemblyLinearVelocity = Vector3.new(emerge.hop.X, vy, emerge.hop.Z)

	-- ...and spun to match, as if it were already rolling. A sphere
	-- that's sliding without spinning has its speed eaten by friction in
	-- a few frames, which reads as stopping dead. Rolling without
	-- slipping means ω = (up × v) / r.
	local radius = math.max(entry.size / 2, 0.05)
	part.AssemblyAngularVelocity = Vector3.new(0, 1, 0):Cross(Vector3.new(emerge.hop.X, 0, emerge.hop.Z)) / radius

	entry.state = "settled"
	entry.reachedColY = true
	-- Born inside the reach of the splitter that made it, so it gets a
	-- moment to roll clear before anything can take it again.
	entry.immuneUntil = emerge.startedAt + cfg.IMMUNITY
	entry.emerge = nil
end

local function stepBall(entry)
	local part = entry.part
	if not part or not part.Parent or paused then
		return
	end

	-- Its behaviour owns where it is, including whether it's allowed to
	-- fall. Everything below assumes an orb thrown up onto the platform,
	-- and none of it is true for a magnet holding station in mid-air.
	if entry.selfDriven then
		return
	end

	-- Being pulled into a splitter or the player's pocket: anchored, and
	-- whatever is pulling it owns its position until it's gone. Neither is
	-- a fall, whatever height it passes through on the way.
	if entry.claimed or entry.stashing then
		return
	end

	if entry.state == "emerging" then
		-- A collapse froze it where it stood; finishing the grow would
		-- unanchor it in the middle of the wipe.
		if not collapsing then
			stepEmerge(entry, part)
		end
		return
	end

	local y = part.Position.Y

	-- The catch-all, checked in every state. The state machine below
	-- only notices a SETTLED ball dropping through the platform, which
	-- is the normal way an orb leaves — but a ball deflected on the way
	-- up never settles at all, and used to fall forever: never reported,
	-- so never replaced, while the ledger went on counting it against
	-- the orb cap. That's a board that quietly thins out and then stops
	-- refilling.
	--
	-- Reporting only. It used to destroy the orb on the same line, which
	-- is why a fall ended in a part blinking out of existence partway
	-- down; the orb now keeps falling from here and gets its send-off
	-- further down, out of sight.
	if y < Config.VOID_Y then
		reportFall(entry)
	end

	if y < Config.VOID_EXIT_Y then
		voidExit(entry)
		return
	end

	if entry.state == "ascending" then
		-- Grow-in starts on height, independently of when collision
		-- comes back.
		if not entry.grown and y > Config.GROW_Y then
			entry.grown = true
			if entry.size > Config.GROW_AT then
				-- Collision must NOT come back until this finishes. A big
				-- ball rises fast enough to cross COL_Y mid-tween, and a
				-- ball that's already solid while still expanding is what
				-- used to shove itself through the platform.
				entry.colliderReady = false
				local grow = TweenService:Create(
					part,
					TweenInfo.new(Config.GROW_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Size = Vector3.new(entry.size, entry.size, entry.size) }
				)
				grow.Completed:Connect(function()
					entry.colliderReady = true
				end)
				grow:Play()
			end
		end

		-- Latched, not re-tested every frame. Requiring "above COL_Y" and
		-- "done growing" in the SAME frame is what used to strand an
		-- oversized ball in mid-air with collision permanently off: the
		-- grow takes 0.6s, and the part is only above the line for part
		-- of that.
		if y > Config.COL_Y then
			entry.reachedColY = true
		end

		if entry.reachedColY and entry.colliderReady ~= false then
			part.CanCollide = true
			entry.state = "settled"
		end

	elseif entry.state == "settled" then
		local position = part.Position
		if position.Y < Config.FALL_Y or position.Magnitude > Config.MAX_DIST_FROM_ORIGIN then
			reportFall(entry)
		end
	end
end

local function stepDisplays()
	for _, part in ipairs(folder:GetChildren()) do
		if part:IsA("BasePart") then
			local size = part.Size.X
			if displayScaleAt[part] ~= size then
				setDisplayScale(part, size)
			end
		end
	end
end

-- ── selling ───────────────────────────────────────────────────────────

-- THE ONE ANSWER TO "CAN THIS BE SOLD RIGHT NOW?"
--
-- As far as the board is concerned — SellClient still owns the upgrade
-- side (defuser, degausser, a magnet that's started pulling). Both sell
-- paths below use this, and SellClient asks it BEFORE it marks an orb as
-- selling or plays anything.
--
-- That order is the fix for an orb that became permanently unsellable.
-- SellClient used to mark the orb, play the flash, and only then ask the
-- board, without looking at the answer. When the board said no — a split
-- half still growing in, an orb being pulled into a splitter — the orb
-- stayed on screen marked "already being sold", and SellClient skips
-- those for hover and box select alike, forever. A marquee over a busy
-- splitter is where it happened: it scoops up everything on screen.
local function canSell(entry)
	if not entry or entry.selling or collapsing or paused then
		return false
	end
	if entry.claimed or entry.retiring then
		-- mid-way into a splitter, or a splitter playing its send-off:
		-- the ledger dropped it the moment the split was reported, so
		-- there's nothing left to sell
		return false
	end
	if entry.selfDriven then
		-- A magnet is sellable through the degausser for its whole rise
		-- and wander; what closes that window is its own Pulling
		-- attribute, which SellClient checks.
		return true
	end
	-- Anything visibly on the board. "emerging" is a split half still
	-- growing in: it's on the server's ledger from the moment it appears,
	-- and a click on it is as legitimate as a click on an orb mid-rise
	-- (see Board.isOnBoard). What's left out is "queued" (not here yet)
	-- and "falling" (already reported, so the server forgot it).
	return entry.state == "settled" or entry.state == "ascending" or entry.state == "emerging"
end

function ClientBoard.canSell(part)
	return canSell(byPart[part])
end

-- Called by SellClient once it has decided a click was a real sell.
-- Returns whether it actually sold; SellClient only plays the flash and
-- sound when it did. The ball goes immediately and the server settles
-- the money.
function ClientBoard.sell(part)
	local entry = byPart[part]
	if not canSell(entry) then
		return false
	end
	entry.selling = true
	send(ToServer.SELL, entry.id)
	forget(entry)
	return true
end

-- The box-select counterpart: one message for the whole selection, so a
-- big drag is one round trip rather than thirty.
--
-- Returns the parts it actually sold, keyed by part, so SellClient
-- flashes exactly those and leaves the rest alone. Everything is checked
-- with the same canSell the single sell uses: a marquee selects by where
-- things are on screen and doesn't care what's falling, being pulled
-- into a splitter, or anything else.
function ClientBoard.sellBox(parts)
	local ids, sold = {}, {}
	for _, part in ipairs(parts) do
		local entry = byPart[part]
		if canSell(entry) then
			entry.selling = true
			table.insert(ids, entry.id)
			sold[part] = true
			forget(entry)
		end
	end
	if #ids > 0 then
		send(ToServer.SELL_BOX, ids)
	end
	return sold
end

-- ── removals the server asks for ─────────────────────────────────────

local function autoSellVisual(entry)
	local part = entry.part
	if not part or not part.Parent then
		forget(entry)
		return
	end

	stopBehaviours(entry)
	local position = part.Position
	local size = entry.size

	-- The server has already forgotten it. For the 0.3s it spends fading
	-- out here it's still a settled orb as far as everything else can
	-- tell — and a splitter that took it in that window reported a split
	-- of an orb the server no longer had. Marked as on its way out, which
	-- keeps it away from splitters, sells and the stash alike.
	entry.retiring = true
	part.CanQuery = false

	-- Cyan, not the seller's yellow: this is the board taking a ball
	-- away rather than the player cashing one in, and the colour is what
	-- tells those apart at a glance.
	local color = Color3.fromRGB(0, 255, 255)
	local highlight = BoardEffects.fadeIn(part, color, Config.PRE_SELL_DELAY)

	task.delay(Config.PRE_SELL_DELAY, function()
		if highlight.Parent then
			highlight:Destroy()
		end
		forget(entry)
		BoardEffects.flash(position, size, color)
		BoardEffects.soundAt(position, Config.SOUNDS.sell)
	end)
end

local function clearVisual(entry)
	local part = entry.part
	if not part or not part.Parent then
		forget(entry)
		return
	end
	local position, size = part.Position, entry.size
	forget(entry)
	BoardEffects.flash(position, size, Config.COLLAPSE_VISUALS.flashColor, true)
	BoardEffects.soundAt(position, Config.SOUNDS.collapseSell)
end

local function onRemove(id, reason)
	local entry = entries[id]
	if not entry then
		return
	end
	if not entry.part then
		-- still queued: it never got to exist
		for index, queued in ipairs(waiting) do
			if queued == entry then
				table.remove(waiting, index)
				break
			end
		end
		entries[id] = nil
		syncQueueCount()
		return
	end

	if reason == "autoSell" then
		autoSellVisual(entry)
	else
		clearVisual(entry)
	end
end

-- ── collapse ──────────────────────────────────────────────────────────

local ambience
local ambienceVolume -- whatever it was before the collapse muted it
local spinScale

local function findAmbience()
	if ambience and ambience.Parent then
		return ambience
	end
	ambience = Workspace:FindFirstChild("ambience", true)
	return ambience
end

-- The decorative spinning pieces read this. It used to be a replicated
-- NumberValue the server drove; now every board freezes its own.
local function getSpinScale()
	if spinScale and spinScale.Parent then
		return spinScale
	end
	spinScale = Workspace:FindFirstChild("SpinScale")
	if not spinScale then
		spinScale = Instance.new("NumberValue")
		spinScale.Name = "SpinScale"
		spinScale.Value = 1
		spinScale.Parent = Workspace
	end
	return spinScale
end

local function freezeBoard()
	-- Anything still queued never arrives: the board is being wiped, and
	-- a ball launching into a freeze would just sit there mid-air.
	for _, entry in ipairs(waiting) do
		entries[entry.id] = nil
	end
	table.clear(waiting)
	syncQueueCount()

	for _, entry in pairs(entries) do
		stopBehaviours(entry)
		local part = entry.part
		if part and part.Parent then
			part.Anchored = true
			part.CanCollide = false
		end
	end
end

local function wipeBoard()
	-- Smallest first, so the board drains rather than vanishing.
	local ordered = {}
	for _, entry in pairs(entries) do
		if entry.part and entry.part.Parent then
			table.insert(ordered, entry)
		end
	end
	table.sort(ordered, function(a, b)
		return a.size < b.size
	end)

	task.spawn(function()
		for index, entry in ipairs(ordered) do
			local part = entry.part
			if part and part.Parent then
				local position, size = part.Position, entry.size
				local highlight = BoardEffects.fadeIn(
					part,
					Config.COLLAPSE_VISUALS.flashColor,
					Config.PRE_SELL_DELAY,
					true
				)
				task.delay(Config.PRE_SELL_DELAY, function()
					if highlight.Parent then
						highlight:Destroy()
					end
					forget(entry)
					BoardEffects.flash(position, size, Config.COLLAPSE_VISUALS.flashColor, true)
					BoardEffects.soundAt(position, Config.SOUNDS.collapseSell)
				end)
			end
			if index < #ordered then
				task.wait(Config.COLLAPSE_SELL_GAP)
			end
		end
	end)
end

local function onCollapse(phase, value)
	if phase == CollapsePhase.TELEGRAPH then
		Workspace:SetAttribute("CollapseCountdown", value)
		BoardEffects.flatSound(Config.SOUNDS.collapseTick)
		BoardEffects.startLoop(Config.SOUNDS.collapseTension)

	elseif phase == CollapsePhase.CANCEL then
		Workspace:SetAttribute("CollapseCountdown", nil)
		BoardEffects.stopLoop(Config.SOUNDS.collapseTension)

	elseif phase == CollapsePhase.CUT then
		collapsing = true
		Workspace:SetAttribute("Collapsing", true)
		Workspace:SetAttribute("CollapseCountdown", nil)
		BoardEffects.stopLoop(Config.SOUNDS.collapseTension)
		BoardEffects.flatSound(Config.SOUNDS.collapseAlarm)
		freezeBoard()
		getSpinScale().Value = 0

		local amb = findAmbience()
		if amb then
			-- captured rather than assumed, so the fade back at the end
			-- restores whatever the map actually had rather than a
			-- number guessed here
			ambienceVolume = amb.Volume
			amb.Volume = 0
		end

	elseif phase == CollapsePhase.WIPE then
		wipeBoard()

	elseif phase == CollapsePhase.RESOLVE then
		local fade = TweenInfo.new(Config.COLLAPSE_FADE_TIME)
		local amb = findAmbience()
		if amb and ambienceVolume then
			TweenService:Create(amb, fade, { Volume = ambienceVolume }):Play()
		end
		TweenService:Create(getSpinScale(), fade, { Value = 1 }):Play()

		task.delay(Config.COLLAPSE_FADE_TIME, function()
			collapsing = false
			Workspace:SetAttribute("Collapsing", false)
		end)
	end

	ClientBoard.collapse:Fire(phase, value)
end

-- ── pause ─────────────────────────────────────────────────────────────

-- Everything stops where it is. Anchoring rather than just not stepping
-- them: a ball left unanchored would keep rolling off the platform
-- under its own momentum while the board is meant to be still, and the
-- fall it reported would be refused by a paused server.
local function setPaused(value)
	if value == paused then
		return
	end
	paused = value

	if paused then
		pausedAt = Workspace:GetServerTimeNow()
	else
		-- Hold the launch queue's clock still for the length of the
		-- pause: a ball that was two seconds from launching should
		-- still be two seconds from launching. The server does the same
		-- arithmetic to its own copy off the same two messages, so
		-- neither side has to re-send anything.
		local delta = pausedAt and (Workspace:GetServerTimeNow() - pausedAt) or 0
		pausedAt = nil
		if delta > 0 then
			for _, entry in ipairs(waiting) do
				entry.launchAt += delta
				if entry.emerge then
					entry.emerge.readyAt += delta
				end
			end
			for _, site in pairs(emergeSites) do
				site.readyAt += delta
			end
		end
	end

	for _, entry in pairs(entries) do
		local part = entry.part
		if part and part.Parent then
			if paused then
				part.Anchored = true
			else
				-- Back to whatever it was before, not blanket unanchored.
				-- Some orbs are anchored on purpose — a magnet holds
				-- station under its own control, a split half is pinned
				-- for its grow, an orb being pulled into a splitter is
				-- being moved by hand — and unanchoring any of those
				-- dropped it out of the air.
				part.Anchored = entry.selfDriven == true
					or entry.state == "emerging"
					or entry.claimed == true
					or entry.stashing == true
					or entry.retiring == true -- a spent splitter, pinned for its send-off
			end
		end
	end
end

-- ── incoming ──────────────────────────────────────────────────────────

local function onServerMessage(op, a, b)
	if op == ToClient.SPAWN then
		addSpawnEntries(a)

	elseif op == ToClient.REMOVE then
		onRemove(a, b)

	elseif op == ToClient.COLLAPSE then
		onCollapse(a, b)

	elseif op == ToClient.PAUSE then
		setPaused(a == true)

	elseif op == ToClient.RESET then
		for _, entry in pairs(entries) do
			forget(entry)
		end
		table.clear(waiting)
		table.clear(emergeSites)
		entries = {}
		syncQueueCount()

	elseif op == ToClient.REJECT then
		-- Shouldn't happen in normal play: this client told the server
		-- something the ledger disagreed with. Worth knowing about in
		-- Studio rather than silently diverging.
		warn(("[ClientBoard] the server refused a message about ball %s: %s"):format(tostring(a), tostring(b)))

		-- ...and "silently diverging" is exactly what used to happen
		-- next. Most of what this client reports it has ALREADY acted
		-- on locally — a sold ball is hidden on the click, a stashed one
		-- has played its pull — so a refusal leaves a ball gone here and
		-- still on the ledger there, forever. The server then counts it
		-- as a ball the board already has and never queues a
		-- replacement.
		--
		-- So don't try to work out which of us is wrong. Ask for the
		-- ledger back and rebuild from it; the server is the authority
		-- by definition.
		requestResync("the server refused something we told it")
	end
end

-- ── the empty-board watchdog ──────────────────────────────────────────
-- The server's rule is that a board is never left empty: the last ball
-- leaving queues a replacement before the payout is even sent. So an
-- empty board here, for longer than it could possibly take one to
-- arrive, means the two sides no longer agree about what this board
-- holds — and nothing on this side can fix that by reasoning, because
-- the ledger is the authority.
--
-- This is deliberately a check on the SYMPTOM rather than on any
-- particular cause. The cause we know about (a refused sell leaving a
-- ball hidden here and still counted there) is fixed properly in
-- Board.isOnBoard, and the REJECT handler above now repairs itself. This
-- sits underneath both, so that a bug we haven't met yet — a special in
-- phase 3 mishandling its own removal, say — costs a two-second pause
-- instead of a dead board and a rejoin.

local emptyFor = 0

-- What the server actually guarantees is a PLAIN orb: its ensureBall
-- counts kind "ball" only, queued ones included. So that's what this
-- looks for. It used to look for anything at all, which meant a splitter
-- or merger still sitting on the board kept it quiet while the server
-- waited on an orb that no longer existed here — exactly the "sold
-- everything and nothing came back" case.
local function hasPlainOrb()
	for _, entry in pairs(entries) do
		if entry.kind == "ball" then
			return true
		end
	end
	return false
end

local function stepEmptyWatchdog(dt)
	-- A collapse empties the board on purpose, and a paused board isn't
	-- meant to be doing anything at all.
	if collapsing or paused or hasPlainOrb() then
		emptyFor = 0
		return
	end

	emptyFor += dt
	if emptyFor >= Config.EMPTY_BOARD_GRACE then
		emptyFor = 0
		requestResync("no plain orb on the board for too long")
	end
end

-- ── start ─────────────────────────────────────────────────────────────

function ClientBoard.start()
	if started then
		return ClientBoard
	end
	started = true

	toServer, toClient = Protocol.remotes(false)

	ballTemplate = Rep:WaitForChild("Ball")
	spawnSymbol = Workspace:FindFirstChild("spawnsymbol")

	-- The server has no way to look at the template, so it works from
	-- BoardConfig.BASE_SIZE. If someone resizes the template in Studio
	-- without updating that, launch arcs and density quietly drift.
	baseSize = ballTemplate.Size.X
	if math.abs(baseSize - Config.BASE_SIZE) > 0.001 then
		warn(("[ClientBoard] the Ball template is size %.2f but BoardConfig.BASE_SIZE says %.2f — update the config")
			:format(baseSize, Config.BASE_SIZE))
	end

	folder = Workspace:FindFirstChild("Balls")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Balls"
		folder.Parent = Workspace
	end
	folder:SetAttribute("CollisionRegainY", Config.COL_Y)
	syncQueueCount()
	ClientBoard.folder = folder

	Workspace:SetAttribute("Collapsing", false)

	toClient.OnClientEvent:Connect(onServerMessage)

	RunService.Heartbeat:Connect(function(dt)
		stepLaunches()
		for _, entry in pairs(entries) do
			if entry.part then
				stepBall(entry)
			end
		end
		stepDisplays()
		stepEmptyWatchdog(dt)
	end)

	-- Ask for whatever the server already has for us. Sent last, so
	-- nothing arrives before the handler above is listening.
	send(ToServer.READY)

	return ClientBoard
end

return ClientBoard