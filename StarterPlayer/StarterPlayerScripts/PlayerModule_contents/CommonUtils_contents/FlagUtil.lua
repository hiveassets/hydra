--[[
    FlagUtil (ModuleScript)
    Path: StarterPlayer → StarterPlayerScripts → PlayerModule → CommonUtils
    Parent: CommonUtils
    ⚠️  NESTED SCRIPT: This script is inside another script
    Exported: 2026-09-23 00:26:24
]]
--!strict
-- Utility module for handling User Fast Flags
export type FlagUtilType = {
	-- Gets the user fast flag value if it's available, otherwise returns false. Don't include flag prefix.
	-- Example: local FFlagUserDoStuff = FlagUtil.getUserFlag("UserDoStuff")
	getUserFlag: (string) -> boolean,
}

local FlagUtil: FlagUtilType = {} :: FlagUtilType;

function FlagUtil.getUserFlag(flagName)
	local success, result = pcall(function()
		return UserSettings():IsUserFeatureEnabled(flagName)
	end)
	return success and result
end

return FlagUtil