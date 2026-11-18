# v5 plan: Zombie-World-style progression (LIVE game; additive migrations only)

The owner's request (2026-11-18): research Zombie World Liberty (an SC2
arcade game) and adopt its design for **in-round character upgrading** and
**long-term character progression**, while continuing v4.

- Research: `docs/research/zombie-world.md`.
- We borrow the mechanics only. All names are ours.
- Order of work: v4 ships first (QC fixes in progress), then v5 builds on top of it.

## Rules carried over from v4

- Never put Robux next to any of this: no buying rinds, whey, talent points, stomps, evolutions or charms, and no paid rerolls or random paid items.
- Bots are labelled 🤖.
- Talent and charm damage apply to PvE only (`stats.pveDamageMult`), so long-term grind never decides PvP.

## A. In-round upgrading (resets every run)

### A1. Two run currencies

**Rinds** (common):
- Every mouse killed drops rinds for the killer, auto-collected:
  - 1 per normal mouse;
  - 3 for elites;
  - 40 for champions, split by damage share;
  - 150 for bosses, split by damage share.
- Squadmates within 45 studs of the killer get 50% of the rinds as a share.
- The amount scales ×(1 + 0.25·(stage−1)).
- **Rinds are kept on death and lost at run end.** They never count as payout cheese.

**Whey** (scarce):
- Earned per POI completed (+40), per champion kill (+60 to the top-damage squad, 30 each to the others), and per stage survived (+50).
- Also +1 per 25 rinds earned.
- **Unspent whey is kept on death. Whey buffs are lost on death.**

### A2. Stat Ranks: upgrade menu (key `V`, or a phone button)

8 stats, max 25 ranks each. The cost of the next rank is `ceil(base · 1.14^rank)` rinds.

| Rank | Per rank | Base cost |
|---|---|---|
| Might | +4% damage (PvE) and +2% damage (PvP) | 20 |
| Hide | +5% max HP | 20 |
| Plating | +1 armor (×0.35 in PvP, as before) | 30 |
| Mending | +0.25 HP/s regen | 25 |
| Frenzy | +2.5% attack speed | 30 |
| Stride | +1.2% move speed (cap +20%) | 25 |
| Reach | +6% pickup range | 15 |
| Focus | −2% ability cooldown (cap −35%) | 35 |

- Full 25/25 on all 8 costs about 75k rinds. A good run earns about 8–15k, so builds are choices.
- **Kept on death.**

### A3. Buff Stalls (whey)

- **Placement:** 4–6 stall pads per map (ArenaBuilder places them, roughly evenly around 0.55 R, and they move inward with the stage radius).
- **Buffs:** each stall offers 2 of the 8 whey buffs at 250 whey each.
  - **Rush:** +15% move speed.
  - **Thick Skin:** +20% max HP.
  - **Keen:** +10% crit chance.
  - **Leech:** heal 2% of damage dealt.
  - **Bloom:** +25% area.
  - **Greed:** +30% rinds.
  - **Scholar:** +30% XP.
  - **Bulwark:** −15% damage taken.
- **Class Stall:** one per map, near the centre. It sells the player's own **class buff** for 500 whey; 7 defs, one per class (each class's signature amplified, e.g. +1 projectile, +30% ability radius).
- **Rules:**
  - A buff is bought once per life. Buffs stack with each other, not with themselves.
  - **All whey buffs are lost when the hero is knocked out** (dead, not just downed and revived by a squadmate).
- **Interaction:** stand on the pad, then a ProximityPrompt opens a 2-choice popup.

### A4. Big Cheese Altar (late game, the centre)

- **Placement:** at the arena centre. The storm already drives everyone there, so the Altar becomes the PvP focal point.
- **Unlock:** from stage 3 onwards.
- **Upgrades:** 4 ultimate upgrades at 6,000 rinds + 600 whey each.
  - **Titan:** +40% max HP and +15% size.
  - **Cataclysm:** your ability hits twice.
  - **Overdrive:** +35% attack speed.
  - **Herdguard:** your squad takes −12% damage while near you.
- **Lost on knockout.** At most 2 per hero.
- **Purchases are announced to all squads**, because the buyer becomes a bounty target (bounty +50%).

### A5. Swap Stand

At the Altar: 10 rinds ↔ 1 whey, with a 20% fee either way.

### A6. Boost Zones

- **Zones:** three capture zones per map.
  - **Rind Mill:** +60% rinds.
  - **Whey Spring:** +60% whey and +1 whey/s.
  - **Golden Glade:** +30% of both and +40% XP.
- **Capture:** the same capture-and-hold logic as the Power Totem (contested by squads).
- **Placement:** the zones sit inside the next storm circle when possible.

