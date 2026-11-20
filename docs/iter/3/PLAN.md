# Iteration 3 plan (lead): from docs/iter/3/VERIFIED.md

## Phase A: hotfix (ships first, by itself)

Live bugs from VERIFIED §2:

| Id | Fix | Owner |
|---|---|---|
| T-1 | The horn HUD treats the server's percents as fractions, and its ready check is wrong. | U |
| T-5 | The Results class-XP bar uses the old curve. | U |
| T-6 | Leaderboard labels and the Best Solo display. | U |
| T-7 | The lobby shows Medium while the server plays Custom for a stale v6 board. | U, plus the server side M2 |
| T-11 | The "+-37" sign. | U |
| T-23 | The Melt warning shows while spectating. | U |
| T-31 | The "Le Fante" name. | U |

## Phase B: the rest of the confirmed list (VERIFIED §3), by owner

**M1:**
- T-2: retune Moldy and Doomwheel so the top tiers can be cleared by strong veterans. Target: maxed veteran on Doomwheel ≥ 25%, fresh squad < 2%.
- T-4: lower bot-squad PvP pressure on rookies further.
- T-3 / T-18: the Early Horn **stacks** the next wave instead of deleting the rest of the current one, so earnings are no longer halved.

**M2:**
- T-8: save the chosen tier in `settings.tier` (additive, with P) and restore it on any server and on Play Again.
- T-10: whey economy. Lower stall prices and the Altar, or raise income, so a veteran can afford 2–3 buffs and one Altar purchase in a good run.
- T-9: Snatcher counts only the player who landed the snatch, and only if alive.
- The remaining M2 items in §3.

**P:**
- T-11: rookie economy. Let rookies choose Mild or Medium, give Mild ×1.0 cheese, and set Mild gems to a minimum of +1%.
- T-13: tutorial hints for the V menu, the horn, whey and gems (with U).
- The remaining P items in §3.

**U:**
- T-12 / T-14: reward moments. Results cards for a gem found, tier unlocked, new Best Solo and challenge progress; a Prestige celebration.
- T-13: hints.
- T-15, T-17: as listed in §3.

**G:**
- T-26 to T-30:
  - the boss death pose (the ground ring tipping);
  - Ascension looks clearly visible from the gameplay camera (scale them up, add glow and colour);
  - hero animation less stiff;
  - richer map views from the gameplay camera.

**New Config files:** owned per VERIFIED: RunShop → M2, Difficulty → M1, Gems → P, Challenges → P, `Run/Waves` → M2.

## Rules (owner instruction)
- Message only the lead, only when necessary, and keep it concise.
- Your files only. No commits, no stash, no full `check.sh`.
