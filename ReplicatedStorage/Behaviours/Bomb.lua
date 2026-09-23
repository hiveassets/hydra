--[[
    Bomb (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-23 02:07:55
]]
--[[
    Bomb (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-22 18:28:57
]]
--[[
	Bomb (ModuleScript) — place in ReplicatedStorage → Behaviours
	(ReplicatedStorage.Behaviours.Bomb).

	Replaces BombFuse, which lived inside the Bomb template and ran on
	the server. Delete that script; this is the whole of it.

	Flickers for 2.5 seconds, then detonates: real explosion physics, an
	expanding neon VFX ball, a billboard flash, and sound.

	WHAT A BEHAVIOUR MODULE IS

	The first of the eleven. Every special becomes one of these: a module
	with a `start(ctx)` that runs on the client owning the orb, driving
	its own local part. ClientBoard's runner spawns it at launch and
	never calls back into it — stopping is `ctx.alive()` going false,
	which the module checks around every yield. That's the same shape
	the old fuse scripts already had (their `stillLive()`), which is why
	the port reads so closely to the original.

	WHAT CHANGED, AND WHAT DELIBERATELY DIDN'T

	Not a single number moved. The flicker phases, the blast radius and
	impulse per size, the VFX scale and timings, the flash — all of it
	is lifted straight across and now lives in BoardConfig.BOMB, where
	both sides can read it. What went away is the machinery that existed
	only because a bomb used to be a server object:

	  * `se:FireAllClients("attachedReused", ...)` for the flicker tick.
	    Sounds were relayed to every client in the game because the
	    server couldn't play one locally. It's a local part now, so it's
	    just a sound, and only the owner hears it — which is correct,
	    since only the owner can see the bomb.
	  * The pre-primed `boomSound`, created and silently played at spawn
	    so the asset would be loaded by detonation time, then reparented
	    onto a standalone anchor before the bomb was destroyed. That
	    whole dance was fighting replication latency on a Sound the
	    server owned. BoardEffects.soundAt does the anchor part, and
	    BoardEffects' preload warm-up covers the asset.
	  * The `PendingSell` attribute. It existed because SellService set a
	    flag 0.3s before it actually destroyed the bomb, and the fuse had
	    to notice. The client hides a sold orb on the click now, so
	    `ctx.alive()` already covers it.

	THE MIMIC DEFUSE IS NOT HERE YET

	A blast is the only thing that ever turns a woken board mimic back
	into a plain orb, and a pet mimic is exempt from bombs entirely.
	None of that can be written yet, because mimics don't come back
	until step 5 and there's nothing to test it against. The impulse
	pass below is marked where it slots in, and the server event this
	sends is already shaped to carry the defused ids when it does.
]]

local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local Bomb = {}

-- ── the fuse ──────────────────────────────────────────────────────────
-- Returns true if it ran all the way through, false if the bomb was
-- sold, collapsed or otherwise taken off the board partway.
local function flicker(ctx)
	local cfg = ctx.config.BOMB
	local part = ctx.part

	local color = cfg.OFF_COLOR
	part.Color = color

	for _, phase in ipairs(cfg.PHASES) do
		for _ = 1, phase.n do
			if not ctx.alive() then
				return false
			end
			task.wait(phase.gap)
			-- Checked on both sides of the wait: a sell landing during
			-- the wait would otherwise get one more tick out of a bomb
			-- that's already been paid for and removed.
			if not ctx.alive() then
				return false
			end

			color = (color == cfg.OFF_COLOR) and cfg.ON_COLOR or cfg.OFF_COLOR
			part.Color = color
			if color == cfg.ON_COLOR then
				-- Reused rather than a fresh Sound per tick: twelve of
				-- those in 2.5s clip and drift, because each one has to
				-- resolve its asset before it plays.
				ctx.effects.soundReusedOn(part, ctx.config.SOUNDS.bombFlicker)
			end
		end
	end

	return ctx.alive()
end

-- ── the expanding ball ────────────────────────────────────────────────
local function vfx(ctx, position, blastRadius)
	local cfg = ctx.config.BOMB
	local radius = blastRadius * cfg.VFX_SCALE

	local ball = Instance.new("Part")
	ball.Shape, ball.Anchored, ball.CanCollide, ball.CanQuery =
		Enum.PartType.Ball, true, false, false
	ball.Material, ball.Color = Enum.Material.Neon, cfg.VFX_START
	ball.Size, ball.Position = Vector3.new(1, 1, 1), position
	ball.Parent = Workspace

	local expand = TweenService:Create(ball,
		TweenInfo.new(cfg.VFX_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
		{ Size = Vector3.new(radius, radius, radius) * 2 })
	-- Kept as its own tween rather than folded into the fade, so the
	-- orange-to-red shift stays readable instead of being buried by it.
	local recolor = TweenService:Create(ball,
		TweenInfo.new(cfg.VFX_TIME * 0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Color = cfg.VFX_END })
	local fade = TweenService:Create(ball,
		TweenInfo.new(cfg.VFX_TIME * 0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Transparency = 1 })

	expand:Play()
	recolor:Play()
	-- Delayed so the colour shift reads before the fade starts eating it
	task.delay(cfg.VFX_TIME * 0.25, function()
		if ball.Parent then
			fade:Play()
		end
	end)
	expand.Completed:Connect(function()
		if ball.Parent then
			ball:Destroy()
		end
	end)
end

-- ── the billboard flash ───────────────────────────────────────────────
local function flash(ctx, position, blastRadius)
	local cfg = ctx.config.BOMB

	local anchor = Instance.new("Part")
	anchor.Anchored, anchor.CanCollide, anchor.CanQuery, anchor.Transparency =
		true, false, false, 1
	anchor.Size, anchor.Position = Vector3.new(0.1, 0.1, 0.1), position
	anchor.Parent = Workspace

	local scale = blastRadius * cfg.FLASH_SCALE
	local gui = Instance.new("BillboardGui")
	gui.Adornee, gui.Size, gui.AlwaysOnTop = anchor, UDim2.new(scale, 0, scale, 0), true
	gui.Parent = anchor

	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency, img.BorderSizePixel = 1, 0
	img.Size, img.Image = UDim2.new(1, 0, 1, 0), cfg.FLASH_IMAGE
	img.ImageColor3, img.ImageTransparency = cfg.FLASH_START, 0
	img.ScaleType, img.ZIndex = Enum.ScaleType.Fit, 10
	img.Parent = gui

	-- AlwaysOnTop puts this above the composited render that a collapse's
	-- ColorCorrectionEffect desaturates, so without this attribute it
	-- would stay full colour while the whole board went grey around it.
	-- CollapseEffectsClient looks for exactly this.
	img:SetAttribute("GreyOnCollapse", true)

	task.delay(cfg.FLASH_RECOLOR_AT, function()
		if img.Parent then
			img.ImageColor3 = cfg.FLASH_COLOR
		end
	end)
	task.delay(cfg.FLASH_TIME, function()
		if anchor.Parent then
			anchor:Destroy()
		end
	end)
end

-- ── detonation ────────────────────────────────────────────────────────
local function explode(ctx)
	-- Re-checked with no yield since flicker() returned: cheap, and
	-- assuming a zero-width gap is the kind of thing that turns out not
	-- to be true exactly once.
	if not ctx.alive() then
		return
	end

	local cfg = ctx.config.BOMB
	local part = ctx.part
	local size = ctx.size -- the LEDGER size, never the part's
	local position = part.Position
	local blastRadius = size * cfg.RADIUS_PER_SIZE

	-- Tell the server first. EXPIRED is the op for something leaving the
	-- board that pays nobody and replaces nothing, which is exactly what
	-- a detonation is: the bomb is gone, no money is created, and the
	-- board restocks itself. Sent before the local teardown so a client
	-- that dies mid-explosion still can't leave an orphan on the ledger.
	--
	-- When mimics land in step 5 this grows a second argument: the ids
	-- the blast defused, for the server to turn back into plain orbs.
	ctx.report(ctx.ops.EXPIRED, ctx.id)

	ctx.effects.soundAt(position, ctx.config.SOUNDS.bombBoom)

	-- Linear in the bomb's size, floored so a small one still registers
	-- and capped so a huge one stays playable. The SHAKE_ block in
	-- BoardConfig has the curve and where it flattens.
	ctx.effects.shake(
		math.min(cfg.SHAKE_MAX, cfg.SHAKE_BASE + size * cfg.SHAKE_PER_SIZE),
		cfg.SHAKE_TIME,
		cfg.SHAKE_FREQUENCY,
		cfg.SHAKE_ROTATION
	)

	-- Takes the part out of the board's bookkeeping and destroys it. Must
	-- happen before the impulse pass, so the blast doesn't try to push
	-- the bomb that's producing it.
	ctx.remove()

	vfx(ctx, position, blastRadius)
	flash(ctx, position, blastRadius)

	-- Only this player's own orbs, because the folder is local — which
	-- is the whole rewrite in one line. This used to reach into a shared
	-- server folder and shove everybody's.
	for _, other in ipairs(ctx.folder:GetChildren()) do
		if other:IsA("BasePart") then
			local offset = other.Position - position
			local distance = offset.Magnitude

			-- STEP 5 GOES HERE: a woken board mimic inside the radius is
			-- defused back into a plain orb, before the impulse below, so
			-- that the same blast that strips it is what sends it flying.
			-- Pet mimics are exempt from both.

			-- Anchored parts sit it out: that's a held orb (it's welded
			-- into the player's hands) or one mid-stash. An impulse is
			-- used rather than a velocity so mass still means something —
			-- a size-300 orb barely shifts where a size-4 one sails.
			if not other.Anchored and distance <= blastRadius then
				local direction = (distance > 0.01) and (offset / distance) or Vector3.new(0, 1, 0)
				local falloff = 1 - distance / blastRadius -- full at the centre, nothing at the edge
				other:ApplyImpulse(direction * size * cfg.IMPULSE_PER_SIZE * falloff)

				-- Inside the same branch on purpose: the flash marks what
				-- the blast actually pushed, so the two can never
				-- disagree about what "got hit" means. Anything excluded
				-- by kind still takes the push, it just doesn't light up.
				if ctx.config.highlightable(ctx.kindOf(other)) then
					ctx.effects.fadeOut(other, cfg.HIT_COLOR, cfg.HIT_FADE_TIME)
				end
			end
		end
	end
end

function Bomb.start(ctx)
	if flicker(ctx) then
		explode(ctx)
	end
end

return Bomb