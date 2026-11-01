# Trunkfall — Game Design Document (v0.1, Roblox)

> Working title. Source material: `docs/brainstorm-2026-06.md` (team brainstorm,
> June 2026). This doc turns that brainstorm into concrete, buildable rules for a
> **Roblox** version. Where the brainstorm left a choice open, the decision taken
> here is marked **[decision]** so the team can revisit it.

## 1. Pitch

Co-op (1–4 players) top-down horde roguelike. You are an elephant hero. The mice
have stolen the world's cheese. Hop between cheese-themed worlds, mow down
swarms of mice with auto-attacks, stack wild upgrades, beat a boss on every map,
and decide: bank your cheese and go home, or go **Double or Nothing**.

Genre: "RougePG-like": Vampire Survivors-style auto-attack hordes, Crab
Champions-style map/route choices, and Death Must Die-style difficulty modifiers.

## 2. Pillars

1. **Every choice is a gamble you can read.** Route, curse, blessing and
   double-or-nothing choices always show the risk and the reward up front.
2. **Upgrades must feel big.** No "+1% damage to frozen enemies at long range".
   Every upgrade visibly changes how your hero plays (brainstorm, Harrison).
3. **Co-op first, solo-friendly.** Shared blessings and revives make teammates
   matter, but a solo player can still finish a run.
4. **Silly, readable, mobile-friendly.** Big shapes, bright cheese colors and
   jokes (a boss is literally "My Grandma"). Every system has to work on a phone.
5. **No physics-driven gameplay** (brainstorm, Topic 4). Enemies and projectiles
   are simulated as maths on the server. Physics is for decoration only.

## 3. Core loop

```
Lobby ──► pick class ──► ready up ──► RUN
RUN  = Cycle 1 (4 stages) → Cycle 2 (4 stages) → … until wipe or "Go Home"
STAGE = Route vote → Survive waves (~2:30) → Boss → Blessing + loot → Continue / Double-or-Nothing vote
After the 4th stage of a cycle: Go Home (bank 100%) or start the next cycle (harder, bigger rewards)
Results screen ──► Cheese + XP saved to profile ──► spend in lobby (classes, talents, cosmetics)
```

### 3.1 Route choice (merges brainstorm Topics 5, 6 and Gianclaudio's round flow)

At the start of every stage the party votes on one of **3 route cards**:

| Card | Map | Boss | Curse (downside) | Blessing (granted after boss) | Reward mult |
|---|---|---|---|---|---|
| Low (green) | random from cycle pool | random | none on Stage 1; else a mild curse for **this stage only** | small | ×1.0 |
| Mid (yellow) | random | random | medium curse for **this stage only** | medium | ×1.5 |
| High (red) | random | random | strong curse that lasts **the whole run** | big | ×2.0, plus a small chance of an **Epic** boss drop |

- **Stage 1 of a run** shows 3 *maps* instead (brainstorm: "Select Map ~ 3 options").
  There is no curse, the blessing is small, and the boss is random.
- **High-tier cleanse:** a High card may come with "Cleanse": picking it removes
  one active run-long curse (brainstorm, Topic 6).
- Votes run for 15 s. Ties are broken at random. If nobody votes, the server picks Low.

### 3.2 Cycles and maps

- 9 maps (§6). A cycle holds 4 stages, and maps **never repeat inside a cycle**.
  They can repeat across cycles (brainstorm, Harrison).
- Every new cycle adds +1 difficulty level (enemy HP, damage, density).
- Maps are hand-designed layouts. The randomness comes from **POI slots**: each
  map has 8–12 slots, and each run fills them at random from that map's POI table
  (shrines, cheese caches, elite camps). Some POIs are rare, so players discover
  them over many runs (brainstorm).
- Portals mean any map can follow any other (brainstorm summary).

### 3.3 Stage flow

1. **Waves (150 s):** mice spawn in rings around the party, and density ramps up
   over time. Elite mice appear from stage 2. Enemies drop **crumbs**, and
   picking them up gives XP.
2. **Level up:** each player picks 1 of 3 upgrades (§5). The game does not pause
   (co-op). Choices wait in a queue on screen, and the player can keep moving.
3. **Boss:** spawns at the map's centre with a 3 s telegraph. The boss has a
   health bar, telegraphed attacks and phases at 50% HP.
4. **Victory:** the route's blessing is applied to the whole party for the rest of
   the run. A boss chest gives Cheese to every player, scaled by the reward mult.
   If the route was High, there is a chance of an Epic drop: a free cosmetic or a
   bonus upgrade.

### 3.4 Banking: Double or Nothing and Go Home

- **Pending cheese** builds up during a cycle. **Banked cheese** is safe.
- After stages 1–3 of a cycle the party votes:
  - **Continue:** next stage, normal rules.
  - **Double or Nothing:** the next stage's rewards ×2 **and** the pending pot ×1.5
    if the party wins. If the party wipes on that stage, the whole pending pot
    is lost.
