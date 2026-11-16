# V4 Review B: player experience, UI/UX and graphics

_Reviewer: v4 Review Team B, 2026-11-16. Build reviewed: branch `claude/focused-gates-jihpzi` (live place v6 / v3). This is a report only. No code was changed._

## How this review was done

- **Code read:**
  - `src/client/**`: UI, Controllers and Visuals.
  - `src/server/Visuals/*`.
  - `Services/{ArenaBuilder,LightingService,LobbyWorld}`.
  - `docs/{HANDOFF,GDD-v2,STYLE}.md` and `assets/models/PLAN.md`.
- **Renders inspected:** every `assets/previews/*.png` and `assets/store/*.png`.
- **New renders** (scratchpad only, not in the repo):
  - `scripts/render-preview.luau` was re-exported to `/tmp/claude-0/-home-user/62ecd08e-82c1-5cab-a26b-5e0b2b23913e/scratchpad/v4b/scenes`.
  - A new compositor, `/tmp/claude-0/-home-user/62ecd08e-82c1-5cab-a26b-5e0b2b23913e/scratchpad/v4b/tools/gameplay.py`, places a 3-elephant squad and a 46-mouse horde on a real arena scene. It renders them with the **live camera values**: pitch 55°, FOV 45, zoom 60 on PC and 66 on phone, at true output sizes.
  - Outputs:
    - `/tmp/claude-0/-home-user/62ecd08e-82c1-5cab-a26b-5e0b2b23913e/scratchpad/v4b/gameplay_forest_pc.png`
    - `/tmp/claude-0/-home-user/62ecd08e-82c1-5cab-a26b-5e0b2b23913e/scratchpad/v4b/gameplay_forest_phone.png`
    - `/tmp/claude-0/-home-user/62ecd08e-82c1-5cab-a26b-5e0b2b23913e/scratchpad/v4b/gameplay_plains_pc.png`
    - `/tmp/claude-0/-home-user/62ecd08e-82c1-5cab-a26b-5e0b2b23913e/scratchpad/v4b/gameplay_plains_phone.png`
- **Contrast maths:** WCAG relative-luminance contrast between enemy body colours (`Visuals/MouseModels.luau`) and the per-map terrain tints (`LightingService.PRESETS[*].terrain`).
- **Caveat:** the preview renderer voxelises terrain at 4 studs (2 studs on small maps) and draws it flat and untextured. Real Roblox terrain is smoother, carries material textures and blends material borders. So the staircase paths in the previews look harsher than they will in game. Prop density, colour values, silhouettes and layout are faithful.

## Verdict in one paragraph

The systems and UI engineering are unusually solid for a code-built Roblox game. The Theme, text floor and touch-target rules, pooled VFX, rigs, and a minimap with edge arrows are all better than most indie Roblox titles. Reception, though, is decided in the first 60 seconds and on the store page, and that is where Trunkfall is weakest:

1. **There is no sound at all.**
2. **The player is not an elephant.** The store sells "7 Elephant Heroes", but you play as your blocky avatar with a hat, next to bigger, cuter elephant bots.
3. **A new player who joins a busy server waits out the whole match** in a 44-stud lobby.
4. **The store art is stale and has visible artefacts.**
5. **At gameplay zoom the 2.5× maps are mostly empty flat ground**, and the basic mice nearly vanish on several grounds.

Fix those five and the game looks and feels like a different product. None of them needs paid assets.

---

## Findings ranked by impact on player reception

Severity key:
- **S1:** players will bounce or rate it down.
- **S2:** it clearly lowers quality perception.
- **S3:** polish.

### S1-1. There is no audio of any kind

- **Evidence:**
  - Running `grep -rn "Sound\|SoundId\|SoundService" src` finds no `Sound` instance, no SoundService use and no sound id anywhere.
  - `Config/AssetIds.luau` is `{}`.
  - `STYLE.md` §"UI and audio" describes brass, woodwind and squeak direction, but none of it is implemented.
