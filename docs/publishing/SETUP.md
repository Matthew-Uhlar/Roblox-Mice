# Publishing setup (owner checklist) 👤

How Trunkfall gets from this repo onto Roblox without Studio: GitHub Actions
builds the place, creates the Robux items, publishes, configures and runs an
in-Roblox smoke test. The steps marked 👤 are the ones only you can do, in
Roblox Creator Hub and on GitHub. They are a one-time setup of about 15 minutes,
plus step 8 before every publish.

The recipe is `docs/publishing/CLOUD_PUBLISHING_PLAYBOOK.md`. The code is
`scripts/publish.py` and `.github/workflows/`.

| Workflow | What it does | Needs |
|---|---|---|
| `CI` (`ci.yml`) | runs on every push and PR: installs the tools, runs `scripts/check.sh`, uploads `Trunkfall.rbxlx` | nothing |
| `Publish to Roblox` (`publish.yml`) | manual, `main` only, `roblox-production` Environment. Checks config, syncs passes and products, runs `check.sh`, publishes the place, sets name/description/server size/devices, runs the smoke test, then commits `src/shared/Config/ProductIds.luau` | steps 1–4 |
| `Roblox status` (`status.yml`) | manual, `main` only. Prints the name, visibility, server size and play URL | steps 1–4 |
| `Upload assets to Roblox` (`upload-assets.yml`) | manual, `main` only. Uploads the files in `assets/models/manifest.json` and commits `src/shared/Config/AssetIds.luau` | steps 1–4, including `ROBLOX_CREATOR_USER_ID` |

## 1. 👤 Create the experience

The API can't create an experience, so publish an empty one once:

1. Open Roblox Studio and choose **New → Baseplate**.
2. Choose **File → Publish to Roblox**, then **Create new experience**.
3. Name it **Trunkfall** and keep it **Private**.
4. Close Studio. The pipeline overwrites this place on the first publish.

## 2. 👤 Get the ids

