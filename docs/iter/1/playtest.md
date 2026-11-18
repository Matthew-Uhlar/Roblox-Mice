# Iteration 1 — Playtest report

Team: Playtest (read-only on `src/`). Date: 2026-11-18. Build: v4 branch as checked out (equivalent to live place v7, apart from the product ids merged since).

## How we played

- **Runtime emulator.** We ran 11 full matches of the real server and client scripts at default timings (150 s waves, real storm, no 25× power-up), plus 3 lobby walkthroughs, using our own driver (`match.luau` and `lobby.luau` in the scratchpad `iter1-play/`; nothing was added to the repo).
  - The driven player walks like a person: champions first, then POIs, then the nearest mice. It stays inside the Melt, circles the boss, casts its ability every 1.5 s, takes upgrade cards through the real UI, answers the Rind Gate by profile, then presses Play Again.
  - The "careful" variant retreats below 45 % HP and skips champions until level 4.
  - Profiles played: rookie on PC at 1280×662 safe area, a veteran (85k cheese, 120 runs, Pressure unlocked), and a phone (touch, 667×375, which is a 667×317 safe area).
  - We also ran 3 "buff" runs (heroes ×3 HP) only to reach the later gates: Stay, Double or Nothing (DoN), Extract at stage 2 and Herd Call.
  - The emulator's automatic seed was varied per run.
  - Result: **0 script errors and 0 emulator gaps in every run.**
- **Headless sim.** `lune run tests/sim/v4-report.luau 24`: 24 seeds of a solo bot-brained human plus 11 bots.
- **Renders.** We ran `scripts/render-preview.luau` and then `render-preview.py` into the scratchpad. The PNGs were read directly: maps, heroes, bots, bot poses, mice, champions, bosses, POIs, lobby and portal. The committed `assets/previews/*` date from 2026-11-16 and are stale (pre-v4).
- **HUD.** We wrote a UIScale-aware layout auditor (off-screen, overflow, tiny text, small touch targets, overlapping buttons across ScreenGuis).

  The emulator's GUI geometry ignores UIListLayout and real text metrics, so the phone layout entries are marked **verify on device**. Two auditor findings were rejected as emulator artefacts: a perk-tree overflow (PerkTreeUI divides an unscaled AbsoluteSize by scaleOf) and the lobby bar sitting under the top bar.

### Headline numbers

| Source | Result |
|---|---|
| Runtime, 8 default-HP matches (rookie ×4, veteran ×2, phone ×2) | **7 squad eliminations in stage 1** (at 58–163 s of play) and 1 extraction after stage 1. **Class XP was 0 in all 7 wipes.** |
| Runtime, 3 buffed matches | Veteran: DoN at gate 1, then eliminated in stage 2 by bot PvP. Phone: Stay, then Extract at stage 2 (435 s). Leaver: our script crashed after `removePlayer` (driver bug, not a game bug). RuntimeLeave already covers the leaver payout. |
| Sim, 24 seeds | Human wins 8 and wipes 16. Matches by stages played (1/2/3/4): 5/7/2/10. Idle 31.8 % of wave time (p75 48.6 %, up to 69 % in winning runs). Payout median 122; wins median 2,197; wipes median 80 (4 % of a win). Herd Call: 10 redeploys from 29 timers. Human storm damage: 1 HP per match. |
| Toasts | 23–87 server toasts per match. In the rookie extraction run, 66 toasts arrived in 3 min 35 s. |

---

## Entries

### P-1 — New players' squads wipe in stage 1
- **Type:** balance · **Impact:** H · **Effort:** M
- **Evidence:**
  - Runtime: 7 of 8 default matches ended with *"Brie squad is eliminated!"* during stage 1. Elapsed times were 72 s, 73 s, 73 s, 81 s, 98 s, 158 s and 163 s, in both reckless and careful play.
  - Most damage came from mice. Example: `m3_rookie_b` took 129 contact + 9 projectile damage before going down in the boss phase. The bot squadmates also went down: *"Squeaky 🤖 is down… Marshmallow 🤖 is down… out until the next stage"*.
  - Sim: 21 % of matches end in stage 1 and 67 % end in a wipe, and the sim's "human" is a full BotBrain, which plays better than a real new player.
  - Rookie Run protection only covers enemy bots and the first champion's HP. Nothing protects a rookie from the horde.
