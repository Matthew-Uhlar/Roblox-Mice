--!strict
-- Lobby start rules (pure; LobbyService applies them). QC2 M2 + QC1 #15.
--
--   * Who starts: ready players first, then idle players who are "auto-eligible",
--     oldest join first, capped at MAX_PARTY. A player who UN-readies sits out the
--     next start (sitOut) instead of cancelling it for everyone.
--   * Countdown: everyone willing is ready -> 5 s; some ready -> 20 s. Nobody
--     ready -> NO countdown (iter 5 A1: the 30 s auto-start is gone; a run only
--     starts from Ready). Once armed a countdown may only get SHORTER: toggling
--     Ready, leaving or joining can never push the start back. It is cancelled
--     when nobody is ready any more (or nobody is left to start).
--   * Idle players are still pulled into a start someone readied for (one party
--     per server). AFK: a player pulled in without pressing Ready who gave no
--     input during the run gets idleRuns + 1. At AFK_AUTO_RUNS (2) they are no
--     longer pulled in and must press Ready. Any input resets the counter.
--
--   * Busy (v4, QA-C M8): a player browsing the shop or the perk tree
--     (SetBusy) is never pulled in; pressing Ready still counts.
--
-- An entry: { ready: boolean, sitOut: boolean, idleRuns: number, joinedAt: number, busy: boolean? }
-- (plus any fields the caller keeps; they are passed through untouched).

local LobbyRules = {}

-- v2 (GDD-v2 §1): 12 seats = 4 squads x 3. Bots fill the seats nobody takes.
LobbyRules.MAX_PARTY = 12
LobbyRules.ALL_READY_SECONDS = 5
LobbyRules.SOME_READY_SECONDS = 20
LobbyRules.AFK_AUTO_RUNS = 2
LobbyRules.EPS = 0.05

export type Entry = {
	ready: boolean,
	sitOut: boolean,
	idleRuns: number,
	joinedAt: number,
	busy: boolean?,
	[string]: any,
}

export type Decision = {
	action: "arm" | "keep" | "cancel" | "none",
	seconds: number?, -- for "arm": the new countdown length
	kind: string?, -- "ready" (the old "auto" kind is gone, iter 5 A1)
}

-- Pulled into a run without pressing Ready?
function LobbyRules.autoEligible(e: Entry): boolean
	return not e.ready and not e.sitOut and e.busy ~= true and (e.idleRuns or 0) < LobbyRules.AFK_AUTO_RUNS
end

-- Will this player be in the next party (if there is room)?
function LobbyRules.willing(e: Entry): boolean
	return e.ready or LobbyRules.autoEligible(e)
end

-- The party the next start takes: ready first, then auto-eligible idle players.
function LobbyRules.party(entries: { Entry }, maxParty: number?): { Entry }
	local cands = {}
	for _, e in entries do
		if LobbyRules.willing(e) then
			table.insert(cands, e)
		end
	end
	table.sort(cands, function(a, b)
		if a.ready ~= b.ready then
			return a.ready
		end
		return a.joinedAt < b.joinedAt
	end)
	local out = {}
	for _, e in cands do
		if #out >= (maxParty or LobbyRules.MAX_PARTY) then
			break
		end
		table.insert(out, e)
	end
	return out
end

-- What to do with the countdown. `remaining` = seconds left on the armed
-- countdown (nil when none), `_kind` its current kind (unused since the "auto" kind went).
function LobbyRules.countdown(entries: { Entry }, remaining: number?, _kind: string?): Decision
	local nReady, nWilling = 0, 0
	for _, e in entries do
		if e.ready then
			nReady += 1
		end
		if LobbyRules.willing(e) then
			nWilling += 1
		end
	end
	-- iter 5 A1: no auto-start. Nobody ready -> nothing counts down.
	if nWilling == 0 or nReady == 0 then
		return { action = if remaining then "cancel" else "none" }
	end
	local want, wantKind
	if nReady == nWilling then
		want, wantKind = LobbyRules.ALL_READY_SECONDS, "ready"
	else
		want, wantKind = LobbyRules.SOME_READY_SECONDS, "ready"
	end
	if remaining == nil or remaining ~= remaining or remaining > want + LobbyRules.EPS then
		return { action = "arm", seconds = want, kind = wantKind }
	end
	-- never longer: keep the running countdown
	return { action = "keep", kind = wantKind }
end

-- A Ready toggle in the lobby. Un-readying sits out the next start; readying
-- (an input) clears both the sit-out and the AFK counter.
function LobbyRules.setReady(e: Entry, ready: boolean)
	if ready then
		e.sitOut = false
		e.idleRuns = 0
	elseif e.ready then
		e.sitOut = true
	end
	e.ready = ready
end

-- Any player input (a remote, real movement in a run).
function LobbyRules.noteInput(e: Entry)
	e.idleRuns = 0
end

-- After a run: returns the new idle-run count.
function LobbyRules.afterRun(idleRuns: number, autoPulled: boolean, hadInput: boolean): number
	if hadInput then
		return 0
	end
	if autoPulled then
		return (idleRuns or 0) + 1
	end
	return idleRuns or 0
end

return LobbyRules
