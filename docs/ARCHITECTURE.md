# Architecture & team contracts

Read `docs/GDD.md` first. This file is the contract between the dev teams: the
**file ownership** list says who may edit what, and the **APIs** section gives
the exact function signatures other teams call. Change a contract only by
editing this file and telling the owning team.

## Toolchain

| Tool | Use |
|---|---|
| Rojo 7 (`default.project.json`) | `rojo build -o build/Trunkfall.rbxlx` or `rojo serve` + Studio plugin |
| Lune 0.11 | runs pure-logic unit tests: `scripts/test.sh [filter]` |
| StyLua | formatting (`stylua src tests`) |
| Selene | lint (`selene src`) |

## Rojo mapping

| Folder | Roblox location | Contains |
|---|---|---|
| `src/shared` | `ReplicatedStorage.Shared` | **pure Luau**: configs, run rules, combat simulation, codecs, data schema. No `game`, no `Instance`, no Roblox datatypes (Vector3, Color3, CFrame). Must run in Lune. |
| `src/server` | `ServerScriptService.Server` | `Main.server.luau` plus `Services/*` (Roblox side: DataStores, remotes, characters, arena parts) |
| `src/client` | `StarterPlayer.StarterPlayerScripts.Client` | `Main.client.luau` plus `Controllers/*` and `UI/*` |

### Require conventions

- **Inside `src/shared`:** relative string requires only, e.g.
  `local Rng = require("../Util/Rng")`. They work in both Lune and Roblox. Never
  use `init.luau` in shared code.
- **Server/client → shared:** `local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")`
  then `require(Shared.Run.RunState)`.
- **Server/client siblings:** `require(script.Parent.X)`.
- All files start with `--!strict`. Types come from `src/shared/Types.luau`.
- Pure modules take an `Rng` (`src/shared/Util/Rng.luau`). Never call `math.random`
  in shared code, so tests stay deterministic.
- Time in shared code is **passed in**. Never call `os.clock()` or `tick()`
  inside a pure module.

## Server authority rules (non-negotiable)

1. The server simulates every enemy, projectile, pickup, damage number and
   reward. Clients send only intents (votes, upgrade picks, ability aim, shop
   buys).
2. Every `OnServerEvent` handler type-checks its arguments, clamps numbers,
   rejects NaN and inf (`x ~= x`), checks the run phase, and rate-limits per
   player (`src/server/Services/Guard.luau`).
3. No gameplay physics. Enemies are table entries moved with maths, and parts
   on clients are visuals only.
4. Robux purchases go only through `MonetizationService` (ProcessReceipt is
   idempotent and session-locked).

## File ownership

| Team | Owns (create/edit only these) |
|---|---|
| **A — Run & Progression** | `src/shared/Config/{Classes,Upgrades,Modifiers,Maps}.luau`, `src/shared/Run/*`, `tests/specs/Run*.spec.luau`, `tests/specs/Config*.spec.luau` |
| **B — Combat & Horde** | `src/shared/Config/{Enemies,Bosses}.luau`, `src/shared/Combat/*`, `src/server/Services/{CombatService,ArenaBuilder}.luau`, `tests/specs/Combat*.spec.luau` |
| **C — Client & UX** | `src/client/**` |
| **D — Data & Monetization** | `src/shared/Config/{Monetization,Cosmetics,Talents,Shop}.luau`, `src/shared/Data/*`, `src/server/Services/{DataService,MonetizationService,ShopService,LeaderboardService}.luau`, `tests/specs/Data*.spec.luau`, `docs/MONETIZATION.md` |
| **E — Server orchestration** | `src/server/Main.server.luau`, `src/server/Services/{RunDirector,LobbyService,Guard,Remotes}.luau` |
| **F — Bots** | `src/shared/Bots/*`, `src/server/Services/BotService.luau`, `tests/specs/Bot*.spec.luau`; may also edit Team E's `RunDirector.luau` / `LobbyService.luau` (Team E has finished) |
| Lead (integration) | `src/shared/{Types,Net}.luau`, `src/shared/Util/*`, `tests/lib/*`, `scripts/*`, `default.project.json`, docs |

