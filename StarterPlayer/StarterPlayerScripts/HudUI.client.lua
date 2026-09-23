--[[
    HudUI (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-23 02:07:55
]]
--[[
    HudUI (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-22 18:28:58
]]
--[[
	HudUI (LocalScript) — StarterPlayerScripts

	Drives the ball-count label (ballCount SurfaceGui > ballNum) and the
	toolbar reveal (toolbar ScreenGui > toolbarContainer), both gated on
	the same ball-count threshold (SHOW_THRESHOLD).

	Ball count label: slides in/out on that threshold. What it shows
	cycles through 3 modes on Q — see MODES / getDisplayText: ball count
	(yellow), queued-launch count (cyan, from BallManager's QueueCount
	attribute on the Balls folder — the launch queue itself is
	server-local and never replicated), and server age (magenta, from
	Workspace's ServerStartTime attribute). Mode-switch and per-mode
	animation details are commented at each piece below (MODE_SWITCH_*,
	COLOR_FLASH_*, the aside-flash helpers, the collapse-aware server
	age state machine).

	Toolbar: same reveal threshold, no text; also forced hidden while
	AFK (AFKHandler's "AFK" attribute on the player) regardless of ball
	count, via newElement's extraHide predicate.

	Resilient to character reset: the pause-menu Reset button (and
	dying) recreates these StarterGui-cloned guis even with
	ResetOnSpawn off below — likely because that flag gets set a beat
	too late to catch the very first reclone. Rather than trust the
	flag alone, each element rebinds to whatever the *current* live
	instance is (ChildAdded on both PlayerGui and its own gui) and
	forces a resync on every CharacterAdded, so it's correct after a
	respawn regardless of what actually caused the old reference to go
	stale.
]]

local Players = game:GetService("Players")
local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local TS = game:GetService("TweenService")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local BadgeService = game:GetService("BadgeService")

-- Owning this badge reveals the toolbar immediately on join, without
-- waiting for the ball count to ever hit SHOW_THRESHOLD — see
-- checkToolbarBadge further below, once toolbarEl exists.
local TOOLBAR_BADGE_ID = 1937874786736578 -- rbxassetid://1937874786736578

local TWEEN_TIME = 0.5
local EASE_OUT = TweenInfo.new(TWEEN_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
local EASE_IN = TweenInfo.new(TWEEN_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)

local SHOW_THRESHOLD = 2 -- reveal once the ball count reaches this (matches "at least 2 balls")
local MAX_BALLS = 50

-- ballNum's 3 display modes, cycled with Q — see cycleMode below for the
-- bump transition and getDisplayText for what each mode shows
local MODES = {
	{ name = "ballCount", color = Color3.fromRGB(255, 255, 0) },
	{ name = "queueCount", color = Color3.fromRGB(0, 255, 255) },
	{ name = "serverAge", color = Color3.fromRGB(255, 0, 255) },
}
local modeIndex = 1

-- Baseline used to tell whether QueueCount is rising or falling.
local queueLastCount = nil

-- Generic "cancel whatever's running under this key, play a new tween,
-- clear the key on natural completion" driver. Every one-off tween in
-- this script (queue pulses, color flashes, aside flashes, show/hide)
-- used to hand-roll this same cancel/create/Completed dance; centralizing
-- it here is most of this file's line-count savings. `store` is a plain
-- table and `key` the slot to track, so unrelated tweens (module-level
-- ones in `tweens`, or an element's own position tween) don't collide.
local function cancelTween(store, key)
	if store[key] then
		store[key]:Cancel()
		store[key] = nil
	end
end

local function playTween(store, key, instance, tweenInfo, goal, onComplete)
	cancelTween(store, key)
	local tween = TS:Create(instance, tweenInfo, goal)
	store[key] = tween
	tween.Completed:Connect(function(playbackState)
		if store[key] ~= tween then return end -- superseded by a newer tween under this key
		store[key] = nil
		if onComplete and playbackState == Enum.PlaybackState.Completed then
			onComplete()
		end
	end)
	tween:Play()
	return tween
end

-- Module-level tween slots, shared by cycleMode/applyServerAgeColorIfActive
-- (the mode-switch color flash) and pulseQueueUpdate (the queue-update
-- pulse). Declared here so everything below closes over the same table
-- regardless of definition order.
local tweens = {}

-- quick "bump" transition for a mode switch: the label jumps instantly
-- (no tween) up to Y scale MODE_SWITCH_BUMP_Y — text swaps right there —
-- then eases back down to its resting Y scale (0) with MODE_SWITCH_EASE.
-- A full slide (an earlier version) looked bad since ballNum fills the
-- whole frame.
local MODE_SWITCH_TIME = 0.5
local MODE_SWITCH_EASE = TweenInfo.new(MODE_SWITCH_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local MODE_SWITCH_BUMP_Y = -0.005

-- ballNum's text is white at rest. On a switch it flashes instantly to
-- the new mode's color (see MODES), then eases back to white over
-- COLOR_FLASH_TIME — independent of the position bump above, on its own
-- timing.
local WHITE = Color3.new(1, 1, 1)
local COLOR_FLASH_TIME = 0.5
local COLOR_FLASH_TWEEN = TweenInfo.new(COLOR_FLASH_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Generic "flash to a color, ease back to grey" driver for the small
-- parenthetical asides — queue's tier suffix and "(max)" — shared by
-- both since only one is ever on screen at a time (they're
-- mode-exclusive). TweenService can't interpolate the hex string
-- embedded in RichText directly, so this rides a throwaway Color3Value
-- instead and re-renders the label every frame the tween is running —
-- see startAsideFlash/stopAsideFlash further below, once ballCountEl
-- exists for them to refresh.
local ASIDE_GRAY = Color3.fromRGB(0x80, 0x80, 0x80)
local asideColorValue = Instance.new("Color3Value")
asideColorValue.Value = ASIDE_GRAY
local asideFlashConn = nil

local function asideColorHex()
	local c = asideColorValue.Value
	return string.format(
		"#%02X%02X%02X",
		math.floor(c.R * 255 + 0.5),
		math.floor(c.G * 255 + 0.5),
		math.floor(c.B * 255 + 0.5)
	)
end

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local ballT = Rep:WaitForChild("Ball") -- name check excludes bombs from the count, same pattern as SellClient
local bf = WS:WaitForChild("Balls")

local function countBalls()
	local n = 0
	for _, obj in ipairs(bf:GetChildren()) do
		-- Split-flagged balls have already spawned their 2 replacements
		-- and are just falling on their way out — see BallManager's
		-- splitBall — so they're excluded even though still parented
		if obj.Name == ballT.Name and not obj:GetAttribute("Split") then
			n += 1
		end
	end
	return n
end

-- "(max)" aside: grey at rest, flashes to a dark yellow the same way the
-- queue aside flashes to a dark cyan — see startAsideFlash's callers in
-- cycleMode below.
local MAX_ASIDE_FLASH = Color3.fromRGB(0x66, 0x66, 0x00)
local QUEUE_ASIDE_FLASH = Color3.fromRGB(0x00, 0x66, 0x66)

local function countText(count)
	if count >= MAX_BALLS then
		return string.format('%d orbs <font color="%s">(max)</font>', MAX_BALLS, asideColorHex())
	end
	if count == 1 then
		return "1 orb"
	end
	return string.format("%d orbs", count)
end

local function queueCount()
	-- kept in sync by BallManager on every queue mutation; nil until the
	-- first one ever fires (defaults to 0, though in practice the
	-- server's own bootstrap spawn sets this before a client could ever
	-- observe it unset)
	return bf:GetAttribute("QueueCount") or 0
end

-- Queue dialogue changes when the queue enters a DIFFERENT tier. Direction
-- is chosen from the direction of the tier transition:
--   rising into a higher tier -> up text
--   falling into a lower tier -> down text
--
-- Moving back and forth around a tier's threshold never swaps up <-> down.
-- QUEUE_DIRECTION_HYSTERESIS is the buffer used when deciding whether a
-- move has actually left the current tier, so small natural queue jitter
-- does not cause a message change.
--
-- up/down share one `min` per tier on purpose — a previous version kept
-- these as two separate tables, which led to mismatches between the two.
-- One table with one `min` per tier rules that class of mismatch out.
local QUEUE_TIERS = {
	{ min = 200, up = "%d queued (it's so over)", down = "%d queued (missingno.)" },
	{ min = 150, up = "%d queued (it's so over)", down = "%d queued (WE'RE SO BACK ???)" },
	{ min = 100, up = "%d queued (SELL SELL SELL SELL)", down = "%d queued (MORE SELLING MORE SELLING)" },
	{ min = 80, up = "%d queued (i would REALLY start selling)", down = "%d queued (this is probably fine ...)" },
	{ min = 60, up = "%d queued (maybe start selling?)", down = "%d queued (getting better ...)" },
	{ min = 40, up = "%d queued (getting kinda high ...)", down = "%d queued (yay !!!)" },
}

local QUEUE_DIRECTION_HYSTERESIS = 5

local activeQueueTierMin = nil
local activeQueueDirection = nil -- "up" | "down"

-- Highest warning tier whose threshold is reached by count.
local function tierForCount(count)
	for _, tier in ipairs(QUEUE_TIERS) do
		if count >= tier.min then
			return tier
		end
	end
	return nil
end

local function queueText(count)
	-- Below 35 the warning disappears completely. The QueueCount listener
	-- also clears the state, so the next climb through 40 is a fresh UP.
	if count < 35 then
		return string.format("%d queued", count)
	end

	local raw
	if activeQueueTierMin ~= nil and activeQueueDirection ~= nil then
		for _, tier in ipairs(QUEUE_TIERS) do
			if tier.min == activeQueueTierMin then
				raw = string.format(activeQueueDirection == "down" and tier.down or tier.up, count)
				break
			end
		end
	end

	raw = raw or string.format("%d queued", count)

	local openBracket = raw:find(" %(")
	if not openBracket then
		return raw
	end

	local main = raw:sub(1, openBracket - 1)
	local aside = raw:sub(openBracket + 2, -2)
	return string.format('%s <font color="%s">(%s)</font>', main, asideColorHex(), aside)
end

-- time since THIS server instance started, not the raw Unix timestamp
-- workspace:GetServerTimeNow() returns on its own — see BallManager's
-- ServerStartTime attribute
local function serverAge()
	local start = WS:GetAttribute("ServerStartTime")
	if not start then return 0 end
	return math.max(0, WS:GetServerTimeNow() - start)
end

local function formatServerAge(seconds)
	seconds = math.floor(seconds)
	local h = seconds // 3600
	local m = (seconds % 3600) // 60
	local s = seconds % 60
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s)
	end
	return string.format("%d:%02d", m, s)
end

-- ── collapse-aware server age ────────────────────────────────────────
-- Fed by BallManager's Collapsing attribute on Workspace (true for the
-- whole freeze/sell/penalty/fade cinematic — see triggerCollapse). This
-- label is already off-screen for the entire collapse anyway (the ball
-- count UI only shows at SHOW_THRESHOLD+ balls, and a collapse's whole
-- point is wiping the board to zero), so there's nothing to animate
-- mid-collapse — just freeze magenta the instant Collapsing goes true,
-- and the instant it goes false, drop back to white and start counting
-- "time since last collapse" from zero instead of "time since server
-- start", permanently, from then on. The "...since last incident" suffix
-- appears the first time Collapsing ever goes false and, once earned,
-- sticks permanently — including through every later freeze, not just
-- the counting-up phase — and gets struck through (RichText's <s>, see
-- ballCountEl's onBind) for exactly as long as the current collapse is
-- frozen.
local COLLAPSE_MAGENTA = Color3.fromRGB(255, 0, 255)
local ageState = "normal" -- "normal" | "frozen" | "postCollapse"
local frozenAgeValue = 0
local postCollapseStart = nil
local hadCollapse = false -- once the first collapse ever finishes, the "since last incident" suffix is permanent

local function currentServerAgeSeconds()
	if ageState == "normal" then
		return serverAge()
	elseif ageState == "frozen" then
		return frozenAgeValue
	else -- postCollapse
		return WS:GetServerTimeNow() - postCollapseStart
	end
end

local function serverAgeText()
	local text = formatServerAge(currentServerAgeSeconds())
	if hadCollapse then
		local suffix = "since last incident"
		if ageState == "frozen" then
			suffix = "<s>" .. suffix .. "</s>"
		end
		text = text .. " " .. suffix
	end
	return text
end

-- forward-declared: cycleMode (below) and the Collapsing listener
-- (further below, once ballCountEl exists) both need to re-assert this
local applyServerAgeColorIfActive

-- what ballNum actually shows for the currently-selected mode
local function getDisplayText(count)
	local mode = MODES[modeIndex]
	if mode.name == "ballCount" then
		return countText(count or countBalls())
	elseif mode.name == "queueCount" then
		return queueText(queueCount())
	else -- serverAge
		return serverAgeText()
	end
end

--[[
	Builds a self-contained "reveal element": binds to a child instance
	inside a top-level PlayerGui entry, rebinds itself whenever Roblox
	reclones either the top-level gui or the child, and exposes
	snapToCurrentState/updateBar for the shared listeners below to
	drive.

	config:
		guiName, childName  — names to WaitForChild under playerGui / gui
		hiddenPos, shownPos — function(basePos) -> UDim2
		setText             — optional function(instance, count); omit for no text
		onBind              — optional function(instance); runs once per (re)bind, before snapToCurrentState
		extraHide           — optional function() -> bool; when true, forces hidden regardless of ball count
		stickyOnceShown     — optional bool; once this element has shown for the first
		                      time (ball count naturally crossing the threshold, or
		                      being forced open — see toolbarEl's badge check below),
		                      it stays eligible to show from then on regardless of
		                      ball count. extraHide (AFK, for toolbarEl) still
		                      overrides this.
]]
local function newElement(config)
	local el = { gui = nil, instance = nil, basePos = nil, shown = false, everShown = false, tweens = {} }

	local function posAt(hidden)
		return hidden and config.hiddenPos(el.basePos) or config.shownPos(el.basePos)
	end

	-- count-based threshold ANDed with an optional extraHide predicate
	-- (config.extraHide) that can force this element hidden regardless
	-- of ball count — used by toolbarEl below to stay hidden while AFK
	-- even with plenty of balls on the board. Threshold-only elements
	-- (ballCountEl) just never set extraHide, so this is a no-op change
	-- for them.
	local function shouldShowNow()
		if config.extraHide and config.extraHide() then
			return false
		end
		if config.stickyOnceShown then
			if el.everShown then
				return true
			end
			if countBalls() >= SHOW_THRESHOLD then
				el.everShown = true
				return true
			end
			return false
		end
		return countBalls() >= SHOW_THRESHOLD
	end

	function el.cancelPositionTween()
		cancelTween(el.tweens, "position")
	end

	-- shared by updateBar's show/hide tween and cycleMode's mode-switch
	-- bump-back below, so either one cancels the other cleanly
	function el.playPositionTween(tweenInfo, goal, onComplete)
		return playTween(el.tweens, "position", el.instance, tweenInfo, goal, onComplete)
	end

	function el.snapToCurrentState()
		if not el.instance then return end
		el.cancelPositionTween()
		local count = countBalls()
		el.shown = shouldShowNow()
		if config.setText then
			config.setText(el.instance, count)
		end
		el.instance.Position = posAt(not el.shown)
	end

	function el.updateBar()
		if not el.instance then return end
		local count = countBalls()
		if config.setText then
			config.setText(el.instance, count)
		end

		local shouldShow = shouldShowNow()
		if shouldShow == el.shown then return end
		el.shown = shouldShow

		el.playPositionTween(el.shown and EASE_OUT or EASE_IN, { Position = posAt(not el.shown) })
	end

	-- refreshes text only — no position/color/shown-state change. Used
	-- by cycleMode's text swap and the 1-second ticker, neither of which
	-- should touch the show/hide tween's Y position.
	function el.refreshText()
		if not el.instance or not config.setText then return end
		-- Queue-count refreshes can happen in bursts while the board is busy.
		-- Don't rescan every ball just to render queue text; the queue mode reads
		-- its own replicated QueueCount attribute directly.
		local count = MODES[modeIndex].name == "ballCount" and countBalls() or nil
		config.setText(el.instance, count)
	end

	local function bindInstance(newInstance)
		el.instance = newInstance
		el.basePos = newInstance.Position
		if config.onBind then
			config.onBind(newInstance)
		end
		el.snapToCurrentState()
	end

	function el.bindGui(newGui)
		el.gui = newGui
		el.gui.ResetOnSpawn = false -- best-effort: try to stop Roblox recloning this at all; the listeners below are the real safety net

		bindInstance(el.gui:WaitForChild(config.childName))

		-- covers the case where only the child instance underneath an
		-- already-persisted gui gets swapped out
		el.gui.ChildAdded:Connect(function(child)
			if child.Name == config.childName then
				bindInstance(child)
			end
		end)
	end

	el.bindGui(playerGui:WaitForChild(config.guiName))

	return el
end

local ballCountEl = newElement({
	guiName = "ballCount",
	childName = "ballNum",
	hiddenPos = function(basePos)
		return UDim2.new(basePos.X.Scale, basePos.X.Offset, -0.1, basePos.Y.Offset)
	end,
	shownPos = function(basePos)
		return UDim2.new(basePos.X.Scale, basePos.X.Offset, 0, basePos.Y.Offset)
	end,
	setText = function(instance, _count)
		-- ignores the raw ball count passed in — what's shown depends on
		-- the active mode, see getDisplayText. Color isn't touched here:
		-- it's white at rest, only flashed by cycleMode on a switch.
		instance.Text = getDisplayText()
	end,
	onBind = function(instance)
		instance.TextColor3 = WHITE
		instance.RichText = true -- needed for serverAgeText's <s> strikethrough on the since-last-incident suffix during an active collapse
	end,
})

local toolbarEl = newElement({
	guiName = "toolbar",
	childName = "toolbarContainer",
	hiddenPos = function(basePos)
		return UDim2.new(basePos.X.Scale, basePos.X.Offset, 1.2, basePos.Y.Offset)
	end,
	shownPos = function(basePos)
		return UDim2.new(basePos.X.Scale, basePos.X.Offset, 1, basePos.Y.Offset)
	end,
	-- AFKHandler owns this attribute (see its header) — forces the
	-- toolbar to stay hidden while AFK regardless of ball count. Only
	-- the toolbar, not the Roblox topbar/TopbarPlus icons — those live
	-- entirely outside this gui and are untouched, so the AFK icon
	-- itself always stays clickable to toggle back off.
	extraHide = function()
		return player:GetAttribute("AFK")
	end,
	-- Once it's risen for the first time (ball count crossing
	-- SHOW_THRESHOLD, or being forced open by checkToolbarBadge below),
	-- it no longer drops back down just because the ball count does —
	-- AFK can still hide it, per extraHide above.
	stickyOnceShown = true,
})

local elements = { ballCountEl, toolbarEl }
queueLastCount = queueCount()

-- Badge owners get the toolbar immediately on join, without waiting for
-- the ball count to ever reach SHOW_THRESHOLD. Marking everShown makes
-- this permanent (same as a natural threshold-crossing reveal — see
-- stickyOnceShown), and updateBar picks up the change on the very next
-- call rather than snapping instantly, so a same-frame AFK state still
-- suppresses it, same as any other reveal.
local function checkToolbarBadge()
	local ok, hasBadge = pcall(BadgeService.UserHasBadgeAsync, BadgeService, player.UserId, TOOLBAR_BADGE_ID)
	if ok and hasBadge then
		toolbarEl.everShown = true
		toolbarEl.updateBar()
	end
end
task.spawn(checkToolbarBadge)

-- covers the case where a whole top-level gui gets recreated — e.g. if
-- a reset was already in flight before an element set ResetOnSpawn, or
-- something else recreates it
playerGui.ChildAdded:Connect(function(child)
	for _, el in ipairs(elements) do
		if child.Name == el.gui.Name and child ~= el.gui then
			el.bindGui(child)
		end
	end
end)

-- catch-all for the actual reported symptom: whatever the Reset button
-- / dying does to these guis, force them back to the true current
-- count right after every respawn — regardless of whether it was the
-- top-level gui, just the child, or something else entirely that
-- touched it
player.CharacterAdded:Connect(function()
	for _, el in ipairs(elements) do
		el.snapToCurrentState()
	end
end)

-- normal live-update path: text (where applicable) always current,
-- position only tweens when the threshold is actually crossed
local function updateAll()
	for _, el in ipairs(elements) do
		el.updateBar()
	end
end

-- forces ballNum's color to reflect the collapse-age state (magenta
-- only while frozen, white otherwise) but only when serverAge is
-- actually the mode on screen — ballCount/queueCount's own color
-- handling is untouched
applyServerAgeColorIfActive = function(forceResting)
	local inst = ballCountEl.instance
	if not inst or MODES[modeIndex].name ~= "serverAge" then return end

	if ageState == "frozen" then
		cancelTween(tweens, "color")
		inst.TextColor3 = COLLAPSE_MAGENTA
	elseif forceResting then
		cancelTween(tweens, "color")
		inst.TextColor3 = WHITE
	end
end

bf.ChildAdded:Connect(updateAll)
bf.ChildRemoved:Connect(updateAll)

-- toolbarEl's extraHide reads this live, so flipping it just needs a
-- re-run of the normal tween path — same updateBar every ball add/
-- remove already goes through, nothing toolbar-specific to add
player:GetAttributeChangedSignal("AFK"):Connect(function()
	toolbarEl.updateBar()
end)

-- queue-count mode's source refreshes on its own schedule (server
-- mutations), not on ball add/remove. Remember the previous count so the
-- dialogue can react differently when the player is bringing the queue down.
bf:GetAttributeChangedSignal("QueueCount"):Connect(function()
	local count = queueCount()
	local previous = queueLastCount

	if previous ~= nil and count ~= previous then
		if count < 35 then
			-- Warning text is gone below 35. Forget the previous tier so the
			-- next entry through 40 is always a fresh UP warning.
			activeQueueTierMin = nil
			activeQueueDirection = nil

		else
			local currentTier = tierForCount(count)

			if activeQueueTierMin == nil then
				-- First entry into the warning range. A single update can jump
				-- over several thresholds, so use the highest tier reached.
				if currentTier then
					activeQueueTierMin = currentTier.min
					activeQueueDirection = count > previous and "up" or "down"
				end

			elseif currentTier and currentTier.min ~= activeQueueTierMin then
				-- The message changes ONLY when we enter a different tier.
				-- Reversing direction inside the same tier never changes the
				-- message from UP to DOWN (or vice versa).
				--
				-- Hysteresis applies to the boundary of the tier we're leaving:
				-- this prevents a queue hovering around a threshold from
				-- repeatedly entering/leaving adjacent tiers.
				local boundary = activeQueueTierMin
				local crossed = false

				if count > previous then
					-- Moving upward: require the old tier's threshold + buffer
					-- before committing to the higher tier.
					crossed = count >= boundary + QUEUE_DIRECTION_HYSTERESIS
				elseif count < previous then
					-- Moving downward: require the old tier's threshold - buffer
					-- before committing to the lower tier.
					crossed = count <= boundary - QUEUE_DIRECTION_HYSTERESIS
				end

				if crossed then
					activeQueueTierMin = currentTier.min
					activeQueueDirection = count > previous and "up" or "down"
				end
			end
		end
	end

	ballCountEl.refreshText()
	queueLastCount = count
end)

-- drives the whole collapse-aware serverAge state machine above —
-- freezes the instant Collapsing goes true, hands off to postCollapse
-- (ticking up from zero) the instant it goes false
WS:GetAttributeChangedSignal("Collapsing"):Connect(function()
	if WS:GetAttribute("Collapsing") then
		frozenAgeValue = currentServerAgeSeconds() -- whatever's actually on the clock right now — server age pre-first-incident, time-since-last-incident after
		ageState = "frozen"
	else
		postCollapseStart = WS:GetServerTimeNow()
		ageState = "postCollapse"
		hadCollapse = true
	end
	ballCountEl.refreshText()
	applyServerAgeColorIfActive(true)
end)

-- server-age mode ticks on its own even with nothing else happening on
-- the board — this also doubles as a catch-all refresh for whichever
-- mode is currently active
task.spawn(function()
	while true do
		task.wait(1)
		ballCountEl.refreshText()
		applyServerAgeColorIfActive()
	end
end)

-- ── collapse telegraph countdown ────────────────────────────────────
-- Driven entirely off Workspace's CollapseCountdown attribute (see
-- BallManager's checkOverflow/startCollapseCountdown): nil while no
-- sustained overflow is building, an integer seconds-remaining while it
-- is. Lives under the same "toolbar" ScreenGui as toolbarEl, but as its
-- own sibling child (collapseCountdown) with its own independent
-- show/hide — this has nothing to do with ball count, so it doesn't go
-- through newElement's threshold-gated shown/hidden model at all, just
-- its own bespoke rebind-on-reset handling below (same reasoning as
-- newElement's own: the pause-menu Reset/dying reclones StarterGui
-- entries even with ResetOnSpawn off). The per-tick ping (12222170) and
-- the temporary tension loop are both fired server-side over
-- SoundEvents by BallManager, alongside this same attribute change —
-- nothing to play from here.
local COUNTDOWN_GUI_NAME, COUNTDOWN_CHILD_NAME = "toolbar", "collapseCountdown"
local COUNTDOWN_START_Y, COUNTDOWN_SHOWN_Y = 0.905, 0.9

local countdownInstance = nil
local countdownTweens = {}

local function countdownText(n)
	return string.format("%d second%s until collapse", n, n == 1 and "" or "s")
end

-- Re-run on every CollapseCountdown change, including the very first
-- appearance (n == the sustain window's full length): position snaps to
-- COUNTDOWN_START_Y then eases (EASE_OUT — exponential out, same tween
-- already used for the show/hide reveal above) down to COUNTDOWN_SHOWN_Y,
-- and the text instantly flashes magenta before easing back to white
-- (COLOR_FLASH_TWEEN) — same instant-jump/ease-back shape as ballNum's
-- own mode-switch color flash, just applied to position too here. Also
-- cancels/reverses any fade-out hideCountdown left mid-flight, so a
-- fresh tick right as it's disappearing snaps it back to fully opaque
-- instead of continuing to fade under the new text.
local function onCountdownTick(n)
	local inst = countdownInstance
	if not inst then return end

	cancelTween(countdownTweens, "fade")
	inst.TextTransparency = 0
	inst.Visible = true
	inst.Text = countdownText(n)

	local pos = inst.Position
	cancelTween(countdownTweens, "position")
	inst.Position = UDim2.new(pos.X.Scale, pos.X.Offset, COUNTDOWN_START_Y, pos.Y.Offset)
	playTween(countdownTweens, "position", inst, EASE_OUT, {
		Position = UDim2.new(pos.X.Scale, pos.X.Offset, COUNTDOWN_SHOWN_Y, pos.Y.Offset),
	})

	inst.TextColor3 = COLLAPSE_MAGENTA -- instant flash
	playTween(countdownTweens, "color", inst, COLOR_FLASH_TWEEN, { TextColor3 = WHITE })
end

-- Countdown ended (collapse fired, or the overflow recovered on its
-- own) — eases TextTransparency out (EASE_IN, same exponential-in shape
-- toolbarEl/ballCountEl already hide with) rather than snapping
-- Visible off, then actually hides once the fade completes so it isn't
-- sitting there invisible-but-still-occupying-layout in the meantime.
local function hideCountdown()
	local inst = countdownInstance
	if not inst then return end
	cancelTween(countdownTweens, "position")
	cancelTween(countdownTweens, "color")
	playTween(countdownTweens, "fade", inst, EASE_IN, { TextTransparency = 1 }, function()
		inst.Visible = false
	end)
end

local function bindCountdownInstance(newInstance)
	countdownInstance = newInstance
	countdownInstance.Visible = false
	countdownInstance.TextTransparency = 0

	local n = WS:GetAttribute("CollapseCountdown")
	if n then
		onCountdownTick(n) -- joining/respawning mid-countdown: catch up immediately instead of waiting on the next tick
	end
end

local function bindCountdownGui(gui)
	gui.ResetOnSpawn = false -- best-effort, same reasoning as newElement's own guis

	bindCountdownInstance(gui:WaitForChild(COUNTDOWN_CHILD_NAME))

	-- covers just the child instance underneath an already-persisted gui
	-- getting swapped out, same as newElement's own bindGui
	gui.ChildAdded:Connect(function(child)
		if child.Name == COUNTDOWN_CHILD_NAME then
			bindCountdownInstance(child)
		end
	end)
end

local countdownGui = playerGui:WaitForChild(COUNTDOWN_GUI_NAME)
bindCountdownGui(countdownGui)

-- covers the whole top-level gui getting recreated — same catch-all as
-- the elements loop above, just for this one instance
playerGui.ChildAdded:Connect(function(child)
	if child.Name == COUNTDOWN_GUI_NAME and child ~= countdownGui then
		countdownGui = child
		bindCountdownGui(countdownGui)
	end
end)

WS:GetAttributeChangedSignal("CollapseCountdown"):Connect(function()
	local n = WS:GetAttribute("CollapseCountdown")
	if n then
		onCountdownTick(n)
	else
		-- countdown ended one way or another — collapse fired (BallManager
		-- owns that whole cinematic separately) or the overflow recovered
		-- on its own. Either way, fade out rather than snap invisible.
		hideCountdown()
	end
end)

-- ── mode switching (Q) ──────────────────────────────────────────────

-- Drives the aside's flash: tweens the shared Color3Value from
-- flashColor down to grey on the same timing as the main label's own
-- COLOR_FLASH_TWEEN, and re-renders the label every frame so the
-- embedded RichText hex actually tracks the tween instead of jumping
-- straight from one fixed color to the other.
local function stopAsideFlash()
	if asideFlashConn then
		asideFlashConn:Disconnect()
		asideFlashConn = nil
	end
	cancelTween(tweens, "asideFlash")
	asideColorValue.Value = ASIDE_GRAY
end

local function startAsideFlash(flashColor)
	stopAsideFlash()
	asideColorValue.Value = flashColor
	asideFlashConn = RunService.Heartbeat:Connect(function()
		ballCountEl.refreshText()
	end)
	playTween(tweens, "asideFlash", asideColorValue, COLOR_FLASH_TWEEN, { Value = ASIDE_GRAY }, function()
		stopAsideFlash()
		ballCountEl.refreshText()
	end)
end

local function cycleMode()
	modeIndex = (modeIndex % #MODES) + 1

	local inst = ballCountEl.instance
	if not inst then return end

	local isShown = ballCountEl.shown

	ballCountEl.cancelPositionTween()
	cancelTween(tweens, "color")
	stopAsideFlash()

	local pos = inst.Position
	if isShown then
		inst.Position = UDim2.new(pos.X.Scale, pos.X.Offset, MODE_SWITCH_BUMP_Y, pos.Y.Offset) -- instant, no tween
	end
	ballCountEl.refreshText() -- swap to the new mode's text right away

	if MODES[modeIndex].name == "queueCount" then
		-- Queue's bounce/flash is a mode-switch animation only.
		-- QueueCount updates refresh the text but must not replay it.
		startAsideFlash(QUEUE_ASIDE_FLASH)
	elseif MODES[modeIndex].name == "ballCount" then
		startAsideFlash(MAX_ASIDE_FLASH)
	end
	inst.TextColor3 = MODES[modeIndex].color -- flash the mode's color instantly

	-- switching into serverAge while it's frozen: don't play the normal
	-- flash-then-fade-to-white animation at all — it's already frozen
	-- magenta, so easing to white just to get snapped back to magenta a
	-- half-second later is a pointless flicker. Preempt it and hold
	-- solid magenta instead.
	if MODES[modeIndex].name == "serverAge" and ageState == "frozen" then
		inst.TextColor3 = COLLAPSE_MAGENTA
	else
		playTween(tweens, "color", inst, COLOR_FLASH_TWEEN, { TextColor3 = WHITE }, function()
			applyServerAgeColorIfActive() -- re-asserts magenta if serverAge went frozen mid-fade; no-op otherwise
		end)
	end

	if isShown then
		ballCountEl.playPositionTween(MODE_SWITCH_EASE, {
			Position = UDim2.new(pos.X.Scale, pos.X.Offset, 0, pos.Y.Offset),
		})
	end
end

UIS.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
		cycleMode()
	end
end)