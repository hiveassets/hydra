--[[
    Blast (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-25 02:23:34
]]
--[[
	Blast (ModuleScript) — place in ReplicatedStorage → Behaviours
	(ReplicatedStorage.Behaviours.Blast).

	The rainbow explosion three radiant specials end on: the radiant bomb
	when its fuse runs out, and the radiant splitter and merger when their
	budget is spent. Like Absorber, it isn't a kind and the board never
	runs it on its own — the modules that go off call Blast.detonate.

	The originals were three copies of the same vfx(), flash() and impulse
	loop, each with a comment saying it was a deliberate duplicate of the
	others. One copy now.

	WHAT A BLAST DOES, IN ORDER

	  1. The boom, where it happened.
	  2. A screen shake, sized the way a plain bomb's is.
	  3. A fireball that expands and fades, cycling through the caller's
	     colour function the whole time — and filling the screen while
	     the camera is inside it, so it still shows when it's bigger
	     than the view.
	  4. A white billboard flash on top of it, collapsing away over a
	     tenth of a second.
	  5. The push: every unanchored part on this board within the radius,
	     away from the centre, full strength at the middle falling to
	     nothing at the edge. An awake mimic in range is defused back into
	     an orb first, so the same push sends the orb flying — the same
	     order a plain bomb uses (see Bomb.lua).

	The caller removes its own part before calling this, so the blast
	never pushes the thing that's producing it.

	Things none of the originals had:
	  * what it hit lights up — in the blast's own rainbow, where a plain
	    bomb's flash is red
	  * the screen shakes (the radiant splitter and merger only barely:
	    theirs is a send-off, not a weapon)
	  * everything it hits freezes and trembles for a beat before it's
	    thrown (ctx.hitstop; see BoardConfig.HITSTOP)

	The boom is primed ahead of time (BoardEffects.primeSound) by whoever
	is going to go off, and handed in as `primed`. Built on the spot, it
	lands a few frames behind the flash.
]]

local RunService = game:GetService("RunService")

local Blast = {}

-- opts:
--   position    where it goes off
--   radius      how far the push reaches, in studs
--   impulse     the push at the very centre; it falls off linearly
--   colorFn     function(secondsSinceDetonation) -> Color3, for the fireball
--   vfxScale    the fireball's radius as a fraction of `radius`
--   vfxTime     how long it takes to expand
--   flashScale  the flash's size as a fraction of `radius`
--   flashTime   how long it stays up
--   sound       a BoardConfig.SOUNDS entry
--   primed      that sound, already made with BoardEffects.primeSound
--               (optional; without it the boom is built on the spot)
--   shakeSize   the plain-bomb size whose shake this should feel like
--   shakeAmplitude, shakeTime
--               set both to override that outright
function Blast.detonate(ctx, opts)
	local bombCfg = ctx.config.BOMB
	local position, radius = opts.position, opts.radius

	-- Skipped if the caller has already played its own (the radiant bomb
	-- has to, before it takes its part off the board — the primed sound
	-- lives on that part).
	if opts.primed or opts.sound then
		ctx.effects.playPrimedAt(opts.primed, position, opts.sound)
	end

	local shakeSize = opts.shakeSize or 5
	ctx.effects.shake(
		opts.shakeAmplitude or (bombCfg.SHAKE_BASE + shakeSize * bombCfg.SHAKE_PER_SIZE),
		opts.shakeTime or bombCfg.SHAKE_TIME,
		bombCfg.SHAKE_FREQUENCY,
		bombCfg.SHAKE_ROTATION
	)

	-- Drawn by BoardEffects.explosion, as every explosion is: a neon
	-- fireball that fills the screen while you're inside it, and a white
	-- flash on top that collapses away.
	ctx.effects.explosion({
		position = position,
		radius = radius * opts.vfxScale,
		time = opts.vfxTime,
		colorFn = opts.colorFn,
		flashScale = radius * opts.flashScale,
		flashImage = bombCfg.FLASH_IMAGE,
		flashTime = opts.flashTime,
	})

	-- Every hit flash cycles through the blast's own colours for as long
	-- as it's fading, instead of a plain bomb's red. One loop drives the
	-- lot, the mimic legs' copies included (BoardEffects mirrors a flash
	-- onto a mimic's legs as a clone, which then needs its own colour).
	local flashes = {}

	for _, other in ipairs(ctx.folder:GetChildren()) do
		if other:IsA("BasePart") then
			local offset = other.Position - position
			local distance = offset.Magnitude
			if distance <= radius then
				-- An awake mimic turns back into an orb before the push
				-- lands; see Bomb.lua for why the order matters.
				ctx.defuse(other)

				-- Anchored parts sit it out (in your hands, mid-stash, being
				-- pulled into something) — except one a blast has already
				-- frozen, which takes this push on top of the last.
				if not other.Anchored or other:GetAttribute("BlastFrozen") then
					local direction = (distance > 0.01) and (offset / distance) or Vector3.new(0, 1, 0)
					local falloff = 1 - distance / radius
					ctx.hitstop(other, direction * opts.impulse * falloff)

					if ctx.config.highlightable(ctx.kindOf(other)) then
						local highlight = ctx.effects.fadeOut(other, opts.colorFn(0), bombCfg.HIT_FADE_TIME)
						table.insert(flashes, highlight)
						local legs = other:FindFirstChild("MimicLegs")
						if legs then
							for _, copy in ipairs(legs:GetChildren()) do
								if copy:IsA("Highlight") then
									table.insert(flashes, copy)
								end
							end
						end
					end
				end
			end
		end
	end

	if #flashes > 0 then
		local elapsed = 0
		local connection
		connection = RunService.Heartbeat:Connect(function(dt)
			elapsed += dt
			local color = opts.colorFn(elapsed)
			local any = false
			for _, highlight in ipairs(flashes) do
				if highlight.Parent then
					highlight.FillColor = color
					any = true
				end
			end
			if not any or elapsed > bombCfg.HIT_FADE_TIME + 0.1 then
				connection:Disconnect()
			end
		end)
	end
end

return Blast