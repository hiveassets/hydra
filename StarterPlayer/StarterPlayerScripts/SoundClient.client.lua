--[[
    SoundClient (LocalScript)
    Path: StarterPlayer → StarterPlayerScripts
    Parent: StarterPlayerScripts
    Properties:
        Disabled: false
    Exported: 2026-09-22 15:18:22
]]
--[[
		SoundClient (LocalScript) — StarterPlayerScripts

		Receiving half of the SoundEvents RemoteEvent fired by BallManager,
		BombFuse, and DashHandler. Building and playing the Sound here,
		client-side, means nobody waits on a server-side Sound:Play() to
		replicate down first.

		Payload: (kind, target, soundId, volume, pitch)
		  "attached"       — one-shot sound on `target` (a BasePart), destroyed
		                      once it finishes. `pitch` optional. Also what
		                      DashHandler uses to relay the dash sound to
		                      everyone but the dasher (attached to their HRP
		                      so it moves with them).
		  "attachedReused" — like "attached", but reuses one Sound instance per
		                      `target` across repeated fires (e.g. bomb clicks)
		                      instead of spawning a new one every time.
		  "attachedLoop"   — like "attachedReused" (one Sound instance per
		                      `target`, so it moves with the target), but
		                      Looped = true and only ever needs firing once:
		                      it keeps playing on its own from then on, no
		                      matching "loopStop" required, since the Sound
		                      is a child of `target` — the instant `target`
		                      itself is destroyed, the Sound goes with it and
		                      stops for free. For an ambient cue that should
		                      follow a specific moving object around for as
		                      long as that object exists (currently just
		                      RadiantSplitterFuse's own ambient hum), rather
		                      than "loopStart"/"loopStop"'s fixed, non-
		                      positional, explicitly-stopped shape below.
		  "positional"     — `target` is a Vector3; spawns a short-lived
		                      anchored part to hang the sound on, for sounds
		                      fired after their source instance is already gone.
		                      `pitch` optional, same as "attached" — used by
		                      SellService to layer a second, sped-up sound
		                      (the bomb defuse cue) on top of the normal sell
		                      sound at the same position/moment.
		  "flatPitched"    — flat, non-positional Sound parented to
		                      SoundService, with its own PlaybackSpeed
		                      (payload is (id, vol, speed), not the usual
		                      (target, soundId, volume, pitch) shape above).
		                      For sounds with no single world position to hang
		                      off of — BallManager's overflow-collapse alarm
		                      (fired once per collapse), SellService's
		                      pitched-down sell cue on the collapse-penalty
		                      chat message, the short ping SellService plays
		                      alongside each of the 3 collapse chat lines
		                      (alert/penalty/quip), and the per-tick ping
		                      BallManager fires on every collapse-telegraph
		                      countdown tick.
		  "loopStart"      — flat, non-positional, Looped Sound parented to
		                      SoundService that keeps playing until a
		                      matching "loopStop" for the same id arrives,
		                      rather than flatPitched's play-once-per-fire
		                      shape. Payload is (id, vol). Currently just
		                      BallManager's collapse-telegraph tension loop:
		                      starts the instant the countdown begins,
		                      stops the instant the collapse itself does.
		  "loopStop"       — stops (not destroys) the Sound "loopStart"
		                      started for `id`, so a later "loopStart" for
		                      the same id resumes from a fresh Play() rather
		                      than finding nothing to stop. Payload is (id).

		`volume` is optional on every kind (defaults to 1) — each sender sets
		its own *_VOL constant next to its sound id, so levels are tweaked at
		the source rather than in here.
	]]

local Rep = game:GetService("ReplicatedStorage")
local WS = game:GetService("Workspace")
local SS = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local se = Rep:WaitForChild("SoundEvents")

-- Every asset ID any sound-related script can fire through SoundEvents,
-- plus BombFuse's flash image (see the "keep in sync" comment on
-- FLASH_IMAGE there). The RemoteEvent relay already removes the
-- server-Play replication delay; this removes the other half — the
-- client's first-ever Play() on an asset still has to download/decode
-- it before anything is audible. Preloading here means that's already
-- done by the time SoundEvents actually fires.
local PRELOAD_IDS = {
	"rbxassetid://12221976",               -- bomb flicker sfx
	"rbxassetid://12222084",               -- bomb explode sfx
	"rbxassetid://131187911056182",        -- flash billboard img
	"rbxassetid://139583503249540",        -- sell sfx
	"rbxassetid://12221967",               -- ball spawn sfx
	"rbxassetid://73276365795189",         -- special spawn sfx
	"rbxassetid://12222208",               -- dash sfx
	"rbxassetid://12222054",               -- grab pickup sfx
	"rbxassetid://12222200",               -- grab throw sfx
	"rbxassetid://12221990",               -- overflow collapse alarm
	"rbxassetid://12222170",               -- overflow collapse sell sfx
	"rbxassetid://135083591486620",        -- collapse chat message ping
	"rbxassetid://12222152",               -- bomb defuse sfx
	"rbxassetid://12221842",               -- magnet spawn sfx
	"rbxassetid://12222095",               -- magnet pull-start sfx
	"rbxassetid://105118844743160",        -- mimic leg grow sfx
	"rbxassetid://84724642336148",         -- ^   reupload
	"rbxassetid://92376313459891",         -- ^^  reupload
	"rbxassetid://12222103",               -- bumper bump sfx
	"rbxassetid://101410298856316",        -- splitter split sfx
	"rbxassetid://86932397872773",         -- merger merge sfx
	"rbxassetid://126727806160402",        -- radiantbomb pull sfx
	"rbxassetid://120604429155099",        -- radiantbomb boom sfx
	"rbxassetid://117163159149291",        -- radiantmagnet pull sfx
	"rbxassetid://87758060178138",         -- collapse-telegraph tension loop sfx
	"rbxassetid://139726170556835",        -- radiant splitter/merger ambient sfx
	"rbxassetid://137086138620952",        -- radiant splitter/merger explode sfx
	
	"rbxassetid://140588480958441",        -- stash sky scrolling texture
	"rbxassetid://81446779718854",         -- stash weld scrolling texture
	"rbxassetid://116959287602054",        -- stash invert scrolling texture
}