## APIs

### Team A — `src/shared/Run/*`

```lua
-- Run/Stats.luau
Stats.DEFAULT : PlayerStats
Stats.compute(classId: string, upgradeStacks: {[string]: number}, blessingIds: {string},
              talents: {[string]: number}?) -> (PlayerStats, WeaponDef, AbilityDef)
Stats.worldMods(cycle: number, stageInCycle: number, curseIds: {string}, playerCount: number) -> WorldMods  -- playerCount is FRACTIONAL (humans + 0.6 × bots, RunState.partySize)
Stats.applyDelta(stats: PlayerStats, weapon: WeaponDef, delta: StatDelta, times: number) -> ()  -- in place

-- Run/Leveling.luau
Leveling.xpToNext(level: number) -> number
Leveling.addXp(level: number, xp: number, gained: number) -> (newLevel: number, newXp: number, levelsGained: number)

-- Run/UpgradeOffers.luau
UpgradeOffers.roll(rng: Rng, classId: string, stacks: {[string]: number}, luck: number, count: number?) -> {UpgradeDef}

-- Run/Vote.luau
Vote.new(optionCount: number, voterIds: {number}) -> vote
vote:cast(voterId: number, option: number) -> boolean      -- false if invalid / not a voter
vote:tally() -> {[number]: number}
vote:allVoted() -> boolean
vote:resolve(rng: Rng, default: number?, needsHuman: {number}?) -> number  -- highest count, random tie-break; options in needsHuman only win with ≥1 human vote (Vote.riskyIndices)

-- Run/RunState.luau  (pure state machine; RunDirector drives it)
RunState.new(seed: number, playerCount: number) -> run
run:getPublic() -> PublicRunState
run.phase : RunPhase
run:openRouteVote() -> {RouteCard}            -- phase -> "RouteVote"
run:chooseRoute(cardIndex: number) -> RouteCard  -- applies curse; phase -> "Waves"
run:startBoss() -> ()                         -- phase -> "Boss"
run:bossDefeated() -> { cheesePerPlayer: number, blessingId: string?, epic: boolean, xpPerPlayer: number }
                                              -- adds to pending; applies blessing; phase -> "StageClear"
run:openBankVote() -> { kind: "bank" | "cycle", options: {string} }
      -- stages 1–3 of a cycle: options {"Continue", "DoubleOrNothing"}, phase "BankVote"
      -- stage 4: options {"GoHome", "NextCycle"}, phase "CycleVote"
run:chooseBank(option: string) -> ()          -- advances stage/cycle or ends the run (GoHome -> "Results")
run:wipe() -> ()                              -- phase -> "Results", outcome "Wipe"
run:finalRewards() -> { cheesePerPlayer: number, xpPerPlayer: number, outcome: "Win" | "Wipe" }
run:activeCurses() -> {string}; run:activeBlessings() -> {string}
run:worldMods() -> WorldMods                  -- Stats.worldMods for current state
run:currentRoute() -> RouteCard?
```

### Team B — `src/shared/Combat/*`

