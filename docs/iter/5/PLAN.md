# Iteration 5 plan (lead), 2026-11-21

Iteration 4 is live. The owner asked for:
1. Remove the lobby auto start.
2. Let the player turn (rotate) the camera.
3. Classes unlock more ability slots as they level: at class level 10 a hero takes **2** abilities into a round, not 1.
4. Review Zombie World Liberty's features and add the ones still missing.

## Phase A: the concrete requests (start now)

**A1. No auto start (team Lobby).**
- When nobody is ready, nothing counts down. A run starts only from Ready (the existing ready / all-ready countdowns stay).
- Remove `LobbyRules.AUTO_START_SECONDS` behaviour and the `"auto"` countdown kind; `autoStart` in the lobby state stays `false`/nil, so old clients are safe.
- Bot fill still happens at start. Studio solo testing must still be possible by pressing Ready.
- Play Again / returning players: no auto start either.
- Update specs (`RunLobby`, the runtime specs that relied on the 30 s auto start: make them press Ready instead).

**A2. Rotatable camera (team Client).**
- Yaw is free; pitch and zoom keep their current limits.
- PC: hold right mouse and drag; also the Q/E-free keys `,` and `.` (or arrows with no conflict) to rotate in steps. Gamepad: right stick X when not aiming. Phone: two-finger twist or a drag on empty screen outside the thumbstick and buttons.
- A "reset camera" control (middle mouse / a setting) snaps back to north-up.
- Movement stays camera-relative (PlayerModule already uses the camera's yaw).
- Everything that assumed a fixed yaw must follow the camera: cursor aim (`AimAt`), gamepad aim, ability aim, the look-ahead, the minimap (rotate the map or the arrow), offscreen objective arrows, and spectating.
- Saved setting `cameraYaw` is not needed; `cameraRotate = true/false` is optional.

**A3. Ability slots by class level (team Abilities, server/shared; team Client for UI).**
- Slots: **1 at level 1, 2 at level 10, 3 at level 20.** Prestige ≥ 1 keeps all three slots (the level resets, the slots don't).
- Each class still has 3 abilities (base at 1, alternates at 5 and 15). A hero equips different abilities in its slots; no duplicates.
- Profile (additive): `classes[id].abilities = { slot1, slot2?, slot3? }`. Migrate from the old single `ability` (it becomes slot 1). Keep `ability` readable for old code paths.
- `SelectAbility(classId, abilityId, slot?)`: validated (unlocked, slot unlocked, no duplicate; swapping two slots allowed).
- `Run/Stats.compute` returns `abilities: {AbilityDef}` (slot order); `ability` stays = slot 1.
- `World`: each slot has its own cooldown; `world:useAbility(id, aimX, aimZ, now, slot?)`. Ability-cooldown modifiers (gems, cards, ranks, uniques) apply to every slot. Snapshots/HUD carry per-slot cooldowns.
- `UseAbility(aimX, aimZ, slot?)`: validated, rate-limited per slot.
- Bots get slots by their (bot) level and use every slot (BotBrain).
- Keys: slot 1 Space / Q (as now), slot 2 **E** (Second Wind keeps E while downed), slot 3 **R**. Gamepad and phone: one button per unlocked slot. HUD shows each slot with its cooldown; the lobby hero screen gets a loadout row (locked slots show "Level 10" / "Level 20").
- Balance guard: CombatTtk and IntegrationDifficulty must stay green; if extra slots make Doomwheel too easy, raise ability cooldowns for slots 2–3 (×1.25) rather than nerf slot 1.

## Phase B: Zombie World Liberty gap review (team Research, now) → lead verifies → build

- Output: `docs/iter/5/ZWL-GAPS.md`: each Liberty feature, whether we have it (with file evidence), and a priority. Public sources only; our decoded save model (`docs/research/zwl-save-model.md`) and `docs/research/zombie-world.md` are the base.
- The lead picks the valid, highest-value gaps and assigns them to the teams in a "Phase B build" section below.
- Rules as always: mechanics only, no copied names or art; never Robux on gems, dust, prestige, ascension, challenges.

## Rules (owner instruction)
- Message only the lead, only when necessary, and keep it concise.
- Your files only. No commits, no stash, no full `check.sh` (use `scripts/test.sh <filter>`).
- Run `stylua` only on files you changed.
