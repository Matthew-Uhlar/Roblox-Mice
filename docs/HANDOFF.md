# HANDOFF — read this first (Codex or any agent continuing the work)

> Living document, updated after every major step. If you are an AI agent
> picking this up (e.g. Codex after a Claude usage limit), read this file top
> to bottom, then `docs/GDD.md` and `docs/ARCHITECTURE.md`, before changing
> anything. Before you stop, update **Status**, **Next steps** and the
> **Log**, then commit and push.

_Last updated: 2026-11-02. ALL features from the brainstorm are built, including the concept features (Pressure, POIs, portals). `scripts/check.sh` PASSES (34/34 specs). The final QC round (A: integration/gameplay, B: security/policy) is running in report-only mode; then fixes, then merge to `main`._

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

| Area | Files | State |
|---|---|---|
| Design | `docs/GDD.md` (§3.7 Pressure, §3.8 POIs and §3.9 Portals are **specified, not built**), `docs/LORE.md`, `docs/STYLE.md` | done |
| Research | `docs/research/{market,monetization,tech}.md` | done (web sources via search summaries; items tagged *verify*) |
| Shared contracts | `src/shared/{Types,Net}.luau`, `Util/Rng.luau` | done |
| A: Run & progression | `Config/{Classes,Upgrades,Modifiers,Maps}`, `Run/{Stats,Leveling,UpgradeOffers,Vote,RunState}` | done, 133 tests |
| B: Combat & horde | `Config/{Enemies,Bosses}`, `Combat/*`, `Services/{CombatService,ArenaBuilder}` | done, 230 tests; ~0.5 ms/step at 220 enemies; implemented API in `docs/COMBAT-API.md` |
| C: Client & UX | `src/client/**` (camera, input, horde renderer, FX, HUD, vote/upgrade/lobby/shop/results UI) | done, compiles, **not play-tested** |
| D: Data & monetization | `Config/{Monetization,Cosmetics,Talents,Shop}`, `Data/*`, `Services/{Data,Monetization,Shop,Leaderboard}Service` | done, 72 tests |
| E: Orchestration | `Main.server.luau`, `Services/{RunDirector,LobbyService,Guard,Remotes}` | done (bots wired in by Team F) |
| F: Bots | `Bots/{BotBrain,BotRoster}`, `Services/BotService`, edits to RunDirector and LobbyService | done, 38 tests. Solo play = 2 bots; 5 s ready / 30 s auto-start |
| Testing / QC teams | `tests/specs/{Integration,Fuzz,Perf}*`, `docs/qa/QC1-integration.md`, `docs/qa/QC2-security-policy.md` | QC reports done (QC1: 1 blocker / 3 major / 11 minor; QC2: 1 / 8 / 14). **Fix round running.** Testing team still running. |

Nothing has run inside Roblox Studio yet, so everything is verified only by Lune
unit tests, a compile check and a Rojo build. **The first Studio play-test is the
top priority** once the code is integrated.

## 5. Next steps (in order)

1. **Fix round in progress.** If a fix team didn't finish, work through the open findings in `docs/qa/QC1-integration.md` and `docs/qa/QC2-security-policy.md`. Areas: Data/Monetization (including a new CosmeticsService for the Blocker "bought cosmetics aren't visible"); gameplay server (movement validation, lobby countdown griefing, bots never voting Double or Nothing alone, reroll offerId, Second Wind charge order, AFK auto-start cap, boss rename to `zoomzola`); client (zone Fx, mobile UI scaling, Play Again → SetReady, onboarding, chat tags). Then make sure `scripts/check.sh` passes.
2. **Integration/QC pass.**
   - Grep every cross-module call: RunDirector → World, CombatService, ArenaBuilder, BotService, DataService, MonetizationService.
   - Check the client ↔ server payloads in `Net.luau`.
   - Fix mismatches.
   - Known items:
     - ~~Studio test players' negative UserIds collide with bot ids~~: **fixed**. Bots use ids ≤ −1000 via `Util/Ids.luau`.
     - AFK players get looped into runs by the 30 s auto-start: stop auto-starting after 2 idle runs.
     - `Remotes.LobbyEntry` and `PartyEntry` types lack `isBot`.
     - PlayerStats has no `crumbHeal`, so Filet's passive is approximated with regen.
     - `abilityMul` on StatDelta is not in Types.
     - Leaderboard data has no server-to-client remote.
     - The client should fire `PromptProduct("refresh")` when the shop opens.
     - Second Wind accounting is duplicated between RunDirector and `Data/RunTokens`.
     - Cheese multiplier timing relative to Double or Nothing.
     - Ability clock base: `CombatService.now` vs `GetServerTimeNow`.
3. **Testing team.**
   - A headless Lune integration test where 3 bots (BotBrain) play a full cycle through RunState and World.
   - Fuzz the receipts and profile migration.
   - Run the perf benchmark (220 enemies, at most 5 ms per step).
4. **QC team:** remote-exploit review, monetization policy compliance, data-loss scenarios and mobile UI review. Write `docs/QA.md`.
5. **Concept features (Team G):** build GDD §3.7 Pressure, §3.8 functional POIs and §3.9 portals.
6. **Studio play-test checklist** (needs a human with Roblox Studio):
   - `rojo build -o build/Trunkfall.rbxlx` and open it.
   - Game Settings: Max Players 4, API Services on, StreamingEnabled off.
   - Delete the template Baseplate and SpawnLocation.
   - Play solo (2 bots should join).
   - Test 2–4 clients.
   - Verify string requires work on a published server.
7. **Creator Dashboard:** create the passes, products and subscription, paste the ids into `src/shared/Config/Monetization.luau`, and complete the maturity questionnaire (target Mild).

## 6. Log (newest first)

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
