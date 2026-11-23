--!nocheck
-- render-cosmetics.luau (iteration 6, team Preview): exports the geometry of every
-- rendered cosmetic thumbnail for scripts/make-cosmetic-icons.py.
--
--   lune run scripts/render-cosmetics.luau <outDir>
--
-- Builds each item with the code the game uses, inside the headless runtime
-- (tests/runtime): the server's BotModel (Herd Suit mode, like HeroDecor) for
-- class skins, Ascension looks and tints, plus the client's Visuals/CosmeticParts
-- for hats (CosmeticsService's geometry on the suit's head) and trails (the
-- showroom ribbon). One JSON per item, named after its icon (Util/PreviewRecipe
-- .iconName): { name, ref, focus, frames = { {parts}... } | parts + yaws }.

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Runtime = require("../tests/runtime/Runtime")

local outDir = process.args[1] or "assets/icons/_cosmetic_scenes"
fs.writeDir(outDir)

local rt = Runtime.new({ root = "." })

local function v3(v)
	return { v.X, v.Y, v.Z }
end

local function partRecord(p)
	local shape = "Block"
	local cls = p.ClassName
	if cls == "Part" then
		shape = p.Shape.Name
	elseif cls == "WedgePart" then
		shape = "Wedge"
	elseif cls == "CornerWedgePart" then
		shape = "CornerWedge"
	end
	local mesh = p:FindFirstChildOfClass("SpecialMesh")
	if mesh and mesh.MeshType == roblox.Enum.MeshType.Sphere then
		shape = "Egg"
	end
	return {
		shape = shape,
		size = v3(p.Size),
		cf = { p.CFrame:GetComponents() },
		color = { p.Color.R, p.Color.G, p.Color.B },
		mat = p.Material.Name,
		t = p.Transparency,
	}
end

local function collect(root, filter)
	local parts = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 0.99 and (not filter or filter(d)) then
			table.insert(parts, partRecord(d))
		end
	end
	return parts
end

local n = 0
local function write(name, scene)
	n += 1
	fs.writeFile(outDir .. "/" .. name .. ".json", serde.encode("json", scene))
end

rt:asServer(function()
	local BotModel = rt:serverModule("ServerScriptService.Server.Visuals.BotModel")
	local Cosmetics = rt:serverModule("ReplicatedStorage.Shared.Config.Cosmetics")
	local ClassSkins = rt:serverModule("ReplicatedStorage.Shared.Config.ClassSkins")
	local Looks = rt:serverModule("ReplicatedStorage.Shared.Data.Looks")
	local Ascension = rt:serverModule("ReplicatedStorage.Shared.Config.Ascension")
	local client = "StarterPlayer.StarterPlayerScripts.Client."
	local PreviewRecipe = rt:serverModule(client .. "Util.PreviewRecipe")
	local CosmeticParts = rt:serverModule(client .. "Visuals.CosmeticParts")
	local cfg = { Cosmetics = Cosmetics, ClassSkins = ClassSkins, Looks = Looks, Ascension = Ascension }

	local function suit(classId, skinId, ascLook)
		return BotModel.build({ id = 0, name = "icon", classId = classId, skinId = skinId, ascLook = ascLook }, nil, {
			suit = true,
		})
	end
	local HEAD_BONES = { head = true, earL = true, earR = true, trunk = true, trunk2 = true, trunk3 = true }

	for _, ref in PreviewRecipe.allRefs(cfg) do
		local r = PreviewRecipe.resolve(ref, cfg)
		if not r or not PreviewRecipe.RENDERED[r.kind] then
			continue
		end
		local scene = { name = r.icon, ref = ref, focus = r.focus, slot = r.slot }
		if r.slot == "skin" then
			local m = suit(r.classId, r.skinId)
			scene.parts = collect(m)
			m:Destroy()
		elseif r.slot == "look" then
			local m = suit("elephante", nil, r.ascLook)
			scene.parts = collect(m)
			m:Destroy()
		elseif r.slot == "tint" then
			local m = suit("elephante")
			CosmeticParts.tint(m, r.tint, Cosmetics.TINT)
			scene.parts = collect(m)
			m:Destroy()
		elseif r.slot == "hat" then
			local m = suit("elephante")
			local head = m:FindFirstChild("Head", true)
			local hat = CosmeticParts.hat(m, head, r.hat, Cosmetics.HAT_SHAPES)
			scene.parts = collect(m, function(p)
				return HEAD_BONES[p:GetAttribute("Bone")] == true or (hat and p:IsDescendantOf(hat))
			end)
			m:Destroy()
		elseif r.slot == "trail" then
			local m = suit("elephante")
			local body = collect(m)
			local rb = CosmeticParts.ribbon(m, r.trail, Cosmetics.TRAIL)
			scene.frames = {}
			for f = 0, 3 do
				rb.set(f * 0.35, true)
				local parts = table.clone(body)
				for _, p in rb.parts do
					table.insert(parts, partRecord(p))
				end
				table.insert(scene.frames, parts)
			end
			m:Destroy()
		end
		write(r.icon, scene)
	end
end)

print(string.format("wrote %d cosmetic scenes to %s", n, outDir))
