# Iteration 1: Original-concept review

Team: Original concept (ITERATIONS.md step 1). Read-only on `src/`.

Sources compared:
- concept: `docs/brainstorm-2026-06.md`, `docs/GDD.md`, `docs/GDD-v2.md`, `docs/LORE.md` and `docs/STYLE.md`;
- plans and research: `docs/V4-PLAN.md`, `docs/V5-PLAN.md` and `docs/research/*.md`;
- code: `src/shared/{Config,Run,Combat}`, `src/shared/Bots/BotBrain.luau`, `src/server/Services/*`, `src/server/Visuals/*`, `src/client/{UI,Controllers,Visuals}`.

What I ran (all output is in `/tmp/claude-0/-home-user/62ecd08e-82c1-5cab-a26b-5e0b2b23913e/scratchpad/iter1-concept/`):
- **Preview renders** of the current tree: `scripts/render-preview.luau` plus `render-preview.py`, written to `png/*.png`. The committed `assets/previews` date from 2026-11-16, before v4 G.
- **A route-choice sim**, `routes.luau`: Headless, 16 seeds, solo stand-in plus 11 bots, all 7 classes rotated.

Owner hints use the V4-PLAN team split: M1 Combat, M2 Match flow, P Progression, U UI, G Graphics and audio.

## Summary: the biggest gaps

The game has every *system* from the brainstorm. The *moments* that make the concept fun are mostly missing or invisible:

1. **The Low/Mid/High gamble almost never happens.** Bots pick Low, and the boss winner (usually a bot squad) picks the route.
2. **The fun and the personality are hidden:**
   - the route and Double-or-Nothing cards start folded;
   - there is no Bookie, no Mouse King and no lore;
   - there are no barks and no boss intro.
3. **Maps differ only in looks**, and the elephant fantasy is weak:
   - players look like grey block avatars with a hood;
   - there is no hero body animation, no stomp and no trumpet.
4. **Audio and boss animation are far below STYLE.md:**
   - there is no music;
   - bosses have one shared pose set.

---

## A. Concept promises missing, half-built, or drifted

