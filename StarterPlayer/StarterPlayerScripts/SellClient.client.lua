--[[
    SellClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-24 20:25:15
]]
--[[
    SellClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-23 02:07:56
]]
--[[
    SellClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-22 18:28:59
]]
--[[
	SellClient (LocalScript) — StarterPlayerScripts

	Client side of the sell mechanic. Pressing 1 toggles sell mode; while
	active, hovering a regular ball in Workspace.Balls highlights it
	solid yellow, and clicking fires SellRequest with whatever's
	currently highlighted. SellBroadcast messages get echoed into chat
	via TextChatService.

	A bomb is included too, but only once this player owns "defuser"
	(a BoolValue under their Upgrades folder — see UpgradeData/
	ShopHandler) — its hover/sellable highlight and flash are solid red
	instead of yellow, so it reads as a distinct kind of sell before the
	server's own SellBroadcast/sellFlash even confirm it. Outside sell
	mode a bomb's numDisplay just shows its static "!!" label (from the
	template); sell mode swaps that for a live "$" price and back again
	on exit — see setBombDollarDisplayText/revertBombDisplayText. A
	magnet works exactly the same way, gated on "demagnetizer" instead —
	same red highlight/flash, same 2x-size display math, its own static
	label ("><" instead of "!!"), its own pair of display functions
	(setMagnetDollarDisplayText/revertMagnetDisplayText) mirroring the
	bomb's, and one extra wrinkle: it also stops being sellable the
	instant it enters its pull phase (MagnetFuse sets its Pulling
	attribute) — demagnetizer only cashes one out before it goes live,
	never once it's already pulling. Every other special variant is
	still ignored entirely regardless of upgrades owned — see isSellable
	below. This is all UX/prediction only: SellHandler re-checks
	defuser/demagnetizer ownership (and, for a magnet, Pulling) itself
	server-side before ever paying out a bomb or magnet sale.

	Clicking predicts the whole sell locally rather than waiting on the
	SellRequest round trip: the sound plays instantly (localSellSound),
	the flash plays instantly (sellFlash), and the ball is hidden for
	just this client via LocalTransparencyModifier — the shared instance
	itself isn't touched, so nothing here needs the server to confirm
	first. SellService pays out and broadcasts the chat line immediately
	too, and only makes everyone *else* wait through a fade-in highlight
	before it actually destroys the ball (see SellService's header) —
	skipping this same player for both the highlight's flash/sound and
	its own local copies above, so nothing plays twice.

	Click-and-HOLD on anything that wouldn't otherwise start a single
	sell (empty space, a bomb/magnet that isn't currently sellable,
	whatever) instead starts a box select: a screen-space marquee that
	follows the mouse while the button's held, drawn with boxFrame. Any
	regular, non-radiant ball whose on-screen position lands inside it
	lights up pure yellow via boxHighlights, live, as the box grows or
	shrinks — a bomb or magnet is never included here regardless of
	upgrades owned, box select only ever touches plain balls, and a
	radiant ball (IsRadiant attribute — see BallManager) is excluded the
	same deliberate way even though it's still a plain ball by Name (see
	SellBoxRequest's header in SellHandler for why the server enforces
	this same restriction on both).
	Releasing the button sells everything still highlighted at that
	moment: predicted locally exactly like a single click (flash, hide,
	swallow the server's own pre-sell Highlight) for every selected ball,
	just with one shared sell sound for the whole batch rather than one
	per ball, then fires SellBoxRequest once with the whole array.
	SellService.sellBoxWithHighlight pays out and broadcasts a single
	"sold a bunch of orbs" line for the total, and fades in the same
	per-ball highlight a single sell gets for everyone else before
	destroying each one — see its own header.
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("RunService")
local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local TCS = game:GetService("TextChatService")
local TS = game:GetService("TweenService")
-- SoundService (SS) no longer needed here — the shared open/close toggle
-- cue now lives in ToolbarPanels (see its header for why), and nothing
-- else in this file plays a non-positional Sound

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local bf = WS:WaitForChild("Balls")
local ballT = Rep:WaitForChild("Ball")
local bombT = Rep:WaitForChild("Bomb") -- sellable too, but only once defuser is owned — see isSellable below
local magnetT = Rep:WaitForChild("Magnet") -- sellable too, but only once demagnetizer is owned — see isSellable below

-- same folder ShopClient reads ownership off of — LeaderboardSetup
-- populates it on join before either client script gets a chance to
-- run (see ShopClient's header for the same reasoning)
local upgrades = player:WaitForChild("Upgrades")

local function hasDefuser()
	return upgrades:FindFirstChild("defuser") ~= nil
end

-- exact same deal as hasDefuser, just for the magnet-gating upgrade
local function hasDemagnetizer()
	return upgrades:FindFirstChild("demagnetizer") ~= nil
end

-- single source of truth for "can this currently be sold" — read live
-- (not cached) since defuser/demagnetizer can be bought mid sell-mode.
-- Used to gate hover, the ambient sellable sweep, and the bf.ChildAdded
-- sweep below, so a bomb/magnet becomes sellable/highlightable
-- everywhere at once rather than each call site growing its own copy
-- of this check.
local function isSellable(obj)
	if obj.Name == ballT.Name then
		return true
	end
	if obj.Name == bombT.Name then
		return hasDefuser()
	end
	if obj.Name == magnetT.Name then
		-- demagnetizer only cashes a magnet out before it goes live —
		-- Pulling is set by MagnetFuse the instant the pull itself
		-- starts (see its header), so this flips to unsellable right as
		-- that happens rather than staying sellable until the player
		-- happens to notice
		return hasDemagnetizer() and not obj:GetAttribute("Pulling")
	end
	return false
end

-- see ToolbarPanels' own header — lets sell mode close itself the
-- moment the shop or mimic panel opens, and tells them to do the same
-- when sell mode turns on, so only one of the three is ever active
local ToolbarPanels = require(Rep:WaitForChild("ToolbarPanels"))

local sellBroadcast = Rep:WaitForChild("SellBroadcast")

-- Selling goes through the board now rather than its own remote: the
-- ball is a part on this machine, so "sell" means remove it here and
-- tell the server which id went. SellRequest, SellBoxRequest and the
-- sellFlash/attachedFlash relay through SoundEvents are all gone with
-- it — none of them had anything left to carry.
local ClientBoard = require(script.Parent:WaitForChild("ClientBoard"))
local BoardEffects = require(script.Parent:WaitForChild("BoardEffects"))
local BoardConfig = require(Rep:WaitForChild("BoardConfig"))

-- "Logs" tab: where the routine sell-log lines (see LOG_CHANNEL in
-- SellService) land instead of the main channel. SellHandler is what
-- actually creates this channel, enables ChannelTabsConfiguration, and
-- adds every player to it (AddUserAsync only works from a server
-- Script) — with CanSend forced off there, so being a member doesn't
-- actually let anyone send into it. All that's needed here is a
-- reference to wait for, plus the input-bar handling below as a UX
-- nicety on top of that server-side enforcement.
local textChannels = TCS:WaitForChild("TextChannels")
local logsChannel = textChannels:WaitForChild("Logs")

-- TargetTextChannel tracks whichever channel tab is currently focused,
-- so this fires on every tab switch. While it's pointed at Logs, the
-- whole input bar gets disabled — there's nothing to type into, rather
-- than a message that would just silently fail to send (CanSend is
-- already false server-side; this just keeps the UI honest about it).
local ChatInputBarConfig = TCS:FindFirstChildOfClass("ChatInputBarConfiguration")
if ChatInputBarConfig then
	local inputBarEnabled = ChatInputBarConfig.Enabled -- whatever it was already authored as, so this doesn't fight other configuration
	ChatInputBarConfig:GetPropertyChangedSignal("TargetTextChannel"):Connect(function()
		ChatInputBarConfig.Enabled = inputBarEnabled and ChatInputBarConfig.TargetTextChannel ~= logsChannel
	end)
end

-- toolbar button that mirrors the "1" keybind: clicking it toggles sell
-- mode exactly like the key does, and it lights up yellow while sell
-- mode is active so the toolbar reflects state either input drives
local toolbarContainer = player:WaitForChild("PlayerGui"):WaitForChild("toolbar"):WaitForChild("toolbarContainer")
local sellButton = toolbarContainer:WaitForChild("1.sellButton")
local sellButtonText = sellButton:WaitForChild("text")
local sellButtonNumber = sellButton:WaitForChild("number")

local TOOLBAR_HIGHLIGHT_COLOR = Color3.fromRGB(255, 255, 0)
-- captured once at startup rather than hardcoded, so whatever color
-- these labels were authored with in Studio is what they revert to
local sellButtonTextColor = sellButtonText.TextColor3
local sellButtonNumberColor = sellButtonNumber.TextColor3

local function setSellButtonHighlighted(active)
	sellButtonText.TextColor3 = active and TOOLBAR_HIGHLIGHT_COLOR or sellButtonTextColor
	sellButtonNumber.TextColor3 = active and TOOLBAR_HIGHLIGHT_COLOR or sellButtonNumberColor
end

-- AFKHandler owns the "AFK" attribute (see its header). Active = false
-- is what actually blocks the click (Roblox GuiButtons stop firing
-- MouseButton1Click etc. once Active is false) — the dimmed text is
-- just the visual tell to go with it, same 0.5 transparency ShopClient
-- uses for its own greyed-out buttons. The "1" keybind isn’t routed
-- through this button at all, so it needs its own guard — see the
-- InputBegan handler below.
local function setSellButtonDisabled(disabled)
	sellButton.Active = not disabled
	sellButtonText.TextTransparency = disabled and 0.5 or 0
	sellButtonNumber.TextTransparency = disabled and 0.5 or 0
end

local HIGHLIGHT_COLOR = Color3.fromRGB(255, 255, 0)

-- pure red — keep in sync with SellService's DEFUSER_FLASH_COLOR.
-- Used for both the solid hover highlight and the click-predicted
-- flash/highlight below, same as HIGHLIGHT_COLOR is for a regular ball.
local DEFUSER_FLASH_COLOR = Color3.fromRGB(255, 0, 0)

-- fallback only — see colorFor below. A radiant bomb's real predicted
-- color is read off its RadiantFlashColor attribute (kept in sync with
-- SellService's own fallback); this only ever fires if that attribute
-- somehow isn't set yet at click time. Keep in sync with SellService's
-- own RADIANT_FLASH_COLOR.
local RADIANT_FLASH_COLOR = Color3.fromRGB(255, 255, 255)

-- keep in sync with SellService's BOMB_SELL_MULTIPLIER — used purely for
-- display below (setBombDollarDisplayText), so the price shown while
-- hovering/sell-mode matches what an actual bomb sale will pay out
local BOMB_SELL_MULTIPLIER = 2

-- keep in sync with SellService's MAGNET_SELL_MULTIPLIER — same
-- reasoning as BOMB_SELL_MULTIPLIER above, used by
-- setMagnetDollarDisplayText
local MAGNET_SELL_MULTIPLIER = 2

-- keep in sync with SellService's RADIANT_SELL_MULTIPLIER — folded into
-- setDollarDisplayText itself (a radiant ball is priced like any other
-- ball, just at this multiplier — see there), rather than a separate
-- per-variant function the way bomb/magnet get.
local RADIANT_SELL_MULTIPLIER = 3

-- keep in sync with SellService's RADIANT_BOMB_SELL_MULTIPLIER — used
-- purely for display below (setBombDollarDisplayText), same reasoning
-- as BOMB_SELL_MULTIPLIER/RADIANT_SELL_MULTIPLIER above. Deliberately
-- its own constant, not RADIANT_SELL_MULTIPLIER — a radiant ball and a
-- radiant bomb are priced completely independently (3x vs 6x).
local RADIANT_BOMB_SELL_MULTIPLIER = 6

-- keep in sync with SellService's RADIANT_MAGNET_SELL_MULTIPLIER — used
-- purely for display below (setMagnetDollarDisplayText), same reasoning
-- as RADIANT_BOMB_SELL_MULTIPLIER above. Same 6x a radiant bomb sells
-- for, per design, but its own constant rather than reusing
-- RADIANT_BOMB_SELL_MULTIPLIER so the two stay independently tunable.
local RADIANT_MAGNET_SELL_MULTIPLIER = 6

-- keep in sync with SellService's ONLY_BALL_FREE_MAX_SIZE — the size at
-- or under which the last orb on the board sells for nothing (see
-- isWorthlessOnlyBall there for the rule and why it's gated on size at
-- all). Used purely for the price label below
-- (setDollarDisplayText), same duplicate-for-display reasoning as the
-- multipliers above: the server is what actually enforces it.
local ONLY_BALL_FREE_MAX_SIZE = 5

-- a bomb/magnet's static numDisplay label whenever sell mode isn't
-- showing a price for it. Matches whatever's already baked into the
-- template in Studio; these are only ever written back here, never what
-- turns the display on in the first place (that's the template's own
-- default Enabled state).
local BOMB_LABEL = "!!"
local MAGNET_LABEL = "><"

-- shared by the hover highlight and the ambient sellable highlight
-- below — one place decides yellow-vs-red-vs-rainbow so all three
-- (this, and the click-predicted flash at sellFlash's own call site)
-- stay in sync. A radiant ball/bomb/magnet (IsRadiant attribute — see
-- BallManager) is checked FIRST now, ahead of the bomb/magnet Name
-- check, so radiant takes priority over DEFUSER_FLASH_COLOR for a
-- radiant bomb/magnet too, not just a plain radiant ball — mirrors
-- SellService's own radiantColor priority server-side. A plain radiant
-- ball or magnet just copies its own live Color (that IS its rainbow
-- loop color at any given moment — a magnet's idle loop freezes rather
-- than stopping once pulling starts, so Color still holds a valid hue);
-- a radiant bomb instead reads its RadiantFlashColor attribute, since
-- bomb.Color itself spends roughly half its time on the flat OFF navy
-- between flicker ticks (see RadiantBombFuse) and would read as
-- "not rainbow" if predicted mid-dark-tick.
local function colorFor(obj)
	if obj:GetAttribute("IsRadiant") then
		if obj.Name == bombT.Name then
			return obj:GetAttribute("RadiantFlashColor") or RADIANT_FLASH_COLOR
		end
		return obj.Color
	end
	if obj.Name == bombT.Name or obj.Name == magnetT.Name then
		return DEFUSER_FLASH_COLOR
	end
	return HIGHLIGHT_COLOR
end

-- keep in sync with SellService's SELL_SND_ID/SELL_VOL — duplicated here
-- (rather than sent over) so this can play with zero network wait
local SELL_SND_ID, SELL_VOL = "rbxassetid://139583503249540", 1

-- keep in sync with SellService's DEFUSE_SND_ID/DEFUSE_VOL/DEFUSE_PITCH —
-- bomb-only cue layered alongside SELL_SND_ID, never in place of it. Same
-- duplicate-here-for-zero-wait reasoning as SELL_SND_ID above.
local DEFUSE_SND_ID, DEFUSE_VOL, DEFUSE_PITCH = "rbxassetid://12222152", 0.7, 1.15

-- same reasoning as the sound: built entirely client-side so there's no
-- server-replicated instance whose position can drift from whatever
-- this client is already rendering
local SELL_FLASH_IMAGE = "rbxassetid://131187911056182" -- keep in sync with BombFuse's FLASH_IMAGE
local SELL_FLASH_SCALE = 2 -- scales linearly with ball size — tuned for a ~5-stud ball
local SELL_FLASH_SHRINK_TIME = 0.4

-- shared, non-positional sell-toggle cue now lives centrally in
-- ToolbarPanels (see its header) — notifyOpened/notifyClosed below play
-- it, so this file doesn't keep its own copy anymore

local sellMode = false
local hovered, highlight -- currently highlighted ball + its Highlight instance
local selling = setmetatable({}, { __mode = "k" }) -- balls with a sell request already in flight

-- declared up here (rather than down with the rest of the box-select
-- state further below) specifically so updateHover's guard above closes
-- over this same local — declaring it later in the script would leave
-- that guard reading an unrelated global instead
local boxSelecting = false

local function clearHighlight()
	if highlight then
		highlight:Destroy()
		highlight = nil
	end
	hovered = nil
end

-- faint highlight applied to every sellable ball for as long as sell mode
-- is on, separate from the solid hover highlight above — a ball can
-- carry both at once (hover on top of this one) since Highlights stack
-- independently. Keyed by ball so toggling off (or a ball getting
-- sold/destroyed mid sell-mode) can clean up exactly the instances this
-- added, without touching the hover highlight or SellService's own
-- pre-sell highlight. Color comes from colorFor per-ball (yellow for a
-- regular ball, red for a bomb) rather than one fixed color, same
-- yellow/red split as the hover highlight below.
local SELLABLE_HIGHLIGHT_TRANSPARENCY = 0.8

local sellableHighlights = {} -- [ball] = Highlight instance

-- declared ahead of addSellableHighlight (rather than after, like before)
-- since addSellableHighlight's PendingSell listener below now needs to
-- call this itself
local function removeSellableHighlight(ball)
	local h = sellableHighlights[ball]
	if h then
		h:Destroy()
		sellableHighlights[ball] = nil
	end
end

local function addSellableHighlight(ball)
	if sellableHighlights[ball] then return end

	local h = Instance.new("Highlight")
	h.FillColor = colorFor(ball)
	h.FillTransparency = SELLABLE_HIGHLIGHT_TRANSPARENCY
	h.OutlineTransparency = 1
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Parent = ball
	sellableHighlights[ball] = h

	-- ball can be destroyed (sold, void-cleaned, etc.) while sell mode
	-- is still on — Destroying takes the Highlight with it automatically,
	-- but the table entry needs clearing too or it'd keep a dead
	-- reference around until the next full sweep
	ball.Destroying:Connect(function()
		sellableHighlights[ball] = nil
	end)

	-- another player's click (or an auto-sell) can mark this ball
	-- PendingSell while sell mode is still on for us — the instant that
	-- happens it's no longer actually sellable, so drop the faint
	-- "you can sell this" highlight right away instead of leaving it lit
	-- until the ball is destroyed. If we're also actively hovering it
	-- with the solid highlight on top, clear that too — updateHover
	-- won't otherwise re-check this ball until the mouse moves onto
	-- something else, which is what let a second player click it during
	-- the highlight-fade in the first place.
	--
	-- A magnet's Pulling attribute is watched the exact same way and
	-- funnels through the same handler: the instant MagnetFuse flips it
	-- true (see its header), isSellable(ball) below goes false for this
	-- magnet too, so it drops its highlight right as it goes live instead
	-- of staying lit as if it could still be demagnetized.
	local function dropHighlightIfUnsellable()
		if ball:GetAttribute("PendingSell") or not isSellable(ball) then
			removeSellableHighlight(ball)
			if hovered == ball then
				clearHighlight()
			end
		end
	end

	ball:GetAttributeChangedSignal("PendingSell"):Connect(dropHighlightIfUnsellable)
	if ball.Name == magnetT.Name then
		ball:GetAttributeChangedSignal("Pulling"):Connect(dropHighlightIfUnsellable)
	end
end

-- sweeps every currently-sellable ball/bomb (see isSellable) the same
-- way setAllSellDisplays sweeps regular balls, adding the highlight on
-- entry or tearing every one of them down on exit
local function setAllSellableHighlights(show)
	if show then
		for _, obj in ipairs(bf:GetChildren()) do
			if isSellable(obj) then
				addSellableHighlight(obj)
			end
		end
	else
		for ball in pairs(sellableHighlights) do
			removeSellableHighlight(ball)
		end
	end
end

-- swaps a single ball's numDisplay between its size and "$" — same
-- display/numDisplay path BallManager's setDisplay uses server-side.
-- Guarded with FindFirstChild the same way, so a template missing the
-- GUI just no-ops instead of erroring.
local function setDisplayText(ball, text)
	local display = ball:FindFirstChild("display")
	local label = display and display:FindFirstChild("numDisplay")
	if label then
		label.Text = text
	end
end

-- reverting doesn't need a cached original string — TargetSize never
-- changes post-spawn (see BallManager), so re-deriving it here always
-- matches what setDisplay wrote originally
local function revertDisplayText(ball)
	local size = ball:GetAttribute("TargetSize")
	if size then
		setDisplayText(ball, tostring(math.round(size)))
	end
end

-- same "only ball in play" criteria SellService.sellWithHighlight checks
-- server-side at sell time (Split-flagged balls excluded, PendingSell
-- ones still counted — see its header) — mirrored here purely for
-- display, so the label matches what an actual sell would pay out
-- before the player even clicks. Only half the rule on its own: the
-- orb's size is the other half (see setDollarDisplayText below).
local function countLiveBalls()
	local count = 0
	for _, obj in ipairs(bf:GetChildren()) do
		if obj.Name == ballT.Name and not obj:GetAttribute("Split") then
			count += 1
		end
	end
	return count
end

-- same TargetSize source as revertDisplayText, just prefixed with "$"
-- instead of shown bare — so a size-5 ball reads "$5" in sell mode
-- rather than just "$", keeping the size visible while still signaling
-- it's sellable. Special-cased to "$0" for the only orb in play, but
-- ONLY while it's still at or under ONLY_BALL_FREE_MAX_SIZE — the
-- zero-payout rule is size-gated server-side (see isWorthlessOnlyBall
-- in SellService), so a last orb bigger than that shows its real price
-- here like any other orb rather than under-advertising a sale that
-- will actually pay out.
--
-- A radiant ball (IsRadiant attribute — see BallManager) is folded in
-- here rather than getting its own function: it's priced at
-- RADIANT_SELL_MULTIPLIER times size, same as SellService actually
-- pays out, but is otherwise identical to a plain ball — same "$0"
-- only-ball case, same revert-to-size-number behavior, same everything
-- else. That multiplier applies to a big last orb too, exactly as the
-- server prices it.
local function setDollarDisplayText(ball)
	local size = ball:GetAttribute("TargetSize")
	if not size then return end

	if countLiveBalls() <= 1 and size <= ONLY_BALL_FREE_MAX_SIZE then
		setDisplayText(ball, "$0")
	else
		local multiplier = ball:GetAttribute("IsRadiant") and RADIANT_SELL_MULTIPLIER or 1
		setDisplayText(ball, "$" .. tostring(math.round(size * multiplier)))
	end
end

-- bomb counterpart to setDollarDisplayText: same "$" + rounded size
-- shape, but scaled by BOMB_SELL_MULTIPLIER (a bomb sale pays 2x its
-- size — see SellService) and with no "only ball in play" zero-payout
-- case, since that rule was never part of the bomb economy either (see
-- SellService.sellWithHighlight). TargetSize falls back to Size.X, same
-- fallback used everywhere else a bomb's size is read.
--
-- Enabled is forced true here as a safety net: outside sell mode a
-- bomb's display normally sits Enabled (showing its static "!!" label
-- from the template — see revertBombDisplayText/BOMB_LABEL), but the
-- click handler below explicitly disables it the instant a sell is
-- predicted, so this makes sure a bomb re-entering "for sale" state
-- (sell mode toggling back on, PendingSell having cleared some other
-- way) actually becomes visible again rather than assuming it already is.
--
-- BUG FIX: this used to force Enabled = true unconditionally, which
-- fought the click handler below. That handler predicts a sell
-- instantly and explicitly disables `display` so a just-sold bomb reads
-- as fully gone on the seller's own screen while the server's 0.3s
-- highlight fade plays out for everyone else — but the bomb is still
-- sitting in `bf` during that window (not destroyed yet), so ANY later
-- call to this function for the same bomb (e.g. setAllSellDisplays
-- re-sweeping every object because some unrelated regular ball
-- elsewhere on the board got sold/removed — see bf.ChildRemoved below,
-- which happens constantly on a busy board) would flip Enabled back to
-- true and write a fresh "$" price onto an otherwise-invisible,
-- already-sold bomb, floating there for the seller until the server
-- actually destroys it a beat later. Regular balls never had this
-- problem because their display is always left Enabled and only the
-- *text* changes (see setDollarDisplayText) — nothing ever re-enables
-- it after the click handler turns it off. Skipping the write here
-- whenever a sell is already underway for this bomb closes the same
-- gap for bombs. selling[bomb] covers the instant right after THIS
-- client's own click (before the server round trip confirms it);
-- PendingSell covers it from then on (including if this same bomb was
-- clicked by/attributed to someone else).
-- A radiant bomb (IsRadiant attribute — see BallManager/BombFuse) is
-- priced at RADIANT_BOMB_SELL_MULTIPLIER instead of the plain
-- BOMB_SELL_MULTIPLIER, same as SellService actually pays out — folded
-- in here rather than a separate function, same pattern
-- setDollarDisplayText already uses for a radiant ball.
local function setBombDollarDisplayText(bomb)
	local display = bomb:FindFirstChild("display")
	if not display then return end
	if selling[bomb] or bomb:GetAttribute("PendingSell") then return end

	local size = bomb:GetAttribute("TargetSize") or bomb.Size.X
	local multiplier = bomb:GetAttribute("IsRadiant") and RADIANT_BOMB_SELL_MULTIPLIER or BOMB_SELL_MULTIPLIER
	display.Enabled = true
	setDisplayText(bomb, "$" .. tostring(math.round(size * multiplier)))
end

-- mirror of revertDisplayText for a bomb — a bomb doesn't revert to a
-- derived size number the way a regular ball does, so this writes the
-- bomb's own static label back instead (a radiant ball has no such
-- static label — revertDisplayText already handles it, same as any
-- other ball). Enabled is deliberately left alone: the template's own
-- default is what makes this visible outside sell mode in the first
-- place, this function was never what turned it on (see
-- setBombDollarDisplayText's comment above for why forcing Enabled only
-- happens on the way IN to sell mode, not on the way out).
local function revertBombDisplayText(bomb)
	local display = bomb:FindFirstChild("display")
	if not display then return end
	if selling[bomb] or bomb:GetAttribute("PendingSell") then return end

	setDisplayText(bomb, BOMB_LABEL)
end

-- magnet counterpart to setBombDollarDisplayText/revertBombDisplayText above —
-- identical shape (MAGNET_SELL_MULTIPLIER instead of
-- BOMB_SELL_MULTIPLIER), including the same selling[]/PendingSell guard,
-- so a demagnetized magnet can't have its price flash back on for the
-- seller the same bug used to let happen to a defused bomb (see the
-- comment on setBombDollarDisplayText above for the full explanation).
-- A radiant magnet (IsRadiant attribute — see BallManager/RadiantMagnetFuse)
-- is priced at RADIANT_MAGNET_SELL_MULTIPLIER instead of the plain
-- MAGNET_SELL_MULTIPLIER, same as SellService actually pays out — folded
-- in here the same way setBombDollarDisplayText handles its own radiant
-- bomb case, rather than a separate function.
local function setMagnetDollarDisplayText(magnet)
	local display = magnet:FindFirstChild("display")
	if not display then return end
	if selling[magnet] or magnet:GetAttribute("PendingSell") then return end

	local size = magnet:GetAttribute("TargetSize") or magnet.Size.X
	local multiplier = magnet:GetAttribute("IsRadiant") and RADIANT_MAGNET_SELL_MULTIPLIER or MAGNET_SELL_MULTIPLIER
	display.Enabled = true
	setDisplayText(magnet, "$" .. tostring(math.round(size * multiplier)))
end

-- magnet counterpart to revertBombDisplayText above — same reasoning,
-- just MAGNET_LABEL ("><") instead of BOMB_LABEL ("!!"). A no-op once
-- Pulling is true anyway, since MagnetFuse tears the whole "display"
-- BillboardGui down itself the instant the pull starts (see its
-- header) — FindFirstChild above just returns nil by then.
local function revertMagnetDisplayText(magnet)
	local display = magnet:FindFirstChild("display")
	if not display then return end
	if selling[magnet] or magnet:GetAttribute("PendingSell") then return end

	setDisplayText(magnet, MAGNET_LABEL)
end

-- sweeps every currently-live regular ball (and, for a defuser owner,
-- every bomb) when sell mode toggles. Any other special variant is
-- still skipped entirely via the same Name check used for
-- hover/highlight above, so its label (if any) is never touched.
local function setAllSellDisplays(showDollar)
	for _, obj in ipairs(bf:GetChildren()) do
		if obj.Name == ballT.Name then
			if showDollar then
				setDollarDisplayText(obj)
			else
				revertDisplayText(obj)
			end
		elseif obj.Name == bombT.Name and hasDefuser() then
			if showDollar then
				setBombDollarDisplayText(obj)
			else
				revertBombDisplayText(obj)
			end
		elseif obj.Name == magnetT.Name and isSellable(obj) then
			if showDollar then
				setMagnetDollarDisplayText(obj)
			else
				revertMagnetDisplayText(obj)
			end
		end
	end
end

-- buying defuser mid-session (shop stays usable while sell mode is on)
-- shouldn't require toggling sell mode off/on again before bombs
-- already on the board light up — sweep just the bombs in, the same
-- way a freshly-spawned one gets added via bf.ChildAdded below
upgrades.ChildAdded:Connect(function(child)
	if child.Name == "defuser" and sellMode then
		for _, obj in ipairs(bf:GetChildren()) do
			if obj.Name == bombT.Name then
				addSellableHighlight(obj)
				setBombDollarDisplayText(obj)
			end
		end
	elseif child.Name == "demagnetizer" and sellMode then
		for _, obj in ipairs(bf:GetChildren()) do
			if obj.Name == magnetT.Name and not obj:GetAttribute("Pulling") then
				addSellableHighlight(obj)
				setMagnetDollarDisplayText(obj)
			end
		end
	end
end)

-- catches balls that spawn (e.g. from a split) while sell mode is
-- already on, so they show "$" immediately instead of their size for a
-- frame. By the time this fires the ball has fully replicated — Size,
-- TargetSize, and the numDisplay text are all already set server-side
-- before BallManager parents it (see spawnBall) — so it's safe to just
-- overwrite the label here.
bf.ChildAdded:Connect(function(obj)
	if not sellMode then return end

	if obj.Name == ballT.Name then
		setAllSellDisplays(true) -- count changed — recheck the only-ball case for every label, not just this one
		addSellableHighlight(obj)
	elseif obj.Name == bombT.Name and isSellable(obj) then
		-- a bomb spawning while sell mode's already on, for a player who
		-- already owns defuser — gets the same "$" treatment a regular
		-- ball does (setBombDollarDisplayText), plus the ambient
		-- sellable highlight
		addSellableHighlight(obj)
		setBombDollarDisplayText(obj)
	elseif obj.Name == magnetT.Name and isSellable(obj) then
		-- exact same deal as the bomb branch above, for a player who
		-- already owns demagnetizer
		addSellableHighlight(obj)
		setMagnetDollarDisplayText(obj)
	end
end)

-- mirror of the above for the other direction: a ball leaving bf (sold,
-- split-replaced, void-cleaned) can just as easily flip the only-ball
-- case for whichever ball's left — e.g. 2 balls -> 1 should immediately
-- start reading "$0" on the survivor, not wait for the next toggle
bf.ChildRemoved:Connect(function(obj)
	if sellMode and obj.Name == ballT.Name then
		setAllSellDisplays(true)
	end
end)

local function updateHover()
	if not sellMode then return end
	if boxSelecting then return end -- the box's own per-ball highlights own this while a drag is in progress

	local target = mouse.Target
	if target == hovered then return end -- nothing changed, skip the churn

	clearHighlight()

	-- selling[target] excludes a ball this client already predicted the
	-- sale of — it's still sitting in bf (real removal is delayed
	-- server-side, see SellService), but LocalTransparencyModifier has
	-- already hidden it for us, so it shouldn't light back up just
	-- because the mouse is still over its (invisible) hitbox
	--
	-- target:GetAttribute("PendingSell") excludes a ball someone else
	-- (another player's click, or an auto-sell) already put into its
	-- sell-animation — that attribute is set the instant SellService
	-- starts selling it and replicates to every client, so this stops
	-- us from ever highlighting (and by extension clicking) a ball
	-- that's already mid-sell out from under another sale
	-- ClientBoard.canSell is the board's half of the question: an orb
	-- being pulled into a splitter, or already on its way off the edge,
	-- shouldn't light up as something you can click.
	if target and target.Parent == bf and isSellable(target) and ClientBoard.canSell(target) and not selling[target] and not target:GetAttribute("PendingSell") then
		hovered = target
		highlight = Instance.new("Highlight")
		highlight.FillColor = colorFor(target)
		highlight.FillTransparency = 0 -- solid, not the default semi-transparent fill
		highlight.OutlineTransparency = 1 -- no outline
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded -- respect normal depth, don't render through other parts
		highlight.Parent = target
	end
end

RS.RenderStepped:Connect(updateHover)

-- keeps every currently-shown radiant highlight tracking its ball's own
-- live rainbow instead of freezing at whatever hue colorFor happened to
-- read the moment the highlight was created — covers both the solid
-- hover highlight above and every faint ambient sellable highlight
-- below (see addSellableHighlight), which can otherwise sit visibly
-- static for as long as sell mode stays on while the ball underneath
-- keeps cycling. Only re-colors radiant targets each frame; a plain
-- ball/bomb/magnet's color never changes, so there's nothing to update
-- there.
RS.Heartbeat:Connect(function()
	if highlight and hovered and hovered:GetAttribute("IsRadiant") then
		highlight.FillColor = colorFor(hovered)
	end
	for ball, h in pairs(sellableHighlights) do
		if ball:GetAttribute("IsRadiant") then
			h.FillColor = colorFor(ball)
		end
	end
end)

-- same "positional" shape SoundClient uses for server-fired sounds, so a
-- locally-predicted sell sounds identical to one someone else hears —
-- anchored to the ball's last known position rather than the ball
-- itself, since the server is about to destroy it out from under us
-- id/volume/pitch default to the normal sell cue (SELL_SND_ID/SELL_VOL,
-- pitch 1) so every existing call site is unaffected; the bomb click
-- handler below passes DEFUSE_SND_ID/DEFUSE_VOL/DEFUSE_PITCH through a
-- second call instead, so both play together off separate anchors
-- rather than one replacing the other.
local function localSellSound(pos, id, volume, pitch)
	local anchor = Instance.new("Part")
	anchor.Anchored, anchor.CanCollide, anchor.CanQuery, anchor.Transparency = true, false, false, 1
	anchor.Size, anchor.Position, anchor.Parent = Vector3.new(0.1, 0.1, 0.1), pos, WS

	local s = Instance.new("Sound")
	s.SoundId, s.Volume, s.PlaybackSpeed, s.Parent = id or SELL_SND_ID, volume or SELL_VOL, pitch or 1, anchor
	s:Play()
	s.Ended:Connect(function() anchor:Destroy() end)
end

-- same shape and recolor timing as BombFuse's flash(), except it
-- shrinks to nothing instead of just popping away after a fixed delay.
-- `size` scales the billboard linearly (see SELL_FLASH_SCALE). `color`
-- is what it settles into after the white flash — defaults to
-- HIGHLIGHT_COLOR (yellow) for a player-initiated sell; SellService
-- sends a cyan override for auto-sells (see se.OnClientEvent below).
--
-- AlwaysOnTop defaults to false: the flash should respect normal depth
-- like the rest of the scene (DepthMode below already keeps it from
-- bleeding through geometry it's genuinely behind), not punch through
-- everything regardless of what's actually in front of it. attachedFlash
-- below overrides this to true only for the overflow-collapse flash —
-- that freeze desaturates/contrast-boosts the whole scene via a
-- ColorCorrectionEffect, which (unlike AlwaysOnTop) only affects the
-- normally-composited render, so without the override the red collapse
-- flash reads as washed-out white instead of red.
--
-- startColor/scaleMultiplier are optional trailing overrides on top of
-- the shared defaults every existing caller (a regular/auto sell,
-- mimicAbsorb, petMimicAbsorb, collapseSell) keeps getting: nil for
-- either just falls back to the original white pop-in at 1x
-- SELL_FLASH_SCALE, so this stays backward compatible for all of them.
-- SplitterFuse's own vanish flash is the one caller that overrides both,
-- for a bigger flash that pops in from black instead.
local function sellFlash(pos, size, color, alwaysOnTop, startColor, scaleMultiplier)
	local anchor = Instance.new("Part")
	anchor.Anchored, anchor.CanCollide, anchor.CanQuery, anchor.Transparency = true, false, false, 1
	anchor.Size, anchor.Position, anchor.Parent = Vector3.new(0.1, 0.1, 0.1), pos, WS

	local scale = size * SELL_FLASH_SCALE * (scaleMultiplier or 1)
	local gui = Instance.new("BillboardGui")
	gui.Adornee, gui.Size, gui.AlwaysOnTop, gui.Parent = anchor, UDim2.new(scale, 0, scale, 0), alwaysOnTop or false, anchor

	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency, img.BorderSizePixel = 1, 0
	img.Size, img.Image = UDim2.new(1, 0, 1, 0), SELL_FLASH_IMAGE
	img.ImageColor3, img.ImageTransparency = startColor or Color3.new(1, 1, 1), 0 -- starts white unless overridden
	img.ScaleType, img.Parent = Enum.ScaleType.Fit, gui
	img.ZIndex = 10

	task.delay(0.03, function()
		if img.Parent then img.ImageColor3 = color or HIGHLIGHT_COLOR end
	end)

	local shrink = TS:Create(gui,
		TweenInfo.new(SELL_FLASH_SHRINK_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
		{ Size = UDim2.new(0, 0, 0, 0) })
	shrink:Play()
	shrink.Completed:Connect(function()
		if anchor.Parent then anchor:Destroy() end
	end)
end

-- like sellFlash, but takes the ball itself instead of a server-computed
-- Vector3 — used only for the overflow-collapse flash (see
-- SellService.collapseSell). Reads `target.Position` off this client's
-- own local copy at the moment the event lands, so the flash always
-- matches wherever *this* client is currently rendering the ball, even
-- if the freeze (see BallManager.triggerCollapse) hasn't fully caught up
-- here yet — a position baked in server-side can only ever be right for
-- the server's own view, not any specific client's. alwaysOnTop is
-- hardcoded true, same reasoning as the collapse override used to pass
-- through explicitly (see sellFlash's comment above).
local function attachedFlash(target, size, color, startColor, scaleMultiplier)
	local ok, pos = pcall(function() return target.Position end)
	if not ok then return end
	sellFlash(pos, size, color, true, startColor, scaleMultiplier)
end

-- BOX SELECT: click-and-hold on anything that wouldn't otherwise start
-- a single sell (see the InputBegan elseif chain further down) drags a
-- screen-space marquee instead; any regular ball whose on-screen
-- position falls inside it lights up pure yellow, and releasing sells
-- everything still lit. Deliberately plain-balls-only — no bomb/magnet
-- path here at all, matching SellHandler's own SellBoxRequest filter
-- (see its header) — so there's no colorFor/isSellable split to carry
-- over from the single-sell code above; it's just HIGHLIGHT_COLOR and
-- ballT.Name throughout.
local boxStart = Vector2.new()
local boxHighlights = {} -- [ball] = Highlight instance; membership IS "currently inside the box"

-- own ScreenGui rather than reusing an existing one — this is the only
-- thing in this file that draws a 2D screen-space rectangle, so it gets
-- its own small ScreenGui instead of hunting for somewhere to hang a
-- Frame off of. IgnoreGuiInset so the box's on-screen position lines up
-- with UIS:GetMouseLocation() (which is itself inset-relative) without
-- needing an extra offset correction at every read.
local boxGui = Instance.new("ScreenGui")
boxGui.Name = "SellBoxSelectGui"
boxGui.ResetOnSpawn = false
boxGui.IgnoreGuiInset = true
boxGui.DisplayOrder = 100
boxGui.Parent = player:WaitForChild("PlayerGui")

local boxFrame = Instance.new("Frame")
boxFrame.Name = "box"
boxFrame.BackgroundColor3 = HIGHLIGHT_COLOR
boxFrame.BackgroundTransparency = 0.75
boxFrame.BorderSizePixel = 0
boxFrame.Visible = false
boxFrame.ZIndex = 10
boxFrame.Parent = boxGui

local boxStroke = Instance.new("UIStroke")
boxStroke.Color = HIGHLIGHT_COLOR
boxStroke.Thickness = 1
boxStroke.Parent = boxFrame

local function clearBoxHighlights()
	for ball, h in pairs(boxHighlights) do
		h:Destroy()
	end
	table.clear(boxHighlights)
end

-- shared by setSellMode (turning sell mode off entirely) and
-- finalizeBoxSelect (a normal release, after it's already pulled the
-- final selection out of boxHighlights) — drops the marquee and every
-- highlight it's currently holding without selling anything
local function cancelBoxSelect()
	boxSelecting = false
	boxFrame.Visible = false
	clearBoxHighlights()
end

local function beginBoxSelect()
	boxSelecting = true
	boxStart = UIS:GetMouseLocation()
	boxFrame.Position = UDim2.fromOffset(boxStart.X, boxStart.Y)
	boxFrame.Size = UDim2.fromOffset(0, 0)
	boxFrame.Visible = true
	clearHighlight() -- drop the solid hover highlight so it doesn't sit lit on top of the drag
end

-- driven off RenderStepped alongside updateHover below, but only does
-- anything while a drag is actually in progress
local function updateBoxSelect()
	if not boxSelecting then return end

	local current = UIS:GetMouseLocation()
	local topLeft = Vector2.new(math.min(boxStart.X, current.X), math.min(boxStart.Y, current.Y))
	local size = Vector2.new(math.abs(current.X - boxStart.X), math.abs(current.Y - boxStart.Y))

	boxFrame.Position = UDim2.fromOffset(topLeft.X, topLeft.Y)
	boxFrame.Size = UDim2.fromOffset(size.X, size.Y)

	local camera = WS.CurrentCamera
	if not camera then return end

	-- add/remove per-ball highlights as membership changes each frame —
	-- selling[obj]/PendingSell excluded for the exact same reason
	-- updateHover excludes them from the single hover highlight: a ball
	-- already mid-sell (this client's own prediction, or someone else's)
	-- shouldn't light back up just because the box happens to be
	-- passing over its now-invisible or about-to-vanish hitbox
	for _, obj in ipairs(bf:GetChildren()) do
		if obj.Name == ballT.Name and not obj:GetAttribute("IsRadiant") and not selling[obj] and not obj:GetAttribute("PendingSell") and not obj:GetAttribute("Split") and ClientBoard.canSell(obj) then
			local screen, onScreen = camera:WorldToViewportPoint(obj.Position)
			local inside = onScreen
				and screen.X >= topLeft.X and screen.X <= topLeft.X + size.X
				and screen.Y >= topLeft.Y and screen.Y <= topLeft.Y + size.Y

			if inside and not boxHighlights[obj] then
				local h = Instance.new("Highlight")
				h.FillColor = HIGHLIGHT_COLOR
				h.FillTransparency = 0 -- solid, same as the single hover highlight
				h.OutlineTransparency = 1
				h.DepthMode = Enum.HighlightDepthMode.Occluded
				h.Parent = obj
				boxHighlights[obj] = h
			elseif not inside and boxHighlights[obj] then
				boxHighlights[obj]:Destroy()
				boxHighlights[obj] = nil
			end
		end
	end

	-- a highlighted ball can fall out of contention mid-drag without
	-- ever going "not inside" above — sold out from under the box by
	-- another player/an auto-sell, or void-cleaned — so this sweeps
	-- boxHighlights itself for anything that's stopped being a live,
	-- still-sellable plain ball in bf, same cleanup
	-- dropHighlightIfUnsellable does for the ambient sellable highlight
	for obj in pairs(boxHighlights) do
		if obj.Parent ~= bf or obj:GetAttribute("PendingSell") or selling[obj] or not ClientBoard.canSell(obj) then
			boxHighlights[obj]:Destroy()
			boxHighlights[obj] = nil
		end
	end
end

-- release: sell everything still highlighted at this instant. Mirrors
-- the single-click prediction below ball-for-ball (flash, hide,
-- swallow the server's own pre-sell Highlight) except for the sound —
-- one shared localSellSound for the whole batch, positioned at the
-- selection's centroid, rather than firing the same clip once per ball
-- and turning a big selection into noise.
local function finalizeBoxSelect()
	boxSelecting = false
	boxFrame.Visible = false

	local targets = {}
	for ball in pairs(boxHighlights) do
		targets[#targets + 1] = ball
	end
	clearBoxHighlights()

	if #targets == 0 then return end

	-- Read before selling, because selling destroys them.
	local info = {}
	for _, ball in ipairs(targets) do
		info[ball] = { pos = ball.Position, size = ball:GetAttribute("TargetSize") or ball.Size.X }
	end

	-- One message for the whole selection, and the balls themselves go
	-- immediately — same reasoning as the single sell above. It hands
	-- back which ones it actually sold, and only those get the flash and
	-- the selling mark. Anything the board refused is left exactly as it
	-- was: still on screen, still sellable a moment later.
	--
	-- This used to mark and flash every target first and ignore what the
	-- board said, which is how an orb could end up permanently marked as
	-- "being sold" while still sitting there — and never be sellable again.
	local sold = ClientBoard.sellBox(targets)

	local sumPos, count = Vector3.new(), 0
	for _, ball in ipairs(targets) do
		if sold[ball] then
			selling[ball] = true
			removeSellableHighlight(ball)
			local i = info[ball]
			sumPos += i.pos
			count += 1
			sellFlash(i.pos, i.size, HIGHLIGHT_COLOR)
		end
	end

	if count > 0 then
		localSellSound(sumPos / count)
	end
end

RS.RenderStepped:Connect(updateBoxSelect)

UIS.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 and boxSelecting then
		finalizeBoxSelect()
	end
end)

-- shared by the "1" keybind, the toolbar button, and the exclusivity
-- handshake below, so all three flip sell mode the exact same way.
-- Takes the target state directly (rather than always flipping)
-- because ToolbarPanels needs to be able to force sell mode OFF from
-- outside when the shop or mimic panel opens.
local function setSellMode(open)
	sellMode = open
	-- GrabClient reads this to block a left-click grab while sell mode
	-- is active (E should still work) — an attribute rather than a
	-- shared module since these are two independent LocalScripts and
	-- this is the same live-readable-from-anywhere pattern AFKHandler
	-- already uses for "AFK"
	player:SetAttribute("SellMode", sellMode)
	if sellMode then
		ToolbarPanels.notifyOpened("sell") -- tells shop/mimic to close themselves; also plays the toggle cue
	else
		ToolbarPanels.notifyClosed("sell") -- plays the toggle cue
	end
	setAllSellDisplays(sellMode)
	setSellButtonHighlighted(sellMode)
	setAllSellableHighlights(sellMode)
	if not sellMode then
		clearHighlight()
		cancelBoxSelect() -- no-ops if a drag wasn't actually in progress
	end
end

local function toggleSellMode()
	setSellMode(not sellMode)
end

sellButton.MouseButton1Click:Connect(toggleSellMode)

-- the other side of the same handshake: close sell mode the instant
-- the shop or mimic panel opens, so the three act as one exclusive
-- group instead of stacking
ToolbarPanels.PanelOpened:Connect(function(id)
	if id ~= "sell" and sellMode then
		setSellMode(false)
	end
end)

-- same exclusivity idea, one more trigger: going AFK closes sell
-- mode too, so a highlighted "sellable" ball doesn’t sit there
-- glowing while every click on it is now a no-op — and disables the
-- toolbar button itself for as long as AFK stays on (see
-- setSellButtonDisabled above)
player:GetAttributeChangedSignal("AFK"):Connect(function()
	local afk = player:GetAttribute("AFK")
	setSellButtonDisabled(afk)
	if afk and sellMode then
		setSellMode(false)
	end
end)

UIS.InputBegan:Connect(function(input, processed)
	if processed then return end

	-- Active = false on the button (see setSellButtonDisabled) only
	-- blocks the click; the "1" key bypasses the button entirely, so
	-- it needs the same AFK check spelled out here
	if input.KeyCode == Enum.KeyCode.One and not player:GetAttribute("AFK") then
		toggleSellMode()

	elseif input.UserInputType == Enum.UserInputType.MouseButton1 and sellMode and hovered and not selling[hovered] and not hovered:GetAttribute("PendingSell") and isSellable(hovered) and not player:GetAttribute("AFK") then
		-- AFKHandler owns this attribute; SellHandler rejects the
		-- request server-side too, but that alone still let the
		-- click-predicted sell below (sound/flash/hide, all fired
		-- before any round trip) play out locally regardless — this
		-- is what actually stops that
		-- the PendingSell check above is re-read live here rather than
		-- trusted from whenever updateHover last ran: updateHover only
		-- re-evaluates a target when the mouse moves onto a *different*
		-- part (see its early "target == hovered" return), so a ball
		-- that goes PendingSell while still sitting under an unmoving
		-- mouse wouldn't otherwise get caught until the next hover
		-- change. This is what actually stops the race that caused the
		-- extra flash: two players clicking the same ball back-to-back
		-- with no mouse movement in between. isSellable(hovered) is the
		-- same live re-check for the same reason, just covering a magnet
		-- that starts pulling (see MagnetFuse) while still sitting under
		-- an unmoving mouse.
		local ball = hovered
		-- Read off the ball while it still exists: the sell below
		-- destroys it.
		local pos = ball.Position
		local size = ball:GetAttribute("TargetSize") or ball.Size.X
		local flashColor = colorFor(ball)
		local isBomb = ball.Name == bombT.Name

		-- The board answers FIRST, and nothing is marked or played unless
		-- it actually sold. This used to be the other way round, with the
		-- answer ignored — so a refused sell left the ball on screen
		-- marked in `selling`, which hover and box select both skip, and
		-- it could never be sold again. See ClientBoard.canSell.
		if ClientBoard.sell(ball) then
			selling[ball] = true

			localSellSound(pos) -- instant — doesn't wait on the server round trip
			if isBomb then
				-- layered alongside the normal sell sound above, not
				-- instead of it
				localSellSound(pos, DEFUSE_SND_ID, DEFUSE_VOL, DEFUSE_PITCH)
			end
			-- Nothing to predict any more: the ball is a part on this
			-- machine, so the flash plays and it's simply gone. All the
			-- hiding that used to live here — LocalTransparencyModifier,
			-- Anchored, CanCollide, CanQuery, disabling the display —
			-- existed because the real ball had to stick around another
			-- 0.3s for everyone else's benefit. There is no everyone else
			-- on this board.
			clearHighlight()
			removeSellableHighlight(ball)
			sellFlash(pos, size, flashColor)
		end

	elseif input.UserInputType == Enum.UserInputType.MouseButton1 and sellMode and not player:GetAttribute("AFK") then
		-- fell through the single-sell branch above — not currently
		-- hovering anything sellable — so this click-and-hold starts a
		-- box select instead (see beginBoxSelect above). Covers empty
		-- space, a bomb/magnet that isn't sellable right now, a ball
		-- already mid-sell, all of it, same as the comment on
		-- beginBoxSelect's own block describes.
		beginBoxSelect()
	end
end)

-- render sale announcements through the default chat system rather than
-- Sound-style RemoteEvent plumbing, since this is text, not audio.
-- `channelName` is SellService's target for this particular message —
-- "Logs" for the routine sell log (see LOG_CHANNEL there), nil for
-- anything meant to land in the normal channel instead. The
-- collapse-penalty message fires here twice, once with each, so it
-- shows up in both.
local broadcastChannels = { Logs = logsChannel }
local ok, general = pcall(function()
	return TCS.TextChannels.RBXGeneral
end)
if ok then
	broadcastChannels.RBXGeneral = general
end

-- `ping` is true for the automated system's own lines (the collapse
-- alert, the fine, the quip, a bribe's reaction). Those used to play
-- their cue through a separate SoundEvents fire to everyone; now the
-- line and its sound arrive together, and only for the player the line
-- is about.
sellBroadcast.OnClientEvent:Connect(function(message, channelName, ping)
	local channel = (channelName and broadcastChannels[channelName]) or broadcastChannels.RBXGeneral
	if channel then
		channel:DisplaySystemMessage(message)
	end
	if ping then
		BoardEffects.flatSound(BoardConfig.SOUNDS.collapseMessage)
	end
end)