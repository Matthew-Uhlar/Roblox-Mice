# v2 QC A: integration and gameplay

_Reviewer: v2 QC A (report only). Branch `claude/focused-gates-jihpzi`, working tree as of 2026-11-04, including the uncommitted fix-round changes. Nothing in `src/` was edited._

## Scope and evidence

- **Docs read:** AGENTS.md, GDD-v2, ARCHITECTURE-v2, COMBAT-API (v2 part), HANDOFF and `tests/runtime/README.md`.
- **Contracts traced:**
  - every S2C payload: RunDirector / Remotes against `Controllers/State` and its UIs;
  - every C2S remote: client `Remotes.fire` against the `Guard.connect` specs and the handlers;
  - the RunDirector calls into World, MatchState, Gear, Stats, ClassProgress, BotService, ArenaBuilder, LightingService, HeroDecor and LobbyService.
- **Run:** `scripts/test.sh Runtime`. All 9 runtime specs pass, with zero errors and zero gaps.
- **Scratch harnesses** are in `/tmp/claude-0/-home-user/62ecd08e-82c1-5cab-a26b-5e0b2b23913e/scratchpad/qcA/`. Each builds on the real emulator:
  - `count.luau` builds all 9 arenas × 3 seeds and counts parts, emitters, lights and BillboardGuis;
  - `leak.luau` rebuilds arenas and checks for leftover instances and terrain state;
  - `bw.luau` plays solo + 11 bots for 120 s of waves and measures netStats per remote;
  - `ks.luau` exercises the client kill-streak logic.

**Summary:** 0 Blockers, 4 Majors, 8 Minors. Two of the Majors are real-runtime problems that the scenario specs never reach:

- the ocean map's terrain;
- the loot bags, which are invisible in the world.

---

## Major

### M1. The ocean map uses a non-terrain material and turns terrain off for the rest of the server's life

- **Where:**
  - `src/server/Services/ArenaBuilder.luau:389-390`: the `ocean` theme sets `patches = { M.Ground, M.Pebble, M.Salt }` and `path = M.Pebble`.
  - `src/server/Visuals/Terra.luau:38-47`: the `guard` sets a sticky `failed = true`.
- **Evidence:**
  - `count.luau` / `leak.luau`, building `ocean`, warn: `[Terra] terrain FillCylinder failed; terrain dressing disabled for this server: FillCylinder: Enum.Material.Pebble is not a valid terrain material`.
  - `Pebble` is a Part material. It is not a Terrain material: the emulator's whitelist (`tests/runtime/Classes.luau:628`) matches Roblox's 22 terrain materials.
  - After the failure, the *next* arena build (plains) makes **0** terrain calls (fills stay at 124). Even `clearBox` is a no-op because `get()` returns nil once `failed` is set.
  - So the ocean's half-built terrain stays (bedrock, sand floor and water ring; cliffs never built). Every later stage on that server is drawn over it, and `Terra.ok()` is false, so ArenaBuilder also turns its flat `Floor` part visible, inside the leftover terrain.
  - The runtime scenarios never route to ocean, so `assertClean` never sees the warning.
- **Real Roblox:** Fill* with a non-terrain material is rejected. The emulator models that error; confirm the exact message in Studio. Even if Roblox ignored the material instead, the path and patches would silently not paint.
- **Fix:**
  1. Replace `M.Pebble` with a terrain material on lines 389–390 (e.g. `M.Cobblestone`, `M.Slate` or `M.Limestone`).
  2. Don't make Terra's failure sticky for `clearBox` (always try the Air clear), or validate theme materials once at load time.
  3. Add a spec that builds all 9 maps in the emulator and asserts `rt:assertClean` (the `count.luau` loop is enough).

### M2. Loot bags and dropped gear have no in-world visual

- **Where:**
  - `src/client/Controllers/FxController.luau:2001-2070` (handlers table);
  - `src/client/UI/MinimapUI.luau:300-326`;
  - `tests/specs/ClientLayout.spec.luau:84-90`.
