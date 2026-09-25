--[[
    RadiantSplitter (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-25 02:23:34
]]
--[[
	RadiantSplitter (ModuleScript) — place in ReplicatedStorage → Behaviours
	(ReplicatedStorage.Behaviours.RadiantSplitter).

	Replaces RadiantSplitterFuse, which lived in ReplicatedStorage.radiant
	and was swapped into a splitter in place of SplitterFuse when it rolled
	radiant. ClientBoard makes the same swap now: a radiant splitter runs
	this module and never Splitter (see BoardConfig.RADIANT_BEHAVIOUR).

	A splitter that takes anything that isn't itself radiant — an orb, a
	bomb, a magnet that hasn't started pulling, a mimic, another splitter,
	a merger — and turns it into three of the same kind, each two thirds
	its size. Any of the three may come out radiant. It spins the colour
	wheel backwards from the moment it appears, hums, and when its budget
	runs out it goes off like a bomb. BoardConfig.RADIANT_SPLITTER's
	header has the whole list against a stock splitter.

	Like the stock one, it's Absorber with a spec; this file is only what
	makes it radiant. The client sends the same two ids a stock split
	sends. The server sees the splitter is radiant, checks the target with
	its own rules, and decides the three results — their kind, size,
	colour and radiance — itself.

	WHAT WENT AWAY

	Beyond everything the stock splitter already shed: the nameToKind
	table and the check for a MimicFuse child to see through a dormant
	mimic's disguise (the board knows every orb's kind; it doesn't have to
	guess from a Name), the startup probe of the radiant folder to see
	which kinds had radiant scripts (BoardRules.radiantSupported, on the
	server, which is the side that rolls), and neutralize(), which stripped
	the Scripts out of whatever it took so the thing couldn't go off or
	walk away mid-pull. ClientBoard's absorb stops the taken special's
	behaviour now, which does the same and cleans up after it.
]]

local Rep = game:GetService("ReplicatedStorage")
local CG = require(Rep:WaitForChild("CollisionGroups"))
local Absorber = require(script.Parent:WaitForChild("Absorber"))
local Blast = require(script.Parent:WaitForChild("Blast"))

local RadiantSplitter = {}

function RadiantSplitter.start(ctx)
	local cfg = ctx.config.RADIANT_SPLITTER
	local bombCfg = ctx.config.BOMB

	-- Readied now, so its boom lands on the flash; see
	-- BoardEffects.primeSound. It rides on the part, so a stash or a
	-- collapse takes it along.
	local primedBoom = ctx.effects.primeSound(ctx.part, ctx.config.SOUNDS.radiantAbsorberBoom)

	-- Each one starts at its own point on the wheel. Backwards, so a
	-- radiant splitter and a radiant merger side by side read as
	-- opposites at a glance.
	local hueOffset = math.random()
	local function rainbow()
		return Color3.fromHSV((hueOffset + cfg.HUE_DIRECTION * os.clock() / cfg.HUE_CYCLE_TIME) % 1, 1, 1)
	end

	Absorber.run(ctx, {
		cfg = cfg,
		group = CG.SplitterActive,
		wants = 1,
		results = cfg.RESULT_COUNT,
		minOrbSize = cfg.MIN_SPLIT_SIZE,
		pendingAttribute = "SplitPending",
		sound = ctx.config.SOUNDS.split,
		soundAtCenter = false,

		pick = ctx.absorbableAny,
		color = rainbow,
		hum = ctx.config.SOUNDS.radiantAbsorberHum,

		report = function(ids)
			ctx.report(ctx.ops.SPLIT, ctx.id, ids[1])
		end,

		-- the stock splitter's budget: 2 a split, spent at 5
		after = function(remaining)
			return ctx.rules.splitterAfterSplit(remaining)
		end,

		-- A size-5 bomb's reach with a size-10 bomb's push, whatever size
		-- the splitter started at.
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

return RadiantSplitter