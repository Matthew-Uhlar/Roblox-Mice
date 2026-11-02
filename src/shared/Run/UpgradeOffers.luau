--!strict
-- Rolls level-up cards (GDD §5): Common 60 / Rare 30 / Epic 9 / Legendary 1,
-- shifted by luck. Each card is unique within an offer; maxed upgrades and
-- other classes' class-only upgrades never appear. If a rarity has nothing
-- left it is skipped and the other weights are renormalised. If fewer
-- upgrades are eligible than `count`, fewer cards are returned (possibly 0).

local Rng = require("../Util/Rng")
local Upgrades = require("../Config/Upgrades")

type UpgradeDef = Upgrades.UpgradeDef -- Types.UpgradeDef + optional abilityMul

local UpgradeOffers = {}

UpgradeOffers.DEFAULT_COUNT = 3
local BASE_WEIGHTS: { [string]: number } = { Common = 60, Rare = 30, Epic = 9, Legendary = 1 }
UpgradeOffers.BASE_WEIGHTS = table.freeze(BASE_WEIGHTS)

-- Luck > 0 shrinks Common and grows the rarer weights (Legendary the most);
-- luck < 0 does the opposite. Luck 2: ~17% Epic, ~3% Legendary.
local LUCK_SCALE: { [string]: number } = { Common = -0.25, Rare = 0.1, Epic = 0.4, Legendary = 0.8 }

function UpgradeOffers.rarityWeights(luck: number?): { [string]: number }
	local L = luck or 0
	if L ~= L then
		L = 0
	end
	L = math.clamp(L, -10, 50)
	local out = {}
	for rarity, base in UpgradeOffers.BASE_WEIGHTS do
		local k = LUCK_SCALE[rarity]
		local f
		if k >= 0 then
			f = if L >= 0 then 1 + k * L else 1 / (1 + k * -L)
		else
			f = if L >= 0 then 1 / (1 + -k * L) else 1 + -k * -L
		end
		out[rarity] = base * f
	end
	return out
end

-- Upgrades that may still be offered to this class with these stacks.
function UpgradeOffers.eligible(classId: string, stacks: { [string]: number }): { UpgradeDef }
	local out = {}
	for _, def in Upgrades.list do
		local have = stacks[def.id] or 0
		if have < def.maxStacks and (def.classOnly == nil or def.classOnly == classId) then
			table.insert(out, def)
		end
	end
	return out
end

function UpgradeOffers.roll(
	rng: Rng.Rng,
	classId: string,
	stacks: { [string]: number },
	luck: number,
	count: number?
): { UpgradeDef }
	local want = math.max(0, math.floor(count or UpgradeOffers.DEFAULT_COUNT))
	local buckets: { [string]: { UpgradeDef } } = { Common = {}, Rare = {}, Epic = {}, Legendary = {} }
	for _, def in UpgradeOffers.eligible(classId, stacks) do
		table.insert(buckets[def.rarity], def)
	end
	local weights = UpgradeOffers.rarityWeights(luck)
	local result: { UpgradeDef } = {}
	while #result < want do
		local names: { string } = {}
		local ws: { number } = {}
		for _, rarity in Upgrades.RARITIES do
			if #buckets[rarity] > 0 and weights[rarity] > 0 then
				table.insert(names, rarity)
				table.insert(ws, weights[rarity])
			end
		end
		if #names == 0 then
			break
		end
		local bucket = buckets[names[rng:weightedIndex(ws)]]
		local i = rng:nextInt(1, #bucket)
		table.insert(result, table.remove(bucket, i) :: UpgradeDef)
	end
	return result
end

-- A reroll replaces the cards of the SAME offer: the offerId is kept, because
-- the client swaps the cards of a queued offer by id (QC1 #3). Returns nil when
-- nothing is left to offer (the caller keeps the old cards in that case).
function UpgradeOffers.reroll(
	offer: { offerId: number, cards: { UpgradeDef } },
	rng: Rng.Rng,
	classId: string,
	stacks: { [string]: number },
	luck: number?,
	count: number?
): { offerId: number, cards: { UpgradeDef } }?
	local cards = UpgradeOffers.roll(rng, classId, stacks, luck or 0, count)
	if #cards == 0 then
		return nil
	end
	return { offerId = offer.offerId, cards = cards }
end

return UpgradeOffers
