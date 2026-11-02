local T = require("../lib/Test")
local Looks = require("../../src/shared/Data/Looks")
local Cosmetics = require("../../src/shared/Config/Cosmetics")

-- QC2 B1: every cosmetic that can be owned resolves to something CosmeticsService draws.

local function ownedAll(): { [string]: boolean }
	local out = {}
	for _, def in Cosmetics.LIST do
		out[def.id] = true
	end
	return out
end

T.describe("Looks.resolve", function()
	T.it("draws every cosmetic in its slot", function()
		local owned = ownedAll()
		for _, def in Cosmetics.LIST do
			local look = Looks.resolve({ [def.slot] = def.id }, owned, {})
			local part = (look :: any)[def.slot]
			T.truthy(part, def.id .. " resolves to a " .. def.slot)
			T.eq(part.id, def.id)
			T.truthy(Looks.validRgb(part.color), def.id .. " colour")
			if def.slot == "hat" then
				T.truthy(Cosmetics.HAT_SHAPES[part.shape], def.id .. " shape")
				T.truthy(Looks.validRgb(part.accent), def.id .. " accent")
			elseif def.slot == "trail" then
				T.truthy(Looks.validRgb(part.color2), def.id .. " color2")
			end
		end
	end)
	T.it("ignores cosmetics the profile doesn't own or that are in the wrong slot", function()
		local look = Looks.resolve({ hat = "hat_party", trail = "hat_chef", tint = "tint_nope" }, {}, {})
		T.eq(look.hat, nil)
		T.eq(look.trail, nil)
		T.eq(look.tint, nil)
		local look2 = Looks.resolve({ trail = "hat_chef" }, { hat_chef = true }, {})
		T.eq(look2.trail, nil, "wrong slot")
	end)
	T.it("tolerates nil and garbage inputs", function()
		local look = Looks.resolve(nil, nil, nil)
		T.deepEq(look.nameplate.nameColor, Cosmetics.NAME_COLOR)
		T.eq(look.nameplate.title, nil)
		T.eq(look.chatTag, nil)
		Looks.resolve({ hat = 5 } :: any, { [5] = true } :: any, {})
	end)
	T.it("VIP gets a gold name, the VIP title and the VIP chat tag", function()
		local look = Looks.resolve({}, {}, { vip = true })
		T.deepEq(look.nameplate.nameColor, Cosmetics.VIP_NAME_COLOR)
		T.eq(look.nameplate.title, "VIP")
		T.eq((look.chatTag :: any).text, "VIP")
	end)
	T.it("Club gets a Cheese Club title and the Club chat tag; Founder only a title", function()
		local club = Looks.resolve({}, {}, { club = true })
		T.eq(club.nameplate.title, "Cheese Club")
		T.eq((club.chatTag :: any).text, "Club")
		T.deepEq(club.nameplate.nameColor, Cosmetics.NAME_COLOR, "not gold")
		local founder = Looks.resolve({}, {}, { founder = true })
		T.eq(founder.nameplate.title, "Founder")
		T.eq(founder.chatTag, nil)
	end)
	T.it("combines titles and tags in a fixed order", function()
		local look = Looks.resolve({}, {}, { club = true, vip = true, founder = true })
		T.eq(look.nameplate.title, "VIP · Founder · Cheese Club")
		T.eq((look.chatTag :: any).text, "VIP · Club")
		T.deepEq((look.chatTag :: any).color, Cosmetics.CHAT_TAGS.vip.color)
	end)
end)

T.describe("Config/Cosmetics hat geometry", function()
	T.it("every hat part has a valid form, size and position", function()
		local forms = { block = true, ball = true, cyl = true, wedge = true }
		for name, parts in Cosmetics.HAT_SHAPES do
			T.truthy(#parts > 0, name)
			for i, part in parts do
				local where = name .. "#" .. i
				T.truthy(forms[part.form], where .. " form")
				T.eq(#part.size, 3, where .. " size")
				T.eq(#part.at, 3, where .. " at")
				for k = 1, 3 do
					T.truthy(part.size[k] > 0 and part.size[k] < 4, where .. " size range")
					T.truthy(math.abs(part.at[k]) < 3, where .. " stays near the head")
				end
				if part.rot then
					T.eq(#part.rot, 3, where .. " rot")
				end
			end
		end
	end)
	T.it("every hat shape is used by at least one hat", function()
		local used = {}
		for _, def in Cosmetics.LIST do
			if def.shape then
				used[def.shape] = true
			end
		end
		for name in Cosmetics.HAT_SHAPES do
			T.truthy(used[name], "unused shape " .. name)
		end
	end)
end)

T.describe("Looks: discovery titles", function()
	T.it("Lost Herd Statue discovery shows the Herd Keeper title", function()
		local look = Looks.resolve({}, {}, { herdKeeper = true })
		T.truthy(look.nameplate.title and string.find(look.nameplate.title, "Herd Keeper", 1, true))
		T.falsy(Looks.resolve({}, {}, {}).nameplate.title)
	end)
end)

return T.finish()
