# Iteration 6 plan (lead), 2026-11-23

Iteration 5 is live. The owner asked to keep iterating and to publish after each major iteration. This round takes the iteration-6 candidates from docs/iter/5/ZWL-GAPS.md plus the open balance warnings.

## 1. New class: a builder elephant (team Builder)
Liberty has 11 heroes with distinct roles; we have 7. Add an 8th class with a **builder / engineer** role (our own name, theme and art; mechanics only).
- **Weapon:** a short-range rivet bolt (modest damage) so the class is playable without builds.
- **Base ability (slot 1): Deploy Turret.** Places an auto-firing turret at the aim point (cast range ~30). Turret: HP, lifetime ~20 s, targets the nearest mouse in range ~40, uses the hero's damage multipliers; at most 2 alive per hero (the oldest despawns).
- **Alternate 1 (level 5): Barricade.** A short wall segment (length ~14) that blocks mice (mice path around it or attack it), HP, lifetime ~12 s. It must not block heroes' own movement in a way that traps players; it never blocks enemy heroes' projectiles in PvP unfairly (treat as cover for mice only, or give it low HP vs heroes).
- **Alternate 2 (level 15): Repair Pulse.** Heals own turrets/barricades and squadmates in an area a little.
- **Passive:** +25% turret/barricade HP.
- Turrets and barricades are World entities (new kinds) with snapshot/fx support; bots of this class use them sensibly (BotBrain).
- PvP: turrets shoot enemy heroes at ×0.5 damage; barricades block enemy heroes' movement but not projectiles; cap per hero as above.
- Unlock: cheese (like the other paid classes, 4000) and the free stomp-unlock track (add it as the 5th free unlock at a higher stomp count). **Never Robux.**
- Profile: additive (new class id in classes{}); prestige, ascension (8 nodes with real effects), challenges/tiers work for it like any class. Skins: one default look.
- Specs: class config, turret targeting, barricade blocking, CombatTtk row, BotBrain use, IntegrationDifficulty unaffected outside tolerance.

## 2. Pace toggle: Normal / Fast (team Flow)
- The lobby leader picks Pace next to the tier. Fast: wave timers ×0.7, spawn rate ×1.35, boss HP ×1.0, storm ×0.8 duration; rewards: cheese ×1.15, class XP ×1.15 (stomps naturally higher). Saved in settings.pace; the Results/records note the pace; Best Solo/records stay per tier (Fast clears count).
- Sim guard: Fast Medium clear rate within ±15 points of Normal Medium.

## 3. Balance follow-ups (team Flow, with Builder for combat-side numbers)
- **Ladder:** Medium ~70–80% clears, Sharp ~45–60% (currently 92% / 83%). Tune tier multipliers in Config/Difficulty and/or totem strength, not the fresh/veteran Doomwheel guards (fresh 0–2%, veteran ≥25%).
- **Champions killed per full stage ≥ 2** (currently ~0.24): make champions reachable (roam toward squads earlier, lower HP a bit in stages 1–2, bots engage them when healthy).
- **Rinds per good run 8–15k** (currently ~6.8k median): raise rind income (champion/boss/miniboss payouts) rather than lower prices.
- Turn these three `[BALANCE]` warnings into passing targets where feasible; report the final numbers.

## 4. Client (team Client)
- Builder class UI: class card, ability icons, turret/barricade placement preview (ghost at the aim point), turret/barricade models + HP bars, Repair Pulse fx.
- Pace toggle in the lobby next to the tier selector; Fast shown on HUD and Results.
- Any HUD needed for turret count (e.g. "Turrets 1/2").

## Then
QC review (a separate reviewer), fixes, full `scripts/check.sh`, fast-forward `main`, upload any new assets, publish with the smoke test, update HANDOFF, report.

## Rules (owner instruction)
- Message only the lead, only when necessary, and keep it concise.
- Your files only (re-read files before editing: other teams work in parallel). No commits, no stash, no full `check.sh` (use `scripts/test.sh <filter>`). Run `stylua` only on files you changed.
- Live game: profile changes additive only. Mechanics only from Liberty; no copied names or art. Never Robux for power.

## Added during iteration 6 (owner requests, 2026-11-23)
- **Hotfix 5.1 (ships first, from `main`):** PC right-drag camera rotation (cursor-position fallback + LockCurrentPosition while dragging); larger XP bar with caption; bottom HUD tiles on a self-sizing dock.
- **Animated icons (team Icons):** every menu item and shop item gets an original animated icon (sprite-sheet atlases `icon_*`, `UI/AnimatedIcon`), fallback to emoji until uploaded, respects the Effects setting.
- **Cosmetic preview (team Preview):** try skins and cosmetics on your own hero in a 3D showroom before buying or equipping; animated icons for every cosmetic. Boot replicates the hero look builders to `ReplicatedStorage.HeroVisuals`.
- **Talent trees and Ascension (team Talents):** deeper per-class trees (branches, tiers, keystones, choice nodes) with safe migration of saved picks; ascension nodes with visible/feelable effects; new tree UI.
