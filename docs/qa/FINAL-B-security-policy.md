# FINAL QC B: security, monetization policy, data safety and UX regression

- **Commit reviewed:** `df3eccc` on branch `claude/focused-gates-jihpzi` ("POIs & portals (G2)").
- **Scope:**
  - Every QC2 finding (`docs/qa/QC2-security-policy.md`).
  - The new remotes `SetPressure`, `SetSetting` and `InteractPoi`.
  - The new features: Pressure, POIs, discoveries, portals and Epic drops.
  - Profile v4.
  - The new client UI.
- **Docs checked against:** AGENTS.md, HANDOFF.md, MONETIZATION.md, research/monetization.md (§2 rules 1–8 and the §5 dev checklist), GDD §3.4 and §3.6–3.9, and STYLE.md.
- **Method:** a read-only review. Every finding was confirmed by reading the cited lines.
- **Quality gate:** `scripts/check.sh` printed **CHECK PASSED** (34 spec files, Rojo build OK) and left the tree clean.
- **Not covered by the gate:** nothing has run in Studio. Behaviour marked *(verify)* needs a live or emulator test.

Severity scale (same as QC2):

- **Blocker:** must be fixed before anything is sold or published.
- **Major:** fix before a public launch.
- **Minor:** fix when convenient, or accept the risk knowingly.
- **Nit:** cosmetic or wording.

---

## Summary

| Severity | Count | Headline |
|---|---|---|
| Blocker | **0** | QC2 B1 is fixed: cosmetics, nametags, titles and chat tags are drawn |
| Major | **1** | Phone text renders at about 7–11 pt now that the UI scale can fall to about 0.51 (the side effect of the M8 fix). The new Pressure board is the worst case *(verify on device)* |
| Minor | 5 | Pressure can be changed in the last instant of the countdown; `InteractPoi` has no handler; the docs disagree on the Pressure migration; POIs have no labels or onboarding; the portal fade hides queued upgrade picks |
| Nit | 3 | Kick wording after a crash; the Epic reroll fallback ignores the holding cap; "Bloodthirst" wording |

**QC2 re-verification.** B1 and M1–M8 are all fixed. M5 and M7 carry small residual notes. Of the 14 QC2 Minors, 10 are fixed, 1 is accepted by a lead decision, and 3 are still open (guest mode, the talent-clamp refund, analytics).

**What is solid in the new code:**

- Pressure is server-only. The board comes from `LobbyService.effectiveBoard`, which applies it only when the leader's own profile has Pressure unlocked. It is sanitized again in `RunState.new` and fixed for the whole run.
- POI rewards are one-shot, computed by the server, and driven by positions that MoveGuard has checked.
- Epic cosmetics are free only and cannot be bought with either currency.
- No Robux path touches Pressure, POIs, votes or Double or Nothing.

---

## Major

### FB-M1. Body text is about 7–11 pt on phones; the new Pressure board is the worst case *(verify on device)*

- **Where:**
  - `src/client/Util/Layout.luau:28-34`: `fitScale` has no 0.7 floor any more. This was the QC2 M8 fix.
  - `src/client/Util/Layout.luau:43-47`: touch targets are compensated with `touchSize`. Text has no equivalent.
  - New UI:
    - `src/client/UI/LobbyUI.luau` Pressure board. Row description `TextSize = 14` (around line 827), `bNote` 16 (:752), `pInfo` 15 (:697).
    - POI ring name, `TextSize = 16` (`src/client/UI/HudUI.luau:532-539`).
    - Buff timers, 18 (`HudUI.luau:639`).
  - `Theme.label` defaults to 22 (`Theme.luau:178`).
  - Only the tooltip compensates for scale (`Theme.luau:452`).
- **Evidence:**
  - On a 667×375 phone the safe viewport is about 667×317, which gives `fitScale` = min(667/1100, 317/620) ≈ **0.51**. Common 390-pt-tall iPhones and 360-dp-tall Androids also land at about 0.52–0.55.
  - Every `TextSize` is multiplied by the root `UIScale`:

    | Design px | Rendered |
    |---|---|
    | 14 | ≈ 7.2 pt |
    | 16 | ≈ 8.2 pt |
    | 22 | ≈ 11 pt |

  - Layout itself is fine at 667×375 (see the UX table below). Nothing overflows.
