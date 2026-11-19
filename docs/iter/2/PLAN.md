# Iteration 2 plan (lead): Liberty alignment, built on top of iteration 1

**Source:** `docs/iter/2/ALIGNMENT.md` (the target model in §1, per-system verdicts in §2, match feel in §3, build list in §4) and `docs/research/zwl-save-model.md`.

**Release plan:** iterations 1 and 2 ship as **one** release.
- The v7 Herd Talent Board, Evolutions and Charms have never been live.
- They are reshaped now, so no v7 → v8 conversion of player data is needed.
- The live game is on profile v6. The new profile version must still migrate additively from v1–v6, with a raw backup taken first.

## Lead decisions

- **Prestige resets the visible class level to 1.** All perks, abilities and skins are kept (ALIGNMENT §2). Mastery Stars convert 1:1 to Prestige.
- **Difficulty tiers:** 11 cheese-themed names, final wording by U and G. The names must not be Liberty's.
- **Cut the Herd Talent Board.** Its income goes into class XP and gems. **Evolutions merge into Ascension**: the looks go on nodes 2, 4 and 8. **Charms become Cheese Gems** with Crumb Dust.
- **Keep:**
  - stomps (= kills);
  - the account cheese Talents, frozen and renamed "Herd Upgrades";
  - the larger map, the storm, POIs, champions, squad PvP, route cards, Double or Nothing and extraction.
- **Never Robux** for gems, dust, prestige, ascension or challenges.

## Build (ALIGNMENT §4 top 12, plus the leftovers from iteration 1)

**P (Progression):**
- **Profile (additive):**
  - Prestige 0–99 per class; old Mastery Stars convert to Prestige.
  - An 8-node Ascension per class, gated by a Prestige milestone plus class stomps.
  - Cheese Gems (tier = difficulty; 5 rolled stats; 11 uniques; upgrade +0–5; Crumb Dust; salvage; inventory 200).
  - 30 Challenges, a difficulty ladder record (unlocked tier, Best Solo, Best Squad per class and per account), and a Skip-Wave/Early-Horn setting.
- Class XP from kills, with the gentler curve (§4 item 7).
- Remove the Herd Talent Board.
- New leaderboards: Total Stomps, Best Solo and Best Squad.
- `awardRun` returns its grant summary.
- Remotes: reuse the v5 names where they fit (`EquipCharm` → gems, etc.) or add new ones. The lead adds Net entries on request.

**M2 (Match flow):**
- **Difficulty ladder:** the lobby leader picks a tier; each tier is a Pressure preset plus base multipliers, and clearing a tier unlocks the next. Add a sim guard on the clear rate per tier.
- **Numbered waves:** 5 per stage, the 5th being the boss, plus the **Early Horn** (horn at 50, 70 or 90% stomped; pays rinds for the skipped seconds).
- Gem drop events and challenge tracking.
- Rind gifting to squadmates.

**M1 (Combat):**
- Finish the rind economy ÷4 and the champion fight guard.
- Idle time ≤ 20%: mice pour in from the storm edge in "fronts", synced to the waves.
- Apply gem stats and uniques, Ascension node effects and Prestige bonuses (PvE damage only).
- Cap long-term HP at +25% in PvP.

**U (UI):**
- **Hero screen:** Level & Perks · Prestige & Ascension · Abilities · Skins. Cut the progression tabs from 9 to 6, with Achievements shown under Challenges.
- **Ladder selector** in the lobby.
- **Gems:** inventory, sockets, upgrade, salvage.
- **Challenges tab.**
- **Early Horn** button.
- **V menu:** a pulse when rinds are ready to spend, plus buy ×5.
- Switch the STAGE CLEAR banner to M2's `stageClear`.
- Remove the Talent Board and Evolution tabs.

**G (Graphics):**
- Ascension looks on nodes 2, 4 and 8.
- Gem icons and drop VFX.
- Prestige nameplate frames.
- Tier visuals in the lobby.
- **Continue the graphics drive:** more detailed champions, POIs and landmarks; full boss pose sets.

## Rules for every team (owner's instruction)

- **Messages:** send messages only to the lead, and only when necessary (a blocker, or your final report). Keep them concise.
- **Files:** only the files you own (the ownership table in `V4-PLAN.md`). No commits, no stash.
- **Checks:** no full `check.sh` until the lead says so; use `scripts/test.sh <filter>` instead.
