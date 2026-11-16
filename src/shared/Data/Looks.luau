--!strict
-- What a player's character should look like (Team D). Pure.
-- Services/CosmeticsService turns a Look into Roblox instances on CharacterAdded
-- and after every Equip / pass / Club change.
--
-- Inputs: the profile's `equipped` map (only cosmetics the profile owns are used)
-- and the paid statuses that change the nametag and the chat tag.
-- Output colours are {r, g, b} 0..255 tables (the server converts to Color3).

local Types = require("../Types")
local Cosmetics = require("../Config/Cosmetics")

type Rgb = Types.Rgb

export type Status = {
	vip: boolean?, -- owns VIP Herd
	founder: boolean?, -- owns Founders' Stampede
	club: boolean?, -- active Cheese Club member
	herdKeeper: boolean?, -- discovered the Lost Herd Statue (rare POI, GDD §3.8)
	mastery: string?, -- (v5) "bronze" | "silver" | "gold" for the class being played (Data/ClassProgress.mastery)
	stars: number?, -- (v6) Mastery Stars of that class: "Gold Herd ★3"
	title: string?, -- (v6) equipped earned title (Config/Cosmetics.EARNED_TITLES id, owned)
	nameDye: string?, -- (v6) Config/Cosmetics.DYES id: the name colour (wins over the VIP gold)
}

export type TrailLook = { id: string, color: Rgb, color2: Rgb }
export type HatLook = { id: string, shape: string, color: Rgb, accent: Rgb }
export type TintLook = { id: string, color: Rgb }
export type Nameplate = { nameColor: Rgb, title: string?, titleColor: Rgb? }
export type ChatTag = { text: string, color: Rgb }

export type Look = {
	trail: TrailLook?,
	hat: HatLook?,
	tint: TintLook?,
	nameplate: Nameplate,
	chatTag: ChatTag?,
}

local Looks = {}

Looks.DEFAULT_HAT_COLOR = { 240, 240, 240 } :: Rgb

local function lighter(c: Rgb, t: number): Rgb
	return {
		math.floor(c[1] + (255 - c[1]) * t + 0.5),
		math.floor(c[2] + (255 - c[2]) * t + 0.5),
		math.floor(c[3] + (255 - c[3]) * t + 0.5),
	}
end
Looks.lighter = lighter

local function validRgb(c: any): boolean
	if type(c) ~= "table" or #c ~= 3 then
		return false
	end
	for i = 1, 3 do
		local v = c[i]
		if type(v) ~= "number" or v ~= v or v < 0 or v > 255 then
			return false
		end
	end
	return true
end
Looks.validRgb = validRgb

-- The def for `id` if the profile owns it and it belongs in `slot`.
local function ownedDef(cosmetics: { [string]: boolean }, slot: string, id: any): Cosmetics.CosmeticDef?
	if type(id) ~= "string" or cosmetics[id] ~= true then
		return nil
	end
	local def = Cosmetics.get(id)
	if not def or def.slot ~= slot then
		return nil
	end
	return def
end

local function badges(map: { [string]: Cosmetics.Badge }, keys: { string }): { Cosmetics.Badge }
	local out: { Cosmetics.Badge } = {}
	for _, k in keys do
		local b = map[k]
		if b then
			table.insert(out, b)
		end
	end
	table.sort(out, function(a, b)
		return a.order < b.order
	end)
	return out
end

local function join(list: { Cosmetics.Badge }): string
	local parts = {}
	for _, b in list do
		table.insert(parts, b.text)
	end
	return table.concat(parts, " · ")
end

function Looks.resolve(equipped: { [string]: any }?, cosmetics: { [string]: boolean }?, status: Status?): Look
	local eq: { [string]: any } = if type(equipped) == "table" then equipped else {}
	local owned: { [string]: boolean } = if type(cosmetics) == "table" then cosmetics else {}
	local st: Status = status or {}
	local look: Look = { nameplate = { nameColor = Cosmetics.NAME_COLOR } }

	local trail = ownedDef(owned, "trail", eq.trail)
	if trail and validRgb(trail.color) then
		local c = trail.color :: Rgb
		local c2 = if validRgb(trail.color2) then trail.color2 :: Rgb else lighter(c, 0.55)
		look.trail = { id = trail.id, color = c, color2 = c2 }
	end

	local hat = ownedDef(owned, "hat", eq.hat)
	if hat and type(hat.shape) == "string" and Cosmetics.HAT_SHAPES[hat.shape] then
		local c = if validRgb(hat.color) then hat.color :: Rgb else Looks.DEFAULT_HAT_COLOR
		local a = if validRgb(hat.accent) then hat.accent :: Rgb else lighter(c, 0.5)
		look.hat = { id = hat.id, shape = hat.shape :: string, color = c, accent = a }
	end

	local tint = ownedDef(owned, "tint", eq.tint)
	if tint and validRgb(tint.color) then
		look.tint = { id = tint.id, color = tint.color :: Rgb }
	end

	local titleKeys = {}
	local tagKeys = {}
	if st.vip then
		look.nameplate.nameColor = Cosmetics.VIP_NAME_COLOR
		table.insert(titleKeys, "vip")
		table.insert(tagKeys, "vip")
	end
	if st.founder then
		table.insert(titleKeys, "founders")
	end
	if st.club then
		table.insert(titleKeys, "club")
		table.insert(tagKeys, "club")
	end
	if st.herdKeeper then
		table.insert(titleKeys, "herd_keeper")
	end
	if type(st.mastery) == "string" and Cosmetics.TITLES["mastery_" .. st.mastery] then
		table.insert(titleKeys, "mastery_" .. st.mastery)
	end
	local titles = badges(Cosmetics.TITLES, titleKeys)
	-- (v6) Mastery Stars on the mastery title, then the equipped earned title
	local stars = if type(st.stars) == "number" and st.stars == st.stars then math.floor(st.stars) else 0
	if stars > 0 then
		for i, b in titles do
			if string.sub(b.text, -5) == " Herd" and st.mastery == "gold" then
				titles[i] = { text = b.text .. " ★" .. tostring(stars), color = b.color, order = b.order }
			end
		end
	end
	local earned = if type(st.title) == "string" then Cosmetics.EARNED_TITLES[st.title] else nil
	if earned then
		table.insert(titles, earned)
	end
	local dye = if type(st.nameDye) == "string" then Cosmetics.DYES[st.nameDye] else nil
	if dye and validRgb(dye.color) then
		look.nameplate.nameColor = dye.color
	end
	if #titles > 0 then
		look.nameplate.title = join(titles)
		look.nameplate.titleColor = titles[1].color
	end
	local tags = badges(Cosmetics.CHAT_TAGS, tagKeys)
	if #tags > 0 then
		look.chatTag = { text = join(tags), color = tags[1].color }
	end
	return look
end

return Looks