- After stage 4 of a cycle: **Go Home** banks 100% of pending cheese and ends the
  run as a win. **Next Cycle** banks 50% now and carries the rest forward as
  pending. **[decision]**
- **Wipe (everyone downed):** the run ends. Banked cheese is kept. Players also
  keep 50% of pending cheese, or 0% if Double or Nothing was active.
- Cheese is soft currency only. **Robux are never staked or multiplied.** Double
  or Nothing touches earned in-game cheese only (Roblox policy, see monetization doc).

### 3.5 Downs and revives

- At 0 HP a player is **downed**: they crawl at 30% speed for 20 s. A teammate
  standing within 8 studs for 3 s revives them at 40% HP.
- If the timer expires, the player becomes a spectator until the stage ends, then
  respawns at 50% HP.
- **Second Wind:** every player has 1 self-revive per run. More can be bought or
  earned (see monetization), capped at **1 per stage** so that money can't carry
  a run.

### 3.6 Bot teammates (party fill)

- Every run has at least **3 heroes**: if fewer real players are in the server
  when the countdown starts, **bot elephants** fill the empty slots. Bots never
  take the 4th slot away from a real player. When a real player joins, the next
  lobby drops one bot.
- Bots are **clearly labelled** in every place they appear: a 🤖 tag in their
  name, the party frames and the lobby list. Roblox policy forbids passing bots
  off as real users.
- Bots ready up instantly. They pick classes that fill missing roles (tank,
  ranged, support), vote with the majority (or pick at random when there are no
  human votes), and take the highest-rarity upgrade. In combat they kite mice,
  stay near the humans, revive downed teammates and use their ability on
  clusters.
- Balance: a bot counts as **0.6 of a player** for difficulty scaling, earns no
  rewards and never holds a run open. If every human leaves, the run ends.
- A solo player can still play alone by turning off "Bot teammates" in the
  lobby.

### 3.7 Pressure (pre-run difficulty modifiers)

Brainstorm, Topic 3: Death Must Die's "Outer Circle" screen. After you beat a
map you can stack modifiers on it for more difficulty and more reward. We take
the idea, not the content.

- **Unlock:** your first **Go Home** win unlocks the Pressure board in the lobby.
- **Board:** 8 modifiers, each with 1–3 ranks. Each rank adds Pressure points.

  | Modifier | Effect per rank | Max |
  |---|---|---|
  | Stampede | elite mice +30% move speed | 3 |
  | Big Cheese | elites +25% size and area | 2 |
  | Rush Hour | +20% spawn rate in the last 60 s of waves | 3 |
  | Slingshot Season | ranged mice +1 projectile | 2 |
  | Hot Crumbs | enemy projectiles +20% speed | 3 |
  | Boss Fury | bosses +20% damage | 3 |
  | Thick Rind | all enemies +15% HP | 3 |
  | No Snacks | −25% healing | 2 |
- **Rewards:** each Pressure point gives **+8% cheese**, **+0.05 luck** (better
  upgrade rarity) and +2% Epic-drop chance.
- **Voting:** the party's Pressure is chosen by the **party leader** (first human
  to ready up). It is shown to everyone before the countdown, and bots accept it.
- **Leaderboards** record deepest cycle at each Pressure level. Your highest
  Pressure cleared is saved to your profile and unlocks title badges at 5, 10
  and 20.
- Pressure is free to use and can never be bought.

### 3.8 Points of interest (POIs)

Brainstorm, Harrison: maps are hand-designed, but POIs spawn at random into
fixed slots. Some POIs are rare, so players discover them over many runs.

| POI | Rarity | Interaction |
|---|---|---|
| Cheese Cache | common | Stand on it for 3 s: +pending cheese (scaled by stage) |
| Shrine of Swiftness / Might / Mending | common | Touch: whole party gets +25% move speed, +25% damage, or heals 30% for 45 s (one use) |
| Elite Camp | uncommon | Spawns an elite pack. Clearing it opens a chest with a free upgrade pick for everyone |
| Crumb Fountain | uncommon | A burst of XP crumbs |
| Mousetrap Field | uncommon | Hazard: traps that also snap mice. Lure enemies in |
| **Grandma's Pantry** | rare (3%) | Pick 1 of 3 Epic upgrades. Discovering it unlocks a cosmetic |
| **Lost Herd Statue** | rare (2%) | Revives every downed hero and refills Second Wind. Discovering it unlocks a title |

POIs activate only during Waves, and every interaction runs on the server.
Discovered rare POIs are saved to the profile (`discoveries`).

### 3.9 Portals between stages

After a boss falls, a **Rind Gate portal** opens at the arena centre. During
the bank/cycle vote it shows the next route's map colour. When the vote ends,
heroes are pulled into the portal with a 1.5 s swirl and a fade, and the next
arena loads behind the fade. Any map can lead to any map (brainstorm summary).

## 4. Classes (7 elephants)

