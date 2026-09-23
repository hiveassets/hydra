--[[
    DecorSpinClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-23 00:26:23
]]
--[[
    DecorSpinClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-22 18:28:58
]]
--[[
	DecorSpinClient (LocalScript) — place in StarterPlayerScripts
	(StarterPlayer.StarterPlayerScripts.DecorSpinClient).

	Spins every piece of decorative geometry that asks to be spun, and
	kicks each one a little every time an orb spawns.

	REPLACES SEVEN COPIES OF THE SAME SCRIPT

	There was a `Spin` (or `SpinModel`) Script sitting inside each piece:
	the spawn symbol, a baseplate part, two rings, a square, a couple of
	models. Fifteen lines each, identical apart from two numbers, and
	each one separately connected to Heartbeat and to the Balls folder.
	They also all broke at once when the board moved to the client,
	because every one of them opened with `workspace:WaitForChild("Balls")`
	and that folder no longer exists on the server.

	This is one script, on the client, doing all of them. The two
	numbers that actually differed per piece are attributes now:

	    SpinSpeed   — degrees per second at rest (negative spins the
	                  other way)
	    SpinBoost   — degrees per second added on each orb spawn, decaying
	                  over SPIN_BOOST_TIME

	Anything in the workspace carrying a SpinSpeed attribute spins. That
	means adding a new spinning piece is setting two attributes in the
	Properties panel, with no script to copy, and tuning one is dragging
	a number while the game runs rather than editing code.

	It works on a Model as readily as a Part — a Model gets PivotTo, a
	BasePart gets its CFrame — which is what SpinModel existed to do
	separately.

	WHY THE CLIENT

	The boost fires on orb spawns, and orbs are per player now: your
	decor should react to YOUR board. It also means the rotation is
	computed on the machine that renders it rather than replicated as a
	stream of CFrame writes to everybody, which is the same reason the
	board itself moved.

	ANGLES ARE TRACKED AS A NUMBER, NOT ACCUMULATED INTO THE CFrame

	The old scripts span by doing `part.CFrame *= CFrame.Angles(...)`
	every frame, which is the obvious way to write it and is subtly
	wrong over a long session. Multiplying a CFrame by a rotation
	doesn't re-normalise the result, so each frame's rounding error is
	baked into the matrix and the next frame compounds it. Give it
	enough multiplications and the rotation part stops being a clean
	rotation: the piece starts to look very slightly sheared, and its
	apparent speed drifts off the number you asked for.

	That was tolerable while this ran on the server at a fixed 60Hz. It
	is not now. On the client this runs once per rendered frame, so a
	144Hz or 240Hz monitor compounds the same error two to four times
	faster than the old server script did — which is exactly why the
	spin started looking a little off after it moved here.

	So each piece keeps its ORIGINAL orientation plus a plain number for
	how far it has turned, and the transform is rebuilt from those two
	every frame. One multiplication from a clean base instead of a
	million stacked on each other. It cannot drift, at any frame rate,
	for any length of session. The position is re-read each frame rather
	than captured, so if anything ever does move a piece the spin
	follows it there instead of dragging it back.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SPIN_SPEED_ATTRIBUTE = "SpinSpeed"
local SPIN_BOOST_ATTRIBUTE = "SpinBoost"

-- How long a spawn kick takes to decay away. Was 1.5 in every copy of
-- the old script; it's one number now.
local SPIN_BOOST_TIME = 1.5

local TAU = math.pi * 2

-- Shared brake: 1 normally, 0 while a collapse has the board frozen,
-- tweened back as it resolves. ClientBoard owns it (see its
-- getSpinScale) — this only ever reads it.
local spinScale

local function scale()
	if not (spinScale and spinScale.Parent) then
		spinScale = Workspace:FindFirstChild("SpinScale")
	end
	return spinScale and spinScale.Value or 1
end

-- [instance] = { speed, boostAmount, boost, elapsed, angle, baseRot, isModel }
local spinners = {}

-- The orientation the piece was built with, with its position stripped
-- off. Every frame's transform is this times the accumulated angle, so
-- a tilted piece keeps its tilt and spins about its own axis exactly
-- like the old post-multiply did.
local function baseRotationOf(instance)
	local cf = instance:IsA("Model") and instance:GetPivot() or instance.CFrame
	return cf.Rotation
end

local function track(instance)
	local speed = instance:GetAttribute(SPIN_SPEED_ATTRIBUTE)
	if speed == nil then
		return -- the overwhelming majority of the workspace
	end
	if typeof(speed) ~= "number" then
		-- Almost always an attribute added as a string by accident. It
		-- would otherwise just quietly not spin, which is a miserable
		-- thing to debug by staring at it.
		warn(("[DecorSpin] %s has a %s attribute of type %s, expected a number")
			:format(instance:GetFullName(), SPIN_SPEED_ATTRIBUTE, typeof(speed)))
		return
	end
	if not (instance:IsA("BasePart") or instance:IsA("Model")) then
		warn(("[DecorSpin] %s has a %s attribute but isn't a Part or a Model")
			:format(instance:GetFullName(), SPIN_SPEED_ATTRIBUTE))
		return
	end

	-- Re-tracking (a piece re-parented, or streamed back in) keeps the
	-- angle it had, so it picks up where it was rather than snapping
	-- back to its build orientation.
	local existing = spinners[instance]

	spinners[instance] = {
		speed = math.rad(speed),
		boostAmount = math.rad(instance:GetAttribute(SPIN_BOOST_ATTRIBUTE) or 0),
		boost = existing and existing.boost or 0,
		elapsed = existing and existing.elapsed or SPIN_BOOST_TIME,
		angle = existing and existing.angle or 0,
		baseRot = existing and existing.baseRot or baseRotationOf(instance),
		isModel = instance:IsA("Model"),
	}

	if existing then
		return -- the signals below are already connected
	end

	-- Live tuning: drag either number in the Properties panel while the
	-- game is running and the piece changes immediately.
	instance:GetAttributeChangedSignal(SPIN_SPEED_ATTRIBUTE):Connect(function()
		local entry = spinners[instance]
		local value = instance:GetAttribute(SPIN_SPEED_ATTRIBUTE)
		if entry and typeof(value) == "number" then
			entry.speed = math.rad(value)
		end
	end)
	instance:GetAttributeChangedSignal(SPIN_BOOST_ATTRIBUTE):Connect(function()
		local entry = spinners[instance]
		if entry then
			entry.boostAmount = math.rad(instance:GetAttribute(SPIN_BOOST_ATTRIBUTE) or 0)
		end
	end)
end

for _, instance in ipairs(Workspace:GetDescendants()) do
	track(instance)
end

Workspace.DescendantAdded:Connect(track)

Workspace.DescendantRemoving:Connect(function(instance)
	spinners[instance] = nil
end)

-- ── the kick ──────────────────────────────────────────────────────────
-- Every orb that lands on the board gives every piece a shove, which
-- then decays. The old scripts each watched the Balls folder for this;
-- one listener does it now.
--
-- Deliberately not inside the Heartbeat loop's reach: ClientBoard
-- creates the folder when the board comes up, so this waits, while the
-- spin above is already running on whatever exists.
task.spawn(function()
	local ballsFolder = Workspace:WaitForChild("Balls")

	ballsFolder.ChildAdded:Connect(function()
		for _, entry in pairs(spinners) do
			entry.boost += entry.boostAmount
			entry.elapsed = 0
		end
	end)
end)

-- ── the spin ──────────────────────────────────────────────────────────

RunService.Heartbeat:Connect(function(dt)
	local brake = scale()

	for instance, entry in pairs(spinners) do
		if not instance.Parent then
			spinners[instance] = nil
			continue
		end

		local rate = entry.speed
		if entry.elapsed < SPIN_BOOST_TIME then
			-- Advanced even while the brake is on, which is what the old
			-- scripts did: multiplying by a scale of 0 still ran the
			-- clock. A collapse freeze outlasts the 1.5s decay, so a kick
			-- caught by one should be spent by the time things resume
			-- rather than waiting to fire off afterwards.
			entry.elapsed += dt
			-- quadratic ease out, same curve the old scripts used: the
			-- kick lands hard and trails off rather than stopping dead
			local t = math.clamp(entry.elapsed / SPIN_BOOST_TIME, 0, 1)
			rate += entry.boost * (1 - t) ^ 2
			if t >= 1 then
				entry.boost = 0
			end
		end

		if brake > 0 then
			-- Wrapped so the number stays small no matter how long the
			-- session runs. Rebuilt from the base rather than multiplied
			-- onto last frame's result — see the header.
			entry.angle = (entry.angle + rate * dt * brake) % TAU

			local spun = entry.baseRot * CFrame.Angles(0, entry.angle, 0)
			if entry.isModel then
				instance:PivotTo(CFrame.new(instance:GetPivot().Position) * spun)
			else
				instance.CFrame = CFrame.new(instance.Position) * spun
			end
		end
	end
end)