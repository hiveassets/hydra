--[[
    FOVController (ModuleScript)
    Path: ReplicatedStorage
    Parent: ReplicatedStorage
    Exported: 2026-09-20 22:14:29
]]
--[[
	FOVController (ModuleScript — place in ReplicatedStorage)

	Camera.FieldOfView has exactly one value at a time, but several
	unrelated systems want to drive it: Sprint (a base FOV depending on
	movement speed), CollapseEffectsClient (a temporary zoom-in during
	the collapse telegraph), and DashClient (a brief widening on each
	dash). Having any two of them tween the property directly means
	whichever TweenService:Create call happens last simply wins every
	Heartbeat — the other tween keeps running underneath it, so they
	visibly fight, and whichever side loses has no way to know it needs
	to resume once it would normally be driving the camera again.

	Instead, this composes three independent layers every frame rather
	than ever writing Camera.FieldOfView from more than one place:

	  base       — Sprint's target FOV (walk vs sprint), tweened.
	  scale      — the collapse zoom-in divisor (1 = no zoom, 1.5 = zoomed
	               to base/1.5), tweened.
	  multiplier — the dash widening (1 = none, 1.25 = 25% wider than
	               whatever base currently is), tweened.

	Final FOV = base * multiplier / scale. Every layer is a plain
	"always applies" number that only modulates the others, so none of
	them ever needs to fully replace, wait on, or hand back to another.
	That's what let the dash's old flat-FOV "override" layer go away: a
	fixed number unrelated to base had to remember to hand back to
	whatever base *currently* targeted when the dash ended (the player
	may have pressed or released Shift mid-dash), which took a flag, a
	seeded value, and a deferred hand-off. As a multiplier of base's
	live value it just resolves itself — dashing while walking widens
	from the walk FOV, dashing while sprinting widens from the sprint
	FOV, and Shift changing mid-dash is picked up on the very next
	frame with no extra calls.

	One RenderStepped callback recomputes camera.FieldOfView from all of
	these each frame, so all of this runs genuinely in parallel —
	changing one layer never has to check, wait on, or know anything
	about the others, and there's no "who owns the camera right now"
	handoff for any side to get stuck on.
]]

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local FOVController = {}

local BIND_NAME = "FOVController"

-- Roblox clamps Camera.FieldOfView to this range itself; clamping here
-- too keeps a stacked multiplier (dash while sprinting) from asking for
-- more than the engine will actually give
local MIN_FOV, MAX_FOV = 1, 120

local startCamera = workspace.CurrentCamera
local base = Instance.new("NumberValue")
base.Value = startCamera and startCamera.FieldOfView or 70
local scale = Instance.new("NumberValue")
scale.Value = 1
local multiplier = Instance.new("NumberValue")
multiplier.Value = 1

local baseTween, scaleTween, multiplierTween

local function apply()
	local camera = workspace.CurrentCamera
	if not camera then return end
	local s = scale.Value
	camera.FieldOfView = math.clamp(base.Value * multiplier.Value / (s ~= 0 and s or 1), MIN_FOV, MAX_FOV)
end
RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, apply)

-- Omitting tweenInfo (or passing nil) snaps instantly instead of
-- easing — used for the hard collapse cut, so the zoom can drop off in
-- the same beat as everything else that snaps there.
function FOVController.SetBase(value, tweenInfo)
	if baseTween then
		baseTween:Cancel()
		baseTween = nil
	end
	if tweenInfo then
		baseTween = TweenService:Create(base, tweenInfo, { Value = value })
		baseTween:Play()
	else
		base.Value = value
	end
end

function FOVController.SetScale(value, tweenInfo)
	if scaleTween then
		scaleTween:Cancel()
		scaleTween = nil
	end
	if tweenInfo then
		scaleTween = TweenService:Create(scale, tweenInfo, { Value = value })
		scaleTween:Play()
	else
		scale.Value = value
	end
end

-- Widens (>1) or narrows (<1) whatever base currently is by this
-- factor; 1 is "no effect". DashClient pushes its multiplier with this
-- and puts it back with SetMultiplier(1, tweenInfo) — a fresh call
-- cancels any tween still in flight and eases from wherever the value
-- actually is right now, so a second dash landing before the first
-- one's ease-out finishes doesn't pop. Same snap-on-nil-tweenInfo
-- behavior as SetBase/SetScale.
function FOVController.SetMultiplier(value, tweenInfo)
	if multiplierTween then
		multiplierTween:Cancel()
		multiplierTween = nil
	end
	if tweenInfo then
		multiplierTween = TweenService:Create(multiplier, tweenInfo, { Value = value })
		multiplierTween:Play()
	else
		multiplier.Value = value
	end
end

return FOVController