--[[
    StashData (ModuleScript)
    Path: ReplicatedStorage
    Parent: ReplicatedStorage
    Exported: 2026-09-20 20:00:09
]]
--[[
	StashData (ModuleScript) — place directly in ReplicatedStorage
	(ReplicatedStorage.StashData), a SIBLING of UpgradeData.

	Single source of truth for everything about the stash upgrade that
	both sides have to agree on: which ball kinds can be stashed at all,
	what each one looks like as a ballPreview in the toolbar, and every
	timing the preview's intro/idle/collapse-wipe animations run on.

	Required by StashHandler (server — what's absorbable, what label goes
	in the chat line), StashClient (client — everything below), and
	LeaderboardSetup (server — sanitizing a loaded save's stash entries
	against the kind list). Exists specifically so those three don't each
	grow their own copy of an asset id or a kind name; this project
	already carries enough "MUST be kept in sync by hand" comments
	(LeaderboardSetup's DEFAULT_PET_*, SellClient's sell multipliers),
	and the stash shouldn't add five more.

	Deliberately NOT in UpgradeData, even though the stash entry lives
	there: UpgradeData is the shop's list — id, price, description lines
	— and every consumer of it (ShopHandler, ShopClient, GrabHandler,
	LeaderboardSetup) walks the whole array. Preview asset ids and tween
	durations have nothing to do with buying anything, so they live in
	their own module rather than bloating an entry that the shop is the
	only thing that actually reads.

	KIND SPEC SHAPE

	Each entry in KINDS below is keyed by the same kind name BallManager
	uses in its own KIND_TEMPLATES/KIND_FUSENAME tables ("ball", "bomb",
	"magnet", "splitter", "merger") — that's what gets stored in a slot
	and handed straight back to _G.SpawnStashResult on deploy, so there's
	no translation layer between what's stashed and what BallManager
	knows how to spawn.

	  template  — the ReplicatedStorage child this kind clones from.
	              Resolved to a live Instance at require time below so
	              kindFromInstance matches on the template's ACTUAL Name
	              rather than on a literal here that could drift if the
	              template is ever renamed in Studio.
	  label     — how it reads in the "stashed a size N <label>" chat
	              line (see SellService.stashAbsorb).
	  image     — ballImage's Image.
	  imageTransparency — what ImageTransparency settles at once the
	              intro fade finishes (the intro itself always starts at
	              1 — see INTRO_* below).
	  displayMode — what ballDisplay, the TextLabel sitting over the
	              image, says for this kind:
	                "size" — the size the stashed object went in at, as
	                         stored in the slot (regular balls, plain and
	                         radiant alike)
	                "text" — displayText, verbatim and unchanging
	                         (every other kind)
	  displayText — the literal string "text" mode shows. Free-form, and
	              per-SPEC rather than per-kind, so a radiant variant can
	              read differently from its plain counterpart if it ever
	              needs to.
	  colorMode — what drives ballImage's BackgroundColor3 once the
	              intro is done:
	                "ball"    — the absorbed ball's own stored color,
	                            static (regular balls only)
	                "static"  — staticColor, forever
	                "flicker" — snaps between colorA/colorB every
	                            `interval` seconds, no tween (bomb)
	                "fade"    — tweens between colorA/colorB over
	                            `interval` seconds each way (magnet)
	                "sequence" — walks `colors` end to end, linear, one
	                            full pass per `cycleTime` (every radiant
	                            kind but the bomb)
	                "rainbowFlicker" — flickers against `offColor` at
	                            `interval`, and while LIT spins the hue
	                            continuously, one full wheel per
	                            `hueCycleTime` seconds OF LIT TIME. Dark
	                            ticks freeze the hue where it was rather
	                            than advancing past it, so each flash
	                            picks up exactly where the last left off
	                            (radiant bomb)
	  gradient  — the name of the UIGradient under ballImage to enable
	              for this kind, or nil to leave both disabled. Both
	              gradients ship Disabled on the template; StashClient
	              enables exactly the one named here and explicitly
	              disables the other, so a recycled preview frame can
	              never come up wearing the previous kind's gradient.

	A MIMIC IS DELIBERATELY ABSENT from this table — that's the entire
	mechanism by which mimics (board AND pet, both named after the same
	Mimic template) are unstashable: kindFromInstance returns nil for
	anything with no entry here, and both StashHandler and StashClient
	reject a nil kind up front. There is no separate "can't stash this"
	list to keep in sync with this one.

	Radiant works differently again: it's an ATTRIBUTE on an otherwise
	ordinary object of one of those kinds, not a kind of its own, so it
	can't be represented in KINDS at all — a radiant bomb and a plain one
	are both kind "bomb". Every kind is stashable radiant, and each has
	an entry in RADIANT_KINDS below that overrides only what its own
	Radiant<Kind>Fuse changes. specFor is the single place the two are
	resolved together.
]]

