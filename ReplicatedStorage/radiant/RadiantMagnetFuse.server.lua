--[[
    RadiantMagnetFuse (Script)
    Path: ReplicatedStorage → radiant
    Parent: radiant
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 14:24:26
]]
--[[
	RadiantMagnetFuse (Script) — place in ReplicatedStorage.radiant (NOT
	nested under the Magnet template — lives alongside RadiantFuse and
	RadiantBombFuse in that shared "radiant" folder, rather than loose at
	the top level of ReplicatedStorage).

	This is the full radiant replacement for MagnetFuse, not an add-on to
	it: BallManager's applyRadiantOverlay destroys the stock MagnetFuse a
	radiant magnet was cloned in with (see spawnMagnet's own `radiant`
	param) and clones this in instead, so a radiant magnet runs ONLY this
	script, never both — same swap RadiantBombFuse gets for a bomb. Rise,
	wander, telegraph, grow-in, and the demagnetizer-sellable-until-pull
	window are all still duplicated here from MagnetFuse's own shape
	(self-contained script, same as RadiantBombFuse doesn't require
	BombFuse) — the things that actually differ, per the design notes:

	  1. Idle color: cycles through the same fixed rainbow sequence
	     RadiantFuse gives a plain radiant ball (~3s per loop) instead of
	     MagnetFuse's red<->blue ease. Runs for as long as the magnet
	     exists and hasn't started pulling — see idleStillLive().
	  2. Pull strength is tripled (this script's own PULL_ACCEL = 3x
	     MagnetFuse's PULL_ACCEL of 10) and lasts 3x as long
	     (PULL_DURATION = 3x MagnetFuse's own SHRINK_TIME of 2) — both
	     per the design notes verbatim ("tripled strength... lasts for 3x
	     as long").
	  3. Pulls EVERY live object in the shared Balls folder — regular
	     balls AND every special (bombs, other magnets, mimics,
	     splitters, mergers) — instead of MagnetFuse's own ballT.Name-only
	     filter. Only this magnet itself and anything currently Held are
	     excluded; see the pull loop in the main Heartbeat below.
	  4. Once pulling starts, this magnet doesn't just hold still at its
	     wander target the way a plain magnet's aligner does — it orbits
	     the board at that same radius, its angular speed ramping up the
	     whole time (see the pull + orbit loop below), before
	     disappearing at the end of PULL_DURATION. The goal (per the
	     design notes) is building up enough momentum that a large ball
	     caught in the pull spins off rather than just getting dragged in
	     place. The wander phase's own aligner/AlignPosition setup is
	     retired the instant pulling begins (magnet.Anchored = true,
	     aligner:Destroy()) rather than reused for the orbit — nothing
	     about the orbit needs physics (no collision, nothing pushes back
	     on it), so it's driven by a plain, direct Position write off a
	     parametric circle every Heartbeat instead, with no constraint
	     around to fight it.
	  5. The pull shine copies RadiantBombFuse's own pull-shine shape
	     wholesale (entrance pop, oscillation, rainbow color cycling via
	     pullRainbow(), exit shrink) instead of MagnetFuse's own
	     white->yellow->red/blue-flicker shine — except it still opens
	     with a brief pure-white pop first, mirroring the very start of a
	     normal magnet's own shine, before handing off to the rainbow
	     cycle for the rest of the pull. See pullShine/SHINE_WHITE_TIME.
	  6. The pull telegraph tracks the magnet's own idle color every
	     frame for as long as it's up, instead of holding flat on
	     MagnetFuse's own fixed yellow — the magnet hasn't started
	     pulling yet while the telegraph is visible, so the telegraph
	     reads as glued to whatever color the magnet's idle cycle (see
	     #1) is actually showing at that moment, rather than running an
	     independent rainbow of its own that could drift out of phase.
	     See pullTelegraph.
	  7. The idle color cycle's starting point (which color, and how far
	     into the transition to it) is randomized per magnet — same
	     "roll a random phase once at script start" approach
	     RadiantBombFuse's own hueOffset uses for its rainbow — so
	     multiple radiant magnets on the board don't all flip colors in
	     lockstep. See idleStartOffset.

	Target height (RISE_Y) and target wander radius (WANDER_RADIUS, which
	also doubles as the orbit radius once pulling starts) are both scaled
	by size exactly the same way MagnetFuse's own riseYForSize/
	wanderRadiusForSize now are — see those below, same constants/
	reasoning, duplicated here rather than shared since this script
	doesn't require MagnetFuse. Both are anchored to size 10: a size-10
	magnet of either kind still rises to 25 and wanders/orbits at 65
	(today's flat values, unchanged), with every other size scaling
	linearly off that anchor.

	The orbit itself eases in from a standstill (ORBIT_EASE_TIME) rather
	than snapping straight to its cruising angular speed the instant
	pulling begins. It's also driven differently than the wander phase
	that precedes it: rather than continuing to steer the wander's own
	AlignPosition constraint, the magnet is anchored and its Position is
	written directly off a parametric circle every Heartbeat once
	orbiting starts (see the Anchored/aligner:Destroy() switch, and the
	pull + orbit loop below) — no physics involved, so Y (a literal
	constant, RISE_Y, in that formula) can't drift the way it could
	fighting a constraint's own solve.

	Sell price (6x instead of a plain magnet's 2x, once "demagnetizer" is
	owned) lives in SellService, not here — see its
	RADIANT_MAGNET_SELL_MULTIPLIER, keyed off the same IsRadiant
	attribute BallManager's applyRadiantOverlay sets. Sellability itself
	(gated on Pulling) is unchanged from a plain magnet — see
	SellHandler/SellClient's own isMagnet handling.
]]

local RS = game:GetService("RunService")
local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local TS = game:GetService("TweenService")

local magnet = script.Parent
local ballsFolder = magnet.Parent -- the shared "Balls" folder BallManager spawns everything into

-- ── config: travel ──────────────────────────────────────────────────
-- riseYForSize: identical constants/reasoning to MagnetFuse's own
-- version (see its header) — duplicated here rather than shared since
-- this script fully replaces MagnetFuse rather than requiring it, same
-- as everything else in this file.
-- Target height and wander radius (the latter also doubling as the orbit
-- radius once pulling starts, see "pull + orbit" below) both scale with the
-- magnet's own size — reanchored to size 10 (was size 5) to match
-- MagnetFuse's own riseYForSize/wanderRadiusForSize, so a size-10 magnet of
-- either kind still rises to exactly 25 and wanders/orbits at exactly 65
-- (today's flat values, unchanged), with every other size scaling linearly
-- off that same anchor.
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
local WANDER_START_DELAY = 0.1

-- ── config: idle color loop — literally RadiantFuse's own COLORS/
-- CYCLE_TIME, duplicated here so this script stays self-contained — see
-- idleStillLive() for what stops it (Parent gone, sold, OR pulling
-- started, unlike RadiantFuse's own ball which only ever stops via the
-- first two) ──
local COLORS = {
	Color3.fromRGB(255, 0, 0),
	Color3.fromRGB(255, 255, 0),
	Color3.fromRGB(0, 255, 0),
	Color3.fromRGB(0, 255, 255),
	Color3.fromRGB(0, 0, 255),
	Color3.fromRGB(255, 0, 255),
}
local CYCLE_TIME = 3
local SEGMENT_TIME = CYCLE_TIME / #COLORS
local segmentInfo = TweenInfo.new(SEGMENT_TIME, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut)

-- randomized per-magnet start point in the idle cycle — same "roll a
-- random phase once at script start" approach RadiantBombFuse's own
-- hueOffset uses, so multiple radiant magnets on the board don't all
-- flip between colors in lockstep. This is a random point in *time*
-- across the whole CYCLE_TIME (not just a random starting index), so
-- both which color a magnet starts on AND how far into that color's
-- segment it starts are randomized — see idleColorLoop below.
local idleStartOffset = math.random() * CYCLE_TIME

-- ── config: pull telegraph — same shape/sizing as MagnetFuse's own
-- warning sphere (still the only warning before the pull starts), just
-- recolored rainbow instead of staying flat yellow — see pullTelegraph ──
local TELEGRAPH_RADIUS_PER_SIZE = 3
local TELEGRAPH_TIME = 2

-- ── config: pull + orbit — tripled strength, tripled duration, per the
-- design notes ──
local PULL_ACCEL = 30      -- 3x MagnetFuse's own PULL_ACCEL (10) — "tripled strength"
local PULL_DURATION = 6    -- 3x MagnetFuse's own SHRINK_TIME (2) — "lasts for 3x as long"; also this magnet's own self-destruct clock, same role SHRINK_TIME plays for a plain magnet
local ORBIT_START_SPEED = 0.5 -- rad/s the orbit's speed curve is aimed at for elapsed == 0 — no longer what it actually starts moving at, see ORBIT_EASE_TIME below
local ORBIT_ACCEL = 0.5       -- rad/s^2 — the orbit's angular speed ramps up linearly with elapsed pull time, per "speeding up its orbit over time"
local ORBIT_EASE_TIME = 1.5   -- seconds to ease angular speed in from a standstill, instead of snapping straight to ORBIT_START_SPEED the instant pulling begins — smooths out the sudden direction/velocity change a caught ball otherwise felt right as the orbit kicked in
local ORBIT_EASE_STYLE = Enum.EasingStyle.Sine

-- ── config: spawn cue — same asset MagnetFuse's own SPAWN_SND uses ──
local SPAWN_SND, SPAWN_VOL, SPAWN_PITCH = "rbxassetid://12221842", 0.2, 4

-- ── config: pull-start cue + shine — same ACTIVE_SND asset MagnetFuse
-- uses for the cue itself; the shine's shape (entrance/osc/exit,
-- FLASH_IMAGE) copies RadiantBombFuse's own pull shine, recolored via
-- pullRainbow() instead of that script's own hueFromClock helper being
-- reused directly (this script stays self-contained, same as every
-- other radiant fuse) — except it opens with a brief pure-white pop
-- (SHINE_WHITE_TIME) before the rainbow cycle takes over, mirroring the
-- very start of a normal magnet's own white->yellow->flicker shine ──
local ACTIVE_SND, ACTIVE_VOL, ACTIVE_PITCH = "rbxassetid://117163159149291", 1, 1
local FLASH_IMAGE = "rbxassetid://131187911056182"
local SHINE_SCALE = 1
local SHINE_OSC_MIN, SHINE_OSC_MAX = 0.9, 1.1
local SHINE_OSC_HZ = 8
local SHINE_ENTRANCE_START, SHINE_ENTRANCE_TIME = 3, 0.5
local SHINE_ENTRANCE_STYLE = Enum.EasingStyle.Quad
local SHINE_EXIT_TIME = 0.5
local SHINE_EXIT_STYLE = Enum.EasingStyle.Quad
local SHINE_WHITE_TIME = 0.15 -- brief pure-white pop before pullRainbow() takes over, per the design notes ("with the white color to start like normal magnets")

-- rainbow cycle backing the pull shine — same shape as RadiantBombFuse's
-- own PULL_HUE_CYCLE_TIME/hueOffset, duplicated here rather than shared
local PULL_HUE_CYCLE_TIME = 3
local RAINBOW_S, RAINBOW_V = 1, 1
local hueOffset = math.random()
local function pullRainbow()
	return Color3.fromHSV((os.clock() / PULL_HUE_CYCLE_TIME + hueOffset) % 1, RAINBOW_S, RAINBOW_V)
end

local se = Rep:WaitForChild("SoundEvents")

-- Keep the pull-start cue local to this magnet — same fix as MagnetFuse's
-- own pullSound (see its comment for the full reasoning): created and
-- primed now, well before pulling starts, so the actual pull-start moment
-- just restarts this existing instance instead of a SoundEvents round-trip
-- building a fresh one on demand. Parented straight to the magnet and left
-- there (no anchor needed) since the magnet stays alive for the whole
-- PULL_DURATION pull afterward, well past ACTIVE_SND's own length.
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

-- ── grow-in: identical shape to MagnetFuse's own — targetSize captured
-- once here and reused everywhere below instead of ever reading
-- magnet.Size.X live ──
local GROW_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local targetSize = magnet:GetAttribute("TargetSize") or magnet.Size.X
if magnet.Size.X < targetSize then
	TS:Create(magnet, GROW_TWEEN, { Size = Vector3.new(targetSize, targetSize, targetSize) }):Play()
end

-- computed once targetSize is known — see riseYForSize/wanderRadiusForSize's own comment above
local RISE_Y = riseYForSize(targetSize)
local WANDER_RADIUS = wanderRadiusForSize(targetSize)

-- ── spawn cue: fired once, right as the magnet first appears — same
-- "positional" reasoning as MagnetFuse's own (fires before the magnet is
-- guaranteed to have replicated to every client yet) ──
se:FireAllClients("positional", magnet.Position, SPAWN_SND, SPAWN_VOL, SPAWN_PITCH)

-- ── idle color loop: literally RadiantFuse's own loop shape, stopped
-- once the magnet is gone, sold, OR starts pulling (unlike a plain
-- radiant ball, which only ever stops on the first two) ──
local function idleStillLive()
	return magnet.Parent ~= nil and not magnet:GetAttribute("PendingSell") and not magnet:GetAttribute("Pulling")
end

local idleColorTween -- current in-flight segment tween, cancelled the instant pulling starts rather than left to finish its own SEGMENT_TIME

-- resolve idleStartOffset into "which segment" + "how far into it" so
-- this magnet's very first frame already shows the color it would have
-- reached had its cycle actually been running since -idleStartOffset
-- seconds ago, instead of every magnet visibly starting from the same
-- red-at-idx-1 pose before drifting apart
local startIdx = math.floor(idleStartOffset / SEGMENT_TIME) + 1
local startFrac = (idleStartOffset % SEGMENT_TIME) / SEGMENT_TIME
local startNextIdx = (startIdx % #COLORS) + 1
magnet.Color = COLORS[startIdx]:Lerp(COLORS[startNextIdx], startFrac)

task.spawn(function()
	if not idleStillLive() then return end

	-- finish out the partial segment this magnet happened to be "born"
	-- into, then fall into the normal full-SEGMENT_TIME loop below
	local remaining = SEGMENT_TIME * (1 - startFrac)
	idleColorTween = TS:Create(magnet, TweenInfo.new(remaining, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut), { Color = COLORS[startNextIdx] })
	idleColorTween:Play()
	task.wait(remaining)

	local idx = startNextIdx
	while idleStillLive() do
		idx = (idx % #COLORS) + 1
		idleColorTween = TS:Create(magnet, segmentInfo, { Color = COLORS[idx] })
		idleColorTween:Play()
		task.wait(SEGMENT_TIME)
	end
end)

-- ── pull telegraph — same shape as MagnetFuse's own pullTelegraph (see
-- its header for the full reasoning: welded to the magnet instead of the
-- wander target since the magnet is still mid-travel throughout), except
-- recolored to track the magnet's own live Color for as long as it's up
-- instead of holding flat on MagnetFuse's own fixed yellow — the magnet
-- is still idle-cycling (see idleStartOffset above) throughout the whole
-- telegraph, so the telegraph reads as glued to it rather than running
-- an independent rainbow that could drift out of phase ──
local function pullTelegraph(size)
	local startRadius = size * TELEGRAPH_RADIUS_PER_SIZE

	local ball = Instance.new("Part")
	ball.Shape, ball.Anchored, ball.CanCollide, ball.CanQuery = Enum.PartType.Ball, false, false, false
	ball.Material, ball.Color = Enum.Material.Neon, magnet.Color
	ball.Transparency = 1
	ball.Size, ball.Position, ball.Parent = Vector3.new(startRadius, startRadius, startRadius), magnet.Position, WS

	local weld = Instance.new("WeldConstraint")
	weld.Part0, weld.Part1 = magnet, ball
	weld.Parent = ball

	-- keeps ball.Color locked to the magnet's own (still-idle-cycling)
	-- Color every frame, instead of independently sampling pullRainbow()
	-- — the magnet hasn't started pulling yet while the telegraph is up,
	-- so its idle loop (see above) is still what's actually driving its
	-- color, and the telegraph should read as glued to it rather than
	-- running its own out-of-phase rainbow. Stopped alongside the ball
	-- itself below rather than left to tick on a destroyed part.
	local hueConn = RS.Heartbeat:Connect(function()
		ball.Color = magnet.Color
	end)

	local magnetGoneConn
	magnetGoneConn = magnet.Destroying:Connect(function()
		hueConn:Disconnect()
		if ball.Parent then ball:Destroy() end
	end)

	local shrink = TS:Create(ball,
		TweenInfo.new(TELEGRAPH_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.In),
		{ Size = Vector3.new(size, size, size) })
	local fadeIn = TS:Create(ball,
		TweenInfo.new(TELEGRAPH_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.In),
		{ Transparency = 0 })

	local pendingSellConn
	shrink.Completed:Connect(function()
		hueConn:Disconnect()
		magnetGoneConn:Disconnect()
		if pendingSellConn then pendingSellConn:Disconnect() end
		if ball.Parent then ball:Destroy() end
	end)

	pendingSellConn = magnet:GetAttributeChangedSignal("PendingSell"):Connect(function()
		if magnet:GetAttribute("PendingSell") then
			shrink:Cancel()
			fadeIn:Cancel()
		end
	end)

	shrink:Play()
	fadeIn:Play()
	task.wait(TELEGRAPH_TIME)
end

-- ── travel — identical shape to MagnetFuse's own: rise + wander
-- recombined every Heartbeat into an AlignPosition target. `angle` is
-- kept as a local past this section (unlike MagnetFuse, which has no
-- further use for it) since the pull + orbit loop below reuses it as
-- the orbit's own starting angle, so the orbit picks up exactly where
-- the wander left off instead of snapping to a new position ──
magnet.Anchored = false
pcall(function() magnet:SetNetworkOwner(nil) end)

local moveAttachment = Instance.new("Attachment")
moveAttachment.Parent = magnet

local aligner = Instance.new("AlignPosition")
aligner.Attachment0 = moveAttachment
aligner.Mode = Enum.PositionAlignmentMode.OneAttachment
aligner.RigidityEnabled = true
aligner.Position = magnet.Position
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

task.delay(WANDER_START_DELAY + WANDER_TIME - TELEGRAPH_TIME, function()
	if magnet.Parent and not magnet:GetAttribute("PendingSell") then
		pullTelegraph(targetSize)
	end
end)

wanderTween.Completed:Wait()
travelConn:Disconnect()
riseDriver:Destroy()
wanderDriver:Destroy()
-- aligner itself is left alone for now (not destroyed) — its target simply
-- stops updating, so it holds the magnet exactly here, same as a plain
-- magnet would for the rest of its life. If pulling actually begins below,
-- the aligner is retired for good in favor of a direct, anchored Position
-- write for the orbit — see the Anchored/aligner:Destroy() switch just
-- below.

if not magnet.Parent or magnet:GetAttribute("PendingSell") then return end

-- flips the instant pulling actually begins — SellHandler/SellClient key
-- off this exactly like they do for a plain magnet
magnet:SetAttribute("Pulling", true)
if idleColorTween then idleColorTween:Cancel() end -- don't let an in-flight idle segment keep playing out once nothing's visible to show it

-- The orbit that starts below is a pure scripted motion (a fixed circle at
-- a fixed height) with nothing physical driving it — no collision on the
-- magnet, nothing pushes back on it, nothing needs velocity or gravity to
-- look right. Handing that off to a physics constraint (AlignPosition) and
-- then also fighting it with direct Position writes, like a first pass at
-- this fix tried, is two systems disagreeing about who owns the part's
-- position every frame — that's what was producing the wobble, and then
-- the extra jitter on top of it. Simplest and cleanest is to remove the
-- physics from the equation entirely: anchor the magnet and just set its
-- Position straight from the orbit formula every Heartbeat (see the pull +
-- orbit loop below) — deterministic, nothing to fight, Y is a literal
-- constant (RISE_Y) in that formula so it physically cannot drift.
magnet.Anchored = true
aligner:Destroy()
moveAttachment:Destroy()

-- ── pull-start cue ──
-- pullSound was created and primed back at spawn (see above), so this is
-- just restarting an existing, already-loaded instance.
pullSound:Play()

magnet.Transparency = 1

for _, child in ipairs(magnet:GetChildren()) do
	if child:IsA("BillboardGui") and child.Name:lower() == "display" then
		child:Destroy()
		break
	end
end

-- ── pull shine — RadiantBombFuse's own pullShine shape (entrance pop,
-- oscillation, exit shrink), recolored via pullRainbow() instead of
-- that script's hue helper, and opening with SHINE_WHITE_TIME seconds
-- of pure white before the rainbow cycle takes over (see its own
-- comment above) ──
local function pullShine(startSize)
	local gui = Instance.new("BillboardGui")
	gui.Adornee, gui.AlwaysOnTop, gui.Parent = magnet, true, magnet
	local baseSize = SHINE_SCALE * startSize
	gui.Size = UDim2.new(baseSize * SHINE_ENTRANCE_START * SHINE_OSC_MIN, 0, baseSize * SHINE_ENTRANCE_START * SHINE_OSC_MIN, 0)

	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency, img.BorderSizePixel = 1, 0
	img.Size, img.Image = UDim2.new(1, 0, 1, 0), FLASH_IMAGE
	img.ImageColor3, img.ImageTransparency = Color3.new(1, 1, 1), 0 -- starts white — the Heartbeat loop below switches to the rainbow cycle after SHINE_WHITE_TIME
	img.ScaleType, img.Parent = Enum.ScaleType.Fit, gui
	img.ZIndex = 10
	img:SetAttribute("GreyOnCollapse", true)

	local entranceDriver = Instance.new("NumberValue")
	entranceDriver.Value = SHINE_ENTRANCE_START
	local entranceTween = TS:Create(entranceDriver,
		TweenInfo.new(SHINE_ENTRANCE_TIME, SHINE_ENTRANCE_STYLE, Enum.EasingDirection.Out),
		{ Value = 1 })
	entranceTween:Play()

	local oscDriver = Instance.new("NumberValue")
	oscDriver.Value = SHINE_OSC_MIN
	local oscTween = TS:Create(oscDriver,
		TweenInfo.new(1 / (SHINE_OSC_HZ * 2), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Value = SHINE_OSC_MAX })
	oscTween:Play()

	return gui, img, entranceDriver, oscDriver
end
local startSize = targetSize
local shineGui, shineImg, shineEntranceDriver, shineOscDriver = pullShine(startSize)

-- ── pull + orbit loop — runs for PULL_DURATION (3x a plain magnet's
-- SHRINK_TIME), pulling EVERY object in the balls folder (not just
-- ballT.Name) at this script's own PULL_ACCEL (3x a plain magnet's own
-- PULL_ACCEL), while sweeping the (now anchored) magnet's own Position
-- around WANDER_RADIUS at a steadily increasing angular speed instead of
-- holding it still — see the Anchored/aligner:Destroy() switch above for
-- why this writes Position directly rather than driving a constraint ──
local elapsed = 0
local orbitAngle = 0 -- accumulated sweep past the wander's own landing angle — see angle above
local hbConn
hbConn = RS.Heartbeat:Connect(function(dt)
	if not magnet.Parent or magnet:GetAttribute("PendingSell") then
		hbConn:Disconnect()
		return
	end

	elapsed = math.min(elapsed + dt, PULL_DURATION)

	-- angular speed ramps up linearly with elapsed pull time — "speeding
	-- up its orbit over time" — integrated into orbitAngle every frame.
	-- For the first ORBIT_EASE_TIME seconds that linear curve is itself
	-- eased in from 0 (see ORBIT_EASE_TIME above) rather than the orbit
	-- starting flat-out at ORBIT_START_SPEED the instant pulling begins.
	local angularSpeed = ORBIT_START_SPEED + ORBIT_ACCEL * elapsed
	if elapsed < ORBIT_EASE_TIME then
		angularSpeed *= TS:GetValue(elapsed / ORBIT_EASE_TIME, ORBIT_EASE_STYLE, Enum.EasingDirection.Out)
	end
	orbitAngle += angularSpeed * dt
	local currentAngle = angle + orbitAngle
	-- pure parametric circle, RISE_Y is a literal constant here — nothing
	-- to drift, no physics involved
	magnet.Position = Vector3.new(math.cos(currentAngle) * WANDER_RADIUS, RISE_Y, math.sin(currentAngle) * WANDER_RADIUS)

	-- size still eases to 0 over PULL_DURATION, same role it plays for a
	-- plain magnet: invisible either way, but this is what scales the
	-- pull strength below down to nothing right as the magnet vanishes
	local size = startSize * (1 - elapsed / PULL_DURATION)
	magnet.Size = Vector3.new(size, size, size)

	-- white pop, then the rainbow cycle takes over for the rest of the pull
	shineImg.ImageColor3 = (elapsed < SHINE_WHITE_TIME) and Color3.new(1, 1, 1) or pullRainbow()

	local timeLeft = PULL_DURATION - elapsed
	local exitMult = 1
	if timeLeft <= SHINE_EXIT_TIME then
		local exitFrac = 1 - timeLeft / SHINE_EXIT_TIME
		exitMult = 1 - TS:GetValue(exitFrac, SHINE_EXIT_STYLE, Enum.EasingDirection.In)
	end
	local shineMult = shineEntranceDriver.Value * shineOscDriver.Value * exitMult
	local shineSize = SHINE_SCALE * startSize * shineMult
	shineGui.Size = UDim2.new(shineSize, 0, shineSize, 0)

	if elapsed >= PULL_DURATION then
		hbConn:Disconnect()
		shineEntranceDriver:Destroy()
		shineOscDriver:Destroy()
		magnet:Destroy() -- also tears down the shine (parented to it) and this script — the aligner/attachment were already destroyed when the orbit took over, see above
		return
	end

	-- pulls EVERY object in the shared folder toward the magnet's
	-- current (orbiting) position — regular balls AND every special
	-- alike, per "pulls ALL balls (including special ones)" — no
	-- distance falloff, same uniform-regardless-of-distance shape a
	-- plain magnet's pull uses. Only this magnet itself and anything
	-- currently Held are excluded.
	local pos = magnet.Position
	for _, obj in ipairs(ballsFolder:GetChildren()) do
		if obj ~= magnet and obj:IsA("BasePart") and not obj:GetAttribute("Held") then
			local toMagnet = pos - obj.Position
			local dist = toMagnet.Magnitude
			if dist > 0.01 then
				obj.AssemblyLinearVelocity += (toMagnet / dist) * PULL_ACCEL * size * dt
			end
		end
	end
end)