--[[
    SellService (ModuleScript)
    Path: ServerScriptService
    Parent: ServerScriptService
    Exported: 2026-09-20 20:00:08
]]
--[[
	SellService (ModuleScript) — ServerScriptService, sibling of
	SellHandler and BallManager

	Shared sell logic used by both SellHandler (player-initiated sells,
	via SellRequest) and BallManager (auto-sell when the orb cap is
	hit).

	sellBoxWithHighlight is the bulk-sell counterpart to
	sellWithHighlight, called by SellHandler for a SellBoxRequest (a
	player's click-drag box-select over the board — see SellClient) once
	it's already filtered the array down to real, currently-live, plain
	balls. Same overall shape as a single sell — pay out, broadcast a
	chat line, fade in a highlight for everyone but the seller, then
	destroy — just batched: one combined payout, one combined chat line,
	and every ball's highlight/destroy happens in parallel rather than
	one at a time, so a big selection doesn't take PRE_SELL_DELAY-per-
	ball to resolve. That chat line is actually three-way, not one fixed
	string — see below — since a selection can land on exactly the same
	edge case a single sell does: "bulk sold some orbs for $total" for a
	genuine multi-ball selection, but a selection that only ever caught
	one ball reuses sellWithHighlight's own single-sell wording verbatim
	rather than reading as a one-item bulk sell, and onlyBall reuses that
	exact message too, for the same reason. Deliberately narrower in
	scope than sellWithHighlight otherwise though: no bomb/magnet path,
	and no radiant path either — SellHandler never lets a bomb, a
	magnet, or a radiant ball reach this function in the first place
	(see its header, specifically SellBoxRequest's IsRadiant check) — so
	unlike sellWithHighlight's own single-sell branch, nothing here ever
	needs to check IsRadiant or apply RADIANT_SELL_MULTIPLIER; every ball
	this function ever sees sells at the same flat rate. onlyBall runs
	through the same shared isWorthlessOnlyBall sellWithHighlight uses,
	but only its live-board count is evaluated up front for the whole
	batch — the size half of that rule is per ball, so the flag is
	latched inside the claim loop rather than computed before it.

	stashAbsorb is the odd one out among the absorb functions here: it
	runs the same claim/chat/highlight/flash/destroy beat petMimicAbsorb
	does, but pays out nothing at all. A stashed ball hasn't been sold,
	it's been pocketed by the player who owns the stash upgrade (see
	StashHandler/StashData) — the money happens later, if and when they
	deploy it again and somebody sells it properly. It lives here rather
	than in StashHandler purely so the highlight/flash/sound/chat shape of
	"a ball leaves the board" is described in one module, the same reason
	mimicAbsorb and petMimicAbsorb do.

	Also owns bribeAnnounce, the chat/log lines ShopHandler fires off on
	a successful bribe purchase (see UpgradeData/ShopHandler/BallManager
	for the rest of that feature) — grouped in here rather than in
	ShopHandler itself since every other "system talks in chat" moment
	(the collapse alert/penalty/quip lines below) already lives in this
	module, sharing its styleMessage/LOG_CHANNEL/magenta conventions.
]]

local Players = game:GetService("Players")
local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local TS = game:GetService("TweenService")
local RS = game:GetService("RunService")
local BadgeService = game:GetService("BadgeService")

local se = Rep:WaitForChild("SoundEvents")
local sellBroadcast = Rep:WaitForChild("SellBroadcast")

local PRE_SELL_DELAY = 0.3

local bf = WS:WaitForChild("Balls")
local ballT = Rep:WaitForChild("Ball")
local bombT = Rep:WaitForChild("Bomb")
local magnetT = Rep:WaitForChild("Magnet")

local SELL_SND_ID, SELL_VOL = "rbxassetid://139583503249540", 1

-- ── stash absorb (see SellService.stashAbsorb) ───────────────────────
-- Its own cue, deliberately NOT SELL_SND_ID: a stash pays nothing, and
-- reusing the sell sound made pocketing a ball read as selling it. This
-- id is a PLACEHOLDER — it's a real, already-in-use sound in this project
-- (the mimic revert cue) purely so the wiring is audibly testable; swap
-- it for the real thing, same as COLLAPSE_MSG_SND_ID below is waiting to
-- be swapped.
local STASH_SND_ID = "rbxassetid://12222054"
local STASH_VOL = 0.6
local STASH_PITCH = 1.3

-- A stash absorb runs at DOUBLE the speed of every other absorb in this
-- module, so it gets its own delay rather than sharing PRE_SELL_DELAY:
-- a sell's 0.3s fade is a deliberate "everyone else gets a beat to see
-- this leaving" warning, and a stash has nothing to warn anyone about —
-- it's the player's own instant action on a ball nobody's being paid
-- for. MUST stay equal to StashHandler's own PULL_TIME, which drives the
-- fly-into-the-player animation this fades in over — same hand-kept
-- relationship PetMimicFuse's PET_ABSORB_TIME has to PRE_SELL_DELAY.
local STASH_ABSORB_DELAY = 0.15

-- Fixed, NOT the absorbed ball's own size — unlike every other flash in
-- this file, which scales with what was sold. A stash flash is feedback
-- on an input landing, not a readout of what left the board, so a
-- size-400 ball shouldn't white out the screen while a size-3 one barely
-- registers. Passed to SellClient's flash in place of `size`, where it's
-- multiplied by SELL_FLASH_SCALE like any other flash — so this number
-- is in the same "studs of ball" units the others use, and 6 reads as a
-- slightly-bigger-than-average pop. Shared by both ends of the feature,
-- so a ball leaves and returns at exactly the same visual weight.
local STASH_FLASH_SIZE = 6

-- How long a deployed ball's cyan glow takes to fade off it (see
-- SellService.stashDeploy). Matched by hand to BallManager's GROW_TWEEN,
-- the ordinary spawn grow a deployed ball now uses like any other — so
-- the glow is gone at about the moment the ball reaches full size, and
-- the fade and the swell read as one movement rather than two that
-- happen to overlap. A ball at or under GROW_AT never plays that tween
-- at all; the glow still fades over the same window, which is what keeps
-- a deploy recognisable at every size.
local STASH_DEPLOY_GLOW_TIME = 0.6

-- Kinds whose own appearance is built out of a Highlight, so a deploy
-- must not add one of its own — see SellService.stashDeploy. Keyed by
-- the same kind names BallManager's SPECIAL_KINDS uses, which is what
-- processQueue passes through.
local HIGHLIGHT_IS_LOAD_BEARING = {
	splitter = true,
	merger = true,
}