local Rep = game:GetService("ReplicatedStorage")

-- only for CG.RadiantPull, which captureSize below uses to recognise a
-- radiant bomb whose live Size has gone cosmetic. Requiring it here
-- rather than in each caller is what lets StashHandler and StashClient
-- share one copy of that rule instead of keeping two in sync.
local CG = require(Rep:WaitForChild("CollisionGroups"))

local StashData = {}

-- ── slots ───────────────────────────────────────────────────────────
-- MAX_SLOTS is the ceiling, not what any given player has: how many
-- slots are actually usable is their stash TIER (see UpgradeData's
-- stash entry — tier 1 = slot 1 only, tier 3 = all three). The slot
-- folders themselves always exist for everyone regardless, same
-- "always created, defaults if nothing was saved" reasoning
-- LeaderboardSetup already applies to PetMimicConfig.
StashData.MAX_SLOTS = 3

StashData.UPGRADE_ID = "stash"
StashData.TIER_VALUE_NAME = "stashTier" -- IntValue under the player's Upgrades folder — ShopHandler's own id.."Tier" convention, nothing special
StashData.FOLDER_NAME = "Stash"         -- Folder under the Player itself, created/persisted by LeaderboardSetup

-- toolbar instances, by name, under PlayerGui.toolbar.toolbarContainer.
-- These are authored in Studio and start hidden; StashClient reveals
-- them as tiers are bought. Indices in SLOT_BUTTONS line up 1:1 with
-- slot numbers, so SLOT_BUTTONS[2] is the button for slot 2.
StashData.DIVIDER_BUTTON = "4.divider"
StashData.SLOT_BUTTONS = { "5.slot1", "6.slot2", "7.slot3" }

StashData.PREVIEW_TEMPLATE = "ballPreview" -- ReplicatedStorage child cloned into a slot button

