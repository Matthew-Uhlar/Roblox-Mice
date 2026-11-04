# tests/runtime: headless Roblox runtime emulator

This runs the real server and client scripts (`src/server`, `src/client`) in a
Roblox-like runtime under Lune 0.11, with no Studio needed. The scenario specs
are `tests/specs/Runtime*.spec.luau`, and `scripts/test.sh` runs them.

```bash
scripts/test.sh Runtime                     # just the runtime scenarios
lune run tests/runtime/fuzz.luau 3 Immediate  # exploratory UI fuzz (seed, signal mode)
```

## How it works

| File | Role |
|---|---|
| `Scheduler.luau` | Deterministic virtual time: `task.*`, `wait`/`tick`/`os.clock`, deferred queue. Every thread and handler runs in a context (the server, or one client). Errors are recorded with a traceback; `warn` is recorded too. |
| `Instance.luau` | Instance class backed by Lune's Roblox **reflection database**: real class hierarchy (`IsA`), every property with its default, type checks on write, read-only properties, attributes (with type rules), tags, change signals, `WaitForChild` (with the "Infinite yield possible" warning), `Clone`, `Destroy`. An unknown member raises Roblox's "X is not a valid member of …" error and is recorded as a possible **EMULATOR GAP**. A property the database marks not scriptable (Terrain.Decoration, Lighting.Technology's write) raises Roblox's capability error and is NOT a gap; `default.project.json` may still set such properties (load time, `Inst.setSerialized`). |
| `Classes.luau` | Parts and models (CFrame/Position, `PivotTo`/`GetPivot`), GUI geometry (`AbsoluteSize`/`AbsolutePosition`), Humanoid, Player (`IsFriendsWith` from `rt.config.friends`, `GetJoinData().Members`, `FollowUserId`), remotes, bindables, tweens, sounds, particles. **Terrain**: `FillBlock`, `FillBall`, `FillCylinder`, `FillWedge`, `FillRegion`, `Clear`, `SetMaterialColor`/`GetMaterialColor`, `ReadVoxels`/`WriteVoxels` (no grid: reads return Air), cell helpers, and the `Water*` properties. Fills are validated like Roblox (argument types, finite numbers, terrain-only materials) and recorded cheaply: counts per method and material, solid/Air bounds, the largest fill in voxels (`rt:terrainStats()`). **Lighting**: `Technology` is readable but not script-writable (Plugin capability); the post-effects are plain reflection classes. `Workspace.Terrain` returns the Terrain. |
| `Services.luau` | In-memory services: Players, RunService, Workspace/Camera, TweenService, CollectionService, HttpService, DataStoreService (with request budgets and the 1-write-per-6-s-per-key queue), MessagingService, MemoryStoreService, MarketplaceService, PolicyService, BadgeService, TextChatService, TeleportService, GuiService, UserInputService, ContextActionService, StarterGui, SocialService, AdService, Debris, … |
| `Datatypes.luau` | Random (deterministic), TweenInfo, DateTime, RaycastParams, OverlapParams. All other datatypes come from `@lune/roblox`. |
| `Runtime.luau` | Builds the DataModel from `default.project.json`: `.server.luau` → Script, `.client.luau` → LocalScript, `.luau` → ModuleScript, folders → Folder. Loads sources with `@lune/luau` in per-script environments. `require` supports instances and Roblox **require-by-string resolved on the instance tree** (`./X` = `script.Parent.X`, `../X` = `script.Parent.Parent.X`, `@self/X` = `script.X`), with per-context caches and cycle detection. Also handles players and characters, remotes, network delivery, and the driver helpers. |
| `Driver.luau` | Scenario helpers: click on-screen buttons, an autoplayer (upgrade cards, the winner's route vote, the Rind Gate extraction through ExtractUI, gear swaps), walkers (`circleWalker`, `squadWalker`: safe corner + the boss at the centre), read-only taps (`tapWorldEvents`: PvP hits, downs, kills, eliminations, loot bags, gear; `tapArena`) and the test-only knobs. |

The Roblox semantics that make a clean run meaningful:

- **Contexts.** There is one server context and one client context per player, each with its own module cache, `_G` and `shared`. In a client, `Players.LocalPlayer`, `RunService:IsClient()`, `workspace.CurrentCamera`, the device and the viewport are per client.
- **Visibility.**
  - Instances a client creates exist only for that client.
  - Children of ServerScriptService and ServerStorage are invisible to clients.
  - A client's property or attribute write to a server-owned instance stays local to that client. The exception is its own character's physics, which replicates like network ownership.
- **Remotes.**
  - Arguments are deep-copied with Roblox's rules: no metatables and no functions; mixed tables lose their dictionary part; non-string keys become strings; instances the receiver can't see arrive as `nil`.
  - `buffer` passes through.
  - Events queue until the first connection.
  - `UnreliableRemoteEvent` payloads over 900 bytes are dropped.
  - Calling a remote from the wrong side raises.
  - A lossy copy is recorded as a `REMOTE LOSSY` warning.
- **Signals.** `Workspace.SignalBehavior` is Deferred by default, and Immediate is available (`RuntimeImmediate.spec`).
- **DataStores.**
  - Values are JSON-validated: no mixed or sparse tables, no NaN, valid UTF-8.
  - The `UpdateAsync` transform must not yield.
  - Request budgets follow the documented per-minute limits.
  - Writes to one key faster than once per 6 s are queued with Roblox's warning.
- **Characters.**
  - `CharacterAdded` fires before the model is parented.
  - Characters have the default `Health` and `Animate` scripts and `Archivable = false`.
  - On respawn, ScreenGuis with `ResetOnSpawn = true` are removed.

## Scenarios (each asserts zero script errors, zero emulator gaps and no unexpected warnings)

| Spec | What it plays |
|---|---|
| `RuntimeBoot` | Server boot; every Net remote with the right class; the emulated tree matches `rojo build` (names, classes, sources); emulator self-checks (Terrain/Lighting rules included). |
| `RuntimeSolo` | One player and 11 bots (2 squad-mates, 3 bot squads), driven through the real UI: READY, the match (waves, boss, the route vote only when the squad won the boss, the Rind Gate: Stay, then Extract after stage 2), Results ("Win" only when extracted), the profile saved with cheese and class XP, back to the lobby, then leaving releases the lock. |
| `RuntimeSquads` | 4 humans in 2 friend pairs: 4 squads seated (friends together), PvP only between enemy squads, a squad elimination and loot bags, a stage-2 extraction paid at once while the match goes on, route votes only to the boss winner, per-class XP, gear picked up and gone in the next run. |
| `RuntimeStudio` | A Studio test player with UserId −1 is a human, not a bot, and is seated in a squad as a human member. |
| `RuntimePurchase` | `PromptProduct` reaches MarketplaceService; the same receipt twice is granted once and both calls return `PurchaseGranted`; a receipt for a player who left gets `NotProcessedYet`. |
| `RuntimeLeave` | The only human leaves mid-match: the `beforeRelease` payout (50% of their own share, 0 on a DoN stage), a clean teardown (noHumans), a new match, then `BindToClose`. |
| `RuntimeVeteran` | Every pass owned: chat tags, cosmetics, a shop buy and equip, the daily reward, Pressure set by the leader and used by the match. |
| `RuntimeImmediate` | Immediate signals, Play Solo ordering, a phone client, the auto-start, slow DataStores and a laggy connection, through a whole match. |

## Test-only knobs (tests only; `src/` has no test code)

- `RunDirector.WAVE_SECONDS` is set on the server context's module table.
- `Driver.powerUp(rt, mult)` wraps the server context's `Stats.compute` for 25× hero damage and HP, so bosses die quickly.
- `Driver.scaleHeroHp(rt, fn)` scales chosen heroes' max HP in the server World (RuntimeSquads makes one bot squad fragile so an elimination happens through the real code path).
- `rt.config.friends`, `addPlayer({ followUserId, joinMembers })` set up parties for LobbyService's friend seating.
- Fake Creator Dashboard ids are written into the server context's `Config/Monetization` items, because the real ids are still 0.
- `rt:seedDataStore`, `rt.config.ownedPasses`, `rt.config.dataStoreFail` and `rt.config.isStudio` set up the environment.
- `rt:setNetConditions` sets replication rate, latency, jitter and freezes.

## What it cannot tell you (needs real Studio or a live server)

- Rendering, layout and readability:
  - real text metrics; `TextBounds` and `AbsoluteSize` are approximations
  - camera feel
  - mobile safe areas
- Physics:
  - collisions, falling and character controller feel
  - `Raycast` always returns nil here
- Real network behaviour: real bandwidth accounting, packet loss and ordering across remotes.
- Real DataStore and MessagingService latency, outages and cross-server locking.
- Marketplace prompts and real receipts.
- Engine-side limits: script timeouts, memory, and the `Highlight` cap.

Also untested here:

- Client changes to a server instance's `Parent` or `Destroy` are applied globally here (and noted in `Instance.clientLocal`); on Roblox they stay local.
- The emulator only knows the Roblox methods it implements. A method that exists on Roblox but not here shows up as an EMULATOR GAP. Add it to `Classes.luau` or `Services.luau`.