- **Risk:**
  - Mobile is the majority audience, and the players are young.
  - The Pressure modifier descriptions, the onboarding cards, the POI names and the party HUD are below comfortable reading size on the first screens a new player sees.
  - This is the trade-off M8 made: touch targets were protected and text was not.
- **Fix:**
  - Add `Layout.textSize(design, scale, minPx)` next to `touchSize`, with a minimum of about 12 screen px on touch devices.
  - Apply it in `Theme.label` / `Theme.button` and in the explicit small sizes. This mainly matters for the Pressure rows (14 → about 24 design px at 0.51). Rows are already `touch + 12` tall, so the text fits.
  - Alternatively, use a smaller design canvas on touch devices (for example 900×500).
  - Check with the Studio device emulator at 667×375 and 640×360. If those tests show the text is readable, downgrade this to Minor.

---

## Minor

### FB-m1. The leader can change Pressure up to the instant the run starts
- **Where:**
  - `src/server/Services/LobbyService.luau:889-922` (`onSetPressure`) has no countdown check.
  - `:691-695`: `fireStart` reads the board at the moment of the start.
- **Evidence:**
  - A leader can press + eight times in the last 0.25 s. The rate limit is 6/s with a burst of 10, and broadcasts are debounced at 0.25 s.
  - Ready teammates and auto-pulled idle players are then committed to a run of up to 21 points before their UI has updated.
  - HANDOFF records this as known: "The board isn't locked during the final countdown seconds."
- **Risk:**
  - Co-op griefing. A run is made much harder without consent.
  - It is not a policy issue: Pressure is free, and the wipe rule still pays 50% of pending cheese.
- **Fix:** lock edits when fewer than 5 s remain (`countdownEndsAt - now < 5`). Alternatively, when the board changes, re-arm a countdown of at least 5 s and toast "👑 changed Pressure to N".

### FB-m2. `InteractPoi` remote exists but nothing handles it
- **Where:** `src/shared/Net.luau:24` creates the RemoteEvent (`Net.setupServer`). `grep -rn InteractPoi src` finds no `Guard.connect` and no `OnServerEvent`.
- **Risk:**
  - Roblox queues events for a RemoteEvent with no listener and logs "invocation queue exhausted" warnings.
  - Spam on this remote bypasses Guard's malformed-call kick counter and floods the server log.
  - If a handler is added later, it will receive the queued backlog first.
- **Fix:** remove it from `Net.C2S` until it is needed, or add a Guard no-op: `Guard.connect(Net.C2S.InteractPoi, {rate = 2, burst = 3, args = {Guard.T.int(1, 1e6)}}, function() end)`.

### FB-m3. The docs disagree about the Pressure migration and the schema version
- **Where:**
  - `src/shared/Data/ProfileSchema.luau:10-11` says "Saves from before v4 start locked". The code at `:360-375` unlocks Pressure for any save with `stats.wins > 0`.
  - `docs/GDD.md:133-137` says both things in consecutive sentences.
  - `docs/MONETIZATION.md:298` still says "Profile schema v3".
  - `docs/HANDOFF.md:85` still lists §3.7–3.9 as "specified, not built".
- **Risk:** the next agent may "fix" the code to match the stale comment and lock out veterans.
- **Fix:** make all four places say "veterans with ≥1 win are unlocked in the v3→v4 migration; everyone else unlocks on their first Go Home win", and change the schema reference to v4.

### FB-m4. POIs have no world label and no first-time hint
- **Where:**
  - `src/server/Services/ArenaBuilder.luau:549+` (`buildPoi`) builds parts with a `PoiId` attribute but no name label.
  - The Onboarding hint set covers move, attack, crumbs, ability, revive and route (`src/client/UI/Onboarding.luau:7-12`), with no POI hint.
  - The HUD ring and name appear only once a hero is standing in range (`HudUI.luau:510-540`).
