-- Runtime emulator: the RuntimeSquads scenario with the fragile squad at 1/25 HP
-- (it survives to a Rind Gate) voting Extract, all of it downed in the gate window.
-- Regression for the extraction exploit: it is eliminated with its bags, never
-- extracted (RunDirector.eliminateFallen). See RuntimeSquads.spec.luau.
local Variant = require("../runtime/Variant")
Variant.squads = { fragileHp = 1 / 25, gateWipe = true }
return require("./RuntimeSquads.spec")
