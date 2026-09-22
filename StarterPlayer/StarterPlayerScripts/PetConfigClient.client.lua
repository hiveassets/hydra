--[[
    PetConfigClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-22 13:33:38
]]
--[[
	PetConfigClient (LocalScript) — StarterPlayerScripts

	Client side of the pet mimic config panel — the "3.mimicButton" /
	"Z" sibling of ShopClient's shop toggle, and deliberately built to
	mirror it closely: same shopOuter-style slide (petOuter here), same
	toolbar-highlight-while-open pattern. The panel starts with its
	ScreenGui Enabled = false (so it can't flash on screen while the
	game loads) and toggles Enabled alongside the Position slide: on as
	soon as it opens, off only once the close tween finishes.

	Layout this expects (see UpgradeData's petMimic entry / ShopClient
	for the sibling shop panel):

	  petConfig (ScreenGui)
	    petOuter (Frame)
	      petInner (Frame)
	        0.enabled (Frame)
	          toggleButton (TextButton)
	            UIStroke
	            decor (TextLabel)
	        1.sizeRange (Frame)
	          minInput (Frame) > input (TextBox)
	          maxInput (Frame) > input (TextBox)
	        2.name (Frame)
	          nameInput (Frame) > input (TextBox)
	        3.color (Frame)
	          colorInput (Frame) > input (TextBox)

	  toolbar.toolbarContainer."3.mimicButton" (mirrors "2.shopButton":
	    a "text"/"number" pair of labels this highlights the same way
	    ShopClient highlights the shop button while it's open)

	The toolbar button — and the whole panel — starts hidden and only
	appears once the player actually owns "petMimic" (Upgrades folder
	populated by LeaderboardSetup on join, or ShopHandler mid-session on
	purchase); there's nothing useful to configure before that. Reads
	the player's current config straight off their PetMimicConfig
	folder (plain replicated Values — no remote needed for reads, same
	as ShopClient reading Upgrades/leaderstats directly) to pre-fill the
	four inputs, and re-submits the FULL set of four on every single
	field's FocusLost — simplest thing that reliably keeps
	UpdatePetMimicConfig's four-field shape in sync without a separate
	"save" button anywhere in the layout above.
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local Rep = game:GetService("ReplicatedStorage")
local TS = game:GetService("TweenService")

local player = Players.LocalPlayer

local TOOLBAR_HIGHLIGHT_COLOR = Color3.fromRGB(255, 255, 0)

local UpgradeData = require(Rep:WaitForChild("UpgradeData"))
local updateConfig = Rep:WaitForChild("UpdatePetMimicConfig")
local setEnabled = Rep:WaitForChild("SetPetMimicEnabled")

-- see ToolbarPanels' own header — lets this panel close itself the
-- moment sell mode or the shop opens, and tells them to do the same
-- when this panel opens, so only one of the three is ever active
local ToolbarPanels = require(Rep:WaitForChild("ToolbarPanels"))

-- same lookup ShopHandler/PetMimicHandler each do their own copy of —
-- confirms the id instead of hardcoding the string a second time here
-- too
local PET_MIMIC_ID = nil
for _, upgrade in ipairs(UpgradeData) do
	if upgrade.id == "petMimic" then
		PET_MIMIC_ID = upgrade.id
		break
	end
end
assert(PET_MIMIC_ID, "PetConfigClient: UpgradeData has no \"petMimic\" entry")

-- shared open/close toggle cue now lives centrally in ToolbarPanels (see
-- its header — it was previously a Sound parented to PlayerGui here,
-- which isn't a supported location for background audio and is why this
-- toggle went silent); notifyOpened/notifyClosed below play it

-- every lookup below is timed out and warns loudly on failure instead
-- of blocking forever the way a bare WaitForChild would — a script
-- hung on one missing element gives zero console feedback and silently
-- takes every OTHER feature in this script down with it (this is almost
-- certainly why an earlier version of this script had both Z and the
-- toolbar button doing nothing at all: one bad WaitForChild anywhere
-- above the input-handling code at the bottom stalls everything below
-- it, forever, with no error). LOOKUP_TIMEOUT is generous — long enough
-- that a slow join never trips it, short enough that a genuine mismatch
-- surfaces in the output within a few seconds instead of hanging
-- the rest of the session.
local LOOKUP_TIMEOUT = 10
local function need(parent, name)
	local inst = parent:WaitForChild(name, LOOKUP_TIMEOUT)
	if not inst then
		warn(("[PetConfigClient] %s is missing %q — check the name/parent match what this script expects"):format(parent:GetFullName(), name))
	end
	return inst
end

local playerGui = player:WaitForChild("PlayerGui")
local gui = need(playerGui, "petConfig")
local petOuter = gui and need(gui, "petOuter")
local petInner = petOuter and need(petOuter, "petInner")

local enabledFrame = petInner and need(petInner, "0.enabled")
local toggleButton = enabledFrame and need(enabledFrame, "toggleButton")
local toggleStroke = toggleButton and need(toggleButton, "UIStroke")
local toggleDecor = toggleButton and need(toggleButton, "decor")

local sizeRangeFrame = petInner and need(petInner, "1.sizeRange")
local minInputFrame = sizeRangeFrame and need(sizeRangeFrame, "minInput")
local minInput = minInputFrame and need(minInputFrame, "input")
local maxInputFrame = sizeRangeFrame and need(sizeRangeFrame, "maxInput")
local maxInput = maxInputFrame and need(maxInputFrame, "input")

local nameFrame = petInner and need(petInner, "2.name")
local nameInputFrame = nameFrame and need(nameFrame, "nameInput")
local nameInput = nameInputFrame and need(nameInputFrame, "input")

local colorFrame = petInner and need(petInner, "3.color")
local colorInputFrame = colorFrame and need(colorFrame, "colorInput")
local colorInput = colorInputFrame and need(colorInputFrame, "input")

-- the panel itself is only usable if every element above actually
-- resolved — if not, this script still keeps running everything else
-- (the toolbar button below is looked up completely independently, so
-- a broken panel doesn't also take the button/Z-key down with it, and
-- vice versa) but setPanelOpen becomes a no-op instead of erroring on a
-- nil petOuter the first time something tries to open it
local panelReady = (petOuter ~= nil) and (toggleButton ~= nil) and (toggleStroke ~= nil) and (toggleDecor ~= nil)
	and (minInput ~= nil) and (maxInput ~= nil) and (nameInput ~= nil) and (colorInput ~= nil)
if not panelReady then
	warn("[PetConfigClient] one or more petConfig panel elements were missing — the panel won't open until the hierarchy matches this script's expectations (see warnings above)")
end

local toolbarContainer = need(playerGui, "toolbar")
toolbarContainer = toolbarContainer and need(toolbarContainer, "toolbarContainer")
local mimicButton = toolbarContainer and need(toolbarContainer, "3.mimicButton")

-- the highlight labels are cosmetic only (the yellow-while-open tint
-- ShopClient's own toolbar button gets) — missing them shouldn't stop
-- the button from actually opening/closing the panel, so these use a
-- plain FindFirstChild (no warning, no blocking) rather than need()
local mimicButtonText = mimicButton and mimicButton:FindFirstChild("text")
local mimicButtonNumber = mimicButton and mimicButton:FindFirstChild("number")
local mimicButtonTextColor = mimicButtonText and mimicButtonText.TextColor3
local mimicButtonNumberColor = mimicButtonNumber and mimicButtonNumber.TextColor3

local function setMimicButtonHighlighted(active)
	if mimicButtonText then
		mimicButtonText.TextColor3 = active and TOOLBAR_HIGHLIGHT_COLOR or mimicButtonTextColor
	end
	if mimicButtonNumber then
		mimicButtonNumber.TextColor3 = active and TOOLBAR_HIGHLIGHT_COLOR or mimicButtonNumberColor
	end
end

-- AFKHandler owns the "AFK" attribute (see its header). Active = false
-- is what actually blocks the click (Roblox GuiButtons stop firing
-- MouseButton1Click etc. once Active is false); the dimmed text is
-- just the visual tell to go with it. Same nil-guarded shape as every
-- other mimicButton-adjacent lookup in this file, since the highlight
-- labels (and even the button itself) are allowed to be missing — see
-- need()'s header comment. The "3" keybind isn’t routed through this
-- button at all, so it needs its own guard — see the InputBegan
-- handler below.
local function setMimicButtonDisabled(disabled)
	if mimicButton then
		mimicButton.Active = not disabled
	end
	if mimicButtonText then
		mimicButtonText.TextTransparency = disabled and 0.5 or 0
	end
	if mimicButtonNumber then
		mimicButtonNumber.TextTransparency = disabled and 0.5 or 0
	end
end

-- colors for the 0.enabled toggle button — see PetMimicHandler's
-- getOrCreateEnabledValue/onPlayerAdded for the actual on/off state
-- this reflects; this function only ever draws whatever
-- petMimicConfig.Enabled.Value currently is, it never decides it.
-- Covers BackgroundColor3, UIStroke.Color, and decor's TextColor3 —
-- NOT decor's Text itself (the "on"/"off" wording), which is set
-- exclusively from the click handler below; see its own comment for why
local TOGGLE_ON_COLOR = Color3.fromRGB(0, 255, 255)
local TOGGLE_ON_STROKE = Color3.fromRGB(0, 0, 0)
local TOGGLE_OFF_COLOR = Color3.fromRGB(0, 0, 0)
local TOGGLE_OFF_ACCENT = Color3.fromRGB(56, 56, 56)

local function applyToggleVisual(enabled)
	if not toggleButton then return end
	toggleButton.BackgroundColor3 = enabled and TOGGLE_ON_COLOR or TOGGLE_OFF_COLOR
	if toggleStroke then
		toggleStroke.Color = enabled and TOGGLE_ON_STROKE or TOGGLE_OFF_ACCENT
	end
	if toggleDecor then
		toggleDecor.TextColor3 = enabled and TOGGLE_ON_COLOR or TOGGLE_OFF_ACCENT
	end
end

local upgrades = player:WaitForChild("Upgrades")
local petMimicConfig = player:WaitForChild("PetMimicConfig")
-- plain replicated Value, same as MinSize/MaxSize/PetName/Color above —
-- server (PetMimicHandler) is what actually resets this to false on
-- join and flips it on/off in response to setEnabled; this script only
-- ever reads it and asks the server to change it, never writes it
-- directly
local mimicEnabledValue = petMimicConfig:WaitForChild("Enabled")
mimicEnabledValue.Changed:Connect(applyToggleVisual)

-- ── slide (identical shape to ShopClient's shopOuter handling) ───────
local SLIDE_TIME = 0.25
local CLOSED_SCALE_OFFSET = 0.4

local OPEN_POS, CLOSED_POS
if panelReady then
	OPEN_POS = petOuter.Position
	CLOSED_POS = UDim2.new(
		OPEN_POS.X.Scale + CLOSED_SCALE_OFFSET, OPEN_POS.X.Offset,
		OPEN_POS.Y.Scale, OPEN_POS.Y.Offset
	)
	petOuter.Position = CLOSED_POS -- starts off-screen too, belt-and-suspenders with Enabled below

	-- gui.Enabled now does the actual hiding (see setPanelOpen below);
	-- starting it false means the panel can't flash into view for a frame
	-- while the game is still loading, before this script has even set
	-- petOuter's Position above. Kept in addition to the off-screen
	-- Position rather than instead of it, since re-enabling still relies
	-- on that Position being correct the moment it's flipped back on.
	gui.Enabled = false
end

local OPEN_INFO = TweenInfo.new(SLIDE_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
local CLOSE_INFO = TweenInfo.new(SLIDE_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)

local panelOpen = false
local slideTween

local function setPanelOpen(open)
	if not panelReady then return end -- see the warning logged above — nothing to slide
	panelOpen = open
	setMimicButtonHighlighted(open)

	if open then
		gui.Enabled = true -- flip on right away so the slide-in is visible; the matching flip-off on close waits for the tween instead (see below)
		ToolbarPanels.notifyOpened("mimic") -- tells sell/shop to close themselves; also hides the leaderboard and plays the toggle cue
	else
		ToolbarPanels.notifyClosed("mimic") -- restores the leaderboard (if mimic's still the one holding it hidden) and plays the toggle cue
	end

	if slideTween then
		slideTween:Cancel()
	end
	slideTween = TS:Create(petOuter, open and OPEN_INFO or CLOSE_INFO, { Position = open and OPEN_POS or CLOSED_POS })
	slideTween:Play()

	if not open then
		-- don't disable until petOuter has actually finished sliding off
		-- screen, or the panel would just vanish mid-tween instead of
		-- sliding out. Captures this specific tween so a reopen-before-
		-- close-finishes (which Cancels this tween and starts a fresh one
		-- above) can't have this stale callback turn the gui back off
		-- right after the reopen turned it on; playbackState is only
		-- Completed on a tween that actually ran to the end, never on one
		-- that got Cancel()'d.
		local closingTween = slideTween
		closingTween.Completed:Connect(function(playbackState)
			if playbackState == Enum.PlaybackState.Completed and not panelOpen and slideTween == closingTween then
				gui.Enabled = false
			end
		end)
	end
end

-- the other side of the same handshake: close this panel the instant
-- sell mode or the shop opens, so the three act as one exclusive group
-- instead of stacking
ToolbarPanels.PanelOpened:Connect(function(id)
	if id ~= "mimic" and panelOpen then
		setPanelOpen(false)
	end
end)

-- AFKHandler owns this attribute (see its header) — closes this panel
-- if it happened to be open, and disables the toolbar button for as
-- long as AFK stays on (see setMimicButtonDisabled above)
player:GetAttributeChangedSignal("AFK"):Connect(function()
	local afk = player:GetAttribute("AFK")
	setMimicButtonDisabled(afk)
	if afk and panelOpen then
		setPanelOpen(false)
	end
end)

-- ── ownership gate: button + panel only exist once petMimic is owned ──
local function ownsPetMimic()
	return upgrades:FindFirstChild(PET_MIMIC_ID) ~= nil
end

local function refreshOwnership()
	local owned = ownsPetMimic()
	if mimicButton then
		mimicButton.Visible = owned
	end
	if not owned and panelOpen then
		setPanelOpen(false)
	end
end

-- ── input handling ───────────────────────────────────────────────────
-- clamped/validated the same way PetMimicHandler validates server-side —
-- this copy is just for immediate feedback (snapping the box back to
-- something sane on FocusLost); the server is what actually enforces it
local function sanitizeSizeText(text, fallback)
	local n = tonumber(text)
	if not n then return fallback end
	return math.clamp(math.floor(n + 0.5), 0, 999)
end

-- Luau's utf8 library iterates by *codepoint*, not by user-perceived
-- "symbol" — a single glyph like a flag (🇺🇸) or a family emoji
-- (👨‍👩‍👧‍👦) is actually several codepoints stitched together via
-- zero-width joiners, variation selectors, skin-tone modifiers, or
-- paired regional-indicator letters. Kept as its own copy rather than a
-- shared module, same reasoning as sanitizeSizeText below — this is
-- just for immediate feedback, PetMimicHandler's own copy is what
-- actually enforces it server-side. MUST be kept in sync with that copy.
local ZWJ = 0x200D
local VARIATION_SELECTOR_16 = 0xFE0F
local COMBINING_MARK_MIN, COMBINING_MARK_MAX = 0x0300, 0x036F
local REGIONAL_INDICATOR_MIN, REGIONAL_INDICATOR_MAX = 0x1F1E6, 0x1F1FF
local SKIN_TONE_MIN, SKIN_TONE_MAX = 0x1F3FB, 0x1F3FF

local function isContinuation(cp, prevCp)
	if cp == ZWJ then return true end
	if cp == VARIATION_SELECTOR_16 then return true end
	if cp >= COMBINING_MARK_MIN and cp <= COMBINING_MARK_MAX then return true end
	if cp >= SKIN_TONE_MIN and cp <= SKIN_TONE_MAX then return true end
	if prevCp == ZWJ then return true end
	if prevCp and prevCp >= REGIONAL_INDICATOR_MIN and prevCp <= REGIONAL_INDICATOR_MAX
		and cp >= REGIONAL_INDICATOR_MIN and cp <= REGIONAL_INDICATOR_MAX then
		return true
	end
	return false
end

local function splitIntoSymbols(str)
	if not utf8.len(str) then
		return nil
	end
	local starts, prevCp = {}, nil
	for pos, cp in utf8.codes(str) do
		if not (prevCp and isContinuation(cp, prevCp)) then
			table.insert(starts, pos)
		end
		prevCp = cp
	end
	return starts
end

local function truncateToSymbols(str, maxSymbols)
	local starts = splitIntoSymbols(str)
	if not starts then
		return str:sub(1, maxSymbols)
	end
	if #starts <= maxSymbols then
		return str
	end
	return str:sub(1, starts[maxSymbols + 1] - 1)
end

local function sanitizeNameText(text)
	text = truncateToSymbols(text, 3)
	return text ~= "" and text or "<3"
end

local function sanitizeColorText(text)
	text = text:upper()
	if not text:match("^#") then
		text = "#" .. text
	end
	if text:match("^#%x%x%x%x%x%x$") then
		return text
	end
	return nil -- caller falls back to the last-known-good value
end

-- re-sends the FULL current state of all four inputs — see this
-- script's own header for why a single combined submit on any one
-- field's FocusLost is simpler than wiring up a separate save button
local function submitConfig()
	if not panelReady then return end

	local minSize = sanitizeSizeText(minInput.Text, petMimicConfig.MinSize.Value)
	local maxSize = sanitizeSizeText(maxInput.Text, petMimicConfig.MaxSize.Value)
	if minSize > maxSize then
		minSize, maxSize = maxSize, minSize
	end
	local name = sanitizeNameText(nameInput.Text)
	local color = sanitizeColorText(colorInput.Text) or petMimicConfig.Color.Value

	-- reflect the sanitized values back into the boxes immediately,
	-- rather than waiting on the round trip below, so e.g. typing
	-- "7.6" in a size box snaps to "8" right away instead of sitting
	-- there looking unsanitized until the server responds
	minInput.Text, maxInput.Text, nameInput.Text, colorInput.Text = tostring(minSize), tostring(maxSize), name, color

	local ok = updateConfig:InvokeServer({ minSize = minSize, maxSize = maxSize, name = name, color = color })
	if not ok then
		-- server rejected it (shouldn't normally happen given the
		-- client-side sanitizing above) — just re-pull whatever's
		-- actually saved so the boxes never show a value that didn't
		-- actually take
		minInput.Text = tostring(petMimicConfig.MinSize.Value)
		maxInput.Text = tostring(petMimicConfig.MaxSize.Value)
		nameInput.Text = petMimicConfig.PetName.Value
		colorInput.Text = petMimicConfig.Color.Value
	end
end

if panelReady then
	for _, box in ipairs({ minInput, maxInput, nameInput, colorInput }) do
		box.FocusLost:Connect(submitConfig)
	end

	-- flips the pet on/off. Colors are still fully server-driven (see
	-- applyToggleVisual/mimicEnabledValue.Changed above) so a rejected
	-- toggle just leaves them showing whatever's actually set instead of
	-- snapping back from an optimistic guess. decor's TEXT is different
	-- on purpose: it only ever changes right here, on an actual click —
	-- never from mimicEnabledValue.Changed — so it doesn't also get
	-- silently overwritten by the join-time reset to false or any other
	-- server-side write that isn't this player pressing the button
	toggleButton.MouseButton1Click:Connect(function()
		if not ownsPetMimic() then return end -- button's Visible=false covers this in practice; just defensive
		local wantEnabled = not mimicEnabledValue.Value
		if toggleDecor then
			toggleDecor.Text = wantEnabled and "on" or "off"
		end
		setEnabled:InvokeServer(wantEnabled)
	end)
end

-- pre-fills the four boxes from whatever's currently saved — called
-- once up front and again every time the panel opens, so a config
-- change made on another device (or an admin !wipedata reset — see
-- LeaderboardSetup) is picked up instead of showing stale text
local function refreshInputsFromSaved()
	if not panelReady then return end
	minInput.Text = tostring(petMimicConfig.MinSize.Value)
	maxInput.Text = tostring(petMimicConfig.MaxSize.Value)
	nameInput.Text = petMimicConfig.PetName.Value
	colorInput.Text = petMimicConfig.Color.Value
	applyToggleVisual(mimicEnabledValue.Value)
end

refreshOwnership()
refreshInputsFromSaved()

upgrades.ChildAdded:Connect(refreshOwnership)
upgrades.ChildRemoved:Connect(refreshOwnership)

-- server-driven reset (LeaderboardSetup's wipeUserData/_G.WipePlayerData
-- — see there) fires the same ResetShopUI event ShopClient listens to;
-- reusing it here too instead of a second dedicated event, since a
-- reset always clears/reverts both Upgrades and PetMimicConfig together
local resetShopUI = Rep:WaitForChild("ResetShopUI")
resetShopUI.OnClientEvent:Connect(function()
	refreshOwnership()
	refreshInputsFromSaved()
end)

-- ── toggle ────────────────────────────────────────────────────────
UIS.InputBegan:Connect(function(input, processed)
	if processed then return end
	-- Active = false on the button (see setMimicButtonDisabled) only
	-- blocks the click; the "3" key bypasses the button entirely, so
	-- it needs the same AFK check spelled out here
	if input.KeyCode == Enum.KeyCode.Three and ownsPetMimic() and not player:GetAttribute("AFK") then
		if not panelOpen then
			refreshInputsFromSaved()
		end
		setPanelOpen(not panelOpen)
	end
end)

-- mimicButton might not actually be a GuiButton (ImageButton/TextButton)
-- — if it's a plain Frame with a separate clickable child, or renamed/
-- restructured some other way, MouseButton1Click simply doesn't exist
-- on it. pcall here means that mismatch just warns once instead of
-- throwing an uncaught error (which, this being the last thing in the
-- script, wouldn't break anything ABOVE it, but is still worth
-- surfacing clearly rather than silently doing nothing when clicked).
if mimicButton then
	local ok, err = pcall(function()
		mimicButton.MouseButton1Click:Connect(function()
			if not ownsPetMimic() then return end -- button's Visible=false covers this in practice; just defensive
			if not panelOpen then
				refreshInputsFromSaved()
			end
			setPanelOpen(not panelOpen)
		end)
	end)
	if not ok then
		warn("[PetConfigClient] 3.mimicButton doesn't support MouseButton1Click (" .. tostring(err) .. ") — it needs to be an ImageButton/TextButton, or a button-class descendant needs to be wired up here instead")
	end
end