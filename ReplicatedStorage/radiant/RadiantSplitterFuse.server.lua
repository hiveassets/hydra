--[[
    RadiantSplitterFuse (Script)
    Path: ReplicatedStorage → radiant
    Parent: radiant
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 13:33:37
]]
--[[
	RadiantSplitterFuse (Script) — place in ReplicatedStorage.radiant (NOT
	nested under the Splitter template — this lives alongside RadiantFuse,
	RadiantBombFuse, RadiantMagnetFuse and any other radiant behavior
	script in that shared "radiant" folder). Requires BallManager's own
	_G.SpawnSplitResultKind (a generalization of _G.SpawnSplitResult that
	can spawn any kind, not just a plain ball — added alongside this file).

	This is the full radiant replacement for SplitterFuse, not an add-on
	to it: BallManager's applyRadiantOverlay destroys the stock
	SplitterFuse a radiant splitter was cloned in with and clones this in
	instead, so a radiant splitter runs ONLY this script, never both.
	Everything from SplitterFuse's own header still applies conceptually
	(dormant until COL_Y, wake into a dedicated non-ball collision group,
	absorb-then-hand-off to BallManager rather than an instant split,
	shrink-per-split down to a floor) — this file duplicates that shape
	rather than requiring SplitterFuse, same as every other Radiant<Kind>Fuse
	duplicates its stock counterpart instead of depending on it, so it
	stays a single self-contained script. What actually differs, per the
	design notes:

	  1. Absorbing a ball produces THREE results instead of two, and each
	     one is 2/3 the size of the ball that went in — not a third each.
	     Yes, that means 3 * (size * 2/3) is DOUBLE the original size:
	     intentional, not a bug (see computeThirdSize) — a radiant
	     splitter is a net size multiplier, unlike a stock splitter's
	     conserve-the-total halving.
	  2. Each of the three results INDEPENDENTLY rolls a 25% chance of
	     coming out radiant (RESULT_RADIANT_CHANCE), which brings this in
	     line with the shape RadiantMergerFuse already uses for its own
	     single result — a real per-result roll — rather than the "exactly
	     one of the three, always" this used to guarantee. A split can now
	     come out with none radiant (about 42% of splits), one, two or all
	     three; the average is 0.75 radiants per split, slightly down from
	     the old guaranteed 1, and the ceiling is much higher.

	     Radiance is also INHERITED, which overrides that roll: if the
	     thing absorbed was itself radiant, ALL THREE results come out
	     radiant — the same rule the stock SplitterFuse follows for its
	     own two halves. In practice that only ever means a plain radiant
	     BALL, since eligibleKind (point 3b) refuses to touch any other
	     radiant kind; it's written against the kind generally anyway, so
	     it keeps holding if that rule is ever loosened.

	     Both paths are gated on that kind actually having a radiant
	     behavior script set up for it. See radiantSupported below:
	     without that gate, a "radiant" mimic (no RadiantMimicFuse exists
	     yet) would spawn IsRadiant-flagged with no behavior at all —
	     applyRadiantOverlay only warns. A kind with no radiant script
	     just produces three ordinary results instead.
	  3. ELIGIBILITY — what this splitter is allowed to absorb. See
	     eligibleKind() below, which is the single place all of this is
	     decided:
	       a. Every kind on the board is fair game — plain balls, bombs,
	          magnets, mimics, splitters and mergers alike — and each
	          splits into three of ITS OWN kind (a bomb becomes three
	          smaller bombs, a mimic three smaller mimics, and so on).
	          This is the one table to edit if that ever needs narrowing
	          again: nameToKind.
	       b. Radiant things are the exception, and the rule is narrow on
	          purpose: a plain radiant BALL can be absorbed, every OTHER
	          radiant kind cannot be touched at all. That single rule is
	          also what stops radiant specials from eating each other —
	          a radiant splitter and a radiant merger sitting on the same
	          pile now ignore one another completely instead of racing to
	          consume (and half-consume, see neutralize()) each other
	          mid-operation.
	       c. Pet mimics are exempt outright, same as everywhere else in
	          the game — they're a purchased, per-player thing, not board
	          inventory.
	       d. A magnet that has already started PULLING is exempt, mirror-
	          ing the demagnetizer rule in SellHandler/MagnetFuse: once
	          it's live it has to be waited out, same as a bomb that's
	          already exploding. A magnet still rising/wandering is fair
	          game, which is the window that actually matters since it
	          rises straight up through the board to get where it's going.
	       e. Mimics are matched by their MimicFuse/RadiantMimicFuse child
	          as well as by name, not by name alone — a dormant mimic can
	          be wearing the plain Ball name as a disguise, and matching
	          on the name alone would quietly split one into three
	          ordinary balls instead of three mimics. This is also what
	          fixes mimics not interacting at all now that MimicBody
	          passes through SplitterActive/MergerActive (see
	          CollisionGroups): they no longer need to physically clip
	          into the splitter for anything to happen, since this scan
	          was never collision-based in the first place — it just had
	          mimics excluded.
	     If the touched ball is a bomb, its three results get fresh
	     Bomb/RadiantBombFuse clones the instant they're spawned — each
	     one's flicker() starts from tick zero on its own, same as any
	     other freshly-spawned bomb — which is what "timers should be
	     reset" actually amounts to: nothing here has to reset a timer by
	     hand, a split bomb simply isn't the same bomb instance anymore.
	     Magnets are the one kind whose results don't grow-and-hop out of
	     the splitter like everything else: they're simply placed at its
	     centre and then fly off under MagnetFuse's own rise/wander, which
	     corrects their position for us — see BallManager's
	     spawnMagnetResult.
	  4. Upon shrinking down to size 0 at the end of its own life, instead
	     of just a decorative collapse-style flash, it goes off: a real
	     explosion that LOOKS like RadiantBombFuse's own (rainbow-cycling
	     neon VFX ball, pure-white billboard flash — no orange->red/
	     white->yellow shift) but ACTS like a plain BombFuse explosion
	     (real ApplyImpulse pass, linear RADIUS_PER_SIZE/IMPULSE_PER_SIZE
	     formula, not RadiantBombFuse's exponential impulse curve). Blast
	     RADIUS is always a fixed size-5 bomb's worth; impulse STRENGTH is
	     always a fixed size-10 bomb's worth — two independent constants,
	     not the same number twice, regardless of how big this splitter
	     started out. Duplicates BombFuse's own explode() shape (mimic
	     revert, pet-mimic exemption, impulse falloff, boom sound primed
	     up front) and RadiantBombFuse's own vfx()/flash() look, rather
	     than requiring either, same "stays self-contained" reasoning as
	     point 3 above.
	  5. Its color is a continuous rainbow loop from the instant it exists
	     (same hueFromClock shape every other radiant fuse uses, starting
	     at a random point in the cycle same as those) instead of the
	     stock splitter's saw-wave pulse between two fixed purples — but
	     spinning backward through the hue wheel relative to every other
	     radiant ball on the board (negative sign on the clock term).
	     Deliberately NOT the stock splitter's "looks/behaves like an
	     ordinary ball while dormant" disguise: a radiant splitter reads
	     as visibly radiant right away, same as every other radiant kind
	     (ball/bomb/magnet) already does.
	  6. Emits its own ambient looping hum for as long as it exists,
	     fired once via SoundEvents' "attachedLoop" kind (added alongside
	     this file — see SoundClient's own header) rather than
	     "loopStart"/"loopStop": the sound is parented directly to this
	     splitter client-side, so it moves with it and is cleaned up for
	     free the instant the splitter itself is destroyed, with no
	     explicit stop needed on any of this script's several despawn
	     paths (vanish, sold, knocked off the platform, etc.).
	  7. Anything it claims is NEUTRALIZED the instant it's claimed — see
	     neutralize(). Now that specials are eligible, the thing being
	     absorbed spends SPLIT_CONVERGE_TIME anchored and shrinking with
	     its OWN behavior script still running: a mimic would keep walking
	     out of the tween, a magnet would keep steering itself with an
	     AlignPosition and keep rewriting its own Size, a bomb would
	     detonate out from under the split. Stripping the doomed part's
	     behavior scripts up front makes that window deterministic — the
	     same thing BallManager's own triggerCollapse does to freeze the
	     board.

	Everything else — the grounded gate before absorbing anything, the
	center-pull-toward-(0,0) rig, the hard per-pair NoCollisionConstraints,
	COOLDOWN/SPLIT_IMMUNITY/SplitPending-vs-MergePending bookkeeping, and
	the shrink-per-split floor that decides when THIS splitter itself is
	done — is carried over from SplitterFuse unchanged.

	One safety net lives outside this file: if this splitter is destroyed
	during the SPLIT_CONVERGE_TIME window (its own vanish, a collapse, a
	magnet flinging it off the board), destroying a Script kills its
	threads, so the hand-off below never happens and the ball it claimed
	is left anchored, invisible and flagged SplitPending forever.
	BallManager sweeps for exactly that — see its orphaned-claim reaper.
]]

