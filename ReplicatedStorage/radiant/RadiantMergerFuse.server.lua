--[[
    RadiantMergerFuse (Script)
    Path: ReplicatedStorage → radiant
    Parent: radiant
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-23 00:26:22
]]
--[[
	RadiantMergerFuse (Script) — place in ReplicatedStorage.radiant (NOT
	nested under the Merger template — this lives alongside RadiantFuse,
	RadiantBombFuse, RadiantSplitterFuse and any other radiant behavior
	script in that shared "radiant" folder). Requires BallManager's own
	_G.SpawnMergeResultKind (a generalization of _G.SpawnMergeResult that
	can spawn any kind, not just a plain ball — added alongside this file,
	exactly the way _G.SpawnSplitResultKind was added alongside
	RadiantSplitterFuse).

	This is the full radiant replacement for MergerFuse, not an add-on to
	it: BallManager's applyRadiantOverlay destroys the stock MergerFuse a
	radiant merger was cloned in with and clones this in instead, so a
	radiant merger runs ONLY this script, never both. Everything from
	MergerFuse's own header still applies conceptually (dormant until
	COL_Y, wake into a dedicated non-ball collision group, converge-then-
	hand-off to BallManager rather than an instant merge, shrink-per-merge
	down to a floor) — this file duplicates that shape rather than
	requiring MergerFuse, same as every other Radiant<Kind>Fuse duplicates
	its stock counterpart instead of depending on it, so it stays a single
	self-contained script. Polar opposite of RadiantSplitterFuse in
	exactly the ways MergerFuse is the polar opposite of SplitterFuse —
	read that file's header first; what follows is only where this one
	diverges, per the design notes:

	  1. A merge is a net size MULTIPLIER, not a conserve-the-total
	     addition. The two source sizes are added as usual, then a third
	     of that combined size is added on top: a 5 and a 7 combine to 12,
	     +12/3 = a size 16 result (see computeResultSize). The mirror of
	     RadiantSplitterFuse's own "three results at 2/3 each is double
	     the input" — intentional, not a rounding bug.
	  2. That single result has a 50% chance of coming out radiant
	     (RESULT_RADIANT_CHANCE, rolled once per merge) — a merge only
	     ever produces one ball, so a guaranteed radiant would mean every
	     merge is radiant, hence a real coin flip. RadiantSplitterFuse
	     now rolls the same way, per result, at 25% each, rather than the
	     "exactly one of the three, guaranteed" it used to do.

	     Radiance is INHERITED, which overrides that roll: if EITHER
	     source was radiant, the result always is — the same rule the
	     stock MergerFuse follows. In practice that only ever means a
	     plain radiant BALL, since eligibleKind (point 3c) refuses to
	     touch any other radiant kind; it's written against the kind
	     generally anyway, so it keeps holding if that rule is ever
	     loosened.

	     Both paths are gated on that kind actually having a radiant
	     script (radiantSupported), same as the splitter's own roll.
	  3. ELIGIBILITY — what this merger is allowed to consume. Identical
	     rules to RadiantSplitterFuse's (read eligibleKind() there and
	     here; the two functions are deliberate copies so the two specials
	     agree on what's on the menu), plus the merger's own same-kind
	     pairing rule on top:
	       a. Every kind on the board is fair game — plain balls, bombs,
	          magnets, mimics, splitters and mergers alike. Two bombs
	          touching this merger at once become one bigger bomb, two
	          mimics one bigger mimic, two magnets one bigger magnet, and
	          so on. The one table to edit if that ever needs narrowing
	          again is nameToKind.
	       b. The two MUST be the same kind — a bomb and a ball touching
	          together is not a pair, and neither is a bomb and a splitter
	          (see the bucket scan in the Heartbeat loop below).
	       c. Radiant things: a plain radiant BALL can be merged (with
	          another ball, radiant or not), every OTHER radiant kind is
	          untouchable. That rule is what stops a radiant merger and a
	          radiant splitter from consuming each other mid-operation,
	          which is where most of the two-radiants-on-one-pile
	          weirdness came from.
	       d. Pet mimics are exempt outright; a magnet that has already
	          started PULLING is exempt (it's live, like a bomb already
	          exploding); a dormant mimic is recognized by its MimicFuse
	          child as well as by name, since it can be sitting there
	          wearing the plain Ball name as a disguise. Mimics not
	          interacting at all since MimicBody started passing through
	          MergerActive (see CollisionGroups) is fixed by this: the
	          scan below was never collision-based, mimics were just
	          excluded from it.
	     When the pair is two bombs, the result gets a fresh Bomb (or
	     RadiantBomb) fuse the instant it's spawned — its flicker() starts
	     from tick zero on its own — which is what "the timer should be
	     reset" actually amounts to: nothing here resets a timer by hand,
	     a merged bomb simply isn't either of the source bomb instances
	     anymore. A merged magnet is placed at this merger's own centre and
	     then flies off under MagnetFuse's own rise/wander, which corrects
	     its position for us — see BallManager's spawnMagnetResult.
	  4. Upon shrinking down to size 0 at the end of its own life, instead
	     of MergerFuse's decorative lime collapse-flash, it goes off: the
	     exact same explosion RadiantSplitterFuse ends on — LOOKS like
	     RadiantBombFuse's (rainbow-cycling neon VFX ball, pure-white
	     billboard flash) but ACTS like a plain BombFuse explosion (real
	     ApplyImpulse pass, linear RADIUS_PER_SIZE/IMPULSE_PER_SIZE, not
	     RadiantBombFuse's exponential curve). Blast RADIUS is always a
	     fixed size-5 bomb's worth; impulse STRENGTH is always a fixed
	     size-10 bomb's worth, regardless of how big this merger started
	     out. Duplicated from RadiantSplitterFuse rather than required
	     from it, same "stays self-contained" reasoning as everything
	     else here.
	  5. Its shrink step is 1/10th of its own original spawn size, not the
	     stock merger's 1/5th (MERGE_SHRINK_FRACTION below) — so a radiant
	     merger survives roughly twice as many merges before it hits the
	     floor and detonates. Same "computed once at wake, reused for
	     every step so they're always equal" shape MergerFuse uses; see
	     that constant's own comment for exactly which merge lands on the
	     floor.
	  6. Its color is a continuous rainbow loop from the instant it exists
	     (same hueFromClock shape every other radiant fuse uses, starting
	     at a random point in the cycle), spinning FORWARD through the hue
	     wheel — RadiantSplitterFuse is the one that runs backward, so the
	     two read as opposites on the board at a glance. Deliberately NOT
	     the stock merger's "looks like an ordinary ball while dormant"
	     disguise: a radiant merger reads as visibly radiant right away.
	  7. Emits its own ambient looping hum for as long as it exists, fired
	     once via SoundEvents' "attachedLoop" kind (see SoundClient's own
	     header): the Sound is parented directly to this merger
	     client-side, so it moves with it and is cleaned up for free the
	     instant the merger is destroyed, with no explicit stop needed on
	     any of this script's several despawn paths (vanish, sold, knocked
	     off the platform, etc.). Same asset the radiant splitter uses —
	     SoundClient's PRELOAD_IDS already lists it as the shared radiant
	     splitter/merger ambient.
	  8. Both halves of a pair are NEUTRALIZED the instant they're claimed
	     — see neutralize(). Now that specials are eligible, each source
	     spends CONVERGE_TIME anchored and shrinking with its own behavior
	     script still running: a mimic would walk out of the tween, a
	     magnet would keep steering itself and rewriting its own Size, a
	     bomb would detonate out from inside the merge (which this file
	     used to just tolerate — see the old "Parent may already be nil"
	     note). Stripping the doomed parts' behavior scripts up front
	     makes that window deterministic, the same way BallManager's
	     triggerCollapse strips fuses to freeze the board.

	Everything else — the grounded gate before merging anything, the
	center-pull-toward-(0,0) rig, the hard per-pair NoCollisionConstraints,
	COOLDOWN/MERGE_IMMUNITY/MergePending-vs-SplitPending bookkeeping, the
	size-weighted color blend, and the shrink-per-merge floor that decides
	when THIS merger itself is done — is carried over from MergerFuse
	unchanged.

	One safety net lives outside this file: if this merger is destroyed
	during the CONVERGE_TIME window (its own vanish, a collapse, a magnet
	flinging it off the board), destroying a Script kills its threads, so
	the hand-off below never happens and the pair it claimed is left
	anchored, invisible and flagged MergePending forever. BallManager
	sweeps for exactly that — see its orphaned-claim reaper.
]]

