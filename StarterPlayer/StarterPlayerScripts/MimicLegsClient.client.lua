--[[
    MimicLegsClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-24 20:25:14
]]
--[[
    MimicLegsClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-23 02:07:55
]]
--[[
    MimicLegsClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-22 18:28:58
]]
--[[
	MimicLegsClient (LocalScript) — place in StarterPlayerScripts (runs once
	per client, watches every mimic in Workspace.Balls for as long as the
	player's around).

	This is the other half of MimicFuse — see that script's header for the
	full "why". Short version: mimic legs used to be anchored parts the
	SERVER CFrame'd directly, replicated to every client as ordinary
	property writes, while the mimic's actual body was a separate
	unanchored, server-owned physics part replicated through Roblox's
	physics replicator (which buffers/interpolates). Two different
	replication paths for one creature meant legs and body could each
	arrive on a given client at different times — read as "the legs lag
	behind the head" (or the reverse, depending on which path happened to
	be slower for a given client at a given moment).

	This script sidesteps that entirely: it never receives leg positions
	over the network at all. Instead, every RenderStepped, for every awake
	mimic, it reads mimic.CFrame — whatever THIS client currently has for
	the body, already-lagged or not — and places this client's own,
	local-only leg parts off of that, right then. Since both the body
	CFrame it reads and the legs it draws happen in the same frame on the
	same machine, the legs can never get ahead of (or behind) whatever
	body position this client is currently rendering. Every client sees
	its own consistent creature, even if different clients are looking at
	slightly different (normal, physics-replication-lag) body positions
	from each other.

	The legs this script creates are pure client-side Instances (created
	by a LocalScript, parented under the mimic) — they are NOT replicated
	to the server or to other clients, by design. Nothing here is
	server-authoritative or gameplay-affecting; it's cosmetic only. The
	server's MimicFuse script still owns all real state (MimicActive,
	body physics, hunt/absorb decisions) and knows nothing about legs.

	Config values below (LEG_LIFT_FRAC especially) intentionally mirror
	MimicFuse's own copies — see the comments over there. They don't need
	to be perfectly identical for legs to look right, but LEG_LIFT_FRAC
	in particular should match, since MimicFuse uses its own copy to
	decide how high off the ground the real body rides, and this script
	uses its copy to decide how far the legs need to reach to meet it.
]]

local RS = game:GetService("RunService")
local WS = game:GetService("Workspace")
local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")

-- LEGS_SPROUT_TIME and LEG_LIFT_FRAC used to be copied here and in
-- MimicFuse by hand, each with a comment saying they MUST match. The
-- mimic's behaviour now runs on this same client (ReplicatedStorage →
-- Behaviours → Mimic), and both read the one copy in BoardConfig.MIMIC.
--
-- Nothing else in this script changed in the rewrite: it still watches
-- workspace.Balls for an orb with MimicActive set and draws its legs off
-- that orb's CFrame every frame. The folder and the orb are both local
-- now, so the replication mismatch this script's header describes can't
-- happen any more — the legs and the body are the same machine's physics.
local MimicConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("BoardConfig")).MIMIC

local player = Players.LocalPlayer

-- The board's orbs. A foot standing on one follows it by position only;
-- see "footholds" in attachLegs.
local ballsFolderForFeet = WS:WaitForChild("Balls")

