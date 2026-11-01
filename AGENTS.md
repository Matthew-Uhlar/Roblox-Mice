# Agent instructions (Codex, Claude, any coding agent)

Before doing anything in this repo, read `docs/HANDOFF.md` (current status,
rules, next steps), then `docs/GDD.md` and `docs/ARCHITECTURE.md`.

- Run `scripts/check.sh` before every commit. It must print `CHECK PASSED`.
- `src/shared` must stay pure Luau that runs under Lune (see HANDOFF §3).
- Update `docs/HANDOFF.md` (Status, Next steps, Log) after every major step,
  then commit and push.
- Work on a feature branch. `main` takes only tested milestones.
