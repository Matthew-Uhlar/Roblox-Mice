--!strict
--[[
	Trunkfall server entry point. The boot itself lives in Boot.luau (Boot.start()), so the
	in-Roblox smoke test can run exactly the same boot (docs/publishing/SMOKE.md).

	PLACE SETTINGS (set in Studio / Creator Hub; scripts can't or shouldn't set them):
	  - Game Settings > Places > Max Players = 12  (v2: one match per server = 4 squads x 3;
	    docs/GDD-v2.md §1). Players.MaxPlayers is NOT scriptable: the publish pipeline sets
	    the place's serverSize to 12. LobbyService seats at most 12 (LobbyRules.MAX_PARTY);
	    bots fill every empty seat, so a match always has 4 squads.
	  - Workspace.StreamingEnabled = false (recommended): the arena is small and client
	    scripts read arena parts. If you turn it on, set the arena and LobbyPad models to
	    ModelStreamingMode = Persistent.
	  - Workspace.SignalBehavior = Deferred is fine: nothing here relies on immediate signals.
	  - Workspace.FallenPartsDestroyHeight: keep the default (-500). The lobby pad sits at
	    Y = 0 around (0, 0, -400) and has invisible walls.
	  - Remove the template Baseplate and SpawnLocation from the place: LobbyService builds
	    the only SpawnLocation (on the lobby pad).
	  - Players.CharacterAutoLoads = true (set in default.project.json).
	  - Game Settings > Security: API Services ON (DataStores) for Studio testing.
	  - Avatar: R15, scaling off recommended so hitboxes match the 2-D combat sim.
	  - Gravity stays at the default (196.2): there is no gameplay physics.
]]

require(script.Parent:WaitForChild("Boot")).start()

print("[Main] Trunkfall server ready")
