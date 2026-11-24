-- Save safety for the v7 migration (Z-17, QC): a pre-v7 save is copied once to the
-- backup store BEFORE the first v7 write. If the copy fails (even after retries), the
-- session writes nothing, so the stored v6 save stays untouched; every later save
-- retries the copy, and the first confirmed copy lets the v7 save through.
-- Runs the real DataService in the runtime emulator with injected DataStore failures.
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")

local USER_ID = 7071
local STORE = "TrunkfallProfiles_v1"
local KEY = "u_" .. USER_ID
local BACKUP_STORE = "TrunkfallBackups_v1"
local BACKUP_KEY = "pre_v7_" .. USER_ID

local rt = Runtime.new({ root = ".", dt = 1 / 30 })
local v6 = {
	version = 6,
	cheese = 4321,
	level = 7,
	unlockedClasses = { elephante = true, ele_fonte = true, ellie_fawn = true },
	classes = { elephante = { xp = 10, level = 8, perks = {} } },
	stats = { runs = 20, wins = 2 },
}
rt:seedDataStore(STORE, KEY, { data = v6, savedAt = 0 })
local failBackup = true
rt.config.dataStoreFail = function(_what: string, key: string): boolean
	return failBackup and key == BACKUP_KEY
end
rt:startServer()
local DataService = rt:serverModule("ServerScriptService.Server.Services.DataService")
DataService.BASE_BACKOFF = 0.05
rt:advance(1)

T.describe("Pre-v7 backup (Z-17)", function()
	local player
	T.it("a failing backup (after retries) blocks every v7 write; the v6 save stays", function()
		player = rt:addPlayer({ userId = USER_ID, name = "Vet" })
		rt:advance(60)
		local profile = DataService.get(player)
		T.truthy(profile, "the player still plays (in memory)")
		T.eq((profile :: any).version, 10) -- iteration 7: v10 (presets, gem tiers 13-14)
		T.eq(rt:dataStoreValue(BACKUP_STORE, BACKUP_KEY), nil, "no backup")
		local saved = nil
		rt:runIn(rt.server, function()
			saved = DataService.save(player)
		end)
		rt:advance(60)
		T.eq(saved, false, "the save is refused")
		local stored = rt:dataStoreValue(STORE, KEY)
		T.eq(stored.data.version, 6, "the v6 save is untouched")
		T.eq(stored.data.cheese, 4321)
	end)
	T.it("once the backup store works, the next save backs up v6 first, then writes v7", function()
		failBackup = false
		local saved = nil
		rt:runIn(rt.server, function()
			saved = DataService.save(player)
		end)
		rt:advance(20)
		T.eq(saved, true)
		local backup = rt:dataStoreValue(BACKUP_STORE, BACKUP_KEY)
		T.truthy(backup, "the backup exists")
		T.eq(backup.version, 6)
		T.eq(backup.data.cheese, 4321)
		T.eq(backup.data.version, 6, "the raw pre-v7 save, unmigrated")
		T.eq(rt:dataStoreValue(STORE, KEY).data.version, 10, "now the current (v10) save is written")
	end)
end)

return T.finish()
