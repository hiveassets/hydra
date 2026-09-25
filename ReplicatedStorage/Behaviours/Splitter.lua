--[[
    Splitter (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-24 20:25:14
]]
--[[
    Splitter (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-23 02:07:55
]]
--[[
	Splitter (ModuleScript) — place in ReplicatedStorage → Behaviours
	(ReplicatedStorage.Behaviours.Splitter).

	Replaces SplitterFuse, which lived inside the Splitter template and ran
	on the server. Delete that script; this is the whole of it.

	A splitter launches and settles like any orb. As it crosses COL_Y on
	the way up it wakes: starts pulsing, stops colliding with orbs, and
	drifts gently back toward the middle. Once it's at rest, any plain orb
	that touches it is pulled into its centre over 0.3s and comes back out
	as two halves. Each split costs it 2 size, and the split that would
	take it to 5 or below is its last: it eases to nothing and flashes out.

	The whole lifecycle lives in Absorber, shared with the merger. This
	file is only what makes a splitter a splitter.

	THE FIRST SPECIAL THAT MAKES MONEY

	A split turns a 4 or a 5 into two 3s, so the server does real work
	here. All the client sends is

		ctx.report(ctx.ops.SPLIT, ctx.id, orbId)

	— two ids. Not the halves, not their sizes, not what the splitter
	shrinks to. The server looks both up in its own ledger, splits the
	orb with its own arithmetic, charges the splitter's budget, and sends
	the halves back as an ordinary SPAWN. There's no ninth split from a
	size-20 splitter whatever arrives on the wire.

	Every number is SplitterFuse's, now in BoardConfig.SPLITTER.
]]

local Rep = game:GetService("ReplicatedStorage")
local CG = require(Rep:WaitForChild("CollisionGroups"))
local Absorber = require(script.Parent:WaitForChild("Absorber"))

local Splitter = {}

function Splitter.start(ctx)
	local cfg = ctx.config.SPLITTER

	Absorber.run(ctx, {
		cfg = cfg,
		group = CG.SplitterActive,
		wants = 1,
		results = 2,
		minOrbSize = cfg.MIN_SPLIT_SIZE, -- a 3 is the floor and is ignored completely
		pendingAttribute = "SplitPending",
		sound = ctx.config.SOUNDS.split,
		soundAtCenter = false, -- where the orb was touched, as the old positional relay did

		report = function(ids)
			ctx.report(ctx.ops.SPLIT, ctx.id, ids[1])
		end,

		after = function(remaining)
			return ctx.rules.splitterAfterSplit(remaining)
		end,
	})
end

return Splitter