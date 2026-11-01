--!strict
-- Per-run Second Wind and reroll-token accounting (Team D). Pure. DataService keeps
-- one state per player per run and exposes useSecondWind / useReroll.
--
-- Second Wind (GDD §3.5 + monetization research):
--   * the first self-revive of a run is free (no token);
--   * at most 1 self-revive per stage (free or token);
--   * at most 2 token revives per run;
--   * no token revive while a boss is below 10% HP or on a Double-or-Nothing stage;
--   * a token revive grants no rewards and marks the run unranked (leaderboards).
-- Reroll tokens (cheese-only, never Robux): at most 2 token rerolls per stage, on top
-- of RunDirector's 1 free reroll per stage.

local Types = require("../Types")
local Monetization = require("../Config/Monetization")

type Profile = Types.Profile

export type State = {
	freeUsed: number,
	tokenRevives: number,
	revivesByStage: { [string]: number },
	rerollsByStage: { [string]: number },
	usedToken: boolean, -- any Second Wind token used -> run is unranked
}

export type ReviveCtx = {
	bossHpFrac: number?, -- current boss hp fraction if a boss is alive
	doubleOrNothing: boolean?, -- this stage is a Double-or-Nothing stage
}

local RunTokens = {}

function RunTokens.new(): State
	return { freeUsed = 0, tokenRevives = 0, revivesByStage = {}, rerollsByStage = {}, usedToken = false }
end

local function validStage(stageKey: any): boolean
	return type(stageKey) == "string" and #stageKey > 0 and #stageKey <= 32
end

-- (true, "free" | "token") or (false, reason). Consumes a token from the profile when needed.
function RunTokens.useSecondWind(
	state: State,
	profile: Profile,
	stageKey: string,
	ctx: ReviveCtx?
): (boolean, string)
	local R = Monetization.RULES
	if not validStage(stageKey) then
		return false, "bad_stage"
	end
	if (state.revivesByStage[stageKey] or 0) >= R.maxSelfRevivesPerStage then
		return false, "stage_cap"
	end
	if state.freeUsed < R.freeSecondWindsPerRun then
		state.freeUsed += 1
		state.revivesByStage[stageKey] = (state.revivesByStage[stageKey] or 0) + 1
		return true, "free"
	end
	if state.tokenRevives >= R.maxTokenRevivesPerRun then
		return false, "run_cap"
	end
	if ctx then
		if ctx.doubleOrNothing then
			return false, "blocked_double_or_nothing"
		end
		if ctx.bossHpFrac and ctx.bossHpFrac < R.tokenReviveBlockedBelowBossHp then
			return false, "blocked_boss_low"
		end
	end
	if profile.secondWindTokens <= 0 then
		return false, "no_tokens"
	end
	profile.secondWindTokens -= 1
	state.tokenRevives += 1
	state.usedToken = true
	state.revivesByStage[stageKey] = (state.revivesByStage[stageKey] or 0) + 1
	return true, "token"
end

-- Self-revives still available right now (for the "Use Second Wind (you have N)" button).
function RunTokens.secondWindsAvailable(state: State, profile: Profile, stageKey: string): number
	local R = Monetization.RULES
	if (state.revivesByStage[stageKey] or 0) >= R.maxSelfRevivesPerStage then
		return 0
	end
	local free = math.max(0, R.freeSecondWindsPerRun - state.freeUsed)
	local tokens =
		math.min(profile.secondWindTokens, math.max(0, R.maxTokenRevivesPerRun - state.tokenRevives))
	return free + tokens
end

function RunTokens.rerollsAvailable(state: State, profile: Profile, stageKey: string): number
	local used = state.rerollsByStage[stageKey] or 0
	return math.max(0, math.min(profile.rerollTokens, Monetization.RULES.maxTokenRerollsPerStage - used))
end

function RunTokens.useReroll(state: State, profile: Profile, stageKey: string): (boolean, string?)
	if not validStage(stageKey) then
		return false, "bad_stage"
	end
	if RunTokens.rerollsAvailable(state, profile, stageKey) <= 0 then
		return false, if profile.rerollTokens <= 0 then "no_tokens" else "stage_cap"
	end
	profile.rerollTokens -= 1
	state.rerollsByStage[stageKey] = (state.rerollsByStage[stageKey] or 0) + 1
	return true, nil
end

return RunTokens
