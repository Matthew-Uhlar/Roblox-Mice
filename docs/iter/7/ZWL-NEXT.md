# Iteration 7: what Liberty still has that we don't, plus new classes (team Research, 2026-11-24)

**Inputs:**
- `docs/iter/5/ZWL-GAPS.md` (the last gap review)
- `docs/research/zombie-world.md` and `docs/research/zwl-save-model.md`
- `docs/iter/6/PLAN.md`
- `docs/HANDOFF.md`
- the code at `c9c9e38`

**Rules:**
- We borrow mechanics only. All names here are ours, never Liberty's.
- Robux never buy power.
- Damage from long-term progress never applies in PvP (`Config/Keystones.luau` header).

**Web check, 2026-11-24:** two new searches found nothing new on Liberty or Unity (only unrelated SC2 arcade pages). As in iteration 5:
- the fandom wiki refuses automated fetches;
- the creator's site and sc2arcade.com are blocked by this session's network policy;
- brainnations.com is spam.

We did not try to get around any of these.

**What we can and can't confirm:**
- The roster of 11 heroes is **Liberty-verified** (from the save).
- The **role** of each hero is our inference from the unit types and is **unverified**.

## 1. Remaining Liberty gaps after iteration 6

Iteration 6 closed these gaps:

| Feature | Evidence |
|---|---|
| Builder class | `tinkerphant` in `Config/Classes.luau:262` |
| Pace toggle | `settings.pace` in `Data/ProfileSchema.luau:522` |
| Deeper talent trees with keystones | `Config/ClassPerks.luau`, `Config/Keystones.luau` |
| 7 abilities per class and a 4th slot | `ClassAbilities.ADVANCED`, `SLOT_COOLDOWN_MULT` |
| Visible ascension | `server/Visuals/AscensionLooks.luau` |
| Gem Vault | `Config/Gems.luau`, "iter6 Gem Vault" block |
| Lobby votes | `client/UI/VoteUI.luau` |

Iteration 5 had already closed:
- the damage meter (`client/UI/MeterUI.luau`);
- the two-way Swap Stand;
- the totems;
- Quick Study;
- the squad stall;
- Overtime;
- time played;
- graphics settings.

### Hero roster versus Liberty's 11 roles

The roles below are inferred, not verified.

| Liberty role (mechanic) | Us | Status | Evidence |
|---|---|---|---|
| Long-range precision shooter | none | **Missing** | Our longest weapon range is 45 (Ele Fonte, `Classes.luau:83`). There is no line or pierce-all ability kind (`ClassAbilities.luau` header). |
| Short-range blink and shade striker | Le F'ante (dash, leap, mark) | Have | `ClassAbilities.luau:149`, `:413` |
| Melee charger | Elephante | Have | `Classes.luau:40` |
| Bulky AoE caster with a shield | Elephante (Iron Hide) / Fizzante | Partial | We have no hero that both tanks and casts. This is low value, so it is not proposed. |
| All-round gunner | Ellie Fawn (spread) | Have | `Classes.luau:103` |
| Healer of allies | none | **Missing** | Every heal mechanic heals only yourself (`tkKillHeal`, `regen` in `ClassPerks.luau:210,356`). The only squad heal is Tinkerphant's Repair Pulse (12%, `ClassAbilities.luau:262`). |
| Worker / builder | Tinkerphant | Have | iteration 6 |
| Stealth assassin | none | **Missing** | A grep for `stealth` or `cloak` in `src/` returns 0 hits. |
| Short-range flame tank | Filet (orbit) / Jumbo (cone) | Partial | Neither class is a tank, and no class has a burning damage-over-time. |
| Artillery with a deploy stance | none | **Missing** | A grep for `siege` returns 0 hits. Fizzante's lob is mid-range (30). Tinkerphant builds turrets, but the hero is never the turret. |
| Storm caster | Ele Fonte / Fizzante | Have | — |

We have 8 classes against Liberty's 11, and four roles are missing: sniper, healer, artillery and stealth. Section 2 proposes three of them. Stealth is the 4th candidate (see the end of section 2).

### Systems

