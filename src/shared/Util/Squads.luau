--!strict
-- The four squads of a v2 match (docs/GDD-v2.md §1). Pure data.

local Squads = {}

Squads.MAX = 4
Squads.SIZE = 3

Squads.LIST = {
	{ id = 1, name = "Swiss", color = { 255, 200, 60 } },
	{ id = 2, name = "Brie", color = { 245, 240, 220 } },
	{ id = 3, name = "Blue", color = { 80, 150, 255 } },
	{ id = 4, name = "Pepper Jack", color = { 235, 70, 60 } },
}

function Squads.get(id: number)
	return Squads.LIST[id]
end

function Squads.isValid(id: any): boolean
	return type(id) == "number" and Squads.LIST[id] ~= nil
end

return Squads
