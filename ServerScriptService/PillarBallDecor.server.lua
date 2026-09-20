--[[
    PillarBallDecor (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-20 20:00:08
]]
--[[
	PillarBallDecor (Script) — ServerScriptService

	Purely cosmetic ambiance: every ~30s (with some jitter), there's a
	10% chance a ball spawns on top of a random "bgpillarcollider" part
	in the workspace and rolls off into the void in the distance.
	Deliberately has nothing to do with BallManager's economy — these
	balls aren't parented into the Balls folder, don't count toward
	MAX_BALLS, don't trigger enforceBallCap or the attach sound, and are
	never tracked/split/sold. They just clean themselves up on a flat
	timer once they've had plenty of time to fall.

	One shared timer/roll (not one per pillar) — a single 10% check every
	cycle, and only on a hit does it pick one random collider to spawn on.
]]

local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

-- config
local COLLIDER_NAME = "bgpillarcollider"
local CHECK_INTERVAL, CHECK_JITTER = 5, 0   -- ~5s between rolls, +/- up to CHECK_JITTER
local SPAWN_CHANCE = 0.5                     -- 50% chance per roll
local MIN_SIZE, MAX_SIZE = 3, 20             -- regular balls only, no specials
local ROLL_SPEED = 40                        -- gentle horizontal-only push, studs/sec
local DESTROY_AFTER = 20                     -- seconds; plenty of time to roll off and fall out of sight

local ballT = Rep:WaitForChild("Ball")

-- the BG group (and the rule keeping economy balls out of it) is
-- declared in ReplicatedStorage.CollisionGroups. This script used to
-- rely on BallManager having registered BG defensively before it ran;
-- requiring the module removes that ordering dependency entirely.
local CG = require(Rep:WaitForChild("CollisionGroups"))

local decorFolder = WS:FindFirstChild("PillarBallDecor") or Instance.new("Folder")
decorFolder.Name, decorFolder.Parent = "PillarBallDecor", WS

-- live list of every bgpillarcollider currently in the workspace, kept
-- in sync below so a random pick always lands on something real
local colliders = {}

local function trackCollider(obj)
	if obj.Name == COLLIDER_NAME and obj:IsA("BasePart") then
		colliders[obj] = true
		obj.AncestryChanged:Connect(function(_, parent)
			if not parent then
				colliders[obj] = nil
			end
		end)
	end
end

for _, obj in ipairs(WS:GetDescendants()) do
	trackCollider(obj)
end
WS.DescendantAdded:Connect(trackCollider)

local function randColor()
	return Color3.fromHSV(math.random(), 0.5 + math.random() * 0.5, 0.75 + math.random() * 0.25)
end

-- picks one collider out of the live set with equal odds
local function randomCollider()
	local n = 0
	for _ in pairs(colliders) do
		n += 1
	end
	if n == 0 then
		return nil
	end
	local pick = math.random(n)
	local i = 0
	for obj in pairs(colliders) do
		i += 1
		if i == pick then
			return obj
		end
	end
end

-- spawns one plain regular ball resting 1 stud above the collider, gives
-- it a gentle horizontal-only shove, and then just lets physics take it
-- from there — entirely separate from BallManager's queue/tracking/
-- Balls folder, so it can't trip the cap, a split, or a badge.
local function spawnOnPillar(collider)
	local size = math.random(MIN_SIZE, MAX_SIZE)

	local ball = ballT:Clone()
	ball.Anchored, ball.CanCollide = false, true
	CG.assign(ball, CG.BG) -- matches the pillar colliders' group so it can actually land on/roll off them
	ball.Size = Vector3.new(size, size, size)
	ball.Color = randColor()
	-- collider's own Y coordinate + 1 stud, then pushed up by half the
	-- ball's size so the ball's *bottom* clears that point by 1 stud
	-- instead of its center (which would bury half the ball in the
	-- collider for anything bigger than size 2)
	local spawnY = collider.Position.Y + 1 + size / 2
	ball.CFrame = CFrame.new(collider.Position.X, spawnY, collider.Position.Z)

	-- strip the size readout entirely (destroy it, don't just blank the
	-- text) — a background ball rolling off a pillar is never grabbable
	-- or sellable, so a size label on it would just be misleading
	local display = ball:FindFirstChild("display")
	if display then
		display:Destroy()
	end

	ball.Parent = decorFolder

	-- horizontal-only kick (Y left at 0) so gravity does the falling and
	-- this only decides which way it rolls off
	local angle = math.random() * math.pi * 2
	ball.AssemblyLinearVelocity = Vector3.new(math.cos(angle) * ROLL_SPEED, 0, math.sin(angle) * ROLL_SPEED)

	Debris:AddItem(ball, DESTROY_AFTER)
end

-- single shared loop: one roll every ~30s (jittered), and only on a hit
-- does it pick a random collider to spawn on
task.spawn(function()
	while true do
		task.wait(CHECK_INTERVAL + (math.random() * 2 - 1) * CHECK_JITTER)
		if math.random() < SPAWN_CHANCE then
			local collider = randomCollider()
			if collider then
				spawnOnPillar(collider)
			end
		end
	end
end)