- **Proposed change:**
  - During a player's runs 0–2, stage 1 only: mice deal 0.6× damage to the rookie's squad and spawns ramp over 60 s instead of 30 s.
  - Bot squadmates of a rookie revive first and use their own Second Wind.
  - Show a "Press E: Second Wind" pulse the first time the rookie is downed.

### P-2 — Class XP is 0 after a stage-1 wipe, however well you played
- **Type:** balance / retention · **Impact:** H · **Effort:** S
- **Evidence:**
  - `ClassProgress.runXp` only counts `stagesSurvived`, `bossDamageShare`, `heroDowns` and `pois`.
  - `m3_rookie_b`: 163 s, 75 mice killed, 1 champion assist, result `classXp=0`.
  - All 7 wipes gave `classXp=0`, and the Results screen showed *"Elephante · +0 class XP"*.
  - The one rookie success (`m3_rookie_f`, extracted after stage 1) ended at *"LV 1 · 97 / 100 XP"*, 3 XP short of the first class level-up.
- **Proposed change:**
  - Add XP per minute alive (about 15/min), per 25 mice (+5) and per champion assist (+30). Keep the extract multiplier.
  - Guarantee class level 2 at the end of the first match.

### P-3 — A wipe pays 4 % of a win, so early progression stalls
- **Type:** balance · **Impact:** H · **Effort:** M
- **Evidence:**
  - Sim payout: wipes median 80 versus wins median 2,197. Runtime wipes paid 40 (plus the 40 first-of-day bonus).
  - Class unlocks cost 2,500–4,000 cheese, which is about 31 wipe runs per class at the median.
  - The sim human never extracts: all 8 wins were Last Herd or the final stage. So the Stay/Extract decision rarely pays off in practice.
- **Proposed change:**
  - Raise the stage floor from 40 to 40 + 25 × stage, and pay a share of the kill-based pot on a wipe (for example 20 % of pending).
  - Tune the sim human's extraction threshold so extraction actually happens, then re-measure.

### P-4 — "⚠ OUTSIDE THE MELT!" fires at drop-in
- **Type:** bug · **Impact:** M · **Effort:** S
- **Evidence:**
  - In all 11 runtime matches, the HUD dump 3 s into stage 1 shows `⚠ OUTSIDE THE MELT! Get inside the circle` next to `🛡 Spawn protection 0:06`. `m3_rookie_f` took 24 HP of `zone` damage.
  - Cause:
    - Squad corners sit at R − 0.1 R (`Pois.SAFE_ZONE_INSET_FRAC`).
    - The storm centre is offset by up to 0.1 R (`Storm.CENTER_OFFSET`).
    - The first circle's radius is exactly R.
    - The spawn ring adds another 4 studs, so a squad can drop in outside the first circle.
- **Proposed change:** Make the first zone's radius `R + CENTER_OFFSET × R + 10`, or clamp the drop-in point inside the circle. Also, no storm damage while spawn protection is active.

### P-5 — The objective arrow shows internal ids
- **Type:** UX bug · **Impact:** M · **Effort:** S
- **Evidence:**
  - HUD text during play: `elite_camp 251m`, `cheese_cache 140m`, `shop_cart 65m`.
  - `src/client/UI/MinimapUI.luau:894` sets `label = pp.kind`.
- **Proposed change:** Map the label through the POI display name in `Config/Pois` (for example "Elite Camp 251 m").

### P-6 — Raw title ids in the Herd Pass and Achievements
- **Type:** UX bug · **Impact:** M · **Effort:** S
- **Evidence:** The Herd panel dump shows `Free: 🏷 title_winter_herd`, `🏷 title_star_herd`, `title_last_herd`, `title_pressured`, `title_squeezed` and `title_streak_keeper`.
- **Proposed change:** Resolve the display names, for example "Title: Winter Herd".

### P-7 — Toast flood buries important messages
- **Type:** UX · **Impact:** M · **Effort:** S
- **Evidence:**
  - 66 toasts in 3 min 35 s (`m3_rookie_f`) and 87 in the phone run.
  - In one stage: 13 "Level N!" toasts, 6 "Mousepedia: new … entry! +5 Golden Cheese", plus achievement toasts.
  - `Toasts.luau` shows at most 3 at once and drops anything past `MAX_QUEUED = 6`. Messages that matter can be lost behind the noise: "Tester is down! Stand close to revive", "Champion appears", "The Melt closes in".
  - On a phone the toast text measured 10.4 px (verify on device).
