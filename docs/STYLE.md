# Characters & style guide (v0.1)

> Brainstorm action item: "Characters & Style". Theme: **Elephants vs Mice**.

## Visual pillars

1. **Readable from a phone at arm's length.** Chunky silhouettes and high
   contrast between heroes (grey and large), mice (small, brown and pink) and
   ground (saturated cheese colours).
2. **Toy-like.** Rounded shapes, flat colours, soft lighting. No gore: defeated
   mice burst into cheese crumbs (supports the *Mild* maturity rating).
3. **Danger is red, reward is gold.** Telegraphs are always red or orange
   translucent shapes that fill before they hit. Loot, crumbs and blessings are
   gold or yellow. Curses are purple.

## Palette

| Use | Colour |
|---|---|
| Cheese gold (UI accent, rewards) | `#FFC93C` |
| Cream (panels) | `#FFF4D6` |
| Rind brown (text, outlines) | `#5B3A1E` |
| Herd grey (heroes) | `#9AA3AD` |
| Mouse brown | `#8B6B4E`, pink ears `#F2A7B5` |
| Danger telegraph | `#FF4B3E` at 60% transparency |
| Curse purple | `#8E5CF7` |
| Route tiers | Low `#5BD16B`, Mid `#FFC93C`, High `#FF5A4E` |
| Rarity | Common `#B8B8B8`, Rare `#4EA8FF`, Epic `#B36BFF`, Legendary `#FF9A2E` |

Each map recolours the ground with its cheese (see `src/shared/Config/Maps.luau`).

## Characters

- **Heroes (elephants):** use standard Roblox characters so player avatars stay
  visible, which matters for cosmetics sales. Each class adds a **class sash and
  accessory** (Le F'ante's beret, Filet's chef hat, Fizzante's goggles). Later,
  an "elephant suit" layered accessory per class is sold as a cosmetic and also
  given free to new players.
- **Bots:** the same sash colours, a visible 🤖 tag, and a slightly
  desaturated body so they never pass as real players.
- **Mice:** at most 2–5 parts each (body, ears, tail). Elites are gold-tinted
  with a tiny crown. Variants differ by silhouette first and colour second:
  Rat Runner is long and thin, Chonk is round, Crumb Slinger carries a
  slingshot and Fuse Mouse has a lit fuse.
- **Bosses:** 3–8× hero size, each with one exaggerated feature you can read
  instantly (Grandma's slipper, the Witch's spell wheel, Corndog Bunny's stick).

## UI and audio

- Font: Fredoka One for headers, Gotham for body text. Minimum touch target 48 px.
- Numbers pop: damage numbers are white, crits are big and yellow, healing is green.
- Audio direction: bouncy brass and woodwinds. Mice squeak in a pitch-shifted
  chorus, and boss themes add a kazoo layer as a running joke. Every telegraph
  has a distinct wind-up sound so players can react without looking.

## Naming rules

Puns welcome, IP never: no Disney, Riot, WB or Coca-Cola names (see GDD renames).
Every name must pass Roblox text filtering and make sense in translation.
