--[[
    Absorber (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-24 20:25:14
]]
--[[
    Absorber (ModuleScript)
    Path: ReplicatedStorage → Behaviours
    Parent: Behaviours
    Exported: 2026-09-23 02:07:55
]]
--[[
	Absorber (ModuleScript) — place in ReplicatedStorage → Behaviours
	(ReplicatedStorage.Behaviours.Absorber).

	Everything the splitter and the merger have in common, which is nearly
	everything. It isn't a kind, and ClientBoard never runs it directly:
	Splitter and Merger each call Absorber.run with a small spec saying
	how they differ.

	The originals were two 600-line scripts that said "polar opposite of
	SplitterFuse in every way that matters" at the top and then repeated
	it line for line with different colours. Every fix one got had to be
	remembered for the other — the grounded gate, the bottom-pinned
	shrink, the framerate fix — and that's exactly the kind of drift this
	rewrite keeps paying for. So there's one copy.

	THE LIFECYCLE

	  1. Dormant. Launches and settles like any orb, wearing its idle
	     colour.
	  2. Wakes as it crosses COL_Y: its own collision group (passes through
	     every orb, solid against the platform), the saw-wave pulse, and a
	     gentle pull back toward the middle.
	  3. Once it's at rest, live by the server's measure, the board is
	     running and it's off cooldown, it looks for `wants` orbs touching
	     it at once — one for a splitter, two for a merger. Those are
	     pulled into its centre, the server is told which ids, and the
	     results emerge from the spot it was standing on (see ClientBoard's
	     absorb / emergeAt).
	  4. Each use shrinks it, from the bottom. The use that spends its
	     budget plays the send-off instead: ease to the floor, then to
	     nothing, then a flash out of black.

	THE SPEC

		{
			cfg              = Config.SPLITTER / Config.MERGER — colours,
			                   timings, grounded gate, centre pull, floor
			group            = the collision group it wakes into
			wants            = how many orbs it takes at once
			results          = how many orbs come back out
			minOrbSize       = an orb must be bigger than this to be taken
			pendingAttribute = set on each taken orb's part (StashClient
			                   reads SplitPending / MergePending)
			sound            = the cue when it acts
			soundAtCenter    = play it at the special rather than the orb
			report(ids)      = tell the server; ids in the order they
			                   were taken
			after(remaining) = the special's next size, and whether this
			                   use spent it — the same function the server
			                   calls (BoardRules), so the two can't
			                   disagree about which use is the last
		}
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Absorber = {}

-- ── shrinking ─────────────────────────────────────────────────────────
-- Resizes around the BOTTOM rather than the centre. A part resizes
-- around its centre, so a special sitting on the platform lifted its own
-- bottom clear of the floor with every shrink, dropped back, and
-- jittered. Moving the centre down by exactly the radius it lost keeps
-- the bottom where it was.
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
-- bottom-pinned, timed by the clock rather than by frames. Returns false
-- if the behaviour stopped partway.
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
local function makeCenterPull(ctx, cfg)
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

	-- No damping, deliberately: it overshoots the centre and swings back,
	-- so a special ends up orbiting the middle rather than parked in it.
	-- That's the original's behaviour and it's the one we want.
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
-- The budget is spent. Ease to the floor, then to nothing, then flash
-- out of black. The server let go of this special the moment its last
-- use arrived, so this only has to clean up after itself.
local function sendOff(ctx, cfg, destroyPull)
	local part = ctx.part

	-- Nothing can sell, stash or grab it from here: the ledger has
	-- already let it go.
	ctx.retire()

	-- The pull would otherwise keep pushing with whatever it last had for
	-- the whole second it takes to disappear.
	destroyPull()

	-- Held still for the send-off. It only ever acts while resting on the
	-- platform, so this pins it where it's sitting, and the shrink can
	-- take it all the way down into the floor without the physics
	-- bouncing a shrinking ball around underneath it.
	part.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
	part.Anchored = true

	if not shrinkTo(ctx, cfg.FLOOR, cfg.SHRINK_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out) then
		return
	end

	local size = part.Size.X -- captured before the vanish touches it
	if not shrinkTo(ctx, 0, cfg.VANISH_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.In) then
		return
	end

	-- Bigger than a sell flash, popping in from black, and on top — as
	-- the old attachedFlash always was.
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

-- ── the stuck report (Studio only) ────────────────────────────────────
-- A splitter or merger has been seen stuck: bouncing up and down near the
-- middle, never still long enough to act, usually after it has shrunk.
-- It isn't reproducible on demand and the map isn't in the export, so
-- rather than guess, it reports itself. If it goes STUCK_REPORT_AFTER
-- seconds without once passing the grounded gate while the board is
-- running, it prints one line with everything needed to see why: its
-- size, where it is, how it's moving, and every part it's touching —
-- map, character or otherwise. Once per episode; it can report again if
-- it recovers and then gets stuck again.
local STUCK_REPORT_AFTER = 4

local function reportStuck(ctx, stuckFor, remaining)
	local part = ctx.part
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ctx.folder } -- other orbs pass through it anyway

	local touching = {}
	for _, other in ipairs(workspace:GetPartBoundsInRadius(part.Position, part.Size.X / 2 + 0.5, params)) do
		if other ~= part and #touching < 8 then
			table.insert(touching, ("%s [%s, %s, top y=%.2f]"):format(
				other:GetFullName(),
				other.CollisionGroup,
				other.CanCollide and "solid" or "non-solid",
				other.Position.Y + other.Size.Y / 2
				))
		end
	end

	local p, v = part.Position, part.AssemblyLinearVelocity
	warn(("[Absorber] %s %d looks stuck: %.1fs without resting. size %.2f (budget %.2f), at (%.1f, %.2f, %.1f), bottom y=%.2f, velocity (%.1f, %.1f, %.1f), %.1f studs from centre, board state '%s', anchored=%s, group %s. Touching: %s")
		:format(
			ctx.kind, ctx.id, stuckFor,
			part.Size.X, remaining,
			p.X, p.Y, p.Z, p.Y - part.Size.X / 2,
			v.X, v.Y, v.Z,
			Vector3.new(p.X, 0, p.Z).Magnitude,
			tostring(ctx.state()), tostring(part.Anchored), part.CollisionGroup,
			#touching > 0 and table.concat(touching, "; ") or "nothing"
		))
end

-- ── awake ─────────────────────────────────────────────────────────────
local function awake(ctx, spec)
	local cfg = spec.cfg
	local part = ctx.part

	local updatePull, destroyPull = makeCenterPull(ctx, cfg)

	-- What this special is worth, tracked locally so the shrink and the
	-- send-off happen on the frame it acts. The server does the same
	-- arithmetic to its own copy with the same function (spec.after) and
	-- its copy is the one that counts; they only disagree if a use is
	-- refused, and a refusal rebuilds the board from the ledger.
	local remaining = ctx.size

	local pulseElapsed = 0
	local groundedFrames, groundedTime = 0, 0
	local isStudio = RunService:IsStudio()
	local stuckFor, stuckReported = 0, false
	local nextUseAt = 0

	-- The small ease down after each use, driven from this loop rather
	-- than a tween so it can be bottom-pinned. A use landing mid-shrink
	-- just restarts it from wherever it had got to.
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

		-- Its own group: passes through every orb, still solid against the
		-- platform. Re-pinned every frame as a guard against anything else
		-- changing it — except while it's in the player's hands, where
		-- GrabClient's carry group is the right one and re-pinning would
		-- have it shove the person holding it.
		if not part:GetAttribute("Held") then
			part.CollisionGroup = spec.group
		end

		updatePull()

		-- Saw-wave pulse: pops to PULSE_COLOR, eases back down to
		-- DEFAULT_COLOR over the rest of the cycle, pops again.
		pulseElapsed = (pulseElapsed + dt) % cfg.PULSE_TIME
		local fade = 1 - TweenService:GetValue(pulseElapsed / cfg.PULSE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		part.Color = cfg.DEFAULT_COLOR:Lerp(cfg.PULSE_COLOR, fade)

		-- Grounded gate. The apex of an arc only spends ~0.015s under
		-- GROUNDED_VY; something sitting on the platform stays under it
		-- indefinitely. Measured in frames AND time, because this runs at
		-- the player's framerate — see GROUNDED_TIME in BoardConfig. The
		-- time is counted from the first frame under the line, so a single
		-- long frame can't satisfy it on its own.
		if math.abs(part.AssemblyLinearVelocity.Y) <= cfg.GROUNDED_VY then
			if groundedFrames > 0 then
				groundedTime += dt
			end
			groundedFrames += 1
		else
			groundedFrames = 0
			groundedTime = 0
		end

		local grounded = groundedFrames >= cfg.GROUNDED_FRAMES and groundedTime >= cfg.GROUNDED_TIME

		if isStudio then
			if grounded or not ctx.running() or part:GetAttribute("Held") then
				stuckFor, stuckReported = 0, false
			else
				stuckFor += dt
				if stuckFor >= STUCK_REPORT_AFTER and not stuckReported then
					stuckReported = true
					reportStuck(ctx, stuckFor, remaining)
				end
			end
		end

		if groundedFrames >= cfg.GROUNDED_FRAMES
			and groundedTime >= cfg.GROUNDED_TIME
			and ctx.running()
			and ctx.live()
			and os.clock() >= nextUseAt
		then
			-- Distance against both radii, because the pair is
			-- deliberately non-colliding and never registers as touching.
			-- Its own radius is re-read every frame: it shrinks under this.
			local center = part.Position
			local reach = part.Size.X / 2

			-- The first `wants` orbs touching it. Nothing is taken until
			-- there are enough: a merger that grabbed one orb and waited
			-- for a second would hold it hostage.
			local picked, ids = {}, {}
			for _, other in ipairs(ctx.folder:GetChildren()) do
				if #picked >= spec.wants then
					break
				end
				if other ~= part and other:IsA("BasePart") then
					local orbId, orbSize = ctx.absorbable(other)
					if orbId
						and orbSize > spec.minOrbSize
						and (other.Position - center).Magnitude <= reach + other.Size.X / 2
					then
						table.insert(picked, other)
						table.insert(ids, orbId)
					end
				end
			end

			if #picked >= spec.wants then
				-- Order matters. Write down where the results come out
				-- BEFORE telling the server, so the site is there however
				-- fast the answer comes back. It's keyed by the first id,
				-- which is the one the server names back.
				ctx.emergeAt(ids[1], center, spec.results, cfg.CONVERGE_TIME)

				ctx.effects.soundAt(spec.soundAtCenter and center or picked[1].Position, spec.sound)
				for _, other in ipairs(picked) do
					ctx.absorb(other, center, cfg.CONVERGE_TIME, spec.pendingAttribute)
				end
				spec.report(ids)

				local nextSize, spent = spec.after(remaining)
				if spent then
					sendOff(ctx, cfg, destroyPull)
					return
				end

				remaining = nextSize
				shrinkFrom, shrinkElapsed = part.Size.X, 0
				-- One use per frame at most, and this cooldown after it.
				-- Every use in a frame would share one centre, and their
				-- results would all come out stacked on one point.
				nextUseAt = os.clock() + cfg.COOLDOWN
			end
		end
	end
end

function Absorber.run(ctx, spec)
	-- Dormant, it wears the colour it'll pulse from, so it's already
	-- recognisable on the way up.
	ctx.part.Color = spec.cfg.DEFAULT_COLOR

	-- Its own collision group from the instant it exists, as the old
	-- spawnSplitter/spawnMerger did. It still launches with CanCollide
	-- off, so this changes nothing until the board switches collision
	-- back on at COL_Y — at which point it's already passing through orbs
	-- rather than being one frame late about it.
	ctx.part.CollisionGroup = spec.group

	if not waitForWake(ctx) then
		return
	end
	awake(ctx, spec)
end

return Absorber