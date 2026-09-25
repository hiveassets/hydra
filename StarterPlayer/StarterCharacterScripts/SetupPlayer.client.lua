--[[
    SetupPlayer (LocalScript)
    Path: StarterPlayer → StarterCharacterScripts
    Parent: StarterCharacterScripts
    Properties:
        Disabled: false
    Exported: 2026-09-25 02:23:36
]]
--[[
    SetupPlayer (LocalScript)
    Path: StarterPlayer → StarterCharacterScripts
    Parent: StarterCharacterScripts
    Properties:
        Disabled: false
    Exported: 2026-09-24 20:25:15
]]
--[[
    SetupPlayer (LocalScript)
    Path: StarterPlayer → StarterCharacterScripts
    Parent: StarterCharacterScripts
    Properties:
        Disabled: false
    Exported: 2026-09-23 02:07:56
]]
--[[
    SetupPlayer (LocalScript)
    Path: StarterPlayer → StarterCharacterScripts
    Parent: StarterCharacterScripts
    Properties:
        Disabled: false
    Exported: 2026-09-22 20:42:27
]]
local Character = script.Parent
local Humanoid = Character:WaitForChild("Humanoid")

-- Disable states that could interfere with your custom systems
local STATES_TO_DISABLE = {
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.Physics,
	Enum.HumanoidStateType.Climbing,
}

for _, state in ipairs(STATES_TO_DISABLE) do
	Humanoid:SetStateEnabled(state, false)
end

-- Disable auto jump
Humanoid.AutoJumpEnabled = false
-- ── staying upright ───────────────────────────────────────────────────
-- With FallingDown and Ragdoll disabled above, a character that gets
-- tipped over has no way back up: GettingUp, the state that rights it,
-- only ever follows those two. So a hard enough knock — a pile of big
-- orbs, a radiant magnet slinging one into you, a dash into something
-- heavy — can leave the root part lying on its side for good. Everything
-- looks subtly wrong from then on, and PlayerTilt, which leans and spins
-- the body relative to the root, leans the wrong way and spins sideways
-- instead of end over end. Only a reset fixed it.
--
-- So this rights it. If the root has been more than about 25° off
-- vertical for a moment, it's eased back upright, keeping the direction
-- it was facing, and its tumble is taken off. A normal wobble never
-- gets near the threshold, and PlayerTilt's own lean and spin never
-- touch the root at all (they're on the root joint), so this doesn't
-- fight either of them.
local RunService = game:GetService("RunService")

local root = Character:WaitForChild("HumanoidRootPart")

local TIPPED_UP_Y = math.cos(math.rad(25)) -- the root's UpVector.Y below this counts as tipped
local TIPPED_FOR = 0.15                     -- seconds tipped before it steps in
local RIGHTING_RATE = 20                    -- higher = snaps back faster

local tippedFor = 0

local righting
righting = RunService.Heartbeat:Connect(function(dt)
	if not root.Parent or Humanoid.Health <= 0 then
		righting:Disconnect()
		return
	end
	if root.Anchored or Humanoid.Sit then
		tippedFor = 0
		return
	end

	local cf = root.CFrame
	if cf.UpVector.Y >= TIPPED_UP_Y then
		tippedFor = 0
		return
	end

	tippedFor += dt
	if tippedFor < TIPPED_FOR then
		return
	end

	-- Upright, facing the way it was facing. If it's lying so its look
	-- direction points straight up or down, fall back to its up vector
	-- (which is then lying flat) for a heading.
	local look = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	if look.Magnitude < 0.1 then
		look = Vector3.new(cf.UpVector.X, 0, cf.UpVector.Z)
	end
	if look.Magnitude < 0.1 then
		look = Vector3.new(0, 0, -1)
	end
	local upright = CFrame.lookAt(cf.Position, cf.Position + look.Unit)

	local alpha = 1 - math.exp(-RIGHTING_RATE * dt)
	root.CFrame = cf:Lerp(upright, alpha)

	-- Keep only the spin about vertical: the tumble is what tipped it.
	local spin = root.AssemblyAngularVelocity
	root.AssemblyAngularVelocity = Vector3.new(0, spin.Y, 0)
end)