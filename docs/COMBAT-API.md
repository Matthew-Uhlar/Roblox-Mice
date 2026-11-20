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
- `Combat/FxFilter.luau` (pure): per-client Fx culling.
  - Point events are dropped beyond 100 studs, and damage numbers beyond 60.
  - Other heroes' melee, chain, boom, hurt and dodge Fx are dropped beyond
    `NEAR_RADIUS` (60). The attacker and the victim always get their own.
  - Projectiles are dropped only when the whole path stays out of range.
  - 12 heroes at the 220 cap (`PerfWorld`): ~315 Fx/s and ~28.7 KB/s for the
    whole batch, but ~136 Fx/s and ~13.4 KB/s average (14.3 KB/s max) per client
    after the filter (JSON proxy). Before `NEAR_RADIUS` it was ~19 KB/s per client.
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

## v2: squads, PvP, gear, contested POIs (Team R2, GDD-v2 §2-4)

Code is the source of truth: `Combat/World.luau`, `Combat/Weapons.luau`,
`Combat/Pois.luau`, `Run/Gear.luau`, `Config/Gear.luau`, `Bots/BotBrain.luau`.

### World options and tunables

- `World.new{ ..., safeZones = {[squad] = {x, z, r}}?, tier = "Low"|"Mid"|"High"?, carriers = boolean? }`.
  `tier` drives gear rarity rolls. Golden carriers are on by default, but never when `enemyCap` is 0.
- Tunables:

  | Constant | Value | Meaning |
  |---|---|---|
  | `PVP_MULT` | 0.3 | Damage against heroes |
  | `HERO_AGGRO` | 10 | Auto-weapons take an enemy hero within this range even if mice are closer |
  | `DOWNED_HITS` | 6 | Hits that kill a downed hero |
  | `SPAWN_PROTECT` | 5 s | Spawn protection after a revive |
  | `DROP_PROTECT` | 9 s | Spawn protection at each stage's drop-in |
  | `SAFE_ZONE_REDUCTION` | 0.6 | Damage reduction inside your squad's safe zone |
  | `ELIM_GRACE` | 5 s | Only while a downed member can still Second Wind |
  | `ASSIST_WINDOW` | 5 s | How long a hero's hit keeps them credited |
  | `GEAR_PICKUP` | 3 | Ground-item pickup range |
  | `SWAP_TIME` | 4 s | Swap offer lifetime |
  | `BAG_RANGE` | 4 | Loot-bag channel range |
  | `BAG_CHANNEL` | 1.5 s | Loot-bag channel time |
  | `CARRIER_*` | | First carrier at 25 s, then every 40-60 s, at most 2 alive |

### Squads and PvP

- `addPlayer(id, stats, weapon, ability, x, z, squad?)`: `squad` defaults to 1.
- Squad functions: `setSquad(id, squad)`, `squadOf(id)`, `squadMembers(squad)`, `aliveSquads()` (sorted), `isEliminated(squad)`.
- `world.pvp` is true once two or more squads are registered. With a single squad (v1) nothing changes.
- Damage between squads:
  - Every sweep, projectile, explosion, chain, player zone, orbit blade, dash line and ring also hits **enemy-squad** heroes (`forFoesInCircle`, `forFoesInLine`).
  - `Weapons.hit` routes hero records (`isHero`) to `Weapons.hitHero`, then `world:damageHeroFrom(h, base, by, source?)`, which works in this order:
    1. No friendly fire.
    2. A spawn-protected target takes 0.
    3. Damage is multiplied by `PVP_MULT`, the Power Totem multiplier and `heroDamageMult`.
    4. It is reduced by `heroResist` and, inside the target's own safe zone, by 60%.
    5. Heroes never take crits.
    6. Hitting a rival ends the attacker's own spawn protection (event `protectEnd`).
- Targeting: `targetsFor(p, range, n)` returns the nearest mice, with the nearest enemy hero first when it is the closest target or within `HERO_AGGRO`. Spawn-protected heroes are skipped.
- Downed heroes:
  - Enemy hits count `downedHits`, gated by i-frames. `DOWNED_HITS` plus `downedHitsBonus` kills them.
  - Only squad-mates revive. Revive speed is the best `reviveSpeedMult` among the helpers and the downed hero.
- Spawn protection:
  - Applies at the first step after `addPlayer` and after every revive (teammate, Second Wind, statue, respawn).
  - `world:protect(id, seconds?)` sets it directly.
  - It protects against heroes only. Mice still hurt.
- Elimination (pvp only):
  - A squad with nobody standing is out after `ELIM_GRACE` (while a downed member could still Second Wind), otherwise at once.
  - Its downed members die and drop their loot bags.
  - `respawnDead` or a statue clears the flag.
- Boss:
  - `bossDamageBySquad() -> (damage table, topSquad)`.
  - `bossInfo()` adds `damageBySquad` and `topSquad`, which decide a timed-out boss.
- `getPlayer` adds `squad, protected, protectUntil, downedHits, downedHitsMax, lastHitBy, lastHitAt, extractBonus, gear, swapOffer, burning`.
- `getPlayers` adds `squad, protected, lastHitBy, lastHitAt, downedHits`.
- Hero snapshots: none are needed. Heroes are characters or BotService models that Roblox replicates.
  - CombatService sets character attributes `Squad, Downed, Spectator, Protected, DownedHits`.
  - BotService sets `Squad, Downed, Dead, Protected, Hp, MaxHp` on bot models.

### Gear (run-only)

- **`Config/Gear`:** 31 items: 11 weapon mods, 10 armors and 10 trinkets.
  - Each effect has one value per rarity (Common, Rare, Epic, Legendary).
  - Prices are in pending cheese: `price(rarity, stage)`.
- **`Run/Gear`** (pure):
  - Main functions: `apply(stats, weapon, ability, items)`, `roll(rng, tier, stage, {minRarity?, slot?, luck?})`, `rarityWeights`, `bossChest(rng, tier, stage)` (2 items, Rare or better), `cartOffers` (one per slot, with prices).
  - Helpers: `make`, `valid`, `rank`, `better`, `clean`, `describe`.
  - `apply` marks its stats `gearApplied = true`.
  - Call it on two lines, because Lua truncates multiple returns that are not last in an argument list:
    `local s, w, a = Stats.compute(...)`, then `s, w, a = Gear.apply(s, w, a, world:gearOf(id))`.
