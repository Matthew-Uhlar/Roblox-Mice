# QC Team 2: security, monetization policy, data safety and UX review

- Reviewed commit: `1504b3d` ("Handoff: bots done, testing/QC running"). The dev teams had finished and committed by then. `tests/sim/` was untracked and was not reviewed.
- Scope: `src/server/**`, `src/shared/{Data,Config/Monetization,Bots}`, and the client UI and controllers.
- Docs checked against: HANDOFF §3, MONETIZATION.md, research/monetization.md (§2 policy rules 1–8 and the §5 dev checklist), research/tech.md (§2 security, §3 persistence, Pitfalls) and STYLE.md.
- Method: this was a read-only review. Every finding below was confirmed by reading the code at the cited lines. Nothing has run in Studio yet, so runtime behaviour marked *(verify)* still needs a live test.

Severity scale:

- **Blocker:** must be fixed before anything is sold or published.
- **Major:** fix before a public launch.
- **Minor:** fix when convenient, or accept the risk knowingly.

---

## Summary

| Severity | Count | Headline |
|---|---|---|
| Blocker | 1 | Cosmetics and pass perks that are sold are never shown in game |
| Major | 8 | No movement anti-cheat; lobby start griefing; bots can stake Double or Nothing for an idle human; timed boosts can be bought for nothing at their cap; pass perks saved without an ownership check; a migration error wipes the profile; 30-min lockout after a crash; mobile UI overflow |
| Minor | 14 | See below |

What is solid:

- **Remotes.** Every remote handler goes through `Guard.connect`, which checks types, NaN/inf and ranges and applies a token-bucket rate limit.
- **Clients send intents only.** The server checks votes, offers and abilities against the current phase and against offer ids it actually issued.
- **ProcessReceipt** follows the research checklist almost exactly.
- **Session locking** uses `UpdateAsync` with a lock token, retries with exponential backoff, and `GetRequestBudgetForRequestType`.
- **Bots** are labelled everywhere and never reach the Data, Monetization or Leaderboard services.

---

## Blocker

### B1. Sold cosmetics, the VIP nametag and the Club tag are never rendered
- **Where:**
  - `src/shared/Config/Monetization.luau:87` (VIP: "Gold nametag, Golden Tusk trail, VIP Crown hat"), `:126–128` (Cheese Wardrobe: six cosmetics), `:242` (Club: "Club chat tag").
  - `src/server/Services/ShopService.luau:362–376` (Equip only writes `profile.equipped`).
- **Evidence:**
  - Nothing outside the shop UI and the profile code ever reads `equipped`. The only hits for `grep -rn equipped src` are `Types`, `ShopUI` and `ShopService`.
  - No code creates a `Trail`, an `Accessory`, a hat, a tint or a nametag on a character. There is no chat-tag code and no `TextChatService` use.
  - VIP's "Gold nametag" and the Club's "chat tag" appear only in benefit strings.
- **Risk:**
  - Players would pay Robux (the Wardrobe pass, VIP, Golden Cheese packs spent on cosmetics, the Club monthly cosmetic) for items that have no visible effect.
  - That breaks the promise in each listing, invites refund and chargeback reports, and conflicts with Roblox's rule that a purchase must deliver what it advertises.
  - Today every `assetId` is 0, so nothing can be sold yet. That is why this blocks launch rather than being a live bug.
- **Fix:**
  - Build a `CosmeticsService` on the server: on `CharacterAdded` and on Equip, apply the trail (an `Attachment` pair plus a `Trail`), the hat (an `Accessory` from ServerStorage) and the tint (`BodyColors` or a highlight).
  - Add a BillboardGui nametag for VIP, and a chat tag via `TextChatService.OnIncomingMessage` (client) or `TextChatService` speaker properties for the Club.
  - Until all of that exists, either leave those `assetId`s at 0 or remove the unbuilt perks from the `benefit` text.

---

## Major

### M1. No server check on player movement (speed hacks, teleports, noclip)
- **Where:**
  - `src/server/Services/CombatService.luau:143–156`: `syncPositions` copies the client-owned `HumanoidRootPart` X/Z straight into the world every step.
  - `src/shared/Combat/World.luau:349–361`: `setPlayerPosition` only clamps to the arena circle and does not push the player out of obstacles.
  - `docs/COMBAT-API.md:110` already says "no per-step movement-distance check yet".