```lua
-- Combat/World.luau  (pure simulation; CombatService wraps it)
World.new({ rng: Rng, mods: WorldMods, arenaRadius: number, obstacles: {{x: number, z: number, r: number}},
            enemyPool: {string}, cycle: number, stage: number }) -> world
world:addPlayer(id: number, stats: PlayerStats, weapon: WeaponDef, ability: AbilityDef, x: number, z: number)
world:removePlayer(id: number)
world:updatePlayer(id: number, stats: PlayerStats, weapon: WeaponDef)   -- keeps hp ratio
world:setPlayerPosition(id: number, x: number, z: number)
world:useAbility(id: number, aimX: number, aimZ: number, now: number) -> boolean
world:useSecondWind(id: number) -> boolean
world:setMods(mods: WorldMods)
world:startWaves(duration: number)            -- spawning ramps over duration
world:stopSpawning()
world:spawnBoss(bossId: string, x: number, z: number)
world:clearEnemies()
world:step(dt: number, now: number) -> {FxEvent}
world:snapshot() -> {EnemySnap}
world:drainEvents() -> {{ type: "xp" | "damaged" | "downed" | "revived" | "dead" | "kill" | "bossDead" | "bossPhase", id: number?, amount: number?, kind: string? }}
world:getPlayer(id: number) -> { hp: number, maxHp: number, downed: boolean, downedUntil: number?, dead: boolean,
                                  abilityReadyAt: number, x: number, z: number }?
world:allPlayersDown() -> boolean
world:bossAlive() -> boolean
world:bossInfo() -> { id: string, hpFrac: number, phase: number }?
world:respawnDead(hpFrac: number)             -- end of stage: spectators come back

-- Combat/SnapshotCodec.luau
SnapshotCodec.encode(snaps: {EnemySnap}, serverTime: number) -> buffer
SnapshotCodec.decode(buf: buffer) -> (serverTime: number, snaps: {EnemySnap})
```

`EnemySnap.kind`: index into `Enemies.ORDER`, or `200 + index` into `Bosses.ORDER`.
FxEvent shapes: `{t="proj", id, kind, x, z, vx, vz, ttl, r}`, `{t="hit", x, z, amount, crit}`,
`{t="die", x, z, kind}`, `{t="tele", shape="circle"|"line"|"cone", x, z, r, dx?, dz?, len?, angle?, delay}`,
`{t="slam", x, z, r}`, `{t="pickup", id, x, z}` (crumb spawned), `{t="pickupTaken", id, by}`,
`{t="boom", x, z, r}`, `{t="down", id}`, `{t="revive", id}`, `{t="ability", id, kind, x, z, r}`, `{t="melee", id, x, z, dx, dz, r, arc}`.
Every Fx is JSON-safe (numbers, strings, booleans; no Roblox types).

```lua
-- Services/CombatService.luau  (server; Roblox side)
CombatService.start(world, players: {Player})  -- Heartbeat loop: sync positions, step, broadcast Snapshot (~15 Hz) and Fx (every step, batched)
CombatService.stop()
CombatService.events -> BindableEvent-like signal with drained world events (RunDirector listens)
-- Services/ArenaBuilder.luau
ArenaBuilder.build(mapId: string, seed: number) -> { model: Model, obstacles: {{x, z, r}}, spawn: Vector3, radius: number }
ArenaBuilder.clear()
```

### Team D — data & monetization

```lua
-- Data/ProfileSchema.luau (pure)
ProfileSchema.VERSION; ProfileSchema.default() -> Profile; ProfileSchema.migrate(raw: any) -> Profile
ProfileSchema.view(profile) -> table          -- safe subset sent to the client
-- Data/Shop.luau (pure): Shop.canBuy(profile, itemId) -> (boolean, reason?); Shop.buy(profile, itemId) -> (boolean, reason?)
-- Data/Daily.luau (pure): Daily.claim(profile, dayNumber) -> (ok, reward?)
-- Services/DataService.luau
DataService.init(); DataService.get(player) -> Profile?; DataService.waitFor(player) -> Profile?
DataService.update(player, fn: (Profile) -> ()) ; DataService.push(player)  -- sends Profile view
DataService.awardRun(player, cheese: number, xp: number, stats: {won: boolean, cycle: number, bosses: number, cycle1Time: number?})
-- Services/MonetizationService.luau
MonetizationService.init(); MonetizationService.hasPass(player, key) -> boolean
MonetizationService.cheeseMult(player) -> number   -- passes, boosts, premium; RunDirector multiplies payouts
MonetizationService.extraRerolls(player) -> number
MonetizationService.prompt(player, key)
```

### Team E — orchestration

`Main.server.luau` calls `Net.setupServer()` and initialises the Data,
Monetization, Shop, Leaderboard and Lobby services, then `RunDirector`.
`RunDirector` owns the run loop: lobby countdown, route vote, arena build,
waves timer, boss, rewards, bank vote, results and the profile award. It
bridges `RunState` and `World` and owns per-player run data: level, xp,
upgrade stacks, pending offers and rerolls.

