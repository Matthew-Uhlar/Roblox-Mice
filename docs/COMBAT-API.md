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

## v2: squads, PvP, gear, contested POIs (Team R2, GDD-v2 §2-4)

Code is the source of truth: `Combat/World.luau`, `Combat/Weapons.luau`,
`Combat/Pois.luau`, `Run/Gear.luau`, `Config/Gear.luau`, `Bots/BotBrain.luau`.

### World options and tunables

- `World.new{ ..., safeZones = {[squad] = {x, z, r}}?, tier = "Low"|"Mid"|"High"?, carriers = boolean? }`.
  `tier` drives gear rarity rolls. Golden carriers are on by default, but never when `enemyCap` is 0.
- Tunables:

  | Constant | Value | Meaning |
  |---|---|---|
  | `PVP_MULT` | 0.45 | Damage against heroes |
  | `HERO_AGGRO` | 10 | Auto-weapons take an enemy hero within this range even if mice are closer |
  | `DOWNED_HITS` | 4 | Hits that kill a downed hero |
  | `SPAWN_PROTECT` | 5 s | Spawn protection |
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
  - **Fighting:** it fights enemy heroes within 18 studs, or one that hit its squad in the last 4 s within 45 studs. It finishes downed foes and aims its ability at foes. Protected heroes are ignored.
  - **Fleeing:** below 35% HP with a foe within 28 studs, it flees.
  - **POIs:** it contests POIs and captures or defends the totem.
  - **Loot:** it fetches better ground gear and loot bags.
- Helpers:
  - `chooseSwap(current, offered)` and `chooseCartItem(offers, prices, sold, pot, gear)`.
  - `chooseVote("extract", options, squadHumanTally, rng, {pot, hpFrac})`.
  - `chooseExtract(matchView, squad, rng) -> "Extract" | "Stay" | "DoubleOrNothing"`. The squad's human votes come from `squads[squad].humanVotes`. Bot-only squads extract at pot ≥ 300, average HP < 45%, or on stage 4. They never choose Double or Nothing alone.
- BotService:
  - Squad colour shows as a band, a cap and the name colour.
  - It uses `Visuals/BotModel.build(spec, squad)` when that module exists, and always keeps the 🤖 tag.
  - Bots think in 3 staggered groups.
  - It resolves swap offers with `chooseSwap` and follows Terrain height.

### Performance (Lune)

- 12 heroes in 4 squads with 220 mice: about 0.5-0.8 ms per step on average.
- The v1 PerfWorld case: 0.47 ms average, 4.9 ms worst.
- `BotBrain:think` with 12 heroes, 220 mice and loot: about 0.1 ms.