local RS = game:GetService("RunService")
local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local TS = game:GetService("TweenService")

local merger = script.Parent
local folder = merger.Parent -- already parented into Workspace.Balls by BallManager

local ballT = Rep:WaitForChild("Ball")
local bombT = Rep:WaitForChild("Bomb")
local magnetT = Rep:WaitForChild("Magnet")
local mimicT = Rep:WaitForChild("Mimic")
local splitterT = Rep:WaitForChild("Splitter")
local mergerT = Rep:WaitForChild("Merger")

-- Every kind on the board, all of them mergeable with another of the same
-- kind — see header point 3a. This is the ONLY place eligibility-by-kind
-- is declared: removing a line here makes that kind pass through this
-- merger untouched, exactly as it would against a stock one, with no other
-- change anywhere (BallManager's spawnMergeResultKind already knows how to
-- build every kind).
--
-- Note this maps NAMES, and a dormant mimic may be wearing the plain Ball
-- name as a disguise — eligibleKind below checks for a MimicFuse child
-- before falling back to this table, so a disguised mimic still resolves
-- as "mimic" (and therefore pairs with other mimics, not with balls).
local nameToKind = {
	[ballT.Name] = "ball",
	[bombT.Name] = "bomb",
	[magnetT.Name] = "magnet",
	[mimicT.Name] = "mimic",
	[splitterT.Name] = "splitter",
	[mergerT.Name] = "merger",
}

