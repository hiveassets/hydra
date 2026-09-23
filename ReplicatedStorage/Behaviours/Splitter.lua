--[[
    Splitter (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-23 00:26:23
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

	THE FIRST SPECIAL THAT MAKES MONEY

	A split turns a 4 or a 5 into two 3s, so this is the first behaviour
	where the server does real work rather than bookkeeping. All this
	module sends is

		ctx.report(ctx.ops.SPLIT, ctx.id, orbId)

	— two ids. Not the halves, not their sizes, not what the splitter
	shrinks to. The server looks both up in its own ledger, splits the
	orb with its own arithmetic, charges the splitter's budget, and sends
	the halves back as an ordinary SPAWN. There's no ninth split from a
	size-20 splitter whatever arrives on the wire.

	WHAT THIS DOES LOCALLY, AND WHY IT'S SAFE TO

	Everything you see happens on the frame of the touch: the pull, the
	shrink, the sound. The halves can't — their sizes are the server's —
	but the convergence is 0.3s long and the server's answer arrives well
	inside it, and the board holds the halves until the orb has landed
	(see ClientBoard's emergeAt). So nothing waits visibly on the network.

	That's only safe because the checks here match the server's exactly.
	An orb that has started converging is gone on screen; if the server
	then refused, the orb would be stranded on the ledger and the board
	would have to be rebuilt. So this only ever takes orbs the server
	will agree to (ctx.absorbable), and only once the splitter itself is
	live by the same measure (ctx.live).

	THE HALVES DON'T DEPEND ON THE SPLITTER

	The splitter's centre is written down the instant it acts (ctx.emergeAt)
	and the halves come out of that point. The splitter can be spent,
	stashed, collapsed or knocked off the edge in the 0.3s between and it
	changes nothing about where they appear. That was the lesson of the
	first attempt at this step, which had the halves look up the
	splitter's live part when they launched and spent two sessions on the
	consequences.

	WHAT WENT AWAY

	  * The NoCollisionConstraints — a folder of them, one per orb on the
	    board, rebuilt as orbs spawned, with its own ChildAdded listener.
	    They guarded against a collision-group ordering race under server
	    load, which was a replication race: the group assignment and the
	    part arriving separately. Nothing replicates now; the group is set
	    on this machine before the splitter wakes.
	  * _G.SpawnSplitResult / _G.SpawnSplitResultKind and their fallback
	    path, _G.BallManagerUntrack, the SoundEvents relay, and the
	    CollisionRegainY attribute read (COL_Y comes from the config both
	    sides already share).
	  * The SplitImmuneUntil / MergeImmuneUntil / SplitPending attribute
	    dance on other orbs' parts. The board tracks claims and immunity
	    itself; SplitPending is still set, only because StashClient reads it.

	Every number is SplitterFuse's, now in BoardConfig.SPLITTER.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Rep = game:GetService("ReplicatedStorage")
local CG = require(Rep:WaitForChild("CollisionGroups"))

local Splitter = {}

-- ── shrinking ─────────────────────────────────────────────────────────
-- Resizes the splitter around its BOTTOM rather than its centre.
--
-- The original tweened Size, and a part resizes around its centre — so a
-- splitter sitting on the platform lifted its own bottom clear of the
-- floor with every shrink, dropped back onto it, and jittered. Moving
-- the centre down by exactly the radius it lost keeps the bottom where
-- it was, so it shrinks into the floor rather than away from it.
--
-- Reads the size back after setting it, because Roblox clamps a part's
-- minimum size and the move has to match what actually happened.
local function setSizeFromBottom(part, size)
	local before = part.Size.X
	part.Size = Vector3.new(size, size, size)
	local after = part.Size.X
	part.CFrame = part.CFrame - Vector3.new(0, (before - after) / 2, 0)
end

-- Eases the size from wherever it is now to `target` over `time`,
-- bottom-pinned, on its own heartbeat. Returns false if the behaviour
-- stopped partway (stashed, collapsed, removed) — nothing is left
-- running to fight a stash's own resize the way a tween would be.
local function shrinkTo(ctx, target, time, style, direction)
	local part = ctx.part
	local from = part.Size.X
	local elapsed = 0
	while elapsed < time do
		local dt = RunService.Heartbeat:Wait()
		if not ctx.alive() then
			return false
		end
		elapsed += dt
		local alpha = TweenService:GetValue(math.clamp(elapsed / time, 0, 1), style, direction)
		setSizeFromBottom(part, from + (target - from) * alpha)
	end
	return true
end

-- ── dormant ───────────────────────────────────────────────────────────
-- Looks and behaves like a plain orb until it crosses COL_Y — the same
-- instant an ordinary orb gets its collision back. Returns false if it
-- left the board first.
local function waitForWake(ctx)
	local colY = ctx.config.COL_Y
	while ctx.part.Position.Y <= colY do
		RunService.Heartbeat:Wait()
		if not ctx.alive() then
			return false
		end
	end
	return true
end

-- ── the centre pull ───────────────────────────────────────────────────
-- A gentle constant push back toward (0, 0), stronger the further out it
-- drifts. A real force scaled by mass rather than steering the velocity,
-- so it layers on top of collisions instead of overriding them.
local function makeCenterPull(ctx)
	local attachment = Instance.new("Attachment")
	attachment.Name = "CenterPullAttachment"
	attachment.Parent = ctx.part

	local force = Instance.new("VectorForce")
	force.Name = "CenterPullForce"
	force.Attachment0 = attachment
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.ApplyAtCenterOfMass = true
	force.Force = Vector3.new(0, 0, 0)
	force.Parent = ctx.part

	local function destroy()
		if force.Parent then
			force:Destroy()
		end
		if attachment.Parent then
			attachment:Destroy()
		end
	end
	ctx.onStop(destroy)

	local cfg = ctx.config.SPLITTER
	local function update()
		local pos = ctx.part.Position
		local offset = Vector3.new(-pos.X, 0, -pos.Z)
		local dist = offset.Magnitude
		if dist > 0.01 then
			local t = math.clamp(dist / cfg.CENTER_PULL_RADIUS, 0, 1)
			local accel = cfg.CENTER_PULL_MIN_ACCEL + (cfg.CENTER_PULL_MAX_ACCEL - cfg.CENTER_PULL_MIN_ACCEL) * t
			force.Force = (offset / dist) * accel * ctx.part.AssemblyMass
		else
			force.Force = Vector3.new(0, 0, 0)
		end
	end

	return update, destroy
end

-- ── the send-off ──────────────────────────────────────────────────────
-- The budget is spent. Ease to the floor, then to nothing over a second,
-- then flash out of black. The server let go of this splitter the moment
-- the last split arrived, so this only has to clean up after itself.
local function sendOff(ctx, destroyPull)
	local cfg = ctx.config.SPLITTER
	local part = ctx.part

	-- Nothing can sell, stash or grab it from here: the ledger has
	-- already let it go.
	ctx.retire()

	-- The pull would otherwise keep pushing with whatever it last had for
	-- the whole second it takes to disappear.
	destroyPull()

	-- Held still for the send-off. It only ever splits while resting on
	-- the platform, so this pins it where it's sitting, and the shrink
	-- below can take it all the way down into the floor without the
	-- physics bouncing a shrinking ball around underneath it.
	part.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
	part.Anchored = true

	if not shrinkTo(ctx, cfg.FLOOR, cfg.SHRINK_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out) then
		return
	end

	local size = part.Size.X -- captured before the vanish touches it
	if not shrinkTo(ctx, 0, cfg.VANISH_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.In) then
		return
	end

	-- Same flash the old version borrowed from the collapse — bigger, and
	-- popping in from black — and on top, as the old attachedFlash always was.
	ctx.effects.flash(
		part.Position,
		size,
		cfg.VANISH_FLASH_COLOR,
		true,
		cfg.VANISH_FLASH_START,
		cfg.VANISH_FLASH_SCALE
	)
	ctx.remove()
end

-- ── awake ─────────────────────────────────────────────────────────────
local function run(ctx)
	local cfg = ctx.config.SPLITTER
	local part = ctx.part

	local updatePull, destroyPull = makeCenterPull(ctx)

	-- What this splitter is worth, tracked locally so the shrink and the
	-- send-off happen on the frame of the split. The server does the
	-- same arithmetic to its own copy (BoardRules.splitterAfterSplit)
	-- and its copy is the one that counts; they only disagree if a split
	-- is refused, and a refusal rebuilds the board from the ledger.
	local remaining = ctx.size

	local pulseElapsed = 0
	local groundedFrames, groundedTime = 0, 0
	local nextSplitAt = 0

	-- The small ease down after each split, driven from this loop rather
	-- than a tween so it can be bottom-pinned (see setSizeFromBottom). A
	-- split landing mid-shrink just restarts it from wherever it had got to.
	local shrinkFrom, shrinkElapsed = nil, 0

	while true do
		local dt = RunService.Heartbeat:Wait()
		if not ctx.alive() then
			return
		end

		if shrinkFrom then
			shrinkElapsed += dt
			local alpha = math.clamp(shrinkElapsed / cfg.SHRINK_TIME, 0, 1)
			local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			setSizeFromBottom(part, shrinkFrom + (remaining - shrinkFrom) * eased)
			if alpha >= 1 then
				shrinkFrom = nil
			end
		end

		-- Its own group from here on: passes through every orb, still
		-- solid against the platform. Re-pinned every frame as a guard
		-- against anything else changing it, as the original did — except
		-- while it's in the player's hands, where GrabClient's carry
		-- group is the right one and re-pinning would have it shove the
		-- person holding it.
		if not part:GetAttribute("Held") then
			part.CollisionGroup = CG.SplitterActive
		end

		updatePull()

		-- Saw-wave pulse: pops to PULSE_COLOR, eases back down to
		-- DEFAULT_COLOR over the rest of the cycle, pops again.
		pulseElapsed = (pulseElapsed + dt) % cfg.PULSE_TIME
		local fade = 1 - TweenService:GetValue(pulseElapsed / cfg.PULSE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		part.Color = cfg.DEFAULT_COLOR:Lerp(cfg.PULSE_COLOR, fade)

		-- Grounded gate. Speed is what separates mid-arc from resting:
		-- the apex of an arc only spends ~0.015s under GROUNDED_VY, while
		-- something sitting on the platform stays under it indefinitely.
		-- Measured in frames AND time, because this runs at whatever
		-- framerate the player has — see GROUNDED_TIME in BoardConfig for
		-- why either one alone lets the apex through at one end or the
		-- other. The time is counted from the first frame under the line,
		-- so a single long frame can't satisfy it on its own. Re-checked
		-- every frame, so a splitter knocked airborne stops splitting
		-- until it lands.
		if math.abs(part.AssemblyLinearVelocity.Y) <= cfg.GROUNDED_VY then
			if groundedFrames > 0 then
				groundedTime += dt
			end
			groundedFrames += 1
		else
			groundedFrames = 0
			groundedTime = 0
		end

		if groundedFrames >= cfg.GROUNDED_FRAMES
			and groundedTime >= cfg.GROUNDED_TIME
			and ctx.running()
			and ctx.live()
			and os.clock() >= nextSplitAt
		then
			-- Distance against both radii, because the pair is
			-- deliberately non-colliding and so never registers as
			-- touching. The splitter's radius is re-read every frame: it
			-- shrinks under this loop.
			local center = part.Position
			local reach = part.Size.X / 2

			for _, other in ipairs(ctx.folder:GetChildren()) do
				if other ~= part and other:IsA("BasePart") then
					local orbId, orbSize = ctx.absorbable(other)
					if orbId
						and orbSize > cfg.MIN_SPLIT_SIZE
						and (other.Position - center).Magnitude <= reach + other.Size.X / 2
					then
						-- Order matters. Write down where the halves come
						-- out BEFORE telling the server, so the site is
						-- there however fast the answer comes back.
						ctx.emergeAt(orbId, center, 2, cfg.CONVERGE_TIME)
						ctx.effects.soundAt(other.Position, ctx.config.SOUNDS.split)
						ctx.absorb(other, center, cfg.CONVERGE_TIME, "SplitPending")
						ctx.report(ctx.ops.SPLIT, ctx.id, orbId)

						local nextSize, spent = ctx.rules.splitterAfterSplit(remaining)
						if spent then
							sendOff(ctx, destroyPull)
							return
						end

						remaining = nextSize
						shrinkFrom, shrinkElapsed = part.Size.X, 0
						nextSplitAt = os.clock() + cfg.COOLDOWN

						-- One orb per frame, full stop. Every split in a
						-- frame would share the same centre, and their
						-- halves would all come out stacked on one point.
						break
					end
				end
			end
		end
	end
end

function Splitter.start(ctx)
	-- Dormant, it wears the colour it'll pulse from, so it's already
	-- recognisable on the way up.
	ctx.part.Color = ctx.config.SPLITTER.DEFAULT_COLOR

	-- Its own collision group from the instant it exists, as the old
	-- spawnSplitter did. It still launches with CanCollide off, so this
	-- changes nothing until the board switches collision back on at
	-- COL_Y — at which point it's already passing through orbs rather
	-- than being one frame late about it.
	ctx.part.CollisionGroup = CG.SplitterActive

	if not waitForWake(ctx) then
		return
	end
	run(ctx)
end

return Splitter