local DEFUSE_SND_ID = "rbxassetid://12222084"
local DEFUSE_VOL = 0.7
local DEFUSE_PITCH = 1.15

local COLLAPSE_SND_ID = "rbxassetid://12222170"

-- plays on every client whenever one of the 3 collapse chat lines
-- (alert / penalty / quip) fires — id is a placeholder, fill in later
local COLLAPSE_MSG_SND_ID = "rbxassetid://135083591486620"
local COLLAPSE_MSG_VOL = 1

local SYS_MSG_COLOR = "#cccccc"
local SYS_MSG_SIZE = 14
local AMOUNT_COLOR = "#FFFF00"
local AUTO_AMOUNT_COLOR = "#00FFFF"
local PENALTY_AMOUNT_COLOR = "#FF00FF"

local FLASH_COLOR = Color3.fromRGB(255, 255, 0)
local AUTO_FLASH_COLOR = Color3.fromRGB(0, 255, 255)

local COLLAPSE_FLASH_COLOR = Color3.fromRGB(255, 0, 255)

local DEFUSER_AMOUNT_COLOR = "#FF0000"
local DEFUSER_FLASH_COLOR = Color3.fromRGB(255, 0, 0)

-- fallback only — see radiantColor below. Every radiant variant's real
-- sell color is read live off the ball itself (rainbow), not this fixed
-- white; this only ever fires if a radiant bomb somehow reaches a sale
-- without its RadiantFlashColor attribute set yet. Keep in sync with
-- SellClient's own RADIANT_FLASH_COLOR.
local RADIANT_FLASH_COLOR = Color3.fromRGB(255, 255, 255)

local BOMB_SELL_MULTIPLIER = 2
local RADIANT_SELL_MULTIPLIER = 3
local RADIANT_BOMB_SELL_MULTIPLIER = 6
local MAGNET_SELL_MULTIPLIER = 2
local RADIANT_MAGNET_SELL_MULTIPLIER = 6

-- The "last orb on the board isn't worth anything" rule is size-gated:
-- it only applies to an orb THIS SIZE OR SMALLER. A last orb bigger
-- than this sells for its ordinary value (radiant multiplier included)
-- and reads as an ordinary sale everywhere — payout, chat line, and the
-- client's own "$" price label alike.
--
-- The rule exists to stop the last orb being flipped for free money on
-- a board that just respawns one behind it (see BallManager's
-- ensureBall), not to strand someone who grew a genuinely valuable orb
-- and happens to be the last one holding it. 5 is the Ball template's
-- own base size, so this reads as "a last orb that never grew past
-- spawn size". Its <= (not <) is what keeps a stock size-5 orb free.
--
-- SellClient keeps its own copy of this number for the price label it
-- shows before the click — keep the two in sync by hand, same as
-- BOMB_SELL_MULTIPLIER and the rest above.
local ONLY_BALL_FREE_MAX_SIZE = 5

local MIMIC_AMOUNT_COLOR = "#FF00FF"
local MIMIC_FLASH_COLOR = Color3.fromRGB(255, 0, 255)

local MIMIC_SELL_FRACTION = 0.5

-- was a flat $1000 — now a fraction so the hit scales with (and stays
-- fair relative to) each player's own balance instead of landing the
-- same on a broke player as a rich one
local COLLAPSE_PENALTY_FRACTION = 0.1

-- a player who's ONLY just gone AFK still gets hit by the penalty —
-- this exists for the player who's been genuinely away for a while,
-- not as a way to dodge an incoming collapse by toggling AFK the
-- instant one starts. Compared against AFKHandler's "AFKSince"
-- attribute (os.time() of the toggle-on), which is the only reason
-- that attribute exists.
local AFK_PENALTY_GRACE = 10

-- collapse chat plays as 3 separate lines: an alert line (fired via
-- SellService.collapseAlert, right as the collapse itself begins — see
-- BallManager.triggerCollapse), then a consequence line and a quip
-- (both fired from applyCollapsePenalty once the penalty actually
-- lands). The consequence line fires immediately when the penalty
-- hits; the quip follows after a randomized 2-3 second beat so it
-- doesn't always land at the exact same cadence. Each of the 3 lines
-- also plays a short client-side ping (COLLAPSE_MSG_SND_ID) the moment
-- it's broadcast. The alert and consequence lines each have a small
-- pool of rewordings (picked at random per-collapse) just so the
-- phrasing doesn't get stale; the quip pool below is much bigger since
-- it's pure flavor and the one most likely to repeat for
-- frequent-offender servers.
local COLLAPSE_ALERT_LINES = {
	"critical mass has been detected, wiping the board ...",
	"imminent pillar collapse has been detected, wiping the board ...",
	"perpetual motion has been detected, wiping the board ...",
}

-- %d%% gets filled in with COLLAPSE_PENALTY_FRACTION * 100
local COLLAPSE_PENALTY_LINES = {
	"everyones getting hit with a %d%% fine for that (sorry)",
	"i gotta take %d%% of everyones money as compensation",
	"our policy says i have to take %d%% of everyones balances",
	"deducting %d%% from everyones balances (sorry)",
	"everyones getting hit with a %d%% fine for that (sorry)",
	"i gotta take %d%% of everyones money as compensation",
	"our policy says i have to take %d%% of everyones balances",
	"deducting %d%% from everyones balances (sorry)",
	"everyones getting hit with a %d%% fine for that (sorry)",
	"i gotta take %d%% of everyones money as compensation",
	"our policy says i have to take %d%% of everyones balances",
	"deducting %d%% from everyones balances (sorry)",
	"deducting %d%% from everyones balances (i'm probably gonna pocket like 3/4ths of this)", -- easter egg
}

-- third chat line for a collapse-penalty is picked at random from
-- here each time, purely for flavor — fill this in with more if you
-- want a bigger pool
local COLLAPSE_QUIPS = {
	"try to keep that ball queue below 150 pls",
	"dont do that again . im watching u",
	"i kow it sucks but last time we let the queue pile up someone made trillions ...",
	"don't worry, ur not the first and wont be the last",
	"id listen to the little voice in the queue counter if i were u",
	"you can press T to cycle through counters at the top if that helps",
	"consider buying the defuser to prevent bombs from detonating",
	"consider buying the defuser to prevent magnets from activating",
	"consider buying the ... nevermind u just cant sell splitter orbs",
	"consider buying the ... nevermind u just cant sell merger orbs",
	"assuming this is your first collapse,, enjoy your new badge !! (dont do that again)",
	"i do accept bribes if u want me to go away for a bit (shhhhhh)",
	"radiant orbs pay out triple if that makes selling more appealing ?",
	"u can make that money back ... probably",
}