- **World applies gear itself**, on top of the stats given to `addPlayer`/`updatePlayer`, unless those stats carry `gearApplied` (then they are used as given, so gear is never applied twice).
- World API:

  | Function | Behaviour |
  |---|---|
  | `gearOf(id)` | `{weapon?, armor?, trinket?}` |
  | `setGear(id, items)` | Restores gear when carrying it to the next stage's World. No events. |
  | `giveGear(id, item) -> ok, offered` | Empty slot: equip (`gearPickup`). Full slot: swap offer (`gearSwapOffer {id, item, slot, current, endsAt}`). Offer already open or hero dead: the item drops at the hero's feet. Items are never lost. |
  | `swapOffer(id)` | The open swap offer |
  | `resolveSwap(id, takeNew)` | `true` equips the offered item and drops the old one on the ground; `false` keeps the current item. An expired offer counts as `false` (`gearSwapDeclined`). |
  | `dropGear(item, x, z, ignoreId?) -> groundId` | Ground items auto-pick-up within `GEAR_PICKUP`. A declined item is ignored by that hero until they step away. |
  | `groundItems()` | Ground items |
  | `addLootBag(x, z, gear, cheese) -> bagId` | Merges into a bag dropped at the same spot within 1 s |
  | `addBagCheese(bag, n)`, `lootBags()` | Bag cheese and the bag list |
  | `extractBonusOf(id)` | Portal Charm extract bonus |

- Loot bags:
  - A hero who dies (`heroKilled`) or leaves drops all their gear in a bag. `heroKilled.bag` is the bag id.
  - The squad cheese share is added by RunDirector.
  - A bag is channelled for 1.5 s, interrupted by damage and held while two squads stand on it.
  - On pickup: event `lootBag {bag, by, squad, gear, cheese, x, z}`. **World hands the gear over itself** with `giveGear` (so `gearPickup` / `gearSwapOffer` events follow). RunDirector pays only the cheese.
- Effects World reads:
  - From the item tables: `projectileBonus`, weapon damage/knockback, area, attack speed, pierce, chain, crit, lifesteal, explodeOnKill, maxHp, armor, regen, moveSpeed, xpMult, luck, pickupRadius, cooldownMult, ability area/damage, cheeseMult, damageMult.
  - New stats: `burnDps` (3 s, ticks every 0.5 s, ×damageMult; on heroes ×PVP_MULT), `slowOnHit` (1.2 s), `projectileResist`, `heroDamageMult`, `heroResist`, `reviveSpeedMult`, `channelSpeedMult` (POIs and bags), `downedHitsBonus`, `downedTimeBonus`, `thorns` (reflects contact damage), `dodge`, `extractBonus`.
- Golden carriers:
  - Enemy `carrier` (`Enemies.ORDER[6]`, World-spawned only; `Enemies.WAVE_IDS` lists the wave mice).
  - It flees heroes and keeps the enemy cap: at the cap it retires the plain mouse furthest from every hero.
  - Killed, it drops one gear item. After 30 s it escapes with Fx `carrierEscape`.

### Contested and new POIs

- Every channel is contested:
  - One squad progresses at a time. With two squads inside, progress holds (`contested`).
  - A new squad first drains the old squad's progress at `STEAL_RATE` (0.5×).
  - A hero hurt in the last 0.6 s does not channel.
- Rewards go to the channelling squad:
  - `poiReward.ids` holds that squad's members, and `.squad` / `.poiKind` are added.
  - Mending heals only that squad, and the Statue revives only that squad.
  - An Elite Camp's chest goes to the squad of whoever killed the last elite, and it also spills one gear item.
