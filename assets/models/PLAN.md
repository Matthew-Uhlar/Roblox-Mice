# AI mesh plan (R4 Graphics) — prepared, not generated

No paid generation has been run. The lead decides after checking credits.

## Procedural meshes (in use; no paid generation)

`scripts/make-meshes.py` (modelling kit: `scripts/meshkit.py`; pins:
`scripts/requirements-meshes.txt`) builds every `mouse_<enemyId>`, `boss_<bossId>`,
the champions (named by their ids, e.g. `champ_captain`) and `hero_elephant` from
signed-distance shapes into `assets/models/meshes/*.glb` (palette baseColor texture,
studs, facing -Z, feet at Y = 0, X/Z centred). Output is deterministic.

**Animation pieces (iter7).** Each model is split into pieces, one glTF node/mesh
each, named after the client rig bones (`Visuals/Rig`): mice `body head earL earR
tail legFL legFR legBL legBR` (+ `weapon`, Neon `spark`, elite-only Neon `crown`),
champions `body head earL earR armL armR legFL legFR tail weapon cape` (+ `bolts`),
bosses `body` + channels (`wheel` spin, `wingL/R` roll, `armL/R`, `legXX` swing,
`head`/`tail` sway, `extra` bob/orbit, Neon `eyes`/`eye`), hero `body head trunk
earL earR tail` + legs. Groups are cut along per-piece regions with closed caps and
a small inset overlap at the joints. `meshes/meshes.json` lists triangles, size,
the design `radius` (mice 1.2, bosses 1, champions 2.4) and every piece (bounds
centre/size, joint, bone, parent, cond, anim, flat colour); the same table is
generated as `src/client/Visuals/MeshData.luau`.

**Runtime (iter7).** `Visuals/MeshModels` (used by `HordeRenderer`) clones the
template and, per piece: Size = authored size × (hitbox radius / MeshData radius)
(the importer drops glTF extras and may change units, so Size is set, not
inherited); position = authored bounds centre × scale (the importer re-centres
each MeshPart on its bounds); rotation relative to the body piece. Mice and
champions get the Rig skeleton from the piece joints (run cycle, ear flop, tail
sway, lunge, flinch squash, death); bosses play the piece anim channels. Tint:
texture swap: a tinted piece clears `TextureID` (and unparents a
`SurfaceAppearance`) and shows `Color` = its dominant palette colour lerped to
the state colour; state 0 restores the texture. The 3-part far LOD, the low-spec
mouse models and every missing or incomplete template (a piece missing) use the
part models. Entries are in `manifest.json`. Rebuild: `python3
scripts/make-meshes.py [names] [--sheet out.png] [--explode 0.5] [--manifest]`;
checked by `tests/specs/MeshManifest.spec.luau` and `RuntimeMeshes.spec.luau`.

**Iteration 8 meshes and runtime.** `wpn_<classId>` (11 class weapons, ClassGear grip
space), `build_turret` (body + turning `head`) / `build_barricade` (stretched to the
build length), `prop_totem / prop_stall / prop_class_stall / prop_altar / prop_swap`,
`obj_caravan / obj_beacon / obj_rescue_cage / obj_miniboss_camp`, and the landmark
kit `lm_<obstacle kind>` (every Props.OBSTACLES kind + ruins `lm_pillar`, `lm_mesa`).
`meshes.json` and `src/shared/Config/MeshData.luau` (plain numbers, shared by client
and server) carry each model's `shift`, so authored position = centre − shift.
Runtime: server `Visuals/MeshSuit` adds hero_elephant + weapon pieces to every
BotModel hero (bots, Herd Suit, statues, cosmetic preview via HeroVisuals) next to
the part body (attribute `MeshSet` mesh / parts, tag `TrunkfallMeshSet`); each client
shows one set (`MeshModels.applySets`, LocalTransparencyModifier). Client
`Visuals/MeshDress` streams landmark / prop / objective meshes over the server's part
models near the camera (cap 70, 30 on low-spec; Neon state accents stay), and
`BuildModels` uses the build meshes. All honour `Config/Visuals.USE_MESHES` and the
player setting Models: Classic, and fall back to the parts when a mesh is missing.

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
   hitbox (iter7: by the pieces in `Visuals/MeshData`; for other models a `Radius` attribute sets the scale
   reference; otherwise half of its widest horizontal size is used. The 3-part
   LOD and the low-spec part models remain as they are.

Required names (exact): `mouse_<enemyId>`, `boss_<bossId>` and the champion ids (`champ_<x>`). These are read today.
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