- **Risk:** characters are owned by their clients, so an exploiter can:
  - teleport onto downed teammates to revive them instantly;
  - outrun or skip every telegraph and vacuum up pickups;
  - stand inside rocks where mice can't reach them;
  - move while "dead" or "downed" (WalkSpeed 0 or ×0.3 is applied only on the exploiter's own client);
  - post impossible `fastestCycle1` leaderboard times. That board is global and ranked.
- **Fix:**
  - Keep the last accepted position per player.
  - In `syncPositions`, allow at most `moveSpeed × stateMult × dt × 1.3 + slack`. Use 0 when the player is dead, ×0.3 when downed, and add the dash distance on the step where the world teleported the player.
  - Above that limit, clamp the world position to the allowed step and `PivotTo` the character back.
  - Also run `pushOutOfObstacles` for players in `setPlayerPosition`.
  - Count violations, and flag the run as unranked after N of them.
  - Ignore the Y axis, because the sim is 2-D.

### M2. One player can stop the lobby from ever starting
- **Where:** `src/server/Services/LobbyService.luau:687–708` (`onSetReady`) and `:557–590` (`evaluate`).
- **Evidence:**
  - `ready=false` always calls `cancelCountdown()`, which clears `countdownKind`. `evaluate()` then re-arms a fresh 20 s (some ready) or 30 s (auto) countdown.
  - Toggling Ready → Unready every few seconds therefore restarts the countdown forever.
  - No exploit is needed: an ordinary client can do this by tapping the Ready button.
  - Each toggle also calls `broadcast()` → `refreshBots()`, which re-runs `BotRoster.fill` and `BotService.placeInLobby`, and fires a Lobby payload to every player. The rate limit is 3/s with a burst of 4.
- **Risk:** this is griefing of other real players. A 4-player server can be held in the lobby indefinitely by one person.
- **Fix:**
  - Once a countdown is armed, it may only get shorter, never longer.
  - An unready player should simply be left out of the next party (the idle players are pulled in anyway) rather than cancelling the countdown.
  - Alternatively, give each player a 2 s cooldown on Ready changes and cap the number of countdown restarts per lobby cycle.

### M3. Bots can stake an idle human's pot on Double or Nothing
- **Where:**
  - `src/shared/Bots/BotBrain.luau:458–482`: `VOTE_SURPRISE = 0.15` at `:71`. With no human votes, each bot picks `safe + 1` 15% of the time.
  - `src/server/Services/RunDirector.luau:1411–1419` (the bank vote).
  - `Vote.resolve` (`src/shared/Run/Vote.luau:75+`) breaks ties at random.
- **Evidence:** for a solo human with 2 bots who doesn't vote (AFK, or on a phone and missed the panel):
  - Both bots vote `DoubleOrNothing` with p = 0.0225.
  - The bots split with p = 0.255, and the tie-break coin flip then picks Double or Nothing half the time.
  - In total that is about 15% that the human's pending pot is wagered with no human input.
- **Risk:** Double or Nothing is the gambling-adjacent mechanic. Research rule 2 is satisfied, because only earned cheese is staked. But an AI placing a wager on a child's behalf is bad optics for a game aiming at a Mild/all-ages rating, and it will also generate "I lost everything and never voted" complaints.
- **Fix:**
  - For `kind == "bank"` / `"cycle"`, bots must never vote `DoubleOrNothing` unless at least one human did. Set `VOTE_SURPRISE` to 0 for bank votes.
  - Also require at least one human `DoubleOrNothing` vote for that option to win, so that bot votes alone can never choose it.

### M4. Cheese Rush and Cheese Feast can be bought while capped, and grant nothing
- **Where:**
  - `src/shared/Data/Boosts.luau:247–250`: `extendUntil` returns at most `now + maxStack`.
  - `src/shared/Data/Receipts.luau:58–68` (Rush, 24 h cap) and `:69–74` (Feast).
  - `src/server/Services/MonetizationService.luau:231`: Feast is capped at 2 h.
  - `MonetizationService.prompt` (`:475–530`) never checks remaining headroom.
- **Risk:**
  - A player holding 23.5 h of Rush who buys another hour pays 99 R$ and gets 30 minutes. At exactly 24 h they get nothing.
  - Feast behaves the same way: 149 R$ for zero extra time once the server is at the 2 h cap.
  - This is a consumer-protection and refund issue, and the receipt still returns PurchaseGranted.
- **Fix:**
  - In `prompt()`, refuse with a toast when `untilT - now + boostSeconds > maxStack`. For Rush, check the profile's `cheese2xUntil`. For Feast, check `feastUntil` plus pending feasts.
  - In the receipt handlers, turn any overflow into a fixed fallback rather than discarding it. For example, bank the extra time, or grant Golden Cheese worth the lost minutes, and disclose this in the `benefit` text.

### M5. Game-pass perks are saved permanently without checking ownership with Roblox
- **Where:** `src/server/Services/MonetizationService.luau:591–610` (`PromptGamePassPurchaseFinished`) → `setOwned` `:123–139` → `applyPassPerks` `:112–121`.
- **Evidence:**
  - When `purchased == true`, the code calls `setOwned` immediately, which writes the pass cosmetics and, for Founders, **all class unlocks** into the profile and saves.
  - The re-check 10 s later (`refreshPasses`) can only *upgrade* ownership (`:157` skips passes already marked owned). Nothing is ever revoked.
- **Risk:**
  - DevForum guidance is to treat this signal as UI-level and confirm with `UserOwnsGamePassAsync` before granting anything durable. There are historical reports of spoofed purchase-finished signals *(verify current status)*.
  - A false positive here is permanent and saved.
  - Separately, a refunded or chargebacked pass keeps its perks until the next rejoin (session flag), and its saved profile perks stay forever.
- **Fix:**
  - On `purchased == true`, set only the session flag. Then call `UserOwnsGamePassAsync` with 3 tries spaced about 2 s apart, and call `applyPassPerks` only when it returns true.
  - Treat the saved cosmetics and class unlocks as revocable: on join, if the pass is no longer owned, drop the pass-sourced items (`Cosmetics` `source = "pass"`).

### M6. A migration or reconcile error resets the profile, and the next save overwrites the real data
- **Where:**
  - `src/shared/Data/ProfileSchema.luau:347–350`: if `reconcile` throws, `migrate` returns `ProfileSchema.default()` with `fresh = true`.
  - `src/server/Services/DataService.luau:176–191`: `finishLoad` only checks `info.futureVersion`.
- **Risk:**
  - Any bug in `reconcile` or the configs it calls (`Shop.freeClassIds`, `Talents.get`, `Cosmetics.get`) turns a real save into a blank profile.
  - The next autosave, which runs within 120 s, overwrites the stored data, and the player's progress and purchases are permanently lost.
  - This contradicts "migration never drops data".
- **Fix:**
  - Add `info.failed = true` when `reconcile` throws on a non-empty table.
  - In `finishLoad`, set `s.readOnly = true` (or kick with "please rejoin") whenever `info.failed`, or whenever `fresh` is true but `raw` was a non-empty table.
  - Add a Lune spec that monkey-patches `reconcile` to throw and asserts that the session is read-only.

### M7. After a server crash the player is locked out for up to 30 minutes
- **Where:** `src/server/Services/DataService.luau:51` (`STALE_LOCK_SECONDS = 30 * 60`), `:227–233` and `:261–265`, which kick after 6×5 s.
- **Risk:**
  - If a server crashes or is force-closed without `BindToClose` finishing, its lock stays "fresh" for 30 min.
  - Any rejoin in that window is kicked after about 30 s with "still being saved by another server".
  - The lock is refreshed every 120 s (`AUTOSAVE_INTERVAL`), so 30 min is 15 missed autosaves, far more caution than needed.
- **Fix:**
  - Lower `STALE_LOCK_SECONDS` to about 3× the autosave interval (6–8 min). This is safe because a live server re-stamps `lock.at` every 120 s.
  - Better: add a MessagingService "release request" handshake, as ProfileStore does, so the old server saves and releases on request.
  - Show a countdown to the player instead of a blind kick.

### M8. Fixed-size panels overflow on phones because UI scale never goes below 0.7
- **Where:**
  - `src/client/UI/Theme.luau:62–66`: `minScale = 0.7` on touch devices, with a design size of 1100×620.
  - `LobbyUI.luau:221`: the bottom bar is 1000 px wide, and its contents add up to about 978 px.
  - `LobbyUI.luau:274`: the class picker is 960×440.
  - `ResultsUI.luau:35`: the results panel is 560×500.
- **Evidence:**
  - Take a 667×375 phone (iPhone SE) and subtract the topbar and safe insets, leaving about 667×317.
  - The fitted scale would be 0.51, but it is clamped up to 0.7. The root is therefore about 953×453 design px.
  - The lobby bar overflows by about 23 px on each side, so READY! sits partly off-screen. The Results panel is about 47 px taller than the screen, so the "Play Again" button is clipped at the bottom.
  - 360-dp Android phones are worse: the root is about 431 px tall.
- **Risk:** mobile is the majority audience (research/market.md). Clipped primary buttons on the first screen and the end screen hurt first-session retention.
- **Fix:**
  - Let the scale fall to the fitted value (down to about 0.5). Keep touch targets large by raising `Theme.TOUCH` on touch devices, rather than flooring the whole UI scale.
  - Alternatively, add a `UISizeConstraint` with scale-based sizes, or use `AutomaticSize` with a `UIListLayout` on the bottom bar.
  - Give the Results and Shop panels a maximum height tied to the root and put their content in a ScrollingFrame.
  - Test at 640×360 and 667×375 with the Studio device emulator.

---

## Minor

1. **The receipt records the PurchaseId before the grant runs.**
   - Where: `Data/Receipts.luau:144–147`.
   - If a handler throws, `DataService.update` (`DataService.luau:425`) catches it, but the id is already recorded. The next Roblox retry then returns `"duplicate"` → PurchaseGranted, and the player is never granted the item.
   - Fix: run the handler first and record the id after it succeeds. Both still happen in one mutation and one save. Alternatively, work on a deep copy and swap it in.
2. **`PromptProduct("refresh")` spam calls the subscription API repeatedly.**
   - Where: `MonetizationService.luau:488–491` spawns `refreshClub`, which has no cooldown (`:341`).
   - The only throttle is `PROMPT_COOLDOWN` = 1.5 s per player, so each player can trigger `GetUserSubscriptionStatusAsync` plus a profile push every 1.5 s.
   - Fix: give `refreshClub` a 30–60 s cooldown per player.
3. **The client never sends `"refresh"`, and it shows a hard-coded price when the price fetch fails.**
   - Where: `client/UI/ShopUI.luau:270–278` and `ShopUI.open` (`:393`).
   - A grep for `"refresh"` in `src/client` finds nothing, so website pass purchases and new Club subscriptions are only picked up on join or by the 600 s poll.
   - The price label falls back to `item.price` (`fallbackPrice`), which is wrong under regional pricing (research §5 "Pricing").
   - Fix: fire `PromptProduct("refresh")` in `ShopUI.open`. While no runtime price is available, show "Buy" (the Roblox prompt displays the real price).
4. **A Second Wind is granted even when the token charge fails.**
   - Where: `RunDirector.luau:1172–1178`.
   - The world revive happens first. If `profileUpdate` then fails (for example, the profile was released), the revive stays and the only result is `usedToken = true`.
   - Fix: take the token first and refund it if `world:useSecondWind` refuses. This is safe because nothing yields in between.
5. **Rejoining the same server during a slow release can lose the tail of the old session.**
   - Where: `DataService.luau:194–198` (30 s wait) and `:230` (a lock with the same JobId is always taken over).
   - If the old release takes more than 30 s (retries plus budget waits can add up to about 40 s), the new session takes the lock. The old final save, including any leaver payout, then fails with "lock lost".
   - Fix: wait on `releasingUsers` until it clears, up to `SHUTDOWN_TIMEOUT` + retries, or hand the in-memory profile over directly.
6. **A load failure kicks the player.**
   - Where: `DataService.luau:246–251`.
   - During a DataStore outage nobody can play.
   - Fix: consider a read-only guest session ("progress won't save") instead of a kick.
7. **Leaderboard writes skip the budget check, and bot-assisted runs rank alongside human parties.**
   - Where: `LeaderboardService.luau:95–123` and RunDirector `finishRun` (`:1471–1478`).
   - The write path skips `GetRequestBudgetForRequestType`, although the 60 s throttle per player keeps the volume low.
   - Solo-plus-2-bots runs rank on the same `fastestCycle1`/`deepestCycle` boards as 4-human parties. Bots never get entries, so this is a fairness and disclosure issue, not a policy one.
   - Fix: add a "with bots" flag or a separate board.
8. **Lowering a talent's `maxLevel` silently clamps paid levels.**
   - Where: `ProfileSchema.luau:139–143` (`talentMap`).
   - Players lose cheese they already spent.
   - Fix: refund the cost of the clamped levels in a migration.
9. **Lobby spam rebuilds bot models.**
   - `SelectClass` and `SetBotFill` both call `broadcast()` → `refreshBots()` → `BotService.sync` (`BotService.luau:293–327`).
   - When the roster's classes change, `sync` destroys and rebuilds 15-part models with a BillboardGui. Each player can do this up to about 5 times a second.
   - Fix: debounce `refreshBots` to about 0.5 s.
10. **Indirect pay-to-power is not disclosed.**
    - Cheese multipliers bought with Robux (Rush ×2, Feast, Herd Leader) speed up talents that give permanent +HP and +damage (`Config/Talents.luau:39,47`).
    - Second Wind tokens are a paid in-run continue: they are capped and unranked, but they still extend a run that earns cheese.
    - Founders unlocks combat classes early.
    - All of these are common Roblox practice and every item can be earned, but `MONETIZATION.md` claims "never buys in-run power". Reword it to "accelerates progression; never sells in-run upgrades or rerolls".
11. **One boss name is still close to Warner Bros IP.**
    - `"Speedy Gorgonzola"` (`Config/Bosses.luau:193`) is a rename of Speedy Gonzales, a WB *mouse* character, and the fast-mouse theme keeps the link strong.
    - STYLE.md bans WB names. Consider a clearer rename, for example "Gorgonzola Zoom".
12. **There is no onboarding for first-time touch players.**
    - The only hint is the ability key label, which is hidden on touch (`HudUI.luau:331–344`).
    - An idle new player reaches combat in about 30 s (auto-start) + up to 15 s (route vote) + arena build, so roughly 45–50 s. The first thing they see is a route card listing curses and blessings.
    - Fix: on the first-ever run, auto-pick the Low route and skip the vote. Show a 3-step coach mark: "drag left to move", "tap 💥 for ability" and "stand near 💫 to revive".
13. **The leaver payout can wait up to 60 s.**
    - `releaseSession` waits up to 60 s for `s.loading` (`DataService.luau:356`), while `RunDirector` keeps `departed` for 120 s (`:1678–1681`). That is consistent today.
    - Do not shorten the `departed` timeout below the DataService release worst case (60 s load wait + 3 s callbacks + retries).
14. **There is no analytics yet.**
    - When `AnalyticsService` funnels and economy events are added, skip ids ≤ 0 and record bot-filled sessions as a dimension, not as players.

---

## Remote handler audit

| Remote | Handler | Validation | Rate (/s, burst) | Phase / ownership checks | Notes |
|---|---|---|---|---|---|
| SelectClass | LobbyService.luau:656 | string ≤32, `classDef` lookup, unlock check | 3, 4 | rejected for run members | No DataStore write (in-memory only). Bot rebuild cost: Minor 9 |
| SetReady | :687 | boolean | 3, 4 | run members: playAgain only | **M2** countdown reset |
| SetBotFill | :708 | boolean | 2, 3 | none needed | Minor 9 |
| Vote | RunDirector.luau:971 | int 1–16, ≤ voteCount, phase == votePhase | 4, 6 | `cast(player.UserId)`: a player can't vote for others | OK |
| ChooseUpgrade | :1004 | int offerId, int card ≤ #cards | 4, 6 | OFFER_PHASES, offerId must match the offer issued | OK |
| RerollUpgrade | :1032 | int offerId | 2, 3 | offer match; free → token caps (RunTokens) | OK |
| UseAbility | :1072 | finite, clamped ±1e5 | 10, 10 | Waves/Boss only; World checks standing and cooldown | Dash clamps distance and arena (Weapons.luau:469–483). OK |
| UseSecondWind | :1128 | no args | 2, 2 | Waves/Boss, own player, downed and not dead, RunTokens probe | Minor 4 |
| BuyShopItem | ShopService.luau:333 | string ≤ MAX_ITEM_ID_LEN, `Shop.parse` | 4, 6 | profile loaded and writable | No immediate save (autosave), which is consistent |
| Equip | :362 | enum slot + optional string | 4, 6 | ownership in `Shop.equip` | B1 (no visual effect) |
| ClaimDaily | :399 | no args | 1, 2 | server-day claim check | Saves once per successful claim. OK |
| PromptProduct | MonetizationService.luau:628 | string ≤32, key whitelist | 1, 3 + 1.5 s cooldown | real players only, already-owned check | Minor 2, M4 |

No `RemoteFunction`s, no `InvokeClient`, no trust in `TeleportData` or in client-set attributes. Guard kicks a player after 60 malformed calls in 60 s. Client values never reach damage, currency or offer contents. **The one client-trusted value is the character position (M1).**

---

## Compliance checklist

| # | Rule | Result | Evidence |
|---|---|---|---|
| P1 | No paid random items | **Pass** | Every item has `random = false` (`Config/Monetization.luau`), and every grant is a fixed handler (`Receipts.luau:50–91`). Club monthly picks are a deterministic rotation (`:177–204`). |
| P1b | PolicyService gate available | **Pass** | `paidRandomItemsRestricted` defaults to restricted on error (`MonetizationService.luau:388–406`). |
| P2 | Robux never near Double or Nothing or the gamba | **Pass** (see M3) | `cheeseMult` is applied only in `finishRun` and `payLeaver` after the bank resolves (`RunDirector.luau:1467`, `:1795`). No prompts exist in VoteUI, ResultsUI or the downed HUD. Token revives are blocked on Double-or-Nothing stages. The gamba boss has no wager. |
| P3 | Age / audience | **n/a (owner task)** | ID verification, 2FA and the all-ages fee are Creator Dashboard steps. |
| P4 | Maturity Minimal/Mild | **Pass (content)** | Cartoon combat; mice burst into crumbs; no gore, romance or real-world gambling UI. Fill in the questionnaire as "Mild: cartoon violence". |
| P5 | Parental spend controls, no re-prompting | **Pass** | `purchased == false` is handled silently (`:593`). There is a prompt cooldown, and prompts happen only on button presses. |
| P6 | No dark patterns (timers, scarcity, death-screen prompts) | **Pass** | No countdown offers. Founders has no timer UI. The downed panel has no buy button (`HudUI.luau:360–420`). Results has only "Play Again". |
| P7 | Refunds and receipt retries | **Partial** | Retries are handled correctly. Pass refunds and chargebacks are never revoked (M5). |
| P8 | Rewarded ads: 13+ only, free path | **Pass (disabled)** | `ADS_ENABLED = false`. AdService availability gates the button, the reward goes through ProcessReceipt, there is a 3/day cap, and the same reward types come from the streak and the first-run bonus. |
| R1 | One ProcessReceipt in one script | **Pass** | `MonetizationService.luau:589` only. |
| R2 | Player not in server → NotProcessedYet | **Pass** | `:267–270` |
| R3 | Waits for the session-locked profile; NotProcessedYet if not loaded or read-only | **Pass** | `:276–279` (20 s wait) |
| R4 | PurchaseId recorded in the same save as the grant | **Pass** (Minor 1) | `Receipts.apply` → `DataService.save`. History holds the last 200 ids. |
| R5 | PurchaseGranted only after a confirmed save; failure → NotProcessedYet | **Pass** | `:297–299`. If the server dies before the save, the purchase is not recorded and Roblox retries it on rejoin. If it dies after the save but before the ack, the retry is a duplicate and is acked without a second grant. |
| R6 | Serialised per player | **Pass** | `receiptBusy` (`:310–328`) |
| R7 | No client-side grants | **Pass** | The client only fires `PromptProduct(key)`. The server grants only in ProcessReceipt, pass ownership and the subscription check. |
| R8 | No auto-prompts on death or loss | **Pass** | `prompt()` is called only from the remote. |
| R9 | Pass caching and re-check on shop open | **Partial** | Ownership is cached on join and after `PromptGamePassPurchaseFinished`, with a 10 s re-check. The client never sends "refresh" (Minor 3). The purchase-finished signal is trusted (M5). |
| R10 | Prices read at runtime | **Partial** | `GetProductInfoAsync` is used in `ShopUI.luau:252`, but it falls back to `fallbackPrice` (Minor 3). |
| R11 | Subscription handling | **Pass (verify API)** | `GetUserSubscriptionStatusAsync` is pcall-guarded, polled every 600 s and re-checked on `UserSubscriptionStatusChanged`. The monthly grant is idempotent per month key. The API name and shape are marked *(verify)*. |
| R12 | Products deliver what they advertise | **Fail** | B1 (cosmetics, nametag and chat tag are not rendered); M4 (boosts bought at their cap). |
| D1 | Session lock with UpdateAsync, safe in a two-server race | **Pass** | Atomic UpdateAsync. A fresh lock held by another JobId cancels the load (`DataService.luau:227–233`). The save checks the lock token (`:298–301`). |
| D2 | Stale-lock takeover | **Partial** | It works, but the 30 min threshold is too long (M7). |
| D3 | Retries, backoff and budget | **Pass** | `withRetries` makes 5 tries with exponential backoff, after `waitForBudget(UpdateAsync)` (`:115–154`). |
| D4 | BindToClose within 30 s | **Pass** | Parallel releases with a 25 s cap (`:647–661`). |
| D5 | Autosave | **Pass** | Every 120 s, spread over about 10 s (`:626–645`). |
| D6 | Migration never drops data | **Fail** | M6 (error path); Minor 8 (talent clamp). Fields not in the whitelist are dropped by design; future-version profiles are opened read-only. |
| D7 | Currency overflow and negatives | **Pass** | `clampCurrency` limits values to 0..1e9 and floors them. `reconcile` clamps every number and rejects NaN/inf. |
| D8 | Leaderboard write frequency | **Pass** | At most one per player per 60 s, only when the value improved, and from ranked stats only. |
| D9 | Leaver reward (beforeRelease) | **Pass** | `payLeaver` (`RunDirector.luau:1757`) applies the wipe rule once (`pr.awarded`) and runs before the final save. It also covers shutdown. |
| BOT1 | Bots labelled everywhere | **Pass** | The name has a 🤖 suffix (`BotRoster.luau:199`) and the BillboardGui shows "🤖 BOT" (`BotService.luau:239`). The lobby list shows "🤖 Bot ·" (`LobbyUI.luau:187`), the party HUD the same (`HudUI.luau:142–143`), and the toasts use the tagged name. |
| BOT2 | Bots never counted as real players in analytics or leaderboards | **Pass** | `LeaderboardService.submit` requires a Player with UserId > 0 (`:128`). There is no analytics yet (Minor 14). Bot-assisted runs still rank (Minor 7). |
| BOT3 | Bots never earn rewards | **Pass** | `isHuman` gates `awardRun`, `cheeseMult` and profile updates (`RunDirector.luau:262–330`). DataService and MonetizationService both return early for non-Players and ids ≤ 0. |
| BOT4 | Bots never act for a human on a stake | **Fail** | M3 |
| T1 | User text and chat filtering | **n/a / Pass** | There is no TextBox and no user-entered text. Displayed names are Roblox DisplayNames (already filtered) or fixed bot names. Revisit if pet names, party names or sprays are added. |
| T2 | IP-safe names | **Partial** | Minor 11 |
| S1 | Server authority over movement | **Fail** | M1 |
| S2 | Remote validation and rate limits | **Pass** | See the remote handler audit table above. |
| S3 | Spam doesn't cause expensive work | **Partial** | M2 and Minor 9 (lobby rebuilds), Minor 2 (subscription API). DataStore writes are not reachable through spam: purchases go through the prompt and the shop relies on autosave. |
| U1 | Touch targets ≥ 48 px | **Pass** | `Theme.TOUCH = 70` design px is ≥ 49 px at the 0.7 scale. The ability button is 150 design px (≈105 px). |
| U2 | Safe insets | **Pass** | `ScreenInsets = CoreUISafeInsets` on every screen (`Theme.luau:493`). |
| U3 | No overflow on small screens | **Fail** | M8 |
| U4 | Reach combat within 30–60 s | **Pass (borderline)** | Auto-start 30 s + route vote ≤ 15 s; pressing READY brings it to 5 s + vote. Minor 12. |
| U5 | Onboarding hints | **Fail (minor)** | Minor 12 |
| U6 | Low-end performance budgets | **Pass (verify on device)** | Fx is pooled and capped harder on mobile (`FxController.luau:19–25`: 18 damage numbers, 60 effects). There is one `BulkMoveTo` per frame and BillboardGuis only on bosses (`HordeRenderer.luau:292`). The snapshot is under 850 B per chunk. Profile it on a low-end Android phone. |

---

## Suggested fix order

1. **B1:** before entering any `assetId`, render the cosmetics or remove the perk claims.
2. **M6 and M5:** both cause durable data damage.
3. **M1:** movement validation. Make suspect runs unranked until it lands.
4. **M2 and M3:** griefing and the consent problem in Double or Nothing.
5. **M4:** add a headroom check to `prompt()`.
6. **M8:** verify on a phone emulator.
7. **M7:** lower the stale-lock time.
8. The Minor items.
