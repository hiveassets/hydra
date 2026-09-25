--[[
    PlayerTilt (LocalScript)
    Path: StarterPlayer → StarterCharacterScripts
    Parent: StarterCharacterScripts
    Properties:
        Disabled: false
    Exported: 2026-09-25 02:23:36
]]
--[[
    PlayerTilt (LocalScript)
    Path: StarterPlayer → StarterCharacterScripts
    Parent: StarterCharacterScripts
    Properties:
        Disabled: false
    Exported: 2026-09-24 20:25:15
]]
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
-- ── diagnostics (temporary) ───────────────────────────────────────────
-- Press F7 while the tilt is misbehaving and a snapshot of everything it
-- depends on goes to the output (F9 in a live game). It's there to catch
-- the broken-tilt bug in the act; take it out once that's found.
local UserInputService = game:GetService("UserInputService")

local function angles(cf)
	local x, y, z = cf:ToEulerAnglesXYZ()
	return ("(%.0f°, %.0f°, %.0f°)"):format(math.deg(x), math.deg(y), math.deg(z))
end

local function vec(v)
	return ("(%.2f, %.2f, %.2f)"):format(v.X, v.Y, v.Z)
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.KeyCode ~= Enum.KeyCode.F7 then
		return
	end

	local joints, tilts = {}, 0
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("Motor6D") and (d.Name == "RootJoint" or d.Name == "Root") then
			table.insert(joints, ("%s in %s: %s -> %s, enabled=%s, C0 %s")
				:format(d.Name, d.Parent and d.Parent.Name or "?",
					d.Part0 and d.Part0.Name or "nil", d.Part1 and d.Part1.Name or "nil",
					tostring(d.Enabled), angles(d.C0)))
		end
		if d:IsA("LocalScript") and d.Name == script.Name then
			tilts += 1
		end
	end

	local touching = {}
	for _, p in ipairs(root:GetTouchingParts()) do
		table.insert(touching, ("%s%s"):format(p:GetFullName(), p.CanCollide and "" or " (non-solid)"))
	end

	local torso = char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso")
	print(table.concat({
		"[PlayerTilt] snapshot",
		("rig %s, state %s, health %.0f, PlatformStand %s, AutoRotate %s"):format(
			humanoid.RigType.Name, humanoid:GetState().Name, humanoid.Health,
			tostring(humanoid.PlatformStand), tostring(humanoid.AutoRotate)),
		("root up %s look %s, velocity %s, spin %s, anchored %s"):format(
			vec(root.CFrame.UpVector), vec(root.CFrame.LookVector),
			vec(root.AssemblyLinearVelocity), vec(root.AssemblyAngularVelocity), tostring(root.Anchored)),
		torso and ("torso up %s"):format(vec(torso.CFrame.UpVector)) or "no torso",
		("RootJoint now %s, captured at spawn %s, joint is still ours: %s"):format(
			angles(rootJoint.C0), angles(originalC0), tostring(rootJoint.Parent == root)),
		("lean %s, spinAngle %.1f°, falling speed %.1f"):format(
			angles(leanCFrame), math.deg(spinAngle), -root.AssemblyLinearVelocity.Y),
		("PlayerTilt copies in character: %d"):format(tilts),
		"joints: " .. (#joints > 0 and table.concat(joints, " | ") or "none"),
		"root touching: " .. (#touching > 0 and table.concat(touching, ", ") or "nothing"),
		("gravity %.1f, FloorMaterial %s"):format(workspace.Gravity, humanoid.FloorMaterial.Name),
	}, "\n  "))
end)