-- ids known to arrive via the "flatPitched" kind — pre-created and
-- warmed up (see below) right after preload, since flatPitched's own
-- per-call cost isn't just the asset download (PRELOAD_IDS above
-- handles that): a brand-new Sound instance's very first Play() still
-- pays Roblox's own pipeline-setup cost, separate from asset loading.
-- Anything not listed here still works fine via flatPitched (it just
-- creates + caches its Sound on first real use instead of ahead of
-- time), so it may have that same small one-time delay on its very
-- first play.
local FLAT_PITCHED_IDS = {
	"rbxassetid://12221990", -- overflow collapse alarm
	"rbxassetid://12222170", -- overflow collapse sell sfx
	"rbxassetid://135083591486620", -- collapse chat message ping
}

-- one persistent Sound instance per id, reused across every fire
-- instead of Instance.new-ing (and paying that pipeline-setup cost)
-- fresh each time — same idea as `reused` below, just keyed by id
-- instead of by target, since flatPitched sounds have no target
local flatPitchedCache = {}

local function getFlatPitchedSound(id, volume, speed)
	local s = flatPitchedCache[id]
	if not s then
		s = Instance.new("Sound")
		s.SoundId, s.Parent = id, SS
		flatPitchedCache[id] = s
	end
	s.Volume, s.PlaybackSpeed = volume or 1, speed or 1
	return s
end

-- Non-blocking: PreloadAsync yields, so this runs alongside script
-- startup instead of delaying the OnClientEvent connection below.
task.spawn(function()
	ContentProvider:PreloadAsync(PRELOAD_IDS)

	-- once the assets themselves are downloaded, spin up each known
	-- flatPitched Sound instance and do one silent play-then-stop —
	-- that's what actually primes Roblox's playback pipeline for it,
	-- so the first *real* Play() later (e.g. the first collapse of the
	-- server's life) isn't also the engine's first time touching that
	-- instance
	for _, id in ipairs(FLAT_PITCHED_IDS) do
		local s = getFlatPitchedSound(id, 0)
		s:Play()
		s:Stop()
	end
end)

-- persistent Sound per id, Looped = true — for "starts now, plays until
-- explicitly told to stop" cues (currently just the collapse-telegraph
-- tension loop), as opposed to flatPitched's own always-restart-from-0
-- one-shot-per-fire behavior. Same one-instance-per-id idea as
-- flatPitchedCache above, just Play()/Stop()'d directly instead of
-- reset-and-replayed on every fire, since a loop is meant to keep
-- running across whatever's happening in between its start and stop.
local loopCache = {}