- **Risk:**
  - New players won't learn that caches and shrines have to be stood on. Cache cheese is lost if it isn't channelled.
  - Players walk into Mousetrap Fields (14 × enemy-damage traps) without warning.
  - This is a retention issue, not a security one.
- **Fix:**
  - Add a client-side BillboardGui with the POI name, read from the `PoiId` attribute and `Config/Pois`, at a short `MaxDistance`.
  - Add a one-time "Stand on glowing spots for rewards ✨ · avoid the mousetraps!" coach mark the first time a POI is in view.

### FB-m5. The portal fade covers queued upgrade picks and can cover toasts
- **Where:**
  - `src/client/Controllers/FxController.luau:1684-1745`: the fade ScreenGui uses `DisplayOrder = 40`, holds for up to `FADE_HOLD_MAX = 6` s, and lifts on Waves.
  - `UpgradeUI` is `Theme.screen(..., 25)` and `Toasts` is also 40.
- **Risk:**
  - An Elite Camp chest or Grandma's Pantry pick that is still queued during the bank/route votes sits under a black screen for up to about 7 s.
  - Where two ScreenGuis share a DisplayOrder, the drawing order is not defined, so the "Stage N-M" toast may be hidden.
  - Nothing is lost. This is UX only.
- **Fix:** set the fade's DisplayOrder to 24 (below Upgrades and Toasts, above HUD and Lobby), or keep 40 and raise Toasts to 45.

---

## Nits

1. **Crash-lockout wording.** After a server crash with no handshake reply, a rejoin can still be refused for up to 7 min. The kick text says "rejoin in a minute" (`DataService.luau:320`). Say "in a few minutes", or show the time left from `lock.at`. (Residual of M7.)
2. **Epic reroll fallback.** When the player owns the whole Epic pool, the fallback grants `+1` reroll token with no holding-cap check (`RunDirector.luau:1716-1720`). The shop's holding cap is 30. This is a free item, so it is harmless; clamp it for consistency.
3. **Maturity wording.** The upgrade name "Bloodthirst" (`Config/Upgrades.luau:340`) is the only blood reference in the game. It predates QC2. Consider "Hungry Herd" to keep the Mild questionnaire clean. The "Knife Block" cleavers (Filet class) are cartoon kitchen tools; declare them under "Mild: cartoon violence".

---

## QC2 re-verification

