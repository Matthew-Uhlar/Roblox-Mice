# Monetization Research: Elephants vs Mice (Roblox co-op roguelike)

*Research date: 2026-10-30. Scope: Roblox monetization levers, policy, benchmarks and a plan for this game.*

> **Method note:** create.roblox.com could not be fetched directly, so facts come from search extracts of official docs, DevForum, the newsroom and SEC filings, cited as `[n]`. **(verify)** marks single or third-party sources; confirm those in the Creator Hub before shipping.

---

## 1. Monetization levers available now (Oct 2026)

| Lever | What it is / API | Key current facts |
|---|---|---|
| **Game Passes** | One-time, permanent. `MarketplaceService:PromptGamePassPurchase`, `UserOwnsGamePassAsync`, `PromptGamePassPurchaseFinished` | Regional pricing launched Apr 2025 and is now on by default ("managed pricing") [4][5]. Developer receives 70% after the 30% fee [21]. |
| **Developer Products** | Consumable and repeatable. `PromptProductPurchase` plus the server-side `MarketplaceService.ProcessReceipt` callback, or the newer `BindReceiptHandler` (verify) [9] | Regional pricing extended to dev products [6]. Since Feb 2025, products can be sold on the experience details page (Test Mode required) [10]. Since Sep 2026, a **"ProcessReceipt needs a fix"** banner hides products from outside surfaces when the handler is flagged [11]. |
| **Cross-experience sales** | *Removed.* | Since 29 May 2026 passes and products sell only in their own experience. Peer-to-peer Robux now goes through the **Transfers API** (Plus senders only, 10% fee) (verify) [12]. |
| **Premium Payouts / EBP** | *Deprecated 24 Jul 2025.* | Replaced by **Creator Rewards** [1][2]. |
| **Creator Rewards** | Automatic, no API | Daily Engagement pays **5 R$ per "Active Spender"** who plays at least 10 minutes in one of the first 3 experiences they open that day. An Active Spender has spent at least $9.99 in the past 60 days. Audience-expansion rewards pay for new and reactivated users. Payouts are held 60 days [3]. |
| **Roblox Premium → Roblox Plus** | Platform subscription | Plus launched 30 Apr 2026 at $4.99/mo and closed new Premium sign-ups [13][14]. Experiences that prompt Plus via `PromptRobloxSubscriptionPurchase` reportedly earn **250 R$/mo for each subscriber's first 3 months** (verify) [15]. |
| **In-experience Subscriptions** | `PromptSubscriptionPurchase`, `GetUserSubscriptionStatusAsync` | Can be priced in **Robux** (minimum 49 R$, regional pricing applies, launched Apr 2026) or in local currency (5 fixed tiers). Price changes allowed once per 60 days with 30 days' notice. Up to 50 per experience. No mutually exclusive Bronze/Silver/Gold tiers [16][17]. |
| **Rewarded Video Ads** | `AdService:GetAdAvailabilityNowAsync(Enum.AdFormat.RewardedVideo)`, `CreateAdRewardFromDevProductId`, `ShowRewardedVideoAdAsync(player, reward, placementId)` | Launched Apr 2025 with Google [18] and opened to all ads-eligible creators by Nov 2025 [19]. Viewers must be **13+**. Content maturity must be Minimal or Mild. **The reward is granted through ProcessReceipt and cannot be a random item** [20]. |
| **Immersive Ads** (billboards/portals) | Ad units placed in Studio | Publisher must be 18+, ID-verified, use 2FA, and meet a visitor threshold. No ads are shown to users under 13 [22]. |
| **Avatar items / UGC** | `PromptPurchase` on a Marketplace item | The experience owner gets a **40% affiliate commission** on in-experience sales [23]. Publishing UGC now requires Plus [14]. |
| **Other** | Private servers, Paid Access, Commerce APIs (Shopify) | Private servers count toward the 18+ DevEx rate [24]. Paid Access does not fit a free-to-play co-op game [25]. Commerce (physical merch, U.S. 13+) is a later idea [26]. |
| **Price Optimization** | Creator Dashboard | Runs 2-week price tests on passes and products [7]. |

