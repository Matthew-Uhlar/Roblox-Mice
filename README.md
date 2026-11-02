# Trunkfall (working title): elephants vs mice, a co-op roguelike for Roblox

Co-op (1–4 players, and **solo players always get 2 labelled bot teammates**) top-down horde roguelike. You play elephant heroes who stomp
swarms of cheese-stealing mice across cheese-themed worlds. Each map ends in a
boss, every route choice is a gamble, and between maps you pick
**Double or Nothing** or **Go Home**. Built from the team's June 2026
brainstorm (`docs/brainstorm-2026-06.md`).

| Doc | What |
|---|---|
| `docs/GDD.md` | Game design: loop, classes, maps, bosses, banking rules |
| `docs/ARCHITECTURE.md` | Code layout, team contracts, server-authority rules |
| `docs/MONETIZATION.md` | Implemented catalog, Creator Dashboard setup, compliance, revenue model |
| `docs/research/market.md` | Market research: audience, comparable games, positioning, risks |
| `docs/research/monetization.md` | Roblox monetization levers and policy (2025–2026) |
| `docs/research/tech.md` | Engine best practices: horde performance, networking, data |
| `docs/qa/` | Testing report and QC reviews (QC1, QC2, TESTING, FINAL-A, FINAL-B) |
| `docs/LORE.md`, `docs/STYLE.md` | World and story, characters and style guide |
| `docs/COMBAT-API.md` | Combat simulation API, Fx events, snapshot format |
| `docs/HANDOFF.md` | Current status and next steps |

## Quick start

Requirements: [Rojo 7](https://rojo.space) plus its Studio plugin. For tests and lint you
also need [Lune](https://lune-org.github.io/docs), StyLua (built with Luau support) and Selene.
The easiest install is `rokit`/`aftman`, or use Cargo:

```bash
cargo install --locked rojo lune selene
```

```bash
cargo install --locked stylua --features luau
```

Open in Studio by either:

- building a place file:

  ```bash
  rojo build -o build/Trunkfall.rbxlx
  ```

  then open `build/Trunkfall.rbxlx` in Roblox Studio, or
- running `rojo serve` and clicking **Connect** in the Rojo Studio plugin to live-sync.

In Studio, open **Game Settings**:

- **Security:** enable *Studio Access to API Services* so DataStores save in Studio.
- **Places:** set *Max Players* to 4.

Then press **Play**. Use **Test → Clients and Servers** (2–4 players) to try co-op.

## Quality gate

```bash
scripts/check.sh
```

`scripts/check.sh` runs, in order: StyLua format check, Selene lint, Luau compile of
every file, Lune unit tests and a Rojo build. Run only the unit tests with
`scripts/test.sh [filter]`.

## Layout

```
src/shared   → ReplicatedStorage.Shared   pure Luau: configs, run rules, combat sim, codecs, data schema (unit-tested in Lune)
src/server   → ServerScriptService.Server  services: run director, combat bridge, arena builder, data, monetization
src/client   → StarterPlayerScripts.Client camera, input, horde renderer, FX, UI (all built in code)
tests/specs  → Lune specs for everything in src/shared
```
