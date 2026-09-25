--[[
    Merger (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-24 20:25:14
]]
--[[
    Merger (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-23 02:07:55
]]
--[[
	Merger (ModuleScript) — place in ReplicatedStorage → Behaviours
	(ReplicatedStorage.Behaviours.Merger).

	Replaces MergerFuse, which lived inside the Merger template and ran on
	the server. Delete that script; this is the whole of it.

	The splitter's mirror. It launches and settles like any orb, wakes as
	it crosses COL_Y, and once it's at rest it waits for TWO plain orbs
	touching it at once. Both are pulled into its centre over 0.3s and one
	orb grows back out: sizes added, colour blended by size, radiant if
	either of them was. Each merge takes a fifth of the size it was born at
	off it, and the merge that would take it to 3 or below is its last.

	The whole lifecycle lives in Absorber, shared with the splitter. This
	file is only what makes a merger a merger.

	WHAT THE CLIENT SENDS

		ctx.report(ctx.ops.MERGE, ctx.id, idA, idB)

	Three ids. The server adds the sizes from its own ledger, blends the
	colours (a stash slot stores colour, so that's the server's call too),
	carries the radiance, charges the budget, and sends the result back
	as an ordinary SPAWN.

	WHAT WENT AWAY

	The NoCollisionConstraint folder and its ChildAdded listener, for the
	same reason the splitter's went. Also the one constraint between the
	two orbs being merged, which let them pass through each other on the
	way in: the board takes their collision away entirely while it pulls
	them (see ClientBoard's absorb), so there's nothing left for it to do.

	Every number is MergerFuse's, now in BoardConfig.MERGER.
]]

local Rep = game:GetService("ReplicatedStorage")
local CG = require(Rep:WaitForChild("CollisionGroups"))
local Absorber = require(script.Parent:WaitForChild("Absorber"))

local Merger = {}

function Merger.start(ctx)
	local cfg = ctx.config.MERGER

	-- Its budget is fifths of THIS, fixed for life. Sent by the server with
	-- every spawn, so a merger rebuilt by a resync mid-life still steps
	-- down in the same size steps the ledger is counting.
	local bornSize = ctx.bornSize

	Absorber.run(ctx, {
		cfg = cfg,
		group = CG.MergerActive,
		wants = 2, -- nothing happens with one; it holds nothing hostage
		results = 1,
		minOrbSize = cfg.MIN_MERGE_SIZE,
		pendingAttribute = "MergePending",
		sound = ctx.config.SOUNDS.merge,
		soundAtCenter = true, -- where both orbs are headed

		report = function(ids)
			ctx.report(ctx.ops.MERGE, ctx.id, ids[1], ids[2])
		end,

		after = function(remaining)
			return ctx.rules.mergerAfterMerge(remaining, bornSize)
		end,
	})
end

return Merger