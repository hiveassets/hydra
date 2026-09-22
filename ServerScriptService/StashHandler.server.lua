--[[
    StashHandler (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 18:28:56
]]
--[[
	StashHandler (Script) — ServerScriptService

	Server side of the stash upgrade. It owns the SLOTS: which ones a
	player has, what's in them, and the fact that they survive a rejoin.
	It no longer owns anything you can see.

	WHAT MOVED, AND WHY

	The old version did the absorb itself: it anchored the ball, lerped
	it into the player frame by frame, shrank it, and ran a highlight
	fade over it, all from the server on a replicated part. Every one of
	those was a property write travelling to every client in the game so
	that one player could watch their own orb get pocketed. That work is
	now on the client that owns the orb (see ClientBoard.stash), where it
	costs nothing and arrives instantly.

	What's left here is the part that has to be true: the slot write.

	  StashRequest (id)     — take this orb off my board and pocket it
	  StashDeploy  (index)  — put slot `index` back on my board
	  StashCollapse ()      — fired TO one player when their board
	                          collapses, so the toolbar can play the wipe
	                          before the values behind it are cleared

	THE ORB'S SIZE COMES FROM THE LEDGER, NOT FROM A PART

	This is the whole reason the rewrite is safe. The old code read
	StashData.captureSize off the live instance, because the instance was
	the truth. Now the board's own entry is the truth, so a client asking
	to stash orb 41 gets slot-filled with whatever size the server says
	orb 41 is — there's nothing to claim and nothing to inflate. Deploy
	reads the same number back out.

	WHAT IS AND ISN'T STASHABLE

	Kind comes from the ledger and is checked against StashData's own
	list, so mimics are excluded by simply not being in it. Radiance
	rides along and comes back out, but only for a kind that can actually
	be given back radiant (see BoardRules.radiantSupported) — refusing to
	TAKE one is better than discovering at deploy time that it can't be
	returned properly.

	Every rejection is silent, including "your slots are full". A press
	that can't do anything just doesn't.
]]

local Rep = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local StashData = require(Rep:WaitForChild("StashData"))
local UpgradeData = require(Rep:WaitForChild("UpgradeData"))
local Rules = require(Rep:WaitForChild("BoardRules"))
local BoardService = require(ServerScriptService:WaitForChild("BoardService"))
local SellService = require(ServerScriptService:WaitForChild("SellService"))

local stashUpgrade
for _, upgrade in ipairs(UpgradeData) do
	if upgrade.id == StashData.UPGRADE_ID then
		stashUpgrade = upgrade
		break
	end
end
assert(stashUpgrade and stashUpgrade.tiers, "StashHandler: UpgradeData is missing a tiered 'stash' entry")

-- ── remotes ───────────────────────────────────────────────────────────
local stashRequest = Rep:FindFirstChild("StashRequest") or Instance.new("RemoteEvent")
stashRequest.Name, stashRequest.Parent = "StashRequest", Rep

local stashDeploy = Rep:FindFirstChild("StashDeploy") or Instance.new("RemoteEvent")
stashDeploy.Name, stashDeploy.Parent = "StashDeploy", Rep

local stashCollapse = Rep:FindFirstChild("StashCollapse") or Instance.new("RemoteEvent")
stashCollapse.Name, stashCollapse.Parent = "StashCollapse", Rep

-- ── slots ─────────────────────────────────────────────────────────────
-- The stash itself lives in a replicated Folder on the Player
-- (Stash/1..3, each holding Kind/Size/Color/Radiant), created and
-- persisted by LeaderboardSetup. The client reads it directly, which is
-- how a preview survives a respawn and comes back on a rejoin with
-- nothing sent over the wire. This script only ever writes it.

local function stashFolder(player)
	-- generous wait rather than a bare FindFirstChild: a request fired
	-- the instant someone joins could in principle race
	-- LeaderboardSetup's own setup, even though nothing is clickable
	-- that fast
	return player:WaitForChild(StashData.FOLDER_NAME, 5)
end

local function slotFolder(stash, index)
	return stash and stash:FindFirstChild(tostring(index))
end

local function isOccupied(slot)
	if not slot then
		return false
	end
	local kind = slot:FindFirstChild("Kind")
	return kind ~= nil and kind.Value ~= ""
end

local function stashTierOf(player)
	local upgrades = player:FindFirstChild("Upgrades")
	local tierValue = upgrades and upgrades:FindFirstChild(StashData.TIER_VALUE_NAME)
	-- :IsA guard is defensive: a save that ever comes back the wrong
	-- ClassName should read as tier 0 rather than erroring on .Value
	return (tierValue and tierValue:IsA("IntValue")) and tierValue.Value or 0
end

-- How many slots they can actually use right now: their tier, clamped
-- to the number of slot folders that exist, so a save from a build with
-- more tiers can't address one that was never created.
local function slotCountFor(player)
	return math.clamp(stashTierOf(player), 0, StashData.MAX_SLOTS)
end

-- Lowest-numbered free slot, or nil if they're full. Left to right by
-- design, so the toolbar fills in reading order.
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
	-- Kind LAST: StashClient watches this one specifically, so writing
	-- it after the others means the preview it builds always reads a
	-- complete entry.
	slot.Kind.Value = kind
end

local function clearSlot(slot)
	-- Kind FIRST, for the mirror image of the reason above: the client
	-- tears a preview down off this value, and shouldn't see a
	-- half-cleared entry.
	slot.Kind.Value = ""
	slot.Size.Value = 0
	slot.Color.Value = Color3.new(1, 1, 1)
	slot.Radiant.Value = false
end

-- ── absorbing ─────────────────────────────────────────────────────────

stashRequest.OnServerEvent:Connect(function(player, id)
	if typeof(id) ~= "number" then
		return
	end
	if player:GetAttribute("AFK") then
		return
	end

	local board = BoardService.get(player)
	if not board then
		return
	end

	if slotCountFor(player) == 0 then
		return -- upgrade not owned at all
	end

	local stash = stashFolder(player)
	local _, slot = firstFreeSlot(player, stash)
	if not slot then
		return -- full, or their folder hasn't loaded; silent either way
	end

	-- Everything the board can't answer on its own. The board checks
	-- that the orb exists, is live and isn't mid-anything; this checks
	-- that it's a kind the stash handles at all.
	-- On success the second return is the ledger's snapshot of the orb;
	-- on failure it's the reason it was refused.
	local ok, snapshotOrReason = board:onStash(id, function(entry)
		if not StashData.isKind(entry.kind) then
			return false, "not stashable" -- mimics land here, by not being in StashData at all
		end
		if entry.radiant and not Rules.radiantSupported(entry.kind) then
			return false, "can't be given back radiant"
		end
		return true
	end)

	if not ok then
		-- Silent to the PLAYER, as every stash refusal is — no message,
		-- no sound, a press that can't do anything just doesn't. But not
		-- silent to their client: StashClient has already played the
		-- pull and removed the orb, so a refusal it never hears about
		-- leaves the orb gone on screen and still on the ledger, which
		-- is what stops the board restocking. reject() asks it to
		-- rebuild from the ledger, and the orb comes back.
		--
		-- StashClient checks its own free slots before animating, so in
		-- normal play this doesn't fire. It's the backstop for the cases
		-- only the server can know about — a kind that isn't stashable,
		-- radiance that can't be given back — which is exactly where
		-- step 5's mimics will land.
		board:reject(id, snapshotOrReason)
		return
	end

	local snapshot = snapshotOrReason
	writeSlot(slot, snapshot.kind, snapshot.size, snapshot.color, snapshot.radiant)

	-- The chat line stays server-side like every other one, and still
	-- goes to the whole Logs channel — stashing is a thing other people
	-- can see you doing, even if the orb itself was only ever on your
	-- own board.
	SellService.log(string.format(
		'<b>%s (@%s)</b> stashed a <font color="#00FFFF"><b>size %d</b></font> %s',
		player.DisplayName,
		player.Name,
		math.round(snapshot.size),
		StashData.specFor(snapshot.kind, snapshot.radiant).label or "orb"
		))
end)

-- ── deploying ─────────────────────────────────────────────────────────

stashDeploy.OnServerEvent:Connect(function(player, index)
	if player:GetAttribute("AFK") then
		return
	end
	if typeof(index) ~= "number" or index ~= math.floor(index) then
		return
	end
	if index < 1 or index > slotCountFor(player) then
		return -- out of range, or past what their tier owns
	end

	local board = BoardService.get(player)
	if not board then
		return
	end

	local stash = stashFolder(player)
	local slot = slotFolder(stash, index)
	if not slot or not isOccupied(slot) then
		return
	end

	local kind, size, color = slot.Kind.Value, slot.Size.Value, slot.Color.Value
	local radiant = slot.Radiant.Value

	if not StashData.isKind(kind) then
		-- a slot holding something this build no longer knows about.
		-- Clear it rather than leaving a permanently dead slot.
		clearSlot(slot)
		return
	end

	-- Queued FIRST, emptied only once that's accepted: a refusal
	-- (mid-collapse, say) should leave the player still holding their
	-- orb rather than silently eating it.
	local ok = board:deployFromStash(kind, size, color, radiant)
	if not ok then
		return
	end

	clearSlot(slot)
end)

-- ── collapse ──────────────────────────────────────────────────────────
-- A collapse takes the stash with it: off-board would otherwise be a way
-- to sit one out for free.
--
-- The client animates first and the values are cleared afterwards, not
-- the other way around. StashClient tears a preview down the instant its
-- slot's Kind goes empty, so clearing up front would yank every preview
-- out of existence before any of them got to play the wipe.
BoardService.onCollapseWipe(function(player)
	stashCollapse:FireClient(player)

	task.delay(StashData.wipeDuration(), function()
		local stash = player:FindFirstChild(StashData.FOLDER_NAME)
		if not stash then
			return
		end
		for index = 1, StashData.MAX_SLOTS do
			local slot = slotFolder(stash, index)
			if slot and isOccupied(slot) then
				clearSlot(slot)
			end
		end
	end)
end)
