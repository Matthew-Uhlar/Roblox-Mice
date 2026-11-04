# V2 QC B: security, monetization policy, data safety and UX (squad PvPvE)

- **Commit reviewed:** `7301773` on `claude/focused-gates-jihpzi` (the v2 fix round: leaderboard budget, Rind Gate, Results stage, PvP pacing, Fx cull).
- **Scope:**
  - Every v2 remote: `ExtractVote`, `SwapGear`, `BuyCartItem`, `SelectPerk`, `ResetPerks`, `SelectAbility` and `SelectSkin`, plus the v1 remotes.
  - PvP rules: protection, safe zones, MoveGuard with 12 players, and the Downed/Protected attributes.
  - Monetization in a PvP game.
  - Profile v5 and the v1→v5 migration chain.
  - Leaderboards.
  - The publish pipeline.
  - Policy and UX, including the new screens at 667×375.
- **Docs checked against:**
  - AGENTS.md and HANDOFF.md
  - GDD-v2.md
  - MONETIZATION.md
  - research/monetization.md (§2 rules 1–8)
  - QC2 and FINAL-B
  - publishing/SETUP.md
- **Method:**
  - This was a read-only review. Every finding was confirmed by reading the cited lines.
  - Only this file was written.
  - `scripts/check.sh` printed **CHECK PASSED** (exit 0).
  - Behaviour marked *(verify)* needs Studio or a device.

Severity scale (as in QC2 and FINAL-B):

- **Blocker:** must be fixed before anything is sold or published.
- **Major:** fix before a public launch.
- **Minor:** fix when convenient, or accept the risk knowingly.
- **Nit:** wording or cosmetic.

---

## Summary