- **Server side:** World emits Fx `bag` (`World.luau:2732`, `{id, x, z, n, cheese}`), `bagProgress`, `bagGone`, `gear` and `gearGone`, and FxFilter always sends them (`FxFilter.luau:56-62`).
- **Client side:**
  - FxController has no `bag` / `bagGone` / `gearGone` handler.
  - `gear` only plays a one-off glint burst (`FxController.luau:2023-2027`).
  - The only lasting representation is a minimap dot (MinimapUI), plus "Looting bag…" in the HUD once you are already channelling (HudUI:1029-1032).
  - No server code builds a bag or ground-gear model either (grep finds none).
- **Impact:**
  - The core extraction-shooter loop (GDD-v2 §2: "Any squad can pick it up, channel 1.5 s") and §3 ("the dropped item stays on the ground") are invisible in 3D. Players stumble onto bags and gear by accident.
  - RuntimeSquads/Gate report "bags dropped 3 / picked 0".
  - The Fx-coverage spec counts MinimapUI's `t == "bag"` as "handled", which hides the gap.
- **Fix:**
  - Add pooled FxController visuals keyed by id:
    - a bag model (sack + glow + small BillboardGui "🧀 N + gear×n") on `bag`, removed on `bagGone`;
    - a rarity-coloured item marker on `gear`, removed on `gearGone`.
  - Use `bagProgress` for a channel ring.
  - Make the coverage spec require these kinds in FxController itself.

### M3. The Shop Cart client and server disagree on the balance and on the sold state

- **Where:**
  - server: `RunDirector.luau:1312-1328` (`sendCart`) and `:2558` (`buyCart`);
  - client: `State.luau:916-925` and `ShopCartUI.luau:27-33, 193-205, 230-246`.
- **Balance:**
  - The server charges the hero's **own share**: `if c.match:shareOf(h.id) < price then return false, "funds"`.
  - The UI shows and enables buttons against the **squad pot** (`pot()` = `State.squad(mySquad).pending`, the sum of 3 shares): "Squad pot: 🧀 N pending", `Theme.setEnabled(r.buy, have >= price)`.
  - Result: with 3 members, a purchase the UI enables often fails with "Not enough pending cheese for that."
  - The server already sends `share` in the payload, but the client ignores it.
- **Sold state:**
  - The server sends `bought = cart.bought`. The client only reads `c.sold` and otherwise reuses `prev.sold`.
  - After a successful buy, the fresh ShopCart reuses the optimistic `"pending"` marker. The 3 s "Buying…" timeout then clears it (`cur.sold[i] = nil`), so a **bought item turns buyable again** after 3 s.
  - Items a squad-mate bought never show as sold.
- **Fix:**
  - Client: read `c.bought` (or `c.sold`) as the authority, and show and compare against `tonumber(c.share)`. Word the label as "your share".
  - Or the server can spend from the squad pot. Either way, pick one owner and document it in ARCHITECTURE-v2's ShopCart row, which today lists only `{poi, offers, prices}`.

### M4. The client shows bounties the server never granted

- **Where:**
  - client: `src/client/Util/KillStreaks.luau:27-31` (`COUNTS` includes `down`), merged into `State.hasBounty` / `State.bountyHolders` at `State.luau:337-371`;
  - server: `MatchState.luau:784-819`, where only `heroKilled` adds to the streak (3 kills).
- **Evidence:**
  - For each PvP kill the server sends a `down` entry and then a `kill` entry (`RunDirector.onHeroDowned` / `onHeroKilled`).
  - `ks.luau` result: after 1 kill (count 2) and one more down (count 3), `KillStreaks.push` returns a new bounty. The server has 1 kill and no bounty.
  - The client resets the victim's streak on a `down`. The server resets it only on death or a bounty claim.
- **Impact:** a "BOUNTY!" banner and markers on the wrong heroes. Players hunt targets worth nothing, and the server's real `bounty` / `Match.bounties` signals get drowned out.
- **Fix:** when `State.isSquadMatch()`, use only the server's `Match.bounties` and the `bounty` / `bountyClaimed` entries. Or at least count only `kind == "kill"` and reset only on `kill`.

---

## Minor

1. **Blessing toast goes to the boss winner, not the squad that got the blessing.**
   - `RunDirector.luau:3162` toasts `winner`.
   - `MatchState.bossDefeated` grants `reward.blessingId` to `chooserSquad`, or to every squad on stage 1.
   - Fix: toast `match.chooserSquad` (expose it), or everyone on stage 1.
