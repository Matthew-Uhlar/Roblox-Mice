--!strict
-- PrestigeFrames (iter2, team G, client): nameplate frames by Prestige
-- (docs/iter/2/ALIGNMENT.md H3: a star frame at P1/5/10/20/40/70/99; A3: the
-- "Wheel of Legends" frame for all 30 Challenges).
--
--   PrestigeFrames.frameFor(prestige, wheel?) -> Frame?   nil below P1
--       Frame = { key, name, stars, color, dark, image? }
--       image = "rbxassetid://..." once assets/frames/frame_<key>.png is uploaded
--       (Config/AssetIds "frame_<key>"); until then draw it with apply().
--   PrestigeFrames.apply(guiObject, frame?)     styles a nameplate Frame/TextLabel:
--       a 9-slice ImageLabel "PrestigeFrame" when the image exists, else a UIStroke
--       + UIGradient in the frame colours. nil removes it.
-- U (nameplates / Hero screen) and the HeroTags owners call these; the data
-- (prestige, all-challenges flag) comes from P (player attributes "Prestige",
-- "WheelFrame" suggested).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PrestigeFrames = {}

local rgb = Color3.fromRGB

export type Frame = { key: string, name: string, stars: number, color: Color3, dark: Color3, image: string? }

PrestigeFrames.STEPS = {
	{
		at = 1,
		key = "p1",
		name = "Bronze Rind",
		stars = 1,
		color = rgb(190, 140, 90),
		dark = rgb(120, 80, 50),
	},
	{
		at = 5,
		key = "p5",
		name = "Silver Rind",
		stars = 1,
		color = rgb(205, 210, 220),
		dark = rgb(130, 140, 155),
	},
	{
		at = 10,
		key = "p10",
		name = "Gold Rind",
		stars = 2,
		color = rgb(255, 201, 60),
		dark = rgb(190, 130, 30),
	},
	{
		at = 20,
		key = "p20",
		name = "Brie Crystal",
		stars = 2,
		color = rgb(120, 210, 255),
		dark = rgb(40, 120, 200),
	},
	{
		at = 40,
		key = "p40",
		name = "Amethyst Wheel",
		stars = 3,
		color = rgb(190, 120, 255),
		dark = rgb(110, 60, 190),
	},
	{
		at = 70,
		key = "p70",
		name = "Ruby Wheel",
		stars = 3,
		color = rgb(255, 110, 90),
		dark = rgb(170, 40, 40),
	},
	{
		at = 99,
		key = "p99",
		name = "Eternal Cheese",
		stars = 4,
		color = rgb(255, 240, 170),
		dark = rgb(255, 170, 40),
	},
}
PrestigeFrames.WHEEL = {
	at = 0,
	key = "wheel",
	name = "Wheel of Legends",
	stars = 5,
	color = rgb(255, 201, 60),
	dark = rgb(91, 58, 30),
}
PrestigeFrames.SLICE = Rect.new(48, 48, 464, 80) -- 9-slice centre of the 512x128 art

local ids: any = nil
local function imageFor(key: string): string?
	if ids == nil then
		local ok, mod = pcall(function()
			local cfg = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
			local inst = cfg:FindFirstChild("AssetIds")
			return if inst then require(inst) :: any else nil
		end)
		ids = if ok and type(mod) == "table" then mod else {}
	end
	local id = tonumber(ids["frame_" .. key])
	return if id and id > 0 then "rbxassetid://" .. tostring(math.floor(id)) else nil
end

function PrestigeFrames.frameFor(prestige: any, wheel: boolean?): Frame?
	local step: any = nil
	if wheel then
		step = PrestigeFrames.WHEEL
	else
		local p = tonumber(prestige) or 0
		for _, s in PrestigeFrames.STEPS do
			if p >= s.at then
				step = s
			end
		end
	end
	if not step then
		return nil
	end
	return {
		key = step.key,
		name = step.name,
		stars = step.stars,
		color = step.color,
		dark = step.dark,
		image = imageFor(step.key),
	}
end

function PrestigeFrames.apply(gui: GuiObject, frame: Frame?)
	for _, name in { "PrestigeFrame", "PrestigeStroke", "PrestigeGradient" } do
		local old = gui:FindFirstChild(name)
		if old then
			old:Destroy()
		end
	end
	if not frame then
		return
	end
	if frame.image then
		local img = Instance.new("ImageLabel")
		img.Name = "PrestigeFrame"
		img.BackgroundTransparency = 1
		img.Image = frame.image
		img.ScaleType = Enum.ScaleType.Slice
		img.SliceCenter = PrestigeFrames.SLICE
		img.SliceScale = 0.25
		img.Size = UDim2.new(1, 12, 1, 12)
		img.Position = UDim2.fromOffset(-6, -6)
		img.ZIndex = gui.ZIndex + 1
		img.Parent = gui
		return
	end
	local stroke = Instance.new("UIStroke")
	stroke.Name = "PrestigeStroke"
	stroke.Thickness = 2 + frame.stars
	stroke.Color = Color3.new(1, 1, 1)
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = gui
	local grad = Instance.new("UIGradient")
	grad.Name = "PrestigeGradient"
	grad.Color = ColorSequence.new(frame.color, frame.dark)
	grad.Rotation = 90
	grad.Parent = stroke
end

return PrestigeFrames