Each class has an **auto-weapon** (fires on its own), an **ability** (cooldown,
aimed at the cursor or the joystick direction, auto-aims on mobile) and a
**passive**. Unlocks: 3 free, 4 bought with Cheese.

| Class | Fantasy | Auto-weapon | Ability | Passive | Unlock |
|---|---|---|---|---|---|
| **Elephante** | Brawler | Trunk Slam: melee arc | Stampede: dash that knocks enemies back | +25% max HP | free |
| **Ele Fonte** | Water mage (fountain) | Water Jet: piercing bolt | Geyser: AoE burst at the target | Pierce +1 | free |
| **Ellie Fawn** | Ranger/druid | Peanut Volley: 3 spread shots | Thorn Ring: ring of damage | +15% move speed | free |
| **Le F'ante** | French duelist | Rapier: fast thrusts in a cone | Riposte: brief invulnerability plus a counter-burst | +15% crit chance | 2,500 🧀 |
| **Filet** | Chef | Orbiting cleavers | Sizzle: fire puddle | Crumbs heal 1 HP | 2,500 🧀 |
| **Jumbo** | Flyer | Ear Gust: cone with knockback | Updraft: hover that makes you immune to contact damage for 2 s | +30% pickup radius | 4,000 🧀 |
| **Fizzante** | Fizzy alchemist | Fizz Bomb: lobbed AoE | Soda Geyser: big slow field | +20% area | 4,000 🧀 |

## 5. Upgrades (in-run)

- Each level-up offers 3 cards drawn by rarity: Common 60%, Rare 30%, Epic 9%,
  Legendary 1%. **Luck** shifts these weights.
- Each card is a big, visible change. Examples: +1 projectile; +40% area; −25%
  cooldown; attacks chain to 2 more enemies; kills explode; +50% max HP and
  heal to full; a second orbiting weapon.
- **Reroll:** 1 free reroll per stage. More rerolls are a soft-currency or Robux
  convenience item (capped).
- **Blessings** come from routes and apply to the whole party. **Curses** apply to
  enemies or the world. See `src/shared/Config/Modifiers.luau`.

## 6. Maps (9) and bosses (13)

Maps (cheese theme in brackets): Plains/Highlands (Swiss), Forest (Gouda), Jungle
(Pepper Jack), Beach/Islands (sand is Parmesan), Tundra (Blue), Volcano
(Cheddar), Toxic Swamp (Moldy), Space Moon (Mozzarella), Deep Ocean (Feta-in-brine).

Bosses: Giant Tree, Froggus (big-bellied brawler frog), Serpent Sisters (3 bodies), My
Grandma, Floating Witch (rotating random spells — the "gamba fight"), Corndog
Bunny, Spider Machine, Green Gorilla, Paper Dinosaur, Dark Hematite Snake, Ancient
Ice Dragon, Void Cat, **Zoomzola the Swift Cheese**.

**IP-safe renames [decision, per market research]:** Dumbo → Jumbo, Fanta → Fizzante,
Frogas → Froggus, Speedy Gonzalez → Zoomzola the Swift Cheese, a rolling wheel of
gorgonzola rather than a mouse (Disney / Coca-Cola / Riot /
WB names). The other brainstorm names are kept.

**Launch subset (market research §4):** the full roster is data-driven and all of
it ships in code. Marketing should lead with 3 starter classes, 1 full cycle of
4 maps and 5 headline bosses, and drip-feed the rest as live-ops "new" content.

Every boss is built from a shared **attack-pattern library**: charge, radial
burst, aimed volley, slam (circle telegraph), summon minions, spiral, line sweep
and random-spell roulette. Each boss picks 3–5 patterns plus one 50% HP phase change.

## 7. Enemies (the mice)

Mouse (chaser), Rat Runner (fast, fragile), Chonk (tank), Crumb Slinger (ranged),
Fuse Mouse (explodes after a 1 s telegraph), Elite variants (tinted, 3× HP, drop
more crumbs). Stats live in `src/shared/Config/Enemies.luau`.

## 8. Meta progression (between runs)

- **Cheese 🧀** (soft currency): unlock classes, Talent upgrades (small,
  permanent), and cosmetics (trails, hats, colour tints).
- **Account level** from XP: unlocks a cosmetic every 5 levels and gives a
  title badge.
- **Daily streak:** login reward that grows over 7 days.
- **Leaderboards:** deepest cycle reached and fastest Cycle-1 clear.

## 9. Monetization (summary — details in `docs/MONETIZATION.md`)

Cosmetic-first and convenience-second. Nothing sold is a random item.
Purchases never make an opponent weaker, and since there is no PvP, no purchase
can hurt another player. Party-wide boosts are designed to be *social* (the buyer
is thanked by name).

## 10. Session targets

- One stage (waves + boss): 4–6 min. Cycle 1: about 20–25 min. The free Go Home
  exit at cycle end makes stopping on mobile painless. The first 60 s from joining to the first
  kill is a hard requirement.
- Max server size 4 (one party per server). Matchmaking and lobby hub places
  are a later milestone.