local function loopStart(id, volume)
	local s = loopCache[id]
	if not s then
		s = Instance.new("Sound")
		s.SoundId, s.Looped, s.Parent = id, true, SS
		loopCache[id] = s
	end
	s.Volume = volume or 1
	if not s.IsPlaying then
		s:Play()
	end
end

local function loopStop(id)
	local s = loopCache[id]
	if s then
		s:Stop()
	end
end

-- weak-keyed: a cached Sound doesn't keep a destroyed target alive —
-- once nothing else references it, this entry just disappears
local reused = setmetatable({}, { __mode = "k" })

local function attached(target, id, volume, pitch)
	if not (target and target.Parent) then return end
	local s = Instance.new("Sound")
	s.SoundId, s.Volume, s.PlaybackSpeed, s.Parent = id, volume or 1, pitch or 1, target
	s:Play()
	s.Ended:Connect(function() s:Destroy() end)
end

local function attachedReused(target, id, volume, pitch)
	if not (target and target.Parent) then return end
	local s = reused[target]
	if not s or s.Parent ~= target then
		s = Instance.new("Sound")
		s.SoundId, s.Parent = id, target
		reused[target] = s
	end
	s.Volume = volume or 1
	s.PlaybackSpeed = pitch or 1
	s.TimePosition = 0
	s:Play()
end

-- see the "attachedLoop" doc entry above — same `reused` cache
-- attachedReused shares (a target only ever needs one non-one-shot
-- Sound on it at a time, whichever kind that is), but Looped = true and
-- idempotent: repeat fires (there normally won't be any — the sender
-- only needs to fire this once) just no-op once it's already playing,
-- instead of restarting from TimePosition 0 like attachedReused does on
-- every fire.
local function attachedLoop(target, id, volume, pitch)
	if not (target and target.Parent) then return end
	local s = reused[target]
	if not s or s.Parent ~= target then
		s = Instance.new("Sound")
		s.SoundId, s.Looped, s.Parent = id, true, target
		reused[target] = s
	end
	s.Volume = volume or 1
	s.PlaybackSpeed = pitch or 1
	if not s.IsPlaying then
		s:Play()
	end
end

local function positional(pos, id, volume, pitch)
	local anchor = Instance.new("Part")
	anchor.Anchored, anchor.CanCollide, anchor.CanQuery, anchor.Transparency = true, false, false, 1
	anchor.Size, anchor.Position, anchor.Parent = Vector3.new(0.1, 0.1, 0.1), pos, WS

	local s = Instance.new("Sound")
	s.SoundId, s.Volume, s.PlaybackSpeed, s.Parent = id, volume or 1, pitch or 1, anchor
	s:Play()
	s.Ended:Connect(function() anchor:Destroy() end)
end

-- flat, non-positional sound with its own playback speed — used for
-- BallManager's overflow-collapse alarm and SellService's pitched-down
-- sell cue on the collapse-penalty message (see the "flatPitched" doc
-- entry above). Moved here from SellClient so every SoundEvents kind
-- lives in one place. Reuses one persistent Sound instance per id
-- (see getFlatPitchedSound above) rather than creating a new one on
-- every fire — restarting from TimePosition 0 handles the (rare) case
-- of the same id firing again before its last play finished.
local function flatPitched(id, volume, speed)
	local s = getFlatPitchedSound(id, volume, speed)
	s.TimePosition = 0
	s:Play()
end

-- generic param names (a/b/c/d) rather than (target, id, volume, pitch):
-- every kind but flatPitched shares that (target, soundId, volume,
-- pitch) shape, but flatPitched's payload is (id, vol, speed) instead —
-- still lines up positionally, just not semantically, so naming them for
-- one kind would be misleading for the other.
se.OnClientEvent:Connect(function(kind, a, b, c, d)
	if kind == "attached" then
		attached(a, b, c, d)
	elseif kind == "attachedReused" then
		attachedReused(a, b, c, d)
	elseif kind == "attachedLoop" then
		attachedLoop(a, b, c, d)
	elseif kind == "positional" then
		positional(a, b, c, d)
	elseif kind == "flatPitched" then
		flatPitched(a, b, c)
	elseif kind == "loopStart" then
		loopStart(a, b)
	elseif kind == "loopStop" then
		loopStop(a)
	end
end)