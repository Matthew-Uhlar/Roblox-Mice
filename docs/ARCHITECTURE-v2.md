# Architecture v2: squad PvPvE (team contracts)

Read `docs/GDD-v2.md` first. Everything in `docs/ARCHITECTURE.md` still holds
(pure `src/shared`, string requires, `Guard.connect`, bot ids via `Util/Ids`,
the monetization rules) unless this file changes it.

## File ownership (redesign round)

| Team | Owns |
|---|---|
| **R1 Match & squads** | `src/shared/Run/{RunState,Vote,LobbyRules,EpicDrop,Pressure,UpgradeOffers,Leveling}.luau`, **new** `Run/MatchState.luau`, `src/shared/Bots/BotRoster.luau`, `src/server/Services/{RunDirector,LobbyService,Guard,Remotes}.luau`, `src/server/Main.server.luau`, specs `Run*`, `BotRoster*` |
| **R2 Combat, PvP, gear, POIs, bot AI** | `src/shared/Combat/*`, **new** `src/shared/Run/Gear.luau`, `src/shared/Config/{Gear,Pois,Enemies,Bosses,Maps}.luau`, `src/shared/Bots/BotBrain.luau`, `src/server/Services/{CombatService,BotService}.luau`, specs `Combat*`, `BotBrain*` |
| **R3 Class progression & data** | `src/shared/Config/{Classes,ClassPerks,ClassAbilities,ClassSkins,Talents,Cosmetics,Shop,Monetization}.luau`, `src/shared/Run/Stats.luau`, `src/shared/Data/*`, `src/server/Services/{DataService,ShopService,MonetizationService,LeaderboardService,CosmeticsService}.luau`, specs `Data*`, `RunStats*` |
| **R4 Graphics** | `src/server/Services/ArenaBuilder.luau`, **new** `src/server/Services/{LightingService,LobbyWorld}.luau`, **new** `src/server/Visuals/*`, **new** `src/client/Visuals/*`, `src/client/Controllers/{HordeRenderer,FxController,CameraController}.luau`, `assets/**` |
| **R5 Client UI/UX** | `src/client/UI/*`, `src/client/Controllers/{State,InputController,ChatTags}.luau`, `src/client/Util/*`, `src/client/Main.client.luau`, spec `ClientLayout*` |
| Lead | `src/shared/{Types,Net}.luau`, `src/shared/Util/*`, `tests/lib/*`, `tests/sim/*`, `tests/runtime/*`, `docs/*.md` |
| Pipeline | `.github/**`, `scripts/**` (except `check.sh`, `test.sh` and `compile-check.luau`, which the lead owns), generated `Config/{ProductIds,AssetIds}.luau` |

If you need a change in a file you don't own, put the exact change in your
final report. Don't make it yourself. Small additive edits to `Types.luau`
(new optional fields only) are allowed for every team.

## Cross-team contracts

### Squads (R1 ↔ everyone)

- Squad ids are `1..4`. `Config/Squads` is lead-owned and lives at `src/shared/Util/Squads.luau`:
  `Squads.LIST[i] = {id, name, color = {r,g,b}}`, `Squads.MAX = 4`, `Squads.SIZE = 3`.
- Every participant (human or bot) has a `squad`. `World:addPlayer(id, stats, weapon, ability, x, z, squad)` takes squad as the **7th argument**, and `world:setSquad(id, squad)` changes it.

### Combat (R2 provides, R1 consumes)

- PvP: every hit applies to mice AND to heroes whose `squad ~= attacker.squad`. Damage to heroes is × `World.PVP_MULT` (0.45) and never crits. There is no friendly fire.
- New world events (`drainEvents`):

  | Event | Fields |
  |---|---|
  | `heroDowned` | `id, by` (attacker id or nil) |
  | `heroKilled` | `id, by` |
  | `squadEliminated` | `squad` |
  | `bossDead` | adds `killerSquad` and `damageBySquad = {[squad] = number}` |
  | `gearPickup` | `id, item, slot` |
  | `gearSwapOffer` | `id, item, slot, current` |
  | `lootBag` | `bag, by, gear = {item…}, cheese` |
  | `poiReward` | adds new kinds: `armory`, `vault`, `totem_owner {squad}`, `shop_cart_open {poi, by, offers}` |

- New world API:
  - `world:addLootBag(x, z, gear, cheese) -> bagId`
  - `world:dropGear(item, x, z) -> groundId`
  - `world:giveGear(id, item) -> ok, offerSwap?`
  - `world:resolveSwap(id, keep: boolean)`
  - `world:gearOf(id) -> {weapon?, armor?, trinket?}`
  - `world:squadOf(id)`
  - `world:aliveSquads() -> {squad}`
