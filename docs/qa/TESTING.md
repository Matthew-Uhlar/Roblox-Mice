# Testing team report (integration, fuzz, perf)

Run with `scripts/test.sh Integration`, `scripts/test.sh Fuzz` or `scripts/test.sh Perf`.

## Suites

- `tests/sim/Headless.luau`: a headless game driver that mirrors RunDirector and
  BotService using only the pure modules.
  - Uses the same RNG fork order as the live server.
  - Difficulty count matches the server.
  - Votes and upgrade picks are made by BotBrain.
  - Steps at 1/30 s, with each participant thinking every 0.1 s.
  - Applies the wipe grace and the second-wind rules.
  - A boss still alive 6 sim-minutes after it spawns counts as a timeout.
  - "Humans" are BotBrains with positive ids.
- `IntegrationRun.spec.luau` (34 tests, about 2 min):
  - full Cycle 1 runs with 3 bots, and with solo + 2 bots
  - banking payouts (GDD §3.4)
  - determinism
  - all 13 bosses can be killed
  - every class clears stage 1
- `FuzzData.spec.luau` (14 tests): garbage profiles, replayed and shuffled receipts, shop buys.
- `FuzzCombat.spec.luau` (14 tests):
  - NaN and infinite inputs
  - players leaving mid-fight against all 13 bosses
  - 0-player and all-bot worlds
  - enemy cap
  - codec clamping
- `PerfWorld.spec.luau` (5 tests): a 300 s wave at the 220-enemy cap.

## Bugs found (tests are tagged `[BUG file:line]` until fixed)

| # | Severity | Where | Issue | Owner |
|---|---|---|---|---|
| 1 | Medium-low | `Data/ProfileSchema.luau` purchases trim | `table.remove(order, 1)` in a loop is O(n²): migrate takes 14.5 s at 80k ids | Fix team 1 |
| 2 | Low | `Combat/World.luau` useAbility | a NaN or infinite `now` before the first step makes a permanent puddle or locks the ability | Fix team 2 |
| 3 | Low-medium | `Services/BotService.luau` | bots ignore `slowed` | Fix team 2 |

## Balance (before the fix round)

- Cycle 1 with 3 bots: 6 of 6 seeds reached the cycle vote. Solo + 2 bots: 6 of 6.
- Stage-1 bosses: all 13 are killable. Average kill time is 37–84 s. Giant Tree wiped 1 of 4 seeds.
- Classes: stage-1 clears take 185–231 s. Le F'ante and Filet each failed 1 of 4 seeds.
- Issues to fix:
  - Late Cycle 1 is too easy: bosses die in 10–17 s while the party takes no damage.
  - Slow bosses drag on: 285 s, and over 360 s when bots kite.
  - Rounding up the fractional party size makes solo + 2 bots harder than 3 bots.
  - Vacuumed XP all goes to one participant.

## Performance (Lune)

| Metric | Result |
|---|---|
| Step time | 0.634 ms average, 1.2 ms p99, 12.3 ms worst |
| Snapshots | 30.1 KB/s at 15 Hz, 20.1 KB/s at 10 Hz |
| Fx | about 20 KB/s |
| BotBrain think at 220 enemies | 0.078 ms |

Recommendation: send snapshots at 10 Hz and cull Fx by distance (assigned to fix team 2).
