--[[
    PillarDecorClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-24 20:25:14
]]
--[[
    PillarDecorClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-23 02:07:55
]]
--[[
    PillarDecorClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-22 18:28:58
]]
--[[
	PillarDecorClient (LocalScript) — place in StarterPlayerScripts
	(StarterPlayer.StarterPlayerScripts.PillarDecorClient).

	Replaces PillarBallDecor (ServerScriptService), which is deleted.

	Every few seconds there's a chance an orb appears on top of one of
	the background pillars and rolls off into the distance. Pure
	ambience: these are not on anyone's board, they're worth nothing,
	they can't be sold or grabbed, and they clean themselves up.

	WHY IT MOVED TO THE CLIENT

	The old version span these up on the server, which made each one a
	replicated physics part: simulated somewhere, streamed to everyone,
	and handed a network owner by proximity like any other unanchored
	part. That's real traffic and real simulation cost for something
	nobody interacts with. Here every player gets their own, on their own
	machine, and nothing about them crosses the network.

	The numbers, the collision group and the "strip the size label"
	detail are all carried over unchanged.
]]

local Workspace = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local CG = require(Rep:WaitForChild("CollisionGroups"))

local COLLIDER_NAME = "bgpillarcollider"
local CHECK_INTERVAL = 20
local SPAWN_CHANCE = 0.3
local MIN_SIZE, MAX_SIZE = 3, 20
local ROLL_SPEED = 40      -- gentle horizontal-only push, studs/sec
local DESTROY_AFTER = 20   -- plenty of time to roll off and fall out of sight

local ballTemplate = Rep:WaitForChild("Ball")

local folder = Instance.new("Folder")
folder.Name = "PillarDecorLocal"
folder.Parent = Workspace

-- live set of pillar colliders, so a random pick always lands on
-- something that still exists
local colliders = {}

local function track(instance)
	if instance.Name == COLLIDER_NAME and instance:IsA("BasePart") then
		colliders[instance] = true
		instance.AncestryChanged:Connect(function(_, parent)
			if not parent then
				colliders[instance] = nil
			end
		end)
	end
end

for _, instance in ipairs(Workspace:GetDescendants()) do
	track(instance)
end
Workspace.DescendantAdded:Connect(track)

local function randomCollider()
	local pool = {}
	for collider in pairs(colliders) do
		table.insert(pool, collider)
	end
	if #pool == 0 then
		return nil
	end
	return pool[math.random(#pool)]
end

local function spawnOnPillar(collider)
	local size = math.random(MIN_SIZE, MAX_SIZE)

	local ball = ballTemplate:Clone()
	ball.Anchored, ball.CanCollide = false, true
	-- the BG group, so it can land on and roll off the pillars while
	-- staying entirely out of the way of anything on the board
	CG.assign(ball, CG.BG)
	ball.Size = Vector3.new(size, size, size)
	ball.Color = Color3.fromHSV(math.random(), 0.5 + math.random() * 0.5, 0.75 + math.random() * 0.25)

	-- the collider's own Y plus a stud, then up by half the ball's size
	-- so its BOTTOM clears that point rather than its centre
	local spawnY = collider.Position.Y + 1 + size / 2
	ball.CFrame = CFrame.new(collider.Position.X, spawnY, collider.Position.Z)

	-- strip the size readout outright rather than blanking it: a
	-- background orb is never grabbable or sellable, so a number on it
	-- would just be a lie
	local display = ball:FindFirstChild("display")
	if display then
		display:Destroy()
	end

	ball.Parent = folder

	-- horizontal only, so gravity does the falling and this only decides
	-- which way it rolls off
	local angle = math.random() * math.pi * 2
	ball.AssemblyLinearVelocity = Vector3.new(math.cos(angle) * ROLL_SPEED, 0, math.sin(angle) * ROLL_SPEED)

	Debris:AddItem(ball, DESTROY_AFTER)
end

task.spawn(function()
	while true do
		task.wait(CHECK_INTERVAL)
		if math.random() < SPAWN_CHANCE then
			local collider = randomCollider()
			if collider then
				spawnOnPillar(collider)
			end
		end
	end
end)
