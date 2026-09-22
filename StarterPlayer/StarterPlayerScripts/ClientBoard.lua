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

local function requestResync(why)
	local t = os.clock()
	if t - lastResyncAt < Config.RESYNC_COOLDOWN then
		return false
	end
	lastResyncAt = t
	warn(("[ClientBoard] asking the server to resend the board: %s"):format(why))
	send(ToServer.READY)
	return true
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

	local highlight = BoardEffects.fadeIn(part, Config.STASH_COLOR, Config.STASH_PULL_TIME)

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
		if highlight.Parent then
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
-- later step is a module plus a weight in SPECIAL_WEIGHTS, and no
-- change to this file at all.

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

	local part = templateFor(entry.kind):Clone()
	part.Anchored = selfDriven
	part.CollisionGroup = CG.Balls
	part.CanCollide = false -- comes back at COL_Y, see the heartbeat
	part.Size = Vector3.new(visual, visual, visual)
	part.CFrame = CFrame.new(Config.SPAWN_POS)

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
	if not selfDriven then
		part.AssemblyLinearVelocity = Rules.launchVelocity(size, Workspace.Gravity, rand, baseSize)
	end

	entry.part = part
	entry.selfDriven = selfDriven
	-- "driven" is its own state rather than a lie about being settled, so
	-- anything that tests the state gets an honest answer. Selling knows
	-- about it; grabbing deliberately doesn't, which is what keeps a
	-- magnet from being picked up mid-flight.
	entry.state = selfDriven and "driven" or "ascending"
	entry.grown = false
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
	if entry.stashed then
		BoardEffects.flash(part.Position, Config.STASH_FLASH_SIZE, Config.STASH_COLOR, true)

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
				state = "queued",
			}
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
	while #waiting > 0 and waiting[1].launchAt <= t do
		local entry = table.remove(waiting, 1)
		if entries[entry.id] then -- still ours; a collapse may have dropped it
			launch(entry)
			launched += 1
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

-- Called by SellClient once it has decided a click was a real sell.
-- The ball goes immediately; SellClient plays its own flash and sound
-- (it has always done both locally), and the server settles the money.
function ClientBoard.sell(part)
	local entry = byPart[part]
	if not entry or entry.selling or collapsing or paused then
		return false
	end
	if not entry.selfDriven and entry.state ~= "settled" and entry.state ~= "ascending" then
		-- already on its way off the edge: the server forgot it the
		-- moment the fall was reported, so selling it would be a message
		-- about a ball that no longer exists
		--
		-- A self-driven orb is exempt: a magnet is sellable through the
		-- degausser for its whole rise and wander, and what closes that
		-- window is its own Pulling attribute, which SellClient checks.
		return false
	end
	entry.selling = true
	send(ToServer.SELL, entry.id)
	forget(entry)
	return true
end

-- The box-select counterpart: one message for the whole selection, so a
-- big drag is one round trip rather than thirty.
function ClientBoard.sellBox(parts)
	local ids = {}
	for _, part in ipairs(parts) do
		local entry = byPart[part]
		-- Same state check the single sell does, and for the same
		-- reason: an orb already on its way off the edge was reported as
		-- fallen the moment it crossed, and the server forgot it right
		-- then. Selling it is a message about an orb that no longer
		-- exists.
		--
		-- This was missing here, and a marquee doesn't care what's
		-- falling — it selects by where things are on screen. On a busy
		-- board a drag would routinely scoop up an orb mid-fall, which
		-- is why a bulk sell so often ended in the whole board rebuilding
		-- itself.
		if entry
			and not entry.selling
			and not collapsing
			and not paused
			and (entry.state == "settled" or entry.state == "ascending")
		then
			entry.selling = true
			table.insert(ids, entry.id)
			forget(entry)
		end
	end
	if #ids == 0 then
		return false
	end
	send(ToServer.SELL_BOX, ids)
	return true
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
			end
		end
	end

	for _, entry in pairs(entries) do
		local part = entry.part
		if part and part.Parent then
			part.Anchored = paused
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

local function stepEmptyWatchdog(dt)
	-- A collapse empties the board on purpose, and a paused board isn't
	-- meant to be doing anything at all.
	if collapsing or paused or next(entries) ~= nil then
		emptyFor = 0
		return
	end

	emptyFor += dt
	if emptyFor >= Config.EMPTY_BOARD_GRACE then
		emptyFor = 0
		requestResync("the board has been empty too long")
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
