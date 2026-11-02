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
| `Instance.luau` | Instance class backed by Lune's Roblox **reflection database**: real class hierarchy (`IsA`), every property with its default, type checks on write, read-only properties, attributes (with type rules), tags, change signals, `WaitForChild` (with the "Infinite yield possible" warning), `Clone`, `Destroy`. An unknown member raises Roblox's "X is not a valid member of …" error and is recorded as a possible **EMULATOR GAP**. |
| `Classes.luau` | Parts and models (CFrame/Position, `PivotTo`/`GetPivot`), GUI geometry (`AbsoluteSize`/`AbsolutePosition`), Humanoid, Player, remotes, bindables, tweens, sounds. |
| `Services.luau` | In-memory services: Players, RunService, Workspace/Camera, TweenService, CollectionService, HttpService, DataStoreService (with request budgets and the 1-write-per-6-s-per-key queue), MessagingService, MemoryStoreService, MarketplaceService, PolicyService, BadgeService, TextChatService, TeleportService, GuiService, UserInputService, ContextActionService, StarterGui, SocialService, AdService, Debris, … |
| `Datatypes.luau` | Random (deterministic), TweenInfo, DateTime, RaycastParams, OverlapParams. All other datatypes come from `@lune/roblox`. |
| `Runtime.luau` | Builds the DataModel from `default.project.json`: `.server.luau` → Script, `.client.luau` → LocalScript, `.luau` → ModuleScript, folders → Folder. Loads sources with `@lune/luau` in per-script environments. `require` supports instances and Roblox **require-by-string resolved on the instance tree** (`./X` = `script.Parent.X`, `../X` = `script.Parent.Parent.X`, `@self/X` = `script.X`), with per-context caches and cycle detection. Also handles players and characters, remotes, network delivery, and the driver helpers. |
| `Driver.luau` | Scenario helpers: click on-screen buttons, an autoplayer for votes and upgrade cards, a walker, and the test-only knobs. |

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
| `RuntimeBoot` | Server boot; every Net remote with the right class; the emulated tree matches `rojo build` (names, classes, sources); emulator self-checks. |
| `RuntimeSolo` | One player and 2 bots, driven through the real UI: READY, 4 stages, Go Home, Results, the profile saved with more cheese, back to the lobby, then leaving releases the lock. |
| `RuntimeStudio` | A Studio test player with UserId −1 is a human, not a bot, and starts a run. |
| `RuntimePurchase` | `PromptProduct` reaches MarketplaceService; the same receipt twice is granted once and both calls return `PurchaseGranted`; a receipt for a player who left gets `NotProcessedYet`. |
| `RuntimeLeave` | The only human leaves mid-run: the `beforeRelease` payout, a clean teardown, a new run, then `BindToClose`. |
| `RuntimeVeteran` | Every pass owned: chat tags, cosmetics, a shop buy and equip, the daily reward, Pressure set by the leader. |
| `RuntimeImmediate` | Immediate signals, Play Solo ordering, a phone client, the auto-start, slow DataStores and a laggy connection, through a full cycle. |

## Test-only knobs (tests only; `src/` has no test code)

- `RunDirector.WAVE_SECONDS` is set on the server context's module table.
- `Driver.powerUp(rt, mult)` wraps the server context's `Stats.compute` for 25× hero damage and HP, so bosses die quickly.
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
