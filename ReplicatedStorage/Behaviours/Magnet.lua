--[[
    Magnet (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-24 20:25:14
]]
--[[
    Magnet (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-23 02:07:55
]]
--[[
    Magnet (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-22 18:28:57
]]
--[[
	Magnet (ModuleScript) — place in ReplicatedStorage → Behaviours
	(ReplicatedStorage.Behaviours.Magnet).

	Replaces MagnetFuse, which lived inside the Magnet template and ran on
	the server. Delete that script; this is the whole of it.

	A magnet rises out of the spawn point, wanders to a random spot over
	the board, telegraphs, then drags every plain orb toward itself while
	shrinking away to nothing. It's sellable through the degausser for
	the whole rise and wander — right up until the pull actually starts.

	WHAT THIS ONE IS REALLY ABOUT

	The bomb was a gentle port. The magnet is where the old architecture
	was bending hardest, and almost all of that bending was for the
	benefit of other clients — who can no longer see this orb at all.

	The old version could not simply move the magnet. Setting Position on
	an anchored part every frame replicates as a string of discrete
	teleports, because Roblox only interpolates parts it's simulating. So
	the magnet was unanchored, given an Attachment and an AlignPosition
	constraint with RigidityEnabled, handed SetNetworkOwner(nil) to keep
	the server authoritative over that simulation, and steered by moving
	the constraint's target — a physically simulated part chasing a goal,
	purely so that everyone else would see smooth motion. The telegraph
	sphere then had to be welded to it, because a Heartbeat loop copying
	the magnet's position was reading a physics step late and visibly
	drifting.

	None of that survives. The part is local, anchored, and its position
	is written directly each frame. Gone with it: the Attachment, the
	AlignPosition, RigidityEnabled, SetNetworkOwner, the WeldConstraint,
	four driver Instances (two NumberValues and two Vector3Values existed
	only because TweenService can't run two tweens at one property), and
	the separate Heartbeat connection that recombined them. The eases are
	computed straight from elapsed time with TweenService:GetValue, which
	is what those drivers were laundering anyway.

	The sounds lose their own layer of the same thing. The spawn cue went
	out as a "positional" event rather than an "attached" one because the
	magnet might not have replicated to a given client yet, and an
	Instance that hasn't arrived reads as nil and drops the sound. The
	pull cue was a Sound created and silently played at spawn, seconds
	early, so the asset would be loaded when it was finally needed. Both
	are now just sounds, played where and when they happen.

	WHAT DELIBERATELY DIDN'T CHANGE

	Every number, every ease, every timing. The rise and wander still run
	on overlapping timelines and recombine into one arc. The telegraph
	still starts TELEGRAPH_TIME before arrival so it lands exactly as the
	magnet stops. The shine is still three curves multiplied together.
	They're all in BoardConfig.MAGNET now.

	WHY IT DOESN'T FALL OR SETTLE

	Magnets are `selfDriven` in BoardConfig.LOOK, so ClientBoard places
	the part and then leaves it alone entirely: anchored, no launch
	velocity, skipped by the per-frame ball physics. The old version got
	this by simply never being tracked by BallManager in the first place.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Magnet = {}

local function lerp(a, b, alpha)
	return a + (b - a) * alpha
end

-- Where the part actually sits. The magnet and its telegraph are both
-- anchored, so they're moved together here rather than welded: same
-- value, same frame, nothing to drift. The old version needed a
-- WeldConstraint for this, because copying a position in a Heartbeat
-- loop read the physics solve a step late and the sphere visibly lagged
-- the magnet it was supposed to be wrapped around.
local function place(part, telegraph, position)
	local cf = CFrame.new(position)
	part.CFrame = cf
	if telegraph and telegraph.Parent then
		telegraph.CFrame = cf
	end
end

-- ── grow-in ───────────────────────────────────────────────────────────
-- The board spawns every orb at a capped visual size and grows the rest
-- in on the way up. A magnet never goes up that path, so it does its own
-- — and everything downstream reads ctx.size rather than the live Size,
-- so none of the timings below can land mid-tween.
local function growIn(ctx)
	local part, size = ctx.part, ctx.size
	if part.Size.X >= size then
		return
	end

	local tween = TweenService:Create(
		part,
		TweenInfo.new(ctx.config.GROW_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(size, size, size) }
	)

	-- Cancelled if the magnet leaves partway. A stash lerps the part's
	-- Size down to nothing over 0.15s, and a grow tween still writing
	-- that same property would fight it the whole way and win. The
	-- window is real rather than theoretical: the grow takes 0.6s, and a
	-- magnet is at its most stashable right at the start, before it has
	-- risen up out of reach.
	ctx.onStop(function()
		tween:Cancel()
	end)

	tween:Play()
end

-- ── the idle colour loop ──────────────────────────────────────────────
-- Runs from the moment it appears, not gated on arrival, so it reads as
-- alive immediately. Cancelled when the pull starts and the part turns
-- invisible — no point tweening a colour nobody can see.
local function startIdleColour(ctx)
	local cfg = ctx.config.MAGNET
	ctx.part.Color = cfg.COLOR_A
	local tween = TweenService:Create(
		ctx.part,
		TweenInfo.new(cfg.COLOR_CYCLE_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Color = cfg.COLOR_B }
	)
	tween:Play()
	ctx.onStop(function()
		tween:Cancel()
	end)
	return tween
end

-- ── the telegraph ─────────────────────────────────────────────────────
-- The inverse of the bomb's fireball: starts big and fully invisible,
-- shrinks onto the magnet while fading in. It's the only warning there
-- is, so nothing dangerous is allowed to happen until it has finished.
--
-- Parented to the magnet rather than to the workspace, which is what
-- makes it clean itself up: a collapse, a sale or a board reset destroys
-- the magnet, and the sphere goes with it.
local function startTelegraph(ctx)
	local cfg = ctx.config.MAGNET
	local startRadius = ctx.size * cfg.TELEGRAPH_RADIUS_PER_SIZE

	local sphere = Instance.new("Part")
	sphere.Name = "MagnetTelegraph"
	sphere.Shape, sphere.Anchored, sphere.CanCollide, sphere.CanQuery =
		Enum.PartType.Ball, true, false, false
	sphere.Material, sphere.Color = Enum.Material.Neon, cfg.TELEGRAPH_COLOR
	sphere.Transparency = 1
	sphere.Size = Vector3.new(startRadius, startRadius, startRadius)
	sphere.CFrame = ctx.part.CFrame
	sphere.Parent = ctx.part

	local info = TweenInfo.new(cfg.TELEGRAPH_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)
	TweenService:Create(sphere, info, { Size = Vector3.new(ctx.size, ctx.size, ctx.size) }):Play()
	local fade = TweenService:Create(sphere, info, { Transparency = 0 })
	fade.Completed:Connect(function()
		if sphere.Parent then
			sphere:Destroy()
		end
	end)
	fade:Play()

	-- The sphere is a child of the magnet, not welded to it, so moving
	-- the magnet doesn't move it. Normally that's fine — the two are
	-- placed together every frame while travelling, and destroying the
	-- magnet destroys this with it. A stash breaks both assumptions at
	-- once: the magnet flies off to the player while this stays put, and
	-- it lives on for the 0.15s that takes. So it goes when the
	-- behaviour does.
	ctx.onStop(function()
		if sphere.Parent then
			sphere:Destroy()
		end
	end)

	return sphere
end

-- ── travel ────────────────────────────────────────────────────────────
-- The rise starts at once; the wander waits, so the magnet clears the
-- floor before it starts moving sideways. Two eases on two timelines,
-- recombined into one position every frame — which is all the pair of
-- tween-driver Instances in the old version ever did.
--
-- Returns false if the magnet left the board partway.
local function travel(ctx)
	local cfg = ctx.config.MAGNET
	local scaled = ctx.size - cfg.SIZE_REF
	local riseY = cfg.RISE_Y_BASE + cfg.RISE_Y_PER_SIZE * scaled
	local wanderRadius = cfg.WANDER_RADIUS_BASE + cfg.WANDER_RADIUS_PER_SIZE * scaled

	local startPos = ctx.part.Position
	local angle = math.random() * math.pi * 2
	local targetX = math.cos(angle) * wanderRadius
	local targetZ = math.sin(angle) * wanderRadius

	local total = cfg.WANDER_START_DELAY + cfg.WANDER_TIME
	local telegraphAt = total - cfg.TELEGRAPH_TIME
	local telegraph = nil

	local elapsed = 0
	while elapsed < total do
		local dt = RunService.Heartbeat:Wait()
		if not ctx.alive() then
			return false
		end
		elapsed += dt

		local riseAlpha = TweenService:GetValue(
			math.clamp(elapsed / cfg.RISE_TIME, 0, 1),
			cfg.RISE_STYLE,
			Enum.EasingDirection.Out
		)
		local wanderAlpha = TweenService:GetValue(
			math.clamp((elapsed - cfg.WANDER_START_DELAY) / cfg.WANDER_TIME, 0, 1),
			cfg.WANDER_STYLE,
			Enum.EasingDirection.InOut
		)

		place(ctx.part, telegraph, Vector3.new(
			lerp(startPos.X, targetX, wanderAlpha),
			lerp(startPos.Y, riseY, riseAlpha),
			lerp(startPos.Z, targetZ, wanderAlpha)
			))

		-- Started from inside the loop so it lands exactly on arrival
		-- however the frame timing falls, and so a magnet sold a moment
		-- earlier never starts one at all.
		if not telegraph and elapsed >= telegraphAt then
			telegraph = startTelegraph(ctx)
		end
	end

	return ctx.alive()
end

-- ── the shine ─────────────────────────────────────────────────────────
-- Replaces the magnet visually once it turns invisible. Its size is
-- three curves multiplied together, all computed from the pull's own
-- clock: a one-shot pop in, a permanent oscillation, and a final ease to
-- nothing that lands on zero the same frame the magnet does.
--
-- BillboardGui.Size's scale component is absolute studs, NOT relative to
-- the adornee, despite being adorned to it — which is why the magnet's
-- arrival size is multiplied in by hand every time this is set.
local function makeShine(ctx)
	local cfg = ctx.config.MAGNET

	local gui = Instance.new("BillboardGui")
	gui.Adornee, gui.AlwaysOnTop = ctx.part, true
	gui.Parent = ctx.part

	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency, img.BorderSizePixel = 1, 0
	img.Size, img.Image = UDim2.new(1, 0, 1, 0), cfg.FLASH_IMAGE
	img.ImageColor3, img.ImageTransparency = cfg.SHINE_WHITE, 0
	img.ScaleType, img.ZIndex = Enum.ScaleType.Fit, 10
	img.Parent = gui

	-- AlwaysOnTop renders above the composited pass a collapse's colour
	-- correction desaturates, so without this the shine would stay full
	-- colour while the whole board went grey around it. This one lives
	-- far longer than the bomb's flash, so it's the one actually likely
	-- to be caught mid-collapse.
	img:SetAttribute("GreyOnCollapse", true)

	return gui, img
end

-- ── the pull ──────────────────────────────────────────────────────────
local function pull(ctx, colourTween)
	local cfg = ctx.config.MAGNET
	local part = ctx.part
	local startSize = ctx.size

	-- SellClient reads this to stop the degausser working: it's meant to
	-- cash a magnet out BEFORE it becomes a hazard, not to bail out of
	-- one already pulling.
	part:SetAttribute("Pulling", true)

	ctx.effects.soundOn(part, ctx.config.SOUNDS.magnetPull)

	part.Transparency = 1 -- the shine is the only visible sign of it from here
	colourTween:Cancel()

	-- The size readout goes with it; there's nothing left to label.
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("BillboardGui") and child.Name:lower() == "display" then
			child:Destroy()
			break
		end
	end

	local gui, img = makeShine(ctx)

	local elapsed = 0
	local stage, flickerPhase = 0, nil

	while true do
		local dt = RunService.Heartbeat:Wait()
		if not ctx.alive() then
			return
		end

		elapsed = math.min(elapsed + dt, cfg.SHRINK_TIME)

		-- Linear to zero over SHRINK_TIME whatever size it arrived at, so
		-- a bigger magnet loses more studs a second rather than lasting
		-- longer. This size is also what scales the pull.
		local size = startSize * (1 - elapsed / cfg.SHRINK_TIME)
		part.Size = Vector3.new(size, size, size)

		-- white, then yellow, then flicker. Each written once on its own
		-- transition rather than every frame.
		if stage == 0 and elapsed >= cfg.SHINE_WHITE_TIME then
			img.ImageColor3 = cfg.SHINE_YELLOW
			stage = 1
		end
		if stage == 1 and elapsed >= cfg.SHINE_POP_DELAY then
			stage = 2
		end
		if stage == 2 then
			local phase = math.floor(elapsed * cfg.SHINE_FLICKER_HZ) % 2
			if phase ~= flickerPhase then
				img.ImageColor3 = (phase == 0) and cfg.COLOR_A or cfg.COLOR_B
				flickerPhase = phase
			end
		end

		local entrance = lerp(
			cfg.SHINE_ENTRANCE_START,
			1,
			TweenService:GetValue(
				math.clamp(elapsed / cfg.SHINE_ENTRANCE_TIME, 0, 1),
				cfg.SHINE_ENTRANCE_STYLE,
				Enum.EasingDirection.Out
			)
		)

		-- A raised cosine starting at the minimum — exactly the curve the
		-- old reversing Sine tween traced, without the driver Instance.
		local osc = lerp(
			cfg.SHINE_OSC_MIN,
			cfg.SHINE_OSC_MAX,
			0.5 - 0.5 * math.cos(elapsed * cfg.SHINE_OSC_HZ * math.pi * 2)
		)

		local timeLeft = cfg.SHRINK_TIME - elapsed
		local exit = 1
		if timeLeft <= cfg.SHINE_EXIT_TIME then
			exit = 1 - TweenService:GetValue(
				1 - timeLeft / cfg.SHINE_EXIT_TIME,
				cfg.SHINE_EXIT_STYLE,
				Enum.EasingDirection.In
			)
		end

		local shineSize = cfg.SHINE_SCALE * startSize * entrance * osc * exit
		gui.Size = UDim2.new(shineSize, 0, shineSize, 0)

		if elapsed >= cfg.SHRINK_TIME then
			-- Gone, and it paid nobody and replaced nothing — which is
			-- exactly what EXPIRED means. Reported before the local
			-- teardown so a client dying here still can't leave the
			-- ledger holding an orb forever.
			ctx.report(ctx.ops.EXPIRED, ctx.id)
			ctx.remove()
			return
		end

		-- Every plain orb, pulled toward wherever the magnet is now,
		-- strength scaling with its current (shrinking) size and no
		-- distance falloff. Specials are unaffected, and so is anything
		-- in the player's hands.
		--
		-- The folder is this player's own, which is the whole rewrite in
		-- one line: a magnet used to drag everybody's orbs around out of
		-- one shared folder.
		local position = part.Position
		for _, other in ipairs(ctx.folder:GetChildren()) do
			if other ~= part
				and other:IsA("BasePart")
				and ctx.kindOf(other) == "ball"
				and not other:GetAttribute("Held")
			then
				local toMagnet = position - other.Position
				local distance = toMagnet.Magnitude
				if distance > 0.01 then
					other.AssemblyLinearVelocity += (toMagnet / distance) * cfg.PULL_ACCEL * size * dt
				end
			end
		end
	end
end

function Magnet.start(ctx)
	growIn(ctx)
	ctx.effects.soundAt(ctx.part.Position, ctx.config.SOUNDS.magnetSpawn)

	local colourTween = startIdleColour(ctx)

	if not travel(ctx) then
		return -- sold, collapsed or otherwise gone mid-flight
	end

	pull(ctx, colourTween)
end

return Magnet