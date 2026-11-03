# In-Roblox smoke test

After every publish, `publish.yml` runs `python3 scripts/publish.py smoke VERSION`.
It sends `scripts/smoke.luau` as an Open Cloud **Luau Execution** task against the
new place version on a real Roblox server, then asserts the facts the script returns.

## Why the script boots the game itself

Luau Execution tasks don't run the place's Scripts. So `smoke.luau` waits 5 s, and
if `ReplicatedStorage.Remotes` doesn't appear it boots the server the way
`src/server/Main.server.luau` does:

1. **If `ServerScriptService.Server.Boot` (a ModuleScript) exists**, it calls
   `Boot.start()`. This is the single source of truth (see below).
2. **Otherwise it runs a mirror of Main:** `Net.setupServer()`, then the OPTIONAL
   services (pcall require + init), then `Players.RespawnTime = 3`, then the
   REQUIRED services.

`python3 scripts/publish.py smoke-sync` compares the mirror with Main.server.luau:

- `scripts/check.sh` prints a warning when they differ.
- `publish.yml` refuses to publish until they match.

So if you add a service to Main, update `OPTIONAL` / `REQUIRED` in `scripts/smoke.luau`, or better, adopt the Boot module.

## Facts and checks

| Fact | Check |
|---|---|
| `bootError` (xpcall traceback) | absent |
| `placeVersion`, `gameId` | equal the published version and `ROBLOX_UNIVERSE_ID` |
| `services` (`name → ok / missing / load failed / init failed`) | every service `ok` |
| `remotes` / `expectedRemotes` (from `Net.C2S` + `Net.S2C`) | equal and > 0 |
| `spawnLocations` | ≥ 1 (LobbyService builds the spawn) |
| `stringRequire` | Config/Monetization loaded, and its `require("./ProductIds")` worked on a live server |
| `configuredItems` | equals the number of non-zero ids in the catalog |
| `errors` (LogService errors during boot + 3 s) | none |
| `autoRan`, `bootMode`, `warnings` | informational |

The checks live in `cmd_smoke` in `scripts/publish.py`. Update them in the same
commit when the world changes, for example if the redesign removes the lobby
SpawnLocation. Failures print the task log and a ✅/❌ table in the run summary.

A task that stays `PROCESSING` past the 5-minute poll is retried once with a fresh
task. Read the printed logs before you treat a timeout as a code bug.

## Single source of truth: the `Boot` module (requested src change)

`src/**` belongs to the redesign team, so the publishing team didn't make this change:

1. Move the body of `Main.server.luau` into `src/server/Boot.luau`, which becomes the ModuleScript `ServerScriptService.Server.Boot`:

   ```lua
   --!strict
   -- Boots the server. Main.server.luau calls start(); so does the in-Roblox smoke
   -- test (scripts/smoke.luau), because Luau Execution doesn't run Scripts.
   local Boot = {}
   function Boot.start(): { [string]: string }
       local status = {} -- service name -> "ok" | "missing" | "load failed: ..." | "init failed: ..."
       -- ...the current Main.server.luau body, with initOptional recording into `status`
       --    (`script.Parent` still finds Services: Boot sits next to it)...
       return status
   end
   return Boot
   ```

2. Reduce `Main.server.luau` to its header comment plus:

   ```lua
   require(script.Parent:WaitForChild("Boot")).start()
   print("[Main] Trunkfall server ready")
   ```

`smoke-sync` then passes by construction, and `smoke.luau` stops using its mirror. The runtime-emulator specs keep working because they still start Main.server.luau.