2. **Extract card overstates the payout.**
   - `ExtractUI.luau:49` "Bank 🧀 X (100% of the pot)" shows the squad pot. Each member banks only their share × extractMult, so Results then show about a third of it.
   - After an extraction, `MatchState.getPublic` shows `pending = 0` for the extracted squad: shares are zeroed in `bankShare`. `Scoreboard.less`'s comment ("for extracted squads: what they banked") is therefore wrong, and extracted squads sort as if empty.
   - Fix: show your share from the Extract payload's `share`, and add a `banked` field per squad.
3. **Doubled bot tag.**
   - BotRoster names already end in " 🤖" (`BotRoster.luau:387,489`).
   - `State.nameOf` (`State.luau:324`) and `ScoreboardUI.luau:271` prepend another "🤖 ", giving "🤖 Name 🤖". Cosmetic only; bots are still labelled.
4. **Respec spends a Robux token automatically.**
   - `PerkTreeUI.luau:436` sends `"token"` whenever `respecTokens > 0`, and `ClassProgress.resetPerks` defaults to the same.
   - Owners can't choose to pay cheese instead. This doesn't break the policy, but offer both buttons.
5. **Lighting is applied twice per stage.**
   - `ArenaBuilder.build` calls `applyMood(id)` (`:921`), then `RunDirector.buildStage` calls `applyLighting(card.mapId)` (`:2947`).
   - Harmless unless LightingService tweens. Drop one.
6. **Extracted humans wait for the whole match.**
   - After an extraction, `handleOut` → `LobbyService.leaveRun` puts the player back in the lobby. But `startRun` refuses while `ctx` exists, so they can't queue a new run until the remaining squads finish (up to ~3 stages, about 10+ minutes).
   - This is a design consequence of one match per server. The lobby should say so, and a TeleportService "find a new server" button would be the real fix.
7. **Part budget.** See the Performance section: jungle and moon arenas exceed 3,000 parts before characters and the horde.
8. **Enemy "💫 DOWN!" tags are dropped within ~0.5 s.**
   - The PartyHud subscription (`FxController.luau:2606`) removes every down tag whose id is not in PartyHud, which is own-squad only. The tag's text ("Stand close to revive") is wrong for enemies anyway.
   - Make it explicit: only create tags for own-squad ids, and give enemies a distinct "finish them" marker if wanted.

---

## Performance (mobile)

### Server-built arena (emulator, `count.luau`, seed 1; parts = BaseParts under `workspace.Arena`)

| Map | R | Parts | of which Decor | DecorFar | Core | Emitters (rate/s) | Lights | Billboards |
|---|---|---|---|---|---|---|---|---|
| plains | 140 | 2,645 | 982 | 436 | 1,227 | 20 (186) | 20 | 10 |
| forest | 130 | 2,970 | 790 | 376 | 1,804 | 17 (162) | 24 | 10 |
| jungle | 130 | **3,322** | 963 | 444 | 1,915 | 23 (209) | 20 | 11 |
| beach | 150 | 2,478 | 779 | 653 | 1,046 | 14 (140) | 21 | 9 |
| tundra | 140 | 2,354 | 445 | 540 | 1,369 | 14 (140) | 24 | 9 |
| volcano | 130 | 2,480 | 564 | 478 | 1,438 | **57** (246) | **55** | 10 |
| swamp | 125 | 2,689 | 964 | 359 | 1,366 | 16 (160) | 41 | 12 |
| moon | 160 | **3,383** | 1,749 | 622 | 1,012 | 13 (131) | 24 | 8 |
| ocean | 135 | 2,565 | 756 | 454 | 1,355 | 66 (229) | 21 | 11 |

**What this means:**

- **Totals:**
  - The lobby adds **1,573** parts that stay loaded at Z = −400 during the whole run.
  - In the solo run, the client's whole workspace held **7,263** BaseParts:
    - arena + lobby;
    - 11 bot models and the characters;
    - the HordeRenderer pool, 2,029 parts with 643 shown.
- **Low tier:** hiding Decor and DecorFar brings each arena down to about 1,000–1,900 core parts, which is fine.
- **Mid tier** keeps decor. Jungle (3.3k) and moon (3.4k) are over the GDD's 3,000 "in view" budget only if the whole arena is in view; at top-down zoom about half is.
- **Risks:**
  - 50+ PointLights on volcano and swamp under Future lighting on phones. Shadows from many lights are the classic mobile killer; check `Build.light` sets `Shadows = false`.
  - About 230 particles/s per arena, before combat Fx.