-- each eligible kind's own behavior-script Name, exactly as it sits on its
-- template — used both by neutralize() below and to check whether a radiant
-- version of that kind is actually set up before the result roll flags one
-- radiant (see radiantSupported). "ball" isn't here: a plain ball's radiant
-- overlay is RadiantFuse, checked separately.
local KIND_FUSENAME = {
	bomb = "BombFuse",
	magnet = "MagnetFuse",
	mimic = "MimicFuse",
	splitter = "SplitterFuse",
	merger = "MergerFuse",
}

local radiantFolder = Rep:FindFirstChild("radiant")

-- resolved once, at startup, rather than probing ReplicatedStorage on every
-- merge — same "a kind with no radiant script yet just never gets picked for
-- one" gating BallManager's own SPECIAL_KINDS.radiantSupported does. Without
-- this, a radiant-flagged result of a kind whose Radiant<Kind>Fuse doesn't
-- exist would spawn with no behavior script at all (applyRadiantOverlay only
-- warns), i.e. a "radiant" bomb that never ticks.
local radiantSupported = {}
do
	for kind, fuseName in pairs(KIND_FUSENAME) do
		radiantSupported[kind] = radiantFolder ~= nil
			and radiantFolder:FindFirstChild("Radiant" .. fuseName) ~= nil
	end
	radiantSupported.ball = radiantFolder ~= nil and radiantFolder:FindFirstChild("RadiantFuse") ~= nil
end

local se = Rep:WaitForChild("SoundEvents")

-- same single source of truth for collision groups every other script
-- reads names off — see ReplicatedStorage.CollisionGroups
local CG = require(Rep:WaitForChild("CollisionGroups"))

-- config: activation — identical to MergerFuse's own
local FALLBACK_COL_Y = 0.5

-- config: continuous rainbow loop (no idle/disguise color — see header
-- point 6). Forward through the hue wheel, i.e. the plain hueFromClock
-- shape RadiantFuse/RadiantBombFuse use; RadiantSplitterFuse is the one
-- that negates it.
local RAINBOW_CYCLE_TIME = 3 -- seconds for one full hue rotation
local RAINBOW_S, RAINBOW_V = 1, 1
local hueOffset = math.random() -- per-merger random start, same as every other radiant fuse
local function rainbow()
	return Color3.fromHSV((hueOffset + os.clock() / RAINBOW_CYCLE_TIME) % 1, RAINBOW_S, RAINBOW_V)
end

