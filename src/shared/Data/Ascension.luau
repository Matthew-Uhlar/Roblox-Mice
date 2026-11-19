--!strict
-- (iteration 2) Ascension nodes and the Prestige run bonus (Team P). Pure.
-- Content: Config/Ascension. Nodes are DERIVED from the saved Prestige and class stomps
-- (node n needs both of its gates and every node before it), so nothing extra is saved
-- except the chosen look (classes[id].look).

local Types = require("../Types")
local A = require("../Config/Ascension")
local ClassProgress = require("./ClassProgress")
local RunBonus = require("./RunBonus")

type Profile = Types.Profile

local Ascension = {}

local function block(profile: Profile, classId: string): any
	local classes = (profile :: any).classes
	return if type(classes) == "table" then classes[classId] else nil
end

local function n(v: any): number
	return if type(v) == "number" and v == v and v > 0 and math.abs(v) ~= math.huge then math.floor(v) else 0
end

-- Nodes unlocked (0..8) for a class block.
function Ascension.nodes(st: any): number
	if type(st) ~= "table" then
		return 0
	end
	local p = ClassProgress.prestige(st)
	local stomps = n(st.stomps)
	local count = 0
	for _, node in A.NODES do
		if p >= node.prestige and stomps >= node.stomps then
			count = node.node
		else
			break
		end
	end
	return count
end

-- Liberty-style 8-bit string, e.g. "11100000".
function Ascension.bits(st: any): string
	local k = Ascension.nodes(st)
	return string.rep("1", k) .. string.rep("0", #A.NODES - k)
end

-- Looks the class owns ("bull", "matriarch", "ancient").
function Ascension.looks(st: any): { string }
	local k = Ascension.nodes(st)
	local out = {}
	for _, look in A.LOOKS do
		if k >= A.LOOK_NODE[look] then
			table.insert(out, look)
		end
	end
	return out
end

-- The look to show: the chosen one if owned, else the best owned, else nil (base).
function Ascension.look(profile: Profile, classId: string): string?
	local st = block(profile, classId)
	local owned = Ascension.looks(st)
	if #owned == 0 then
		return nil
	end
	local chosen = if type(st) == "table" then st.look else nil
	if chosen == "base" then
		return nil
	end
	if type(chosen) == "string" and table.find(owned, chosen) then
		return chosen
	end
	return owned[#owned]
end

-- Chooses the look (Net SetEvo: stage 1 = base, 2 = Bull, 3 = Matriarch, 4 = Ancient).
-- Reasons: "bad_class" | "class_locked" | "bad_stage" | "look_locked"
function Ascension.setLook(profile: Profile, classId: any, stage: any): (boolean, string?)
	if not ClassProgress.isClass(classId) then
		return false, "bad_class"
	end
	if not profile.unlockedClasses[classId] then
		return false, "class_locked"
	end
	if type(stage) ~= "number" or stage ~= math.floor(stage) or stage < 1 or stage > #A.LOOKS + 1 then
		return false, "bad_stage"
	end
	local st: any = ClassProgress.ensure(profile, classId)
	if stage == 1 then
		st.look = "base"
		return true, nil
	end
	local look = A.LOOKS[stage - 1]
	if not table.find(Ascension.looks(st), look) then
		return false, "look_locked"
	end
	st.look = look
	return true, nil
end

-- Personal run bonus of the class played: Prestige (+0.5% PvE damage, +0.25% max HP
-- per Prestige up to P40) and the numeric ascension nodes. extras.ascNodes tells M1
-- how many behaviour nodes to apply.
function Ascension.bonus(profile: Profile, classId: string): RunBonus.Bonus
	local b = RunBonus.new()
	local st = block(profile, classId)
	if type(st) ~= "table" then
		return b
	end
	local p = math.min(ClassProgress.prestige(st), A.BONUS_PRESTIGE_CAP)
	RunBonus.add(b, "pve", nil, A.PVE_PER_PRESTIGE * p)
	RunBonus.add(b, "pctStat", "maxHp", A.HP_PER_PRESTIGE * p)
	local k = Ascension.nodes(st)
	for _, node in A.NODES do
		if node.node <= k then
			RunBonus.add(b, "pctStat", "maxHp", node.maxHpPct or 0)
			RunBonus.add(b, "cutStat", "cooldownMult", node.cooldownCut or 0)
		end
	end
	RunBonus.add(b, "extra", "ascNodes", k)
	return b
end

-- Squad aura part of a member's ascension (node 8: +5% PvE damage).
function Ascension.squadPve(profile: Profile, classId: string?): number
	if type(classId) ~= "string" then
		return 0
	end
	local k = Ascension.nodes(block(profile, classId))
	local v = 0
	for _, node in A.NODES do
		if node.node <= k then
			v += node.squadPve or 0
		end
	end
	return v
end

-- View for one class (merged into profile.classes[id] by ProfileSchema.view).
function Ascension.view(st: any): { [string]: any }
	local k = Ascension.nodes(st)
	local nextNode = A.NODES[k + 1]
	return {
		nodes = k,
		bits = Ascension.bits(st),
		looks = Ascension.looks(st),
		look = if type(st) == "table" and type(st.look) == "string" then st.look else nil,
		next = if nextNode
			then { node = nextNode.node, prestige = nextNode.prestige, stomps = nextNode.stomps }
			else nil,
	}
end

return Ascension
