# Trunkfall: Monetization (implemented)

Owner: Team D. The source of truth is `src/shared/Config/Monetization.luau`. Research
and policy background is in `docs/research/monetization.md`. **(verify)** marks API
details that must be checked against the current Creator Hub reference before launch.

## Principles

- Robux buys cosmetics, convenience, account-level speed and social boosts. It never
  buys in-run power, upgrade rerolls (reroll tokens cost cheese only) or a stake in
  Double or Nothing.
- **No paid random items.** Every item gives a fixed result that is listed before
  purchase, and `DataConfig.spec` asserts `random = false` on every item.
- Every gameplay-relevant item can be earned for free. All classes unlock with cheese,
  Second Wind tokens come from the daily streak and the cheese shop, and talents cost cheese.
- The game never prompts a purchase on its own. A prompt only happens when the player
  presses a button (`Net.C2S.PromptProduct`). There are no countdown offers, no prompts
  on death or loss screens, and no streak restores for sale.
- Prices come from `MarketplaceService:GetProductInfoAsync` at runtime because of
  regional pricing. `fallbackPrice` is only an offline fallback.

## Catalog

### Game passes (one-time)

| Key | Name | Price (R$) | Benefit |
|---|---|---|---|
| `vip` | VIP Herd | 399 | Gold nametag, Golden Tusk trail, VIP Crown hat, and a fixed daily bonus of +150 cheese and +5 Golden Cheese when the daily reward is claimed |
| `double_xp` | Fast Learner | 249 | 2x **account** XP (levels and level cosmetics). No effect on in-run stats |
| `herd_leader` | Herd Leader | 349 | While the owner is in the server, **everyone** earns +15% cheese. Does not stack |
| `founders` | Founders' Stampede | 499 | Unlocks all 7 classes now (all can be earned), Founder's Plume hat and Founder Gold tint. Launch window only, with no countdown UI |
| `wardrobe` | Cheese Wardrobe | 99 | 6 cosmetics: Viking, Pirate and Flower hats; Bubblegum, Lagoon and Lava tints |

