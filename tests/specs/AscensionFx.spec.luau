--!strict
-- (iteration 6, team Talents) Every Ascension node of every class has a combat effect, a
-- client Fx and a description, and each one shows up in a World.
local T = require("../lib/Test")
local fs = require("@lune/fs")
local Rng = require("../../src/shared/Util/Rng")
local World = require("../../src/shared/Combat/World")
local Defaults = require("../../src/shared/Combat/Defaults")
local Classes = require("../../src/shared/Config/Classes")
local AscensionNodes = require("../../src/shared/Config/AscensionNodes")
local Keystones = require("../../src/shared/Config/Keystones")
local Ascension = require("../../src/shared/Config/Ascension")

local DT = 1 / 30
-- the Fx kind each node's mechanic sends (TalentFx draws it)
local FX = { "secondWind", "wave", "state", "orb", "echo", "charged", "frenzy", "stomp" }

T.describe("Ascension nodes: data", function()
	local src = fs.readFile("src/client/Visuals/TalentFx.luau")
	T.it("8 nodes x every class: an effect, a mechanic, an Fx handler and a description", function()
		for _, cid in Classes.ORDER do
			for n = 1, AscensionNodes.COUNT do
				local node = AscensionNodes.node(cid, n) :: any
				T.truthy(node, cid .. " " .. n)
				local field, v = next(node.mech or {})
				T.truthy(field and Keystones.isField(field) and v > 0, cid .. " " .. n .. " mechanic")
				T.truthy(Keystones.phrase(field, v), "mechanic text")
				local text = AscensionNodes.describe(cid, n)
				T.truthy(#text > 30, cid .. " " .. n .. " description")
				T.truthy(string.find(text, Keystones.phrase(field, v) :: string, 1, true) ~= nil, "text has the numbers")
				T.truthy(string.find(src, '"' .. FX[n] .. '"', 1, true) ~= nil, "TalentFx draws " .. FX[n])
			end
		end
		T.eq(#Ascension.NODES, AscensionNodes.COUNT)
		for i, nd in Ascension.NODES do
			T.eq(nd.name, AscensionNodes.NAMES[i], "names match")
		end
	end)
	T.it("combine / behaviours add the mechanics (and keep the old numbers)", function()
		local d = AscensionNodes.combine("elephante", 8)
		for _, m in AscensionNodes.MECH do
			local f, v = next(m)
			T.eq(d.add[f :: string], v)
		end
		local b = AscensionNodes.behaviours("elephante", 1)
		T.eq(b.add.ascSecondWind, 1)
		T.eq(b.mul.maxHp, nil, "node 1's max HP stays in P's numbers")
	end)
end)

local function newWorld(seed: number): any
	return World.new({
		rng = Rng.new(seed),
		mods = Defaults.mods(),
		arenaRadius = 300,
		obstacles = {},
		enemyPool = { "mouse" },
		cycle = 1,
		stage = 1,
		enemyCap = 400,
		champions = false,
		carriers = false,
	} :: any)
end

T.describe("Ascension nodes: in a World", function()
	T.it("a hero with all 8 nodes shows every mechanic", function()
		for _, cid in Classes.ORDER do
			local w = newWorld(11)
			local cls = Classes.get(cid) :: any
			w:addPlayer(1, Defaults.stats(), table.clone(cls.weapon), table.clone(cls.ability), 0, 0, 1)
			w:setAscension(1, cid, 8)
			local p = w.players[1]
			for i = 1, 30 do
				local a = i / 30 * math.pi * 2
				local e = w:spawnEnemy("mouse", math.cos(a) * 6, math.sin(a) * 6)
				if e then
					e.hp, e.maxHp = 3, 3
				end
			end
			local seen: { [string]: boolean } = {}
			local function step(sec: number)
				for _ = 1, math.floor(sec / DT + 0.5) do
					for _, f in w:step(DT, w.now + DT) do
						if f.t == "tk" then
							seen[f.k] = true
						end
					end
				end
			end
			step(0.2)
			w:useAbility(1, 5, 0, w.now)
			step(1)
			p.iframeUntil, p.invulnUntil, p.hoverUntil = 0, 0, 0
			p.hp = p.maxHp * 0.3
			w:damagePlayer(p, p.maxHp * 0.1, "contact")
			for _ = 1, 4 do -- keep feeding mice for the frenzy
				for i = 1, 14 do
					local a = i / 14 * math.pi * 2
					local e = w:spawnEnemy("mouse", math.cos(a) * 4, math.sin(a) * 4)
					if e then
						e.hp, e.maxHp = 1, 1
					end
				end
				step(1)
			end
			step(8)
			for n, k in FX do
				T.truthy(seen[k], cid .. ": node " .. n .. " Fx '" .. k .. "'")
			end
		end
	end)
end)

return T.finish()
