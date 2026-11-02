# Combat API as implemented (Team B)

This file adds to `docs/ARCHITECTURE.md` "Team B". Where they differ, the code
in `src/shared/Combat/World.luau` is the source of truth.

## Clock

All time is `workspace:GetServerTimeNow()`. `CombatService.now()` returns it.
After the first step, `useAbility` uses the world's own clock.

## World additions beyond the contract

| Function | Purpose |
|---|---|
| `world:getPlayers()` | Returns `{[id] = {id, x, z, hp, maxHp, downed, dead, abilityReadyAt, isBot}}` |
| `world:pickupsNear(x, z, r)` | Returns `{{x, z, xp}}`. Used by the bot AI. |
| `world:partyWeight()` | Bots count `World.BOT_WEIGHT` = 0.6 |
| `world:healPlayer(id, frac)` | Heals a fraction of max HP, times `healingMult` |
| `world:drainTeleports()` | Dash moves. CombatService applies them to characters. |
| `world:setStage(cycle, stage)` | Resets the cap of one Second Wind per stage |
| `setPlayerAbility`, `enemyCount`, `pickupCount` | Helpers |
| `forcePattern` | Test hook |
| `SnapshotCodec.encodeChunks(snaps, t, maxBytes = 850)` | Splits a snapshot into chunks |

Other additions:

- `CombatService`: `getWorld`, `setPlayers`, `stats`.
- `getPlayer` extra fields: `reviveProgress` (0..1), `secondWindUsed`, `slowed`, `hovering`, `invulnerable`, `moveSpeed`.
- `bossInfo` extra fields: `name`, `title`, `entityId`.

## Behaviour notes

- World applies `xpMult` to `xp` events, so callers must not multiply again.
- The optional `stats.crumbHeal` is honoured.
- Event `kind` values:
  - `damaged`: one of `contact | projectile | boss | zone | fuse | rock`.
  - `revived`: one of `teammate | secondWind | respawn`.
- Bosses:
  - 3 s invulnerable intro, a telegraph, then a landing slam.
  - The first pattern opens the fight, and the first pattern of each phase opens that phase.
  - On death: minions die, hostile projectiles clear, and every crumb flies to the party.
- CombatService:
  - Syncs HumanoidRootParts and Humanoids, and applies dash teleports, only for ids > 0.
  - Writes WalkSpeed every frame: ×0.3 downed, ×0.6 slowed, 0 for a spectator.

## Snapshot format

- **Header (13 bytes):** u8 version (= 1), f64 serverTime, u16 count, u8 chunkIndex, u8 chunkCount.
- **Entry (9 bytes):**

  | Field | Type | Notes |
  |---|---|---|
  | id | u16 | |
  | kind | u8 | |
  | x | i16 | stored ×8 |
  | z | i16 | stored ×8 |
  | hp | u8 | 0..255 |
  | flags | u8 | see below |

- **Flags:**
  - bit 0: elite
  - bit 1: telegraphing or airborne
  - bit 2: stunned or slowed
  - bit 3: boss minion
- **Size:** at most 93 entries per chunk (≤ 850 B). 220 enemies take 3 chunks.

## Fx events

**Contract events:** `proj` (plus `hostile`, `owner`), `hit` (plus `id`), `die` (plus `id`),
`tele` (plus `src`, `style`), `slam`, `pickup` (plus `xp`), `pickupTaken`, `boom`,
`down`, `revive`, `ability`, `melee` (cone weapons send `style = "cone"`).

**Additional events:**

| Event | Fields |
|---|---|
| `projEnd` | `id` |
| `strike` | `shape, x, z, dx, dz, len, r, angle` |
| `hurt` | `id, amount, x, z` |
| `dead` | `id` |
| `zone` | `id, kind, x, z, r, ttl, owner?, follow?, hostile?` |
| `orbit` | `id, n, r, blade, omega, t0`. Blade i's angle = omega·(t − t0) + i·2π/n. Re-sent every 5 s. |
| `chain` | `x1, z1, x2, z2, id` |
| `boss` | `id, bossId, name, title, x, z, intro` |
| `bossPhase` | `id, phase, x, z` |
| `minion` | `id, of, x, z` |
| `dash` | `id, dx, dz, speed, dur` |
| `leap` | `id, x, z, dur` |
| `blink` | `id, x, z, delay` |
| `roulette` | `id, spell, options, reveal` |
| `adapt` | `id, mode, pattern` |
| `fizzle` | `id, x, z` |
| `surge` | (no fields) |
| `clear` | (no fields) |

**Telegraph shapes:**

