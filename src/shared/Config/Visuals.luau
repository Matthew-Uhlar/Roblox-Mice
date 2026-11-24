--!strict
-- Config/Visuals (iteration 7, team Mesh): live switches for client visuals.
--
--   USE_MESHES  true: HordeRenderer draws mice / champions / bosses from the
--               procedural mesh uploads (Visuals/MeshModels) when they are
--               loaded; false: every client keeps the part models. A one-line
--               publish turns meshes off if the live import looks wrong. The
--               player setting "models" = "classic" (Data/Settings) forces the
--               part models for that player only.

local Visuals = {}

Visuals.USE_MESHES = true

return Visuals
