--!strict
-- Pure model of the Robux shop v2 (docs/V4-PLAN.md "Robux shop v2",
-- docs/qa/V4-C-progression.md §4). No Roblox APIs; specs run it in Lune.
--
-- Tabs: Featured · Cosmetics · Passes · Golden Cheese · Boosts · Herd Pass · Cheese Shop.
-- Rules this model enforces (and the spec checks):
--   * Featured never carries a timer, countdown or "leaving soon" text, and
--     the rotation is the same for everyone on a given day.
--   * Owned items say "Owned" and never show a price.
--   * Benefit text is split into short bullets; the full text is always
--     reachable (`details`), never cut.
--   * Ad-only and unconfigured-subscription items are hidden.

local ShopModel = {}

ShopModel.TABS = { "Featured", "Cosmetics", "Passes", "Golden Cheese", "Boosts", "Herd Pass", "Cheese Shop" }
ShopModel.SHORT = {
	Featured = "★ Featured",
	Cosmetics = "🎩 Cosmetics",
	Passes = "🎫 Passes",
	["Golden Cheese"] = "✨ Golden",
	Boosts = "⚡ Boosts",
	["Herd Pass"] = "🐘 Herd Pass",
	["Cheese Shop"] = "🧀 Cheese",
}

local function lower(s: any): string
	return string.lower(tostring(s or ""))
end

-- Which tab a Config/Monetization item belongs to. An explicit `tab` (or
-- `shopTab`) field on the item wins, so Team P can place new items.
function ShopModel.tabFor(item: any): string?
	if type(item) ~= "table" or item.adOnly == true then
		return nil
	end
	local explicit = item.tab or item.shopTab
	if type(explicit) == "string" and table.find(ShopModel.TABS, explicit) then
		return explicit
	end
	local key = lower(item.key)
	if item.kind == "subscription" then
		return "Golden Cheese"
	end
	if
		item.herdPass == true
		or item.passPremium == true
		or item.passSeason ~= nil
		or string.find(key, "herd_pass", 1, true)
		or string.find(key, "pass_premium", 1, true)
	then
		return "Herd Pass"
	end
	if
		string.find(key, "starter", 1, true)
		or string.find(key, "bundle", 1, true)
		or string.find(key, "emote", 1, true)
		or item.bundle == true
		or item.oneTime == true
		or item.covers ~= nil
		or item.skinPasses ~= nil
		or item.emotes ~= nil
		or (item.kind == "product" and item.cosmetics ~= nil)
	then
		return "Featured"
	end
	if item.kind == "pass" then
		return "Passes"
	end
	if item.boostSeconds or item.secondWindTokens or item.respecTokens then
		return "Boosts"
	end
	if item.goldenCheese then
		return "Golden Cheese"
	end
	return "Boosts"
end

-- Benefit text -> up to `max` short bullets (split on ". ", ";" and ":" lists).
-- `more` is true when the bullets don't hold the whole text (show "Details").
function ShopModel.bullets(text: any, max: number?): ({ string }, boolean)
	local s = tostring(text or "")
	s = (s:gsub("%s+", " "))
	s = (s:gsub("^%s+", ""):gsub("%s+$", ""))
	local out: { string } = {}
	if s == "" then
		return out, false
	end
	local limit = max or 4
	local pieces: { string } = {}
	-- sentences first ("1,150" and "2.5" are kept: split only on ". " / "; ")
	local buf = s .. " "
	local start = 1
	while start <= #buf do
		local a, b = string.find(buf, "[%.;!] ", start)
		if not a then
			table.insert(pieces, string.sub(buf, start))
			break
		end
		local stop = if string.sub(buf, a, a) == ";" then a - 1 else a
		table.insert(pieces, string.sub(buf, start, stop))
		start = (b :: number) + 1
	end
	for _, p in pieces do
		local t = (p:gsub("^%s+", ""):gsub("%s+$", ""))
		t = (t:gsub("%.$", ""))
		if t ~= "" then
			table.insert(out, t)
		end
	end
	local more = #out > limit
	while #out > limit do
		table.remove(out)
	end
	-- a very long single bullet is cut at a word with "…" (the Details view has it all)
	for i, b in out do
		if #b > 110 then
			local cut = string.sub(b, 1, 104)
			cut = cut:gsub("%s+%S*$", "")
			out[i] = cut .. "…"
			more = true
		end
	end
	return out, more
end

-- Owned state of a Robux item from the profile view (`passes` map from
-- MonetizationService; `purchasesOnce` / `entitlements` from Team P).
function ShopModel.owned(item: any, profile: any): boolean
	if type(item) ~= "table" or type(profile) ~= "table" then
		return false
	end
	local key = tostring(item.key)
	if item.kind == "pass" then
		local passes = profile.passes
		return type(passes) == "table" and (passes[key] == true or table.find(passes, key) ~= nil)
	end
	if item.kind == "subscription" then
		return profile.club == true and string.find(lower(key), "club", 1, true) ~= nil
	end
	local once = profile.purchasesOnce
	if type(once) == "table" and (once[key] == true or table.find(once, key) ~= nil) then
		return true
	end
	local ent = profile.entitlements
	if type(ent) == "table" and (ent[key] == true or table.find(ent, key) ~= nil) then
		return true
	end
	if item.herdPass == true or string.find(lower(key), "herd_pass", 1, true) then
		return profile.passPremium == true
	end
	return false