local RS = game:GetService("RunService")
local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local TS = game:GetService("TweenService")

local splitter = script.Parent
local folder = splitter.Parent -- already parented into Workspace.Balls by BallManager

local ballT = Rep:WaitForChild("Ball")
local bombT = Rep:WaitForChild("Bomb")
local magnetT = Rep:WaitForChild("Magnet")
local mimicT = Rep:WaitForChild("Mimic")
local splitterT = Rep:WaitForChild("Splitter")
local mergerT = Rep:WaitForChild("Merger")

-- Every kind on the board, all of them splittable — see header point 3a.
-- This is the ONLY place eligibility-by-kind is declared: removing a line
-- here makes that kind pass through this splitter untouched, exactly as
-- it would against a stock one, with no other change anywhere (BallManager's
-- spawnSplitResultKind already knows how to build every kind).
--
-- Note this maps NAMES, and a dormant mimic may be wearing the plain Ball
-- name as a disguise — eligibleKind below checks for a MimicFuse child
-- before falling back to this table, so a disguised mimic still resolves
-- as "mimic" rather than as "ball". See header point 3e.
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
-- version of that kind actually exists before the split flags one of the
-- three results radiant (see radiantSupported). "ball" isn't here: a plain
-- ball's radiant overlay is RadiantFuse, checked separately.
local KIND_FUSENAME = {
	bomb = "BombFuse",
	magnet = "MagnetFuse",
	mimic = "MimicFuse",
	splitter = "SplitterFuse",
	merger = "MergerFuse",
}

