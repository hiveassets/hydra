--[[
	CollapseEffectsClient (LocalScript) — StarterPlayerScripts

	Everything you see during a collapse that isn't a ball: the colour
	grade ramping through the countdown, the instant grey cut when it
	fires, the camera shake, the FOV push, and the ease back to normal
	afterwards.

	WHAT CHANGED

	This script used to be a dumb tweener driven by a RemoteEvent, and it
	existed because the server tweening a shared ColorCorrectionEffect
	arrives in uneven bursts — fine in principle, jittery in practice.
	The reasoning holds, there's just no server left in the loop: the
	collapse is this player's own board, so ClientBoard fires a plain
	BindableEvent and everything below runs on the machine that's about
	to render it.

	That also means the target values are worked out here, from
	BoardConfig, rather than being computed server-side and sent over. It
	reads better anyway: the ramp knows what it's ramping towards.

	The baseline it eases back to is whatever the map's own colour
	grading was at startup, read once rather than assumed, so Studio-side
	grading survives a collapse. See the note on `base` below for why
	"once" matters more than it looks.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("BoardConfig"))
local Protocol = require(ReplicatedStorage:WaitForChild("BoardProtocol"))
local FOVController = require(ReplicatedStorage:WaitForChild("FOVController"))
local ClientBoard = require(script.Parent:WaitForChild("ClientBoard"))

local V = Config.COLLAPSE_VISUALS
local Phase = Protocol.Collapse

-- Reuse the map's own grading if it has one rather than fighting it
-- with a second effect.
local cc = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
if not cc then
	cc = Instance.new("ColorCorrectionEffect")
	cc.Parent = Lighting
end

-- Every tween currently touching cc. Saturation is tweened separately
-- from Contrast/TintColor during the build, because TweenService only
-- allows one easing style per Create() and the two want different
-- curves — so this is a list, but the rule is the same: every handler
-- clears it before adding its own, so nothing is ever left fighting
-- over cc's properties.
local activeTweens = {}

local function stopActiveTweens()
	for _, tween in ipairs(activeTweens) do
		tween:Cancel()
	end
	table.clear(activeTweens)
end

-- The map's true values, read ONCE, here, before anything in this file
-- has had a chance to touch them.
--
-- The first version captured this lazily, when a telegraph started, and
-- that quietly ratcheted: a telegraph that gets cancelled eases back to
-- baseline over half a second, and a collapse eases back over a full
-- second, so any new telegraph starting inside either of those windows
-- captured a mid-fade value as its "baseline" — and then restored to
-- that. Do it a few times in a row, which a board that keeps
-- re-crossing the overflow line does easily, and contrast walks
-- steadily upward and never comes back to where it started.
--
-- Nothing else in the game writes to this effect, and the map's own
-- grading is authored in Studio rather than changed at runtime, so one
-- reading at startup is the true one for the whole session.
local base = {
	saturation = cc.Saturation,
	contrast = cc.Contrast,
	tint = cc.TintColor,
}

-- ── camera shake ─────────────────────────────────────────────────────
-- A NumberValue is tweened from 0 up to the target intensity, and a
-- RenderStepped callback reads whatever it currently is each frame to
-- size the jitter. Bound at Camera priority + 1 so it runs AFTER the
-- camera script has set camera.CFrame for the frame — it perturbs that
-- fresh value rather than fighting it, and since nothing accumulates
-- frame to frame, unbinding snaps straight back to normal with no
-- separate reset step.
local SHAKE_BIND_NAME = "CollapseTelegraphShake"

local rng = Random.new()
local shakeIntensity = Instance.new("NumberValue")
shakeIntensity.Value = 0
local shakeTween = nil
local shaking = false

local function applyShakeThisFrame()
	local camera = workspace.CurrentCamera
	local intensity = shakeIntensity.Value
	if not camera or intensity <= 0 then
		return
	end
	local posOffset = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1)) * intensity
	local rotOffset = CFrame.Angles(
		math.rad(rng:NextNumber(-1, 1) * intensity * 4),
		math.rad(rng:NextNumber(-1, 1) * intensity * 4),
		math.rad(rng:NextNumber(-1, 1) * intensity * 4)
	)
	camera.CFrame = camera.CFrame * CFrame.new(posOffset) * rotOffset
end

local function startShaking()
	if shaking then
		return
	end
	shaking = true
	RunService:BindToRenderStep(SHAKE_BIND_NAME, Enum.RenderPriority.Camera.Value + 1, applyShakeThisFrame)
end

local function stopShaking()
	if not shaking then
		return
	end
	shaking = false
	RunService:UnbindFromRenderStep(SHAKE_BIND_NAME)
end

-- Builds exponentially over the same window as the colour ramp,
-- matching the Contrast/Tint curve rather than the linear Saturation —
-- the shake is meant to escalate, not drain steadily.
local function startShake(duration, targetIntensity)
	if shakeTween then
		shakeTween:Cancel()
	end
	startShaking()
	shakeTween = TweenService:Create(
		shakeIntensity,
		TweenInfo.new(duration, Enum.EasingStyle.Exponential, Enum.EasingDirection.In),
		{ Value = targetIntensity }
	)
	shakeTween:Play()