- **Proposed change:**
  - Add priorities: combat-critical messages beat rewards.
  - Fold level-ups into one "Level 9 → 13".
  - Hold Mousepedia, achievement and contract toasts until Results or the lobby, as one "+3 discoveries" line.

### P-8 — Results undersells what you actually earned
- **Type:** UX / retention · **Impact:** M · **Effort:** S
- **Evidence:**
  - Rookie first extraction: the Results headline is `+220`, but the profile went from 0 to 1,290 cheese and from 0 to 80 Golden Cheese.
  - The extra 1,070 cheese came from:
    - the first-of-day bonus (+220);
    - **FIRST EXTRACTION +500 and +50 Golden Cheese**, shown only as one toast among 4 others;
    - contracts and achievements.
  - The phone run had the same gap: `+195` on Results against +1,240 in the profile.
- **Proposed change:** Results shows a breakdown (pot, secured, bonuses, first extraction, contracts, achievements) ending in the total. Give the first extraction its own celebration card.

### P-9 — The "Kills" and "Downs" counters on Results read 0
- **Type:** UX · **Impact:** L · **Effort:** S
- **Evidence:**
  - Every run shows `☠ Kills: 0 | 💫 Downs: 0`. For example, `m4_phone_i` had 144 mice killed and was downed itself.
  - These counters only count hero PvP, which a new player reads as "I did nothing".
- **Proposed change:** Show mice slain, champions helped, bosses and POIs, and label PvP explicitly ("Rivals downed").

### P-10 — The MVP is always a bot, and the human gets no accolade
- **Type:** UX / retention · **Impact:** M · **Effort:** S
- **Evidence:**
  - 11 of 11 runs had a 🤖 MVP (Marshmallow, Pachy, Waffles, Bumble, Biscuit, Rumble…), often from another squad.
  - `Awards.you` never carried a title.
- **Proposed change:**
  - MVP is chosen among humans when any are present. Bots still appear on the scoreboard.
  - Always give each human at least one personal accolade, such as "Mouse Masher: 144 mice" or "Best run on this class".

### P-11 — Contracts are out of reach for new players
- **Type:** UX / balance · **Impact:** M · **Effort:** S
- **Evidence:**
  - A fresh profile's dailies were "Bank 1,000 cheese" (a rookie banks 40–220 per run), "Help defeat 4 Mouse Champions" and "Pick up 4 gear items".
  - The weeklies were "Bank 6,000 cheese" and "Defeat 8 bosses".
  - With stage-1 wipes, none of these progresses in a first session.
- **Proposed change:** During runs 0–5, draw from a rookie pool: play 2 matches, slay 200 mice, activate 3 POIs, reach level 5 in a run. Scale "bank" goals to the player's recent average.

### P-12 — Long walks and idle time
- **Type:** balance · **Impact:** H · **Effort:** M
- **Evidence:**
  - Sim idle (no mouse within 30 studs and no enemy hero within 45): 31.8 % on average and p75 48.6 %. It reaches 49–69 % in winning runs, because late stages have only 2 squads on big maps.
  - Runtime longest idle streaks: 33–39 s (walking from the corner to POIs and champions).
  - Map renders (`map_*.png` gameplay camera) show bare ground in the play frame.
- **Proposed change:**
  - Spawn mice packs relative to heroes, in a ring at 25–45 studs, whenever none are within 30 studs.
  - Add roaming "cheese wagon" mini-events in empty sectors.
  - Shrink R for stages 3–4, or pull POIs inward as the Melt closes.

### P-13 — The upgrade picker interrupts combat too often
- **Type:** UX · **Impact:** M · **Effort:** S
- **Evidence:**
  - `m3_rookie_f`: 16 UpgradeOffers and 25 picks in one stage, with level 9 → 13 during the route choice. `m4_phone_i` had 13 offers.
  - On the phone, the card panel overlaps the HUD gear slots (auditor: BUTTON_OVERLAP between Card1–3 and Gear_weapon, armor and trinket), and card text measured 10.4 px (verify on device).
- **Proposed change:**
  - Queue offers while mice are within 20 studs, and open them in a calm moment or at the gate.
  - Add an "auto-pick recommended" toggle for the phone.
  - Hide the gear row while the picker is open.

