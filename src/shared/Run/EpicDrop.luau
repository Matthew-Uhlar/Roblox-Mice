--!strict
-- Epic boss drops (GDD §3.3: a High-route boss kill may drop an EPIC cosmetic).
-- Pure; RunDirector grants the result to each HUMAN participant (bots get nothing).
--
--   EpicDrop.pick(pool, owned, rng) -> cosmeticId?   nil when the player owns them all
--   EpicDrop.roll(pool, owned, rng) -> { kind = "cosmetic", id } | { kind = "reroll" }
--
-- The pool is Config/Cosmetics.epicPool(). Candidates are sorted first, so the
-- pick depends only on the rng and the set of unowned ids (not on table order).

local Rng = require("../Util/Rng")

local EpicDrop = {}

export type Drop = { kind: "cosmetic", id: string } | { kind: "reroll" }

function EpicDrop.pick(pool: { string }, owned: { [string]: any }?, rng: Rng.Rng): string?
	local have = owned or {}
	local seen: { [string]: boolean } = {}
	local cands: { string } = {}
	for _, id in pool do
		if type(id) == "string" and not have[id] and not seen[id] then
			seen[id] = true
			table.insert(cands, id)
		end
	end
	if #cands == 0 then
		return nil
	end
	table.sort(cands)
	return rng:pick(cands)
end

-- A cosmetic the player does not own yet, else a free reroll token.
function EpicDrop.roll(pool: { string }, owned: { [string]: any }?, rng: Rng.Rng): Drop
	local id = EpicDrop.pick(pool, owned, rng)
	if id then
		return { kind = "cosmetic", id = id }
	end
	return { kind = "reroll" }
end

return EpicDrop
