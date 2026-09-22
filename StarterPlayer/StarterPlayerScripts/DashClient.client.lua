--[[
    DashClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-22 13:33:38
]]
--[[
	DashClient (LocalScript) — StarterPlayerScripts

	Pressing F dashes the player at a fixed speed for a fixed duration,
	gated behind owning the "Dash" upgrade (see UpgradeData/
	ShopHandler) and a per-press cooldown. Direction is read from
	whatever WASD is held at the moment of the press, camera-relative
	(the same convention Roblox's default movement uses) — holding
	nothing dashes straight along the character's current facing.

	Movement is driven by a LinearVelocity constraint rather than
	setting AssemblyLinearVelocity by hand. That matters for two
	things this needs:
	  - Mass independence: a constraint with a high MaxForce is
	    enforced by the physics solver every substep, not just once a
	    frame, so a heavy ball's collision response can't bleed off our
	    speed in the gap between manual updates the way it could
	    before.
	  - No vertical movement: the constraint's VectorVelocity locks all
	    three axes, so pinning Y to 0 cancels gravity outright for the
	    duration instead of just leaving whatever Y velocity happened
	    to already be there.

	MaxForce is DASH_FORCE (math.huge) so mass never slows the dash —
	dashing into a heavy ball holds full speed instead of getting bogged
	down. That force being literally infinite is also what was
	launching/ragdolling the player on impact — handled elsewhere now
	rather than here (this script only disables Jumping for the
	duration, so a jump press mid-dash doesn't fight the Y-lock for a
	frame).

	Dash movement itself is purely client-side — a dash doesn't grant
	currency or anything else worth validating server-side, and Roblox
	already gives each client network ownership of their own character.
	The dash *sound*, however, needs to be heard by everyone else, so
	it's handled the same instant-local / server-relay split SellClient/
	SellService use for the sell sound: played locally here the instant
	the dash fires (localDashSound, zero network wait), then DashRequest
	pings DashHandler so it can relay the same sound to everyone else via
	SoundEvents. See DashHandler's header for the relay side.

	While on cooldown, a Highlight is shown on the character as the
	only feedback for "not ready yet" — same DepthMode = Occluded trick
	SellClient's hover highlight uses, so it respects normal depth
	instead of rendering through walls/other players. Only shown
	locally; nobody else needs to see your own cooldown state.

	Camera FOV widens by DASH_FOV_MULT for the dash's duration and eases
	back after, through FOVController's multiplier layer (see that
	module's own comment) rather than tweening Camera.FieldOfView here
	directly — Sprint drives the same property for its own reasons, and
	layering through FOVController means the two run in parallel instead
	of fighting over it. It's a multiplier of whatever Sprint's FOV is
	at the time (not a fixed number), so dashing while sprinting widens
	from the sprint FOV and dashing while walking widens from the walk
	FOV, and pressing/releasing Shift mid-dash resolves itself with no
	handoff needed once the dash ends.
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local WS = game:GetService("Workspace")
local TS = game:GetService("TweenService")
local Rep = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

local dashRequest = Rep:WaitForChild("DashRequest")
local FOVController = require(Rep:WaitForChild("FOVController"))

local DASH_SPEED = 100
local DASH_TIME = 0.1
local DASH_COOLDOWN = 1
local DASH_FORCE = math.huge -- relies on Ragdoll being disabled below to avoid the earlier fling

-- how much wider than the current FOV a dash pushes the camera, as a
-- multiplier (1 = no change) rather than a flat number — pushed through
-- FOVController's multiplier layer, so it's relative to whatever Sprint's
-- FOV currently is: 1.25 is ~87.5 from a walk (70) and ~112.5 from a
-- sprint (90). FOVController clamps the final result to Roblox's 120 cap.
local DASH_FOV_MULT = 1.25
local FOV_TWEEN_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)

-- keep in sync with DashHandler's DASH_SND_ID/VOL/PITCH — duplicated
-- here (rather than sent over) so this can play with zero network
-- wait, same reasoning as SellClient's SELL_SND_ID/VOL
local DASH_SND_ID, DASH_SND_VOL, DASH_SND_PITCH = "rbxassetid://12222208", 0.1, 1.3

-- Created once and reused for every dash instead of Instance.new()'d
-- and Destroy()'d per press. rbxasset:// content ships with the
-- client, so it doesn't benefit from ContentProvider preloading (that
-- was tried first and didn't help) — the more likely source of the
-- "delay" is that Roblox's audio engine does some output-device setup
-- lazily on a Sound's first Play() in a session, which shows up as a
-- one-time hitch per fresh instance. Playing it once at Volume 0 right
-- here pays that cost immediately at script load, before the player
-- can ever press F, instead of on their first dash.
local dashSound = Instance.new("Sound")
dashSound.SoundId = DASH_SND_ID
dashSound.PlaybackSpeed = DASH_SND_PITCH
dashSound.Volume = 0
dashSound.Parent = WS
dashSound:Play()
dashSound:Stop()
dashSound.Volume = DASH_SND_VOL

local COOLDOWN_HIGHLIGHT_COLOR = Color3.new(0, 0, 0)
local COOLDOWN_HIGHLIGHT_TRANSPARENCY = 0.5

local lastDash = -DASH_COOLDOWN -- lets the very first dash fire immediately
local cooldownHighlight -- currently-shown cooldown Highlight instance, if any
local cooldownTween -- its currently-running fade tween, if any

-- Upgrades folder replicates in from LeaderboardSetup the same way
-- leaderstats does — checked fresh on every press rather than cached,
-- since it's cheap and this only ever fires on a keypress anyway
local function ownsDash()
	local upgrades = player:FindFirstChild("Upgrades")
	return upgrades and upgrades:FindFirstChild("dash") ~= nil
end

local function clearCooldownHighlight()
	if cooldownTween then
		cooldownTween:Cancel()
		cooldownTween = nil
	end
	if cooldownHighlight then
		cooldownHighlight:Destroy()
		cooldownHighlight = nil
	end
end

-- shows the cooldown highlight on `character`, fading its FillTransparency
-- from COOLDOWN_HIGHLIGHT_TRANSPARENCY up to fully invisible over
-- however long is left on the cooldown (read fresh from lastDash rather
-- than taking a duration, so this and CharacterAdded below don't need
-- to independently compute it the same way). Linear, not eased, since
-- the point is to visually track the cooldown's actual progress rather
-- than look stylized.
--
-- Called both right after a dash fires and (if the cooldown is still
-- running) from CharacterAdded below, so respawning mid-cooldown
-- doesn't leave the new character without an indicator — and resumes
-- the fade from wherever it should already be by then, rather than
-- popping back to full opacity and re-fading from scratch.
local function showCooldownHighlight(character)
	if player:GetAttribute("AFK") then return end -- AFKHandler already puts its own highlight on the character; don't stack this on top of it

	local remaining = DASH_COOLDOWN - (os.clock() - lastDash)
	if remaining <= 0 then return end

	clearCooldownHighlight()

	local highlight = Instance.new("Highlight")
	highlight.FillColor = COOLDOWN_HIGHLIGHT_COLOR
	highlight.OutlineTransparency = 1 -- no outline
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded -- respects normal depth, doesn't render through walls/always-on-top
	highlight.Parent = character

	local elapsedFraction = 1 - (remaining / DASH_COOLDOWN)
	highlight.FillTransparency = COOLDOWN_HIGHLIGHT_TRANSPARENCY
		+ (1 - COOLDOWN_HIGHLIGHT_TRANSPARENCY) * elapsedFraction
	cooldownHighlight = highlight

	local tween = TS:Create(highlight, TweenInfo.new(remaining, Enum.EasingStyle.Linear), { FillTransparency = 1 })
	cooldownTween = tween
	tween:Play()
	tween.Completed:Connect(function()
		if cooldownHighlight == highlight then
			clearCooldownHighlight()
		end
	end)
end

-- covers dying mid-cooldown: the old highlight (and its tween) goes
-- with the old character automatically, but the new one needs its own
-- pick up wherever the fade should be by now
player.CharacterAdded:Connect(function(character)
	showCooldownHighlight(character)
end)

-- covers the case where AFK gets toggled on WHILE the cooldown
-- highlight is already showing/fading — showCooldownHighlight's own
-- guard above only stops a NEW one from starting, so an existing one
-- needs to be torn down here instead
player:GetAttributeChangedSignal("AFK"):Connect(function()
	if player:GetAttribute("AFK") then
		clearCooldownHighlight()
	end
end)

-- camera-relative WASD, flattened to the XZ plane — matches how
-- Roblox's own default movement reads input. Falls back to the
-- character's current facing when nothing's held, and returns nil
-- only if there's truly no usable horizontal direction (e.g. camera
-- pointed straight down with no keys held).
local function getDashDirection(camera, hrp)
	local camForward = camera and camera.CFrame.LookVector or hrp.CFrame.LookVector
	local camRight = camera and camera.CFrame.RightVector or hrp.CFrame.RightVector
	camForward = Vector3.new(camForward.X, 0, camForward.Z)
	camRight = Vector3.new(camRight.X, 0, camRight.Z)
	camForward = camForward.Magnitude > 0.01 and camForward.Unit or Vector3.new()
	camRight = camRight.Magnitude > 0.01 and camRight.Unit or Vector3.new()

	local x, z = 0, 0
	if UIS:IsKeyDown(Enum.KeyCode.W) then z += 1 end
	if UIS:IsKeyDown(Enum.KeyCode.S) then z -= 1 end
	if UIS:IsKeyDown(Enum.KeyCode.D) then x += 1 end
	if UIS:IsKeyDown(Enum.KeyCode.A) then x -= 1 end

	if x == 0 and z == 0 then
		local look = hrp.CFrame.LookVector
		local dir = Vector3.new(look.X, 0, look.Z)
		return dir.Magnitude > 0.01 and dir.Unit or nil
	end

	local dir = camForward * z + camRight * x
	return dir.Magnitude > 0.01 and dir.Unit or nil
end

-- plays instantly, doesn't wait on the DashRequest round trip — same
-- "attached" shape SoundClient builds server-fired dash sounds with,
-- so a locally-predicted dash sounds identical to one someone else
-- hears. Reparented to hrp (not a detached anchor) since the character
-- keeps moving for the dash's duration — and reparented fresh each
-- time since hrp itself is a new instance every respawn. Reuses the
-- single warmed-up dashSound rather than creating a new Sound per
-- dash (see dashSound's own comment above for why).
local function localDashSound(hrp)
	dashSound.Parent = hrp
	dashSound.TimePosition = 0
	dashSound:Play()
end

local function dash()
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChild("Humanoid")
	if not (hrp and humanoid) then return end

	local dir = getDashDirection(WS.CurrentCamera, hrp)
	if not dir then return end

	local velocity = dir * DASH_SPEED

	localDashSound(hrp) -- instant — doesn't wait on the server round trip
	dashRequest:FireServer() -- server relays to everyone else via SoundEvents

	FOVController.SetMultiplier(DASH_FOV_MULT, FOV_TWEEN_INFO)

	local attachment = Instance.new("Attachment")
	attachment.Parent = hrp

	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = attachment
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = DASH_FORCE -- math.huge — see header note; Ragdoll is handled by a separate script now
	lv.VectorVelocity = velocity -- Y = 0, so gravity is cancelled for the duration too
	lv.Parent = hrp

	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)

	task.delay(DASH_TIME, function()
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		FOVController.SetMultiplier(1, FOV_TWEEN_INFO)
		if attachment.Parent then attachment:Destroy() end
		if lv.Parent then lv:Destroy() end
	end)
end

UIS.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode ~= Enum.KeyCode.F then return end
	if not ownsDash() then return end

	local now = os.clock()
	if now - lastDash < DASH_COOLDOWN then return end
	lastDash = now

	local character = player.Character
	if character then
		showCooldownHighlight(character)
	end

	dash()
end)