end

-- One-time items (starter pack) hide once owned; permanent passes stay with "Owned".
function ShopModel.oneTime(item: any): boolean
	return type(item) == "table"
		and (
			item.oneTime == true
			or item.oncePerAccount == true
			or string.find(lower(item.key), "starter", 1, true) ~= nil
		)
end

-- A bundle that would give you things twice (it covers a pass you own) or a
-- pass that a bundle you own already covers: the UI shows this text instead
-- of a price (MonetizationService refuses that prompt anyway). nil = buyable.
function ShopModel.blocked(item: any, profile: any, all: { any }?): string?
	if type(item) ~= "table" or type(profile) ~= "table" then
		return nil
	end
	local passes = if type(profile.passes) == "table" then profile.passes else {}
	local ent = if type(profile.entitlements) == "table" then profile.entitlements else {}
	if type(item.covers) == "table" then
		for _, k in item.covers do
			if passes[k] == true then
				return "✔ You own part"
			end
		end
	end
	if item.kind == "pass" then
		for _, other in all or {} do
			if type(other.covers) == "table" and table.find(other.covers, item.key) and ent[other.key] then
				return "✔ Owned (bundle)"
			end
		end
	end
	return nil
end

-- Items for a tab, in display order (cheapest first, owned passes last).
function ShopModel.itemsFor(tab: string, products: { any }?, profile: any): { any }
	local out = {}
	for _, it in products or {} do
		if ShopModel.tabFor(it) == tab then
			local owned = ShopModel.owned(it, profile)
			if it.kind == "subscription" and it.configured == false then
				continue -- Cheese Club: only once it is live (C m6)
			end
			if owned and ShopModel.oneTime(it) then
				continue
			end
			table.insert(out, it)
		end
	end
	table.sort(out, function(a, b)
		local oa, ob = ShopModel.owned(a, profile), ShopModel.owned(b, profile)
		if oa ~= ob then
			return not oa
		end
		local pa, pb = tonumber(a.price) or 1e9, tonumber(b.price) or 1e9
		if pa ~= pb then
			return pa < pb
		end
		return tostring(a.name) < tostring(b.name)
	end)
	return out
end

-- Robux button text. Live price only (`price` from GetProductInfoAsync).
function ShopModel.robuxLabel(owned: boolean, configured: boolean, price: number?): string
	if owned then
		return "✔ Owned"
	elseif not configured then
		return "Coming soon"
	elseif price then
		local s = tostring(math.floor(price))
		return "R$ " .. s
	end
	return "R$ —"
end

-- Deterministic daily rotation, identical for every player: picks `n`
-- entries from `pool` (sorted by id first) with a small LCG seeded by `day`.
-- Owned entries stay in (greyed by the UI), never re-rolled per player.
function ShopModel.rotation(pool: { any }, day: number, n: number): { any }
	local sorted = table.clone(pool)
	table.sort(sorted, function(a, b)
		return tostring(a.itemId or a.id) < tostring(b.itemId or b.id)
	end)
	local out = {}
	local seed = (math.floor(day) * 7919 + 104729) % 2147483647
	local count = math.min(n, #sorted)
	for _ = 1, count do
		seed = (seed * 48271) % 2147483647
		local i = (seed % #sorted) + 1
		table.insert(out, table.remove(sorted, i))
	end
	return out
end

-- Featured cosmetics: the Shop config's own `featured(day)` when Team P adds
-- one, else 4 Golden Cheese + 2 cheese cosmetics by the shared rotation.
function ShopModel.featuredCosmetics(entries: { any }, day: number, shopCfg: any): { any }
	if type(shopCfg) == "table" and type(shopCfg.featured) == "function" then
		local ok, list = pcall(shopCfg.featured, day)
		if ok and type(list) == "table" then
			return list
		end
	end
	local golden, cheese = {}, {}
	for _, e in entries do
		if e.kind == "cosmetic" or e.kind == "skin" then
			table.insert(if e.currency == "golden" then golden else cheese, e)
		end
	end
	local out = ShopModel.rotation(golden, day, 4)
	for _, e in ShopModel.rotation(cheese, day + 1000, 2) do
		table.insert(out, e)
	end
	return out
end

-- Text guard for Featured: true if a string looks like sales pressure
-- (timers, countdowns, "only N left", "% off"). Featured never shows these.
function ShopModel.isPressureText(s: string): boolean
	local l = string.lower(s)
	for _, pat in { "%d+:%d%d", "left", "ends", "hurry", "limited", "% off", "last chance", "expires", "⏱" } do
		if string.find(l, pat) then
			return true
		end
	end
	return false
end

return ShopModel
