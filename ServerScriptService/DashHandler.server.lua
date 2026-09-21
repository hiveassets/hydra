--[[
    DashHandler (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-20 22:14:28
]]
--[[
	DashHandler (Script) — ServerScriptService

	All that's left of this is the sound. Dashing itself was always
	client-side (see DashClient), and now the balls it shoves are too, so
	there's nothing for the server to arrange.

	WHAT WAS HERE BEFORE, AND WHY IT'S GONE

	claimNearbyBalls handed the dashing player explicit network ownership
	of every ball within 20 studs, then handed each one back a quarter of
	a second later. That existed because a dash pushes balls through the
	dasher's own local physics, but the dasher usually wasn't the ball's
	network owner — Roblox reassigns ownership on its own slow proximity
	pass, which can't keep up with something that's over in a tenth of a
	second. Without the claim, the push looked right on the dasher's
	screen and then got overwritten when the real owner's (stale,
	un-pushed) state replicated in. That's what "the dash struggles to
	move balls under load" actually was.

	Every ball on your board is now simulated by your own machine, so the
	dash and the balls it hits are the same physics step. There is no
	owner to claim, no handoff to lose, and no window where it can go
	wrong.

	The sound stays, because other players can see you dash: DashClient
	plays it locally the instant the dash fires, and this relays the same
	cue to everyone else. Same instant-local / server-relay split as
	before, just with nothing else attached to it.

	This script also owns creating SoundEvents now. BallManager used to,
	and BallManager is gone.
]]

local Players = game:GetService("Players")
local Rep = game:GetService("ReplicatedStorage")

-- SoundClient waits on this by name; create-if-missing, same pattern the
-- other remotes in this game use.
local se = Rep:FindFirstChild("SoundEvents") or Instance.new("RemoteEvent")
se.Name, se.Parent = "SoundEvents", Rep

local dashRequest = Rep:FindFirstChild("DashRequest") or Instance.new("RemoteEvent")
dashRequest.Name, dashRequest.Parent = "DashRequest", Rep

local DASH_SND_ID, DASH_VOL, DASH_PITCH = "rbxassetid://12222208", 0.25, 1.3
local DASH_COOLDOWN = 1 -- keep in step with DashClient's own

-- weak-keyed so a player leaving doesn't leave an entry behind
local lastDash = setmetatable({}, { __mode = "k" })

local function ownsDash(player)
	local upgrades = player:FindFirstChild("Upgrades")
	return upgrades and upgrades:FindFirstChild("dash") ~= nil
end

-- everyone except the player who already heard it locally
local function fireExceptDasher(player, ...)
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			se:FireClient(other, ...)
		end
	end
end

-- The checks below aren't protecting anything valuable — a dash can't
-- earn money and can't touch anyone else's board. They're here so a
-- modified client can't fire this every frame and turn the dash cue
-- into server-wide noise.
dashRequest.OnServerEvent:Connect(function(player)
	if not ownsDash(player) then
		return
	end

	local t = os.clock()
	if lastDash[player] and t - lastDash[player] < DASH_COOLDOWN then
		return
	end
	lastDash[player] = t

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end

	-- "attached" rather than "positional": the character keeps moving
	-- for the length of the dash, so the sound should move with them.
	fireExceptDasher(player, "attached", hrp, DASH_SND_ID, DASH_VOL, DASH_PITCH)
end)
