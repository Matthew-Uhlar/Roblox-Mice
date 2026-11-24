--!strict
-- (iteration 6, team Talents) Pure model + layout of a class talent tree for
-- UI/PerkTreeUI (Config/ClassPerks: 3 branches x 9 nodes on 5 rows; ranks, row gates,
-- requirements, exclusive choices, keystones). No Instances: Lune-testable.
--
--   TalentTree.model(ClassPerks, classId, set, free) -> Model
--       node states: "maxed" | "partial" (some ranks, can take more) | "available"
--       | "locked" (why: "gate" | "requires" | "exclusive" | "points") | "capped"
--       (some ranks, no point left)
--   TalentTree.layout(nodeSize) -> {w, h, branchW, pos(bi, row, col) -> (x, y)}

local TalentTree = {}

TalentTree.NODE = 54 -- px
TalentTree.KEYSTONE = 66
TalentTree.ROW_H = 84
TalentTree.COL_W = 76
TalentTree.HEAD_H = 54
TalentTree.BRANCH_GAP = 24
TalentTree.PAD = 14

export type NodeView = {
	def: any,
	rank: number,
	maxRank: number,
	state: string,
	why: string?,
}
export type BranchView = {
	def: any,
	spent: number,
	nodes: { NodeView },
	byId: { [string]: NodeView },
}
export type Model = {
	classId: string,
	branches: { BranchView },
	spent: number,
	free: number,
	placeholder: boolean,
}

local function rankOf(set: { [string]: any }, def: any): number
	local r = 0
	for k = 1, def.maxRank or 1 do
		local key = if k == 1 then def.id else def.id .. "#" .. k
		if set[key] == true then
			r = k
		else
			break
		end
	end
	return r
end
TalentTree.rankOf = rankOf

function TalentTree.model(cp: any, classId: string, set: { [string]: any }?, free: number?): Model
	local taken = set or {}
	local f = math.max(0, math.floor(tonumber(free) or 0))
	local out: Model = { classId = classId, branches = {}, spent = 0, free = f, placeholder = true }
	local list = if type(cp) == "table" and type(cp.branches) == "function" then cp.branches(classId) else nil
	if type(list) ~= "table" or #list == 0 or type(list[1].nodes) ~= "table" then
		return out
	end
	out.placeholder = false
	for _, b in list do
		local bv: BranchView = { def = b, spent = 0, nodes = {}, byId = {} }
		for _, d in b.nodes do
			local r = rankOf(taken, d)
			bv.spent += r * (d.cost or 1)
			local nv: NodeView = { def = d, rank = r, maxRank = d.maxRank or 1, state = "locked", why = nil }
			table.insert(bv.nodes, nv)
			bv.byId[d.id] = nv
		end
		out.spent += bv.spent
		table.insert(out.branches, bv)
	end
	for _, bv in out.branches do
		for _, nv in bv.nodes do
			local d = nv.def
			local below = 0
			for _, o in bv.nodes do
				if o.def.tier < d.tier then
					below += o.rank * (o.def.cost or 1)
				end
			end
			local reqOk = #(d.requires or {}) == 0
			for _, rid in d.requires or {} do
				local o = bv.byId[rid]
				if o and o.rank > 0 then
					reqOk = true
				end
			end
			local exclOk = true
			if d.exclusive then
				for _, o in bv.nodes do
					if o ~= nv and o.def.exclusive == d.exclusive and o.rank > 0 then
						exclOk = false
					end
				end
			end
			if nv.rank >= nv.maxRank then
				nv.state = "maxed"
			elseif not exclOk then
				nv.state, nv.why = "locked", "exclusive"
			elseif below < (d.gate or 0) then
				nv.state, nv.why = "locked", "gate"
			elseif not reqOk then
				nv.state, nv.why = "locked", "requires"
			elseif f < (d.cost or 1) then
				nv.state, nv.why = if nv.rank > 0 then "capped" else "locked", "points"
			else
				nv.state = if nv.rank > 0 then "partial" else "available"
			end
		end
	end
	return out
end

-- Canvas size and node centres for 3 branches side by side (row 1 at the top).
function TalentTree.layout(): { w: number, h: number, branchW: number }
	local branchW = TalentTree.COL_W * 3
	return {
		w = TalentTree.PAD * 2 + branchW * 3 + TalentTree.BRANCH_GAP * 2,
		h = TalentTree.HEAD_H + TalentTree.ROW_H * 5 + TalentTree.PAD,
		branchW = branchW,
	}
end

function TalentTree.pos(bi: number, row: number, col: number): (number, number)
	local branchW = TalentTree.COL_W * 3
	local x = TalentTree.PAD + (bi - 1) * (branchW + TalentTree.BRANCH_GAP) + (col - 0.5) * TalentTree.COL_W
	local y = TalentTree.HEAD_H + (row - 0.5) * TalentTree.ROW_H
	return x, y
end

-- Tooltip lines for a node view (exact numbers from the def).
function TalentTree.tooltip(nv: NodeView, branchName: string?): string
	local d = nv.def
	local kind = if d.kind == "keystone"
		then "KEYSTONE"
		elseif d.kind == "choice" then "CHOICE (pick one of two)"
		else string.format("Rank %d/%d", nv.rank, nv.maxRank)
	local per = if nv.maxRank > 1 then " (per rank)" else ""
	local status = if nv.state == "maxed"
		then '<font color="#FFD65C">Maxed</font>'
		elseif nv.state == "available" or nv.state == "partial" then '<font color="#7CE07C">Tap to learn (1 point)</font>'
		elseif nv.why == "gate" then string.format(
			'<font color="#FF8A7A">Locked: spend %d points in %s rows above first</font>',
			d.gate or 0,
			branchName or "this branch's"
		)
		elseif nv.why == "requires" then '<font color="#FF8A7A">Locked: learn a linked talent above first</font>'
		elseif nv.why == "exclusive" then '<font color="#FF8A7A">You chose the other talent of this pair</font>'
		else '<font color="#FF8A7A">Needs a free perk point</font>'
	return string.format("<b>%s</b>  · %s\n%s%s\n%s", d.name, kind, d.description, per, status)
end

return TalentTree