| Severity | Count | Headline |
|---|---|---|
| Blocker | **0** | No Robux path reaches the pot, Double or Nothing, gear, carts or class XP. There are no paid random items, and the API key is never printed or committed |
| Major | **2** | **V2-M1:** paid Second Wind tokens are a PvP advantage (a revive with 5 s of PvP immunity that cancels an enemy's elimination). **V2-M2:** the maturity questionnaire guidance doesn't cover player-vs-player combat |
| Minor | 9 | Combat-logging pays better than being wiped; the `heroDowns` board can be farmed on bots; teammates can buy from a cart anywhere on the map; one squad's vote recolours the shared Rind Gate for all squads; the respec token is always spent before cheese; phone perk-tree nodes are about 29 px; the extraction panel covers the arena during live PvP; a cosmetic tint Highlight may fight the squad outline *(verify)*; the publish secret is visible to every job step |
| Nit | 6 | Wording: "gamble", "Bloodthirst" (still present), "squad's pending cheese"; undisclosed Second Wind blocks; Club "No combat stats"; Studio profiles |

**What is solid:**

**Remote validation.**
- Every v2 remote goes through `Guard.connect`, with typed and ranged arguments and a rate limit.
- Every handler re-derives the squad, the offer and the cart from server state:
  - `onExtractVote` only casts into `x.votes[pr.squad]`;
  - `onSwapGear` only answers the caller's own `pr.swapOffer`;
  - `buyCart` requires `cart.squad == h.squad`.
- You can't vote for, swap for or buy for another squad.

**No duplication.**
- Gear lives in the World:
  - `giveGear` either equips the item, opens one swap offer, or drops the item on the ground;
  - `resolveSwap` moves exactly one item;
  - `_dropBagOf` empties `p.gear`.
- Bags are claimed once (`MatchState.claimBag` nils the key).
- Cart stock is decremented in the World (`Pois.takeCartOffer`) and in RunDirector (`cart.bought`).
- A leaver's gear drops in a bag (`World.removePlayer`).
- No path that adds an item to one place fails to remove it from the other.

**The Rind Gate fix holds.**
- `eliminateFallen` runs with no yield between it and `resolveExtraction` (`RunDirector.luau:2453-2468`).
- `fallenSquads` treats dead members as fallen and members with no World record as unknown (`MatchState.luau:685-707`).
- `gateOver` keeps the wipe check running during the route choice and the extraction window.

**Attributes are server-owned.**
- `Downed`, `Protected`, `Squad` and `DownedHits` are written by `CombatService.applyHumanoids` (`CombatService.luau:276-283`).
- Damage and protection are read from World state (`World.damageHeroFrom`, `World.luau:868-940`), never from attributes.
- The only server-side attribute reads compare against server state (`CombatService.luau:148, 286`) or read server-set Player attributes (`CosmeticsService.luau:101, 116`).
- A client's local attribute edits never replicate, so no attribute a client can spoof is trusted.

**MoveGuard scales to 12 players.**
- It checks humans only, at O(n) per step.
- During dash and spawn graces, out-of-reach samples are *ignored*, never accepted (`MoveGuard.luau:175-179`).
- PvP hit tests use the World position, which MoveGuard has checked.

**Class progression is earned only.**
- Class XP is never multiplied (`DataService.luau:708-727`; `payMember` passes `classXp` without `xpMult`).
- Class XP is capped per run (`ClassProgress.MAX_RUN_XP` 5000, `maxHeroDowns` 30).
- Perks, abilities and skins are validated on the server (`ClassProgress.canTake`, `isAbilityUnlocked`, `skinAllowed`).
- `classState` is snapshotted at run start (`RunDirector.luau:3452-3455`), so a lobby respec mid-run changes nothing.

**Robux never reaches the pot.**
- `cheeseMult` is applied only in `payMember` after the payout (`RunDirector.luau:1548`).
- Cache, vault, bounty, bag and cart cheese never see a Robux multiplier.

---

## Major

### V2-M1. Paid Second Wind tokens are a PvP advantage (pay-to-win)

**Where:**
- `src/shared/Data/RunTokens.luau:43-80`: 1 free self-revive per run, plus up to `maxTokenRevivesPerRun = 2` token revives (`Config/Monetization.luau:79-81`).
- `src/server/Services/RunDirector.luau:2731-2795` (`onUseSecondWind`).
- `src/shared/Combat/World.luau:714-731` (`useSecondWind`) → `_revive` (`:681-708`). This gives 50% HP, `REVIVE_GRACE`, 2 s of extra invulnerability, a mouse shove, **and `SPAWN_PROTECT` 5 s of PvP immunity** (`:701-705`).
- `World._checkSquads` (`:3048-3090`): a fully downed squad waits `ELIM_GRACE` 5 s while a Second Wind is still possible, and a revive cancels the elimination.
- Sources of tokens:
  - `second_wind_1` (49 R$) and `second_wind_3` (129 R$) (`Config/Monetization.luau:227-246`);
  - Cheese Club, +1 per day (`:92-93`, `:296`).
- `MonetizationService.prompt` (`:730-798`) has no run or phase check. A downed player, or an exploit firing `PromptProduct("second_wind_1")`, can buy a token in the middle of a fight and use it within seconds.

**Evidence:**
- In co-op, a token was a "continue" against the horde.
- In v2, the token is used against other players. Squad B downs the last standing member of squad A. A's downed human pays a token:
  - they stand up immune to B for 5 s;
  - A's elimination is cancelled, so B loses the loot bags (30% of every share), the kill and bounty credit, and possibly Last Herd Standing.
- Over a 4-stage match, a payer has up to 3 self-revives; a non-payer without stock has 1.
- Tokens are *also* free: the daily streak gives them, and the cheese shop sells them for 1,000 cheese (`Config/Shop.luau:51-52`). They are capped, and their runs are unranked.
- That limits the leaderboard damage, but not the advantage over the opponent in the match, who is usually a real player.
- GDD-v2 §7 says "no pay-to-win". `MONETIZATION.md` still describes the token as a "continue" written for co-op.

**Risk:**
- PvP pay-to-win is the top review-bomb and retention risk for this genre on Roblox.
- It breaks the project's own stated rule.
- It is **not** a Roblox policy violation, which is why this is Major and not Blocker.

**Fix (pick one, in order of preference):**
1. **Disable token revives when the revive affects PvP.** Allow only the free revive while two or more squads are in the run, and keep tokens for solo or co-op modes. In `RunTokens.useSecondWind`, add `ctx.pvp` → `return false, "blocked_pvp"` before the token branch, and pass `pvp = c.pvpWorld` from `probeSecondWind`.
2. **If tokens stay in PvP, take the PvP edge out of the revive:**
   - no `SPAWN_PROTECT` after a `secondWind` revive (pass a kind flag to `_revive`);
   - no revive inside `ELIM_GRACE` once an enemy hero dealt the last down;
   - tokens limited to one per run.
3. **In every case:**
   - refuse `second_wind_*` prompts while the player is a run member (add `RunDirector.isRunning()` / a member check to `prompt()`), so nobody can buy in the middle of a fight;
   - update the `benefit` text, MONETIZATION.md and the Club text to say how tokens behave in PvP.
4. **Do not change** the free per-run revive or teammate revives. They are fair because everyone has them.

Related (Minor, no action needed): Robux cheese boosts speed up cheese-bought talents and reroll tokens. Talents were trimmed in v2 (`Config/Talents.luau:3-5`; at most +20 HP, +10% damage) and both are earnable. Keep the "accelerates progression" disclosure, and never raise talents back up while PvP exists.

### V2-M2. Maturity questionnaire guidance does not cover player-vs-player combat

**Where:**
- `docs/publishing/SETUP.md` §5 says "Violence: cartoon combat only. Elephants stomp mice and fight bosses … The v2 redesign adds squad-vs-squad play, so answer for the current build."
- `docs/MONETIZATION.md` Compliance checklist targets "Minimal or Mild".
- The game now has:
  - avatars of real players damaging, downing and killing each other (`World.damageHeroFrom`, `_kill`);
  - a kill feed with a skull icon (`KillFeedUI.luau:27-28`);
  - kills, streaks and bounties (`MatchState.luau:784-819`).

**Risk:**
- The owner fills in the questionnaire from SETUP.md.
- An answer of "creatures only" or "occasional" would misdeclare repeated player-vs-player violence. Roblox can re-rate the game or take enforcement action for an inaccurate questionnaire, and the label gates ads and all-ages discovery.

**Fix:** rewrite SETUP.md §5 to say exactly what to answer *(verify the current questionnaire wording in Creator Hub)*:
- **Violence: Yes.**
  - It is unrealistic, cartoon violence.
  - It is **repeated or frequent** (the core loop).
  - It is aimed at creatures (mice, bosses) **and at other players' avatars** (squad PvP: players down and "kill" each other; a kill feed shows it).
  - There is no blood, gore, dismemberment or realistic weapons. Defeated heroes fall down and drop a loot bag.
- **Blood:** none. Rename "Bloodthirst" and "Lifeblood" (see the Nits) so the content matches the answer.
- **Expected label: Mild** (repeated mild/unrealistic violence). If the questionnaire maps "violence against humanoid characters" to a higher tier, accept that answer honestly rather than tuning it to a target. A higher label affects ads and audience, not legality.
- **Also update:**
  - "Bots: solo players get bot teammates" → "bots fill empty seats in every squad, **including rival squads that fight the player**; they are labelled 🤖 everywhere".
  - "Gambling: …" → also say that Double or Nothing never accepts Robux or Robux-bought currency, and that PvP loot bags hold only earned in-run cheese and gear.
  - Social: free-form text chat between players of rival squads (standard Roblox chat).

---

## Minor

### V2-m1. Combat-logging pays better than being wiped, and denies the enemy their loot

**Where:**
- `MatchState.removeMember` (`MatchState.luau:709-733`) banks `LEAVER_KEEP_FRAC` = 50% of the share and drops **no cheese bag**.
- An eliminated member first drops a 30% bag (`_dropBag :636-650`) and then keeps 50% of the rest (`eliminateSquad :652-683`), which is 35%.
- `RunDirector.onPlayerRemoving` (`:3587-3632`) → `World.removePlayer` drops only the gear (`World.luau:439-441`).

**Risk:** a downed player whose squad is about to be wiped can leave the game to keep 50% instead of 35%. The enemy squad loses the 30% bag, the kill and any bounty. This is the classic extraction-game "combat log".

**Fix:** in `removeMember`, a member who is downed, or was hit by an enemy hero within `World.ASSIST_WINDOW`, during Waves, Boss, RouteChoice or Extraction, takes the elimination path:
- `_dropBag` at their position;
- `ELIMINATED_KEEP_FRAC` of the rest;
- kill credit to `lastHitBy`.

`onPlayerRemoving` must then place the bag (`dropBag` with `heroPos`).

### V2-m2. The `heroDowns` board (and class XP) can be farmed on bots and repeat downs

**Where:**
- `MatchState.heroDowned` (`:760-783`) counts `k.downs += 1` for **any** enemy-squad member, bots included, on every down.
- Per-run cap: 10,000 (`Award.luau:136`).
- Board: `LeaderboardService.luau:49`.
- Class XP: 25 per down, up to 30 per run (`ClassProgress.luau:51-57`).

**Evidence:**
- A solo human always faces 9 bots.
- A downed bot is revived by its squad-mates and gets 5 s of protection, after which it can be downed again.
- Each cycle adds +1 to the global "PvP downs" board.
- No bot or Studio id can get an entry: `submit` requires `UserId > 0` (`:163`).

**Risk:** the board measures bot-farming, not PvP. That is a leaderboard-integrity and disclosure issue.

**Fix:**
- Count a down for the board only when the victim is human (`not Ids.isBot(victim)`), or at most once per victim per stage.
- Keep bot downs for class XP if wanted, already capped at 30.
- Name the board "Hero downs (incl. bots)" if the rule stays.

### V2-m3. A squad can buy from its cart anywhere on the map, at any later time in the stage

**Where:**
- `openCart` (`RunDirector.luau:1331-1357`) stores `c.carts[poi] = {squad = opener's squad}`.
- `buyCart` (`:2549-2591`) checks only `cart.squad == h.squad`, the funds and the stock. There is no distance check, and it works in every `LIVE_PHASES` phase (Waves, Boss, RouteChoice, Extraction) until the stage ends (`c.carts = {}` at `:3034`).
- If a rival hero opens the same cart, `squad` is overwritten and the first squad is locked out.

**Risk:** the opener's teammates, and the opener after walking away, can shop remotely, even while fighting the boss. This removes the "contested cart" design (GDD-v2 §4). The cost is in-run only and no Robux is involved, hence Minor.

**Fix:**
- Store the opener ids per cart, or require the buyer to be within `e.r + 2` of the cart in World state (`world:getPlayer(id)` vs the POI position).
- Close the cart for a hero who leaves its radius (Pois already tracks `e.opened` per hero).
- Allow buys only in Waves.

### V2-m4. One squad's extraction vote recolours the shared Rind Gate for everyone

**Where:** `onExtractVote` (`RunDirector.luau:2515-2518`) → `setPortal(c, "open", PORTAL_COLORS[choice])` → a World Fx to every client plus `ArenaBuilder.setPortalColor` on the workspace part (`:1492-1501`).

**Risk:**
- The gate is shared by all 4 squads.
- The last human vote of any squad shows its choice to every rival. Red, for example, means "Pepper Jack is going Double or Nothing, hunt them".
- Each squad's voters can also make the gate flicker colours up to 4 times a second.

**Fix:** tint the portal per viewer (a client-side tint from the viewer's own squad votes, which `Net.S2C.Extract` already carries), or keep the server tint gold during the window.

### V2-m5. Respec always spends a paid token when the player has one

**Where:**
- `PerkTreeUI.luau:435-436` sends `"token"` whenever `respecTokens > 0`, and the button only offers "Respec (token ×N)" (`:503-506`).
- `ClassProgress.resetPerks` with `nil` also prefers a token (`ClassProgress.luau:539`).

**Risk:** a player who would rather pay a few hundred cheese burns a 49 R$ token without being asked. The amount is small, but it is a consumer-fairness issue for a Robux consumable.

**Fix:** when the player has both, show two buttons ("🧀 N" and "Token"), or default to cheese if the player can afford it and require a second tap for the token.

### V2-m6. Perk-tree nodes are about 29 px on a 667×375 phone; node labels overlap *(verify on device)*

**Where:**
- `PerkTreeUI.luau:82-83, 214-229`: the panel is 900×580, the head is `touch + 10` = 104, and the canvas is about 436 design px.
- `PerkTree.layout` (`PerkTree.luau:290`) gives `node = min(68, rowH − 22)`, which is about 57 design px.

**Evidence:**
- The safe viewport is about 667×317, so the scale is 0.511.
- A 57 design px node is about 29 screen px, below the project's 48 px touch rule (Layout `MIN_TOUCH_PX`, STYLE.md).
- The name label (`:318-327`, 16 design px tall, micro 12) is floored to 24 design px by `Theme` `floorText`. The gap between rows is about 21 design px, so the names spill onto the links and the next node.
- The other new screens fit:
  - Scoreboard 760×470, Extract 964×504, ShopCart 420×~400: all `fitFrame` into a root of about 1305×620.
  - The HUD top-right stack (minimap 150, kill feed 5×32, buffs) ends at y≈458 of 620.

**Fix:**
- On touch devices, lay the tree out as one branch per page (tabs) or as a vertical scroller, with nodes ≥ `Theme.TOUCH`.
- Alternatively, draw the names in a detail panel on tap instead of under each node.

### V2-m7. The extraction panel covers about 75–80% of the arena while PvP is live

**Where:**
- `ExtractUI.luau:95-106`: 3 cards of 300×(300 + touch), about 964×504 design px. It cannot be dismissed and stays up for the whole 20 s, even after you vote (`:390-391`).
- The World keeps stepping and bots keep fighting during the route choice and the extraction window (`gateOver`, `BotBrain` has no phase gate).

**Risk:**
- Humans vote blind while rivals and bots can still down them.
- A squad downed at the gate is now eliminated (the Rind Gate fix), so the blind vote can cost a wipe.
- Bots don't have a panel, so the disadvantage falls on humans.

**Fix:** after the player votes, collapse the panel to a compact ribbon. Alternatively, give every squad PvP protection during the extraction window, or shorten the cards on touch.

### V2-m8. A cosmetic tint Highlight may conflict with the enemy squad outline *(verify)*

**Where:**
- `CosmeticsService.buildTint` (`:271-283`) puts a `Highlight` on the character for paid and earned tints: Founder Gold, Lagoon, Lava, Club Teal and others.
- `FxController.setHighlight` (`:1945-1975`) adds a second Highlight (`SquadHighlight`) for enemy identification.

**Risk:**
- If Roblox renders only one Highlight per adornee, a tint could hide or replace the enemy squad outline. Tints such as Lava (red) next to Pepper Jack (red), or Founder Gold next to Swiss (gold), read as another squad's colour.
- That would make a paid cosmetic a PvP disguise *(verify the multiple-Highlight behaviour in Studio)*.

**Fix:** during a run, disable the `Tint` Highlight, or fold the tint into the `SquadHighlight` fill and keep the outline in the squad colour.

### V2-m9. The publish workflow exposes the API key to every step, including the test suite

**Where:**
- `.github/workflows/publish.yml:23-26` sets `ROBLOX_API_KEY` as **job-level** env.
- That env reaches `install-tools.sh`, `check.sh` (Lune runs repo code with `process.env`) and `lune run scripts/catalog.luau`.
- The workflow can be dispatched on any branch (`workflow_dispatch`, `contents: write`).

**What is fine:**
- `publish.py` puts the key only in the `x-api-key` header (`:135-146`).
- Errors show only the method, path and status (`:96-98`, `:161`).
- `ProductIds.luau` holds only ids.
- The tools are pinned with sha256 (`install-tools.sh:20-25`).
- CI on PRs gets no secrets.

**Risk:** several agents push branches. A branch whose spec or workflow reads the env could leak the key in a dispatched run. That matters because the key can publish places and create products.

**Fix:**
- Move `ROBLOX_API_KEY` to the `env:` of only the `products`, `place`, `configure` and `smoke` steps.
- Put the job in a GitHub **Environment** (for example `roblox-production`) with "deployment branches: `main`" and a required reviewer.
- Do the same in `status.yml` and `upload-assets.yml`.
- Keep the key's 90-day expiry (SETUP.md §3).

---

## Nits

1. **"gamble".** `ExtractUI.luau:78` says "Stay and gamble the pot". Use "risk the pot" to keep the UI away from gambling vocabulary (research rule 2).
2. **"Bloodthirst" is still present** (`Config/Upgrades.luau:340`, FINAL-B Nit 3). New similar names:
   - "Lifeblood" (`ClassPerks.luau:185`)
   - "Vampiric Blade" (`:310`)
   - "Killer Instinct" (`:287`)
   - the Filet branch "Butcher" (`:340`)

   They are not blockers, but rename them before filling in the questionnaire as Mild: for example "Hungry Herd", "Wellspring Heart", "Cheese-Leech Blade", "Sharp Instinct", "Chop Shop".
3. **ShopCart text.** `ShopCartUI.luau:82` says "Paid with your squad's pending cheese". The server spends the **buyer's own share** (`MatchState.spendShare`). Say "your pending cheese share".
4. **Second Wind benefit.** The text (`Monetization.luau:233`) doesn't mention the Double-or-Nothing and last-10%-boss blocks (`RunTokens.luau:64-71`). Players may buy one and find it refused. Add "not usable on Double-or-Nothing stages or in a boss's last 10%" (and the PvP rule from V2-M1).
5. **Cheese Club "No combat stats".** This is true, but the daily +1 Second Wind is combat-relevant in PvP. Revisit the wording with V2-M1.
6. **Studio profiles.** `DataService.isRealPlayer` accepts Studio ids −1…−8 (`DataService.luau:130`). With "Studio Access to API Services" on, those test profiles are written to the **live** DataStore under keys "-1", "-2" and so on. The leaderboards still refuse them (`LeaderboardService.luau:163`). This is harmless, but consider an in-memory store for ids ≤ 0 in Studio.

---

## Remote handler audit (v2 and changed)

| Remote | Handler | Validation | Rate (/s, burst) | Phase / ownership | Verdict |
|---|---|---|---|---|---|
| ExtractVote | `RunDirector.luau:2494` | `T.enum(CHOICES)` | 4, 6 | Phase "Extraction"; `pr.out` refused; casts only into the caller's own squad's vote; DoN needs a human vote (`Vote.riskyIndices`) | OK. V2-m4 (portal colour leak) |
| SwapGear | `:2524` | `T.boolean` | 4, 4 | `LIVE_PHASES`; only the caller's own `pr.swapOffer`; expired offers ignored; the World moves exactly one item | OK (no remote or other-player swap, no dup) |
| BuyCartItem | `:2593` → `buyCart :2549` | int poiId, index 1..8 | 3, 4 | `LIVE_PHASES`; `cart.squad == h.squad`; `cart.bought` and World stock; `spendShare` (pending share only, never profile or Robux); refund only when the World refused | OK on currency. V2-m3 (no proximity or phase limit) |
| SelectPerk | `ShopService.luau:338` → `ClassProgress.selectPerk` | string 32, string 64 | 4, 8 | Class unlocked; tier order; points; no phase check needed (the run snapshot is fixed) | OK |
| ResetPerks | `:345` → `resetPerks` | string 32, optional enum cheese/token | 0.5, 2 | Class unlocked; must have perks; cost 100×level (min 200) or 1 token; saves | OK. V2-m5 (token default) |
| SelectAbility | `:352` | string 32, optional string 64 | 2, 4 | `unlockLevel <= level` | OK |
| SelectSkin | `:359` | string 32, optional string 64 | 2, 4 | `skinAllowed` (level skins or owned paid skins); cosmetics redraw is coalesced | OK |
| UseSecondWind | `RunDirector.luau:2731` | none | 2, 2 | Downed, not dead, `RunTokens` caps; charge before revive, refund on refusal | Logic OK. **V2-M1** (PvP) |
| PromptProduct | `MonetizationService.luau:910` | string 32 | 1, 3 + 1.5 s | Real players only; no run-phase gate | V2-M1 fix 3 |
| BuyShopItem | `ShopService.luau:314` | string 64 | 4, 6 | No phase gate: talents bought mid-run apply at the next `computeStats` (`RunDirector.luau:718-724`) | Accepted (cheese only, small talents) |
| Vote, ChooseUpgrade, RerollUpgrade, UseAbility, SetReady, SelectClass, SetBotFill, SetPressure, SetSetting, Equip, ClaimDaily | unchanged | as in FINAL-B | as in FINAL-B | Vote limited to `v.voters` (route chooser's squad); Pressure leader computed by the server, locked 5 s before start (`LobbyService.luau:1128-1134`) | OK |

`InteractPoi` was removed from `Net.C2S` (FB-m2), so no remote is left without a handler.

---

## PvP fairness and safety

| Check | Result | Evidence |
|---|---|---|
| Spawn and revive protection | Pass | `DROP_PROTECT` 9 s at drop-in, `SPAWN_PROTECT` 5 s after a revive (`World.luau:135-136, 701-705`). Attacking a rival ends it (`:879-883`). Protected targets are excluded from `forFoesInCircle`. *Note:* a protected hero can still channel bags and POIs, which the protection doesn't stop. Acceptable. |
| Safe zones | Pass | −60% damage from other squads inside your own zone only (`:902-904`). Zones come from ArenaBuilder, not the client. |
| No friendly fire, no PvP crits | Pass | `h.squad == by.squad → 0` (`:872-874`). |
| MoveGuard at 12 players | Pass | Humans only, per player, O(n). Violations snap back with `PivotTo`; 10 make the run unranked (`CombatService.luau:207-243`, `RunDirector.isRanked`). |
| Dash and teleport | Pass | A dash is server-issued (`drainTeleports`, `TELEPORT_GRACE` 0.75 s). In grace, an out-of-reach client sample is ignored (the World keeps the server position), so a client teleport timed with a dash gains nothing. |
| Downed/Protected attribute spoofing | Pass | Set by the server, read by the client only for Highlights (`FxController.luau:1966-1967`). The server never trusts them. |
| Paid revive in PvP | **Fail** | V2-M1 |
| Leaving the game to avoid loss | Partial | V2-m1 |
| Griefing other squads (votes, carts, swaps) | Pass | See the audit above. Only an information leak remains (V2-m4). |

---

## Monetization regression

### Every pass and product in PvP

| Item | PvP combat power? | Verdict |
|---|---|---|
| VIP Herd | No: nametag, title, chat tag, trail, hat; daily 150 cheese + 5 GC | Pass |
| Fast Learner | No: account XP only. Class XP is never multiplied (`DataService.luau:708-727`) | Pass |
| Herd Leader | No: +15% cheese for *everyone* in the server, rivals included, applied to the banked payout | Pass |
| Founders' Stampede | Indirect: all 7 classes early (all earnable; class levels still start at 1) | Pass (disclosed) |
| Cheese Wardrobe, Gilded/Neon skin passes, skins for GC | No stats (`ClassSkins.luau:9`). Tints: V2-m8 *(verify)* | Pass |
| Golden Cheese packs | GC buys only fixed cosmetics and paid skins (`Config/Shop.luau`). It never converts to cheese | Pass |
| Cheese Rush / Feast | Indirect: more cheese → cheese-bought talents and reroll tokens, both small and earnable. Applied after the bank only | Pass (disclosed "accelerates progression") |
| **Second Wind x1 / x3, Club daily token** | **Yes:** a revive with 5 s PvP immunity that cancels an elimination | **Fail (V2-M1)** |
| Perk Respec Token | No: refunds earned points only. Cheese respec always available (`ClassProgress.resetPerks`) | Pass (V2-m5 UX) |
| Rerolls | Reroll tokens cost cheese only (`Config/Shop.luau:49-50`). There is no Robux reroll | Pass |
| Snack Break ad | Disabled; deterministic cheese | Pass |

### Policy rules

- **No paid random items: Pass.**
  - Every Robux item has `random = false` and a fixed handler (`Receipts.luau:59-117`).
  - Random gear (Armory Crate, Vault, carriers, chests, Shop Cart stock) is free, or paid with *pending* in-run cheese, which no Robux multiplier touches (`addSquadCheese`, `spendShare`).
  - Carriers are golden mice that drop gear for free.
- **Robux never touch Double or Nothing, Pressure, gear or carts: Pass.**
  - Token revives are blocked on Double-or-Nothing squads (`probeSecondWind` → `squadDoubleOrNothing`).
  - No prompt exists in the Extract, Vote, Results, Cart or Gear UI (grep finds none).
  - Gear is never sold (`Gear.valid` items come only from World rolls).
- **Benefit text matches what is delivered: Pass,** with the exceptions in Nits 3–5 and V2-M1.
- **ProductIds and the pipeline: Pass for leaks; V2-m9 is hardening.**
  - `write_product_ids` writes only keys and ids.
  - The commit step adds only `ProductIds.luau` / `AssetIds.luau`.
  - The key is never printed.

---

## Data safety (profile v5)

| Check | Result | Evidence |
|---|---|---|
| Migration chain v1→v5 | **Pass** | `MIGRATIONS[1..4]` run on a shallow copy (`ProfileSchema.luau:376-445`). v4→v5 adds `classes` (owned classes at level 1), `ownedSkins = {}` and `respecTokens = 0`. A failed step or reconcile on a non-empty save is "corrupt" and read-only (`:470-500`, `sessionMode`). Future versions are opened read-only. |
| Reconcile of the v5 fields | **Pass** | `paidSkinSet` runs before `sanitizeClasses`. `ClassProgress.sanitize` clamps level 1..30, xp below `xpToNext(level)`, perks to a valid tier order within the points budget (dropping the top tiers first), and only unlocked abilities and allowed skins. `respecTokens` is capped at `MAX_TOKENS`. |
| `view()` exposure | **Pass** | Adds `classes` (`ClassProgress.view`: derived numbers only), `ownedSkins` and `respecTokens`. `passGrants`, purchase history, ad counters and club internals stay server-side. MonetizationService's decorator adds only flags and multipliers. |
| Class XP caps | **Pass** | Per run: `MAX_RUN_XP` 5000 (clamped in DataService and in `award`). Inputs capped: stages 8, boss share 8, downs 30, POIs 30. Never multiplied by Robux. |
| Respec abuse | **Pass** | A respec only refunds earned points. Cost is 100×level (min 200) cheese or 1 token, with a 0.5/s rate and a save. No currency is created. |
| Paid skin revocation | **Pass** | `passGrants[key].skins` records only the skins that pass newly granted. A refund removes those and never skins bought with GC (`Passes.luau:108-189`). |
| Leaderboard writes | **Pass** (V2-m2) | Ranked stats only. At most one submit per 60 s, improvement-only `UpdateAsync`, budget wait (`LeaderboardService.luau:128-182`). `heroDowns` and `lastHerd` are cumulative ranked totals (`Award.luau:136-144`). |
| Bots or Studio ids on leaderboards | **Pass** | `submit` requires a Player with `UserId > 0` (`:163`). The refresh drops keys ≤ 0 (`:229-230`). Bots never call `awardRun` (`RunDirector.isHuman`). Bot *victims* still count toward a human's `heroDowns` (V2-m2). |
| Leaver payout | **Pass** (V2-m1) | Paid once (`pr.awarded`), from `beforeRelease`, kept 120 s in `departed`. Double or Nothing pays 0. |

---

## QC regression table

| Earlier finding | Status at `7301773` | Evidence |
|---|---|---|
| QC2 B1: cosmetics / nametag / chat tag not rendered | Fixed (held) | CosmeticsService; ChatTags now also adds the squad tag (`ChatTags.luau:64-76`), escaped |
| QC2 M1: movement anti-cheat | Fixed (held, 12 players OK) | MoveGuard / CombatService as above |
| QC2 M2: lobby stall | Fixed (held) | `LobbyRules`, `UPDATE_DEBOUNCE` |
| QC2 M3: bots stake DoN for a human | Fixed (held, v2 too) | `botExtractVote` waits for a human (`RunDirector.luau:2380-2388`); all-bot squads never choose DoN (`:2420-2425`); `Vote.resolve` needs a human (`Vote.luau:107-113`) |
| QC2 M4: boosts bought at their cap | Fixed (held) | `boostHeadroom`, overflow refund (`Receipts.luau:73-86`) |
| QC2 M5: pass perks unverified, never revoked | Fixed (held; skins included) | `verifyPurchase` / `UserOwnsGamePassAsync` (`MonetizationService.luau:218-267`); revocation on join |
| QC2 M6: migration error wipes the profile | Fixed (held through v5) | `migrate` failed → corrupt |
| QC2 M7: 30-min lockout | Fixed (held) | `STALE_LOCK_SECONDS = 7*60` (`DataService.luau:68`) plus the handshake. FB Nit 1 wording fixed ("in a few minutes", `:213, :338`) |
| QC2 M8: mobile overflow | Fixed (held) | `fitFrame` on the new panels. New: V2-m6 (perk nodes) |
| QC2 m1–m5, m7, m9–m13 | Fixed / accepted (held) | Unchanged code paths |
| QC2 m6: no guest mode | Open (accepted) | `DataService.luau:317` still kicks |
| QC2 m8: talent clamp, no refund | Open | No `maxLevel` was lowered, but v2 *trimmed* `perLevel` values (`Talents.luau:3-5`), not levels, so nothing is clamped. Still open for future changes |
| QC2 m14: analytics | Open (n/a) | none |
| FINAL-B FB-M1: phone text size | Fixed | `Layout.textSize` + `Theme` `floorText` (`Layout.luau:49-59`, `Theme.luau:1001-1036`) |
| FB-m1: Pressure changed at the last instant | Fixed | `PRESSURE_LOCK_SECONDS = 5` (`LobbyService.luau:1103, 1128-1134`) |
| FB-m2: `InteractPoi` without a handler | Fixed | Removed from `Net.C2S` |
| FB-m3: docs disagree on Pressure / schema | Fixed | `ProfileSchema.luau:9-11`; MONETIZATION "schema v5" |
| FB-m4: POI labels / hint | Fixed | `ArenaBuilder.luau:839-840` `PoiLabel` |
| FB-m5: portal fade covers picks | Fixed | Fade `DisplayOrder = 12` (`FxController.luau:1797`) |
| FB Nit 2: Epic reroll fallback ignores the cap | Open (harmless) | `RunDirector.luau:2839` `+1` with no cap |
| FB Nit 3: "Bloodthirst" | **Open** | `Upgrades.luau:340` (Nit 2 above) |
| v2 Rind Gate wiped-squad extraction | **Fixed (verified)** | `eliminateFallen` → `resolveExtraction` with no yield; `fallenSquads` |
| v2 leaderboard budget | Fixed (verified) | `waitForBudget` returns false; refresh skipped |

---

## Policy compliance checklist

| # | Rule | Result | Evidence |
|---|---|---|---|
| P1 | No paid random items | **Pass** | Fixed handlers; random gear is free or bought with pending cheese |
| P1b | PolicyService gate available | **Pass** | `paidRandomItemsRestricted` unchanged |
| P2 | Robux never touch Double or Nothing | **Pass** | Multiplier only after the bank; DoN token block; no prompts on vote, loss or extract screens |
| P2b | Robux never touch Pressure, gear or carts | **Pass** | No reference in Monetization, Receipts or Shop; `spendShare` uses the pending share only |
| P2c | No pay-to-win (GDD-v2 §7, project rule) | **Fail** | V2-M1 |
| P3 | Age / audience publishing | n/a (owner) | SETUP.md §6 |
| P4 | Maturity questionnaire answered for the current build | **Fail (docs)** | V2-M2; Nit 2 |
| P5 | Parental spend controls, no re-prompting | **Pass** | `purchased == false` is silent; cooldowns |
| P6 | No dark patterns | **Pass** | No timers or scarcity. Downed panel uses owned tokens only (`HudUI.luau:844-882`). V2-M1 fix 3 closes an exploit-driven mid-fight prompt |
| P7 | Refunds and chargebacks | **Pass** | Revocation on join, paid skins included |
| P8 | Rewarded ads 13+, free path | **Pass (disabled)** | `ADS_ENABLED = false` |
| R1–R7 | ProcessReceipt checklist | **Pass** | Unchanged; `respec_token` handler is idempotent via `Receipts.apply` |
| R12 | Products deliver what they advertise | **Pass** (Nits 3–5) | See the table above |
| D1–D9 | Locking, migration, no double award | **Pass** | Data table above |
| BOT1 | Bots clearly labelled across squads | **Pass** | Name suffix "🤖" (`BotRoster.luau:387, 489`); `State.nameOf` adds "🤖" for World bots (`State.luau:319-328`); scoreboard and party HUD prefix (`ScoreboardUI.luau:270-272`, `HudUI.luau:314-318`); kill feed uses `nameOf`; Extract UI says "🤖 bots follow their humans" |
| BOT2 | Bots never on leaderboards / analytics | **Pass** | `submit` requires `UserId > 0` |
| BOT3 | Bots earn nothing | **Pass** | `isHuman` gates |
| BOT4 | Bots never stake for a human | **Pass** | QC2 M3 held in v2 |
| T1 | User text filtered / none | **Pass** | No TextBox; names are DisplayNames or fixed bot names; chat tags and squad tags are rich-text escaped |
| T2 | IP-safe names | **Pass** | Checked: v2 perks, abilities, skins, gear, POIs, squad names (Swiss, Brie, Blue, Pepper Jack: generic cheeses) and bot names. No protected names found. "Musketeer Hat" and "Hunter's Mark" are generic. Maturity wording is in Nit 2 |
| S1 | Server authority over movement | **Pass** | MoveGuard |
| S2 | Remote validation and rate limits | **Pass** | Audit table |
| S3 | No client-trusted attributes | **Pass** | PvP table |
| S4 | Secrets never exposed | **Pass** (V2-m9 hardening) | `publish.py` header only; no printing |
| U1 | Touch targets ≥ 48 px | **Partial** | V2-m6 (perk nodes about 29 px) |
| U2 | Safe insets | **Pass** | `CoreUISafeInsets` |
| U3 | No overflow at 667×375 | **Pass** (new screens fit) | Scoreboard, Extract, ShopCart, PerkTree panels use `fitFrame`; HUD stack ends at y≈458/620 |
| U3b | Readable text on phones | **Pass** *(verify)* | Text floor 12 px |
| U4 | Combat readability during gate votes | **Partial** | V2-m7 |

---

## Suggested fix order

1. **V2-M1:** block token revives (or their PvP immunity) when two or more squads are in the run, and refuse revive-token prompts for run members. Update the benefit text, MONETIZATION.md and the Club text.
2. **V2-M2:** rewrite SETUP.md §5 with the exact questionnaire answers, and rename the blood and kill names (Nit 2) first.
3. **V2-m1 and V2-m2:** combat-log payout and `heroDowns` integrity, before the boards go public.
4. **V2-m9:** step-scoped secret plus a protected Environment, before the next publish.
5. **V2-m3, m4, m7:** cart proximity, per-viewer portal tint, collapsible extraction panel.
6. **V2-m5, m6, m8**, then the Nits.