| Shape | Fields |
|---|---|
| circle | `x, z, r` |
| line | origin `x, z`, unit direction `dx, dz`, `len`, half-width `r` |
| cone | `x, z, dx, dz`, `r` = range, `angle` = full angle in degrees |

`delay` is always ≥ 0.6 s. A test checks that every strike lands exactly where
and when its telegraph said.

## Fix-round additions

- `world:setPlayerPosition(id, x, z)` pushes the player out of obstacles and
  returns the position it stored `(x, z)`. A push deeper than 2 studs also moves
  the character back.
- `world:bossSpawnPoint(radius?) -> (x, z)` is 40 studs from the party, on the
  side toward the arena centre. RunDirector spawns bosses there.
- Boss enrage after `World.BOSS_ENRAGE_AFTER` (120 s):
  - The boss and its minions move ×1.35 faster, and the gaps between patterns
    shrink ×0.5.
  - Emits the world event `bossEnrage` and the Fx
    `{t="enrage", id, x, z, speedMult=1.35, gapMult=0.5}`.
  - `bossInfo().enraged` is set.
- New world events:
  - `moveViolation`: CombatService's MoveGuard snapped a player back. After
    `MoveGuard.UNRANKED_VIOLATIONS` (10), RunDirector passes `ranked=false`.
  - `fatal`: 30 failed steps in a row. RunDirector ends the run as a safe wipe.
- `Combat/MoveGuard.luau` (pure): server-side speed check with a carried-over
  allowance, slack and grace windows.
- `Combat/FxFilter.luau` (pure): per-client Fx culling. Point events are dropped
  beyond 100 studs, damage numbers beyond 60, and projectiles only when the
  whole path stays out of range.
- Snapshots go out at **10 Hz** with only the enemies within 110 studs of that
  client (bosses always). The 220-enemy stress case uses about 26 KB/s per
  client (estimate).
- `CombatService.placePlayer`, `CombatService.violations`.

## Points of interest and portal (Team G2, GDD §3.8 / §3.9)

Data: `Config/Pois.luau` (defs, tunables, `RARES`, `cacheCheese`, `fountainXp`,
`campPack`). Logic: `Combat/Pois.luau` (pure). Map slot tables: `Config/Maps.luau`.

### Stage setup (shared by RunDirector, ArenaBuilder and the headless sim)

```lua
Pois.rollStage(rng, mapId) -> {kind}            -- Maps.rollPois + ONE rare roll per stage (Pantry 3%, Statue 2%)
Pois.layout(rng, mapId, radius?) -> {{kind, x, z, r, slot, traps?}}   -- ring at 0.55..0.8 R
-- RunDirector: layout = Pois.layout(Rng.new(stageSeed):fork(RunDirector.POI_SALT = 0x9017), mapId)
ArenaBuilder.build(mapId, seed, { pois = layout })  -- parts at exactly these spots; obstacles keep r + 6 clear
world:addPoi(entry) -> poiId                     -- for each layout entry
```

### World API

| Function | Purpose |
|---|---|
| `world:addPoi({kind, x, z, r?, traps?}) -> id` | Adds a POI entity. Asleep until the waves run. Emits Fx `poi`. |
| `world:pois()` | Copies `{id, kind, x, z, r, state, progress, usedBy, active, mode, pack, traps?}`. `state` is `idle`, `active` or `done`; `active` = waves running. |
| `world:setPortal(x, z, phase, color?)` | `phase` = `open`, `pull` or `close`; `color` = `{r, g, b}`. Emits Fx `portal`. |
| `world:portal()` | `{x, z, phase, color}` or nil (bots walk in on `pull`). |

Behaviour (each `world:step`, only while `wave.active`):

- **channel** (cache, shrines, fountain, Pantry, Statue, landmarks): standing heroes within `r + 0.8` fill `progress` at `dt / channel × rate`, where rate = 1 + 0.5 × (n − 1), capped at ×2. A hero hurt in the last `HURT_PAUSE` (0.6 s) does not count; with nobody in range progress drains 0.25/s. At 1 the world-side reward runs once: Mending heals 30%, the fountain drops crumbs, the Statue revives downed and dead heroes (`revived` kind `statue`) and clears `secondWindUsed`.
- **camp**: the first hero in range spawns `campPack` elites (they ignore the wave cap, `enemy.poiId`). The last one's death (any killer) opens the chest. Camps do not wake in the last `CAMP_WAKE_CUTOFF` (20) s of the waves; a pack still alive when the waves end (the boss start clears it) flees and the chest opens anyway (`poiReward.fled`).
- **hazard** (Mousetrap Field): a trap arms when a hero or a non-boss mouse is within 2.2 studs. After a 0.8 s telegraph it snaps everything within 3 studs: mice take `60 × enemyHpMult` (no killer: no kill event), heroes take `14 × enemyDamageMult` (damage kind `trap`). It rearms after 3 s. A trap armed as the waves stop never snaps.
- `World.damagePlayer` stamps `p.lastHurtAt`.

