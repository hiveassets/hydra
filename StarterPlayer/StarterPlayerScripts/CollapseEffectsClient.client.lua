--[[
    CollapseEffectsClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-20 20:00:09
]]
--[[
	CollapseEffectsClient

	Owns every visual effect tied to the collapse telegraph and the
	collapse itself: ramping Lighting.ColorCorrectionEffect during the
	telegraph, the instant grey cut when a collapse actually fires, and
	the ease back to baseline once it resolves.

	WHY THIS LIVES ON THE CLIENT (not BallManager on the server):
	BallManager used to tween the shared ColorCorrectionEffect directly
	from the server. That works, but every step of that tween has to
	travel server Heartbeat -> network -> this client's own render frame,
	and that hop isn't synced to the client's frame timing. Under any
	real network variance (and this game's server is already busy
	replicating a constantly-spawning ball queue), the property updates
	arrive in uneven little bursts instead of a steady stream — which
	reads as jitter no matter how clean the tween itself is.

	Running the tween here instead means nothing has to cross the
	network mid-tween: TweenService interpolates every property change
	on the same machine that's about to render it, so it's as smooth as
	the client's own frame rate allows.

	Camera shake also lives here now (see the "camera shake" section
	below) — a player's Camera instance isn't accessible from the server
	at all, even in principle, so this was always going to be the only
	place it could live. FOV shift (see the "FOV shift" section below)
	follows the same reasoning.

	PROTOCOL (fired by BallManager on ReplicatedStorage.CollapseVisualEffects):
		"telegraphStart",  duration, targetSaturation, targetContrast, targetTintColor, targetShakeIntensity
		"telegraphCancel", fadeTime, baseSaturation,   baseContrast,   baseTint
		"collapseCut",     targetContrast, targetTintColor   -- instant, no tween
		"collapseResolve", fadeTime, targetSaturation, targetContrast

	The server always sends already-computed target values, never raw
	tuning constants — this script is a dumb tweener with no tuning
	knobs of its own. Even camera shake's intensity comes from the
	server (COLLAPSE_TELEGRAPH_SHAKE_INTENSITY in BallManager.lua) so
	every telegraph tuning value lives in exactly one place.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local vfx = ReplicatedStorage:WaitForChild("CollapseVisualEffects")
local FOVController = require(ReplicatedStorage:WaitForChild("FOVController"))

-- Roblox's default Name for a fresh ColorCorrectionEffect instance is
-- "ColorCorrectionEffect", and BallManager never renames the one it
-- creates — so WaitForChild-by-name here is safe and means this script
-- doesn't have to poll for it if it hasn't replicated down yet.
local cc = Lighting:FindFirstChildOfClass("ColorCorrectionEffect") or Lighting:WaitForChild("ColorCorrectionEffect", 5)

-- Every tween currently touching cc. Saturation gets tweened separately
-- from Contrast/TintColor during the telegraph build (see
-- handlers.telegraphStart) since TweenService only allows one easing
-- style per Create() call, and the two need different curves — so this
-- is a list, not a single tween, but the rule's the same as before:
-- every handler clears it before adding its own, so nothing is ever
-- left fighting over cc's properties.
local activeTweens = {}

local function stopActiveTweens()
	for _, tween in ipairs(activeTweens) do
		tween:Cancel()
	end
	table.clear(activeTweens)
end

-- ── FOV shift ────────────────────────────────────────────────────────
-- Driven through FOVController (see that module's own comment) rather
-- than tweening Camera.FieldOfView here directly — Sprint tweens the
-- same property for its own reasons, and this way the two run in
-- parallel instead of fighting over it or needing any handoff.

-- ── camera shake ─────────────────────────────────────────────────────
-- Driven the same way as the color ramp: a NumberValue's .Value is
-- tweened from 0 up to whatever target intensity BallManager sends,
-- and a RenderStepped callback reads whatever that value currently is
-- each frame to size the jitter it applies. Bound at Camera priority +
-- 1 so it runs AFTER the game's own camera script has already set
-- camera.CFrame for the frame — it perturbs that fresh value rather
-- than fighting it, and since nothing is accumulated frame-to-frame,
-- stopping the binding snaps straight back to whatever the normal
-- camera script wants with no separate "reset" step needed.
local SHAKE_BIND_NAME = "CollapseTelegraphShake"

local rng = Random.new()
local shakeIntensity = Instance.new("NumberValue")
shakeIntensity.Value = 0
local shakeTween = nil
local shaking = false

local function applyShakeThisFrame()
	local camera = workspace.CurrentCamera
	local intensity = shakeIntensity.Value
	if not camera or intensity <= 0 then return end
	local posOffset = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1)) * intensity
	local rotOffset = CFrame.Angles(
		math.rad(rng:NextNumber(-1, 1) * intensity * 4),
		math.rad(rng:NextNumber(-1, 1) * intensity * 4),
		math.rad(rng:NextNumber(-1, 1) * intensity * 4)
	)
	camera.CFrame = camera.CFrame * CFrame.new(posOffset) * rotOffset
end

local function startShaking()
	if shaking then return end
	shaking = true
	RunService:BindToRenderStep(SHAKE_BIND_NAME, Enum.RenderPriority.Camera.Value + 1, applyShakeThisFrame)
end

local function stopShaking()
	if not shaking then return end
	shaking = false
	RunService:UnbindFromRenderStep(SHAKE_BIND_NAME)
end

-- Builds in intensity exponentially over the same `duration` as the
-- color ramp, matching its Contrast/Tint easing rather than the linear
-- Saturation — the shake is meant to escalate, not drain steadily.
local function startShake(duration, targetIntensity)
	if shakeTween then
		shakeTween:Cancel()
	end
	startShaking()
	shakeTween = TweenService:Create(shakeIntensity, TweenInfo.new(duration, Enum.EasingStyle.Exponential, Enum.EasingDirection.In), {
		Value = targetIntensity,
	})
	shakeTween:Play()
end

-- False alarm: eases back to still, same Exponential/Out as the color
-- cancel-fade above, then stops the render-step binding once it's
-- actually reached zero (rather than leaving a permanently-connected,
-- always-zero callback running every frame forever).
local function fadeOutShake(fadeTime)
	if shakeTween then
		shakeTween:Cancel()
	end
	shakeTween = TweenService:Create(shakeIntensity, TweenInfo.new(fadeTime, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {
		Value = 0,
	})
	local thisTween = shakeTween
	thisTween.Completed:Connect(function(playbackState)
		if playbackState == Enum.PlaybackState.Completed and shakeTween == thisTween then
			stopShaking()
		end
	end)
	shakeTween:Play()
end

-- Genuine collapse: cut straight back to the default camera position
-- immediately, matching the instant grey cut rather than fading.
local function cutShake()
	if shakeTween then
		shakeTween:Cancel()
		shakeTween = nil
	end
	shakeIntensity.Value = 0
	stopShaking()
end
-- ─────────────────────────────────────────────────────────────────────

local handlers = {}

function handlers.telegraphStart(duration, targetSaturation, targetContrast, targetTintColor, targetShakeIntensity)
	if not cc then return end
	stopActiveTweens()

	-- Saturation ramps linearly — a flat, steady drain rather than the
	-- accelerating build Contrast/Tint get below.
	local satTween = TweenService:Create(cc, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
		Saturation = targetSaturation,
	})
	satTween:Play()
	table.insert(activeTweens, satTween)

	-- Exponential/In so Contrast/Tint ease in gently at first and
	-- accelerate toward their target — one continuous motion across the
	-- whole countdown, landing at its peak exactly as it reaches 0.
	local contrastTintTween = TweenService:Create(cc, TweenInfo.new(duration, Enum.EasingStyle.Exponential, Enum.EasingDirection.In), {
		Contrast = targetContrast,
		TintColor = targetTintColor,
	})
	contrastTintTween:Play()
	table.insert(activeTweens, contrastTintTween)

	startShake(duration, targetShakeIntensity)

	-- Zoom in over the same build as Contrast/Tint (Exponential/In), so
	-- it lands at its peak — base FOV / 1.5 — exactly as the countdown
	-- hits 0. This is a divisor tweened through FOVController, running
	-- in parallel with whatever Sprint is doing to the base FOV, not a
	-- value captured once off the camera.
	FOVController.SetScale(1.3, TweenInfo.new(duration, Enum.EasingStyle.Exponential, Enum.EasingDirection.In))
end

function handlers.telegraphCancel(fadeTime, baseSaturation, baseContrast, baseTint)
	if not cc then return end
	stopActiveTweens()
	-- Exponential/Out mirrors the Exponential/In build above — fast at
	-- first, then eases out gently as it settles back at baseline,
	-- rather than the flat default easing.
	local cancelTween = TweenService:Create(cc, TweenInfo.new(fadeTime, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {
		Saturation = baseSaturation,
		Contrast = baseContrast,
		TintColor = baseTint,
	})
	cancelTween:Play()
	table.insert(activeTweens, cancelTween)

	fadeOutShake(fadeTime)

	-- False alarm: mirrors the Exponential/Out un-build above, easing
	-- the zoom divisor back to 1.
	FOVController.SetScale(1, TweenInfo.new(fadeTime, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out))
end

function handlers.collapseCut(targetContrast, targetTintColor)
	if not cc then return end
	stopActiveTweens()
	-- Instant, no tween — the collapse itself cutting to grey should
	-- read as a hard cut, not a fade.
	cc.Saturation = -1
	cc.Contrast = targetContrast
	cc.TintColor = targetTintColor

	cutShake()

	-- Zoom snaps off right here, the instant the collapse actually
	-- fires, rather than staying zoomed through the whole sell-off/
	-- penalty sequence until collapseResolve — which can run several
	-- seconds later and would otherwise leave the camera zoomed in (and
	-- Sprint's own FOV changes reading as oddly muted) the entire time.
	-- No tweenInfo = instant, matching the hard cut everything else
	-- here takes.
	FOVController.SetScale(1)
end

function handlers.collapseResolve(fadeTime, targetSaturation, targetContrast)
	if not cc then return end
	stopActiveTweens()
	local resolveTween = TweenService:Create(cc, TweenInfo.new(fadeTime), {
		Saturation = targetSaturation,
		Contrast = targetContrast,
	})
	resolveTween:Play()
	table.insert(activeTweens, resolveTween)
end

vfx.OnClientEvent:Connect(function(kind, ...)
	local handler = handlers[kind]
	if handler then
		handler(...)
	end
end)

--[[
	FOV shift is implemented via FOVController (see its own comment) —
	the SetScale calls in telegraphStart/telegraphCancel/collapseCut
	above.
]]