- **Impact:** for a horde game this is the single biggest "feel" gap. Hits, kills, level-ups, loot drops, boss telegraphs and UI clicks are silent. Top Roblox horde and simulator games rely on audio for most of their perceived "juice". Telegraph sounds are also an accessibility and gameplay feature: STYLE says "every telegraph has a distinct wind-up sound", and that is missing.
- **Fix (a plan; ids must be supplied):**
  1. **Today, at zero cost:** use sounds that ship with the Roblox client as `rbxasset://sounds/...`, as is already done for particle textures. Commonly available files include `swordslash.wav`, `swordlunge.wav`, `unsheath.wav`, `electronicpingshort.wav`, `button.wav`, `clickfast.wav`, `Rocket shot.wav`, `Rocket whoosh.wav`, `collide.wav`, `impact_water.mp3`, `action_jump.mp3`, `action_get_up.mp3` and `uuhhh.mp3`. **Each path must be verified in Studio**, because the client content folder changes between versions. They are good enough as placeholders for swing, hit, explosion, UI click and down.
  2. **Real ids:** pick free sounds in the Studio Toolbox, Audio tab, filtered to **creator "Roblox"**. Roblox's own uploads are usable in every experience after the 2022 audio-privacy change. Search terms per slot are in the table below. Alternatively, generate SFX procedurally: sfxr/jsfxr-style Python generation of `.ogg` files under `assets/audio/`. Upload them through the existing `scripts/publish.py assets` and `upload-assets.yml` pipeline. Open Cloud accepts audio assets, subject to the monthly audio upload quota, which needs verifying. Do not guess ids. Every id stays 0 (silent) until pasted in.
  3. **Code shape:**
     - New `Config/Sounds.luau` holds `{key = {id, volume, pitchMin, pitchMax, maxPerSecond, group, is3D}}`.
     - New client `Controllers/SoundController.luau` hooks the existing Fx handlers and UI events.
     - Three SoundGroups: Music (Volume 0.35), SFX (0.6), UI (0.5).
     - 3-D world sounds use `RollOffMode = InverseTapered`, `RollOffMinDistance = 20` and `RollOffMaxDistance = 110`, since the camera sits about 60 studs away.
     - Pitch is randomised between 0.92 and 1.12 on every play.
     - Rate limits: `hit` at most 10 per second, `die` at most 8 per second, crumb pickup at most 12 per second, with a rising pitch chain of +0.04 per pickup within 0.6 s, reset after that.
     - Pool 24 Sound objects.
     - Duck the music to 0.15 for 1.5 s on a boss intro or a level-up.
     - Add a Settings toggle for Music and SFX in the Shop or lobby bar.

| Slot | Trigger (existing hook) | Toolbox search, creator Roblox | Notes |
|---|---|---|---|
| Hero swing | `melee`, HeroFx weapon flick | "whoosh", "swing" | very quiet; 0.25 volume |
| Hit mouse | Fx `hit` | "punch", "hit soft" | crit: same sound at pitch 1.3 plus "ding" |
| Mouse death | Fx `die` | "squeak", "pop" | the core feedback loop; pitch 1.2 to 1.6 |
| Crumb pickup | `pickupTaken` | "coin", "pickup" | rising pitch chain |
| Level up | client sees `hud.level` increase | "level up", "fanfare short" | duck music |
| Upgrade pick | UpgradeUI choose | "magic chime" | |
| Gear drop and rarity | Fx `gear`, `bag` | "sparkle" (Rare+), "chest" | Legendary: stinger plus a short sustained shimmer |
| Telegraph wind-up | Fx `tele` | "charge up", "warning" | distinct per style: slam, line, ring |
| Explosion | Fx `boom`, fuse mouse | "explosion small" | |
| Player hurt | Fx `hurt` (own) | "hurt", "thud" | at most 4 per second |
| Downed and revive | `down`, `revive` | "fall", "heal" | |
| Boss roar and phase | `boss`, `bossPhase`, `enrage` | "roar", "monster" | |
| Champion intro | tele `champIntro` | "horn", "gong" | |
| Rind Gate open / pull | Fx `portal` | "portal", "teleport" | |
| UI click / hover | Theme button helper | "click", "button" | 2-D, UI group |
| Countdown 3-2-1 | LobbyUI countdown | "tick", "beep" | |
| Results count-up | ResultsUI | "coins" loop + "cash register" | |
| Music | lobby, waves (one per biome), boss | "upbeat", "adventure", "boss battle" | 1 loop per map family |

### S1-2. The player hero is a plain avatar, not an elephant, and is smaller than the bots