- `Run/Gear.luau` (pure):
  - `Gear.apply(stats, weapon, ability, items) -> (stats, weapon, ability)`
  - `Gear.roll(rng, tier, stage) -> item`
  - Items look like `{id, slot = "weapon"|"armor"|"trinket", rarity, …}`. Definitions are in `Config/Gear`.
- R1 applies gear on top of `Stats.compute`:
  `stats, weapon, ability = Gear.apply(Stats.compute(...), world:gearOf(id))`,
  then calls `world:updatePlayer`.

### Class progression (R3 provides, R1/R5 consume)

- **Profile v5:** `profile.classes[classId] = {xp, level, perks = {[perkId] = true}, ability = abilityId?, skin = skinId?}`. Mastery is derived from level.
- **`Data/ClassProgress.luau` (pure):**
  - `xpToNext(level)` and `addXp(state, xp) -> (state, levelsGained)`
  - `perkPointsFree(state)` and `canTake(classId, state, perkId)`
  - `respecCost(level)`
  - `unlockedAbilities(classId, level)` and `unlockedSkins(classId, level)`
  - `mastery(level) -> "none"|"bronze"|"silver"|"gold"`
  - `runXp(summary)`, where `summary = {stagesSurvived, bossDamageShare, heroDowns, pois, extracted}`
- **`Stats.compute(classId, stacks, blessings, talents, talentDefs, classState?)`**
  gains a 6th argument, `classState = {perks, ability}`. It applies the perks,
  and returns the chosen alternate ability as the third result.
- **`DataService.awardRun(player, cheese, xp, stats)`:** `stats` gains
  `classId` and `classXp`. DataService adds the class XP, and the level-up
  toasts happen there.
- **New remotes:** `SelectPerk`, `ResetPerks`, `SelectAbility` and `SelectSkin`.
  ShopService handles them (R3). The profile view includes `classes`.

### Graphics (R4 provides, others call)

- `Visuals/HeroDecor` (server) `apply(character, classId, skinId, squad)`:
  class gear plus the squad colour. CosmeticsService (R3) and RunDirector (R1)
  call it.
- `Visuals/BotModel` (server) `build(spec, squad) -> Model`: BotService (R2)
  calls it instead of building its own model.
- `LobbyWorld.build() -> {spawn, readyPad, squadPads[1..4]}`: LobbyService
  (R1) calls it instead of building its own geometry.
- `LightingService.apply(mapId | "lobby")`: RunDirector calls it each stage.
- `ArenaBuilder.build(mapId, seed, opts)` keeps its signature and its return
  value (obstacles, spawn, radius, center). It adds `squadSpawns[1..4]` (one
  corner each) and `safeZones[1..4] = {x, z, r}`.
- On the client, `HordeRenderer` and `FxController` use `src/client/Visuals/*`
  models. They prefer mesh assets from `Shared.Config.AssetIds` when present
  (a generated file that may not exist yet; require it in a pcall), and fall
  back to rich Part models.

### Network (lead, `src/shared/Net.luau`)

| Direction | Remote | Arguments / payload |
|---|---|---|
| C2S | `ExtractVote` | `(choice: "Extract"\|"Stay"\|"DoubleOrNothing")` |
| C2S | `SwapGear` | `(takeNew: boolean)`: **true = equip the offered item** (the old one drops on the ground); false = keep the current item |
| C2S | `BuyCartItem` | `(poiId: number, index: number)` |
| C2S | `SelectPerk` | `(classId, perkId)` |
| C2S | `ResetPerks` | `(classId)` |
| C2S | `SelectAbility` | `(classId, abilityId)` |
| C2S | `SelectSkin` | `(classId, skinId)` |
| S2C | `Match` | `{phase, stage, squads = {[1..4] = {name, color, members = {id…}, pending, alive, aliveCount, extracted, eliminated, kills, isYou}}, routeChooser?, bounties = {id…}}` |
| S2C | `KillFeed` | `({killer, victim, killerSquad, victimSquad, kind})` |
| S2C | `Inventory` | `({weapon?, armor?, trinket?, swapOffer? = {item, slot, endsAt}})` |
| S2C | `Extract` | `({endsAt, options, votes = {[choice] = n}, yourChoice?})` |
| S2C | `ShopCart` | `({poi, offers = {item…}, prices})` |

Route voting is replaced: the squad that killed the boss picks the route.
RunDirector sends `VoteOpen` with `kind = "route"` only to that squad's
humans; everyone else gets `Match.routeChooser`. A bot squad picks by
`BotBrain.chooseVote`.
