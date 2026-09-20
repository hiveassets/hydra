--[[
    MusicClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-20 20:00:09
]]
--[[
	MusicClient (LocalScript) — StarterPlayerScripts

	Owns and plays the four looping music layers ENTIRELY locally — no
	Sound instance here is ever created or Play()'d by the server, and
	nothing about this client's own copies is shared with any other
	client. Replaces the previous MusicSyncClient, which tried to
	resync each layer's TimePosition to a server-computed elapsed time;
	that approach is fundamentally capped by a confirmed, still-open
	Roblox engine limitation — see MusicManager's own header for the
	full explanation and source. Sample-accurate multi-layer sync is
	ONLY guaranteed when every layer starts from TimePosition = 0 at the
	same moment; nothing else reliably stays glued together, no matter
	how carefully the "correct" nonzero position is computed.

	So: this script always starts its own four private copies fresh
	from 0, back-to-back, the moment it's finished preloading — the one
	sequence Roblox actually guarantees stays in sync — rather than
	trying to match wherever the server or other clients currently are
	in the song.

	WHICH layers should be audible right now, and at what volume, still
	comes from the server (ReplicatedStorage.MusicState — a NumberValue
	per layer, named to match MusicData, holding that layer's current
	desired volume, 0 when inactive), since that decision genuinely
	should agree across every player — everyone should hear a new layer
	kick in at the same ball count, even without sharing an exact
	timeline position within it. This script just eases its own local
	Sound.Volume toward whatever that replicated value currently says,
	rather than trusting a network value to animate its own fade.

	Muting, by contrast, is entirely local and never should agree across
	players — it's exposed to TopbarClient's Mute icon via a client-only
	BindableEvent (ReplicatedStorage.MusicMuteToggle) rather than
	anything replicated from the server. The mute only affects the music
	layers owned by this script; the map's `ambience` background Sound
	is intentionally left playing.
]]

local Rep = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")
local WS = game:GetService("Workspace")

local MusicData = require(Rep:WaitForChild("MusicData"))
local stateFolder = Rep:WaitForChild("MusicState")

local FADE_TIME = 2
local FADE_STYLE = Enum.EasingStyle.Sine
local FADE_DIR = Enum.EasingDirection.InOut

-- private to this client — parented under SoundService purely as a
-- convenient, always-available spot, NOT a signal that this replicates
-- to the server or any other client. A LocalScript's own Instance.new
-- calls never leave this client.
local masterGroup = Instance.new("SoundGroup")
masterGroup.Name = "DynamicMusicLocal"
masterGroup.Parent = SoundService

local masterVolumeValue = stateFolder:WaitForChild("MasterVolume")
local playbackSpeedValue = stateFolder:WaitForChild("PlaybackSpeed")

-- isMuted is purely local state — it never touches the server or the
-- replicated MasterVolume value, so muting yourself has zero effect on
-- anyone else and doesn't fight with MusicManager's own volume tuning.
local isMuted = false

local function applyMasterVolume()
	masterGroup.Volume = isMuted and 0 or masterVolumeValue.Value
end

applyMasterVolume()
masterVolumeValue.Changed:Connect(applyMasterVolume)

-- Client-local mute toggle, fired by TopbarClient's Mute icon. This is a
-- BindableEvent, not a RemoteEvent: it's created here by a LocalScript,
-- so it only ever exists in THIS client's copy of ReplicatedStorage and
-- is only ever heard by other LocalScripts on this same client — the
-- server and other players never see it, same as everything else this
-- script owns.
local muteToggleEvent = Instance.new("BindableEvent")
muteToggleEvent.Name = "MusicMuteToggle"
muteToggleEvent.Parent = Rep

muteToggleEvent.Event:Connect(function(muted)
	isMuted = muted
	applyMasterVolume()
	-- Intentionally do not touch Workspace.ambience:
	-- muting only silences the music layers in masterGroup.
end)

local sounds = {}
local orderedSounds = {} -- same order as MusicData, used for the synchronized-start passes below

for _, cfg in ipairs(MusicData) do
	local snd = Instance.new("Sound")
	snd.Name = cfg.name
	snd.SoundId = cfg.soundId
	snd.Looped = true
	snd.PlaybackSpeed = playbackSpeedValue.Value
	snd.SoundGroup = masterGroup
	snd.Volume = 0
	snd.Parent = masterGroup

	sounds[cfg.name] = snd
	table.insert(orderedSounds, snd)
end

playbackSpeedValue.Changed:Connect(function(speed)
	for _, snd in pairs(sounds) do
		snd.PlaybackSpeed = speed
	end
end)

print("preloading music layers ...")

local preloadOk = pcall(function()
	ContentProvider:PreloadAsync(orderedSounds)
end)

if not preloadOk then
	warn("failed (music layers may start unsynced for this client)")
end

-- THE step that actually determines whether these four sound synced or
-- not: every layer's TimePosition reset to 0, then every layer
-- Play()'d back-to-back, with nothing else run in between. This is the
-- one sequence Roblox actually guarantees stays sample-aligned — see
-- this script's own header for why nothing else (resyncing to a
-- nonzero elapsed time, however it's computed) reliably does.
for _, snd in ipairs(orderedSounds) do
	snd.TimePosition = 0
end
for _, snd in ipairs(orderedSounds) do
	snd:Play()
end

print("all music layers started and synced !!!")

-- ── fading ──────────────────────────────────────────────────────────────

local activeTweens = {}

-- eases this client's own volume toward whatever the server currently
-- says this layer's target is — covers both "layer just activated/
-- deactivated" and a live SetLayerVolume tuning call
local function fadeLayerTo(name, targetVolume)
	local snd = sounds[name]
	if not snd then
		return
	end

	if activeTweens[name] then
		activeTweens[name]:Cancel()
	end

	local tween = TweenService:Create(
		snd,
		TweenInfo.new(FADE_TIME, FADE_STYLE, FADE_DIR),
		{ Volume = targetVolume }
	)

	activeTweens[name] = tween
	tween:Play()
end

for _, cfg in ipairs(MusicData) do
	local v = stateFolder:WaitForChild(cfg.name)
	fadeLayerTo(cfg.name, v.Value) -- catch up immediately to whatever's already true on join
	v.Changed:Connect(function(newVolume)
		fadeLayerTo(cfg.name, newVolume)
	end)
end