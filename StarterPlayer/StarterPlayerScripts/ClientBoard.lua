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
-- Phase 3 turns every behaviour into its own module under a Behaviours
-- folder; the radiant colour loop is small enough, and needed from
-- phase 1, that it lives here until then.

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

local function forget(entry)
	entry.behavioursAlive = false
	entries[entry.id] = nil
	if entry.part then
		byPart[entry.part] = nil
		if entry.part.Parent then
			entry.part:Destroy()
		end
	end
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
	send(ToServer.HOLD, entry.id)
	return true
end

function ClientBoard.release(part)
	local entry = byPart[part]
	if not entry then
		return false
	end
	entry.held = nil
	send(ToServer.RELEASE, entry.id)
	return true
end

function ClientBoard.reportTrickShot()
	send(ToServer.TRICK_SHOT)
end

-- ── spawning ──────────────────────────────────────────────────────────

local function launch(entry)
	local size = entry.size
	local visual = Rules.visualSize(size)

	local part = ballTemplate:Clone()
	part.Anchored = false
	part.CollisionGroup = CG.Balls
	part.CanCollide = false -- comes back at COL_Y, see the heartbeat
	part.Size = Vector3.new(visual, visual, visual)
	part.Color = entry.color
	part.CFrame = CFrame.new(Config.SPAWN_POS)

	part:SetAttribute("BallId", entry.id)
	part:SetAttribute("TargetSize", size)
	if entry.radiant then
		part:SetAttribute("IsRadiant", true)
	end

	setDisplayText(part, size)

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
	part.AssemblyLinearVelocity = Rules.launchVelocity(size, Workspace.Gravity, rand, baseSize)

	entry.part = part
	entry.state = "ascending"
	entry.grown = false
	entry.behavioursAlive = true
	byPart[part] = entry

	if entry.radiant then
		startRadiantLoop(entry)
	end

	-- The spawn cue comes from the map's fixed spawn symbol rather than
	-- the ball, so a burst of launches doesn't smear across the floor.
	local special = entry.kind ~= "ball" or entry.radiant
	BoardEffects.soundAt(
		spawnSymbol and spawnSymbol.Position or Config.SPAWN_POS,
		special and Config.SOUNDS.spawnSpecial or Config.SOUNDS.spawn
	)
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

local function stepBall(entry)
	local part = entry.part
	if not part or not part.Parent or paused then
		return
	end

	-- The catch-all, checked in every state. The state machine below
	-- only notices a SETTLED ball dropping through the platform, which
	-- is the normal way an orb leaves — but a ball deflected on the way
	-- up never settles at all, and used to fall forever: never reported,
	-- so never replaced, while the ledger went on counting it against
	-- the orb cap. That's a board that quietly thins out and then stops
	-- refilling.
	if part.Position.Y < Config.VOID_Y then
		reportFall(entry)
		forget(entry)
		return
	end

	if entry.state == "ascending" then
		local y = part.Position.Y

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
	if entry.state ~= "settled" and entry.state ~= "ascending" then
		-- already on its way off the edge: the server forgot it the
		-- moment the fall was reported, so selling it would be a message
		-- about a ball that no longer exists
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
		if entry and not entry.selling and not collapsing and not paused then
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

	entry.behavioursAlive = false
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
		entry.behavioursAlive = false
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

	RunService.Heartbeat:Connect(function()
		stepLaunches()
		for _, entry in pairs(entries) do
			if entry.part then
				stepBall(entry)
			end
		end
		stepDisplays()
	end)

	-- Ask for whatever the server already has for us. Sent last, so
	-- nothing arrives before the handler above is listening.
	send(ToServer.READY)

	return ClientBoard
end

return ClientBoard
