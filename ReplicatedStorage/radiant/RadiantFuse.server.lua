--[[
    RadiantFuse (Script)
    Path: ReplicatedStorage → radiant
    Parent: radiant
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 15:18:20
]]
--[[
	RadiantFuse (Script) — place inside the Radiant template in
	ReplicatedStorage (ReplicatedStorage.Radiant.RadiantFuse).

	The only thing this owns: looping the ball's Color through a fixed
	rainbow sequence, ~3 seconds per full cycle, for as long as the ball
	is alive and hasn't started selling. Launch, grow-in, physics, and
	the fall-off/respawn behavior all live in BallManager, exactly like
	a regular ball — this script never touches any of that.
]]

local TS = game:GetService("TweenService")

local ball = script.Parent

local COLORS = {
	Color3.fromRGB(255, 0, 0),
	Color3.fromRGB(255, 255, 0),
	Color3.fromRGB(0, 255, 0),
	Color3.fromRGB(0, 255, 255),
	Color3.fromRGB(0, 0, 255),
	Color3.fromRGB(255, 0, 255),
}
local CYCLE_TIME = 3 -- full loop through every color, seconds
local SEGMENT_TIME = CYCLE_TIME / #COLORS
local segmentInfo = TweenInfo.new(SEGMENT_TIME, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut)

-- same PendingSell/Parent reasoning BombFuse's stillLive() uses — stops
-- the loop the instant a sell starts instead of fighting SellService's
-- own highlight/Destroy over this ball's Color.
local function stillLive()
	return ball.Parent ~= nil and not ball:GetAttribute("PendingSell")
end

ball.Color = COLORS[1]

task.spawn(function()
	local idx = 1
	while stillLive() do
		idx = (idx % #COLORS) + 1
		TS:Create(ball, segmentInfo, { Color = COLORS[idx] }):Play()
		task.wait(SEGMENT_TIME)
	end
end)