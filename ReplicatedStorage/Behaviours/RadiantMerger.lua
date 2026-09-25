--[[
    RadiantMerger (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-25 02:23:34
]]
--[[
	RadiantMerger (ModuleScript) — place in ReplicatedStorage → Behaviours
	(ReplicatedStorage.Behaviours.RadiantMerger).

	Replaces RadiantMergerFuse, which lived in ReplicatedStorage.radiant and
	was swapped into a merger in place of MergerFuse when it rolled
	radiant. ClientBoard makes the same swap now: a radiant merger runs
	this module and never Merger (see BoardConfig.RADIANT_BEHAVIOUR).

	The radiant splitter's mirror. It takes a PAIR of anything that isn't
	itself radiant — as long as both are the same kind — and turns them
	into one of that kind: the two sizes added, plus a third on top, with
	an even chance of coming out radiant (a certainty if either going in
	was). Each merge costs it a tenth of the size it was born at, so it
	lasts twice as long as a stock merger. Rainbow forwards, hums, and goes
	off like a bomb at the end. BoardConfig.RADIANT_SPLITTER's header has
	the whole list; the merger's column is the same one.

	The client sends the same three ids a stock merge sends. The server
	sees the merger is radiant, checks both targets and that they match,
	and decides the result itself.

	What went away is the radiant splitter's list, plus the one
	NoCollisionConstraint the original put between the two halves of a
	pair — the board takes their collision away entirely while it pulls
	them in.
]]

local Rep = game:GetService("ReplicatedStorage")
local CG = require(Rep:WaitForChild("CollisionGroups"))
local Absorber = require(script.Parent:WaitForChild("Absorber"))
local Blast = require(script.Parent:WaitForChild("Blast"))

local RadiantMerger = {}

function RadiantMerger.start(ctx)
	local cfg = ctx.config.RADIANT_MERGER
	local bombCfg = ctx.config.BOMB

	-- Tenths of THIS, fixed for life, as the stock merger's fifths are.
	local bornSize = ctx.bornSize

	-- Readied now, so its boom lands on the flash; see
	-- BoardEffects.primeSound. It rides on the part, so a stash or a
	-- collapse takes it along.
	local primedBoom = ctx.effects.primeSound(ctx.part, ctx.config.SOUNDS.radiantAbsorberBoom)

	local hueOffset = math.random()
	local function rainbow()
		return Color3.fromHSV((hueOffset + cfg.HUE_DIRECTION * os.clock() / cfg.HUE_CYCLE_TIME) % 1, 1, 1)
	end

	Absorber.run(ctx, {
		cfg = cfg,
		group = CG.MergerActive,
		wants = 2,
		results = 1,
		minOrbSize = cfg.MIN_MERGE_SIZE,
		pendingAttribute = "MergePending",
		sound = ctx.config.SOUNDS.merge,
		soundAtCenter = true,

		pick = ctx.absorbableAny,
		sameKind = true, -- two bombs, two mimics, two orbs; never a bomb and an orb
		color = rainbow,
		hum = ctx.config.SOUNDS.radiantAbsorberHum,

		report = function(ids)
			ctx.report(ctx.ops.MERGE, ctx.id, ids[1], ids[2])
		end,

		after = function(remaining)
			return ctx.rules.mergerAfterMerge(remaining, bornSize, true)
		end,

		finale = function(position)
			Blast.detonate(ctx, {
				position = position,
				radius = cfg.BLAST_RADIUS_SIZE * bombCfg.RADIUS_PER_SIZE,
				impulse = cfg.BLAST_IMPULSE_SIZE * bombCfg.IMPULSE_PER_SIZE,
				colorFn = rainbow,
				vfxScale = cfg.VFX_SCALE,
				vfxTime = cfg.VFX_TIME,
				flashScale = cfg.FLASH_SCALE,
				flashTime = cfg.FLASH_TIME,
				sound = ctx.config.SOUNDS.radiantAbsorberBoom,
				primed = primedBoom,
				-- barely a nudge: a send-off, not a weapon
				shakeAmplitude = cfg.BLAST_SHAKE_AMPLITUDE,
				shakeTime = cfg.BLAST_SHAKE_TIME,
			})
		end,
	})
end

return RadiantMerger