local LOG_CHANNEL = "Logs"

local function styleMessage(text)
	return string.format(
		'<font color="%s" size="%d">%s</font>',
		SYS_MSG_COLOR,
		SYS_MSG_SIZE,
		text
	)
end

local function styleAmount(amount, color)
	return string.format(
		'<font color="%s"><b>$%d</b></font>',
		color,
		amount
	)
end

local function fireExceptSeller(player, ...)
	if player then
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= player then
				se:FireClient(p, ...)
			end
		end
	else
		se:FireAllClients(...)
	end
end

-- "sold an orb worth at least this much" milestones. Both tiers are
-- about ONE orb's own payout, never a running or combined figure — a
-- $100 sale clears both, since 100 >= 50 too.
local SELL_BADGES = {
	{ threshold = 50, badgeId = 4491513065757921 },
	{ threshold = 100, badgeId = 3248473547490503 },
}

-- `amount` MUST be a single ball's payout, not a sum of several. Every
-- caller is responsible for that: sellWithHighlight passes its one
-- ball's own amount, and sellBoxWithHighlight passes the biggest single
-- amount in the batch rather than the batch total (see the comment at
-- its own call site for why that's equivalent to checking each ball).
local function checkSellBadges(amount)
	for _, tier in ipairs(SELL_BADGES) do
		if amount >= tier.threshold then
			for _, p in ipairs(Players:GetPlayers()) do
				task.spawn(function()
					local ok, hasBadge = pcall(
						BadgeService.UserHasBadgeAsync,
						BadgeService,
						p.UserId,
						tier.badgeId
					)

					if ok and not hasBadge then
						pcall(
							BadgeService.AwardBadgeAsync,
							BadgeService,
							p.UserId,
							tier.badgeId
						)
					end
				end)
			end
		end
	end
end

-- shared by every payout site below (a manual/auto sell, a mimic
-- absorb, a pet-mimic absorb) — every ball sale pays out to the whole
-- server the same way, so this is the one place that decides who gets
-- how much. A player currently flagged AFK (see AFKHandler) only
-- earns half of whatever everyone else gets, rounded down per-player
-- rather than rounding the shared `amount` once and handing that same
-- reduced figure to everyone — an AFK player's cut shouldn't affect
-- what active players are paid.
local AFK_PAYOUT_FRACTION = 0.5

local function distributePayout(amount)
	if amount <= 0 then return end

	for _, p in ipairs(Players:GetPlayers()) do
		local leaderstats = p:FindFirstChild("leaderstats")
		local cash = leaderstats and leaderstats:FindFirstChild("$$$")

		if cash then
			local payout = amount
			if p:GetAttribute("AFK") then
				payout = math.floor(amount * AFK_PAYOUT_FRACTION)
			end
			cash.Value += payout
		end
	end
end

-- The rainbow sell color for any radiant variant, read live off the ball
-- itself rather than a fixed constant — a radiant ball/magnet's own
-- Color IS its rainbow loop color at any given moment (magnet included:
-- once pulling starts its idle loop freezes rather than stopping cold,
-- so Color still holds a valid hue), so this just copies it straight.
-- A radiant bomb is the one exception: bomb.Color itself spends roughly
-- half its time on the flat OFF navy between flicker ticks (see
-- RadiantBombFuse), so this reads RadiantFlashColor instead — an
-- attribute RadiantBombFuse keeps mirrored to its flash tick's own
-- rainbow hue specifically so this doesn't have to guess which tick a
-- bomb happens to be sold on. RADIANT_FLASH_COLOR is only ever a
-- fallback for the (should-never-happen) case that attribute isn't set.
local function radiantColor(ball, isBomb)
	if isBomb then
		return ball:GetAttribute("RadiantFlashColor") or RADIANT_FLASH_COLOR
	end
	return ball.Color
end

-- The one place the "worthless last orb" rule is actually decided, so a
-- single sell and a bulk sell can't drift apart on it (they already
-- drifted apart on the sell badges once — see checkSellBadges). Both
-- halves have to hold: it's the only orb left in play AND it never grew
-- past ONLY_BALL_FREE_MAX_SIZE. Callers pass their own already-counted
-- liveBalls rather than having this re-walk the folder, since both of
-- them need that count for other things anyway.
local function isWorthlessOnlyBall(liveBalls, size)
	return liveBalls <= 1 and size <= ONLY_BALL_FREE_MAX_SIZE
end

local SellService = {}

