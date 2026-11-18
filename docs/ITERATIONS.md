# Improvement iterations (owner request 2026-11-18)

Ship v4 first, then run this loop **3 times** (iterations 1, 2 and 3).
- Each iteration ends with a QC pass, `scripts/check.sh` printing CHECK PASSED, a fast-forward of `main`, and a publish with the live smoke test.
- Graphics and animation work runs alongside every iteration.

## The loop

1. **Playtest and research teams** (read-only on `src/`; they write only their own report files). They cover three angles:
   - **Playtest:** play the real game headless with the runtime emulator (`tests/runtime`), the sims (`tests/sim`) and the preview renders (`scripts/render-preview`). They act as a new player, a veteran and a phone player, and note bugs, confusing moments, dead time, balance problems and ugly visuals.
   - **Zombie World research:** compare against `docs/research/zombie-world.md` and the Zombie World series pages. What Zombie World does better for in-round upgrading, long-term progression, team play and retention.
   - **Original concept:** compare against `docs/brainstorm-2026-06.md`, `docs/GDD.md` and `docs/GDD-v2.md`. What the concept promised that the game still lacks or does poorly.

   Output: `docs/iter/<n>/<team>.md`, a list of entries. Each entry has an **id**, a **type** (bug / balance / UX / feature / graphics), **evidence** (repro steps, sim numbers, render path, or a source quote), **impact** (High/Med/Low), **effort** (S/M/L) and a **proposed change**.

2. **Verification team** (read-only). For every entry it:
   - reproduces it or checks it against the code;
   - marks it **Confirmed**, **Partly** or **Rejected**, with the reason;
   - removes duplicates;
   - writes `docs/iter/<n>/VERIFIED.md` with the confirmed entries ranked by impact ÷ effort.

3. **Lead review:** picks the most valid entries, guided by the owner's goals: fun loop, retention, monetization that stays within policy, and visual quality. Writes `docs/iter/<n>/PLAN.md` with the chosen entries, owners (the team split in V4-PLAN) and contracts. **Iteration 1 includes the v5 plan (docs/V5-PLAN.md).**

4. **Build teams** (M1 Combat, M2 Match flow, P Progression, U UI, G Graphics and animation) implement PLAN.md. They edit only the files their team owns; no commits or stash (the lead checkpoints).

5. **QC:**
   - An independent reviewer checks the iteration diff for live-safety (data, receipts, policy, remotes, runtime errors, soft-locks).
   - The teams fix the findings.
   - `scripts/check.sh` must print CHECK PASSED.
   - Then fast-forward `main`, publish and smoke-test.
   - Log the iteration in HANDOFF.

## Standing graphics and animation goals (every iteration)

- **Richer models:** much more complex, intricate and well-designed heroes, mice, champions, bosses, POIs and map landmarks (more parts, bevels, layered detail, consistent style), while staying within the part and performance budgets: LOD, client-side detail, and streaming detail around the camera.
- **Smoother animation:**
  - eased procedural animation with proper blending (idle, run, attack, hit react, death, ability windups);
  - no snapping, smooth interpolation of the snapshot for mice and remote heroes;
  - squash and stretch, and anticipation on attacks.
- **Polish:** environment detail, lighting and VFX, plus updated preview renders and store art in every iteration.