- New POIs (placed by `Pois.rollStage` through `Config/Pois.SPECIALS`, at most one of each per stage; the Armory is also in every map's table):

  | POI id | Mode | Reward / events |
  |---|---|---|
  | `armory` | channel 4 s | `poiReward {kind = "armory", items = {item}}`. The item goes to the channeller, Rare or better from stage 3. |
  | `cheese_vault` | channel 8 s | On start: event `poiAlert {poi, kind, squad, x, z}` and Fx `vault {phase = "start"}`. Also Fx `vault` "contested" and "done". `poiReward {kind = "vault", poiKind = "cheese_vault", items (2, Rare or better, to the channellers), cheese = vaultCheese(cycle, stage)}` |
  | `power_totem` | totem, 6 s capture | One squad alone fills it (neutral) or drains it (owned by someone else). Two squads hold it. `poiReward {kind = "totem_owner", squad, prev}`, event `totemLost {poi, squad, by}`, Fx `totem {owner, prev, by, p}`. The owner squad deals ×1.15 damage (`world:squadDamageMult(squad)`) until the totem is neutralised; ownership lasts through the boss. |
  | `shop_cart` | cart | A hero standing in it for 1 s gets a personal `poiReward {kind = "shop_cart_open", poi, by, squad, offers, prices, sold}`. It re-opens only after they step out. `world:cartOffers(poi)` and `world:takeCartOffer(poi, index) -> item?, price?` (each item sells once; done when sold out). RunDirector charges pending cheese, then calls `giveGear`. |

- Layout: `Pois.layout(rng, mapId, radius?, safeZones?)` keeps every POI clear of the squad safe zones by its radius plus 4 studs. The default zones are `Pois.defaultSafeZones(R)`: the diagonals at R − 20 with r = 13, matching ArenaBuilder. A slot that would overlap slides along the ring, then inward. No extra rng is drawn, so the same arguments give the same layout everywhere.
- `world:pois()` entries add `squad, contested, owner, capSquad, left`. The `poi` Fx adds `squad, contested, owner`.

### New events (`drainEvents`)

| Event | Fields |
|---|---|
| `heroDowned` | `id, by?, squad`. The v1 `downed` event still fires. |
| `heroKilled` | `id, by?, squad, bySquad?, x, z, bag?`. The v1 `dead` event still fires. |
| `squadEliminated` | `squad, by?` |
| `damaged` | Adds `by` for PvP. `kind = "downedHit"` for hits on downed heroes. |
| `bossDead` | Adds `killer?, killerSquad, damageBySquad` |
| `gearPickup` | `id, item, slot, replaced?` |
| `gearSwapOffer` | `id, item, slot, current, endsAt` |
| `gearSwapDeclined` | `id, item, slot` |
| `lootBag` | `bag, by, squad, gear, cheese, x, z` |
| `poiAlert` | `poi, kind, squad, x, z` |
| `totemLost` | `poi, kind, squad, by, x, z` |
| `protectEnd` | `id` |
| `poiActivated` / `poiProgress` | Add `squad` |

### New Fx (all JSON-safe)

| Fx | Fields | FxFilter |
|---|---|---|
| `protect` | `id, untilT` (0 = ended) | always sent |
| `heroKill` | `id, by, x, z, squad, bySquad` | always sent |
| `squadOut` | `squad, by` | always sent |
| `down` | adds `by` | always sent |
| `hurt` | adds `by`. Downed hits add `hits, need`. | point-culled, but always sent to the attacker |
| `dodge` | `id, x, z` | point-culled |
| `gear` | `id, x, z, item` | always sent |
| `gearGone` | `id, by?` | always sent |
| `gearEquip` | `id, item, slot` | always sent |
| `bag` | `id, x, z, n, cheese` | always sent |
| `bagGone` | `id, by` | always sent |
| `bagProgress` | `id, p` (quarters), `by` | always sent |
| `carrier` | `id, x, z, untilT` | always sent |
| `carrierEscape` | `id, x, z` | always sent |
| `vault` | `id, x, z, phase, squad, by?` | always sent |
| `totem` | `id, x, z, r, owner, prev, by, p` | always sent |
| `cart` | `id, x, z, by?, left` | always sent |

`FxFilter.ALWAYS` lists the always-sent set.

### BotBrain v2

- View additions:
  - `self.squad`, `self.gear`, `self.lastHitBy/At`.
  - Allies gain `squad, protected, lastHitBy, lastHitAt`.
  - Optional `foes` (otherwise derived from allies by squad), `gear` (`groundItems`) and `bags` (`lootBags`).
- Behaviour:
  - **Squad:** a bot leashes to its squad's human, otherwise to the squad leader (the highest bot id). The leader roams.
  - **Fighting:** it fights enemy heroes within the engage range, or one that hit its squad in the last 4 s within the chase range. It finishes downed foes and aims its ability at foes. Protected heroes are ignored.
    - **Pacing** (`BotBrain.pvpRanges(view)`): the view's `stage` and `waveTime` come from `world:stageClock()`.
    - Stage 1, before `CALM_SECONDS` (75): no hunting, self-defence only. The bot also steers away from foes within `CALM_AVOID` (30).
    - Before `EARLY_SECONDS` (75) of any stage: engage at most 9, chase at most 24.
    - After that: `HERO_ENGAGE_BY_STAGE` {0, 10, 24} and `DEFEND_RANGE_BY_STAGE` {12, 25, 55} (v4; v3: {10, 20, 24} / {24, 45, 55}).
    - A view without `stage`/`waveTime` uses `HERO_ENGAGE` (18) and `SQUAD_ATTACK_RANGE` (45).
  - **Fleeing:** below 50% HP (`LOW_HP`) with a foe within 28 studs, it flees.
  - **POIs:** it contests POIs and captures or defends the totem.
  - **Loot:** it fetches better ground gear and loot bags.
- Helpers:
  - `chooseSwap(current, offered)` and `chooseCartItem(offers, prices, sold, pot, gear)`.
  - `chooseVote("extract", options, squadHumanTally, rng, {pot, hpFrac})`.
  - `chooseExtract(matchView, squad, rng) -> "Extract" | "Stay" | "DoubleOrNothing"`. The squad's human votes come from `squads[squad].humanVotes`. An optional 4th argument overrides `EXTRACT_POT`; the headless sim's human stand-in uses it. Bot-only squads extract at pot ≥ 220 per member, average HP < 30% from stage 3, or on stage 4. They never choose Double or Nothing alone.
- BotService:
  - Squad colour shows as a band, a cap and the name colour.
  - It uses `Visuals/BotModel.build(spec, squad)` when that module exists, and always keeps the 🤖 tag.
  - Bots think in 3 staggered groups.
  - It resolves swap offers with `chooseSwap` and follows Terrain height.

### Performance (Lune)

- 12 heroes in 4 squads with 220 mice: about 0.5-0.8 ms per step on average.
- The v1 PerfWorld case: 0.47 ms average, 4.9 ms worst.
- `BotBrain:think` with 12 heroes, 220 mice and loot: about 0.1 ms.

## v3: big maps, Mouse Champions, sprint (GDD-v2 §4a–4b)

Code is the source of truth: `Config/Champions.luau` (data), `Combat/Champions.luau`
(director, AI, rewards), `Combat/BossPatterns.luau` (their attacks), `Combat/World.luau`.

### Snapshot kinds

| Kind | Meaning |
|---|---|
| 1..99 | mice: `Enemies.ORDER` index |
| 100 + i | Mouse Champion: `Config/Champions.ORDER[i]` (101 `champ_captain` … 106 `champ_thunder`). Flag bit 3 = a Mad Chemist clone (draw it small); size bits 4–5 = a lair champion (×1.25) |
| 200 + i | boss: `Bosses.ORDER[i]` |

`SnapshotCodec.CHAMPION_KIND` (100), `BOSS_KIND` (200) and `kindClass(kind) -> "mouse" | "champion" | "boss"`.
The wire format is unchanged. `FxFilter.snapshotForViewer` always keeps kinds ≥ 100
(champions and bosses), whatever the 110-stud radius.

### World API

| Function | Purpose |
|---|---|
| `World.new{ ..., champions = false? }` | Champions are on by default, but only spawn at the world's champion sites (POIs of mode `champion`). No sites, no champions. |
| `world:champions()` | `{{id, champId, x, z, hpFrac, lair, enraged, site, damageBySquad, topSquad}}` (main bodies) |
| `world:spawnChampion(champId, x, z, lair?)` | Test / debug spawn |
| `world:rallyMice(caster, x, z, r, dur)` | Captain Whiskers' rally |
| `getPlayer(id).walkSpeed`, `.sprinting` | v3 sprint: `walkSpeed = moveSpeed × Maps.SPRINT.mult` while sprinting. CombatService (WalkSpeed, MoveGuard), BotService and the sim use `walkSpeed`; `moveSpeed` stays the stat. Characters and bot models get the attribute `Sprinting`. |

Tunables: `World.STRAY_RADIUS` 160 (plain mice farther than this from every
standing hero are recycled, checked every `STRAY_CHECK` 1 s; arenas ≤ 160 never),
`World.SPRINT` = `Config/Maps.SPRINT` `{mult = 1.3, clear = 18, calm = 2.5}`.

### Director and AI (Config/Champions)

- First champion `FIRST` 25–35 s into the waves, then every `INTERVAL` 30–40 s, at
  most `MAX_ALIVE` 3 regular champions (`MAX_ALIVE_SMALL` 2 below a 250-stud
  radius), none in the last `CUTOFF` 25 s. Lair i wakes one champion at `LAIR_AT[i]`
  (55 / 95 s ± 8). The times are for 150 s waves; shorter waves scale them down
  (`Champions.timeScale`).
- `HP = def.hp × bossHpMult × HP_SCALE (1.15) × (1 + HP_WAVE_GROWTH (2.5) × elapsed / duration)`;
  pattern damage and contact × `bossDamageMult`; lairs ×1.8 HP, ×1.2 damage, ×1.25 radius.
- A champion has `aggro` 38, `leash` 36 and its own rng (`World.champRng`, root fork 7,
  so boss fights replay unchanged). BossPatterns only target heroes inside `aggro`
  (`standingFor`/`nearestFor`), random spots stay near its site. Champions ignore
  the enemy cap, take ×0.15 knockback, shove mice, and are not separated by them.
- Enrage once at 50% HP (Fx `champ` phase `enrage`, event `championEnrage`):
  phase-2 patterns, ×1.2 speed, ×0.7 gaps; the Mad Chemist spawns 2 clones
  (`champOf`, 20% max HP each, they die with it, no reward).
- New BossPatterns bases: `rally`, `chain` (chain lightning: telegraph circles on
  up to 3 heroes, then strike + `slam` Fx there and `chain` arcs), `evade` (Sniper
  Squeak's blink, run by the AI when a hero gets within `evadeRange`). `charge`
  takes `shield = true` (damage ×`SHIELD_MULT` 0.35 while it runs).
  `dmgOf(w, P, caster)` uses `caster.dmgMult` when set.

### Events (`drainEvents`; the champion entity id is in `champ`, never `id`)

| Event | Fields |
|---|---|
| `championSpawn` | `champ, champId, lair, x, z, site` |
| `championEnrage` | `champ, champId, lair, x, z` |
| `championDead` | `champ, champId, lair, x, z, by?, squad?, killerSquad?, damageBySquad, ids, xp, cheese, buff = {kind, name, stat, mul, duration, untilT}?, items, stage, fightTime?, maxHp` |

`squad` = the rewarded squad: v4 the top-damage squad, else the killer's squad (v3: the killer's squad first).
The World hands each rewarded member (not dead) a gear item (`giveGear`:
`gearPickup` / `gearSwapOffer` follow) and an `xp` event (xpMult applied).
RunDirector pays `cheese` per member (Pressure applied) and adds the buff with
`Champions.addSquadBuff` (stacks: kinds `champ_might#1`, `#2`; a third kill
refreshes the stack that expires first).

### Fx (always sent)

| Fx | Fields |
|---|---|
| `champ` | `id, champId, x, z, phase = "spawn" \| "enrage" \| "dead", lair`, plus `name, site` (spawn), `squad, by` (dead: the rewarded squad), `escaped = true` (dead: left when the boss came) |
| `rally` | `id, x, z, r, dur, n` |
| `tele` | new styles `champIntro` (1.5 s landing), `rally`, `chain` |
| `chain` | hostile arcs carry `src` (the champion) and `hostile = true`, no `id` |

### POIs and layout

- `Config/Pois`: `champion_site` (r 12) and `champion_lair` (r 14, `lair = true`), mode
  `champion` (no channel; state `active` while a champion lives there).
- `Pois.layout` returns the `poiSlots` regular slots on `Pois.RINGS`, then
  `championSites` sites (`champion = true`) on `CHAMPION_RING` and `championLairs`
  lairs (`lair = true`) on `LAIR_RING`; regular slots and sites keep clear of the
  safe corners and of each other. Slots are numbered 1..n in that order.
- `Pois.squadCorners(R)` = the safe zones / drop-in corners (squads 1..4 at 225,
  315, 45, 135 degrees), `R − max(20, 0.1 R)` out, r = `max(13, 0.05 R)`.
  `defaultSafeZones` returns the same circles.
- `SPECIALS` gain `rolls` (totem 3 × 0.8, vault 3 × 0.4, cart 2 × 0.25). Vault: 3 items,
  `gearLateRarity` Epic from stage 3, `VAULT_MULT` 5. Elite Camp: 2 Rare+ items.
  `TOTEM_DAMAGE_MULT` 1.2.

### Performance (Lune, PerfWorld on a 350-stud map with the plains layout)

12 heroes at the 220 cap with up to 4 champions alive: see docs/HANDOFF.md.

## v4: The Melt, per-hero spawning, the PvP channel (team M1, docs/V4-PLAN.md)

Code is the source of truth: `Config/Storm.luau`, `Config/Maps.luau`,
`Combat/World.luau`, `Combat/WaveDirector.luau`, `Combat/Weapons.luau`,
`Config/{Champions,Bosses,Classes}.luau`, `Bots/BotBrain.luau`. Specs:
`CombatV4`, `CombatTtk`, `CombatWaves`, `CombatPvP`, `PerfWorld`, `FuzzCombat`.

### Arena radius per stage

`Maps.stageRadius(mapId, stage) -> number`: `STAGE_RADIUS` {480, 420, 360, 310}
x `size / 350`, clamped to 300-560 (stages past 4 use 310). ArenaBuilder builds to
it and RunDirector passes it to `World.new{arenaRadius}` and to Config/Storm.

### Config/Storm (pure)

| Function | Purpose |
|---|---|
| `Storm.schedule(R, stage, seed?, duration?) -> {{at, zone}}` | Every wave step (wave time) |
| `Storm.zoneAt(R, stage, waveT, seed?, duration?) -> zone` | The zone in force `waveT` s into the waves |
| `Storm.bossZone(R, stage, bossT, seed?) -> zone` | Holds 0.22 R (8 %); after 90 s closes to 0.12 R over 30 s (12 %) |
| `Storm.toWorld(zone, t0) -> zone` | Shifts close times from wave / boss time to the world clock |
| `Storm.center(R, stage, seed?) -> (cx, cz)` | Arena centre + up to `CENTER_OFFSET` (0.1) x R, one per stage, shared by every circle |
| `Storm.radiusAt(zone, t)` | Lerped radius |
| `Storm.safeCornersOn(waveT, duration?)` | False from `SAFE_CORNERS_OFF` (30 s) |

Steps (150 s waves; other durations scale the times): 0 s edge -> 0.65 R closing
30-60 (2 %); 60 s 0.65 -> 0.40 R closing 85-110 (2 %, 4 % from 85 s); 110 s
0.40 -> 0.22 R closing 125-150 (4 %, 8 % from 125 s). `zone.step` is the step index
(boss: 100 hold, 101 squeeze). dps = fraction of max HP per second.

### World storm API

| Function | Behaviour |
|---|---|
| `world:setZone({cx, cz, r, toR, closeStart, closeEnd, dps})` | World-clock close times; the radius lerps r -> toR. `nil` clears it (Fx `storm {off = true}`). |
| `world:zone()` | Copy of the zone plus `radius` (now), or nil |
| `world:insideZone(x, z, margin?)` | True without a storm |
| `world:setStormPlan({radius?, stage?, seed?, duration?, safeCorners?})` | Optional autopilot: the World calls setZone itself from Config/Storm (wave clock; a live boss uses its spawn time) and switches the safe corners off at 30 s. RunDirector currently drives setZone itself, which is equally fine. |

- Fx `{t = "storm", cx, cz, r, toR, closeStart, closeEnd, dps, now}` on every
  setZone and again every `STORM_RESEND` (10 s). It is in `FxFilter.ALWAYS`.
- Every `STORM_TICK` (0.5 s) standing heroes outside take `dps x maxHp x 0.5`.
  Armor, dodge, i-frames and shields are ignored; `lastHurtAt` / `iframeUntil` are
  never set, so POI channels, loot bags, sprint and PvP hits carry on. Fx `hurt`
  with `storm = true`, event `stormDamage {id, amount}`. A storm down credits the
  usual assist window. Downed heroes outside bleed out `STORM_DOWNED_DRAIN` (x2) as fast.
- `getPlayer` / `getPlayers` add `outsideZone`; CombatService sets the character
  attribute `OutsideZone`.
- No mouse spawns outside the current circle (4 studs margin); plain mice more
  than `STRAY_ZONE_MARGIN` (12) outside it are recycled.
- Champions spawn only at sites inside the next circle (`min(r, toR)` minus the
  site radius); lairs too.
- `world.safeOff` (set by the autopilot) makes `inSafeZone` false. A caller driving
  setZone itself can do the same with `world:setSafeZones({})`.

### Per-hero mouse spawning (WaveDirector, no API change)

`rate = PER_HERO_RATE (0.6; plan 0.9) x standing heroes (bots count 1) x ramp(1 -> 3.2) x
cycle / stage scale x mods.spawnRateMult`. Live mice stay under
`min(World.DEFAULT_CAP (300), PER_HERO_CAP (28) x standing heroes)`. Spawn anchors
favour heroes with fewer mice within 48 studs (`nearMice`, counted every 0.5 s),
and each stage starts with 2 mice per hero banked. `WaveDirector.new{perHero =
false}` keeps the v1-v3 budget. Mouse HP x `(1 + 0.03 x (average hero level - 1))`.

### Hero levels, rookies

- Mouse spawning was retuned for match health: `PER_HERO_RATE` 0.6 (plan 0.9),
  `MOUSE_HP_PER_LEVEL` 0.03 (was 0.06).
- `world:setHeroLevel(id, level)` (or `stats.level`, an optional PlayerStats field).
  `world:avgHeroLevel()`, `world:levelForScaling()` (nil when no hero has a level:
  champions and bosses then scale x1). `getPlayer().level`.
- `world:setRookie(id, on)`: in stage 1 (`world.stage <= 1`) enemy-squad BOTS'
  weapons and abilities skip that hero (`targetsFor`, `forFoesInCircle/Line`);
  `getPlayers()[id].rookie` lets BotBrain skip it too.

### Redeploy

`world:redeploy(id, x, z, hpFrac?, protect?) -> boolean`: a downed or dead hero
comes back at (x, z) (clamped, pushed out of rocks; a teleport is queued for
CombatService) with `hpFrac` (default 0.6) of max HP, revive kind `"redeploy"`,
and `protect` s of spawn protection (default `SPAWN_PROTECT`). Clears the squad's
elimination. Returns false for an unknown or standing hero.

### PvP channel

| Tunable | Value | Meaning |
|---|---|---|
| `PVP_MULT` | 0.35 | x hero damage to heroes |
| `PVP_ARMOR_MULT` | 0.35 | share of the target's armor that counts against hero hits |
| `PVP_DAMAGE` | 0.8 | extra x after PVP_MULT (match-health tuning, see below) |
| `PVP_LOCKOUT` | 0.5 s | per-attacker lockout; replaces the shared i-frames for hero hits |
| `PVP_MICE_IFRAMES` | 0.5 s | a hero hit gives its victim mice-only i-frames |
| `PVP_FOCUS_WINDOW` / `PVP_FOCUS_FALLOFF` | 1 s / 0.5 | each of n attackers that hit within 1 s deals x 1 / (1 + 0.5 (n - 1)) |
| `DOWNED_HITS` / `DOWNED_HIT_GAP` | 9 / 0.8 s | finishing hits on a downed hero; at most one per 0.8 s from anyone |
| `HERO_AGGRO` | 4 | auto-weapons take a closer enemy hero over mice (was 10) |
| `PVP_REGEN_PAUSE` | 3 s | regen stops after PvP damage (`getPlayer().regenPausedUntil`) |
| `PVP_CRIT_BONUS` | 0.5 | crits on heroes: x (1 + (critMult - 1) x 0.5) |

- Damage = `base x PVP_MULT x PVP_DAMAGE x weapon.pvpMult x focus x totem x
  heroDamageMult x (1 - heroResist) x safe zone`, then `- armor x PVP_ARMOR_MULT` (min 1).
- Inside an attacker's lockout a bigger hit tops up the difference (no armor), so
  an ability landing with a weapon hit still counts; a smaller one does nothing.
- Hero hits are gated only by the attacker's own lockout (never by mice i-frames);
  they give the victim `PVP_MICE_IFRAMES` against mice. Mice hits keep the 0.5 s
  i-frames.
- `stats.pveDamageMult` (talents) multiplies damage to mice, champions and bosses
  (and gear burn on them), never to heroes. Default 1.
- `WeaponDef.pvpMult` (optional): Elephante 0.8, Ele Fonte 0.75, Fizzante 0.8,
  Jumbo 1.1, Filet 1.3 (Le F'ante, Ellie 1).
- Class changes: Ellie pellets 9 -> 10, Jumbo 10 -> 13, Updraft's gust slows rival
  heroes for 0.6 s (`Weapons.HOVER_HERO_SLOW`).
- Measured (`CombatTtk`, even "stage-2" builds, abilities on cooldown, no mice):
  median 1v1 21.6 s, 2v1 17.6 s, 3v1 14.4 s; class medians 17.8-25.1 s; slowest
  pairing 32.5 s. The plan's 6-9 s / 2.5-4 s (reached first with PVP_DAMAGE 2,
  lockout 0.25) wiped the solo human in 85% of `tests/sim/v4-report` matches, mostly
  in stage 1, so the channel was retuned for match health.

### Champions and bosses

- Champions: `FIRST` 35-45 s, `MAX_ALIVE_STAGE1` 2 (`maxAlive(radius, stage?)`),
  `LAIR_AT` 70 / 112, Golem 1250 HP, `HP_SCALE` 0.95, `HP_WAVE_GROWTH` 1.6, and HP x
  `Champions.levelHpMult(avgLevel)` = clamp(1 + 0.04 (level - 8), 0.8, 2.0).
- Champion rewards (v4): the top-damage squad (else the killer's); `ids` includes
  dead members, whose gear is queued and handed over when they come back (revive,
  respawn, statue or redeploy).
- Bosses: `world:spawnBoss(bossId, x, z, opts?)`, opts `{final?, heroes?, level?,
  scale = false?}`. HP x `Bosses.hpScale(heroes, level, final, stage)` =
  `HERO_HP_BASE` (1) + `HERO_HP_PER_SQUAD` (0) x standing heroes / 3, x `STAGE_HP[stage]`
  {1.3, 2.8, 4.5, 6}, x 2.5 on the final boss (`final` defaults to `world.stage >=
  World.FINAL_STAGE` (4)). The level factor is off (`LEVEL_HP_EXP` 0): Stats'
  bossHpMult already climbs ~6x from stage 1 to 4. The hero-count factor is flat
  because extra (bot) heroes added little boss damage in the sims.
  The final boss gets a third phase at 25 % HP (phase-2 patterns, gaps x 0.7,
  speed x 1.15; Fx `bossPhase {phase = 3}`, event `bossPhase {amount = 3}`).
- Final-boss stall (fixed in v4): knockback impulses stacked on bosses (10 % each,
  but fast high-level hits) into a ~45 studs/s shove that juggled the boss out of
  the storm circle, where zone-aware heroes do not follow; damage fell by two
  thirds and fights timed out at 180 s. Now `World.BIG_KNOCK_CAP` (6 studs/s) caps
  the knockback velocity of bosses and champions, and between leaps / dashes a boss
  outside the circle walks back in at `BOSS_ZONE_PULL` (30 studs/s) to
  `BOSS_ZONE_MARGIN` (6) inside the edge.

### BotBrain v4

- `BotBrain.new(id, classId, rng, ability?)` and `brain:setAbility(abilityDef)`:
  the equipped (alternate) ability's kind, area and range drive casting.
- `view.zone` = `world:zone()`: the bot keeps inside the next circle minus
  `ZONE_MARGIN` (15) and ignores POIs, champions, gear and bags outside it; outside
  the current circle getting in beats everything, fleeing included. The squad
  leader drifts toward the circle centre. Helpers `BotBrain.zoneOf(view)`,
  `BotBrain.inZone(view, x, z)`.
- Pings: `view.ping` or `brain:setPing({x, z, kind?, t?, untilT?})` (nil clears).
  Live until `untilT`, else `t + PING_TTL` (12 s). `enemy` / `attack`: fight the foe
  nearest the ping within 20 studs (any stage, never a stage-1 rookie).
  `danger` / `retreat`: keep 35 studs away. Every other kind (go, champion, loot,
  extract, stay, help): walk there before POIs, champions and the leash.
- Rookies: foes with `rookie = true` are never picked in stage 1 (or without a stage).

### Fx `die` and `hit` (v4)

`hit` adds `by?`: the hero who dealt the most of that number (hits on one enemy are
merged per step, so a shared number names its biggest contributor).

`die` adds `by?`: the id of the hero whose hit killed the enemy (absent for
recycled strays, traps, despawns and bosses' clean-up). FxFilter is unchanged
(point-culled at 100 studs), so a client counts its own kills with `fx.by == myId`.

## Iteration 1 / v5 hooks (team M1, docs/iter/1/PLAN.md §A, §C, §D, §E)

Code: `Config/RunShop.luau` (new), `Combat/World.luau`, `Combat/WaveDirector.luau`,
`Combat/Champions.luau`, `Config/Bosses.luau`, `Bots/BotBrain.luau`. Spec: `CombatV5`.

### Config/RunShop (pure)

- Economy: `RINDS` {mouse 5, elite 15, champion 200, boss 750}, `STAGE_SCALE` 0.25,
  `SHARE` 0.5 within `SHARE_RADIUS` 45, `TOTEM_RIND_MULT` 1.6, `WHEY_PER_RINDS` 25,
  `WHEY` {poi 40, championTop 60, championOther 30, stage 50}, `XP_SHARE` 0.5 within 45.
- Ranks: `RANK_ORDER` (might, hide, plating, mending, frenzy, stride, reach, focus),
  `RANKS[id]` {base, add?, pct?, cap?}, `MAX_RANK` 25, `RANK_GROWTH` 1.14.
  All 8 at 25 cost ~36k rinds (V5 quoted ~75k; the formula is V5's).
- Buffs: `BUFFS` (8, `BUFF_COST` 250 whey), `CLASS_BUFFS[classId]` (7, `CLASS_BUFF_COST` 500),
  `ULTIMATES` (titan, cataclysm, overdrive, herdguard; `ULTIMATE_COST` {6000 rinds, 600 whey},
  `ULTIMATE_MAX` 2, `ALTAR_FROM_STAGE` 3), `HERDGUARD_RADIUS` 20 / `HERDGUARD_MULT` 0.88.
- Swap (rinds -> whey only): `SWAP_RATE` 10, `SWAP_FEE` 0.2.
- Functions:
  - `RunShop.rankCost(statId, rank) -> number?` (cost of rank `rank + 1`; nil at 25)
  - `RunShop.rankTotal(statId, n) -> number`
  - `RunShop.rindsFor(kind, stage?) -> number`
  - `RunShop.swap(rinds) -> (whey, rindsSpent)`
  - `RunShop.rankDelta(ranks) -> StatDelta`
  - `RunShop.combine(ranks?, buffIds?, ultimateIds?, classId?, classBuff?) -> StatDelta`
    (buffs once each, at most 2 ultimates; pass the result to `world:setRunMods`).

### World

| Function / event | Behaviour |
|---|---|
| `world:setRunMods(id, delta?)` | A `Types.StatDelta` stat layer on top of base stats and gear (nil clears). Keeps the HP fraction. |
| `world:setSquadAura(squad, delta?)` | The same layer for every member of a squad (charms), bots included; follows `setSquad`. |
| event `rinds {id, amount, kind}` | `kind` = `kill` / `share` / `champion` / `boss`. Mouse kills: the killer, plus SHARE to standing squadmates within 45. Champions / bosses: split by squad damage share, every member of a squad (dead ones too). x stats.rindMult x TOTEM_RIND_MULT while the squad owns a Power Totem. |
| event `whey {id, amount, kind}` | `kind` = `rinds` (+1 per 25 rinds earned, per hero) / `champion` (60 top squad, 30 others). x stats.wheyMult. POI and stage whey are RunDirector's. |
| event `xp` (`kind = "share"`) | Shared XP: standing squadmates within 45 studs of a crumb's picker get 50%. |

New optional `PlayerStats` keys: `rindMult`, `wheyMult`, `damageTakenMult` (Bulwark),
`abilityRepeat` (Cataclysm: the ability fires again 0.35 s later), `herdguard`
(squadmates within 20 studs take x0.88 from mice / champions / bosses), `sizeMult`
(Titan, cosmetic), `pveResist` (P's `runBonuses` extras: x(1 - min(pveResist, 0.6))
from mice / champions / bosses; never PvP). M2 can pass `pveResist` in the stats or
in the `setRunMods` delta (`add = {pveResist = x}`).

### Rookie squads (P-1, P-29)

- `World.ROOKIE_STAGES` 2: enemy BOTS never target a rookie hero through stage 2.
- `World.ROOKIE_SQUAD_STAGES` 1: in stage 1 they also skip every member of a rookie's
  squad; mice / champions / boss deal x0.75 to that squad (`ROOKIE_MICE_DAMAGE`), and
  its heroes count x0.85 for mouse spawning (`ROOKIE_SPAWN`).
- `getPlayers()` adds `rookieSquad` and `secondWindUsed`.
- BotBrain: `ROOKIE_STAGES` 2 and `ROOKIE_SQUAD_STAGES` 1 (foes with `rookie` /
  `rookieSquad`); a downed rookie squadmate is revived first (`ROOKIE_REVIVE_WEIGHT` 5,
  from `ROOKIE_REVIVE_RANGE` 70, whatever the danger). **Second Wind:** `think` returns
  `intent.secondWind = true` when the bot is downed with no standing squadmate within
  `SECOND_WIND_ALONE` (10) and `view.self.canSecondWind ~= false`.
  **M2: BotService should call `world:useSecondWind(id)` on it** (pass
  `canSecondWind = not secondWindUsed`).

### Idle time and champions (P-12)

- Spawn weight: `World._spawnHeroes()`: standing heroes, x0.85 for a stage-1 rookie squad, x1.25
  with at most 2 squads (`FEW_SQUADS_SPAWN`). WaveDirector per-hero mode uses it.
- Idle lure: a standing hero with no mouse within `LURE_NEAR` (30) for `LURE_AFTER` s gets
  `LURE_BASE + stage` mice `LURE_RING` studs away (inside the storm circle), at most every
  `LURE_EVERY` s; at the cap, plain mice > 60 studs from every hero are retired to make room.
- Champions: the director picks one of the 2 free sites nearest a standing hero
  (`Champions.pickSite`).

### Route gamble (C-1)

- `BotBrain.chooseRoute(cards, rng, ctx?)`: tier weights `ROUTE_WEIGHTS` by
  `ctx.routeStage` (the stage the card leads to): {1,0,0} / {50,40,10} / {35,45,20};
  `ROUTE_LOW_HP_WEIGHTS` {80,20,0} when `ctx.hpFrac < 0.5`. Used by `chooseVote("route")`
  with no human votes.
- `BotBrain.randomRoute(cards, rng)`: no winner, {50, 35, 15}.
  (M2's `MatchState.botRouteIndex` / `randomRouteIndex` drive the sim and RunDirector.)

### Bosses (C-29, boss ceremony)

- `Bosses.POSES[id]` / `Bosses.pose(id)`: `{stance, lean, crouch, bob, bobHz, sway,
  windup, strike, phase2}`, a distinct set per boss (for team G).
- Each boss def has `lore` (one cartoon line) and `tip` ("Watch for ...") for the intro
  card (team U). `Types.BossDef` gains both as optional fields.

## Iteration 2 hooks (team M1, docs/iter/2/PLAN.md, ALIGNMENT §2)

### Economy and champions (iteration 1 close-out)

- `RunShop.RINDS` = {mouse 1.25, elite 4, champion 50, boss 190}: the iteration-1 x5 values / 4.
- `Champions.HP_SCALE` 2.1 (IntegrationSquads: champion fight median 18 s; guard 12-45 s).

### Meta layer: "meta never decides PvP"

| Function | Behaviour |
|---|---|
| `world:setMetaMods(id, delta?)` | Long-term layer (Prestige, Ascension). Applied after run mods. `damageMult` in it is read as `pveDamageMult`. |
| `world:setSquadAura(squad, delta?, classDeltas?)` | Gems (team-wide sum) and Ascension node 8. `classDeltas = {[classId] = delta}` reaches only that class in the squad (gem class uniques). Also a meta layer. |
| `world:setHeroClass(id, classId?)` | Needed for class auras. |

- `World.META_HP_PVP_CAP` 1.25: max HP from the meta layers (meta + aura + class aura)
  counts at most +25% against heroes. Hero damage is scaled up by `ratio / 1.25` when a
  hero's meta HP ratio is above the cap; run-shop HP is not capped.
- New optional stat keys: `luckyCrumb` (chance of x2 PvE damage per hit), `unshakable`
  (> 0: enemy projectile slows do not apply), `abilityAreaMult` (x ability area),
  `abilityEcho` (the ability echoes ~0.5 s later at this x damage).

### Ascension (`Config/AscensionNodes.luau`, M1's 7 x 8 table)

- `AscensionNodes.node(classId, n) -> {delta, look?, squadAura?}?`
- `AscensionNodes.combine(classId, asc) -> (delta, squadAura?, looks)`: `asc` is P's
  8-char "10110000" string, or a count n (nodes 1..n). Pass `delta` to `setMetaMods` and
  `squadAura` into the squad's `setSquadAura` sum.
- Nodes: 1 +8% HP; 2 Bull look + ability area x1.2; 3 the class weapon extra (+1
  projectile / pierce, or arc area x1.15); 4 Matriarch look + the passive again; 5 ability
  echo 50%; 6 cooldowns x0.9; 7 the Class-Stall buff at half strength; 8 Ancient look +
  squad aura +5% PvE damage.

### Numbered waves

- `world:startWave(index, opts?) -> frontMice`: RunDirector calls it at each wave start;
  `index` = match wave 1..20 (`opts.stageWave` overrides `(index - 1) % 5 + 1`).
  - Mouse mix unlocks by stage wave (wave 1 plain mice, wave 4 everything).
  - Mouse HP +4% per stage wave (`WAVE_HP_STEP`).
  - The per-hero ramp steps per match wave: x1.0 at wave 1 to x3.2 at wave 19 (`WaveDirector.waveRamp`).
  - Horde waves (stage waves 1-4) open with 2-3 fronts: `FRONT_SHARE` (40%) of
    `PER_HERO_RATE x heroes x 30 x ramp` pours in from 8 studs inside the storm circle
    (or the arena edge) toward the squads' centroids, in 3 bursts over `FRONT_TIME` (6 s).
  - The boss wave (5) has no fronts. Event `waveStart {amount = index, kind = stageWave}`.
- `Storm.zoneForWave(R, stage, wave, seed?, waveSeconds?)`: circle steps keyed to the
  stage wave (wave 1 edge with Circle 1 shown; waves 2-4 close to 0.65 / 0.40 / 0.22 R over
  the wave at 2 / 4 / 8 %; wave 5 = `bossZone`). Close times are relative to the wave's
  start: `Storm.toWorld(zone, waveStartT)`.

## Iteration 3 (team M1, docs/iter/3/PLAN.md §B)

- **T-2, `Config/Difficulty` (now M1):** Moldy 1.6 / 1.4 / 1.2 and Doomwheel 2.2 / 1.8 / 1.3
  (hp / damage / spawn). On 16 seeds: Doomwheel fresh 0/16, maxed veteran 9/16; Moldy fresh 3/16,
  veteran 7/16. Veteran stand-in: Prestige 40, all 8 Ascension nodes, three +5 tier-11 gems,
  Lucky Crumb + the class unique. Mild `reward` is 1.0 (T-11).
- **T-4, bots and rookies:**
  - `World.ROOKIE_STAGES` 3 and `ROOKIE_SQUAD_STAGES` 2 (BotBrain the same).
  - A revived or redeployed hero is not an enemy bot's target for `BOT_SAFE_AFTER_REVIVE` (10 s).
  - One enemy bot at a time on a human (`BOT_FOCUS_WINDOW` 2 s): enforced in `_rookieSafe` and
    `damageHeroFrom`. `getPlayers()` adds `botSafe` and `botFocus`; BotBrain skips such foes.
  - Bot PvP is 32% of a rookie's damage taken (16 seeds; target < 40%).
  - `World.BOT_PVP_VS_HUMAN_SQUAD` 0.35 (was 0.5): enemy bots deal x0.35 to a squad with a
    human. IntegrationDifficulty: Medium 10/12, Sharp 9/12, Doomwheel 0/12; veteran
    Doomwheel 7/16.
- **T-3 / T-18, horn carry:** World keeps each wave's budget and spawned count. When
  `startWave` comes early in the same stage (the Early Horn), the unspawned rest (at most
  `CARRY_MAX` = 1 wave) joins the new wave's fronts, the boss wave's too. Event `waveStart`
  adds `carry`.