| QC2 | Status | Evidence |
|---|---|---|
| **B1** Sold cosmetics, VIP nametag and Club tag not rendered | **Fixed** | **Server:** `Services/CosmeticsService.luau` builds the trail (:136-159), hat (:161-209), tint Highlight (:211-223) and BillboardGui nametag with titles (:240-263), and sets the ChatTag attributes (:265-274). It redraws on CharacterAdded, AppearanceLoaded, profile load and entitlement changes (:378-418). It is initialised by `Main.server.luau:57`, and Equip calls `refresh` (`ShopService.luau:145`).<br>**Look and client:** `Data/Looks.luau` uses only owned cosmetics (:64-73) and sets the VIP gold name and the VIP / Founder / Club / Herd Keeper titles (:122-147). The client chat hook (`Controllers/ChatTags.luau:60-98`) escapes rich text and is loaded by `Main.client.luau:41`.<br>**Catalog:** every `assetId` is still 0, so nothing is for sale yet. |
| **M1** No movement anti-cheat | **Fixed** | **Guard:** `Combat/MoveGuard.luau:131-191` gives a budget of speed × state × elapsed × 1.3, with up to 0.6 s of carry, a 1.5-stud slack paid back as debt, a downed factor of 0.3, a dead factor of 0, and LAG_GRACE.<br>**Sync:** `CombatService.luau:207-243` snaps violations with `PivotTo`.<br>**Obstacles:** `World.setPlayerPosition` pushes players out of obstacles (`World.luau:388-403`).<br>**Server moves:** dashes, respawns and stage start use grace windows (`CombatService.luau:283-290, 391-400, 429-432`), and stale samples are ignored rather than accepted.<br>**Ranking:** 10 violations make the run unranked (`RunDirector.luau:392-394, 1107-1120`). |
| **M2** One player can stall the lobby | **Fixed** | `Run/LobbyRules.luau:77-103`: an armed countdown can only get shorter, and it is cancelled only when nobody willing is left. Un-ready means sitting out (:107-115). `LobbyService.onSetReady` (:866-887) never cancels. Spam is coalesced by `UPDATE_DEBOUNCE` 0.25 s (:736-745). |
| **M3** Bots can stake Double or Nothing for an idle human | **Fixed** | `Run/Vote.luau:92-131`: DoubleOrNothing and NextCycle count only with ≥1 human vote. RunDirector passes `Vote.riskyIndices` (:1363-1364). `BotBrain.chooseVote` (:635-669) applies `VOTE_SURPRISE` to route votes only, and on staking votes picks the safe option in a tie. |
| **M4** Boosts can be bought at their cap | **Fixed** | `MonetizationService.boostHeadroom` (:679-717) refuses Rush or Feast when the full unit won't fit (`Boosts.fits`, `Boosts.luau:68-81`), with a toast. Overflow from purchases in flight is refunded as Golden Cheese (`Receipts.luau:66-80`, `startPendingFeasts` :364+). The refund is disclosed in `benefit` (`Config/Monetization.luau:221, 231`). |
| **M5** Pass perks saved without verification, never revoked | **Fixed** (residual) | `PromptGamePassPurchaseFinished` grants nothing; it starts `verifyPurchase`, which polls `UserOwnsGamePassAsync` at 0/2/4/10/30 s (:226-267, :871-888). `setOwned` is called only after ownership is confirmed (:189-210). Perks are recorded in `passGrants`, and a definite "not_owned" on join revokes them (`Passes.revoke` :108-143, `onJoin` :826-838). An API error never revokes. *Residual:* a refund during a session is only caught on the next join (documented in HANDOFF). |
| **M6** Migration or reconcile error wipes the profile | **Fixed** | `ProfileSchema.migrate` returns `failed = true` for a non-empty save whose migration step or reconcile throws (:413-447). `sessionMode` returns "corrupt" (:460-468). `DataService.finishLoad` exposes no profile and makes the session read-only (:199-216). The player is kicked with a "progress is safe" message and the lock is released without writing data (:686-692). |
| **M7** 30-min lockout after a crash | **Fixed** (residual) | `STALE_LOCK_SECONDS = 7*60` (`DataService.luau:61`). A MessagingService release handshake (`requestRelease` :424-439, `onReleaseRequest` :715-735) checks the JobId before clearing an orphaned lock (:407-421). *Residual:* see Nit 1 on the kick wording. |
| **M8** Mobile overflow | **Fixed** (layout) | `Layout.fitScale` has no 0.7 floor, and `touchSize` keeps targets ≥48 px (`Layout.luau:28-47`). The bottom bar has a UIScale guard (`LobbyUI.luau:350-366`). The picker, Pressure board, Results, Shop and Vote panels use `Theme.fitFrame`. *New side effect:* **FB-M1** (text size). |
| m1 Receipt id recorded before the grant | Fixed | `Receipts.apply` grants against a deep-copy backup and records the id only after a non-empty grant (:194-207). |
| m2 "refresh" spams the subscription API | Fixed | `REFRESH_COOLDOWN` 30 s and `CLUB_REFRESH_COOLDOWN` 45 s (`MonetizationService.luau:68-71, 535-541`). |
| m3 Client never refreshes; hard-coded price | Fixed | `ShopUI.luau:81-90` fires "refresh" on open. Only the live `PriceInRobux` is shown (:315-340). |
| m4 Second Wind granted when the charge fails | Fixed | The token is charged before the revive and refunded if the world refuses (`RunDirector.luau:1577-1608`). |
| m5 Same-server rejoin loses the tail of the session | Fixed | The load waits up to `SAME_SERVER_RELEASE_WAIT` (90 s) for an old release (`DataService.luau:233-243`). |
| m6 Load failure kicks the player | **Open** (accepted in HANDOFF) | `DataService.luau:296-301` still kicks; there is no guest mode. |
| m7 Leaderboard budget; bot-assisted runs ranked | Fixed / accepted | `waitForBudget` before writes (`LeaderboardService.luau:98-125`). Bot-assisted runs stay ranked by a lead decision (MONETIZATION.md "Ranking policy"). |
| m8 Talent `maxLevel` clamp loses paid levels | **Open** | `ProfileSchema.talentMap` still clamps with no refund (:151-169). No `maxLevel` has been lowered yet. |
| m9 Lobby spam rebuilds bot models | Fixed | Debounce, and the roster signature skips identical rosters (`LobbyService.luau:563-580`). |
| m10 Indirect pay-to-power not disclosed | Fixed | MONETIZATION.md "Principles" and the `Config/Monetization.luau:10-13` header now say "accelerates progression". |
| m11 "Speedy Gorgonzola" | Fixed | Renamed "Zoomzola the Swift Cheese" (`Config/Bosses.luau:194-196`). This is a cheese pun with no WB name; acceptable. |
| m12 No onboarding | Fixed (partial) | `UI/Onboarding.luau` has coach marks for move, attack, crumbs, ability, revive and route, device-specific, controlled by `settings.hints`. The first run still has a route vote (it defaults to Low), and there is no POI hint (FB-m4). |
| m13 Leaver payout timing | OK (unchanged) | `departed` is kept 120 s (`RunDirector.luau:2263-2266`) and `releaseSession` waits up to 60 s for the load (`DataService.luau:471`). |
| m14 No analytics | Open (n/a) | There is no AnalyticsService yet. |

