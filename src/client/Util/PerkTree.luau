--!strict
-- Pure perk-tree helpers (no Roblox APIs; tested in tests/specs/ClientV2.spec.luau).
--
-- GDD-v2 §5: each class has 3 branches x 5 tiers. Tier t of a branch needs
-- the tier t - 1 perk of that branch, so a branch unlocks in order. A perk
-- costs `cost` points (Config/ClassPerks: tier t costs t; default 1).
-- Config/ClassPerks (Team R3) is written in parallel, so `extract` and
-- `normalise` accept several layouts:
--   * mod[classId] / mod.byClass[classId] / mod.TREES[classId] / mod.trees[classId]
--   * mod.get(classId) / mod.tree(classId) / mod.forClass(classId) (functions)
--   * a flat list (mod.LIST / mod.ALL / array) of perks with classId, branch, tier
-- and per class either { branches = { {id, name, perks = {…}} } } or an array of
-- branches, each a list of perks or { perks = {…} }.

local PerkTree = {}

PerkTree.BRANCHES = 3
PerkTree.TIERS = 5

export type Perk = {
	id: string,
	name: string,
	description: string,
	tier: number,
	branch: number,
	cost: number,
	icon: string?,
}

export type Branch = {
	id: string,
	name: string,
	color: { number }?,
	perks: { [number]: Perk }, -- tier -> perk (may have holes)
}

export type Tree = { branches: { Branch }, placeholder: boolean }

local function str(v: any, default: string): string
	if v == nil then
		return default
	end
	return tostring(v)
end

local function asPerk(p: any, branch: number, tierFallback: number): Perk?
	if type(p) ~= "table" then
		return nil
	end
	local id = p.id or p.key or p.perkId
	if id == nil then
		return nil
	end
	local tier = math.floor(tonumber(p.tier) or tierFallback)
	return {
		id = tostring(id),
		name = str(p.name or p.title or p.displayName, tostring(id)),
		description = str(p.description or p.desc or p.text or p.effectText, ""),
		tier = math.clamp(tier, 1, PerkTree.TIERS),
		branch = branch,
		cost = math.max(1, math.floor(tonumber(p.cost) or 1)),
		icon = if type(p.icon) == "string" then p.icon else nil,
	}
end

-- Calls a config accessor safely (pcall: a bad config must never break the UI).
local function tryCall(f: any, ...: any): any
	if type(f) ~= "function" then
		return nil
	end
	local ok, res = pcall(f, ...)
	return if ok then res else nil
end

-- Raw per-class tree from a ClassPerks module of unknown layout (or nil).
function PerkTree.extract(mod: any, classId: string): any
	if type(mod) ~= "table" then
		return nil
	end
	for _, fname in { "branches", "tree", "forClass", "treeFor", "getTree", "get" } do
		local r = tryCall(mod[fname], classId)
		if type(r) == "table" and next(r) ~= nil then
			-- A flat list of perk defs (they carry a tier and no perks list).
			local first = r[1]
			if type(first) == "table" and first.tier ~= nil and first.perks == nil then
				return { flat = r }
			end
			return r
		end
	end
	for _, field in { "byClass", "BY_CLASS", "TREES", "trees", "CLASSES", "classes" } do
		local t = mod[field]
		if type(t) == "table" and type(t[classId]) == "table" then
			return t[classId]
		end
	end
	if type(mod[classId]) == "table" then
		return mod[classId]
	end
	-- Flat list of perks tagged with their class.
	for _, field in { "LIST", "ALL", "list", "all", "PERKS", "perks" } do
		local t = mod[field]
		if type(t) == "table" then
			local mine = {}
			for _, p in t do
				if type(p) == "table" and tostring(p.classId or p.class) == classId then
					table.insert(mine, p)
				end
			end
			if #mine > 0 then
				return { flat = mine }
			end
		end
	end
	return nil
end

local function branchKeyIndex(key: any, keys: { string }): number
	local n = tonumber(key)
	if n then
		return math.floor(n)
	end
	local s = tostring(key)
	local i = table.find(keys, s)
	if i then
		return i
	end
	table.insert(keys, s)
	return #keys
end

