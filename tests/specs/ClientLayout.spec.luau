-- Scratch spec (copy to tests/specs/ to keep). Pure maths of src/client/Util/Layout
-- plus a coverage check: every Fx `t` the server emits has a client handler.
local T = require("../lib/Test")
local Layout = require("../../src/client/Util/Layout")
local fs = require("@lune/fs")

local UiSizes = require("../../src/client/Util/UiSizes")
local Progression = require("../../src/client/Util/Progression")
local ChallengesCfg = require("../../src/shared/Config/Challenges")
local AchievementsCfg = require("../../src/shared/Config/Achievements")

-- Safe viewport = raw minus the 58 px top bar (QC2 used ~667x317 for an SE).
local TOPBAR = 58
local cases = {
	{ name = "iPhone SE 667x375", w = 667, h = 375, touch = true, old = 0.511 },
	{ name = "Android 740x360", w = 740, h = 360, touch = true, old = 0.487 },
	{ name = "Laptop 1366x768", w = 1366, h = 768, touch = false, old = 1.145 },
	{ name = "PC 1920x1080", w = 1920, h = 1080, touch = false, old = 1.5 },
	{ name = "PC 2560x1440", w = 2560, h = 1440, touch = false, old = 1.5 },
}

T.describe("Layout (v3: smaller UI on PC, phones unchanged)", function()
	for _, c in cases do
		T.it(c.name, function()
			local w, h = Layout.safeViewport(c.w, c.h, 0, TOPBAR, 0, 0)
			local m = Layout.metrics(w, h, c.touch)
			print(
				string.format(
					"  %s: safe %dx%d scale %.3f (v2 %.3f, %d%%) root %.0fx%.0f touch %d design = %.1f px dense %s",
					c.name,
					w,
					h,
					m.scale,
					c.old,
					math.floor(100 * m.scale / c.old + 0.5),
					m.rootW,
					m.rootH,
					m.touch,
					m.touchPx,
					tostring(m.dense)
				)
			)
			-- the whole compact 1100x620 design area always fits (no overflow)
			T.truthy(
				m.rootW >= Layout.COMPACT_W - 0.01 and m.rootH >= Layout.COMPACT_H - 0.01,
				"compact design area fits"
			)
			T.truthy(
				math.abs(m.rootW * m.scale - w) < 0.01 and math.abs(m.rootH * m.scale - h) < 0.01,
				"root maps to viewport"
			)
			T.truthy(m.scale <= Layout.MAX_SCALE + 1e-9, "never above 1:1")
			-- touch targets: >= 48 px on touch, never below the base
			if c.touch then
				T.truthy(m.touchPx >= 48 - 1e-6, "touch >= 48 px")
				T.truthy(
					Layout.slimSize(m.scale, true) * m.scale >= 48 - 1e-6,
					"slim bar control >= 48 px on touch"
				)
			else
				T.truthy(
					Layout.slimSize(m.scale, false) * m.scale >= Layout.MIN_CLICK_PX - 1e-6,
					"slim >= 36 px"
				)
				T.truthy(m.touchPx >= Layout.MIN_CLICK_PX - 1e-6, "buttons >= 36 px")
			end
			T.truthy(m.touch >= Layout.BASE_TOUCH, "touch >= base")
			-- text floor: 12 px design text renders >= 11 / 12 px
			local floorPx = if c.touch then Layout.MIN_TEXT_PX else Layout.MIN_TEXT_PX_MOUSE
			T.truthy(Layout.textSize(12, m.scale, c.touch) * m.scale >= floorPx - 1e-6, "text floor")
			-- lobby bar (1040 wide, touch + 30 tall) and results panel fit
			T.truthy(1040 <= m.rootW - 28, "lobby bar fits")
			T.truthy(m.touch + 30 + 14 < m.rootH / 3, "lobby bar under a third of the height")
			T.truthy(330 + (m.touch + 18) <= m.rootH - 20, "results panel fits uncapped")
		end)
	end
	T.it("phones keep the v2 scale (their text floor binds); PCs shrink to 55-70%", function()
		for _, c in cases do
			local w, h = Layout.safeViewport(c.w, c.h, 0, TOPBAR, 0, 0)
			local s = Layout.fitScale(w, h)
			if c.touch then
				T.truthy(math.abs(s - c.old) < 0.002, c.name .. " unchanged: " .. s)
				T.falsy(Layout.dense(s), c.name .. " not dense")
			else
				T.truthy(s / c.old >= 0.55 and s / c.old <= 0.7, c.name .. " shrinks: " .. s / c.old)
				T.truthy(Layout.dense(s), c.name .. " dense")
			end
		end
	end)
	T.it("SE scale is the fitted ~0.51, not the old 0.7 floor", function()
		local w, h = Layout.safeViewport(667, 375, 0, TOPBAR, 0, 0)
		local s = Layout.fitScale(w, h)
		T.truthy(s > 0.5 and s < 0.52)
	end)
	T.it("PC scale caps at 1.0 (1:1 at 1920x1080) and keeps the 52 px base", function()
		T.eq(Layout.fitScale(1920, 1022), 1)
		T.eq(Layout.fitScale(2560, 1382), 1)
		T.eq(Layout.touchSize(1, false), 52)
		T.eq(Layout.slimSize(1, false), 36)
	end)
	T.it("fitScale is continuous and monotonic in the viewport height", function()
		local prev = 0
		for hh = 250, 1400, 5 do
			local s = Layout.fitScale(hh * 16 / 9, hh)
			T.truthy(s >= prev - 1e-9, "monotonic at " .. hh)
			T.truthy(s - prev < 0.03 or prev == 0, "no jump at " .. hh)
			prev = s
		end
	end)
	T.it("cap clamps to available minus margins", function()
		T.eq(Layout.cap(500, 400, 10), 380)
		T.eq(Layout.cap(300, 400, 10), 300)
		T.eq(Layout.cap(300, 10, 10), 0)
	end)
	T.it("degenerate sizes are safe", function()
		T.eq(Layout.fitScale(0, 0), 1)
		T.eq(Layout.fitScale(10, 10), Layout.MIN_SCALE)
		T.truthy(Layout.touchSize(Layout.MIN_SCALE, true) <= Layout.MAX_TOUCH)
	end)
end)