| Liberty / series feature | Source | Us | Evidence | Note |
|---|---|---|---|---|
| Class-specific gem uniques for each hero | Liberty (6 hero uniques) | **Partial** | `Gems.UNIQUES` has 7 class uniques. **Tinkerphant has none.** | Add one per class, including each new class. |
| Gem tiers 13–14 | Liberty | Partial | `Gems.MAX_TIER = #RANGES = 12` | Tie them to Overtime depth, which exists now. |
| Minibosses give long-term progress | series | Missing | Camps pay only rinds, whey and XP (`Combat/Champions.luau`). Carried over from iteration 5. | Small Crumb Dust on the first kill per match, with a daily cap. |
| Hero level cap of about 70 | Liberty | Partial (30) | `ClassProgress.MAX_LEVEL = 30` | Prestige covers the long tail. **Leave as is.** Raising it would mean reworking the perk-point budget. |
| Gems as a team-wide aura | Liberty | N/A | owner decision in iteration 4 | Do not revert. |
| Gems drop from bosses | Liberty | N/A (end-of-match only) | owner decision in iteration 4 | — |
| Speed × Life chosen separately | series | Have | tier plus Pace (iteration 6) | — |
| Skip Wave At, graphics toggles, 30 challenges, Best Solo, 11 tiers, prestige 99, 8-node ascension | Liberty | Have | earlier iterations | — |

### Polish (not Liberty-specific, but expected in this genre)

| Polish item | Us | Evidence |
|---|---|---|
| Aim preview for abilities (range ring, area or line ghost) | **Missing** except for builds | The only ghost is `client/Util/BuildMath.luau` + `BuildRenderer` (turret and barricade). Other abilities cast instantly with no preview, including leap, vortex, mark and chain. |
| Hit-stop, camera shake, per-class cast sounds | **Missing** | No `hitstop` or shake in `client/`. `Config/Sounds.luau` only has generic keys (swing, hit, boom, crit…), so all 56 abilities sound alike. |
| Talent build presets (save and swap builds) | Missing | The only option is `ResetPerks` for cheese (`Net.luau:29`). Iteration 6's deeper trees make respeccing expensive. |
| Mobile auto-cast or smart-cast | Missing | grep for `autocast` returns 0. Phones press 4 ability buttons plus attack. |
| Keybind remapping and key hints for 4 slots | Missing | grep for `keybind` returns 0. |
| Off-screen arrows for downed squadmates | Partial | Downed bar in `HeroTags.luau:20`. Edge arrows exist only for champions (HANDOFF v3). |
| Death recap ("downed by X; top 3 damage sources") | Missing | The kill feed exists, but there is no personal recap. The meter already tracks the data (`World.meterStats`). |

### Top 10 by player value against effort

New classes are left out of this list; they are section 2.

Effort: **S** ≤ 1 day, **M** 2–4 days, **L** a week or more.

| # | Item | Status | Effort | Why |
|---|---|---|---|---|
| 1 | **Ability aim preview**: hold the key to see the range ring plus the area, line or landing ghost, and release to cast. A tap still quick-casts. Mobile: show it while dragging. | Missing | S–M (reuse BuildMath) | There are 56 abilities now. Leap, vortex and mark are unreadable without a preview, and the new sniper line shot needs one. |
| 2 | **Game-feel pass**: 40–60 ms hit-stop on crits and kills by abilities; small shake on your own big hits (Effects setting respected); distinct cast and impact sounds for each ability kind, plus 1 signature sound per class | Missing | M | The biggest jump in how the game "feels" per day of work. It uses the Fx events that already exist. |
| 3 | **Class gem unique for Tinkerphant**, and the same rule for every new class | Partial | S | Liberty has hero uniques. Tinkerphant players have no gem to chase. |
| 4 | **Death recap card** while downed or spectating | Missing | S | PvP clarity ("what killed me?"). The data is already in `meterStats`. |
| 5 | **Off-screen arrows for downed squadmates** and an automatic "needs revive" ping | Partial | S | Makes revives and the proposed healer class work on our large maps. |
| 6 | **Talent presets**: 2 saved builds per class, free to swap in the lobby | Missing | M | The deeper trees invite experiments. Respeccing for cheese punishes them. |
| 7 | **Miniboss first-kill reward**: Crumb Dust, capped per day | Missing | S | Carried over from the series and from iteration 5. It gives camps lasting value. |
| 8 | **Gem tiers 13–14** from Overtime wave milestones on the top tiers | Partial | S–M | Matches Liberty's 14 tiers and gives Overtime an end-game reason. |
| 9 | **Mobile smart-cast**: optional auto-cast of slot 1 when ≥ N mice are in range; off in PvP | Missing | S–M | Phones are most of Roblox. Four slots plus attack is a lot of thumbs. |
| 10 | **Keybind remapping** plus key and button hints on every slot | Missing | M | PC and gamepad players with 4 slots. Hints also teach new players. |