### P-14 — Herd Call rarely completes
- **Type:** balance · **Impact:** M · **Effort:** S
- **Evidence:** In the sim, 10 redeploys came from 29 started timers (34 %). A timer is cancelled by the boss, by the last 20 s of the waves, or when no squadmate is standing.
- **Proposed change:**
  - The base delay of 20–35 s is too long against 150 s waves. Use 12 / 15 / 18 / 22 s.
  - Let a timer that started during the waves finish on the boss arena edge instead of being cancelled.

### P-15 — Storm pressure is near zero apart from drop-in
- **Type:** balance · **Impact:** L · **Effort:** S
- **Evidence:** Human storm damage in the sim was 1 HP per match. In the runtime, only the P-4 drop-in damage occurred (5–24 HP).
- **Proposed change:** This is fine as a nudge. Consider showing the next circle on the minimap at the start of each stage, so the Melt reads as a plan rather than a surprise. Lower priority than P-12.

### P-16 — "Pressure unlocked!" fires on run 1 although Pressure is hidden until run 3
- **Type:** UX bug · **Impact:** L · **Effort:** S
- **Evidence:**
  - A rookie who extracted on run 1 got *"Pressure unlocked! Stack modifiers in the lobby for more cheese."* (`DataService.luau:1062`, with no rookie gate). `RunState` hides Pressure for runs below `ProfileSchema.ROOKIE_RUNS = 3`.
  - The lobby lock text still says *"Win a run (Go Home) to unlock Pressure"*, using the old term.
- **Proposed change:** Defer the toast to the first lobby visit after run 3, and replace "Go Home" with "Extract".

### P-17 — The combat HUD stays live under Results
- **Type:** UX · **Impact:** L · **Effort:** S
- **Evidence:**
  - The Results dump still shows `🔥 Melt closes 0:09`, the objective arrow `shop_cart 65m`, `Stage 2/4 · Survive the horde!` and the full squad HUD behind the panel.
  - On the phone, the HUD gear buttons overlap 🐘 Play Again (verify on device).
  - During the Rind Gate the header already names the next map (`Stage 1/4 · Cheddar Volcano`).
- **Proposed change:** Hide the TrunkfallCombat and TrunkfallHud screens once the player is out, and keep the current map name until the next stage starts.

### P-18 — Phone layout: crowded text and overlaps (verify on device)
- **Type:** UX · **Impact:** M · **Effort:** S
- **Evidence:** Auditor at 667×317, in `m4_phone_i` and `m3_phone_e`:
  - The hint "Got it ✔" overlaps the 📍 Ping button by 42×40 px.
  - The header scoreboard touch target is 28 px tall.
  - "Pepper Jack" gets 42 px, "Fizzante 1" gets 35 px, and the boss title "Ancient Ice Dragon · Frost of the Blue Peaks" overflows 235 px.
  - "They won the boss, so they pick the next route for everyone." needs about 382 px but has 231.
  - Results captions measured 10.4 px.
- **Proposed change:**
  - Move phone hints above the joystick zone.
  - Use short squad tags (SWS / BRI / BLU / PJ) on the phone header.
  - Drop the boss epithet on touch.
  - Enforce the 12 px text floor on Toasts, Hints, Upgrades and Results.

### P-19 — Bot heroes have no client smoothing
- **Type:** animation · **Impact:** H · **Effort:** M
- **Evidence:**
  - `BotService.luau:406` calls `b.model:PivotTo(cf)` on the server every Heartbeat.
  - `BotAnimator` only rewrites weld C0s from the root's speed. Nothing interpolates the root itself.
  - Anchored-part CFrame replication arrives at network rate with jitter, so 11 of the 12 heroes in a solo match will step and snap. Mice, by contrast, are interpolated about 100 ms behind (HordeRenderer).
- **Proposed change:** Send bot transforms in the snapshot stream, or keep a server proxy and render a client-side clone interpolated about 100 ms behind with a yaw lerp. This is the same approach as HordeRenderer.

### P-20 — Bot attacks have no anticipation or follow-through
- **Type:** animation · **Impact:** M · **Effort:** M
- **Evidence:**
  - `renders/bot_poses.png`: the idle, walk and attack columns are almost identical for all 7 classes. Only the weapon shifts a little. The ability rear-up and the downed pose read well.
  - Mice (`mice.png`): the attack lunge is barely different from idle.
  - Champions (`champions.png`): the wind-up and strike of the chemist and the golem barely differ.
