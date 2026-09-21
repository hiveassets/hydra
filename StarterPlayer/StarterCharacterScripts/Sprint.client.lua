--[[
    Sprint (LocalScript)
    Path: StarterPlayer → StarterCharacterScripts
    Parent: StarterCharacterScripts
    Properties:
        Disabled: false
    Exported: 2026-09-20 22:14:30
]]
local t=game:GetService("TweenService")
local u=game:GetService("UserInputService")
local rs=game:GetService("ReplicatedStorage")
local p=game.Players.LocalPlayer
local h=p.Character:FindFirstChildOfClass("Humanoid")
local i=TweenInfo.new(.5,Enum.EasingStyle.Circular,Enum.EasingDirection.Out)

-- FOV goes through FOVController instead of a direct camera tween, so it
-- composes cleanly with whatever CollapseEffectsClient is doing to FOV
-- at the same time (zooming in for the collapse telegraph) rather than
-- fighting it for the property. See FOVController's own comment — this
-- script never has to know a collapse is happening at all.
local FOVController=require(rs:WaitForChild("FOVController"))

-- Sprinting is now the free "sprint" upgrade in UpgradeData (the shop's
-- tutorial purchase) instead of something everyone starts with. Checked
-- fresh on every press, same as DashClient's ownsDash — cheap, and it
-- only ever runs on a keypress.
local function ownsSprint()
	local upgrades=p:FindFirstChild("Upgrades")
	return upgrades and upgrades:FindFirstChild("sprint")~=nil
end

-- Tracks whether a sprint actually started, so releasing Shift only
-- undoes one that did — otherwise letting go of Shift without owning
-- the upgrade (or after buying it mid-hold) would still snap FOV/speed
-- back to the walk values for no reason.
local sprinting=false

local function f(a,b)
	FOVController.SetBase(a,i)
	t:Create(h,i,{WalkSpeed=b}):Play()
end

u.InputBegan:Connect(function(x,g)
	if g or x.KeyCode~=Enum.KeyCode.LeftShift then return end
	if not ownsSprint() then return end
	sprinting=true
	f(90,32)
end)

u.InputEnded:Connect(function(x,g)
	if g or x.KeyCode~=Enum.KeyCode.LeftShift then return end
	if not sprinting then return end
	sprinting=false
	f(70,16)
end)