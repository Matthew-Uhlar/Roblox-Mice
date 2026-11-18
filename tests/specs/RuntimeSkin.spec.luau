-- Runtime emulator, UI skin scenario: every UI texture "uploaded" (fake ids in
-- Config/AssetIds, test-only), then the real client boots the lobby, opens the
-- shop, switches tabs, hovers / presses buttons and opens the class picker.
-- Checks: zero errors, gaps or unexpected warnings; panels, buttons, tabs and
-- dots draw 9-slice textures; button captions mirror the button text; and the
-- server's AssetLoader leaves the ui_* images alone.
local T = require("../lib/Test")
local Runtime = require("../runtime/Runtime")
local Driver = require("../runtime/Driver")
local Inst = require("../runtime/Instance")
local SkinSlices = require("../../src/client/UI/SkinSlices")

local rt = Runtime.new({ root = ".", dt = 1 / 30 })
do
	local lines = { "return {" }
	for i, name in SkinSlices.names do
		table.insert(lines, string.format("\t[%q] = %d,", name, 90000 + i))
	end
	table.insert(lines, "}")
	local mod = rt:find("ReplicatedStorage.Shared.Config.AssetIds")
	local d = Inst.D[mod]
	d.extra.source = table.concat(lines, "\n")
	d.extra.path = d.extra.path .. "#skin" -- own compile-cache key
end
rt:startServer()
rt:advance(1)

local function shop(client: any): any
	local gui = rt:playerGui(client)
	return gui and gui:FindFirstChild("TrunkfallShop")
end

-- Reads client-made instances as that client (they only exist there).
local function as(client: any, fn: () -> ())
	local prev = rt.S.current
	rt.S.current = client
	local ok, err = pcall(fn)
	rt.S.current = prev
	if not ok then
		error(err, 0)
	end
end

T.describe("RuntimeSkin", function()
	local p, c
	T.it("the lobby boots skinned with zero errors, gaps or warnings", function()
		p, c = rt:addPlayer({ userId = 8101, name = "Skinny" })
		rt:advance(6)
		local ready = Driver.findButton(rt, c, "TrunkfallLobby", "READY")
		as(c, function()
			local lobby = rt:playerGui(c):FindFirstChild("TrunkfallLobby")
			T.truthy(lobby, "lobby gui")
			local squads = lobby:FindFirstChild("Squads", true)
			T.truthy(squads and squads:FindFirstChild("Skin"), "Squads panel has a texture")
			T.eq(squads.BackgroundTransparency, 1, "panel's flat background hidden")
			T.truthy(ready, "READY button")
			T.truthy(ready:FindFirstChild("Skin"), "READY is skinned")
			local label = ready:FindFirstChild("SkinContent") and ready.SkinContent:FindFirstChild("Label")
			T.eq(label and label.Text, ready.Text, "caption mirrors the text")
			T.eq(ready.TextTransparency, 1, "button's own text hidden under the caption")
		end)
		rt:assertClean(nil, "skinned lobby")
	end)

	T.it("shop: tabs, cards, captions with icons, the close button", function()
		rt:click(c, Driver.findButton(rt, c, "TrunkfallLobby", "Shop"))
		rt:advance(0.5)
		local tab = Driver.findButton(rt, c, "TrunkfallShop", "Cosmetics")
		T.truthy(tab, "Cosmetics tab")
		rt:click(c, tab)
		rt:advance(0.5)
		local feat = Driver.findButton(rt, c, "TrunkfallShop", "Featured")
		local price = Driver.findButton(rt, c, "TrunkfallShop", "🧀")
		local close = Driver.findButton(rt, c, "TrunkfallShop", "✕")
		as(c, function()
			T.eq(tab:GetAttribute("SkinKind"), "tab", "tab kind")
			T.eq(tab.Skin:GetAttribute("SkinTexture"), "ui_tab_active", "active tab texture")
			T.eq(feat.Skin:GetAttribute("SkinTexture"), "ui_tab_inactive", "inactive tab texture")
			T.truthy(price, "cheese price button")
			local content = price:FindFirstChild("SkinContent")
			T.truthy(content and content.Icon.Visible, "cheese emoji drawn as an icon")
			T.falsy(string.find(content.Label.Text, "🧀", 1, true), "emoji moved out of the caption")
			local cards = 0
			for _, x in shop(c):GetDescendants() do
				if x.Name == "RaritySkin" then
					cards += 1
				end
			end
			T.truthy(cards > 0, "shop cards have frames")
			T.truthy(close, "close button")
			T.eq(close.Skin:GetAttribute("SkinTexture"), "ui_close", "close texture")
			T.falsy(close.SkinContent.Visible, "close texture carries its own X")
		end)
		rt:click(c, close)
		rt:advance(1)
		rt:assertClean(nil, "skinned shop")
	end)

	T.it("class picker and the server never loads ui_* images as models", function()
		local classBtn = Driver.findButton(rt, c, "TrunkfallLobby", "Elephante")
		if classBtn then
			rt:click(c, classBtn)
			rt:advance(1)
		end
		local folder = rt:find("ReplicatedStorage.TrunkfallAssets")
		T.truthy(folder == nil or #folder:GetChildren() == 0, "no ui_* models loaded")
		rt:assertClean(nil, "class picker")
		local _ = p
	end)
end)

return T.finish()
