--[[
    StashHandler (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: true
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 13:33:36
]]
--[[
	StashHandler (Script) — ServerScriptService, sibling of SellHandler,
	GrabHandler, BallManager and SellService

	Server side of the stash upgrade (see UpgradeData's tiered "stash"
	entry, and StashData for everything about what a stashed ball looks
	like once it's in the toolbar).

	Three remotes, all created here the same create-if-missing way
	SellHandler/BallManager own theirs:

	  StashRequest (RemoteEvent) — player presses Q with their cursor on
	  a ball. Validates kind, state, reach and free-slot availability,
	  then absorbs it: the ball is pulled into the player and shrinks
	  away while SellService.stashAbsorb runs its highlight/flash/chat
	  beat, and its kind/size/color land in the first free slot.

	  StashDeploy (RemoteEvent) — player asks for a stashed ball back,
	  either by clicking its slot button or by pressing Q with the cursor
	  on nothing. Hands the stored kind/size/color to BallManager's
	  _G.QueueStashDeploy, which puts it at the FRONT of the launch queue,
	  and empties the slot once that's accepted. The ball then arrives
	  from the spawn point on the ordinary launch arc — a deploy chooses
	  WHEN a ball comes back, never where. See that function's own header
	  for why the feature is built that way.

	  StashCollapse (RemoteEvent) — fired TO every client by
	  _G.StashCollapseWipe when a collapse starts wiping the board, so
	  their previews can play the left-to-right fade-and-shrink before
	  this script actually clears the values behind them.

	WHERE THE STASH ITSELF LIVES

	Not in a table in this script: in a replicated Folder on the Player
	(Stash/1..3, each holding Kind/Size/Color values), created and
	persisted by LeaderboardSetup alongside leaderstats/Upgrades/
	PetMimicConfig. Same reasoning PetMimicConfig follows — the client
	reads it directly rather than needing a remote to ask what's in it,
	so a preview survives a respawn (or is rebuilt on rejoin from the
	save) with nothing pushed over the wire. This script only ever
	writes those values; StashClient only ever reads them.

	WHAT ABSORBING ACTUALLY DOES, IN ORDER

	Order matters here more than anywhere else in this script, so it's
	spelled out:

	  1. _G.FinalizeBallAscent/_G.FinalizeBallGrowth, exactly as
	     GrabHandler calls them and for the same reason: a ball still
	     mid-launch or still mid grow-tween isn't at its real size yet.
	     Since a stashed ball is stored at its LIVE size (see
	     StashData.captureSize), absorbing one mid-ascent without this
	     would pocket a size-8 ball that was on its way to being size
	     40. Both hooks no-op for anything already settled.
	  2. Capture kind/size/color, before anything starts shrinking it.
	  3. _G.BallManagerUntrack(ball). This is the one that isn't
	     optional: onHB's "not obj.Parent" branch treats a settled ball
	     that disappears without the Sold attribute as an unexpected
	     fall and fires splitBall for 2 replacements — so absorbing a
	     ball without untracking it first hands the board two free
	     balls on top of the one that went in the pocket. Deliberately
	     this hook and not the Sold attribute, per its own comment over
	     in BallManager: Sold carries payout/UI meaning a stash was
	     never meant to trigger.
	  4. RESERVE the slot, synchronously, before any yield — so two Q
	     presses in the same frame can't both land in slot 1. Reserving
	     is not the same as filling it: the slot's own values aren't
	     written until the ball actually arrives (see step 5), because a
	     preview appearing in the toolbar while the ball is still
	     visibly crossing the board reads as one ball in two places.
	     reservedSlots is what keeps the gap between the two safe.
	  5. task.spawn(SellService.stashAbsorb, ...). task.spawn resumes
	     the new thread immediately and runs it up to its first yield,
	     and stashAbsorb claims PendingSell before it yields — so by the
	     time control comes back here the ball is already claimed
	     against SellHandler, enforceBallCap, another player's click and
	     every mimic's scan. Same guarantee PetMimicFuse's pullIn leans
	     on for its own absorb. It's handed a `commit` callback that it
	     fires on its flash frame; THAT is what turns the reservation
	     from step 4 into a real, previewable slot entry.
	  6. pullIn, on its own coroutine, running alongside that: anchor
	     the ball and lerp it into the player while easing it down to
	     size 1, over exactly the STASH_ABSORB_DELAY that stashAbsorb's
	     own highlight fade takes, so the flash — and the slot filling —
	     land right as it arrives.

	WHAT IS AND ISN'T ABSORBABLE

	Kind comes from StashData.kindFromInstance, so mimics (board and
	pet alike) are excluded by simply not being in that table. Radiant is
	fine for every kind and comes back radiant, subject to one check:
	IsRadiant is an attribute on an otherwise ordinary object, and
	applyRadiantOverlay only WARNS when a Radiant<Kind>Fuse is missing, so
	_G.BallManagerRadiantSupported is asked first — refusing to take a
	ball that couldn't be given back properly, rather than discovering it
	at deploy time.

	On top of that: never something already live in a way that has to be
	waited out — a magnet that has started pulling (Pulling — mirrors the
	demagnetizer's own rule in SellHandler), or a radiant bomb whose
	halfway pull has begun (its lift VectorForce, see
	StashData.RADIANT_PULL_LIFT_FORCE; the shrink that TELEGRAPHS that
	pull is still stashable, which is the whole reason that signal isn't
	the collision group). And never anything already spoken for by
	something else: Held (a carried ball — a grab in progress wins, the
	stash request is simply dropped), PendingSell, Sold, Split, or
	SplitPending/MergePending (a splitter/merger has already claimed it
	and is mid-converge). No size cap and no upgrade prerequisites — a
	bomb or magnet can be stashed without owning defuser/demagnetizer.

	Every one of those rejections is silent, including "your slots are
	full": a press that can't do anything just doesn't, rather than
	firing an error back for the client to interpret.
]]

local Players = game:GetService("Players")
local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local RS = game:GetService("RunService")

local StashData = require(Rep:WaitForChild("StashData"))
local UpgradeData = require(Rep:WaitForChild("UpgradeData"))
local SellService = require(script.Parent:WaitForChild("SellService"))

local bf = WS:WaitForChild("Balls") -- created by BallManager

local stashUpgrade
for _, upgrade in ipairs(UpgradeData) do
	if upgrade.id == StashData.UPGRADE_ID then
		stashUpgrade = upgrade
		break
	end
end
assert(stashUpgrade and stashUpgrade.tiers, "StashHandler: UpgradeData is missing a tiered 'stash' entry")

-- ── config ──────────────────────────────────────────────────────────

-- a little past StashClient's own local pre-check, as slack for
-- latency — same relationship (and the same numbers) GrabHandler's
-- GRAB_RANGE has to GrabClient's, since a stash reaches exactly as far
-- as a grab does
local STASH_RANGE = 23

-- how long the ball spends flying into the player and shrinking.
-- MUST stay equal to SellService's STASH_ABSORB_DELAY — that's how long
-- stashAbsorb's highlight takes to fade in before it destroys the ball,
-- so anything longer here would just be cut off mid-flight. Same
-- hand-kept relationship PetMimicFuse's PET_ABSORB_TIME has to
-- PRE_SELL_DELAY.
--
-- Deliberately half of PRE_SELL_DELAY (0.3), which is what this used to
-- be: a sell's fade is a warning to everyone else that a ball is
-- leaving, and a stash isn't warning anyone about anything — it's the
-- player's own input, and at 0.3s it read as sluggish rather than
-- deliberate.
local PULL_TIME = 0.15

-- how long past PULL_TIME a slot reservation is allowed to sit before
-- it's assumed dead and released — see the reservation note below. Only
-- ever reached when stashAbsorb bails before its flash, which needs
-- something else to have claimed the same ball in the same frame.
local RESERVATION_GRACE = 0.5

-- the size a pulled ball eases down to before it's destroyed — 1, not
-- 0, same as a pet mimic's catch: a part tweened to literally zero
-- renders as a degenerate speck for its last frame rather than just
-- reading as small.
local PULL_END_SIZE = 1

-- ── remotes ─────────────────────────────────────────────────────────
local stashRequest = Rep:FindFirstChild("StashRequest") or Instance.new("RemoteEvent")
stashRequest.Name, stashRequest.Parent = "StashRequest", Rep

local stashDeploy = Rep:FindFirstChild("StashDeploy") or Instance.new("RemoteEvent")
stashDeploy.Name, stashDeploy.Parent = "StashDeploy", Rep

local stashCollapse = Rep:FindFirstChild("StashCollapse") or Instance.new("RemoteEvent")
stashCollapse.Name, stashCollapse.Parent = "StashCollapse", Rep

-- ── slot access ─────────────────────────────────────────────────────
-- Everything below goes through these rather than reaching into the
-- folder shape directly, so LeaderboardSetup's layout is described in
-- exactly one place on this side too.

-- generous timeout rather than a bare FindFirstChild, same reasoning
-- as ShopHandler's WaitForChild("Upgrades", 5): a request fired the
-- instant a player joins could in principle race LeaderboardSetup's
-- onPlayerAdded, even though in practice nothing is clickable that fast
local function stashFolder(player)
	return player:WaitForChild(StashData.FOLDER_NAME, 5)
end

local function slotFolder(stash, index)
	return stash and stash:FindFirstChild(tostring(index))
end

-- Slots spoken for by an absorb that's currently mid-flight. The slot's
-- own values are NOT written until the ball actually arrives and flashes
-- (see the absorb handler's own step 4 and stashAbsorb's onAbsorbed
-- callback) — the preview appearing the instant Q was pressed, while the
-- ball was still visibly flying across the board, read as the same ball
-- existing in two places at once.
--
-- That leaves a gap the length of PULL_TIME where the slot is going to
-- be filled but doesn't look it yet, and a second Q press inside that
-- gap would pick the very same slot and quietly overwrite the first
-- ball. This table closes it: a reservation is taken synchronously, in
-- the same frame as the request, and isOccupied below counts it exactly
-- like a written slot does.
--
-- Weak-keyed on the slot Folder so a player leaving doesn't leave an
-- entry behind.
local reservedSlots = setmetatable({}, { __mode = "k" })

-- An empty slot is an EXISTING folder whose Kind is the empty string,
-- never a missing folder — all three always exist for every player
-- regardless of tier (see StashData.MAX_SLOTS' own comment) — and is
-- also not currently reserved by an in-flight absorb (see above).
local function isOccupied(slot)
	if not slot then return false end
	if reservedSlots[slot] then return true end
	local kind = slot:FindFirstChild("Kind")
	return kind ~= nil and kind.Value ~= ""
end

-- :IsA guard is defensive, same reasoning as ShopClient/GrabHandler's
-- identical check on grabTier: a save/load round trip that ever hands
-- this back as the wrong ClassName should read as tier 0 rather than
-- erroring on .Value
local function stashTierOf(player)
	local upgrades = player:FindFirstChild("Upgrades")
	local tierValue = upgrades and upgrades:FindFirstChild(StashData.TIER_VALUE_NAME)
	return (tierValue and tierValue:IsA("IntValue")) and tierValue.Value or 0
end

-- the number of slots this player can actually use right now: their
-- tier, clamped to MAX_SLOTS so a save that somehow came back higher
-- than the number of tiers that currently exist can't address a slot
-- folder that was never created
local function slotCountFor(player)
	return math.clamp(stashTierOf(player), 0, StashData.MAX_SLOTS)
end

-- lowest-numbered free slot within the player's tier, or nil if
-- they're full (or own no tier at all). Left-to-right by design: slot
-- 1 is checked before 2 before 3, so the toolbar fills in reading
-- order rather than wherever happens to be free.
local function firstFreeSlot(player, stash)
	for index = 1, slotCountFor(player) do
		local slot = slotFolder(stash, index)
		if slot and not isOccupied(slot) then
			return index, slot
		end
	end
	return nil
end

local function writeSlot(slot, kind, size, color, radiant)
	slot.Size.Value = size
	slot.Color.Value = color
	slot.Radiant.Value = radiant == true
	slot.Kind.Value = kind -- LAST: StashClient watches Kind specifically, so writing it after the others means the preview it builds always reads a complete entry
end

local function clearSlot(slot)
	slot.Kind.Value = "" -- FIRST, for the same reason writeSlot does it last — the client tears the preview down off this, and shouldn't see a half-cleared entry
	slot.Size.Value = 0
	slot.Color.Value = Color3.new(1, 1, 1)
	slot.Radiant.Value = false
end

-- ── absorbing ───────────────────────────────────────────────────────

-- Lives in StashData, not here: StashClient measures its own range
-- pre-check against the same number, and the radiant-bomb exception
-- inside it is subtle enough that two hand-kept copies would drift. See
-- StashData.captureSize for the whole rule and why it isn't just
-- ball.Size.X.

-- The ball flies into the player and eases down to nothing while
-- SellService.stashAbsorb's highlight fades in around it. Same shape as
-- PetMimicFuse's own pullIn, minus the collision group: a pet mimic's
-- prey needs CG.MimicPrey so it can pass through the mimic's body, but
-- this ball is flying at a PLAYER, and no existing group passes through
-- those. Anchored + CanCollide false does the same job for the third of
-- a second it has left to live, without a new group that would then
-- need its own pairing against every ball-ish tag in CollisionGroups.
-- CanQuery goes off too, so it can't be re-targeted by another player's
-- cursor mid-flight.
--
-- The target is re-read every frame rather than snapshot: the player
-- can keep running while this plays, and the ball should follow them
-- rather than converging on wherever they were standing when Q landed.
-- A player who leaves/respawns mid-pull just leaves it easing toward
-- its own start position instead, which stashAbsorb destroys a moment
-- later regardless.
local function pullIn(ball, player)
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false

	local startPos = ball.Position
	local startSize = ball.Size

	task.spawn(function()
		local t = 0
		while t < PULL_TIME do
			local dt = RS.Heartbeat:Wait()
			if not ball.Parent then return end -- stashAbsorb got there first (or something else destroyed it) — nothing left to move
			t += dt

			local alpha = math.clamp(t / PULL_TIME, 0, 1)
			local sizeAlpha = 1 - 2 ^ (-10 * alpha) -- expo-out, same curve a pet mimic's catch shrinks on: fast at first, easing into its final size right as it arrives

			local character = player.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart")
			local target = hrp and hrp.Position or startPos

			ball.CFrame = CFrame.new(startPos:Lerp(target, alpha))
			ball.Size = startSize:Lerp(Vector3.new(PULL_END_SIZE, PULL_END_SIZE, PULL_END_SIZE), sizeAlpha)
		end
	end)
end

stashRequest.OnServerEvent:Connect(function(player, ball)
	-- AFKHandler is the source of truth for this attribute and it's
	-- checked fresh here, never trusted from whatever StashClient
	-- predicted — same treatment SellHandler/GrabHandler give it
	if player:GetAttribute("AFK") then
		return
	end

	-- mid-collapse the board is being wiped for $0 anyway, and
	-- _G.StashCollapseWipe is in the middle of emptying this player's
	-- slots — an absorb landing in that window would drop a preview
	-- into a slot the wipe has already passed over
	if WS:GetAttribute("Collapsing") then
		return
	end

	if slotCountFor(player) == 0 then
		return -- upgrade not owned at all
	end

	if typeof(ball) ~= "Instance" or not ball:IsA("BasePart") or ball.Parent ~= bf then
		return -- forged or stale reference
	end

	local kind = StashData.kindFromInstance(ball)
	if not kind then
		return -- not something the stash handles — mimics land here (see StashData's header)
	end

	-- Radiant is an attribute, not a kind of its own, so the kind lookup
	-- above can't see it either way. EVERY kind is stashable radiant and
	-- comes back out radiant — the flag rides the slot and the deploy
	-- (see writeSlot and _G.QueueStashDeploy), and BallManager re-applies
	-- the overlay by asking for that kind radiant rather than by copying
	-- anything off the original.
	--
	-- The one thing that can't be honored is a radiant kind whose own
	-- Radiant<Kind>Fuse doesn't exist: applyRadiantOverlay only warns in
	-- that case, so the deploy would hand back an IsRadiant-flagged
	-- object with no behavior at all. Refused HERE rather than at deploy
	-- time on purpose — a ball that can't be given back is worse than one
	-- that was never taken.
	local radiant = ball:GetAttribute("IsRadiant") == true
	if radiant and _G.BallManagerRadiantSupported and not _G.BallManagerRadiantSupported(kind) then
		return
	end

	if kind == "magnet" and ball:GetAttribute("Pulling") then
		return -- already gone live; mirrors the demagnetizer's own rule in SellHandler
	end

	-- A radiant bomb whose pull has gone live is the same "already live,
	-- wait it out" situation a pulling magnet is, but RadiantBombFuse sets
	-- no Pulling attribute of its own. What it does build, at that exact
	-- instant and nowhere else, is its lift VectorForce — see
	-- StashData.RADIANT_PULL_LIFT_FORCE for why that's the signal and why
	-- the collision group, which looks like a better one, isn't.
	--
	-- The whole 1.5s shrink BEFORE that is deliberately still stashable.
	-- It's a telegraph, not the pull: the bomb is an ordinary part on the
	-- platform for all of it, and taking it during the wind-up is the same
	-- kind of read as taking any other bomb off the board.
	if radiant and kind == "bomb" and ball:FindFirstChild(StashData.RADIANT_PULL_LIFT_FORCE) then
		return
	end

	-- already spoken for: carried by someone (a grab in progress wins
	-- outright — this request is just dropped), mid-sale, or claimed by
	-- a splitter/merger that's mid-converge
	if ball:GetAttribute("Held")
		or ball:GetAttribute("PendingSell")
		or ball:GetAttribute("Sold")
		or ball:GetAttribute("Split")
		or ball:GetAttribute("SplitPending")
		or ball:GetAttribute("MergePending")
	then
		return
	end

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end

	local stash = stashFolder(player)
	local _, slot = firstFreeSlot(player, stash) -- the index itself is only useful to the client, which reads it off the folder anyway
	if not slot then
		return -- full, or their folder hasn't loaded yet; silent either way
	end

	-- see the header, step 1: settle anything still ascending or still
	-- mid grow/shrink tween BEFORE reading its size, so a ball caught
	-- mid-launch is stored at the size it was actually going to be.
	-- Both are no-ops for a ball that isn't in the state they finalize.
	if _G.FinalizeBallAscent then
		_G.FinalizeBallAscent(ball)
	end
	if _G.FinalizeBallGrowth then
		_G.FinalizeBallGrowth(ball)
	end

	-- distance to the ball's SURFACE, not its centre — measuring to the
	-- centre instead silently eats up to a whole radius of STASH_RANGE.
	-- Same check, and the same reasoning, as GrabHandler's.
	local size = StashData.captureSize(ball)
	if (ball.Position - hrp.Position).Magnitude - size / 2 > STASH_RANGE then
		return
	end

	local color = ball.Color

	-- step 3 in the header — this is the one that stops the board
	-- handing out two free replacement balls for every ball stashed
	if _G.BallManagerUntrack then
		_G.BallManagerUntrack(ball)
	end

	-- step 4: the slot is CLAIMED synchronously here, before either of the
	-- two calls below can yield, so a second Q in the same frame sees it
	-- as taken and moves to the next one (or gets rejected as full) — but
	-- it is not FILLED until the ball actually lands, on stashAbsorb's own
	-- flash frame (see reservedSlots, and onAbsorbed's note over in
	-- SellService). Writing it here instead put the preview in the toolbar
	-- while the ball was still visibly crossing the board.
	reservedSlots[slot] = true

	local committed = false
	local function commit()
		if committed then return end
		committed = true
		reservedSlots[slot] = nil
		if slot.Parent then -- the player could have left mid-flight
			writeSlot(slot, kind, size, color, radiant)
		end
	end

	-- Safety net for the one path where commit never runs: stashAbsorb
	-- bails out at its very first line if something else claimed
	-- PendingSell in the same frame, and never reaches its flash. Without
	-- this the reservation would sit there forever and that slot would
	-- read as permanently full. Flipping `committed` rather than only
	-- clearing the table also means a late callback can't then write into
	-- a slot that's since been reused by another absorb.
	task.delay(PULL_TIME + RESERVATION_GRACE, function()
		if not committed then
			committed = true
			reservedSlots[slot] = nil
		end
	end)

	-- step 5: claims PendingSell before its first yield (see header),
	-- then owns the payout-free chat line, the cyan highlight fade, the
	-- flash and the Destroy — and calls `commit` on the flash frame, which
	-- is what actually fills the slot reserved above
	-- specFor, not KINDS[kind], so a radiant ball says "radiant ball" in
	-- the chat line rather than quietly reading as an ordinary one
	task.spawn(SellService.stashAbsorb, ball, player, StashData.specFor(kind, radiant).label, size, commit)

	-- step 6: runs alongside it for exactly as long as that fade takes
	pullIn(ball, player)
end)

-- ── deploying ───────────────────────────────────────────────────────

stashDeploy.OnServerEvent:Connect(function(player, index)
	if player:GetAttribute("AFK") then
		return
	end

	-- a deploy bypasses BallManager's launch queue entirely (it's not a
	-- spawn request, it's a ball coming back), so spawningEnabled can't
	-- gate it — this is what keeps a deploy from putting a fresh ball on
	-- a board that's currently being wiped for $0
	if WS:GetAttribute("Collapsing") then
		return
	end

	if typeof(index) ~= "number" or index ~= math.floor(index) then
		return
	end
	if index < 1 or index > slotCountFor(player) then
		return -- out of range, or past what their tier actually owns
	end

	local stash = stashFolder(player)
	local slot = slotFolder(stash, index)
	if not slot or not isOccupied(slot) then
		return
	end

	-- Deliberately no character/HumanoidRootPart check: a deploy doesn't
	-- emerge from the player any more, it goes into BallManager's launch
	-- queue and arrives from the spawn point like any other ball, so
	-- being dead or mid-respawn is no reason to refuse one.

	local kind, size, color = slot.Kind.Value, slot.Size.Value, slot.Color.Value
	local radiant = slot.Radiant.Value
	if not StashData.isKind(kind) then
		-- a slot holding something this build no longer knows about
		-- (a kind removed from StashData between sessions). Clear it
		-- rather than leaving the player with a permanently dead slot.
		clearSlot(slot)
		return
	end

	if not _G.QueueStashDeploy then
		return -- BallManager hasn't finished starting up; leave the slot alone so the player can just try again
	end

	-- Queued FIRST, slot emptied only once that's actually accepted —
	-- the reverse of the old in-place spawner, which had to clear up
	-- front because it parented the ball synchronously. Nothing spawns
	-- synchronously now (processQueue is deferred), so there's no race to
	-- get ahead of, and the ordering that's left is the one that matters:
	-- a refusal (mid-collapse, say) leaves the player still holding their
	-- ball instead of silently eating it.
	local ok = _G.QueueStashDeploy(kind, size, color, radiant)
	if not ok then
		return
	end

	clearSlot(slot)
end)

-- ── collapse ────────────────────────────────────────────────────────
-- Called by BallManager.triggerCollapse as its own per-ball sell loop
-- starts (see the call site there), so the toolbar drains at the same
-- time the board does rather than before or after it.
--
-- The clients animate first and the values are cleared afterwards, not
-- the other way around: StashClient tears a preview down the instant
-- its slot's Kind goes empty, so clearing up front would yank every
-- preview out of existence before any of them got to play the wipe.
-- Firing the event, waiting out the full animation, then clearing means
-- the previews are animating over data that's still there, and the
-- clear that follows is just bookkeeping nobody sees.
--
-- Fired to everyone at once (not per-player) and every player's slots
-- are cleared — a collapse is a server-wide event and the board's own
-- wipe doesn't spare anyone either. A player with nothing stashed just
-- has three empty slots to not animate.
_G.StashCollapseWipe = function()
	stashCollapse:FireAllClients()

	task.delay(StashData.wipeDuration(), function()
		for _, player in ipairs(Players:GetPlayers()) do
			local stash = player:FindFirstChild(StashData.FOLDER_NAME)
			if stash then
				for index = 1, StashData.MAX_SLOTS do
					local slot = slotFolder(stash, index)
					if slot then
						-- reservation dropped before the clear, not after:
						-- an absorb that was mid-flight when the collapse
						-- started has already committed by now (the wipe
						-- runs an order of magnitude longer than
						-- PULL_TIME), but releasing it here regardless
						-- means a collapse can never strand one. The ball
						-- itself is gone either way — same as everything
						-- else a collapse takes.
						reservedSlots[slot] = nil
						if isOccupied(slot) then
							clearSlot(slot)
						end
					end
				end
			end
		end
	end)
end