**DevEx rate:** **$0.0038 per earned Robux** for Robux earned on or after 5 Sep 2025, an 8.5% rise. Older Robux cash out at $0.0035 [1][27]. Since 8 Jun 2026, spend from **age-verified U.S. 18+ players** on passes, Robux subscriptions, select items and private servers in R15-rig games cashes out at **$0.0054** [24]. That rate is a minor factor for a kid-skewed game. The minimum cash-out is about 30,000 earned R$ (verify).

---

## 2. Policy constraints that shape the design

1. **Paid random items.** Any random reward bought with Robux, or with currency bought with Robux (crates, eggs, spins, luck boosts), must list every outcome with its numeric odds. Odds boosters must show the boosted odds. Players must be gated with `PolicyService:GetPolicyInfoForPlayerAsync().ArePaidRandomItemsRestricted`. Without that gate, the game becomes unavailable to UK users under 18. Restricted users may not trade the outcomes [28][29]. **Our decision: no paid random items at launch.** Every Robux purchase gets a known, specific result.
2. **Gambling.** Playable or simulated gambling is prohibited. **"No real money, Robux, or in-experience items of value may be exchanged in connection with any gambling activities"** [30]. This means:
   - **Double or Nothing** may stake only free, earned run rewards. Robux-bought currency must never enter the pot. Do not sell "insurance", "keep half on loss" or "buy back the pot". Do not offer a purchase prompt on the loss screen.
   - The **Floating Witch "gamba" fight** has random spell rotation as gameplay. Avoid slot-machine, roulette or casino UI. Do not let players wager currency on it, and do not attach Robux to it.
3. **Age and audience (2026).** Users who have not verified their age default to **Roblox Kids (5–8)**. **Select** covers 9–15 [31][32]. Since 19 May 2026, publishing to all ages requires the creator to be **ID-verified**, use **2FA**, and either hold 2 months of Plus/Premium or pay a **refundable 1,000 R$ fee per game**. The game must then pass an evaluation based on engagement from highly engaged, age-checked players [33]. Social-hangout and free-form-drawing features are barred from Kids and Select catalogs [31]. Sprays must therefore be preset stickers only.
4. **Content Maturity.** Since 30 Sep 2025, unrated experiences cannot be played [34]. Complete the Maturity & Compliance questionnaire and aim for **Minimal or Mild** so the game qualifies for ads and all ages.
5. **Spending controls.** Parents can set monthly spend caps, get spend notifications, or block purchases entirely [35][36]. Purchase prompts must fail gracefully, with no nagging and no repeated re-prompts.
6. **Dark patterns.** A 2026 University of Sydney audit found deceptive monetization in 14 of 15 top games [37]. Do not use countdown-timer offers, "only 5 left" messaging, or timed purchase prompts on death screens.
7. **Refunds.** Robux purchases are generally not refundable. Unfulfilled dev-product receipts are retried when the player rejoins or makes another purchase [8]. Chargebacks reverse pending Robux (verify).
8. **Ads.** Rewarded ads reach only users 13+, so under-13 players must have a non-ad path to every reward [19].

---

## 3. What comparable games sell (benchmarks)

| Item type | Typical price | Source |
|---|---|---|
| 2x XP / 2x coins multiplier pass | 99–249 R$ | [38] (third-party guide) |
| VIP pass | ~300 R$ (All Star Tower Defense) up to 1,500 R$ (Ball TD) | [39] |
| Premium battle/season pass | ~799 R$ (Universal TD) | [39] |
| Soft-currency packs (DOORS knobs) | 49 / 99 / 129 / 199 / 399 / 699 / 1,799 R$ | [40] |
| Revives (DOORS) | Robux-only consumable, also given free through codes and group join | [40] |

