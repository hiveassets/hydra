--[[
    MusicManager (ModuleScript)
    Path: ServerScriptService
    Parent: ServerScriptService
    Exported: 2026-09-20 20:00:08
]]
--[[
	MusicManager (ModuleScript) — ServerScriptService

	Decides WHICH music layers should be audible right now, based on how
	many balls are in workspace.Balls — it no longer touches any Sound
	instance itself. See MusicClient's own header (StarterPlayerScripts)
	for the full story, but in short: Roblox only guarantees
	sample-accurate sync between separate audio instances when they're
	ALL started from TimePosition = 0 at the same moment — a confirmed,
	still-open engine limitation, not something either of this system's
	earlier revisions got wrong. Seeking to any other TimePosition,
	including a carefully server-computed "correct" elapsed time (what
	this module used to do via a SongStartTime attribute), reintroduces
	a small but permanent offset. See:
	https://devforum.roblox.com/t/add-a-way-to-sync-audio-tracks-together-in-precision/2446731
	— confirmed as of that thread to affect BOTH the legacy Sound object
	and the newer AudioPlayer API, so switching APIs doesn't sidestep it
	either.

	The only approach actually consistent with that limitation: every
	client owns private, unreplicated Sound instances and starts all
	four together from 0 the moment it's finished loading — guaranteed
	in sync with each other, by construction, every time. This module's
	only remaining job is being the single source of truth for WHICH
	layers should currently be audible and at what volume, so every
	client's local mix agrees about THAT decision — replicated via
	NumberValues under ReplicatedStorage.MusicState (one per layer,
	named to match MusicData; each holds that layer's current desired
	volume, 0 when inactive) rather than via any Sound instance.

	One consequence worth knowing: a player is no longer guaranteed to
	hear the song at the exact same timeline position as another player
	— each client starts its own copy from 0 whenever THAT client
	finishes loading in. For reactive/ambient background music (not
	something players are meant to listen to side-by-side expecting a
	shared beat), that's the trade that actually keeps the four layers
	glued to each other, which is the property that's audibly obvious
	when it's wrong.
]]

local WS = game:GetService("Workspace")
local Rep = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MusicData = require(Rep:WaitForChild("MusicData"))

local MASTER_VOLUME = 0.6
local PLAYBACK_SPEED = 1
local POLL_RATE = 0.5

local ONLY_COUNT_REGULAR_BALLS = true
local REGULAR_BALL_NAME = "Ball"

local ballsFolder = WS:WaitForChild("Balls")

-- replicated state every client reads/listens to. Plain Instances
-- (NumberValues), not a RemoteEvent, on purpose: a late-joining client
-- just sees the current correct values the moment it reads them via
-- ordinary replication, no "catch this client up" logic needed the way
-- a RemoteEvent would require.
local stateFolder = Rep:FindFirstChild("MusicState")
if not stateFolder then
	stateFolder = Instance.new("Folder")
	stateFolder.Name = "MusicState"
	stateFolder.Parent = Rep
end

local function getOrCreateNumberValue(name, parent)
	local v = parent:FindFirstChild(name)
	if not v or not v:IsA("NumberValue") then
		if v then
			v:Destroy() -- defensive: wrong ClassName from some stale state, replace outright
		end
		v = Instance.new("NumberValue")
		v.Name = name
		v.Parent = parent
	end
	return v
end

local masterVolumeValue = getOrCreateNumberValue("MasterVolume", stateFolder)
masterVolumeValue.Value = MASTER_VOLUME

local playbackSpeedValue = getOrCreateNumberValue("PlaybackSpeed", stateFolder)
playbackSpeedValue.Value = PLAYBACK_SPEED

local layerTargetVolume = {} -- name -> configured target, tunable live via SetLayerVolume
local layerValues = {}       -- name -> NumberValue, this layer's CURRENT desired volume (0 or target)
local lastActiveState = {}

for _, cfg in ipairs(MusicData) do
	layerTargetVolume[cfg.name] = cfg.volume or 1
	local v = getOrCreateNumberValue(cfg.name, stateFolder)
	v.Value = 0
	layerValues[cfg.name] = v
end

local function ballCount()
	if not ONLY_COUNT_REGULAR_BALLS then
		return #ballsFolder:GetChildren()
	end

	local n = 0
	for _, obj in ipairs(ballsFolder:GetChildren()) do
		if obj.Name == REGULAR_BALL_NAME then
			n += 1
		end
	end
	return n
end

-- pushes this layer's replicated value to its current target (or 0),
-- based on lastActiveState — called both when active/inactive flips
-- and when SetLayerVolume retunes an already-active layer's target
local function applyLayerVolume(name)
	layerValues[name].Value = lastActiveState[name] and layerTargetVolume[name] or 0
end

local function update()
	local count = ballCount()

	for _, cfg in ipairs(MusicData) do
		local shouldBeActive = count >= cfg.minBalls

		if lastActiveState[cfg.name] ~= shouldBeActive then
			lastActiveState[cfg.name] = shouldBeActive
			applyLayerVolume(cfg.name)
		end
	end
end

-- Run immediately so a player joining mid-game gets the correct layers
-- the instant their MusicClient reads MusicState — no waiting for the
-- next poll tick.
update()

local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc >= POLL_RATE then
		acc = 0
		update()
	end
end)

-- ── optional scripted tuning API ────────────────────────────────────────

local MusicManager = {}

function MusicManager.SetMasterVolume(v: number)
	masterVolumeValue.Value = v
end

function MusicManager.SetLayerVolume(levelName: string, v: number)
	if not layerValues[levelName] then
		warn("MusicManager.SetLayerVolume: no layer named " .. tostring(levelName))
		return
	end

	layerTargetVolume[levelName] = v
	applyLayerVolume(levelName) -- re-push immediately if this layer's currently active
end

function MusicManager.SetPlaybackSpeed(speed: number)
	playbackSpeedValue.Value = speed
end

return MusicManager