Also considered, not ranked:
- Level cap 70: leave it; prestige covers the long tail.
- Gems as a team aura, and boss gem drops: owner decisions, N/A.
- A tank that also casts: low value.

## 2. Three new classes

**Shared rules:**
- Each class costs 4,000 cheese (×1.5 after iteration 6) or comes from the free stomp-unlock track. Never Robux.
- Each class gets:
  - 8 ascension nodes;
  - one class gem unique;
  - a skin set;
  - a BotBrain profile;
  - a CombatTtk row.
- Abilities follow `ClassAbilities` gates:
  - base: L1;
  - alternates: L5 and L15;
  - advanced: L25, P3 and P10;
  - ascended: node 6, about ×1.35 budget.
- Each class has at most **one** new ability kind.
- Talent trees follow the shape in `ClassPerks.luau`: 3 branches, an E1/E2 choice, and one keystone per branch. Keystones are built from the existing `tk*` mechanics where possible.

### 2a. Ele Vation: Marksman (the long-range sniper)

A calm, precise elephant who props a long peanut rifle on her trunk. She is the only hero who wins fights at 60+ studs.

**Weapon: Peanut Rifle**
- kind `bolt`
- damage 34, cooldown 1.5, range 75, pierce 2, area 0.8
- `pvpMult` 0.55, so long range doesn't decide PvP
- Note: `InputController.AUTO_AIM_RANGE` is 70. Raise it for this class or cap the range at 70.

**Passive: Steady Trunk.** After standing still for 1 s: +30% weapon damage and +15% range. Moving loses it.

| Slot | Ability | Kind | Shape |
|---|---|---|---|
| Base L1 | **Long Shot** | **`lance` (NEW)** | Instant line: distance 90, half width 1.5, damage 70. Hits everything on the line. Shows a 0.35 s laser-sight telegraph, which rivals can see in PvP. Cooldown 9. |
| Alt L5 | Spotter Flare | `mark` | Range 60, radius 10, fuse 2.5 s. Marked targets pop. |
| Alt L15 | Scoot | `dash` | Short dash (14) with low damage. The disengage. |
| L25 | Crow's Nest | `hover` | 3 s in the air (immune), with a small gust on take-off. Reposition over the horde. |
| P3 | Ricochet Round | `chain` | Reach 70, then 3 bounces. |
| P10 | Tripwire Net | `field` | Range 55, radius 9, 5 s slow field. Zone control for squadmates. |
| Ascended | **Sky Splitter** | `lance` | Distance 120, half width 4, ×1.35 damage. Leaves a 3 s burning line. |

**Talent tree:**

| Branch | Theme | Keystone |
|---|---|---|
| **Deadeye** | crit and precision | **Headliner**: every 4th shot is empowered and pierces everything (`tkEmpower` + pierce). |
| **Overwatch** | standing still and range | **Perch**: while Steady Trunk is active, kills refund Long Shot cooldown (`tkCdKill`), and the rifle gains +1 pierce. |
| **Trapper** | marks and nets | **Snare Line**: mice that die while marked or netted throw shards (`tkShards`). |

**Distinct from:**
- Ellie Fawn: a short spread at 40, always moving.
- Ele Fonte: a mid-range bolt caster.

Ele Vation is slow, deliberate, and rewards positioning.

**Bots:** stop moving to shoot when no mouse is within 15. Line Long Shot up through the densest lane.

