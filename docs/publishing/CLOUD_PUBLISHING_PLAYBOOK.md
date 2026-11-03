# Playbook: build and publish a Roblox game from a Claude Code cloud session

How Slime Heist was set up, built, tested and published live **without
Roblox Studio and without a local machine**, from a cloud agent session. Follow
it to do the same for another game. Everything here is generic; Slime Heist
paths are examples you can copy from this repo.

## 0. The shape of the solution

```
cloud agent session (no Studio, no secrets)
   │  writes Luau code, runs tests headlessly (Rojo + Lune)
   │  git push ─────────────────────────────┐
   │  triggers GitHub Actions via the GitHub MCP tools
   ▼                                        ▼
GitHub repo ── Actions runner (has internet + the Roblox API key secret)
                 │  rojo build → .rbxl
                 │  Roblox Open Cloud REST API
                 ▼
              Roblox: products, place version, settings, in-Roblox smoke test
```

Key ideas:

1. **The whole game is code.** Rojo project; map, models and UI are built by
   scripts at runtime, so `rojo build` produces a complete place file and no
   Studio-only assets exist.
2. **The agent never holds the Roblox API key.** It lives in GitHub Actions
   secrets. The agent only *dispatches* workflows and reads their logs.
3. **Everything is verified twice:** headless tests in CI (Lune runs the real
   built place with stubbed engine APIs) and an in-Roblox smoke test after each
   publish (Open Cloud Luau Execution runs a script on a real Roblox server).
4. A handful of steps **must be done by the human** in Creator Hub (marked 👤).

## 1. Cloud-session constraints to know up front

- **No `gh` CLI auth / no direct GitHub API.** Use the GitHub MCP tools
  (`mcp__github__*`): `actions_run_trigger` (method `run_workflow`) to dispatch,
  `actions_list` (`list_workflow_runs`) and `actions_get` to poll,
  `get_job_logs` to read failures. Plain `git push` works for the session's
  repository.
- **Attach the repo first.** If the repository isn't in the session, call
  `mcp__claude-code-remote__add_repo` (owner, repo, `access: "push"`), clone it,
  then `register_repo_root`. Don't pre-check with curl (private repos 404).
- **Branch rules.** The session is assigned a branch (here
  `claude/jolly-archimedes-9usphg`); develop and push only there. In this
  project the user made it the default branch, which matters because
  `workflow_dispatch` workflows must exist on the default branch to be
  triggered.
- **Outbound network is proxied.** GitHub release downloads worked; some CDNs
  (e.g. image CDNs) were blocked. When the container can't fetch something,
  make a small workflow that runs on the GitHub runner instead (see
  `fetch-images.yml`).
- **No browser / Studio.** Anything that needs a Creator Hub UI is a 👤 step:
  tell the user exactly where to click.
- **Sessions restart and agents share branches.** Keep a handoff file updated
  after every milestone (`CLAUDE_HANDOFF.md`, `docs/HANDOFF.md`). Before every
  push: `git fetch` and fast-forward/rebase; another agent (Codex) pushed to
  the same branch while this session was paused.
- **Never paste secrets into chat, commits or logs.** Don't `echo` the key in
  workflows.

## 2. Repository skeleton (copy these)