**Conversion and revenue benchmarks:**
- Newzoo (2025): about **1.25% of DAU purchase per day**, with daily bookings per DAU of about $0.14 at platform level [41].
- GameAnalytics (2025, ~500 games): the median payer spent **$0.81 per year**, the top 10% spent $8.88 and the top 5% spent $20.31 [42].
- Developer-side ARPDAU estimates: **$0.003–0.006** conservative, $0.015–0.025 strong [43] (verify). Dashboard ARPDAU = conversion × ARPPU [44].

---

## 4. Plan for this game: ethical and not pay-to-win first

**Principles:**
- Robux buys cosmetics, convenience, account-level speed and social gifts.
- Robux never buys in-run power, upgrade rerolls, or stakes in Double or Nothing.
- Everything that affects gameplay can be earned for free.

### Game Passes (one-time; each needs a **Pass asset ID** from Creator Dashboard → Monetization → Passes)

| # | Pass | Price | Contents | Rationale |
|---|---|---|---|---|
| P1 | **VIP Herd** | 399 R$ | Gold nametag, VIP lobby corner, daily VIP cheese crate with fixed contents, exclusive "Golden Tusk" trail | Status only. Matches the ~300–400 R$ VIP benchmark. |
| P2 | **Fast Learner (2x Account XP)** | 249 R$ | 2x *meta* XP toward class and cosmetic unlocks. No effect on in-run stats. | Standard multiplier price. Unlocks are all earnable free. |
| P3 | **Big Trunk** | 149 R$ | +3 saved loadout presets, +20 cosmetic stash slots | Convenience pass. |
| P4 | **Herd Leader** | 349 R$ | When the owner is in a party, **every member** gets +15% end-of-run cheese (soft currency, does not stack) | Positive-sum co-op. Friends want the owner in their party. |
| P5 | **Founders' Stampede** | 499 R$ (launch window only, no countdown UI) | Instant unlock of all 7 classes (also earnable), founder badge, 2 founder skins | Classes are sidegrades, so this is a time-saver. |
| P6 | **Emote & Sticker Pack** | 99 R$ | 8 emotes and preset stickers (no free drawing) | Low-friction first purchase. |

### Developer Products (consumables; each needs a **Developer Product ID**)

| # | Product | Price | Notes |
|---|---|---|---|
| D1–D5 | **Golden Cheese packs** (premium cosmetic currency) | 49 / 99 / 249 / 499 / 999 R$, with +0/5/10/15/20% bonus | Spent only in a **deterministic** cosmetic shop where every item shows its price, so no odds disclosure is needed. The shop UI also shows the Robux-equivalent price. 5 IDs. |
| D6 | **Second Wind token** | 49 R$ (3-pack 129 R$ = D7) | Self-revive. See the rules below. |
| D8 | **Cheese Feast** (server boost) | 149 R$ | +50% soft currency for **everyone in the server** for 30 minutes, with a server-wide shout-out. Social and positive-sum. |
| D9 | **Gift a Skin** | One product per price tier: 99 / 249 / 499 R$ | Buys a specific skin for a friend in the server. Use `GetUsersPriceLevelsAsync` to prevent regional-price arbitrage [5]. |
| D10 | **Rewarded-ad reward** (R$ 0, ad-only) | Dev product used with `CreateAdRewardFromDevProductId` | Grants +50% cheese on the run results screen, or 1 Second Wind. Capped at 3 per day. |

**Cosmetic elephant skins and trails.** About 4 skins per class (free starter, earned, Golden Cheese, seasonal), themed on the cheese maps (Parmesan Beach, Blue-Cheese Tundra, Cheddar Volcano, Mozzarella Moon). Add trails (cheese crumbs, bubbles, lava drips) and mouse-defeat VFX, priced 300–1,200 Golden Cheese in a deterministic weekly rotation with no countdowns. Later, sell 2–3 **UGC avatar items** (elephant ears, trunk hat) in-experience for the 40% commission (needs Marketplace asset IDs and Plus).

