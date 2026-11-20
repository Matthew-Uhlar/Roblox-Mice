# Iteration 4 plan: the owner's requests (2026-11-20)

Iteration 3 is live. The owner asked for six things:
1. Fix the bottom UI bar graphics.
2. Make the maps drastically larger and more complex, with more objectives and minibosses.
3. Make in-round strength work more like Zombie World Liberty.
4. Gems: equip at most **2**; they boost you from the start of the round; they're permanent, dropped at a low chance when a round is completed, with a **guaranteed** gem the first time you clear a difficulty.
5. A toggle for auto-attack: aim at the **cursor** or at the **nearest** enemy.
6. A UI overhaul: a much cleaner look with custom buttons and designs.

## Decisions (lead)

**Gems (P, then U and M2):**
- **Sockets:** 2 (was 3). During migration, any 3rd equipped gem goes back to the inventory; nothing is lost.
- **Personal:** gems are no longer a squad aura. They apply to their owner from round start.
- **Drops:** only when a round is completed (extraction or full clear).
  - The base chance is 6%, +2% per stage cleared, × the tier's reward, capped at 20%.
  - The **first clear of each difficulty tier guarantees 1 gem of that tier**, once per tier per account.
  - Boss, lair and Double or Nothing drops are removed.
  - The weekly first clear becomes the guaranteed first-ever clear.
- Gem tier still follows the difficulty, with 5 rolled stats, uniques, upgrades and dust. Never Robux.

**In-round strength like Liberty (M2 + M1 + U):**
- **The V menu becomes the main source of power.** Ranks are uncapped (soft cap 100). The cost grows linearly: `base + step·rank`. Per-rank values are bigger, with diminishing returns only past 50. Number keys 1–8 buy inside the menu, and holding a key repeats.
- **Hero levels give fixed stat gains every level,** shown in a Levels list: +3% HP, +2% damage, and +1 armor every 5 levels.
- **Level-up cards** become **milestone picks** every 5 levels (not every level).
- Whey stalls and the Altar stay as Liberty's vespene buffs and late-game store.
- Sim guard: in-round power from the V menu > power from cards at stage 3.

**Auto-attack aim (M1 + M2 + U):**
- A saved setting, `aimMode = "nearest"` (default) or `"cursor"`. Toggle with **T**, a phone button, or a gamepad button.
- In cursor mode the client sends `AimAt(x, z)` at up to 15/s (only while it changes). The server validates it and aims ranged and arc weapons toward that point. Melee and area weapons still hit around the hero.
- Bots stay on nearest.

**Bigger, richer maps (M1 + G + M2):**
- Stage radius ×1.35 (clamp 400–760), within the part and perf budgets. Mice spawning per hero stays the same.
- About 2× objectives per map: more POI slots, plus 2–3 new objective types:
  - an escort/caravan,
  - a capture beacon chain,
  - a rescue of trapped bot elephants.
- **Minibosses:** 2–4 named roaming miniboss camps per map, in Liberty's corner style. Each patrols, respawns every 90 s, drops whey, rinds and XP, and counts toward contracts and challenges.
- Terrain gets real complexity:
  - raised plateaus and ramps;
  - rivers and bridges that are walkable chokepoints;
  - cliffs, forests and ruins as cover;
  - per-map biome layout.
  
  Use client-side detail plus server collision primitives, and keep the server part budget, with a new per-map budget spec.

**UI (U + UI-art):**
- Fix the lobby bottom bar: the mirrored wood strip looks broken. Rebuild it as one clean custom dock.
- **Overhaul:** a new, cleaner texture set in a flatter, modern style with rounded cards, soft shadows and a crisp outline, using a consistent accent palette and custom button shapes (pill and squircle). Apply it everywhere through Theme. New asset names, then upload.

## Owners
| Area | Owner |
|---|---|
| Gems data, migration, drop rules | P |
| V-menu ranks curve, Levels gains, milestone cards, drop calls, aim remotes, objective and miniboss scheduling | M2 |
| World aim, miniboss AI, bigger maps' Config (`Maps`, `Pois`, `Champions`) | M1 |
| Terrain complexity, landmarks, objective and miniboss models | G |
| Bottom dock, overhaul, aim toggle, V-menu hotkeys | U |
| New texture set | UI-art |
| Net (`SetAimMode`, `AimAt` added) | Lead |

**Rules:** message only the lead, only when necessary, and keep it concise. Your files only. No commits, no stash, no full `check.sh`.
