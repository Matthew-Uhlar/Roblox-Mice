-- Prints the Robux catalog from src/shared/Config/Monetization.luau as JSON, for
-- scripts/publish.py products. Usage: lune run scripts/catalog.luau
--
-- `assetId` is the id the game resolves (Monetization.luau's own id, else the
-- generated Config/ProductIds.luau one); `generatedId` is the ProductIds value.
-- When they differ, the id was typed into Monetization.luau by hand and wins.
local serde = require("@lune/serde")
local Monetization = require("../src/shared/Config/Monetization") :: any
local ProductIds = require("../src/shared/Config/ProductIds") :: any

local out = {}
for _, item in Monetization.ALL do
	table.insert(out, {
		key = item.key,
		kind = item.kind,
		name = item.name,
		description = item.benefit,
		price = item.fallbackPrice,
		adOnly = item.adOnly == true,
		assetId = item.assetId,
		generatedId = ProductIds[item.key] or 0,
	})
end
print(serde.encode("json", out))
