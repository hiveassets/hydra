--[[
    AFKHandler (Script)
    Path: ServerScriptService
    Parent: ServerScriptService
    Properties:
        Disabled: false
        RunContext: Enum.RunContext.Legacy
    Exported: 2026-09-22 18:28:56
]]
--[[
	AFKHandler (Script) — ServerScriptService, sibling of SellHandler
	and BallManager

	Server side of the AFK toggle in TopbarClient.
	AFKToggle carries no payload — every fire is a request to flip
	whatever this player's AFK state currently is, tracked here via an
	"AFK" attribute on the player (never trusted from the client, same
	philosophy as the defuser/demagnetizer checks in SellHandler). This
	is the one place that decides what "AFK" actually does:

	* a 50% transparent black Highlight (Occluded, not AlwaysOnTop —
	  same DepthMode SellService's regular sell highlights use) on the
	  character
	* the character's BaseParts moved into the AFKPlayers collision
	  group (CG.AFKPlayers — declared, along with every rule about what
	  it passes through, in ReplicatedStorage.CollisionGroups) — so an
	  AFK player can't push, be pushed by, or stand on any ball/bomb/
	  magnet/mimic/radiant, or on a ball someone else is carrying, but
	  still collides with the platform same as always (like every player,
	  it passes through other players)
	* SellHandler checks the same AFK attribute and rejects any
	  sellRequest from a player currently flagged AFK (see the guard
	  added near the top of its handler)
	* an "AFKSince" attribute (os.time() of the toggle-on, cleared on
	  toggle-off/leave) is set alongside "AFK" purely so other scripts
	  can tell how LONG a player's been AFK, not just whether they
	  currently are — SellService's collapse penalty uses this to
	  exempt anyone who's been AFK a while (see AFK_PENALTY_GRACE
	  there)

	Owns tagging every Balls-folder child with the "Balls" collision
	group via its own bf.ChildAdded connection, kept separate from
	BallManager's rather than reaching into that file to add a line —
	multiple scripts can connect to the same signal fine. Also sweeps
	whatever's already in the folder at startup, in case this script's
	first run lands after BallManager has already queued some in
	(execution order between sibling Scripts isn't guaranteed).

	Highlight/collision group get reapplied on every CharacterAdded
	while still flagged AFK, since dying/respawning hands the player a
	brand new Character/BaseParts that inherit neither — and a
	DescendantAdded catches parts that stream/load in after
	CharacterAdded fires (limbs, accessories), not just whatever's
	already parented that frame. That connection is remade (and the
	previous one disconnected) on every CharacterAdded so they don't
	pile up over a long session. A CharacterAppearanceLoaded reapply is
	also in the mix, as a safety net for a race the report below
	describes: parts that Roblox's avatar pipeline swaps in (rather
	than just adds) after CharacterAdded can land back on Default with
	nothing here having caught the swap. A periodic reconciliation
	pass (see RECONCILE_INTERVAL near the bottom) is the last line of
	defense on top of those two — it doesn't target one specific cause,
	it just notices and fixes any AFK player's character that's drifted
	out of the AFK group, on a short delay, regardless of why. Attribute is
	cleared on PlayerRemoving so nothing lingers.
]]

local Players = game:GetService("Players")
local RS = game:GetService("RunService")
local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- AFK stops your board now: nothing launches, nothing falls, nothing
-- spawns, and the launch queue's clock is held still so you come back
-- to the board you left rather than to fifty orbs arriving at once.
-- The collision group below still changes too — it costs nothing and
-- covers the moment between the toggle and the freeze.
local BoardService = require(ServerScriptService:WaitForChild("BoardService"))

-- Every collision group, and every pairing between them, is declared in
-- ReplicatedStorage.CollisionGroups — including AFKPlayers' own "passes
-- through anything ball-ish, plus a ball someone's carrying" rules,
-- which used to be set up by hand right here. This script now only
-- ASSIGNS groups; it never registers or pairs them.
local CG = require(Rep:WaitForChild("CollisionGroups"))

local HIGHLIGHT_NAME = "AFKHighlight"
local HIGHLIGHT_COLOR = Color3.new(0, 0, 0)
local HIGHLIGHT_TRANSPARENCY = 0.3

-- No folder sweep any more: every ball is created by the client that
-- owns it (see ClientBoard), which tags its own collision group as it
-- goes. AFK still works exactly as before, because the AFKPlayers group
-- and its rules are registered on the server and replicate down, so an
-- AFK player passes through the balls on their own board.

-- same create-if-missing pattern SellHandler/BallManager use for their
-- own remotes
local afkToggle = Rep:FindFirstChild("AFKToggle") or Instance.new("RemoteEvent")
afkToggle.Name, afkToggle.Parent = "AFKToggle", Rep

local function setCharacterAFK(character, afk)
	local existing = character:FindFirstChild(HIGHLIGHT_NAME)
	if existing then
		existing:Destroy()
	end

	-- every BasePart, not just the HumanoidRootPart — an arm, leg or
	-- accessory left behind would keep colliding on its own
	CG.assignDescendants(character, afk and CG.AFKPlayers or CG.Players)

	if afk then
		local highlight = Instance.new("Highlight")
		highlight.Name = HIGHLIGHT_NAME
		highlight.FillColor = HIGHLIGHT_COLOR
		highlight.FillTransparency = HIGHLIGHT_TRANSPARENCY
		highlight.OutlineTransparency = 1
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Parent = character
	end