**Second Wind rules (keeping co-op fair):**
- Every player gets **1 free Second Wind per run**. Teammates can always revive a downed player for free by standing next to them.
- Paid tokens allow **at most 1 additional self-revive per map and 2 per run**.
- Tokens cannot be used during the final 10% of a boss's HP or in the Double-or-Nothing finale.
- A paid revive grants **no extra rewards**.
- Runs that use paid revives are tagged and **excluded from leaderboards and "Flawless" badges**.
- Tokens are earnable from the daily streak (day 3), from rewarded ads (13+), and from rare boss drops.
- Never auto-prompt a purchase on death. Show "Use Second Wind (you have N)" only when N > 0. Buying happens in the shop or through a plain button that has no timer.

### Subscription idea: "Cheese Club" (Robux subscription, needs a **Subscription ID**)
- **249 R$/month** (minimum allowed is 49).
- Benefits: 40 Golden Cheese per day on login (about 1,200 per month), one exclusive skin each month that the player **keeps forever**, +1 free Second Wind per day, a club chat tag, and 10% off the cosmetic shop.
- No combat stats. It qualifies for the 18+ U.S. DevEx rate.

### Premium / Plus plan
- Premium Payouts are gone. Optimize for **Creator Rewards**: **10+ minute sessions** and being one of a player's **first 3 games** each day (daily streak, first-run-of-the-day bonus).
- Premium/Plus perk: nametag icon and +10% soft currency, no power. Check `Player.MembershipType == Enum.MembershipType.Premium`; a separate Plus flag is unconfirmed (verify).
- One non-intrusive "Get Roblox Plus" button in the lobby shop via `PromptRobloxSubscriptionPurchase` (verify API name).

### Daily login and streak
- A 7-day ladder: cheese, cheese, **Second Wind**, cosmetic sticker, cheese, Golden Cheese ×25, and a **streak trail** on day 7.
- A missed day **steps back 1 day instead of resetting**. Streak restores are **never** sold, because selling them exploits loss aversion.
- Add a "first run of the day" ×2 cheese bonus to support Creator Rewards.