- **Evidence:**
  - `HeroDecor.luau` adds only a hat, face gear, a back item, a sash and a weapon to the R15 avatar. It has no ears and no trunk (no "trunk" or "ear" in HeroDecor).
  - `GDD-v2 §6` makes this deliberate ("Heroes keep the player's avatar").
  - Bots are full part-built chibi elephants (`BotModel`) about **8.5 studs tall**, while a default R15 avatar is about 5 studs tall (`bot_elephante.json` extents y = 0.22 to 8.49).
  - All store art (`thumb_3_heroes.png`, "7 ELEPHANT HEROES"; `icon_512.png`) and the lobby showcase statues sell elephants.
- **Impact:** an expectation mismatch the moment you spawn. You are the least on-theme and smallest character in your own squad. Your two bot teammates are cuter, bigger and better dressed than you. This also undermines cosmetics sales, because skins are previewed on elephants.
- **Fix (no meshes needed): an "elephant hood" welded to the avatar `Head`, built in `ClassGear` and reused by HeroDecor.** Measurements are relative to head size `h`:
  - **Ears:** two Parts with `SpecialMesh` (FileType Sphere), `Scale = (0.25, 1.5, 1.25) * h`. Colour herd grey `#9AA3AD`. Hinge 0.55·h to each side, angled ±30° yaw and +12° roll, mirroring `BotModel` lines 271–275. Add an inner disc `#F2A7B5` at 75% size, offset −0.06 forward.
  - **Trunk:** 3 to 4 tapered Ball segments with radius 0.30 → 0.18 · h, curling down then forward from the face centre (like BotModel's trunk). Add 2 small white tusks: Wedges of 0.12 × 0.12 × 0.35 h.
  - **Optional:** during a run, set `BodyColors` to herd grey `#9AA3AD`. Make this a profile setting, "Elephant skin: on" by default, and restore on return to the lobby so avatar identity stays in the lobby.
  - **Size parity:** scale BotModel to about 0.65 so bots are about 5.5 studs, or apply `ScaleTo(1.3)` to the HeroDecor hood only. The human should never be visually smaller than a bot. Hitboxes come from the 2-D sim, so this is purely visual.
  - **Bot policy:** the 🤖 tags and the bot desaturation stay, so bots are still clearly labelled.

### S1-3. Joining a busy server means waiting out the whole match in a tiny lobby

- **Evidence:**
  - Servers hold 12 players (4 squads × 3).
  - The lobby shows "Match in progress · about N left. The next match starts when this one ends" (`LobbyService.runInfo`, `RunDirector.estimateEnd`).
  - A match is several stages of 150 s waves plus a boss and an extraction window, so N is often many minutes.
  - The lobby island is 44 studs across inside its wall (`LobbyWorld.WALL_RADIUS`) and has nothing to do.
  - Roblox matchmaking prefers partly full servers, so **most organic joiners will hit this.**
- **Impact:** the worst possible first five minutes. Players will leave before playing.
- **Fix, in order of value:**
  1. **Drop-in to a bot seat.** Every squad's empty seats are filled by bots, so a joiner replaces a bot in the squad with the fewest humans. Swap at the next stage start, or immediately using the existing `DROP_PROTECT` 9 s, through `RunDirector`'s drop-in path. Bots earn nothing, so no reward rule changes.
  2. If drop-in is not possible, **teleport to a fresh reserved server** after a 10 s countdown ("Find a new match").
  3. **Practice yard while waiting:** spawn 10 to 20 client-side "training mice" (the existing HordeRenderer models, killed by any hit, giving no rewards) on a sandbox pad beside the plaza, so the controls are learned before the match.

### S1-4. The store icon and thumbnails are stale, show artefacts and show no gameplay

- **Evidence:**
  - **`icon_512.png`** and **`thumb_3_heroes.png`** were made at commit e670dc3, before the v3 rework in edba9ca. They show the **old elephant**: a straight stick trunk, white glowing legs and a crate-like ear. The current BotModel has a curled trunk, toes and chibi eyes (`assets/previews/bots.png`).
  - **The icon:**
    - Its subject is a grey elephant on a yellow-orange blurred circle, with low figure/ground contrast.
    - Its face is about 15% of the canvas.
    - It shows no mouse and no action.
    - The "TRUNKFALL" text takes the bottom 20%. On the 150 px store tile the text is unreadable, and that space is lost from the character.
  - **`thumb_2_maps.png`:**
    - The source sheet's title "Trunkfall: the 9 maps (overview)" shows through at the top edge.
    - A third row of maps peeks out under the bottom bar.
    - The maps are top-down discs that read as pizzas.
    - It has no characters.
  - **`thumb_1_bosses.png`** says "13 WILD BOSSES" but shows 10.
  - **`thumb_3_heroes.png`:**
    - All 7 bodies are identical.
    - The second row sits on a different green band that overlaps the caption bar (layout glitch).
    - It sells elephants the player does not get (see S1-2).
  - **There is no in-action thumbnail** (horde, VFX, damage numbers, HUD). On Roblox that is the top click-through driver.
- **Fix (do this before any ad spend):**
  - **Icon:** re-render a close-up of the current BotModel at 1024² and downscale.
    - Pose: three-quarter view, from slightly below; trunk raised; class weapon (Elephante's hammer) mid-swing.
    - Add 3 to 4 mice flying off with "pop" crumbs, and one big cheese wedge.
    - Background: saturated sky blue `#4EA8FF` → `#9FD8FF` radial, which makes grey pop far better than yellow.
    - Add a **sticker outline**: dilate the subject's alpha by 10 px and fill with `#2B1A0E`, plus a 4 px white inner rim.
    - The face (eyes) should fill at least 30% of the frame. Add angry or determined brows, which are 2 small dark Wedges above the eyes.
    - Drop the text, or use a short 2-word logo at least 90 px high across the top.
  - **Thumbnail 1, "action", first in order:** the composite in `tools/gameplay.py` already gets close.
    - Render at 1920×1080 from the live camera with VFX parts: the Elephante ability ring, orange hit sparks, white and yellow damage-number text drawn in PIL, and a boss telegraph red disc `#FF4B3E` at 60%.
    - Overlay the real HUD (status card, scoreboard pips), mocked in PIL from the Theme colours.
    - Caption: "STOMP 1,000 MICE".
  - **Thumbnail 2:** one boss towering over the squad (Grandma with slipper raised), not a grid.
  - **Thumbnail 3:** a squad-vs-squad moment at the Rind Gate ("Extract or gamble?").
  - Regenerate `make-store-art.py` from current renders, and add a guard that fails if the source sheets are older than `src/server/Visuals/BotModel.luau`.

### S1-5. At gameplay zoom the big maps are mostly empty flat ground

- **Evidence:**
  - `map_*.png` "gameplay camera" tiles: plains shows one crate; forest shows one tree; tundra and moon show nothing but patch colours.
  - Maps grew to radius 320–400 (area about 6.25×), while `obstacleCount` only doubled. Plains has 30 obstacles over about 322,000 studs², which is one per about 10,700 studs², roughly one per 100×100-stud patch.
  - `nDecor = R * 1.2` (about 400 decor items).
  - The view on PC at zoom 60 is about 88 × 50 studs, so you see well under one obstacle per screen.
  - Grass maps have no terrain decoration: there is no `Terrain.Decoration` or `GrassLength` anywhere.
- **Impact:** the composite frames show a squad and horde on a featureless green or yellow field. The game reads as a "baseplate game", which is the strongest amateur tell on Roblox.
- **Fix (mostly free in parts):**
  1. **`Terrain.Decoration = true`** (animated grass blades on Grass and LeafyGrass) on plains, forest, jungle, swamp and the lobby, with `GrassLength = 0.7`. Set it in the place file if the script write is refused. Roblox drops it automatically on low quality levels. This is the biggest single "looks professional" win on grass maps.
  2. **Micro-relief:** `Terra.ball` bumps buried so they rise at most 0.8 studs above Y = 0 (centre Y = −r + 0.8, r 4–9) in the patch materials. This breaks up the flat plane. It is below R15 step height and invisible to the 2-D sim. Projectiles fly at Y 2.5, so they are unaffected.
  3. **Scale decor with area:**
     - Change `nDecor = math.floor(R * 1.2)` to `math.floor(R * 3)`, using 1 to 3-part micro decor: pebble clusters, flowers, mushrooms, bones, cheese crumbs, lava rocks, shells, ice shards.
     - Set `CanCollide = false`, `CastShadow = false` and `CanQuery = false` on them.
     - Keep them under the "Decor" tag (DetailLevel already streams it by distance).
     - Fund it by cutting backdrop parts: the rim and plateau are seen rarely at gameplay zoom, so `BACKDROP_PARTS` 380 → 150.
  4. **Landmark clusters:** each region (mesa, ruins, meadow, bog) should be visible from the next one. Raise region dressing from `g.r / 4` to `g.r / 2` items.
  5. **Paths:** use `FillCylinder` stamps every 6 studs (r = width/2 + 0.5) instead of rotated FillBlocks, so the road edge is round rather than stair-stepped. Then border roads with a second, 2-stud-wider stamp in a mid-tone material (Ground on grass, Sandstone on sand) for a soft edge.

### S1-6. Basic mice are nearly invisible on several grounds, and Chonks read as elephants

- **Evidence:** contrast ratios (WCAG; 1.0 means identical luminance) from `MouseModels` body colours against `LightingService` terrain tints:

| Ground | mouse (150,112,80) | rat_runner (118,106,104) | chonk (128,128,150) | slinger (196,158,108) | carrier (255,200,64) |
|---|---|---|---|---|---|
| plains Grass | 1.88 | 2.21 | 1.63 | **1.05** | 1.53 |
| plains Ground (paths/patches) | **1.08** | 1.27 | **1.06** | 1.65 | 2.66 |
| forest LeafyGrass | **1.02** | 1.15 | 1.18 | 1.83 | 2.94 |
| beach Sand | 2.85 | 3.35 | 2.48 | 1.60 | **1.01** |
| hero grey #9AA3AD | 1.74 | 2.04 | 1.51 | **1.03** | 1.65 |

  - In `gameplay_forest_pc.png`, brown mice on the mud paths are hard to pick out.
  - Grey Chonks (radius 2.4) sit right next to the grey elephants and read as the same family of blob.
  - On a phone a basic mouse is about 16 pt across: radius 1.2 studs at about 6.9 pt per stud at zoom 66.
- **Fix:** no single body colour works on every ground, so add a structural separator.
  1. **A contact shadow under every enemy:**
     - One pooled flat cylinder per mouse in HordeRenderer, 0.05 thick, diameter 2.3 × radius.
     - Colour `#1E140F`, Transparency 0.45, Material SmoothPlastic, CastShadow off.
     - On LOD tiers, drop it beyond `ANIM_FULL`.
     - This gives contrast of at least 2.1 on every ground and anchors mice to the floor. Real shadows are weak from a 55° camera.
  2. **Darker, warmer base mouse**, with the cream muzzle and belly kept:
     - Recolour (150,112,80) → (96,62,44).
     - Contrast becomes 4.0 on plains grass, 2.1 on forest leafy and 6.1 on sand.
     - Lighten the forest path and mud tint to about (140,104,66) so dark mice also read on the paths.
  3. **Chonk to plum** (128,128,150) → (92,64,104). Against hero grey this is 3.4 instead of 1.5.
  4. **Slinger:** add a saturated red-orange sling pouch and a headband `#FF5A4E`, because its body equals grass and hero luminance.
  5. **Per-map rule (put it in STYLE.md):** ground tints sit in a mid-value band (relative luminance about 0.15–0.35). Enemies sit below 0.08 or carry a bright accent of at least 3:1.

### S2-1. Hits, kills and level-ups lack weight

- **Evidence:**
  - **Hits:** a hit gives directional sparks, a damage number, and a mouse white flash for 0.1 s (`HordeRenderer HIT_FLASH`). Crits add a star, rays and an FOV punch. That is good.
  - **Level-ups:** a level-up shows only the bottom card strip, "⬆ LEVEL UP! Pick one" (`UpgradeUI`). No world effect exists; grep finds no level handler in FxController.
  - **Damage taken:** taking damage shows only a red "-N" number. There is no screen-edge feedback and no low-HP warning (`hurt` handler, FxController lines 3159–3177).
  - **Damage numbers:** they are shown for every nearby hit regardless of who dealt it (cap 40). With 3 heroes and a squad of bots, that is noise.
- **Fixes:**
  - **Level-up burst** (client, on an `hud.level` increase):
    - A gold column: a Neon cylinder 0.4 × 14 studs, colour `#FFC93C`, Transparency 0.2 → 1 over 0.6 s.
    - An expanding ground ring of radius 1 → 9 over 0.35 s.
    - 24 `sparkles` particles, Speed 8–14, Lifetime 0.6–0.9.
    - A "LEVEL UP!" BillboardGui: Fredoka 40, gold with a `#5B3A1E` stroke, popping 1.4 → 1.0.
    - Knock nearby mice visually back by 1.5 studs.
    - A camera punch at strength 0.6.
  - **Hurt vignette:**
    - Four edge Frames with a `UIGradient` running Transparency 0.35 → 1 inward, colour `#C81E14`.
    - Flash in 0.05 s and fade over 0.4 s, at most once per 0.25 s.
    - Below 30% HP, pulse at 1.2 Hz with a minimum transparency of 0.55.
    - While downed, lower `ColorCorrection.Saturation` by 0.35.
  - **Damage-number hygiene:**
    - Show your own hits at full size.
    - Squad-mates' hits: 60% size and 0.4 transparency, or hide them via a setting.
    - Merge repeated hits on one target within 0.12 s into one rising number.
    - The Fx needs a `by` (attacker) field on `hit`; add it if it is missing.
  - **Kill streak counter** (PvE): "×12 STOMP!" under the status card. It resets after 2 s without a kill, with a pop at 25 / 50 / 100 kills and a pitch-rising sound once audio exists.
  - **Crumb vacuum:** within the pickup radius, crumbs should lerp to the hero over 0.15 s with a slight scale-down, not vanish.

### S2-2. The first match is full of simultaneous systems and explanations

- **Evidence:**
  - `Onboarding.luau` queues move, attack, crumbs, ability, squads, gear, extract, pois, route and revive.
  - The first run also surfaces Pressure (lobby card), curses and blessings, Double or Nothing, bounties, champions, lairs, POI kinds and gear swap keys.
  - Every hint is a text card in the bottom-right corner, about 15–25 words each.
  - Nothing points at anything in the world.
- **Fix: progressive disclosure for `stats.runs == 0`:**
  - Hide the Pressure card, the DoN option, bounty banners and curse chips.
  - Auto-select the Low route, with a one-liner.
  - **Objective arrows:** an in-world guide is an `Attachment` Beam from the hero to the next objective, the nearest live POI during waves, then the boss, then the Rind Gate. Use Width 0.6, Texture `rbxasset://textures/particles/sparkles_main.dds` (verify), TextureSpeed 2, colour gold, and FaceCamera.
  - Cut the hint text to 8 words or fewer, with an icon. Example: "WASD to move · attacks are automatic".

### S2-3. The lobby: blown-out neon, nothing to do, no social proof

- **Evidence:**
  - **Blown-out neon:** in `lobby.png` the ready pad and squad pads are large Neon discs (`LobbyWorld` lines 252 and 289: a 20-stud ready disc and 11-stud squad pads). They bloom into white blobs (bloom threshold 1.6), and the pad colours are lost.
  - **No leaderboards:** there are no physical leaderboards. HANDOFF lists "no leaderboard UI".
  - **Weak first instruction:** the lobby copy says "Pick an elephant and READY UP!" (but see S1-2), while the sign says "Pick a class and READY UP". The first instruction is text on a world sign behind the player.
- **Fix:**
  - **Pads:** make pad tops `SmoothPlastic` in the pad colour, with only a 0.6-stud Neon rim ring. Add a ParticleEmitter of rising motes (Rate 6, Lifetime 1.5, Speed 2) in the squad colour.
  - **Leaderboards:** add 2 SurfaceGui boards (Top Cheese this week, Most Mice Stomped) on the plaza edge facing the spawn, from `LeaderboardService`.
  - **Class statues:** they become clickable (ProximityPrompt "Try Ellie Fawn") to open the class picker on that class.
  - **First instruction:** a big pulsing READY button is already there. Add a gold Beam arrow from spawn to the ready pad for first-time players.

### S2-4. Art direction across the maps: nine recolours of one layout

- **Evidence:**
  - Every map is the same disc: an X of roads, a ring road, a river, 4 corner pads and a centre boss pad (`maps.png`). The variety is mostly the colour grade.
  - Tundra and moon are pastel-on-pastel with weak value range. Moon's whole palette sits between (120,130,200) and (160,170,230).
  - Volcano is a single red-brown field (`map_volcano.png` gameplay tile).
  - Swamp is uniform olive under heavy haze.
- **Fix:**
  - **Per-biome signature ground features** (Terrain, colliding, registered as obstacles):
    - volcano: Basalt columns, cracked-lava fissure lines with a Neon edge;
    - tundra: Glacier ice sheets with reflectance, plus snowdrifts;
    - moon: craters, i.e. a FillBall carve, dark Basalt rim and a lighter floor;
    - beach: tide pools of Water and wet Sand;
    - swamp: bog water pools and giant mushrooms.
  - **Value range:** each preset's ground should span at least 3 distinct values (dark, mid, light). Moon examples: floor (140,150,190), crater rims (70,70,95), dust highlights (210,215,240).
  - **Swamp haze:** reduce `atmosphere.density` to 0.30 or below.
  - **Volcano:** raise grade contrast; add `Slate` patches at (110,96,90) and lava-glow PointLights (Range 18, Brightness 1.5, `#FF7A2E`) inside the existing 29-light budget.

### S2-5. Top-down silhouettes: the back item, not the elephant, is what you see

- **Evidence:** the camera has fixed yaw and sits behind (+Z), so a hero moving up-screen shows its back. In the composites the back item (shield, water tank, propeller) and the hat are the readable shapes. Trunk, eyes and face are mostly hidden, and ears appear as two grey bumps.
- **Fix:**
  - Make ears 15% larger and tilt them 20° outward-up, so they read as an elephant from above.
  - Give each class a bold top-visible colour plate. Hat brims should have a diameter at least 1.2 × the head width, in a saturated class colour.
  - The squad ground ring already exists. Make it a 0.25-wide Neon ring at 0.3 transparency in the squad colour, radius 3.2, so allies and enemies read instantly in PvP.

### S2-6. Phone HUD density

- **Evidence** (`UiSizes.hud` non-dense values; 1100×620 design area scaled to about 0.52–0.57 on a 667×375 phone). Up to 9 concurrent widgets fit into a 375 pt-tall landscape screen:
  - the status card is 330 × 100 plus a squad panel of about 130;
  - the header is 560 wide, with tiles, title, phase, cheese, chips, boss bar and banner;
  - the minimap is 132 plus a kill feed of 4 × 28;
  - the bottom row holds gear slots and the ability.
  - The top-left column alone is about 40% of screen height. With text floors this is legible but crowded.
- **Fix (phone only):**
  - Kill feed: 2 rows.
  - Squad panel: icons plus HP bars only, with no names.
  - Header: scoreboard as pips only; hide the phase-text row during Waves.
  - Gear slots: collapse to a single "bag" button that expands.
  - Minimap: increase to 150 design px. It is the most useful widget on the big maps.

### S3 polish

- **Mobile controls:**
  - What is good: a single ability button with tap auto-aim and drag-to-aim, the jump button hidden, and automatic sprint.
  - Add a cooldown sweep and a "ready" pulse on the touch ability button that matches PC.
  - Optional: haptics with `HapticService` (small motor 0.3 for 0.05 s) on own hit taken and on level-up.
- **Results screen:** the count-up, XP bar and LEVEL UP pop are good. Without sound they feel flat; see S1-1.
  - Add a coin-burst particle when the cheese total lands.
  - Stagger the reveal: outcome, then placement, then cheese, then XP, with 0.4 s steps.
- **Loot reveal:** rarity beams exist. Add a Legendary ground shockwave plus 0.2 s of white screen flash at 0.6 transparency, and an Epic+ chat-style toast for the whole server ("X found a Legendary!") for social proof.
- **Emoji icons** (🧀💥🛡⚔) are used throughout the HUD. They render inconsistently on some Android devices. Keep them, and as soon as decals can be uploaded, swap the 10 most visible ones for image icons.
- **Champions and bosses:** strong, characterful designs. Champion Golem (yellow blocks) reads as a pile of crates. Give it a face (2 Neon eyes, `#FF5A2E`) and round the blocks with Ball shapes. Ice Dragon is thin and small for a boss: scale it 1.4× and add wing membranes as translucent `Glass` wedges at transparency 0.4.
- **POIs:**
  - They read well; the shrines and the shop cart are charming.
  - Message bottle and mousetrap field are flat from above. Give them a ground-glow ring in the POI colour.
  - Witch hut's roof is a dark purple blob. Lighten it to (120,80,170) with a Neon chimney ember.
- **Rind Gate:** good. It is the clearest "go here" visual in the game.
- **Post FX:**
  - DepthOfField is on for PC at radius 45–50. At zoom 60 that blurs the screen edges where mice approach. Reduce `FarIntensity` to 0.1 or below, or drop it in combat.
  - Bloom thresholds of 1.5–1.8 are fine except for large Neon surfaces (see S2-3).

## What already works (keep it)

- **UI foundation:** the Theme system, the text floor, touch sizing, safe insets, the compact PC layout and the minimised vote and extract bars are better than most of the genre.
- **Characters:** the champion, boss and mouse rigs with idle, walk, wind-up and death poses are charming and toy-like, and match STYLE.md.
- **Map readability:** the minimap with edge arrows, champion icons and the bounty ring is excellent for big-map navigation.
- **Mouse silhouettes:** fuse mouse (bomb), carrier (gold) and rat runner (long tail) are distinct.
- **Pooling:** VFX pooling and LOD tiers will keep mobile frame rates healthy.

## AI-mesh priorities (once credits exist)

`assets/models/PLAN.md` already ranks `mouse_mouse` first. Agreed, with one change: put **`hero_elephant` hood or suit** at #2, ahead of the bosses, because of S1-2. Every mesh should bake a 1–2 px dark outline into its texture (toon look); it reads far better from 60 studs.

---

## Top 10 upgrades (ordered by reception impact per effort)

1. **Add audio.** Add `Config/Sounds` and `SoundController`:
   - hook hit, die, crumb, level-up, telegraph, boss, portal and UI events;
   - use 3 SoundGroups, pitch variance and rate caps;
   - start with `rbxasset://sounds/*` placeholders (verify each in Studio), then Roblox-creator Toolbox ids or generated SFX uploaded through the existing pipeline. Ids must be supplied.
2. **Make the player an elephant.** Add a part-built ear and trunk hood on the avatar head (SpecialMesh spheres `#9AA3AD`, pink inner `#F2A7B5`, 3–4 trunk balls), plus optional grey BodyColors in runs. Shrink bots to about 0.65 so the human is never the smallest hero.
3. **Drop late joiners into bot seats** mid-match, or teleport them to a fresh server. Never make a new player wait a whole match in the lobby. Add a practice-mice yard as a fallback.
4. **Redo the store art from current models.**
   - The first thumbnail is a gameplay action shot (horde, VFX, damage numbers, HUD).
   - The icon is a close-up angry chibi elephant mid-swing with flying mice on sky blue, with a sticker outline and almost no text.
   - Fix the thumb_2 artefacts and the "13 bosses shows 10" mismatch.
5. **Fill the empty ground.**
   - Turn on `Terrain.Decoration` with GrassLength 0.7 on grass maps.
   - Add buried FillBall micro-relief of 0.8 studs or less.
   - Raise decor to `R * 3` with 1–3-part micro props.
   - Move parts from the backdrop (380 → 150) to the play floor.
6. **Make enemies readable.**
   - A pooled dark contact-shadow disc under every mouse: `#1E140F`, transparency 0.45, diameter 2.3 × radius.
   - Base mouse to (96,62,44).
   - Chonk to plum (92,64,104).
   - A red accent on slingers.
   - A ground-value band rule in STYLE.md.
7. **Add juice.**
   - A level-up world burst: gold column, ring, sparkles, "LEVEL UP!" billboard, mouse knockback.
   - A red edge vignette on damage and a low-HP pulse.
   - A PvE kill-streak counter.
   - A crumb vacuum.
   - Only your own damage numbers at full size.
8. **Simplify the first run.** Hide Pressure, DoN, bounties and curses until run 2. Auto-pick the Low route. Use an in-world gold Beam arrow to the next objective (POI → boss → Rind Gate), and keep hints to 8 words or fewer.
9. **Polish the lobby.**
   - Neon pads become SmoothPlastic with a thin Neon rim and mote particles.
   - Add SurfaceGui leaderboards facing the spawn.
   - Make the class statues clickable.
   - Add a Beam arrow to the ready pad for new players.
10. **Give each biome a signature.**
    - Map features: craters on the moon, basalt columns and glowing fissures on the volcano, ice sheets on the tundra, tide pools on the beach, bog pools and mushrooms in the swamp.
    - Give every ground at least 3 distinct values.
    - Swamp haze ≤ 0.30.
    - Phone HUD diet: kill feed 2 rows, pips-only scoreboard, bigger minimap.