local radiantFolder = Rep:FindFirstChild("radiant")

-- resolved once, at startup, rather than probing ReplicatedStorage on every
-- split — same "a kind with no radiant script yet just never gets picked for
-- one" gating BallManager's own SPECIAL_KINDS.radiantSupported does. Without
-- this, a radiant-flagged result of a kind whose Radiant<Kind>Fuse doesn't
-- exist would spawn with no behavior script at all (applyRadiantOverlay only
-- warns), i.e. a "radiant" mimic that never wakes. See header point 2.
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

-- config: activation — identical to SplitterFuse's own
local FALLBACK_COL_Y = 0.5

-- config: continuous rainbow loop (no idle/disguise color — see header point 5)
local RAINBOW_CYCLE_TIME = 3 -- seconds for one full hue rotation
local RAINBOW_S, RAINBOW_V = 1, 1
local hueOffset = math.random() -- per-splitter random start, same reasoning RadiantBombFuse/RadiantMagnetFuse's own hueOffset gives
local function reversedRainbow()
	-- every other radiant fuse's own hueFromClock is
	-- `(clock / cycleTime + hueOffset) % 1` — this is that, negated, so
	-- the hue spins the opposite direction at the same speed
	return Color3.fromHSV((hueOffset - os.clock() / RAINBOW_CYCLE_TIME) % 1, RAINBOW_S, RAINBOW_V)
end

