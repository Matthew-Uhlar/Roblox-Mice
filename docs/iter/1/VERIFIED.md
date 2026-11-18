# Iteration 1: Verification (step 2 of docs/ITERATIONS.md)

Team: Verification. Read-only on `src/`. Date: 2026-11-18. Build: the working tree as checked out (v4, live as place v7).

Inputs: `docs/iter/1/playtest.md` (P-1 … P-31), `docs/iter/1/concept.md` (C-1 … C-30) and `docs/iter/1/zombie-world.md` (Z-1 … Z-25): 86 entries.

## What we ran

All throwaway scripts and logs are in `/tmp/claude-0/-home-user/62ecd08e-82c1-5cab-a26b-5e0b2b23913e/scratchpad/iter1-verify/`.

| Run | Result |
|---|---|
| `storm.luau` (runtime emulator; real RunDirector + World; seeds 1–3) | At wave start **every one of the 12 heroes is outside the Melt**. The circle is already 0.65 R at t = 0 (r 289.7 for R 445.7), and the zone holds `closeStart = 30, closeEnd = 60` while `world.now ≈ 1.79e9`. A hero standing still loses 2.5 HP/s (125 → 22 HP in 40 s). Root cause in **P-4** below. |
| `tests/specs/IntegrationSquads.spec.luau` (24 seeds, `squads.txt`) | Human squad: eliminated in **75 %** of matches, and in stage 1 in **8 / 24 (33 %)**. Stage-1 eliminations 0.88 per match, champions killed 1.62 per stage, bot squads out alive 12 %, first PvP down median 76 s. Both `[BALANCE]` warnings still fire. |
| Concept `routes.luau` (16 seeds, `routes.txt`) | 18 clears: tiers **Low 17, Mid 1, High 0**. The human's squad won the boss in 4 of 18 clears (22 %). This reproduces C-1 exactly. |
| Playtest logs (`iter1-play/m*.txt`, `v4report.txt`) re-read | See P-1: 4 of the 8 "default" wipes had **0 mouse kills** by the driven human. 3 logs (`m_rookie`, `m_veteran`, `m2_rookie_c`) are byte-for-byte the same match, so the seed variation did not work. |
| `cmp` of `assets/previews/*.png` against the fresh renders | 15 of 20 differ. `bosses`, `boss_poses`, `champions`, `pois` and `portal` are identical. `heroes.png` is not committed. |
| Render PNGs read: `heroes`, `bots`, `bot_poses`, `map_volcano` | They confirm P-20, P-21/C-16 and P-22/C-27. |

Scoring: impact H = 3, M = 2, L = 1; effort S = 1, M = 2, L = 3; **score = impact ÷ effort**. Owners follow the V4-PLAN ownership table: M1 Combat, M2 Match flow, P Progression, U UI, G Graphics and audio.

---

## (1) Every entry: verdict

Columns: reported impact/effort → verified impact/effort. **Dup →** names the merged item in section 2.

### Playtest (P)