Go to [create.roblox.com/dashboard/creations](https://create.roblox.com/dashboard/creations) and find the experience:

- **Universe ID:** on the experience tile, click **⋯ → Copy Universe ID**.
  It also appears in the experience's URL: `.../experiences/<UNIVERSE_ID>/overview`.
- **Place ID:** open the experience, then **Places**, and click the start place.
  The URL is `.../experiences/<UNIVERSE_ID>/places/<PLACE_ID>/configure`.
  You can also click **⋯ → Copy Start Place ID** on the tile.
- **Your user ID** (owner of uploaded 3D assets): open your profile on roblox.com.
  The URL is `https://www.roblox.com/users/<USER_ID>/profile`.
  If a **group** owns the experience, use the group ID from `https://www.roblox.com/groups/<GROUP_ID>/...` instead.

## 3. 👤 Create the Open Cloud API key

1. Go to [create.roblox.com/dashboard/credentials](https://create.roblox.com/dashboard/credentials) → **API Keys** → **Create API Key**.
   For a group-owned experience, switch to the group in the top-left creator picker first.
2. Name it, for example `trunkfall-github-actions`.
3. Under **Access Permissions**, add each API system below. For each one, choose the
   **Trunkfall** experience where asked, then tick the operations:

   | API system (permission) | Operations | Used for |
   |---|---|---|
   | `universe-places` | Write | publishing place versions |
   | `universe.place` | Read, Write | place name, description, server size |
   | `universe` | Read, Write | device toggles, status |
   | `game-pass` | Read, Write | creating and updating game passes |
   | `developer-product` | Read, Write | creating and updating developer products |
   | `universe.place.luau-execution-session` | Write | the in-Roblox smoke test |
   | `asset` (shown as "Assets API") | Read, Write | uploading AI-generated 3D models (Model assets) owned by you or the group |

4. Under **Security → Accepted IP Addresses**, add `0.0.0.0/0`. GitHub runners change
   IPs on every run.
5. Set an **expiration date** (for example 90 days). Put a reminder in your calendar:
   publishing fails with HTTP 401 once the key expires.
6. Click **Save & Generate Key** and **copy the key**. Roblox shows it only once.
   Paste it only into GitHub in step 4: never into chat, a commit or a file.

## 4. 👤 Add the secret and variables to GitHub

The API key lives in a GitHub **Environment** named `roblox-production`, not in
the repository secrets. Every workflow that talks to Roblox (`publish.yml`,
`status.yml`, `upload-assets.yml`) runs only from the default branch (`main`),
uses that Environment, and hands the key only to the steps that call Open
Cloud. The tests (`check.sh`) and the tool install never see it.

1. Open [github.com/Matthew-Uhlar/Roblox-Mice/settings/environments](https://github.com/Matthew-Uhlar/Roblox-Mice/settings/environments) → **New environment**, and name it exactly `roblox-production`.
2. In the new Environment:
   - **Deployment branches and tags** → **Selected branches and tags** → add `main`.
   - Optional but recommended: **Required reviewers** → add yourself. Every publish then waits for your approval in the Actions tab.
   - **Environment secrets** → **Add environment secret**:

     | Name | Value |
     |---|---|
     | `ROBLOX_API_KEY` | the key from step 3 |

   If you added `ROBLOX_API_KEY` as a repository secret earlier, delete it under **Settings → Secrets and variables → Actions**, so only the Environment has it.
3. Open [github.com/Matthew-Uhlar/Roblox-Mice/settings/variables/actions](https://github.com/Matthew-Uhlar/Roblox-Mice/settings/variables/actions). On the **Variables** tab, choose **New repository variable** for each of these (they are not secret):

   | Name | Value |
   |---|---|
   | `ROBLOX_UNIVERSE_ID` | the Universe ID from step 2 |
   | `ROBLOX_PLACE_ID` | the start Place ID from step 2 |
   | `ROBLOX_CREATOR_USER_ID` | your user ID from step 2 (owner of uploaded assets) |
   | `ROBLOX_CREATOR_GROUP_ID` | optional: only if a group should own uploaded assets (this wins over the user ID) |

Then tell the agent **"credentials added"**. It dispatches `publish.yml` on `main`.
To run it yourself, go to **Actions → Publish to Roblox → Run workflow** and pick the `main` branch. A run started from any other branch is skipped.

## 5. 👤 Maturity & Compliance questionnaire

Unrated experiences can't be played by others. Go to Creator Hub → the experience → **Audience → Maturity & Compliance**, then answer every question honestly for the **current build**. Don't tune the answers to reach a label. The wording below matches the questionnaire's topics; check the exact questions in Creator Hub, since Roblox changes them.

Trunkfall v2 is a **squad PvPvE** game: real players' avatars fight each other as well as mice and bosses. Answer for that.

**Violence: Yes.**

- **Type:** unrealistic, cartoon violence. Elephant heroes stomp, spray and blast cartoon mice, bosses **and other players' avatars**.
- **Frequency:** repeated and frequent. Fighting is the core loop of every stage, not an occasional event.
- **Targets:** creatures (mice and bosses) **and humanoid player avatars**. Squads of real players damage, "down" and defeat each other. A kill feed shows who defeated whom (with a skull icon), and there are kill streaks and bounties.
- **Presentation:** no blood, no gore, no dismemberment and no realistic weapons. Downed heroes fall over and crawl; defeated heroes disappear in a cartoon poof and drop a loot bag of cheese and gear.
- **Expected label: Mild** (repeated, mild, unrealistic violence). If the questionnaire puts violence against other players' avatars, or frequent violence, in a higher tier (for example Moderate), **give the honest answer and accept that label**. A higher label limits ads and the youngest audience; a misdeclared questionnaire can get the experience re-rated or actioned.

**Blood: none.** Upgrade and perk names avoid blood words: the former "Bloodthirst", "Lifeblood", "Vampiric Blade" and "Killer Instinct" are now "Hungry Herd", "Wellspring Heart", "Cheese-Leech Blade" and "Sharp Instinct"; "Cheese Vampire" and "Vampire Herd" are "Cheese Muncher" and "Snacking Herd"; and the Filet "Butcher" branch is "Chop Shop".

**Fear / crude humour / romance / alcohol, drugs and tobacco: none.**

**Paid random items: none.** Every Robux item grants a fixed, listed result. Random gear (Armory Crate, Cheese Vault, golden carriers, Shop Cart stock) is free or bought with earned in-run cheese only.

**Gambling: none.**

- Robux and Robux-bought currency can never be wagered.
- "Double or Nothing" risks earned in-run cheese only. It never accepts Robux, Golden Cheese or anything bought with them.
- PvP loot bags hold only earned in-run cheese and run-only gear.

**Paid item trading: none.**

**Social and chat:** standard Roblox text chat, including between players in rival squads, with squad chat tags. There is no voice chat and no social-hangout focus. There is no free-form text entry besides Roblox chat.

**Bots:** labelled 🤖 bots fill every empty seat, in your own squad **and in the rival squads that fight you**, so a solo player always has a full match. They are labelled 🤖 on their names, models, the scoreboard and the kill feed, never presented as real users, and they never appear on leaderboards.

**Monetization in PvP:** Second Wind tokens (paid self-revives) are disabled while two or more squads are still in a run, and can't be bought during a run, so no Robux purchase beats another player.

## 6. 👤 Public visibility (when you're ready to launch)

The API can't set an experience to Public. Since 2026, the **Public** option only unlocks when the owning account has all of these:

- passed an age check
- completed ID verification
- 2-step verification turned on
- an active Roblox Plus subscription
- good standing
- the experience has passed Roblox's per-game evaluation

Then go to Creator Hub → the experience → **Configure → Settings → Privacy**, choose **Public** and save. Run **Actions → Roblox status** to confirm that visibility reads `PUBLIC`.

## 7. 👤 Icon and thumbnails

The API can't upload the main icon or thumbnails. Go to Creator Hub → the experience → **Configure → Basic Info**:

- **Icon:** 512×512 PNG or JPG. No text near the edges and no Roblox logos.
- **Thumbnails:** 1920×1080 (16:9), up to 10 of them. Real gameplay works best.

Art must follow the Roblox community standards. Show Roblox-style avatars, not Minecraft-like blocks (see playbook §6).

## 8. 👤 Before every publish: close Studio

Close the place in Roblox Studio, including any Team Create session, before you or the agent run **Publish to Roblox**. An open session makes the upload return HTTP 409 "Server is busy". The workflow retries for about 17 minutes, then fails with a message telling you to close Studio.

## What stays manual

- The **Cheese Club** subscription. It needs subscription eligibility. Create it in Creator Hub → Monetization → Subscriptions, then send the `EXP-…` id to the agent. It goes into `src/shared/Config/ProductIds.luau` as `cheese_club`.
- The **rewarded-ad product** (`ad_reward`). It needs ads eligibility, and ads are off in code.
- Steps 5–7 above, account verification and payout setup.

---

## For agents

- **Who dispatches:** while the v2 redesign is in progress, only the lead dispatches `publish.yml` and `upload-assets.yml`, after integration and QC. Other agents may dispatch `ci.yml` and `status.yml`.
- **Dispatch** only through the GitHub MCP tools: `actions_run_trigger` (`run_workflow`, `workflow_id: publish.yml`, `ref: main`, `inputs: {"smoke_test": "true"}`). `publish.yml`, `status.yml` and `upload-assets.yml` skip any other branch, and their key is in the `roblox-production` Environment (step 4), so a required reviewer may have to approve the run. Poll with `actions_list` / `actions_get`, and read failures with `get_job_logs` (`failed_only: true`). Workflows must exist on `main` to be dispatchable.
- **After a publish that created products, `git pull`.** The workflow commits `ProductIds.luau`, and `upload-assets.yml` commits `AssetIds.luau`.
- **Generated files** (never edit them by hand; an id typed into `Monetization.luau` wins over the generated one):
  - `src/shared/Config/ProductIds.luau`: `return { key = id }`, every Monetization key, default 0.
  - `src/shared/Config/AssetIds.luau`: `return { ["name"] = id }`, default `{}`.
- **Asset manifest:** `assets/models/manifest.json` is a JSON list, for example `[{"name": "elephant_hero", "path": "elephant_hero.glb", "type": "Model", "description": "optional"}]`.
  - Paths are relative to `assets/models/`, and each file can be up to 20 MB.
  - Upload AI-generated `.fbx`, `.glb` or `.gltf` files as type **Model**: Roblox imports them as a Model of MeshParts and stores them as a package. The `Mesh` type only accepts mesh data downloaded from Roblox, so `publish.py` rejects it.
  - Names that already have an id are skipped, so re-runs never upload twice.
- **Smoke test:** see `docs/publishing/SMOKE.md`.
- **Known blocker before the first real publish.** `tests/specs/DataConfig.spec.luau`'s test "placeholder ids are 0 and never resolve" asserts that every `assetId` is 0. Once `products` writes real ids, it fails, and so does `check.sh` in `publish.yml`. The owner of `tests/specs` should replace it with:

  ```lua
  	T.it("ids come from Monetization or the generated ProductIds; 0 never resolves", function()
  		local ProductIds = require("../../src/shared/Config/ProductIds") :: { [string]: number | string }
  		for _, item in Monetization.ALL do
  			T.truthy(ProductIds[item.key] ~= nil, "ProductIds.luau lacks " .. item.key)
  			T.eq(Monetization.isConfigured(item), item.assetId ~= 0, item.key)
  		end
  		T.eq(Monetization.keyForAsset("product", 0), nil)
  	end)
  ```

  It passes with all-zero ids and with real ids. It was tested on a copy.
- **Local dry runs** need no key: `python3 scripts/publish.py products --dry-run` and `python3 scripts/publish.py assets --dry-run`.