-- config: split mechanics — same shrink/floor/cooldown numbers as
-- SplitterFuse; only the eligibility/result-count/result-size differ
local SHRINK_PER_SPLIT = 2
local MIN_SPLITTER_SIZE = 5
local COOLDOWN = 0.1
local GROUNDED_VY = 1.5
local GROUNDED_FRAMES = 2
local SPLIT_IMMUNITY = 0.75
local MIN_SPLIT_SIZE = 3 -- a touched ball already this small can't be split further
local RESULT_RADIANT_CHANCE = 0.25 -- rolled independently for EACH of the three results (see header point 2) — deliberately a real per-result roll like RadiantMergerFuse's own 0.5, not the old guaranteed one-of-three. A radiant source overrides it: all three come out radiant regardless.
local SPLIT_CONVERGE_TIME = 0.3
local SPLIT_SND, SPLIT_VOL = "rbxassetid://101410298856316", 1

-- config: vanish explosion — see header point 4. Radius and impulse are
-- deliberately two independent fixed sizes, not one "size 10" reused for
-- both: "always the size of a size 5 bomb's explosion, but the strength
-- of a size 10."
local VANISH_TIME = 1 -- seconds to ease down to size 0 before detonating
local VANISH_RADIUS_SIZE = 5
local VANISH_IMPULSE_SIZE = 10
local RADIUS_PER_SIZE, IMPULSE_PER_SIZE = 6, 5000 -- identical to BombFuse's own linear constants
local VFX_SCALE, VFX_TIME = 0.5, 0.3 -- same shape as RadiantBombFuse's own vfx()
local FLASH_SCALE, FLASH_TIME = 0.6, 0.1
local FLASH_IMAGE = "rbxassetid://131187911056182"
local BOOM_SND, BOOM_VOL = "rbxassetid://137086138620952", 0.9 -- RadiantBombFuse's own boom, not BombFuse's — this explosion LOOKS like RadiantBombFuse's, sound included

-- config: ambient hum — the shared radiant splitter/merger ambient already
-- listed in SoundClient's PRELOAD_IDS
local AMBIENT_SND, AMBIENT_VOL = "rbxassetid://139726170556835", 0.1

-- config: center pull — identical shape/numbers to SplitterFuse's own
local CENTER_PULL_RADIUS = 50
local CENTER_PULL_MIN_ACCEL = 2
local CENTER_PULL_MAX_ACCEL = 5

