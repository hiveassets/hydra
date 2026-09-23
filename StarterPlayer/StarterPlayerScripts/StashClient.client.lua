--[[
    StashClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-23 02:07:56
]]
--[[
    StashClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-22 18:28:59
]]
--[[
	StashClient (LocalScript) — StarterPlayerScripts

	Client side of the stash upgrade (see StashHandler for the server
	half, StashData for every asset id and timing below, and
	UpgradeData's tiered "stash" entry for what buying it costs).

	Two jobs, which barely touch each other:

	  1. INPUT. R stashes whatever the cursor is on; Q asks for the
	     rightmost stashed ball back, regardless of where the cursor is;
	     clicking a slot button deploys that specific slot. One key per
	     job — see the key handler for why that isn't decided by aim any
	     more.
	     All of them are pure requests — unlike SellClient, nothing here is
	     predicted locally. There's nothing worth predicting: the whole
	     visible result of an absorb is a server-owned pull-in animation
	     on a replicated part, and the preview that follows it comes
	     from replicated values, so a prediction would only ever be a
	     second copy of something already arriving on its own. The stash
	     checks below mirror StashHandler's exactly, purely to skip a
	     round trip that was going to be rejected.

	  2. THE TOOLBAR. Which slot buttons are visible (driven by the
	     player's stash tier) and what's drawn in them (driven by the
	     Stash folder on the Player itself, which LeaderboardSetup
	     creates and persists and StashHandler writes). Nothing here
	     ever asks the server what's stashed — it reads the folder,
	     which is how a preview survives a respawn and comes back on a
	     rejoin without a single remote call.

	PREVIEWS

	One clone of ReplicatedStorage's ballPreview per occupied slot,
	parented into that slot's button — whichever kind of GuiButton it's
	authored as; nothing here depends on that except the AFK dim, which
	checks the class first (see setSlotButtonsDisabled).

	ballPreview is a CanvasGroup, and it owns everything about the
	preview's SHAPE: the corner rounding, the stroke, the shadow, the
	aspect ratio, and the clipping that keeps its contents inside that
	shape. That matters to this script for one reason — it's what lets
	ballImage simply slide (see startTextureScroll) without any of the
	tiling, resizing or second-copy machinery that would otherwise be
	needed to crop it.

	ballDisplay, a TextLabel in that same template, is the one piece of
	a preview that never animates: its Text is written once at build
	time from StashData.displayFor and then left alone until the frame
	is destroyed. A regular ball — radiant or not — shows the size it
	went in at, which is the only thing separating one stashed ball from
	another; every other kind shows its own fixed string out of
	StashData. It's optional in a way ballImage isn't, too: a template
	with no such child just goes without text, since the image, gradient
	and color loop already say what the slot is holding.

	Everything about how the preview looks
	comes from StashData.KINDS — image, image transparency, which
	UIGradient to enable, and what drives its background color once it's
	settled in (a bomb flickers, a magnet fades, a splitter/merger sits
	on white under its gradient, a regular ball keeps the color of the
	ball that went in).

	Every preview plays the same intro regardless of kind: pure white
	with its image invisible, an instant snap to cyan a beat later, then
	an ease into whatever that kind actually is. A kind's own color loop
	only starts once that ease has fully finished, so the two never
	fight over BackgroundColor3.

	PREVIEW LIFETIME / TOKENS

	Every preview a slot has ever held shares one counter,
	previewToken[index], bumped on every build and every teardown. The
	intro's two chained task.delays and both color loops capture the
	token they were started under and bail the moment it stops matching.
	That's what stops a preview that was replaced mid-intro (absorb,
	deploy, absorb again, faster than 0.175s — trivially possible by
	spamming R and Q) from having its predecessor's delayed
	fade write a color onto its successor, or from leaving two loops
	both driving the same ImageLabel. Same problem, and the same
	generation-counter fix, as BallManager's collapseCountdownGeneration.
]]

-- Almost nothing in this file runs per-frame, unlike SellClient/GrabClient.
-- Aiming happens once per R press, previews are driven by tweens and
-- task.delay, and the toolbar reacts to Changed signals. The preview's
-- texture scroll is a looping tween for exactly that reason (see
-- startTextureScroll). RunService is here for the single exception: the
-- radiant bomb's continuously-spinning flash hue, which has no fixed set
-- of stops to hand to a tween (see the "rainbowFlicker" branch of
-- startColorLoop). That loop only exists while a radiant bomb is actually
-- sitting in a slot, and it disconnects itself the moment that preview goes.
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local TS = game:GetService("TweenService")
local RS = game:GetService("RunService")

local player = Players.LocalPlayer

local StashData = require(Rep:WaitForChild("StashData"))

-- The absorb animation lives on the board now. The orb is a part on
-- this machine, so pulling it in is local and instant rather than a
-- CFrame write per frame arriving from the server.
local ClientBoard = require(script.Parent:WaitForChild("ClientBoard"))

local stashRequest = Rep:WaitForChild("StashRequest")
local stashDeploy = Rep:WaitForChild("StashDeploy")
local stashCollapse = Rep:WaitForChild("StashCollapse")

local previewTemplate = Rep:WaitForChild(StashData.PREVIEW_TEMPLATE)

local bf = WS:WaitForChild("Balls")

-- same folders ShopClient/SellClient read ownership and state off —
-- LeaderboardSetup populates all of them on join before any client
-- script gets a chance to run (see ShopClient's header for the same
-- reasoning)
local upgrades = player:WaitForChild("Upgrades")
local stash = player:WaitForChild(StashData.FOLDER_NAME)

local toolbarContainer = player:WaitForChild("PlayerGui"):WaitForChild("toolbar"):WaitForChild("toolbarContainer")
local dividerButton = toolbarContainer:WaitForChild(StashData.DIVIDER_BUTTON)

local slotButtons = {}
for index, name in ipairs(StashData.SLOT_BUTTONS) do
	slotButtons[index] = toolbarContainer:WaitForChild(name)
end

-- ── config ──────────────────────────────────────────────────────────

-- studs from the player's own HumanoidRootPart to the ball — NOT the
-- camera. Kept a little under StashHandler's own STASH_RANGE so a
-- passing local check is never rejected server-side; exactly the
-- relationship (and the numbers) GrabClient has with GrabHandler,
-- since a stash reaches as far as a grab does.
local STASH_RANGE = 20

-- studs the cursor raycast itself is allowed to reach — aiming is
-- camera-based even though eligibility (STASH_RANGE) isn't, same split
-- GrabClient's own RAYCAST_DISTANCE describes
local RAYCAST_DISTANCE = 300

-- ── slot button visibility ──────────────────────────────────────────
-- The divider and all three slot buttons are authored in Studio inside
-- toolbarContainer and are simply hidden until they're owned; tier N
-- shows the divider plus slots 1..N. Hidden outright rather than greyed
-- out: a greyed slot reads as "you have this and it's unusable", which
-- isn't what an unbought tier is.

-- read fresh on every use rather than cached, same as ShopClient's own
-- currentTier: it's cheap, and nothing here runs per-frame. :IsA guard
-- is defensive, same reasoning as ShopClient/GrabClient's identical
-- checks — a save/load round trip that ever hands this back as the
-- wrong ClassName should read as tier 0 rather than erroring on .Value.
-- Clamped to MAX_SLOTS so a save written against more tiers than
-- currently exist can't address a slot button that was never authored.
local function currentTier()
	local tierValue = upgrades:FindFirstChild(StashData.TIER_VALUE_NAME)
	local tier = (tierValue and tierValue:IsA("IntValue")) and tierValue.Value or 0
	return math.clamp(tier, 0, StashData.MAX_SLOTS)
end

local function refreshSlotButtons()
	local tier = currentTier()

	dividerButton.Visible = tier > 0
	for index, button in ipairs(slotButtons) do
		button.Visible = index <= tier
	end
	return tier
end

-- AFKHandler owns the "AFK" attribute (see its header). Active = false
-- is what actually blocks the click (Roblox GuiButtons stop firing
-- MouseButton1Click once it's false, same as ShopClient/SellClient rely
-- on for their own toolbar buttons); everything below it is just the
-- visual tell, at the same 0.5 transparency those two use.
--
-- That tell is written through a class check rather than straight to one
-- property, because this script deliberately doesn't care which flavor of
-- GuiButton the slots are authored as in Studio: a TextButton has
-- TextTransparency and no ImageTransparency, an ImageButton the reverse,
-- and writing the one that doesn't exist is a hard ERROR, not a silent
-- no-op. Everything else this script does to these buttons (Visible,
-- Active, MouseButton1Click, parenting a preview into them) is plain
-- GuiButton/GuiObject surface that both classes share, so this is the
-- single spot that ever had to know the difference — and now it doesn't
-- break if they're ever re-authored as the other one.
-- Note this dims the BUTTON, not the ballPreview sitting inside an
-- occupied one — that's a separate instance and ignores its parent
-- button's transparency entirely. On slots authored as TextButtons with
-- no visible text of their own, that means a full slot looks the same
-- AFK as it does normally. Deliberately left that way rather than also
-- writing the preview's own ImageTransparency from here: the intro tween
-- owns that property (see playIntro), so a second writer would be one
-- more thing to keep in sync for what is purely a visual nicety — the
-- click is already blocked either way.
local function setSlotButtonsDisabled(disabled)
	local transparency = disabled and 0.5 or 0

	for _, button in ipairs(slotButtons) do
		button.Active = not disabled

		if button:IsA("ImageButton") then
			button.ImageTransparency = transparency
		elseif button:IsA("TextButton") then
			button.TextTransparency = transparency
		end
	end
end

-- ShopHandler CREATES the tier IntValue on the first purchase and then
-- mutates its .Value on every tier after that, so watching one or the
-- other alone would miss half the upgrades. ChildRemoved covers a data
-- wipe (see LeaderboardSetup's wipeUserData, which clears the whole
-- Upgrades folder).
local tierConnection
local function watchTierValue()
	if tierConnection then
		tierConnection:Disconnect()
		tierConnection = nil
	end
	local tierValue = upgrades:FindFirstChild(StashData.TIER_VALUE_NAME)
	if tierValue then
		tierConnection = tierValue.Changed:Connect(function()
			refreshSlotButtons()
		end)
	end
end

upgrades.ChildAdded:Connect(function(child)
	if child.Name == StashData.TIER_VALUE_NAME then
		watchTierValue()
		refreshSlotButtons()
	end
end)

upgrades.ChildRemoved:Connect(function(child)
	if child.Name == StashData.TIER_VALUE_NAME then
		watchTierValue()
		refreshSlotButtons()
	end
end)

watchTierValue()
refreshSlotButtons()
setSlotButtonsDisabled(player:GetAttribute("AFK") == true)

-- ── previews ────────────────────────────────────────────────────────

local activePreviews = {} -- [index] = { frame = Frame, image = ImageLabel, display = TextLabel or nil, scrollTween = Tween }
local previewToken = {}   -- [index] = generation counter; see the header
for index = 1, StashData.MAX_SLOTS do
	previewToken[index] = 0
end

local wiping = false -- true for the length of a collapse wipe; see the stashCollapse handler at the bottom

local function clearPreview(index)
	previewToken[index] += 1 -- invalidates any in-flight intro step or color loop for this slot
	local preview = activePreviews[index]
	if preview then
		-- the texture scroll repeats forever, so unlike every other tween
		-- here it has no natural end to wait for — cancel it explicitly
		-- rather than leave it looping against an instance on its way out
		if preview.scrollTween then
			preview.scrollTween:Cancel()
		end
		preview.frame:Destroy()
		activePreviews[index] = nil
	end
end

-- The preview's scrolling texture, and the whole of it: ballImage slides
-- from one full width right of the group (X scale 1) to one full width
-- left of it (X scale -1), then starts over. ballPreview being a
-- CanvasGroup is what makes that sufficient on its own — the group crops
-- whatever hangs outside it, to its own rounded shape, so the image can
-- simply travel without anything here tiling it, resizing it, cropping
-- it or cloning a second copy to cover the gap.
--
-- Note the pass covers TWO group widths, not one: the image is fully
-- off-frame at both ends, which is what lets it enter and leave cleanly
-- rather than popping at the edges. SCROLL_LOOP_SECONDS is the time for
-- that whole pass, so the on-screen speed is two widths per loop.
--
-- Linear easing because a texture scroll has to hold a constant speed;
-- anything with acceleration reads as the preview lurching. RepeatCount
-- -1 loops it forever, with Reverses left false so each pass restarts
-- from the right rather than sliding back the way it came.
--
-- Returned so the caller can hold onto it: the tween outlives the
-- function, and cancelling it on teardown is what stops it writing
-- Position onto an instance that's mid-collapse-wipe or already gone.
local function startTextureScroll(image)
	local home = image.Position

	-- offsets and the whole Y axis are left exactly as authored — only
	-- the X scale is driven, so a preview that's inset or nudged in
	-- Studio keeps that inset through every frame of the loop
	image.Position = UDim2.new(1.5, home.X.Offset, home.Y.Scale, home.Y.Offset)

	local scroll = TS:Create(
		image,
		TweenInfo.new(
			StashData.SCROLL_LOOP_SECONDS,
			Enum.EasingStyle.Linear,
			Enum.EasingDirection.InOut,
			-1,   -- repeat forever
			false -- don't reverse; snap back to the right and go again
		),
		{ Position = UDim2.new(-0.5, home.X.Offset, home.Y.Scale, home.Y.Offset) }
	)
	scroll:Play()

	return scroll
end

-- a bomb snaps between its two colors with no tween at all (that's what
-- makes it read as a flicker rather than a pulse); a magnet eases
-- between its two over the same interval. Both bail the moment their
-- token stops matching — a preview replaced out from under them, or a
-- collapse wipe taking it.
local function startColorLoop(index, image, spec, token)
	if spec.colorMode == "flicker" then
		task.spawn(function()
			local on = true -- the intro left it on colorB (see StashData.introColor), so the first step below is the one that moves it off
			while previewToken[index] == token do
				task.wait(spec.interval)
				if previewToken[index] ~= token or not image.Parent then return end
				on = not on
				image.BackgroundColor3 = on and spec.colorB or spec.colorA
			end
		end)
	elseif spec.colorMode == "fade" then
		task.spawn(function()
			local toB = true -- intro left it on colorA, so the first leg heads for colorB
			while previewToken[index] == token do
				if not image.Parent then return end
				TS:Create(
					image,
					TweenInfo.new(spec.interval, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
					{ BackgroundColor3 = toB and spec.colorB or spec.colorA }
				):Play()
				task.wait(spec.interval)
				if previewToken[index] ~= token then return end
				toB = not toB
			end
		end)
	elseif spec.colorMode == "sequence" then
		-- A radiant ball, running the exact loop RadiantFuse runs on the
		-- ball itself — same stops, same order, same linear segments, same
		-- total cycle time (see StashData.RADIANT_COLORS, which is kept in
		-- sync with that script by hand). Deliberately a copy of its shape
		-- rather than something merely similar: the preview is meant to be
		-- the same animation as the thing it's a preview of, so anything
		-- that drifts — easing, segment length, the order of the stops —
		-- would show up as the toolbar and the board disagreeing.
		--
		-- The index advances BEFORE the tween, like RadiantFuse's own
		-- loop, because the intro already left the preview sitting on
		-- colors[1] (see StashData.introColor) — so the first thing this
		-- does is head for the second stop rather than re-tween to where
		-- it already is.
		task.spawn(function()
			local segment = spec.cycleTime / #spec.colors
			local info = TweenInfo.new(segment, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut)
			local idx = 1
			while previewToken[index] == token do
				if not image.Parent then return end
				idx = (idx % #spec.colors) + 1
				TS:Create(image, info, { BackgroundColor3 = spec.colors[idx] }):Play()
				task.wait(segment)
				if previewToken[index] ~= token then return end
			end
		end)
	elseif spec.colorMode == "rainbowFlicker" then
		-- A radiant bomb: the plain bomb's flicker, but the lit tick spins
		-- the rainbow instead of holding on red. That's exactly the split
		-- RadiantBombFuse makes — its idle tick is the same flat navy a
		-- plain bomb sits on, and only the flash carries color (see its own
		-- header, point 1).
		--
		-- The FLICKER is snapped, never tweened, for the same reason the
		-- plain one is: easing between the navy and the lit color turns a
		-- flicker into a pulse, which is a different object entirely.
		--
		-- The HUE is continuous, and runs on that script's own clock rule:
		-- litAccum grows only on frames where the flash is lit, so the hue
		-- freezes solid through every dark tick and the next flash resumes
		-- exactly where the last one ended. A dark tick is a pause in the
		-- spin, not a gap the color crosses unseen — which is the whole
		-- difference between this and stepping one fixed stop per flash.
		--
		-- This is the file's one per-frame loop, and it has to be one: the
		-- hue never settles anywhere, so there are no stops to hand a
		-- tween, and easing raw RGB the third of a wheel a single flash
		-- covers would wash out through grey instead of staying saturated
		-- (the same trap StashData.RADIANT_COLORS exists to avoid).
		-- Heartbeat rather than RenderStepped: this only writes a color, so
		-- there's no reason to make the renderer wait on it, and a frame of
		-- latency is a fraction of a degree of hue.
		-- Seeded DARK because the intro leaves it on the off navy (see
		-- StashData.introColor), so the first flip one interval from now is
		-- the first flash. Starting lit here would double up on the intro's
		-- own color and cut the opening flash short.
		local lit = false
		local tickAccum = 0 -- wall-clock toward the next flicker flip
		local litAccum = 0  -- LIT time only; this and nothing else drives the hue
		local conn
		conn = RS.Heartbeat:Connect(function(dt)
			-- same bail as the other loops, just checked per-frame instead
			-- of per-step: a replaced or wiped preview drops this within a
			-- frame rather than at the end of the current interval
			if previewToken[index] ~= token or not image.Parent then
				conn:Disconnect()
				return
			end

			tickAccum += dt
			if tickAccum >= spec.interval then
				-- consume every whole interval this frame spanned, so a
				-- hitch leaves the flicker in the phase wall-clock says it
				-- should be in rather than running permanently behind
				local flips = math.floor(tickAccum / spec.interval)
				tickAccum -= flips * spec.interval
				if flips % 2 == 1 then
					lit = not lit
				end
			end

			if lit then
				litAccum += dt
				image.BackgroundColor3 = Color3.fromHSV((litAccum / spec.hueCycleTime) % 1, 1, 1)
			else
				image.BackgroundColor3 = spec.offColor
			end
		end)
	end
	-- "ball" and "static" have nothing to loop — whatever the intro
	-- faded them into is what they stay
end

-- white -> (INTRO_SNAP_DELAY) -> instant cyan -> (INTRO_FADE_TIME ease)
-- -> the kind's real color and image transparency -> its color loop.
-- Both waits are task.delay rather than a single coroutine with
-- task.wait so nothing here holds a thread open for a preview that may
-- well be gone by the time it fires; the token check at each step is
-- what makes that safe.
--
-- Deliberately doesn't touch Position: that belongs to the texture
-- scroll, which is already running by the time this fires. The two never
-- collide — this owns BackgroundColor3 and ImageTransparency, that owns
-- Position.
local function playIntro(index, image, spec, ballColor, token)
	task.delay(StashData.INTRO_SNAP_DELAY, function()
		if previewToken[index] ~= token or not image.Parent then return end

		image.BackgroundColor3 = StashData.INTRO_SNAP_COLOR -- instant, deliberately not a tween

		TS:Create(
			image,
			TweenInfo.new(StashData.INTRO_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{
				BackgroundColor3 = StashData.introColor(spec, ballColor),
				ImageTransparency = spec.imageTransparency,
			}
		):Play()

		task.delay(StashData.INTRO_FADE_TIME, function()
			if previewToken[index] ~= token or not image.Parent then return end
			startColorLoop(index, image, spec, token)
		end)
	end)
end

local function buildPreview(index, kind, size, ballColor, radiant)
	-- specFor rather than KINDS[kind]: a radiant ball and a plain one are
	-- the same kind but not the same preview, and this is the only place
	-- that difference has to be resolved — everything downstream just
	-- reads the spec it's handed
	local spec = StashData.specFor(kind, radiant)
	if not spec then return end

	clearPreview(index)
	local token = previewToken[index]

	local frame = previewTemplate:Clone()
	local image = frame:FindFirstChild("ballImage")
	if not image then
		-- guarded the same way BallManager's setDisplay guards its own
		-- display/numDisplay lookup: a template missing the child just
		-- no-ops instead of erroring
		frame:Destroy()
		warn("[StashClient] ballPreview has no ballImage child — preview skipped")
		return
	end

	-- every gradient off first, then exactly the one this kind wants
	-- back on. Explicitly disabling the others matters because the
	-- template is cloned fresh each time but the SET of gradients is
	-- shared — a splitter preview must never come up wearing the
	-- merger's gradient just because the template was saved that way.
	for _, gradientName in ipairs(StashData.GRADIENTS) do
		local gradient = image:FindFirstChild(gradientName)
		if gradient then
			gradient.Enabled = (spec.gradient == gradientName)
		end
	end

	-- image and gradient go live immediately; the image is simply
	-- invisible until the intro fades it in, so there's no second
	-- "enable it now" moment to get wrong
	image.Image = spec.image
	image.ImageTransparency = 1
	image.BackgroundColor3 = StashData.INTRO_START_COLOR

	-- ballDisplay is written here and never touched again — nothing
	-- animates it, so there's no token to check and no loop to leave
	-- running. Deliberately NOT guarded the way ballImage is above: the
	-- image is what a preview fundamentally IS, while a missing label
	-- just means no text, and warning about it here would print a line
	-- per absorb for the rest of the session rather than once.
	local display = frame:FindFirstChild("ballDisplay")
	if display then
		display.Text = StashData.displayFor(spec, size)
	end

	frame.Parent = slotButtons[index]

	-- started before the intro rather than after it: the scroll owns
	-- Position and the intro owns color and transparency, so the two are
	-- independent, and starting it now means the texture is already in
	-- motion for the whole of the intro's quarter-second rather than
	-- lurching into it afterwards. Held onto so clearPreview can cancel
	-- it — see there.
	local scrollTween = startTextureScroll(image)

	activePreviews[index] = { frame = frame, image = image, display = display, scrollTween = scrollTween }

	playIntro(index, image, spec, ballColor, token)
end

-- reconciles one slot's preview against what the slot actually holds.
-- Everything below routes through this rather than building/tearing
-- down directly, so a rejoin, a respawn, a fresh absorb, a deploy and
-- the end of a collapse wipe all take the exact same path.
local function refreshSlot(index)
	if wiping then return end -- the wipe owns every preview for its duration; see the handler at the bottom

	local slot = stash:FindFirstChild(tostring(index))
	if not slot then
		clearPreview(index)
		return
	end

	local kind = slot.Kind.Value
	if kind == "" then
		clearPreview(index)
		return
	end

	buildPreview(index, kind, slot.Size.Value, slot.Color.Value, slot.Radiant.Value)
end

local function refreshAllSlots()
	for index = 1, StashData.MAX_SLOTS do
		refreshSlot(index)
	end
end

-- StashHandler writes Kind LAST on an absorb and FIRST on a clear
-- (see writeSlot/clearSlot there), so watching Kind alone is always
-- watching a complete entry — Size/Color are already correct by the
-- time a build fires, and already irrelevant by the time a teardown
-- does.
for index = 1, StashData.MAX_SLOTS do
	local slot = stash:FindFirstChild(tostring(index))
	if slot then
		slot.Kind.Changed:Connect(function()
			refreshSlot(index)
		end)
	end
end

refreshAllSlots()

-- ── absorbing ───────────────────────────────────────────────────────

-- Aim is a ray from the camera through the mouse cursor, not straight
-- out of the camera's centre — the cursor can be pointed somewhere the
-- camera itself isn't facing, especially in third person. Same
-- targeting GrabClient's own raycastGrabTarget does, for the same
-- reason.
local function raycastStashTarget()
	local camera = WS.CurrentCamera
	if not camera then return nil end

	local mouseLocation = UIS:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }

	local result = WS:Raycast(ray.Origin, ray.Direction.Unit * RAYCAST_DISTANCE, params)
	return result and result.Instance or nil
end

-- Slots spoken for by a request that's already on its way to the
-- server. The absorb plays immediately, but a slot's own values only
-- appear once the server has written them and replication has carried
-- them back — and two R presses inside that window would both pick the
-- same empty slot, with the second orb quietly overwriting the first.
-- A reservation closes that gap, and lapses on its own if the answer
-- never arrives.
local RESERVATION_TIME = 2

local reservedUntil = {} -- [index] = os.clock() it stops counting as taken

local function slotIsFree(index)
	local slot = stash:FindFirstChild(tostring(index))
	if not slot or slot.Kind.Value ~= "" then
		return false
	end
	local until_ = reservedUntil[index]
	return not (until_ and os.clock() < until_)
end

local function firstFreeSlot(tier)
	for index = 1, tier do
		if slotIsFree(index) then
			return index
		end
	end
	return nil
end

-- Every check here mirrors one StashHandler makes server-side — none of
-- this is enforcement, it just avoids firing a request that was always
-- going to be dropped. StashHandler re-checks all of it and never
-- trusts any of it.
--
-- `target` is resolved by the caller rather than here, because whether
-- the cursor is on a board object at all is what decides whether Q
-- stashes or deploys in the first place — see the Q handler at the
-- bottom of this file.
local function tryStash(target)
	if player:GetAttribute("AFK") then return end
	if WS:GetAttribute("Collapsing") then return end

	local tier = currentTier()
	if tier == 0 then return end -- upgrade not owned at all
	local freeSlot = firstFreeSlot(tier)
	if not freeSlot then return end -- full; silently rejected, same as server-side

	local kind = StashData.kindFromInstance(target)
	if not kind then return end -- mimics land here, by virtue of not being in StashData.KINDS at all

	-- every kind is stashable radiant, and comes back out radiant — see
	-- StashHandler, which re-checks all of this and owns the rule
	local radiant = target:GetAttribute("IsRadiant") == true

	-- a magnet mid-pull is live and has to be waited out; a radiant bomb
	-- whose pull has gone live is the same situation wearing a different
	-- hat, and is recognised by the lift VectorForce RadiantBombFuse
	-- builds at that instant (it has no Pulling attribute of its own) —
	-- see StashData.RADIANT_PULL_LIFT_FORCE and StashHandler's own copy of
	-- this check for the full reasoning. The shrink that telegraphs the
	-- pull is deliberately NOT covered: that's still a stashable bomb.
	if kind == "magnet" and target:GetAttribute("Pulling") then return end
	if radiant and kind == "bomb" and target:FindFirstChild(StashData.RADIANT_PULL_LIFT_FORCE) then return end
	if target:GetAttribute("Held")
		or target:GetAttribute("PendingSell")
		or target:GetAttribute("Sold")
		or target:GetAttribute("Split")
		or target:GetAttribute("SplitPending")
		or target:GetAttribute("MergePending")
	then
		return
	end

	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	-- distance to the ball's SURFACE, not its centre — matches
	-- StashHandler's own check. Through the shared StashData.captureSize
	-- rather than target.Size.X so it measures against exactly the number
	-- the server will store: a radiant bomb mid-shrink is the case where
	-- those two differ, and reading the shrunken sphere here would make
	-- this pre-check stricter than the server and silently swallow legal
	-- stashes at the edge of range.
	local size = StashData.captureSize(target)
	if (target.Position - hrp.Position).Magnitude - size / 2 > STASH_RANGE then return end

	-- The pull plays here and now, and the orb leaves the board the
	-- moment it arrives. The server is told which id went and fills the
	-- slot from its own ledger, so the size in the toolbar is the one
	-- the board already had — never a number this client sent.
	local id = ClientBoard.stashAbsorb(target)
	if not id then return end

	reservedUntil[freeSlot] = os.clock() + RESERVATION_TIME
	stashRequest:FireServer(id)
end

-- ── deploying ───────────────────────────────────────────────────────
-- Two ways in, both landing here: clicking a slot button, or pressing Q
-- (see the key handler below). Same checks either way — the key is not a
-- shortcut past anything the button enforces, it's the same call.
--
-- Everything here is a pre-check only, exactly like tryStash above:
-- StashDeploy re-validates the tier, the index and the slot's contents
-- server-side and never trusts any of it.
local function tryDeploy(index)
	if player:GetAttribute("AFK") then return end

	-- The button's own Active = false already blocks the click while AFK,
	-- but the key path bypasses the button entirely — so the guard above has
	-- to be spelled out here rather than left to the button, the same way
	-- SellClient's "1" and ShopClient's "2" each re-check it for their own
	-- keybinds.
	if index > currentTier() then return end

	local slot = stash:FindFirstChild(tostring(index))
	if not slot or slot.Kind.Value == "" then return end -- empty slot — nothing to put back

	stashDeploy:FireServer(index)
end

for index, button in ipairs(slotButtons) do
	button.MouseButton1Click:Connect(function()
		tryDeploy(index)
	end)
end

-- Highest-numbered occupied slot the player actually owns, or nil if
-- they're empty. Highest rather than lowest because the toolbar fills
-- LEFT to right (firstFreeSlot on the server takes slot 1 first), so the
-- last ball stashed is the rightmost one — and the Q deploy below is
-- meant to hand back the most recent thing you put away, the way undoing
-- a stack does.
local function rightmostOccupiedSlot()
	for index = currentTier(), 1, -1 do
		local slot = stash:FindFirstChild(tostring(index))
		if slot and slot.Kind.Value ~= "" then
			return index
		end
	end
	return nil
end

-- ── R / Q ───────────────────────────────────────────────────────────
--   R -> stash whatever the cursor is on
--   Q -> deploy the rightmost stashed ball, wherever the cursor is
--
-- Two separate keys, and that separation is the whole point. An earlier
-- version had one key do both, choosing by whether the cursor was on a
-- ball — which meant a slightly-off aim didn't fail, it did the exact
-- opposite of what was intended and threw a stashed ball back onto the
-- board. Aim is the wrong signal to carry that decision: balls move,
-- they're small at range, and the cursor is over empty space most of the
-- time. A modifier (ALT+Q) fixed the ambiguity but not the ergonomics.
--
-- With one key each, both failures are harmless. R that hits nothing
-- stashable does nothing at all. Q deliberately ignores the cursor
-- entirely — deploying while looking straight at a ball is a perfectly
-- ordinary thing to want, and having it silently refuse was a large part
-- of why the whole thing felt unpredictable.
--
-- NOTE: R was the HUD's counter-cycle key before this (see HudUI, and
-- the collapse quip in SellService that mentions it). Both keys were
-- freed up deliberately; if R ever stops stashing, that's the first
-- thing to check for having been rebound back.
UIS.InputBegan:Connect(function(input, processed)
	if processed then return end -- typing in chat, or the cursor is over a GUI that swallowed it

	if input.KeyCode == Enum.KeyCode.R then
		-- stash only. A miss is a no-op, never a deploy.
		local target = raycastStashTarget()
		if target and target.Parent == bf then
			tryStash(target)
		end
		return
	end

	if input.KeyCode == Enum.KeyCode.Q then
		local index = rightmostOccupiedSlot()
		if index then
			tryDeploy(index)
		end
	end
end)

-- ── AFK ─────────────────────────────────────────────────────────────
-- Same treatment the sell and shop toolbar buttons get: disabled (and
-- dimmed) for as long as AFK is on. R needs its own guard in tryStash
-- since it doesn't route through a button at all.
player:GetAttributeChangedSignal("AFK"):Connect(function()
	setSlotButtonsDisabled(player:GetAttribute("AFK") == true)
end)

-- ── collapse wipe ───────────────────────────────────────────────────
-- Fired by StashHandler's _G.StashCollapseWipe as BallManager's own
-- per-ball sell loop starts, so the toolbar drains alongside the board.
--
-- `wiping` locks refreshSlot out for the duration: the server clears
-- the slot values once this animation is over (see that function's own
-- comment), and without the lock those clears would fire refreshSlot
-- and destroy previews that are already mid-fade. Bumping each slot's
-- token up front hands ownership of its frame to this handler outright
-- — it kills any in-flight intro step and any running color loop, so
-- nothing is still writing BackgroundColor3 while the wipe is fading
-- it to magenta.
stashCollapse.OnClientEvent:Connect(function()
	wiping = true

	for index = 1, StashData.MAX_SLOTS do
		local preview = activePreviews[index]
		activePreviews[index] = nil
		previewToken[index] += 1

		if preview then
			local frame, image, display = preview.frame, preview.image, preview.display

			-- the texture keeps scrolling right through the wipe, which is
			-- what it should do — it's fading and shrinking away, not
			-- freezing. Only cancelled once the frame is actually destroyed
			-- at the end of the shrink below.
			local scrollTween = preview.scrollTween

			task.delay((index - 1) * StashData.WIPE_SLOT_GAP, function()
				if not frame.Parent then return end

				TS:Create(
					image,
					TweenInfo.new(StashData.WIPE_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{
						ImageTransparency = 1,
						BackgroundColor3 = StashData.WIPE_COLOR,
					}
				):Play()

				-- the label goes with it, on the same curve over the same
				-- window: it's a separate instance, so the fade above
				-- doesn't reach it, and text left at full opacity on top of
				-- a swatch that has already gone reads as the wipe having
				-- missed a bit. TextTransparency only — a UIStroke on the
				-- label, or a text stroke, would need its own line here.
				if display then
					TS:Create(
						display,
						TweenInfo.new(StashData.WIPE_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ TextTransparency = 1 }
					):Play()
				end

				task.delay(StashData.WIPE_FADE_TIME, function()
					if not frame.Parent then return end
					local shrink = TS:Create(
						frame,
						TweenInfo.new(StashData.WIPE_SHRINK_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.In),
						{ Size = UDim2.new(0, 0, 0, 0) }
					)
					shrink.Completed:Connect(function()
						if scrollTween then
							scrollTween:Cancel()
						end
						frame:Destroy()
					end)
					shrink:Play()
				end)
			end)
		end
	end

	-- a little past the animation's own length, so the server's clear
	-- (scheduled for exactly wipeDuration()) has definitely landed
	-- before this reconciles — otherwise refreshAllSlots could rebuild
	-- a preview off a slot that's about to be emptied a frame later
	task.delay(StashData.wipeDuration() + 0.25, function()
		wiping = false
		refreshAllSlots()
	end)
end)