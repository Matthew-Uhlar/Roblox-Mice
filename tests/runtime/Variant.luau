--!strict
-- Scenario variant knobs shared between a spec and the spec it reuses (one Lune
-- process: the module cache hands both the same table). RuntimeSquadsGate sets
-- `squads` before requiring RuntimeSquads.spec.
return {
	squads = nil :: { fragileHp: number?, gateWipe: boolean? }?,
}
