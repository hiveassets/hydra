--[[
    MusicData (ModuleScript)
    Path: ReplicatedStorage
    Parent: ReplicatedStorage
    Exported: 2026-09-20 20:00:08
]]
--[[
	MusicData (ModuleScript) — ReplicatedStorage

	Shared by MusicManager (ServerScriptService, decides which layers
	should be active based on ball count) and MusicClient
	(StarterPlayerScripts, owns and actually plays the audio for each
	layer) — same sharing pattern as UpgradeData between
	ShopHandler/ShopClient elsewhere in this game.

	`volume` is each layer's normal target volume once active — not its
	starting volume; every layer always starts at 0 and fades in, see
	MusicClient's own fade-in logic.
]]

return {
	{ name = "Level1", soundId = "rbxassetid://90263426927549",  minBalls = 0,  volume = 1 },
	{ name = "Level2", soundId = "rbxassetid://137522955883217", minBalls = 6,  volume = 1 },
	{ name = "Level3", soundId = "rbxassetid://72722003181600",  minBalls = 16, volume = 1 },
	{ name = "Level4", soundId = "rbxassetid://111886404519315", minBalls = 40, volume = 1 },
}