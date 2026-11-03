# Handoff: continuing Trunkfall in a local session

Paste everything below the line into a new local Claude Code session. A desktop
app session with Computer use turned on is best.

---

You are continuing work on **Trunkfall**, a finished Roblox co-op horde roguelike
(elephants vs mice) in Luau, built with Rojo. The code is done and tested. What's
left needs a real computer: Roblox Studio and the Roblox Creator Dashboard.

## 1. Get the repo and tools

```bash
git clone https://github.com/Matthew-Uhlar/Roblox-Mice.git
```

```bash
cd Roblox-Mice
```

```bash
cargo install --locked rojo lune selene
```

```bash
cargo install --locked stylua --features luau
```

If Cargo isn't installed, install Rojo from https://rojo.space. Rojo is the only
tool Studio work needs. The others run the test suite.

Work on `main`. It holds the complete, tested game. For larger changes, use a
feature branch and fast-forward `main` once `scripts/check.sh` passes.

## 2. Read first

1. `AGENTS.md` (repo rules)
2. `docs/HANDOFF.md` (status, rules, log)
3. `docs/LAUNCH-STEPS.md` (the exact owner checklist for what's left)
4. Only as needed: `docs/GDD.md`, `docs/ARCHITECTURE.md`, `docs/MONETIZATION.md`

Confirm the baseline before changing anything:

```bash
scripts/check.sh
```

It must print `CHECK PASSED` (about 42 spec files, including a headless Roblox
runtime emulator in `tests/runtime/`).

## 3. What's left (do it in this order)

1. **Publish from Studio** (`docs/LAUNCH-STEPS.md` §1):
   - Run `rojo build -o Trunkfall.rbxlx`, open the file in Studio, and use File → Publish to Roblox (keep it private).
   - Game Settings: Studio Access to API Services ON, Max Players 4.
   - Workspace.StreamingEnabled OFF.
   - Delete any Baseplate or SpawnLocation.
2. **Play-test in Studio:**
   - Solo: 2 🤖 bots join, the auto-start fires at 30 s, and a full stage plays through (route vote → waves → boss → portal → bank vote → Go Home).
   - Clients and Servers with 2 players.
   - The phone emulator at 667×375.
   - Watch the Output / Developer Console for errors.
   - Fix real errors in `src/` with a regression test where possible. Run `scripts/check.sh`, commit, rebuild, republish.
3. **Play the published game once** from the Roblox app. This confirms that string `require("./X")` works on live servers.
4. **Create the Robux items.** Use either option:
   - **Script (preferred):** have the owner create an Open Cloud API key at create.roblox.com/dashboard/credentials.
     - Scope it to this experience with game-pass read/write, developer-product read/write and universe-places write. Allow IPs `0.0.0.0/0`.
     - Set the environment variables `ROBLOX_API_KEY`, `ROBLOX_UNIVERSE_ID` and `ROBLOX_PLACE_ID` locally (never in chat, never committed). Then run:

       ```bash
       scripts/roblox-setup.py all --dry-run
       ```

       ```bash
       scripts/roblox-setup.py all
       ```

     - The script creates the 5 passes and 9 products at their prices, matching existing ones by name, writes the ids into `src/shared/Config/Monetization.luau`, and publishes the place.
   - **Browser/UI:** create the items listed in `docs/LAUNCH-STEPS.md` §2 by hand and paste each id over its `assetId = 0`.
   - Either way, then run `scripts/check.sh`, commit, push, and republish.
5. **Maturity & Compliance questionnaire** in the Dashboard (target **Mild**). Draft the answers from the game's content (cartoon violence, mice "poof" into crumbs, no blood, no chat beyond Roblox's own, purchases present). Get the owner's confirmation before you submit.
6. **Optional, later:** the `cheese_club` subscription and the `ad_reward` product once the account is eligible (keep `ADS_ENABLED = false` until then), a balance pass with real players, real art and audio (`docs/STYLE.md`), and the open Minors in `docs/HANDOFF.md` §5.

## 4. Rules

- **The owner does these steps:** signing in to Roblox (password and 2FA), ID or age verification, payout and eligibility forms. Never type passwords or handle the API key in chat.
- **Load-bearing code rules:** `src/shared` stays pure Luau that runs under Lune. All remote handlers go through `Guard.connect`. Bot ids use `Util/Ids` (≤ −1001), and Studio test players (−1…−8) are humans. No paid random items. Robux never touch Double or Nothing or Pressure.
- **Before every commit:** run `scripts/check.sh`. Update `docs/HANDOFF.md` (status line and Log) after each major step, then commit and push.
