--!strict
-- SquadAlerts (iteration 7 §B 4-5, team Client): pure maths for the downed-
-- squadmate edge arrows and the automatic "needs revive" ping. No Roblox APIs
-- (Lune-tested, ClientIter7.spec).
--
--   downedMates(party, me)              PartyHud entries with downed = true (not me)
--   revivePos(pings, id, now)           the latest "revive" ping by hero `id`
--   arrow(sx, sy, behind, w, h, margin, safeTop?, safeBottom?)
--                                       -> (x, y, angleDeg)? on the screen edge, nil
--                                          when the target is on screen
--   label(name, dist, untilT, now)      "Name · 42m · 9s"

local Minimap = require("./Minimap")

local SquadAlerts = {}

SquadAlerts.MARGIN = 34 -- px from the screen edge
SquadAlerts.MAX_ARROWS = 4
SquadAlerts.PING_TTL = 10 -- s a revive ping position stays usable without a live model

export type Mate = { id: number, name: string, downedUntil: number? }

function SquadAlerts.downedMates(party: any, me: number?): { Mate }
	local out: { Mate } = {}
	if type(party) ~= "table" then
		return out
	end
	for k, e in party do
		local id = tonumber(k) or (if type(e) == "table" then tonumber(e.id) else nil)
		if id and id ~= me and type(e) == "table" and e.downed == true and e.dead ~= true then
			table.insert(out, {
				id = id,
				name = if type(e.name) == "string" then e.name else "Squadmate",
				downedUntil = tonumber(e.downedUntil),
			})
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

-- Position of the newest "revive" ping by `id` within PING_TTL, else nil.
function SquadAlerts.revivePos(pings: any, id: number, now: number): (number?, number?)
	if type(pings) ~= "table" then
		return nil, nil
	end
	local bx, bz, bt = nil, nil, -math.huge
	for _, p in pings do
		if type(p) == "table" and p.kind == "revive" and tonumber(p.by) == id then
			local t = tonumber(p.t) or 0
			if t > bt and now - t <= SquadAlerts.PING_TTL then
				bx, bz, bt = tonumber(p.x), tonumber(p.z), t
			end
		end
	end
	return bx, bz
end

-- An edge arrow for a target at viewport (sx, sy) (behind = behind the camera)
-- on a (w, h) viewport. safeTop / safeBottom keep it off HUD bars. nil when the
-- target is on screen.
function SquadAlerts.arrow(
	sx: number,
	sy: number,
	behind: boolean,
	w: number,
	h: number,
	margin: number?,
	safeTop: number?,
	safeBottom: number?
): (number?, number?, number?)
	local m = margin or SquadAlerts.MARGIN
	local x, y, ang = Minimap.edgeArrow(sx, sy, behind, w, h, m)
	if x == nil or y == nil then
		return nil, nil, nil
	end
	x = math.clamp(x, m, w - m)
	y = math.clamp(y, m + (safeTop or 0), h - m - (safeBottom or 0))
	return x, y, ang
end

function SquadAlerts.label(name: string, dist: number?, untilT: number?, now: number?): string
	local parts = { name }
	if dist then
		table.insert(parts, string.format("%dm", math.floor(dist + 0.5)))
	end
	if untilT and now then
		local left = math.ceil(untilT - now)
		if left > 0 then
			table.insert(parts, string.format("%ds", left))
		end
	end
	return table.concat(parts, " · ")
end

return SquadAlerts
