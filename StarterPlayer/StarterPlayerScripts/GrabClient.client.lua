--[[
    GrabClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: true
    Exported: 2026-09-20 22:14:29
]]
--[[
	GrabClient (LocalScript) — StarterPlayerScripts

	Client side of the grab upgrade (see GrabHandler's header for the
	full rebuild rationale).

	REBUILD, v2. A first pass made the server own a held ball's motion
	entirely, which fixed the ownership races but felt bad: the ball
	dragged behind its holder, grabbing felt slow to respond to input,
	and throwing could drop the ball on the spot instead of launching
	it (a network-ownership race — see GrabHandler's header). This
	version moves carry authority back to the CLIENT, which is what
	actually gives zero-latency movement, but keeps it correct with the
	same two protections the original working version relied on:

	  - A local "ghost" stand-in bridges the RequestGrab round trip so
	    the ball visibly starts moving the INSTANT the key is pressed,
	    not after the server responds. See beginCarry for how.
	  - GrabHandler now keeps the thrower as the ball's explicit network
	    owner for a brief window after a throw (OWNERSHIP_RELEASE_DELAY)
	    before handing back to automatic assignment, so the throw
	    velocity has time to actually land before ownership can move on.

	Either E or left-click does double duty depending on state:
	  - not carrying anything: aim (a ray from the camera through the
	    mouse cursor, not straight out of camera center — the cursor
	    can be pointed somewhere the camera itself isn't facing,
	    especially in third person) + press either key. If that hits a
	    settled, grabbable-size regular or radiant ball within
	    GRAB_RANGE of the player (straight-line distance from the
	    player's own HumanoidRootPart, NOT the camera), it's requested
	    from the server.
	  - carrying a ball: either key is just held down for as long as you
	    want to keep carrying it. Letting go of EITHER one throws the
	    ball immediately along the camera's current look vector, at a
	    flat THROW_SPEED, full force every time.

	A held ball always floats a fixed HOLD_CLEARANCE above the carrying
	player's HumanoidRootPart, offset further by the ball's own radius
	so different tiers/sizes all float the same actual distance above
	the ground. Carrying uses an AlignPosition (constraint-driven, so it
	tracks smoothly through the physics solver instead of teleporting)
	pulling toward an invisible anchor part that RenderStepped keeps
	re-centered above the player each frame.

	Carrying is purely client-side, and only actually works because
	RequestGrab handed this client network ownership of the ball first
	(see GrabHandler's header for why that has to be explicit rather
	than relying on Roblox's automatic proximity-based assignment).

	Why the ghost exists: tryGrab's checks all mirror what GrabHandler
	validates server-side, so agreement is the overwhelming common
	case — but AlignPosition can't move a part on a machine that isn't
	its NetworkOwner, and this client doesn't reliably have that until
	the server's response explicitly grants it (Roblox's own automatic
	assignment picks by proximity, which is *often* but not always this
	client already). Rather than have the visible carry wait on that
	round trip, beginCarry spins up a fully local, throwaway CLONE of
	the ball — a part a LocalScript creates and parents itself is never
	replicated to anyone, so there's no NetworkOwner to wait on for it
	at all — and gives it the exact same AlignPosition pull the real
	ball will use. The ghost is shown in the real ball's place (the real
	one is hidden via LocalTransparencyModifier, a client-only cosmetic
	override, along with any value/price Gui it has) until ownership is
	actually confirmed, at which point the real ball's live CFrame/
	velocity is copied from the ghost so the swap is invisible, and the
	ghost is torn down. A release that comes in before that
	confirmation lands is queued rather than dropped, and fires the
	instant confirmation does.

	Grabbing and throwing each play a sound the same instant-local /
	server-relay way DashClient plays its dash sound: this script plays
	locally the instant its own action lands (grab: optimistically,
	before the server even responds, since a rejection is the rare
	exception, not the norm; throw: the moment a real release happens),
	and GrabHandler relays the same sound to everyone else.
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local WS = game:GetService("Workspace")
local RS = game:GetService("RunService")
local Rep = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local UpgradeData = require(Rep:WaitForChild("UpgradeData"))
local requestGrab = Rep:WaitForChild("RequestGrab")
local releaseGrab = Rep:WaitForChild("ReleaseGrab")
local ballTemplate = Rep:WaitForChild("Ball")

local grabUpgrade
for _, upgrade in ipairs(UpgradeData) do
	if upgrade.id == "grab" then
		grabUpgrade = upgrade
		break
	end
end
assert(grabUpgrade and grabUpgrade.tiers, "GrabClient: UpgradeData is missing a tiered 'grab' entry")

local GRAB_RANGE = 20 -- studs from the player's own HumanoidRootPart to the ball — NOT the camera. Kept a little under GrabHandler's own GRAB_RANGE so a passing local check is never rejected server-side
local RAYCAST_DISTANCE = 300 -- studs the cursor raycast itself is allowed to reach — aiming is camera-based even though eligibility (GRAB_RANGE) isn't
local THROW_SPEED = 90 -- flat strength every real throw releases at — letting go always throws at full force, no charge-up
local HOLD_CLEARANCE = 3 -- studs between the BOTTOM of a carried ball and HRP — see the RenderStepped loop below for why this isn't just a flat height
local HOLD_RESPONSIVENESS = 100 -- AlignPosition tightness; Roblox's own default
local HOLD_MAX_ACCEL = 10000 -- studs/s^2 the hold constraint can impart; finite so solid geometry can actually stop a carried ball
local REGRAB_DELAY = 0.35 -- ignore a just-released ball as a grab target for this long, so an instant re-aim doesn't just catch it back

-- keep in sync with GrabHandler's identical constants — duplicated
-- here (rather than sent over) so these can play with zero network
-- wait
local GRAB_SND_ID, GRAB_SND_VOL, GRAB_SND_PITCH = "rbxassetid://12222054", 0.3, 1.1
local THROW_SND_ID, THROW_SND_VOL = "rbxassetid://12222200", 0.5
local THROW_PITCH_MIN, THROW_PITCH_MAX = 1.1, 1.4 -- throw pitch is randomized per-throw within this range

-- Collision group names come from ReplicatedStorage.CollisionGroups,
-- the same module the server reads them from — so there is no second
-- spelling here to drift out of sync with GrabHandler/BallManager, which
-- is what used to risk two overlapping balls violently depenetrating.
-- Requiring it from a LocalScript is fine: registration and the rules
-- themselves are server-side (groups replicate down on their own), and
-- the client just gets the names and helpers.
--
-- Every assignment below goes through CG.assign / CG.assignDescendants
-- rather than writing .CollisionGroup directly, precisely BECAUSE this
-- is the client: a raw assignment throws outright if the group hasn't
-- replicated down yet (a real, if brief, window at the very start of a
-- session), which mid-beginCarry would abort the carry setup partway
-- through and leave the constraints half-built. The helper warns and
-- carries on instead.
--
-- beginCarry below flips these locally too, optimistically, same spirit
-- as the rest of tryGrab's prediction — without that, there'd be a
-- window (at least one full RequestGrab round trip) where the ball is
-- still in the regular Balls group, still fully collidable with the
-- player, while AlignPosition is already pulling it toward them.
local CG = require(Rep:WaitForChild("CollisionGroups"))

-- Upgrades folder replicates in from LeaderboardSetup the same way it
-- does for DashClient — checked fresh on every press rather than
-- cached, since it's cheap and this only ever runs on a keypress.
-- :IsA("IntValue") guard is defensive, same reasoning as ShopClient's
-- identical check.
local function currentGrabTier()
	local upgrades = player:FindFirstChild("Upgrades")
	local tierValue = upgrades and upgrades:FindFirstChild("grabTier")
	return (tierValue and tierValue:IsA("IntValue")) and tierValue.Value or 0
end

local heldBall -- the ball currently being carried, if any
local holdPart, ballAttachment, goalAttachment, alignPosition, renderConn
local carryingCharacter -- the character whose CollisionGroup beginCarry optimistically flipped, for stopCarry to revert
local justThrown = setmetatable({}, { __mode = "k" }) -- ball -> os.clock() of its last release

-- ghostPart is a fully local, throwaway clone of heldBall shown in its
-- place until ownershipConfirmed flips true — see beginCarry for why
-- the real ball can't just be moved directly from the moment input is
-- pressed. pendingReleaseSpeed holds a release that came in before
-- that confirmation landed, so it can be applied the instant it does.
local ghostPart, ghostAttachment, ghostAlign
local ownershipConfirmed
local pendingReleaseSpeed
local hiddenGuis -- BillboardGui/SurfaceGui children of the real ball, disabled while it's hidden — see beginCarry

-- A regular or radiant ball (by template name, same check BallManager
-- itself uses to separate balls from bombs/other specials) counts as a
-- valid target. This only answers "what's under the cursor" — it does
-- NOT check GRAB_RANGE, since the ray starts at the camera; see
-- tryGrab for the actual from-player distance check.
local function isGrabbableKind(name)
	return name == ballTemplate.Name
end

local function raycastGrabTarget()
	local camera = WS.CurrentCamera
	if not camera then return nil end

	local mouseLocation = UIS:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }

	local result = WS:Raycast(ray.Origin, ray.Direction.Unit * RAYCAST_DISTANCE, params)
	if not result or not isGrabbableKind(result.Instance.Name) then
		return nil
	end
	return result.Instance
end

-- rolled fresh per throw so repeated throws don't all sound identical.
local function randomThrowPitch()
	return math.random(THROW_PITCH_MIN * 100, THROW_PITCH_MAX * 100) / 100
end

-- shared local-sound helper — same "attached, plays instantly, doesn't
-- wait on any round trip" shape as DashClient's localDashSound.
local function playLocalSound(hrp, id, volume, pitch)
	local s = Instance.new("Sound")
	s.SoundId, s.Volume, s.PlaybackSpeed, s.Parent = id, volume, pitch, hrp
	s:Play()
	s.Ended:Connect(function() s:Destroy() end)
end

-- Undoes beginCarry's optimistic collision-group swap: without this, a
-- rejected grab, a drop, a ball vanishing mid-carry, or a respawn
-- mid-carry would leave the ball and/or the former holder's character
-- phased through each other locally until GrabHandler's own
-- authoritative reset happens to replicate back.
local function stopCarry(ball)
	if renderConn then renderConn:Disconnect() renderConn = nil end
	if alignPosition then alignPosition:Destroy() alignPosition = nil end
	if ballAttachment then ballAttachment:Destroy() ballAttachment = nil end
	if holdPart then holdPart:Destroy() holdPart = nil end
	if ghostAlign then ghostAlign:Destroy() ghostAlign = nil end
	if ghostAttachment then ghostAttachment:Destroy() ghostAttachment = nil end
	if ghostPart then ghostPart:Destroy() ghostPart = nil end
	ownershipConfirmed = nil
	pendingReleaseSpeed = nil

	if ball and ball.Parent then
		CG.assign(ball, CG.Balls)
		ball.LocalTransparencyModifier = 0 -- undo beginCarry's local-only hide, in case we're unwinding before ownership ever confirmed
	end
	if hiddenGuis then
		for _, gui in ipairs(hiddenGuis) do
			gui.Enabled = true
		end
		hiddenGuis = nil
	end
	if carryingCharacter then
		-- assignDescendants, not just the HumanoidRootPart: leaving an
		-- arm/leg/accessory behind means collision quietly keeps happening
		-- through it
		CG.assignDescendants(carryingCharacter, CG.Players)
		carryingCharacter = nil
	end
end

-- Builds the same Attachment + AlignPosition pull toward holdPart's
-- goalAttachment for whichever part is passed in — used for BOTH the
-- real ball (once ownership is confirmed) and the local-only ghost
-- (while it isn't), so the two never visibly move differently.
local function attachHoldPull(part)
	local attachment = Instance.new("Attachment")
	attachment.Parent = part

	local align = Instance.new("AlignPosition")
	align.Attachment0 = attachment
	align.Attachment1 = goalAttachment
	align.MaxForce = part:GetMass() * HOLD_MAX_ACCEL
	align.Responsiveness = HOLD_RESPONSIVENESS
	align.Parent = part

	return attachment, align
end

-- Copies the ghost's live CFrame/velocity onto `target` and tears the
-- ghost down, unhiding the real ball in its place. Shared by both
-- confirmation-time paths below (still being carried, or a release
-- that got queued while waiting on confirmation).
local function syncFromGhostAndReveal(target)
	local ghostCFrame = ghostPart and ghostPart.CFrame
	local ghostVelocity = ghostPart and ghostPart.AssemblyLinearVelocity
	if ghostAlign then ghostAlign:Destroy() ghostAlign = nil end
	if ghostAttachment then ghostAttachment:Destroy() ghostAttachment = nil end
	if ghostPart then ghostPart:Destroy() ghostPart = nil end

	target.LocalTransparencyModifier = 0
	if hiddenGuis then
		for _, gui in ipairs(hiddenGuis) do
			gui.Enabled = true
		end
		hiddenGuis = nil
	end

	if ghostCFrame then target.CFrame = ghostCFrame end
	target.AssemblyLinearVelocity = ghostVelocity or Vector3.new()
	target.AssemblyAngularVelocity = Vector3.new()
end

local function beginCarry(ball, hrp)
	heldBall = ball
	ownershipConfirmed = false
	pendingReleaseSpeed = nil

	-- flip collision groups locally right away, before anything below
	-- starts pulling — this can't wait on RequestGrab's round trip
	carryingCharacter = player.Character
	CG.assign(ball, CG.HeldBall)
	CG.assignDescendants(carryingCharacter, CG.GrabHolder)

	holdPart = Instance.new("Part")
	holdPart.Anchored = true
	holdPart.CanCollide = false
	holdPart.CanQuery = false
	holdPart.Transparency = 1
	holdPart.Size = Vector3.new(0.2, 0.2, 0.2)
	local radius = (ball:GetAttribute("TargetSize") or 0) / 2
	holdPart.Position = hrp.Position + Vector3.new(0, HOLD_CLEARANCE + radius, 0)
	holdPart.Parent = WS

	goalAttachment = Instance.new("Attachment")
	goalAttachment.Parent = holdPart

	-- Real ball's own pull: built now so its settings match the ghost's
	-- exactly, but left unattached from physics until ownership is
	-- confirmed — this client doesn't reliably have NetworkOwner yet.
	ballAttachment, alignPosition = attachHoldPull(ball)
	alignPosition.Enabled = false

	-- Stand-in for the real ball while ownership is unconfirmed: a
	-- throwaway, fully local clone, unanchored, with the same
	-- AlignPosition pull. Works because a part a LocalScript creates
	-- and parents itself is never replicated, so there's no
	-- NetworkOwner to contend for on it at all. Cloned AFTER the flip
	-- above, so it inherits CG.HeldBall and shares the real ball's
	-- passthrough rules while it stands in for it.
	ghostPart = ball:Clone()
	ghostPart.CanCollide = false
	ghostPart.CanQuery = false
	ghostPart.CanTouch = false
	for _, descendant in ipairs(ghostPart:GetDescendants()) do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		end
	end
	ghostPart.AssemblyLinearVelocity = Vector3.new()
	ghostPart.AssemblyAngularVelocity = Vector3.new()
	ghostPart.Parent = WS
	ghostAttachment, ghostAlign = attachHoldPull(ghostPart)

	-- Hide the real ball for this client only — LocalTransparencyModifier
	-- is a purely cosmetic, client-local override, unlike Transparency
	-- or CanCollide.
	ball.LocalTransparencyModifier = 1
	hiddenGuis = {}
	for _, child in ipairs(ball:GetChildren()) do
		if child:IsA("BillboardGui") or child:IsA("SurfaceGui") then
			table.insert(hiddenGuis, child)
			child.Enabled = false
		end
	end

	renderConn = RS.RenderStepped:Connect(function()
		-- ball vanished from under us (sold/destroyed some other way) —
		-- just drop cleanly, nothing left to throw or charge toward
		if not (heldBall and heldBall.Parent) then
			local ball = heldBall
			heldBall = nil
			stopCarry(ball)
			return
		end

		local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if not hrp then return end

		-- AlignPosition pulls toward the CENTER of this point, so a flat
		-- height here would mean bigger balls sit with their bottom much
		-- closer to (or clipping into) the ground/player. Adding the
		-- radius on top keeps the gap constant regardless of size.
		local radius = (heldBall:GetAttribute("TargetSize") or 0) / 2
		holdPart.Position = hrp.Position + Vector3.new(0, HOLD_CLEARANCE + radius, 0)
	end)
end

-- Does the actual work of a release (real throw or drop alike) on a
-- ball we're guaranteed to actually own by this point. The pitch is
-- rolled once here and sent along with the throw, so everyone hears
-- the same randomized pitch for a given throw.
local function finalizeRelease(ball, speed)
	-- Grabbed at the same instant, then input already come back up: a
	-- release fired this quickly can land before AlignPosition has
	-- actually lifted the ball up to HOLD_CLEARANCE — it's still
	-- sitting wherever it physically was when grabbed, often still at
	-- ground level with the camera aimed down at it. Firing a full
	-- THROW_SPEED launch from point-blank range on a downward-ish
	-- vector can tunnel through the platform in a single physics step
	-- instead of colliding with it. Never release from lower than the
	-- hold height a fully-settled carry would already have.
	local safeY = holdPart and holdPart.Position.Y

	stopCarry(ball)

	local throwPitch
	if ball.Parent then
		if safeY and ball.Position.Y < safeY then
			ball.CFrame = ball.CFrame + Vector3.new(0, safeY - ball.Position.Y, 0)
		end

		local camera = WS.CurrentCamera
		local direction = (camera and camera.CFrame.LookVector) or Vector3.new(0, 0, -1)

		ball.AssemblyAngularVelocity = Vector3.new()
		ball.AssemblyLinearVelocity = direction * speed
		justThrown[ball] = os.clock()

		if speed > 0 then
			throwPitch = randomThrowPitch()
			local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if hrp then playLocalSound(hrp, THROW_SND_ID, THROW_SND_VOL, throwPitch) end
		end
	end

	releaseGrab:FireServer(ball, speed, throwPitch)
end

-- shared release path for both a real throw and a drop — the only
-- difference is `speed` (THROW_SPEED for an actual release, 0 for the
-- respawn/AFK safety nets below).
local function releaseHeldBall(speed)
	local ball = heldBall
	if not ball then return end

	if not ownershipConfirmed then
		-- Input came up before RequestGrab's response (and the network
		-- ownership it grants) actually landed. Setting velocity on the
		-- ball right now would be a no-op — this client isn't
		-- simulating it yet. Queue it instead: the moment
		-- ownershipConfirmed flips true in tryGrab's task.spawn
		-- continuation, this exact release gets finalized there using
		-- the ball we're actually confirmed to own.
		pendingReleaseSpeed = speed
		return
	end

	heldBall = nil
	finalizeRelease(ball, speed)
end

local function tryGrab()
	if player:GetAttribute("AFK") then return end -- AFK players can't initiate a grab — GrabHandler enforces this too, this just saves the round trip
	if heldBall then return end -- already carrying — extra grab-input presses are no-ops until release

	local tier = currentGrabTier()
	if tier == 0 then return end -- upgrade not owned at all

	local target = raycastGrabTarget()
	if not target then return end

	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local lastRelease = justThrown[target]
	if lastRelease and os.clock() - lastRelease < REGRAB_DELAY then return end

	local maxSize = grabUpgrade.tiers[tier].maxSize
	local size = target:GetAttribute("TargetSize") or math.huge
	if size > maxSize then return end -- too big for the current tier — server would reject it anyway

	-- distance to the ball's SURFACE, not its center — matches
	-- GrabHandler's own check
	local radius = size / 2
	if (target.Position - hrp.Position).Magnitude - radius > GRAB_RANGE then return end

	-- Optimistically start carrying right away instead of waiting on
	-- RequestGrab's round trip: every check above mirrors what
	-- GrabHandler validates server-side, so agreement is the
	-- overwhelming common case — a rejection is a real exception, not
	-- the norm.
	playLocalSound(hrp, GRAB_SND_ID, GRAB_SND_VOL, GRAB_SND_PITCH)
	beginCarry(target, hrp)

	task.spawn(function()
		local ok = requestGrab:InvokeServer(target)
		-- Only act if we're still optimistically holding THIS ball.
		if heldBall ~= target then return end

		if not ok then
			heldBall = nil
			stopCarry(target)
			return
		end

		-- Network ownership is now ours.
		ownershipConfirmed = true

		if pendingReleaseSpeed then
			-- Input already came back up while we were waiting — sync
			-- the real ball onto the ghost's actual last position
			-- first, THEN finalize the release using the ball we're
			-- actually confirmed to own.
			local speed = pendingReleaseSpeed
			pendingReleaseSpeed = nil
			heldBall = nil
			syncFromGhostAndReveal(target)
			finalizeRelease(target, speed)
			return
		end

		-- Still being held — hand off from the ghost to the real ball.
		-- Copy the ghost's LIVE CFrame/velocity across rather than
		-- snapping straight to holdPart, since the ghost may still be
		-- mid-pull — matching that exact in-flight state is what makes
		-- the handoff invisible.
		syncFromGhostAndReveal(target)
		if alignPosition then alignPosition.Enabled = true end
	end)
end

local function isGrabInput(input)
	return input.KeyCode == Enum.KeyCode.E or input.UserInputType == Enum.UserInputType.MouseButton1
end

UIS.InputBegan:Connect(function(input, processed)
	if processed then return end
	if not isGrabInput(input) then return end
	if heldBall then return end -- already carrying — input is just being held, nothing new to do until it's released

	-- Left-click doubles as sell mode's own sell-click (see SellClient),
	-- so a grab shouldn't also fire off of it while sell mode is open —
	-- SellClient keeps this attribute live-updated on every toggle. E is
	-- untouched: it's not overloaded with a second meaning in sell mode,
	-- so it keeps working exactly as normal.
	if input.UserInputType == Enum.UserInputType.MouseButton1 and player:GetAttribute("SellMode") then
		return
	end

	tryGrab()
end)

-- deliberately not gated on `processed`/mouse-over-GUI the way
-- InputBegan is above — once a ball's actually being carried, letting
-- go should always throw it, even if the key-up happens to land over a
-- GUI element
UIS.InputEnded:Connect(function(input)
	if not isGrabInput(input) then return end
	if not heldBall then return end

	releaseHeldBall(THROW_SPEED)
end)

-- respawn mid-carry: the old character (and any UIS state tied to it)
-- is gone, so just drop whatever was held rather than trying to keep
-- carrying through a death — GrabHandler's own CharacterAdded hook
-- clears the server-side hold independently, this only needs to clean
-- up the client-side constraint/charge state
player.CharacterAdded:Connect(function()
	if heldBall then
		local ball = heldBall
		heldBall = nil
		stopCarry(ball)
		releaseGrab:FireServer(ball, 0)
	end
end)

-- going AFK mid-carry: same drop-cleanly shape as the respawn safety
-- net above
player:GetAttributeChangedSignal("AFK"):Connect(function()
	if player:GetAttribute("AFK") and heldBall then
		local ball = heldBall
		heldBall = nil
		stopCarry(ball)
		releaseGrab:FireServer(ball, 0)
	end
end)