### 2b. Elephaid: Field Medic (the healer of allies)

A nurse elephant with a herbal spritzer and a pouch of peanut plasters. She is our first class whose main job is keeping **other** heroes alive.

**Weapon: Salve Spritzer**
- kind `bolt`
- damage 9, cooldown 0.5, range 32
- `pvpMult` 0.7

**Passive: Bedside Manner.**
- Revives 50% faster (`World.REVIVE_TIME` 3 s becomes 1.5 s for her).
- 15% of her weapon damage heals the lowest-HP squadmate within 25.

| Slot | Ability | Kind | Shape |
|---|---|---|---|
| Base L1 | **Lifeline** | **`tether` (NEW)** | Links to the aimed or nearest squadmate within 35 for 5 s. Heals 4% of their max HP per 0.5 s tick. Breaks beyond 45. With no ally, it links to herself at half rate. Heals own squad only. Cooldown 10. |
| Alt L5 | Triage Pulse | `repair` | Radius 18, heals squadmates 15% (no build bonus). |
| Alt L15 | Sleepy Mist | `field` | Range 30, radius 10, 5 s, low damage and a 50% slow. Peels mice off allies. |
| L25 | Halo Hum | `ring` | 4 s ring around herself. Low damage per tick, knocks mice back. |
| P3 | Rescue Hop | `leap` | Leap up to 30. Landing next to a downed squadmate adds 50% revive progress. |
| P10 | Antidote Arc | `chain` | The offensive option: reach 30, 4 jumps. |
| Ascended | **Second Wind** | `tether` | Links to every squadmate within 40 for 6 s. Heals them and clears slows. Instantly revives one downed squadmate in range, once per 90 s. |

**Talent tree:**

| Branch | Theme | Keystone |
|---|---|---|
| **Physician** | healing power | **Overflow**: overhealing becomes a short shield on the target (uses the `tkGuard` mechanic, aimed at the target). |
| **Herbalist** | fields and damage-over-time | **Pollen Cloud**: a damage aura around her (`tkAura`), mice only. |
| **Field Runner** | mobility and revives | **Guardian Link**: the tethered ally gets `tkLastStand` once per 60 s while linked. |

**PvP:**
- She heals only her own squad.
- Healing on heroes is capped by the existing +25% PvP meta-HP cap rule.

**Distinct from:** every current class. All existing healing is self-only, and Tinkerphant's pulse is a side ability.

**Bots:** tether the squadmate with the lowest HP%. Prioritise revives.

### 2c. Trunkillery: Artillery (the hero who becomes the turret)

A heavy elephant with a coconut mortar on her back. When mobile she is mediocre. Dug in, she shells the whole lane.

**Weapon: Coconut Mortar**
- kind `lob`
- damage 26, cooldown 1.8, range 55, area 7
- `pvpMult` 0.6
- Optional new weapon field `minRange` 10. Without it, the class is still fine.

**Passive: Heavy Plating.** +2 armor, immune to knockback, +15% weapon area.

| Slot | Ability | Kind | Shape |
|---|---|---|---|
| Base L1 | **Dig In** | **`anchor` (NEW)** | A stance lasting 8 s, which a recast ends early (0.5 s to unroot). She cannot move. Weapon range ×1.6, damage ×1.5, area ×1.3, +3 armor. Cooldown 10. In PvP, rivals see a visible ground plate. |
| Alt L5 | Sandbag Wall | `barricade` | Half length 8, 10 s. Cover while dug in. |
| Alt L15 | Spotting Round | `mark` | Range 70, radius 12, fuse 2 s. |
| L25 | Recoil Hop | `leap` | Leap 20 backwards along the aim line, with a landing blast. The escape. |
| P3 | Shrapnel Ring | `ring` | One slam around herself. Close defence while rooted. |
| P10 | Flak Burst | `burst` | Range 70, radius 10. Long-range nuke. |
| Ascended | **Grand Bombardment** | `field` | Range 80, radius 16, 6 s of shells falling (damage per tick plus slow). Shells fire ×1.35 harder while dug in. |

**Talent tree:**

