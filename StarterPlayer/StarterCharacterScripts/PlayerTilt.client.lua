--[[
    PlayerTilt (LocalScript)
    Path: StarterPlayer → StarterCharacterScripts
    Parent: StarterCharacterScripts
    Properties:
        Disabled: false
    Exported: 2026-09-23 02:07:56
]]
--[[
    PlayerTilt (LocalScript)
    Path: StarterPlayer → StarterCharacterScripts
    Parent: StarterCharacterScripts
    Properties:
        Disabled: false
    Exported: 2026-09-22 20:42:27
]]
local RunService = game:GetService("RunService")

local char = script.Parent
local humanoid = char:WaitForChild("Humanoid")
local root = char:WaitForChild("HumanoidRootPart")
local rootJoint = root:WaitForChild("RootJoint")

local originalC0 = rootJoint.C0

-- Horizontal lean tuning
local SPEED_FOR_UNIT_TILT = 60       -- higher = more speed needed per degree = subtler
local TILT_SCALE = 0.35               -- extra scale-down on top of that, independent knob
local MIN_SPEED = 2
local LEAN_EASE_RATE = 15             -- higher = faster ease toward target lean

-- Fall spin tuning
local FALL_SPEED_FOR_MIN_SPIN = 50
local SPIN_RAMP_SPEED = 1000
local MAX_SPIN_RATE = math.rad(1440)

local function isTouchingSolidGeometry()
	for _, part in ipairs(root:GetTouchingParts()) do
		if part.CanCollide and not part:IsDescendantOf(char) then
			return true
		end
	end
	return false
end

local leanCFrame = CFrame.new()
local spinAngle = 0
local spinDirection = 1

local connection
connection = RunService.Heartbeat:Connect(function(dt)
	if not rootJoint.Parent or humanoid.Health <= 0 then
		if connection then connection:Disconnect() end
		return
	end

	if isTouchingSolidGeometry() then
		local alpha = 1 - math.exp(-LEAN_EASE_RATE * dt)
		leanCFrame = leanCFrame:Lerp(CFrame.new(), alpha)
		spinAngle = 0
		rootJoint.C0 = rootJoint.C0:Lerp(originalC0 * leanCFrame, alpha)
		return
	end

	local fullVelocity = root.Velocity
	local horizontalVel = fullVelocity * Vector3.new(1, 0, 1)
	local horizSpeed = horizontalVel.Magnitude
	local fallSpeed = -fullVelocity.Y

	-- Target lean from current velocity (pitch = forward/back, yaw = turning)
	local pitchAngle, yawAngle = 0, 0
	if horizSpeed > MIN_SPEED then
		local dir = horizontalVel.Unit
		local strength = math.atan(horizSpeed / SPEED_FOR_UNIT_TILT) * TILT_SCALE
		pitchAngle = root.CFrame.LookVector:Dot(dir) * strength
		yawAngle = root.CFrame.RightVector:Dot(dir) * strength
	end
	local targetLean = CFrame.Angles(pitchAngle, -yawAngle, 0)

	-- Ease current lean toward target, frame-rate independent, exponential-out
	local alpha = 1 - math.exp(-LEAN_EASE_RATE * dt)
	leanCFrame = leanCFrame:Lerp(targetLean, alpha)

	-- Spin accumulates directly, no smoothing -- smoothing this is what caused the jolt
	if fallSpeed > FALL_SPEED_FOR_MIN_SPIN then
		if spinAngle == 0 then
			-- Starting a new spin: decide direction once from current facing.
			local horizLook = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
			local posFromOrigin = Vector3.new(root.Position.X, 0, root.Position.Z)
			if horizLook.Magnitude > 0.01 and posFromOrigin.Magnitude > 0.01 then
				-- Facing away from origin (looking outward) -> spin forward (+1)
				-- Facing toward origin (looking inward) -> spin backward (-1)
				spinDirection = horizLook.Unit:Dot(posFromOrigin.Unit) >= 0 and 1 or -1
			else
				spinDirection = 1
			end
		end
		local spinRate = math.clamp(fallSpeed / SPIN_RAMP_SPEED, 0, 1) * MAX_SPIN_RATE
		spinAngle += spinDirection * spinRate * dt
	else
		spinAngle = 0
	end
	local spin = CFrame.Angles(spinAngle, 0, 0)

	rootJoint.C0 = leanCFrame and (originalC0 * leanCFrame * spin) or (originalC0 * spin)
end)