### C-1 Route cards: Mid/High tiers almost never get picked
- **Type:** balance / feature. **Owner:** M2 (BotBrain is M1's file).
- **Evidence:**
  - **Concept:**
    - brainstorm Topic 5: *"One option will be low reward, low penalty. One will be Mid and the other high."*
    - GDD pillar 1: *"Every choice is a gamble you can read."*
    - The showcase blessings (+1 Projectile, Jumbo Abilities, Hyper Cooldown, Explosive Party) are all **High** (`Config/Modifiers.luau` 249–291).
  - **Code:**
    - `Bots/BotBrain.luau` 1222–1229: `safeOption("route")` returns the **Low** card.
    - BotBrain 1305–1307 and `VOTE_SURPRISE = 0.15` (line 157): with no human vote, a bot picks Low 85% of the time and Mid 15%, never High.
    - `RunDirector.luau` 2636–2643: no boss winner means the Low card.
  - **Sim** (`routes.luau`, 16 seeds): 18 stage clears.
    - Tiers played: **Low 17, Mid 1, High 0.**
    - The human's squad chose the route in **4 of 18** clears (22%), all in a single seed.
- **Impact:** H. **Effort:** S.
- **Proposed change:**
  - **Give bot squads a tier policy that reads their state:**
    - stage 1–2 healthy: about 50% Low, 35% Mid, 15% High;
    - when the squad trails on pot, prefer High (a comeback gamble);
    - when low on HP, prefer Low.
  - **Never default to Low silently:** with no vote, pick at random weighted toward Mid.
  - **Add a sim guard:** at least 30% of cleared stages are Mid or High, and at least 8% are High.

### C-2 Only the boss-winning squad votes on the route and gets its blessing
- **Type:** feature. **Owner:** M2 + U.
- **Evidence:**
  - **Concept:**
    - brainstorm Topic 5: *"a buff for the **entire group** that lasts the rest of the run"*;
    - GDD §3.1: *"the party votes on one of 3 route cards"*.
  - **Code:**
    - `Run/MatchState.luau` 1148–1160: after stage 1 the blessing goes to `chooserSquad` only.
    - 1212–1218: only the winner chooses.
    - `RunDirector.runRouteChoice` 2627–2630: VoteOpen goes only to the winner's humans; everyone else sees "<Squad> is choosing the route…" (VoteUI 693–712).
    - With C-1's 22%, a typical human plays a whole match with **one** blessing (the stage-1 Low one) and never makes a route decision.
- **Impact:** H. **Effort:** M.
- **Proposed change:** split the route card.
  - **Shared world part:** the winner chooses the map, boss and curse, as now.
  - **Blessing draft:** every squad still in the run picks 1 of 3 blessings, Low, Mid or High.
    - A Mid or High blessing comes with a **squad-only hex** for the next stage (for example −20% max HP, or +25% mice targeting you). This keeps the brainstorm's risk-for-reward on every squad.
  - **The winner's perk:** it chooses the world, and it gets a free blessing reroll or +1 blessing tier.
  - **UI:** a 3-card draft during the Rind Gate window, opened (not folded) for every squad.

### C-3 The first map is never chosen
- **Type:** feature / UX. **Owner:** M2 + U.
- **Evidence:**
  - **Concept:**
    - brainstorm (Gianclaudio), Round I: *"Select Map/Terrain ~ 3 Options"*;
    - GDD §3.1: *"Stage 1 of a run shows 3 maps instead."*
  - **Code:**
    - `RunDirector.luau` 4736: `c.match:begin()` is called with no index.
    - `MatchState.begin` 998–1009: *"default: a seeded random one. Nobody chooses the first route."*
    - `VoteUI.luau` 415–418 still has a dead `"Pick your first map!"` title.
- **Impact:** M. **Effort:** S.
- **Proposed change:**
  - Show the 3 stage-1 Low cards (map, boss and blessing) on the lobby board during the countdown, and let humans vote; the plurality wins, bots abstain, and no time is added.
  - This also gives the lobby a "what's next" hook.

### C-4 Cycles and "go deeper" were dropped: a run is one 4-stage cycle
- **Type:** feature. **Owner:** M2 (lead decision).
- **Evidence:**
  - **Concept:**
    - brainstorm (Harrison): *"Runs contain cycles… after beating a cycle, a new cycle begins with 4 random maps."*
    - LORE: *"Every cycle pushes deeper into the Rind Gate."*
  - **Code:**
    - `MatchState.CONFIG.STAGES = STAGES_PER_CYCLE` ("4: one cycle per run", MatchState 242);
    - `RunDirector.luau` 1784 hard-codes `cycle = 1`;
    - GDD-v2 §8 calls deeper runs "a later live-ops option".
  - Veterans have no long-run mode, and `bestStage` caps at 4.
- **Impact:** M (veteran retention). **Effort:** L.
- **Proposed change:** "Go Deeper".
  - Squads still in at the stage-4 clear may vote **Deeper** instead of auto-extracting:
    - a 2-stage "Rind Depths" mini-cycle;
    - harder (cycle 2 difficulty), ×1.5 rewards;
    - co-op against the world, with no new Rival Herds;
    - ends with a Mouse King finale (C-15).
  - Losing there keeps 50% of the pot (the v1 wipe rule).
  - Feed `bestStage` up to 6, plus a "Deepest Herd" board.

### C-5 The core decisions start folded into a slim bar on PC
- **Type:** UX. **Owner:** U.
- **Evidence:**
  - **Concept:** GDD pillar 1, *"route, curse, blessing and double-or-nothing choices always show the risk and the reward up front."*
  - **Code:**
    - `VoteUI.luau` 11–13: *"On PC the vote STARTS minimised as a slim bar… full details in each card's tooltip"*.
    - `ExtractUI.luau` 15–18: the same for Extract, Stay and Double or Nothing.
    - Curse and blessing descriptions live only in tooltips (VoteUI 197–216).
- **Impact:** H. **Effort:** S.
- **Proposed change:**
  - Open both panels at full size with inline curse and blessing text for the first 4 s, or until the player votes, then fold.
  - Pulse the gate while unvoted.
  - Keep the fold for PvP safety after the vote.
  - This is also the moment to give the cards real art: a tier frame, a map thumbnail colour and the boss's silhouette icon.

### C-6 The Cheese Bookie, Double or Nothing's character, does not exist
- **Type:** feature (humour). **Owner:** U + G.
- **Evidence:**
  - **Concept:** LORE: *"The Cheese Bookie, a suspicious rat in a visor, offers to double your haul if you dare one more portal."*
  - **Code:**
    - `grep -ri bookie src` finds nothing;
    - `ExtractUI.luau` 79–94: a plain card with "Cheese only, never Robux";
    - the result is a toast only (RunDirector "DOUBLE!" / "NOTHING!").
- **Impact:** M. **Effort:** S–M.
- **Proposed change:**
  - **At the Rind Gate:** a part-built Bookie rat (visor, ledger) appears during the Extract window.
  - **On the DoN card:** his portrait and a rotating quip ("Double it? I've got a *good* feeling about you…").
  - **On the outcome:** a reaction ("Pleasure doing business!" or he tips his visor and pockets the pot).
  - Cheese only; no Robux anywhere near it.

### C-7 The lore is absent from the game
- **Type:** feature (humour). **Owner:** P (config fields) + U.
- **Evidence:**
  - `grep -ri "mouse king|squeakeasy|fromagia|nibble horde|insistent|hydration" src` finds 0 hits.
  - None of these reach the player:
    - the boss hooks ("Her slipper has range");
    - the class one-liners ("Speaks only in proverbs about hydration");
    - the premise.
  - The boss bar shows only the name and title (`HudUI.luau` 951–960), and the Mousepedia shows names only (`ProgressUI.luau` 490–520).
- **Impact:** M. **Effort:** S.
- **Proposed change:**
  - Add a `lore` string to Bosses, Classes, Champions and Maps (copied from LORE.md).
  - Show it on the boss intro (C-8), the Mousepedia (C-22), the class picker and portal-fade tips.
  - Add one premise screen on the very first join (3 lines and a picture).

### C-8 Boss arrival and boss kill have no ceremony
- **Type:** feature / graphics (juice). **Owner:** G + U.
- **Evidence:**
  - **Arrival:** `Juice.bossArrive` is a red pillar plus a "BOSS!" billboard (Juice.luau 6–7, 144); there is no name card.
  - **Kill:** a stack of toasts (`RunDirector.luau` ~4560–4615):
    - Stage cleared, Boss chest, EPIC drop!, Blessing, DOUBLE!/NOTHING!;
    - all of them compete in the toast column.
  - There is no physical chest: GDD §3.3 says *"A boss chest gives Cheese"*.
  - There is no hit-stop or slow-mo anywhere (grep `hitstop|TimeScale` finds nothing).
- **Impact:** H (game feel, clip-ability). **Effort:** M.
- **Proposed change:**
  - **Intro card (2.5 s, client):** boss portrait (ViewportFrame of BossModels), name, title, lore hook and a "Watch for: <signature attack>" hint.
  - **Kill beat:**
    - 0.4 s slow-mo plus a camera punch on the killing blow;
    - the boss collapses, and a part-built chest drops at the winner and bursts into cheese;
    - one centred "STAGE CLEAR" banner summarises cheese, blessing and Epic;
    - the DoN result plays as its own card (C-6).
  - **Hit-stop:** 60 ms on crits against champions and bosses.

### C-9 Bosses have no signature loot, and there is no reward choice
- **Type:** feature. **Owner:** M1 (Gear config) + M2.
- **Evidence:**
  - **Concept:**
    - brainstorm (Gianclaudio): *"Select Reward ~ Map / Boss / Random"*;
    - Topic 6: *"Low chance to get an epic version of the drop."*
  - **Code:**
    - `Config/Gear.luau` (30 items) has no boss-specific items;
    - `grantChestGear` rolls by tier only.
  - As a result, bosses are not memorable as loot sources.
- **Impact:** M–H. **Effort:** M.
- **Proposed change:**
  - **13 boss trophy items, run-only:**
    - My Grandma's Slipper (weapon mod: a returning slipper throw);
    - Witch's Wheel (trinket: a random shrine buff every 20 s);
    - Froggus Belly (armor: knockback on contact);
    - Paper Crown (−50% damage from the next hit every 15 s), and so on.
  - An **Epic version** drops on the Epic roll.
  - **The boss chest asks the winner to pick 1 of 3:** Map relic (a map-themed item), Boss trophy, or Mystery (a random rarity +1). Earned, never paid.
  - Add a Mousepedia "Trophies" page.

### C-10 The Floating Witch's "gamba wheel" is only floating text
- **Type:** graphics / feature. **Owner:** G.
- **Evidence:**
  - **Concept:** brainstorm, *"Floating Witch (Rotating spells, gamba fight)"*; LORE, *"Spins a wheel of spells every phase"*.
  - **Code:**
    - the server already emits `{t="roulette", spell, options, reveal}` (`BossPatterns.luau` 1643–1654);
    - the client shows only a damage-number style "🎲 spell name" (`FxController.luau` 3326–3335).
  - In the render (`png/bosses.png`) her model has no wheel players can read.
- **Impact:** M. **Effort:** S.
- **Proposed change:**
  - Draw a segmented wheel above her: one slice per `options` entry, with the spell icon and colour.
  - Spin it, ease it out over `reveal`, then tick-tick-land with a sound.
  - The "lucky dud" slice pops confetti.
  - This doubles as a readable telegraph of the spell that is coming.

### C-11 Maps play identically: hazards and features are visual only
- **Type:** feature. **Owner:** M1 (World) + G.
- **Evidence:**
  - **Concept:**
    - brainstorm (Harrison): *"pre-designed map with natural obstacles (rocks, trees, waterfalls, cliffsides)"*;
    - summary: moving between zones should "feel like an impactful choice".
  - **Code:**
    - `Visuals/Signatures.luau` 11–14: *"Every feature is WALKABLE… invisible to the 2-D combat sim"*;
    - the lava and ice rivers in `Visuals/Regions.luau` are visual strips;
    - maps differ only in POI weights and enemy pool (`Config/Maps.luau` 74–200).
  - So picking Volcano over Plains changes nothing you play.
- **Impact:** H. **Effort:** M.
- **Proposed change:** one light, telegraphed, pure-maths rule per map, held as data in `Maps.def.hazard` and applied in World to mice too.

  | Map | Rule |
  |---|---|
  | volcano | fissure DoT strips |
  | tundra | ice patches: ×1.3 speed, and mice slide on knockback |
  | swamp | bog: ×0.75 speed |
  | moon | knockback ×1.5, dash +40% |
  | ocean | current lane pushes along the river |
  | beach | tide pools heal 1%/s |
  | forest | canopy: hidden from the enemy minimap |
  | jungle | vine snares (rooted 0.5 s) |
  | plains | windmill gust rings |

  - Mice obey the same rule, so luring them is a tactic.
  - Show the rule on the route card ("🌋 Lava fissures").

### C-12 Bosses have no home map
- **Type:** feature (flavour). **Owner:** M2 / M1.
- **Evidence:**
  - LORE: *"Ancient Ice Dragon: has guarded the Blue Cheese Tundra…"*;
  - `Bosses.luau` 79 gives the Giant Tree the title "Elder of the Gouda Grove";
  - but `RunState._rollCards` 314–318 picks maps and bosses independently, so the Ice Dragon fights on the volcano.
- **Impact:** L–M. **Effort:** S.
- **Proposed change:**
  - Add `Bosses.home`.
  - When the cards roll, pair about 50% of boss and map combos with the boss's home map.
  - A home-turf fight shows a "Home turf!" tag and gives +10% cheese.

### C-13 Mice variety: no themed mice per map
- **Type:** feature / graphics. **Owner:** M1 (Enemies) + G (MouseModels).
- **Evidence:**
  - The same 5 types (plus Carrier) appear in all 9 worlds (`Config/Maps.luau` `enemyPool`).
  - `MouseModels` has no map or theme variation (grep `mapId|theme` finds 0).
  - The concept sells cheese-themed *worlds*, and the mice are the main thing on screen.
- **Impact:** M. **Effort:** M.
- **Proposed change:**
  - **Map dress (G):** 1–3 parts on the head bone per map: astronaut bubble on the moon, snorkel in the ocean, scarf and earmuffs in the tundra, leaf hat in the jungle, hard hat on the volcano.
  - **Signature mice (M1):** 1 per map using existing behaviours: Snowball Roller (tundra, a fast charge), Lava Hopper (volcano), Bubble Mouse (ocean, slows), Moon Bouncer (moon, leaps).

### C-14 No character barks or speech
- **Type:** feature (humour). **Owner:** G / U.
- **Evidence:**
  - **Concept:** GDD pillar 4, *"Silly… jokes (a boss is literally 'My Grandma')"*; the LORE hooks.
  - **Code:** grep finds no speech, bark or quip system; bosses, champions, bots and mice never "say" anything.
- **Impact:** M. **Effort:** S.
- **Proposed change:** authored, localisable speech bubbles (BillboardGui, rate-limited, at most 1 on screen per source type).
  - **Boss:** an intro line and a phase-2 line (Grandma: "You look thin. EAT." Froggus: "Belly first, questions never!").
  - **Champion:** a spawn line.
  - **Bot cadets:** "For the Herd!" on a revive.
  - **Mice:** "Eek!" when fleeing.
  - **Players:** quick-chat lines reuse the same bubble.

### C-15 The Mouse King never appears
- **Type:** feature (narrative). **Owner:** G + M2.
- **Evidence:**
  - **Concept:** LORE premise, *"the Mouse King, Squeakeasy the Grate… sent the Nibble Horde"*; the post-launch "Rind Palace".
  - **Code:** the final stage is a random boss × `FINAL_HP_MULT` 2.5 (`Bosses.luau` 55) with no story framing.
- **Impact:** M. **Effort:** M.
- **Proposed change:**
  - **At stage starts:** a Mouse King hologram taunt, 3 s over the portal ("Your cheese is MINE, trunk-faces!").
  - **Final stage:** presented as "The Mouse King's champion".
  - **Later (with C-4):** the Mouse King himself as the Rind Depths finale, plus a seasonal event.

## B. The elephant fantasy

### C-16 Player heroes don't read as elephants; bots look better than players
- **Type:** graphics. **Owner:** G.
- **Evidence:**
  - **Concept:**
    - brainstorm *"Character Theme: Elephant vs Mice"*;
    - STYLE: *"an 'elephant suit' layered accessory per class is sold as a cosmetic and also given free to new players."*
  - **Code:**
    - `Visuals/ElephantHood.luau` builds ears and a trunk on the avatar head plus a grey BodyColors tint;
    - no suit exists (grep `suit` finds nothing).
  - **Renders:**
    - `png/heroes.png`: blocky grey R15 bodies with ears;
    - `png/bots.png`: cute, round part-built elephants.
  - The player, the main character, is the least on-brand model on screen.
- **Impact:** H. **Effort:** M.
- **Proposed change:** a free default **Herd Suit**.
  - Hide the avatar's body parts locally, and weld the BotModel elephant body (full size, not bot scale 0.65) to the HumanoidRootPart.
  - The avatar's face and hats stay optional on the head.
  - A settings toggle switches between "Suit" and "Avatar + hood".
  - Class skins and accessories apply to the suit (one family with the bots).
  - Bots keep the desaturation and 🤖 tag rule.

### C-17 The elephant verbs are missing: stomp, trumpet, and "afraid of mice"
- **Type:** feature / game feel. **Owner:** G (client Fx and sound).
- **Evidence:**
  - **Concept:**
    - market research: positioning *"Stomp the mouse horde"*;
    - the store thumbnail says "STOMP 1,000 MICE";
    - LORE: *"Elephants are famously afraid of mice."*
  - **Code:**
    - there is no stomp action or effect;
    - no trumpet sound exists (`Config/Sounds.luau` uses swordslash, uuhhh and electronicpingshort);
    - "Trunk Trumpet" exists only as a paid emote name.
- **Impact:** M. **Effort:** S.
- **Proposed change** (client-only, cosmetic):
  - **(a) Stomp:** every 4th melee hit, and the end of every dash or landing, plays a ground-pound shockwave with a camera thump.
  - **(b) Trumpet:** a trumpet blast on ability cast, revive and level-up.
  - **(c) The "eek" gag:** a jump-scare pose (squash plus ears flared) when a Fuse Mouse pops near you.

### C-18 Player heroes have no body animation for attacks, casts, hits or downs
- **Type:** animation. **Owner:** G.
- **Evidence:**
  - **Concept:** ITERATIONS standing goal, *"eased procedural animation with proper blending (idle, run, attack, hit react, death, ability windups)… anticipation on attacks."*
  - **Code:**
    - `Visuals/HeroFx.luau` 15–19: the player's attack only rotates the welded weapon's `GripWeld`; ranged classes recoil the prop;
    - `BotAnimator.cast` (rear up, ears flare) is used for **bots only** (`FxController.luau` 3375);
    - players get default Roblox walk and idle, and nothing for downed, revive or casts.
- **Impact:** H. **Effort:** M.
- **Proposed change:**
  - **Procedural R15 layer:** a client-local Motor6D `Transform` layer (the same maths style as `Visuals/Rig`), blended over the default animations.
  - **Poses:**
    - attack: wind-up, then swing with anticipation and follow-through;
    - cast: rear up with ears flared, matching the bots;
    - hit flinch;
    - downed: a crawl pose;
    - revive: a get-up.
  - **Secondary motion:** ear flap on sprint; trunk sway on the hood segments.
  - **Shared:** the same layer drives the Herd Suit (C-16).

### C-19 Upgrades never change how the hero looks
- **Type:** graphics. **Owner:** G (+ M1 exposes the stat totals).
- **Evidence:**
  - **Concept:**
    - GDD pillar 2: *"Every upgrade visibly changes how your hero plays"*;
    - the cards themselves promise size: "Giant Elephant: Double area", "Mammoth: Triple max HP", "Fortress" (`Config/Upgrades.luau` 214–420).
  - **Code:** there is no visual hook (grep `ScaleTo|heroScale` finds only the enemy renderer).
  - A level-20 build looks the same as level 1, which is the Vampire Survivors / Crab Champions payoff lost.
- **Impact:** M. **Effort:** M.
- **Proposed change:** a "build look" from the player's stats.
  - **Size:** +5% scale per size-type card (capped at ×1.3, visual only; the hitbox is unchanged).
  - **Aura:** tinted by the rarest card owned.
  - **Armor:** rind plates appear for armor.
  - **Elements:** orbiting peanuts, and lightning crackle for chain builds.

## C. Built but invisible or confusing

### C-20 The "practice yard" is promised but doesn't exist
- **Type:** UX / bug. **Owner:** M2 + G.
- **Evidence:**
  - `RunDirector.luau` 3896–3899 sets the attribute `PracticeYard` and toasts *"warm up in the practice yard until the next one!"*.
  - Nothing reads that attribute: no client code, `LobbyWorld` or `LobbyService` (grep).
  - Research §4.1 also specified a **Training Yard** for rookies.
- **Impact:** M. **Effort:** M (S just to fix the text).
- **Proposed change:**
  - **Build the yard:** a lobby pen with client-side dummy mice. Run a local `World` with the player's class, or simpler, targets that pop into crumbs; it should exercise the attack, the ability and crumbs.
  - **Use it for:** late joiners, rookies during the countdown, and players who are out of the match.
  - **Until it exists:** change the toast.

### C-21 No spectating while dead
- **Type:** UX. **Owner:** U (CameraController).
- **Evidence:**
  - `CameraController.luau` 126–145 always follows your own character.
  - A dead hero waits 20–35 s for Herd Call (`MatchState.CONFIG.REDEPLOY_DELAYS`), or the rest of the stage, looking at an empty spot.
  - GDD-v2 §2 says *"Dead heroes spectate their squad"*; research #15.
- **Impact:** M. **Effort:** S.
- **Proposed change:**
  - On death, follow the nearest standing squadmate, with "Spectating <name> · back in 23 s" and tap/Q to cycle.
  - Flash the timer when teammates cut it (champion kill −3 s).

### C-22 The Mousepedia is a list of names; discoveries are invisible
- **Type:** UX / feature. **Owner:** U (+ P for the lore field).
- **Evidence:**
  - `ProgressUI.luau` 490–520 renders page chips and entry names only.
  - Rare finds (landmarks, Grandma's Pantry, Lost Herd Statue) are saved in `profile.discoveries` but show only a one-time banner (`HudUI.luau` 1083–1086).
  - **Concept (brainstorm):** *"Some pathways or areas may have unique POIs - may take a few runs to see them all."*
- **Impact:** M. **Effort:** M.
- **Proposed change:**
  - **Entry card:**
    - a ViewportFrame model, reusing the BossModels, MouseModels and ChampionModels specs;
    - the lore line (C-7);
    - "defeated ×N" and first seen;
    - black silhouettes for entries not yet found.
  - **New page "Secrets & Landmarks":** the 9 landmarks plus the 2 global rares, with a hint for each unfound one ("Found on Mozzarella Moon…").

### C-23 Stale Double-or-Nothing text in VoteUI
- **Type:** bug (copy). **Owner:** U.
- **Evidence:** `VoteUI.luau` 65–75 `BANK_TEXT.DoubleOrNothing` says *"pending pot ×1.5 if you win… If the party wipes, ALL pending cheese is lost"*. The v4 rule is a true ×2 that pays only with a champion or boss kill (MatchState 237–239). The `bank` and `cycle` vote kinds are the v1 path, but the text ships.
- **Impact:** L. **Effort:** S.
- **Proposed change:** update the text to the v4 rule or delete the v1 bank and cycle branches. Add a spec that the DoN copy in VoteUI and ExtractUI matches `MatchState.CONFIG.DON_POT_MULT`.

## D. Core loop, retention and Roblox conventions

### C-24 "Share" is only a game invite; no social rewards
- **Type:** feature. **Owner:** U + P.
- **Evidence:**
  - `ResultsUI.luau` 405–423: "📣 Share" calls `SocialService:PromptGameInvite`.
  - There is no `CaptureService` share card, no party bonus and no referral reward (grep `referral|partyBonus|Capture` finds nothing).
  - Research v4-features #7–#8: friend sessions run 1.9× longer, and Roblox scores co-play days.
- **Impact:** M. **Effort:** S–M.
- **Proposed change:**
  - **Share card:** `CaptureService` capture of the MVP / Herd Awards card ("Stomped 1,284 mice as Filet · Last Herd Standing"), shared with `PromptShareCapture`.
  - **Party bonus:** +10% pass XP per Roblox friend in your squad (capped at +20%).
  - **Referral:** a one-time Friend Referral reward (a cosmetic).
  - **"Squad up again":** on the Results screen, for non-friends.

### C-25 No weekly live-ops hook
- **Type:** feature. **Owner:** M2 + P + U.
- **Evidence:**
  - market.md §4: *"Weekly on the same weekday: a rotating 'Cheese of the Week' mutator, a featured boss"*;
  - v4-features #11;
  - nothing in `Config/*` (grep `mutator|weekly event` finds 0).
  - Contracts exist, but nothing changes the game week to week.
- **Impact:** M–H. **Effort:** M.
- **Proposed change:**
  - **Weekly rule:** a pure `Config/Weekly.luau` keyed by week number (server time).
  - **It applies:**
    - one world modifier (reuse a Modifier, a curse or a C-11 hazard, e.g. "Hailstorm Week: Cheese Hail on every stage, +25% cheese");
    - a featured boss (+50% Mousepedia XP);
    - a weekly contract tied to it.
  - **Lobby board:** shows "This week: …".
  - **Fairness:** free, and the same for everyone.

### C-26 Audio is almost absent: no music, and placeholder effects
- **Type:** graphics (audio). **Owner:** G.
- **Evidence:**
  - **STYLE:** *"bouncy brass and woodwinds. Mice squeak in a pitch-shifted chorus, boss themes add a kazoo layer… Every telegraph has a distinct wind-up sound."*
  - **Code (`Config/Sounds.luau`):**
    - 185–187: `musicLobby`, `musicRun` and `musicBoss` are all `id = ""`;
    - boss arrival and phase use `uuhhh.mp3` pitched down;
    - every telegraph, pickup, POI, storm and win sound is `electronicpingshort.wav`;
    - there are no squeaks and no trumpet.
- **Impact:** H (feel; most kids play with sound on). **Effort:** S–M (asset sourcing).
- **Proposed change:**
  - **Music:** licensed creator-Roblox Toolbox audio (or uploaded and verified) for 3 beds plus a kazoo boss sting.
  - **Effects:** a squeak pack (pitch-varied, capped per second) and a trumpet.
  - **Telegraphs:** a sound per pattern base: slam thud, charge whoosh, volley click, summon squeak-horn.
  - **Cheese:** a cheese "squish" for crumbs.

## E. Graphics and animation versus STYLE.md

### C-27 The map close to the gameplay camera is nearly empty
- **Type:** graphics. **Owner:** G.
- **Evidence:**
  - **Current renders:**
    - `png/map_forest.png` (gameplay camera): flat grass, one bush, path pixels;
    - `png/map_volcano.png`: a flat red plane.
  - **Caveat:** client `GroundScatter` is not in the preview, so verify with a Studio screenshot.
  - **STYLE pillar:** *"saturated cheese colours"*; ITERATIONS: *"environment detail"*. The overviews look rich, but the play view, where the player spends 100% of the time, does not.
- **Impact:** H. **Effort:** M.
- **Proposed change:**
  - **Density where the camera looks:** clustered prop vignettes (3–6 parts) around each POI and along paths; ground decals and terrain colour noise; small terrain dishes and bumps every ~25 studs.
  - **Client-streamed:** detail within about 90 studs of the camera, pooled by the existing DetailLevel tiers.
  - **Preview:** add a "gameplay camera + GroundScatter" panel to render-preview so the review loop sees it.

### C-28 The cheese-world identity is weak
- **Type:** graphics. **Owner:** G.
- **Evidence:**
  - **Brainstorm:** *"Beach / Islands (Sand is Parmesan Cheese)", "Tundra (Blue Cheese)", "Volcano (Cheddar Cheese)", "Toxic Swamp (Moldy Cheese)", "Space Moon (Mozzarella Cheese)."*
  - **Code:**
    - cheese appears mostly as the `cheese_wheel` landmark (`Regions.luau` 64–114, 841);
    - forest and jungle grounds are plain grass;
    - `GroundScatter.luau` has 0 cheese references.
  - The worlds read as generic biomes.
- **Impact:** M–H. **Effort:** M.
- **Proposed change:** one recurring cheese motif per map in ground paint and scatter.

  | Map | Motif |
  |---|---|
  | plains | Swiss-hole craters |
  | forest | Gouda-wax red rocks |
  | jungle | pepper-fleck gravel |
  | beach | Parmesan grain sand mounds |
  | tundra | blue-vein marbling on ice |
  | volcano | cheddar crust on lava edges |
  | swamp | green mould fuzz tufts |
  | moon | mozzarella strings between craters |
  | ocean | feta-brine bubbles |

  - Make the arena barrier a rind wall in every map.

### C-29 Bosses share one set of poses; their signature attacks have no animation
- **Type:** animation. **Owner:** G.
- **Evidence:**
  - **Render** `png/boss_poses.png`: walk, wind-up, strike and roar are nearly identical for every boss (a small root lean); death is a tip-over.
  - **Code:** `HordeRenderer.luau` 23–25, *"Bosses keep their idle channels… a root pose layer adds the wind-up lean / strike lunge"*.
  - **Contrast:** champions get a biped rig. Patterns like slipper_slam, belly_flop, tongue_lash and chest_pound have no matching motion.
  - **STYLE:** *"each [boss] with one exaggerated feature you can read instantly."*
- **Impact:** H. **Effort:** L.
- **Proposed change:**
  - **Rig:** give bosses bones in `BossModels` (arms, head, jaw, tail or wings where present).
  - **Clips:** one pose clip per pattern **base** in `BossPatterns.DEFS`:
    - slam: raise, hold for the `delay`, drop with squash on impact;
    - charge: crouch, then a stretch on the dash;
    - volley: a throwing arm;
    - summon: arms up;
    - roulette: a wand spin;
    - breath: head pull-back.
  - **Scope:** about 10 bases cover all 13 bosses.
  - **Phase 2:** a 1 s roar with a scale pulse.

### C-30 Elite mice show a glow blob, not the crown in STYLE
- **Type:** graphics. **Owner:** G.
- **Evidence:**
  - STYLE: *"Elites are gold-tinted with a tiny crown."*
  - Render `png/mice.png`, elite column: a yellow neon blob on the head that doesn't read as a crown; the body is not gold-tinted.
- **Impact:** L. **Effort:** S.
- **Proposed change:**
  - Make the crown a 3-point part.
  - Lerp the body colour 30% toward gold.
  - Keep the neon glint small.

---

## Ranking hint (impact ÷ effort, my view)

| Rank | Entries | Why |
|---|---|---|
| 1 | C-1 (H/S), C-5 (H/S), C-26 (H/S–M) | cheap, and they restore the concept's gamble and the feel |
| 2 | C-2, C-8, C-11, C-16, C-18, C-27 (H/M) | the moments, map identity and the elephant fantasy |
| 3 | C-3, C-6, C-7, C-10, C-14, C-17, C-21 (M/S) | quick personality and UX wins |
| 4 | C-9, C-13, C-19, C-22, C-24, C-25, C-28 (M/M) | depth and retention |
| 5 | C-4, C-15, C-29 (L effort) | worth planning for iteration 2 or 3 |
