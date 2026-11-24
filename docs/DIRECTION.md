# Project direction (lead, 2026-11-24)

Every iteration plan is checked against this page. Sources: the original brainstorm (`docs/brainstorm-2026-06.md`), the Zombie World series notes from the creator's website (`docs/research/zombie-world.md`), the owner's Liberty save (`docs/research/zwl-save-model.md`), and the owner's instructions. The gameplay video (https://youtu.be/eetAIASZnx4) is still to be watched: it needs a Gemini API key from the owner; notes go to `docs/research/zwl-video-notes.md`.

## The game in one line
A Zombie World Liberty–style wave survival with elephants vs mice, played on larger maps with extra objectives and squad PvP, carrying the original outline's run structure (route choices, bosses, double or nothing).

## Pillars (keep)
1. **Run structure from the original outline:** stages across cheese-themed maps; after each boss a route choice with low/mid/high risk-reward (a downside modifier plus a group buff); boss selection with downsides on harder picks; double or nothing; portals that can lead anywhere; fixed maps with randomised POI spawns. Upgrades must feel meaningful (no "+1% in rare cases" stats).
2. **Liberty's in-round power:** a safe currency for repeatable stat ranks (rinds, V menu) and a risky one for buffs lost on death (whey, stalls); a centre late-game store (the Altar); a swap stand; hero levels with listed gains; shared XP nearby; minibosses on timers; boost zones worth fighting over.
3. **Liberty's long-term chase:** lifetime kills (stomps) that unlock things; per-class level → prestige → 8-node ascension; difficulty ladder with Best Solo; gems with rolled stats by tier (2 personal sockets, owner decision), dust, upgrades; 30+ challenges; Overtime.
4. **Our additions:** larger maps with objectives, a shrinking storm, squad PvP (fair: long-term power is capped in PvP), champions, extraction.
5. **Co-op first, readable, fair:** no physics-driven mechanics (desync); rookies protected; bots labelled; never pay-to-win except the owner's explicit cheese-boost exception (`docs/decisions.md`).

## Each iteration should move all of these
- **Gameplay and mechanic depth:** new mechanics, deeper choices (talents, abilities, builds), more Liberty features, new classes toward Liberty's role spread.
- **Graphics:** meshes for everything (procedural mesh kit, `scripts/make-meshes.py`), better materials, effects and maps.
- **Animation:** smoother, more expressive rigs and ability animations for heroes, mice, bosses.
- **Polish and QoL:** readability, feedback, game feel.
- **Publish** after QC and the full check; report to the owner.

## Watch-outs
- Don't let PvP or power creep break the ladder (fresh Doomwheel ≤2%).
- Save safety on the live game (additive migrations, version bumps, read-only on older servers).
- Usage limits: run fewer agents at once and keep briefs tight.