- **Proposed change:**
  - Melee: a 0.12 s wind-up (lean back, squash 0.9), a 0.08 s strike (stretch 1.1, weapon arc of 90° or more), then a 0.2 s ease-out recovery.
  - Ranged: recoil plus a trunk kick.
  - Mice: a hop-lunge.
  - Champions: hold a clearly larger wind-up for the telegraph `delay`.

### P-21 — The player hero is the ugliest model in the game
- **Type:** graphics · **Impact:** H · **Effort:** M
- **Evidence:**
  - `renders/heroes.png`: the player is a grey blocky avatar with flat ring ears, a trunk made of stacked balls and a hat.
  - The bots (`bots.png`) are cute rounded elephants with faces.
  - In every squad the human stands next to two bots that look like a different game, and the human is the model the camera follows all the time.
- **Proposed change:** Hide the avatar body and weld the BotModel elephant rig, at full scale with the class hat and weapon, onto the HumanoidRootPart. Animate it locally with BotAnimator. Skins and tints then apply to the same rig.

### P-22 — Maps read as one flat disc with the same layout
- **Type:** graphics · **Impact:** H · **Effort:** L
- **Evidence:**
  - `renders/maps.png`: all 9 maps are a round plate with the same 4 spokes, a centre ring and corner domes. Only the colour changes.
  - The gameplay-camera close-ups (`map_plains.png`, `map_moon.png`, `map_volcano.png`, `map_swamp.png`) frame bare ground with 0–1 props. POIs and landmarks are tiny against R 300–560.
  - Volcano, swamp and ocean are nearly monochrome, so props and mice have low contrast with the ground.
- **Proposed change:**
  - Give each map 2–3 large signature landmarks (40–80 studs tall) placed asymmetrically, plus terrain height (ridges and basins).
  - Use a different path topology per map instead of the shared spokes.
  - Add mid-size clutter clusters every 30–40 studs within the playable radius.
  - Use darker paths and lighter clearings to separate the ground from the actors.

### P-23 — POIs and champions are simple shapes
- **Type:** graphics · **Impact:** M · **Effort:** M
- **Evidence:**
  - `renders/pois.png`: the mousetrap field is a few flat planks, the three shrines share one template, the totem is small, and the bottle and chest are single primitives.
  - `champions.png`: the Cheese Golem is a box stack.
- **Proposed change:**
  - Add a bevel and trim pass, and give each shrine its own silhouette.
  - Add a ground decal and ring per POI so it reads from the gameplay camera.
  - Give the golem a chunked cheese body with holes and a wedge crown.

### P-24 — Mixed lobby state while the shop is open
- **Type:** UX · **Impact:** L · **Effort:** S
- **Evidence:**
  - Before opening the shop, the lobby showed "Auto-start in 0:22 · Squads (1 + 11 🤖)" with named bots.
  - After opening it (SetBusy), the squads panel switched to 12 × "Empty seat · 🤖 a bot fills it at the start" and "Press READY to play".
  - On closing the shop the countdown restarts, so the lobby flickers between two states.
- **Proposed change:** Keep the bot preview and show "Paused while you shop" instead of resetting the panel.

### P-25 — Herd Pass shows 30 "Claim" buttons on locked tiers
- **Type:** UX · **Impact:** L · **Effort:** S
- **Evidence:**
  - At tier 0, every row shows `🔒 Tier N | … | Claim | 🔒 Premium`.
  - Contracts show three "🎲 Reroll" buttons, although only 1 reroll per day is free.
- **Proposed change:**
  - Show Claim only on reachable tiers, and scroll to the current tier.
  - Show reroll as one control, "Free reroll (1)", next to the selected contract.

### P-26 — "Coming soon" tiles in the Robux shop
- **Type:** UX / monetization · **Impact:** L · **Effort:** S
- **Evidence:**
  - The Emote Pack is skipped by its publish feature flag, so its card can only ever render "Coming soon" in the Packs section.
  - In the emulator every Robux item showed "Coming soon" because only the server got fake ids. Live place v7 has real ids, so only the Emote Pack is affected live.
- **Proposed change:** Hide items whose feature flag is off, instead of showing a dead card next to paid ones.