### A7. Level buffs and shared XP

- **Level buffs:** each in-run level also grants a small listed buff, on top of the upgrade cards.
  - Every level: +2 max HP.
  - Every 5 levels: +3% damage.
  - Every 10 levels: +1 armor.
  - A "Levels" list shows them.
- **Levels are kept** through redeploy (a deviation from Zombie World; our redeploy already costs time).
- **Shared XP:** squadmates within 45 studs get 50% of the XP from kills.

### A8. Status list

- A "What's left to buy" list (the Zombie World `-status` equivalent) shows unbought stalls with their distance and cost, and the Altar with its cost.
- Toggle it with `B` or a phone button.

## B. Long-term progression (saved)

### B1. Herd Talent Points (per class)

**Earning:**

| Source | Points |
|---|---|
| Boss kill (participated) | +3 |
| Champion kill (participated) | +1 |
| Stage cleared alive | +1 |
| Extraction | +2 |
| Win (M1 rule) | +5 |

- Points are multiplied by Pressure (`1 + 0.1·pressure`).
- First-of-day bonus ×2, up to 10 points.
- Points go to the class you played.

**Talent Board** (per class, 10 repeatable talents, 50 ranks each):
- **Cost:** 1 point per rank for ranks 1–10, 2 for 11–30, 3 for 31–50, so 120 points per maxed talent.
- **The 10 talents and their per-rank values:**
  - Brawn: +0.5% PvE damage
  - Bulk: +0.6% max HP
  - Guard: +0.1 armor
  - Vigor: +0.03 HP/s
  - Haste: +0.25% attack speed
  - Fleet: +0.15% move speed
  - Insight: +0.6% XP
  - Fortune: +0.6% cheese, capped by M11
  - Scavenger: +0.8% rinds
  - Alchemy: +0.8% whey
- **Total and pace:** fully maxed is about +25% PvE damage and +30% HP, with 1,200 points per class, and about 6 points per typical run. That's the long tail beyond class level 30, alongside Mastery Stars.
- **Respec:** free once per day, otherwise cheese.
- **Not the same as the existing systems:** the account Talents (cheese) and class Perks stay as they are. The board is a separate "Talents" tab in the class screen.

### B2. Lifetime Stomps and Evolutions

**Stomps:** each class counts the mice its player has killed (`classes[id].stomps`), plus an account total (`stats.stomps`, also a leaderboard).
- Kills are **not** split between squadmates; each player counts their own.
- Pressure ×(1 + 0.05·pressure) applies.

**Evolutions** (per class, 4 stages):

| Stage | Class stomps | What it adds |
|---|---|---|
| 1 | 0 | base look |
| 2 | 2,500 | "Bull" look (bigger tusks, war paint); +3% max HP |
| 3 | 15,000 | "Matriarch" look (armor plates, glowing eyes); +3% PvE damage; ability gets an extra visual |
| 4 | 60,000 | "Ancient" look (stone/gold carapace, aura); +4% XP and rinds; unique nameplate frame |

- The bonuses are small. Most of the reward is the look and the status.
- The player can choose to display any unlocked stage.

**Free class unlocks by account stomps**, an alternative to buying with cheese, for each locked class: 1,000 / 5,000 / 12,500 / 25,000 / 50,000 / 100,000 in the order of Config/Classes. Cheese purchase stays.

**Nameplate:** shows the stomp count (for example "🐭 12.5k").

### B3. Charms (team jewels)

**Drops:**
- **Boss:** each boss kill drops 1 charm to each member of the top-damage squad.
- **Match end:** a chance by stage reached: 25 / 45 / 70 / 100% at stages 1–4.

**Rarity weights:** Common 70, Rare 22, Epic 7, Legendary 1. From stage 4, Rare+ is guaranteed.

**Sockets:** 3, unlocking at account levels 1, 10 and 25.
- **Equipped charms grant a squad-wide aura**: every member of your squad gets the bonus, bots included.
- The same charm type from several squadmates doesn't stack; the highest rarity wins. This encourages variety.

**Charm types (12):**

| Charm | Bonus per rarity (C / R / E / L) |
|---|---|
| Might | +2/4/6/9% PvE damage |
| Vigor | +3/5/8/12% max HP |
| Swiftness | +2/3/5/7% move speed |
| Wisdom | +5/8/12/18% XP |
| Plenty | +4/7/10/15% rinds |
| Spring | +4/7/10/15% whey |
| Mending | +0.2/0.3/0.5/0.8 HP/s |
| Focus | −3/5/7/10% ability cooldown |
| Luck | +1/1/2/3 luck |
| Haste | +2/3/5/7% attack speed |
| Warding | −2/3/5/7% damage taken (PvE) |
| Fortune | +2/3/5/8% cheese payout, within the M11 cap |