- **Suggestions:**
  - Parent the lobby island to ServerStorage (or `Parent = nil` on the client) while a run is active.
  - Cap mid-tier decor at about 600 parts.
  - Turn off Shadows on decorative lights; volcano and ocean add many.
- **No leaks:** after 27 rebuilds only `workspace.Arena` changed (`leak.luau`). Portal, POI and decor models all live under the Arena model and die with it.

### Bandwidth (emulator JSON-size proxy, `bw.luau`, solo + 11 bots, 120 s of waves, phase stayed Waves)

| Remote | KB/s |
|---|---|
| Fx | 5.52 |
| Snapshot | 2.81 |
| PlayerHud | 0.41 |
| PartyHud | 0.35 |
| Match | 0.25 |
| **Total S2C** | **9.38** |

- PerfWorld's 13–15 KB/s is the Fx-only worst case: 12 heroes clustered, at the 220-mice cap. Add Snapshot: CombatService says about 20 KB/s at the 220 cap before `SNAPSHOT_RADIUS` culling.
- The realistic worst case per client is therefore about **30–35 KB/s**, not 13–15. That is acceptable for Roblox, but measure it in Studio's Network stats with 4+ real clients in one corner.
- Highlights:
  - up to 9 enemy SquadHighlights enabled, plus 1 Tint Highlight per human with a tint (≤ 12), so ≤ 21 enabled, under the 31 cap;
  - own-squad Highlights stay `Enabled = false`;
  - a character can carry both a Tint and a SquadHighlight. How the two overlap needs a Studio look.

---

## Emulator blind spots (explicitly unverified)

- **Terrain:** fills are recorded, not voxelised; reads return Air.
  - Real replication of a ~480×480 terrain rebuild every stage (32 Air chunks + ~120 fills, about 34 M voxel-volume per 27 builds, roughly 1.3 M per build) to every client. Watch for a stage-start hitch and a bandwidth spike.
  - Whether `FillCylinder` / `FillWedge` give the intended smooth shapes.
- **Highlight:** the 31 cap, and overlapping Highlights on one adornee.
- **BillboardGui:** rendering cost with `AlwaysOnTop` (damage numbers pool up to `CAP.hit`; 10–12 POI labels; 11 bot tags; 12 nameplates).
- **InsertService** (`Visuals/AssetLoader.luau:76`):
  - `LoadAsset` only works for assets owned by the place's creator (user vs group must match).
  - The single-child `Model` unwrap assumes the import shape.
  - `Config/AssetIds` is `{}` today, so none of this path is exercised.
- **CornerWedgePart / Trail / welds:**
  - Properties are reflection-checked, but nothing is rendered.
  - HeroDecor welds to avatar parts at the current pose (`C0 = anchor.CFrame:ToObjectSpace(p.CFrame)`). Correct maths, but R6, R15 and Rthro head sizes need a look.
- **Physics and client network ownership:** a client-local `Destroy` or `Parent` change applies globally in the emulator.
- **Real remote ordering and packet loss:** the client tolerates a missing `Extract` close (2 s timeout) and stale ShopCart updates (see M3).

---

## Verified OK

- **C2S remotes, all 21: the client sends exactly what Guard accepts.**
  - `ExtractVote`: an enum of `MatchState.CHOICES`.
  - `SwapGear(bool)`: true = take new, consistently through `RunDirector.onSwapGear`, `World.resolveSwap(id, takeNew)`, the bot path and the 4 s timeout (false = keep).
  - `BuyCartItem(int, int 1..8)`.
  - `SelectPerk(str, str)`, `ResetPerks(str, enum?)`, `SelectAbility(str, str?)`, `SelectSkin(str, str?)`: the client sends nil for base/default, which the optional validators accept.
  - `SetPressure(str, number)`, plus the v1 remotes.
  - Every handler re-checks phase, membership and offered state.