| Id | Verdict | Reason (one line) | I/E reported → verified | Merged into |
|---|---|---|---|---|
| P-1 | **Partly** | Real: the sim's bot-brained human loses its squad in stage 1 in 21–33 % of matches (v4-report 5/24, IntegrationSquads 8/24). But the runtime's "7 of 8" is a driver artefact: 4 runs had 0 mouse kills, 3 logs are the same seed, the driver walks into champions at level 1–2 at 14 studs, and P-4 hits every drop-in. `_rookieSafe` covers only the rookie, not the rookie's bot squadmates (World 4066), and those bots are OUT at level 1–4 in every log. | H/M → H/M | #10 |
| P-2 | **Confirmed** | `ClassProgress.runXp` only counts stagesSurvived, bossDamageShare, heroDowns and pois. A stage-1 wipe with 0 POIs pays 0 (`classXp=0` in all 7 wipes; `m3_rookie_b` had 75 kills and a champion). | H/S → H/S | #2 |
| P-3 | **Confirmed** | v4-report: wipe median 80 against a win median of 2,197 (4 %). Class unlocks cost 2,500–4,000. The sim human never extracts (all wins are lastHerd/final). | H/M → H/M | #11 |
| P-4 | **Confirmed, different root cause** | Not the corner geometry. The first `K.stormTick` runs right after `buildStage` (RunDirector 4440), when the new World's `now` is still 0 (World 256). So `K.worldNow` (3427) returns 0, `t0 = 0` and the close times 30/60 sit on a clock already at server time (~1.79e9). The circle is **0.65 R from second 0 until the step-2 reset at 60 s, in every stage**, so all 12 heroes start 0.25 R (75–140 studs) outside, and the step is cached, so it is never corrected. Storm damage also ignores `protectUntil` (World 3984 checks only `invulnUntil`). | M/S → **H/S** | #1 (hotfix) |
| P-5 | **Confirmed** | `MinimapUI.luau:894` sets `label = pp.kind`, and `Config/Pois` already has `name`. | M/S → M/S | #3 (hotfix) |
| P-6 | **Confirmed** | `Util/Progression.reward`: `name = str(r.name or r.label or r.title)`, so a `{title = id}` reward uses the raw id as its name, and the namer that ProgressUI installs (`rewardName` → "Title: Winter Herd") never runs. A one-line fix. | M/S → M/S | #3 (hotfix) |
| P-7 | **Confirmed** | `Toasts.luau` has `MAX_QUEUED = 6` and drops the oldest with no priority. Logs have 19–87 server toasts per match (66 in 3 min 35 s). | M/S → M/S | #13 |
| P-8 | **Confirmed** | The Results headline is the payout only. The first-extraction +500/+50 is a toast (`DataService` 1050). +220 shown against +1,290 banked. | M/S → M/S | #14 |
| P-9 | **Confirmed** | `ResultsUI` 685 shows `r.kills`/`r.downs`, which count hero PvP only. It reads 0 with 144 mice killed. | L/S → L/S | #12 |
| P-10 | **Partly** | The MVP is scored over all 12 heroes (`MatchState.awards`), so a surviving bot wins (11/11). But "the human gets no accolade" is wrong: Results shows the human's Pack Mule / Iron Trunk. The driver read `aw.you.title`; the field is `accolades`. | M/S → M/S | #12 |
| P-11 | **Partly** | The Easy pool holds "Stomp 1,200 mice" (8–16 matches at 75–144 kills each) and "Pick up 4 gear" (the human picked up 0 gear in all 11 runs). Medium and Hard being hard is by design. There is no rookie pool. | M/S → M/S | #15 |
| P-12 | **Confirmed** (proposal partly) | Sim idle is 31.8 % (p75 48.6 %), and up to 69 % in late stages. Spawns are already hero-relative (`WaveDirector`: a ring at VIEW_RADIUS 48 that prefers heroes with few mice), so the fix is tuning, not new placement. | H/M → H/M | #6 |
| P-13 | **Partly** | Frequency confirmed (13–16 offers per stage, level 9 → 13 during the gate). The phone overlap is emulator geometry (verify on device). | M/S → M/S | #19 |
| P-14 | **Confirmed** | `REDEPLOY_DELAYS` is 20/25/30/35 against 150 s waves, and 10 of 29 timers complete in the sim. | M/S → M/S | #17 |
| P-15 | **Rejected** | Low storm damage in the sim is the V4 intent ("a nudge"). The only runtime storm damage is the P-4 bug, and fixing P-4 changes the picture. The "show next circle" idea is cosmetic and is folded into #1's follow-up. | L/S → — | (#1) |
| P-16 | **Confirmed** | `DataService.luau:1062` has no rookie gate. `LobbyUI:1411` still says "(Go Home)". | L/S → L/S | #23 (hotfix) |
| P-17 | **Confirmed** | The visible-only text dump shows the Melt timer, the objective arrow and "Survive the horde!" under Results. | L/S → L/S | #29 |
| P-18 | **Partly** | The auditor's geometry ignores UIListLayout and text metrics, so this must be verified on a device. The long strings ("They won the boss…", the boss epithet) are real. | M/S → M/S | #30 |
| P-19 | **Confirmed** (code; verify feel in Studio) | `BotService.pose` calls `model:PivotTo(cf)` on the server every Heartbeat. Anchored-part CFrames replicate without client interpolation, and `BotAnimator` poses only the C0s. | H/M → H/M | #7 |
| P-20 | **Confirmed** | `bot_poses.png`: idle, walk and attack are nearly identical for all 7 classes. Ability and downed read well. | M/M → M/M | #9 |
| P-21 | **Confirmed** | `heroes.png` shows a grey block R15 with ring ears and a ball trunk; `bots.png` shows rounded faced elephants. | H/M → H/M | #8 |
| P-22 | **Confirmed** | `maps.png` shows the same spokes and centre ring on every map. The `map_volcano.png` gameplay camera shows a flat red plane. Caveat: client GroundScatter is not in the preview. | H/L → H/L | #24 |
| P-23 | **Confirmed** | `pois.png` / `champions.png`: shared shrine template, box-stack golem. | M/M → M/M | #28 |
| P-24 | **Confirmed** | `lobby_rookie.txt`: "Auto-start 0:22 · 1 + 11 🤖" flips to 12 × "Empty seat" while busy. | L/S → L/S | #29 |
| P-25 | **Confirmed** | Herd dump: Claim on 🔒 tiers, and 3 Reroll buttons with 1 free reroll. | L/S → L/S | #29 |
| P-26 | **Confirmed** | `ProductIds.emote_pack = 0` → `ShopModel.robuxLabel` "Coming soon" card next to paid items (live). | L/S → L/S | #23 (hotfix) |
| P-27 | **Confirmed** | Extract was pre-selected but the panel stayed collapsed; the rookie ended at 97/100 class XP. | M/S → M/S | #16 |
| P-28 | **Confirmed** | DoN loss is not explained on Results. The sim has DoN 0 paid / 0 lost, so it is untested. | M/S → M/S | #18 |
| P-29 | **Partly** | As designed (`BotBrain.ROOKIE_STAGES = 1`), but the evidence is real: the rookie was finished by 🤖 PvP in stage 2. | M/S → M/S | #10 |
| P-30 | **Confirmed** | Veteran back-fill toasts "First Steps!" / "Regular!" mid-match. | L/S → L/S | #29 |
| P-31 | **Partly** | 15 of 20 committed previews are stale, but 5 are byte-identical to fresh renders, and `heroes.png` is missing. There is no HUD render. | L/S → L/S | #29 |

### Concept (C)

