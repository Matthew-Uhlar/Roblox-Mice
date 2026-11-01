--!strict
-- Participant ids. Real players use their UserId, which is NEGATIVE for Studio
-- local-server test players (-1, -2, …). Bots therefore live in their own band
-- at or below BOT_BASE, so "is this a bot?" never depends on the sign alone.

local Ids = {}

Ids.BOT_BASE = -1000

-- The n-th bot id (n >= 1): -1001, -1002, …
function Ids.botId(n: number): number
	return Ids.BOT_BASE - n
end

function Ids.isBot(id: any): boolean
	return type(id) == "number" and id <= Ids.BOT_BASE
end

return Ids
