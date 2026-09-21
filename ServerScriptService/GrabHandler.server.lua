--[[
    GrabHandler (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: true
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-20 22:14:28
]]
--[[
	GrabHandler (Script) — ServerScriptService, sibling of ShopHandler,
	BallManager, and DashHandler

	Server side of the grab upgrade (see UpgradeData's "grab" entry).

	REBUILD, v2. The first rebuild pass made the SERVER own a held
	ball's physics outright (SetNetworkOwner(nil), server-side
	AlignPosition). That removed the old ownership-handoff races
	outright, but at a real cost: every bit of motion now had to round
	-trip client -> server -> client before it was visible, which read
	as the ball dragging behind its holder, grabbing feeling slow to
	respond, and — worst of all — throwing a ball and immediately
	handing ownership back to Roblox's automatic assignment let a
	different nearby player's client get picked as the new owner before
	the just-set throw velocity had actually replicated, so it
	resimulated from the stale (still-held) state instead — which is
	exactly what reads as "the throw just drops the ball".

	So this version goes back to CLIENT-authoritative carry (GrabClient
	actually moves the ball locally via its own AlignPosition — zero
	added network latency, no drag) — but keeps two specific,
	deliberate protections so the same bugs that motivated the earlier
	rebuild don't come back:

	  1. Ownership hand-off delay (OWNERSHIP_RELEASE_DELAY below): this
	     server keeps the thrower as the ball's EXPLICIT owner for a
	     brief window after a throw before releasing to automatic
	     assignment. Flipping to Auto immediately loses a race in a
	     game this physics-heavy — the ball is almost always part of a
	     busy pile of other balls, so the instant ownership goes back
	     to Auto, a different nearby player can be assigned before the
	     throwing client's own velocity has reached the server. This is
	     the fix for "throwing just drops the ball".

	  2. Collision groups: every group name, and every "these two don't
	     collide" rule, now lives in ReplicatedStorage.CollisionGroups.
	     This script no longer registers anything or declares any
	     pairing of its own — it requires that module and reads names
	     off it (CG.HeldBall, CG.Balls, CG.GrabHolder). Requiring it is
	     what registers the groups and applies the rules, so there's no
	     "which sibling script ran first" race left, and no second
	     spelling of "Balls" here to drift out of sync with the one
	     BallManager stages every ball through
	     ("ascending"/"SplitGrowing"/"Balls"). Getting that pairing
	     wrong is what makes two overlapping balls violently
	     depenetrate against each other; with the module, a typo
	     (CG.Ballz) errors on the line that has it instead of silently
	     assigning nothing. The HeldBall-vs-Balls and
	     HeldBall-vs-GrabHolder pairings this script used to set up by
	     hand are declared on the HeldBall entry over there now.

	A ball still needs an actual network-ownership handoff (not just a
	server-side flag) because the player carrying it isn't necessarily
	the closest player to it — Roblox's automatic assignment only looks
	at proximity — so without this, a carried ball can stutter as
	physics authority silently flips to someone else mid-carry.

	Remotes:
	  RequestGrab (RemoteFunction) — player asks to pick up a specific
	  ball (regular or radiant — see isGrabbableKind; bombs and every
	  other special stay ungrabbable). Validates tier, size, ball
	  state, and reach, then hands the requesting client network
	  ownership so their local carry logic actually has authority to
	  move it. Returns true/false.

	  ReleaseGrab (RemoteEvent) — fired on a real throw (speed > 0) or a
	  silent drop (speed 0/absent — used by the safety nets below and
	  GrabClient's own respawn/AFK handling). Also carries `pitch`,
	  rolled once client-side so everyone hears the same randomized
	  pitch for a given throw.

	Grab tiers reuse ShopHandler's storage convention exactly as
	before: current tier is an IntValue named "grabTier" under the
	player's Upgrades folder.
]]

local Players = game:GetService("Players")
local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local RS = game:GetService("RunService")
local BadgeService = game:GetService("BadgeService")

local UpgradeData = require(Rep:WaitForChild("UpgradeData"))

-- Single source of truth for group names and collidability rules — see
-- the header. Requiring this registers every group and applies every
-- rule (server-side), so by the time any name below is read, the
-- pairings this script depends on are already in place.
local CG = require(Rep:WaitForChild("CollisionGroups"))

local grabUpgrade
for _, upgrade in ipairs(UpgradeData) do
	if upgrade.id == "grab" then
		grabUpgrade = upgrade
		break
	end
end
assert(grabUpgrade and grabUpgrade.tiers, "GrabHandler: UpgradeData is missing a tiered 'grab' entry")

local ballT = Rep:WaitForChild("Ball")
local bf = WS:WaitForChild("Balls") -- created by BallManager

local se = Rep:WaitForChild("SoundEvents") -- created by BallManager

-- keep in sync with GrabClient's identical constants
local GRAB_SND_ID, GRAB_VOL, GRAB_PITCH = "rbxassetid://12222054", 0.3, 1.1
local THROW_SND_ID, THROW_VOL = "rbxassetid://12222200", 0.9
local THROW_PITCH_MIN, THROW_PITCH_MAX = 1.1, 1.4 -- clamp range for the pitch the client rolls and sends along with a throw

-- "trick shot" badge: a throw released from the small pad in the
-- middle of the platform (thrower within TRICK_ZONE_RADIUS studs of
-- the origin, measured on the ground plane, at the instant of
-- release) that then clears TRICK_SHOT_Y without touching anything on
-- the way
local TRICK_SHOT_BADGE_ID = 776457600018699
local TRICK_ZONE_RADIUS = 5
local TRICK_SHOT_Y = -10

-- a little past GrabClient's own local pre-check, as slack for latency
-- — position the server sees is always slightly behind what the
-- client just saw when it fired the request
local GRAB_RANGE = 23

-- see the header: how long the thrower keeps EXPLICIT network
-- ownership of a ball after releasing it, before this hands ownership
-- back to automatic assignment
local OWNERSHIP_RELEASE_DELAY = 0.15

local requestGrab = Rep:FindFirstChild("RequestGrab") or Instance.new("RemoteFunction")
requestGrab.Name, requestGrab.Parent = "RequestGrab", Rep

local releaseGrab = Rep:FindFirstChild("ReleaseGrab") or Instance.new("RemoteEvent")
releaseGrab.Name, releaseGrab.Parent = "ReleaseGrab", Rep

local function isGrabbableKind(obj)
	return obj.Name == ballT.Name
end

-- :IsA("IntValue") guard is defensive, same reasoning as ShopClient's
-- identical check
local function grabTierOf(player)
	local upgrades = player:FindFirstChild("Upgrades")
	local tierValue = upgrades and upgrades:FindFirstChild("grabTier")
	return (tierValue and tierValue:IsA("IntValue")) and tierValue.Value or 0
end

-- same "everyone but the player who already heard it locally" shape as
-- SellService's fireExceptSeller / DashHandler's fireExceptDasher
local function fireExceptHolder(player, ...)
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= player then
			se:FireClient(p, ...)
		end
	end
end

-- ball -> player currently holding it. Weak-keyed so a ball that gets
-- GC'd elsewhere (split, sold, void cleanup) doesn't need an explicit
-- cleanup call here.
local heldBy = setmetatable({}, { __mode = "k" })

local trickShotWatchers = setmetatable({}, { __mode = "k" })

local function stopTrickShotWatch(ball)
	local w = trickShotWatchers[ball]
	if not w then return end
	if w.touchConn then w.touchConn:Disconnect() end
	if w.heartbeatConn then w.heartbeatConn:Disconnect() end
	trickShotWatchers[ball] = nil
end

local function startTrickShotWatch(ball, thrower)
	stopTrickShotWatch(ball) -- defensive — shouldn't already be watching this ball, but don't stack watchers if so

	local watcher = { thrower = thrower }
	trickShotWatchers[ball] = watcher

	watcher.touchConn = ball.Touched:Connect(function(hit)
		local character = thrower.Character
		if character and hit:IsDescendantOf(character) then
			return
		end
		stopTrickShotWatch(ball)
	end)

	watcher.heartbeatConn = RS.Heartbeat:Connect(function()
		if not ball.Parent then
			stopTrickShotWatch(ball) -- gone before clearing the threshold — no badge
			return
		end
		if ball.Position.Y < TRICK_SHOT_Y then
			stopTrickShotWatch(ball)
			pcall(function() BadgeService:AwardBadge(thrower.UserId, TRICK_SHOT_BADGE_ID) end)
		end
	end)
end

-- shared release path: used for a real throw, a plain drop, a player
-- leaving mid-carry, and a respawn/AFK mid-carry alike, so all leave
-- the ball (and its former holder's character) in the same clean
-- state. `wasThrow` only affects the network-ownership handoff — see
-- OWNERSHIP_RELEASE_DELAY above.
local function clearHold(ball, wasThrow)
	local holder = heldBy[ball]
	heldBy[ball] = nil

	if ball and ball.Parent then
		ball.CollisionGroup = CG.Balls
		ball:SetAttribute("Held", nil)

		if wasThrow and holder then
			ball:SetNetworkOwner(holder)
			task.delay(OWNERSHIP_RELEASE_DELAY, function()
				-- only release to Auto if nobody's grabbed it again in
				-- the meantime — a fresh grab already set its own
				-- explicit owner via RequestGrab, and this firing late
				-- would just fight that new hold
				if ball.Parent and not heldBy[ball] then
					ball:SetNetworkOwnershipAuto()
				end
			end)
		else
			ball:SetNetworkOwnershipAuto()
		end
	end

	if holder then
		-- Not unconditionally CG.Players: this runs from the AFK
		-- safety net below as well as a normal release, and that net
		-- fires off player:GetAttributeChangedSignal("AFK") — a
		-- separate, deferred connection from AFKHandler's own toggle
		-- handler, which has already moved this character into
		-- CG.AFKPlayers by the time this runs. Forcing CG.Players here
		-- regardless would silently undo that and leave an AFK
		-- player's character colliding with balls again. Landing back
		-- in the AFK group when the attribute says AFK keeps this in
		-- sync with whichever handler happens to run second.
		local group = holder:GetAttribute("AFK") and CG.AFKPlayers or CG.Players
		CG.assignDescendants(holder.Character, group)
	end
end

requestGrab.OnServerInvoke = function(player, ball)
	if player:GetAttribute("AFK") then
		return false -- AFK players can't grab — never trust GrabClient's own mirror of this check
	end

	local tier = grabTierOf(player)
	if tier == 0 then
		return false -- upgrade not owned at all
	end

	if typeof(ball) ~= "Instance" or not ball:IsDescendantOf(bf) then
		return false
	end
	if not isGrabbableKind(ball) then
		return false -- regular + radiant balls only — bombs/other specials are never grabbable
	end
	if ball:GetAttribute("Sold") or ball:GetAttribute("Split") or ball:GetAttribute("PendingSell") then
		return false -- already on its way out one way or another
	end
	if heldBy[ball] then
		return false -- somebody else already has it
	end

	local maxSize = grabUpgrade.tiers[tier].maxSize
	local size = ball:GetAttribute("TargetSize") or math.huge
	if size > maxSize then
		return false -- too big for this player's current tier
	end

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return false
	end

	-- distance to the ball's SURFACE, not its center — measuring to
	-- center instead silently eats up to a whole radius of GRAB_RANGE
	local radius = size / 2
	if (ball.Position - hrp.Position).Magnitude - radius > GRAB_RANGE then
		return false
	end

	-- Two different "not actually settled yet" states can still be true
	-- of a ball that's otherwise a perfectly valid grab target:
	--
	--   - still mid-launch (tracked "ascending" by BallManager,
	--     CanCollide false, possibly still mid grow-in tween) — a
	--     freshly-spawned ball reachable the instant it appears.
	--   - a split/merge result, grabbable from the instant it lands
	--     even while its own grow/shrink tween is still playing — a
	--     still-growing merge result is Anchored, and SetNetworkOwner
	--     errors outright on an anchored part.
	--
	-- Force either one to its fully-settled state now, before this
	-- touches CollisionGroup or calls SetNetworkOwner below, rather
	-- than rejecting the grab outright while the ball is still
	-- settling on its own. Both hooks are no-ops for a ball that isn't
	-- currently in the state they finalize, so calling both unconditionally
	-- is safe regardless of which (if either) applies to this ball.
	if _G.FinalizeBallAscent then
		_G.FinalizeBallAscent(ball)
	end
	if _G.FinalizeBallGrowth then
		_G.FinalizeBallGrowth(ball)
	end

	if not ball.CanCollide then
		return false -- still not collidable after finalizing — e.g. not tracked by BallManager at all, so bail rather than grab something broken
	end

	heldBy[ball] = player
	ball.CollisionGroup = CG.HeldBall -- still collides with everything except this specific player/other balls now — see header
	ball:SetAttribute("Held", true) -- read by BallManager's enforceBallCap to exclude it from auto-sell
	ball:SetNetworkOwner(player)
	CG.assignDescendants(character, CG.GrabHolder)
	fireExceptHolder(player, "attached", hrp, GRAB_SND_ID, GRAB_VOL, GRAB_PITCH)
	return true
end

releaseGrab.OnServerEvent:Connect(function(player, ball, speed, pitch)
	if typeof(ball) ~= "Instance" then
		return
	end
	if heldBy[ball] ~= player then
		return -- only the actual holder can release it — ignore anyone else
	end

	-- speed > 0 means an actual throw, not a drop — a respawn/AFK
	-- safety net fires this with speed 0/nil outright. Only a real
	-- throw gets a sound, same as it plays (or doesn't) locally on the
	-- throwing client.
	local wasThrow = typeof(speed) == "number" and speed > 0
	if wasThrow then
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if hrp then
			local safePitch = typeof(pitch) == "number" and math.clamp(pitch, THROW_PITCH_MIN, THROW_PITCH_MAX) or THROW_PITCH_MIN
			fireExceptHolder(player, "attached", hrp, THROW_SND_ID, THROW_VOL, safePitch)

			local pos = hrp.Position
			if Vector2.new(pos.X, pos.Z).Magnitude <= TRICK_ZONE_RADIUS then
				startTrickShotWatch(ball, player)
			end
		end
	end

	clearHold(ball, wasThrow)
end)

-- safety nets: a held ball shouldn't stay Held/owned by a client
-- that's no longer able to update it, whether they left, respawned, or
-- just went AFK mid-carry. Applied to players already in-game at
-- startup too, not just future joins.
local function wireSafetyNets(player)
	player.CharacterAdded:Connect(function()
		for ball, holder in pairs(heldBy) do
			if holder == player then
				clearHold(ball)
			end
		end
	end)

	player:GetAttributeChangedSignal("AFK"):Connect(function()
		if player:GetAttribute("AFK") then
			for ball, holder in pairs(heldBy) do
				if holder == player then
					clearHold(ball)
				end
			end
		end
	end)
end

Players.PlayerAdded:Connect(wireSafetyNets)
for _, player in ipairs(Players:GetPlayers()) do
	wireSafetyNets(player)
end

Players.PlayerRemoving:Connect(function(player)
	for ball, holder in pairs(heldBy) do
		if holder == player then
			clearHold(ball)
		end
	end

	-- an in-flight trick shot has nobody left to award — stop watching
	-- rather than let the connections dangle
	for ball, watcher in pairs(trickShotWatchers) do
		if watcher.thrower == player then
			stopTrickShotWatch(ball)
		end
	end
end)