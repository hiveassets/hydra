--[[
    MergerFuse (Script)
    Path: ReplicatedStorage → Merger
    Parent: Merger
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-20 20:00:09
]]
--[[
	MergerFuse (Script) — place inside the Merger template in ReplicatedStorage
	(ReplicatedStorage.Merger.MergerFuse).

	Polar opposite of SplitterFuse in every way that matters: same
	skeleton (dormant -> wake at COL_Y -> pulse/scan Heartbeat -> shrink
	per event -> floor-shrink-then-vanish), but where a splitter waits
	for ONE ball to touch it and turns it into two smaller ones, a merger
	waits for TWO balls to touch it at once and turns them into one
	bigger one. Read SplitterFuse's own header first — this one only
	calls out where the behavior actually diverges.

	BallManager.spawnMerger launches/grows/settles a merger with the
	exact same physics as a regular ball — this script never touches any
	of that. Everything below only starts once this script itself starts
	running, which (same as every other Fuse script) is the instant
	spawnMerger parents the clone into the shared Balls folder.

	Lifecycle:
	  1. Nothing happens until the merger crosses the same COL_Y
	     threshold every other Fuse script keys off (see
	     CollisionRegainY on the Balls folder — same attribute
	     SplitterFuse reads, so this never drifts out of sync with it).
	     Until then it just sits there looking/behaving like a
	     completely normal ball.
	  2. It then wakes up: switches into CG.MergerActive (declared, and
	     wired non-collidable against every ball-ish group, in
	     ReplicatedStorage.CollisionGroups — the exact same shape
	     CG.SplitterActive gets) so it passes straight through every
	     ball/bomb/magnet/mimic/radiant/splitter from here on, while
	     remaining solid against the platform, and starts pulsing
	     between its default and pulse color. Two awake mergers do still
	     collide with each other, same as two splitters do.
	  3. From that instant, one Heartbeat loop does three things every
	     frame: re-pins the collision group, drives the saw-wave pulse
	     (identical shape to the splitter's — pops instantly to
	     PULSE_COLOR, eases back down to DEFAULT_COLOR — just different
	     colors), and — whenever not on cooldown — checks its own
	     current radius against every live, mergeable regular ball
	     ("Ball" by name specifically) for the first TWO actually
	     touching it at once.

	A touch is detected the same way the splitter's is: distance against
	the merger's own current radius plus each ball's radius, since the
	merger is deliberately non-collidable against the Balls group so
	GetTouchingParts() never fires for it either.

	Merging (mergeTouched, below) does NOT hand the two balls straight to
	BallManager the instant they're found — unlike a split, which is
	over in the same frame, a merge has a brief "move into each other"
	animation first (see config below), so mergeTouched kicks that off in
	its own task.spawn and returns immediately, letting the Heartbeat
	loop's own shrink/vanish bookkeeping proceed on schedule regardless
	of how long the visual convergence takes. _G.BallManagerUntrack is
	called on both balls right away (same reasoning as the splitter's own
	call — see its header) so BallManager's onHB doesn't mistake either
	Destroy() for an unexpected fall.

	That convergence animation: both source balls move toward the
	merger's OWN position (captured once, up front, since the merger
	keeps drifting under its own center-pull force for the CONVERGE_TIME
	this takes) — not their own midpoint — while simultaneously easing
	their Size down to 0 with an Exponential/In tween, so they visibly
	shrink into the merger as they converge rather than just sliding
	together at full size. Both tweens share CONVERGE_TIME, so the shrink
	finishes at the same instant the balls arrive, and only once that's
	done are partA/partB actually destroyed.

	The merge result itself (_G.SpawnMergeResult, in BallManager) always
	starts at size 0 now, spawned at the merger's own position — but
	pinned to the merger's *bottom*, not its center, and grown upward
	from there (see spawnMergeResult's own comment) so a big result
	growing out of a small merger doesn't clip through the platform the
	way growing equally in every direction from a mid-air center would.

	Sizes simply add (49 + 12 -> 61) — no floor/ceil juggling needed the
	way splitting requires, since there's no way to combine two sizes
	above MIN_SIZE into something below it. A ball at or below
	MIN_MERGE_SIZE (2, deliberately one below SplitterFuse's own floor of
	3 — see the config comment) is skipped entirely,
	same as if the merger weren't touching it — no merge, no cooldown, no
	sound, exactly mirroring the splitter's own floor check.

	Color is a size-weighted blend, not a flat 50/50 — the bigger of the
	two source balls pulls the result color further toward its own,
	proportional to how much bigger it is (a 40 merging with a 10 lands
	much closer to the 40's color than the 10's). See mixColor.

	Radiance, unlike color, does NOT blend: it's inherited if EITHER
	source ball was radiant, so merging a radiant ball with anything —
	radiant or not — always produces a radiant result. (Mirrors
	SplitterFuse's own radiant inheritance, which carries a split radiant
	ball's radiance onto both halves; a radiant ball is an ordinary
	"Ball" carrying the IsRadiant attribute plus a RadiantFuse, which is
	why the scan below treats it as mergeable like any other ball in the
	first place.) Handled by spawning the result through
	_G.SpawnMergeResultKind — see spawnResult, below, for why that entry
	point rather than _G.SpawnMergeResult. The result's own RadiantFuse
	takes its color over from the moment it spawns, so mixColor's blend
	only really matters for a non-radiant merge.

	Every successful merge actually shrinks the merger itself (Size +
	TargetSize) by SHRINK_PER_MERGE — unlike the splitter's flat
	per-config-constant shrink, this is 1/5th of the merger's own
	*original* spawn size (TargetSize read once, right as it wakes),
	computed once and reused for all 5 shrinks so they're always equal
	steps. The same small Quad-out tween each time, right up until a
	merge's shrink would take it down to MIN_MERGER_SIZE or below —
	given the 1/5th-of-original step size, that's exactly the 5th merge
	by construction. That merge skips the small tween entirely, same as
	the splitter's own floor-crossing split: no further scanning/
	pulsing, and instead of shrinking it the usual amount it eases its
	actual *current* size down to 0 over VANISH_TIME (exponential
	ease-in), flashes with the same collapse-style billboard flash
	SellService.collapseSell uses (no highlight fade-in — just the
	flash, lime green here instead of the splitter's magenta), and
	destroys itself.

	Like the splitter, an awake merger gently pulls itself back toward
	that same (0, 0) horizontal spot — same ramped-by-distance
	VectorForce shape SplitterFuse's own center-pull uses. See the
	center-pull config below.
]]

local RS = game:GetService("RunService")
local Rep = game:GetService("ReplicatedStorage")
local TS = game:GetService("TweenService")

local merger = script.Parent
local folder = merger.Parent -- already parented into Workspace.Balls by BallManager

local ballT = Rep:WaitForChild("Ball")
local se = Rep:WaitForChild("SoundEvents")

-- collision group names (and every rule about what MergerActive passes
-- through) live in ReplicatedStorage.CollisionGroups — this script only
-- ever re-pins the group, never registers or pairs anything
local CG = require(Rep:WaitForChild("CollisionGroups"))

-- config: activation
local FALLBACK_COL_Y = 0.5 -- only used if the Balls folder's CollisionRegainY attribute isn't set yet (shouldn't happen — BallManager sets it at load, well before any merger can spawn); must match BallManager's own COL_Y

-- config: pulse — same saw-wave shape as SplitterFuse's, just recolored:
-- pops instantly to PULSE_COLOR (pure yellow), then eases back down to
-- DEFAULT_COLOR (the merger's idle green) over the rest of the cycle
-- before popping again.
local DEFAULT_COLOR, PULSE_COLOR = Color3.fromRGB(152, 255, 0), Color3.fromRGB(0, 255, 255)
local PULSE_TIME = 3 -- one full pop+decay cycle; tune to taste

-- config: merge mechanics
local MIN_MERGE_SIZE = 2 -- a ball at or below this can't be merged. Deliberately ONE BELOW SplitterFuse's MIN_SPLIT_SIZE (3) rather than equal to it: a size-3 ball is already at the splitter's floor and can never be split again, so staying mergeable is the only route it has back into play as something bigger. Raising this to 3 to "match" the splitter would make every size-3 ball permanently inert.
local MERGE_SHRINK_FRACTION = 1 / 5 -- the merger shrinks by this fraction of its OWN ORIGINAL (spawn) size on every successful merge — see header for why this always lands the 5th merge exactly on the floor
local MIN_MERGER_SIZE = 3 -- floor on the merger's own (real, visible) size — see header; the merge whose shrink would land at or below this vanishes instead, same merge, starting from its current already-shrunk size
local COOLDOWN = 0.1
-- grounded gate — identical to SplitterFuse's own, and there for the identical
-- reason (see its config comment). The merger wakes when its CENTER crosses
-- CollisionRegainY on the way up through the platform, still moving fast and
-- sitting right inside the settled pile, so the merger's own centre — which
-- the result is spawned around — is below FALL_Y at that instant: the merge
-- result would be created underneath the platform, read by onHB as a settled
-- ball that has already fallen, and queue 2 replacements before
-- VOID_FALLBACK_TIMEOUT cleared it. (BallManager's resultCenterY backstops
-- the platform itself; it can't tell that the merger had no business merging
-- yet, which is what this gate is for.)
local GROUNDED_VY = 1.5 -- studs/s of vertical speed still counted as "at rest"
local GROUNDED_FRAMES = 2 -- consecutive frames under GROUNDED_VY before merging is allowed
local MERGE_IMMUNITY = 0.75 -- seconds a freshly-created merge result is skipped by this loop's touch check — see SPLIT_IMMUNITY's own comment in SplitterFuse for why this exists; same reasoning, just for the single ball a merge produces instead of the two a split does
local CONVERGE_TIME = 0.3 -- seconds the two source balls take to visually move into each other before the result spawns
local MERGE_SND, MERGE_VOL = "rbxassetid://86932397872773", 1

-- config: vanish (merger's own end-of-life — see header)
local VANISH_TIME = 1 -- seconds to ease down to size 0
local COLLAPSE_FLASH_COLOR = Color3.fromRGB(0, 255, 0) -- pure lime — the merger's own vanish-flash color, polar opposite of the splitter's magenta
-- same shared sellFlash/attachedFlash pipeline SplitterFuse's own vanish
-- flash goes through — see its comment for the two optional trailing
-- args this relies on
local VANISH_FLASH_SCALE_MULTIPLIER = 2
local VANISH_FLASH_START_COLOR = Color3.new(0, 0, 0)

-- config: center pull — a gentle, constant horizontal nudge back toward
-- (0, 0) on the platform (the same horizontal spot balls spawn at —
-- SPAWN_POS's X/Z are both 0), active for as long as the merger is
-- awake. Identical shape to SplitterFuse's own center-pull: same ramped
-- VectorForce (stronger the further out it's already drifted), pointed
-- inward. Modeled as an actual physics force (scaled by the merger's
-- own mass) for the same "layers on top of collisions/bounces instead
-- of overriding them" reasoning the splitter's pull uses.
local CENTER_PULL_RADIUS = 50 -- studs from (0,0) at which the pull reaches its max strength
local CENTER_PULL_MIN_ACCEL = 2 -- studs/s^2, applied even near the center
local CENTER_PULL_MAX_ACCEL = 5 -- studs/s^2, applied at/beyond CENTER_PULL_RADIUS studs out

-- size-weighted blend: the bigger source ball's color counts for more,
-- proportional to how much bigger it is. t = sizeB / (sizeA + sizeB), so
-- Lerp(colorA, colorB, t) works out to colorA*(sizeA/total) +
-- colorB*(sizeB/total) — exactly the weighted average described in the
-- header, not a flat 50/50.
local function mixColor(colorA, sizeA, colorB, sizeB)
	local total = sizeA + sizeB
	if total <= 0 then
		return colorA
	end
	return colorA:Lerp(colorB, sizeB / total)
end

-- Spawns the merged result through BallManager, carrying `radiant` onto
-- it.
--
-- Routed through _G.SpawnMergeResultKind rather than
-- _G.SpawnMergeResult because only the Kind entry point takes a radiant
-- flag — the exact same relationship (and the exact same reasoning)
-- SplitterFuse's own spawnHalf has to _G.SpawnSplitResultKind. For kind
-- "ball" the two are the same function line for line over in
-- BallManager — same clone, same size-0 grow from the merger's own
-- centre, same hop arc, same setDisplay/density, same
-- BALLS_GROUP-and-unanchor handoff, same `tracked` entry — the Kind one
-- just additionally applies the radiant overlay before parenting, so a
-- non-radiant merge comes out exactly as it did before. "ball" is
-- passed explicitly for the same reason: merging SPECIALS into a bigger
-- special is RadiantMergerFuse's job, not this script's.
--
-- _G.SpawnMergeResult is kept as a fallback for a BallManager that
-- predates the Kind entry point: the merge still happens there, the
-- result just comes out regular, and it says so rather than silently
-- dropping the radiance.
local function spawnResult(centerPos, size, color, radiant)
	if _G.SpawnMergeResultKind then
		return _G.SpawnMergeResultKind(centerPos, size, color, "ball", radiant)
	end

	if _G.SpawnMergeResult then
		if radiant then
			warn("[MergerFuse] _G.SpawnMergeResultKind missing — a radiant merge is spawning a regular result")
		end
		return _G.SpawnMergeResult(centerPos, size, color)
	end

	return nil
end

-- destroys both `partA`/`partB` and hands off to BallManager's own
-- _G.SpawnMergeResult for the combined ball — keeps it fully owned by
-- BallManager's normal tracked/onHB machinery from the instant it
-- exists, so it falls/splits/merges again later exactly like any other
-- settled ball, with nothing left for this script to babysit.
-- _G.BallManagerUntrack is called on both source balls first, same
-- reasoning as splitTouched's own call in SplitterFuse (see header).
--
-- Unlike a split (over in the same frame), this runs the "move into
-- each other" convergence as its own task.spawn and returns right away
-- — the caller (the Heartbeat loop below) doesn't wait on it, so the
-- merger's own shrink/vanish bookkeeping isn't held up by the ~
-- CONVERGE_TIME the animation takes.
local function mergeTouched(partA, partB)
	local sizeA = partA:GetAttribute("TargetSize") or partA.Size.X
	local sizeB = partB:GetAttribute("TargetSize") or partB.Size.X
	local colorA, colorB = partA.Color, partB.Color

	local combinedSize = sizeA + sizeB
	local mixedColor = mixColor(colorA, sizeA, colorB, sizeB)
	-- EITHER source being radiant makes the result radiant — see header.
	-- Read here, synchronously, for the same reason the sizes and colors
	-- above are: both source balls are destroyed at the end of the
	-- convergence below, a full CONVERGE_TIME before the result is
	-- spawned. Compared against true rather than read for plain
	-- truthiness because BallManager's convertRadiantToRegular sets
	-- IsRadiant to false rather than clearing it, so the attribute can
	-- legitimately exist and mean "not radiant".
	local radiant = partA:GetAttribute("IsRadiant") == true
		or partB:GetAttribute("IsRadiant") == true

	-- both source balls converge INTO the merger itself, not their own
	-- midpoint — captured once, up front, since the merger keeps
	-- drifting under its own center-pull force for the CONVERGE_TIME
	-- this animation takes. The result spawns centred on the merger itself
	-- and grows outward around that point, so it emerges from its middle
	-- rather than its feet; BallManager raises that centre only if the
	-- result would otherwise grow down through the platform — see
	-- resultCenterY there.
	local mergerCenter = merger.Position

	-- Claimed immediately, synchronously, before anything below yields —
	-- CONVERGE_TIME (the visual move-into-each-other animation) is
	-- longer than COOLDOWN, so without this the very next scan (from
	-- this merger, or any other one on the board) would find these same
	-- two balls still sitting untouched/undestroyed in the touch radius
	-- and merge them a second time, producing two result balls out of
	-- one pair. Checked by the candidate scan below alongside
	-- SplitImmuneUntil/MergeImmuneUntil. Never cleared — both balls are
	-- destroyed for good a few lines down, so there's nothing to reset it
	-- back on.
	partA:SetAttribute("MergePending", true)
	partB:SetAttribute("MergePending", true)

	if _G.BallManagerUntrack then
		_G.BallManagerUntrack(partA)
		_G.BallManagerUntrack(partB)
	else
		warn("[MergerFuse] _G.BallManagerUntrack missing — BallManager may not have finished loading yet")
	end

	-- temporarily disable collision between just this pair (per design:
	-- everything else they might still be resting against/bumping is
	-- untouched) — parented to partA so it's cleaned up for free the
	-- instant either ball is destroyed below, no manual bookkeeping
	-- needed
	local noCollide = Instance.new("NoCollisionConstraint")
	noCollide.Name = "NoCollision_Merge"
	noCollide.Part0 = partA
	noCollide.Part1 = partB
	noCollide.Parent = partA

	-- freeze both in place so the convergence tween below reads cleanly
	-- (no fighting gravity/momentum mid-animation) — they're doomed
	-- either way, on their way to Destroy() the instant they finish
	-- moving into each other
	partA.Anchored, partB.Anchored = true, true

	se:FireAllClients("positional", mergerCenter, MERGE_SND, MERGE_VOL)

	-- move: eases into the merger's own position, same Quad InOut shape
	-- as before. shrink: runs alongside it, easing each ball's Size down
	-- to 0 with an Exponential/In curve — starts slow, then collapses
	-- fast right at the end — so the balls visibly shrink into the
	-- merger as they arrive, rather than sliding in at full size and
	-- popping out of existence.
	local moveInfo = TweenInfo.new(CONVERGE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
	local shrinkInfo = TweenInfo.new(CONVERGE_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)

	local moveA = TS:Create(partA, moveInfo, { Position = mergerCenter })
	local moveB = TS:Create(partB, moveInfo, { Position = mergerCenter })
	local shrinkA = TS:Create(partA, shrinkInfo, { Size = Vector3.new(0, 0, 0) })
	local shrinkB = TS:Create(partB, shrinkInfo, { Size = Vector3.new(0, 0, 0) })
	moveA:Play()
	moveB:Play()
	shrinkA:Play()
	shrinkB:Play()

	task.spawn(function()
		task.wait(CONVERGE_TIME)
		moveA:Destroy()
		moveB:Destroy()
		shrinkA:Destroy()
		shrinkB:Destroy()

		if partA.Parent then partA:Destroy() end
		if partB.Parent then partB:Destroy() end

		if _G.SpawnMergeResultKind or _G.SpawnMergeResult then
			-- spawns at size 0, centred on the merger itself, and grows
			-- outward from there — see spawnMergeResult's own comment in
			-- BallManager. Radiant if either source ball was — see
			-- spawnResult and the header.
			local result = spawnResult(mergerCenter, combinedSize, mixedColor, radiant)
			if result then
				result:SetAttribute("MergeImmuneUntil", os.clock() + MERGE_IMMUNITY)
			end
		else
			warn("[MergerFuse] _G.SpawnMergeResult missing — BallManager may not have finished loading yet")
		end
	end)
end

-- Hard per-pair collision exclusion for the merger itself, same
-- belt-and-suspenders reasoning as SplitterFuse's own
-- ensureNoCollisionWithBall — collision groups are the primary
-- broad-phase filter, but this guards against a transient
-- collision-group ordering issue under heavy physics load.
local mergerNoCollisionFolder = Instance.new("Folder")
mergerNoCollisionFolder.Name = "MergerNoCollision"
mergerNoCollisionFolder.Parent = merger

local function ensureNoCollisionWithBall(part)
	if not part or not part:IsA("BasePart") or part == merger then return end
	if part.Name ~= ballT.Name then return end

	-- part is the BALL, which never itself lives under
	-- mergerNoCollisionFolder (the constraint does) — that made the old
	-- `part:IsDescendantOf(mergerNoCollisionFolder)` check here a no-op
	-- that could never actually skip anything. Check the folder's
	-- children for an existing constraint pointed at this ball instead,
	-- so a ball that somehow triggers this twice doesn't get a second,
	-- redundant NoCollisionConstraint.
	for _, existing in ipairs(mergerNoCollisionFolder:GetChildren()) do
		if existing:IsA("NoCollisionConstraint") and existing.Part1 == part then
			return
		end
	end

	local constraint = Instance.new("NoCollisionConstraint")
	constraint.Name = "NoCollision_Merger"
	constraint.Part0 = merger
	constraint.Part1 = part
	constraint.Parent = mergerNoCollisionFolder
end

for _, part in ipairs(folder:GetChildren()) do
	ensureNoCollisionWithBall(part)
end

local ballAddedConn = folder.ChildAdded:Connect(function(part)
	ensureNoCollisionWithBall(part)
end)

-- the merger's own end-of-life — see header. Identical shape to
-- SplitterFuse's vanishSplitter, just recolored (lime instead of
-- magenta) and renamed. Caller is responsible for disconnecting the
-- Heartbeat loop before this runs, same as any other path off it.
local function vanishMerger()
	local size = merger.Size.X -- captured before the tween below touches it — its current, already-shrunk size

	local shrink = TS:Create(
		merger,
		TweenInfo.new(VANISH_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.In),
		{ Size = Vector3.new(0, 0, 0) }
	)
	shrink:Play()
	shrink.Completed:Wait()

	se:FireAllClients(
		"attachedFlash",
		merger,
		size,
		COLLAPSE_FLASH_COLOR,
		VANISH_FLASH_START_COLOR,
		VANISH_FLASH_SCALE_MULTIPLIER
	)
	task.wait() -- let the event replicate with a valid merger reference before Destroy() invalidates it
	merger:Destroy()
end

-- ── dormant: looks/behaves exactly like a normal ball until it crosses
-- the same COL_Y threshold every other Fuse script uses — see header ──
merger.Color = DEFAULT_COLOR

task.spawn(function()
	local colY = folder:GetAttribute("CollisionRegainY") or FALLBACK_COL_Y
	while merger.Parent and merger.Position.Y <= colY do
		RS.Heartbeat:Wait()
	end
	if not merger.Parent then return end -- already gone (sold, knocked off, etc.) before ever waking

	-- captured once, right as the merger wakes — see header for why
	-- 1/5th of THIS (not the current, shrinking) size is what every
	-- shrink step uses
	local originalSize = merger:GetAttribute("TargetSize") or merger.Size.X
	local SHRINK_PER_MERGE = originalSize * MERGE_SHRINK_FRACTION

	local onCooldown = false
	local nextMergeAt = 0
	local pulseElapsed = 0
	local groundedFrames = 0 -- see GROUNDED_VY's own comment

	-- center-pull rig — see config comment above. Parented under the
	-- merger itself so Destroy() (vanish, or any other despawn path)
	-- cleans both up for free, same as everything else on it.
	local pullAttachment = Instance.new("Attachment")
	pullAttachment.Name = "CenterPullAttachment"
	pullAttachment.Parent = merger

	local pullForce = Instance.new("VectorForce")
	pullForce.Name = "CenterPullForce"
	pullForce.Attachment0 = pullAttachment
	pullForce.RelativeTo = Enum.ActuatorRelativeTo.World
	pullForce.ApplyAtCenterOfMass = true
	pullForce.Force = Vector3.new(0, 0, 0)
	pullForce.Parent = merger

	local hbConn
	hbConn = RS.Heartbeat:Connect(function(dt)
		if not merger.Parent then
			hbConn:Disconnect()
			if ballAddedConn then ballAddedConn:Disconnect() end
			return
		end

		-- Defensive invariant: BallManager assigns MergerActive at spawn and
		-- again at COL_Y; this re-pin is now only a safeguard against any other
		-- script accidentally changing the group, not the mechanism that makes
		-- the merger safe at activation.
		merger.CollisionGroup = CG.MergerActive

		-- center pull: horizontal-only (Y left alone so this never fights
		-- gravity/the platform), ramped by how far out on the platform
		-- the merger currently is — identical shape to the splitter's
		-- own pull, see config comment
		do
			local pos = merger.Position
			local offset = Vector3.new(-pos.X, 0, -pos.Z) -- points TOWARD (0,0)
			local dist = offset.Magnitude
			if dist > 0.01 then
				local t = math.clamp(dist / CENTER_PULL_RADIUS, 0, 1)
				local accel = CENTER_PULL_MIN_ACCEL + (CENTER_PULL_MAX_ACCEL - CENTER_PULL_MIN_ACCEL) * t
				pullForce.Force = (offset / dist) * accel * merger.AssemblyMass
			else
				pullForce.Force = Vector3.new(0, 0, 0)
			end
		end

		-- saw-wave pulse: instant pop to PULSE_COLOR, eased-out decay
		-- back to DEFAULT_COLOR over the rest of the cycle, then pop
		-- again — see header/config comment
		pulseElapsed = (pulseElapsed + dt) % PULSE_TIME
		local frac = pulseElapsed / PULSE_TIME
		local t = 1 - TS:GetValue(frac, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		merger.Color = DEFAULT_COLOR:Lerp(PULSE_COLOR, t)

		-- grounded gate — see GROUNDED_VY's own comment. Placed after the
		-- collision-group re-pin, the center pull and the pulse so an airborne
		-- merger still looks and behaves exactly as before; the only thing this
		-- holds back is merging.
		if math.abs(merger.AssemblyLinearVelocity.Y) <= GROUNDED_VY then
			groundedFrames = groundedFrames + 1
		else
			groundedFrames = 0
		end
		if groundedFrames < GROUNDED_FRAMES then return end

		if onCooldown or os.clock() < nextMergeAt then return end

		-- distance against the merger's own current radius (re-read
		-- every frame, same as the splitter) plus each ball's — collect
		-- the first TWO eligible balls currently touching, in one pass
		local pos = merger.Position
		local r1 = merger.Size.X / 2

		local candidates = {}
		for _, part in ipairs(folder:GetChildren()) do
			if #candidates >= 2 then break end
			if part ~= merger and part:IsA("BasePart") and part.Name == ballT.Name then
				local splitImmuneUntil = part:GetAttribute("SplitImmuneUntil")
				local mergeImmuneUntil = part:GetAttribute("MergeImmuneUntil")
				local size = part:GetAttribute("TargetSize") or part.Size.X
				local immune = (splitImmuneUntil and os.clock() < splitImmuneUntil)
					or (mergeImmuneUntil and os.clock() < mergeImmuneUntil)
					or part:GetAttribute("MergePending")
					-- mirrors the SplitPending check SplitterFuse's own
					-- scan now makes for MergePending — a ball already
					-- mid-convergence into a splitter shouldn't also be
					-- pulled into a merger at the same time
					or part:GetAttribute("SplitPending")

				if size > MIN_MERGE_SIZE and not immune then
					local r2 = part.Size.X / 2
					if (part.Position - pos).Magnitude <= r1 + r2 then
						table.insert(candidates, part)
					end
				end
			end
		end

		if #candidates < 2 then return end

		mergeTouched(candidates[1], candidates[2])

		local currentSize = merger:GetAttribute("TargetSize") or merger.Size.X
		local nextSize = currentSize - SHRINK_PER_MERGE
		local vanishing = false

		if nextSize <= MIN_MERGER_SIZE then
			-- this merge's shrink would cross the floor — stop scanning
			-- (nothing left to shrink toward, and the merger's about to
			-- vanish anyway) and handle the floor-shrink-then-vanish
			-- sequence once, below, same as SplitterFuse's own
			merger:SetAttribute("TargetSize", MIN_MERGER_SIZE)
			vanishing = true
		else
			merger:SetAttribute("TargetSize", nextSize)
		end

		if vanishing then
			hbConn:Disconnect()
			if ballAddedConn then ballAddedConn:Disconnect() end

			-- stop pulling toward center the instant the vanish sequence
			-- starts — same reasoning as the splitter disabling its own
			-- pull before its floor-shrink tween (a VectorForce keeps
			-- pushing with its last-set Force until told otherwise, which
			-- would fight the shrink-to-0 tween below for the full
			-- floorShrink + VANISH_TIME it takes to actually disappear)
			pullForce.Force = Vector3.new(0, 0, 0)
			pullForce:Destroy()
			pullAttachment:Destroy()

			local floorShrink = TS:Create(
				merger,
				TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = Vector3.new(MIN_MERGER_SIZE, MIN_MERGER_SIZE, MIN_MERGER_SIZE) }
			)
			floorShrink:Play()
			floorShrink.Completed:Wait()

			task.spawn(vanishMerger)
			return
		end

		-- Keep the merger in its dedicated non-ball collision group even during
		-- the rapid re-arm window. BallManager also enforces this at COL_Y.
		merger.CollisionGroup = CG.MergerActive
		merger.CanCollide = true

		local finalSize = merger:GetAttribute("TargetSize")
		TS:Create(merger, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(finalSize, finalSize, finalSize) }):Play()

		onCooldown = true
		nextMergeAt = os.clock() + COOLDOWN
		task.delay(COOLDOWN, function()
			onCooldown = false
		end)
	end)
end)