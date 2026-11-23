--!strict
-- Mousepedia: the collection book (v4 plan, research §4.9). Pure data.
--
-- Pages list the ids of the game's own configs, so a new boss, champion, mouse,
-- gear item, map or class gets an entry automatically. An entry fills the first
-- time it is met (Data/Achievements.collect):
--   bosses     a boss defeated                (DataService.awardRun stats.bossIds, or collect)
--   champions  a Mouse Champion defeated      (stats.championIds, or collect)
--   mice       an enemy type stomped          (DataService.collect(player, "mice", enemyId))
--   gear       a gear item picked up          (DataService.collect(player, "gear", gearId))
--   maps       a stage played on that map     (stats.mapIds, or collect)
--   classes    a class reaching class level 5 (automatic, Data/Award)
-- Each NEW entry: +ENTRY_GOLDEN Golden Cheese and +Config/Pass.COLLECTION_XP Pass XP.
-- A finished page and the overall milestones give the listed reward once.

local Bosses = require("./Bosses")
local Champions = require("./Champions")
local Enemies = require("./Enemies")
local Gear = require("./Gear")
local Maps = require("./Maps")
local Classes = require("./Classes")
local Economy = require("./Economy") -- iteration 6: the cheese grind (x0.6)

export type Reward = {
	cheese: number?,
	goldenCheese: number?,
	cosmetic: string?,
	title: string?,
}

export type PageDef = {
	id: string,
	name: string,
	entries: { string },
	reward: Reward, -- for completing the page
}

local C = {}

C.ENTRY_GOLDEN = 5
C.CLASS_ENTRY_LEVEL = 5

local function copy(list: { string }): { string }
	return table.clone(list)
end

C.PAGES = {
	{
		id = "bosses",
		name = "Bosses",
		entries = copy(Bosses.ORDER),
		reward = { cosmetic = "hat_golden_rind", title = "title_boss_hunter" },
	},
	{
		id = "champions",
		name = "Mouse Champions",
		entries = copy(Champions.ORDER),
		reward = { goldenCheese = 50, title = "title_champion_slayer" },
	},
	{
		id = "mice",
		name = "Mice",
		entries = copy(Enemies.ORDER),
		reward = { cheese = Economy.cheese(500), title = "title_mouseologist" },
	},
	{
		id = "gear",
		name = "Gear",
		entries = copy(Gear.ORDER),
		reward = { goldenCheese = 100 },
	},
	{
		id = "maps",
		name = "Maps",
		entries = copy(Maps.ORDER),
		reward = { goldenCheese = 50, title = "title_cartographer" },
	},
	{
		id = "classes",
		name = "Classes",
		entries = copy(Classes.ORDER),
		reward = { title = "title_herdmaster" },
	},
} :: { PageDef }

-- Overall completion milestones (percent of every entry on every page).
C.MILESTONES = {
	{ pct = 25, reward = { goldenCheese = 100 } },
	{ pct = 50, reward = { goldenCheese = 150, title = "title_collector" } },
	{ pct = 75, reward = { goldenCheese = 200 } },
	{ pct = 100, reward = { cosmetic = "trail_archivist" } },
} :: { { pct: number, reward: Reward } }

C.byId = {} :: { [string]: PageDef }
C.entryOf = {} :: { [string]: { [string]: boolean } }
for _, page in C.PAGES do
	C.byId[page.id] = page
	local set = {}
	for _, id in page.entries do
		set[id] = true
	end
	C.entryOf[page.id] = set
end

function C.get(pageId: any): PageDef?
	if type(pageId) ~= "string" then
		return nil
	end
	return C.byId[pageId]
end

-- True when `entryId` is a real entry of `pageId`.
function C.isEntry(pageId: any, entryId: any): boolean
	local set = if type(pageId) == "string" then C.entryOf[pageId] else nil
	return set ~= nil and type(entryId) == "string" and set[entryId] == true
end

function C.totalEntries(): number
	local n = 0
	for _, page in C.PAGES do
		n += #page.entries
	end
	return n
end

return C
