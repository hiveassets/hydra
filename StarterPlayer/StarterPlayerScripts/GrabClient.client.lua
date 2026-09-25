--[[
    GrabClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-25 02:23:35
]]
--[[
    GrabClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-23 02:07:55
]]
--[[
    GrabClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-22 18:28:58
]]
--[[
	GrabClient (LocalScript) — StarterPlayerScripts

	Pick up an orb, carry it, throw it. E or left click to grab, let go
	to throw along the camera's look vector at full strength.

	REBUILT, v3 — and this time by deleting things.

	v1 had the server own a held ball's motion. That killed the
	ownership races and cost everything else: the ball dragged behind
	its holder, grabbing felt slow, and a throw could drop the ball on
	the spot because the throw velocity hadn't replicated before
	ownership moved on.

	v2 moved the carry back to the client and then spent about 200 lines
	hiding the fact that the client didn't actually own the ball yet:

	  * RequestGrab, a RemoteFunction the whole grab waited on
	  * a fully local throwaway CLONE of the ball, shown in its place
	    with its own copy of the carry rig, because AlignPosition can't
	    move a part this machine doesn't own
	  * LocalTransparencyModifier to hide the real ball behind it, and a
	    list of its GUIs to disable and restore
	  * syncFromGhostAndReveal, to copy the ghost's live position and
	    velocity onto the real ball at the moment ownership confirmed,
	    so the swap was invisible
	  * pendingReleaseSpeed, because you can let go before the server
	    answers, and that throw had to be queued and replayed
	  * OWNERSHIP_RELEASE_DELAY on the server, holding ownership for a
	    beat after a throw so the velocity landed first

	Every one of those exists to paper over one sentence: the ball
	belongs to someone else. It doesn't any more. The orb under your
	cursor is a part your own machine made, so picking it up is just
	attaching a constraint, and throwing it is just setting a velocity.
	None of the above survives, GrabHandler is deleted, and the two
	remotes it owned are gone.

	WHAT THE SERVER STILL HEARS

	Two things, neither of which is permission:

	  * hold and release, so the orb cap doesn't auto-sell the ball out
	    of your hands (see Board's _enforceCap)
	  * a trick shot, so it can hand out the badge

	Grab tiers are read straight off the player's own Upgrades folder.
	There's nothing to validate: a tier the player doesn't own only ever
	lets them carry their own orb around their own board, and the orb is
	worth exactly what the ledger says either way.
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("RunService")
local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

local UpgradeData = require(Rep:WaitForChild("UpgradeData"))
local Config = require(Rep:WaitForChild("BoardConfig"))
local CG = require(Rep:WaitForChild("CollisionGroups"))
local ClientBoard = require(script.Parent:WaitForChild("ClientBoard"))

local ballTemplate = Rep:WaitForChild("Ball")

local grabUpgrade
for _, upgrade in ipairs(UpgradeData) do
	if upgrade.id == "grab" then
		grabUpgrade = upgrade
		break
	end
end
assert(grabUpgrade and grabUpgrade.tiers, "GrabClient: UpgradeData is missing a tiered 'grab' entry")

local GRAB_RANGE = Config.GRAB_RANGE
local THROW_SPEED = Config.THROW_SPEED
local HOLD_CLEARANCE = Config.HOLD_CLEARANCE
local REGRAB_DELAY = Config.REGRAB_DELAY

local RAYCAST_DISTANCE = 300   -- how far the cursor ray reaches; eligibility is measured from the player, not the camera
local HOLD_RESPONSIVENESS = 100
local HOLD_MAX_ACCEL = 10000   -- finite, so solid geometry can still stop a carried ball

local GRAB_SND_ID, GRAB_SND_VOL, GRAB_SND_PITCH = "rbxassetid://12222054", 0.3, 1.1
local THROW_SND_ID, THROW_SND_VOL = "rbxassetid://12222200", 0.5
local THROW_PITCH_MIN, THROW_PITCH_MAX = 1.1, 1.4

local heldBall
local holdPart, ballAttachment, goalAttachment, alignPosition, renderConn
local carryingCharacter
local justThrown = setmetatable({}, { __mode = "k" }) -- ball -> os.clock() of its last release

local function currentGrabTier()
	local upgrades = player:FindFirstChild("Upgrades")
	local tierValue = upgrades and upgrades:FindFirstChild("grabTier")
	return (tierValue and tierValue:IsA("IntValue")) and tierValue.Value or 0
end

-- Regular and radiant balls only, by template name — the same check
-- everything else in the game uses to tell an orb from a special.
local function isGrabbableKind(name)
	return name == ballTemplate.Name
end

local function raycastGrabTarget()
	local camera = WS.CurrentCamera
	if not camera then
		return nil
	end

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

local function randomThrowPitch()
	return math.random(THROW_PITCH_MIN * 100, THROW_PITCH_MAX * 100) / 100
end

local function playLocalSound(parent, id, volume, pitch)
	local s = Instance.new("Sound")
	s.SoundId, s.Volume, s.PlaybackSpeed, s.Parent = id, volume, pitch, parent
	s:Play()
	s.Ended:Connect(function()
		s:Destroy()
	end)
end

-- ── the trick shot ────────────────────────────────────────────────────
-- A throw released from the pad in the middle of the platform that then
-- clears the edge without touching anything. This used to be watched by
-- the server, which could see the ball; now the client watches its own
-- throw and reports it. The server checks that the thrower was standing
-- on the pad, which is the half it can still see — see BoardService.
local function watchTrickShot(ball)
	local touched, heartbeat
	local done = false

	local function stop()
		if done then
			return
		end
		done = true
		if touched then
			touched:Disconnect()
		end
		if heartbeat then
			heartbeat:Disconnect()
		end
	end

	touched = ball.Touched:Connect(function(hit)
		local character = player.Character
		if character and hit:IsDescendantOf(character) then
			return -- your own body doesn't spoil it
		end
		stop()
	end)

	heartbeat = RS.Heartbeat:Connect(function()
		if not ball.Parent then
			stop() -- gone before it cleared the edge
			return
		end
		if ball.Position.Y < Config.TRICK_SHOT_Y then
			stop()
			ClientBoard.reportTrickShot()
		end
	end)
end

-- ── carrying ──────────────────────────────────────────────────────────

local function stopCarry(ball)
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	if alignPosition then
		alignPosition:Destroy()
		alignPosition = nil
	end
	if ballAttachment then
		ballAttachment:Destroy()
		ballAttachment = nil
	end
	if holdPart then
		holdPart:Destroy()
		holdPart = nil
	end

	if ball and ball.Parent then
		CG.assign(ball, CG.Balls)
		ClientBoard.release(ball)
	end

	if carryingCharacter then
		-- assignDescendants, not just the root: an arm or an accessory
		-- left behind keeps colliding on its own.
		CG.assignDescendants(carryingCharacter, player:GetAttribute("AFK") and CG.AFKPlayers or CG.Players)
		carryingCharacter = nil
	end
end

local function beginCarry(ball, hrp)
	heldBall = ball

	-- HeldBall passes through the other orbs and through the person
	-- carrying it, so a carried orb doesn't shove its owner around or
	-- plough through the pile.
	carryingCharacter = player.Character
	CG.assign(ball, CG.HeldBall)
	CG.assignDescendants(carryingCharacter, CG.GrabHolder)

	ClientBoard.hold(ball)

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

	ballAttachment = Instance.new("Attachment")
	ballAttachment.Parent = ball

	alignPosition = Instance.new("AlignPosition")
	alignPosition.Attachment0 = ballAttachment
	alignPosition.Attachment1 = goalAttachment
	alignPosition.MaxForce = ball:GetMass() * HOLD_MAX_ACCEL
	alignPosition.Responsiveness = HOLD_RESPONSIVENESS
	alignPosition.Parent = ball

	renderConn = RS.RenderStepped:Connect(function()
		-- the ball went out from under us: sold, collapsed, auto-sold
		if not (heldBall and heldBall.Parent) then
			local gone = heldBall
			heldBall = nil
			stopCarry(gone)
			return
		end

		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if not root then
			return
		end

		-- AlignPosition pulls toward the CENTRE of the goal, so a flat
		-- height would let a big orb sit with its bottom in the floor.
		-- Adding the radius keeps the gap the same at every size.
		local r = (heldBall:GetAttribute("TargetSize") or 0) / 2
		holdPart.Position = root.Position + Vector3.new(0, HOLD_CLEARANCE + r, 0)
	end)
end

-- speed 0 is a drop (the respawn and AFK nets below), anything else is
-- a real throw.
local function releaseHeldBall(speed)
	local ball = heldBall
	if not ball then
		return
	end
	heldBall = nil

	-- A release this fast can land before the carry has lifted the ball
	-- to its hold height — it's still sitting where it was grabbed,
	-- often on the floor with the camera aimed down at it. A full-speed
	-- throw from there can tunnel straight through the platform in one
	-- physics step.
	local safeY = holdPart and holdPart.Position.Y

	stopCarry(ball)

	if not ball.Parent then
		return
	end

	if safeY and ball.Position.Y < safeY then
		ball.CFrame = ball.CFrame + Vector3.new(0, safeY - ball.Position.Y, 0)
	end

	local camera = WS.CurrentCamera
	local direction = (camera and camera.CFrame.LookVector) or Vector3.new(0, 0, -1)

	ball.AssemblyAngularVelocity = Vector3.new()
	ball.AssemblyLinearVelocity = direction * speed
	justThrown[ball] = os.clock()

	if speed > 0 then
		-- Marks it as a throw, for anything it might hit on the way. An
		-- awake mimic reads this to decide whether the orb that just
		-- touched it was thrown at it (and knocks itself back), or merely
		-- rolled into it. Only a real throw, not a drop; the mimic clears
		-- it when it uses it, so one throw is one knock.
		ball:SetAttribute("ThrownAt", os.clock())
		local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if hrp then
			playLocalSound(hrp, THROW_SND_ID, THROW_SND_VOL, randomThrowPitch())

			local from = hrp.Position
			if Vector2.new(from.X, from.Z).Magnitude <= Config.TRICK_ZONE_RADIUS then
				watchTrickShot(ball)
			end
		end
	end
end

local function tryGrab()
	if player:GetAttribute("AFK") then
		return
	end
	if ClientBoard.isPaused() or ClientBoard.isCollapsing() then
		return
	end
	if heldBall then
		return -- already carrying; extra presses do nothing until release
	end

	local tier = currentGrabTier()
	if tier == 0 then
		return -- upgrade not owned
	end

	local target = raycastGrabTarget()
	if not target then
		return
	end
	if not ClientBoard.entryOf(target) then
		return -- not one of this board's orbs (a decor ball, say)
	end

	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end

	local lastRelease = justThrown[target]
	if lastRelease and os.clock() - lastRelease < REGRAB_DELAY then
		return -- just thrown; don't catch it straight back
	end

	local maxSize = grabUpgrade.tiers[tier].maxSize
	local size = target:GetAttribute("TargetSize") or math.huge
	if size > maxSize then
		return -- too big for this tier
	end

	-- distance to the orb's SURFACE, not its centre: measuring to the
	-- centre silently eats a whole radius of range on a big one.
	if (target.Position - hrp.Position).Magnitude - size / 2 > GRAB_RANGE then
		return
	end

	playLocalSound(hrp, GRAB_SND_ID, GRAB_SND_VOL, GRAB_SND_PITCH)
	beginCarry(target, hrp)
end

-- ── input ─────────────────────────────────────────────────────────────

local function isGrabInput(input)
	return input.KeyCode == Enum.KeyCode.E or input.UserInputType == Enum.UserInputType.MouseButton1
end

UIS.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if not isGrabInput(input) then
		return
	end
	if heldBall then
		return
	end

	-- Left click is also sell mode's sell-click (see SellClient), so a
	-- grab shouldn't fire off it while sell mode is open. E isn't
	-- overloaded, so it keeps working either way.
	if input.UserInputType == Enum.UserInputType.MouseButton1 and player:GetAttribute("SellMode") then
		return
	end

	tryGrab()
end)

-- Deliberately not gated on `processed`: once an orb is actually being
-- carried, letting go should always throw it, even if the key-up lands
-- over a GUI element.
UIS.InputEnded:Connect(function(input)
	if not isGrabInput(input) then
		return
	end
	if not heldBall then
		return
	end
	releaseHeldBall(THROW_SPEED)
end)

-- Respawning mid-carry: the old character is gone, so drop cleanly
-- rather than trying to carry through a death.
player.CharacterAdded:Connect(function()
	if heldBall then
		releaseHeldBall(0)
	end
end)

-- Going AFK mid-carry: same thing. The board is about to freeze
-- underneath us anyway.
player:GetAttributeChangedSignal("AFK"):Connect(function()
	if player:GetAttribute("AFK") and heldBall then
		releaseHeldBall(0)
	end
end)