end

-- False alarm: ease back to still, then stop the render-step binding
-- once it's actually reached zero, rather than leaving a permanently
-- connected always-zero callback running every frame forever.
local function fadeOutShake(fadeTime)
	if shakeTween then
		shakeTween:Cancel()
	end
	shakeTween = TweenService:Create(
		shakeIntensity,
		TweenInfo.new(fadeTime, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
		{ Value = 0 }
	)
	local thisTween = shakeTween
	thisTween.Completed:Connect(function(playbackState)
		if playbackState == Enum.PlaybackState.Completed and shakeTween == thisTween then
			stopShaking()
		end
	end)
	shakeTween:Play()
end

-- Genuine collapse: cut straight back to the default camera position,
-- matching the instant grey cut rather than fading.
local function cutShake()
	if shakeTween then
		shakeTween:Cancel()
		shakeTween = nil
	end
	shakeIntensity.Value = 0
	stopShaking()
end

-- ── the four beats ───────────────────────────────────────────────────

local function telegraphStart()
	local b = base
	stopActiveTweens()

	local duration = Config.OVERFLOW_SUSTAIN

	-- Saturation ramps linearly: a flat, steady drain rather than the
	-- accelerating build Contrast and Tint get.
	local satTween = TweenService:Create(cc, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
		Saturation = b.saturation + V.telegraphSaturation,
	})
	satTween:Play()
	table.insert(activeTweens, satTween)

	-- Exponential/In so Contrast and Tint ease in gently and accelerate
	-- toward their peak — one continuous motion across the countdown,
	-- landing exactly as it reaches zero.
	local contrastTintTween = TweenService:Create(
		cc,
		TweenInfo.new(duration, Enum.EasingStyle.Exponential, Enum.EasingDirection.In),
		{
			Contrast = b.contrast + V.telegraphContrast,
			TintColor = b.tint:Lerp(V.telegraphTint, V.telegraphTintIntensity),
		}
	)
	contrastTintTween:Play()
	table.insert(activeTweens, contrastTintTween)

	startShake(duration, V.telegraphShake)

	-- Zoom in over the same build, through FOVController rather than
	-- touching Camera.FieldOfView directly — Sprint drives the same
	-- property for its own reasons, and layering means the two run in
	-- parallel instead of fighting.
	FOVController.SetScale(1.3, TweenInfo.new(duration, Enum.EasingStyle.Exponential, Enum.EasingDirection.In))
end

local function telegraphCancel()
	stopActiveTweens()

	local fadeTime = V.telegraphCancelFade
	-- Exponential/Out mirrors the build: quick at first, easing out as
	-- it settles back. Deliberately faster than a real collapse's own
	-- fade — standing down should read as a false alarm, not a
	-- leisurely recovery.
	local cancelTween = TweenService:Create(
		cc,
		TweenInfo.new(fadeTime, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
		{
			Saturation = base.saturation,
			Contrast = base.contrast,
			TintColor = base.tint,
		}
	)
	cancelTween:Play()
	table.insert(activeTweens, cancelTween)

	fadeOutShake(fadeTime)
	FOVController.SetScale(1, TweenInfo.new(fadeTime, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out))
end

local function collapseCut()
	local b = base
	stopActiveTweens()

	-- Instant, no tween: the collapse firing should read as a hard cut.
	-- TintColor goes back to the map's own, so this lands as genuinely
	-- grey rather than grey tinted magenta by the build-up.
	cc.Saturation = -1
	cc.Contrast = b.contrast + V.contrastBoost
	cc.TintColor = b.tint

	cutShake()

	-- The zoom snaps off here rather than at the end of the whole
	-- sell-off and penalty sequence, which can run several seconds
	-- later and would otherwise leave the camera zoomed the whole time.
	FOVController.SetScale(1)
end

local function collapseResolve()
	stopActiveTweens()

	-- TintColor as well as the other two. The cut already put it back,
	-- so this is belt and braces rather than a fix — but every property
	-- this file ever touches should be named in the one place that
	-- returns things to normal, or the next person to add a boost has
	-- to remember to add it here too.
	local resolveTween = TweenService:Create(cc, TweenInfo.new(Config.COLLAPSE_FADE_TIME), {
		Saturation = base.saturation,
		Contrast = base.contrast,
		TintColor = base.tint,
	})
	resolveTween:Play()
	table.insert(activeTweens, resolveTween)
end

-- The telegraph fires once a second while the queue is over the line;
-- the ramp only starts on the first one.
local telegraphing = false

ClientBoard.collapse.Event:Connect(function(phase)
	if phase == Phase.TELEGRAPH then
		if not telegraphing then
			telegraphing = true
			telegraphStart()
		end
	elseif phase == Phase.CANCEL then
		telegraphing = false
		telegraphCancel()
	elseif phase == Phase.CUT then
		telegraphing = false
		collapseCut()
	elseif phase == Phase.RESOLVE then
		collapseResolve()
	end
end)