| Id | Verdict | Reason (one line) | I/E reported → verified | Merged into |
|---|---|---|---|---|
| C-1 | **Confirmed** (reproduced) | `BotBrain.safeOption("route")` → Low, `VOTE_SURPRISE 0.15` → Mid, never High. No winner → `defaultRouteIndex`. Sim: Low 17 / Mid 1 / High 0. | H/S → H/S | #4 |
| C-2 | **Confirmed** | `MatchState` 1148–1160: the blessing goes to `chooserSquad` only; VoteOpen goes only to the winner's humans. | H/M → H/M | #20 |
| C-3 | **Confirmed** | `MatchState.begin` uses a seeded random first card. VoteUI's "Pick your first map!" is dead. Needs a lobby vote (LobbyService + LobbyUI). | M/S → M/**M** | #25 |
| C-4 | **Confirmed** | `STAGES = 4` and `cycle = 1` are hard-coded. Veteran mode for iteration 2–3. | M/L → M/L | #31 |
| C-5 | **Confirmed** | VoteUI/ExtractUI start minimised on PC; curse and blessing text only in tooltips. Touch starts open, so impact is M, not H. | H/S → **M**/S | #16 |
| C-6 | **Confirmed** (absent) | `grep -i bookie src` finds nothing. Needs a model, a UI portrait and lines. | M/S–M → M/M | #18 |
| C-7 | **Confirmed** | 0 hits for the lore names; Bosses has no `lore`. | M/S → M/S | #21 |
| C-8 | **Confirmed** | No hit-stop or TimeScale anywhere; the boss kill is a toast stack. Impact M (feel), not H. | H/M → **M**/M | #13 / #26 |
| C-9 | **Partly** | No boss-specific gear (true). It overlaps v5 charms and stalls (scope risk, Z-20), so defer it. | M–H/M → M/M | #31 |
| C-10 | **Confirmed** | The server emits `roulette {spell, options, reveal}`; `FxController:3326` shows only a text pop. | M/S → M/S | #21 |
| C-11 | **Confirmed** | `Signatures.luau`: every feature is walkable and invisible to the sim. 9 hazard rules touch World balance and telegraphs: effort L, impact M. | H/M → **M/L** | #31 |
| C-12 | **Confirmed** | `RunState._rollCards` picks maps and bosses independently. | L–M/S → L/S | #29 |
| C-13 | **Confirmed** | `MouseModels` has no per-map dress; the enemy pool is the same on every map. | M/M → M/M | #28 |
| C-14 | **Confirmed** | No speech or bark system. | M/S → M/S | #21 |
| C-15 | **Confirmed** (absent) | No Mouse King anywhere. | M/M → L/M | #31 |
| C-16 | **Confirmed** (duplicate) | Same as P-21. | H/M → H/M | #8 |
| C-17 | **Confirmed** | No stomp or trumpet (`Config/Sounds` has no trumpet or squeak). | M/S → M/S | #5 |
| C-18 | **Confirmed** | `HeroFx` only rotates the GripWeld; `BotAnimator.cast` runs for bots only (`FxController:3376`). | H/M → H/M | #9 |
| C-19 | **Confirmed** | No hero scale or "build look" hook (`ScaleTo` appears only in HordeRenderer). | M/M → M/M | #28 |
| C-20 | **Confirmed** | `PracticeYard` is set (RunDirector 3897) and read nowhere. The text fix is S. | M/M → M/M (text S) | #23 (text hotfix), #31 |
| C-21 | **Confirmed** | `CameraController` always follows your own character. Owner is **G** (CameraController per V4 ownership) plus U for the label. | M/S → M/S | #17 |
| C-22 | **Confirmed** | The Mousepedia lists names only. | M/M → M/M | #28 |
| C-23 | **Partly** | The stale ×1.5 copy exists, but RunDirector never sends a `bank` vote in v4, so it is dead code players don't see. | L/S → L/S | #18 |
| C-24 | **Confirmed** | No CaptureService, party bonus or referral. | M/S–M → M/M | #22 |
| C-25 | **Confirmed** | No weekly mutator. | M–H/M → M/M | #28 |
| C-26 | **Confirmed** | `Config/Sounds` 185–187: all 3 music ids are `""`; 10 sounds share `electronicpingshort`. Asset ids must be verified (V4 rule), so effort is M. | H/S–M → H/M | #5 |
| C-27 | **Partly** | The preview's gameplay camera is bare, but GroundScatter (client) is not in the preview, so verify in Studio. | H/M → H/M | #24 |
| C-28 | **Confirmed** | `GroundScatter` has 0 cheese references. | M–H/M → M/M | #24 |
| C-29 | **Confirmed** | `boss_poses.png` (unchanged since 2026-11-16): the same lean on every boss. | H/L → H/L | #27 |
| C-30 | **Confirmed** | The elite crown is a neon cylinder (`MouseModels` 293–305). | L/S → L/S | #29 |

### Zombie World (Z): v5 plan refinements (v5 is not built yet)