-- Normalises a raw tree into exactly BRANCHES branches. A missing tree gives a
-- placeholder (every node "???", locked), so the screen still renders.
function PerkTree.normalise(raw: any): Tree
	local branches: { Branch } = {}
	local placeholder = true
	local function ensure(i: number): Branch
		local b = branches[i]
		if not b then
			b = { id = "branch" .. i, name = "Branch " .. i, color = nil, perks = {} }
			branches[i] = b
		end
		return b
	end
	if type(raw) == "table" then
		if type(raw.flat) == "table" then
			local keys: { string } = {}
			for _, p in raw.flat do
				local bi = if tonumber(p.branchIndex)
					then math.floor(tonumber(p.branchIndex) :: number)
					else branchKeyIndex(p.branch or p.branchId or 1, keys)
				if bi >= 1 and bi <= PerkTree.BRANCHES then
					local perk = asPerk(p, bi, 1)
					if perk then
						ensure(bi).perks[perk.tier] = perk
						placeholder = false
					end
				end
			end
			for i, k in keys do
				if i <= PerkTree.BRANCHES and tonumber(k) == nil then
					ensure(i).name = k
				end
			end
		else
			local list = if type(raw.branches) == "table" then raw.branches else raw
			local bi = 0
			for _, b in ipairs(list) do
				bi += 1
				if bi > PerkTree.BRANCHES then
					break
				end
				local br = ensure(bi)
				if type(b) == "table" then
					br.id = str(b.id or b.key, br.id)
					br.name = str(b.name or b.title, br.name)
					if type(b.color) == "table" then
						br.color = b.color
					end
					local perks = if type(b.perks) == "table" then b.perks else b
					local ti = 0
					for _, p in ipairs(perks) do
						ti += 1
						local perk = asPerk(p, bi, ti)
						if perk then
							br.perks[perk.tier] = perk
							placeholder = false
						end
					end
				end
			end
		end
	end
	for i = 1, PerkTree.BRANCHES do
		ensure(i)
	end
	return { branches = branches, placeholder = placeholder }
end

-- Points spent in branch `b` (sum of the costs of its taken perks).
function PerkTree.spentIn(tree: Tree, b: number, taken: { [string]: any }): number
	local br = tree.branches[b]
	if not br then
		return 0
	end
	local n = 0
	for _, p in br.perks do
		if taken[p.id] then
			n += p.cost
		end
	end
	return n
end

-- Total points spent on perks that exist in this tree.
function PerkTree.spent(tree: Tree, taken: { [string]: any }): number
	local n = 0
	for b = 1, #tree.branches do
		n += PerkTree.spentIn(tree, b, taken)
	end
	return n
end

-- Free points: an explicit server value wins; otherwise 1 point per level
-- after the first, minus what is spent (Data/ClassProgress is the authority).
function PerkTree.freePoints(level: number, spent: number, explicit: any): number
	local e = tonumber(explicit)
	if e then
		return math.max(0, math.floor(e))
	end
	return math.max(0, math.floor(level) - 1 - spent)
end

-- "taken" | "available" | "locked", plus why it is locked:
-- "tier" (earlier tiers of the branch first), "points" (no free point),
-- "missing" (placeholder node) or nil.
function PerkTree.nodeState(
	tree: Tree,
	b: number,
	t: number,
	taken: { [string]: any },
	free: number
): (string, string?)
	local br = tree.branches[b]
	local perk = br and br.perks[t]
	if not perk then
		return "locked", "missing"
	end
	if taken[perk.id] then
		return "taken", nil
	end
	local prev = if t > 1 then br.perks[t - 1] else nil
	if (prev and not taken[prev.id]) or PerkTree.spentIn(tree, b, taken) < t - 1 then
		return "locked", "tier"
	end
	if free < perk.cost then
		return "locked", "points"
	end
	return "available", nil
end

export type NodePos = { x: number, y: number } -- top-left, px
-- vertical bar (x = centre, from y down h); a horizontal one (rows layout) runs
-- from x right `w`, centred on y
export type Link = { branch: number, tier: number, x: number, y: number, h: number, w: number? }
export type Rect = { x: number, y: number, w: number, h: number }
export type TreeLayout = {
	node: number, -- node diameter
	colW: number,
	rowH: number,
	header: number,
	nodes: { [number]: { [number]: NodePos } },
	links: { Link },
	horizontal: boolean?, -- rows layout: one row per branch, tiers left to right
	labels: { [number]: { [number]: Rect } }?, -- name label under each node (rows layout)
	bands: { [number]: Rect }?, -- branch title strip above each row (rows layout)
}

