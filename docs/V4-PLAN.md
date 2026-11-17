# v4 plan (LIVE game — every data change must migrate safely)

The owner's request (2026-11-16):
- The maps should be even bigger, and each later stage slightly smaller.
- Teams should be pushed toward the centre as the round goes on.
- Run multiple review teams.
- Add the features that make similar games successful.
- Drastically upgrade the graphics.
- Make sure the progression systems work, and improve them.
- Add an in-game Robux shop.

Inputs (read the ones relevant to your team):
- `docs/research/v4-features.md` (R): research.
- `docs/qa/V4-A-gameplay.md` (A): gameplay review.
- `docs/qa/V4-B-ux-graphics.md` (B): UX and graphics review.
- `docs/qa/V4-C-progression.md` (C): progression review.

## Decisions (lead)

### Maps and storm ("The Melt")

**Maps:**
- Stage arena radius is 480 / 420 / 360 / 310 for stages 1–4, scaled per map by `Maps.size / 350`.
- Clamp the radius to 300–560.

**Storm:**
- Circle radii are 0.65 R, then 0.40 R, then 0.22 R. They close over 30–60 s, 85–110 s and 125–150 s of the waves.
- If the boss lives past 90 s, the storm squeezes to 0.12 R.
- Damage outside the circle is 2 / 4 / 8 / 12 % of max HP per second at each step.
- The storm does not interrupt POI channels.
- Squad safe corners turn off at 30 s.
- The circle centre is the arena centre, offset by up to 0.1 R at random per stage.
- Champions spawn inside the next circle.
- Bots path inside the circle.

### Match

**Mouse spawning:**
- Mice spawn per hero: 0.9/s per hero, ramping ×3.2, with a soft cap of 28 per hero and a global cap of 300.
- Mouse HP scales with the average hero level.

**PvP channel:**
- Hit protection is a per-attacker lockout of 0.25 s, replacing the shared invulnerability window.
- Armor is multiplied by `PVP_MULT` in PvP.
- Regen pauses for 3 s after taking PvP damage.
- `PVP_MULT` is 0.35. Target time-to-kill: 6–9 s for a 1v1, 2.5–4 s for a 3v1.
  - **Revised 2026-11-17 (lead):** the 6–9 s target caused stage-1 squad wipes in 85% of simulated matches. Accepted the M1 retune: 1v1 time-to-kill is about 21.6 s and 3v1 about 14.4 s. Hero hits give mice-only i-frames, finishing hits on downed heroes have a 0.8 s gap, and bots are calmer in stages 1–2. Mice spawn at 0.6/s per hero. PvP is the spice, not the main loop.
- Crits apply to heroes at half bonus.
- Talents affect PvE only: `stats.pveDamageMult`; the World ignores it against heroes.

**Keeping the match populated:**
- Bot squads never extract before the stage-2 gate. After that they extract at 330 / 420 per member.
- If at most 1 squad is in the run at a stage start, a labelled 🤖 Rival Herd bot squad enters.
- `LAST_HERD_STAGES` = 1.

**Redeploy (Herd Call):**
- Delay is 20 / 25 / 30 / 35 s by stage. It needs a standing squadmate.
- Each champion kill takes 3 s off, each down of an enemy hero 2 s, and each POI 1 s.
- Redeployed heroes return at 60 % HP with 5 s of protection.
- Limit 1 per stage. No redeploys during the boss or the last 20 s of the waves.

**Rewards and payouts:**
- Secured cheese: 25 % of champion, vault and boss rewards bank instantly. Every stage reached is worth at least 40 cheese.
- Champions and the boss reward the squad with the most damage. If another squad lands the kill, it gets a 50 % "Snatch" bonus.
- Dead members still get their gear share.
- Double or Nothing becomes a true ×2. It pays only if the squad survives and kills a champion or the boss on that stage. DoN squads are marked on the map.

**Tuning:**
- Class rebalance from A §8.
- Bots use all 7 classes and their alternate abilities.
- Champion HP scales to a 20–30 s fight. Boss HP scales with hero count; the final boss gets ×2.5 HP and a third phase (60–90 s fight).