### World events

| Event | Fields |
|---|---|
| `poiProgress` | `poi, kind, amount` (each 10% step) |
| `poiActivated` | `poi, kind, by, x, z` (channel done, or camp woken) |
| `poiReward` | `poi, kind, by, x, z, ids` (every participant), plus `cheese` (cache / landmark), `buff = {kind, stat, mul?, addFracMaxHp?, duration, untilT}` (shrines), `xp` (fountain), `revived` (statue), `cards` (Pantry), `fled = true` (a camp whose pack was still alive when the waves ended: the chest is granted anyway) |

POI events use `poi` / `by`, never `id`, so RunDirector's bot routing does not swallow them.

### Fx (all JSON-safe)

| Fx | Fields | FxFilter |
|---|---|---|
| `poi` | `id, kind, x, z, r, state, active, p` (on add, state change, waves on/off, and every 15 s while the waves run) | always sent |
| `poiProgress` | `id, p` (10% steps) | always sent |
| `poiDone` | `id, kind, x, z, by`, plus `cheese?`, `dur?` and `untilT?` (shrines), `chest?` (camp) | always sent |
| `trap` | `id, n, x, z, r` (a snap) | point-culled (100 studs) |
| `tele` | `style = "trap"`, `poi`: the trap's 0.8 s telegraph | always sent |
| `portal` | `x, z, phase = "open" \| "pull" \| "close", color = {r, g, b}` | always sent |
| `discovered` | `kind, isNew = true`: sent by RunDirector to one player on their first find of a rare POI or landmark (HUD banner) | personal, not from World |

### RunDirector meta rewards

- Cache cheese is held per stage (`c.stagePoiCheese`) and goes into pending right after `bossDefeated`, through `run:addPending(n)` if it exists, else `run.pendingCheese`. It is scaled by `RunState.applyPressureCheese` when that exists.
- Shrine buffs go into `c.buffs` and are applied by `Pois.applyBuffs` after `Stats.compute`, then pushed with `world:updatePlayer`. The HUD loop reverts them when they expire (`Pois.pruneBuffs`).
- The Elite chest queues a `"chest"` bonus pick (+1 luck) for every human. The Pantry queues a `"pantry"` pick (`Pois.epicCards`). Bots pick at once. UpgradeOffer payloads carry `source`.
- The Statue resets each human's RunTokens free Second Wind and this stage's cap.
- Rare POIs and landmarks set `profile.discoveries[kind] = true` for humans. The first find shows a toast and sends that player a personal `discovered` Fx (the HUD banner). The Pantry also grants an unowned `Cosmetics.epicPool()` item; the Statue names the title "Herd Keeper".
- Portal: `ArenaBuilder.buildPortal(x, z, color)`, `setPortalColor`, `clearPortal`.

### Pressure WorldMods (Team G1 fields, read by World / WaveDirector)

| Field | Default | Effect |
|---|---|---|
| `eliteSpeedMult` | 1 | Elite move speed (on top of `enemySpeedMult`) |
| `eliteSizeMult` | 1 | Elite radius at spawn, fuse blast radius and projectile radius |
| `lateSpawnMult` | 1 | `WaveDirector.rate` while `elapsed >= duration − Config/Pressure.LATE_SPAWN_WINDOW` (60 s) |
| `rangedExtraProjectiles` | 0 | Each ranged volley fires 1 + n shots in a 12° fan (`World.RANGED_FAN`) |
| `enemyXpMult` | 1 | XP of the crumb a mouse drops (`_killEnemy`); boss crumbs are not scaled |

Snapshot flags bits 4–5 carry a size step (`SnapshotCodec.sizeBits` / `sizeScale`): elites (×1.3) and Big Cheese elites are drawn as big as their hitbox.

## Known follow-ups

- ~~Bandwidth~~: done (10 Hz snapshots, per-client LOD, Fx culling). Confirm the real wire size in Studio's network stats.
- ~~Speed-hack check~~: done (MoveGuard). Tune the thresholds on a live server.
- ~~Solo wipes~~: done (5 s grace when a Second Wind is usable).
- **WalkSpeed conflict:** CombatService's WalkSpeed overrides RunDirector's `setHumanoidSpeed`.