### Team F — bots

Bot participant ids live in their own band, **−1001, −1002, …**
(`src/shared/Util/Ids.luau`: `Ids.botId(n)`, `Ids.isBot(id)`). Real players use
their UserId, which is **negative for Studio test players (−1…−8)**, so never
test for a bot with `id < 0`; always use `Ids.isBot`. Every world, vote, party and HUD map must accept both.
`CombatService` syncs positions only for ids that belong to a real Player.
`BotService` drives bot positions through `world:setPlayerPosition`.

```lua
-- Bots/BotBrain.luau (pure)
BotBrain.new(id: number, classId: string, rng: Rng) -> brain
brain:think(view: { self: {x, z, hp, maxHp, downed, abilityReady: boolean},
                    allies: {{id, x, z, downed: boolean, isBot: boolean}},
                    enemies: {EnemySnap}, arenaRadius: number,
                    obstacles: {{x, z, r}}, now: number }, dt: number)
      -> { moveX: number, moveZ: number, speedFrac: number, ability: {x: number, z: number}? }
BotBrain.chooseUpgrade(cards: {UpgradeDef}, rng) -> index
BotBrain.chooseVote(kind: string, options: {any}, humanTally: {number}, rng) -> index
-- Bots/BotRoster.luau (pure): BotRoster.fill(humanCount, maxParty, minParty, takenClassIds, rng) -> {{id, name, classId}}
```

### Team D additions (fix round)

- `Services/CosmeticsService.luau` draws each player's equipped trail, hat,
  tint, nametag and chat tag. Chat tags use the player attributes `ChatTag` and
  `ChatTagColor`. Call `CosmeticsService.suspendTrail(player)` before any
  teleport so the trail doesn't streak across the map.
- `Data/Looks.luau` (pure) resolves a profile into a look.
- `Data/Passes.luau` (pure) records pass-sourced grants in
  `profile.passGrants`, so perks are revoked on join when the pass is no longer
  owned.
- `MonetizationService.prompt(player, key) -> (ok, reason)` refuses boosts that
  would pass their cap. `MonetizationService.onEntitlementsChanged` fires when
  a pass or Club status changes.
- `C2S.SetSetting(key, boolean)` is handled in ShopService. Only the
  allowlisted key `hints` is accepted.
- ProfileSchema v3 (v4 since Team G1: `pressure`, `discoveries`). A save that fails to migrate puts the session in
  **corrupt** mode: it is read-only, the player is kicked with a "your data is
  safe" message, and the lock is released without writing.
