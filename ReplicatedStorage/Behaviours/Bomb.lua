--[[
    Bomb (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-25 02:23:34
]]
--[[
    Bomb (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-24 20:25:14
]]
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

	THE MIMIC DEFUSE

	A blast is one of two things that turn an awake board mimic back into
	a plain orb (the platform edge is the other). The bomb doesn't know
	how: it asks each orb in range to defuse itself (ctx.defuse), and only
	an awake mimic has anything registered. The mimic tells the server
	about its own revert, so this still only reports its own detonation.
]]


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

-- ── the fireball and the flash ───────────────────────────────────────
-- Both drawn by BoardEffects.explosion, which every explosion shares: a
-- neon fireball that fills the screen while the camera is inside it (so
-- it still shows when the blast is bigger than the view), and a flash on
-- top of it that collapses away rather than blinking out.
local function vfx(ctx, position, blastRadius)
	local cfg = ctx.config.BOMB
	ctx.effects.explosion({
		position = position,
		radius = blastRadius * cfg.VFX_SCALE,
		time = cfg.VFX_TIME,
		startColor = cfg.VFX_START,
		endColor = cfg.VFX_END, -- orange to red
		flashScale = blastRadius * cfg.FLASH_SCALE,
		flashImage = cfg.FLASH_IMAGE,
		flashTime = cfg.FLASH_TIME,
		flashColor = cfg.FLASH_START,
		flashEndColor = cfg.FLASH_COLOR, -- white pops to yellow...
		flashRecolorAt = cfg.FLASH_RECOLOR_AT, -- ...this far in
	})
end

-- ── detonation ────────────────────────────────────────────────────────
local function explode(ctx, primedBoom)
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
	-- Any mimic the blast defuses reports that itself (MIMIC_REVERT), so
	-- this stays one message about one orb.
	ctx.report(ctx.ops.EXPIRED, ctx.id)

	-- Primed at spawn (see Bomb.start), so it lands on the flash rather
	-- than a few frames behind it.
	ctx.effects.playPrimedAt(primedBoom, position, ctx.config.SOUNDS.bombBoom)

	-- Linear in the bomb's size, floored so a small one still registers,
	-- with no ceiling. The SHAKE_ block in BoardConfig has the curve.
	ctx.effects.shake(
		cfg.SHAKE_BASE + size * cfg.SHAKE_PER_SIZE,
		cfg.SHAKE_TIME,
		cfg.SHAKE_FREQUENCY,
		cfg.SHAKE_ROTATION
	)

	-- Takes the part out of the board's bookkeeping and destroys it. Must
	-- happen before the impulse pass, so the blast doesn't try to push
	-- the bomb that's producing it.
	ctx.remove()

	vfx(ctx, position, blastRadius)

	-- Only this player's own orbs, because the folder is local — which
	-- is the whole rewrite in one line. This used to reach into a shared
	-- server folder and shove everybody's.
	for _, other in ipairs(ctx.folder:GetChildren()) do
		if other:IsA("BasePart") then
			local offset = other.Position - position
			local distance = offset.Magnitude

			-- An awake mimic inside the radius is defused back into a
			-- plain orb first, so the same blast that strips it is what
			-- sends it flying. It's the mimic's own behaviour that knows
			-- what defusing means (see its setDefuse), and only an AWAKE
			-- one has registered anything — a dormant mimic is just an
			-- orb as far as a blast is concerned, and so is anything else.
			-- Pet mimics (step 7) will simply never register one.
			if distance <= blastRadius then
				ctx.defuse(other)
			end

			-- Anchored parts sit it out: that's a held orb (it's welded
			-- into the player's hands) or one mid-stash — except one that
			-- another blast has just frozen, which takes this push on top.
			-- An impulse rather than a velocity, so mass still means
			-- something — a size-300 orb barely shifts where a size-4 one
			-- sails — and delivered through the hitstop: frozen for a beat,
			-- trembling, then thrown (see BoardConfig.HITSTOP).
			if (not other.Anchored or other:GetAttribute("BlastFrozen")) and distance <= blastRadius then
				local direction = (distance > 0.01) and (offset / distance) or Vector3.new(0, 1, 0)
				local falloff = 1 - distance / blastRadius -- full at the centre, nothing at the edge
				ctx.hitstop(other, direction * size * cfg.IMPULSE_PER_SIZE * falloff)

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
	-- Readied now so it can play the instant the bomb goes off; see
	-- BoardEffects.primeSound for why building it then is too late.
	local primedBoom = ctx.effects.primeSound(ctx.part, ctx.config.SOUNDS.bombBoom)
	if flicker(ctx) then
		explode(ctx, primedBoom)
	end
end

return Bomb