# QC1: Integration and correctness audit

- **Team:** QC 1 (integration and correctness)
- **Date:** 2026-11-01
- **Type:** report only. No source files were changed.

## Baseline

- Audited against commit `1504b3d` ("Handoff: bots done, testing/QC running").
- Line numbers below are for `HEAD`.
- During the audit, another agent had **uncommitted** working-tree edits in progress. They touch 21 files and add `src/shared/Util/Ids.luau`, `tests/sim/` and `tests/specs/IntegrationSmoke.tmp.luau`.
  - Where those edits already address a finding, the finding says so.
  - Re-verify after they are committed.

## Checks run

- `lune run scripts/compile-check.luau src`: 66 files, 0 errors (working tree).
- Require-by-string simulation of `src/shared`:
  - Every relative path was resolved against the Rojo folder layout (`./X` = sibling, `../X` = parent's sibling).
  - All 35 modules resolve. No cycles, no `init.luau`, no non-literal requires.
- Server require graph:
  - No cycles.
  - `DataService` reaches `LeaderboardService` only through a lazy `require` at call time.

## Findings

Sorted by severity. Each finding gives the two sides of the mismatch and a fix.

| # | Sev | Where (HEAD) | What is wrong | Evidence (both sides) | Suggested fix |
|---|---|---|---|---|---|
| 1 | **Blocker** (Studio play-test) | `src/server/Services/CombatService.luau:146`, `:161`, `:197` | Studio local-server test players have **negative UserIds** (−1…−8). CombatService treats any id ≤ 0 as a bot, so in Studio a human is never moved in the sim: no HRP→world position sync, no Humanoid HP/WalkSpeed display, no dash teleports. Enemies chase the spawn point, the player walks around untouched, and the first Studio play-test (HANDOFF top priority) is meaningless. | `syncPositions`: `if id > 0 and player.Parent == Players`. `applyHumanoids`: `if id <= 0 ... continue`. `applyTeleports`: `if tp.id > 0`. `tracked` only ever holds real `Player`s (`CombatService.start(world, memberList(c))`, RunDirector:1312), so the sign test is not needed at all. | Drop the sign tests for `tracked` players, since they are Players by construction. For teleports, test against a bot band, not the sign. *Working tree:* fixed (`Ids.isBot`, sign tests removed). Commit it. |
| 2 | **Major** (Studio) | Same root cause, all other `id < 0` sites. (a) `src/shared/Combat/World.luau:1769` `partyWeight`. (b) `World.luau:1787` `getPlayers().isBot`. (c) `src/shared/Bots/BotRoster.luau:114` `isBotId`, and `:146` bot ids start at `-1`. (d) `src/client/Controllers/State.luau:84` `State.isBot`. (e) `src/client/Controllers/FxController.luau:196` `characterRoot`. (f) `src/server/Services/RunDirector.luau:1532` accepts bot ids in `[-1000000, -1]`. (g) Docs: `docs/ARCHITECTURE.md` "Team F" and `docs/HANDOFF.md` §3.4 define bots as "−1, −2 …". | (a) Studio humans count 0.6 for spawn pressure. (b) Humans are flagged `isBot` in `getPlayers()`. (c) Bot ids share the band with Studio players; `fill` skips the party's ids, but any other code using `isBotId` misclassifies humans. (d) Every human in Studio gets the "🤖 Bot ·" tag in the party HUD and lobby. LobbyUI:577 ignores their Ready, so it shows "Auto-start in" instead of "Starting in". (e) Character-anchored FX (down, revive, ability) look for a bot model and find none, so they are not drawn for Studio humans. (f) Too wide: it accepts the human band. | Use one shared helper with a disjoint bot band. *Working tree* adds `src/shared/Util/Ids.luau` (`BOT_BASE = -1000`, `isBot(id) = id <= -1000`) and moves (a)–(e) to it. Still needed: change RunDirector:1532 to `Ids.isBot(spec.id)`, and update ARCHITECTURE/HANDOFF to "bots ≤ −1001". `DataService.isRealPlayer` (UserId > 0 or Studio) and LeaderboardService:128/186 (skip ≤ 0, so no Studio writes) are already correct. |
| 3 | **Major** | `src/server/Services/RunDirector.luau:1067-1068` (`onRerollUpgrade` → `rollOffer`, `:564-565`), against `src/client/Controllers/State.luau:270-287` and `src/client/UI/UpgradeUI.luau:153-160` | A reroll gets a **new offerId**, but the client only replaces cards when the offerId is the same. The reroll result is appended behind the old offer, and the UI keeps showing the old cards (`offers[1]`). The next pick sends the stale id. The server rejects it ("stale or unknown offer"), while the client already removed it optimistically, so the pick is lost and the rerolled cards only appear then. The free reroll or the paid **reroll token** is spent for nothing visible, and one level-up pick is silently lost. | Server: `pr.offer = nil; rollOffer(c, pr)`, which does `c.nextOfferId += 1; pr.offer = { offerId = c.nextOfferId, ... }`. Client: `if existing.offerId == entry.offerId then q[i] = entry -- reroll result for the same offer ... else table.insert(q, entry)`. | Server, preferred: on reroll keep the id. Roll the cards and set `pr.offer = { offerId = offer.offerId, cards = cards }`, then `sendOffer`. Or have the client drop any offer older than an incoming one, since the server only ever has one live offer. |
| 4 | **Major** | `src/client/Controllers/FxController.luau:820` (handler table), against `src/shared/Combat/World.luau:994` and `:1030` | Fx `zone` events are emitted but never rendered. Hostile damage zones are invisible: boss puddles (`BossPatterns:1383`) and dash trail zones (`World._trailZone`), which tick damage. Player puddle and field zones are invisible too. Players take damage from areas they cannot see. | World emits `{t="zone", id, kind, x, z, r, ttl, owner?, follow?, hostile?}` (COMBAT-API "Additional events"). The `handlers` table has no `zone` key, and the dispatcher silently ignores unknown `t`. Also unhandled: `strike`, `dash`, `leap`, `blink`, `adapt`, `surge` (cosmetic; the boss position still arrives by snapshot). | Add a `zone` handler: a pooled flat cylinder of radius `r` for `ttl` seconds, red when `hostile`, otherwise class colour. Follow `owner` when `follow`. At least add a `strike` flash. Add a test that every `t` emitted in `Combat/*` has a client handler. *Working tree:* still missing. |
| 5 | Minor | RunDirector:1695 (`onPlayerRemoving`) | When a human leaves, `run:setPlayerCount` is updated but the live world keeps its old mods until the next stage. A 2-human party where one leaves keeps 2-player HP and spawn scaling for the rest of the stage. | `setPlayerCount` only changes `RunState.playerCount`; `world:setMods` is never called. | After `setPlayerCount`: `if c.world then c.world:setMods(c.run:worldMods()) end`. Note that `setMods` also re-scales spawns via `wave:setMods`. |
| 6 | Minor | `src/client/UI/ResultsUI.luau:96-104`, against LobbyService:687-699 and `:643-654` | "Play Again" only closes the panel. It never sends `SetReady(true)`, so LobbyService's "Ready during Results comes back readied" path cannot be reached. Every solo player waits for the 30 s auto-start, which can fire while the Results overlay is still open. | Client: `State.set("results", nil)` only. Server: `onSetReady` → `e.playAgain = ready` (run member), and `returnToLobby` → `e.ready = e.playAgain`. | In the Play Again callback, also send `Remotes.fire(Remotes.C2S.SetReady, true)`. |
| 7 | Minor (design) | `src/shared/Bots/BotBrain.luau:71`, `:478` and `RunDirector:911-924` | With no human vote, each bot has a 15 % "surprise" vote for the next option. A solo player who does not vote gets **Double or Nothing** on about 15 % of bank votes (both bots surprise: 2.25 %; split vote: 25.5 % × ½ tie-break), and NextCycle instead of GoHome on cycle votes. This overrides the contract "no votes → default (Continue / Go Home)" in `Vote.lua` / GDD §3.1. | `chooseVote`: `if safe < n and rng:chance(VOTE_SURPRISE) then return safe + 1`. `Vote.resolve` returns `default` only when there are 0 votes, and bot votes count. | Bots should never pick a risky bank or cycle option without a human plurality. Apply the surprise only to `route` votes. |
| 8 | Minor | RunDirector:1652-1663 with `finishRun` :1449-1453 | Crash recovery: if `runLoop` errors **inside** `finishRun` part-way through the payout loop, the retry `finishRun(c)` returns at once (`c.awarded` is already true). Members after the crash point get no award and no Results. | `if c.awarded then return end; c.awarded = true` comes before the per-player loop; each player has its own `pr.awarded`. | Guard per player only. In `finishRun`, skip players with `pr.awarded` and drop the `c.awarded` early return, or make the payout loop `pcall` per player. |
| 9 | Minor | `CombatService.luau:238-246` with RunDirector:1349 | If `world:step` errors every frame (a bad pattern), CombatService warns and `break`s each frame. The world never advances, so the boss never dies and `allPlayersDown` never changes. The boss wait has **no deadline**, so the run hangs until every human leaves. | `if not ok then warn(...) break end`. `r = waitFor(c, nil, function() ... end)`. | Count consecutive step failures in CombatService (for example 30) and fire an `{type="fatal"}` event. RunDirector then treats it as a crash (wipe payout + teardown). Optionally add a generous boss timeout (for example 10 min). |
| 10 | Minor | RunDirector:1332 (wipe in Waves) → `finishRun` | After a wipe the world keeps stepping and **spawning waves** for the 8 s Results window, still sending Snapshot and Fx at full rate. Harmless to the outcome, but wasted bandwidth and enemy noise behind the Results screen. | `finishRun` never calls `world:stopSpawning()` or `stopCombat`. | At the start of `finishRun`: `if c.world then c.world:stopSpawning(); c.world:clearEnemies() end`. |
| 11 | Minor | RunDirector:1164-1179 | Token Second Wind: the world revive happens **before** the token is charged. If `DataService.update` fails (profile released or read-only), the revive is free. It is marked `usedToken`, so it is unranked, but no token is spent. | `if not world:useSecondWind(...) then return end` → `profileUpdate(...)` → `if not spent then warn(...); pr.tokens.usedToken = true end`. | Charge first: `profileUpdate` with `RunTokens.useSecondWind`, and only if `spent`, call `world:useSecondWind`. Refund (`profile.secondWindTokens += 1`) if the world refuses. |
| 12 | Minor | `src/client/Controllers/State.luau:213-224` | The Lobby payload fields `autoStart`, `botFillAny`, `botCount` and `playAgain` (LobbyService:479-514) are dropped by `State`, so the UI cannot show "bots: N" or "auto-start". | State copies only `players`, `startsAt`, `runActive` and `botFill`. | Pass the extra fields through, or drop them from the server payload. |
| 13 | Minor | `src/server/Services/CombatService.luau:115-127`, `:190-191` | Character state set for combat leaks into the lobby: `TrunkfallCombatReady`, `Downed` and `Spectator` attributes, Dead state disabled, regen script destroyed, and Humanoid Health possibly near 0.01. Nothing reads these yet. Also, `SetStateEnabled` on the server does not replicate to the owning client. | Set in `prepareCharacter` / `applyHumanoids` and never reset in `stop()`. | In `CombatService.stop()`, reset the attributes and set `Health = MaxHealth` for tracked characters. |
| 14 | Minor | `Remotes.snapshot` / `fx` via `FireAllClients` (CombatService:214, :249) | Players who joined mid-run (lobby, not in the party) still receive every Snapshot and Fx for an arena 400 studs away. | `snapshotRemote:FireAllClients(buf)`. | Send to `tracked` only (`FireClient` loop), or accept the cost knowingly. |
| 15 | Minor (economy) | LobbyService auto-start (`AUTO_START_SECONDS = 30`) with bots | An idle (AFK) solo player is auto-started into runs indefinitely, and bots can carry. With the safe default votes (route Low, Continue, then GoHome at stage 4 → `outcome = "Win"`, all pending banked), an AFK player can farm cheese. Roblox's 20-minute idle kick limits it, but anti-AFK tools exist. | `armCountdown(AUTO_START_SECONDS, "auto")` whenever `nReady == 0`; the run ends only when all humans leave. | After one auto-started run with no input from the human, stop auto-starting until they press Ready. Or pay nothing if the human dealt no damage and cast no vote. Testing team: measure whether 2 bots alone can clear stage 1. |

## Verified OK

### Cross-module calls (signatures and return shapes match)

- **RunDirector → RunState:**
  - `new(seed, pc, {bossIds, mapIds})`, `openRouteVote` (idempotent in RouteVote), `chooseRoute`, `getStageSeed`, `worldMods`, `startBoss`, `bossDefeated`, `openBankVote`, `chooseBank`, `wipe`, `finalRewards`, `setPlayerCount`, `getPublic`.
  - `CONFIG.WIPE_KEEP_FRAC`, plus the raw fields `pendingCheese`, `bankedCheese`, `doubleOrNothing` and `xpEarned` used by `payLeaver`.
- **RunDirector → other Run modules:**
  - `Stats.compute(class, stacks, blessings, talents, talentDefs)`: 5th parameter, fed by `Talents.defs` `{perLevel}`.
  - `Leveling.addXp` (3 returns) and `xpToNext`.
  - `UpgradeOffers.roll(rng, class, stacks, luck, n)`.
  - `Vote.new/cast/tally/resolve/removeVoter`: negative bot voter ids work.
- **RunDirector → World:**
  - `new{rng, mods, arenaRadius, obstacles, enemyPool, cycle, stage}`.
  - Player calls: `addPlayer`, `removePlayer`, `updatePlayer`, `useAbility(id, x, z, now)`, `useSecondWind`, `healPlayer`.
  - Waves and boss: `startWaves`, `stopSpawning`, `clearEnemies`, `spawnBoss`, `respawnDead`, `setStage`.
  - Queries: `getPlayer` (all fields used exist, including `secondWindUsed`), `allPlayersDown`, `bossAlive`, `bossInfo.hpFrac`, `drainEvents`.
  - Event `type` values match `WorldEvent`.
- **RunDirector → services:**
  - CombatService: `start(world, players)`, `stop`, `events:Connect` (a table signal with one event per Fire, handled by `onCombatEvents`), `now`, `getWorld`.
  - ArenaBuilder: `build(mapId, seed)` → `{model, obstacles, spawn, radius, center}`, and `clear`.
  - BotService: `spawnForRun(specs, nil, nil, seed)`, `setWorld(w, arena)`, `despawnAll`.
  - BotBrain: `chooseUpgrade(cards, rng)` (0 when there are no cards; guarded), `chooseVote(kind, options, tally, rng)`.
  - RunTokens: `new`, `useSecondWind`, `secondWindsAvailable`, `rerollsAvailable`, `useReroll`.
  - DataService: `get`, `update`, `push`, `awardRun(p, cheese, xp, {won, cycle, bosses, cycle1Time, ranked, day})` matching `Award.applyRun`, `beforeRelease`, `isRealPlayer`.
  - MonetizationService: `cheeseMult`, `xpMult`.
  - Config: `Bosses.ORDER`, `Maps.ORDER/get`, `Modifiers.get`.
- **LobbyService:**
  - → BotRoster: `fill(h, max, min, takenClasses, rng, takenIds)`, matching the 6-parameter signature.
  - → BotService: `placeInLobby(specs, positions, lookAt)`.
  - → Classes: `ORDER`, `DEFAULT_ID`, `get`, `unlockCost`.
  - → DataService: `get`, `waitFor`, `update`.
  - `onStart` callback `(players, classes[UserId], bots)` matches `startRun`.
- **Main.server:**
  - Inits the D services, then `LobbyService.init()` and `RunDirector.init()`. All exist and are idempotent.
  - BotService needs no `init`.
- **ShopService:**
  - → Data and Config: `Data/Shop.parse/buy/equip`, `Daily.claim(profile, day, {vip})` → `{day, granted}`, `Config/Shop.list/classes/BUNDLES/MAX_ITEM_ID_LEN`, `Talents.get`, `Cosmetics.get`.
  - → services: `MonetizationService.isClubMember/refreshClub/hasPass`, `DataService.isReadOnly/save/today`.
- **Client:**
  - `SnapshotCodec.decode` (4 returns, chunked frames merged).
  - `Defs` (tolerant of `ORDER` + `defs/get`).
  - `Defs.products()` reads `Monetization.ALL`, and `Config/Shop.list()` item ids match `Shop.parse`, including `cosmetic:<id>:golden`.

### Net payloads

Server → client:
- **RunState:** PublicRunState plus `phaseEndsAt`.
- **PlayerHud:** every field the HUD and InputController read is present (`secondWinds`, `secondWindReady`, `downedUntil`, `abilityReadyAt` on the `GetServerTimeNow` base).
- **PartyHud and Lobby:** use `tostring(id)` keys, normalised by `Format.numericKeys`; negative keys parse.
- **VoteOpen:** `{kind, options, endsAt}`; RouteCard fields and bank option strings match VoteUI.
- **VoteTally:** a dense array.
- **VoteClosed:** a number.
- **UpgradeOffer:** `{offerId, cards, rerollsLeft, queued}`; UpgradeDefs are plain tables, safe to send over a remote.
- **Results:** fields match ResultsUI.
- **Profile:** `ProfileSchema.view` plus the Monetization decorator.
- **Toast:** `(text, kind)`.
- **Snapshot:** an `UnreliableRemoteEvent` carrying chunks of at most 850 B.

Client → server (argument counts and types match each `Guard.connect` spec):

| Remote | Arguments |
|---|---|
| Vote | int |
| ChooseUpgrade | int, int |
| RerollUpgrade | int |
| UseAbility | number, number |
| UseSecondWind | none |
| SelectClass | string ≤ 32 |
| SetReady, SetBotFill | boolean |
| BuyShopItem | string ≤ 64 |
| Equip | enum, optional string (a trailing nil is fine) |
| ClaimDaily | none |
| PromptProduct | string ≤ 32 |

### Roblox API and Rojo

- No deprecated globals: no `wait`, `spawn`, `delay` or `tick`, and no `Instance.new(…, parent)`.
- ScreenGuis set `ResetOnSpawn = false` and parent to `PlayerGui` via `WaitForChild`.
- `UnreliableRemoteEvent` is created with `Instance.new`.
- `Main.server.luau` becomes a Script and `Main.client.luau` a LocalScript; module files map to ModuleScripts.
- Clients wait for `Shared`, `Remotes` and each remote with `WaitForChild`.
- `BindToClose`: DataService releases sessions, and RunDirector's `payLeaver` (`beforeRelease`) pays the wipe-rule share on shutdown.

### Logic walk-through (1 human + 2 bots)

1. **Join:** a 30 s auto-start countdown arms, and BotRoster places 2 bots on the pad (ids avoid the party's UserIds).
2. **Ready:** the countdown drops to 5 s.
3. **Start:** `fireStart` → `startRun`. `setRunActive(true)` runs before any yield. The lobby bot models are reused by `spawnForRun`.
4. **Route vote:** it closes as soon as the human votes, or after 15 s.
5. **Stage setup:** the arena is built, the human is teleported, and humans and bots are added to the world.
6. **Waves (150 s):** the wipe grace is 1.5 s, or 5 s while a Second Wind is still usable.
7. **Boss** → **StageClear** (4 s) → **bank vote** → next stage, or Results.
8. **Results** (8 s): `finishRun`.
9. **Teardown:** bots are despawned before `setRunActive(false)` re-places the lobby bots, then the RunState goes back to "Lobby".

No double payout:

- `pr.awarded` is set before `awardRun`.
- A leaver is paid once, by `payLeaver` via `departed` or the live member, whichever PlayerRemoving handler runs first.
- `awardRun`'s extra `save` and the release save are serialised by `s.saving`.

No per-run connection leaks:

- CombatService disconnects its Heartbeat and PlayerRemoving connections in `stop()`.
- The BotService Heartbeat and the RunDirector `hudLoop` are each created once.
- `ArenaBuilder.clear()` runs every stage and at teardown.
