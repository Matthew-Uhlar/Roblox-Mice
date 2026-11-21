--!strict
-- TotemDress (iteration 5 Phase B #4, client): the totem family's variants.
-- The server builds every "*totem*" POI with the Power Totem model
-- (server Visuals/PoiModels resolves by keyword), so this module dresses the
-- new kinds LOCALLY, from Config/Pois ids team Abilities adds:
--   Whey Totem   (id contains "whey")            milky blue glow, 🥛 crest
--   Crumb Totem  (id contains "crumb" or "xp")   XP green glow, ✨ crest
--   any other non-power totem                    its Config/Pois colour, 🗿 crest
-- The Power Totem keeps its look. Dressing = the model's Neon parts and lights
-- recoloured (a local write: other players dress their own copy) plus a small
-- floating crest. Scans workspace.Arena.POIs twice a second; nothing collides.
--
--   TotemDress.variant(poiId, def?) -> "whey" | "crumb" | "other" | nil   (pure)
--   TotemDress.step(dt)     FxController calls it every frame
--   TotemDress.clear()

local TotemDress = {}

TotemDress.WHEY = Color3.fromRGB(150, 210, 255)
TotemDress.CRUMB = Color3.fromRGB(120, 230, 110)
TotemDress.ICON = { whey = "🥛", crumb = "✨", other = "🗿" } :: { [string]: string }

local dressed: { [Instance]: boolean } = {}
local acc = 0
local defsMod: any = nil

-- Which variant a POI id is (nil: not a totem, or the Power Totem).
function TotemDress.variant(poiId: string, def: any?): string?
	local id = string.lower(poiId)
	local isTotem = string.find(id, "totem", 1, true) ~= nil
		or (type(def) == "table" and (def.mode == "totem" or def.reward == "totem"))
	if not isTotem or id == "power_totem" or string.find(id, "power", 1, true) then
		return nil
	end
	if string.find(id, "whey", 1, true) then
		return "whey"
	elseif string.find(id, "crumb", 1, true) or string.find(id, "xp", 1, true) then
		return "crumb"
	end
	return "other"
end

local function poiDef(id: string): any
	if defsMod == nil then
		local ok, mod = pcall(function()
			return require(script.Parent.Parent.Util.Defs) :: any
		end)
		defsMod = if ok then mod else false
	end
	if not defsMod then
		return nil
	end
	local ok, d = pcall(defsMod.get, "Pois", id)
	return if ok then d else nil
end

local function colorOf(variant: string, def: any): Color3
	if variant == "whey" then
		return TotemDress.WHEY
	elseif variant == "crumb" then
		return TotemDress.CRUMB
	end
	local c = if type(def) == "table" then def.color else nil
	if type(c) == "table" and tonumber(c[1]) then
		return Color3.fromRGB(tonumber(c[1]) or 255, tonumber(c[2]) or 255, tonumber(c[3]) or 255)
	end
	return Color3.fromRGB(255, 220, 120)
end

local function dress(m: Instance)
	local id = m:GetAttribute("PoiId")
	if type(id) ~= "string" then
		return
	end
	local def = poiDef(id)
	local variant = TotemDress.variant(id, def)
	dressed[m] = true
	if not variant then
		return
	end
	local color = colorOf(variant, def)
	local top: BasePart? = nil
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			if d.Material == Enum.Material.Neon then
				d.Color = color
			end
			if d.Transparency < 1 and (top == nil or d.Position.Y > (top :: BasePart).Position.Y) then
				top = d
			end
		elseif d:IsA("PointLight") or d:IsA("SpotLight") then
			(d :: any).Color = color
		end
	end
	local x = tonumber(m:GetAttribute("X"))
	local z = tonumber(m:GetAttribute("Z"))
	local anchor = Instance.new("Part")
	anchor.Name = "TotemCrest"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	local y = if top then top.Position.Y + top.Size.Y / 2 + 2.5 else 10
	anchor.CFrame =
		CFrame.new(x or (if top then top.Position.X else 0), y, z or (if top then top.Position.Z else 0))
	local gui = Instance.new("BillboardGui")
	gui.Name = "Crest"
	gui.Size = UDim2.fromOffset(44, 44)
	gui.LightInfluence = 0
	gui.MaxDistance = 160
	gui.AlwaysOnTop = false
	local label = Instance.new("TextLabel")
	label.BackgroundColor3 = color
	label.BackgroundTransparency = 0.25
	label.Size = UDim2.fromScale(1, 1)
	label.Text = TotemDress.ICON[variant] or "🗿"
	label.TextScaled = true
	label.Font = Enum.Font.FredokaOne
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = label
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(60, 40, 20)
	stroke.Thickness = 2
	stroke.Parent = label
	label.Parent = gui
	gui.Parent = anchor
	anchor.Parent = m -- a local child: removed with the model
end

function TotemDress.step(dt: number)
	acc += dt
	if acc < 0.5 then
		return
	end
	acc = 0
	for m in dressed do
		if not m.Parent then
			dressed[m] = nil
		end
	end
	local arena = workspace:FindFirstChild("Arena")
	local pois = arena and arena:FindFirstChild("POIs")
	if not pois then
		return
	end
	for _, m in pois:GetChildren() do
		if not dressed[m] and m:IsA("Model") then
			local ok, err = pcall(dress, m)
			if not ok then
				dressed[m] = true
				warn("[Trunkfall] TotemDress: " .. tostring(err))
			end
		end
	end
end

function TotemDress.clear()
	table.clear(dressed)
end

return TotemDress