### Rewarded ads fit
- Good fit: optional, on the results screen, deterministic reward through D10.
- Hide the button unless `GetAdAvailabilityNowAsync` says available (it won't for under-13s or ineligible users). Never require ads to progress. Needs Minimal/Mild maturity and good standing [19].

### Asset IDs to create in the Creator Dashboard
- **Passes:** P1–P6
- **Developer products:** D1–D10, about 14 IDs including the price tiers
- **Subscription:** Cheese Club
- **Badges:** streak, founder, flawless
- **Optional:** UGC items, private-server price
- Put every ID in one `ReplicatedStorage/Config/MonetizationIds` module. Never scatter literal IDs through the code.

---

## 5. Implementation checklist for devs

**ProcessReceipt and dev products**
- [ ] Assign **one** `ProcessReceipt` callback, in **one server Script**. Optionally migrate to `BindReceiptHandler` after checking its docs [9].
- [ ] If the player is not in the server, return `NotProcessedYet`.
- [ ] **Wait for the player's session-locked profile to load** (ProfileStore or equivalent) before granting. Purchases made outside the experience arrive at join, before data loads [11][45].
- [ ] **Idempotency:** keep a rolling `PurchaseIds` history (the last ~100) in the player's profile.
  - If `receipt.PurchaseId` is already in the history, return `PurchaseGranted` without granting again.
  - Otherwise grant the item and record the ID **in the same profile write**.
  - Return `PurchaseGranted` **only after the save is confirmed**. On any error, return `NotProcessedYet`.
- [ ] Wrap DataStore calls in `pcall` and do not yield forever. Roblox retries a receipt only when the player rejoins or buys again, not on a timer [8].
- [ ] Never grant from the client or from `PromptProductPurchaseFinished`, which is UI-only.
- [ ] Turn on Test Mode under External Purchase Settings before listing products outside the experience [10]. Watch for the "needs a fix" banner [11].

**Game Passes**
- [ ] On `PlayerAdded`, check every pass with `pcall(UserOwnsGamePassAsync)`, cache the results in a server table, and apply the perks.
- [ ] `UserOwnsGamePassAsync` results can be cached for about 10 seconds [46]. On the server's `PromptGamePassPurchaseFinished(player, passId, wasPurchased)`, set the cache entry to true when `wasPurchased` is true, then re-verify after a short delay.
- [ ] Re-check ownership when the shop opens, to catch website purchases.
- [ ] Apply pass perks idempotently (grant state, never add stacking increments).

**Pricing and policy**
- [ ] Show all prices dynamically with `GetProductInfoAsync` or `GetDeveloperProductsAsync`. Regional pricing changes them, so never hardcode prices in the UI [5].
- [ ] Add a `PolicyService` wrapper now, even though nothing is random-paid at launch, in case paid random items are added later [28].
- [ ] Handle `isPurchased == false` quietly to respect parental spending limits.

**Testing**
- [ ] In a Studio solo Play test, purchases are **mocked and not charged** and ProcessReceipt still fires [47]. Team Test is unreliable for receipts.
- [ ] Test these cases:
  - A duplicate `PurchaseId` grants nothing the second time.
  - A server killed mid-grant leads to a correct grant on rejoin.
  - A DataStore failure returns `NotProcessedYet`.
  - Ads unavailable hides the ad button.
  - A restricted policy account behaves correctly.
- [ ] Run a final end-to-end test on a private live place with real 1-R$ test products, then delete them.

---

## Sources
1. SEC 10-Q Q3 2025: https://www.sec.gov/Archives/edgar/data/1315098/000131509825000327/rblx-20250930.htm
2. Engagement-based payouts (deprecated): https://create.roblox.com/docs/production/monetization/engagement-based-payouts.md
3. Creator Rewards: https://create.roblox.com/docs/creator-rewards and https://devforum.roblox.com/t/introducing-creator-rewards-earn-more-by-growing-the-community/3777628
4. Regional pricing for passes: https://devforum.roblox.com/t/introducing-regional-pricing-for-passes/3621382
5. Regional pricing docs: https://create.roblox.com/docs/production/monetization/regional-pricing.md
6. Regional pricing for dev products: https://devforum.roblox.com/t/introducing-regional-pricing-for-developer-products/3971235
7. Price Optimization: https://devforum.roblox.com/t/introducing-price-optimization-find-the-best-prices-for-in-experience-items-and-passes/3186081
8. NotProcessedYet behaviour: https://devforum.roblox.com/t/notprocessedyet-taking-robux-from-users/3237430
9. MarketplaceService reference: https://create.roblox.com/docs/reference/engine/classes/MarketplaceService.md
10. Selling dev products on the details page: https://devforum.roblox.com/t/selling-developer-products-on-your-experience-details-page/3494897
11. ProcessReceipt fix banner: https://devforum.roblox.com/t/fix-the-processreceipt-needs-a-fix-banner-and-sell-your-products-outside-your-game/4910527
12. Cross-experience sales ended / Transfers API: https://piunikaweb.com/2026/05/05/roblox-disable-gamepasses-sales-players-furious/
13. Roblox Plus (newsroom): https://about.roblox.com/newsroom/2026/04/introducing-roblox-plus-subscription
14. Introducing Roblox Plus (DevForum): https://devforum.roblox.com/t/introducing-roblox-plus/4567894
15. Plus creator bonus: https://tubefilter.com/2026/04/13/roblox-plus-creator-payouts
16. Subscriptions docs: https://create.roblox.com/docs/production/monetization/subscriptions.md
17. Robux subscriptions: https://devforum.roblox.com/t/let-your-players-pay-for-subscriptions-within-experiences-in-robux/4552995
18. Roblox and Google video ads: https://about.roblox.com/newsroom/2025/04/roblox-scales-video-ads-partners-with-google
19. Rewarded video eligibility: https://devforum.roblox.com/t/more-creators-can-now-use-rewarded-video-ads/3838678
20. Rewarded video ads docs: https://create.roblox.com/docs/production/promotion/rewarded-video-ads
21. 30% fee: https://www.analyticsinsight.net/gaming/how-to-make-money-on-roblox-as-a-developer
22. Immersive ads: https://create.roblox.com/docs/production/monetization/immersive-ads
23. Avatar monetization and commissions: https://create.roblox.com/docs/en-us/monetize-avatar and https://create.roblox.com/docs/marketplace/marketplace-fees-and-commissions
24. 18+ DevEx rate: https://about.roblox.com/newsroom/2026/04/roblox-fuels-high-fidelity-games-over-18-players-increases-qualifying-devex-rate-42 and https://create.roblox.com/docs/production/monetization/18-plus-devex-rate
25. Paid access: https://create.roblox.com/docs/production/monetization/paid-access-robux
26. Commerce APIs: https://about.roblox.com/newsroom/2025/05/roblox-launches-shopify-integration-amp-licensing-program
27. DevEx 8.5% increase: https://gam3s.gg/news/roblox-increases-creator-payouts
28. Paid random items: https://create.roblox.com/docs/production/monetization/paid-random-items
29. UK under-18 restriction: https://devforum.roblox.com/t/update-on-paid-random-items-restriction-for-uk-users-under-18/3072183
30. Gambling policy discussion: https://devforum.roblox.com/t/clarity-around-playableunplayable-gambling-in-17-experiences/3097203
31. Kids/Select accounts: https://techcrunch.com/2026/04/13/roblox-introduces-kids-and-select-accounts-for-age-appropriate-access-to-games-and-chat/
32. Kids and Select publishing: https://create.roblox.com/docs/production/publishing/kids-and-select
33. Publishing requirements: https://devforum.roblox.com/t/new-publishing-requirements-evaluation-process-for-games/4573166
34. Unrated experiences: https://devforum.roblox.com/t/important-updates-unrated-experiences-and-changes-to-experience-pages/3899317
35. Parental spending controls: https://www.businesswire.com/news/home/20260616748440/en/
36. Parental controls guide: https://www.parentmap.com/article/parental-controls-roblox
37. University of Sydney audit: https://www.sydney.edu.au/news-opinion/news/2026/05/17/inside-the-pay-to-play-world-of-roblox-targeting-children-.html
38. Pass pricing guide: https://www.creation.dev/learn/how-to-price-game-passes-roblox
39. Tower defense pass prices: https://sportskeeda.com/roblox-news/ball-tower-defense-robux-shop-guide and https://sportskeeda.com/roblox-news/exploring-gamepasses-roblox-all-star-tower-defense
40. DOORS knobs: https://doors-game.fandom.com/wiki/Knobs
41. Newzoo on Roblox: https://gamedevreports.substack.com/p/newzoo-roblox-as-a-platform-in-2025
42. GameAnalytics 2025 Roblox report: https://www.gameanalytics.com/reports/2025-roblox-report
43. DevEx math per 1,000 players: https://rowatcher.com/news/devex-math-in-2026-what-you-actually-take-home-per-1-000-players
44. Monetization analytics: https://create.roblox.com/docs/production/analytics/monetization
45. ProfileStore dev products: https://madstudioroblox.github.io/ProfileStore/devproducts
46. UserOwnsGamePassAsync caching: https://devforum.roblox.com/t/do-not-cache-results-of-userownsgamepassasync/3639404
47. Mock purchases in Studio: https://devforum.roblox.com/t/mock-purchases-in-studio/26974
