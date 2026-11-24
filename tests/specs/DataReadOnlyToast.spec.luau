-- QC m4 (iteration 6): a save written by a NEWER server version opens read-only
-- (ProfileSchema futureVersion); the player is told once, and nothing is saved over it.
-- Runs the real DataService in the runtime emulator.
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")

local USER_ID = 8181
local STORE = "TrunkfallProfiles_v1"
local KEY = "u_" .. USER_ID

local rt = Runtime.new({ root = ".", dt = 1 / 30 })
rt:seedDataStore(STORE, KEY, {
	data = { version = 99, cheese = 1234, unlockedClasses = { elephante = true } },
	savedAt = 0,
})
rt:startServer()
local DataService = rt:serverModule("ServerScriptService.Server.Services.DataService")
rt:advance(1)

T.describe("Read-only session toast (QC m4)", function()
	T.it("a newer save: one toast, read-only, the stored save untouched", function()
		local player, client = rt:addPlayer({ userId = USER_ID, name = "Future" })
		rt:advance(DataService.READ_ONLY_TOAST_DELAY + 3)
		T.truthy(DataService.isReadOnly(player), "read-only session")
		local box = client.inbox.Toast
		local n = 0
		for _, args in (box and box.list) or {} do
			if args[1] == DataService.READ_ONLY_TEXT then
				n += 1
			end
		end
		T.eq(n, 1, "told once")
		rt:advance(10)
		T.eq(rt:dataStoreValue(STORE, KEY).data.version, 99, "never saved over")
		rt:removePlayer(player)
		rt:advance(5)
	end)
end)

return T.finish()
