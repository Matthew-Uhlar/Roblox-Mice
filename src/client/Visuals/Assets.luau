--!strict
-- Assets (R4 Graphics, client): generated mesh templates, when they exist.
--
--   Assets.template(name) -> Model?
--   Assets.ids() -> {[name] = assetId}   (Shared.Config.AssetIds, or {} if missing)
--
-- The server's Visuals/AssetLoader loads every Shared.Config.AssetIds entry with
-- InsertService and stores it as ReplicatedStorage.TrunkfallAssets.<name> (a
-- MeshPart's MeshId cannot be set from scripts, so the client never builds meshes
-- itself). The renderers call template("mouse_<enemyId>") / template("boss_<bossId>")
-- and fall back to their part models while it returns nil.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = {}

Assets.FOLDER = "TrunkfallAssets"

local cachedIds: { [string]: number }? = nil

function Assets.ids(): { [string]: number }
	if cachedIds then
		return cachedIds
	end
	local ok, mod = pcall(function()
		local shared = ReplicatedStorage:FindFirstChild("Shared")
		local config = shared and shared:FindFirstChild("Config")
		local inst = config and config:FindFirstChild("AssetIds")
		return if inst and inst:IsA("ModuleScript") then require(inst) :: any else nil
	end)
	local ids = if ok and type(mod) == "table" then mod else {}
	cachedIds = ids
	return ids
end

function Assets.template(name: string): Model?
	if Assets.ids()[name] == nil then
		return nil
	end
	local folder = ReplicatedStorage:FindFirstChild(Assets.FOLDER)
	local m = folder and folder:FindFirstChild(name)
	if m and m:IsA("Model") then
		return m
	end
	return nil
end

return Assets