- The stale lock threshold is 7 min, plus a MessagingService release handshake.
- Saves are paced and coalesced (runtime-emulator fix): one write per profile key every
  `DataService.WRITE_SPACING` (6 s, Roblox's per-key write limit). Save requests made
  while waiting share one write, so `DataService.save` may take up to 6 s to confirm.
  `awardRun` does not save on its own while the session is releasing, because the release save covers it.

## Pressure (Team G1, GDD §3.7)

Pre-run difficulty modifiers. Pure maths in `src/shared/Run/Pressure.luau`,
data in `src/shared/Config/Pressure.luau` (8 modifiers, 1 point per rank,
`MAX_POINTS = 21`). A **board** is `{[modId]: rank}`; anything from a client
or a save goes through `Pressure.sanitize` (unknown ids dropped, ranks floored
and clamped to `0..maxRank`, at most 64 raw keys looked at).

```lua
-- Run/Pressure.luau (pure)
Pressure.sanitize(raw: any) -> Board;  Pressure.setRank(board, modId, rank) -> Board?   -- nil = unknown id
Pressure.points(board) -> number                       -- 0..21
Pressure.applyToMods(mods: WorldMods, board) -> WorldMods  -- in place (Stats.applyCurse semantics)
Pressure.cheeseMult(points) -> 1 + 0.08*points;  Pressure.luck(points) -> 0.05*points;  Pressure.epicBonus(points) -> 0.02*points
Pressure.pickLeader({{id, ready, readyAt?, joinedAt, willing?}}) -> id?
Pressure.recordRun(profile.pressure, won, points) -> (unlockedNow, newRecord)

-- Run/RunState.luau
RunState.new(seed, partySize, { bossIds?, mapIds?, pressure: {[modId]: number}? })  -- board sanitized here
run:worldMods()        -- Stats.worldMods(...) + Pressure.applyToMods(board)
run:bossDefeated()     -- cheesePerPlayer = floor(stageCheese * (1 + 0.08*points)); flows into pending/banked
run:finalRewards()     -- { cheesePerPlayer (already includes the bonus, counted once), xpPerPlayer, outcome, pressurePoints }
run:pressurePoints() -> number;  run:pressureLuck() -> number (0.05/point);  run:pressureBoard() -> Board (copy)
run:getPublic()        -- + pressure: Board, pressurePoints: number
-- every rolled RouteCard.epicChance = min(1, tier base + 0.02*points) (Low/Mid too)

-- Services/LobbyService.luau
LobbyService.onStart(fn(players, classes, bots, pressure: {[modId]: number}))  -- leader's validated board, {} = none
LobbyService.getPressure() -> (Board, leader: Player?)
-- C2S.SetPressure(modId: string, rank: number): Guard.connect (string<=32, number clamped -100..100,
--   rate 6/s burst 10); leader only, lobby only, leader's profile.pressure.unlocked required,
--   rank clamped to the modifier's max; saved to profile.pressure.board.
-- S2C.Lobby payload: pressure = { board, points, leaderId?, unlocked (leader's), youUnlocked (recipient's) };
--   players[id].leader = true on the leader's entry.
```

**Party leader:** the first human to ready up (`readyAt`), else the
earliest-joined willing player (would be in the next party), else the
earliest-joined player in the lobby. At start the leader is picked among the
starting party. A run led by a player who hasn't unlocked Pressure has none.

**Profile (v4):** `profile.pressure = {unlocked, highestCleared, board}` and
`profile.discoveries = {[poiId] = true}` (rare POIs, Team G2). `Award.applyRun`
takes `pressurePoints`: a win (Go Home) unlocks the board and raises
`highestCleared`; a wipe changes nothing. `DataService.awardRun` forwards
`stats.pressurePoints`; RunDirector must pass it.

**WorldMods fields added for Pressure** (defaults in `Stats.defaultWorldMods`;
optional in `Types.WorldMods`, so read them with a default). Combat/World must
implement these (status: see `docs/HANDOFF.md`):

| Field | Default | Meaning |
|---|---|---|
| `eliteSpeedMult` | 1 | multiplies the move speed of elite mice, on top of `enemySpeedMult` |
| `eliteSizeMult` | 1 | multiplies an elite's radius at spawn and the area (radius) of its attacks (fuse blast, projectile radius) |
| `lateSpawnMult` | 1 | multiplies the spawn rate while `elapsed >= duration - Config/Pressure.LATE_SPAWN_WINDOW` (60 s) of a wave |
| `rangedExtraProjectiles` | 0 | integer; each ranged-mouse volley fires `1 + n` projectiles in a small fan |
| `enemyXpMult` | 1 | multiplies the XP in crumbs dropped by mice (not boss crumbs); No Snacks |

The other Pressure effects use existing fields: Hot Crumbs
`enemyProjectileSpeedMult`, Boss Fury `bossDamageMult` (and `enemyDamageMult`
from stage 2), Thick Rind `enemyHpMult` and `bossHpMult`, No Snacks
`healingMult`, Stampede and Big Cheese `eliteChance`. Modifiers with
`perStage` grow with the run's global stage: `RunState.worldMods` passes
`globalStage()` to `Pressure.applyToMods(mods, board, globalStage)`.

## Network

See `src/shared/Net.luau` for every remote and its payload. Snapshots use a
`buffer` over an `UnreliableRemoteEvent` at about 15 Hz. Clients interpolate
between the last two snapshots, with about 100 ms of render delay.