---

## New attack surface

### Remote handler audit (new and changed)

| Remote | Handler | Validation | Rate (/s, burst) | Phase / ownership checks | Notes |
|---|---|---|---|---|---|
| SetPressure | `LobbyService.luau:889` | `T.string(32)` and `T.number(-100,100)`. An unknown modifier is rejected (`clampRank(mod,1)==0`). Rank is floored and clamped to `maxRank` (`Run/Pressure.luau:54-89`) | 6, 10 | Run members are refused. **Leader computed by the server** (`currentLeader` :481). Leader must have Pressure unlocked in their profile (:437-443). Board sanitized (≤64 raw keys) | FB-m1 (no countdown lock). The profile write is in-memory; autosave persists it |
| SetSetting | `ShopService.luau:191` | `T.enum({"hints"})` and `T.boolean()` | 2, 4 | Profile loaded and writable; push only on a change | OK. `settingsMap` caps 32 keys (`ProfileSchema.luau:171-190`) |
| InteractPoi | **none** | none | none | none | FB-m2 |

All other remotes keep their QC2 specs (`RunDirector.luau:2419-2435`, `ShopService.luau:214-239`, `MonetizationService.luau:906-912`, `LobbyService.luau:1037-1040`).

### Can the Pressure reward multiplier be applied by a non-leader, or while locked? No

- **Only one entry point.** `startRun` is reached only through `LobbyService.onStart` (`RunDirector.luau:2445`). The board passed in is `effectiveBoard(leaderAmong(party))`, which returns `{}` unless the leader's own profile has `pressure.unlocked == true` (`LobbyService.luau:494-500, 691-695`).
- **Corrupt profiles count as locked.** A corrupt session exposes no profile, so it reads as locked.
- **Fixed per run.** `RunState.new` sanitizes the board once and stores `pressurePts` (`RunState.luau:173, 200-201`). Nothing changes it mid-run.
- **Server-side only.** The cheese bonus (`applyPressureCheese` :220-223), the luck and the Epic bonus (:310-311) are all computed from that stored value.
- **POI cheese.** Cache cheese gets the same server-side Pressure multiplier (`RunDirector.luau:1021-1037`).

### POI rewards: can a client farm caches or shrines, or trigger discoveries or Epic cosmetics? No