| Id | Verdict | Reason (one line) | I/E reported → verified | Merged into |
|---|---|---|---|---|
| Z-1 | **Confirmed** | Runtime humans kill 75–94 mice in stage 1 and 144 over 2 stages. At 1 rind per mouse plus shares and boss/champion splits, that is about 1.5–2.5k per full run, against V5's 8–15k. | H/S → H/S | #3b |
| Z-2 | **Confirmed** (math) | 1,200 points per class ÷ about 6 per run = 200 runs per class, 1,400 for all 7. It punishes switching class. | H/S → H/S | #3c |
| Z-3 | **Partly** | The ×10 display is cosmetic. A steeper Pressure multiplier is fair, but HANDOFF's "board barely separates" is about stages cleared, not rewards. | H/S → M/S | #3c |
| Z-4 | **Partly** | Fine but optional (1.62 champion kills per stage measured). | M/S → L/S | #31 |
| Z-5 | **Confirmed** | V5 B2 lists 6 thresholds; `Config/Classes` has 4 locked classes (2500/2500/4000/4000). | M/S → M/S | #3d |
| Z-6 | **Confirmed** | `ProfileSchema.stats` has no `kills` field, so V5 B4 seeds every veteran at 0 stomps: a visible "wipe" on a live game. | H/S → H/S | #3d |
| Z-7 | **Partly** | Valid link to Pressure, but more scope on a system Z-20 already suggests deferring. | H/M → M/M | #31 |
| Z-8 | **Partly** | Good veteran content, but a server shares one match between up to 4 humans, so trials need a server-level mode: effort L. | H/M–L → M/L | #31 |
| Z-9 | **Rejected** | Most squads are 1 human + 2 bots, and Z-9's own rule is that bots never send, so gifting has almost no use. It adds a remote and abuse surface. | M/S → — | — |
| Z-10 | **Confirmed** | Nothing rewards grouping (no party bonus). Same as C-24's party bonus. | M/S → M/S | #22 |
| Z-11 | **Partly** | Reasonable depth; M/M, after v5 core. | M/M → M/M | #31 |
| Z-12 | **Partly** | Harmless, but the idle evidence it cites is unrelated (idle comes from walking and empty sectors, not start rinds). | M/S → L/S | #3c |
| Z-13 | **Confirmed** | Board Fortune overlaps the account talent `cheese_nose` (`Config/Talents`) and the M11 cap. | M/S → M/S | #3c |
| Z-14 | **Partly** | Only reachable after 200+ runs, so it belongs in iteration 3. | M/M → L/M | #31 |
| Z-15 | **Partly** | The outcome multiplier is good for **talent points**. Rejected for **stomps**: the stomp count is shown on the nameplate as a kill count, and ×6 makes it dishonest. | M/S → M/S | #3c |
| Z-16 | **Partly** | Depends on Z-1 and Z-15 pacing; the pips are a cheap good idea. | M/S → L/S | #3d |
| Z-17 | **Confirmed** | DataService has no pre-migration backup or restore path (the only "snapshot" is the save write). v7 is the biggest migration yet. | H/M → H/M | #3e |
| Z-18 | **Partly** | Fine flavour, low value. | L/S → L/S | #31 |
| Z-19 | **Partly** | Overlaps P-12; one idle fix, not two. | M/M → M/M | #6 |
| Z-20 | **Confirmed** | Boost zones duplicate the Power Totem (`Config/Pois`: up to 3 totems per stage at 80 %). Fortune and Luck charms touch cheese and loot. | H/S → H/S | #3a |
| Z-21 | **Partly** | Depends on systems that don't exist yet. | M/S → L/S | #31 |
| Z-22 | **Partly** | Already a HANDOFF open Minor. | L/M → L/M | #31 |
| Z-23 | **Confirmed** | No per-class sim report exists; it is cheap (a sim script). | M/S → M/S | #3d |
| Z-24 | **Partly** | Only valid once Z-1 lands (the rind/25 trickle scales ×5). | M/S → M/S | #3b |
| Z-25 | **Partly** | No Robux involved, so within policy; low value. | L/S → L/S | #31 |

**Totals:** 86 entries. **Confirmed 59** (P 23, C 27, Z 9) · **Partly 25** (P 7, C 3, Z 15) · **Rejected 2** (P-15, Z-9).

Duplicates merged:
- P-21 = C-16
- P-20 + C-18 (+ C-29 for bosses)
- P-12 + Z-19
- P-1 + P-29
- P-27 + C-5
- P-28 + C-6 + C-23
- P-9 + P-10
- P-7 + C-8 (kill-beat banner)
- P-22 + C-27 + C-28
- C-24 + Z-10
- Z-2 + Z-3 + Z-12 + Z-13 + Z-15
- Z-1 + Z-24
- P-14 + C-21

---

## (2) Merged, confirmed list, ranked by impact ÷ effort

Ties are broken by how much the item hurts live players today.

### #1 The Melt starts at 0.65 R: everyone drops in outside (score 3.0, H/S) · **M2** · hotfix
- **Sources:** P-4 (P-15 rejected into it).
- **Problem:** In every stage, for the first 60 s, the storm circle is already 0.65 R and its close times sit on a dead clock. All 12 heroes spawn 75–140 studs outside and take 2 %/s. Bots path straight to the centre, which pulls squads together early (more early PvP: a likely contributor to P-1). The client receives `now = 0` in the storm Fx, so the drawn ring and the server's ring disagree.
- **Evidence:**
  - `iter1-verify/storm.luau`: at t + 0.6 s, the zone has `r 445.7 → toR 289.7`, `closeStart 30`, `closeEnd 60` and `world.now 1.79e9`; all 12 heroes are OUTSIDE; a standing hero loses 125 → 22 HP in 40 s.
  - RunDirector 4430–4440 calls `buildStage` and then `K.stormTick` before the first `world:step`. World 256 sets `self.now = 0`. `K.worldNow` (3427) accepts 0. `st.step` caches step 1, so the zone is not re-set until step 2 at 60 s.
- **Change:**
  - In `K.worldNow`, return `simNow()` when `w.now <= 0`. That is a one-line fix in RunDirector. Optionally, M1 can also seed `World.new` with `opts.now`.
  - Add a RuntimeV4 assertion: at wave start, every hero is inside `world:zone().radius`, and `radius ≈ R`.
  - Optional (M1): storm damage skips heroes with `protectUntil > now` for the first 6 s of a stage.
- **Effort:** S.

