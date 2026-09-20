--[[
    DashHandler (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-20 20:00:08
]]
--[[
	DashHandler (Script) — ServerScriptService

	Server side of the dash sound. Dash itself stays purely client-side
	(see DashClient's header) — this only exists to relay the dash
	sound to everyone else, the same instant-local / server-relay split
	SellClient/SellService use for the sell sound. DashClient plays it
	locally the instant a dash fires and pings this with DashRequest so
	everyone else hears it too.

	Validation here is limited to what's needed to keep DashRequest
	from being spammed/spoofed into free sound spam: the player has to
	actually own Dash and be off cooldown server-side too — mirrors
	DashClient's own gating so a modified client can't just fire this
	on every frame.

	DashRequest also does one more thing beyond the sound relay: it
	temporarily hands the dashing player explicit network ownership of
	every ball near them (see claimNearbyBalls). Dash pushes balls
	purely through local physics on the dasher's own client (see
	DashClient's header — dash movement is deliberately unvalidated,
	same as everywhere else here that's client-only), but that client
	usually isn't the ball's actual network owner: Roblox only
	reassigns ownership on its own periodic proximity pass, which can't
	keep up with a dash that's over in DASH_TIME seconds — especially
	once the field is busy with balls constantly colliding into each
	other and churning ownership around on their own. Without this, the
	push looks right on the dasher's own screen and then gets
	overwritten once the ball's actual (stale, un-pushed) owner's state
	replicates in, which is what reads as the dash "struggling" to move
	balls under load. Explicitly claiming ownership up front — and
	holding it briefly past the dash itself, so the ball's post-impact
	roll has time to settle before ownership moves on — fixes the
	common case. It can't fully cover every case: on a high enough ping
	the claim itself can still arrive after the dash has already
	finished playing out locally, in which case that particular
	impact's initial contact frame is still a best-effort thing, same
	as any physics networking under real latency.

	DashHandler owns creating DashRequest, same create-if-missing
	pattern SellHandler uses for SellRequest/SellBroadcast.
]]

local Players = game:GetService("Players")
local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")

local dashRequest = Rep:FindFirstChild("DashRequest") or Instance.new("RemoteEvent")
dashRequest.Name, dashRequest.Parent = "DashRequest", Rep

local se = Rep:WaitForChild("SoundEvents") -- created by BallManager

local ballT = Rep:WaitForChild("Ball")
local bf = WS:WaitForChild("Balls") -- created by BallManager

local DASH_SND_ID, DASH_VOL, DASH_PITCH = "rbxassetid://12222208", 0.25, 1.3
local DASH_COOLDOWN = 1 -- keep in sync with DashClient's DASH_COOLDOWN
local DASH_SPEED, DASH_TIME = 100, 0.1 -- keep in sync with DashClient's own — used only to size DASH_PUSH_RADIUS below

-- generous radius around the player to claim ball ownership in: covers
-- how far a full dash can travel, plus slack for the fact that by the
-- time this fires the server's own view of the player's position may
-- already be mid-dash (or a little behind it) depending on latency —
-- better to over-claim a few extra idle balls than under-claim the one
-- that actually gets hit
local DASH_PUSH_RADIUS = DASH_SPEED * DASH_TIME + 10

-- how long the dasher keeps explicit ownership of a claimed ball after
-- the dash itself ends, so its post-impact roll gets to settle under
-- the dasher's own (already-in-sync) simulation instead of getting
-- reassigned mid-roll — same reasoning and shape as GrabHandler's
-- OWNERSHIP_RELEASE_DELAY for a thrown ball
local DASH_OWNERSHIP_DELAY = 0.25

-- weak-keyed so a player leaving doesn't leak an entry forever
local lastDash = setmetatable({}, { __mode = "k" })

local function ownsDash(player)
	local upgrades = player:FindFirstChild("Upgrades")
	return upgrades and upgrades:FindFirstChild("dash") ~= nil
end

-- same "everyone but the player who already heard it locally" shape as
-- SellService's fireExceptSeller
local function fireExceptDasher(player, ...)
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= player then
			se:FireClient(p, ...)
		end
	end
end

-- hands `player` explicit network ownership of every regular ball
-- within DASH_PUSH_RADIUS of `hrp`, then hands each one back to
-- automatic assignment after DASH_OWNERSHIP_DELAY — unless it's been
-- grabbed in the meantime, in which case GrabHandler already owns that
-- ball's ownership lifecycle and this backs off. "Held" is the same
-- attribute GrabHandler already sets/clears on grab/release, reused
-- here as a cheap cross-system signal rather than reaching into its
-- private heldBy table.
local function claimNearbyBalls(player, hrp)
	for _, ball in ipairs(bf:GetChildren()) do
		if ball.Name == ballT.Name and not ball:GetAttribute("Held") then
			if (ball.Position - hrp.Position).Magnitude <= DASH_PUSH_RADIUS then
				ball:SetNetworkOwner(player)
				task.delay(DASH_OWNERSHIP_DELAY, function()
					if ball.Parent and not ball:GetAttribute("Held") then
						ball:SetNetworkOwnershipAuto()
					end
				end)
			end
		end
	end
end

dashRequest.OnServerEvent:Connect(function(player)
	if not ownsDash(player) then return end

	local now = os.clock()
	if lastDash[player] and now - lastDash[player] < DASH_COOLDOWN then return end
	lastDash[player] = now

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	claimNearbyBalls(player, hrp)

	-- "attached" (not "positional") since the character keeps moving
	-- for the dash's duration — the sound should move with them
	fireExceptDasher(player, "attached", hrp, DASH_SND_ID, DASH_VOL, DASH_PITCH)
end)