# Iteration 1 plan (lead): built from docs/iter/1/VERIFIED.md

v4 is live as place v7. Hotfix **v4.1** ships separately from `main`:
- H1: the storm time base;
- H2: title ids shown instead of names;
- H3: objective arrow shows internal names;
- H7: the practice-yard toast.

Teams must merge `main` before they start, so these fixes are in their tree; the lead does that merge.

**Everything else below is in iteration 1.** Ownership follows the V4-PLAN table, and the ids refer to VERIFIED.md.

## A. Fix the first 10 minutes (top priority)

**M2 + P: class XP on a wipe (P-2, H4).**
- Rates: +10 class XP per minute played, +1 per 10 mice, +20 per champion assist.
- At least 25 XP per run.
- Run 1 always reaches class level 2.

**M1 + M2: rookie protection for the whole squad (P-1, P-29).**
- In stage 1, when a squad has a rookie, its mice deal ×0.75 damage and spawn at ×0.85 rate.
- Bots revive the rookie as a priority and use Second Wind.
- `BotBrain.ROOKIE_STAGES = 2`.
- Sim guard: stage-1 squad wipes ≤ 20% in IntegrationSquads.

**P + U: rookie messaging (H5).**
- No "Pressure unlocked!" before run 3.
- Remove "Go Home" from the lobby text.
- A rookie contract pool: easy contracts only (P-11).

**U: hide the Emote Pack card (H6).**
- Hide any product whose id is 0, or whose key is in `unavailable`.

## B. Clarity and reward feel

**M2 + U: MVP and the Results screen (P-10, P-9, P-8).**
- The MVP is chosen among humans; bots can win accolades only.
- Results count mice and champions, not just PvP downs.
- Results show a breakdown: run cheese, secured, first-extraction bonus, contracts, pass XP and class XP, so the headline matches what the profile gained.

**U (with M2 events): toast priorities and one STAGE CLEAR banner (P-7, C-8).**
- Toasts get priority classes:
  - critical: down / revive / storm;
  - reward;
  - info, which is merged and rate-limited.
- Each stage clear shows one big STAGE CLEAR banner, replacing the stacked toasts.

**M2 + G: boss ceremony (C-8).**
- **Intro card:** the boss's name, a title, one lore line and one "watch for…" tip.
- **Kill beat:** 0.6 s of slow-mo on clients via camera and effects only (the server keeps its normal speed), a chest burst, then the banner.

**U: decision panels (C-5, P-27).**
- Route, extract and Double or Nothing panels open full-size, with their details written inline, for their first 4 s, then can collapse.
- **Double or Nothing readability (P-28, C-23):** state the ×2 rule and its condition plainly.

**U: a calmer upgrade picker (P-13).**

## C. Fun loop

**M1 + M2: route gamble (C-1).**
- Bot squads pick Low, Mid or High by stage, HP and pot. Rough weights: stage 1 Low; stage 2 is 50 / 40 / 10; stage 3+ is 35 / 45 / 20, shifting toward Low when HP is low.
- When no squad wins the boss, the server picks at random across tiers with weights 50 / 35 / 15.
- Sim guard: ≥ 30% of stages are Mid or High.

**M2 + G: shorter Herd Call and spectating (P-14, C-21).**
- The Herd Call delay drops to 12 / 15 / 18 / 22 s by stage.
- While dead, the player spectates a squadmate: G owns the camera, U adds a small "Spectating X" bar.

**M1: idle time (P-12, Z-19).**
- Mice are attracted to nearby heroes (a lure radius).
- Champions roam towards squads.
- Target: idle time ≤ 20% in the sim.

## D. v5 progression (Zombie World style), with VERIFIED §3 corrections applied

`docs/V5-PLAN.md` is the base. **These corrections override it:**

**Scope cuts (Z-20).**
- The boss-zone role goes to the existing Power Totem: it also gives +60% rinds while held, so no new zones are built.
- The Swap Stand only converts rinds → whey.
- Drop the Fortune and Luck charms and the Fortune talent.

**Rind economy ×5 (Z-1, Z-24).**
- Rinds: 5 per mouse, 15 per elite, 200 per champion and 750 per boss.
- Whey: +1 per 25 rinds still applies, so whey rises too.
- Prices stay as in V5. M2 adds a sim guard: a good run earns 8–15k rinds.

**Talent board is account-wide (Z-2, Z-13, Z-3, Z-15).**
- One board shared by all classes, so players aren't punished for switching class.
- Talent-point income is multiplied by (1 + 0.2·Pressure).
- A weekly full-clear bonus by Pressure band.
- Points per run ×1.5 for extracting and ×2 for a full clear.

**Stomps.**
- Veterans start with stomps = lifetime class XP × 1.2 per class (Z-6). The profile has no kill count to seed from.
- Free unlocks of the 4 locked classes at 3k / 8k / 20k / 50k account stomps (Z-5; P picks the order).

**Charms (Z-7, simplified).** Charm tier follows the Pressure band, plus fusing.

**Build order inside D:**
1. Run economy (rinds/whey, stat ranks, stalls, Altar, Swap).
2. Talents.
3. Stomps and evolutions.
4. Charms.
If time runs short, charms move to iteration 2.

## E. Graphics, animation and audio (G, every iteration)

**Player hero suit (P-21, C-16).** Players get the bot elephant rig look (a free "Herd Suit" body), properly animated.

**Animations (C-18, P-20).** One procedural animation set shared by players and bots:
- idle, run, attack (anticipation, then hit, then recovery), cast, hit react, downed and revive;
- eased blending, with squash and stretch.

**Smooth bot movement (P-19).** The server sends bot positions at 10–20 Hz and the client interpolates, like mice; no more per-Heartbeat PivotTo snapping on clients.

**Music and sounds (C-26, C-17).**
- Lobby, run and boss music, using verified, free, non-copyrighted Roblox library assets via the asset pipeline. If none can be verified, generate simple loops procedurally, or leave a TODO.
- A distinct sound for each telegraph, mouse squeaks, and an elephant trumpet.

**Much more intricate visuals.** Heroes, mice, champions, bosses, POIs, landmarks and maps:
- more detail parts, bevels and layered materials;
- per-map ground variation, beyond the flat disc with recolours (P-22);
- bosses get distinct pose sets (C-29).
All within the part and performance budgets, using client-side detail and LOD.

**v5 world models:** stall pads, the Class Stall, the Big Cheese Altar and the Swap Stand.

## F. UI art (the UI-art team, already running) and health bars (done)

- The textured UI skin across all menus, with fallback until the assets are uploaded.
- After it lands, the lead runs the upload-assets workflow.
- The health bars and team colours are done (`HeroTags`, `SquadColors`).