| Branch | Theme | Keystone |
|---|---|---|
| **Battery** | firepower while dug in | **Salvo**: while anchored, every 3rd mortar fires 3 shells (`tkCharges` / `tkEmpower`). |
| **Bunker** | defence while rooted | **Payback**: hits taken while anchored set off a quake (`tkRetaliate`), and her armor counts double (`tkGuard`). |
| **Demolitions** | splash | **Chain Blast**: kills from the mortar burst into shards (`tkShards`); every 10th kill sets off a nova (`tkNova`). |

**Distinct from:**
- Fizzante: a mobile, mid-range lob and fields.
- Tinkerphant: builds separate turrets.

Trunkillery trades all mobility for range and power. That is a new decision for the player.

**Bots:** dig in when ≥ 8 mice are within 50 and no rival hero is within 25. Unroot when HP < 40%.

### Reserve: the 4th missing role (stealth assassin)

- **Name:** "Ele-Phantom".
- **New kind:** `cloak`. Untargetable by mice for 3 s; the first hit out of cloak crits.
- **Why it is not in the top 3:** in PvP, stealth needs careful counters (shimmer, reveal on damage). It also overlaps Le F'ante's burst-duelist niche.
- **Revisit** after the three classes above.

### New ability kinds needed (one per class)

| Kind | Fields (same pattern as the header of `ClassAbilities.luau`) | Fx |
|---|---|---|
| `lance` | distance = line length; area = half width; damage | laser-sight telegraph, then a tracer |
| `tether` | distance = link range; heal = max-HP share per tick; duration; breakRange | beam between the two heroes |
| `anchor` | duration; rangeMult, damageMult, areaMult, armorAdd; recast ends it | ground plate, braces, mortar recoil |

Each one also needs:
- a World handler;
- snapshot/Fx support;
- an aim preview (Top 10 #1).

## 3. Visual-quality wins for the mesh pass, in priority order

**Today:** every model is built from Parts in code:
- `server/Visuals/BotModel.luau`: about 95 parts per elephant;
- `client/Visuals/MouseModels.luau`: 20–26 parts per mouse;
- `BossModels`, `Props`, `StallModels` and so on.

**Already done with parts** (re-check them in Studio, don't redo them): gem cuts, ascension scale, cape and aura (iteration 3, T-27 and T-28). **Delivery:** `assets/models/PLAN.md`. Scripts cannot set `MeshId`, so meshes reach the game as uploaded models through `AssetLoader`. If "procedural meshes" means EditableMesh, check the current API and publishing limits in Studio first.

1. **Base mouse and the 5 elite mice.** They are on screen hundreds of times, and they are the biggest "programmer art" tell (`PLAN.md` #1). Keep the 3-part far LOD. Mesh the near and mid models with the same bone names so `Rig` still animates them.
2. **The hero elephant body**, for the Herd Suit, bots and the lobby. It is the player's identity, and the ball-built body and trunk read lumpy up close (V4-B S1-2). Build it as one mesh with attach points for ascension capes, tusks and class gear.
3. **Class weapons and builds**:
   - rifle, mortar and spritzer for the new classes;
   - Tinkerphant's turret and barricade (`client/Visuals/BuildModels.luau`).
   These are small, highly visible, and define the silhouette of each class.
4. **Bosses with shapes that parts can't make**: spider mech legs, paper dinosaur folds, ice dragon wings (`PLAN.md` notes). Each boss also needs clearly different wind-up, strike and roar poses (T-26: corndog bunny and hematite snake look alike).
5. **Map landmark kit**:
   - rock clusters, cheese boulders, rind fences, path edging;
   - biome props every ~60 studs.
   The gameplay-camera view is flat and empty (T-29, `Visuals/Props.luau`, `Biomes.luau`).
6. **The contested map spots**: totems, stalls, Altar and POI objectives (`StallModels`, `ObjectiveModels`). They need to read from 60 studs, because players fight over them.
7. **Bake the house style into every mesh**: a 1–2 px dark toon outline in the texture (V4-B), one material, and 2–8k triangles. This keeps everything readable from the top-down camera and cheap on phones.
