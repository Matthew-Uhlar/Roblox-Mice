--!strict
-- SmartCast (iteration 8 §C, team Client): the phone "smart-cast" option. When
-- on, slot 1 casts by itself at the nearest mouse / boss in range as soon as it
-- is ready. It holds off in PvP fights (a rival hero close by) so it never
-- wastes the ability on the wrong target, and right after a manual cast.
-- Pure (Lune-tested, ClientIter8.spec); InputController applies it at 5 Hz.

local SmartCast = {}

SmartCast.RANGE = 34 -- studs: only targets this close (the auto-aim reach is 70)
SmartCast.PVP_RADIUS = 45 -- studs: a rival hero this close = a PvP fight, smart-cast off
SmartCast.MANUAL_GRACE = 1.5 -- s after a manual cast before smart-cast resumes
SmartCast.HZ = 5

export type Input = {
	enabled: boolean, -- the setting
	touch: boolean, -- phone controls
	inCombat: boolean,
	downed: boolean,
	ready: boolean, -- slot 1 off cooldown
	targetDist: number?, -- nearest enemy distance (nil = none)
	rivalDist: number?, -- nearest rival-squad hero (nil = none)
	sinceManual: number, -- s since the last manual cast
}

function SmartCast.shouldCast(i: Input): boolean
	if not (i.enabled and i.touch and i.inCombat and i.ready) or i.downed then
		return false
	end
	if i.sinceManual < SmartCast.MANUAL_GRACE then
		return false
	end
	if i.rivalDist ~= nil and i.rivalDist <= SmartCast.PVP_RADIUS then
		return false
	end
	return i.targetDist ~= nil and i.targetDist <= SmartCast.RANGE
end

return SmartCast