- **One-shot.** Every channel or camp POI ends in `state = "done"` and returns early after that (`Combat/Pois.luau:269-272, 364-366`). Caches, shrines, fountains and chests each pay **once per spawned POI**. POIs are rolled from the stage seed on the server (`Pois.layout`, `RunDirector.luau:1764-1775`).
- **Only during Waves.** POIs run only while the waves are active (`Pois.update` :545-575). The client has no input except position.
- **No useful teleports.**
  - Range checks use `w.standing` positions, which MoveGuard has already checked.
  - Downed and dead heroes never count (`inRangeOf` :349-362).
  - A hero hurt in the last 0.6 s does not channel.
  - The grace windows *ignore* out-of-reach samples rather than accept them (`MoveGuard.luau:175-179`).
  - An exploiter is therefore held to about 1.3× legal speed, which is not worth exploiting for a 1–3 s channel.
- **Discoveries.**
  - Recorded only from `poiActivated` events of `rare` POIs (`RunDirector.luau:936-951`), once per profile (`discoveries[kind]` guard, :895-898).
  - Rares are rolled by the server: 3% / 2% per stage, mutually exclusive (`Combat/Pois.luau:68-80`).
  - The one Epic cosmetic per first Pantry discovery is free, picked from the unowned pool with the run's `discoverRng`.
- **Lost Herd Statue.** It resets the per-stage self-revive cap (`RunDirector.luau:1006-1013`). The free revive is always used first (`Data/RunTokens.luau:53-58`), so a **paid** token still can't be used more than once per stage. The policy holds.

### Portal pull teleports: no new surface

- The pull is a client swirl and fade only: `World.setPortal` only emits Fx (`World.luau:1957-1973`).
- Characters are moved only by `teleportToArena`, which calls `CombatService.placePlayer` with RESPAWN_GRACE (`RunDirector.luau:1652-1659`).

### Epic drops: free only, server-rolled, not sold

- **Server-rolled.** The chance is only the route tier base (High 0.1) plus Pressure at +0.02 per point (`RunState.luau:95, 310-311`), rolled with the server `lootRng`.
- **Bots get nothing.** Only human members get a drop (`RunDirector.luau:1691-1733`).
- **Not sold.** `source = "epic"` cosmetics have no price fields, and `Shop.buy` refuses any source other than shop (`Data/Shop.luau:75`). `Shop.list` lists only shop cosmetics (`Config/Shop.luau:136-158`).
- **No paid odds.** Nothing Robux-bought or Golden-Cheese-bought changes the Epic chance or the rare-POI chance.

---

## Data safety: profile v4

| Check | Result | Evidence |
|---|---|---|
| Migration chain v1→v4 | **Pass** | `MIGRATIONS[1..3]` (`ProfileSchema.luau:336-376`) runs on a shallow copy. A step error makes the session corrupt and read-only (:413-435). v3→v4 adds `pressure` (unlocked when `stats.wins > 0`) and `discoveries`. Future versions are opened read-only (:402-412). |
| Reconcile of the new fields | **Pass** | `Pressure.sanitizeProfile` (`Run/Pressure.luau:221-228`) clamps points 0..21 and the board to known modifiers and ranks. `discoverySet` caps 500 keys of ≤64 chars and accepts `true` or a positive number (:194-208). |
| `view()` exposure | **Pass** | Adds `pressure` and `discoveries` only (:509-510). `passGrants`, purchase history, ad counters and club internals stay server-side. |
| Size growth | **Pass** | Board ≤ 8 entries. Discoveries ≤ 2 rares + 9 landmarks. Settings ≤ 32. All three are capped by reconcile. |
| `awardRun` can't double-count Pressure | **Pass** | `pr.awarded` is set before `awardRun` in `payMember` and `payLeaver` (`RunDirector.luau:1997, 2371`). `Pressure.recordRun` is max-based (`highestCleared = max`) and unlocks only on `won == true` (`Run/Pressure.luau:237-249`). A leaver is always paid as `won = false` (:2397-2406). Points are clamped by `Award` and `DataService.awardRun` (:632). |
| Discovery writes | **Pass** | `profileUpdate` respects read-only sessions. The write is idempotent per kind. |

---

## Monetization: MONETIZATION.md vs `Config/Monetization.luau`

Every catalog row matches its config `benefit`, and each benefit is delivered:

| Item | What is delivered |
|---|---|
| VIP | Gold name and VIP title (`Looks.luau:124-128`), VIP chat tag, Golden Tusk trail and VIP Crown (pass cosmetics via `Passes.apply`), and the daily +150 cheese and +5 GC (`Data/Daily.luau:117-120`, called with `vip` from `ShopService.luau:175-177`) |
| Fast Learner | Account XP only (`payMember` xp × `xpMult`) |
| Herd Leader | +15% for the whole server, does not stack |
| Founders | Classes plus the plume, tint and title |
| Wardrobe | 6 cosmetics |
| Products | Fixed amounts |
| Rush / Feast | Caps and refunds as described under M4 |
| Club | Daily GC + Second Wind, monthly rotation, a 10% discount on cosmetics only (`Data/Shop.luau:90-92`), title and chat tag |

Stale lines in MONETIZATION.md:

- The "Save-data safety" section says schema v3 (FB-m3).
- There is an orphaned "Free sources:" bullet after the chat-hook code block (Nit).

---

## UX and policy

| Area | Result | Evidence |
|---|---|---|
| Bots labelled | **Pass** | The party HUD shows "🤖 Bot ·" (`HudUI.luau:168-170`). The lobby list, header and button carry 🤖 tags (`LobbyUI.luau:305, 332, 339, 383`). The bot BillboardGui reads "🤖 BOT" (`BotService.luau:240`). The Pressure note says "🤖 bots accept it" (:928). Bots never get nameplates or titles (they are not Players). |
| Pressure board at 667×375 | **Layout pass / text FB-M1** | The root is about 1305×620 design px. The summary card (300 wide, top-left), countdown (≤620, centre) and party panel (300, top-right) don't overlap. The board uses `fitFrame` plus a scroller, and its −/+ buttons are `touch` (≈48 px). |
| POI HUD at 667×375 | **Layout pass / text FB-M1** | The ring sits at bottom −140, above the ability widget (which is hidden on touch). Buff timers sit top-right at y 70, and the discovery banner below the 200-px header. |
| Portal fade | **Pass** (FB-m5) | A 1.2 s fade to black, no flashing, lifted on Waves, Results or Lobby, with a 6 s fail-safe (`FxController.luau:1715-1745, 2297-2303`). |
| Onboarding | **Pass** (FB-m4) | Coach marks controlled by `settings.hints`, which the allowlisted `SetSetting` can change. |
| Text input | **Pass** | There is no `TextBox` anywhere in `src`. Nametags use Roblox-filtered DisplayNames. Titles, tags and toasts are fixed strings. |
| Maturity | **Pass (Mild)** | Mousetrap Fields "snap" cartoon traps; the Lost Herd Statue, shrines and portal fade are non-violent. See Nit 3 for wording. |
| IP-safe names | **Pass** | All ~260 `name =` strings in `src/shared/Config` and the 20 bot names were checked: no Disney, WB, Riot or Coca-Cola names. "Zoomzola the Swift Cheese" is a pun on gorgonzola cheese with no link to "Speedy Gonzales". "Jumbo" and "Pop Goes the Mouse" are generic or public domain. |

---

## Policy compliance checklist

