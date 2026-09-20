--[[
    MagnetFuse (Script)
    Path: ReplicatedStorage → Magnet
    Parent: Magnet
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-20 20:00:09
]]
--[[
	MagnetFuse (Script) — lives as a child of ReplicatedStorage.Magnet, so
	it's cloned in fresh with every magnet ball BallManager.spawnMagnet
	places. Owns the magnet's ENTIRE lifecycle end to end — rise, wander,
	telegraph, pull, shrink, color loop, and self-destruct — the same way
	BombFuse owns a bomb's fuse/detonation. BallManager places it
	(Anchored, CanCollide = false, at SPAWN_POS) and never touches it again.

	Almost everything here is TweenService + a Heartbeat loop, not
	physics — BallManager's onHB never touches the magnet (spawnMagnet
	doesn't call track()), so there's no ascend/settle/fall-through
	logic to worry about. The one exception is its own travel: rather
	than setting Position directly on an Anchored part every frame
	(which replicates as a series of discrete teleports to other
	clients, since Anchored parts don't get the interpolation Roblox
	applies to simulated ones), the magnet is unanchored and steered by
	an AlignPosition constraint instead — see "travel" below. That
	constraint is also what holds it perfectly still, fighting gravity,
	for the rest of its life once travel ends.

	Grow-in: BallManager still clones the magnet in at a GROW_AT-capped
	visual size (same vis cap every other spawned kind gets), even
	though it never tracks a magnet through its own onHB ascend/settle
	loop the way it does for everything else. So the very first thing
	this script does is tween the magnet's Size the rest of the way up
	to its real TargetSize — see the grow-in block right below. Purely
	cosmetic and over almost immediately (GROW_TWEEN is short), well
	before travel, telegraph, or pull ever look at the magnet's size —
	and everything downstream reads the TargetSize attribute rather than
	a live Size query anyway (see targetSize below), so none of that
	timing can land mid-tween even if GROW_TWEEN were ever lengthened.

	Lifecycle:
	  0. Sellable via the "demagnetizer" upgrade (see SellHandler/
	     SellClient) for the entire rise/wander/telegraph stretch below,
	     right up until the instant the pull actually starts — a sale
	     flips PendingSell, which this script checks before ever setting
	     the Pulling attribute (step 4), so a magnet already mid-sale
	     never starts pulling balls, and any telegraph already in
	     progress cancels itself immediately rather than playing out its
	     full TELEGRAPH_TIME (see pullTelegraph's own PendingSell watcher).
	     Once Pulling is set true, demagnetizer can no longer sell it —
	     by that point it's live and needs to be waited out or otherwise
	     dealt with, same as a bomb that's already exploding.
	  1. The instant this script starts running (== the instant the magnet
	     first appears, since BallManager clones it in fresh with every
	     spawn), the spawn cue fires once — SPAWN_SND attached to the
	     magnet.
	  2. Rise and wander happen on overlapping timelines, not back-to-back
	     — the vertical rise (RISE_TIME) starts immediately, while the
	     horizontal wander toward a random point WANDER_RADIUS studs from
	     the map's XZ origin (WANDER_TIME) waits WANDER_START_DELAY
	     seconds to start, so the magnet clears the floor first instead
	     of clipping through it while sliding sideways underground. Each
	     is eased on its own timeline and recombined into Position every
	     frame, so together they trace a single arc once wander kicks in.
	  3. Timed to land exactly on arrival: a telegraph sphere welded to
	     the magnet as it finishes its travel — the inverse of
	     BombFuse's explosion vfx: starts big and fully
	     invisible, then shrinks down onto the magnet's own size while
	     fading IN with an exponential-in ease (Transparency 1 -> 0),
	     instead of BombFuse's expand-while-fading-OUT. This is the only
	     warning a player gets before the pull starts, so nothing
	     dangerous happens until it's fully played out.
	  4. The instant the telegraph finishes (== the instant the magnet
	     arrives), the pull-start cue fires once — ACTIVE_SND, via
	     pullSound, a real Sound instance already created and primed
	     back at spawn (see below) so this Play() is instant instead of
	     a fresh instance needing to load in — same approach BombFuse's
	     own boomSound and RadiantBombFuse's own pullSound use — and a
	     shine — literally BombFuse's own
	     billboard-flash effect, left alive for the whole pull instead of
	     flashing once and disappearing (see pullShine()): it pops in
	     white for SHINE_WHITE_TIME seconds, then yellow for the rest of
	     SHINE_POP_DELAY, then almost immediately starts instantly
	     flicking between pure red and pure blue, SHINE_FLICKER_HZ times
	     a second.
	  5. From that same instant, the ball itself goes invisible — the
	     shine above is the only thing actually visible from here on. Its
	     size pops in at 3x, eases down to 1x over SHINE_ENTRANCE_TIME,
	     then holds flat there while gently oscillating, SHINE_OSC_HZ
	     times a second, on top of its flicker — until the final
	     SHINE_EXIT_TIME seconds of the pull, when it eases down to 0,
	     timed to hit exactly 0 on the same frame the magnet is
	     destroyed. Under the hood the (invisible) ball's Size still
	     shrinks — linearly, from whatever size it arrived at down to 0,
	     over exactly SHRINK_TIME seconds, regardless of how big it
	     arrived — since that's what scales the pull strength. Every
	     Heartbeat, the magnet also pulls every regular AND radiant ball
	     toward its current position, strength scaled by that same
	     shrinking size.
	  6. From the moment it's placed (not gated on any of the above), its
	     own color eases red <-> blue, one second each way, forever
	     (tween, Reverses + infinite repeat) — so it's visibly "alive"
	     immediately. This gets cancelled the instant the pull starts and
	     the ball goes invisible (see 5), since nothing would be visibly
	     tweening anyway — the shine's own flicker takes over as the
	     visible cue from that point on.
]]

local RS = game:GetService("RunService")
local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local TS = game:GetService("TweenService")

local magnet = script.Parent
local ballsFolder = magnet.Parent -- the shared "Balls" folder BallManager spawns everything into
local ballT = Rep:WaitForChild("Ball")

-- config: travel
-- Target height and wander radius both scale with the magnet's own size now
-- — a size-10 magnet is the reference point, so it still rises to exactly
-- 25 and wanders out to exactly 65 (today's flat values, unchanged), while
-- every other size scales linearly off that anchor. riseYForSize/
-- wanderRadiusForSize are called once targetSize is known (see targetSize
-- below) rather than these being flat constants.
local RISE_Y_BASE, RISE_Y_PER_SIZE = 25, 0.5
local WANDER_RADIUS_BASE, WANDER_RADIUS_PER_SIZE = 65, 2
local SIZE_REF = 10
local function riseYForSize(size)
	return RISE_Y_BASE + RISE_Y_PER_SIZE * (size - SIZE_REF)
end
local function wanderRadiusForSize(size)
	return WANDER_RADIUS_BASE + WANDER_RADIUS_PER_SIZE * (size - SIZE_REF)
end
local RISE_TIME, RISE_STYLE = 2, Enum.EasingStyle.Exponential
local WANDER_TIME, WANDER_STYLE = 3, Enum.EasingStyle.Sine
local WANDER_START_DELAY = 0.1                       -- seconds to hold XZ still (Y still rises) before starting the horizontal wander — RISE_STYLE is an Out ease, so the magnet is already well clear of the floor by 1s in; starting the sideways move any earlier shows it clipping through the floor while still underground

-- config: idle color loop — runs the whole time the magnet exists, not gated on arrival/telegraph/pull
local COLOR_A, COLOR_B = Color3.new(1, 0, 0), Color3.new(0, 0, 1) -- pure red / pure blue
local COLOR_CYCLE_TIME = 0.5                           -- one leg of the ease; Reverses below makes the full loop 2x this

-- config: pull telegraph — the warning sphere, timed to finish right as the magnet arrives, before pulling is allowed to start
local TELEGRAPH_COLOR = Color3.fromRGB(255, 255, 0) -- yellow, distinct from the idle color loop's red/blue
local TELEGRAPH_RADIUS_PER_SIZE = 3                  -- scales with the magnet's arrival size, same idea as BombFuse's RADIUS_PER_SIZE
local TELEGRAPH_TIME = 2

-- config: pull + shrink — only starts once the telegraph sphere has finished shrinking down onto the magnet
local SHRINK_TIME = 2                                -- seconds from "pull starts" to gone, REGARDLESS of how big the magnet is
local PULL_ACCEL = 10                                -- pull acceleration per stud of the magnet's CURRENT size, applied to every regular ball each frame

-- config: spawn cue — sound fired once, the instant the magnet first appears
local SPAWN_SND, SPAWN_VOL, SPAWN_PITCH = "rbxassetid://12221842", 0.2, 4 -- pitch here is PlaybackSpeed (see SoundClient's "attached") — 4x speed

-- config: pull-start cue — sound + shine, both fired once, the instant pulling begins
local ACTIVE_SND, ACTIVE_VOL, ACTIVE_PITCH = "rbxassetid://12222095", 0.7, 3 -- pitch here is PlaybackSpeed (see SoundClient's "attached") — 3x speed
local FLASH_IMAGE = "rbxassetid://131187911056182"   -- same image BombFuse's flash uses — keep in sync with SoundClient's preload
local SHINE_SCALE = 1                                -- multiple of the magnet's ARRIVAL size (startSize), not a fixed world size. NOTE: BillboardGui.Size's Scale component is always absolute studs in 3D space — it is NOT relative to the Adornee's size despite being adorned to the magnet — so pullShine() below multiplies this by startSize itself every time it sets Size, to actually get "proportional to the magnet's size" instead of a flat 10 studs for every magnet regardless of how big it arrived
local SHINE_OSC_MIN, SHINE_OSC_MAX = 0.9, 1.1        -- the shine's size oscillates between these multiples of SHINE_SCALE...
local SHINE_OSC_HZ = 8                               -- ...SHINE_OSC_HZ full oscillations per second, for as long as the pull lasts
local SHINE_ENTRANCE_START, SHINE_ENTRANCE_TIME = 3, 0.5 -- shine pops in at this multiple of SHINE_SCALE, eases down to 1x over this many seconds, then holds flat at 1x (oscillation still layers on top)
local SHINE_ENTRANCE_STYLE = Enum.EasingStyle.Quad   -- easing (Out) for the pop-in above
local SHINE_EXIT_TIME = 0.5                          -- seconds before the magnet is destroyed that the shine starts easing from 1x down to 0 (holds flat at 1x before this window)
local SHINE_EXIT_STYLE = Enum.EasingStyle.Quad       -- easing (In) for that final shrink-to-0
local SHINE_POP_DELAY = 0.1                           -- total time (white + yellow) before the flicker loop below takes over — must be well above one frame or the flicker overwrites it before it's ever seen
local SHINE_WHITE_TIME = 0.03                        -- of that pop window, how long stays white before switching to yellow for the remainder
local SHINE_FLICKER_HZ = 4                           -- after the white-then-yellow pop, the shine's color instantly snaps between COLOR_A/COLOR_B (no fade) this many times a second

local se = Rep:WaitForChild("SoundEvents")

-- Keep the pull-start cue local to this magnet. The Sound is created and
-- primed immediately (well before pulling actually starts — rise, wander,
-- and the telegraph all still have to play out first), so the actual
-- pull-start moment only needs to restart this existing instance; no
-- SoundEvents round-trip (and no client having to build+load a fresh
-- Sound on demand) is involved. Same approach BombFuse's own boomSound
-- and RadiantBombFuse's own pullSound use for their equivalent cues —
-- parented straight to the magnet and left there rather than moved to a
-- standalone anchor, since (unlike a bomb, which is destroyed the
-- instant its sound plays) the magnet stays alive for the whole
-- SHRINK_TIME pull afterward, well past ACTIVE_SND's own length.
local pullSound = Instance.new("Sound")
pullSound.SoundId = ACTIVE_SND
pullSound.Volume = ACTIVE_VOL
pullSound.PlaybackSpeed = ACTIVE_PITCH
pullSound.Parent = magnet

-- Prime the Sound instance without producing an audible cue.
pullSound.Volume = 0
pullSound:Play()
pullSound:Stop()
pullSound.Volume = ACTIVE_VOL

-- ── grow-in: BallManager clones the magnet in at a GROW_AT-capped
-- visual size, same as every other spawned kind — this is what tweens
-- it the rest of the way up to its real TargetSize, since a magnet
-- never goes through BallManager's own onHB ascend/settle loop (see
-- header). targetSize is captured once, here, and reused everywhere
-- else below (telegraph radius, pull startSize) instead of ever reading
-- magnet.Size.X live — same convention BombFuse/BumperFuse use their
-- own TargetSize attribute for — so nothing downstream can land mid-tween.
local GROW_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out) -- same shape as BallManager's own GROW_TWEEN; kept as a separate local since this script has no access to that one
local targetSize = magnet:GetAttribute("TargetSize") or magnet.Size.X
if magnet.Size.X < targetSize then
	TS:Create(magnet, GROW_TWEEN, { Size = Vector3.new(targetSize, targetSize, targetSize) }):Play()
end

-- computed once targetSize is known — see riseYForSize/wanderRadiusForSize above
local RISE_Y = riseYForSize(targetSize)
local WANDER_RADIUS = wanderRadiusForSize(targetSize)

-- ── spawn cue: fired once, right as the magnet first appears ──
-- Uses "positional" (a plain Vector3), not "attached" (an Instance
-- reference) — this fires in the very same instant the magnet is
-- created, before it's guaranteed to have replicated to every client
-- yet. An Instance argument that hasn't replicated to a given client
-- arrives there as nil, which trips attached()'s own
-- "not (target and target.Parent)" guard and silently drops the sound
-- on that client. "positional" sidesteps this entirely since it just
-- spawns its own local anchor part from a position, no dependency on
-- the magnet instance having arrived yet. (The pull-start cue below
-- doesn't need this at all anymore — it's played straight off pullSound,
-- a real Sound instance already sitting on the magnet by then — see its
-- creation above.)
se:FireAllClients("positional", magnet.Position, SPAWN_SND, SPAWN_VOL, SPAWN_PITCH)

-- ── idle color loop: pure red <-> pure blue, one second each way, forever ──
magnet.Color = COLOR_A
local colorTween = TS:Create(
	magnet,
	TweenInfo.new(COLOR_CYCLE_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
	{ Color = COLOR_B }
)
colorTween:Play()

-- ── pull telegraph: the inverse of BombFuse's explosion vfx — starts
-- big and fully invisible, shrinks down onto the magnet's own size while
-- fading IN, instead of BombFuse's expand-while-fading-OUT. Nothing
-- downstream (sound, shine, pull, shrink) happens until this has
-- actually finished. Welded to the magnet instead of sitting at the
-- wander target — the magnet is still mid-travel for the whole
-- telegraph window, so this keeps the warning sphere glued to it rather
-- than marking a fixed landing spot.
--
-- This used to copy magnet.Position onto the telegraph ball every
-- Heartbeat, which is exactly the "Position on an Anchored part" pattern
-- the magnet's own travel moved away from — same snapping, plus now the
-- magnet's real motion comes from a physics constraint, so a Heartbeat
-- copy is reading it a step late and drifting out of sync (the
-- telegraph visibly running ahead of/behind the magnet). Welding the two
-- together means the physics engine solves them as one rigid assembly
-- every step — same position, same instant, no copying — and gives the
-- telegraph the same network smoothing as the magnet.
local function pullTelegraph(size)
	local startRadius = size * TELEGRAPH_RADIUS_PER_SIZE

	local ball = Instance.new("Part")
	ball.Shape, ball.Anchored, ball.CanCollide, ball.CanQuery = Enum.PartType.Ball, false, false, false
	ball.Material, ball.Color = Enum.Material.Neon, TELEGRAPH_COLOR
	ball.Transparency = 1 -- fully invisible at first; fades in as it shrinks
	ball.Size, ball.Position, ball.Parent = Vector3.new(startRadius, startRadius, startRadius), magnet.Position, WS

	local weld = Instance.new("WeldConstraint")
	weld.Part0, weld.Part1 = magnet, ball
	weld.Parent = ball

	-- the weld only holds while both parts exist — if the magnet is
	-- destroyed mid-telegraph (e.g. stripped by a collapse) there's
	-- nothing left to follow, so just clean the telegraph up immediately
	-- rather than leaving it unanchored and unwelded to fall on its own
	local magnetGoneConn
	magnetGoneConn = magnet.Destroying:Connect(function()
		if ball.Parent then ball:Destroy() end
	end)

	local shrink = TS:Create(ball,
		TweenInfo.new(TELEGRAPH_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.In),
		{ Size = Vector3.new(size, size, size) })
	local fadeIn = TS:Create(ball,
		TweenInfo.new(TELEGRAPH_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.In),
		{ Transparency = 0 })

	-- self-cleaning regardless of whether this script is still around by
	-- the time it fires (e.g. stripped mid-telegraph by a collapse) —
	-- same pattern BombFuse's own vfx() uses for its expanding ball.
	-- Tween:Cancel() below also fires this same Completed event (with a
	-- Cancelled PlaybackState instead of Completed), so the sell-triggered
	-- early stop just below and this normal finish both funnel through
	-- the one cleanup path here.
	local pendingSellConn
	shrink.Completed:Connect(function()
		magnetGoneConn:Disconnect()
		if pendingSellConn then pendingSellConn:Disconnect() end
		if ball.Parent then ball:Destroy() end
	end)

	-- a demagnetizer sale landing mid-telegraph shouldn't let the warning
	-- sphere keep playing out for its full TELEGRAPH_TIME regardless —
	-- cancelling both tweens fires shrink.Completed immediately (see
	-- above), tearing the telegraph down right away instead of leaving it
	-- visibly running until the magnet's own Destroy() up to
	-- PRE_SELL_DELAY later
	pendingSellConn = magnet:GetAttributeChangedSignal("PendingSell"):Connect(function()
		if magnet:GetAttribute("PendingSell") then
			shrink:Cancel()
			fadeIn:Cancel()
		end
	end)

	shrink:Play()
	fadeIn:Play()
	task.wait(TELEGRAPH_TIME) -- sequencing only; the cleanup above doesn't depend on this thread surviving
end

-- ── travel: rise starts immediately; wander waits WANDER_START_DELAY so
-- the magnet clears the floor first — a NumberValue tweens the magnet's
-- Y on its own timeline (RISE_TIME) while a Vector3Value tweens its X/Z
-- on its own, later-starting timeline (WANDER_TIME); a small Heartbeat
-- loop below just recombines the two every frame, since TweenService
-- can't run two independent tweens on the same Position property at
-- once without them fighting each other.
--
-- The recombined value drives an AlignPosition constraint's target
-- instead of magnet.Position directly — magnet.Anchored is flipped off
-- here so the constraint actually has something to push on. Moving it
-- this way (a physically-simulated part being steered toward a moving
-- goal) gets the same client-side smoothing/interpolation any other
-- moving part gets, instead of the per-frame teleports an Anchored
-- part's Position replicates as.
--
-- RigidityEnabled matters here: without it, AlignPosition is a
-- spring/damper chasing its target, and against a target moving this
-- fast (WANDER_RADIUS studs over WANDER_TIME seconds) the spring never
-- fully catches up — the magnet visibly trails behind where it should
-- be. Rigid mode snaps the constraint's own solve to the target exactly
-- every physics step instead of easing toward it, so there's no
-- catch-up lag; it's still an unanchored, physically-simulated part
-- underneath, so it still gets normal network-replication smoothing —
-- rigid removes the *spring* lag, not the part's own smoothing.
-- SetNetworkOwner(nil) keeps the server authoritative over that
-- simulation instead of leaving it to whichever client Roblox would
-- otherwise auto-assign as owner (normally the nearest player) — every
-- client should be seeing the same server-driven motion, not a
-- particular player's local simulation of it.
magnet.Anchored = false
pcall(function() magnet:SetNetworkOwner(nil) end)

local moveAttachment = Instance.new("Attachment")
moveAttachment.Parent = magnet

local aligner = Instance.new("AlignPosition")
aligner.Attachment0 = moveAttachment
aligner.Mode = Enum.PositionAlignmentMode.OneAttachment
aligner.RigidityEnabled = true
aligner.Position = magnet.Position -- start exactly where it already is, so nothing jumps the instant this is enabled
aligner.Parent = magnet

local startPos = magnet.Position

local angle = math.random() * math.pi * 2
local target = Vector3.new(math.cos(angle) * WANDER_RADIUS, RISE_Y, math.sin(angle) * WANDER_RADIUS)

local riseDriver = Instance.new("NumberValue")
riseDriver.Value = startPos.Y
local riseTween = TS:Create(riseDriver, TweenInfo.new(RISE_TIME, RISE_STYLE, Enum.EasingDirection.Out), { Value = RISE_Y })

local wanderDriver = Instance.new("Vector3Value")
wanderDriver.Value = Vector3.new(startPos.X, 0, startPos.Z)
local wanderTween = TS:Create(wanderDriver, TweenInfo.new(WANDER_TIME, WANDER_STYLE, Enum.EasingDirection.InOut), { Value = Vector3.new(target.X, 0, target.Z) })

local travelConn
travelConn = RS.Heartbeat:Connect(function()
	if not magnet.Parent then
		travelConn:Disconnect()
		return
	end
	local xz = wanderDriver.Value
	aligner.Position = Vector3.new(xz.X, riseDriver.Value, xz.Z)
end)

riseTween:Play()
task.delay(WANDER_START_DELAY, function()
	wanderTween:Play()
end)

-- fires the telegraph so it finishes exactly as the (now delayed) wander
-- does — starts TELEGRAPH_TIME before the wander tween completes, at the
-- magnet's real target size (targetSize, not a live Size read — see the
-- grow-in comment above)
task.delay(WANDER_START_DELAY + WANDER_TIME - TELEGRAPH_TIME, function()
	if magnet.Parent and not magnet:GetAttribute("PendingSell") then
		pullTelegraph(targetSize)
	end
end)

wanderTween.Completed:Wait()
travelConn:Disconnect()
riseDriver:Destroy()
wanderDriver:Destroy()
-- aligner itself is left alone (not destroyed) — its target just stops
-- updating, so it keeps holding the magnet exactly here, still fighting
-- gravity, for the rest of its life (telegraph, pull, shrink)

-- PendingSell here covers a sell that landed anywhere during travel or
-- the telegraph (see the task.delay guard above for the telegraph's own
-- copy of this same check) — same reasoning as BombFuse's stillLive()
-- check gating its own detonation
if not magnet.Parent or magnet:GetAttribute("PendingSell") then return end -- destroyed or sold mid-travel/telegraph — never starts pulling

-- flips the instant pulling actually begins. SellHandler/SellClient
-- both key off this to stop a magnet from being sellable at all once
-- it's here — demagnetizer is only meant to let a player cash a magnet
-- out BEFORE it becomes a live hazard, not bail out of one already
-- mid-pull (see their headers)
magnet:SetAttribute("Pulling", true)

-- ── pull-start cue: sound + shine, both fired once, right as pulling begins ──
-- pullSound was created and primed back at spawn (see above), so this is
-- just restarting an existing, already-loaded instance.
pullSound:Play()

magnet.Transparency = 1 -- the ball goes invisible from here on — the shine below is the only visible sign of it shrinking away
colorTween:Cancel() -- no point tweening a color nobody can see for the whole pull; the shine's own flicker (below) takes over as the visible cue

-- the magnet's own "display" BillboardGui (whatever label/UI it was
-- showing up to now) gets torn down here, since the shine above takes
-- over as the only visible thing from this point on
for _, child in ipairs(magnet:GetChildren()) do
	if child:IsA("BillboardGui") and child.Name:lower() == "display" then
		child:Destroy()
		break
	end
end

-- literally BombFuse's flash() effect, adorned to the magnet itself
-- (still alive at this point, unlike a detonating bomb — no need for
-- BombFuse's separate anchor-part trick) — except instead of flashing
-- once and disappearing, this one stays alive for the whole pull
-- (destroyed along with the magnet, since it's parented to it), gently
-- oscillating in size, and — via the Heartbeat loop below, once its own
-- brief white-then-yellow pop has played out — instantly flickering red<->blue.
--
-- Size is three independent curves recombined every Heartbeat (same
-- driver+recombine trick the travel arc uses above, since TweenService
-- can't run multiple tweens against the same Size property at once):
-- entranceDriver pops 3x -> 1x once at the start and then holds,
-- oscDriver oscillates 0.9x <-> 1.1x on top of that forever, and an exit
-- factor (computed in the pull+shrink loop below) sits flat at 1 for
-- almost the whole pull, then eases 1 -> 0 over just the final
-- SHINE_EXIT_TIME seconds, timed off the same elapsed/SHRINK_TIME clock
-- the magnet's own Size uses so it hits exactly 0 the instant the magnet
-- is destroyed.
local function pullShine(startSize)
	local gui = Instance.new("BillboardGui")
	gui.Adornee, gui.AlwaysOnTop, gui.Parent = magnet, true, magnet
	local baseSize = SHINE_SCALE * startSize
	gui.Size = UDim2.new(baseSize * SHINE_ENTRANCE_START * SHINE_OSC_MIN, 0, baseSize * SHINE_ENTRANCE_START * SHINE_OSC_MIN, 0) -- corrected on the very next Heartbeat

	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency, img.BorderSizePixel = 1, 0
	img.Size, img.Image = UDim2.new(1, 0, 1, 0), FLASH_IMAGE
	img.ImageColor3, img.ImageTransparency = Color3.new(1, 1, 1), 0 -- starts white — the Heartbeat loop below switches it to yellow, then to the flicker
	img.ScaleType, img.Parent = Enum.ScaleType.Fit, gui
	img.ZIndex = 10
	-- AlwaysOnTop (above) bypasses the normally-composited render that a
	-- collapse's ColorCorrectionEffect desaturates — this attribute is
	-- what lets BallManager's triggerCollapse find and grey this out in
	-- step with everything else instead of it staying full color for the
	-- whole freeze (this shine lives far longer than BombFuse's flash,
	-- so it's the one actually likely to be caught mid-collapse)
	img:SetAttribute("GreyOnCollapse", true)

	-- one-shot pop: 3x -> 1x over SHINE_ENTRANCE_TIME, eases out, then holds at 1 forever after
	local entranceDriver = Instance.new("NumberValue")
	entranceDriver.Value = SHINE_ENTRANCE_START
	local entranceTween = TS:Create(entranceDriver,
		TweenInfo.new(SHINE_ENTRANCE_TIME, SHINE_ENTRANCE_STYLE, Enum.EasingDirection.Out),
		{ Value = 1 })
	entranceTween:Play()

	-- ongoing oscillation: 0.9x <-> 1.1x, forever, for as long as the pull lasts
	local oscDriver = Instance.new("NumberValue")
	oscDriver.Value = SHINE_OSC_MIN
	local oscTween = TS:Create(oscDriver,
		TweenInfo.new(1 / (SHINE_OSC_HZ * 2), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Value = SHINE_OSC_MAX })
	oscTween:Play()

	return gui, img, entranceDriver, oscDriver
end
local startSize = targetSize -- the magnet's size the instant pulling begins — drives the shine's proportional scale below, AND the shrink/pull loop's own curve. Reused from the grow-in capture above rather than re-reading magnet.Size.X, same reasoning as the telegraph call above.
local shineGui, shineImg, shineEntranceDriver, shineOscDriver = pullShine(startSize)

-- ── pull + shrink loop: only now, once the telegraph has fully played ──
-- Linear shrink from whatever size it arrived at to 0 over exactly
-- SHRINK_TIME seconds — "relative to size" in the sense that a bigger
-- magnet shrinks by more studs per second (startSize / SHRINK_TIME) to
-- still land on exactly 0 at the same SHRINK_TIME mark a smaller one
-- would, rather than every magnet losing studs at the same flat rate.
-- The ball itself is invisible now, but its Size still drives both the
-- pull strength below AND (via startSize, captured above) the shine's
-- own baseline size, so a bigger magnet produces a proportionally
-- bigger shine.
local elapsed = 0
local shineStage = 0 -- 0 = white, 1 = yellow, 2 = flickering — only write ImageColor3 on an actual transition, not every frame
local flickerPhase = nil
local hbConn
hbConn = RS.Heartbeat:Connect(function(dt)
	-- PendingSell is set the instant SellService.sellWithHighlight starts
	-- selling this magnet (demagnetizer) — same idea as BombFuse's
	-- stillLive() check: don't let the pull keep affecting balls for the
	-- ~0.3s highlight fade between that and the magnet's actual Destroy()
	if not magnet.Parent or magnet:GetAttribute("PendingSell") then
		hbConn:Disconnect()
		return
	end

	elapsed = math.min(elapsed + dt, SHRINK_TIME)
	local size = startSize * (1 - elapsed / SHRINK_TIME) -- 0 at pull-start -> 0 exactly when the magnet is destroyed
	magnet.Size = Vector3.new(size, size, size)

	-- white -> yellow -> flicker, each written once on its own transition
	-- rather than every frame (only the flicker needs to keep changing,
	-- and even that only ~SHINE_FLICKER_HZ times a second, not 60)
	if shineStage == 0 and elapsed >= SHINE_WHITE_TIME then
		shineImg.ImageColor3 = Color3.new(1, 1, 0) -- yellow
		shineStage = 1
	end
	if shineStage == 1 and elapsed >= SHINE_POP_DELAY then
		shineStage = 2
	end
	if shineStage == 2 then
		-- instant, no tween: snaps to the other color every 1/SHINE_FLICKER_HZ seconds
		local phase = math.floor(elapsed * SHINE_FLICKER_HZ) % 2
		if phase ~= flickerPhase then
			shineImg.ImageColor3 = (phase == 0) and COLOR_A or COLOR_B
			flickerPhase = phase
		end
	end

	-- recombine the shine's three size curves (see pullShine above) —
	-- flat at 1 until the final SHINE_EXIT_TIME seconds, then eases to 0,
	-- timed off the same elapsed/SHRINK_TIME clock the magnet's own Size
	-- uses so it always lands on exactly 0 the instant the magnet gets
	-- destroyed below
	local timeLeft = SHRINK_TIME - elapsed
	local exitMult = 1
	if timeLeft <= SHINE_EXIT_TIME then
		local exitFrac = 1 - timeLeft / SHINE_EXIT_TIME -- already in [0, 1]: timeLeft is bounded to [0, SHINE_EXIT_TIME] by the guard above (elapsed itself is clamped to SHRINK_TIME below)
		exitMult = 1 - TS:GetValue(exitFrac, SHINE_EXIT_STYLE, Enum.EasingDirection.In)
	end
	local shineMult = shineEntranceDriver.Value * shineOscDriver.Value * exitMult
	local shineSize = SHINE_SCALE * startSize * shineMult -- proportional to the magnet's arrival size, not a flat stud count (see SHINE_SCALE above)
	shineGui.Size = UDim2.new(shineSize, 0, shineSize, 0)

	if elapsed >= SHRINK_TIME then
		hbConn:Disconnect()
		shineEntranceDriver:Destroy()
		shineOscDriver:Destroy()
		magnet:Destroy() -- also tears down the shine (parented to it) and this script; colorTween was already cancelled when the pull started
		return
	end

	-- pulls every regular AND radiant ball toward the magnet's current
	-- position; strength scales with the magnet's own current
	-- (shrinking) size, per spec — no distance falloff, so the pull is
	-- uniform regardless of how far a ball currently is. Bombs and every
	-- other special stay unaffected, same as before.
	local pos = magnet.Position
	for _, obj in ipairs(ballsFolder:GetChildren()) do
		if obj ~= magnet and obj.Name == ballT.Name and not obj:GetAttribute("Held") then
			local toMagnet = pos - obj.Position
			local dist = toMagnet.Magnitude
			if dist > 0.01 then
				obj.AssemblyLinearVelocity += (toMagnet / dist) * PULL_ACCEL * size * dt
			end
		end
	end
end)