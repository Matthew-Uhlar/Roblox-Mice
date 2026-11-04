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
| `Publish to Roblox` (`publish.yml`) | manual. Checks config, syncs passes and products, runs `check.sh`, publishes the place, sets name/description/server size/devices, runs the smoke test, then commits `src/shared/Config/ProductIds.luau` | steps 1–4 |
| `Roblox status` (`status.yml`) | manual. Prints the name, visibility, server size and play URL | steps 1–4 |
| `Upload assets to Roblox` (`upload-assets.yml`) | manual. Uploads the files in `assets/models/manifest.json` and commits `src/shared/Config/AssetIds.luau` | steps 1–4, including `ROBLOX_CREATOR_USER_ID` |

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

Open [github.com/Matthew-Uhlar/Roblox-Mice/settings/secrets/actions](https://github.com/Matthew-Uhlar/Roblox-Mice/settings/secrets/actions).

**Secrets** tab → **New repository secret**:

| Name | Value |
|---|---|
| `ROBLOX_API_KEY` | the key from step 3 |

**Variables** tab → **New repository variable**, once for each:

| Name | Value |
|---|---|
| `ROBLOX_UNIVERSE_ID` | the Universe ID from step 2 |
| `ROBLOX_PLACE_ID` | the start Place ID from step 2 |
| `ROBLOX_CREATOR_USER_ID` | your user ID from step 2 (owner of uploaded assets) |
| `ROBLOX_CREATOR_GROUP_ID` | optional: only if a group should own uploaded assets (this wins over the user ID) |

Then tell the agent **"credentials added"**. It dispatches `publish.yml`.
To run it yourself, go to **Actions → Publish to Roblox → Run workflow**.

## 5. 👤 Maturity & Compliance questionnaire

Unrated experiences can't be played by others. Go to Creator Hub → the experience → **Audience → Maturity & Compliance**, then answer every question honestly. The target is **Mild**. Facts about the game for your answers:

- **Violence:** cartoon combat only. Elephants stomp mice and fight bosses; there is no blood or gore and no realistic weapons. The v2 redesign adds squad-vs-squad play, so answer for the current build.
- **Paid random items:** none. Every Robux item grants a fixed, listed result.
- **Gambling:** Robux and Robux-bought currency can't be wagered. "Double or Nothing" risks earned in-game cheese only.
- **Paid item trading:** none.
- **Chat:** standard Roblox text chat with chat tags. There is no voice and no social-hangout focus.
- **Bots:** solo players get bot teammates, labelled 🤖 everywhere.

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
- **Dispatch** only through the GitHub MCP tools: `actions_run_trigger` (`run_workflow`, `workflow_id: publish.yml`, `ref: main` or the work branch, `inputs: {"smoke_test": "true"}`). Poll with `actions_list` / `actions_get`, and read failures with `get_job_logs` (`failed_only: true`). Workflows must exist on `main` to be dispatchable.
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