| # | Rule | Result | Evidence |
|---|---|---|---|
| P1 | No paid random items | **Pass** | Every Robux item has `random = false` and a fixed handler (`Config/Monetization.luau`, `Receipts.luau:58-104`). The Club monthly item is a fixed rotation. Golden Cheese buys only fixed-price cosmetics. Reroll tokens and talents (including Lucky Tusk luck) cost cheese only (`Config/Shop.luau:118-131, 161-167`). |
| P1b | No odds sold (Epic / rare POI) | **Pass** | The Epic chance comes from route tier + Pressure only (`RunState.luau:310-311`). The rare-POI chance is fixed config (`Config/Pois.luau:85-88`). Epic cosmetics can't be bought (`Data/Shop.luau:75`). |
| P1c | PolicyService gate available | **Pass** | `paidRandomItemsRestricted` (`MonetizationService.luau:592-620`). |
| P2 | Robux never touch Double or Nothing | **Pass** | `cheeseMult` is applied only in `payMember` and `payLeaver` after the bank resolves (`RunDirector.luau:1994-1995, 2394`). No prompts from VoteUI or ResultsUI (grep shows none). Token revives are blocked on Double-or-Nothing stages. Bots can't stake (M3). |
| P2b | Robux never touch Pressure | **Pass** | No reference to Pressure in Monetization, Receipts, Shop config or data, or ShopUI. Pressure is free and gated by unlock and leadership. |
| P3 | Age / audience publishing | n/a (owner) | Creator Dashboard step. |
| P4 | Maturity Minimal / Mild | **Pass** | See the UX table and Nit 3. |
| P5 | Parental spend limits, no re-prompting | **Pass** | `purchased == false` is handled silently (:873-875). Prompt cooldowns. |
| P6 | No dark patterns | **Pass** | No timers or scarcity messages. Cap refusals are informational toasts. The pass "Activating…" toast appears only after the purchase. |
| P7 | Refunds and chargebacks | **Pass** (M5 residual) | Revocation on join from a definite "not_owned". |
| P8 | Rewarded ads 13+ with a free path | **Pass (disabled)** | `ADS_ENABLED = false`. Unchanged. |
| R1–R7 | ProcessReceipt checklist | **Pass** | One handler (:868). Idempotent: grant first, then record (`Receipts.luau:194-207`). PurchaseGranted only after the save. |
| R9 | Pass caching and re-check | **Pass** | Re-check on shop open ("refresh"); verified purchase grants. |
| R10 | Runtime prices | **Pass** | Live price only (`ShopUI.luau:315-340`). |
| R12 | Products deliver what they advertise | **Pass** | B1 and M4 are fixed. See the catalog section above. |
| D1–D5 | Locking, retries, BindToClose, autosave | **Pass** | Unchanged, plus the 7-min stale lock and the handshake. |
| D6 | Migration never drops data | **Pass** (m8 open) | M6 is fixed. The v4 chain is verified above. |
| D9 | No double award | **Pass** | `pr.awarded`, and the Pressure record is max-based. |
| BOT1 | Bots labelled everywhere | **Pass** | See the UX table. |
| BOT2 | Bots not counted as players | **Pass** | `LeaderboardService.submit` and `isRealPlayer` gates. |
| BOT3 | Bots earn nothing | **Pass** | Epic drops, discoveries and payouts are for humans only (`RunDirector.luau:885-887, 1699-1701`). |
| BOT4 | Bots never stake for a human | **Pass** | M3 fixed. |
| T1 | User text filtered / none | **Pass** | No TextBox. |
| T2 | IP-safe names | **Pass** | m11 fixed; full config scan done. |
| S1 | Server authority over movement | **Pass** | M1 fixed. |
| S2 | Remote validation and rate limits | **Partial** | All handled remotes pass. `InteractPoi` has no handler (FB-m2). |
| S3 | Spam doesn't cause expensive work | **Pass** | Lobby debounce. SetPressure and SetSetting write in memory only. Refresh cooldowns. |
| S4 | Leader-only, unlocked-only Pressure | **Pass** (FB-m1) | Server-computed leader plus profile unlock check. |
| U1 | Touch targets ≥ 48 px | **Pass** | `Layout.touchSize`. |
| U2 | Safe insets | **Pass** | `CoreUISafeInsets` on every `Theme.screen`. |
| U3 | No overflow on small screens | **Pass** | M8 fixed. |
| U3b | Readable text on phones | **Fail** *(verify)* | FB-M1. |
| U5 | Onboarding | **Pass** (FB-m4) | Coach marks exist, but there is none for POIs. |

---

## Suggested fix order

1. **FB-M1:** add a text-size floor, then check in the emulator at 667×375 and 640×360.
2. **FB-m2 and FB-m1:** a 5-minute fix each. Bind or remove `InteractPoi`, and freeze Pressure edits in the last 5 s.
3. **FB-m3:** update the docs so the next agent doesn't "fix" the migration.
4. **FB-m4 and FB-m5**, then the Nits.
5. Still open from QC2: m6 (guest mode), m8 (talent refund migration if a `maxLevel` is ever lowered), m14 (analytics).
