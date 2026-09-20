--[[
    CameraUI (ModuleScript)
    Path: StarterPlayer → StarterPlayerScripts → PlayerModule → CameraModule
    Parent: CameraModule
    ⚠️  NESTED SCRIPT: This script is inside another script
    Exported: 2026-09-20 20:00:09
]]
--!nonstrict
local StarterGui = game:GetService("StarterGui")

local initialized = false

local CameraUI: any = {}

do
	-- Instantaneously disable the toast or enable for opening later on. Used when switching camera modes.
	function CameraUI.setCameraModeToastEnabled(enabled: boolean)
		if not enabled and not initialized then
			return
		end

		if not initialized then
			initialized = true
		end
		
		if not enabled then
			CameraUI.setCameraModeToastOpen(false)
		end
	end

	function CameraUI.setCameraModeToastOpen(open: boolean)
		assert(initialized)

		if open then
			StarterGui:SetCore("SendNotification", {
				Title = "Camera Control Enabled",
				Text = "Right click to toggle",
				Duration = 3,
			})
		end
	end
end

return CameraUI