function SellService.sellWithHighlight(ball, player)
	if ball:GetAttribute("PendingSell") then return end
	ball:SetAttribute("PendingSell", true)

	local size = ball:GetAttribute("TargetSize") or ball.Size.X

	local isBomb = ball.Name == bombT.Name
	local isMagnet = ball.Name == magnetT.Name
	-- Radiant is an overlay (IsRadiant attribute set by BallManager),
	-- not its own template, for a plain ball OR a special one now — see
	-- BallManager's own header. For a plain ball this is folded into
	-- the same liveBalls/onlyBall/badge treatment it already gets below,
	-- diverging only in the payout multiplier (and the flavor text). A
	-- radiant bomb/magnet/etc. instead gets its own dedicated multiplier
	-- right in that kind's own branch below (see RADIANT_BOMB_SELL_MULTIPLIER).
	local isRadiant = ball:GetAttribute("IsRadiant") == true

	local liveBalls = 0

	if not isBomb and not isMagnet then
		for _, obj in ipairs(bf:GetChildren()) do
			if obj.Name == ballT.Name and not obj:GetAttribute("Split") then
				liveBalls += 1
			end
		end
	end

	-- Still named onlyBall, and still the flag every branch below keys
	-- off, but it now means "the last orb AND too small to be worth
	-- anything" rather than just "the last orb" — see
	-- isWorthlessOnlyBall/ONLY_BALL_FREE_MAX_SIZE. A last orb bigger
	-- than that gate leaves this false and so falls through to the
	-- ordinary payout and the ordinary "sold an orb" wording below,
	-- which is exactly the intent: nothing extra to special-case.
	local onlyBall = not isBomb and not isMagnet and isWorthlessOnlyBall(liveBalls, size)

	local amount

	if isBomb then
		amount = math.round(size * (isRadiant and RADIANT_BOMB_SELL_MULTIPLIER or BOMB_SELL_MULTIPLIER))
	elseif isMagnet then
		amount = math.round(size * (isRadiant and RADIANT_MAGNET_SELL_MULTIPLIER or MAGNET_SELL_MULTIPLIER))
	elseif onlyBall then
		amount = 0
	else
		amount = math.round(size * (isRadiant and RADIANT_SELL_MULTIPLIER or 1))
	end

	-- Player-initiated, non-bomb, non-magnet sales only. Radiant now
	-- counts toward badges same as any other ball sale — it's just a
	-- variant, not a separately-excluded kind.
	if player and not isBomb and not isMagnet then
		checkSellBadges(amount)
	end

	local pos = ball.Position

	-- A radiant ball/bomb/magnet flashes/highlights with its own live
	-- rainbow color (see radiantColor above), taking priority over
	-- DEFUSER_FLASH_COLOR for a radiant bomb/magnet — but only for a
	-- player-initiated sell. The ball-cap overflow auto-sell (this
	-- function called with player == nil — see enforceBallCap in
	-- BallManager) only ever targets a plain ball, never a bomb/magnet,
	-- and is specifically meant to read as a cyan "this got auto-sold"
	-- cue regardless of what got caught by it — radiant included — so
	-- that case still falls through to AUTO_FLASH_COLOR below untouched
	-- rather than getting overridden into rainbow.
	local color
	if isRadiant and player then
		color = radiantColor(ball, isBomb)
	elseif isBomb or isMagnet then
		color = DEFUSER_FLASH_COLOR
	else
		color = player and FLASH_COLOR or AUTO_FLASH_COLOR
	end

	ball:SetAttribute("Sold", true)

	distributePayout(amount)

	local message

	if isBomb then
		message = string.format(
			isRadiant and "<b>%s (@%s)</b> defused a <b>radiant</b> bomb for %s" or "<b>%s (@%s)</b> defused a bomb for %s",
			player.DisplayName,
			player.Name,
			styleAmount(amount, DEFUSER_AMOUNT_COLOR)
		)

	elseif isMagnet then
		message = string.format(
			isRadiant and "<b>%s (@%s)</b> degaussed a <b>radiant</b> magnet for %s" or "<b>%s (@%s)</b> degaussed a magnet for %s",
			player.DisplayName,
			player.Name,
			styleAmount(amount, DEFUSER_AMOUNT_COLOR)
		)

	elseif onlyBall then
		message = player
			and string.format(
				"<b>%s (@%s)</b> tried to sell the only orb, but it wasn't worth anything...",
				player.DisplayName,
				player.Name
			)
			or "the last orb was auto-sold, but it wasn't worth anything..."

	elseif player then
		message = isRadiant
			and string.format(
				"<b>%s (@%s)</b> sold a <b>radiant</b> orb for %s",
				player.DisplayName,
				player.Name,
				styleAmount(amount, AMOUNT_COLOR)
			)
			or string.format(
				"<b>%s (@%s)</b> sold an orb for %s",
				player.DisplayName,
				player.Name,
				styleAmount(amount, AMOUNT_COLOR)
			)

	else
		message = isRadiant
			and string.format(
				"<b>max orbs reached !!!</b> smallest orb was <b>radiant</b> and auto-sold for %s",
				styleAmount(amount, AUTO_AMOUNT_COLOR)
			)
			or string.format(
				"<b>max orbs reached !!!</b> smallest orb was auto-sold for %s",
				styleAmount(amount, AUTO_AMOUNT_COLOR)
			)
	end

	sellBroadcast:FireAllClients(
		styleMessage(message),
		LOG_CHANNEL
	)

	local highlight = Instance.new("Highlight")
	highlight.FillColor = color
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = ball

	-- keeps the pre-sell fade-in tracking the ball's own live rainbow
	-- for the radiant case instead of freezing on whatever hue `color`
	-- happened to be at the instant the sale started — same live source
	-- radiantColor already reads from (ball.Color, or RadiantFlashColor
	-- for a bomb), just re-sampled every frame for the length of the
	-- fade rather than once up front.
	local colorConn
	if isRadiant and player then
		colorConn = RS.Heartbeat:Connect(function()
			highlight.FillColor = radiantColor(ball, isBomb)
		end)
	end

	TS:Create(
		highlight,
		TweenInfo.new(
			PRE_SELL_DELAY,
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out
		),
		{
			FillTransparency = 0,
		}
	):Play()

	task.wait(PRE_SELL_DELAY)

	if colorConn then colorConn:Disconnect() end

	-- one last re-sample right before the ball goes away, so the flash
	-- everyone else sees (fireExceptSeller below) reflects the hue this
	-- radiant ball is actually on at the moment it's destroyed, not
	-- whatever `color` was still holding from back when the sale started
	if isRadiant and player then
		color = radiantColor(ball, isBomb)
	end

	highlight:Destroy()
	ball:Destroy()

	fireExceptSeller(
		player,
		"positional",
		pos,
		SELL_SND_ID,
		SELL_VOL
	)

	if isBomb then
		fireExceptSeller(
			player,
			"positional",
			pos,
			DEFUSE_SND_ID,
			DEFUSE_VOL,
			DEFUSE_PITCH
		)
	end

	fireExceptSeller(
		player,
		"sellFlash",
		pos,
		size,
		color
	)
end