-- v3 popups: every combat popup covers <= ~35% of the screen, and each text
-- box holds its (floored) text, on every viewport. The dense numbers are
-- also checked at the lowest dense scale (worst text floor).
T.describe("UiSizes (v3 compact popups)", function()
	local function viewports()
		local out = {}
		for _, c in cases do
			local w, h = Layout.safeViewport(c.w, c.h, 0, TOPBAR, 0, 0)
			local m = Layout.metrics(w, h, c.touch)
			table.insert(out, { name = c.name, m = m, touch = c.touch })
		end
		-- worst dense case: a window right at the dense threshold
		local s = Layout.DENSE_SCALE
		table.insert(out, {
			name = "dense threshold",
			m = Layout.metrics(1600 * s, 900 * s, false),
			touch = false,
		})
		return out
	end
	T.it("combat popups cover <= 35% of the screen (Results is separate)", function()
		for _, v in viewports() do
			local m = v.m
			local slim = Layout.slimSize(m.scale, v.touch)
			local area = m.rootW * m.rootH
			local parts = {}
			for name, r in UiSizes.combatPopups(m.dense, m.touch, slim) do
				local frac = (math.min(r.w, m.rootW) * math.min(r.h, m.rootH)) / area
				table.insert(parts, string.format("%s %.0f%%", name, 100 * frac))
				T.truthy(
					frac <= 0.36,
					v.name .. ": " .. name .. " covers " .. string.format("%.1f%%", 100 * frac)
				)
			end
			table.sort(parts)
			print("  " .. v.name .. ": " .. table.concat(parts, ", "))
		end
	end)
	T.it("the open Extract / vote panel and the level-up strip fit together", function()
		for _, v in viewports() do
			local m = v.m
			local slim = Layout.slimSize(m.scale, v.touch)
			local hud = UiSizes.hud(m.dense, m.touch)
			local e = UiSizes.extract(m.dense, m.touch, slim)
			local u = UiSizes.upgrade(m.dense)
			if m.dense then
				-- PC: panels open top-centre under the header, strip at the bottom
				local top = UiSizes.barSlotY(true, m.touch, slim, 1)
				local stripTop = m.rootH - (hud.rowH + hud.bottomY + hud.abilityHintH + 10) - u.panelH
				T.truthy(top + e.panelH <= stripTop, v.name .. ": extract panel clears the strip")
				-- and stays above the screen centre (the hero)
				T.truthy(top + e.panelH <= m.rootH * 0.55, v.name .. ": extract panel above the hero")
			else
				-- phones: the panel lifts above the strip, capped to stay on screen
				local lift = UiSizes.stackLift(false, m.touch, m.rootH, e.panelH, true)
				local top = m.rootH - (hud.rowH + hud.bottomY + 12 + lift) - e.panelH - m.touch * 0.6
				T.truthy(
					lift > 0 and top >= 0,
					v.name .. ": lifted panel stays on screen (top " .. top .. ")"
				)
			end
			T.truthy(u.panelW <= m.rootW - 16, v.name .. ": strip fits the width")
			T.truthy(e.panelW <= m.rootW - 16, v.name .. ": extract fits the width")
		end
	end)
	T.it("live fix: every bottom tile sits on its dock (0-3 ability tiles)", function()
		for _, v in viewports() do
			local m = v.m
			local z = UiSizes.hud(m.dense, m.touch)
			for abilities = 0, 3 do
				local d = UiSizes.bottomDock(z, 3, abilities)
				local tag = string.format("%s, %d ability tiles", v.name, abilities)
				T.eq(#d.tiles, 3 + abilities, tag .. ": tile count")
				local pad = z.dockPad
				for i, t in d.tiles do
					T.truthy(
						t.x >= pad - 1e-6 and t.x + t.w <= d.w - pad + 1e-6,
						string.format("%s: tile %d x %d..%d outside dock 0..%d", tag, i, t.x, t.x + t.w, d.w)
					)
					T.truthy(
						t.y >= pad - 1e-6 and t.y + t.h <= d.h - pad + 1e-6,
						string.format("%s: tile %d y %d..%d outside dock 0..%d", tag, i, t.y, t.y + t.h, d.h)
					)
					local nx = d.tiles[i + 1]
					if nx then
						T.truthy(t.x + t.w <= nx.x, tag .. ": tiles overlap")
					end
				end
				T.truthy(d.w <= m.rootW - 16, tag .. ": dock fits the screen width (" .. d.w .. ")")
				T.truthy(d.h <= m.rootH * 0.3, tag .. ": dock stays low")
			end
		end
	end)
	T.it("live fix: the XP bar is readable (size, caption, inside the status card)", function()
		for _, v in viewports() do
			local m = v.m
			local z = UiSizes.hud(m.dense, m.touch)
			local tag = v.name
			-- at least the pre-iteration-5 14 design px, and >= 10 screen px
			T.truthy(z.xpH >= 14, tag .. ": xp bar height " .. z.xpH)
			T.truthy(z.xpH * m.scale >= 10, tag .. ": xp bar on screen " .. z.xpH * m.scale)
			T.truthy(z.barW >= 180, tag .. ": xp bar width " .. z.barW)
			T.truthy(z.showXpText, tag .. ": xp caption shown")
			local px = Layout.textSize(z.xpText, m.scale, v.touch)
			T.truthy(px <= z.xpH + 1.01, tag .. ": xp caption fits (" .. px .. " in " .. z.xpH .. ")")
			T.truthy(px * m.scale >= 8.5, tag .. ": xp caption legible")
			T.truthy(z.xpY >= z.hpY + z.hpH, tag .. ": xp under hp")
			T.truthy(z.windY >= z.xpY + z.xpH, tag .. ": wind row under xp")
			T.truthy(z.windY + z.windH <= z.statusH, tag .. ": status card holds the rows")
		end
	end)
	T.it("text boxes hold their floored text", function()
		local function fits(tag: string, m: any, touch: boolean, h: number, text: number, lines: number?)
			local px = Layout.textSize(text, m.scale, touch)
			T.truthy(
				px * (lines or 1) <= h + 1.01,
				string.format(
					"%s: %d px design text (floored %d) x%d in a %d box",
					tag,
					text,
					px,
					lines or 1,
					h
				)
			)
		end
		for _, v in viewports() do
			local m = v.m
			if not m.dense then
				continue -- phones keep the v2 HUD boxes and roomy popups (checked below)
			end
			local slim = Layout.slimSize(m.scale, v.touch)
			local z = UiSizes.hud(true, m.touch)
			local tag = v.name
			fits(tag .. " class", m, false, z.classH, z.classText)
			fits(tag .. " hp", m, false, z.hpH, z.hpText)
			fits(tag .. " wind", m, false, z.windH, z.windText)
			fits(tag .. " mate name", m, false, z.mateNameH, z.mateNameText)
			fits(tag .. " mate sub", m, false, z.mateNameH, z.mateSubText)
			fits(tag .. " mate bar", m, false, z.mateBarH, z.mateBarText)
			fits(tag .. " tile", m, false, z.tileLineH, z.tileText)
			fits(tag .. " title", m, false, z.titleH, z.titleText)
			fits(tag .. " phase", m, false, z.phaseH, z.phaseText)
			fits(tag .. " boss", m, false, z.bossNameH, z.bossNameText)
			fits(tag .. " boss bar", m, false, z.bossBarH, z.bossBarText)
			fits(tag .. " banner", m, false, z.bannerH, z.bannerText)
			fits(tag .. " kill", m, false, z.killH - 4, z.killText)
			fits(tag .. " buff", m, false, z.buffH, z.buffText)
			fits(tag .. " slot tag", m, false, z.slotTagH, z.slotTagText)
			fits(tag .. " ability hint", m, false, z.abilityHintH, z.abilityHintText)
			fits(tag .. " poi", m, false, z.poiNameH, z.poiNameText)
			fits(tag .. " down sub", m, false, z.downSubH, z.downSubText)
			local sw = UiSizes.swap(true, m.touch)
			fits(tag .. " swap cap", m, false, sw.capH, sw.capText)
			fits(tag .. " swap name", m, false, sw.nameH, sw.nameText)
			fits(tag .. " swap desc", m, false, sw.descH, sw.descText, 2)
			local e = UiSizes.extract(true, m.touch, slim)
			fits(tag .. " extract reward", m, false, e.rewardH, e.rewardText, 2)
			fits(tag .. " extract risk", m, false, e.riskH, e.riskText)
			fits(tag .. " extract risk line", m, false, e.riskLineH, e.riskLineText)
			fits(tag .. " extract footer", m, false, e.footerH, e.votesText)
			fits(tag .. " extract bar", m, false, e.barH, e.barText)
			local vt = UiSizes.vote(true, m.touch, slim)
			fits(tag .. " vote map", m, false, vt.mapH, vt.mapText)
			fits(tag .. " vote line", m, false, vt.lineH, vt.lineText)
			fits(tag .. " vote extra", m, false, vt.extraH, vt.extraText)
			fits(tag .. " vote body", m, false, vt.bodyH, vt.bodyText, 4)
			T.truthy(
				vt.lineY + vt.mapH + 3 * vt.lineH + vt.rewardH + vt.extraH <= vt.cardH - vt.footerH - 6,
				tag .. " route lines clear the footer"
			)
			local u = UiSizes.upgrade(true)
			fits(tag .. " upgrade name", m, false, u.nameH, u.nameText)
			fits(tag .. " upgrade desc", m, false, u.descH, u.descText, 3)
			fits(tag .. " upgrade band", m, false, u.bandH, u.bandText)
			local t = UiSizes.toast(true)
			fits(tag .. " toast", m, false, t.lineH, t.text)
		end
	end)
	T.it("phone popups hold their floored text too", function()
		for _, v in viewports() do
			local m = v.m
			if m.dense then
				continue
			end
			local slim = Layout.slimSize(m.scale, true)
			local function fits(name: string, h: number, text: number, lines: number?)
				local px = Layout.textSize(text, m.scale, true)
				T.truthy(
					px * (lines or 1) <= h + 1.01,
					string.format("%s %s: floored %d x%d in %d", v.name, name, px, lines or 1, h)
				)
			end
			local e = UiSizes.extract(false, m.touch, slim)
			fits("extract band", e.bandH, e.bandText)
			fits("extract reward", e.rewardH, e.rewardText, 2)
			fits("extract risk", e.riskH, e.riskText)
			fits("extract risk line", e.riskLineH, e.riskLineText)
			fits("extract footer", e.footerH, e.votesText)
			T.truthy(e.riskLineY + e.riskLineH <= e.cardH - e.footerH - 6, "extract lines clear the footer")
			local vt = UiSizes.vote(false, m.touch, slim)
			fits("vote band", vt.bandH, vt.bandText)
			fits("vote map", vt.mapH, vt.mapText)
			fits("vote line", vt.lineH, vt.lineText)
			fits("vote body", vt.bodyH, vt.bodyText, 5)
			fits("vote footer", vt.footerH, vt.tallyText)
			T.truthy(
				vt.lineY + vt.mapH + 3 * vt.lineH + vt.rewardH + vt.extraH <= vt.cardH - vt.footerH - 6,
				"route lines clear the footer"
			)
			local u = UiSizes.upgrade(false)
			fits("upgrade band", u.bandH, u.bandText)
			fits("upgrade name", u.nameH, u.nameText)
			fits("upgrade desc", u.descH, u.descText, 3)
			fits("upgrade title", u.titleH, u.titleText)
			local t = UiSizes.toast(false)
			fits("toast", t.lineH, t.text)
		end
	end)
	T.it("PC popups are 30-60% of their v2 screen size (1920x1080)", function()
		-- v2 sizes in design px at the old 1.5 scale vs v3 at 1.0
		local slim = Layout.slimSize(1, false)
		local e = UiSizes.extract(true, 52, slim)
		local u = UiSizes.upgrade(true)
		local t = UiSizes.toast(true)
		local pairs_ = {
			{ "extract", (3 * 300 + 4 * 16) * 1.5, e.panelW },
			{ "upgrade", 924 * 1.5, u.panelW },
			{ "toast", 460 * 1.5, t.w },
			{ "minimap", 150 * 1.5, UiSizes.hud(true, 52).minimap },
			{ "status", 330 * 1.5, UiSizes.hud(true, 52).statusW },
		}
		for _, p in pairs_ do
			local f = p[3] / p[2]
			print(string.format("  %s: %.0f -> %.0f px (%.0f%%)", p[1], p[2], p[3], 100 * f))
			T.truthy(f <= 0.6, p[1] .. " shrank to " .. f)
		end
	end)
end)

T.describe("Fx coverage", function()
	T.it("every emitted Fx t has a client handler", function()
		local fx = fs.readFile("src/client/Controllers/FxController.luau")
		local block = string.match(fx, "local handlers: { %[string%]: %(any%) %-> %(%) } = {(.-)\n}\n")
		assert(block, "handlers table not found")
		local handled = {}
		for k in string.gmatch(block, "\n\t([%a]+) = ") do
			handled[k] = true
		end
		-- Loot bags and ground gear need a real in-world visual (QC-A M2): a
		-- minimap dot or a HUD line does not count for these kinds.
		local WORLD_VISUAL = { "bag", "bagProgress", "bagGone", "gear", "gearGone" }
		local noWorld = {}
		for _, t in WORLD_VISUAL do
			if not handled[t] then
				table.insert(noWorld, t)
			end
		end
		T.eq(#noWorld, 0, "FxController has no world visual for: " .. table.concat(noWorld, ", "))
		-- HUD / minimap modules consume some other Fx (POI ring, carriers, spawn
		-- protection): they listen to Net.S2C.Fx and branch on `t == "<kind>"`.
		local worldSet = {}
		for _, t in WORLD_VISUAL do
			worldSet[t] = true
		end
		for _, f in { "src/client/UI/HudUI.luau", "src/client/UI/MinimapUI.luau" } do
			for t in string.gmatch(fs.readFile(f), 't == "(%a+)"') do
				if not worldSet[t] then
					handled[t] = true
				end
			end
		end
		local missing = {}
		for _, f in
			{
				"src/shared/Combat/World.luau",
				"src/shared/Combat/BossPatterns.luau",
				"src/shared/Combat/Weapons.luau",
				"src/shared/Combat/Pois.luau",
				"src/shared/Combat/Champions.luau", -- v3: champ, rally, tele champIntro
			}
		do
			local src = fs.readFile(f)
			-- `%f[%w]t`: the field `t`, not `at = "target"` (boss pattern anchors)
			for t in string.gmatch(src, '%f[%w]t = "(%a+)"') do
				if t ~= "all" and t ~= "self" then -- target selectors, not Fx
					if not handled[t] then
						missing[t] = true
					end
				end
			end
		end
		local list = {}
		for k in missing do
			table.insert(list, k)
		end
		table.sort(list)
		local hl = {}
		for k in handled do
			table.insert(hl, k)
		end
		table.sort(hl)
		print("  handled: " .. table.concat(hl, ", "))
		T.eq(#list, 0, "missing: " .. table.concat(list, ", "))
	end)
	T.it("v3 champion Fx: rally, tele styles and hostile chain arcs are drawn", function()
		local fx = fs.readFile("src/client/Controllers/FxController.luau")
		T.truthy(string.find(fx, "\n\trally = onRally,", 1, true), "rally handler")
		-- every champion tele style the server emits has its own look
		local styles = {}
		for _, f in { "src/shared/Combat/Champions.luau", "src/shared/Combat/BossPatterns.luau" } do
			local src = fs.readFile(f)
			for style in string.gmatch(src, 'style = "(%a+)"') do
				styles[style] = true
			end
		end
		for _, st in { "champIntro", "rally", "chain" } do
			T.truthy(styles[st], "server emits tele style " .. st)
			T.truthy(string.find(fx, "\n\t" .. st .. " = Color3", 1, true), "TELE_COLORS has " .. st)
		end
		T.truthy(string.find(fx, 'style == "champIntro"', 1, true), "champIntro ground sigil")
		-- hostile chain arcs (BossPatterns `hostile = true`) go to the red Beam path
		T.truthy(string.find(fs.readFile("src/shared/Combat/BossPatterns.luau"), "hostile = true", 1, true))
		T.truthy(
			string.find(fx, "if ev.hostile == true then\n\t\t\thostileChain(ev)", 1, true),
			"hostile chain"
		)
		T.truthy(string.find(fx, 'Instance.new("Beam")', 1, true), "chain Beams")
		-- sprint dust follows the Sprinting attribute; the camera widens its FOV
		T.truthy(string.find(fx, 'GetAttribute("Sprinting")', 1, true), "sprint dust")
		local cam = fs.readFile("src/client/Controllers/CameraController.luau")
		T.truthy(string.find(cam, 'GetAttribute("Sprinting")', 1, true), "sprint FOV")
	end)
end)

T.describe("Layout.textSize (readable text on phones)", function()
	T.it("14 px design text renders >= 12 screen px on a 667x375 phone", function()
		local m = Layout.metrics(667, 375 - 58, true)
		local size = Layout.textSize(14, m.scale, true)
		T.truthy(size * m.scale >= 12 - 1e-6, "rendered " .. size * m.scale)
	end)
	T.it("never shrinks and grows at most 2.2x", function()
		T.eq(Layout.textSize(30, 1.5, true), 30)
		T.truthy(Layout.textSize(10, 0.3, true) <= 22)
	end)
end)

T.describe("Menu readability (live fix: text fills its boxes)", function()
	-- the owner's PC window (800x520) plus the usual phone / laptop / PC sizes
	local menuCases = {
		{ name = "PC window 800x520", w = 800, h = 520, touch = false },
		{ name = "Laptop 1366x768", w = 1366, h = 768, touch = false },
		{ name = "PC 1920x1080", w = 1920, h = 1080, touch = false },
		{ name = "iPhone SE 667x375", w = 667, h = 375, touch = true },
	}
	local M = UiSizes.MENU
	local function each(fn: (string, any, boolean, (number) -> number) -> ())
		for _, c in menuCases do
			local w, h = Layout.safeViewport(c.w, c.h, 0, TOPBAR, 0, 0)
			local m = Layout.metrics(w, h, c.touch)
			local function rendered(n: number): number
				return Layout.textSize(n, m.scale, c.touch, true) -- the menu text floor
			end
			fn(c.name, m, c.touch, rendered)
		end
	end
	-- a list of {title, body} rows in a list `width` design px wide
	local function checkRows(
		tag: string,
		m: any,
		rows: { { string } },
		width: number,
		rendered: (number) -> number
	)
		local ts, bs = rendered(M.title), rendered(M.body)
		T.truthy(ts * m.scale >= 13 - 1e-6 and bs * m.scale >= 13 - 1e-6, tag .. ": text >= 13 screen px")
		T.truthy(ts >= M.title and bs >= M.body, tag .. ": title / body at least 18 / 15 design px")
		T.truthy(M.padX >= 8 and M.padY >= 8, tag .. ": rows are padded")
		for _, r in rows do
			local box = UiSizes.rowHeight(width, r[1], r[2], nil, rendered)
			local need = 2 * M.padY
				+ box.titleLines * ts
				+ (if box.bodyLines > 0 then M.gap + box.bodyLines * bs else 0)
			T.truthy(box.h >= need, tag .. ": row holds its text: " .. r[1])
			-- at least the two lines the owner saw jammed (title + one body line)
			if r[2] and r[2] ~= "" then
				T.truthy(box.h >= 2 * M.padY + ts + bs, tag .. ": row fits 2 lines: " .. r[1])
			end
			-- the text area is a real column, and no word is wider than it
			T.truthy(box.textW >= 200, tag .. ": text column " .. box.textW)
			for word in string.gmatch((r[2] or "") .. " " .. r[1], "%S+") do
				T.truthy(UiSizes.textWidth(word, ts) <= box.textW, tag .. ": word fits the column: " .. word)
			end
		end
	end
	T.it("Herd -> Challenges and Milestones rows fit their boxes", function()
		local ch = Progression.challenges(nil, ChallengesCfg)
		local ach = Progression.achievements(AchievementsCfg.LIST or AchievementsCfg, nil)
		T.truthy(#ch >= 30, "challenges listed")
		each(function(name, m, _touch, rendered)
			-- ProgressUI: a 900-wide modal (fitFrame margin 10), scroller 24 + padding 8, rows -8
			local width = Layout.cap(900, m.rootW, 10) - 24 - 8 - 8
			local rows = {}
			for _, c in ch do
				table.insert(
					rows,
					{ c.name, c.text .. (if c.reward.text ~= "" then "  ·  " .. c.reward.text else "") }
				)
			end
			checkRows(name .. " challenges", m, rows, width, rendered)
			local mrows = {}
			for _, a in ach do
				table.insert(mrows, { a.name, a.text })
			end
			checkRows(name .. " milestones", m, mrows, width, rendered)
		end)
	end)
	T.it("the owner's example row needs 2+ lines and gets them at 800x520", function()
		each(function(name, m, _touch, rendered)
			local width = Layout.cap(900, m.rootW, 10) - 40
			local box = UiSizes.rowHeight(
				width,
				"Lone Tusk: Elephante",
				"Clear Smoked solo with Elephante · tier-6 gem",
				nil,
				rendered
			)
			T.truthy(box.titleLines + box.bodyLines >= 2, name .. ": two lines")
			T.truthy(box.h >= 2 * M.padY + rendered(M.title) + rendered(M.body), name .. ": tall enough")
		end)
	end)
	T.it("tab labels fill their buttons (Herd, Shop, Hero, Run Shop)", function()
		local labels = {
			"📜 Contracts",
			"🐘 Herd Pass",
			"🏅 Challenges",
			"📖 Mousepedia",
			"⭐ Levels",
			"🏆 Boards",
			"Ranks",
			"Levels",
			"What's left",
			"Skins",
			"Prestige & Ascension",
			"Tinkerphant 🔒",
		}
		each(function(name, m, _touch, rendered)
			local size = rendered(M.tabText)
			T.truthy(size * m.scale >= 13 - 1e-6, name .. ": tab text " .. size * m.scale .. " screen px")
			for _, l in labels do
				local w = UiSizes.tabWidth(l, rendered)
				local tw = UiSizes.textWidth(l, size)
				T.truthy(tw + 2 * 8 <= w, name .. ": tab holds '" .. l .. "' with padding")
				-- and is not a big empty button: the label fills most of it
				T.truthy(
					tw >= 0.45 * w,
					name .. ": tab label fills '" .. l .. "' (" .. tw .. " of " .. w .. ")"
				)
			end
		end)
	end)
	T.it("Shop, Ladder, Results and Lobby boxes hold their text at the menu floor", function()
		-- {name, box height (design px), design text size, lines the box must hold}
		each(function(name, m, touch, rendered)
			local T_ = Layout.touchSize(m.scale, touch)
			local boxes = {
				{ "shop card title", 28, 17, 1 },
				{ "shop card subtitle", (104 + T_) - (36 + T_ + 12), UiSizes.MENU.body - 1, 2 },
				{ "shop busy note", 24, 13, 1 },
				{ "ladder tile name", 26, 17, 1 },
				{ "ladder tile body", 132 - 34, 13, 4 },
				{ "results stat cell", 40, 13, 1 }, -- TextScaled, min 13
				{ "lobby ability title", 22, 17, 1 },
				{ "lobby ability info", math.max(72, T_ * 0.9) - 30, UiSizes.MENU.body - 1, 2 },
				{ "lobby progress note", 22, 13, 1 },
				{ "lobby skin label", 24, 12, 1 },
				{ "settings subtitle", 24, 14, 1 },
			}
			for _, b in boxes do
				local px = rendered(b[3])
				T.truthy(px * m.scale >= 13 - 1e-6, name .. ": " .. b[1] .. " renders >= 13 px")
				-- one line needs ~its size; allow the floor's last pixel of overlap
				T.truthy(
					px * b[4] <= b[2] * 1.15 + 1,
					string.format("%s: %s %d px x%d lines in a %d box", name, b[1], px, b[4], b[2])
				)
			end
		end)
	end)
	T.it("the text estimate wraps words sensibly", function()
		T.eq(UiSizes.textLines("", 15, 100), 0)
		T.eq(UiSizes.textLines("abc", 10, 100), 1)
		T.eq(UiSizes.textLines("aaaa bbbb cccc dddd", 10, 40), 4)
		T.eq(UiSizes.textLines("aaaa bbbb cccc dddd", 10, 60), 2)
		T.eq(UiSizes.textLines("one\ntwo", 10, 500), 2)
		T.truthy(UiSizes.textWidth("🏅", 10) > UiSizes.textWidth("a", 10))
	end)
end)

return T.finish()