**Inventory:** 60 slots.
- **Fuse:** 3 charms of the same type and rarity make 1 of the next rarity.
- **Salvage:** a charm can be turned into cheese.
- **Never sold for Robux, never rerolled for Robux.** Charms are not in the shop.

### B4. Profile v7 (additive)

- **Per class** (`classes[id]`): `talentPoints`, `talentSpent`, `talents = {[id]=rank}`, `stomps`, `evo` (chosen stage).
- **Account:** `stats.stomps`, `charms = {inv = {{id, type, rarity}}, equipped = {id?, id?, id?}, nextId}`, `talentRespecDay`.
- Migration from v1–v6 adds the defaults.
- **Veterans:** start stomps at `stats.kills` if that field exists, otherwise 0. Never take anything away.

## Ownership (same split as v4)

| Team | Owns (v5) |
|---|---|
| **M1 Combat** | World hooks: rind/whey drops and sharing, XP share, kill attribution, stat-rank and whey/ultimate application inside World stats, Altar "Herdguard" aura, charm auras applied to squad heroes. Config `RunShop.luau` (new: ranks, whey buffs, class buffs, ultimates, swap rate, boost zones). Specs `Combat*`. |
| **M2 Match flow** | `Run/RunWallet.luau` (new, pure: rinds/whey balance, buy rank/buff/ultimate, lose-on-knockout, swap). Remotes: `BuyRank`, `BuyStallBuff`, `BuyUltimate`, `Swap` via `Guard`; stall/Altar proximity validation in RunDirector; boost-zone capture; announcing Altar purchases; sending `Wallet` S2C; talent-point, stomp and charm-drop events into DataService at the right moments. Sim and specs `Run*`, `Integration*`, `Runtime*`. |
| **P Progression** | `Data/Talents2.luau` (Herd Talent Board), `Data/Evolution.luau`, `Data/Charms.luau`, profile v7 migration, `Config/{HerdTalents,Evolutions,Charms}.luau`. DataService APIs: `addTalentPoints`, `spendTalent`, `respecTalents`, `addStomps`, `setEvo`, `grantCharm`, `equipCharm`, `fuseCharms`, `salvageCharm`, `squadCharmAura`. Remotes: `SpendTalent`, `RespecTalents`, `SetEvo`, `EquipCharm`, `FuseCharms`, `SalvageCharm`. Free class unlocks by stomps. Leaderboard `stomps`. Specs `Data*`. |
| **U UI** | Upgrade menu (V), Stall and Altar popups, "What's left" list (B), wallet HUD (rinds and whey), Levels list, Talents tab with board, Evolution panel with stage picker, Charms inventory (sockets, fuse, salvage), stomp counter on the HUD and nameplate. Specs `Client*`. |
| **G Graphics** | Stall pads, Class Stall, Big Cheese Altar, Swap Stand and the 3 boost-zone models (ArenaBuilder places them per `Maps.stageRadius`). Evolution looks stages 2–4 for player hoods and bot models. Charm icons and drop VFX, rind/whey pickup VFX, Altar purchase flare. |
| **Lead** | `Net` remotes, `Types`, docs, integration, QC, publish. |

## Contracts

- **Net** (the lead adds these):
  - C2S:
    - `BuyRank(stat)`, `BuyStallBuff(stallId, buffId)`, `BuyUltimate(id)`, `Swap(dir, amount)`
    - `SpendTalent(classId, talentId)`, `RespecTalents(classId)`, `SetEvo(classId, stage)`
    - `EquipCharm(slot, charmId?)`, `FuseCharms(type, rarity)`, `SalvageCharm(charmId)`
  - S2C: `Wallet({rinds, whey, ranks = {[stat]=n}, buffs = {ids}, ultimates = {ids}})` and `Stalls({ {id, x, z, offers = {buffId, buffId}, class = bool} }, altar = {x, z, open})`.
- **World:**
  - `world:setRunMods(id, mods)`: M2 passes the combined rank, buff and ultimate stat deltas, and M1 applies them as a stat layer.
  - `world:setSquadAura(squad, auraDeltas)`: the charm aura.
  - Event `rinds {id, amount}` per kill (squad shares included).
- **Stat deltas** use the existing `Types.StatDelta` shape (`add`/`mul` per stat); a new stat key may be added only as an optional field.
- **DataService.awardRun stats** gains `talentPoints`, `stomps` and `charmDrops` (P computes the grants; M2 supplies the counts).
