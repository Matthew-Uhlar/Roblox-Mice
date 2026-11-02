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

## Known follow-ups

- ~~Bandwidth~~: done (10 Hz snapshots, per-client LOD, Fx culling). Confirm the real wire size in Studio's network stats.
- ~~Speed-hack check~~: done (MoveGuard). Tune the thresholds on a live server.
- ~~Solo wipes~~: done (5 s grace when a Second Wind is usable).
- **WalkSpeed conflict:** CombatService's WalkSpeed overrides RunDirector's `setHumanoidSpeed`.