end

-- keyed by player, holds the DescendantAdded connection for whatever
-- their CURRENT character is — disconnected and replaced every
-- CharacterAdded so a reset never leaves two of these stacked up
-- watching (functionally harmless once the old character is gone, but
-- there's no reason to let them pile up over a long session)
local descendantConns = {}

local function setup(player)
	player:SetAttribute("AFK", false)

	player.CharacterAdded:Connect(function(character)
		local prev = descendantConns[player]
		if prev then
			prev:Disconnect()
		end

		-- Connected BEFORE the GetDescendants() scan below runs, not
		-- after: with the scan running first, any part parented into
		-- the character between the scan and this connect (very much
		-- in play right at CharacterAdded, when limbs/accessories are
		-- still actively streaming in) was missed by both — too late
		-- for the scan to have seen it, too early for the listener to
		-- be watching yet. Connecting first closes that gap; the scan
		-- immediately after still covers everything already present.
		descendantConns[player] = character.DescendantAdded:Connect(function(desc)
			if player:GetAttribute("AFK") and desc:IsA("BasePart") then
				CG.assign(desc, CG.AFKPlayers)
			end
		end)

		if player:GetAttribute("AFK") then
			setCharacterAFK(character, true)

			-- The avatar can replace body/accessory parts for a short time after
			-- CharacterAdded. Reconcile every Heartbeat for the first second so
			-- an AFK reset never has to wait for the slower 2-second watchdog.
			task.spawn(function()
				for _ = 1, 60 do
					if not player:GetAttribute("AFK") or player.Character ~= character then
						break
					end
					for _, part in ipairs(character:GetDescendants()) do
						if part:IsA("BasePart") and part.CollisionGroup ~= CG.AFKPlayers then
							CG.assign(part, CG.AFKPlayers)
						end
					end
					RS.Heartbeat:Wait()
				end
			end)
		end
	end)

	-- CharacterAdded fires once the rig itself is built, but a
	-- player's actual appearance (accessories, layered clothing,
	-- scaled/replacement body parts) can keep loading in afterward and,
	-- per Roblox's avatar pipeline, sometimes REPLACES parts that
	-- DescendantAdded already caught rather than only adding new ones —
	-- a replacement part comes in on Default and there's no edit event
	-- to catch it being swapped in. This is the likeliest source of the
	-- "collisions didn't disable after resetting" report: a fast
	-- reset re-triggers appearance loading, and depending on how long
	-- that takes to settle, a swapped-in part can end up back in
	-- Default with nothing here to notice. Reapplying once appearance
	-- is confirmed fully loaded closes that window — redundant with
	-- CharacterAdded on the common case where nothing gets swapped, but
	-- that's just re-setting a handful of CollisionGroups again, which
	-- is harmless.
	player.CharacterAppearanceLoaded:Connect(function(character)
		if player:GetAttribute("AFK") then
			setCharacterAFK(character, true)
		end
	end)
end

Players.PlayerAdded:Connect(setup)
for _, player in ipairs(Players:GetPlayers()) do
	setup(player)
end

Players.PlayerRemoving:Connect(function(player)
	player:SetAttribute("AFK", nil)
	player:SetAttribute("AFKSince", nil)

	local conn = descendantConns[player]
	if conn then
		conn:Disconnect()
		descendantConns[player] = nil
	end
end)

afkToggle.OnServerEvent:Connect(function(player)
	local afk = not player:GetAttribute("AFK")
	player:SetAttribute("AFK", afk)
	BoardService.setPaused(player, afk)

	-- os.time() rather than os.clock(): os.clock() is process uptime,
	-- not wall time, and attributes are plain values with no epoch
	-- context of their own — SellService (a separate script) reads
	-- this back later purely as "seconds since toggle", so it needs a
	-- clock that means the same thing in both places
	player:SetAttribute("AFKSince", afk and os.time() or nil)

	local character = player.Character
	if character then
		setCharacterAFK(character, afk)
	end
end)

-- self-healing safety net: every RECONCILE_INTERVAL seconds, re-check
-- any currently-AFK player's character for a BasePart that isn't
-- actually sitting in CG.AFKPlayers and fix it if so. This isn't chasing
-- one specific cause — it's a backstop for whatever narrow startup/
-- respawn race might occasionally leave a part (or a whole character)
-- out of sync despite CharacterAdded/CharacterAppearanceLoaded/
-- DescendantAdded all trying to cover that above, since none of those
-- have been confirmed to be the actual gap. Cheap in practice: only
-- ever scans AFK players (rare), and only calls setCharacterAFK (which
-- re-touches every part + the highlight) when the cheap scan actually
-- finds something adrift, not every pass.
local RECONCILE_INTERVAL = 2

task.spawn(function()
	while true do
		task.wait(RECONCILE_INTERVAL)

		for _, player in ipairs(Players:GetPlayers()) do
			if player:GetAttribute("AFK") then
				local character = player.Character
				if character then
					for _, part in ipairs(character:GetDescendants()) do
						if part:IsA("BasePart") and part.CollisionGroup ~= CG.AFKPlayers then
							setCharacterAFK(character, true)
							break
						end
					end
				end
			end
		end
	end
end)