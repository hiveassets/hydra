--[[
    RadiantMagnet (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-25 02:23:34
]]
--[[
	RadiantMagnet (ModuleScript) — place in ReplicatedStorage → Behaviours
	(ReplicatedStorage.Behaviours.RadiantMagnet).

	Replaces RadiantMagnetFuse, which lived in ReplicatedStorage.radiant
	and was swapped into a magnet in place of MagnetFuse when it rolled
	radiant. ClientBoard makes the same swap now: a radiant magnet runs
	this module and never Magnet (see BoardConfig.RADIANT_BEHAVIOUR).

	Up to the moment its pull starts, it's a plain magnet in rainbow: the
	same grow-in, rise, wander and telegraph, taken straight from
	Magnet.lua rather than copied. Then it goes its own way. It pulls
	three times as hard for three times as long, it pulls EVERYTHING on
	the board rather than only plain orbs, and instead of holding still
	it orbits the middle at its wander radius, speeding up as it goes, so
	whatever it has caught gets slung round and flung.

	Sellable through the degausser for 6x until the pull starts, exactly
	like a plain magnet; SellClient and StashClient both go by its Pulling
	attribute.

	WHAT WENT AWAY

	The same things the plain magnet shed in step 2: the AlignPosition
	and its attachment, SetNetworkOwner, the welded telegraph, the tween
	driver Instances, the primed pull Sound. On top of those, this one had
	to retire the AlignPosition the moment the orbit began and anchor the
	magnet instead — two systems writing one position was what made the
	orbit wobble. A local anchored part has only ever had one.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Magnet = require(script.Parent:WaitForChild("Magnet"))

local RadiantMagnet = {}

-- ── the idle colour ───────────────────────────────────────────────────
-- A radiant orb's six-stop loop, from a random point in it — both which
-- colour and how far into it — so two radiant magnets on the board don't
-- change colour together. Worked out from the clock each frame rather
-- than chained tweens, which is all the old loop was approximating.
local function startIdleColour(ctx)
	local colors = ctx.config.RADIANT_COLORS
	local cycle = ctx.config.RADIANT_CYCLE_TIME
	local segment = cycle / #colors
	local clock = math.random() * cycle

	local function paint()
		local position = (clock % cycle) / segment
		local index = math.floor(position) + 1
		local nextIndex = (index % #colors) + 1
		ctx.part.Color = colors[index]:Lerp(colors[nextIndex], position - math.floor(position))
	end
	paint()

	local connection = RunService.Heartbeat:Connect(function(dt)
		clock += dt
		paint()
	end)
	ctx.onStop(function()
		connection:Disconnect()
	end)
	return connection
end

-- ── the pull and the orbit ────────────────────────────────────────────
local function pull(ctx, idle, route)
	local cfg = ctx.config.RADIANT_MAGNET
	local part = ctx.part
	local startSize = ctx.size

	part:SetAttribute("Pulling", true)
	idle:Disconnect()

	ctx.effects.soundOn(part, ctx.config.SOUNDS.radiantMagnetPull)
	part.Transparency = 1

	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("BillboardGui") and child.Name:lower() == "display" then
			child:Destroy()
			break
		end
	end

	local gui, img = Magnet.makeShine(ctx)

	-- Its own colour wheel for the shine, from its own random start.
	local hueOffset = math.random()

	local elapsed = 0
	local orbitAngle = 0

	while true do
		local dt = RunService.Heartbeat:Wait()
		if not ctx.alive() then
			return
		end
		elapsed = math.min(elapsed + dt, cfg.PULL_DURATION)

		-- The orbit. Angular speed climbs the whole time, eased in from a
		-- standstill for the first ORBIT_EASE_TIME, and it picks up from
		-- exactly where the wander left it: same angle, same radius, same
		-- height. A plain circle about the middle, written straight onto
		-- an anchored part — nothing physical is involved, so nothing can
		-- drift.
		local speed = cfg.ORBIT_START_SPEED + cfg.ORBIT_ACCEL * elapsed
		if elapsed < cfg.ORBIT_EASE_TIME then
			speed *= TweenService:GetValue(elapsed / cfg.ORBIT_EASE_TIME, cfg.ORBIT_EASE_STYLE, Enum.EasingDirection.Out)
		end
		orbitAngle += speed * dt
		local angle = route.angle + orbitAngle
		part.CFrame = CFrame.new(
			math.cos(angle) * route.wanderRadius,
			route.riseY,
			math.sin(angle) * route.wanderRadius
		)

		-- Shrinks to nothing over the pull, and the pull shrinks with it.
		local size = startSize * (1 - elapsed / cfg.PULL_DURATION)
		part.Size = Vector3.new(size, size, size)

		-- White for a moment, like a plain magnet's opening pop, then the
		-- rainbow for the rest.
		if elapsed < cfg.SHINE_WHITE_TIME then
			img.ImageColor3 = Color3.new(1, 1, 1)
		else
			img.ImageColor3 = Color3.fromHSV((os.clock() / cfg.PULL_HUE_CYCLE_TIME + hueOffset) % 1, 1, 1)
		end

		local entrance = cfg.SHINE_ENTRANCE_START + (1 - cfg.SHINE_ENTRANCE_START) * TweenService:GetValue(
			math.clamp(elapsed / cfg.SHINE_ENTRANCE_TIME, 0, 1),
			cfg.SHINE_ENTRANCE_STYLE,
			Enum.EasingDirection.Out
		)
		local osc = cfg.SHINE_OSC_MIN + (cfg.SHINE_OSC_MAX - cfg.SHINE_OSC_MIN)
			* (0.5 - 0.5 * math.cos(elapsed * cfg.SHINE_OSC_HZ * math.pi * 2))
		local timeLeft = cfg.PULL_DURATION - elapsed
		local exit = 1
		if timeLeft <= cfg.SHINE_EXIT_TIME then
			exit = 1 - TweenService:GetValue(1 - timeLeft / cfg.SHINE_EXIT_TIME, cfg.SHINE_EXIT_STYLE, Enum.EasingDirection.In)
		end
		local shine = cfg.SHINE_SCALE * startSize * entrance * osc * exit
		gui.Size = UDim2.new(shine, 0, shine, 0)

		if elapsed >= cfg.PULL_DURATION then
			-- Gone, paid nobody, replaced nothing. Reported first so a
			-- client dying here can't leave the ledger holding it.
			ctx.report(ctx.ops.EXPIRED, ctx.id)
			ctx.remove()
			return
		end

		-- Everything on this board, specials included — the one thing
		-- that makes this magnet a hazard to your bombs and mergers as
		-- well as your orbs. Only itself and whatever you're holding are
		-- spared. Anchored parts (another magnet, an orb mid-stash) don't
		-- take velocity, which is the same as being spared.
		local position = part.Position
		for _, other in ipairs(ctx.folder:GetChildren()) do
			if other ~= part and other:IsA("BasePart") and not other:GetAttribute("Held") then
				local toMagnet = position - other.Position
				local distance = toMagnet.Magnitude
				if distance > 0.01 then
					other.AssemblyLinearVelocity += (toMagnet / distance) * cfg.PULL_ACCEL * size * dt
				end
			end
		end
	end
end

function RadiantMagnet.start(ctx)
	Magnet.growIn(ctx)
	ctx.effects.soundAt(ctx.part.Position, ctx.config.SOUNDS.magnetSpawn)

	local idle = startIdleColour(ctx)

	local arrived, route = Magnet.travel(ctx, true)
	if not arrived then
		return -- sold, stashed, collapsed or otherwise gone mid-flight
	end

	pull(ctx, idle, route)
end

return RadiantMagnet