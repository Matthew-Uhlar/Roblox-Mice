# HANDOFF — read this first (Codex or any agent continuing the work)

> Living document, updated after every major step. If you are an AI agent
> picking this up (e.g. Codex after a Claude usage limit), read this file top
> to bottom, then `docs/GDD.md` and `docs/ARCHITECTURE.md`, before changing
> anything. Before you stop, update **Status**, **Next steps** and the
> **Log**, then commit and push.

_Last updated: 2026-11-02. Feature-complete and QC'd. The server and client scripts now run end to end in a headless Roblox runtime emulator (`tests/runtime/`, 7 scenario specs). Two real DataStore bugs it found are fixed. CHECK PASSED (42 specs). Next: a human Studio play-test (§5)._

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
CHECK PASSED (42 spec files, lint/format clean, Rojo build OK).

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
| Runtime emulator | `tests/runtime/*`, `tests/specs/Runtime*.spec.luau` | runs the real server + client scripts headless (Lune); 7 scenarios, zero errors/gaps; see its README |

## 5. Next steps (in order)

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
3. **Creator Dashboard:** create the passes, products and subscription from `docs/MONETIZATION.md` and paste the ids into `src/shared/Config/Monetization.luau`. Complete the maturity questionnaire (target Mild) and set up ads eligibility.
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
