--[[
    Spin (Script)
    Path: Workspace → spawnsymbol
    Parent: spawnsymbol
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 13:33:39
]]
local p=script.Parent
local r=game:GetService("RunService")
local b=workspace:WaitForChild("Balls")
local spinScale=workspace:WaitForChild("SpinScale") -- BallManager owns this; 0 during an overflow collapse, tweened back to 1 as it fades out
local baseSpeed=math.rad(20)
local boostAmount=math.rad(200)
local boost,elapsed=0,1.5

b.ChildAdded:Connect(function()boost+=boostAmount;elapsed=0 end)

r.Heartbeat:Connect(function(d)
	local scale=spinScale.Value
	if elapsed<1.5 then
		elapsed+=d
		local t=math.clamp(elapsed/1.5,0,1)
		p.CFrame*=CFrame.Angles(0,(baseSpeed+boost*(1-t)^2)*d*scale,0)
		if t>=1 then boost=0 end
	else
		p.CFrame*=CFrame.Angles(0,baseSpeed*d*scale,0)
	end
end)