| Path | Purpose |
|---|---|
| `default.project.json` | Rojo tree: `src/shared` → ReplicatedStorage.Shared, `src/server` → ServerScriptService.Server, `src/client` → StarterPlayerScripts.Client |
| `rokit.toml` | Pinned tool versions (documentation for humans/Windows) |
| `scripts/install-tools.sh` | Downloads Linux binaries of rojo, lune, stylua, luau-lsp + Roblox `globalTypes.d.luau` into `.tools/` (gitignored) |
| `scripts/check.sh` | The quality gate: `stylua --check` → `rojo sourcemap` → `luau-lsp analyze` → `rojo build` → `lune run tests/run.luau`; fails if the log contains "Stack Begin"/"runtime error" (errors in background threads) |
| `tests/lib/Loader.luau`, `tests/lib/RobloxStubs.luau`, `tests/run.luau` | Headless test harness: `roblox.deserializePlace` on the built place, a fake `require` that resolves Rojo instance paths, stubs for engine methods Lune lacks (`implementMethod`) |
| `.github/workflows/ci.yml` | On every push: install tools, run `check.sh`, upload the `.rbxl` |
| `.github/workflows/publish.yml` | Manual: sync products → check → publish → configure → smoke test → commit product IDs |
| `.github/workflows/status.yml` | Manual: prints name, visibility and play URL |
| `.github/workflows/fetch-images.yml` | Manual: downloads URLs into `assets/` and commits (for things the container can't fetch) |
| `.github/workflows/store-art.yml` | Manual: resizes icon/thumbnails and commits them (upload itself is a 👤 step, see §6) |
| `scripts/publish.py` | Stdlib-only Python Open Cloud client with subcommands `products`, `place FILE`, `configure`, `smoke VERSION`, `status`, `store-art` |

Install + check locally in the cloud session:

```bash
./scripts/install-tools.sh && export PATH="$PWD/.tools/bin:$PATH"
./scripts/check.sh
```

Pinned versions that worked: Rojo 7.7.1, Lune 0.10.5, StyLua 2.5.2,
luau-lsp 1.70.1 (`--flag:LuauSolverV2=false`).

Headless-test gotchas: Lune can't override existing properties with stubs, so
read `part.CFrame.Position` instead of `part.Position`; stub
`Workspace:GetServerTimeNow` (return `os.clock()`), `Terrain:FillBlock`,
`Model:PivotTo/GetPivot`, `RemoteEvent:FireClient`, etc. Boot the real server
by requiring `ServerScriptService.Server.Main` in an integration spec, then
simulate players by creating `Player` instances with a character model.

## 3. 👤 One-time Roblox setup (the human does this; ~15 minutes)

Give the user this checklist (adapted from `docs/04-publishing.md`):

1. **Create the experience:** Roblox Studio → New → Baseplate → File → Publish
   to Roblox. Any empty place works; the pipeline overwrites it.
2. **Get the IDs** (Creator Hub → Creations): Universe ID (⋯ → Copy Universe
   ID) and the start Place ID (from the place's configure URL).
3. **Create an Open Cloud API key** (Creator Hub → Open Cloud → API Keys),
   restricted to this experience, IP `0.0.0.0/0` (GitHub runners rotate IPs),
   with an expiry:

   | Permission | Operations | Used for |
   |---|---|---|
   | `universe-places` | Write | Publishing place versions |
   | `universe.place` | Read, Write | Name, description, server size |
   | `universe` | Read, Write | Devices, private-server price, status |
   | `game-pass` | Read, Write | Creating/updating game passes |
   | `developer-product` | Read, Write | Creating/updating developer products |
   | `universe.place.luau-execution-session` | Write | In-Roblox smoke test |

   (A `legacy-universe` manage scope was added later for store-art attempts; see §6.)
4. **Add to GitHub** (repo → Settings → Secrets and variables → Actions):
   secret `ROBLOX_API_KEY`; variables `ROBLOX_UNIVERSE_ID`, `ROBLOX_PLACE_ID`
   (optional `ROBLOX_GROUP_ID`).
5. **Maturity & Compliance questionnaire** (Creator Hub → Audience). Answer
   honestly; Slime Heist answers: no violence, no social hangout, no paid random
   items, no paid item trading.
6. **Public visibility** cannot be set through the API. Since 2026 the owning
   account needs an age check, ID verification, 2-step verification, an active
   Roblox Plus subscription, good standing and a passed per-game evaluation
   before "Public" unlocks. The user flips Configure → Privacy → Public.
7. **Icon and thumbnails** must be uploaded in Creator Hub (Configure → Basic
   Info); see §6.
8. **Close the place in Studio before every publish.** An open Studio/Team
   Create session makes place uploads return HTTP 409 "Server is busy".

## 4. The publish pipeline

### `publish.yml` (essentials)

```yaml
name: Publish to Roblox
on:
  workflow_dispatch:
    inputs:
      smoke_test: { type: boolean, default: true, description: "Run the in-Roblox smoke test" }
permissions: { contents: write }
concurrency: { group: publish, cancel-in-progress: false }
jobs:
  publish:
    runs-on: ubuntu-latest
    env:
      ROBLOX_API_KEY: ${{ secrets.ROBLOX_API_KEY }}
      ROBLOX_UNIVERSE_ID: ${{ vars.ROBLOX_UNIVERSE_ID }}
      ROBLOX_PLACE_ID: ${{ vars.ROBLOX_PLACE_ID }}
    steps:
      - uses: actions/checkout@v5
      - name: Check configuration      # fail fast with a clear message if a secret/variable is missing
        run: for n in ROBLOX_API_KEY ROBLOX_UNIVERSE_ID ROBLOX_PLACE_ID; do [ -n "${!n}" ] || { echo "::error::$n not set"; exit 1; }; done
      - run: ./scripts/install-tools.sh && echo "$PWD/.tools/bin" >> "$GITHUB_PATH"
      - run: python3 scripts/publish.py products        # writes real IDs into a generated Luau config
      - run: ./scripts/check.sh                         # same gate as CI, on the generated IDs
      - id: place
        run: python3 scripts/publish.py place build/Game.rbxl   # prints version to $GITHUB_OUTPUT
      - run: python3 scripts/publish.py configure
      - if: ${{ inputs.smoke_test }}
        run: python3 scripts/publish.py smoke "${{ steps.place.outputs.version }}"
      - name: Commit product ids
        run: |
          if ! git diff --quiet -- src/shared/Config/ProductIds.luau; then
            git config user.name "github-actions[bot]"
            git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
            git add src/shared/Config/ProductIds.luau
            git commit -m "Update Roblox product ids (published v${{ steps.place.outputs.version }})"
            git push
          fi
```

After a publish that created products, **pull** before your next push (the
workflow commits `ProductIds.luau`).

### Open Cloud endpoints used by `scripts/publish.py`

All requests go to `https://apis.roblox.com` with header `x-api-key`.

| Step | Method + path | Notes |
|---|---|---|
| List passes | `GET /game-passes/v1/universes/{u}/game-passes/creator` | paginate with `pageToken` |
| Create/update pass | `POST /game-passes/v1/universes/{u}/game-passes`, `PATCH .../game-passes/{id}` | **multipart/form-data** (name, description, price, isForSale) |
| List products | `GET /developer-products/v2/universes/{u}/developer-products/creator` | |
| Create/update product | `POST /developer-products/v2/universes/{u}/developer-products`, `PATCH .../{id}` | multipart |
| Publish place | `POST /universes/v1/{u}/places/{p}/versions?versionType=Published` | body = raw `.rbxl` (`application/octet-stream`; `.rbxlx` → `application/xml`); returns `versionNumber`. Retry 409 with growing waits (~18 min total). |
| Place settings | `PATCH /cloud/v2/universes/{u}/places/{p}?updateMask=displayName,description,serverSize` | JSON |
| Universe settings | `PATCH /cloud/v2/universes/{u}?updateMask=desktopEnabled,mobileEnabled,tabletEnabled,consoleEnabled,privateServerPriceRobux` | JSON |
| Status | `GET /cloud/v2/universes/{u}` | `visibility` is read-only |
| Smoke test | `POST /cloud/v2/universes/{u}/places/{p}/versions/{v}/luau-execution-session-tasks` with `{"script": ..., "timeout": "120s"}`, then poll `GET /cloud/v2/{path}` until `COMPLETE`/`FAILED`, read `GET /cloud/v2/{path}/logs` and `output.results[0]` | see below |

Game design detail that keeps products safe to sync: products and passes are
declared in a Luau config (`Config/Monetization.luau`), exported to JSON by a
small Lune script (`scripts/catalog.luau`), created/updated idempotently by
name, and their real IDs written back to a generated `Config/ProductIds.luau`.
The game hides any offer whose ID is still 0.

### The in-Roblox smoke test (important lessons)

- **Luau Execution sessions do not run your place's scripts automatically.**
  The smoke script must detect that the map isn't built after a few seconds
  and boot the services itself, exactly as `Main.server.luau` does (same
  ordered service list: require all, `Init` all, `Start` all, DataService
  last). Keep that list in `publish.py` in sync with `Main.server.luau`
  whenever you add a service; otherwise the smoke test boots a different game.
- Wrap the boot in `xpcall(..., debug.traceback)` and return the error in the
  report, so a failure shows a real traceback in the Actions log.
- Return a single table of facts (map built, counts of bases/pipes/remotes,
  feature flags present…) and assert them in Python. Update the expected
  numbers whenever the world layout changes, in the same commit.
- The first task occasionally stays `PROCESSING` past the poll limit; one
  unchanged re-run passed. Don't treat a poll timeout as a code bug without
  reading the logs.

### Releasing from the cloud session

1. `./scripts/check.sh` locally; commit; `git fetch` + rebase/fast-forward;
   push. Wait for CI green (`actions_list` → `list_workflow_runs` on `ci.yml`).
2. Ask the user to close Studio (or confirm it's closed).
3. Dispatch: `mcp__github__actions_run_trigger` with
   `method: run_workflow`, `workflow_id: publish.yml`, `ref: <branch>`,
   `inputs: {"smoke_test": "true"}`.
4. Poll `list_workflow_runs` for `publish.yml` (or `actions_get` with the run
   id) until `completed`. On failure, `get_job_logs` with `failed_only: true`.
5. Read the log for the published version number and "Smoke test passed".
6. Pull (product IDs may have been committed), record the version and run URL
   in the handoff file. New servers get the update; running servers keep the
   old version.

## 5. Things the API cannot do (plan them as 👤 steps)

- Setting the experience **Public**.
- Uploading the main **icon/thumbnails**: the
  `legacy-game-internationalization` image endpoints only manage
  *translations* and reject the source language ("can't update translations
  for source language"). Generate and resize the art, commit it to
  `assets/store/`, and have the user upload in Creator Hub (or drive a
  logged-in browser if the session has one).
- **Rewarded video ads** need eligibility (the user reported 2,000 monthly
  users).
- The Maturity questionnaire, Roblox account verification and payout setup.

## 6. Art and assets from a cloud session

- Generated images (e.g. via an image-generation MCP) are hosted on CDNs the
  container may not reach. `fetch-images.yml` takes `name=url` pairs and a
  destination under `assets/`, downloads on the runner and commits; then `git
  pull` and post-process locally with Pillow (`scripts/make-ads.py` adds
  headlines and logos; `store-art` resizes to 512×512 icons and 1920×1080
  thumbnails).
- Review art before shipping: one batch drew Minecraft-like characters, which
  risks ad rejection. Prompt for "Roblox R15 avatar, smooth plastic, NOT
  Minecraft, no pixel textures".
- For in-game procedural models you can't see in Studio, render them offline:
  `scripts/slime-preview.{luau,py}` and `scripts/map-preview.{luau,py}` export
  parts from the built place via Lune and ray-trace a contact sheet with
  numpy. Coarse, but it catches overlaps, washed-out materials and sameness.

## 7. Checklist for a new game

1. User creates the GitHub repo; attach it with `add_repo` (push access); work
   on the assigned branch (ask the user to make it the default branch so
   manual workflows can be dispatched).
2. Copy the skeleton from §2 (rename the place file in `check.sh` and
   workflows), get `check.sh` green, push, confirm CI green.
3. Hand the user the §3 checklist; wait for "credentials added".
4. Dispatch `publish.yml` with the smoke test on; fix anything the smoke test
   reports; repeat until green.
5. User sets the experience Public, uploads icon/thumbnails, completes the
   questionnaire; dispatch `status.yml` to confirm visibility.
6. Keep `docs/HANDOFF.md` (or `CLAUDE_HANDOFF.md`) updated with: live version,
   last release run URL, unpublished commits, invariants, and what is 👤-only.
