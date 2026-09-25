--[[
    MusicClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-24 20:25:14
]]
--[[
    MusicClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-23 02:07:55
]]
--[[
    MusicClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-22 18:28:58
]]
--[[
	MusicClient (LocalScript) — StarterPlayerScripts

	Owns and plays the four looping music layers entirely locally. That
	was already true of the audio; what's new is that the DECISION is
	local too.

	WHAT CHANGED

	MusicManager (ServerScriptService) used to count the balls in the one
	shared folder and publish a target volume per layer as NumberValues
	under ReplicatedStorage.MusicState, so everyone's music agreed. With
	a board per player there's nothing left to agree about — your music
	should follow YOUR board — so the count happens here and MusicManager
	is deleted. The engine limitation that shaped this script hasn't
	changed: layers only stay sample-aligned if they all start from
	TimePosition 0 together, so that's still exactly what happens below.

	The collapse duck used to arrive as a tween on a replicated
	NumberValue the server drove. Now it comes from ClientBoard's own
	collapse signal, on this machine, with no network in between.

	Muting stays purely local and purely this script's business, fired by
	TopbarClient's Mute icon over a client-only BindableEvent.
]]

local Rep = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")

local MusicData = require(Rep:WaitForChild("MusicData"))
local Config = require(Rep:WaitForChild("BoardConfig"))
local Protocol = require(Rep:WaitForChild("BoardProtocol"))
local ClientBoard = require(script.Parent:WaitForChild("ClientBoard"))

local FADE_TIME = 2
local FADE_STYLE = Enum.EasingStyle.Sine
local FADE_DIR = Enum.EasingDirection.InOut

-- These three used to live in MusicManager, which was the only thing
-- that set them. They're plain locals now.
local MASTER_VOLUME = 0.6
local PLAYBACK_SPEED = 1
local POLL_RATE = 0.5 -- how often the ball count is re-checked

-- private to this client — parented under SoundService purely as a
-- convenient, always-available spot, NOT a signal that this replicates
-- anywhere. A LocalScript's own Instance.new calls never leave this
-- client.
local masterGroup = Instance.new("SoundGroup")
masterGroup.Name = "DynamicMusicLocal"
masterGroup.Parent = SoundService

local isMuted = false

-- 1 normally, 0 while a collapse has the board frozen. Tweened rather
-- than set, so the music ducks and comes back the same way everything
-- else in a collapse does.
local duck = Instance.new("NumberValue")
duck.Value = 1

local function applyMasterVolume()
	masterGroup.Volume = isMuted and 0 or MASTER_VOLUME * duck.Value
end

applyMasterVolume()
duck.Changed:Connect(applyMasterVolume)

-- Client-local mute toggle, fired by TopbarClient's Mute icon. A
-- BindableEvent, not a RemoteEvent: it's created here by a LocalScript,
-- so it only exists in this client's copy of ReplicatedStorage and is
-- only ever heard by other LocalScripts on this same client.
local muteToggleEvent = Instance.new("BindableEvent")
muteToggleEvent.Name = "MusicMuteToggle"
muteToggleEvent.Parent = Rep

muteToggleEvent.Event:Connect(function(muted)
	isMuted = muted
	applyMasterVolume()
	-- Deliberately doesn't touch Workspace.ambience: muting only
	-- silences the music layers in masterGroup.
end)

-- ── the layers ────────────────────────────────────────────────────────

local sounds = {}
local orderedSounds = {} -- same order as MusicData, for the synchronised start below

for _, cfg in ipairs(MusicData) do
	local snd = Instance.new("Sound")
	snd.Name = cfg.name
	snd.SoundId = cfg.soundId
	snd.Looped = true
	snd.PlaybackSpeed = PLAYBACK_SPEED
	snd.SoundGroup = masterGroup
	snd.Volume = 0
	snd.Parent = masterGroup

	sounds[cfg.name] = snd
	table.insert(orderedSounds, snd)
end

local preloadOk = pcall(function()
	ContentProvider:PreloadAsync(orderedSounds)
end)

if not preloadOk then
	warn("[MusicClient] preload failed — layers may start unsynced for this client")
end

-- THE step that actually decides whether these four sound synced:
-- every layer's TimePosition reset to 0, then every layer Play()'d
-- back to back with nothing in between. It's the one sequence Roblox
-- guarantees stays sample-aligned; see the header.
for _, snd in ipairs(orderedSounds) do
	snd.TimePosition = 0
end
for _, snd in ipairs(orderedSounds) do
	snd:Play()
end

-- ── fading ────────────────────────────────────────────────────────────

local activeTweens = {}
local layerActive = {}

local function fadeLayerTo(name, targetVolume)
	local snd = sounds[name]
	if not snd then
		return
	end
	if activeTweens[name] then
		activeTweens[name]:Cancel()
	end
	local tween = TweenService:Create(snd, TweenInfo.new(FADE_TIME, FADE_STYLE, FADE_DIR), { Volume = targetVolume })
	activeTweens[name] = tween
	tween:Play()
end

-- Which layers should be audible right now, from this player's own
-- board. Exactly the rule MusicManager used, just with a local count.
local function update()
	local count = ClientBoard.ballCount()
	for _, cfg in ipairs(MusicData) do
		local shouldBeActive = count >= cfg.minBalls
		if layerActive[cfg.name] ~= shouldBeActive then
			layerActive[cfg.name] = shouldBeActive
			fadeLayerTo(cfg.name, shouldBeActive and (cfg.volume or 1) or 0)
		end
	end
end

update()
task.spawn(function()
	while true do
		task.wait(POLL_RATE)
		update()
	end
end)

-- ── collapse ──────────────────────────────────────────────────────────

local duckTween

ClientBoard.collapse.Event:Connect(function(phase)
	if duckTween then
		duckTween:Cancel()
	end

	if phase == Protocol.Collapse.CUT then
		-- Instant, matching the hard cut to grey everything else takes.
		duck.Value = 0
	elseif phase == Protocol.Collapse.RESOLVE then
		duckTween = TweenService:Create(duck, TweenInfo.new(Config.COLLAPSE_FADE_TIME), { Value = 1 })
		duckTween:Play()
	end
end)