-- ── config: sound ──────────────────────────────────────────────────
-- purely cosmetic, per-client sounds for this script's own leg
-- animation. Unlike MimicFuse's wake/revert cues (which fire through
-- the server-driven SoundEvents remote, since those are genuinely
-- one-time authoritative events — see that script's own "config:
-- sound" comment), leg growth and footsteps are already rendered
-- independently by every client the same way the legs themselves are
-- (see this script's header): there's no single authoritative moment
-- to fire a remote from, so each client just plays its own copy
-- locally, in step with its own local leg animation.
--
-- LEG_COUNT legs start sprouting a fraction of a second apart, all firing the same cue.
-- Re-triggering the identical asset id that fast is a known, long-standing
-- Roblox engine limitation (still open on the DevForum as of this writing,
-- reports go back to 2017) — replaying the same SoundId repeatedly glitches,
-- gets silently dropped, or starts from a stale playhead, independent of
-- whether it's one reused Sound instance or several separate ones pointed
-- at that id. Neither approach was actually the bug; the shared id was.
-- The reliable fix is to not repeat the identical id back-to-back: this is
-- the SAME clip uploaded as LEG_COUNT separate Roblox audio assets, so
-- every consecutive play hits a distinct id.
--
-- ACTION NEEDED: entries 2 and 3 below are currently just duplicates of
-- entry 1's id as a placeholder — re-upload the leg-grow clip (unchanged
-- content is fine) as 2 more separate Roblox audio assets and drop their
-- real ids in here. Until then this still shares one id and the original
-- bug can resurface.
local LEG_GROW_SOUND_IDS = {
	"rbxassetid://105118844743160", -- reuploaded twice because thats how roblox works idk
	"rbxassetid://84724642336148",
	"rbxassetid://92376313459891",
}
local LEG_GROW_VOLUME = 0.5 -- was implicitly 1 (playAttachedSound's default) — turned down, tune to taste
local FOOTSTEP_SOUND = "rbxassetid://136714739465426"
local FOOTSTEP_PITCH_MIN, FOOTSTEP_PITCH_MAX = 0.9, 1.1 -- random PlaybackSpeed range rolled fresh per footfall, so every step doesn't sound identically pitched

-- Preloaded here, as a plain BLOCKING call, before the watcher below ever
-- starts attaching legs to anything. This has to actually be waited on, not
-- fire-and-forgotten: PreloadAsync yields for as long as the asset takes to
-- load, and if that load is still in flight the first time a leg tries to
-- Play() this sound, Roblox has no decoded buffer ready yet and the Play()
-- call just silently does nothing — which is what read as only one leg
-- (whichever happened to win the race) ever making a sound per sprout,
-- instead of every leg getting its own cue. Wrapping this in task.spawn
-- looked like it preloaded early, but a spawned thread runs in parallel
-- with the rest of this script, not before it — the ballsFolder watcher
-- below could still reach an already-awake mimic and start growing its
-- legs while the preload was still mid-flight, losing the exact same race
-- a step later. Blocking here instead guarantees both sounds are already
-- loaded by the time anything below can possibly ask to play them.
do
	local toPreload = { FOOTSTEP_SOUND }
	local seen = {}
	for _, id in ipairs(LEG_GROW_SOUND_IDS) do
		if not seen[id] then
			seen[id] = true
			table.insert(toPreload, id)
		end
	end
	ContentProvider:PreloadAsync(toPreload)
end

-- one-shot sound, attached to `target` and destroyed once it finishes
-- (not `target` itself — target is a persistent leg part, not a
-- disposable one) — same shape as SoundClient's own `attached` helper,
-- duplicated locally rather than shared cross-script since these are
-- two unrelated LocalScripts and neither exposes the other's functions
local function playAttachedSound(target, id, volume, pitch)
	if not (target and target.Parent) then return end
	local s = Instance.new("Sound")
	s.SoundId, s.Volume, s.PlaybackSpeed, s.Parent = id, volume or 1, pitch or 1, target
	s:Play()
	s.Ended:Connect(function() s:Destroy() end)
end



-- ── config: wake-up (mirrors MimicFuse) ────────────────────────────────
-- total time for all LEG_COUNT legs to sprout out, one after another, before
-- MimicFuse starts pushing the body up on them. MUST match MimicFuse's
-- own LEGS_SPROUT_TIME — that script just holds the body still for this
-- same span while this one paces the actual per-leg animation, so the
-- two read as one sequence (sprout fully, THEN rise) instead of the
-- body lifting while legs are still stretching out from stubs.
-- Unlike the old GROW_LEGS_TIME this replaces, the RISE that follows
-- doesn't need a matching client-side constant at all: once every leg
-- is fully grown and planted, this script's ordinary per-frame foot IK
-- (see the steady-state loop below) tracks the ground under a rising
-- hip on its own, at whatever pace MimicFuse actually raises the body —
-- that's just solveKnee straightening as hip-to-foot distance grows,
-- the same IK that already runs the rest of the time.
local LEGS_SPROUT_TIME = MimicConfig.LEGS_SPROUT_TIME

-- ── config: legs ────────────────────────────────────────────────────
local LEG_COUNT = 3              -- see buildHipLocal below for how the hip layout adapts to whatever this is set to — spread evenly around the body, so this is the only line that needs to change to add/remove legs
local HIP_ATTACH_FRAC = 0.7      -- where each leg's hip SOCKET sits, relative to body radius — this is what keeps legs flush against the body's own surface, so don't bump this up to spread the stance; it just pushes the whole leg's root away from the body and reads as the legs hovering disconnected from it. Use FOOT_SPREAD_FRAC below instead.
local FOOT_SPREAD_FRAC = 0.95    -- extra outward distance (x body radius) the RESTING FOOT is pushed beyond the hip, along the same outward direction the hip already faces — this is what actually widens the stance, without moving the hip socket itself. Tune this one to taste for a wider/narrower stance.
local LEG_THICKNESS_FRAC = 0.2   -- both leg segments' thickness, relative to body size — upper and lower now share one thickness; the taper between them comes from LEG_MESH_ID_UPPER/LEG_MESH_ID_LOWER being different sculpted meshes instead
local LEG_SEGMENT_FRAC = 1       -- each of the 2 leg segments' length, relative to body size
local LEG_LIFT_FRAC = MimicConfig.LEG_LIFT_FRAC -- clearance the legs hold the body's underside above the floor, as a fraction of body size; shared with the Mimic behaviour, which rides the body at this height
local LEG_REFLECTANCE = 0.5      -- reflectance on both leg segments
-- TODO: swap these placeholders for the real sculpted upper/lower meshes once ready — both point at the same asset for now, so nothing looks different in-game until they're replaced.
local LEG_MESH_ID_UPPER = "rbxassetid://116303918671108" -- hip-to-knee segment mesh — MeshType.Head (the old approach) silently falls back to rendering as a plain cylinder once stretched past ~4 studs on its long axis, which every leg segment routinely is; this mesh is a real FileMesh instead, so it doesn't have that size cutoff. Unlike Head, a FileMesh doesn't auto-fill the part's Size on its own — placeSegment below has to keep its Scale in sync by hand.
local LEG_MESH_ID_LOWER = "rbxassetid://90220320261377"  -- knee-to-foot segment mesh — see LEG_MESH_ID_UPPER's comment; same FileMesh mechanics, just a distinct asset so the two segments no longer rely on differing thickness scale to read as different parts of the leg
local STEP_HEIGHT_FRAC = 0.4     -- how high a stepping foot lifts, relative to body size — a touch higher than before to read cleanly at the longer STRIDE_LEAD_FRAC/STEP_THRESHOLD_FRAC below, so a longer stride doesn't look like the foot is dragging across the ground on its way to the next plant
local STEP_TIME = 0.3            -- seconds a single step takes, before STEP_TIME_JITTER below — longer than before so a foot has time to actually cover the farther distance a longer stride now sends it, instead of covering more ground in the same time and reading as a faster walk rather than a longer one
local STEP_TIME_JITTER = 0.1     -- +/- randomness applied to each individual step's duration, so footfalls don't all take identically long and read as mechanical
local MIN_STEP_TIME = 0.08       -- floor on a single step's duration once speedScale (see the stepDur assignment below) starts shrinking it for a hip moving faster than strideLeadReferenceSpeed — without this, a pet mimic's CHASE_SPEED hip could scale STEP_TIME down toward ~0 and the swing would collapse into a single-frame teleport instead of a fast-but-still-visible step
local STEP_THRESHOLD_FRAC = 3.2  -- a foot re-steps once it's drifted this far (x body radius) from its rest spot — raised alongside STRIDE_LEAD_FRAC/FOOT_SPREAD_FRAC below so a foot is still allowed to drift the farther distance a longer stride implies before it's forced to catch up
local STEP_THRESHOLD_MAX_REACH_FRAC = 0.7 -- SAFETY CAP: the actual drift threshold used below is never allowed past this fraction of a leg's true max physical reach (2x a segment's length — see solveKnee's clamp), so a foot is always forced to re-plant before it's stretched anywhere near the leg's actual reach
local IDLE_COMFORT_DELAY = 0.25   -- seconds the whole body must sit essentially stationary (see idleTime in updateFeet) before feet start getting nudged toward a tidy rest stance — short walk pauses shouldn't trigger this, only genuine idling
local IDLE_COMFORT_THRESHOLD_FRAC = 0.15 -- x STEP_THRESHOLD_FRAC's own drift distance — much tighter than the ordinary re-step threshold, since the point here is catching a foot that's technically within the normal walking tolerance but still landed somewhere crooked/awkward once there's no hurry to fix it
local STRIDE_LEAD_FRAC = 2.2     -- how far ahead of the hip (x body radius, in the current direction of travel) a stepping foot plants AT FULL SPEED — larger than before so each step actually carries the foot a farther distance forward, reading as a longer, farther-reaching stride rather than more frequent short ones. See STRIDE_LEAD_REFERENCE_SPEED_PER_SIZE below for how this scales down at lower speed — this is a ceiling, not the distance every step reaches for.
local STRIDE_LEAD_REFERENCE_SPEED_PER_SIZE = 2 -- studs/sec of actual hip speed, PER POINT of bodySize, at which a stepping foot plants the FULL STRIDE_LEAD_FRAC ahead — used to be a flat 10, mirroring MimicFuse's own (then-flat) WALK_SPEED, since that's the speed this is actually tuned to read well at. MimicFuse's WALK_SPEED is now itself derived from a per-size rate rather than a flat number (see that script's own WALK_SPEED_PER_SIZE comment), so this has to scale the same way to keep mirroring it — otherwise a bigger mimic's now-faster walk would outrun what this still thought "full stride" hip speed was, and a smaller mimic's now-slower walk would always read as a full-length stride even while barely moving. The actual reference speed is derived once bodySize is known (see attachLegs below). Below that reference, the plant point's lead scales down proportionally with actual speed (see leadFrac in updateFeet), so a foot settling toward a stop only reaches as far ahead as its real motion warrants, instead of always committing to a full-length stride in whatever direction the hip's velocity last happened to read as.

-- Legs used to always plant the full STRIDE_LEAD_FRAC ahead, at any
-- speed, in whatever direction leg.leadDir currently read as. That's

