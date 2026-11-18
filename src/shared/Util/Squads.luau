--!strict
-- The four squads of a v2 match (docs/GDD-v2.md §1). Pure data.
-- Colours come from the one shared palette, Config/SquadColors.

local SquadColors = require("../Config/SquadColors")

local Squads = {}

Squads.MAX = 4
Squads.SIZE = 3

Squads.LIST = {
	{ id = 1, name = "Swiss", color = SquadColors.rgb(1) },
	{ id = 2, name = "Brie", color = SquadColors.rgb(2) },
	{ id = 3, name = "Blue", color = SquadColors.rgb(3) },
	{ id = 4, name = "Pepper Jack", color = SquadColors.rgb(4) },
}

function Squads.get(id: number)
	return Squads.LIST[id]
end

function Squads.isValid(id: any): boolean
	return type(id) == "number" and Squads.LIST[id] ~= nil
end

return Squads