-- see this file's header for the overall shape/reasoning. `balls` is
-- SellHandler's already-filtered array (real, currently-live, plain
-- balls only, capped at MAX_BOX_SELL) — re-checked once more here
-- anyway (Parent/Name/PendingSell) since PendingSell is claimed
-- per-ball synchronously in the loop below, same never-trust-what-was-
-- true-a-moment-ago reasoning sellWithHighlight applies to its own
-- single target.
function SellService.sellBoxWithHighlight(balls, player)
	local liveBalls = 0
	for _, obj in ipairs(bf:GetChildren()) do
		if obj.Name == ballT.Name and not obj:GetAttribute("Split") then
			liveBalls += 1
		end
	end
	-- Same "the only orb in play pays nothing" rule sellWithHighlight
	-- enforces, via the same shared isWorthlessOnlyBall — but only its
	-- liveBalls half can be settled up front like this. The other half
	-- is that orb's own size, which is read per entry in the claim loop
	-- below, so this starts false and is set there if the rule actually
	-- lands. That can only ever happen for a single entry: a box select
	-- can only contain currently-live orbs, so liveBalls <= 1 means the
	-- selection amounts to that one remaining orb anyway.
	local onlyBall = false

	-- claim every ball synchronously, all in one pass with no yields in
	-- between, so two overlapping box-sells (or a box-sell racing a
	-- single-ball SellRequest, or the ball-cap auto-sell) can't both
	-- grab the same ball — mirrors the single PendingSell claim
	-- sellWithHighlight makes, just for the whole array at once
	local sold = {} -- array of { ball, size, amount, pos }
	local total = 0

	for _, ball in ipairs(balls) do
		if ball.Parent == bf and ball.Name == ballT.Name and not ball:GetAttribute("PendingSell") then
			ball:SetAttribute("PendingSell", true)

			-- no IsRadiant check/multiplier here — SellHandler already
			-- filtered every radiant ball out of `balls` before this ever
			-- ran (see this function's own header), so every ball reaching
			-- this point sells at the flat rate regardless of size alone
			local size = ball:GetAttribute("TargetSize") or ball.Size.X

			-- the per-entry half of the only-orb rule (see the onlyBall
			-- declaration above). Latched onto the batch-level flag so the
			-- message block further down still reads one boolean; a last
			-- orb bigger than the gate leaves it false and so gets the
			-- ordinary "sold an orb for $x" line via the #sold == 1 branch.
			local worthless = isWorthlessOnlyBall(liveBalls, size)
			if worthless then
				onlyBall = true
			end

			local amount = worthless and 0 or math.round(size)

			sold[#sold + 1] = {
				ball = ball,
				size = size,
				amount = amount,
				pos = ball.Position, -- captured now, same as sellWithHighlight's own `pos` — read once up front rather than after Destroy, which is the whole reason a captured var exists at all
			}
			total += amount
		end
	end

	if #sold == 0 then return end

	for _, entry in ipairs(sold) do
		entry.ball:SetAttribute("Sold", true)
	end

	distributePayout(total)

	-- player-initiated, plain-ball sales only — exact same condition
	-- sellWithHighlight gates its own checkSellBadges call on, just
	-- unconditionally true here since this function never sees a
	-- bomb/magnet at all.
	--
	-- The BIGGEST single ball in the batch, NOT `total`: SELL_BADGES'
	-- tiers are per-orb milestones ("sell one orb worth $50/$100" — see
	-- there), and passing the combined payout handed both badges to
	-- anyone who box-selected enough small orbs to add up to a
	-- threshold, which is the bug this replaced. Since every tier is a
	-- plain `amount >= threshold` test, the largest amount in the batch
	-- clearing a tier is exactly equivalent to testing every ball
	-- against it individually — one call, rather than N redundant
	-- UserHasBadgeAsync sweeps over the whole server for a single big
	-- selection. `sold` (not `balls`) for the same reason every other
	-- line down here reads off it: it's the set that actually got
	-- claimed and paid out. onlyBall needs no special case — it already
	-- zeroed every entry's amount above, so nothing clears a threshold.
	if player then
		local largest = 0
		for _, entry in ipairs(sold) do
			if entry.amount > largest then
				largest = entry.amount
			end
		end

		checkSellBadges(largest)
	end

	-- one combined line for the whole batch rather than N "sold an orb"
	-- lines — except for onlyBall, which reuses sellWithHighlight's exact
	-- wording rather than reading as a batch: a box selection can only
	-- hit this case by amounting to the one ball left in play (the same
	-- ball a plain click on it would've hit this same rule for), so the
	-- message should read identically either way rather than
	-- differentiating "sold a bunch of orbs for $0" from a plain sell of
	-- that same single, worthless ball
	local message

	if onlyBall then
		message = string.format(
			"<b>%s (@%s)</b> tried to sell the only orb, but it wasn't worth anything...",
			player.DisplayName,
			player.Name
		)
	elseif #sold == 1 then
		-- a box selection that only ever caught one ball reads exactly
		-- like a plain click on that same ball would, rather than as a
		-- one-item "bulk sold" — always the plain wording here, never the
		-- radiant one, since a radiant ball can never reach this function
		-- (see this function's own header) to be that one ball
		message = string.format(
			"<b>%s (@%s)</b> sold an orb for %s",
			player.DisplayName,
			player.Name,
			styleAmount(total, AMOUNT_COLOR)
		)
	else
		message = string.format(
			"<b>%s (@%s)</b> bulk sold some orbs for %s",
			player.DisplayName,
			player.Name,
			styleAmount(total, AMOUNT_COLOR)
		)
	end

	sellBroadcast:FireAllClients(
		styleMessage(message),
		LOG_CHANNEL
	)

	-- every ball's highlight starts tweening in parallel, not one after
	-- another — a single shared task.wait(PRE_SELL_DELAY) below covers
	-- the whole batch, rather than this taking PRE_SELL_DELAY-per-ball
	-- to resolve for a big selection
	for _, entry in ipairs(sold) do
		local highlight = Instance.new("Highlight")
		highlight.FillColor = FLASH_COLOR
		highlight.FillTransparency = 1
		highlight.OutlineTransparency = 1
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Parent = entry.ball
		entry.highlight = highlight

		TS:Create(
			highlight,
			TweenInfo.new(
				PRE_SELL_DELAY,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out
			),
			{
				FillTransparency = 0,
			}
		):Play()
	end

	task.wait(PRE_SELL_DELAY)

	for _, entry in ipairs(sold) do
		entry.highlight:Destroy()
		entry.ball:Destroy()

		-- per-ball flash so the batch still visually reads as N separate
		-- sells resolving at once, matching what the seller's own client
		-- already predicted for each one (see SellClient)
		fireExceptSeller(
			player,
			"sellFlash",
			entry.pos,
			entry.size,
			FLASH_COLOR
		)
	end

	-- one shared sell sound for the whole batch rather than one per
	-- ball — a big selection firing N overlapping copies of the same
	-- clip would just read as noise, not N confirmations. Positioned at
	-- the selection's centroid rather than any single ball's spot, same
	-- "anchored to a last-known position, not a real Instance" shape
	-- localSellSound/the positional sound elsewhere in this file already
	-- use.
	local sumPos = Vector3.new()
	for _, entry in ipairs(sold) do
		sumPos += entry.pos
	end

	fireExceptSeller(
		player,
		"positional",
		sumPos / #sold,
		SELL_SND_ID,
		SELL_VOL
	)
end

function SellService.collapseSell(obj)
	local size = obj:GetAttribute("TargetSize") or 0
	local pos = obj.Position

	obj:SetAttribute("Sold", true)

	local highlight = Instance.new("Highlight")
	highlight.FillColor = COLLAPSE_FLASH_COLOR
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = obj

	TS:Create(
		highlight,
		TweenInfo.new(
			PRE_SELL_DELAY,
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out
		),
		{
			FillTransparency = 0,
		}
	):Play()

	task.wait(PRE_SELL_DELAY)

	highlight:Destroy()

	se:FireAllClients(
		"attachedFlash",
		obj,
		size,
		COLLAPSE_FLASH_COLOR
	)

	obj:Destroy()

	se:FireAllClients(
		"positional",
		pos,
		COLLAPSE_SND_ID,
		SELL_VOL
	)
end

function SellService.mimicAbsorb(ball)
	if ball:GetAttribute("PendingSell") then return end
	ball:SetAttribute("PendingSell", true)

	local size = ball:GetAttribute("TargetSize") or ball.Size.X
	local amount = math.ceil(size * MIMIC_SELL_FRACTION)
	local pos = ball.Position

	ball:SetAttribute("Sold", true)

	distributePayout(amount)

	local message = string.format(
		"a <b>mimic</b> ate an orb and sold it for %s",
		styleAmount(amount, MIMIC_AMOUNT_COLOR)
	)

	sellBroadcast:FireAllClients(
		styleMessage(message),
		LOG_CHANNEL
	)

	local highlight = Instance.new("Highlight")
	highlight.FillColor = MIMIC_FLASH_COLOR
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = ball

	TS:Create(
		highlight,
		TweenInfo.new(
			PRE_SELL_DELAY,
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out
		),
		{
			FillTransparency = 0,
		}
	):Play()

	task.wait(PRE_SELL_DELAY)

	highlight:Destroy()

	se:FireAllClients(
		"attachedFlash",
		ball,
		size,
		MIMIC_FLASH_COLOR
	)

	ball:Destroy()

	se:FireAllClients(
		"positional",
		pos,
		SELL_SND_ID,
		SELL_VOL
	)
end

local DEFAULT_PET_NAME = "<3"

function SellService.petMimicAbsorb(ball, ownerId)
	if ball:GetAttribute("PendingSell") then return end
	ball:SetAttribute("PendingSell", true)

	local size = ball:GetAttribute("TargetSize") or ball.Size.X
	local amount = math.round(size)

	ball:SetAttribute("Sold", true)

	distributePayout(amount)

	local ownerPlayer = Players:GetPlayerByUserId(ownerId)
	local ownerName = ownerPlayer and ownerPlayer.Name

	local petMimicConfig =
		ownerPlayer and ownerPlayer:FindFirstChild("PetMimicConfig")

	local petNameValue =
		petMimicConfig and petMimicConfig:FindFirstChild("PetName")

	local displayName =
		(petNameValue and petNameValue.Value)
		or DEFAULT_PET_NAME

	local message

	if ownerName then
		message = string.format(
			"<b>%s (@%s's pet mimic)</b> sold an orb for %s",
			displayName,
			ownerName,
			styleAmount(amount, AUTO_AMOUNT_COLOR)
		)
	else
		message = string.format(
			"<b>a stray pet mimic</b> sold an orb for %s (we have no idea how this happened)",
			styleAmount(amount, AUTO_AMOUNT_COLOR)
		)
	end

	sellBroadcast:FireAllClients(
		styleMessage(message),
		LOG_CHANNEL
	)

	local highlight = Instance.new("Highlight")
	highlight.FillColor = AUTO_FLASH_COLOR
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = ball

	TS:Create(
		highlight,
		TweenInfo.new(
			PRE_SELL_DELAY,
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out
		),
		{
			FillTransparency = 0,
		}
	):Play()

	task.wait(PRE_SELL_DELAY)

	highlight:Destroy()

	se:FireAllClients(
		"attachedFlash",
		ball,
		size,
		AUTO_FLASH_COLOR
	)

	local pos = ball.Position

	ball:Destroy()

	se:FireAllClients(
		"positional",
		pos,
		SELL_SND_ID,
		SELL_VOL
	)
end

-- The stash's own absorb beat (see StashHandler/StashData). Shaped
-- exactly like petMimicAbsorb above — synchronous PendingSell claim,
-- chat line, cyan highlight fading in over PRE_SELL_DELAY, attachedFlash,
-- destroy, positional sound — with one deliberate omission: no
-- distributePayout call at all. A stashed ball hasn't been sold, it's
-- been pocketed; the money happens (or doesn't) whenever its owner
-- deploys it again and someone sells it properly. Nothing here calls
-- checkSellBadges either, for the same reason — a stash isn't a sale, so
-- it shouldn't count toward a sell badge.
--
-- Cyan rather than yellow for the same reason a pet mimic's catch is
-- cyan: this isn't a player-initiated SALE, it's the board losing a ball
-- to a system, and the color is what tells those two apart at a glance.
--
-- `size` is passed in rather than read off the ball, and it must be:
-- StashHandler starts shrinking this ball toward size 1 on its own
-- coroutine the same instant it calls this, so anything read from the
-- instance here is already mid-animation. `label` likewise comes from
-- StashData (which knows the splitter/merger templates; this module only
-- knows ball/bomb/magnet).
--
-- `onAbsorbed` is an optional callback fired exactly once, at the single
-- frame the flash goes off — the moment the ball visually arrives and
-- stops existing. StashHandler hangs the actual slot write off it so the
-- toolbar preview appears in step with the flash instead of the instant
-- Q was pressed, which read as the ball being in two places at once for
-- the length of the pull. It's a callback rather than a second
-- task.delay on StashHandler's side specifically so there's only ONE
-- copy of that timing: whatever this function's own pacing turns out to
-- be, the slot lands on it.
--
-- The PendingSell claim below happens before this function's first
-- yield, which is what StashHandler's own ordering depends on — see its
-- header, step 5. Don't add a yield above it.
function SellService.stashAbsorb(ball, player, label, size, onAbsorbed)
	if ball:GetAttribute("PendingSell") then return end
	ball:SetAttribute("PendingSell", true)

	size = size or ball:GetAttribute("TargetSize") or ball.Size.X

	ball:SetAttribute("Sold", true)

	local message = string.format(
		'<b>%s (@%s)</b> stashed a <font color="%s"><b>size %d</b></font> %s',
		player.DisplayName,
		player.Name,
		AUTO_AMOUNT_COLOR,
		math.round(size),
		label or "orb"
	)

	sellBroadcast:FireAllClients(
		styleMessage(message),
		LOG_CHANNEL
	)

	local highlight = Instance.new("Highlight")
	highlight.FillColor = AUTO_FLASH_COLOR
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = ball

	TS:Create(
		highlight,
		TweenInfo.new(
			STASH_ABSORB_DELAY,
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out
		),
		{
			FillTransparency = 0,
		}
	):Play()

	task.wait(STASH_ABSORB_DELAY)

	highlight:Destroy()

	-- This is the moment the ball visually arrives and stops existing, so
	-- it's the moment the slot fills — see onAbsorbed's own note above.
	-- Fired BEFORE the flash rather than after, so the preview is already
	-- there on the frame the flash covers it; pcall'd because a callback
	-- erroring here would abandon the rest of this function and leave a
	-- claimed, highlighted, undestroyed ball behind.
	if onAbsorbed then
		local ok, err = pcall(onAbsorbed)
		if not ok then
			warn("[SellService] stashAbsorb's onAbsorbed callback errored: " .. tostring(err))
		end
	end

	-- attachedFlash, not a server-computed position: this ball has been
	-- flying into its owner for the whole STASH_ABSORB_DELAY above, so each
	-- client resolves the flash against wherever IT is currently
	-- rendering the ball rather than wherever the server happened to see
	-- it. STASH_FLASH_SIZE rather than this ball's own `size` — see that
	-- constant's own comment for why this one flash is deliberately fixed.
	se:FireAllClients(
		"attachedFlash",
		ball,
		STASH_FLASH_SIZE,
		AUTO_FLASH_COLOR
	)

	local pos = ball.Position -- read after the wait, so the sound lands where it actually arrived

	ball:Destroy()

	se:FireAllClients(
		"positional",
		pos,
		STASH_SND_ID,
		STASH_VOL,
		STASH_PITCH
	)
end

-- The mirror image of stashAbsorb above, for a ball coming back OUT: the
-- same cyan, at the same fixed flash size, so pocketing a ball and
-- producing one read as two halves of one mechanic rather than two
-- unrelated effects.
--
-- Where the absorb FADES ITS HIGHLIGHT IN over the pull and then
-- destroys the ball, this starts fully opaque and fades OUT — the ball
-- launches as a solid cyan shape and resolves into its real color as it
-- rises and grows. Running the beat backwards is what makes a deploy
-- read as the absorb in reverse.
--
-- Called from processQueue rather than by StashHandler, because a deploy
-- goes through the launch queue now (see _G.QueueStashDeploy) and the
-- instance doesn't exist until the queue reaches it. That also means
-- this is the ONLY thing marking a deployed ball as deployed — it grows,
-- launches and arcs exactly like an organic spawn, which is deliberate.
--
-- "sellFlash" rather than the absorb's "attachedFlash", and this is the
-- one place that distinction matters: attachedFlash takes the ball
-- itself and each client reads its position locally, which is right for
-- a ball that's existed for a while, but this one was created a
-- moment ago and may not have replicated everywhere yet — an Instance
-- argument that hasn't arrived on a given client comes through as nil
-- and that client silently gets no flash. A plain Vector3 has nothing to
-- wait for. It's the ball's launch point either way, which is exactly
-- where the flash belongs.
--
-- No sound: a deploy already plays the ordinary spawn cue by virtue of
-- landing in the Balls folder (see bf.ChildAdded in BallManager), and
-- layering the stash cue on top of it just muddies both.
--
-- `kind` decides whether the highlight half happens at all — see
-- HIGHLIGHT_IS_LOAD_BEARING below. The flash half always does.
function SellService.stashDeploy(ball, kind)
	se:FireAllClients(
		"sellFlash",
		ball.Position,
		STASH_FLASH_SIZE,
		AUTO_FLASH_COLOR,
		true -- alwaysOnTop, matching the absorb's own flash
	)

	-- A splitter and a merger are DRAWN with a Highlight — it's not
	-- decoration on top of their appearance, it IS their appearance (see
	-- SplitterFuse/MergerFuse). Adding a second one here fights the one
	-- they own, so these two get the flash and nothing else. They still
	-- read as deployed: the flash is a separate world-space billboard
	-- that never touches the ball itself.
	--
	-- Keyed on kind rather than on "does this ball already have a
	-- Highlight child", which looks more general but is a race: the
	-- fuse that creates theirs is cloned in with the template and hasn't
	-- necessarily had a frame to run by the time this is called, so the
	-- check would pass or fail depending on scheduler timing.
	if HIGHLIGHT_IS_LOAD_BEARING[kind] then
		return
	end

	local highlight = Instance.new("Highlight")
	highlight.FillColor = AUTO_FLASH_COLOR
	highlight.FillTransparency = 0 -- fully opaque to start; the tween below is what reveals the ball
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = ball

	local fade = TS:Create(
		highlight,
		TweenInfo.new(
			STASH_DEPLOY_GLOW_TIME,
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out
		),
		{
			FillTransparency = 1,
		}
	)

	-- destroyed on completion rather than after a task.wait, so nothing
	-- here holds a thread open for half a second per deploy — and a ball
	-- that gets sold, split or collapsed mid-fade takes its highlight with
	-- it when it's destroyed regardless
	fade.Completed:Connect(function()
		highlight:Destroy()
	end)
	fade:Play()
end

local function playCollapseMsgSound()
	se:FireAllClients("flatPitched", COLLAPSE_MSG_SND_ID, COLLAPSE_MSG_VOL)
end

-- fired once, right as the collapse itself starts (see
-- BallManager.triggerCollapse) — separate from applyCollapsePenalty
-- below so the alert line lands the instant the freeze/mute/desaturate
-- kicks in, rather than waiting until every ball's already been sold
-- and the penalty is about to hit.
function SellService.collapseAlert()
	local chatMessage1 = string.format(
		"<font color=\"#FF00FF\"><b>★</b>  · </font> %s",
		COLLAPSE_ALERT_LINES[math.random(#COLLAPSE_ALERT_LINES)]
	)

	sellBroadcast:FireAllClients(chatMessage1)
	playCollapseMsgSound()
end

-- builds the "who's exempt from the incoming collapse penalty" table.
-- Separated out from applyCollapsePenalty itself so BallManager can
-- call this WHILE the board is still being cleared (see its comment
-- at the call site) rather than leaving that per-player attribute
-- work to happen at applyCollapsePenalty's own moment — right at the
-- tight beat between "board's empty" and "penalty applied", which is
-- exactly where extra synchronous work is most likely to read as a
-- stutter.
function SellService.snapshotCollapseExemptions()
	local exempt = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local afkSince = p:GetAttribute("AFK") and p:GetAttribute("AFKSince")
		if afkSince and (os.time() - afkSince) >= AFK_PENALTY_GRACE then
			exempt[p] = true
		end
	end
	return exempt
end

function SellService.applyCollapsePenalty(exempt)
	-- exempt is normally handed in already-computed (see
	-- snapshotCollapseExemptions above and BallManager's call site);
	-- falling back to computing it here too so this function still
	-- works correctly if ever called on its own
	exempt = exempt or SellService.snapshotCollapseExemptions()

	-- each player loses their own 1/10th, rounded down per-player —
	-- same reasoning as distributePayout's AFK cut: a shared flat
	-- number wouldn't scale fairly across wildly different balances,
	-- so this is computed fresh per player rather than once up front.
	-- Anyone who's been AFK for at least AFK_PENALTY_GRACE is skipped
	-- entirely (no deduction at all) — someone who stepped away isn't
	-- the one who let the queue pile up, so they shouldn't eat the
	-- fine for it.
	for _, p in ipairs(Players:GetPlayers()) do
		local leaderstats = p:FindFirstChild("leaderstats")
		local cash = leaderstats and leaderstats:FindFirstChild("$$$")

		if cash and not exempt[p] then
			local penalty = math.floor(cash.Value * COLLAPSE_PENALTY_FRACTION)
			cash.Value = math.max(
				0,
				cash.Value - penalty
			)
		end
	end

	se:FireAllClients(
		"flatPitched",
		SELL_SND_ID,
		SELL_VOL,
		0.8
	)

	local logsMessage = string.format(
		"<b>an automated system</b> detected an imminent pillar collapse and intervened, deducting <font color=\"#FF00FF\"><b>%d%%</b></font> of everyone's balance as punishment\n<b>(maybe try <font color=\"#FFFF00\">selling</font> orbs more often..?)</b>",
		COLLAPSE_PENALTY_FRACTION * 100
	)

	-- the penalty line and quip go out as separate messages, plain (no
	-- styleMessage) so they render at normal chat size/color rather
	-- than the small grey system-log styling. Both are randomized
	-- per-collapse — the penalty line from its own small pool just to
	-- avoid repeating the exact same phrasing every time, the quip from
	-- its much bigger pool above. The penalty line fires immediately
	-- (this function only runs once the penalty itself is being
	-- applied), then the quip follows after a randomized 2-3 second
	-- beat so the cadence isn't identical every collapse. Both also
	-- play the same client-side ping as the alert line.
	local chatMessage2 = string.format(
		"<font color=\"#FF00FF\"><b>★</b>  · </font> %s",
		string.format(
			COLLAPSE_PENALTY_LINES[math.random(#COLLAPSE_PENALTY_LINES)],
			COLLAPSE_PENALTY_FRACTION * 100
		)
	)
	local chatMessage3 = string.format(
		"<font color=\"#FF00FF\"><b>★</b>  · </font> %s",
		COLLAPSE_QUIPS[math.random(#COLLAPSE_QUIPS)]
	)

	sellBroadcast:FireAllClients(chatMessage2)
	playCollapseMsgSound()
	task.wait(math.random(2, 2.5))
	sellBroadcast:FireAllClients(chatMessage3)
	playCollapseMsgSound()

	sellBroadcast:FireAllClients(styleMessage(logsMessage), LOG_CHANNEL)
end

-- how long a bribe disables the overflow-collapse trigger for — purely
-- for this message's wording. BallManager's own BRIBE_DURATION is the
-- copy that actually governs the timing; this MUST be kept in sync
-- with it by hand, same reasoning as LeaderboardSetup's DEFAULT_PET_*
-- constants having to match PetMimicHandler's.
local BRIBE_DISABLE_SECONDS = 30

-- two separate flavor pools for the chat lines below, same "own pool
-- per message slot" shape as COLLAPSE_PENALTY_LINES/COLLAPSE_QUIPS
-- above rather than one shared pool sampled twice — a reaction line
-- ("here's why i'm taking the money") followed by a quip
-- ("here's the aftermath/parting shot"), picked independently per
-- purchase. Add more to either pool for variety; nothing else needs
-- to change.
local BRIBE_REACTION_LINES = {
	"ooooh money",
}

local BRIBE_QUIPS = {
	"dont mind if i do",
}

-- fired by ShopHandler right after a bribe purchase actually goes
-- through (price charged, cooldown armed, BallManagerBribe already
-- called) — see its header. Three lines total, same shape as the
-- collapse alert/penalty/quip sequence above: a styled log line naming
-- the buyer, then a reaction line and a quip from "the automated
-- system" back to back, each from their own pool (see above) so the
-- two messages are never accidentally identical, reusing the same
-- magenta star-bullet prefix and separated by the same randomized
-- 2-2.5 second beat applyCollapsePenalty uses between its own
-- consequence/quip pair, so a bribe doesn't read as any snappier or
-- more clipped than a collapse does.
function SellService.bribeAnnounce(player)
	local logsMessage = string.format(
		"<b>%s (@%s) bribed the automated system !!!</b> collapses have been <font color=\"#FF00FF\">disabled</font> for %d seconds",
		player.DisplayName,
		player.Name,
		BRIBE_DISABLE_SECONDS
	)
	sellBroadcast:FireAllClients(styleMessage(logsMessage), LOG_CHANNEL)

	local chatMessage1 = string.format(
		"<font color=\"#FF00FF\"><b>★</b>  · </font> %s",
		BRIBE_REACTION_LINES[math.random(#BRIBE_REACTION_LINES)]
	)
	local chatMessage2 = string.format(
		"<font color=\"#FF00FF\"><b>★</b>  · </font> %s",
		BRIBE_QUIPS[math.random(#BRIBE_QUIPS)]
	)

	sellBroadcast:FireAllClients(chatMessage1)
	playCollapseMsgSound() -- same ping every other "the automated system says something" chat line plays
	task.wait(math.random(2, 2.5))
	sellBroadcast:FireAllClients(chatMessage2)
	playCollapseMsgSound()
end

return SellService