-- ── eligibility: the one place "may this splitter absorb that?" is
-- answered — see header point 3. Returns the kind to split it into, or
-- nil for anything to be left alone entirely. ──
local function eligibleKind(part)
	-- purchased, per-player, never board inventory — same exemption
	-- BallManager/BombFuse give it everywhere else (3c)
	if part:GetAttribute("IsPetMimic") then
		return nil
	end

	-- still mid grow-in: a split/merge result is Anchored with its own
	-- sizeConn rewriting its CFrame off every Size change until it reaches
	-- full size (see BallManager's spawnSplitResultKind). Absorbing one in
	-- that window means splitTouched's convergence tween fights a CFrame
	-- being rewritten under it — the same hazard the stock SplitterFuse
	-- calls out for MergeImmuneUntil, caught directly here rather than
	-- relying on the immunity windows happening to outlast GROW_TWEEN.
	if part:GetAttribute("Growing") then
		return nil
	end

	local kind
	-- a mimic is whatever is carrying a mimic behavior script, awake or
	-- not — a dormant one can be sitting there under the plain Ball name,
	-- and matching on the name alone would split it into three ordinary
	-- balls and quietly delete the mimic (3e)
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

	-- THE radiant rule (3b): a plain radiant ball is fair game, every
	-- other radiant kind is untouchable. Radiant splitters and radiant
	-- mergers are "every other radiant kind" as far as each other is
	-- concerned, which is precisely what keeps the two of them from
	-- consuming each other mid-operation.
	if kind ~= "ball" and part:GetAttribute("IsRadiant") then
		return nil
	end

	-- a magnet mid-pull is live and has to be waited out, same as a bomb
	-- already exploding — mirrors MagnetFuse/SellHandler's own "sellable
	-- right up until Pulling, not after" rule (3d)
	if kind == "magnet" and part:GetAttribute("Pulling") then
		return nil
	end

	return kind
end

-- ── vanish-explosion boom sound: primed up front, same reasoning
-- BombFuse/RadiantBombFuse give theirs — avoids the audible delay of
-- asking a client to build+load a fresh Sound at the moment it's needed.
-- Parented to the splitter for now purely so it's primed against a live
-- Instance; explodeAt reparents it to its own standalone anchor before
-- the splitter itself is destroyed.
local boomSound = Instance.new("Sound")
boomSound.SoundId = BOOM_SND
boomSound.Volume = 0
boomSound.Parent = splitter
boomSound:Play()
boomSound:Stop()
boomSound.Volume = BOOM_VOL

-- ── vanish-explosion VFX/flash — LOOKS like RadiantBombFuse's own: an
-- expanding neon ball that keeps cycling through this splitter's own
-- reversedRainbow() for as long as it's on screen (instead of BombFuse's
-- fixed orange -> red), and a billboard flash that pops straight to pure
-- white (instead of BombFuse's white -> yellow) ──
local function vfx(pos, blastRadius)
	local r = blastRadius * VFX_SCALE

	local ball = Instance.new("Part")
	ball.Shape, ball.Anchored, ball.CanCollide, ball.CanQuery = Enum.PartType.Ball, true, false, false
	ball.Material, ball.Color = Enum.Material.Neon, reversedRainbow()
	ball.Size, ball.Position, ball.Parent = Vector3.new(1, 1, 1), pos, WS

	local expand = TS:Create(ball,
		TweenInfo.new(VFX_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
		{ Size = Vector3.new(r, r, r) * 2 })
	local fade = TS:Create(ball,
		TweenInfo.new(VFX_TIME * 0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Transparency = 1 })

	local hueConn = RS.Heartbeat:Connect(function()
		if ball.Parent then
			ball.Color = reversedRainbow()
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
-- BombFuse's own revertMimic
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

-- ── neutralize: strips the behavior off something this splitter has just
-- claimed — see header point 7. Called synchronously, as part of the same
-- claim that sets SplitPending, so nothing gets a single frame to act on
-- its own after being claimed.
--
-- Destroying a Script stops its threads and drops its connections (the
-- same mechanism BallManager's triggerCollapse relies on when it strips
-- fuses to freeze the board), which is what actually stops a mimic
-- walking out of the convergence tween, a magnet re-writing its own Size
-- every frame from MagnetFuse's shrink loop, or a bomb detonating from
-- inside the split. The part is destroyed a fraction of a second later
-- either way — this just makes that fraction of a second deterministic. ──
local function neutralize(part, kind)
	-- an awake mimic's legs are its own children, so they'd be destroyed
	-- with it regardless — but they don't shrink with the convergence
	-- tween (separate parts, separate sizes), so a mimic absorbed with
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

-- fires the blast at `pos` and destroys `splitter` — called once the
-- vanish shrink tween finishes, from vanishSplitter below. Sequenced
-- EXACTLY the way BombFuse's own explode() (and RadiantBombFuse's) is:
-- build+reparent the sound anchor first, THEN destroy the exploding
-- part, THEN vfx()/flash()/the impulse pass — not a from-scratch
-- ordering of our own. (An earlier version of this file destroyed
-- splitter before doing any of this, which is what actually caused the
-- explosion to get stuck: destroying splitter also destroys this script
-- and everything still parented under it, including the not-yet-
-- reparented boomSound, so reparenting it moments later threw and
-- aborted the whole sequence before vfx()/flash() ever ran.)
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

	splitter:Destroy()
	vfx(pos, blastRadius)
	flash(pos, blastRadius)

	-- splitter is already gone from folder:GetChildren() at this point
	-- (just Destroy()'d above), same reason BombFuse's own loop doesn't
	-- need a `part ~= splitter` check either
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

-- whole-number rounding, floored at MIN_SPLIT_SIZE — see header point 1
-- for why each of the three results is independently size*2/3 rather
-- than a conserve-the-total halving. Only ever called on a size that's
-- already passed the MIN_SPLIT_SIZE eligibility check below, so the
-- MIN_SPLIT_SIZE floor here is belt-and-braces, not the normal case.
local function computeThirdSize(size)
	return math.max(MIN_SPLIT_SIZE, math.round(size * (2 / 3)))
end

-- Same shape as SplitterFuse's own splitTouched (converge-then-destroy,
-- kicked off in its own task.spawn so the caller's shrink/cooldown
-- bookkeeping proceeds on schedule) — just three hand-offs instead of
-- two, all sharing `kind` (a bomb splits into three bombs, a mimic into
-- three mimics, etc. — see header point 3), fanned out 120° apart instead
-- of a straight opposite pair, and with exactly one of the three flagged
-- radiant whenever that kind supports it.
local function splitTouched(part, size, kind)
	local resultSize = computeThirdSize(size)
	local color = part.Color
	-- absorbing something RADIANT makes every result radiant, roll or no
	-- roll — see header point 2. Read here, synchronously, for the same
	-- reason `color` above is: `part` is neutralized on the next line and
	-- destroyed at the end of the convergence below, a full
	-- SPLIT_CONVERGE_TIME before any result is actually spawned.
	-- (neutralize() strips scripts, not attributes, so this would survive
	-- it — read first anyway rather than relying on that.) Compared
	-- against true rather than read for plain truthiness because
	-- BallManager's convertRadiantToRegular sets IsRadiant to false rather
	-- than clearing it, so the attribute can exist and mean "not radiant".
	local sourceRadiant = part:GetAttribute("IsRadiant") == true

	-- Claimed synchronously, before anything below yields, and neutralized
	-- in the same breath: from this line on the part is inert, and every
	-- other splitter/merger scan on the board skips it — see header point 7
	part:SetAttribute("SplitPending", true)
	neutralize(part, kind)

	if _G.BallManagerUntrack then
		_G.BallManagerUntrack(part)
	else
		warn("[RadiantSplitterFuse] _G.BallManagerUntrack missing — BallManager may not have finished loading yet")
	end

	-- all three results spawn centred on the splitter itself and grow
	-- outward around that point, so they emerge from its middle rather
	-- than its feet; BallManager raises that centre only if a result would
	-- otherwise grow down through the platform — see resultCenterY there.
	local splitterCenter = splitter.Position

	se:FireAllClients("positional", part.Position, SPLIT_SND, SPLIT_VOL)

	part.Anchored = true

	local moveInfo = TweenInfo.new(SPLIT_CONVERGE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
	local shrinkInfo = TweenInfo.new(SPLIT_CONVERGE_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)

	local move = TS:Create(part, moveInfo, { Position = splitterCenter })
	local shrink = TS:Create(part, shrinkInfo, { Size = Vector3.new(0, 0, 0) })
	move:Play()
	shrink:Play()

	task.spawn(function()
		task.wait(SPLIT_CONVERGE_TIME)
		move:Destroy()
		shrink:Destroy()

		if part.Parent then part:Destroy() end

		local baseAngle = math.random() * math.pi * 2
		-- whether a radiant result is even possible for this kind: without
		-- a Radiant<Kind>Fuse to give it, an IsRadiant-flagged result is a
		-- radiant with no behavior at all (applyRadiantOverlay only warns)
		-- — see radiantSupported and header point 2
		local canBeRadiant = radiantSupported[kind] == true

		if _G.SpawnSplitResultKind then
			local immuneUntil = os.clock() + SPLIT_IMMUNITY
			for i = 1, 3 do
				local angle = baseAngle + (i - 1) * (math.pi * 2 / 3)
				local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
				-- per-result roll, replacing the old one-of-three index:
				-- each result is its own RESULT_RADIANT_CHANCE coin, and a
				-- radiant source skips the coin entirely and makes all three
				-- radiant — see header point 2
				local resultRadiant = canBeRadiant
					and (sourceRadiant or math.random() < RESULT_RADIANT_CHANCE)
				local result = _G.SpawnSplitResultKind(splitterCenter, resultSize, color, dir, kind, resultRadiant)
				if result then
					result:SetAttribute("SplitImmuneUntil", immuneUntil)
				end
			end
		else
			warn("[RadiantSplitterFuse] _G.SpawnSplitResultKind missing — BallManager may not have finished loading yet")
		end
	end)
end

-- ── hard per-pair collision exclusion — identical to SplitterFuse's own,
-- just scoped to every kind this splitter can actually touch rather than
-- plain balls only ──
local splitterNoCollisionFolder = Instance.new("Folder")
splitterNoCollisionFolder.Name = "SplitterNoCollision"
splitterNoCollisionFolder.Parent = splitter

local function ensureNoCollisionWithBall(part)
	if not part or not part:IsA("BasePart") or part == splitter then return end
	-- name-based rather than eligibleKind(): this is a physics exclusion,
	-- and something that's ineligible to be SPLIT (a radiant bomb, a
	-- pulling magnet) still shouldn't be shoving this splitter around
	if not nameToKind[part.Name] then return end

	for _, existing in ipairs(splitterNoCollisionFolder:GetChildren()) do
		if existing:IsA("NoCollisionConstraint") and existing.Part1 == part then
			return
		end
	end

	local constraint = Instance.new("NoCollisionConstraint")
	constraint.Name = "NoCollision_Splitter"
	constraint.Part0 = splitter
	constraint.Part1 = part
	constraint.Parent = splitterNoCollisionFolder
end

for _, part in ipairs(folder:GetChildren()) do
	ensureNoCollisionWithBall(part)
end

local ballAddedConn = folder.ChildAdded:Connect(function(part)
	ensureNoCollisionWithBall(part)
end)

-- ── this splitter's own end-of-life: shrink to 0, then detonate — see
-- header point 4. Caller is responsible for disconnecting the Heartbeat
-- loop before this runs, same as SplitterFuse's own vanishSplitter ──
local function vanishSplitter()
	local shrink = TS:Create(
		splitter,
		TweenInfo.new(VANISH_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.In),
		{ Size = Vector3.new(0, 0, 0) }
	)
	shrink:Play()
	shrink.Completed:Wait()

	explodeAt(splitter.Position) -- destroys splitter itself too — see that function's own comment
end

-- ── ambient hum: fired once, keeps playing (and following this
-- splitter around) on its own from here — see header point 6 ──
se:FireAllClients("attachedLoop", splitter, AMBIENT_SND, AMBIENT_VOL)

-- ── color: cycling from the instant this splitter exists, no
-- SplitterFuse-style "looks like a plain ball while falling" disguise
-- phase — same as every other radiant kind (ball/bomb/magnet), which
-- all read as visibly radiant immediately rather than only once
-- something else happens. hueOffset above is already a fresh
-- math.random() per instance, so this also starts at a random point in
-- the loop, same as those. Runs for this splitter's whole lifetime (not
-- just post-wake), and is the ONLY place splitter.Color gets set now —
-- the old post-wake Heartbeat loop below used to set it too, which is
-- redundant with this running the whole time regardless of wake state.
local colorConn
colorConn = RS.Heartbeat:Connect(function()
	if not splitter.Parent then
		colorConn:Disconnect()
		return
	end
	splitter.Color = reversedRainbow()
end)

task.spawn(function()
	local colY = folder:GetAttribute("CollisionRegainY") or FALLBACK_COL_Y
	while splitter.Parent and splitter.Position.Y <= colY do
		RS.Heartbeat:Wait()
	end
	if not splitter.Parent then return end

	local onCooldown = false
	local nextAbsorbAt = 0
	local groundedFrames = 0

	local pullAttachment = Instance.new("Attachment")
	pullAttachment.Name = "CenterPullAttachment"
	pullAttachment.Parent = splitter

	local pullForce = Instance.new("VectorForce")
	pullForce.Name = "CenterPullForce"
	pullForce.Attachment0 = pullAttachment
	pullForce.RelativeTo = Enum.ActuatorRelativeTo.World
	pullForce.ApplyAtCenterOfMass = true
	pullForce.Force = Vector3.new(0, 0, 0)
	pullForce.Parent = splitter

	local hbConn
	hbConn = RS.Heartbeat:Connect(function(dt)
		if not splitter.Parent then
			hbConn:Disconnect()
			if ballAddedConn then ballAddedConn:Disconnect() end
			return
		end

		splitter.CollisionGroup = CG.SplitterActive

		do
			local pos = splitter.Position
			local offset = Vector3.new(-pos.X, 0, -pos.Z)
			local dist = offset.Magnitude
			if dist > 0.01 then
				local t = math.clamp(dist / CENTER_PULL_RADIUS, 0, 1)
				local accel = CENTER_PULL_MIN_ACCEL + (CENTER_PULL_MAX_ACCEL - CENTER_PULL_MIN_ACCEL) * t
				pullForce.Force = (offset / dist) * accel * splitter.AssemblyMass
			else
				pullForce.Force = Vector3.new(0, 0, 0)
			end
		end

		-- color itself is handled by the standalone colorConn above now
		-- (runs for this splitter's whole lifetime, not just post-wake)
		-- — see header point 5

		if math.abs(splitter.AssemblyLinearVelocity.Y) <= GROUNDED_VY then
			groundedFrames = groundedFrames + 1
		else
			groundedFrames = 0
		end
		if groundedFrames < GROUNDED_FRAMES then return end

		if onCooldown or os.clock() < nextAbsorbAt then return end

		local pos = splitter.Position
		local r1 = splitter.Size.X / 2

		local splitHappened = false
		local vanishing = false

		for _, part in ipairs(folder:GetChildren()) do
			if part ~= splitter and part:IsA("BasePart") then
				-- every "may this be absorbed at all" question — kinds,
				-- radiant, pet mimics, pulling magnets — is answered in
				-- one place now; see eligibleKind and header point 3
				local kind = eligibleKind(part)

				if kind then
					local splitImmuneUntil = part:GetAttribute("SplitImmuneUntil")
					local mergeImmuneUntil = part:GetAttribute("MergeImmuneUntil")
					local immune = (splitImmuneUntil and os.clock() < splitImmuneUntil)
						or (mergeImmuneUntil and os.clock() < mergeImmuneUntil)
					local size = part:GetAttribute("TargetSize") or part.Size.X
					local pending = part:GetAttribute("SplitPending") or part:GetAttribute("MergePending")
					if size > MIN_SPLIT_SIZE and not pending and not immune then
						local r2 = part.Size.X / 2
						if (part.Position - pos).Magnitude <= r1 + r2 then
							splitTouched(part, size, kind)
							splitHappened = true

							local currentSize = splitter:GetAttribute("TargetSize") or splitter.Size.X
							local nextSize = currentSize - SHRINK_PER_SPLIT

							if nextSize <= MIN_SPLITTER_SIZE then
								splitter:SetAttribute("TargetSize", MIN_SPLITTER_SIZE)
								vanishing = true
								break
							end

							splitter:SetAttribute("TargetSize", nextSize)
							break
						end
					end
				end
			end
		end

		if not splitHappened then return end

		if vanishing then
			hbConn:Disconnect()
			if ballAddedConn then ballAddedConn:Disconnect() end

			pullForce.Force = Vector3.new(0, 0, 0)
			pullForce:Destroy()
			pullAttachment:Destroy()

			local floorShrink = TS:Create(
				splitter,
				TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = Vector3.new(MIN_SPLITTER_SIZE, MIN_SPLITTER_SIZE, MIN_SPLITTER_SIZE) }
			)
			floorShrink:Play()
			floorShrink.Completed:Wait()

			task.spawn(vanishSplitter)
			return
		end

		splitter.CollisionGroup = CG.SplitterActive
		splitter.CanCollide = true

		local finalSize = splitter:GetAttribute("TargetSize")
		TS:Create(splitter, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(finalSize, finalSize, finalSize) }):Play()

		onCooldown = true
		nextAbsorbAt = os.clock() + COOLDOWN
		task.delay(COOLDOWN, function()
			onCooldown = false
		end)
	end)
end)