**Joining, leaving and rookies:**
- **Late joiners** take a bot's seat mid-match: next stage start, or redeploy if possible. Only if no seat exists do they get a practice yard.
- **Play Again:** eliminated or extracted players, with their party, can teleport to a fresh server via TeleportService. This is never automatic.
- **Rookie Run (R #1):** applies to a player's runs 0–2.
  - Enemy bots don't target rookies in stage 1, and rookies carry no bounty.
  - Run 1: the first champion has ×0.7 HP, and Extract is pre-selected at the first gate.
  - Double or Nothing and Pressure are hidden until run 3.
  - The first extraction pays 500 cheese and 50 Golden Cheese.

**Fixes from C:**
- **B1:** a Pressure record counts only on a full 4-stage clear.
- **M1:** `wins` counts only Last Herd or extraction at stage ≥ 3.
- **B3:** replace `deepestCycle` with `bestStage`/`championKills`.
- **M8:** no auto-start while the player is "busy" in the shop or perk tree (`SetBusy`).

### Progression and monetization (C + R)

- **Profile v6** (additive migration only): `quests`, `pass`, `achievements`, `collection`, `masteryStars`, `accountRewards`, `settings.busy` is not persisted.
- **Herd Contracts (quests):** 3 dailies per day (Easy / Medium / Hard: 150 / 250 / 350 pass XP plus 100–200 cheese), drawn from a pool of about 18. 5–6 weeklies (500–600 pass XP plus 300 cheese). 1 free reroll per day. No quest ever requires Robux, a friend, Double or Nothing or downing a human.
- **Herd Pass:**
  - Season of 28 days, 30 tiers of 1,000 XP.
  - Free and premium tracks. Premium is a per-season Game Pass at 399 R$, with 8 cosmetics and 600 Golden Cheese.
  - Rewards are cosmetic or currency only: no class XP, no tier skips for Robux.
  - Upgrading mid-season back-fills premium rewards. Unclaimed rewards auto-grant at season end.
- **Mastery Stars** after class level 30: 12,000 XP each. The first star grants the 30th perk point.
- **Account level rewards** up to level 100: a cosmetic or Golden Cheese every 5 levels.
- **Achievements and collection book (Mousepedia):** pages for bosses, champions, mice, gear, maps and classes. Each new entry gives +5 Golden Cheese and +50 pass XP.
- **Repricing (Golden Cheese):** Neon skins 150, Gilded 200, hats 150–250, tints 100–150. Add more repeatable cheese sinks.
- **New Robux items** (all cosmetic or currency, never random):
  - Starter Herd Pack, 99 R$, one-time.
  - Skin Collector Bundle, 299 R$.
  - Wardrobe+ Bundle, 199 R$.
  - Emote Pack, 199 R$.
  - Herd Pass premium, 399 R$.
- **Robux shop v2:** tabs Featured, Cosmetics (with try-on), Passes, Golden Cheese, Boosts (with timers), Herd Pass and Cheese Shop.
  - The featured rotation is the same for everyone, shows no timers and nothing leaves sale.
  - Entry points: a HUD button with a dot, a lobby kiosk, and a "View in shop" card on Results after a win only. Never prompt on wipes, never auto-prompt.
- **Show what is already built:** the account level badge, boost timers, a dot when the daily reward is ready, "Owned" on owned items, readable benefit details, and a leaderboard wall in the lobby.

### Experience and graphics (B + R)

- **Audio:** add a SoundController and `Config/Sounds`.
  - Sound groups: Music 0.35, SFX 0.6, UI 0.5.
  - Pitch varies 0.92–1.12. Hit sounds are capped at 10/s.
  - Use placeholder `rbxasset://sounds/*` ids. Any id must be verified as existing, or left empty and marked TODO.
- **Players are elephants:** a part-built elephant hood with ears and a trunk, plus a grey tint during runs. Bots scale to about 0.65.
- **Readability:** a shadow disc under every mouse, darker mouse colours, a plum Chonk and a red accent on slingers.
- **Fill the maps:** terrain decoration and low bumps, decor out to 3 R, backdrop parts 380 → 150, and a signature feature per map.
- **Feedback:**
  - Level-up burst in the world; red screen edge on damage, pulsing at low HP.
  - Kill-streak counter.
  - Crumbs fly to the hero.
  - Only your own damage numbers show at full size.
- **Match features:**
  - Pings and quick-chat: context pings with no free text; bots obey them.
  - Results show an MVP and awards (R #7), with Share and Play Again.
- **Interface:**
  - An objective arrow points at the next goal.
  - The first run is simplified.
  - Phone HUD trims; storm UI (ring, timer, outside warning).
  - Redeploy timer and lobby polish.
- **Store art:** an action-shot thumbnail and a new icon.

## Ownership

| Team | Owns |
|---|---|
| **M1 Combat** | `src/shared/Combat/*`, `src/shared/Config/{Maps,Pois,Champions,Enemies,Bosses,Classes,Upgrades,Storm}.luau`, `src/shared/Bots/BotBrain.luau`, `src/server/Services/CombatService.luau`, specs `Combat*`, `BotBrain*`, `Perf*`, `Fuzz*` |
| **M2 Match flow** | `src/shared/Run/{MatchState,RunState,Vote,LobbyRules,EpicDrop,Pressure,UpgradeOffers,Leveling,Gear}.luau`, `src/shared/Bots/BotRoster.luau`, `src/server/Services/{RunDirector,LobbyService,BotService,Guard,Remotes}.luau`, `src/server/Boot.luau`, `src/server/Main.server.luau`, `tests/sim/*`, specs `Run*`, `Integration*`, `BotRoster*`, `Runtime*`, `tests/runtime/*` |
| **P Progression** | `src/shared/Data/*`, `src/shared/Run/Stats.luau`, `src/shared/Config/{Monetization,Cosmetics,Shop,Talents,ClassPerks,ClassAbilities,ClassSkins,Quests,Pass,Achievements,Collection,AccountRewards}.luau`, `src/server/Services/{DataService,ShopService,MonetizationService,LeaderboardService,CosmeticsService}.luau`, specs `Data*`, `RunStats*`, `docs/MONETIZATION.md` |
| **U UI** | `src/client/UI/*`, `src/client/Util/*`, `src/client/Controllers/{State,InputController,ChatTags}.luau`, `src/client/Main.client.luau`, specs `Client*` |
| **G Graphics and audio** | `src/server/Services/{ArenaBuilder,LightingService,LobbyWorld}.luau`, `src/server/Visuals/*`, `src/client/Visuals/*`, `src/client/Controllers/{HordeRenderer,FxController,CameraController,SoundController}.luau`, `src/shared/Config/Sounds.luau`, `assets/**`, `scripts/{render-preview,make-store-art}.*` |
| **Lead** | `src/shared/{Net,Types}.luau` (other teams may add optional Types fields), `src/shared/Util/*`, docs, `scripts/check.sh` |

## Contracts

- **`World` storm API (M1):**
  - `world:setZone({cx, cz, r, toR, closeStart, closeEnd, dps})` and `world:zone()`.
  - Fx `{t = "storm", cx, cz, r, toR, closeStart, closeEnd, dps, now}`, sent on every change.
  - Event `stormDamage` (optional).
- **Storm schedule:** `Config/Storm.luau` (M1) is driven by RunDirector (M2). It calls `world:setZone` at each step. Arena radius per stage: `Maps.stageRadius(mapId, stage)` (M1). ArenaBuilder (G) builds to `Maps.stageRadius`.
- **Redeploy (M2):** `world:redeploy(id, x, z, hpFrac, protect)` (M1).
- **Per-hero spawning:** inside World/WaveDirector (M1). No API change.
- **PvE-only damage:** `stats.pveDamageMult` (P sets it in Stats; M1 applies it only against non-heroes).
- **Remotes (lead adds them to Net now):**
  - Client to server: `Ping(kind, x, z)`, `QuickChat(index)`, `SetBusy(bool)`, `ClaimQuest(id)`, `RerollQuest(id)`, `ClaimPassTier(tier, track)`, `PlayAgain()`, `ClaimAccountReward(level)`.
  - Server to client:
    - `Storm(payload)`
    - `Ping({by, squad, kind, x, z, t})`
    - `Quests(view)`
    - `Pass(view)`
    - `Awards({mvp, accolades = {[userId] = {...}}, you})`
    - `Leaderboards({[board] = {{name, value}…}})`
    - `Redeploy({until})`
  - Ownership: M2 handles Ping, QuickChat, SetBusy and PlayAgain. P handles the quest, pass and account-reward remotes and sends Quests, Pass and Leaderboards.