-- fine while genuinely walking, but right as the mimic settles toward a
-- stop, real hip speed drops toward zero and leadDir (still whatever

-- direction it last resolved to — see leadDir's own comment below) gets
-- noisy and easily flips, since there's barely any real motion left to
-- derive a direction from confidently. A foot that trips its drift
-- threshold in that moment committed to a FULL-length stride in
-- whatever that noisy direction happened to be — including backward —
-- which is what read as a leg suddenly stepping backward while the
-- mimic was just trying to come to rest. Scaling the actual plant
-- distance down by how much real motion is happening (leadFrac) means a
-- near-stationary foot only ever takes a short corrective step toward
-- wherever the hip actually is right now, rather than lunging a full
-- stride out on a direction reading that isn't backed by much real
-- velocity to begin with.
local STEP_HOLD_TIME = 0.12      -- seconds a foot stays planted after landing, before the NEXT leg in the fixed step sequence is allowed to start its swing
local STEP_VERTICAL_THRESHOLD_FRAC = 0.5 -- a PLANTED foot also re-steps once whatever's directly beneath it has moved this far (x body size) from the foot's current height — catches "stepped on something that then moved out from under it"
local RETRACT_TIME = 0.35        -- seconds all LEG_COUNT legs take to retract back into the body once MimicActive goes false (reverted to a normal ball, or destroyed) — see the retract section below
local LEG_MAX_RADIUS = 53        -- studs from the world origin (0,0) that a foot is ever allowed to plant beyond — mirrors MimicFuse's own MIMIC_MAX_RADIUS/WORLD_BOUND_RADIUS pattern, but for feet specifically: a wide stance (FOOT_SPREAD_FRAC) plus a long stride (STRIDE_LEAD_FRAC) can otherwise plant a foot noticeably farther from the origin than the platform edge, once the body itself is walking right up near its own MIMIC_MAX_RADIUS. Kept a little tighter than that 55-stud body cap so the stance never visibly pokes past the platform edge before the body itself would revert.

-- ── config: balance recovery (mirrors MimicFuse's own copy) ───────────
-- an independent, cosmetic-only check: MimicFuse uses its own copy of
-- this same tilt/velocity-mismatch test to sharpen the body's real
-- self-righting torque; this script uses its copy purely to let feet
-- scramble/replant urgently in the moment, so the legs visibly react to
-- a hit rather than just eventually catching up once things settle.
-- They don't need to agree frame-to-frame with the server's version.
local RECOVERY_TILT_THRESHOLD = math.rad(12)
local RECOVERY_VELOCITY_THRESHOLD = 10
local RECOVERY_STEP_TIME = 0.14
local RECOVERY_DRIFT_FRAC = 0.35
local VELOCITY_SMOOTHING = 0.35 -- low-pass factor (0-1, higher = snappier) on the client's own moved/dt velocity estimate; a raw single-frame diff is noisy enough (replication buffering, variable RenderStepped dt) to spuriously trip isKnocked() during completely normal speed changes like starting a chase, which read as random little hops

-- ══════════════════════════════════════════════════════════════════════
-- per-mimic leg rig
-- ══════════════════════════════════════════════════════════════════════

-- `initialPos` seeds the part's own CFrame at creation time (see the call
-- sites below, which pass each leg's hip). Without this, a freshly created
-- Part just sits at the world origin (0,0,0) — Roblox's default — until the
-- first placeSegment call ever moves it. That default origin is what
-- the leg-grow cue's very first play (fired on leg.upper before this leg has
-- been placed anywhere — see the sprout section) was actually spatializing
-- from: not broken exactly, but playing from the map's (0,0,0) instead of
-- the mimic, which is what read as the cue coming from a location, and
-- stereo direction, that had nothing to do with where the mimic actually
-- was. Seeding the part at its hip up front means there's no window where
-- it's sitting somewhere stale for a sound to spatialize from.
local function makeSegment(legsFolder, bodyColor, legThickness, meshId, name, initialPos)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored, part.CanCollide, part.CanQuery = true, false, false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = bodyColor
	part.Reflectance = LEG_REFLECTANCE
	part.TopSurface, part.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	part.Size = Vector3.new(legThickness, 0.05, legThickness) -- starts as a stub; the grow-in loop stretches this out
	part.CFrame = CFrame.new(initialPos)

	local mesh = Instance.new("SpecialMesh")
	mesh.Name = "LegMesh"
	mesh.MeshType = Enum.MeshType.FileMesh
	mesh.MeshId = meshId -- LEG_MESH_ID_UPPER or LEG_MESH_ID_LOWER, picked by the caller — each segment now keeps its own asset for its whole life, never reassigned after creation
	mesh.Scale = part.Size -- kept in sync with part.Size every resize in placeSegment — FileMesh has no auto-fill of its own, unlike the Head type this replaced
	mesh.Parent = part

	part.Parent = legsFolder
	return part
end

-- orients a segment so its local Y axis (the mesh's long axis) spans
-- exactly from p0 to p1, and resizes the part (and its mesh — see
-- LEG_MESH_ID_UPPER's comment) to match
local function placeSegment(part, p0, p1, legThickness)
	local lengthDir = p1 - p0
	local len = math.max(lengthDir.Magnitude, 0.05)
	lengthDir = lengthDir / len

	local up = Vector3.new(0, 1, 0)
	if math.abs(lengthDir:Dot(up)) > 0.999 then
		up = Vector3.new(1, 0, 0)
	end
	local xAxis = lengthDir:Cross(up).Unit
	local zAxis = xAxis:Cross(lengthDir).Unit

	local size = Vector3.new(legThickness, len, legThickness)
	part.Size = size
	local mesh = part:FindFirstChild("LegMesh")
	if mesh then mesh.Scale = size end
	part.CFrame = CFrame.fromMatrix((p0 + p1) / 2, xAxis, lengthDir, zAxis)
end

-- pulls a foot position back onto the LEG_MAX_RADIUS circle (XZ plane,
-- centered on the world origin) if it lies beyond it, preserving Y —
-- applied everywhere a foot's actual rest/plant position is finalized,
-- so a wide stance/long stride can never plant a foot farther out than
-- this regardless of where the body itself currently is.
local function clampFootRadius(point)
	local flat = Vector3.new(point.X, 0, point.Z)
	if flat.Magnitude <= LEG_MAX_RADIUS then return point end
	local clamped = flat.Unit * LEG_MAX_RADIUS
	return Vector3.new(clamped.X, point.Y, clamped.Z)
end

-- simple 2-bone (law-of-cosines) IK
local function solveKnee(hip, foot, bendHint, segLen)
	local toFoot = foot - hip
	local dist = math.clamp(toFoot.Magnitude, 0.05, segLen * 2 - 0.02)
	local dir = toFoot.Unit

	local cosAngle = math.clamp(dist / (2 * segLen), -1, 1)
	local hipAngle = math.acos(cosAngle)

	local axis = dir:Cross(bendHint)
	if axis.Magnitude < 0.001 then
		axis = dir:Cross(Vector3.new(0, 1, 0))
	end
	if axis.Magnitude < 0.001 then
		axis = dir:Cross(Vector3.new(1, 0, 0))
	end
	axis = axis.Unit

	local bentDir = CFrame.fromAxisAngle(axis, hipAngle) * dir
	return hip + bentDir * segLen
end

-- sets up and drives one mimic's leg rig for as long as it's active.
-- Runs entirely on RenderStepped; tears itself down (Destroy()s its
-- Folder) the moment MimicActive goes false or the mimic disappears.
local function attachLegs(mimic)
	local bodySize = mimic:GetAttribute("TargetSize") or mimic.Size.X
	local bodyColor = mimic.Color

	-- A Model rather than a Folder, and that's the only reason: a
	-- Highlight can light up a whole Model, but not a Folder, and one on
	-- the body part covers the body alone. BoardEffects looks for this
	-- by name and gives the legs a matching highlight whenever the body
	-- gets one — a bomb's hit, the collapse, a thrown orb's knock — so the
	-- whole creature lights up rather than a floating head. Nothing else
	-- about the legs cares what they're grouped in.
	local legsFolder = Instance.new("Model")
	legsFolder.Name = "MimicLegs"
	legsFolder.Parent = mimic

	-- keeps every leg part's Color in sync with the body's for as long as
	-- legs exist — matters most for a pet mimic, whose owner can recolor
	-- it live through PetConfigClient mid-life (see PetMimicHandler),
	-- but applies the same way to any mimic, in case anything else ever
	-- changes mimic.Color after it's already grown legs. bodyColor above
	-- only seeds each segment's color AT CREATION; without this, a later
	-- color change would update the (server-owned, replicated) body but
	-- leave these client-only parts showing whatever color they were
	-- built with. Self-disconnects off legsFolder's own Destroying event
	-- rather than needing to be torn down at every one of this
	-- function's several early-return exit points below.
	do
		local colorConn
		colorConn = mimic:GetPropertyChangedSignal("Color"):Connect(function()
			local newColor = mimic.Color
			for _, part in ipairs(legsFolder:GetChildren()) do
				if part:IsA("BasePart") then
					part.Color = newColor
				end
			end
		end)
		legsFolder.Destroying:Connect(function()
			colorConn:Disconnect()
			-- no legs, nothing to stand on: the body goes back to judging
			-- its height by the floor (see publishFootY below)
			if mimic.Parent then
				mimic:SetAttribute("FootY", nil)
			end
		end)
	end

	local legThicknessUpper = bodySize * LEG_THICKNESS_FRAC
	local legThicknessLower = legThicknessUpper -- upper and lower now share one thickness; the two segments read as distinct via LEG_MESH_ID_UPPER/LEG_MESH_ID_LOWER instead — kept as its own local (rather than collapsing every call site to legThicknessUpper) so placeSegment's calls below don't need touching
	local legSegLen = bodySize * LEG_SEGMENT_FRAC
	local hipAttachDist = (bodySize / 2) * HIP_ATTACH_FRAC -- where the hip SOCKET sits — stays flush with the body's surface regardless of stance width
	local footSpreadDist = (bodySize / 2) * FOOT_SPREAD_FRAC -- extra outward push applied to the FOOT's rest position only, on top of hipAttachDist — this is the actual stance-width knob
	local stepHeight = bodySize * STEP_HEIGHT_FRAC
	local stepThreshold = math.min((bodySize / 2) * STEP_THRESHOLD_FRAC, legSegLen * 2 * STEP_THRESHOLD_MAX_REACH_FRAC)
	local stepVerticalThreshold = bodySize * STEP_VERTICAL_THRESHOLD_FRAC
	local strideLead = (bodySize / 2) * STRIDE_LEAD_FRAC
	local strideLeadReferenceSpeed = STRIDE_LEAD_REFERENCE_SPEED_PER_SIZE * bodySize -- mirrors MimicFuse's own scaled WALK_SPEED for this mimic's actual bodySize — see STRIDE_LEAD_REFERENCE_SPEED_PER_SIZE's own comment

	-- lets a foot's own ground raycast (below) ignore the ball currently
	-- being hunted, the same way MimicFuse's groundYAt excludes it for
	-- body height — without this, a plant point landing over the prey
	-- (always possible, since prey is always smaller than the mimic and
	-- so always clears the head-height check below) raycasts onto the
	-- BALL's own top surface and plants a foot up on it as if it were
	-- floor. That foot then sits elevated until drift/vertical-mismatch
	-- eventually forces a re-step — reading as a leg "caught on" or stuck
	-- on top of a ball before it snaps back down. WaitForChild with a
	-- timeout since this is set up in the same server frame as everything
	-- else here but still crosses the network to get to this client.
	local huntedPreyValue = mimic:WaitForChild("HuntedPrey", 5)

	local floorRayParams = RaycastParams.new()
	floorRayParams.FilterType = Enum.RaycastFilterType.Exclude
	floorRayParams.FilterDescendantsInstances = { mimic, legsFolder }
	local function surfaceYAt(worldX, worldZ)
		local floorGuess = mimic.Position.Y - bodySize / 2 - bodySize * LEG_LIFT_FRAC
		local origin = Vector3.new(worldX, floorGuess + bodySize * 3, worldZ)
		local huntedPrey = huntedPreyValue and huntedPreyValue.Value
		floorRayParams.FilterDescendantsInstances = huntedPrey and { mimic, legsFolder, huntedPrey } or { mimic, legsFolder }
		local result = WS:Raycast(origin, Vector3.new(0, -(bodySize * (6 + LEG_LIFT_FRAC)), 0), floorRayParams)
		if result then
			local headY = mimic.Position.Y + bodySize / 2 -- top of the mimic's own body
			if result.Position.Y <= headY then
				-- the part too, so a foot planted here can ride along with
				-- it (see footholds below)
				return result.Position.Y, result.Instance
			end
			-- whatever the ray hit (a nearby ball, some prop) pokes up
			-- higher than the mimic's own head — never a valid foot plant,
			-- so fall back to the floor guess instead of stepping up onto it
		end
		return floorGuess
	end

	-- ── footholds ──────────────────────────────────────────────────────
	-- A planted foot remembers WHAT it stepped on, not just where. The
	-- board is physics all the way down — orbs roll, get knocked, get
	-- bombed, get sold out from under a foot — so a world-space point that
	-- was ground a moment ago can be empty air now. Every frame a planted
	-- foot is re-placed on its foothold wherever that has moved to, and a
	-- foot whose foothold has gone (destroyed, sold, absorbed) re-steps
	-- straight away instead of standing on nothing. A swinging foot's
	-- landing spot tracks its foothold the same way, so it lands on the
	-- thing it was aiming for even if that thing moved mid-swing.
	--
	-- Orbs (anything in the Balls folder) are followed by position only.
	-- They roll, and following their rotation would carry a foot round
	-- the orb with the roll — under it, eventually. Everything else is
	-- followed rigidly, rotation included, so a foot on a tilting or
	-- spinning prop moves as if it were stuck to it. Static ground is
	-- followed too; it just never moves.
	--
	-- Riding along is still bounded by the ordinary checks: a foot carried
	-- too far from where it should be trips the drift threshold, and one
	-- carried up or down off the surface under it trips the vertical one,
	-- and either way it steps.
	local function makeFoothold(point, hit)
		if not hit or hit == WS.Terrain then
			return nil
		end
		if hit:IsDescendantOf(ballsFolderForFeet) then
			return { part = hit, offset = point - hit.Position, rigid = false }
		end
		return { part = hit, offset = hit.CFrame:PointToObjectSpace(point), rigid = true }
	end

	-- where the foothold's point is now, or nil if the foothold is gone
	local function footholdPoint(hold)
		local p = hold.part
		if not p.Parent or not p:IsDescendantOf(WS) then
			return nil
		end
		if hold.rigid then
			return p.CFrame:PointToWorldSpace(hold.offset)
		end
		return p.Position + hold.offset
	end

	-- the ground under (x, z), and a foothold on whatever that ground is
	local function groundPoint(x, z)
		local y, hit = surfaceYAt(x, z)
		local point = Vector3.new(x, y, z)
		return point, makeFoothold(point, hit)
	end

	-- Roblox's default local "forward" is -Z and "right" is +X — flip
	-- either of these if the legs end up mirrored front-to-back or
	-- left-to-right once you can actually see it in-game.
	local FRONT_IS_NEGATIVE_Z = true
	local RIGHT_IS_POSITIVE_X = true
	-- which end one leg sits centered on (see buildHipLocal below) —
	-- "Back" reads as a stabilizing tail leg; flip to "Front" for an
	-- extra grasping/lunging leg up front instead. The rest of the legs
	-- fall out symmetrically to either side of it purely from being
	-- evenly spaced around the circle, so this is the only knob needed
	-- to rotate the whole layout.
	local ANCHOR_LEG_END = "Back"

	-- hip socket positions (local space), spread evenly around the body
	-- like spokes on a wheel rather than paired off across the front/
	-- back centerline. Used to build the old 4-corner (and then
	-- 4-corner-plus-center) layout by pairing legs left/right and
	-- spacing the pairs between the front and back ends; that's a
	-- sensible quadruped stance, but it doesn't read as "radial" the
	-- way a 5-plus-leg creature with an even spread around the whole
	-- body does. This instead places ONE leg exactly on the centerline
	-- at ANCHOR_LEG_END, then walks the rest of the way around the
	-- circle in equal angleStep increments. Since count-1 further legs
	-- are still spaced evenly starting from an anchor sitting ON the
	-- axis, they land in symmetric left/right pairs automatically —
	-- no separate pairing logic needed, unlike the old table.
	local function buildHipLocal(count, attachDist)
		local positions = {}
		local angleStep = (2 * math.pi) / count
		-- angle 0 = straight toward the front (-Z), sweeping first
		-- toward +X (right) as angle increases — matches Roblox's -Z
		-- forward / +X right convention, so this reads as spokes
		-- fanning out evenly around the body regardless of leg count
		local startAngle = (ANCHOR_LEG_END == "Back") and math.pi or 0
		for i = 0, count - 1 do
			local angle = startAngle + i * angleStep
			local x = math.sin(angle) * attachDist
			local z = -math.cos(angle) * attachDist
			positions[#positions + 1] = Vector3.new(x, 0, z)
		end
		return positions
	end
	local HIP_LOCAL = buildHipLocal(LEG_COUNT, hipAttachDist)

	-- the hip's outward bend-hint used to be computed ONCE here, from
	-- hipLocal.X/Z treated as if they were already world-space — which
	-- is only ever correct at the instant the rig is created. It never
	-- rotated with the body afterward, so the knee's bend direction
	-- silently went stale the moment the body turned at all: once
	-- turned far enough, the stale hint fights the actual hip-to-foot
	-- vector and the knee solve collapses inward, reading as the knee
	-- joints bunching up underneath the body — during a walk, not just
	-- a stationary spin, since ordinary walking reorients the body too.
	-- worldOutward recomputes it fresh every frame from the body's
	-- CURRENT orientation instead, so the bend hint always matches.
	local function worldOutward(hipLocal)
		local flatLocal = Vector3.new(hipLocal.X, 0, hipLocal.Z)
		if flatLocal.Magnitude < 0.001 then return Vector3.new(0, 0, 1) end
		local worldDir = mimic.CFrame:VectorToWorldSpace(flatLocal)
		return worldDir.Magnitude > 0.001 and worldDir.Unit or Vector3.new(0, 0, 1)
	end

	local legs = {}
	for i = 1, LEG_COUNT do
		local hipLocal = HIP_LOCAL[i]
		local hipWorld = (mimic.CFrame * CFrame.new(hipLocal)).Position

		local isFront = (hipLocal.Z < 0) == FRONT_IS_NEGATIVE_Z
		local isCenter = math.abs(hipLocal.X) < 0.001 -- a leg that landed exactly on the centerline (the ANCHOR_LEG_END leg always does; with an even LEG_COUNT its opposite-end leg can too) — has no left/right side to name
		local isRight = (hipLocal.X > 0) == RIGHT_IS_POSITIVE_X
		local sideName = (isFront and "Front" or "Back") .. (isCenter and "Center" or (isRight and "Right" or "Left")) -- e.g. "FrontRight", or "BackCenter" for a leg on the centerline
		legs[i] = {
			hipLocal = hipLocal,
			isFront = isFront,
			isRight = isRight,
			upper = makeSegment(legsFolder, bodyColor, legThicknessUpper, LEG_MESH_ID_UPPER, sideName .. "UpperLeg", hipWorld),
			lower = makeSegment(legsFolder, bodyColor, legThicknessLower, LEG_MESH_ID_LOWER, sideName .. "LowerLeg", hipWorld),
			foot = hipWorld,
			stepping = false,
			stepFrom = hipWorld,
			stepTo = hipWorld,
			foothold = nil, -- what the planted foot is standing on (see footholds above)
			stepFoothold = nil, -- what a swinging foot is going to land on
			lostFooting = false, -- the foothold went away: step now
			stepT = 0,
			stepDur = STEP_TIME,
			holdCooldown = 0, -- seconds left before THIS leg specifically is allowed to start its next step, after ITS OWN previous step plants — see the gait comment below for why this is per-leg now, not shared
			leadDir = Vector3.new(0, 0, 1), -- this leg's own current stride-lead direction, recomputed every frame in updateFeet from this hip's actual physics velocity
			leadSpeed = 0, -- this leg's own current hip speed (studs/sec, flat XZ), recomputed alongside leadDir every frame — used to scale how far a step actually reaches (see STRIDE_LEAD_REFERENCE_SPEED_PER_SIZE above), independent of leadDir's own low-speed fallback to travelDir
		}
	end

	-- walking gait: which leg steps next is decided by drift, not a fixed
	-- turn order. This used to be a strict round-robin — only the leg at
	-- STEP_SEQUENCE[sequenceIndex] was ever eligible to start a step, and
	-- every other leg just held its plant no matter how far it had
	-- drifted, until the sequence worked its way back around to it.
	-- Different hips accrue drift at different rates depending on travel
	-- direction (a leg trailing the direction of travel drifts faster
	-- than one leading it), so the "due" leg could take a couple of
	-- seconds to trip its own threshold while an off-turn leg had already
	-- drifted well past its own — that read as a leg randomly freezing in
	-- place for a couple seconds while the body kept moving, then
	-- snapping back once its turn finally came up.
	--
	-- Letting any planted leg step the moment IT trips its own threshold
	-- fixed the round-robin-starvation case, but every leg still shared
	-- ONE single gate (anyStepping/holdCooldown), so all legs still
	-- queued behind one global "turn" — the isFront/isRight fields above
	-- were computed but never actually used to split that queue. That's
	-- fine while ambling, where drift accrues slowly enough that a leg's
	-- turn comes up before it's drifted far past threshold, but during a
	-- fast chase multiple legs blow past threshold well before the single
	-- shared slot frees up, so the same freeze-then-snap symptom
	-- reappears — just from a different queue depth than before.
	--
	-- Splitting the gate into two independent per-pair slots (one per
	-- fixed diagonal pair) let both pairs make progress in parallel, but
	-- each pair was still exactly ONE shared slot for its own two legs —
	-- so starting a chase from a standstill, both legs of a pair could
	-- blow past threshold in the same frame, one would claim the slot,
	-- and its partner sat maxed out at the IK's physical reach limit
	-- (fully stretched, unable to go any further) for that leg's whole
	-- swing PLUS STEP_HOLD_TIME afterward before it was even eligible to
	-- start — then closed all that accumulated drift in one single
	-- STEP_TIME swing once it finally got a turn. That's what read as a
	-- leg freezing rigid for a beat and then snapping/leaping to catch up.
	--
	-- The fix: drop the fixed leg-to-pair assignment entirely. There is
	-- still only ever MAX_CONCURRENT_STEPS foot allowed off the ground at
	-- once (below), and which of the legs gets to use that slot is
	-- decided fresh every frame by whichever leg is furthest past its own
	-- threshold — not by which fixed partner happens to be free. A leg
	-- that's badly overdue can never again be stuck waiting behind a
	-- specific other leg; it just wins the slot the moment it opens up.
	--
	-- This used to allow 2 concurrent swings, picked purely by drift
	-- ranking with no idea which 2 legs those were — nothing stopped both
	-- winners from being, say, the two back legs (or two front, or two
	-- same-side) if those happened to be the most overdue in the same
	-- frame, which reads as a pair hopping together rather than a normal
	-- one-foot-at-a-time walk. Rather than add a diagonal-pairing rule
	-- (which reintroduces the old fixed-partner starvation this comment
	-- block already walked through and rejected above), capping this at 1
	-- sidesteps the whole "which legs are allowed together" question:
	-- with only one slot to hand out, only ever one foot is in the air at
	-- any moment, so no combination of legs can swing together at all.
	local MAX_CONCURRENT_STEPS = 1 -- feet allowed mid-swing at once, across all LEG_COUNT legs — 1 means true one-leg-at-a-time gait

	local lastFeetPos = mimic.Position
	local travelDir = Vector3.new(0, 0, 1)
	local lastVelocity = Vector3.new(0, 0, 0) -- this client's own read of the body's recent motion, purely for the tilt/velocity knocked-check below
	local idleTime = 0 -- seconds the body's actual physics velocity has been under 0.5 studs/sec, back-to-back — reset the instant it's genuinely moving again; see IDLE_COMFORT_DELAY above

	local function isKnocked()
		local tiltDot = math.clamp(mimic.CFrame.UpVector:Dot(Vector3.new(0, 1, 0)), -1, 1)
		local tiltAngle = math.acos(tiltDot)
		local actualVel = mimic.AssemblyLinearVelocity
		local velMismatch = (Vector3.new(actualVel.X, 0, actualVel.Z) - Vector3.new(lastVelocity.X, 0, lastVelocity.Z)).Magnitude
		return tiltAngle > RECOVERY_TILT_THRESHOLD or velMismatch > RECOVERY_VELOCITY_THRESHOLD
	end

	local function updateFeet(dt)
		local moved = Vector3.new(mimic.Position.X - lastFeetPos.X, 0, mimic.Position.Z - lastFeetPos.Z)
		lastFeetPos = mimic.Position
		if moved.Magnitude > 0.01 then
			travelDir = moved.Unit
		else
			-- not actually translating this frame — e.g. the body is
			-- spinning in place to face a new heading, or self-righting
			-- after a knock. hipWorld still rotates with the body every
			-- frame regardless, but without this, travelDir stays frozen
			-- on whatever direction it last physically walked in, so the
			-- stride-lead offset (hipWorld + travelDir*strideLead) ends up
			-- pointing the wrong way relative to the body's new facing —
			-- reads as the legs ending up bunched backwards underneath it.
			-- Falling back to the body's current facing keeps the plant
			-- point sane through a pure rotation.
			local look = mimic.CFrame.LookVector
			local flatLook = Vector3.new(look.X, 0, look.Z)
			if flatLook.Magnitude > 0.001 then
				travelDir = flatLook.Unit
			end
		end

		-- smoothed rather than a raw single-frame diff — see
		-- VELOCITY_SMOOTHING's comment for why the raw estimate is noisy
		-- enough to spuriously trip isKnocked() below
		local rawVelocity = dt > 0 and (moved / dt) or lastVelocity
		lastVelocity = lastVelocity:Lerp(rawVelocity, VELOCITY_SMOOTHING)

		-- each leg's own stride-lead direction, recomputed fresh every
		-- frame from THAT leg's own hip velocity rather than reused from
		-- the shared, body-CENTER-only travelDir above. travelDir only
		-- reflects the body's translation; an individual hip's actual
		-- world-space velocity also has a rotational component (the hip
		-- sweeping around the body's center as it turns), and that
		-- component scales with the hip's own radius from center — a
		-- wide stance on a big mimic turning at TURN_SPEED can have a
		-- trailing hip's rotational sweep briefly outrun or even reverse
		-- its share of the body's forward translation. Planting that foot
		-- strideLead studs ahead of the shared travelDir (which knows
		-- nothing about that sweep) could then aim the plant point behind
		-- where the hip is actually headed — read as the leg stepping
		-- backward, worse the wider the stance and worse still while
		-- slowing to a stop or turning in place, exactly when the body's
		-- own translation is smallest and so easiest for a hip's
		-- rotational sweep to dominate or reverse it.
		--
		-- This used to be estimated from a raw frame-to-frame hipWorld
		-- position delta, but that reconstructs velocity from a REPLICATED
		-- CFrame that's already subject to Roblox's own physics
		-- interpolation/jitter — noise that's small next to a fast walk
		-- but dominates the signal exactly when real hip motion is
		-- smallest (stopping, or a near-standstill turn), which is what
		-- made steps look backward most often in precisely those moments.
		-- v = v_com + ω × r (rigid-body point velocity) computed directly
		-- from the body's own AssemblyLinearVelocity/AssemblyAngularVelocity
		-- is exact, not a numerical estimate, and stays correct all the
		-- way down to a dead stop with the body still spinning in place.
		local comVel = mimic.AssemblyLinearVelocity
		local angVel = mimic.AssemblyAngularVelocity

		-- real physics speed, not the fixed-direction `moved` estimate
		-- above (that one only measures translation and reads as ~0 during
		-- a pure in-place turn too, which isn't idle) — this is what
		-- IDLE_COMFORT_DELAY actually times against
		local flatBodySpeed = Vector3.new(comVel.X, 0, comVel.Z).Magnitude
		idleTime = (flatBodySpeed < 0.5) and (idleTime + dt) or 0

		for _, leg in ipairs(legs) do
			local hipWorldNow = (mimic.CFrame * CFrame.new(leg.hipLocal)).Position
			local r = hipWorldNow - mimic.Position
			local hipVel = comVel + angVel:Cross(r)
			local flatHipVel = Vector3.new(hipVel.X, 0, hipVel.Z)
			-- falls back to the shared travelDir at low speed, same
			-- reasoning as travelDir's own fallback above — a near-zero
			-- hip velocity is too noisy a direction to trust
			leg.leadDir = flatHipVel.Magnitude > 0.5 and flatHipVel.Unit or travelDir
			-- the actual speed, independent of the direction fallback
			-- above — this is what STRIDE_LEAD_REFERENCE_SPEED_PER_SIZE scales
			-- the plant distance against below, so a near-stationary hip
			-- gets a short, corrective step even though leadDir just fell
			-- back to some other (possibly stale) direction
			leg.leadSpeed = flatHipVel.Magnitude
		end

		local knocked = isKnocked()
		local steppingCount = 0

		-- first pass: advance any leg already mid-swing, and count how
		-- many of the MAX_CONCURRENT_STEPS slots are currently in use
		for _, leg in ipairs(legs) do
			leg.holdCooldown = math.max(leg.holdCooldown - dt, 0)

			-- ride along with whatever it's standing on, or is about to
			if leg.stepping then
				if leg.stepFoothold then
					local p = footholdPoint(leg.stepFoothold)
					if p then
						leg.stepTo = p
					else
						-- the landing spot went away mid-swing: land where
						-- it last was; the next check re-steps if that's
						-- empty air now
						leg.stepFoothold = nil
					end
				end
			elseif leg.foothold then
				local p = footholdPoint(leg.foothold)
				if p then
					leg.foot = p
				else
					leg.foothold = nil
					leg.lostFooting = true
				end
			end

			if leg.stepping then
				leg.stepT = math.min(leg.stepT + dt / leg.stepDur, 1)
				local flat = leg.stepFrom:Lerp(leg.stepTo, leg.stepT)
				local arc = math.sin(leg.stepT * math.pi) * stepHeight
				leg.foot = flat + Vector3.new(0, arc, 0)
				if leg.stepT >= 1 then
					leg.stepping = false
					leg.foot = leg.stepTo
					leg.foothold, leg.stepFoothold = leg.stepFoothold, nil
					leg.holdCooldown = STEP_HOLD_TIME
					playAttachedSound(leg.lower, FOOTSTEP_SOUND, nil, FOOTSTEP_PITCH_MIN + math.random() * (FOOTSTEP_PITCH_MAX - FOOTSTEP_PITCH_MIN)) -- see "config: sound" above — fires for every landing, ordinary gait or recovery alike
				else
					steppingCount += 1
				end
			end
		end

		-- second pass: among planted legs that are actually due to step,
		-- rank by how far each has drifted and hand out whatever slots
		-- are still free to the MOST overdue legs first — so a leg that's
		-- drifted way past threshold can never end up waiting behind some
		-- other leg that's only just barely due, regardless of which
		-- hip either one happens to be
		local candidates = {}
		for _, leg in ipairs(legs) do
			if not leg.stepping and leg.holdCooldown <= 0 then
				local hipWorld = (mimic.CFrame * CFrame.new(leg.hipLocal)).Position
				-- scales the lead distance down with actual hip speed
				-- (see STRIDE_LEAD_REFERENCE_SPEED_PER_SIZE.s comment above) —
				-- clamped to 1 so a fast chase still plants the full
				-- strideLead this was tuned for, same as before
				local leadFrac = math.clamp(leg.leadSpeed / strideLeadReferenceSpeed, 0, 1)
				local plantPoint = hipWorld + worldOutward(leg.hipLocal) * footSpreadDist + leg.leadDir * (strideLead * leadFrac)
				plantPoint = clampFootRadius(plantPoint)
				local restFoot, restFoothold = groundPoint(plantPoint.X, plantPoint.Z)
				local underFootY = surfaceYAt(leg.foot.X, leg.foot.Z)
				local verticalDrift = math.abs(leg.foot.Y - underFootY)
				local drift = (leg.foot - restFoot).Magnitude

				-- while genuinely idling, a foot that's technically inside
				-- the ordinary walking threshold can still have landed
				-- somewhere crooked/awkward — there's no hurry once the body
				-- has actually stopped, so tighten the tolerance and let it
				-- settle into a comfortable rest stance instead of staying
				-- wherever its last real step happened to leave it
				local comfortThreshold = (idleTime > IDLE_COMFORT_DELAY) and (stepThreshold * IDLE_COMFORT_THRESHOLD_FRAC) or stepThreshold
				local due = (knocked and drift > stepThreshold * RECOVERY_DRIFT_FRAC)
					or drift > comfortThreshold or verticalDrift > stepVerticalThreshold
					or leg.lostFooting
				if due then
					-- nothing left under it outranks any amount of drift
					local urgency = leg.lostFooting and math.huge or drift
					table.insert(candidates, { leg = leg, drift = urgency, restFoot = restFoot, restFoothold = restFoothold })
				end
			end
		end
		table.sort(candidates, function(a, b) return a.drift > b.drift end)

		-- more than one leg due in the same frame is a BACKLOG, not just
		-- an ordinary gait — most visible right after the mimic actually
		-- comes to a full stop-and-idle (now that moveTo's arrival really
		-- works — see MimicFuse's own arrival-braking fix) and then heads
		-- off toward a fresh, differently-aimed wander target: several
		-- hips' restFoot points can all jump past their own leg's
		-- threshold in the same frame. With only MAX_CONCURRENT_STEPS=1
		-- foot ever allowed to swing at once, draining that backlog at
		-- the normal STEP_TIME (one leg every ~0.3s) meant the other
		-- overdue legs just sat planted at their stale spot — visibly
		-- "frozen" relative to the body that had already moved on — until
		-- their own turn finally came up, several tenths of a second
		-- later, and snapped into place. This never showed up in
		-- practice before because the mimic never actually held still
		-- long enough to build up that kind of simultaneous backlog — it
		-- was always drifting, so legs came due one at a time, staggered
		-- naturally. Reusing the same faster RECOVERY_STEP_TIME the
		-- physical-knockback case already uses (rather than a third
		-- separate constant) drains a same-frame backlog in a fraction of
		-- the time — worst case (all LEG_COUNT legs due at once) drops
		-- from LEG_COUNT * STEP_TIME to LEG_COUNT * RECOVERY_STEP_TIME —
		-- short enough to read as a quick scurry to catch up rather than
		-- a stall-then-snap. Steps still go out strictly one at a time
		-- (MAX_CONCURRENT_STEPS is untouched), so this doesn't reopen the
		-- synchronized-hop look that constant was written to avoid.
		local backlog = #candidates > 1

		for _, c in ipairs(candidates) do
			if steppingCount >= MAX_CONCURRENT_STEPS then break end
			local leg = c.leg
			leg.stepping = true
			steppingCount += 1
			leg.stepT = 0
			leg.stepFrom = leg.foot
			leg.stepTo = c.restFoot
			leg.stepFoothold = c.restFoothold
			leg.foothold = nil
			leg.lostFooting = false

			-- STEP_TIME/RECOVERY_STEP_TIME were both tuned assuming a hip
			-- never moves faster than strideLeadReferenceSpeed — true for a
			-- board mimic, since WALK_SPEED_PER_SIZE/CHASE_SPEED_PER_SIZE
			-- feed the exact same per-size formula strideLeadReferenceSpeed
			-- mirrors (see that constant's own comment), so its actual hip
			-- speed and this reference always scale together. A pet mimic
			-- breaks that assumption: PetMimicFuse's WALK_SPEED/CHASE_SPEED
			-- are flat numbers, not derived from bodySize at all, and at
			-- PET_MIMIC_SIZE=2 they sit well above what a size-2
			-- strideLeadReferenceSpeed expects. Before this, a step still
			-- took the same ~STEP_TIME to swing no matter how fast the hip
			-- underneath it was actually moving, so the foot spent that
			-- whole swing committed to a plant point the body had already
			-- blown past by the time the swing finished — read as the legs
			-- perpetually dragging behind rather than keeping pace.
			--
			-- speedScale reuses the exact same leadSpeed/strideLeadReferenceSpeed
			-- ratio leadFrac above already computes for stride DISTANCE, just
			-- left unclamped past 1 here (instead of capped) and applied to
			-- stepDur instead: a hip moving faster than reference gets
			-- proportionally quicker steps, whatever mimic it belongs to. No
			-- petMimic-specific branch needed — a board mimic's hip speed
			-- never exceeds the reference, so speedScale is always 1 for it
			-- and this reduces to exactly the old flat STEP_TIME/RECOVERY_STEP_TIME.
			-- MIN_STEP_TIME keeps a pet's CHASE_SPEED swing fast-but-visible
			-- instead of collapsing toward an instant teleport.
			local speedScale = math.max(leg.leadSpeed / strideLeadReferenceSpeed, 1)
			leg.stepDur = (knocked or backlog) and (RECOVERY_STEP_TIME / speedScale)
				or (STEP_TIME * (1 + (math.random() * 2 - 1) * STEP_TIME_JITTER) / speedScale)
			leg.stepDur = math.max(leg.stepDur, MIN_STEP_TIME)
		end
	end

	local function placeLegSegments(growSegLen)
		for _, leg in ipairs(legs) do
			local hipWorld = (mimic.CFrame * CFrame.new(leg.hipLocal)).Position
			local hip = hipWorld - Vector3.new(0, bodySize * 0.15, 0)
			local knee = solveKnee(hip, leg.foot, worldOutward(leg.hipLocal), growSegLen or legSegLen)
			placeSegment(leg.upper, hip, knee, legThicknessUpper)
			placeSegment(leg.lower, knee, leg.foot, legThicknessLower)
		end
	end

	-- sprout: every leg unfolds out of the body in two stages, upper
	-- segment first, then lower, and the legs overlap: the next leg
	-- starts its upper segment the moment the previous one starts its
	-- lower. Each foot lands straight onto the spot it will stand on, so
	-- there's no settle-into-place afterwards. Then, once the last foot is
	-- down, the body pushes itself up onto them (the rise, below).
	--
	-- Where each leg ends up is worked out once, up front: its foot on the
	-- ground at the stance position (the same hip + FOOT_SPREAD spot the
	-- walking IK plants at), and its knee from the same IK the walk uses,
	-- solved for the body still sitting low. The body sits that low, so
	-- the solve folds each leg up with its knee high and out — a
	-- crouched spider — and the rise then straightens the same legs.
	-- Nothing jumps at the hand-over because it's the same solve.
	--
	-- Computed off an IDENTITY orientation at the body's current position
	-- rather than mimic.CFrame's rotation. The body just landed as a real
	-- ball and can be resting at any tumbled angle; its rotation has
	-- nothing to do with which way is up. The Mimic behaviour torques the
	-- body upright (identity heading) as it rises, so by the time the
	-- steady-state loop switches to the real mimic.CFrame, they agree.
	local legUpperFrac = MimicConfig.LEG_UPPER_GROW_FRAC or 0.5
	-- LEGS_SPROUT_TIME = LEG_COUNT * upper + lower, with upper = frac * perLeg
	local perLegTime = LEGS_SPROUT_TIME / (LEG_COUNT * legUpperFrac + (1 - legUpperFrac))
	local upperTime = perLegTime * legUpperFrac
	local lowerTime = perLegTime - upperTime

	-- The body's standing height comes from here. Every frame the feet are
	-- down, this publishes FootY on the body: the average height of the
	-- ground under its feet. The Mimic behaviour holds the body
	-- STAND_HEIGHT above that, so a foot stepping up onto an orb lifts
	-- the body by its share, rather than the body hovering a fixed height
	-- over whatever happens to be under its centre. A foot mid-swing
	-- counts as the straight line between where it left and where it's
	-- landing (not the arc of the step), so the height changes smoothly
	-- across a step instead of jumping when the foot lands.
	local lastFootY = nil
	local function publishFootY()
		local sum = 0
		for _, leg in ipairs(legs) do
			if leg.stepping then
				sum += leg.stepFrom.Y + (leg.stepTo.Y - leg.stepFrom.Y) * leg.stepT
			else
				sum += leg.foot.Y
			end
		end
		local footY = sum / #legs
		if lastFootY == nil or math.abs(footY - lastFootY) > 0.001 then
			lastFootY = footY
			mimic:SetAttribute("FootY", footY)
		end
	end

	local function identityHip(leg)
		return (mimic.Position + leg.hipLocal) - Vector3.new(0, bodySize * 0.15, 0)
	end
	local function flatOutward(leg)
		local flatLocal = Vector3.new(leg.hipLocal.X, 0, leg.hipLocal.Z)
		return flatLocal.Magnitude > 0.001 and flatLocal.Unit or Vector3.new(0, 0, 1)
	end

	for i, leg in ipairs(legs) do
		local hipWorld = mimic.Position + leg.hipLocal
		local hip = identityHip(leg)
		local outward = flatOutward(leg)
		local plantPoint = clampFootRadius(hipWorld + outward * footSpreadDist)
		leg.foot, leg.foothold = groundPoint(plantPoint.X, plantPoint.Z)
		leg.stepFrom, leg.stepTo = leg.foot, leg.foot
		local knee = solveKnee(hip, leg.foot, outward, legSegLen)
		leg.sproutUpperDir = (knee - hip).Unit
		leg.sproutStart = (i - 1) * upperTime
		leg.sproutStarted = false
		leg.sproutLanded = false
	end

	local function easeOut(a)
		return 1 - (1 - a) ^ 2
	end
	-- the lower segment's curve: slow away from the knee, slow onto the
	-- ground. An ease-out did nearly all of its swing in the first few
	-- frames, which read as the foot being flicked down rather than
	-- lowered.
	local function easeInOut(a)
		return a * a * (3 - 2 * a)
	end

	-- Footholds apply from the very first frame: a foot landing on an orb
	-- during the sprout lands on it wherever it has rolled, and one whose
	-- orb is gone drops to whatever is under that spot now.
	local function trackFoot(leg)
		if not leg.foothold then
			return
		end
		local p = footholdPoint(leg.foothold)
		if p then
			leg.foot = p
		else
			leg.foot, leg.foothold = groundPoint(leg.foot.X, leg.foot.Z)
		end
		leg.stepFrom, leg.stepTo = leg.foot, leg.foot
	end

	do
		local t = 0
		local finished = false
		while not finished do
			if not mimic:GetAttribute("MimicActive") then legsFolder:Destroy() return end
			local dt = RS.RenderStepped:Wait()
			t = math.min(t + dt, LEGS_SPROUT_TIME)
			finished = t >= LEGS_SPROUT_TIME

			for i, leg in ipairs(legs) do
				local hip = identityHip(leg)
				local local_t = finished and perLegTime or (t - leg.sproutStart)
				trackFoot(leg)

				if local_t <= 0 then
					-- not started: a zero-length stub tucked inside the body
					placeSegment(leg.upper, hip, hip, legThicknessUpper)
					placeSegment(leg.lower, hip, hip, legThicknessLower)
				else
					if not leg.sproutStarted then
						leg.sproutStarted = true
						-- a distinct id per leg: see LEG_GROW_SOUND_IDS for why
						-- the same id can't be replayed this close together
						local growId = LEG_GROW_SOUND_IDS[((i - 1) % #LEG_GROW_SOUND_IDS) + 1]
						playAttachedSound(leg.upper, growId, LEG_GROW_VOLUME)
					end

					-- stage 1: the upper segment grows out of the body
					-- toward where its knee will be
					local upperAlpha = easeOut(math.clamp(local_t / upperTime, 0, 1))
					local knee = hip + leg.sproutUpperDir * (legSegLen * upperAlpha)
					placeSegment(leg.upper, hip, knee, legThicknessUpper)

					-- stage 2: the lower segment grows out of the knee. It
					-- starts pointing along the upper segment, carrying the
					-- reach outward, and swings down as it lengthens, so the
					-- foot arcs over and lands on its spot rather than
					-- poking straight at it.
					local lowerAlpha = easeInOut(math.clamp((local_t - upperTime) / lowerTime, 0, 1))
					if lowerAlpha <= 0 then
						placeSegment(leg.lower, knee, knee, legThicknessLower)
					else
						-- aimed at where the foot's spot is NOW, from the
						-- knee's final position
						local toFoot = leg.foot - (hip + leg.sproutUpperDir * legSegLen)
						local lowerLen = toFoot.Magnitude
						local lowerDir = lowerLen > 0.001 and toFoot / lowerLen or Vector3.new(0, -1, 0)
						local dir = leg.sproutUpperDir:Lerp(lowerDir, lowerAlpha)
						dir = dir.Magnitude > 0.001 and dir.Unit or lowerDir
						local footNow = knee + dir * (lowerLen * lowerAlpha)
						if lowerAlpha >= 1 then
							footNow = leg.foot
						end
						placeSegment(leg.lower, knee, footNow, legThicknessLower)
						if lowerAlpha >= 1 and not leg.sproutLanded then
							leg.sproutLanded = true
							playAttachedSound(leg.lower, FOOTSTEP_SOUND, nil, FOOTSTEP_PITCH_MIN + math.random() * (FOOTSTEP_PITCH_MAX - FOOTSTEP_PITCH_MIN))
						end
					end
				end
			end
		end
	end

	-- rise: every foot is down, and the Mimic behaviour now pushes the
	-- body up over BODY_RISE_TIME. The feet stay on what they landed on
	-- and the same IK straightens each leg under the rising hip.
	-- Hips stay on the identity layout here too, while the body rights
	-- itself; the steady-state loop below takes over from the real
	-- orientation once it's standing.
	do
		local riseTime = MimicConfig.BODY_RISE_TIME or 0.6
		local t = 0
		while t < riseTime do
			if not mimic:GetAttribute("MimicActive") then legsFolder:Destroy() return end
			local dt = RS.RenderStepped:Wait()
			t += dt
			for _, leg in ipairs(legs) do
				trackFoot(leg)
				local hip = identityHip(leg)
				local knee = solveKnee(hip, leg.foot, flatOutward(leg), legSegLen)
				placeSegment(leg.upper, hip, knee, legThicknessUpper)
				placeSegment(leg.lower, knee, leg.foot, legThicknessLower)
			end
			publishFootY()
		end
	end

	-- steady state: one continuous per-frame foot-IK loop for as long as
	-- the mimic is active — no special-casing for walk vs. crouch/eat,
	-- since either way it's just "place feet under wherever the real,
	-- already-replicated body currently is"
	while mimic:GetAttribute("MimicActive") and mimic.Parent do
		local dt = RS.RenderStepped:Wait()
		updateFeet(dt)
		placeLegSegments()
		publishFootY()
	end

	-- retract: MimicActive just went false — reverted back to an
	-- ordinary ball, whether from a bomb catching it or from wandering
	-- past the platform edge — or the mimic disappeared outright (sold,
	-- board wipe, etc). If the ball itself is still around, shrink every
	-- leg back toward its own hip together over RETRACT_TIME rather than
	-- just vanishing outright, so a reverted mimic reads as its legs
	-- pulling back into the body instead of the legs cutting out from
	-- under it. All 4 retract together (not one-at-a-time like the
	-- sprout) since this is meant to read as a quick snap-back, not
	-- another creature-standing-itself-up beat. If the ball disappears
	-- entirely partway through (sold out from under the retract, etc.),
	-- the loop below just stops early and the folder is destroyed as-is.
	if mimic.Parent then
		local startKnee, startFoot = {}, {}
		for _, leg in ipairs(legs) do
			local hipWorld = (mimic.CFrame * CFrame.new(leg.hipLocal)).Position
			local hip = hipWorld - Vector3.new(0, bodySize * 0.15, 0)
			startKnee[leg] = solveKnee(hip, leg.foot, worldOutward(leg.hipLocal), legSegLen)
			startFoot[leg] = leg.foot
		end
		local t = 0
		while t < RETRACT_TIME and mimic.Parent do
			local dt = RS.RenderStepped:Wait()
			t = math.min(t + dt, RETRACT_TIME)
			local shrink = (t / RETRACT_TIME) ^ 2 -- ease-in: slow to start, snaps the rest of the way in fast — reads as retracting rather than the sprout's grow-out played backward
			local remaining = 1 - shrink
			for _, leg in ipairs(legs) do
				local hipWorld = (mimic.CFrame * CFrame.new(leg.hipLocal)).Position
				local hip = hipWorld - Vector3.new(0, bodySize * 0.15, 0)
				local knee = hip:Lerp(startKnee[leg], remaining)
				local foot = hip:Lerp(startFoot[leg], remaining)
				placeSegment(leg.upper, hip, knee, legThicknessUpper)
				placeSegment(leg.lower, knee, foot, legThicknessLower)
			end
		end
	end

	legsFolder:Destroy()
end

-- ══════════════════════════════════════════════════════════════════════
-- watcher: finds mimics in Workspace.Balls and attaches/detaches legs
-- as each one wakes up / stops being active
-- ══════════════════════════════════════════════════════════════════════

local ballsFolder = WS:WaitForChild("Balls")
local watching = {} -- [mimic] = true, so a mimic already being watched isn't double-attached

local function watch(obj)
	if not obj:IsA("BasePart") or watching[obj] then return end
	watching[obj] = true

	local function onActiveChanged()
		if obj:GetAttribute("MimicActive") then
			task.spawn(attachLegs, obj)
		end
	end
	obj:GetAttributeChangedSignal("MimicActive"):Connect(onActiveChanged)
	onActiveChanged() -- in case it's already awake (e.g. this script started after the mimic did)

	obj.AncestryChanged:Connect(function()
		if not obj:IsDescendantOf(WS) then
			watching[obj] = nil
		end
	end)
end

for _, obj in ipairs(ballsFolder:GetChildren()) do
	watch(obj)
end
ballsFolder.ChildAdded:Connect(watch)