-- ── preview intro (see StashClient's playIntro) ─────────────────────
-- Fixed, deliberate sequence, identical for every kind: a preview pops
-- in pure white with its image invisible, snaps to cyan a beat later,
-- then eases into whatever that kind actually looks like. The snap is
-- an instant assignment, NOT a tween — the hard cut is the point.
StashData.INTRO_START_COLOR = Color3.fromRGB(255, 255, 255)
StashData.INTRO_SNAP_COLOR = Color3.fromRGB(0, 255, 255)
StashData.INTRO_SNAP_DELAY = 0.05  -- seconds spent on INTRO_START_COLOR before snapping to INTRO_SNAP_COLOR
StashData.INTRO_FADE_TIME = 0.125  -- seconds the snap color takes to ease into the kind's real color/image transparency; a kind's color loop only starts once this has fully finished

-- ── preview texture scroll (see StashClient's startTextureScroll) ───
-- ballImage drifts leftward for as long as the preview exists,
-- independent of kind and independent of everything the intro and the
-- color loops are doing — those own BackgroundColor3 and
-- ImageTransparency, the scroll owns Position and nothing else.
--
-- One pass is the image travelling from a full width right of the group
-- (Position X scale 1) to a full width left of it (scale -1), then
-- starting over — so this is the period of the whole loop rather than a
-- speed, and that loop covers two group widths. Expressed in SCALE
-- rather than pixels, which is what makes it resolution independent: a
-- slot is a different pixel size on every screen, but one width is one
-- width everywhere.
StashData.SCROLL_LOOP_SECONDS = 5 -- two group widths per pass; slow enough to read as texture, not as animation

-- ── collapse wipe (see StashClient's stashCollapse handler and
-- StashHandler's _G.StashCollapseWipe) ──────────────────────────────
-- A collapse takes the stash with it, one slot at a time, left to
-- right. Each preview fades its image out and its background to
-- magenta — the same COLLAPSE_FLASH_COLOR/telegraph magenta the board
-- itself wipes in (see SellService's COLLAPSE_FLASH_COLOR and
-- BallManager's COLLAPSE_TELEGRAPH_TINT_COLOR) — then shrinks to
-- nothing on an Exponential/In curve, so it reads as being sucked out
-- rather than simply hidden.
StashData.WIPE_SLOT_GAP = 0.15    -- delay between slot N and slot N+1 starting their own wipe
StashData.WIPE_FADE_TIME = 0.1   -- image -> transparent / background -> WIPE_COLOR
StashData.WIPE_SHRINK_TIME = 0.125 -- preview frame -> zero size, Exponential/In
StashData.WIPE_COLOR = Color3.fromRGB(255, 0, 255)

-- total wall-clock length of the whole left-to-right wipe. StashHandler
-- waits this out before actually clearing the slot values server-side,
-- so the client is animating previews whose backing data is still there
-- rather than racing a clear that would yank them mid-fade.
function StashData.wipeDuration()
	return (StashData.MAX_SLOTS - 1) * StashData.WIPE_SLOT_GAP
		+ StashData.WIPE_FADE_TIME
		+ StashData.WIPE_SHRINK_TIME
end

-- ── kinds ───────────────────────────────────────────────────────────
StashData.KINDS = {
	ball = {
		template = "Ball",
		label = "ball",
		image = "rbxassetid://140588480958441",
		imageTransparency = 0.5,
		-- the one kind whose preview color isn't fixed here: it's
		-- whatever color the absorbed ball happened to be, stored in the
		-- slot's own Color3Value and handed back through
		-- introColor/idleColor below
		colorMode = "ball",
		-- and the only kind whose LABEL isn't fixed here either, for the
		-- same reason: one stashed ball differs from another only by the
		-- size it went in at, so that's what its slot says (see displayFor)
		displayMode = "size",
	},
	bomb = {
		template = "Bomb",
		label = "bomb",
		image = "rbxassetid://81446779718854",
		imageTransparency = 0,
		colorMode = "flicker",
		colorA = Color3.fromRGB(255, 0, 0),
		colorB = Color3.fromRGB(27, 41, 53),
		interval = 0.5,
		displayMode = "text",
		displayText = "!!",
	},
	magnet = {
		template = "Magnet",
		label = "magnet",
		image = "rbxassetid://81446779718854",
		imageTransparency = 0,
		colorMode = "fade",
		colorA = Color3.fromRGB(255, 0, 0),
		colorB = Color3.fromRGB(0, 0, 255),
		interval = 1,
		displayMode = "text",
		displayText = "><",
	},
	splitter = {
		template = "Splitter",
		label = "splitter",
		image = "rbxassetid://103590650370264",
		imageTransparency = 0,
		colorMode = "static",
		staticColor = Color3.fromRGB(255, 255, 255),
		gradient = "splitterGradient",
		displayMode = "text",
		displayText = "//",
	},
	merger = {
		template = "Merger",
		label = "merger",
		image = "rbxassetid://103590650370264",
		imageTransparency = 0,
		colorMode = "static",
		staticColor = Color3.fromRGB(255, 255, 255),
		gradient = "mergerGradient",
		displayMode = "text",
		displayText = "++",
	},
}

-- ── radiant ─────────────────────────────────────────────────────────
-- Radiant is an OVERLAY on an ordinary ball (an IsRadiant attribute, not
-- its own template — see kindFromInstance below), so it can't be an
-- entry in KINDS: a radiant ball and a plain one are both kind "ball".
-- It gets an override spec instead, swapped in by specFor when a slot is
-- flagged radiant.
--
-- Identical to the ball spec except for the color, which cycles forever
-- rather than sitting on the absorbed ball's own color. That matters
-- more than it looks: a radiant ball sells for RADIANT_SELL_MULTIPLIER
-- times a plain one (see SellService), so two slots that look the same
-- can be worth wildly different amounts, and the cycling is the only
-- thing telling them apart at a glance.
--
-- RADIANT_COLORS and RADIANT_CYCLE_TIME below MUST be kept in sync by
-- hand with RadiantFuse's own COLORS/CYCLE_TIME — the preview is
-- supposed to be the same loop the ball itself is running out on the
-- board, and a preview drifting to its own rhythm would read as a
-- different kind of thing entirely. Same hand-kept-duplicate convention
-- the rest of this project already runs on (SellClient's sell
-- multipliers, LeaderboardSetup's DEFAULT_PET_*), and for the same
-- reason: RadiantFuse is a plain Script inside a template, so nothing
-- can require() the values out of it.
--
-- Six stops rather than a continuous hue sweep, and that's load-bearing:
-- each adjacent pair differs in exactly ONE channel (red -> yellow is
-- green rising, yellow -> green is red falling, and so on), so tweening
-- straight through RGB stays fully saturated the whole way round. A
-- naive tween between two opposite colors would cut across the middle of
-- the color space and wash out through grey instead.
--
-- EVERY kind has one of these, not just the ball — a radiant bomb,
-- magnet, splitter and merger are all stashable, and each one's preview
-- reproduces the loop its own Radiant<Kind>Fuse runs out on the board.
StashData.RADIANT_COLORS = {
	Color3.fromRGB(255, 0, 0),
	Color3.fromRGB(255, 255, 0),
	Color3.fromRGB(0, 255, 0),
	Color3.fromRGB(0, 255, 255),
	Color3.fromRGB(0, 0, 255),
	Color3.fromRGB(255, 0, 255),
}
StashData.RADIANT_CYCLE_TIME = 3 -- seconds for a full loop through every color above

-- the same six stops walked backwards, for the one kind that spins the
-- other way — see the splitter entry below. Built here rather than
-- written out a second time so the two can never drift apart.
StashData.RADIANT_COLORS_REVERSED = {}
for i = #StashData.RADIANT_COLORS, 1, -1 do
	table.insert(StashData.RADIANT_COLORS_REVERSED, StashData.RADIANT_COLORS[i])
end

-- MUST be kept in sync with RadiantBombFuse's FLASH_HUE_CYCLE_TIME.
-- Seconds of LIT time for the flash hue to travel the whole wheel — not
-- wall-clock seconds. That script accumulates elapsed time only on ticks
-- where the flash is actually on, so a bomb sitting dark half the time
-- takes 3 real seconds to go round once. The preview does the same, which
-- is the whole point: the two are driven by the same clock rule, so a
-- stashed bomb's swatch reads as the same object as the one on the board.
StashData.RADIANT_FLASH_HUE_CYCLE_TIME = 5

-- MUST be kept in sync with the Name RadiantBombFuse's startLift gives
-- its VectorForce.
--
-- This is how both StashHandler and StashClient tell a radiant bomb that
-- has actually ENTERED its halfway pull from one that is merely
-- telegraphing it. The distinction matters because those are two quite
-- different objects to a player: through the shrink the bomb is still an
-- ordinary part sitting on the platform under ordinary gravity, and
-- stashing it there is fair game; once the pull is live it's dragging
-- the whole board around and has to be waited out, exactly like a magnet
-- that's gone live.
--
-- The collision group is NOT that signal, though it reads like one.
-- triggerHalfwayPull moves the bomb into CG.RadiantPull before the
-- shrink even starts (the solver needs it out of contact with the other
-- balls while its collision shape is changing size), so the group goes
-- on at the telegraph and stays on for everything after it. The lift
-- force is built in startLift, which runs at the far end of that
-- shrink's own task.wait — the same instant the shine appears,
-- PULL_START_SND fires and the bomb goes invisible — and is destroyed
-- again by restorePullPhysics on every path that ends the pull early.
-- So its presence is exactly "the pull is live right now", with no edit
-- to that script and nothing new for it to maintain.
StashData.RADIANT_PULL_LIFT_FORCE = "RadiantPullLiftForce"

-- Per-kind radiant overrides. Each one is its plain counterpart with the
-- color swapped for whatever that kind's radiant fuse actually does:
--
--   ball      RadiantFuse — the six stops, forward, 3s.
--   magnet    RadiantMagnetFuse — literally RadiantFuse's own COLORS and
--             CYCLE_TIME, duplicated into that script (see its idle color
--             loop), so the preview is identical to the ball's.
--   merger    RadiantMergerFuse — a continuous forward hue spin at the
--             same 3s period. Rendered here as the six stops rather than
--             a true HSV sweep for the reason in the note above: the
--             stops keep it saturated, where tweening raw RGB across the
--             wheel washes out through grey.
--   splitter  RadiantSplitterFuse — the same spin BACKWARD (that script's
--             reversedRainbow negates the clock term), which is exactly
--             what the reversed stop list above produces. Keeps its
--             gradient on, since that plus the direction is what
--             separates a stashed splitter from a stashed merger at a
--             glance.
--   bomb      RadiantBombFuse — the odd one out, and the only kind here
--             that doesn't use the six stops. That script leaves the idle
--             tick on the plain bomb's flat navy and cycles only the
--             FLASH, so this flickers navy exactly like a plain bomb and
--             spins the hue on the lit tick. Crucially it spins on the
--             SAME clock rule that script uses: hue advances only while
--             the flash is on and freezes through every dark tick, so a
--             flash resumes the color the last one ended on instead of
--             jumping. That's why it borrows FLASH_HUE_CYCLE_TIME rather
--             than RADIANT_CYCLE_TIME — a preview flickering at a
--             readable 0.5s is lit half the time, so 1.5s of lit time
--             lands it back at a ~3s wheel anyway, matching the other
--             previews without having to special-case the number.
StashData.RADIANT_KINDS = {
	ball = {
		template = "Ball",
		label = "radiant ball", -- reads straight into the chat line: "stashed a size 12 radiant ball"
		image = "rbxassetid://140588480958441",
		imageTransparency = 0.5,
		colorMode = "sequence",
		colors = StashData.RADIANT_COLORS,
		-- NOT `interval` like the flicker/fade kinds, which measure one STEP:
		-- this is the whole loop, and StashClient divides it by the number of
		-- stops to get a segment, exactly as RadiantFuse does
		cycleTime = StashData.RADIANT_CYCLE_TIME,
		-- the size, same as a plain ball: radiance is already spelled out
		-- by the color loop, so the label doesn't have to spend itself
		-- saying it a second time
		displayMode = "size",
	},
	bomb = {
		template = "Bomb",
		label = "radiant bomb",
		image = "rbxassetid://81446779718854",
		imageTransparency = 0,
		colorMode = "rainbowFlicker",
		offColor = Color3.fromRGB(27, 41, 53),                  -- RadiantBombFuse's own OFF, same navy a plain bomb sits on
		interval = 0.5,                                         -- matches the plain bomb preview's flicker, so the two read as the same object
		hueCycleTime = StashData.RADIANT_FLASH_HUE_CYCLE_TIME,  -- of LIT time, not wall-clock — see that constant
		displayMode = "text",
		displayText = "!!",
	},
	magnet = {
		template = "Magnet",
		label = "radiant magnet",
		image = "rbxassetid://81446779718854",
		imageTransparency = 0,
		colorMode = "sequence",
		colors = StashData.RADIANT_COLORS,
		cycleTime = StashData.RADIANT_CYCLE_TIME,
		displayMode = "text",
		displayText = "><",
	},
	splitter = {
		template = "Splitter",
		label = "radiant splitter",
		image = "rbxassetid://103590650370264",
		imageTransparency = 0,
		colorMode = "sequence",
		colors = StashData.RADIANT_COLORS_REVERSED, -- backward, per RadiantSplitterFuse
		cycleTime = StashData.RADIANT_CYCLE_TIME,
		gradient = "splitterGradient",
		displayMode = "text",
		displayText = "//",
	},
	merger = {
		template = "Merger",
		label = "radiant merger",
		image = "rbxassetid://103590650370264",
		imageTransparency = 0,
		colorMode = "sequence",
		colors = StashData.RADIANT_COLORS, -- forward, per RadiantMergerFuse
		cycleTime = StashData.RADIANT_CYCLE_TIME,
		gradient = "mergerGradient",
		displayMode = "text",
		displayText = "++",
	},
}

-- The spec that actually drives a preview: the kind's own, unless this
-- slot is flagged radiant and that kind has an override above.
-- Everything that renders or describes a stashed ball goes through this
-- rather than indexing KINDS directly, so radiant is handled in one
-- place instead of at every call site. Falls back to the plain spec for
-- a kind with no override, so adding a stashable kind that has no
-- radiant variant needs no change here.
function StashData.specFor(kind, radiant)
	if radiant then
		return StashData.RADIANT_KINDS[kind] or StashData.KINDS[kind]
	end
	return StashData.KINDS[kind]
end

-- every gradient name any kind above uses, so StashClient can disable
-- the whole set and re-enable just the one it wants without hardcoding
-- a second list of them
StashData.GRADIENTS = { "splitterGradient", "mergerGradient" }

-- ── template Name -> kind ───────────────────────────────────────────
-- Resolved once, at require time, off the live templates rather than
-- from the `template` literals above — so this matches on whatever the
-- template is ACTUALLY called, exactly like BallManager comparing
-- against ballT.Name instead of the string "Ball". A missing template
-- warns and falls back to the literal rather than hanging: this module
-- is required from LeaderboardSetup's startup path, and a stash that
-- can't identify one kind shouldn't take player data loading down with
-- it.
local kindByTemplateName = {}
for kind, spec in pairs(StashData.KINDS) do
	local template = Rep:WaitForChild(spec.template, 10)
	if not template then
		warn(("[StashData] ReplicatedStorage.%s is missing — falling back to matching on the literal name"):format(spec.template))
	end
	kindByTemplateName[template and template.Name or spec.template] = kind
end

-- The kind name for a board object, or nil if it isn't something the
-- stash handles at all. nil covers both "not a ball at all" and,
-- importantly, a MIMIC — board or pet, both named after the Mimic
-- template, neither of which has an entry in KINDS (see this file's
-- header). Note this answers "what kind IS this", NOT "can this be
-- stashed right now" — Held/PendingSell/IsRadiant/Pulling are live
-- state, checked by StashHandler and StashClient at their own call
-- sites.
function StashData.kindFromInstance(obj)
	if typeof(obj) ~= "Instance" then
		return nil
	end
	return kindByTemplateName[obj.Name]
end

-- true if `kind` is a string this module actually knows about — used by
-- LeaderboardSetup to throw out a corrupted/hand-edited save entry
-- before it ever reaches a slot value
function StashData.isKind(kind)
	return typeof(kind) == "string" and StashData.KINDS[kind] ~= nil
end

-- The size to remember a board object at — live Size.X in almost every
-- case, NOT the TargetSize attribute. For a ball or bomb the two are the
-- same thing once settled (which is why StashHandler finalizes any
-- in-progress ascent or growth before calling this), but a
-- splitter/merger shrinks over its own lifetime while TargetSize keeps
-- reporting whatever it spawned at, so a worn-down splitter has to come
-- back out of the stash worn down rather than refreshed to full size.
--
-- The one exception is a radiant bomb partway through the shrink that
-- telegraphs its halfway pull, which is a stashable moment (see the
-- RADIANT_PULL_LIFT_FORCE note above). That shrink is explicitly
-- COSMETIC — RadiantBombFuse captures TargetSize before it starts and
-- keeps driving the pull strength, the blast radius and the flash off
-- that captured value all the way down — so the live Size during it
-- isn't a worn-down bomb, it's a full-size bomb wearing a shrinking
-- sphere. Reading it as a size would hand back a runt: the shrink is
-- Exponential/In toward 0.75 studs, so nearly all of the travel happens
-- in its last moments and a bomb stashed late would come back barely
-- bigger than a marble.
--
-- The collision group is what identifies that window, which is the job
-- it IS exact for: triggerHalfwayPull sets it at the top, before the
-- shrink starts, and restores it if the bomb leaves the pull. So
-- "radiant bomb in RadiantPull" means precisely "this bomb's live Size
-- is cosmetic", while the lift force means "the pull is live" — two
-- different questions, two different signals, and the reason the group
-- check didn't simply disappear when the gate moved off it.
--
-- Shared rather than duplicated because StashHandler stores what this
-- returns and StashClient measures its range pre-check against it: if
-- the two disagreed, the client would silently refuse stashes the server
-- would have allowed, in exactly this newly-reachable case.
function StashData.captureSize(ball)
	if ball:GetAttribute("IsRadiant") == true
		and StashData.kindFromInstance(ball) == "bomb"
		and ball.CollisionGroup == CG.RadiantPull
	then
		return ball:GetAttribute("TargetSize") or ball.Size.X
	end
	return ball.Size.X
end

-- What ballImage's BackgroundColor3 eases INTO at the end of the intro
-- fade. For a flicker/fade kind this is just whichever end of its own
-- two-color cycle it starts on, so the first loop step is a continuation
-- of the intro rather than a second, unrelated jump.
--
-- Takes the resolved SPEC rather than a kind name, since a radiant ball
-- and a plain one share a kind but not a spec — see specFor above.
function StashData.introColor(spec, ballColor)
	if not spec then
		return StashData.INTRO_START_COLOR
	end
	if spec.colorMode == "ball" then
		return ballColor or StashData.INTRO_START_COLOR
	elseif spec.colorMode == "static" then
		return spec.staticColor
	elseif spec.colorMode == "flicker" then
		return spec.colorB -- bomb lands on the off navy, then takes its first flash to red one interval later
	elseif spec.colorMode == "fade" then
		return spec.colorA -- magnet lands on red, then starts fading to blue
	elseif spec.colorMode == "sequence" then
		-- the first stop, matching RadiantFuse setting ball.Color = COLORS[1]
		-- before its own loop starts; the loop below picks up from here and
		-- heads for the second.
		return spec.colors[1]
	elseif spec.colorMode == "rainbowFlicker" then
		-- the OFF navy, landing a radiant bomb on the same dark tick a plain
		-- one lands on (see the flicker branch above) rather than on a lit
		-- flash. The loop below starts dark to match and takes the first
		-- flash one interval later, so the intro reads as the bomb settling
		-- into its resting state and then beginning to blink — not as a
		-- flash already in progress that the first tick abruptly cuts off.
		--
		-- There's no colorA/colorB to swap here the way there is on a plain
		-- bomb: the lit color isn't a constant, it's whatever the hue clock
		-- says at that instant, so the starting phase is set here and in
		-- StashClient's `lit` seed instead.
		return spec.offColor
	end
	return StashData.INTRO_START_COLOR
end

-- ── preview display text (see StashClient's buildPreview) ───────────
-- ballDisplay is a TextLabel inside ballPreview, over the top of
-- ballImage, and it's the one part of a preview that never animates: the
-- intro owns BackgroundColor3 and ImageTransparency, the scroll owns
-- Position, and this owns Text and nothing else. Written once when the
-- preview is built and then left alone for the life of the frame, so
-- unlike the color loops it needs no token of its own.
--
-- What it says is per-kind, and the split is deliberate. A regular ball
-- is the only thing in the stash whose previews are otherwise
-- interchangeable — every one of them carries the same image, and
-- radiance aside the same kind of color — so that's the one kind that
-- spends its label on the size that actually tells two of them apart.
-- Every other kind is already identified at a glance by its image,
-- gradient and color loop, so its label is free text and can say
-- whatever reads best in a slot that narrow.

-- Sizes are read off a live part (see captureSize), so what lands here
-- is a float: a ball settled at 12 is 12, but a value that has been
-- through a tween can sit a hair off one, and "11.999998" in a label
-- that small is unreadable. Whole numbers print bare; anything genuinely
-- fractional keeps a single decimal, which is enough to tell a worn-down
-- object from a fresh one without overflowing the label.
local function formatSize(size)
	if typeof(size) ~= "number" then
		return ""
	end

	local rounded = math.floor(size + 0.5)
	if math.abs(size - rounded) < 0.05 then
		return tostring(rounded)
	end
	return string.format("%.1f", size)
end

-- What ballDisplay reads for a stashed object. Takes the resolved SPEC
-- and the slot's stored size — the same shape introColor takes, and for
-- the same reason: a radiant ball and a plain one share a kind but not a
-- spec, and this is not the place to work out which is which.
--
-- Always returns a string, never nil, since StashClient writes the
-- result straight onto Text. A kind added later with no displayMode of
-- its own comes back empty rather than erroring — an unlabelled preview
-- is a missing nicety, not a broken slot.
function StashData.displayFor(spec, size)
	if not spec then
		return ""
	end

	if spec.displayMode == "size" then
		return formatSize(size)
	elseif spec.displayMode == "text" then
		return spec.displayText or ""
	end
	return ""
end

return StashData