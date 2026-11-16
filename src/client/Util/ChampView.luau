--!strict
-- Pure Mouse Champion view helpers (v3, GDD-v2 §4b): squad buff chips and
-- names for the HUD / kill feed. No Roblox APIs (tests/specs/ClientV2.spec.luau).
--
-- Squad buffs arrive in Match.buffs = {{kind, untilT, stat?, mul?}} (the
-- player's squad, RunDirector). Champion buffs are stacked kinds
-- "champ_might#1", "champ_might#2", "champ_swift#1", ...

local ChampView = {}

ChampView.BUFF_ICON = {
	champ_might = "⚔",
	champ_swift = "💨",
} :: { [string]: string }

ChampView.BUFF_SHORT = {
	champ_might = "Might",
	champ_swift = "Stride",
} :: { [string]: string }

-- "champ_might#2" -> "champ_might", 2. Non-champion kinds -> nil.
function ChampView.splitKind(kind: any): (string?, number?)
	local k = tostring(kind)
	local base, n = string.match(k, "^(champ_[%a_]+)#(%d+)$")
	if base then
		return base, tonumber(n)
	end
	if string.match(k, "^champ_[%a_]+$") then
		return k, 1
	end
	return nil, nil
end

export type Chip = { base: string, stacks: number, left: number, maxLeft: number, mul: number? }

-- Active champion buffs grouped by base kind: stacks, the time until the next
-- stack drops (`left`) and until the last one does (`maxLeft`). Sorted by base.
function ChampView.buffChips(buffs: any, now: number): { Chip }
	local by: { [string]: Chip } = {}
	if type(buffs) == "table" then
		for _, b in buffs do
			if type(b) == "table" then
				local base = ChampView.splitKind(b.kind)
				local untilT = tonumber(b.untilT)
				if base and untilT and untilT > now then
					local left = untilT - now
					local c = by[base]
					if c then
						c.stacks += 1
						c.left = math.min(c.left, left)
						c.maxLeft = math.max(c.maxLeft, left)
					else
						by[base] =
							{ base = base, stacks = 1, left = left, maxLeft = left, mul = tonumber(b.mul) }
					end
				end
			end
		end
	end
	local out = {}
	for _, c in by do
		table.insert(out, c)
	end
	table.sort(out, function(a, b)
		return a.base < b.base
	end)
	return out
end

-- Buff def ({name, stat, mul, duration}) for a base kind from Config/Champions.
function ChampView.buffDef(champions: any, base: string): any
	local defs = if type(champions) == "table" then champions.defs else nil
	if type(defs) ~= "table" then
		return nil
	end
	for _, d in defs do
		if type(d) == "table" and type(d.buff) == "table" and d.buff.kind == base then
			return d.buff
		end
	end
	return nil
end

local STAT_TEXT = { damageMult = "damage", moveSpeed = "move speed" }

-- Tooltip: "Champion's Might: +25% damage per stack (2/2 stacks: +56%)."
function ChampView.buffTooltip(champions: any, chip: Chip, maxStacks: number?): string
	local def = ChampView.buffDef(champions, chip.base)
	local name = if def then tostring(def.name) else chip.base
	local mul = chip.mul or (if def then tonumber(def.mul) else nil) or 1
	local stat = if def then STAT_TEXT[def.stat] or tostring(def.stat) else "power"
	local per = math.floor((mul - 1) * 100 + 0.5)
	local total = math.floor((mul ^ chip.stacks - 1) * 100 + 0.5)
	return string.format(
		"%s: +%d%% %s per stack (%d/%d stacks: +%d%%). From slaying a Mouse Champion.",
		name,
		per,
		stat,
		chip.stacks,
		maxStacks or 2,
		total
	)
end

-- Display name of a champion id ("A Mouse Champion" when unknown).
function ChampView.name(champions: any, champId: any): string
	local defs = if type(champions) == "table" then champions.defs else nil
	local d = if type(defs) == "table" then defs[tostring(champId)] else nil
	if type(d) == "table" and type(d.name) == "string" then
		return d.name
	end
	return "a Mouse Champion"
end

-- Kill feed row text for {kind = "champion", ...}: (verb + name, lair badge?).
function ChampView.feedText(champions: any, e: any): (string, boolean)
	return "slew " .. ChampView.name(champions, e.champId), e.lair == true
end

return ChampView
