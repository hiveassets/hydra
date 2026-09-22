--[[
    TopbarClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-22 13:33:39
]]
--[[
	TopbarClient (LocalScript) — StarterPlayerScripts

	One topbar container icon ("QuickSettingsIcon") holding both toggles
	side by side via a fixed menu (Icon:setFixedMenu — see
	https://1foreverhd.github.io/TopbarPlus/features/#menus), which is
	always open with its close button hidden — both icons are visible
	the moment the topbar loads, no click on the container needed to
	reveal them. Both are plain on/off toggles that don't auto-close
	each other (autoDeselect(false)), since pressing one has nothing to
	do with the other:

	1. AFK — fires AFKToggle on every click. AFKToggle carries no
	   payload — the server treats each fire as "flip whatever my AFK
	   state currently is" and is the sole source of truth for what AFK
	   actually does (highlight, ball collision, sell-blocking — see
	   AFKHandler's header). This script only drives the button's own
	   look; nothing here reads the AFK attribute back, so
	   icon.isSelected mirrors the server's state purely by convention
	   (every click flips both in lockstep) — same class of
	   trust-the-round-trip risk sellRequest itself already carries
	   elsewhere in this codebase.

	2. Mute — fires the client-only MusicMuteToggle BindableEvent that
	   MusicClient listens on (StarterPlayerScripts). Unlike AFK this
	   never touches the server: muting is purely local, so there's no
	   round trip to trust and no risk of it silently affecting anyone
	   else's audio. Uses an icon image instead of a text label.

	Requires the TopbarPlus Icon module to be installed somewhere under
	ReplicatedStorage (see https://1foreverhd.github.io/TopbarPlus/installation/).
]]

local Rep = game:GetService("ReplicatedStorage")

local Icon = require(Rep:WaitForChild("Icon"))

local afkToggle = Rep:WaitForChild("AFKToggle")
local muteToggleEvent = Rep:WaitForChild("MusicMuteToggle")

local afkIcon = Icon.new()
	:setName("AFK")
	:setLabel("AFK")
	:autoDeselect(false)

afkIcon:bindEvent("toggled", function(self, isSelected)
	afkToggle:FireServer()
end)

local muteIcon = Icon.new()
	:setName("MusicMute")
	:setImage("rbxassetid://118938013363985")
	:modifyTheme({
		{"IconImageScale", "Value", 0.7}
	})
	:autoDeselect(false)


muteIcon:bindEvent("toggled", function(self, isSelected)
	muteToggleEvent:Fire(isSelected)
end)

-- the container both toggles actually live inside. setFixedMenu (not
-- setMenu) specifically: setMenu hides its icons behind a click on the
-- container first, whereas setFixedMenu is "always selected" with its
-- close button hidden — AFK and Mute are just always visible side by
-- side, no extra click to reveal them.
local quickSettingsIcon = Icon.new()
	:setName("QuickSettingsIcon")
	:setLabel("Menu")
	:setFixedMenu({ afkIcon, muteIcon })