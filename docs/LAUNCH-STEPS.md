# Launch steps (owner checklist)

These steps need a Roblox account, Roblox Studio or the Creator Dashboard, so they
can't be done from the cloud coding session. Do them in this order: you need a
published experience before you can create passes and products. Menu names in
Studio and the Dashboard may differ slightly.

## 1. Play-test in Roblox Studio

**One-time setup**

1. Install [Roblox Studio](https://create.roblox.com).
2. Install the Rojo CLI from [rojo.space](https://rojo.space), or, with Rust installed:

   ```bash
   cargo install --locked rojo
   ```

**Build the place**

```bash
git clone https://github.com/Matthew-Uhlar/Roblox-Mice.git
```

```bash
cd Roblox-Mice
```

```bash
rojo build -o Trunkfall.rbxlx
```

**Open and configure it in Studio**

1. In Studio, choose **File → Open from File** and pick `Trunkfall.rbxlx`.
2. Choose **File → Publish to Roblox** to create the experience. Keep it private for now.
3. Open **Game Settings**:
   - Under **Security**, turn on **Enable Studio Access to API Services**.
   - Under **Places**, set Max Players to **4**.
4. In the Explorer, select **Workspace**. In Properties, untick **StreamingEnabled**.
5. If a Baseplate or SpawnLocation is present, delete it.

**Play it**

1. Use **Test → Play** for a solo run. Check:
   - 2 bots marked 🤖 join.
   - READY starts the run, or it starts by itself after 30 s.
   - A full stage works: route vote → waves → boss → portal → bank vote.
2. Use **Test → Clients and Servers** with 2 players to test co-op.
3. Use **Test → Device** to try a phone (e.g. iPhone SE). Text should be readable and buttons should fit.
4. Keep **View → Developer Console** (F9) open and report any red errors.
5. Play the *published* game once from the Roblox site or app. This confirms
   `require("./X")` string requires work on live servers.

## 2. Creator Dashboard: Robux items

Open [create.roblox.com](https://create.roblox.com) → **Creations**, then your experience.

**Game Passes** (Monetization → Passes → Create a Pass). Put each one on sale and copy its Pass ID.

| Key | Name | Robux |
|---|---|---|
| `vip` | VIP Herd | 399 |
| `double_xp` | Fast Learner | 249 |
| `herd_leader` | Herd Leader | 349 |
| `founders` | Founders' Stampede | 499 |
| `wardrobe` | Cheese Wardrobe | 99 |

**Developer Products** (Monetization → Developer Products → Create). Copy each Product ID.

| Key | Name | Robux |
|---|---|---|
| `golden_xs` | Golden Cheese x100 | 49 |
| `golden_s` | Golden Cheese x210 | 99 |
| `golden_m` | Golden Cheese x550 | 249 |
| `golden_l` | Golden Cheese x1150 | 499 |
| `golden_xl` | Golden Cheese x2400 | 999 |
| `second_wind_1` | Second Wind | 49 |
| `second_wind_3` | Second Wind x3 | 129 |
| `cheese_rush` | Cheese Rush | 99 |
| `cheese_feast` | Cheese Feast | 149 |

**Optional for now:**

- Subscription `cheese_club` ("Cheese Club", 249 Robux/month). Its id looks like
  `EXP-…`. This appears only once your account is subscription-eligible.
- Product `ad_reward`. Only needed after the experience qualifies for rewarded ads,
  and ads are off in code (`ADS_ENABLED = false`).

**Required:** Audience → **Maturity & Compliance** questionnaire. Target **Mild**.
Unrated experiences can't be played.

**Paste the ids.** Each id replaces `assetId = 0` next to its key in
`src/shared/Config/Monetization.luau`, or send the list to a coding agent to apply.
Then rebuild (`rojo build`) and republish. Items left at 0 are hidden and never
prompted, so the game works without them.

## 3. Let GitHub Actions create the items and publish (Open Cloud)

**Follow `docs/publishing/SETUP.md`.** It is the exact owner checklist: create the
experience, copy the ids, create the API key (permission table), add the GitHub
secret and variables, the maturity questionnaire, Public visibility, icon and
thumbnails, and closing Studio before each publish.

After that, the `Publish to Roblox` workflow does the rest:

1. It creates or updates the 5 passes and 9 products by name, never duplicating one.
2. It writes their ids into the generated `src/shared/Config/ProductIds.luau`.
3. It publishes the place and sets the name, description, server size and devices.
4. It runs an in-Roblox smoke test.

`scripts/roblox-setup.py` is now a thin wrapper around `scripts/publish.py`.

The play-test, the maturity questionnaire, the subscription and ads eligibility
always need you.
