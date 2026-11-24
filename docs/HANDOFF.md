# HANDOFF — read this first (Codex or any agent continuing the work)

> Living document, updated after every major step. If you are an AI agent
> picking this up (e.g. Codex after a Claude usage limit), read this file top
> to bottom, then `docs/GDD.md` and `docs/ARCHITECTURE.md`, before changing
> anything. Before you stop, update **Status**, **Next steps** and the
> **Log**, then commit and push.

_Last updated: 2026-11-20. **LIVE: iterations 1 + 2** (publish run 44670602226; smoke test passed), adding Zombie World Liberty alignment: difficulty ladder, numbered waves + Early Horn, Prestige/Ascension, Cheese Gems, 30 Challenges, run economy, Herd Suit, health bars, textured UI, music. **Iteration 3 in progress** (docs/ITERATIONS.md)._

## 1. What this is

**Trunkfall** (working title; other candidates: "Elephants vs Mice", "Double or
Cheese") is a Roblox co-op (1–4) top-down horde roguelike. Elephant heroes fight
swarms of mice across 9 cheese-themed maps, with 13 bosses, Low/Mid/High route
cards (curse + blessing), Double or Nothing banking and 4-map cycles. The source
concept is `docs/brainstorm-2026-06.md`, the team's June 2026 Confluence brainstorm.

- Repo: **github.com/Matthew-Uhlar/Roblox-Mice**.
  - `main` holds tested milestones only.
  - Day-to-day work goes on branch `claude/focused-gates-jihpzi`. Merge to `main` (via PR, or a fast-forward the owner approves) once `scripts/check.sh` passes.
- Owner: Matthew Uhlar.
- Owner directions so far:
  - Build the brainstorm game on Roblox with monetization.
  - Use multiple agent teams (research, dev, testing, QC) and keep quality high.
  - **Bots must fill every lobby so a lone player can always play.**
  - Keep everything in this repo, NOT in childcare-ops. That repo has been cleaned.
  - Keep a handoff for Codex.

## 2. Stack and tools

- Luau, `--!strict`.
- **Rojo 7** (`default.project.json`) for building and syncing the place.
- **Lune 0.11** runs unit tests outside Studio.
- **StyLua** (built with `--features luau`) for formatting.
- **Selene** (offline std `roblox_offline.yml`, because GitHub API-dump download is blocked in the cloud sandbox) for linting.
- Install them with:

  ```bash
  cargo install --locked rojo lune selene
  ```

  ```bash
  cargo install --locked stylua --features luau
  ```

- Quality gate:

  ```bash
  scripts/check.sh
  ```

  It runs the format check, lint, Luau compile of every file, all Lune specs and a Rojo build.
- Tests only:

  ```bash
  scripts/test.sh [filter]
  ```

## 3. Load-bearing rules (do not break)

1. **`src/shared` is pure Luau.**
   - No `game`, Instance, Vector3 or Color3, no `math.random`, no `os.clock`.
   - Requires between shared modules are **relative string requires** (`require("../Util/Rng")`), with no `init.luau` files.
   - The code must run under Lune. Roblox supports string requires, but **verify once on a live server** (launch checklist).
2. **Server authority.**
   - Enemies, projectiles, damage and rewards are simulated on the server as maths: `Combat/World.luau`, with no physics and no Humanoids for enemies.
   - Clients send only intents.
   - Every remote handler goes through `Services/Guard.luau` (`Guard.connect`).
3. **Monetization rules** (`docs/MONETIZATION.md`, `docs/research/monetization.md`):
   - No paid random items.
   - Robux never touch Double or Nothing or the Floating Witch "gamba".
   - Paid revives are capped (1 per stage) and grant no extra rewards.
   - ProcessReceipt is idempotent and session-locked (`MonetizationService`, `Data/Receipts`).
   - Never auto-prompt a purchase.
4. **Bots** use ids ≤ −1001 (`Util/Ids.luau`, `Ids.isBot`). Studio test players have UserIds −1…−8 and are humans.
   - They are clearly labelled 🤖 everywhere (Roblox policy: never pass bots off as real users).
   - They earn nothing, and every Data/Monetization call skips ids ≤ 0.
5. **Team file ownership** is in `docs/ARCHITECTURE.md`. Contracts there are the source of truth for cross-module APIs.

## 4. Status (what exists)

**Feature-complete against the brainstorm, and fully reviewed.** `scripts/check.sh` →
CHECK PASSED (55 spec files, lint/format clean, Rojo build OK; v2 final fix round 2026-11-04).

Nothing has run inside Roblox Studio yet. The real `src/server` and `src/client` scripts do run end to end in the headless runtime emulator (`tests/runtime/README.md`): boot, solo play through a full cycle, Studio −1 players, purchases, leaving mid-run, veteran/pass owners, and Immediate signals under lag. The next step is still a human play-test, for rendering, physics, feel and live services.

| Area | Key files | State |
|---|---|---|
| Design | `docs/GDD.md`, `docs/LORE.md`, `docs/STYLE.md`, `docs/brainstorm-2026-06.md` | done |
| Research | `docs/research/{market,monetization,tech}.md` | done (claims tagged *verify* still need checking) |
| Run & progression | `Config/{Classes,Upgrades,Modifiers,Maps}`, `Run/*` | done |
| Combat & horde | `Config/{Enemies,Bosses}`, `Combat/*`, `Services/{CombatService,ArenaBuilder}` | done; about 0.6 ms/step at 220 enemies; about 26 KB/s per client |
| Bots (solo play always works) | `Bots/*`, `Services/BotService`, `Util/Ids` | done: solo = 2 labelled bots, 5 s ready / 30 s auto-start (AFK cap) |
| Client & UX | `src/client/**` | done, compiles, mobile layout + text floor, **not play-tested** |
| Data & monetization | `Data/*`, `Config/{Monetization,Cosmetics,Talents,Shop}`, `Services/{Data,Monetization,Shop,Leaderboard,Cosmetics}Service` | done; asset ids still 0 (see step 3) |
| Pressure (GDD §3.7) | `Config/Pressure`, `Run/Pressure`, lobby board | done; sim win rates P0 100% / P10 83% / P21 58% |
| POIs and portals (GDD §3.8–3.9) | `Config/Pois`, `Combat/Pois`, ArenaBuilder, RunDirector, Fx | done; rare Pantry ~3%, Statue ~2% |
| QA | `docs/qa/` (QC1, QC2, TESTING, FINAL-A, FINAL-B) | every Blocker and Major fixed; open Minors listed below |
| Runtime emulator | `tests/runtime/*`, `tests/specs/Runtime*.spec.luau` | runs the real server + client scripts headless (Lune); 11 scenarios (incl. RuntimeArenas: all 9 maps; RuntimeV2Fixes), zero errors/gaps; see its README |

## 5. Next steps (in order)

**Standing owner instruction (2026-11-24):** keep iterating and publish after every major iteration. Each iteration adds more Zombie World Liberty features, new classes, better graphics (procedural meshes for everything, higher visual quality) and polish, then QC, full check, publish, report.


**Current (after iteration 6, live 2026-11-24, publish run 45382239813; iteration 7 in progress, docs/iter/7/PLAN.md):**
1. **Owner playtest of iteration 6:** Tinkerphant (builds), Normal/Fast pace, lobby votes + 60 s countdown, 7 abilities + slot 4 (C / D-pad left), talent trees + ascension effects, Gem Vault, Herd Pass screen + claim-all, animated icons, cosmetic try-on, elephant look in the lobby, menu readability (13 px), slower/pricier cheese.
2. **Iteration 7 (building):** 3 new classes (Ele Vation, Elephaid, Trunkillery), aim preview, game feel (hit-stop, shake, cast sounds), death recap, revive arrows/pings, talent presets, miniboss dust, gem tiers 13–14, animated procedural meshes for mice/bosses/champions (kill switch Config/Visuals.USE_MESHES, player setting Models: Detailed/Classic), class emblems. Profile v10.
3. **Needs Studio checks:** mesh import (pieces, texture vs flat tint, wheel spin, joints), camera twist direction, lobby suit while walking, preview showroom.
4. **Accepted:** maxed veteran clears Doomwheel ~83–92% (endgame); consider a tier above Doomwheel later.

**Older notes (v1–v3, kept for reference):**

1. **Studio play-test** (needs a human with Roblox Studio):
   - Run `rojo build -o build/Trunkfall.rbxlx` and open it.
   - Game Settings: Max Players 4, Studio Access to API Services on, StreamingEnabled off.
   - Delete the template Baseplate and SpawnLocation.
   - Play solo: 2 🤖 bots should join, and the auto-start should fire after 30 s.
   - Then test with 2–4 clients.
   - Check:
     - camera and controls on PC and in the phone emulator (667×375)
     - boss telegraphs, enrage and the portal fade
     - POI labels, shrine buffs and the Elite Camp chest
     - cosmetics (trail, hat, tint, nametag) and chat tags
     - Network stats against about 26 KB/s
   - Publish a private place and confirm that string `require("./X")` works on live servers.
2. **Balance pass with real players.** The sim's "human" is a bot. Tune with:
   - `Config/Pressure` (`perStage`)
   - `Stats.DIFFICULTY`
   - boss HP in `Config/Bosses`
   - MoveGuard thresholds, if live lag causes false positives. Emulator data: normal lag (150 ms ± 100 ms at 20 Hz) and replication freezes up to 0.6 s cause no violations. Freezes of 1.0 s cause about 1 snap-back each. Repeated 1.2 s freezes (about 6 per minute) make a run unranked after 10. Raising `MoveGuard.CARRY_SECONDS` trades this off against teleport detection.
3. **Creator Dashboard:** create the passes, products and subscription from `docs/MONETIZATION.md` and paste the ids into `src/shared/Config/Monetization.luau`. Complete the maturity questionnaire with the exact answers in `docs/publishing/SETUP.md` §5 (repeated cartoon violence against creatures AND other players' avatars, no blood; expect Mild, accept a higher label if the questionnaire says so) and set up ads eligibility. Create the GitHub Environment `roblox-production` with the `ROBLOX_API_KEY` secret (SETUP.md §4); the Roblox workflows now run only from `main`.
4. **Open Minors (nice to have):**
   - per-Pressure leaderboard and the title badges (`Pressure.badges()` exists)
   - no leaderboard server-to-client remote / UI yet
   - no guest mode during a DataStore outage
   - pass refunds are only revoked on the next join
   - no analytics events
   - localisation
   - Filet's passive is approximated with regen (`crumbHeal` exists in World but not in PlayerStats)
5. **Art and audio:** everything is built from Parts in code. Replace it with real meshes, animations and sound following `docs/STYLE.md`.
6. **Working title:** "Trunkfall" is a placeholder. Options are in `docs/research/market.md`.

## 6. Log (newest first)

- 2026-11-24: Iteration 6 published (run 45382239813): Tinkerphant builder class; pace; lobby votes/countdown; 7 abilities per class + 4th slot; talent trees (3x9, keystones) + visible ascension effects; Gem Vault; Herd Pass screen; animated icons (15 atlases uploaded); cosmetic try-on; lobby elephant look; readability pass; cheese x0.6 / upper prices x1.5 (owner kept Rush/Feast); balance targets all pass; profile v9; two QC reviews (1 lobby major, 4 combat majors) fixed.

- 2026-11-24: Hotfix 5.1 published (run 45310437583): PC right-drag camera rotation (cursor-position fallback + cursor lock while dragging), larger XP bar with caption, bottom HUD tiles on a self-sizing dock. Built on `main` in a separate worktree; iteration 6 continues on the branch.

- 2026-11-23: Iteration 5 published (docs/iter/5/PLAN.md, ZWL-GAPS.md).
  - Owner requests: no lobby auto start; rotatable camera; ability slots by class level (1 / L10 / L20, Prestige keeps all; slots 2–3 cooldown ×1.25).
  - Liberty gaps: damage meter, two-way Swap Stand, saved Effects/Decor settings, Whey and Crumb Totems, Quick Study rank, Rally Horn squad stall, Overtime (endless scaling waves after the final boss, best wave per tier), lifetime stats with time played.
  - Profile v8 (no-op migration from v7, so old servers open new saves read-only).
  - QC: Overtime blocker (in-run remotes gated off) and two majors (no way to leave; extract exploit) fixed; participation-gated Overtime pay.

- 2026-11-21: Iteration 4 published (docs/iter/4/PLAN.md).
  - Gems: 2 personal sockets; drops only on round completion; a guaranteed gem on each tier's first clear.
  - Liberty in-round strength: uncapped V-menu ranks (soft cap 100), fixed per-level gains, milestone cards every 5 levels.
  - Aim toggle (nearest/cursor) via `SetAimMode`/`AimAt`.
  - Maps ×1.35 with biomes, plateaus, rivers, bridges; beacon chain, rescue cage, caravan; 2–4 miniboss camps; MapBudget spec.
  - UI: new bottom dock, `ui2_` texture set (51 uploaded), pill/squircle buttons.
  - Bots: stage-1 calm 88 s, then hunt only all-bot squads; longer hunt range in stages 2–4.
  - First publish failed on a selene unused-variable warning (fixed in dfb2cac).

- 2026-11-20: Iterations 1 and 2 published together.
  - Plan: docs/iter/1/PLAN.md and docs/iter/2/PLAN.md, from the owner's Liberty save, decoded in docs/research/zwl-save-model.md.
  - Profile v7 migrates additively, with a pre-v7 backup that blocks saves until copied.
  - QC4 major (solo credit) fixed.
  - Balance: the ladder separates (Medium ≥70% clears, Doomwheel 0% for fresh squads); rinds about 12k per full run; idle about 31% (warning, sim stand-in).
  - Open: champions per stage below 2 (warning); the art/animation needs a Studio check.
  - Next: iteration 3 (playtest → verify → build → QC → publish).

- 2026-11-18: v4 QC done.
  - QC4 found 2 Majors and 7 Minors, all fixed: replaceSeat reset, PlayAgain caller-only plus invite, DoN on boss flee, leaver farming, rejoin seat, Herd Pass refund revoke, Emote Pack skipped in publish, season epoch moved to 2026-11-18, quests forward-only.
  - The final boss stall was knockback juggling it out of the storm circle; fixed with a knockback cap plus a zone pull.
  - Rival Herd plus Last Herd only at stage 4: 33% of sim matches now reach stage 4.
  - PvP time-to-kill revised to about 20 s (recorded in V4-PLAN).
  - Owner asked for Zombie World (SC2) style progression: research in docs/research/zombie-world.md, plan in docs/V5-PLAN.md.

- 2026-11-17: v4 build status. U (shop v2, Herd panel, HUD), P (profile v6, contracts, Herd Pass, new Robux items), G (audio, elephant hood, maps, storm wall, store art) and M2 (storm/redeploy/rival/rookie/awards/PlayAgain) are DONE. M2's run passed scripts/check.sh. Open: M1 combat balance. In the sim, 41/48 matches end in stage 1 and champions are too tanky; IntegrationSquads balance targets are temporarily warnings. Next: M1 balance → full QC round → fixes → publish. Lead hookups done: lobby 🔊 toggle, SETTING_KEYS music/sfx.

- 2026-11-16: v4 started. Owner request: bigger maps that shrink each stage, a storm pushing teams to the centre, research-driven features, a graphics upgrade, a progression fix and upgrade, and a Robux shop. Inputs: research (docs/research/v4-features.md) and three reviews (docs/qa/V4-A/B/C). Plan and contracts: docs/V4-PLAN.md. The v4 remotes are in Net. Build teams M1/M2/P/U/G are working on the branch. If you pick this up mid-build, run scripts/check.sh and carry on per V4-PLAN ownership.

- 2026-11-16: Published v3 as place v6 via run 43852889063. Smoke test passed. Balance to watch with real players: Pressure now mostly affects stages cleared, not win rate.
- 2026-11-16: **v3 client integration** (champions, sprint, budget). Minimap: champion markers (own icon per champion, gold and bigger for lairs, HP ring, kept on the rim), Champion Sites / Lairs, range scaled to the arena radius (`Minimap.rangeFor`, radius from Config/Maps by mapId), off-screen edge arrows for champions within 250 studs (pooled, 10 Hz). Kill feed "<killer> slew <Champion>" with a LAIR badge. HUD buff chips for `champ_might` / `champ_swift` stacks (server now sends `Match.buffs`). Fx: `rally` ring + mouse auras, tele styles `champIntro` (gold sigil) / `rally` / `chain`, hostile chain arcs as red Beams; sprint dust trail + a 3° FOV widen. Shorter champion toasts. `ArenaBuilder.PART_BUDGET` 3,300, so every map is ≤ 3,369 parts with the Rind Gate (RuntimeArenas now asserts ≤ 3,400); GDD-v2 §6 says 3,500. New specs in ClientV2 (Minimap v3, ChampView) and ClientLayout (champion Fx coverage). `scripts/check.sh` → CHECK PASSED.

- 2026-11-16: **v3 gameplay team: big maps + Mouse Champions** (owner play-test feedback; GDD-v2 §4a–4b, COMBAT-API "v3", ARCHITECTURE-v2 "v3 contracts"). `scripts/check.sh` → CHECK PASSED (56 specs).
  - Maps ×2.5 (radius 320–400), POI slots ×3 on three rings, obstacles ×2, scaled squad corners / safe zones (`Pois.squadCorners`; ArenaBuilder `USE_SHARED_CORNERS = true`), out-of-combat sprint ×1.3 (`Config/Maps.SPRINT`, `getPlayer().walkSpeed`), stray mice recycled beyond 160 studs, an obstacle bucket grid in World.
  - 6 Mouse Champions (`Config/Champions`, `Combat/Champions`, new BossPatterns bases rally / chain / evade), 6 sites + 1–2 lairs per map, rewards (gear per member, XP burst, pending cheese, stacking Champion's Might), `Match.champions`, KillFeed `champion`; bots hunt and contest champions.
  - Objectives: Elite Camps ×2 per slot (2 Rare+ items), up to 3 Totems (+20%) and Vaults (3 items, ×5 pot) per stage.
  - Sim (24 seeds; before → after): reach stage 3+ 50% → 54%, stage 4 33% → 33%, stage-1 eliminations 0.58 → 0.83, eliminations 1.42 → 1.62, first PvP down median 67 s → 55 s (stage 1), bot squads out alive 29% → 29%, champions killed 2.38 per stage (fight median 20 s). Pots ~1.7× bigger: bot `EXTRACT_POT` 220 → 260, the sim human's target 800 → 1400 (Pressure-scaled).
  - IntegrationPressure: win rates no longer separate the Pressure levels (6/7/7 of 16; PvP at champions decides most matches); the guard is now stages cleared (28/27/22) + cheese per stage (135/244/358). Worth a look in the live balance pass.
  - PerfWorld (350-stud map, 90 obstacles r 9–14, champions alive): 0.70 ms/step avg, p99.9 2.7 ms; Fx per client 6.8 KB/s avg.

- 2026-11-15: First live publish via GitHub Actions run 43763797915: place v5, serverSize 12, 17 passes/products synced (ids committed by the bot as cfcec21). Smoke test passed on a real Roblox server: 8/8 services ok, 39/39 remotes, string require works live, 0 errors. Workflows now accept the ROBLOX_* ids as variables or secrets.
- 2026-11-10: Final v2 fix round verified (CHECK PASSED, 55 specs). Fast-forwarded `main`. Publishing waits on the owner: experience, API key, GitHub Environment `roblox-production` with `ROBLOX_API_KEY`, and the variables in SETUP.md.
- 2026-11-04: **v2 final fix team** (QC-A M1–M4 + minors, QC-B V2-M1/M2 + minors; every item has a test):
  - **QC-A M1 ocean terrain.** `ArenaBuilder` ocean theme: `Pebble` (a Part material) → `Cobblestone` patches and a `Limestone` path; LightingService's ocean terrain colours too (its `Pebble` entry made `SetMaterialColor` fail). `Visuals/Terra`: a failure skips only the rest of that build (`Terra.reset()` at every arena build) and `clearBox` always runs its Air fills. New `RuntimeArenas` spec builds all 9 arenas in sequence (ocean first and last) and asserts terrain fills, no warnings and no gaps, plus a forced bad fill that must not stick.
  - **QC-A M2 loot visuals.** FxController draws pooled bag / ground-gear markers (bobbing body, rarity-coloured pulsing disc, glint, channel fill from `bagProgress`, a label "🧀 N + gear ×n" or the item name), removed on `bagGone` / `gearGone` and on a new arena. World's `bag` Fx carries `r` (best rarity). The ClientLayout coverage test now requires these kinds in FxController itself (the minimap no longer counts). `RuntimeV2Fixes` checks them on a real client.
  - **QC-A M3 Shop Cart.** Decision: the cart charges the buyer's OWN share (server unchanged). The panel shows "Your share" and enables Buy against the payload's `share`, reads `bought` (string keys, `sold` alias), and the server re-sends the cart to squad-mates with it open after a buy and when the share changes (`refresh`, never reopens a closed panel). ARCHITECTURE-v2 documents it.
  - **QC-A M4 bounties.** In a squad match the client trusts only `Match.bounties` and the `bounty` / `bountyClaimed` feed entries; `KillStreaks` counts kills only (downs never).
  - **QC-B V2-M1 Second Wind.** Token revives are refused while 2+ squads are in the run (`RunTokens` `blocked_pvp`, `Monetization.RULES.tokenReviveBlockedFromSquads = 2`); the free revive, teammate revives and the Statue stay. `Monetization.promptRefusal` + `MonetizationService.setRunMemberCheck` (installed by RunDirector) refuse `second_wind_*` prompts for run members with a toast. Benefit, Club, MONETIZATION.md and GDD texts updated.
  - **QC-B V2-M2.** `docs/publishing/SETUP.md` §5 rewritten with explicit questionnaire answers (repeated unrealistic violence against creatures and player avatars, no blood, bots in rival squads, expect Mild but answer honestly). Renamed (ids kept): Bloodthirst → Hungry Herd, Lifeblood → Wellspring Heart, Vampiric Blade → Cheese-Leech Blade, Killer Instinct → Sharp Instinct, Butcher → Chop Shop, Cheese Vampire → Cheese Muncher, Vampire Herd → Snacking Herd. `ConfigData` scans every Config `name` for blood / killing words.
  - **QC-A minors:** blessing toast to the blessed squads (`StageResult.blessed`); Extract card shows your own share / bank (`Extract.share`, `bank`); Match squads carry `banked` and the scoreboard ranks extracted squads by it; one 🤖 per bot name (`Format.botName`); respec asks cheese or token and a token is spent only when picked (`ClassProgress.resetPerks` defaults to cheese); lighting applied once per stage (ArenaBuilder only); enemy DOWN tags follow the server's `Downed` attribute; lobby players see "Match in progress · about N left. The next match starts when this one ends" (`Lobby.runInfo`, `RunDirector.estimateEnd`) and a toast when they leave a run.
  - **QC-B minors:** combat-logging (downed or hit by an enemy within `ASSIST_WINDOW`) takes the elimination path: 30% bag for the enemy, kill credit, 35% kept (`MatchState.removeMember(id, combat)`); the `heroDowns` board counts distinct HUMAN victims per match (`Payout.humanDowns`); Shop Cart buys need Waves and ≤ 14 studs (`Run/CartRules`); the Rind Gate stays gold on the server and each client tints it from its own squad's votes; touch perk tree uses a wide panel and a rows layout (nodes ≈ 58 px on 667×375, no overlaps, `PerkTree.layoutRows`); the Extract panel folds to a compact bar (▾, and automatically after you vote); Epic reroll fallback respects the 30 holding cap (`EpicDrop.grantFallbackToken`); `publish.yml` / `status.yml` / `upload-assets.yml` use the `roblox-production` Environment, give `ROBLOX_API_KEY` only to the Open Cloud steps and run only from the default branch.
  - **Part budget:** arenas are thinned to `ArenaBuilder.PART_BUDGET` 2,850 parts (Rind Gate included: < 3,000) and `LIGHT_BUDGET` 29 PointLights (30 with the gate); jungle trees use fewer canopy parts. Measured (seed 1): jungle 3,322 → 2,848, moon 3,383 → 2,843, volcano 55 → 29 lights. The lobby island's decor is hidden locally (`DetailLevel.setLobbyHidden`) while the player is in a run.
  - **Found on the way:** RunDirector hit Luau's 200-local register limit; small constants moved into one `K` table. The Shop Cart's sparse `bought` table would not survive a remote (Roblox cuts arrays at the first nil), so it is sent with string keys.

- 2026-11-04: **v2 fix team** (5 items, all tested):
  1. **LeaderboardService budget.** In Studio the probe is now the first board's real refresh, so a cycle sends 5 GetSortedAsync calls, not 6. `waitForBudget` returns false when the wait runs out (`READ_BUDGET_WAIT` 60 s), and a refresh then skips that board and keeps its stale cache instead of queueing. Writes wait up to `WRITE_BUDGET_WAIT` before sending. `RuntimeStudio` passes with no "added to queue" warning.
  2. **Rind Gate exploit.** A squad with every member downed or dead could Extract and bank 100%.
     - New `MatchState.fallenSquads(standing)`. `RunDirector.eliminateFallen` runs right before `resolveExtraction` and eliminates every squad with nobody standing, through the normal path (bags, kill feed, payouts).
     - The wipe check (`gateOver`) keeps running during the route choice and the extraction window. Either may now end the match.
     - The headless sim mirrors it.
     - Regression tests:
       - `RunMatch` (fallenSquads, gate regression);
       - `IntegrationSquads` "[regression] a wiped squad at the Rind Gate" (fails without the fix);
       - new `RuntimeSquadsGate` (RuntimeSquads with the fragile squad at 1/25 HP voting Extract, then downed at its gate; without the fix it extracts with 0 standing).
     - Found on the way: in `RuntimeSquads`, pair A's stage-2 "extraction" was itself often an all-downed squad. Both human squads now get ×3 HP there so the scenario stays meaningful.
  3. **Results stage.** `Payout.stage` (`MatchState.outStageOf`) is the squad's `outAtStage`, so an extraction after stage 2 shows stage 2. `stagesCleared` is unchanged. Asserted in RunMatch and RuntimeSquads.
  4. **PvP balance** (data-driven).
     - World: `PVP_MULT` 0.45 → 0.3, `DOWNED_HITS` 4 → 6, and a new `DROP_PROTECT` of 9 s (drop-in protection; revives keep `SPAWN_PROTECT` 5 s).
     - BotBrain pacing (`pvpRanges`; the view's `stage` and `waveTime` come from the new `World.stageClock`, passed by BotService and the sim):
       - stage 1 has no hunting for 75 s (`CALM_SECONDS`), only self-defence plus `CALM_AVOID`;
       - the first 75 s of each stage cap the ranges at engage 9 and chase 24;
       - after that, aggression ramps by stage (`HERO_ENGAGE_BY_STAGE` {10, 20, 24}, `DEFEND_RANGE_BY_STAGE` {24, 45, 55});
       - early in a stage the leader drifts to 0.7·R, not 0.35·R (the old drift pulled all 4 squads to the centre within ~8 s);
       - `LOW_HP` 0.35 → 0.5;
       - `EXTRACT_POT` 300 → 220.
     - The sim's human stand-in extracts at `Headless.HUMAN_EXTRACT_POT` = 800 per member (new optional 4th argument of `chooseExtract`). With the bot threshold it leaves at the stage-2/3 gate, so no PvP setting could reach stage 4 (with 220: reach 3+ 2%).
     - `IntegrationSquads` now plays 24 seeds and guards the pacing targets with margins. `IntegrationPressure` went to 16 runs per level: 8 no longer separated P10 from P21. The win-gap margin is now 12.5 points (19 measured), plus a stages-cleared check (33 / 20 / 14).
     - Headless sim, solo stand-in + 11 bots, POIs on, the same 48 seeds; "before" is commit dec173b:

       | Metric | Before | After |
       |---|---|---|
       | Matches by stages played (1/2/3/4) | 30/18/0/0 | 10/13/9/16 |
       | Reach stage 3+ | 0% | 52% |
       | Reach stage 4 | 0% | 33% |
       | Stage-1 eliminations per match | 2.27 | 0.67 |
       | Eliminations per match | 2.35 | 1.42 |
       | PvP downs per match | 12.7 | 29.5 |
       | PvP kills per match | 8.2 | 6.7 |
       | First PvP down (median) | 23.9 s | 70.8 s |
       | Bot squads extract / Last Herd | 1% | 35% |
       | Bot squads alive at the end (incl. noHumans) | 44% | 68% |

     - **Misses:** eliminations are 1.42 per match against the 2+ target, and "most matches reach stage 3" is only just met (52%). The extra stage-2 lethality that would add eliminations wipes the human's squad and the bot squads before they reach the gate (sweeps in the fix-team report).
  5. **Fx bandwidth.** PerfWorld's ~315 Fx/s and ~28.7 KB/s were the whole batch, before culling. Per client after `FxFilter.forViewer` it was ~19 KB/s.
     - New `FxFilter.NEAR_RADIUS` = 60: other heroes' melee, chain, boom, hurt and dodge Fx are culled beyond 60 studs. The attacker and the victim always get their own.
     - Now ~136 Fx/s, about 13.4 KB/s average and 14.3 KB/s max per client (JSON proxy, 300 s at the cap, every 3rd step sampled). At full rate over the first 120 s it is 14.4 average and 15.0 max.
     - PerfWorld samples once a second (121 Fx/s, 12.3 / 12.7 KB/s) and asserts < 15 KB/s. Denser sampling added GC pauses to the timed steps.
     - PerfWorld's "worst step" now checks p99.9 < 25 ms and still prints the max. The plain max was flaky on the original code too: 5 / 14 / 34 ms over three runs of dec173b.
     - Hurt and dodge flashes are already one per hero per i-frame window (`IFRAMES` 0.5 s, ~0.45 KB/s), so merging them would gain nothing.
- 2026-11-03: Publishing pipeline (GitHub Actions + Open Cloud, per `docs/publishing/CLOUD_PUBLISHING_PLAYBOOK.md`). **Owner checklist: `docs/publishing/SETUP.md`.** Added `ci.yml`, `publish.yml`, `status.yml` and `upload-assets.yml`, plus `scripts/{install-tools.sh,publish.py,smoke.luau,catalog.luau}`. Ids go to the generated `Config/ProductIds.luau` and `Config/AssetIds.luau`; `Monetization.luau` reads ProductIds when its own id is 0. Smoke test: `docs/publishing/SMOKE.md`. Before the first real publish, the `DataConfig` spec "placeholder ids are 0" must accept generated ids (exact replacement in `docs/publishing/SETUP.md` → For agents).
- 2026-11-03: Owner asked to redo the game to match the original vision (classes with long-term progression, squads fighting each other, POIs granting power and items, much better graphics) and to publish via a GitHub Actions pipeline (`docs/publishing/CLOUD_PUBLISHING_PLAYBOOK.md`). Owner decisions: squads PvPvE; 12 players; class levels + perk tree + skins/mastery + alternate abilities; gear run-only; built-in graphics plus AI meshes. Contracts are in `docs/ARCHITECTURE-v2.md`. If a team didn't finish, its report items are listed there by owner.
- 2026-11-03: Added `docs/LOCAL-SESSION-HANDOFF.md`, a paste-ready prompt for a local or desktop session to finish the Studio and Dashboard steps.
- 2026-11-03: Network opened. Added `scripts/roblox-setup.py`, which creates the passes and products through the Open Cloud beta APIs (idempotent, writes the ids into config) and publishes the place. Dry run verified. It needs `ROBLOX_API_KEY`, `ROBLOX_UNIVERSE_ID` and `ROBLOX_PLACE_ID` (see `docs/LAUNCH-STEPS.md` §3).
- 2026-11-03: The owner asked for everything that can be done. Added `docs/LAUNCH-STEPS.md` (owner checklist). Merged the branch into `main`. Roblox hosts (apis.roblox.com, create.roblox.com, roblox.com) are blocked by the cloud environment's network policy, so publishing and Dashboard setup remain owner tasks.
- 2026-11-02: Runtime verification team: built `tests/runtime/`, a headless Roblox runtime emulator under Lune.
  - **What it verifies.**
    - The real Script and LocalScripts run in a DataModel built from `default.project.json` (cross-checked against `rojo build`).
    - Require-by-string resolves on the instance tree.
    - Server and client contexts are separate.
    - Remotes are copied with Roblox's rules.
    - Instances and properties are checked against the Roblox reflection database.
    - The service mocks cover DataStore budgets and the 1-write-per-6-s-per-key queue.
    - There are 7 scenario specs (boot; solo Cycle 1 through the real UI; Studio −1; purchase idempotency; leave mid-run plus `BindToClose`; veteran/passes/cosmetics/chat tags/shop/Pressure; Immediate signals with Play-Solo ordering, a phone, the auto-start and lag), plus `tests/runtime/fuzz.luau`.
  - **Real bugs fixed (`DataService`).**
    1. A leaver's payout (`awardRun` from `beforeRelease`) spawned its own save right before the release save. That is two writes to one key, so Roblox queued the release about 6 s and the lock stayed held. `awardRun` now skips that save while the session is releasing.
    2. Saves were neither paced nor coalesced. A pass owner's join wrote the profile 4 times in 20 s (one queued write per pass perk), and a purchase right after join queued too. `saveSession` now waits until 6 s after the previous write (`DataService.WRITE_SPACING`), and all save requests made meanwhile share one write.
  - **Emulator gaps fixed:** `Trail:Clear`.
  - **Still needs real Studio:**
    - rendering, layout and text metrics
    - physics and the character controller
    - real network bandwidth, loss and ordering
    - real DataStore and MessagingService latency, outages and cross-server locks
    - Marketplace prompts and real receipts
    - script timeouts, memory, and the `Highlight` cap
    - confirm string `require("./X")` on a live server

- 2026-11-02: Final fix round done: Pressure rebalanced, plus FINAL-A m1–m9 and the POI labels/onboarding. Status and next steps rewritten for the finished state.
- 2026-11-02: Final fix team (FINAL-A M1, m1–m9; FINAL-B FB-m4):
  - **M1 Pressure balance.** New `perStage` growth in `Config/Pressure` (`Pressure.worldDelta(board, globalStage)`; `RunState.worldMods` passes `globalStage()`). Stampede and Big Cheese add elite chance, Boss Fury also grows mouse damage, Thick Rind grows HP each stage, and No Snacks cuts mouse XP by 30% per rank (new WorldMods field `enemyXpMult`). Cheese stays +8% per point.
  - Headless, solo + 2 bots, POIs on, 8 seeds × 3 classes, Cycle 1 → Go Home: P0 24/24 (avg 768 cheese), P10 20/24 (1,141), P21 14/24 (1,215; ~2,050 per win). Before: P0 24/24, P10 18/24, P21 23/24 (1,966). The new spec `IntegrationPressure` (~100 s) guards win(P0) > win(P10) > win(P21).
  - m1/m8: `State` keeps `offer.source`; the `Remotes` payload types gain `source` and `pressure`.
  - m2: POI state is re-sent only while the waves run (no ghost rings).
  - m3: camps don't wake in the last 20 s of waves; a pack alive when the waves end flees and its chest is granted (`poiReward.fled`).
  - m4: one enrage toast ("<Boss> is enraged: faster attacks!"); phase 2 says "The boss gets angry! (phase 2)".
  - m5: snapshot flags bits 4–5 carry an elite size step (codec v1, wire format unchanged); `HordeRenderer` draws elites at that size.
  - m6: cache and landmark cheese get the Pressure bonus in the sim too (matching RunDirector); the GDD says so.
  - m7: RunDirector sends a personal `discovered` Fx on a first find; the HUD banner shows only then.
  - m9: `UpgradeOffers.nextQueued` skips an empty bonus pick without dropping queued level-ups.
  - FB-m4: POI name labels (BillboardGui, 70 studs) in `ArenaBuilder`, and one onboarding hint near the first POI.
  - Still open: verify the Pressure difficulty in a real play-test (the sim "human" is a BotBrain); the per-Pressure leaderboard and badges.

- 2026-11-02: Final QC B: 0 blockers; FB-M1 (text size on phones) and FB-m1/m2/m3/m5 fixed; reports in `docs/qa/FINAL-*.md`. Final QC A: 0 blockers; M1 Pressure balance plus m1–m9 assigned to the final fix team. If you are Codex and that team didn't finish, work through `docs/qa/FINAL-A-integration.md`.
- 2026-11-02: G2 POIs and portals done:
  - Rare Pantry 2.94% and Statue 2.02% over 20k stages.
  - Bots activate POIs in 6 of 6 sim runs.
  - The 4 Pressure WorldMods are live in World.

  Lead added `RunState.addPending`, the Herd Keeper title and bonus-pick labels. Check: PASSED (34 specs). Final QC A and B started.
- 2026-11-02: G1 Pressure done: `Config/Pressure`, `Run/Pressure`, RunState integration, lobby board (leader-edited, SetPressure), profile v4 (`pressure`, `discoveries`; veterans auto-unlocked). Still open:
  - 4 modifiers need World support (eliteSpeedMult, eliteSizeMult, lateSpawnMult, rangedExtraProjectiles); assigned to G2.
  - No per-Pressure leaderboard or title badges yet (`Pressure.badges()` exists).
  - The board isn't locked during the final countdown seconds.
- 2026-11-02: Fix team 2 done:
  - MoveGuard, lobby anti-grief, bots never stake Double or Nothing without a human, reroll id, safe payouts and timeouts, an AFK cap.
  - Balance: fractional party size, XP split, boss scaling and a 120 s enrage.
  - Bandwidth about 50 → 26 KB/s.
  - Epic drops.
  - Boss renamed to `zoomzola`.

  The headless sim was updated to match. Check: PASSED (31 specs). Team G started.
- 2026-11-01: Fix team 3 (client) done: Fx coverage, mobile layout, onboarding, chat tags, Play Again. Fix team 1 done: CosmeticsService fixes QC2's blocker; pass verification and revocation; corrupt-save guard; 7-min stale lock with a handshake; boost caps. New remote `SetSetting`. Open from team 1: no guest mode during a DataStore outage; pass revocation runs on join only.
- 2026-11-01: Testing team done: 67 tests, full-run sims, fuzz and perf; report in `docs/qa/TESTING.md`. Its 3 bugs and the balance/bandwidth items went to fix teams 1 and 2. All three fix teams paused on a usage limit, then resumed. If you are Codex picking this up mid-fix: run `scripts/check.sh`. Failing specs tagged `[BUG …]` and the QC reports are your to-do list.
- 2026-11-01: QC1 and QC2 reports committed. Bot/Studio id collision fixed (`Util/Ids`). Fix teams 1–3 launched.
- 2026-11-01: Bots (F) finished and committed. Testing team and QC teams 1 and 2 started.
- 2026-11-01: Combat & horde (B) finished: 230 tests, chunked snapshots. Follow-ups are listed in `docs/COMBAT-API.md` (bandwidth about 30 KB/s, speed-hack check, solo wipe grace).
- 2026-11-01: Project moved from childcare-ops to the Roblox-Mice repo (history preserved). Lore and style docs written (brainstorm action items). Pressure, POI and portal specs added to the GDD. Handoff created.
- 2026-11-01: Client (C) and Data/Monetization (D) finished. Owner asked for bots so solo players can always play (Team F).
- 2026-10-30: Research teams (market, monetization, tech) finished. Scaffold, contracts, GDD and toolchain set up. Run & progression (A) and orchestration (E) finished.
