# AI mesh plan (R4 Graphics) — prepared, not generated

No paid generation has been run. The lead decides after checking credits.

## How a generated mesh reaches the game

1. Generate an image from the prompt below, then image-to-3D, and export `.glb`
   (or `.fbx`), around 2–8k triangles, one material with a baked colour texture.
2. Save it under `assets/models/` and add `{ "name": "<name>", "path": "<file>",
   "type": "Model" }` to `assets/models/manifest.json`.
3. `scripts/publish.py assets` uploads it and writes the id into
   `src/shared/Config/AssetIds.luau`.
4. At runtime the server's `Visuals/AssetLoader` loads each id with
   `InsertService:LoadAsset`. Scripts cannot set `MeshPart.MeshId`, because its
   write security is NotAccessible. The loader stores the model as
   `ReplicatedStorage.TrunkfallAssets.<name>`.
5. `HordeRenderer` then clones it in place of the part model, scaled to the
   hitbox. Put a `Radius` number attribute on the model to set the scale
   reference; otherwise half of its widest horizontal size is used. The 3-part
   LOD and the low-spec part models remain as they are.

Required names (exact): `mouse_<enemyId>` and `boss_<bossId>`. These are read today.
`hero_elephant` is reserved for an optional elephant suit, which
HeroDecor / BotModel would need to adopt.

Models must face -Z with their feet at Y = 0, be centred on the origin and have
no scripts (the loader deletes any it finds).

## House style (append to every prompt)

> Roblox-style smooth plastic, cute stylized, chunky rounded toy proportions,
> soft studio lighting, flat bright colours, clean silhouette, single object
> centred on plain white background, three-quarter front view, NOT Minecraft,
> no pixel textures, no voxels, no text, no gore.

## Priority order (most visual payoff first)

| # | name | why it benefits | prompt (before the house style) |
|---|---|---|---|
| 1 | `mouse_mouse` | on screen hundreds of times; the part model is the biggest "programmer art" tell | "a small round brown cartoon mouse minion with big pink ears, tiny pink nose, black bead eyes, long thin pink tail, standing on four short legs, mischievous grin" |
| 2 | `hero_elephant` | the player's identity; an elephant suit is also a planned cosmetic | "a heroic chubby grey baby elephant adventurer standing on four legs, huge floppy ears with pink insides, short curled trunk, small ivory tusks, a gold sash across the chest, determined friendly eyes" |
| 3 | `mouse_rat_runner` | fast flanker, silhouette must read as lean | "a lean fast grey cartoon rat runner with a red headband, long nose, long whip tail, leaning forward mid-sprint" |
| 4 | `mouse_chonk` | tank silhouette | "a very round fat grey-blue cartoon mouse hugging a wedge of yellow cheese, tiny legs, puffed cheeks" |
| 5 | `mouse_crumb_slinger` | ranged enemy | "a tan cartoon mouse holding a wooden slingshot, a little cloth sack of crumbs on its back" |
| 6 | `mouse_fuse_mouse` | readable danger | "a reddish cartoon mouse carrying a round black cartoon bomb on its back with a lit sparking fuse, nervous expression" |
| 7 | `mouse_carrier` | rare golden loot mouse | "a shiny golden cartoon mouse carrying a tiny treasure sack, sparkly, smug" |
| 8 | `boss_my_grandma` | marquee boss, the meme | "a giant sweet old grandma in a lilac cardigan and apron, white hair bun, round gold glasses, raising a huge pink fluffy slipper overhead, ball of red yarn in the other hand" |
| 9 | `boss_floating_witch` | gamba wheel identity | "a floating green-skinned cartoon witch in a purple robe and tall black hat with a gold band, riding a broom, a big colourful roulette spell wheel behind her" |
| 10 | `boss_spider_machine` | mech legs read poorly as parts | "a cute-but-menacing steel spider mech robot with eight segmented legs, a glass cockpit dome with a tiny mouse pilot, one big red laser eye" |
| 11 | `boss_giant_tree` | | "a giant friendly-angry cartoon oak tree monster with a carved face, glowing yellow eyes, branch arms with leaf mittens, acorns in a fluffy round canopy, root feet" |
| 12 | `boss_froggus` | | "a huge fat cartoon frog boss with a big cream belly, bulging eyes on top, wide grin with pink tongue, sitting on a lily pad, tiny gold crown" |
| 13 | `boss_serpent_sisters` | | "a coiled teal cartoon cobra with a golden hood pattern, yellow eyes, little fangs, three glowing charm beads on its coils" |
| 14 | `boss_corndog_bunny` | | "a fluffy white cartoon bunny boss with red eyes and tall pink-lined ears, swinging a giant corndog on a stick like a club, mustard and ketchup zigzags" |
| 15 | `boss_green_gorilla` | | "a muscular green cartoon gorilla boss with huge fists, a crown of bananas, a banana bandolier across the chest" |
| 16 | `boss_paper_dinosaur` | origami folds are hard with parts | "an origami T-rex folded from white paper, crisp folds and facets, red paper back spikes, tiny arms, big stomping legs" |
| 17 | `boss_hematite_snake` | | "a long segmented dark iron snake made of polished hematite plates, glowing red seams and eyes, a red horseshoe magnet floating above its head" |
| 18 | `boss_ice_dragon` | wings | "an ancient icy blue cartoon dragon with translucent crystal wings, ice horns and back spikes, frosty breath glow, four sturdy legs" |
| 19 | `boss_void_cat` | | "a sitting cosmic black cat filled with stars and galaxies, glowing cyan eyes, purple-lit ears, a curled tail with a star tip, a small moon floating nearby" |
| 20 | `boss_zoomzola` | | "a rolling wheel of blue-veined cheese with a cartoon face, running sneakers on little legs, speed lines, a green stink cloud trail" |

Budget suggestion: do 1–2 first (the mouse and the hero). They are on screen
all the time, and checking them in Studio validates the pipeline before the
13 bosses are spent.