### P-27 — Rookie Extract pre-selection works, but the payoff is easy to miss
- **Type:** UX · **Impact:** M · **Effort:** S
- **Evidence:**
  - On run 1, Extract was pre-selected ("🌀 ⏱ 0:20 · Your pick: Extract | ▴ Open"), shown as a collapsed bar.
  - The hint "Extract banks your cheese. Stay risks it." appeared during the route choice, before the gate.
  - The rookie left with a 3 min 35 s run and missed class level 2 by 3 XP (see P-2).
- **Proposed change:** For rookies, open the extraction panel expanded, with "You'll bank 🧀 220 + FIRST EXTRACTION 500 ✨50" written on the Extract card.

### P-28 — DoN and Stay outcomes are hard to read and punishing for veterans
- **Type:** balance / UX · **Impact:** M · **Effort:** S
- **Evidence:**
  - Buffed veteran (`m4_veteran_g`): took DoN at gate 1, was downed by mice 13 s into stage 2 and finished by bot PvP. Result: `cheeseEarned=50`, a Wipe, with nothing on Results explaining that DoN cost the pot.
  - The sim never takes DoN (0 paid, 0 lost), so the ×2 risk is untested.
- **Proposed change:**
  - Results shows "Double or Nothing lost: 🧀 X".
  - Add a sim policy that takes DoN 30 % of the time, to measure its expected value.
  - Consider letting DoN pay if the squad survives the stage, even without a champion kill.

### P-29 — PvP still reaches a rookie from stage 2 on
- **Type:** balance · **Impact:** M · **Effort:** S
- **Evidence:**
  - Rookie phone run (`m4_phone_i`, run 1): 195 PvP damage taken, downed by 🤖 −1006 and finished by 🤖 −1004 in stage 2.
  - The veteran was finished by bot PvP during a boss.
  - Rookie protection covers stage 1 only, and bots are calmer only in stages 1–2.
- **Proposed change:** Extend rookie targeting immunity from bots to the whole of run 1, or to stages 1–2 for runs 0–2. Real humans can still fight rookies.

### P-30 — First-session achievements fire for imported veterans
- **Type:** UX · **Impact:** L · **Effort:** S
- **Evidence:** The veteran profile (120 runs) got "Achievement: First Steps!" and "Achievement: Regular!" right at the start of the match.
- **Proposed change:** This is expected for a back-fill, but grant these silently, or as one summary at login ("Back-filled 2 achievements"), not mid-match.

### P-31 — Committed preview renders are stale
- **Type:** graphics process · **Impact:** L · **Effort:** S
- **Evidence:**
  - `assets/previews/*.png` are dated 2026-11-16, before v4: no hood heroes, no storm wall.
  - Fresh renders are in the scratchpad `iter1-play/renders/`.
  - There is still no HUD render, so UI quality cannot be judged visually without Studio.
- **Proposed change:** Re-export the previews every iteration (the standing goal). Extend `render-preview` with a GUI pass that draws ScreenGui frames and text at 1280×720 and 667×375.

---

## Not issues / checked OK

- Play Again appears on Results after both a wipe and an extraction. It teleports only the caller to a reserved server and returns the server to the Lobby.
- In every run: 0 script errors, 0 emulator gaps and no unexpected warnings.
- The busy rookie is not auto-started.
- The phone auto-start fires at 30 s, and the phone's touch Extract and Stay votes go through the ExtractUI cards (0 fallbacks).
- The Herd panel's tabs (Contracts, Herd Pass, Mousepedia, Achievements, Levels, Boards) and the shop's 7 tabs open without errors on PC and phone.
- Pings and quick-chat, and the redeploy timer remote: covered by RuntimeV4 (passes, 41 s).

## Reproduce

- Scripts (in the scratchpad `iter1-play/`, which has symlinks to the repo's `tests/runtime` and `src`). Run them from the repo root:
  - `lune run <scratch>/match.luau <rookie|veteran|phone|leaver> <seedTag> [careful][_buff][fast]`
  - `lune run <scratch>/lobby.luau <rookie|veteran|phone>`
  - `lune run tests/sim/v4-report.luau 24`
  - `lune run scripts/render-preview.luau <dir>`, then `python3 scripts/render-preview.py <dir> <out>`
- Logs: `m*_*.txt`, `v4report.txt` and `lobby_*.txt` in the same scratchpad folder.