Dropped from the research plan: *Big Trunk* (loadouts and stash slots don't exist) and
*Emote & Sticker Pack* (no emote system yet). Cheese Wardrobe replaces the sticker pack
as the low-cost first purchase.

### Developer products (consumable)

| Key | Name | Price (R$) | Benefit |
|---|---|---|---|
| `golden_xs` | Golden Cheese x100 | 49 | 100 Golden Cheese |
| `golden_s` | Golden Cheese x210 | 99 | 210 (+5%) |
| `golden_m` | Golden Cheese x550 | 249 | 550 (+10%) |
| `golden_l` | Golden Cheese x1150 | 499 | 1,150 (+15%) |
| `golden_xl` | Golden Cheese x2400 | 999 | 2,400 (+20%) |
| `second_wind_1` | Second Wind | 49 | 1 self-revive token |
| `second_wind_3` | Second Wind x3 | 129 | 3 tokens |
| `cheese_rush` | Cheese Rush | 99 | Personal 2x cheese for 60 min of real time. Buying again extends the timer, up to 24 h |
| `cheese_feast` | Cheese Feast | 149 | +50% cheese for **everyone in the server** for 30 min. The buyer is thanked by name in a server-wide toast |
| `ad_reward` | Snack Break (rewarded ad) | 0 (ad only) | +50% of the last run's cheese (min 25, max 500). Max 3 per day, 13+ only |

Golden Cheese is spent only in the cosmetic shop, where every price is fixed and
visible. It never converts to cheese.

Dropped from the research plan: *Gift a Skin*. A cross-profile grant can't be made
atomic with the buyer's receipt, and it needs `GetUsersPriceLevelsAsync` to stop
regional-price arbitrage. This is a candidate for after launch.

### Subscription

| Key | Name | Price | Benefit |
|---|---|---|---|
| `cheese_club` | Cheese Club | 249 R$ / month | Granted automatically on login each day: +40 Golden Cheese and +1 Second Wind. Each month: one exclusive cosmetic the player keeps forever (rotation: Club Swirl trail, Club Cap, Club Teal tint). 10% off the cosmetic shop. Club tag. No combat stats |

### Platform perk

Roblox Premium or Plus members get +10% cheese. This is checked with
`player.MembershipType == Premium`; a separate Plus flag is unconfirmed **(verify)**.
`PromptProduct("roblox_plus")` shows the Plus prompt **(verify API name)**.

### How the cheese multipliers stack

All bonuses are **additive**: `1 + 0.15 (Herd Leader) + 0.5 (Feast) + 0.1 (Premium) + 1.0 (Rush)`,
which gives a maximum of 2.75x. RunDirector applies `MonetizationService.cheeseMult` only
to the **final banked payout**, after Double or Nothing has resolved. Robux-boosted cheese
therefore never enters the pot.

### Second Wind rules (Data/RunTokens and RunDirector)

- Each player gets 1 free self-revive per run. Teammates can always revive for free.
- At most 1 self-revive per stage (free or token), and at most 2 token revives per run.
- Tokens can't be used while a boss is below 10% HP or on a Double-or-Nothing stage.
- A token revive grants no extra rewards. A run that uses one is **unranked**: it is
  kept out of `stats.ranked` and the leaderboards.
- Free sources: daily streak day 3, the Cheese Club daily grant, and the cheese shop
  (1,000 cheese each, holding cap 10).

## Free and soft-currency economy (summary)

- **Cheese shop** (`Config/Shop.luau`):
  - Class unlocks at the `Config/Classes` unlockCost (2,500 or 4,000).
  - 8 talents, each 4–5 levels, costing 200–3,000 per level.
  - 13 shop cosmetics: cheese, Golden Cheese, or both.
  - Reroll token bundles: 3 for 300, 10 for 900, holding cap 30.
  - Second Wind bundles: 1,000 and 2,700.
- **Daily streak:**
  - Rewards by day: 100 cheese, 150 cheese, Second Wind, Sunny tint, 300 cheese,
    25 Golden Cheese, Streak Sparks trail.
  - A day whose cosmetic is already owned gives a fixed fallback instead.
  - Each missed day steps the streak back one day instead of resetting it.
- **First run of the day:** the run's cheese is doubled, with a bonus of at most 1,000.
  This supports Creator Rewards.
- **Account level:** a cosmetic unlocks every 5 levels, up to level 30.

## Creator Dashboard setup checklist

1. [ ] Creator Dashboard → your experience → **Monetization → Passes**. Create the 5
   passes above with icons and descriptions copied from this table, and set the prices.
2. [ ] **Monetization → Developer Products**. Create the 10 products. `ad_reward` needs a
   product too; its price never reaches players because it is granted via AdService.
3. [ ] **Monetization → Subscriptions**. Create Cheese Club as a Robux subscription
   (249 R$, minimum 49) and copy its `EXP-…` id.
4. [ ] Paste every id into `assetId` in `src/shared/Config/Monetization.luau`. It is the
   only place ids live. Ids left at 0 are never prompted ("coming soon" toast) and never granted.
5. [ ] Turn on **Enable Studio Access to API Services** for DataStore testing. Without it,
   DataService uses in-memory profiles and warns.
6. [ ] Studio solo Play test: buy every product. Purchases are mocked and ProcessReceipt
   still fires. Then check:
   - A duplicate PurchaseId grants nothing.
   - A DataStore failure returns NotProcessedYet.
   - Leaving mid-purchase leads to a correct grant on rejoin.
7. [ ] External Purchase Settings: turn on Test Mode before selling products on the
   details page. Watch for the "ProcessReceipt needs a fix" banner.
8. [ ] Final end-to-end test on a private live place with real 1 R$ test products, then delete them.
9. [ ] Badges for streak, founder and flawless are still to be created (not wired yet).

## Compliance checklist

- [ ] Complete the **Maturity & Compliance questionnaire**. Target Minimal or Mild,
      which is required for ads and for all-ages publishing.
- [x] No paid random items. Every Robux item has a fixed, listed result, and tests enforce
      `random = false`. `MonetizationService.paidRandomItemsRestricted` (PolicyService)
      exists in case any are added later.
- [x] **Double or Nothing never touches Robux.** It stakes only earned cheese, Golden
      Cheese is never staked, multipliers apply after the vote resolves, and nothing can
      be bought from the vote or loss screens.
- [x] The Floating Witch "gamba" fight has no wager and no Robux attached.
- [x] **Rewarded ads 13+ only.** The button stays hidden unless AdService reports
      availability. The reward is deterministic and goes through ProcessReceipt. Ads are
      never required: the streak and first-run bonus give the same kinds of reward.
      `ADS_ENABLED = false` until the experience is eligible.
- [x] No timers on offers, no "only N left" messaging, and no prompts on death.
      `isPurchased == false` is handled silently, which respects parental spend limits.
- [x] One ProcessReceipt handler, idempotent and session-locked. It returns
      PurchaseGranted only after the save is confirmed.
- [ ] Before publishing to all ages, the creator needs ID verification and 2FA, plus
      either Plus/Premium history or the refundable 1,000 R$ fee.

## Revenue model (ESTIMATES ONLY)

These are illustrative estimates, not forecasts. Assumptions:

- The developer receives 70% of the Robux price, and earned Robux cash out through
  DevEx at **$0.0038 per R$**.
- The daily payer rate uses the research benchmarks: about 1.25% of DAU at
  platform level (Newzoo 2025). A new game should expect less.
- Cheese Club subscribers pay 249 R$ a month and are assumed to earn the same 70%
  **(verify)**.
- Creator Rewards (5 R$ per Active Spender per day) and Plus referral bonuses are not
  modelled. Both would add to these totals.

| Scenario (estimate) | DAU | Daily payer rate | Avg R$ per payer-day | Net R$/day (70%) | Products and passes $/month | Club subs | Club $/month | **Total $/month** | ARPDAU |
|---|---|---|---|---|---|---|---|---|---|
| Conservative | 1,000 | 0.75% | 120 | 630 | ~$72 | 10 | ~$7 | **~$78** | ~$0.0024 |
| Base | 5,000 | 1.0% | 150 | 5,250 | ~$599 | 75 | ~$50 | **~$648** | ~$0.0040 |
| Optimistic | 25,000 | 1.25% | 180 | 39,375 | ~$4,489 | 500 | ~$331 | **~$4,820** | ~$0.0060 |

Arithmetic, using the base case:

- Net per day: 5,000 × 1% × 150 R$ × 0.7 = 5,250 R$.
- Products and passes: 5,250 R$ × $0.0038 × 30 days ≈ $599 per month.
- Club: 75 × 249 × 0.7 × $0.0038 ≈ $50 per month.

How the estimates compare with the research benchmarks:

- **ARPDAU.** The research gives $0.003–0.006 as a conservative range and
  $0.015–0.025 as strong (verify). The base and optimistic cases sit inside the
  conservative range on purpose; the conservative case sits below it.
- **Payout threshold.** The DevEx minimum is about 30,000 earned R$ (verify). The
  conservative case reaches it in about 1.5 months, the base case in under a week.
- **Payer spend.** GameAnalytics reports a median payer spend of $0.81 a year and a
  top-5% spend of $20.31. Most revenue will therefore come from a few whales on
  Golden Cheese and the Club, so these figures swing widely with the share of top
  spenders.

## Integration API (for other teams)

```lua
-- DataService
DataService.init(); DataService.get(player) -> Profile?; DataService.waitFor(player, timeout?) -> Profile?
DataService.update(player, fn) -> boolean; DataService.push(player); DataService.save(player) -> boolean
DataService.awardRun(player, cheese, xp, {won, cycle, bosses, cycle1Time?, ranked?, day?})
DataService.beforeRelease(callback: (Player) -> ())   -- runs (pcall, <=3 s) before the final save on leave/shutdown
DataService.isReadOnly(player); DataService.today(); DataService.isRealPlayer(x)
DataService.addViewDecorator(fn); DataService.onLoaded(fn)
-- MonetizationService
MonetizationService.hasPass(player, key); .cheeseMult(player); .xpMult(player); .extraRerolls(player)
MonetizationService.prompt(player, key)  -- keys from Config/Monetization, plus "refresh" (shop opened) and "roblox_plus"
MonetizationService.isClubMember(player); .feastSecondsLeft(); .paidRandomItemsRestricted(player)
-- LeaderboardService
LeaderboardService.submit(player, rankedStats)  -- called by DataService.awardRun; do not call separately
LeaderboardService.getTop("deepestCycle" | "wins" | "fastestCycle1") -> {{rank, userId, name, value}}
```

All public functions return safe defaults for bots: anything that is not a Player, or a
UserId ≤ 0 outside Studio. Bots never get profiles, purchases or leaderboard entries.