-- config: merge mechanics — same floors/cooldown/immunity numbers as
-- MergerFuse; only the shrink fraction, the eligibility and the result
-- size differ
local MIN_MERGE_SIZE = 2 -- a ball at or below this can't be merged — see MergerFuse's own comment for why this is deliberately one below the splitter's MIN_SPLIT_SIZE
local RESULT_GROWTH_FRACTION = 1 / 3 -- the combined size gets this much of itself added back on top — see computeResultSize and header point 1
local RESULT_RADIANT_CHANCE = 0.5 -- see header point 2
local MERGE_SHRINK_FRACTION = 1 / 10 -- the merger shrinks by this fraction of its OWN ORIGINAL (spawn) size per merge — half the stock merger's 1/5th, so it lasts twice as long. With MIN_MERGER_SIZE at 3 that's exactly the 10th merge for any merger that spawned above 30 studs, and proportionally sooner below that (whichever merge's shrink would first land at or under the floor)
local MIN_MERGER_SIZE = 3 -- floor on the merger's own (real, visible) size; the merge whose shrink would land at or below this detonates instead, same merge, starting from its current already-shrunk size
local COOLDOWN = 0.1
local GROUNDED_VY = 1.5 -- studs/s of vertical speed still counted as "at rest" — see MergerFuse's own comment for why merging is gated on this
local GROUNDED_FRAMES = 2 -- consecutive frames under GROUNDED_VY before merging is allowed
local MERGE_IMMUNITY = 0.75 -- seconds a freshly-created merge result is skipped by this loop's touch check
local CONVERGE_TIME = 0.3 -- seconds the two source balls take to visually move into each other before the result spawns
local MERGE_SND, MERGE_VOL = "rbxassetid://86932397872773", 1

-- config: vanish explosion — see header point 4. Identical to
-- RadiantSplitterFuse's own: radius and impulse are two independent fixed
-- sizes, not one number reused twice ("always the size of a size 5 bomb's
-- explosion, but the strength of a size 10").
local VANISH_TIME = 1 -- seconds to ease down to size 0 before detonating
local VANISH_RADIUS_SIZE = 5
local VANISH_IMPULSE_SIZE = 10
local RADIUS_PER_SIZE, IMPULSE_PER_SIZE = 6, 5000 -- identical to BombFuse's own linear constants
local VFX_SCALE, VFX_TIME = 0.5, 0.3 -- same shape as RadiantBombFuse's own vfx()
local FLASH_SCALE, FLASH_TIME = 0.6, 0.1
local FLASH_IMAGE = "rbxassetid://131187911056182"
local BOOM_SND, BOOM_VOL = "rbxassetid://137086138620952", 0.9 -- RadiantBombFuse's own boom, same as RadiantSplitterFuse's vanish

-- config: ambient hum — the shared radiant splitter/merger ambient already
-- listed in SoundClient's PRELOAD_IDS
local AMBIENT_SND, AMBIENT_VOL = "rbxassetid://139726170556835", 0.1

-- config: center pull — identical shape/numbers to MergerFuse's own
local CENTER_PULL_RADIUS = 50
local CENTER_PULL_MIN_ACCEL = 2
local CENTER_PULL_MAX_ACCEL = 5

-- ── eligibility: the one place "may this merger consume that?" is
-- answered — see header point 3. Returns the kind (which is also what it
-- has to be paired with), or nil for anything to be left alone entirely.
-- Deliberately a line-for-line copy of RadiantSplitterFuse's own, so the
-- two specials never disagree about what's on the menu. ──
local function eligibleKind(part)
	-- purchased, per-player, never board inventory — same exemption
	-- BallManager/BombFuse give it everywhere else
	if part:GetAttribute("IsPetMimic") then
		return nil
	end

	-- still mid grow-in: a split/merge result is Anchored with its own
	-- sizeConn rewriting its CFrame off every Size change until it reaches
	-- full size (see BallManager's spawnMergeResultKind). Consuming one in
	-- that window means the convergence tween fights a CFrame being
	-- rewritten under it — see RadiantSplitterFuse's own copy of this check.
	if part:GetAttribute("Growing") then
		return nil
	end

	local kind
	-- a mimic is whatever is carrying a mimic behavior script, awake or
	-- not — a dormant one can be sitting there under the plain Ball name,
	-- and matching on the name alone would pair it with ordinary balls
	if part:GetAttribute("MimicActive")
		or part:FindFirstChild("MimicFuse")
		or part:FindFirstChild("RadiantMimicFuse")
	then
		kind = "mimic"
	else
		kind = nameToKind[part.Name]
	end

	if not kind then
		return nil
	end

	-- THE radiant rule (3c): a plain radiant ball is fair game, every
	-- other radiant kind is untouchable — including radiant splitters and
	-- radiant mergers, which is precisely what keeps the two of them from
	-- consuming each other mid-operation.
	if kind ~= "ball" and part:GetAttribute("IsRadiant") then
		return nil
	end

	-- a magnet mid-pull is live and has to be waited out, same as a bomb
	-- already exploding — mirrors MagnetFuse/SellHandler's own "sellable
	-- right up until Pulling, not after" rule
	if kind == "magnet" and part:GetAttribute("Pulling") then
		return nil
	end

	return kind
end

-- ── vanish-explosion boom sound: primed up front, same reasoning
-- BombFuse/RadiantBombFuse/RadiantSplitterFuse all give theirs — avoids the
-- audible delay of asking a client to build+load a fresh Sound at the moment
-- it's needed. Parented to the merger for now purely so it's primed against a
-- live Instance; explodeAt reparents it to its own standalone anchor before
-- the merger itself is destroyed.
local boomSound = Instance.new("Sound")
boomSound.SoundId = BOOM_SND
boomSound.Volume = 0
boomSound.Parent = merger
boomSound:Play()
boomSound:Stop()
boomSound.Volume = BOOM_VOL

-- ── vanish-explosion VFX/flash — identical to RadiantSplitterFuse's, just
-- cycling through THIS merger's own (forward-spinning) rainbow ──
local function vfx(pos, blastRadius)
	local r = blastRadius * VFX_SCALE

	local ball = Instance.new("Part")
	ball.Shape, ball.Anchored, ball.CanCollide, ball.CanQuery = Enum.PartType.Ball, true, false, false
	ball.Material, ball.Color = Enum.Material.Neon, rainbow()
	ball.Size, ball.Position, ball.Parent = Vector3.new(1, 1, 1), pos, WS

	local expand = TS:Create(ball,
		TweenInfo.new(VFX_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
		{ Size = Vector3.new(r, r, r) * 2 })
	local fade = TS:Create(ball,
		TweenInfo.new(VFX_TIME * 0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Transparency = 1 })

	local hueConn = RS.Heartbeat:Connect(function()
		if ball.Parent then
			ball.Color = rainbow()
		end
	end)

	expand:Play()
	task.delay(VFX_TIME * 0.25, function()
		if ball.Parent then fade:Play() end
	end)
	expand.Completed:Connect(function()
		hueConn:Disconnect()
		if ball.Parent then ball:Destroy() end
	end)
end

local function flash(pos, blastRadius)
	local anchor = Instance.new("Part")
	anchor.Anchored, anchor.CanCollide, anchor.CanQuery, anchor.Transparency = true, false, false, 1
	anchor.Size, anchor.Position, anchor.Parent = Vector3.new(0.1, 0.1, 0.1), pos, WS

	local scale = blastRadius * FLASH_SCALE
	local gui = Instance.new("BillboardGui")
	gui.Adornee, gui.Size, gui.AlwaysOnTop, gui.Parent = anchor, UDim2.new(scale, 0, scale, 0), true, anchor

	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency, img.BorderSizePixel = 1, 0
	img.Size, img.Image = UDim2.new(1, 0, 1, 0), FLASH_IMAGE
	img.ImageColor3, img.ImageTransparency = Color3.new(1, 1, 1), 0 -- pure white, no yellow shift — see header point 4
	img.ScaleType, img.Parent = Enum.ScaleType.Fit, gui
	img.ZIndex = 10
	img:SetAttribute("GreyOnCollapse", true)

	task.delay(FLASH_TIME, function()
		if anchor.Parent then anchor:Destroy() end
	end)
end

-- board-mimic-only defuse, pet mimics fully exempt — identical to
-- BombFuse's/RadiantSplitterFuse's own revertMimic
local function revertMimic(part)
	local legs = part:FindFirstChild("MimicLegs")
	if legs then
		legs:Destroy()
	end

	local size = part:GetAttribute("TargetSize") or part.Size.X
	local display = part:FindFirstChild("display")
	local label = display and display:FindFirstChild("numDisplay")
	if label then
		label.Text = tostring(math.round(size))
	end

	part:SetAttribute("MimicActive", false)
	part.Name = ballT.Name
	part.Anchored = false
	part.CanCollide = true
	part.CanQuery = true
end

-- ── neutralize: strips the behavior off a part this merger has just
-- claimed — see header point 8, and RadiantSplitterFuse's own copy of
-- this function (identical; duplicated for the same self-contained
-- reasoning as everything else here). Called synchronously as part of the
-- same claim that sets MergePending, so neither half of the pair gets a
-- single frame to act on its own after being claimed. ──
local function neutralize(part, kind)
	-- an awake mimic's legs are its own children, so they'd be destroyed
	-- with it regardless — but they don't shrink with the convergence
	-- tween (separate parts, separate sizes), so a mimic pulled in with
	-- them still attached visibly collapses into a pile of legs first
	if kind == "mimic" then
		local legs = part:FindFirstChild("MimicLegs")
		if legs then
			legs:Destroy()
		end
		part:SetAttribute("MimicActive", false)
	end

	-- MagnetFuse's telegraph sphere is parented to Workspace and WELDED to
	-- the magnet, and the thing that normally cleans it up is a
	-- magnet.Destroying connection owned by the very script being destroyed
	-- on the next line. Left alone it survives as an unanchored, unwelded
	-- neon ball falling through the world until void cleanup gets it, so
	-- it's taken down from this side instead. Scoped to magnets rather than
	-- run for every kind: nothing else here welds loose parts into
	-- Workspace, and a blind joint sweep is a good way to destroy something
	-- that wasn't ours.
	if kind == "magnet" then
		for _, joint in ipairs(part:GetJoints()) do
			if joint:IsA("WeldConstraint") then
				local other = (joint.Part0 == part) and joint.Part1 or joint.Part0
				if other and other.Parent == WS then
					other:Destroy()
				end
			end
		end
	end

	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("BaseScript") then
			child:Destroy()
		end
	end
end

-- fires the blast at `pos` and destroys `merger` — called once the vanish
-- shrink tween finishes, from vanishMerger below. Sequenced EXACTLY the way
-- BombFuse's own explode() (and RadiantBombFuse's, and
-- RadiantSplitterFuse's) is: build+reparent the sound anchor first, THEN
-- destroy the exploding part, THEN vfx()/flash()/the impulse pass. Destroying
-- the merger first would take this script and the not-yet-reparented
-- boomSound with it and abort the whole sequence — see RadiantSplitterFuse's
-- own comment on exactly that bug.
local function explodeAt(pos)
	local blastRadius = VANISH_RADIUS_SIZE * RADIUS_PER_SIZE
	local impulseMagnitude = VANISH_IMPULSE_SIZE * IMPULSE_PER_SIZE

	local soundAnchor = Instance.new("Part")
	soundAnchor.Anchored, soundAnchor.CanCollide, soundAnchor.CanQuery, soundAnchor.Transparency = true, false, false, 1
	soundAnchor.Size, soundAnchor.Position, soundAnchor.Parent = Vector3.new(0.1, 0.1, 0.1), pos, WS
	boomSound.Parent = soundAnchor
	boomSound:Play()
	task.delay(boomSound.TimeLength > 0 and boomSound.TimeLength or 3, function()
		if soundAnchor.Parent then soundAnchor:Destroy() end
	end)

	merger:Destroy()
	vfx(pos, blastRadius)
	flash(pos, blastRadius)

	-- merger is already gone from folder:GetChildren() at this point (just
	-- Destroy()'d above), same reason BombFuse's own loop doesn't need a
	-- `part ~= bomb` check either
	for _, part in ipairs(folder:GetChildren()) do
		if part:IsA("BasePart") then
			local offset = part.Position - pos
			local dist = offset.Magnitude

			if dist <= blastRadius and part:GetAttribute("MimicActive") and not part:GetAttribute("IsPetMimic") then
				revertMimic(part)
			end

			if not part.Anchored and dist <= blastRadius and not part:GetAttribute("IsPetMimic") then
				local dir = (dist > 0.01) and (offset / dist) or Vector3.new(0, 1, 0)
				local falloff = 1 - dist / blastRadius
				part:ApplyImpulse(dir * impulseMagnitude * falloff)
			end
		end
	end
end

-- see header point 1: the two sizes are added, then a third of that total is
-- added on top (5 + 7 = 12, + 4 = 16). Rounded to a whole number for the same
-- reason splitBall rounds its own jitter — TargetSize is what numDisplay and
-- the grab-tier maxSize checks both read, so a fractional one reads as a
-- different size than it actually is.
local function computeResultSize(sizeA, sizeB)
	local combined = sizeA + sizeB
	return math.round(combined + combined * RESULT_GROWTH_FRACTION)
end

-- size-weighted blend, identical to MergerFuse's own: the bigger source
-- ball's color counts for more, proportional to how much bigger it is.
local function mixColor(colorA, sizeA, colorB, sizeB)
	local total = sizeA + sizeB
	if total <= 0 then
		return colorA
	end
	return colorA:Lerp(colorB, sizeB / total)
end

-- Same shape as MergerFuse's own mergeTouched (claim -> untrack -> converge
-- -> destroy -> hand off, kicked off in its own task.spawn so the caller's
-- shrink/cooldown bookkeeping proceeds on schedule) — just handing off to
-- _G.SpawnMergeResultKind with the pair's shared `kind` instead of always
-- spawning a plain ball, at computeResultSize's inflated size, with a 50/50
-- radiant roll on the result.
local function mergeTouched(partA, partB, kind)
	local sizeA = partA:GetAttribute("TargetSize") or partA.Size.X
	local sizeB = partB:GetAttribute("TargetSize") or partB.Size.X
	local colorA, colorB = partA.Color, partB.Color

	local resultSize = computeResultSize(sizeA, sizeB)
	local mixedColor = mixColor(colorA, sizeA, colorB, sizeB)

	-- rolled once, here, rather than inside the task.spawn below purely so the
	-- roll is part of the same synchronous claim as everything else — which is
	-- also where the two source balls have to be read for radiance, since
	-- neutralize() runs a few lines down and both are destroyed at the end of
	-- the convergence, before the result is ever spawned.
	--
	-- EITHER source being radiant makes the result radiant outright, roll or no
	-- roll — see header point 2. Compared against true rather than read for
	-- plain truthiness because BallManager's convertRadiantToRegular sets
	-- IsRadiant to false rather than clearing it, so the attribute can exist
	-- and mean "not radiant".
	local sourceRadiant = partA:GetAttribute("IsRadiant") == true
		or partB:GetAttribute("IsRadiant") == true
	local resultRadiant = radiantSupported[kind] == true
		and (sourceRadiant or math.random() < RESULT_RADIANT_CHANCE)

	-- both source balls converge INTO the merger itself, not their own
	-- midpoint — captured once, up front, since the merger keeps drifting
	-- under its own center-pull force for the CONVERGE_TIME this takes.
	-- the result spawns centred on the merger itself and grows outward
	-- around that point, so it emerges from its middle rather than its
	-- feet; BallManager raises that centre only if the result would
	-- otherwise grow down through the platform — see resultCenterY there.
	local mergerCenter = merger.Position

	-- Claimed immediately, synchronously, before anything below yields —
	-- CONVERGE_TIME is longer than COOLDOWN, so without this the very next
	-- scan (from this merger, or any other one on the board) would find these
	-- same two still sitting untouched in the touch radius and merge them a
	-- second time. Never cleared — both are destroyed for good a few lines
	-- down. neutralize() rides along on the same claim, so from here on
	-- neither half can move, tick or wake under its own power (header
	-- point 8).
	partA:SetAttribute("MergePending", true)
	partB:SetAttribute("MergePending", true)
	neutralize(partA, kind)
	neutralize(partB, kind)

	if _G.BallManagerUntrack then
		_G.BallManagerUntrack(partA)
		_G.BallManagerUntrack(partB)
	else
		warn("[RadiantMergerFuse] _G.BallManagerUntrack missing — BallManager may not have finished loading yet")
	end

	-- temporarily disable collision between just this pair — parented to
	-- partA so it's cleaned up for free the instant either is destroyed below
	local noCollide = Instance.new("NoCollisionConstraint")
	noCollide.Name = "NoCollision_Merge"
	noCollide.Part0 = partA
	noCollide.Part1 = partB
	noCollide.Parent = partA

	-- freeze both in place so the convergence tween reads cleanly (no fighting
	-- gravity/momentum mid-animation) — they're doomed either way
	partA.Anchored, partB.Anchored = true, true

	se:FireAllClients("positional", mergerCenter, MERGE_SND, MERGE_VOL)

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

		-- Parent may already be nil if something else removed one of them
		-- mid-convergence (a sell, a collapse) — the merge still resolves
		-- either way, same as a source ball sold out from under a stock
		-- merge would. A bomb detonating itself out of the merge isn't one
		-- of those cases any more: neutralize() took its fuse with it at
		-- claim time.
		if partA.Parent then partA:Destroy() end
		if partB.Parent then partB:Destroy() end

		if _G.SpawnMergeResultKind then
			-- spawns at size 0, pinned to the merger's own bottom, and grows
			-- UP from there — see spawnMergeResultKind's own comment in
			-- BallManager. A bomb result gets a brand-new Bomb/RadiantBomb
			-- fuse out of that clone, which is the timer reset — see header
			-- point 3. A magnet result skips the grow/hop entirely and is
			-- simply placed here for MagnetFuse to fly off with.
			local result = _G.SpawnMergeResultKind(
				mergerCenter,
				resultSize,
				mixedColor,
				kind,
				resultRadiant
			)
			if result then
				result:SetAttribute("MergeImmuneUntil", os.clock() + MERGE_IMMUNITY)
			end
		else
			warn("[RadiantMergerFuse] _G.SpawnMergeResultKind missing — BallManager may not have finished loading yet")
		end
	end)
end

-- ── hard per-pair collision exclusion — identical to MergerFuse's own,
-- just scoped to every kind this merger can actually touch rather than
-- plain balls only ──
local mergerNoCollisionFolder = Instance.new("Folder")
mergerNoCollisionFolder.Name = "MergerNoCollision"
mergerNoCollisionFolder.Parent = merger

local function ensureNoCollisionWithBall(part)
	if not part or not part:IsA("BasePart") or part == merger then return end
	-- name-based rather than eligibleKind(): this is a physics exclusion,
	-- and something that's ineligible to be MERGED (a radiant bomb, a
	-- pulling magnet) still shouldn't be shoving this merger around
	if not nameToKind[part.Name] then return end

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

-- ── this merger's own end-of-life: shrink to 0, then detonate — see header
-- point 4. Caller is responsible for disconnecting the Heartbeat loop before
-- this runs, same as MergerFuse's own vanishMerger ──
local function vanishMerger()
	local shrink = TS:Create(
		merger,
		TweenInfo.new(VANISH_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.In),
		{ Size = Vector3.new(0, 0, 0) }
	)
	shrink:Play()
	shrink.Completed:Wait()

	explodeAt(merger.Position) -- destroys merger itself too — see that function's own comment
end

-- ── ambient hum: fired once, keeps playing (and following this merger
-- around) on its own from here — see header point 7 ──
se:FireAllClients("attachedLoop", merger, AMBIENT_SND, AMBIENT_VOL)

-- ── color: cycling from the instant this merger exists, no MergerFuse-style
-- "looks like a plain ball while falling" disguise phase and no saw-wave
-- pulse — same as every other radiant kind, which all read as visibly radiant
-- immediately. hueOffset above is already a fresh math.random() per instance,
-- so this also starts at a random point in the loop. Runs for this merger's
-- whole lifetime (not just post-wake), and is the ONLY place merger.Color
-- gets set. ──
local colorConn
colorConn = RS.Heartbeat:Connect(function()
	if not merger.Parent then
		colorConn:Disconnect()
		return
	end
	merger.Color = rainbow()
end)

task.spawn(function()
	local colY = folder:GetAttribute("CollisionRegainY") or FALLBACK_COL_Y
	while merger.Parent and merger.Position.Y <= colY do
		RS.Heartbeat:Wait()
	end
	if not merger.Parent then return end -- already gone (sold, knocked off, etc.) before ever waking

	-- captured once, right as the merger wakes — every shrink step is
	-- 1/10th of THIS size, not of the current shrinking one, so all ten
	-- steps are equal (see MERGE_SHRINK_FRACTION)
	local originalSize = merger:GetAttribute("TargetSize") or merger.Size.X
	local SHRINK_PER_MERGE = originalSize * MERGE_SHRINK_FRACTION

	local onCooldown = false
	local nextMergeAt = 0
	local groundedFrames = 0

	-- center-pull rig — parented under the merger itself so Destroy() (vanish,
	-- or any other despawn path) cleans both up for free
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
	hbConn = RS.Heartbeat:Connect(function()
		if not merger.Parent then
			hbConn:Disconnect()
			if ballAddedConn then ballAddedConn:Disconnect() end
			return
		end

		-- Defensive invariant, same as MergerFuse's own: BallManager assigns
		-- MergerActive at spawn and again at COL_Y; this re-pin only guards
		-- against another script changing the group.
		merger.CollisionGroup = CG.MergerActive

		-- center pull: horizontal-only (Y left alone so this never fights
		-- gravity/the platform), ramped by how far out the merger currently is
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

		-- color itself is handled by the standalone colorConn above (runs for
		-- this merger's whole lifetime, not just post-wake) — see header
		-- point 6

		-- grounded gate — placed after the collision-group re-pin and the
		-- center pull so an airborne merger still looks and behaves exactly as
		-- before; the only thing this holds back is merging
		if math.abs(merger.AssemblyLinearVelocity.Y) <= GROUNDED_VY then
			groundedFrames = groundedFrames + 1
		else
			groundedFrames = 0
		end
		if groundedFrames < GROUNDED_FRAMES then return end

		if onCooldown or os.clock() < nextMergeAt then return end

		-- distance against the merger's own current radius (re-read every
		-- frame) plus each candidate's — collect the first pair of the SAME
		-- kind currently touching, in one pass. `pending` holds at most one
		-- already-seen candidate per kind; the moment a second of that kind
		-- turns up, that's the pair and the scan stops. A bomb and a ball
		-- touching at the same time is therefore not a pair, per header
		-- point 3b.
		local pos = merger.Position
		local r1 = merger.Size.X / 2

		local pending = {}
		local pairKind, pairA, pairB = nil, nil, nil

		for _, part in ipairs(folder:GetChildren()) do
			if part ~= merger and part:IsA("BasePart") then
				-- every "may this be consumed at all" question — kinds,
				-- radiant, pet mimics, pulling magnets, disguised dormant
				-- mimics — is answered in one place now; see eligibleKind
				-- and header point 3
				local kind = eligibleKind(part)

				if kind then
					local splitImmuneUntil = part:GetAttribute("SplitImmuneUntil")
					local mergeImmuneUntil = part:GetAttribute("MergeImmuneUntil")
					local size = part:GetAttribute("TargetSize") or part.Size.X
					local immune = (splitImmuneUntil and os.clock() < splitImmuneUntil)
						or (mergeImmuneUntil and os.clock() < mergeImmuneUntil)
						or part:GetAttribute("MergePending")
						-- a ball already mid-convergence into a splitter
						-- shouldn't also be pulled into a merge
						or part:GetAttribute("SplitPending")

					if size > MIN_MERGE_SIZE and not immune then
						local r2 = part.Size.X / 2
						if (part.Position - pos).Magnitude <= r1 + r2 then
							local waiting = pending[kind]
							if waiting then
								pairKind, pairA, pairB = kind, waiting, part
								break
							end
							pending[kind] = part
						end
					end
				end
			end
		end

		if not pairKind then return end

		mergeTouched(pairA, pairB, pairKind)

		local currentSize = merger:GetAttribute("TargetSize") or merger.Size.X
		local nextSize = currentSize - SHRINK_PER_MERGE
		local vanishing = false

		if nextSize <= MIN_MERGER_SIZE then
			-- this merge's shrink would cross the floor — stop scanning and
			-- handle the floor-shrink-then-detonate sequence once, below
			merger:SetAttribute("TargetSize", MIN_MERGER_SIZE)
			vanishing = true
		else
			merger:SetAttribute("TargetSize", nextSize)
		end

		if vanishing then
			hbConn:Disconnect()
			if ballAddedConn then ballAddedConn:Disconnect() end

			-- stop pulling toward center the instant the vanish sequence
			-- starts — a VectorForce keeps pushing with its last-set Force
			-- until told otherwise, which would fight the shrink-to-0 tween
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

		-- keep the merger in its dedicated non-ball collision group even during
		-- the rapid re-arm window
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