### #2 Zero class XP on a wipe (score 3.0, H/S) · **P** (ClassProgress) + **M2** (summary fields) · hotfix
- **Sources:** P-2 (plus the first-match part of P-27).
- **Problem:** A new player who loses in stage 1 gets "+0 class XP" every time. The one rookie extraction ended 3 XP short of level 2.
- **Evidence:** `ClassProgress.RUN_XP` counts only perStage 60, perBossShare 200, perHeroDown 25 and perPoi 15. 7 of 7 wipes gave `classXp=0`, including 163 s, 75 kills and a champion assist.
- **Change:**
  - Add `perMinute = 10` (time in waves or boss, cap 40), `perTenMice = 1` (cap 30) and `perChampionAssist = 20` (cap 5) to `RUN_XP`.
  - Add a floor of 25 XP for any finished match.
  - On run 1, give at least `xpToNext(1) = 100`, so the first match always reaches class level 2.
  - Keep `extractMult 1.5`.
  - M2 adds `seconds`, `mice` and `championAssists` to the payout summary (MatchState already tracks `mice` for awards).
  - Check: `m3_rookie_b` would then get 27 + 7 + 20 = 54 XP.
- **Effort:** S.

### #3 V5 plan corrections, before the build starts (paper changes; each H/S or M/S) · **Lead** (V5-PLAN), then **P / M1 / M2**
- **3a. Scope cuts (Z-20), H/S, score 3.0:**
  - Drop the 3 boost-zone models, and give Power Totems a random rind / whey / XP boost instead.
  - Make the Swap Stand rinds → whey only, at 10:1.
  - Drop the Fortune and Luck charms.
  - Ship the board, stomps and evolutions before charms.
- **3b. Rebase the rind economy (Z-1 + Z-24), H/S, score 3.0, owner M1 (`Config/RunShop`) + M2 (sim guard):**
  - Rind drops ×5: normal 5, elite 15, champion 200, boss 750.
  - Altar: 6,000 rinds + 800 whey.
  - Whey trickle: +1 per 100 rinds.
  - Guard in IntegrationSquads: the human's median per full run is 8–15k rinds, and 4–7k by stage 3.
- **3c. Herd Talent Board (Z-2, Z-13, Z-3, Z-15, Z-12), H/S, score 3.0, owner P:**
  - Make it **account-wide** (`herdTalents = {points, spent, ranks}`).
  - 12 talents: the V5 list minus Fortune; Alchemy merged into Scavenger; add Focus (−0.2 % cooldown × 25) and Homing Call (−0.15 s redeploy × 20).
  - Talent-point multiplier `1 + 0.15·P`, and outcome ×1 / ×1.5 / ×2 (wipe / extract / clear) **on talent points only, never on stomps**.
  - A weekly band bonus (100 / 250 / 500 / 900 / 1,500) once per band per week.
  - Packed Lunch (+20 start rinds per rank, 20 ranks) is optional.
- **3d. Stomps and unlocks (Z-6, Z-5, Z-16, Z-23), H/S, score 3.0, owner P (+M2 for the sim report):**
  - Veteran seed: `classes[id].stomps = floor(1.2 × lifetime class XP)`, `stats.stomps = Σ`, and a one-time toast. Never 0 for a veteran.
  - Free unlocks: le_fante 3,000; filet 8,000; jumbo 4,000 elephante + 4,000 on any other class; fizzante 6,000 ele_fonte + 6,000 ellie_fawn.
  - Evolution pips every 20 %.
  - A per-class stomps-per-minute sim report (7 × 24 seeds).
- **3e. Save safety (Z-17), H/M, score 1.5, owner P:**
  - Before the first v7 write, copy the v6 profile once to `backup_v6/<userId>`, or document the restore path through DataStore versions (`GetVersionAsync`).
  - Add an admin-only restore (not a remote).
  - Log a daily count of charm grants per player.

### #4 The route gamble never happens (score 3.0, H/S) · **M1** (BotBrain) + **M2** (RunDirector default)
- **Sources:** C-1.
- **Problem:** 17 of 18 cleared stages were Low, and none were High. The High showcase blessings are never seen.
- **Evidence:** `BotBrain.safeOption` / `VOTE_SURPRISE 0.15` (lines 157, 1222–1229, 1305–1307), `RunDirector.runRouteChoice` (2636–2643), and the `routes.luau` re-run.
- **Change:**
  - Bot-squad tier policy:
    - stages 1–2, squad HP ≥ 60 %: Low 50 / Mid 35 / High 15;
    - the squad's pot below the leading squad's: High +20 points;
    - HP < 50 %: Low 80 / Mid 20.
  - No winner: random, weighted Low 40 / Mid 45 / High 15.
  - Sim guard: ≥ 30 % of clears Mid or High, and ≥ 8 % High.
- **Effort:** S.

### #5 No music and placeholder sounds (score 1.5, H/M) · **G**
- **Sources:** C-26, C-17.
- **Problem:** A live game with silent music beds, where 10 sounds share one ping.
- **Evidence:** `Config/Sounds` 185–187 have `id = ""`; there is no trumpet or squeak.
- **Change:**
  - 3 music beds (lobby, run, boss), with Music volume at 0.35 per V4.
  - A squeak pack, pitch 0.92–1.12, capped at 6/s.
  - A trumpet on ability cast, revive and level-up.
  - A telegraph sound per pattern base: slam, charge, volley, summon.
  - Client stomp shockwave every 4th melee hit.
  - Every id must be verified as existing (V4 rule); otherwise leave it `""` + TODO.
- **Effort:** M (sourcing). The wiring itself is S.

