--[[
    SplitterFuse (Script)
    Path: ReplicatedStorage → Splitter
    Parent: Splitter
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 15:18:20
]]
--[[
	SplitterFuse (Script) — place inside the Splitter template in ReplicatedStorage
	(ReplicatedStorage.Splitter.SplitterFuse).

	BallManager.spawnSplitter launches/grows/settles a splitter with the
	exact same physics as a regular ball — this script never touches any
	of that. Everything below only starts once this script itself starts
	running, which (same as BombFuse/MagnetFuse) is the instant
	spawnSplitter parents the clone into the shared Balls folder.

	Lifecycle:
	  1. Nothing happens until the splitter crosses the same Y threshold
	     BallManager's own onHB uses to regain a settling ball's collision
	     (COL_Y there — exposed on the Balls folder as the
	     CollisionRegainY attribute so this script reads the exact same
	     value rather than duplicating a number that could drift out of
	     sync). Until that crossing, it just sits there looking/behaving
	     like a completely normal ball (still in CG.Balls, still solid,
	     default color) — this is deliberately the same instant a regular
	     ball would settle, not a separate timer synced to it.
	  2. It then wakes up: switches into CG.SplitterActive (declared, and
	     wired non-collidable against every ball-ish group, in
	     ReplicatedStorage.CollisionGroups) so it passes straight through
	     every ball/bomb/magnet/mimic/radiant from here on, while
	     remaining solid against the platform, and starts pulsing between
	     its default and pulse color. Note that two awake splitters DO
	     still collide with each other — there has never been a
	     SplitterActive-vs-itself rule; add passesThroughSelf to that
	     entry in the module if that's ever meant to change.
	  3. From that instant, one Heartbeat loop does three things every
	     frame: re-pins the collision group (onHB's own COL_Y collision-
	     regain fires in the same frame the splitter crosses that
	     threshold, so this re-assert just guards against any stray
	     ordering rather than racing a delayed one), drives the
	     saw-wave pulse — pops instantly to PULSE_COLOR at the top of each
	     cycle, then eases back down to DEFAULT_COLOR over the rest of
	     PULSE_TIME before popping again — and — whenever not on
	     cooldown — checks its own current radius against every live,
	     splittable regular ball ("Ball" by name specifically; every
	     other special just passes through untouched) for the first one
	     actually touching it.

	The splitter's numDisplay is never set at all — BallManager's own
	spawnSplitter deliberately skips setDisplay for it, exactly like
	spawnBomb/spawnMagnet skip it for theirs (see BallManager). This
	script has no display to avoid touching in the first place; it only
	ever touches Size/TargetSize, which is a different thing.

	A touch is detected by distance against the splitter's own current
	radius (Size.X / 2, re-read every frame so it stays accurate as the
	splitter's own size changes under it) plus the ball's radius —
	GetTouchingParts() doesn't work here since the splitter is
	deliberately non-collidable against the Balls group (see lifecycle step
	2, above): with collision response off between those groups, the
	engine never registers them as touching, so GetTouchingParts() never
	returns anything for it.

	Splitting itself (splitTouched, below) does NOT destroy the touched
	ball the instant it's found — same as MergerFuse's own mergeTouched,
	it's pulled INTO the splitter's own center first, shrinking to nothing
	over SPLIT_CONVERGE_TIME, and only once that convergence finishes is
	it destroyed and handed off to BallManager's own _G.SpawnSplitResult
	twice for the two halves — which now spawn at size 0, pinned to the
	splitter's own bottom, and grow upward from there, shooting outward in
	opposite directions (see spawnSplitResult's own comment in
	BallManager), rather than the old approach of nudging two full-size
	halves apart in place. This keeps both halves fully owned by
	BallManager's normal tracked/onHB machinery from the instant they
	exist, so they fall/split again later exactly like any other settled
	ball, with nothing left for this script to babysit. Because the
	convergence takes real time, splitTouched kicks it off in its own
	task.spawn and returns immediately, letting the Heartbeat loop's own
	shrink/vanish bookkeeping for the splitter proceed on schedule
	regardless — see splitTouched's own comment. This is the one piece of
	SplitterFuse deliberately brought in line with MergerFuse; the
	splitter's own shrink-per-split and COOLDOWN logic further below are
	untouched. _G.BallManagerUntrack is called right away so BallManager's
	own onHB doesn't mistake the eventual Destroy() for an unexpected fall
	and fire off ITS OWN fallback split on top of this one (see that
	hook's comment).

	Split sizes are whole-number floor/ceil (49 -> 25 + 24) except
	anywhere in (MIN_SPLIT_SIZE, 5] — a 4 or a 5 can't floor/ceil into
	two halves that are both >= MIN_SPLIT_SIZE (3), so anything in that
	band halves into two flat MIN_SPLIT_SIZEs instead (see computeHalves).
	A ball already at MIN_SPLIT_SIZE is the floor and is skipped
	entirely, same as if the splitter weren't touching it — no shrink,
	no cooldown, no sound.

	Radiance is inherited: splitting a RADIANT ball produces two radiant
	halves rather than two regular ones. A radiant ball is an ordinary
	"Ball" carrying an overlay (the IsRadiant attribute plus a RadiantFuse
	cloned onto it — see BallManager's applyRadiantOverlay), which is why
	the scan below finds it splittable like any other ball in the first
	place; the only thing this adds is carrying that overlay onto both
	halves. Handled by spawning the halves through
	_G.SpawnSplitResultKind — see spawnHalf, below, for why that entry
	point rather than _G.SpawnSplitResult.

	Every successful split actually shrinks the splitter itself (Size +
	TargetSize) by SHRINK_PER_SPLIT studs, same small Quad-out tween each
	time, so it visibly gets smaller split by split — right up until a
	split's shrink would take it down to MIN_SPLITTER_SIZE or below. That
	split skips the small tween entirely: no further scanning/pulsing,
	and instead of shrinking it the usual amount it eases its actual
	*current* size (already small from every split before this one, not
	the size it spawned at) down to 0 over 1 second (exponential ease-in),
	flashes with the same collapse-style billboard flash
	SellService.collapseSell uses (no highlight fade-in — just the
	flash), and destroys itself.
]]

local RS = game:GetService("RunService")
local Rep = game:GetService("ReplicatedStorage")
local TS = game:GetService("TweenService")

local splitter = script.Parent
local folder = splitter.Parent -- already parented into Workspace.Balls by BallManager

local ballT = Rep:WaitForChild("Ball")
local se = Rep:WaitForChild("SoundEvents")

-- collision group names (and every rule about what SplitterActive passes
-- through) live in ReplicatedStorage.CollisionGroups — this script only
-- ever re-pins the group, never registers or pairs anything
local CG = require(Rep:WaitForChild("CollisionGroups"))

-- config: activation
local FALLBACK_COL_Y = 0.5 -- only used if the Balls folder's CollisionRegainY attribute isn't set yet (shouldn't happen — BallManager sets it at load, well before any splitter can spawn); must match BallManager's own COL_Y

-- config: pulse — saw wave: pops instantly to PULSE_COLOR, then eases
-- back down to DEFAULT_COLOR over the rest of the cycle before popping
-- again. Driven by hand off TS:GetValue (one number per frame) rather
-- than an actual Tween, the same way MagnetFuse recombines its shine's
-- size curves, since there's no "instant snap" easing to chain onto a
-- normal Tween/Reverses pair.
local DEFAULT_COLOR, PULSE_COLOR = Color3.fromRGB(152, 0, 255), Color3.fromRGB(255, 0, 255)
local PULSE_TIME = 3 -- one full pop+decay cycle; tune to taste

-- config: split mechanics
local SHRINK_PER_SPLIT = 2
local MIN_SPLITTER_SIZE = 5 -- floor on the splitter's own (real, visible) size — see header; the split whose shrink would land at or below this vanishes instead, same split, starting from its current already-shrunk size
local COOLDOWN = 0.1
-- grounded gate: the splitter may not absorb anything until it has actually
-- come to rest on the platform. The wake threshold (CollisionRegainY) is
-- crossed by the splitter's CENTER on the way UP through the platform, still
-- travelling at ~66 studs/s, and the launch's horizontal kick is small enough
-- that it arrives within about a stud of dead centre — i.e. right inside the
-- settled pile, where the r1+r2 distance test below (which does not care about
-- collision at all) matches immediately. The splitter's own centre is what
-- both halves are then spawned around, and at that instant it is BELOW
-- BallManager's FALL_Y: both halves get created underneath the platform,
-- onHB reads them as settled-and-fallen on its next pass, and each one
-- queues 2 replacement balls before being cleared by VOID_FALLBACK_TIMEOUT.
-- (BallManager's resultCenterY is the floor behind this, but it only keeps
-- a result out of the platform — it can't tell that the splitter itself had
-- no business splitting yet, which is what this gate is for.)
-- Vertical speed is what separates "mid-arc" from "resting": gravity changes
-- it by ~3.3 studs/s per frame at 60Hz, so requiring it to stay under
-- GROUNDED_VY for GROUNDED_FRAMES consecutive frames can't be satisfied at the
-- apex (where it momentarily passes through zero) but is always true once the
-- splitter is sitting on the platform. Re-checked every frame rather than
-- latched once, so a splitter knocked airborne again also stops splitting
-- until it lands.
local GROUNDED_VY = 1.5 -- studs/s of vertical speed still counted as "at rest"
local GROUNDED_FRAMES = 2 -- consecutive frames under GROUNDED_VY before absorbing is allowed
local SPLIT_IMMUNITY = 0.75 -- seconds a freshly-created split half is skipped by this loop's touch check — the two halves shoot outward from the splitter's own bottom (see spawnSplitResult), so right at spawn they're still well inside r1+r2 of the splitter that just made them; without this they're eligible to be immediately re-split the instant COOLDOWN clears, before they've had any real chance to roll away
local MIN_SPLIT_SIZE = 3 -- a ball already this small can't be split any further; also the flat halved size a 3-5 ball produces (see computeHalves)
local SPLIT_CONVERGE_TIME = 0.3 -- seconds the touched ball takes to visually move into the splitter (shrinking to nothing as it goes) before the two halves spawn — same shape/duration as MergerFuse's own CONVERGE_TIME, see splitTouched
local SPLIT_SND, SPLIT_VOL = "rbxassetid://101410298856316", 1

-- config: vanish (splitter's own end-of-life — see header)
local VANISH_TIME = 1 -- seconds to ease down to size 0
local COLLAPSE_FLASH_COLOR = Color3.fromRGB(255, 0, 255) -- same value SellService uses for its own collapse flash
-- the vanish flash reuses SellClient's shared sellFlash/attachedFlash pipeline
-- (same one collapseSell/mimicAbsorb/petMimicAbsorb all go through), but
-- reads bigger and pops in from black instead of the shared default white —
-- these two are new, optional trailing args on attachedFlash (see
-- SellClient), so every other attachedFlash caller is unaffected
local VANISH_FLASH_SCALE_MULTIPLIER = 2 -- stacks on top of SellClient's own size-based SELL_FLASH_SCALE
local VANISH_FLASH_START_COLOR = Color3.new(0, 0, 0)

-- config: center pull — a gentle, constant horizontal nudge back toward
-- (0, 0) on the platform, active for as long as the splitter is awake
-- (same window as the pulse/scan loop below). Modeled as an actual
-- physics force (VectorForce, scaled by the splitter's own mass) rather
-- than hand-steering AssemblyLinearVelocity, so it layers on top of
-- normal collisions/bounces instead of fighting or overriding them.
-- Ramps from CENTER_PULL_MIN_ACCEL right at the center up to
-- CENTER_PULL_MAX_ACCEL once CENTER_PULL_RADIUS studs out, linearly in
-- between — "slightly more aggressive" the further out it drifts, never
-- a hard snap back.
local CENTER_PULL_RADIUS = 50 -- studs from (0,0) at which the pull reaches its max strength
local CENTER_PULL_MIN_ACCEL = 2 -- studs/s^2, applied even near the center
local CENTER_PULL_MAX_ACCEL = 5 -- studs/s^2, applied at/beyond CENTER_PULL_RADIUS studs out

-- whole-number floor/ceil halving, except anywhere in (MIN_SPLIT_SIZE, 5],
-- which can't floor/ceil into two halves that are both >= MIN_SPLIT_SIZE,
-- so it halves into two flat MIN_SPLIT_SIZEs instead — see header. Only
-- ever called on a size that's already passed the MIN_SPLIT_SIZE
-- eligibility check below, so `size` here is always > MIN_SPLIT_SIZE.
local function computeHalves(size)
	if size <= 5 then
		return MIN_SPLIT_SIZE, MIN_SPLIT_SIZE
	end
	local a = math.floor(size / 2)
	return a, size - a
end

-- Spawns one half through BallManager, carrying `radiant` onto it.
--
-- Routed through _G.SpawnSplitResultKind rather than _G.SpawnSplitResult
-- because only the Kind entry point takes a radiant flag. For kind
-- "ball" the two are the same function line for line over in
-- BallManager — same clone, same size-0 centre-pinned grow, same
-- hand-simulated hop arc, same setDisplay/density, same
-- BALLS_GROUP-and-unanchor handoff, same `tracked` entry — the Kind one
-- just additionally applies the radiant overlay before parenting, the
-- same way spawnBall does for a ball that rolls radiant at spawn. So a
-- non-radiant split comes out of this exactly as it did before, and the
-- splitter doesn't need two different call sites to pick between.
-- ("ball" is passed explicitly rather than left to default, since the
-- stock splitter only ever splits plain balls — splitting SPECIALS into
-- specials is RadiantSplitterFuse's job, and passing the kind through is
-- what that would change here.)
--
-- _G.SpawnSplitResult is kept as a fallback for a BallManager that
-- predates the Kind entry point: the split still happens there, the
-- halves just come out regular, and it says so once per half rather
-- than silently dropping the radiance.
local function spawnHalf(centerPos, size, color, hopDir, radiant)
	if _G.SpawnSplitResultKind then
		return _G.SpawnSplitResultKind(centerPos, size, color, hopDir, "ball", radiant)
	end

	if _G.SpawnSplitResult then
		if radiant then
			warn("[SplitterFuse] _G.SpawnSplitResultKind missing — a radiant ball's halves are spawning regular")
		end
		return _G.SpawnSplitResult(centerPos, size, color, hopDir)
	end

	return nil
end

-- Mirrors MergerFuse's own mergeTouched, just for one absorbed ball
-- instead of two: rather than destroying `part` on the spot, it's pulled
-- INTO the splitter's own center (captured once, up front, since the
-- splitter keeps drifting under its own center-pull force for the
-- SPLIT_CONVERGE_TIME this animation takes) while simultaneously easing
-- its Size down to 0, so it visibly shrinks into the splitter as it
-- converges rather than just vanishing in place. Only once that
-- convergence finishes is `part` actually destroyed and the two halves
-- handed off to BallManager's own _G.SpawnSplitResult — which, mirroring
-- spawnMergeResult, spawns them at size 0 pinned to the splitter's own
-- *bottom* and grows them upward from there (see spawnSplitResult's own
-- comment) so they shoot outward rather than appear stacked, instead of
-- the old nudge-apart-at-full-size approach.
--
-- Like mergeTouched, this doesn't hand off to BallManager the instant
-- `part` is found — it kicks off the convergence in its own task.spawn
-- and returns immediately, so the Heartbeat loop's own shrink/vanish
-- bookkeeping for the splitter proceeds on schedule (this fix
-- deliberately leaves that bookkeeping, and COOLDOWN, untouched) rather
-- than waiting on however long the visual convergence takes.
-- _G.BallManagerUntrack is called on `part` right away (same reasoning
-- as mergeTouched's own calls) so BallManager's onHB doesn't mistake its
-- eventual Destroy() for an unexpected fall, and a SplitPending attribute
-- is claimed synchronously (mirroring MergePending) so no other splitter
-- — or this one, next frame — tries to absorb the same ball a second
-- time while it's still mid-convergence; the eligibility scan below and
-- MergerFuse's own candidate scan both check for it.
local function splitTouched(part, size)
	local sizeA, sizeB = computeHalves(size)
	local color = part.Color
	-- read here, synchronously, for exactly the same reason `color` above
	-- is: `part` is destroyed at the end of the convergence below, a full
	-- SPLIT_CONVERGE_TIME before either half is actually spawned, so
	-- anything the halves need off it has to be captured now. Compared
	-- against true rather than read for plain truthiness because
	-- BallManager's convertRadiantToRegular sets IsRadiant to false rather
	-- than clearing it, so the attribute can legitimately exist and mean
	-- "not radiant".
	local radiant = part:GetAttribute("IsRadiant") == true

	part:SetAttribute("SplitPending", true)

	if _G.BallManagerUntrack then
		_G.BallManagerUntrack(part)
	else
		warn("[SplitterFuse] _G.BallManagerUntrack missing — BallManager may not have finished loading yet")
	end

	-- both halves spawn centred on the splitter itself and grow outward
	-- around that point, so they emerge from its middle rather than its
	-- feet. BallManager raises that centre only if a half would otherwise
	-- grow down through the platform — see resultCenterY there.
	local splitterCenter = splitter.Position

	se:FireAllClients("positional", part.Position, SPLIT_SND, SPLIT_VOL)

	-- freeze it in place so the convergence tween below reads cleanly (no
	-- fighting gravity/momentum mid-animation) — it's doomed either way,
	-- on its way to Destroy() the instant it finishes moving in
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

		-- opposite hop directions so the two halves visibly shoot apart
		-- rather than in two independent random ones — see
		-- spawnSplitResult's own comment
		local angle = math.random() * math.pi * 2
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		if _G.SpawnSplitResultKind or _G.SpawnSplitResult then
			local immuneUntil = os.clock() + SPLIT_IMMUNITY
			-- both halves inherit the source ball's radiance — see
			-- spawnHalf and the header
			local a = spawnHalf(splitterCenter, sizeA, color, dir, radiant)
			local b = spawnHalf(splitterCenter, sizeB, color, -dir, radiant)
			if a then a:SetAttribute("SplitImmuneUntil", immuneUntil) end
			if b then b:SetAttribute("SplitImmuneUntil", immuneUntil) end
		else
			warn("[SplitterFuse] _G.SpawnSplitResult missing — BallManager may not have finished loading yet")
		end
	end)
end

-- Hard per-pair collision exclusion for the splitter. Collision groups are
-- still the primary broad-phase filter, but under heavy physics load we also
-- install NoCollisionConstraints so a transient collision-group ordering
-- issue cannot make the splitter physically collide with a regular ball.
local splitterNoCollisionFolder = Instance.new("Folder")
splitterNoCollisionFolder.Name = "SplitterNoCollision"
splitterNoCollisionFolder.Parent = splitter

local function ensureNoCollisionWithBall(part)
	if not part or not part:IsA("BasePart") or part == splitter then return end
	if part.Name ~= ballT.Name then return end

	-- part is the BALL, which never itself lives under
	-- splitterNoCollisionFolder (the constraint does) — that made the old
	-- `part:IsDescendantOf(splitterNoCollisionFolder)` check here a no-op
	-- that could never actually skip anything. Check the folder's
	-- children for an existing constraint pointed at this ball instead,
	-- so a ball that somehow triggers this twice doesn't get a second,
	-- redundant NoCollisionConstraint.
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

-- Install exclusions for balls that already exist, then catch newly spawned
-- balls. The constraints are parented to the splitter, so they disappear
-- automatically when the splitter is destroyed.
for _, part in ipairs(folder:GetChildren()) do
	ensureNoCollisionWithBall(part)
end

local ballAddedConn = folder.ChildAdded:Connect(function(part)
	ensureNoCollisionWithBall(part)
end)

-- the splitter's own end-of-life: a split's shrink just would've taken
-- it to MIN_SPLITTER_SIZE or below, so instead of that shrink it eases
-- its actual current size (already small from every real shrink before
-- this point) down to 0 over VANISH_TIME (exponential ease-in), flashes
-- with the same collapse-style billboard flash SellService.collapseSell
-- uses — no highlight fade-in, just the flash — and destroys itself.
-- Caller is responsible for disconnecting the Heartbeat loop before
-- this runs, same as any other path off it.
local function vanishSplitter()
	local size = splitter.Size.X -- captured before the tween below touches it — its current, already-shrunk size

	local shrink = TS:Create(
		splitter,
		TweenInfo.new(VANISH_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.In),
		{ Size = Vector3.new(0, 0, 0) }
	)
	shrink:Play()
	shrink.Completed:Wait()

	se:FireAllClients(
		"attachedFlash",
		splitter,
		size,
		COLLAPSE_FLASH_COLOR,
		VANISH_FLASH_START_COLOR,
		VANISH_FLASH_SCALE_MULTIPLIER
	)
	task.wait() -- let the event replicate with a valid splitter reference before Destroy() invalidates it
	splitter:Destroy()
end

-- ── dormant: looks/behaves exactly like a normal ball until it crosses
-- the same COL_Y threshold BallManager's own onHB uses to regain a
-- settling ball's collision — see header ──
splitter.Color = DEFAULT_COLOR

task.spawn(function()
	local colY = folder:GetAttribute("CollisionRegainY") or FALLBACK_COL_Y
	while splitter.Parent and splitter.Position.Y <= colY do
		RS.Heartbeat:Wait()
	end
	if not splitter.Parent then return end -- already gone (sold, knocked off, etc.) before ever waking

	local onCooldown = false
	local nextAbsorbAt = 0
	local pulseElapsed = 0
	local groundedFrames = 0 -- see GROUNDED_VY's own comment

	-- center-pull rig — see config comment above. Parented under the
	-- splitter itself so Destroy() (vanish, or any other despawn path)
	-- cleans both up for free, same as everything else on it.
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

		-- Defensive invariant: BallManager assigns SplitterActive at spawn and
		-- again at COL_Y; this re-pin is now only a safeguard against any other
		-- script accidentally changing the group, not the mechanism that makes
		-- the splitter safe at activation.
		splitter.CollisionGroup = CG.SplitterActive

		-- center pull: horizontal-only (Y left alone so this never fights
		-- gravity/the platform), ramped by how far out on the platform the
		-- splitter currently is — see config comment
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

		-- saw-wave pulse: instant pop to PULSE_COLOR, eased-out decay
		-- back to DEFAULT_COLOR over the rest of the cycle, then pop
		-- again — see header/config comment
		pulseElapsed = (pulseElapsed + dt) % PULSE_TIME
		local frac = pulseElapsed / PULSE_TIME
		local t = 1 - TS:GetValue(frac, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		splitter.Color = DEFAULT_COLOR:Lerp(PULSE_COLOR, t)

		-- grounded gate — see GROUNDED_VY's own comment. Deliberately placed
		-- AFTER the collision-group re-pin, the center pull and the pulse, so
		-- an airborne splitter still looks and behaves exactly as before; the
		-- only thing this holds back is absorbing.
		if math.abs(splitter.AssemblyLinearVelocity.Y) <= GROUNDED_VY then
			groundedFrames = groundedFrames + 1
		else
			groundedFrames = 0
		end
		if groundedFrames < GROUNDED_FRAMES then return end

		if onCooldown or os.clock() < nextAbsorbAt then return end

		-- distance against the splitter's own current radius (re-read
		-- every frame — see header) plus the ball's, since
		-- GetTouchingParts doesn't fire for a deliberately
		-- non-collidable pair
		local pos = splitter.Position
		local r1 = splitter.Size.X / 2

		-- Only the first eligible ball found in this Heartbeat is split
		-- (enforced by the break below, not just by convention).
		-- The cooldown then controls the next absorb, so at COOLDOWN = 0.1
		-- the splitter can absorb at most one ball every 0.1 seconds.
		local splitHappened = false
		local vanishing = false

		for _, part in ipairs(folder:GetChildren()) do
			if part ~= splitter and part:IsA("BasePart") and part.Name == ballT.Name then
				-- MergeImmuneUntil is checked alongside SplitImmuneUntil, mirroring
				-- MergerFuse's own scan: a freshly-spawned merge result is still
				-- anchored and mid grow-tween (its own sizeConn re-pinning its
				-- CFrame every frame), so absorbing it during that window meant
				-- splitTouched's convergence tween fought a CFrame that was being
				-- rewritten under it.
				local splitImmuneUntil = part:GetAttribute("SplitImmuneUntil")
				local mergeImmuneUntil = part:GetAttribute("MergeImmuneUntil")
				local immune = (splitImmuneUntil and os.clock() < splitImmuneUntil)
					or (mergeImmuneUntil and os.clock() < mergeImmuneUntil)
				local size = part:GetAttribute("TargetSize") or part.Size.X
				-- SplitPending: this ball is already mid-convergence into
				-- this (or another) splitter — see splitTouched. Now that
				-- an absorb takes SPLIT_CONVERGE_TIME rather than being
				-- instant, without this check a splitter could otherwise
				-- re-target the same ball once COOLDOWN clears, well
				-- before its first absorb has actually finished.
				-- MergePending: mirrors the same check MergerFuse's own
				-- candidate scan makes for SplitPending — a ball already
				-- mid-convergence into a merger shouldn't also be pulled
				-- into a splitter at the same time.
				local pending = part:GetAttribute("SplitPending") or part:GetAttribute("MergePending")
				if size > MIN_SPLIT_SIZE and not pending and not immune then
					local r2 = part.Size.X / 2
					if (part.Position - pos).Magnitude <= r1 + r2 then
						splitTouched(part, size)
						splitHappened = true

						local currentSize = splitter:GetAttribute("TargetSize") or splitter.Size.X
						local nextSize = currentSize - SHRINK_PER_SPLIT

						if nextSize <= MIN_SPLITTER_SIZE then
							-- this split's shrink would cross the floor —
							-- stop scanning (nothing left to shrink toward,
							-- and the splitter's about to vanish anyway)
							-- and handle the floor-shrink-then-vanish
							-- sequence once, below, same as any other split
							splitter:SetAttribute("TargetSize", MIN_SPLITTER_SIZE)
							vanishing = true
							break
						end

						splitter:SetAttribute("TargetSize", nextSize)

						-- One ball per Heartbeat, full stop. Without this break the
						-- loop kept going and split EVERY ball touching the splitter
						-- in the same frame — COOLDOWN is only applied after the loop,
						-- so it never constrained this — and every one of those splits
						-- captured the same splitterCenter, so SPLIT_CONVERGE_TIME
						-- later 2N halves all spawned stacked on a single point.
						-- MergerFuse's own scan has always stopped at one event per
						-- frame; this brings the splitter in line with it.
						break
					end
				end
			end
		end

		if not splitHappened then return end

		if vanishing then
			-- same floor-shrink-then-vanish sequence as before, just
			-- moved out here so it only ever runs once regardless of how
			-- many balls this frame's loop actually split
			hbConn:Disconnect()
			if ballAddedConn then ballAddedConn:Disconnect() end

			-- stop gravitating toward the center the instant the vanish
			-- sequence starts — the pull is otherwise only ever refreshed
			-- from inside this same Heartbeat loop, so disconnecting it
			-- above would just leave whatever force vector was set on the
			-- splitter's last live frame applied indefinitely (VectorForce
			-- keeps pushing with its last-set Force until told otherwise),
			-- fighting the shrink-to-0 tween below for the full
			-- floorShrink + VANISH_TIME it takes to actually disappear
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

		-- Keep the splitter in its dedicated non-ball collision group even during
		-- the rapid re-arm window. BallManager also enforces this at COL_Y.
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