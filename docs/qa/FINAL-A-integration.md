# Final QC A: integration and gameplay

- **Team:** Final QC A (integration and gameplay)
- **Date:** 2026-11-02
- **Type:** report only. No source files were changed.

## Baseline

- Audited against `253d3ad`, which is `df3eccc` plus a handoff-only commit.
- The lead's **uncommitted** Final-QC-B edits are also in the working tree and were taken into account:
  - Layout text floor
  - portal fade `DisplayOrder` set to 12
  - `LobbyService.PRESSURE_LOCK_SECONDS` (5 s)
  - `C2S.InteractPoi` removed from `Net`
  - kick message text
  - the ProfileSchema and GDD unlock wording
- Line numbers below are for the working tree.

## Checks run

- `scripts/test.sh`: **all 34 spec files passed**, including `CombatPois`, `IntegrationPois` and `RunPressure`.
- Other gate steps, run one by one so nothing is written into the repo:
  - `stylua --check`: OK
  - `selene`: 0 errors, 0 warnings
  - `compile-check`: 116 files, 0 errors
  - `rojo build`, output to the scratchpad: OK
- **Require-by-string simulation** of all 45 `src/shared` modules, using Roblox semantics (`./X` = sibling, `../X` = the parent's sibling):
  - every path resolves
  - no cycles
  - no `init.luau`
  - New modules:

    | Module | Requires |
    |---|---|
    | `Run/Pressure` | `Types`, `Config/Pressure`, `Run/Stats` |
    | `Combat/Pois` | `Util/Rng`, `Types`, `Config/Maps`, `Config/Pois`, `Run/UpgradeOffers` |
    | `Config/Pois` | `Types` |
    | `Config/Pressure` | nothing |
    | `WaveDirector` | `Config/Pressure` |
    | `BotBrain` | `Config/Pois` |
    | `Award` and `ProfileSchema` | `Run/Pressure` |

  - The new shared modules are pure: no `game`, `Instance`, `Vector3`, `Color3`, `math.random`, `os.clock` or `task`.
- **Headless sims** (scratchpad, not committed):
  - Party: 1 "human" (a BotBrain) plus 2 `BotRoster` bots, with POIs and the portal on (`pois = true`).
  - Pressure 0 against the full board (21). `RunState.new` was given the board exactly as RunDirector does.
  - Runs: 8 seeds × 3 free classes through Cycle 1 to Go Home, 6 seeds through Cycle 2, and 30 seeds of stage 1 only.
  - Every Map `poiTable` id has a `Config/Pois` def, and every map has an `accentColor` for the portal tint.

## Findings

No Blockers. One Major (balance) and nine Minors. The cross-module wiring of Pressure, POIs and the portal matches end to end. Both sides of every payload were checked (see "Verified OK").

### Major

**M1. At Pressure 21, solo with bots is barely harder than at Pressure 0, but pays +168% cheese.** (Balance and economy.)

- **Where:** `src/shared/Config/Pressure.luau:46-119` (per-rank values) and `src/shared/Config/Pressure.luau:37-41` (`REWARDS`).
- **Evidence (headless, solo with 2 bots, POIs on):**
  - Stage-1 WorldMods at P21:
    - enemy HP 1.42 → 2.06
    - boss HP 1.72 → 2.49
    - boss damage ×1.6
    - enemy projectile speed ×1.6
    - elite speed ×1.9, elite size ×1.5
    - spawn rate ×1.6 in the last 60 s of waves
    - ranged mice fire +2 projectiles
    - healing ×0.5

    All 8 modifiers do reach World: `spawnEnemy` (`World.luau:631-662`), the ranged fan (`:1426`), `WaveDirector.rate` (`:146-154`), `BossPatterns:814`, contact damage (`World.luau:698`) and `_heal` (`:472`).
  - Results:

    | Run | P0 | P21 |
    |---|---|---|
    | Cycle 1 → Go Home, Ele Fonte | 8/8 wins | 7/8 |
    | Cycle 1 → Go Home, Elephante | 7/8 | 7/8 |
    | Cycle 1 → Go Home, Ellie Fawn | 6/8 | 6/8 |
    | Cycle 1 total | **21/24** | **20/24** |
    | Cycle 1 banked cheese | 580–940 | 1,539–1,932 |
    | Cycle 2, Ele Fonte, 6 seeds | 6/6 wins, banked 1,749–1,982 | 5/6 wins, banked 4,113–4,447 |
    | Stage 1 only, 30 seeds: wipes | 0/30 | 4/30 |

  - Every P21 failure is a stage-1 wipe. From stage 2 on, the party out-scales the board: P21 bosses die in 15–60 s, the same as at P0.
  - Stampede and Big Cheese do nothing on stage 1-1, because `eliteChance` is 0 at global stage 1. The only elites there are Elite Camp packs.
- **Effect:** once a player clears stage 1, the full board is close to a free ×2.68 cheese multiplier. It feeds the soft-currency economy (class unlocks, talents, cosmetics). GDD §3.7 says Pressure should make a run harder for more reward.
- **Caveat:** the sim "human" is a BotBrain that kites well. Real players may struggle more. Verify in a play-test before retuning.
- **Fix, any of:**
  1. Scale the late-run threats rather than stage 1. For example, add a per-rank `enemyDamageMult` to Thick Rind or Boss Fury, and make Rush Hour also raise `eliteChance`.
  2. Lower `cheesePerPoint` to 0.04–0.05.
  3. Have Stampede and Big Cheese add `eliteChance` so they matter from stage 1.

  Add an `IntegrationPressure` spec that asserts the P21 win rate is at least 25 points below P0 over N seeds, so later tuning cannot regress.

### Minor

| # | Where | What is wrong | Evidence (both sides) | Fix |
|---|---|---|---|---|
| m1 | `src/client/Controllers/State.luau:325-331` against `RunDirector.luau:645` and `UpgradeUI.luau:192-197` | **`offer.source` is dropped on the client**, so the "🥧 GRANDMA'S PANTRY! Pick an Epic" and "🎁 ELITE CHEST! Bonus pick" titles never show. Every bonus pick is labelled "⬆ LEVEL UP!". | The server sends `{offerId, cards, rerollsLeft, queued, source}`. The `State` UpgradeOffer handler builds `entry` from `offerId`, `cards`, `rerollsLeft` and `queued` only. `UpgradeUI` reads `offer.source`, which is always nil. | Add `source = if type(o.source) == "string" then o.source else nil` to `entry`. Also add `source` to `Remotes.UpgradeOfferPayload`. |
| m2 | `src/shared/Combat/Pois.luau:507-513` (resync runs while not live) with `FxController.luau:2297-2302` and `HudUI` `resetPois` | **Ghost POI rings in the next arena.** | After the boss, the old world keeps stepping through StageClear, the bank vote and the route vote (up to about 35 s). Every 15 s `Pois.update` re-emits `{t="poi"}` for all old POIs. That re-creates the marks the client cleared on BankVote or RouteVote. The new world numbers its POIs 1..N again, and the client does not clear on `Waves`. If the old stage had more POIs (8–12 per map), ids N+1.. stay as faint rings (0.88/0.93 transparency) at old positions for the whole stage. Same-id marks are moved or replaced, so only the extras ghost. | Any one of: (a) skip the periodic resync while `not live`; (b) `clearPoiMarks()` on the portal `pull` or `close` event; (c) carry a world nonce or `stageIndex` in `poi` Fx and drop marks from older nonces. Option (a) is one line. |
| m3 | `RunDirector.luau:1853` (`world:clearEnemies()` at boss start) with `Pois.luau:429` | **The Elite Camp chest is silently lost** if the camp is woken late in the waves. | `clearEnemies` sets `alive = false` without `_killEnemy`, so `onPackKill` never runs. The camp stays `state = "active"` with `pack > 0`, and its ring shows "active" through the boss fight. There is no chest and no message. | In `World.stopSpawning` (or `clearEnemies`), complete any camp that has a live pack (grant the chest), or mark it "done" with a toast such as "The camp's elites fled". |
| m4 | `RunDirector.luau:1124`, `RunDirector.luau:1197` and `FxController.luau:1369` | **Three overlapping "enraged" messages, one of them wrong.** | (a) At 50% HP the phase-2 event toasts "The boss is enraged!". (b) The 120 s enrage toasts "<Boss> is ENRAGED! Finish it fast!" from the server. (c) The client adds "😡 The boss is ENRAGED! **Hits harder**, moves faster!". `World._enrage` (`World.luau:890-911`) only changes speed (×1.35) and pattern gaps (×0.5), not damage. | Make the phase-2 toast "The boss gets angry! (phase 2)". Drop either the client toast or the server toast. Change "Hits harder" to "attacks faster". |
| m5 | `World.snapshot` (`World.luau:2028-2057`) and `HordeRenderer.luau:692-703` | **Big Cheese (elite size ×1.25 per rank) is invisible.** | The snapshot carries no radius. The renderer only tints elites (flag bit 0) and draws them at their kind's base size. At P21 elite hitboxes and contact are 1.5× (×1.4 elite base × 1.5) larger than what players see. This was already true for `Enemies.ELITE.radiusMult`; Pressure makes it worse. | Have the client scale elite models by `ELITE.radiusMult` × the run's `eliteSizeMult`. It can read the Lobby or RunState `pressure` board, or use a spare snapshot flag bit for "big". |
| m6 | `tests/sim/Headless.luau:773` against `RunDirector.luau:1025-1032` | **Sim and server disagree on cache cheese under Pressure.** | RunDirector multiplies POI cache cheese by `Pressure.cheeseMult`. The headless sim adds it raw. GDD §3.7 and §3.8 say the bonus applies to "every stage chest" and do not mention caches. | Pick one rule. To keep the server's: mirror `applyPressureCheese` in `Headless` and add "(Pressure bonus applies)" to the GDD cache row. |
| m7 | `src/client/UI/HudUI.luau:613-615` | The "Discovered: X!" banner shows on **every** rare or landmark completion, not only the first. The server toast (`RunDirector` `recordDiscovery`) fires only on the first find, so returning players see "Discovered" for things they already own. | `poiDone` with `def.rare` always calls `showBanner`. | Word it "Found: X!" when it is not new. Or drive the banner from the server's first-discovery toast, or from `profile.discoveries`, which is already in the Profile view. |
| m8 | `src/server/Services/Remotes.luau:17`, `:51-59` | Type contracts lag the payloads: `UpgradeOfferPayload` has no `source`, and `LobbyPayload` has no `pressure`. | No runtime effect: `compile-check` does not type-check, and the payloads are built as `any`. | Add the fields so a future strict type-check pass stays clean. |
| m9 | `RunDirector.luau` `rollOffer` (empty-cards branch) | If a POI bonus pick rolls no cards (all upgrades maxed), the branch also sets `pendingLevels = 0` and clears `bonusOffers`, so queued level-ups are dropped. This was already the behaviour; POIs add a new way to reach it. | Only reachable with every upgrade maxed. | Clear only the source that failed, then try the next queued source. |

Known items from HANDOFF that are still open, and not counted above:
- no per-Pressure leaderboard or badges
- the bot model `groundY` uses the arena spawn's Y = 4 (bots float slightly)

## QC1 re-verification

| QC1 # | Status | Evidence |
|---|---|---|
| 1 Blocker: Studio negative ids in CombatService | **Fixed** | The sign tests are gone. Teleports use `Ids.isBot` (`CombatService.luau:285`), and `tracked` holds Players only. |
| 2 Major: other `id < 0` sites | **Fixed** | All of them now use `Ids.isBot`: `World.partyWeight` and `getPlayers` (`World.luau:1987`, `:2005`), `BotRoster.isBotId` (`:114`), and `State.isBot` and FxController `characterRoot` (`:228`). `RunDirector.startRun` accepts `Guard.isInt(spec.id, -1000000, -1001) and Ids.isBot`. ARCHITECTURE "Team F" and HANDOFF §3.4 say ≤ −1001. |
| 3 Major: reroll offerId | **Fixed** | The reroll keeps `offerId` (`RunDirector` `onRerollUpgrade`, "Same offerId"). The client also drops older queued offers (`State.luau:333-343`). |
| 4 Major: `zone` Fx unhandled | **Fixed** | The `handlers` table has `zone`, `strike`, `dash`, `leap`, `blink`, `surge`, `enrage` and `adapt` (`FxController.luau:1893-1900`), plus the new `poi`, `poiProgress`, `poiDone`, `trap` and `portal`. |
| 5 `setMods` on leave | **Fixed** | `onPlayerRemoving` calls `w:setMods(c.run:worldMods())`, which includes the Pressure board. |
| 6 Play Again → SetReady | **Fixed** | `ResultsUI.luau:145`. |
| 7 Bot surprise votes | **Fixed** | `BotBrain.chooseVote`: surprise only when `kind == "route"`. `Vote.resolve(..., Vote.riskyIndices(options))` needs a human vote for a risky option. |
| 8 `finishRun` partial payout | **Fixed** | `payMember` runs under a pcall per player and skips players with `pr.awarded`. The early return on `c.awarded` is gone. |
| 9 Stuck world | **Fixed** | `CombatService` `MAX_STEP_FAILURES` → `{type="fatal"}` → `c.fatal` → `waitFor` returns "fatal" → wipe payout. `BOSS_TIMEOUT` is 600 s. |
| 10 Spawning behind Results | **Fixed** | `finishRun` calls `stopSpawning` and `clearEnemies` (pcall). |
| 11 Second Wind charged after revive | **Fixed** | The charge is a dry run (`probeSecondWind`), then the charge, then `world:useSecondWind`, with a refund if the world refuses. |
| 12 Lobby fields dropped | **Fixed** | `State` keeps `autoStart`, `botFill`, `botFillAny`, `botCount` and `pressure`. `playAgain`, `sittingOut`, `needsReady` and `leader` arrive per entry. |
| 13 Combat state leaks into lobby | **Fixed** | `CombatService.stop` clears the attributes, sets `Health = MaxHealth`, then re-enables Dead (`:465-475`). |
| 14 Snapshot and Fx sent to all clients | **Fixed** | `sendFx` and `broadcastSnapshot` loop over `tracked` with `FireClient` and per-viewer culling (`FxFilter`). |
| 15 AFK auto-start farming | **Fixed** | `LobbyRules.AFK_AUTO_RUNS = 2`, `afterRun` and `needsReady`. |

## Solo run traced: 1 human + 2 bots, Pressure set, POIs present

1. **Lobby.**
   - `currentLeader` picks the leader with `Pressure.pickLeader`: ready tier by `readyAt`, then willing, then present.
   - `SetPressure` arrives through Guard (`string(32)`, `number(-100, 100)`, rate 6/s). It checks, in order: a known id, lobby only, the leader, the leader's unlock, and the new 5 s countdown lock (same server-time base as `countdownEndsAt`). Then it calls `Pressure.setRank` (clamped and floored) and saves the board to `profile.pressure.board`.
   - Broadcast `pressure = {board, points, leaderId, unlocked, youUnlocked}`; `State.normalisePressure` and LobbyUI read exactly these fields.
2. **Start.**
   - `fireStart` passes `effectiveBoard(leaderAmong(party))`, a cloned board, as the 4th argument of `onStart`.
   - `startRun(players, classes, botSpecs, pressure)` builds `RunState.new(seed, partySize, {bossIds, mapIds, pressure})`, which sanitizes the board again.
3. **Route vote.**
   - Every card has `epicChance = min(1, base + 0.02 × points)`.
   - Bots follow the human.
4. **Stage build.**
   - `Pois.layout(Rng.new(stageSeed):fork(0x9017), mapId, Pois.arenaRadius)` produces the slots.
   - `ArenaBuilder.build(mapId, seed, {pois = layout})` builds parts at the same spots; obstacles avoid `r + 6`, and POI parts never collide.
   - `World.new{mods = run:worldMods()}`, where Pressure is applied via `Stats.applyCurse` and `Defaults.fillMods`, then `world:addPoi(entry)` for each slot.
   - Then `CombatService.start` and `BotService.setWorld`.
   - The first step's Fx carries the `poi` state.
5. **Waves.**
   - `Pois.update` runs only while `wave.active`.
   - `poiActivated` (rare) → `recordDiscovery` → `profile.discoveries[kind]`, plus an Epic cosmetic (Pantry) or the Herd Keeper title. The title shows through `CosmeticsService.lookFor`.
   - `poiReward` by kind:
     - cache → `c.stagePoiCheese`
     - shrine → `Pois.addBuff` → `refreshAllStats`
     - camp chest or Pantry → `pr.bonusOffers` and `botLevelUp(c, b, source)`
     - statue → `tokens.freeUsed = 0` and `revivesByStage[key] = 0`; the world resets `secondWindUsed`
   - Buffs expire through `hudLoop` `pruneBuffs`. Every clock involved is `GetServerTimeNow`: the World `now`, `simNow` and the HUD timers.
6. **Boss.**
   - The 120 s enrage emits Fx `enrage {id, x, z, …}` and the event `bossEnrage {kind}`; both match their readers.
   - Boss Fury applies to contact damage, patterns (`BossPatterns:814`) and trail zones.
7. **Boss kill.**
   - `bossDefeated()` already includes the Pressure bonus on the stage chest.
   - `payPoiCheese` adds the caches once, with the Pressure multiplier, through `run:addPending`, and resets to 0. Nothing is paid twice, and a wipe loses the unpaid caches.
8. **Portal.**
   - `openPortal`: `ArenaBuilder.buildPortal` parents the portal under `workspace.Arena` (removed by `ArenaBuilder.clear`) and `world:setPortal` sends the Fx.
   - During the bank and route votes, `tintFromVote` recolours it.
   - After the route vote: "pull" (bots walk in, the client swirls and fades), a 1.5 s wait, "close", 0.15 s, then `stopCombat`. `clear` and `build` run in the same frame, so characters never fall.
   - The client releases the fade on the `Waves` RunState, which is broadcast only after the build. The fade holds for at most 6 s.
   - An abort during the pull returns "abort".
9. **Go Home.**
   - `finishRun` → `payMember`: `pr.awarded` is set before `awardRun(..., {won = true, pressurePoints})`.
   - `DataService` passes `finite(pressurePoints)` to `Award.applyRun`, which calls `Pressure.recordRun`: the board unlocks and `highestCleared` rises, with toasts.
   - A leaver gets `won = false`, so the leave path never unlocks.
10. **Teardown.**
    - Order: `stopCombat`, `ArenaBuilder.clear` (arena, POIs and portal), `BotService.despawnAll`, `returnToLobby`, `setRunActive(false)`.
    - On Lobby or Results the client removes the portal motes, POI marks and HUD buffs.
    - Nothing leaks between runs: `c.buffs` and `c.stagePoiCheese` belong to the run context, and `lastLeader` is cleared on leave.

## Verified OK

- **Function names and arities across modules:**
  - `Pois.layout/arenaRadius/addBuff/applyBuffs/pruneBuffs/epicCards`, `PoiDefs.get`
  - `World.addPoi/pois/setPortal(x, z, phase, color)/portal`
  - `ArenaBuilder.build(mapId, seed, opts)/buildPortal/setPortalColor`
  - `RunState.addPending/pressurePoints/pressureLuck/applyPressureCheese`
  - `UpgradeOffers.eligible`, `LobbyRules.willing`, `Cosmetics.epicPool`, `CosmeticsService.refresh`
  - `Theme.radial().set`, `Format.clock`, `Defs.module("Pressure")`, and every `Theme.C` and FxController `COLORS` key used
- **Payloads, server against client:**
  - Lobby `pressure`
  - Fx `poi`, `poiProgress`, `poiDone` (`cheese`, `chest`, `untilT`, `dur`), `trap`, `portal` (`color` as `{r, g, b}`), `enrage`, and `tele style="trap"`
  - `poiReward` fields read by RunDirector
  - the BotBrain `PoiView` and `PortalView`, which match `Pois.copy` and `World.portal`
  - **Exception:** `offer.source` (m1).
- **Pressure maths:** `"*Mult"` fields multiply and other fields add. Healing is clamped to ≥ 0. `rangedExtraProjectiles` is rounded. The reward applies once, through pending → banked → `finalRewards`. Luck is added for humans and bots. The 2% Epic bonus applies on every tier.
- **Profile v4:** the migration unlocks veterans who have `stats.wins > 0`. `reconcile` sanitizes `pressure` and `discoveries`, and `view` sends both. The wording now matches in code, ProfileSchema and GDD.
- **Roblox APIs:**
  - All the new parts use valid materials and shapes, and are Anchored with CanTouch false.
  - `PointLight.Color` is set by `setPortalColor`.
  - The fade ScreenGui has `ResetOnSpawn = false` and `DisplayOrder = 12`.
  - The bot BillboardGui's `ResetOnSpawn` (a LayerCollector property) is valid.
  - `CylinderHandleAdornment.InnerRadius` is guarded by `rimSupported`.
  - `BulkMoveTo` is called once per frame (HordeRenderer, FxController).
  - Characters are moved with `PivotTo` (lobby teleport, MoveGuard snap).
  - New client `WaitForChild` paths point at modules that exist, and HudUI/FxController wrap them in a pcall.
  - New per-frame Instance work is pooled (POI marks, motes). HUD buff labels are created once per buff.
- **Bots and POIs:**
  - Bots seek safe channels near the human. They go to the statue only when someone is down, wake camps only when healthy, keep out of trap fields, and walk into the portal on "pull".
  - In the sims, POIs fired 6–14 times per 4-stage run, and every kind activated (`IntegrationPois`).
  - Camp waking is not the main cause of P21 wipes (1 of 4).
- **Gameplay:**
  - Solo with bots at Pressure 0 stays winnable: 21/24 Cycle-1 Go Home wins, 6/6 two-cycle runs.
  - At Pressure 21 it is survivable but not hard enough (M1).