### #6 Idle time and long walks (score 1.5, H/M) · **M1** (WaveDirector)
- **Sources:** P-12, Z-19.
- **Problem:** Humans have no mouse within 30 studs for 31.8 % of wave time, up to 69 % in stages 3–4.
- **Evidence:** v4-report (24 seeds); runtime idle streaks of 33–39 s; HANDOFF §5.
- **Change:**
  - When a standing hero has `nearMice < 3` for 5 s, spawn a cluster of `4 + stage` mice at 30–40 studs, inside the circle. At most 1 per 6 s per hero, inside the per-hero cap.
  - When ≤ 2 squads are in the run, multiply `PER_HERO_RATE` by 1.25.
  - Target: sim idle ≤ 20 %, p75 ≤ 30 %.
  - Z-19's Lure Horn is not needed if this lands.
- **Effort:** M.

### #7 Bot heroes snap: no client interpolation (score 1.5, H/M) · **M2** (BotService) + **G** (client renderer)
- **Sources:** P-19.
- **Problem:** 11 of 12 heroes in a solo match are bots moved by server `PivotTo` every Heartbeat. Their motion arrives at replication rate with jitter.
- **Evidence:** `BotService.pose` (lines 398–406). `BotAnimator` only writes C0s.
- **Change:**
  - The server stops moving the visible model. It keeps a hidden anchored root (for tags and hit tests) updated at 10 Hz, plus attributes `X`, `Z`, `Face` and `Mode`.
  - The client clones the BotModel locally and renders it 100 ms behind with a position lerp and a yaw lerp (rate 12/s), as HordeRenderer does.
  - Verify in Studio (the emulator cannot show this).
- **Effort:** M.

### #8 The player hero is the ugliest model (score 1.5, H/M) · **G**
- **Sources:** P-21, C-16.
- **Problem / evidence:** `heroes.png` against `bots.png`.
- **Change:**
  - A free "Herd Suit": hide the avatar's body parts and weld the BotModel elephant body at scale 1.0 to the HumanoidRootPart, with the class hat and weapon.
  - The head, face and hats stay optional.
  - A setting switches between Suit and Avatar + hood.
  - Skins and tints apply to the suit; the hitbox is unchanged.
- **Effort:** M.

