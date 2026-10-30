# Technical Research: Roblox Horde-Survivor

*Technical research team, 2026-10-30. Scope: co-op 1–4 player horde-survivor with bosses, top-down camera, 100–300 enemies, no physics-driven gameplay (see `../brainstorm-2026-06.md`, Topic 4).*

> **Method note.** create.roblox.com, devforum.roblox.com and about.roblox.com could not be fetched directly from this session, so these findings come from search-index excerpts of those pages plus established practice. Items marked **(verify)** should be checked against the live page before anyone builds on them.

---

## 1. Horde performance (100–300 enemies)

**Don't give enemies Humanoids.** Every Humanoid runs a state machine and physics and replicates its own properties. Forum consensus is that hundreds of Humanoids are the main cause of lag in NPC-heavy games ([optimise hundreds of humanoids](https://devforum.roblox.com/t/how-to-optimise-hundreds-of-humanoids/1760085), [RTS with 200+ units](https://devforum.roblox.com/t/how-we-are-developing-an-rts-game-with-good-performance-for-more-than-200-units/3281168/8)).

**Server simulation in plain math:**
- Keep enemies as data in arrays (posX, posZ, velX, velZ, hp, typeId, state) indexed by a u16 id. The server creates **no Instances** for them, so network ownership never applies.
- Run a fixed-step tick at 15–20 Hz on `Heartbeat` with an accumulator.
- **Pathing:** rebuild a flow field over a baked map grid (a BFS outward from all players) about 4 times per second. Enemies follow the grid gradient. Separation forces use a spatial hash with cells of about 4 studs. Don't raycast per enemy; bake obstacles and height into the grid when the map loads.
- Add `--!native` to hot modules ([native codegen](https://devforum.roblox.com/t/luau-native-code-generation-preview-studio-beta/2572587)). Reach for Parallel Luau Actors only if the profiler calls for it.
- Any server-side parts that must exist (boss telegraphs, for example) are **Anchored**. Anchored parts have no network owner.

**Compact replication:**
- Encode each tick **once** into a `buffer` and send the same buffer to everyone with `FireAllClients`.
- Each enemy takes 8 bytes: `u16 id`, `i16 x`, `i16 z` (quantised to 1/8 stud, giving ±4096 studs), `u8 yaw`, `u8 anim/flags`.
- `UnreliableRemoteEvent` payloads are documented at **≤900 bytes**, and larger ones are **dropped** ([API](https://create.roblox.com/docs/reference/engine/classes/UnreliableRemoteEvent), [announcement](https://devforum.roblox.com/t/introducing-unreliableremoteevents/2724155)). Split each snapshot into self-contained chunks of 850 bytes or less (a `u16 tick` header plus about 100 entries).
- At 300 enemies and 10 Hz the raw cost is about 24 KB/s. Send enemies near any player at 10 Hz and far or off-screen ones at 3 Hz, and skip idle ones. The target is under 20 KB/s per client.
- Events that must arrive go on a **reliable** RemoteEvent, batched per frame: spawn batch, death batch, hit/damage-number batch, boss phase changes, run state.
- For typed reliable events, use an IDL code generator: [Blink](https://devforum.roblox.com/t/blink-an-idl-compiler-written-in-luau-for-roblox-buffer-networking-0185/2959671) or Zap ([comparison](https://devforum.roblox.com/t/zap-or-bytenet-performance-security/2888968)). Write the snapshot codec by hand so it can be tested in Lune.

**Client rendering:**
- Keep pooled models per enemy type in a client-only Workspace folder, parked out of view when unused.
- Interpolate about 120 ms behind the newest snapshot (lerp position, shortest-arc yaw). On packet loss, extrapolate for at most one tick.
- Each frame, build a list of parts and a matching list of CFrames, then make **one** `workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)` call. One report measured a ~70% FPS gain at 1,000 NPCs ([source](https://devforum.roblox.com/t/how-we-are-developing-an-rts-game-with-good-performance-for-more-than-200-units/3281168/8)). That was anecdotal, so profile it ourselves.
- Each enemy is 1–2 MeshParts with `Anchored`, `CanCollide=false`, `CanTouch=false`, `CanQuery=false` and `CastShadow=false`.
- Animate with procedural bob/squash folded into the same BulkMoveTo call. Use `AnimationController`+`Animator` only for elites and bosses.

**Mobile budgets** (no official numbers exist; starting targets to validate on a low-end Android phone with the MicroProfiler): ≤600 moving enemy parts (300 × 2), ≤1k triangles per enemy, ≤5–8k arena parts, ≤30 pooled damage numbers, no per-enemy BillboardGuis (health bars on elites and bosses only), pooled and capped ParticleEmitters, client render scripts ≤4 ms/frame, server step ≤5 ms at 300 enemies.

## 2. Networking and security

- **Treat every client argument as hostile.** Check `typeof`, reject NaN (`x ~= x`) and ±inf, clamp ranges, whitelist enum values, and check a buffer's length before reading it. Blink and Zap generate these checks.
- **Rate limits:** wrap every client-to-server handler in a token bucket per player and per remote (for example 20/s for input, 2/s for menu choices). Drop over-limit calls and log them; kick on sustained abuse.
- **Clients send intent only.** That means "ability slot 2 + aim angle (u8)", "upgrade option index k", "ready". Clients never send damage, hit lists, enemy ids, rewards, XP or currency. The server checks cooldowns, that the player is alive, and that the chosen option was actually offered.
- **Server-side hit detection for auto-attacks:** each tick, take the attacker's position from the server copy of its HumanoidRootPart, query the spatial hash with a circle, cone or line test, apply damage, and broadcast a hit batch for VFX. The client plays the swing immediately as cosmetic prediction only; AoE attacks on slow hordes hide latency well.
- **Movement:** characters are client-owned by default, so speed hacks and teleports are possible ([network ownership](https://create.roblox.com/docs/scripting/security/network-ownership)). Each tick, compare distance moved against `WalkSpeed × dt × 1.3` and snap the player back if it is exceeded. Server Authority (§6) is the longer-term fix.
- **Other rules:** never use `InvokeClient` (a client can yield it forever); server-only modules live in ServerScriptService/ServerStorage; don't trust client-set attributes or TeleportData; write code that works under `SignalBehavior = Deferred`.

## 3. Persistence

**DataStore limits:**
- 4 MB per key ([limits](https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits.md)).
- Request budgets are dynamic. Read them with `GetRequestBudgetForRequestType` instead of hard-coding the old "60 + 10×players" formula ([thread](https://devforum.roblox.com/t/datastore-request-limits-not-consistent/3216411)).
- An experience-wide **storage cap of 500 MB + 1 MB × lifetime users** applies. It was raised from 100 MB in July 2026 and has been enforced since April 2026 ([announcement](https://devforum.roblox.com/t/datastores-access-and-storage-updates/3597255), [recap](https://devforum.roblox.com/t/weekly-recap-july-13-%E2%80%93-17-animation-graphs-go-live-5%C3%97-more-data-store-storage/4743286)).
- Requests above the limits can be bought through Extended Services, and `SetRateLimitForRequestType` can raise server-level limits **(verify)** ([Extended Services](https://devforum.roblox.com/t/extended-services-for-data-stores-is-now-available/4504347)).

**ProfileStore** (loleris, [GitHub](https://github.com/MadStudioRoblox/ProfileStore), [docs](https://madstudioroblox.github.io/ProfileStore), [DevForum](https://devforum.roblox.com/t/profilestore-save-your-player-data-easy-datastore-module/3190543)):
- It is the supported successor to ProfileService, which is no longer supported. Licence is Apache-2.0.
- It provides session locking with a MessagingService-assisted handoff, auto-save, `:Reconcile()` and Luau types.
- By design it is for **per-player data only**, not leaderboards or global state.
- The author noted early on that it had seen limited production use. Check the latest release before shipping **(verify)**.

**`UpdateAsync` on other keys:** the transform must be pure and must not yield; return `nil` to cancel. Make writes idempotent: in `ProcessReceipt`, record the `PurchaseId` in the profile **before** granting.

**Versioning:** store a `DataVersion` integer. `Migrations[n]` is a pure n→n+1 function; run the chain on load, then `Reconcile`. Keep a fixture of every past schema version and test migrations in Lune.

**Leaderboards:** one `OrderedDataStore` per board (integer scores), written **at run end** only. A server task caches `GetSortedAsync` top 100 for ~5 minutes. Seasons go in key names (`Weekly_2026W44`).

**MemoryStoreService** ([docs](https://create.roblox.com/docs/cloud-services/memory-stores)): 1000 + 120 × CCU request units/minute; items ≤32 KB; each queue/map ≤1M items / 100 MB. Parties in a `MemoryStoreSortedMap` (or HashMap) with `UpdateAsync` for atomic joins; matchmaking via a `MemoryStoreQueue` polled by lobby servers; the run hand-off payload keyed by reserved-server access code (TeleportData is client-visible, so unsafe for this).

**Lobby to run flow:**
- Reserve a server (the reference now marks `ReserveServer` deprecated in favour of `ReserveServerAsync` **(verify)**).
- Put the access code in `TeleportOptions.ReservedServerAccessCode`, then call `TeleportAsync(runPlaceId, partyPlayers, options)` with retries and a `TeleportInitFailed` handler ([TeleportService](https://create.roblox.com/docs/reference/engine/classes/TeleportService), [party thread](https://devforum.roblox.com/t/teleporting-a-party-using-teleportpartyasync-not-sure-how-to-teleport-them-to-a-reserved-server/2224900)).
- **Keep the whole run in one reserved server.** Swap maps by cloning them from ServerStorage instead of teleporting for each map.
- Store `userId → access code` in MemoryStore so a disconnected player can rejoin within N minutes.

## 4. Project tooling

**Tool versions:**
- Pin every tool with **[Rokit](https://github.com/rojo-rbx/rokit)** (`rokit.toml`). It is drop-in compatible with Aftman and Foreman, and Aftman is effectively unmaintained.
- **Rojo 7.6.x.** 7.7 is in RC, adding syncback and a websocket sync loop ([releases](https://newreleases.io/project/github/rojo-rbx/rojo/release/v7.7.0-rc.1)).
- **Wally 0.3.x**, with Shared `Packages/` and `ServerPackages/`.
- **[Lune](https://docs.rs/crate/lune/latest) 0.10.x**: a standalone Luau runtime for tests and scripts.
- **StyLua** (`syntax = "Luau"`), **Selene** (`std = "roblox"`), and **luau-lsp** fed by `rojo sourcemap --watch`.

**Typing:**
- Put `--!strict` in every file.
- The new type solver reached general release in late 2025 and its Studio beta flag was removed on 2026-01-07 ([post](https://devforum.roblox.com/t/general-release-luau%E2%80%99s-new-type-solver/4084991)).
- Projects with strict scripts are opted out of the new solver by default. Pick one solver on purpose and set it in both Studio and luau-lsp.

**Testable modules:**
- Shared pure modules use **require-by-string** with relative paths (`require("./SpatialHash")`).
- Pure modules never call `game:GetService`; any engine dependency is passed in.
- Tests (`tests/**/*.spec.luau`) run with `lune run tests`. CI runs `stylua --check`, `selene`, `luau-lsp analyze` and the Lune tests.

**Do string requires work in live Roblox? Likely yes, but confirm with a live test.**
- Require-by-string is a Luau engine feature, not a Studio-only one, so it runs on live servers and clients. It shipped as "preliminary support" in Release Notes 647 (Oct 2024) and was then announced ([Introducing Require-by-String](https://devforum.roblox.com/t/introducing-require-by-string/3405078)).
- `./X` resolves to `script.Parent.X` and `../U/X` resolves to `script.Parent.Parent.U.X`, the same as Lune's file semantics. A folder with an `init` ModuleScript can be required ([RFC, Implemented](https://rfcs.luau.org/new-require-by-string-semantics.html)).
- **Caveats:**
  1. Rojo turns `foo/init.luau` into the ModuleScript `foo`. Inside it, `./bar` therefore means a *sibling* of `foo`, not its child. Use `@self/bar` there (approved in luau-lang/rfcs PR #109). Lune supports `@self`; the Roblox build that shipped it is unconfirmed **(verify)**.
  2. Engine support for `.luaurc` aliases was still pending in the sources found ([aliases RFC](https://rfcs.luau.org/require-by-string-aliases.html)). Use only `./` and `../`.
  3. Cyclic requires error in both Roblox and Lune. Keep the module graph acyclic and pass back-references in instead.
  4. Paths resolve by Instance name and are case-sensitive. Avoid duplicate siblings (`Rng.luau` next to `Rng/`). Scripts named `*.server.luau` or `*.client.luau` can't be required.
  5. luau-lsp needs the Rojo sourcemap to resolve string requires.
- **Action:** before standardising on string requires, publish a test place and confirm sibling, parent and `@self` requires work in a live server and on a client.

**Folder layout** (two places share `src/shared`, via `lobby.project.json` and `run.project.json`):

```
src/
  shared/      -> ReplicatedStorage.Shared   (PURE: Lune-testable)
    Sim/       Grid, SpatialHash, FlowField, EnemyMove, Combat, Rng
    Codec/     Snapshot, Quantize
    Data/      Schema, Migrations, Balance (enemy/upgrade tables)
    Types.luau
  client/      -> StarterPlayer.StarterPlayerScripts.Client
    Render/  Camera/  Input/  UI/  init.client.luau
  server/      -> ServerScriptService.Server
    Run/  Lobby/  Net/  Persistence/  init.server.luau
Packages/       -> ReplicatedStorage.Packages
ServerPackages/ -> ServerScriptService.ServerPackages
tests/          (not synced; Lune specs + fixtures)
```

`run.project.json` (sketch):
```json
{ "name": "Run", "tree": { "$className": "DataModel",
  "ReplicatedStorage": { "Shared": { "$path": "src/shared" }, "Packages": { "$path": "Packages" } },
  "ServerScriptService": { "Server": { "$path": "src/server" }, "ServerPackages": { "$path": "ServerPackages" } },
  "StarterPlayer": { "StarterPlayerScripts": { "Client": { "$path": "src/client" } } } } }
```

## 5. Top-down camera and mobile

**Camera:**
- Set `CameraType = Scriptable` and bind with `RunService:BindToRenderStep("TopDown", Enum.RenderPriority.Camera.Value + 1, ...)`.
- Each frame, set `cam.CFrame = CFrame.lookAt(focus + offset, focus)` with `offset ≈ (0, 45, 28)` (about 58° pitch). Use FOV 40–50, a spring follow, and a clamped zoom.
- Yaw stays fixed, so the default PlayerModule controls stay camera-relative.
- Design maps with no roofs. For tall props, fade them through `LocalTransparencyModifier` after a raycast from camera to player.

**Mobile controls:**
- Use the default dynamic thumbstick for movement.
- **Auto-attack** needs no button, which follows the Vampire Survivors model and suits touch.
- Give 2–3 large ability buttons on the bottom right. Default to auto-aim at the nearest or priority target; dragging off a button aims manually, in Wild Rift style.

**Input API:**
- Use the **Input Action System** (`InputContext`/`InputAction`/`InputBinding`) behind a thin `Input` module. Roblox calls it the input API it will primarily support, and it is publishable in the client beta ([client beta](https://devforum.roblox.com/t/client-beta-input-action-system-is-now-available-to-publish-in-experiences/3890979), [docs](https://create.roblox.com/docs/input/input-action-system.md)).
- ContextActionService still works, but its auto-generated touch buttons are hard to style.

**UI scaling:** Scale-based sizing plus `UIAspectRatioConstraint`; drive `UIScale` from the viewport (`min(vp.X/1280, vp.Y/720)`, clamped); `ScreenGui.ScreenInsets = DeviceSafeInsets` for notches; touch targets ≥44 pt; test in the Studio Device Emulator at phone sizes.

## 6. Engine changes in 2025–2026 that matter

**Server Authority:**
- It went from early access (2025) to Studio beta, then client beta (spring 2026), then **Full Release** in mid-2026 ([full release](https://devforum.roblox.com/t/full-release-ship-fair-and-competitive-games-with-server-authority/4727993), [docs](https://create.roblox.com/docs/projects/server-authority)).
- Setting `Workspace.AuthorityMode = Server` turns on NextGenerationReplication, PlayerScriptsUseInputActionSystem, Deferred signals, StreamingEnabled and UseFixedSimulation.
- Gameplay code moves into `RunService:BindToSimulation`. The client predicts and the server rolls it back when it disagrees.
- **For us:** it would make player movement server-authoritative and free us from writing reconciliation. Our enemy sim is unaffected.
- **Risks:** NextGenerationReplication has open reports, such as rubberbanding when the server sets a player's CFrame ([thread](https://devforum.roblox.com/t/workspacenextgenerationreplication-causes-rubberbands-when-manipulating-a-players-cframe/4795364)). It also forces the Input Action System.

**Other changes:**
- **Physics replication:** `ImprovedPhysicsReplication` rolled out June–July 2026 ([post](https://devforum.roblox.com/t/upcoming-improvements-to-physics-replication/4675512)). It barely affects us, since we avoid physics.
- **StreamingEnabled** is on by default for new places ([docs](https://create.roblox.com/docs/workspace/streaming)). Our client-created enemy models are unaffected. Arena geometry that client scripts read should use Persistent or Atomic model streaming, or `WaitForChild`.
- **Luau:** the new type solver, require-by-string, [user-defined type functions](https://rfcs.luau.org/user-defined-type-functions.html), native codegen, and the native `vector` type. The `buffer` type underpins all networking.
- **Data stores:** storage caps and Extended Services (§3).
- **Deprecations:** `task` library over `spawn`/`wait`/`delay`; `Animator:LoadAnimation` over `Humanoid:LoadAnimation`; constraint movers over legacy BodyMovers; `ReserveServerAsync` over `ReserveServer` **(verify)**; Input Action System soft-supersedes ContextActionService.

---

## Architecture recommendation

**Shape.**
- One experience with two places:
  - **Lobby:** party, meta-progression, shop, leaderboards.
  - **Run:** one reserved server per party of 1–4. It hosts the whole run (every map, boss, reward pick and double-or-nothing choice) and swaps maps by cloning them from ServerStorage.

**Server simulation (Run place).**
- One fixed-step loop at 20 Hz, `server/Run/World`, calls pure systems from `shared/Sim` in this order: Spawner → FlowField (rebuilt at 4 Hz) → EnemyMove (flow plus separation via spatial hash) → Combat (auto-attacks, abilities, projectiles as math) → Damage/Death → Loot/XP → Snapshot.
- Enemies, projectiles and pickups are arrays keyed by u16 ids, with **no Instances, no Humanoids and no physics**.
- Bosses use the same entity system plus a scripted phase state machine. Any telegraph parts are Anchored and visual only.
- Players are standard characters, client-owned, with server checks for speed and teleporting. Evaluate **Server Authority** in a spike at the vertical-slice milestone and adopt it only if NextGenerationReplication is stable for us.

**Networking.**
- **Reliable typed remotes** (Blink or Zap IDL):
  - Client to server: intents only (ability + aim, upgrade choice, ready).
  - Server to client: batched lifecycle events (spawn, death, hits, run state).
- **Snapshots:** a hand-written `shared/Codec/Snapshot` at 8 bytes per enemy, sent in chunks of 850 bytes or less over one `UnreliableRemoteEvent` with `FireAllClients`. Near enemies go at 10 Hz and far ones at 3 Hz.
- Every client-to-server handler goes through `server/Net/Guard` (type and range validation plus a token bucket).
- All damage and hit detection happens on the server.

**Client.**
- `Render/EntityRenderer`: per-type model pools, about 120 ms interpolation, one `BulkMoveTo` call per frame.
- Pools for VFX and damage numbers.
- `Camera/TopDown`: Scriptable camera with fixed yaw.
- `Input`: built on the Input Action System, with thumbstick movement, auto-attack, and 2–3 auto-aim ability buttons.
- UI uses `UIScale` and `DeviceSafeInsets`.

**Persistence.**
- **ProfileStore** for player profiles, with `DataVersion` and pure migrations.
- **OrderedDataStore** for leaderboards, written once per run.
- **MemoryStore** for parties, the matchmaking queue, the run hand-off payload and rejoin codes.
- `TeleportAsync` with `ReservedServerAccessCode` for lobby-to-run.

**Tooling.**
- Rokit pins Rojo 7.6, Wally, Lune, StyLua, Selene and luau-lsp.
- `--!strict` in every file.
- CI runs format, lint, type check and Lune tests.
- **Hard rule:** `shared/Sim`, `shared/Codec` and `shared/Data` never touch Instances or services, so they run under Lune.

**Budgets** (enforce from the first prototype):

| Item | Budget |
|---|---|
| Enemies | 300 |
| Parts per enemy | ≤2 |
| Server step | ≤5 ms |
| Client render scripts | ≤4 ms/frame |
| Download per client | ≤20 KB/s |
| Test device | a low-end Android phone, every milestone |

## Pitfalls

1. Prototyping enemies with Humanoids "for now". Once they're in, they never come out.
2. Snapshots over 900 bytes, which UnreliableRemoteEvents **drop silently** in live games.
3. Firing one remote per enemy instead of one batched buffer per tick.
4. Trusting client hit reports, damage, upgrade picks that were never offered, or TeleportData.
5. Writing to the DataStore every kill or wave. Write profiles through ProfileStore and leaderboards once per run.
6. Not versioning the save schema from day one.
7. Teleporting between maps mid-run. That brings failure points, lost run state, and load screens on mobile.
8. Calling `game:GetService` inside shared sim code, which stops it running under Lune. Likewise, `./child` inside a Rojo `init.luau` points at a sibling; use `@self/child`.
9. Raycasting per enemy per tick; bake the grid instead.
10. A BillboardGui per enemy, unpooled particles, and shadows on horde meshes.
11. Testing only on desktop. Phones hit memory and thermal limits much sooner.
12. Assuming StreamingEnabled is off. Client code must `WaitForChild` or use Persistent models.
13. Mixing the new and old type solvers between Studio and luau-lsp.
14. Adopting Server Authority without a spike. It forces the Input Action System, Deferred signals and NextGenerationReplication all at once.