-- Lays out a branches x tiers node graph in a w x h box: one column per
-- branch, tier 1 at the top, a `header` band above for the branch titles.
-- Nodes are centred in their cells and capped so they never touch; each link
-- joins tier t to tier t + 1 in the same column.
function PerkTree.layout(
	w: number,
	h: number,
	branches: number?,
	tiers: number?,
	node: number?,
	header: number?
): TreeLayout
	local nb = math.max(1, branches or PerkTree.BRANCHES)
	local nt = math.max(1, tiers or PerkTree.TIERS)
	local head = math.max(0, header or 0)
	local colW = math.max(1, w) / nb
	local rowH = math.max(1, h - head) / nt
	local size = math.floor(math.min(node or 72, colW * 0.8, rowH * 0.8))
	size = math.max(size, 8)
	local nodes: { [number]: { [number]: NodePos } } = {}
	local links: { Link } = {}
	for b = 1, nb do
		nodes[b] = {}
		local cx = colW * (b - 0.5)
		for t = 1, nt do
			local cy = head + rowH * (t - 0.5)
			nodes[b][t] = { x = cx - size / 2, y = cy - size / 2 }
			if t < nt then
				local y1 = cy + size / 2
				local y2 = head + rowH * (t + 0.5) - size / 2
				table.insert(links, { branch = b, tier = t, x = cx, y = y1, h = math.max(0, y2 - y1) })
			end
		end
	end
	return { node = size, colW = colW, rowH = rowH, header = head, nodes = nodes, links = links }
end

-- Touch layout (QC-B V2-m6): one ROW per branch and the tiers left to right,
-- which fits far bigger nodes in a wide phone panel than 5 stacked tiers. Each
-- row starts with a `bandW` column for the branch title, then the tier cells;
-- a node sits above a `label` strip for its name (sized for the phone text
-- floor), the pair centred in the row. Nodes are as big as fit (capped at
-- `node`); labels are at most `labelW` wide and never cross their column.
function PerkTree.layoutRows(
	w: number,
	h: number,
	branches: number?,
	tiers: number?,
	opts: {
		node: number?,
		bandW: number?,
		label: number?,
		gap: number?,
		labelW: number?,
	}?
): TreeLayout
	local o = opts or {}
	local nb = math.max(1, branches or PerkTree.BRANCHES)
	local nt = math.max(1, tiers or PerkTree.TIERS)
	local W = math.max(1, w)
	local bandW = math.clamp(o.bandW or 150, 0, W * 0.4)
	local labelH = math.max(0, o.label or 24)
	local gap = math.max(0, o.gap or 4)
	local colW = (W - bandW) / nt
	local rowH = math.max(1, h) / nb
	local size = math.floor(math.min(o.node or 140, colW * 0.85, rowH - labelH - 2 - 2 * gap))
	size = math.max(size, 8)
	local lw = math.max(1, math.min(o.labelW or 200, colW - 6))
	local nodes: { [number]: { [number]: NodePos } } = {}
	local labels: { [number]: { [number]: Rect } } = {}
	local bands: { [number]: Rect } = {}
	local links: { Link } = {}
	for b = 1, nb do
		nodes[b], labels[b] = {}, {}
		local top = rowH * (b - 1)
		bands[b] = { x = 0, y = top, w = bandW, h = rowH }
		local y = top + math.max(gap, (rowH - (size + 2 + labelH)) / 2)
		for t = 1, nt do
			local cx = bandW + colW * (t - 0.5)
			nodes[b][t] = { x = cx - size / 2, y = y }
			labels[b][t] = { x = cx - lw / 2, y = y + size + 2, w = lw, h = labelH }
			if t < nt then
				local x1 = cx + size / 2
				local x2 = bandW + colW * (t + 0.5) - size / 2
				table.insert(
					links,
					{ branch = b, tier = t, x = x1, y = y + size / 2, h = 6, w = math.max(0, x2 - x1) }
				)
			end
		end
	end
	return {
		node = size,
		colW = colW,
		rowH = rowH,
		header = 0,
		nodes = nodes,
		links = links,
		horizontal = true,
		labels = labels,
		bands = bands,
	}
end

-- The perk-tree screen (UI/PerkTreeUI): panel size in design px and the layout
-- for its canvas. Touch devices get the wide panel and the rows layout
-- (QC-B V2-m6); mouse / gamepad keep the classic column tree.
PerkTree.PANEL = { w = 900, h = 580 }
PerkTree.PANEL_WIDE = { w = 1240, h = 600 }
PerkTree.ROW_LABEL = 26 -- name strip: the 12 px micro text floored for phones (24) + 2

function PerkTree.panelSize(wide: boolean): (number, number)
	local p = if wide then PerkTree.PANEL_WIDE else PerkTree.PANEL
	return p.w, p.h
end

function PerkTree.screenLayout(wide: boolean, w: number, h: number): TreeLayout
	if wide then
		return PerkTree.layoutRows(w, h - 6, PerkTree.BRANCHES, PerkTree.TIERS, {
			node = 140,
			bandW = 150,
			label = PerkTree.ROW_LABEL,
			gap = 4,
			labelW = 200,
		})
	end
	local rowH = (h - 40) / PerkTree.TIERS
	return PerkTree.layout(w, h - 6, PerkTree.BRANCHES, PerkTree.TIERS, math.min(68, rowH - 22), 40)
end

return PerkTree
