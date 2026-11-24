# Iteration 7 plan (lead), from docs/iter/7/ZWL-NEXT.md

Starts as soon as iteration 6 is published. Standing owner instruction: more Liberty features, new classes, mesh graphics, polish; publish after the iteration.

## A. Three new classes (roster 8 → 11, Liberty's count)
- **Ele Vation** (Marksman / sniper): new kind `lance`. Auto-aim range raised to cover range 75 (or cap at 70).
- **Elephaid** (Field Medic / healer): new kind `tether`; ascended ability links the squad and revives one downed squadmate. PvP: heals never exceed the existing PvP HP caps.
- **Trunkillery** (Artillery): new kind `anchor` (rooted stance).
Each: 7 abilities (base, L5, L15, L25, P3, P10, ascended), passive, 3-branch talent tree with keystones (same shape as iteration 6), 8 ascension node flavours, a class gem unique, skins, challenge, bots, client UI/fx, unlocks by cheese or stomps (never Robux). The stealth class (Ele-Phantom) is held for later (PvP counters).

## B. Liberty gaps and polish (ZWL-NEXT top 10, accepted 1–8)
1. Ability aim preview for every slot (hold to preview: range ring, area, line, landing ghost; tap still quick-casts).
2. Game feel: hit-stop, small camera shake, per-kind and per-class cast sounds.
3. Class gem uniques for Tinkerphant and the new classes.
4. Death recap card (who downed you, top 3 damage sources).
5. Off-screen arrows to downed squadmates + automatic "needs revive" ping.
6. Talent presets: 2 saved builds per class, free swap in the lobby.
7. Miniboss first-kill reward: Crumb Dust, capped per day.
8. Gem tiers 13–14 from Overtime wave milestones.
(9 mobile smart-cast and 10 keybind remapping: later.)

## C. Mesh graphics
- Team Mesh generates procedural meshes (mice, bosses, champions, hero body) → upload → runtime adoption: HordeRenderer for mice/bosses/champions with LOD; hero suit body; then class weapons, Tinkerphant builds, landmarks, totems/stalls/Altar/objectives.

## D. Carry-over balance
- Ladder targets (Medium ~70–80%, Sharp ~45–60%, fresh Doomwheel ≤2%, veteran ≥25%); champions killed per stage; rinds per good run.

## Rules
Same as iteration 6 (message the lead only, own files, no commits/stash/full check, additive profile changes, mechanics only from Liberty, never Robux for power).