### #9 Animation: heroes and bots have no attack anticipation (score 1.5, H/M) · **G**
- **Sources:** C-18, P-20.
- **Problem:** Player attacks rotate only the weapon. Bot idle, walk and attack look the same.
- **Change:**
  - One shared procedural layer, used by the suit (#8), BotAnimator and the R15 fallback:
    - melee: a 0.12 s wind-up (lean back, squash 0.9), a 0.08 s strike (stretch 1.1, weapon arc ≥ 90°) and a 0.2 s ease-out;
    - ranged: recoil plus a trunk kick;
    - cast: rear up (bots already have this);
    - a hit flinch, a downed crawl and a revive hop.
  - Mice: a hop-lunge.
- **Effort:** M.

### #10 New players' squads wipe in stage 1 (score 1.5, H/M) · **M1** (World, BotBrain) + **M2** (rookie flags)
- **Sources:** P-1, P-29.
- **Problem:**
  - A BotBrain-driven human's squad is eliminated in stage 1 in 21–33 % of matches, and in 67–75 % overall.
  - A real rookie plays worse than BotBrain.
  - Rookie protection covers only the rookie hero against bots in stage 1. The rookie's own bot squadmates are fair game and are OUT at level 1–4 in every log, which leaves the rookie alone.
- **Evidence:**
  - IntegrationSquads: 8/24 stage-1 human-squad eliminations and 0.88 stage-1 eliminations per match. v4-report: 5/24.
  - `World._rookieSafe` (4066) checks only `h.rookie`.
  - The runtime "7 of 8" is inflated (0-kill driver runs, duplicate seeds, champion beelining), and the P-4 storm bug hits every drop-in.
- **Change** (runs 0–2):
  - In stage 1, `_rookieSafe` also covers the rookie's bot squadmates against enemy bots.
  - Mice deal ×0.7 damage to the rookie's squad in stage 1.
  - `BotBrain.ROOKIE_STAGES` goes from 1 to 2 (bots don't target rookies in stage 2 either).
  - A rookie's bot squadmates put revive first (revive weight ×2).
  - A one-time "Press E: Second Wind" pulse on the first down.
  - Add an IntegrationSquads variant with `rookie = true` on the human. Target: stage-1 human-squad elimination ≤ 12 %.
  - Re-measure after #1. Do not tune the general difficulty yet.
- **Effort:** M. The `ROOKIE_STAGES` constant alone is S.

### #11 A wipe pays 4 % of a win (score 1.5, H/M) · **M2** (MatchState payout) · check with P for M11
- **Sources:** P-3.
- **Evidence:** Wipe median 80 against a win median of 2,197; unlocks cost 2,500–4,000.
- **Change:**
  - Stage floor 40 → `40 + 25 × stagesReached`.
  - A wipe also banks 15 % of the pending pot (the secured 25 % is unchanged).
  - Target: wipe median ≈ 10 % of the win median, staying below extraction so Stay/Extract keeps its meaning.
  - Tune the sim human to extract at pot ≥ 600 or HP < 40 % (stage ≥ 2), then re-measure.
- **Effort:** M (economy plus a sim re-run).

### #12 Results: MVP always a bot, PvP-only counters (score 2.0, M/S) · **M2** (awards) + **U** (ResultsUI)
- **Sources:** P-10, P-9.
- **Problem / evidence:** 11 of 11 MVPs were 🤖. "Kills: 0" was shown with 144 mice killed.
- **Change:**
  - When any human is in the match, the MVP is the best-scoring human; show "Top 🤖" separately.
  - Every human gets at least 1 accolade (fallback: "Mouse Masher: N mice").
  - Results stats become: 🐭 Mice · 👑 Champions helped · 🧀 POIs · ⚔ Rivals downed.
- **Effort:** S.

### #13 Toast flood, and the boss kill is a toast stack (score 2.0, M/S) · **U** (Toasts) + **M2/P** (sources)
- **Sources:** P-7, C-8 (kill beat).
- **Change:**
  - Three priorities:
    - **critical:** downs, champion, boss, Melt, gate. Never dropped; may evict others.
    - **game:** levels, gear.
    - **meta:** Mousepedia, achievements, contracts. Held until Results or the lobby as one line, "+N discoveries".
  - Coalesce level-ups ("Level 9 → 13").
  - The boss kill becomes one "STAGE CLEAR" banner (cheese, blessing, Epic) instead of 4–5 toasts.
- **Effort:** S.

### #14 Results undersells the first extraction (score 2.0, M/S) · **U** + **P** (result breakdown in `awardRun`)
- **Sources:** P-8.
- **Change:**
  - A breakdown: pot share, secured, first-of-day, FIRST EXTRACTION +500 / ✨50 (with its own card), contracts and achievements, then the total.
- **Effort:** S.

### #15 Contracts out of reach for new players (score 2.0, M/S) · **P**
- **Sources:** P-11.
- **Change:**
  - Easy `d_mice` 1,200 → 300, and `d_gear` 4 → 2.
  - A rookie pool for runs 0–5: Finish 2 matches, Stomp 150 mice, Activate 2 POIs, Reach level 5 in a run.
  - "Bank" goals become `max(300, 2 × the player's 7-day median payout)`.
- **Effort:** S.

### #16 Key decisions start folded (score 2.0, M/S) · **U**
- **Sources:** C-5, P-27.
- **Change:**
  - Route and Extract panels open at full size with inline curse and blessing text for 4 s, or until the player votes, then fold.
  - Pulse the gate while unvoted.
  - Rookies get the Extract card expanded, with "You'll bank 🧀 N + FIRST EXTRACTION 🧀500 ✨50".
- **Effort:** S.

### #17 Dead time: Herd Call is too slow, and there is no spectating (score 2.0, M/S) · **M2** (MatchState) + **G** (CameraController) + **U** (label)
- **Sources:** P-14, C-21.
- **Change:**
  - `REDEPLOY_DELAYS` 20 / 25 / 30 / 35 → 12 / 15 / 18 / 22.
  - A timer started during the waves finishes into the boss phase, dropping in at the boss-ring edge.
  - A dead hero spectates the nearest standing squadmate: "Spectating X · back in N s", cycled with tap or Q.
  - Target: ≥ 60 % of redeploy timers complete (sim).
- **Effort:** S.

### #18 Double or Nothing is unreadable and untested (score 2.0, M/S) · **U** + **M2** (sim policy)
- **Sources:** P-28, C-23; C-6 as the follow-up.
- **Change:**
  - A Results row "🎲 Double or Nothing lost: 🧀 X" or "won ×2".
  - Delete the dead v1 `bank` and `cycle` branches in VoteUI (C-23).
  - A sim policy that takes DoN 30 % of the time, to measure its expected value.
  - Later: the Bookie rat (C-6, G + U, M).
- **Effort:** S.

### #19 The upgrade picker interrupts combat (score 2.0, M/S) · **U**
- **Sources:** P-13.
- **Change:**
  - Hold offers while ≥ 6 mice are within 20 studs; open after 1.5 s of calm, or after at most 8 s.
  - A phone "auto-pick recommended" toggle.
  - Hide the gear row while the picker is open.
- **Effort:** S.

### #20 Only the boss winner drafts a blessing (score 1.5, H/M) · **M2** + **U**
- **Sources:** C-2.
- **Change:**
  - Every squad still in the run picks 1 of 3 blessings (Low / Mid / High).
  - Mid and High come with a squad-only hex for the next stage: −15 % max HP (Mid), or +25 % mice aggro on that squad (High).
  - The winner still chooses the map, boss and curse, and gets a free blessing reroll.
- **Effort:** M.

### #21 Personality: lore, barks, the witch wheel (score 2.0 each, M/S) · **P** (config `lore`) + **U/G**
- **Sources:** C-7, C-14, C-10.
- **Change:**
  - A `lore` string on Bosses, Classes, Champions and Maps, shown on the boss bar intro, the Mousepedia and the class picker.
  - Barks as a rate-limited BillboardGui, at most 1 per source type on screen.
  - The witch wheel: one slice per `options` entry, spun and eased out over `reveal`.
- **Effort:** S each.

### #22 Reward grouping (score 1.0–2.0, M/S–M) · **P** + **M2** + **U**
- **Sources:** Z-10, C-24.
- **Change:**
  - +10 % pass XP and talent points per other human in the squad (max +30 %), +5 % more if any is a Roblox friend. Bots never count.
  - Later: a CaptureService share card (M).
- **Effort:** S for the bonus.

### #23 Small live text and shop fixes (score 1.0, L/S, but trivial) · **P/U/M2** · hotfix
- **Sources:** P-16, P-26, C-20 (text).
- **Change:**
  - Gate the "Pressure unlocked!" toast to runs ≥ 3; the lobby text becomes "Extract or win a run to unlock Pressure".
  - Hide shop items with `assetId == 0` instead of showing "Coming soon".
  - Change the PracticeYard toast to "No seat this round. You'll join at the next stage start."
- **Effort:** S.

### #24 Maps: identical layout, bare play view (score 1.5 / 1.0) · **G** (+M1 `Maps`)
- **Sources:** C-27 (H/M), P-22 (H/L), C-28 (M/M).
- **Change, in order:**
  1. Prop vignettes of 3–6 parts around each POI and along paths, and terrain dishes and bumps every ~25 studs, streamed within 90 studs of the camera.
  2. A cheese motif per map in ground paint and scatter (C-28 table).
  3. 2–3 asymmetric landmarks of 40–80 studs and per-map path topology.
  - Add a "gameplay camera + GroundScatter" panel to `render-preview` first, so the change can be judged.
- **Effort:** M, then L.

### #25 First map vote in the lobby (score 1.0, M/M) · **M2** + **U**
- **Sources:** C-3.
- **Change:** Show the 3 stage-1 Low cards on the lobby board during the countdown. The human plurality wins and bots abstain. Pass the index to `match:begin(idx)`.

### #26 Boss arrival and kill ceremony (score 1.0, M/M) · **G** + **U**
- **Sources:** C-8.
- **Change:**
  - A 2.5 s intro card (portrait, name, title, lore hook, "Watch for").
  - On the kill: 0.4 s slow-mo plus a camera punch, then a part-built chest burst.
  - 60 ms hit-stop on crits against champions and bosses.

### #27 Boss animation (score 1.0, H/L) · **G**
- **Sources:** C-29.
- **Change:** Bones in BossModels, and one clip per pattern base (slam, charge, volley, summon, roulette, breath), about 10 clips for 13 bosses. Plan for iteration 2.

### #28 Content depth (score 1.0 each, M/M) · **G / M1 / P / U**
- **Sources:** P-23, C-13, C-19, C-22, C-25.
- **Change:**
  - Shrine silhouettes and POI ground rings (P-23).
  - Per-map mouse dress (C-13).
  - Build look: +5 % scale per size card, capped at ×1.3, visual only (C-19).
  - Mousepedia entry cards with silhouettes (C-22).
  - A weekly mutator (C-25).

### #29 Low-impact polish (score 1.0 each, L/S) · **U / G / P / M2**
- **Sources:** P-17, P-24, P-25, P-30, P-31, C-12, C-30.
- **Change:**
  - Hide the combat HUD under Results (P-17).
  - "Paused while you shop" (P-24).
  - Claim only on reachable tiers, and a single reroll control (P-25).
  - Silent back-fill (P-30).
  - Re-export the previews and add `heroes.png` plus a HUD pass (P-31).
  - Boss home map at 50 %, with "Home turf!" +10 % cheese (C-12).
  - A 3-point gold crown, with the body lerped 30 % toward gold (C-30).

### #30 Phone layout overflow (score 2.0, M/S, but verify on device first) · **U**
- **Sources:** P-18.
- **Change:**
  - Short squad tags on the phone header.
  - Drop the boss epithet on touch.
  - Move hints above the joystick zone.
  - Enforce the 12 px floor on Toasts, Hints, Upgrades and Results.

### #31 Later iterations (score ≤ 1.0)
- C-4 Go Deeper (M/L)
- C-9 boss trophies (M/M, after v5)
- C-11 map hazards (M/L)
- C-15 Mouse King (L/M)
- C-20 practice yard build (M/M)
- Z-4 escalating champion talent points (L/S)
- Z-7 charm tiers (M/M)
- Z-8 Trials (M/L)
- Z-11 class rank lines (M/M)
- Z-14 Prestige (L/M)
- Z-18 relics (L/S)
- Z-21 broadcasts (L/S)
- Z-22 speed boards (L/M)
- Z-25 witch talent points (L/S)

---

## (3) Hotfix now: confirmed bugs hurting live players, small to fix

| # | Fix | Owner | Size | Test |
|---|---|---|---|---|
| H1 | **Storm time base (P-4):** `K.worldNow` falls back to `simNow()` when `world.now <= 0`, so the first circle is R and closes to 0.65 R over 30–60 s. | M2 (RunDirector) | 1 line | RuntimeV4: every hero is inside the zone at wave start, and `radius ≈ R`. |
| H2 | **Raw title ids (P-6):** in `Util/Progression.reward`, `name = str(r.name or r.label)` (drop `r.title`), so the namer resolves "Title: Winter Herd". | U | 1 line | Client spec: a `{title="title_winter_herd"}` reward text has no `title_`. |
| H3 | **Objective arrow ids (P-5):** in `MinimapUI` 894, `label = Pois def name or pp.kind`. | U | S | Client spec. |
| H4 | **Zero class XP on a wipe (P-2):** add minutes, mice and champion assists, a 25 XP floor, and level 2 guaranteed on run 1 (#2). | P + M2 | S | DataClassProgress spec: a stage-1 wipe of 160 s with 75 mice gives > 0. |
| H5 | **Rookie text (P-16):** no "Pressure unlocked!" toast for runs < 3; the lobby lock text drops "Go Home". | P + U | S | — |
| H6 | **Dead shop card (P-26):** hide Robux items whose `assetId == 0` (the Emote Pack). | U (ShopModel / ShopUI) | S | Client spec. |
| H7 | **Practice-yard promise (C-20):** change the toast to say when they will join. | M2 | S | — |
| H8 | (balance, optional) `BotBrain.ROOKIE_STAGES = 2` (P-29). | M1 | 1 constant | BotBrain spec. |

Notes:
- The UI art and health-bar teams are editing `src/client` now. H2, H3 and H6 are a few lines each, so the lead should sequence them after those teams checkpoint.
- H1 is the most valuable: it changes the first minute of every stage for every hero. It may also lower the stage-1 wipe rate (#10), so re-measure #10 after H1.