- **S2C payloads match what the client reads:**
  - **Match**: `squads[1..4]` with `members` as numbers (bots negative), `alive` bool + `aliveCount`, a `bounties` array, `routeChooser` only in RouteChoice. Scoreboard and State tolerate string keys.
  - **KillFeed**: kinds `down, kill, bounty, bountyClaimed, eliminated, extracted, lastHerd` all have icons and text.
  - **Inventory**: slots and `swapOffer.endsAt`.
  - **Extract**: `votes` keyed by choice name, `yourChoice`.
  - **Lobby**: string-keyed players, squads, yourSquad.
  - **Results**: result, placement, classXp, stage = `outStageOf`.
  - **Profile.classes**: `ClassProgress.view` gives exactly the fields `State.classState` expects.
- **RunDirector → module calls match their signatures:**
  - `World.new{…, safeZones, tier}`, `addPlayer(..., squad)` as the 7th argument, `setGear`, `giveGear → (ok, swap)`, `resolveSwap`, `gearOf`, `addBagCheese`, `addLootBag`, `bossDamageBySquad → (tbl, top)`, `extractBonusOf`, `setPortal`.
  - `MatchState.*` phase methods are called in the right order (begin → startBoss → bossDefeated → chooseRoute → resolveExtraction).
  - `Stats.compute(..., classState)` is followed by `Gear.apply(stats, weapon, ability, items)`.
  - `ClassProgress.classState` / `skinFor` / `autoSpec` / `runXp`.
  - `ArenaBuilder.build(mapId, seed, {pois})` returns `squadSpawns` and `safeZones`.
  - `LightingService.apply(id | "lobby")`, `HeroDecor.apply(char, classId, skin, squad)`, `BotService.spawnForRun(specs, arena, world, seed)`.
  - The LobbyService APIs used (`teleportCharacter`, `leaveRun`, `returnToLobby`, `setRunActive`, `isRunMember`, `onStart`) all exist.
  - CombatService.events is a plain Lua Signal: no Bindable table-copy loss for `damageBySquad`.
- **GDD-v2 §1–5 rules:**
  - **Boss and route:** the killer squad (if still in the run), else the top-damage squad, picks the route. VoteOpen goes only to that squad's humans, and its bots follow. Nobody won → the Low card after 2 s.
  - **Extraction:** Extract banks share × extractMult (Portal Charm via `updateExtractMults` before resolve and before the final stage). Default Stay. DoN needs a human vote (`Vote.riskyIndices`) and grows ×1.5 at the next stage clear, or banks 0 if the squad is eliminated or leaves.
  - **Brave and Last Herd:** brave ×1.25 with ≥ 2 squads extracted. Last Herd after 2 alone stages: ×1.5, extracted, the match ends. Stage 4 survivors auto-extract.
  - **Wiped squads:** `eliminateFallen` runs right before `resolveExtraction`, and `gateOver` keeps the wipe check running during RouteChoice and Extraction. RuntimeSquadsGate covers it.
  - **Loot bag cheese** is 30% of the victim's share, split over the picker's squad. Unclaimed bags die at the next `_startStage`.
  - **Gear** carries across stages (`syncGear` → `setGear`) and is lost at run end. RuntimeSquads checks it is gone in the next run.
  - **Class XP:** `ClassProgress.runXp(summary)`, ×1.5 when extracted, awarded in `DataService.awardRun` (never multiplied by Robux boosts). Perks and the alternate ability are captured once at run start and applied through `Stats.compute`. Bots get `autoSpec` perks near the humans' average level.
  - **No friendly fire:** RuntimeSquads/Gate show "friendly 0". Revives are squad-only.
  - **Bots:** ids ≤ −1001, labelled "🤖 BOT" on models and names, and `isHuman` / `DataService.isRealPlayer` gate every award, profile write and epic drop.
- **Leaving:** the leaver keeps 50% (0 on DoN), paid once through `beforeRelease`. `pr.awarded` is set before `awardRun`.
- **Lifecycle:**
  - ScreenGuis via `Theme.screen` and the fade GUI use `ResetOnSpawn = false`.
  - FxController pools projectile parts with Trails (`Clear` on reuse) and damage numbers (capped).
  - `clearWorld` runs on every non-combat phase.
- **Tests:** `scripts/test.sh Runtime` passes 9/9 (Boot, Immediate, Leave, Purchase, Solo, Squads, SquadsGate, Studio, Veteran).
