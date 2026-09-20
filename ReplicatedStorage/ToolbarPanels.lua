--[[
    ToolbarPanels (ModuleScript)
    Path: ReplicatedStorage
    Parent: ReplicatedStorage
    Exported: 2026-09-20 20:00:08
]]
--[[
	ToolbarPanels (ModuleScript) — ReplicatedStorage

	Shared client-side coordinator so the toolbar's sell/shop/mimic
	toggles behave like the default Roblox toolbar: opening one closes
	whichever other one is currently open, instead of letting them
	stack. Purely local UI state — nothing here ever touches the
	server or another player. Each client gets its OWN BindableEvent
	the moment it requires this module: a ModuleScript's returned
	value is cached per-VM (i.e. per client), so this isn't shared or
	replicated the way an Instance sitting in ReplicatedStorage on its
	own would be — it's just a convenient, already-everyone-can-see-it
	place for three independent LocalScripts to require the same
	small piece of glue.

	Usage (see SellClient / ShopClient / PetConfigClient):

		local ToolbarPanels = require(Rep:WaitForChild("ToolbarPanels"))

		-- whenever THIS panel opens (key or button, doesn't matter):
		ToolbarPanels.notifyOpened("shop") -- also plays the toggle cue

		-- whenever THIS panel closes, for any reason (key, button, or
		-- another panel forcing it shut via PanelOpened below):
		ToolbarPanels.notifyClosed("shop") -- also plays the toggle cue

		-- close this panel if a DIFFERENT one just opened:
		ToolbarPanels.PanelOpened:Connect(function(id)
			if id ~= "shop" and shopOpen then
				setShopOpen(false)
			end
		end)

	Ids in use: "sell", "shop", "mimic". Only ever fire notifyOpened
	on the transition INTO open — never on close — or every close
	would immediately bounce back around and re-close whatever's
	already closed (harmless, but pointless event traffic). notifyClosed
	carries no such restriction since it doesn't fire PanelOpened at all;
	call it on every close.

	Also owns the shared open/close toggle cue all three menus play. This
	used to be 3 separate copies (one per script) — worth centralizing
	regardless since the id/volume were already required to be identical
	across all three, but ALSO fixes a real bug: shop's and mimic's
	copies each parented their Sound to PlayerGui, which isn't a
	supported location for background/non-positional audio (Roblox's own
	Sound docs: background audio needs to be parented directly to
	Workspace or SoundService — PlayerGui doesn't count). Sell's copy
	worked because it happened to parent to SoundService. One Sound
	here, parented correctly, means this can't drift out of sync again.

	Also owns hiding the PlayerList leaderboard while shop or mimic is
	open (sell does not hide it — see HIDES_LEADERBOARD below) — this
	used to be 2 separate copies (ShopClient/PetConfigClient),
	each with their own private "what was PlayerList enabled to before
	I hid it" flag, and that's what caused a real bug: switching
	straight from one panel to the other (shop -> mimic or back) with
	the leaderboard on would leave it stuck permanently hidden after a
	visible flicker.

	The cause is that BindableEvent:Fire is deferred — connected
	handlers don't run synchronously, they run after the CURRENT
	function finishes. So e.g. opening mimic while shop is open used to
	go: mimic's notifyOpened fires the event (queued, not run yet) ->
	mimic reads PlayerList's CURRENT state (already false, since shop
	has it hidden) as "what to restore later" -> mimic hides it (already
	hidden, no-op) -> THEN, only now, the deferred event actually runs
	shop's PanelOpened handler, which closes shop and restores PlayerList
	to shop's OWN snapshot (true) — stomping the hide mimic just did. From
	then on mimic's remembered "restore to" value is the wrong one (false,
	captured mid-transition instead of the real original state), so the
	leaderboard stays hidden even after every panel closes.

	Two independent snapshots racing against a deferred event is the
	actual bug — fixing it means having exactly ONE snapshot, owned here,
	that only the panel CURRENTLY holding the hide is allowed to clear.
	See leaderboardHiddenBy/leaderboardWasEnabled below.
]]

local SoundService = game:GetService("SoundService")
local StarterGui = game:GetService("StarterGui")
local ContentProvider = game:GetService("ContentProvider")

local ToolbarPanels = {}

local event = Instance.new("BindableEvent")
ToolbarPanels.PanelOpened = event.Event -- fires with the id of whichever panel just opened

-- preloading + reusing one persistent Sound (reset TimePosition + Play
-- again, instead of a fresh Instance.new/Play/Destroy every toggle) is
-- what makes playback immediate and consistent every time — see
-- ShopClient/PetConfigClient's old per-script comments for the same
-- reasoning, now applied in the one place that actually needs it
local TOGGLE_SND_ID, TOGGLE_VOL = "rbxasset://Sounds/SWITCH3.wav", 0.3
ContentProvider:PreloadAsync({ TOGGLE_SND_ID })

local toggleSound = Instance.new("Sound")
toggleSound.SoundId = TOGGLE_SND_ID
toggleSound.Volume = TOGGLE_VOL
toggleSound.Parent = SoundService -- NOT PlayerGui — see header

local function playToggleSound()
	toggleSound.TimePosition = 0
	toggleSound:Play()
end

-- ── shared leaderboard hide/show ─────────────────────────────────────
-- leaderboardHiddenBy: the id of whichever panel is CURRENTLY
-- responsible for PlayerList being hidden, or nil if nothing's hiding
-- it. leaderboardWasEnabled: PlayerList's state from BEFORE the FIRST
-- panel in the current streak hid it — captured once, on the
-- nil -> non-nil transition only, and only ever consumed by the one
-- notifyClosed call that brings leaderboardHiddenBy back to nil. This
-- single pair (instead of one private copy per panel script) is what
-- makes restoring correct regardless of how notifyOpened/notifyClosed
-- calls happen to interleave with the deferred PanelOpened event — see
-- this module's header for the bug that caused.
local leaderboardHiddenBy = nil
local leaderboardWasEnabled = true

-- only these panels hide the leaderboard — "sell" opens/closes like
-- normal (toggle cue, PanelOpened event, closes the other panels via
-- each script's own PanelOpened handler) but never touches PlayerList
local HIDES_LEADERBOARD = { shop = true, mimic = true }

function ToolbarPanels.notifyOpened(id)
	playToggleSound()

	if HIDES_LEADERBOARD[id] then
		if leaderboardHiddenBy == nil then
			leaderboardWasEnabled = StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.PlayerList)
		end
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
		leaderboardHiddenBy = id
	end

	event:Fire(id)
end

function ToolbarPanels.notifyClosed(id)
	playToggleSound()

	-- only restore if THIS id is the one currently holding the hide —
	-- if a different panel already took over (e.g. this close is the
	-- indirect result of that other panel opening and forcing this one
	-- shut), leave PlayerList alone; the new holder owns it now
	if leaderboardHiddenBy == id then
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, leaderboardWasEnabled)
		leaderboardHiddenBy = nil
	end
end

return ToolbarPanels