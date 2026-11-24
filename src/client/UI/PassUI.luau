--!strict
-- PassUI (iteration 6, team Pass): the Herd Pass screen, a modern season-pass
-- layout (generic genre conventions, our own art):
--
--   header    season name, tier badge, XP bar to the next tier, currency /
--             locker chips, "Claim all", "Unlock Premium" (only a button the
--             player presses), close
--   track     a horizontally scrolling row of tier columns: a FREE card on the
--             top row and a PREMIUM card on the bottom row; the tier being
--             worked towards is centred and highlighted; claimed / claimable /
--             locked / premium-locked states; drag, wheel and touch scroll with
--             snap; keyboard / gamepad navigation
--   featured  the selected reward, big: UI/CosmeticPreview's 3-D showroom for
--             cosmetics (when that module is there), else a big animated icon.
--             A side panel on PC; a drawer over the track on phones.
--
-- Animations run on ONE driver (a RenderStepped connection that lives only
-- while the screen is open): cards slide / scale in, claimable cards glow and
-- bob, a shine sweeps over premium cards, the XP bar fills smoothly, a claim
-- pops the card with a particle burst and flies the reward to its chip, a new
-- tier flashes the header. The saved Effects setting (State.gfx().fx) picks the
-- profile (Util/PassModel.anim): "full", "reduced" (minimal) or "off" (static).
-- Closing destroys the screen, the driver, the bindings and the showroom.
--
-- Policy (docs/MONETIZATION.md): the premium track is cosmetics and Golden
-- Cheese only; this screen shows no countdown or season-end text (the view's
-- `daysLeft` is never read) and never prompts a purchase on its own: only the
-- "Unlock Premium" button fires PromptProduct(premiumKey), the same remote and
-- game pass the shop uses. Claims go through ClaimPassTier(tier, track); "Claim
-- all" sends one ClaimPassAll (fallback: paced ClaimPassTier calls when that
-- remote is missing).
--
-- Opened from UI/ProgressUI (the Herd panel's "Herd Pass" tab and
-- ProgressUI.open("Herd Pass"), which the shop's "Open Herd Pass" button uses).

local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Theme = require(script.Parent.Theme)
local Remotes = require(Client.Util.Remotes)
local Defs = require(Client.Util.Defs)
local Format = require(Client.Util.Format)
local Progression = require(Client.Util.Progression)
local PassModel = require(Client.Util.PassModel)
local State = require(Client.Controllers.State)

local PassUI = {}

local C = Theme.C
local make = Theme.make
local TEXT = PassModel.TEXT

local ACTION = "TrunkfallPassNav"
local CLAIM_SPACING = 0.3 -- s between "Claim all" sends (server: 4/s, burst 10)
local PENDING_SECONDS = 5 -- an unanswered claim reverts after this
local PROMPT_COOLDOWN = 1.6 -- the server's PromptProduct cooldown

local FREE_BG = Color3.fromRGB(56, 70, 102)
local FREE_BG2 = Color3.fromRGB(34, 42, 66)
local PANEL_BG = Color3.fromRGB(30, 22, 40)

-- Optional sibling modules (teams Icons / Preview); absent = fallbacks.
local function optional(name: string): any
	local inst = script.Parent:FindFirstChild(name)
	if not inst or not inst:IsA("ModuleScript") then
		return nil
	end
	local ok, mod = pcall(require, inst)
	return if ok and type(mod) == "table" then mod else nil
end

local function optionalUtil(name: string): any
	local inst = Client.Util:FindFirstChild(name)
	if not inst or not inst:IsA("ModuleScript") then
		return nil
	end
	local ok, mod = pcall(require, inst)
	return if ok and type(mod) == "table" then mod else nil
end

local function sound(key: string)
	local inst = Client.Controllers:FindFirstChild("SoundController")
	if inst and inst:IsA("ModuleScript") then
		local ok, S = pcall(require, inst)
		if ok and type(S) == "table" and type(S.play) == "function" then
			pcall(S.play, key)
		end
	end
end

----------------------------------------------------------------------
-- Session state (one table per open screen; nil while closed)
----------------------------------------------------------------------

type CardUI = {
	button: TextButton,
	content: Frame,
	stroke: UIStroke,
	glow: Frame,
	glowStroke: UIStroke,
	shine: Frame?,
	shineGrad: UIGradient?,
	scale: UIScale,
	overlay: Frame,
	lock: Frame,
	check: TextLabel,
	ribbon: TextLabel,
	ring: Frame,
	empty: TextLabel,
	tier: number,
	track: string,
	phase: number,
}

type ColUI = {
	frame: Frame,
	scale: UIScale,
	homeX: number,
	pill: TextLabel,
	pillStroke: UIStroke,
	hl: Frame,
	free: CardUI,
	premium: CardUI,
}

local S: any = nil
local lastPromptAt = -math.huge

local function profile(): any
	local p = State.get("profile")
	return if type(p) == "table" then p else {}
end

local function seasonDef(seasonNo: any): any
	local mod = Defs.module("Pass")
	if type(mod) == "table" and type(mod.season) == "function" then
		local ok, def = pcall(mod.season, tonumber(seasonNo) or 1)
		if ok then
			return def
		end
	end
	return nil
end

-- Builds the model from the live view, keeping optimistic claims still in flight.
local function computeModel(): PassModel.Model
	local raw = State.get("pass")
	local pv = Progression.pass(raw, Defs.module("Pass"))
	local m = PassModel.build(pv, seasonDef(pv.season), Progression.reward)
	local s = S
	if s then
		for key, untilT in s.pending do
			local tier, track = string.match(key, "^(%d+):(%a+)$")
			local col = m.columns[tonumber(tier) or 0]
			local slot = col and (col :: any)[track or ""]
			-- kept while unanswered and fresh; dropped once the server answered
			-- (or it is gone), or when it timed out (shown claimable again)
			if slot ~= nil and slot.state == "claimable" and s.t < untilT then
				slot.state = "claimed"
				m.claimable -= 1
			else
				s.pending[key] = nil
			end
		end
	end
	return m
end

local function slotOf(tier: number, track: string): PassModel.Slot?
	local s = S
	local col = s and s.model and s.model.columns[tier]
	if not col then
		return nil
	end
	return if track == "premium" then col.premium else col.free
end

local function cosmeticDef(reward: any): any
	if type(reward) ~= "table" or reward.id == nil then
		return nil
	end
	if reward.kind == "skin" then
		return Defs.get("ClassSkins", reward.id)
	end
	return Defs.get("Cosmetics", reward.id)
end

local function infoOf(slot: PassModel.Slot): PassModel.RewardInfo
	return PassModel.rewardInfo(slot.reward, slot.track, cosmeticDef(slot.reward))
end

local function iconColor(info: PassModel.RewardInfo, reward: any): Color3
	local def = cosmeticDef(reward)
	if type(def) == "table" and type(def.color) == "table" then
		return Color3.fromRGB(def.color[1] or 255, def.color[2] or 255, def.color[3] or 255)
	end
	if info.icon == "cheese" then
		return C.cheese
	elseif info.icon == "coin" then
		return C.gold
	elseif info.icon == "gem" then
		return C.blue
	end
	return C.goldLight
end

-- Converts a screen-space point to design px inside `layer`.
local function toLocal(layer: GuiObject, abs: Vector2): Vector2
	return (abs - layer.AbsolutePosition) / Theme.scaleOf(layer)
end

local function centreOf(obj: GuiObject): Vector2
	return obj.AbsolutePosition + obj.AbsoluteSize / 2
end

----------------------------------------------------------------------
-- Icons (team Icons' UI/AnimatedIcon when present, else drawn icons)
----------------------------------------------------------------------

local function makeIcon(info: PassModel.RewardInfo, reward: any, size: number, animated: boolean): GuiObject
	if animated then
		local A = optional("AnimatedIcon")
		if A then
			for _, fname in { "make", "new", "create" } do
				local f = A[fname]
				if type(f) == "function" then
					local ok, res = pcall(f, info.anim, size)
					if ok and typeof(res) == "Instance" and (res :: Instance):IsA("GuiObject") then
						return res :: GuiObject
					elseif ok and type(res) == "table" and typeof(res.frame) == "Instance" then
						return res.frame
					end
				end
			end
		end
	end
	return Theme.icon(info.icon, size, iconColor(info, reward))
end

----------------------------------------------------------------------
-- Animation driver helpers
----------------------------------------------------------------------

-- Runs step(eased 0..1) over `duration` s after `delay` s on the driver.
local function animate(duration: number, delay: number, ease: string, step: (number) -> (), done: (() -> ())?)
	local s = S
	if not s then
		return
	end
	local start = s.t + delay
	step(0)
	table.insert(s.tasks, function(t: number): boolean
		if t < start then
			return true
		end
		local x = math.clamp((t - start) / math.max(duration, 1e-3), 0, 1)
		step(PassModel.ease(ease, x))
		if x >= 1 and done then
			done()
		end
		return x < 1
	end)
end

local function scrollTo(tier: number, instant: boolean?)
	local s = S
	if not s or not s.scroller then
		return
	end
	local L = s.lay
	local x = PassModel.centreOffset(tier, s.model.maxTier, L.cardW, L.colGap, L.scroller.w)
	if instant or not s.anim.smoothScroll then
		s.scrollTarget = nil
		s.lastSetX = x
		s.scroller.CanvasPosition = Vector2.new(x, 0)
	else
		s.scrollTarget = x
	end
	s.userScrollAt = nil
end

----------------------------------------------------------------------
-- Card states
----------------------------------------------------------------------

local function applyCard(card: CardUI)
	local s = S
	local slot = slotOf(card.tier, card.track)
	if not s or not slot then
		return
	end
	local st = slot.state
	local premium = card.track == "premium"
	card.empty.Visible = st == "empty"
	card.content.Visible = st ~= "empty"
	card.overlay.Visible = st == "locked" or st == "needsPremium" or st == "claimed"
	card.overlay.BackgroundTransparency = if st == "claimed" then 0.55 else 0.4
	card.lock.Visible = st == "locked" or st == "needsPremium"
	card.check.Visible = st == "claimed"
	card.ribbon.Visible = st == "claimable"
	card.glow.Visible = st == "claimable"
	card.glowStroke.Transparency = 0.25
	card.stroke.Color = if st == "claimable"
		then C.green
		elseif st == "claimed" then C.greyDark
		elseif premium then C.goldDeep
		else Color3.fromRGB(120, 140, 190)
	card.stroke.Thickness = if st == "claimable" then 4 else 2
	if card.shine then
		card.shine.Visible = s.anim.shine and st ~= "claimed" and st ~= "empty"
	end
	card.content.Position = UDim2.new()
	local sel = s.sel
	card.ring.Visible = sel ~= nil and sel.tier == card.tier and sel.track == card.track
end

local function applyColumn(cu: ColUI)
	local s = S
	local col = s and s.model.columns[cu.free.tier]
	if not col then
		return
	end
	cu.hl.Visible = col.current
	cu.pill.BackgroundColor3 = if col.current then C.white elseif col.reached then C.cheese else C.greyDark
	cu.pill.TextColor3 = if col.reached or col.current then C.ink else C.textDim
	cu.pillStroke.Color = if col.current then C.cheese else C.brownDark
	cu.pillStroke.Thickness = if col.current then 3 else 2
	applyCard(cu.free)
	applyCard(cu.premium)
end

local refreshFeatured: () -> ()
local refreshHeader: () -> ()

local function refreshAll()
	local s = S
	if not s then
		return
	end
	for _, cu in s.cols do
		applyColumn(cu)
	end
	if s.railFill then
		local L = s.lay
		s.railFill.Size = UDim2.fromOffset(
			PassModel.railFill(s.model.tier, s.model.frac, s.model.maxTier, L.cardW, L.colGap, L.scroller.w),
			8
		)
	end
	refreshHeader()
	refreshFeatured()
end

----------------------------------------------------------------------
-- Effects: pop, burst, fly, flash
----------------------------------------------------------------------

local function bumpChip(chip: GuiObject?)
	local s = S
	if not s or not chip or not s.anim.pop then
		return
	end
	local sc = chip:FindFirstChild("BumpScale") :: UIScale?
	if not sc then
		return
	end
	animate(0.3, 0, "linear", function(e)
		sc.Scale = 1 + 0.22 * math.sin(math.pi * e)
	end)
end

local function burstAt(at: Vector2, color: Color3)
	local s = S
	if not s or s.anim.particles <= 0 then
		return
	end
	local layer: Frame = s.fxLayer
	local parts = PassModel.burst(s.anim.particles, math.floor(s.t * 1000) + 7)
	local frames: { Frame } = {}
	for i, p in parts do
		local f = make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(at.X, at.Y),
			Size = UDim2.fromOffset(p.size, p.size),
			BackgroundColor3 = if i % 3 == 0 then C.white elseif i % 3 == 1 then color else C.cheese,
			BorderSizePixel = 0,
			ZIndex = 60,
			Parent = layer,
		}) :: Frame
		if i % 2 == 0 then
			Theme.round().Parent = f
		end
		frames[i] = f
	end
	-- shock ring
	local ring = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(at.X, at.Y),
		Size = UDim2.fromOffset(20, 20),
		BackgroundTransparency = 1,
		ZIndex = 59,
		Parent = layer,
	}) :: Frame
	Theme.round().Parent = ring
	local rs = Theme.stroke(color, 5)
	rs.Parent = ring
	local start = s.t
	table.insert(s.tasks, function(t: number): boolean
		local age = t - start
		local alive = false
		for i, p in parts do
			local f = frames[i]
			if f.Parent then
				if age >= p.life then
					f:Destroy()
				else
					alive = true
					f.Position =
						UDim2.fromOffset(at.X + p.vx * age, at.Y + p.vy * age + 0.5 * 900 * age * age)
					f.Rotation = p.spin * age
					f.BackgroundTransparency = math.clamp(age / p.life, 0, 1) ^ 2
				end
			end
		end
		if ring.Parent then
			local x = math.clamp(age / 0.45, 0, 1)
			if x >= 1 then
				ring:Destroy()
			else
				alive = true
				local d = 20 + 200 * PassModel.ease("outCubic", x)
				ring.Size = UDim2.fromOffset(d, d)
				rs.Transparency = x
			end
		end
		return alive
	end)
end

local function flyTo(card: CardUI, info: PassModel.RewardInfo, reward: any)
	local s = S
	if not s or not s.anim.fly then
		bumpChip(s and s.chips[info.fly])
		return
	end
	local target: GuiObject? = s.chips[info.fly] or s.chips.locker
	if not target then
		return
	end
	local layer: Frame = s.fxLayer
	local a = toLocal(layer, centreOf(card.button))
	local b = toLocal(layer, centreOf(target))
	local holder = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(a.X, a.Y),
		Size = UDim2.fromOffset(56, 56),
		BackgroundTransparency = 1,
		ZIndex = 61,
		Parent = layer,
	}) :: Frame
	local ic = makeIcon(info, reward, 56, false)
	ic.ZIndex = 62
	ic.Parent = holder
	local sc = make("UIScale", { Scale = 1, Parent = holder }) :: UIScale
	animate(0.65, 0.08, "inOutSine", function(e)
		local x, y = PassModel.arc(a.X, a.Y, b.X, b.Y, 140, e)
		holder.Position = UDim2.fromOffset(x, y)
		sc.Scale = 1.25 - 0.75 * e
		holder.Rotation = 20 * math.sin(e * math.pi)
	end, function()
		holder:Destroy()
		bumpChip(target)
	end)
end

local function celebrate(card: CardUI)
	local s = S
	local slot = slotOf(card.tier, card.track)
	if not s or not slot then
		return
	end
	local info = infoOf(slot)
	sound("pickup")
	if s.anim.pop then
		animate(PassModel.POP_TIME, 0, "linear", function(e)
			card.scale.Scale = PassModel.popScale(e * PassModel.POP_TIME)
		end, function()
			card.scale.Scale = 1
		end)
	end
	burstAt(toLocal(s.fxLayer, centreOf(card.button)), Theme.rarityColor(info.rarity))
	flyTo(card, info, slot.reward)
end

local function tierUp(newTier: number)
	local s = S
	if not s then
		return
	end
	sound("levelUpChime")
	if s.badgeScale and s.anim.pop then
		local sc: UIScale = s.badgeScale
		animate(0.45, 0, "linear", function(e)
			sc.Scale = 1 + 0.3 * math.sin(math.pi * e)
		end)
	end
	if not s.anim.flash then
		return
	end
	local flash: Frame = s.flash
	animate(0.6, 0, "outQuad", function(e)
		flash.BackgroundTransparency = 0.25 + 0.75 * e
	end)
	local banner = Theme.label({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromOffset(520, 110),
		Text = string.format(TEXT.tierUp, newTier),
		TextSize = 72,
		TextColor3 = C.cheese,
		ZIndex = 70,
		Parent = s.fxLayer,
	})
	Theme.textStroke(C.brownDark, 4).Parent = banner
	local bs = make("UIScale", { Scale = 0.3, Parent = banner }) :: UIScale
	animate(0.4, 0, "outBack", function(e)
		bs.Scale = 0.3 + 0.7 * e
	end)
	animate(0.5, 1.1, "linear", function(e)
		banner.TextTransparency = e
	end, function()
		banner:Destroy()
	end)
end

----------------------------------------------------------------------
-- Claims and purchase
----------------------------------------------------------------------

local function cardFor(tier: number, track: string): CardUI?
	local s = S
	local cu = s and s.cols[tier]
	if not cu then
		return nil
	end
	return if track == "premium" then cu.premium else cu.free
end

local function claim(tier: number, track: string, sent: boolean?): boolean
	local s = S
	local slot = slotOf(tier, track)
	if not s or not slot or slot.state ~= "claimable" then
		return false
	end
	local key = PassModel.key(tier, track)
	if s.pending[key] and not sent then
		return false
	end
	s.pending[key] = s.t + PENDING_SECONDS
	if not sent then
		Remotes.fire(Remotes.C2S.ClaimPassTier, tier, track)
	end
	slot.state = "claimed" -- optimistic; the next Pass view confirms or reverts it
	s.model.claimable = math.max(0, s.model.claimable - 1)
	local card = cardFor(tier, track)
	if card then
		applyCard(card)
		celebrate(card)
	end
	refreshHeader()
	refreshFeatured()
	return true
end

local function claimAll()
	local s = S
	if not s or s.queue then
		return
	end
	local q = PassModel.claimQueue(s.model, s.pending)
	if #q == 0 then
		return
	end
	-- one ClaimPassAll request when the server has it; the cards then only
	-- animate one by one. Without it: one ClaimPassTier per slot, paced.
	s.queueSent = Remotes.C2S.ClaimPassAll ~= nil
	if s.queueSent then
		for _, e in q do
			s.pending[PassModel.key(e.tier, e.track)] = s.t + PENDING_SECONDS
		end
		Remotes.fire(Remotes.C2S.ClaimPassAll)
	end
	s.queue = q
	s.queueNext = s.t
	refreshHeader()
end

-- Only ever called from the "Unlock Premium" buttons (a player press).
local function promptPremium()
	local s = S
	if not s or s.model.premium or not s.model.premiumKey then
		return
	end
	if os.clock() - lastPromptAt < PROMPT_COOLDOWN then
		return
	end
	lastPromptAt = os.clock()
	Remotes.fire(Remotes.C2S.PromptProduct, s.model.premiumKey)
end

----------------------------------------------------------------------
-- Selection / featured panel
----------------------------------------------------------------------

local function setDrawer(open: boolean)
	local s = S
	if not s or s.lay.featuredMode ~= "drawer" or not s.featured then
		return
	end
	local f: Frame = s.featured
	if f.Visible == open then
		return
	end
	f.Visible = open
	if open then
		refreshFeatured()
		if s.anim.smoothScroll then
			local home = f.Position
			animate(0.25, 0, "outCubic", function(e)
				f.Position = home + UDim2.fromOffset(math.floor((1 - e) * 80), 0)
			end, function()
				f.Position = home
			end)
		end
	end
	local sr = s.showroom
	if sr then
		pcall(sr.setActive, open and s.showroomOn == true)
	end
end

local function selectSlot(tier: number, track: string, scroll: boolean, openDrawer: boolean?)
	local s = S
	if not s then
		return
	end
	local old = s.sel
	s.sel = { tier = tier, track = track }
	if old then
		local oc = cardFor(old.tier, old.track)
		if oc then
			oc.ring.Visible = false
		end
	end
	local nc = cardFor(tier, track)
	if nc then
		nc.ring.Visible = true
	end
	if scroll then
		scrollTo(tier)
	end
	refreshFeatured()
	if openDrawer then
		setDrawer(true)
	end
end

local function onCard(tier: number, track: string)
	local s = S
	if not s then
		return
	end
	if s.dragEndAt and s.t - s.dragEndAt < 0.2 then
		return -- the end of a mouse drag, not a click
	end
	sound("click")
	local slot = slotOf(tier, track)
	if slot and slot.state == "claimable" then
		selectSlot(tier, track, false)
		claim(tier, track)
	else
		selectSlot(tier, track, false, true)
	end
end

local function showPreview(info: PassModel.RewardInfo, reward: any)
	local s = S
	if not s or not s.previewBox then
		return
	end
	local box: Frame = s.previewBox
	if s.bigIcon then
		s.bigIcon:Destroy()
		s.bigIcon = nil
	end
	local ref = info.ref
	local CP = if ref and (string.sub(ref, 1, 9) == "cosmetic:" or string.sub(ref, 1, 5) == "skin:")
		then optional("CosmeticPreview")
		else nil
	local PR = if CP then optionalUtil("PreviewRecipe") else nil
	local shown = false
	if CP and PR and type(CP.showroom) == "function" then
		local ok = pcall(function()
			if not s.showroom then
				s.showroom = CP.showroom(box, { Size = UDim2.fromScale(1, 1), ZIndex = 3 })
			end
			local recipe = CP.recipe(ref)
			local outfit = PR.outfit(CP.baseOutfit(nil), recipe)
			s.showroom.frame.Visible = true
			s.showroom.show(outfit)
			s.showroomOn = true
			s.showroom.setActive(s.featured.Visible)
		end)
		shown = ok
	end
	if not shown then
		s.showroomOn = false
		local sr = s.showroom
		if sr then
			pcall(function()
				sr.frame.Visible = false
				sr.setActive(false)
			end)
		end
		local side = math.floor(math.min(box.AbsoluteSize.X, box.AbsoluteSize.Y) / Theme.scaleOf(box))
		local size = math.clamp(math.floor(side * 0.55), 64, 190)
		local holder = make("Frame", {
			Name = "BigIcon",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(size, size),
			BackgroundTransparency = 1,
			ZIndex = 4,
			Parent = box,
		}) :: Frame
		local ic = makeIcon(info, reward, size, true)
		ic.AnchorPoint = Vector2.new(0.5, 0.5)
		ic.Position = UDim2.fromScale(0.5, 0.5)
		ic.ZIndex = 5
		ic.Parent = holder
		s.bigIcon = holder
		if s.anim.pop then
			local sc = make("UIScale", { Scale = 0.6, Parent = holder }) :: UIScale
			animate(0.3, 0, "outBack", function(e)
				sc.Scale = 0.6 + 0.4 * e
			end)
		end
	end
	if s.rays then
		s.rays.Visible = not shown
		s.rays.ImageColor3 = Theme.rarityColor(info.rarity)
	end
end

refreshFeatured = function()
	local s = S
	if not s or not s.featured or not s.sel then
		return
	end
	local slot = slotOf(s.sel.tier, s.sel.track)
	if not slot then
		return
	end
	local info = infoOf(slot)
	local premium = slot.track == "premium"
	s.featTag.Text = string.format("TIER %d · %s", slot.tier, if premium then TEXT.premium else TEXT.free)
	s.featTag.BackgroundColor3 = if premium then C.goldDeep else FREE_BG
	s.featTitle.Text = if slot.state == "empty" then "—" else info.title
	s.featSub.Text = info.sub
	s.featState.Text = PassModel.stateText(slot)
	s.featState.TextColor3 = if slot.state == "claimable" then C.green else C.textDim
	s.featPitch.Visible = premium and not s.model.premium and s.model.premiumKey ~= nil
	local key = slot.tier .. slot.track .. slot.state
	if s.featKey ~= key then
		s.featKey = key
		showPreview(info, slot.reward)
	end
	local btn: TextButton = s.featBtn
	local st = slot.state
	if st == "claimable" then
		btn.Visible = true
		btn.Text = TEXT.claim
		btn.BackgroundColor3 = C.green
		Theme.setEnabled(btn, true)
		s.featAction = "claim"
	elseif st == "needsPremium" and s.model.premiumKey and not s.model.premium then
		btn.Visible = true
		btn.Text = TEXT.unlock
		btn.BackgroundColor3 = C.orange
		Theme.setEnabled(btn, true)
		s.featAction = "unlock"
	elseif st == "claimed" or st == "locked" then
		btn.Visible = true
		btn.Text = PassModel.stateText(slot)
		btn.BackgroundColor3 = C.creamDark
		Theme.setEnabled(btn, false)
		s.featAction = nil
	else
		btn.Visible = false
		s.featAction = nil
	end
end

refreshHeader = function()
	local s = S
	if not s or not s.tierText then
		return
	end
	local m: PassModel.Model = s.model
	s.seasonTag.Text = string.format(TEXT.season, m.season)
	s.seasonTitle.Text = m.seasonName
	s.tierText.Text = tostring(m.tier)
	s.barText.Text = if m.known then PassModel.xpCaption(m, Format.int) else TEXT.loading
	s.barTarget = m.frac
	if not s.anim.smoothBar then
		s.barShown = m.frac
		s.barWrap = false
	end
	local busy = s.queue ~= nil
	local n = m.claimable
	s.claimAllBtn.Text = if n > 0 then string.format("%s (%d)", TEXT.claimAll, n) else TEXT.claimAll
	Theme.setEnabled(s.claimAllBtn, n > 0 and not busy)
	s.unlockBtn.Visible = not m.premium and m.premiumKey ~= nil
	s.ownedTag.Visible = m.premium
	s.premiumLabel.Text = if m.premium then TEXT.premium else "🔒 " .. TEXT.premium
	local p = profile()
	s.cheeseText.Text = "🧀 " .. Format.short(tonumber(p.cheese) or 0)
	s.goldenText.Text = "✨ " .. Format.short(tonumber(p.goldenCheese) or 0)
end

----------------------------------------------------------------------
-- Building
----------------------------------------------------------------------

local function chip(parent: Instance, text: string, order: number, w: number, h: number): TextLabel
	local l = Theme.label({
		LayoutOrder = order,
		Size = UDim2.fromOffset(w, h),
		BackgroundColor3 = C.shade,
		BackgroundTransparency = 0.3,
		Text = text,
		TextSize = 18,
		TextColor3 = C.cream,
		Parent = parent,
	})
	Theme.round().Parent = l
	Theme.stroke(C.goldDeep, 1, 0.3).Parent = l
	make("UIScale", { Name = "BumpScale", Scale = 1, Parent = l })
	return l
end

local function buildCard(parent: Instance, tier: number, track: string, x: number, y: number): CardUI
	local s = S
	local L: PassModel.PassLayout = s.lay
	local w, h = L.cardW, L.cardH
	local premium = track == "premium"
	local slot = slotOf(tier, track) :: PassModel.Slot
	local info = infoOf(slot)
	local btn = make("TextButton", {
		Name = "Card_" .. track,
		Position = UDim2.fromOffset(x + w / 2, y + h / 2),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(w, h),
		BackgroundColor3 = if premium then C.cheese else FREE_BG,
		AutoButtonColor = false,
		Text = "",
		Selectable = false,
		ClipsDescendants = false,
		ZIndex = 2,
		Parent = parent,
	}) :: TextButton
	Theme.corner(14).Parent = btn
	if premium then
		Theme.gradient(btn, C.goldLight, C.goldDeep, 90)
	else
		Theme.gradient(btn, Color3.fromRGB(110, 132, 180), FREE_BG2, 90)
	end
	local stroke = Theme.stroke(C.goldDeep, 2)
	stroke.Parent = btn
	local scale = make("UIScale", { Name = "PopScale", Scale = 1, Parent = btn }) :: UIScale
	-- glow (claimable): an outer ring that breathes
	local glow = make("Frame", {
		Name = "Glow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 14, 1, 14),
		BackgroundTransparency = 1,
		ZIndex = 1,
		Visible = false,
		Parent = btn,
	}) :: Frame
	Theme.corner(20).Parent = glow
	local glowStroke = Theme.stroke(C.cheese, 6, 0.25)
	glowStroke.Parent = glow
	-- rarity strip
	local strip = make("Frame", {
		Size = UDim2.new(1, -20, 0, 5),
		Position = UDim2.fromOffset(10, 6),
		BackgroundColor3 = Theme.rarityColor(info.rarity),
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = btn,
	})
	Theme.round().Parent = strip
	local content = make("Frame", {
		Name = "Content",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = btn,
	}) :: Frame
	local iconSize = math.floor(math.min(w * 0.5, h * 0.36))
	local ic = makeIcon(info, slot.reward, iconSize, true)
	ic.AnchorPoint = Vector2.new(0.5, 0)
	ic.Position = UDim2.new(0.5, 0, 0, 16)
	ic.ZIndex = 4
	ic.Parent = content
	local ink = if premium then C.ink else C.white
	local title = Theme.label({
		Position = UDim2.fromOffset(6, 16 + iconSize + 4),
		Size = UDim2.new(1, -12, 0, 30),
		Text = info.title,
		TextSize = L.text.card,
		TextColor3 = ink,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		ZIndex = 4,
		Parent = content,
	})
	if not premium then
		Theme.textStroke(C.shade, 1).Parent = title
	end
	Theme.label({
		Position = UDim2.fromOffset(6, 16 + iconSize + 34),
		Size = UDim2.new(1, -12, 1, -(16 + iconSize + 34 + 6)),
		Text = info.sub,
		TextSize = L.text.small,
		Font = Theme.FONT_BODY,
		TextColor3 = if premium then C.brownDark else C.textDim,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 4,
		Parent = content,
	})
	local empty = Theme.label({
		Size = UDim2.fromScale(1, 1),
		Text = "—",
		TextSize = 30,
		TextColor3 = if premium then C.brown else C.textDim,
		TextTransparency = 0.4,
		Visible = false,
		ZIndex = 4,
		Parent = btn,
	})
	-- shine sweep (premium)
	local shine: Frame? = nil
	local shineGrad: UIGradient? = nil
	if premium then
		local sh = make("Frame", {
			Name = "Shine",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = C.white,
			BackgroundTransparency = 0,
			ZIndex = 5,
			Visible = false,
			Parent = btn,
		}) :: Frame
		Theme.corner(14).Parent = sh
		shineGrad = make("UIGradient", {
			Rotation = 20,
			Offset = Vector2.new(1.5, 0),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.42, 1),
				NumberSequenceKeypoint.new(0.5, 0.5),
				NumberSequenceKeypoint.new(0.58, 1),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Parent = sh,
		})
		shine = sh
	end
	local overlay = make("Frame", {
		Name = "Dim",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.shadow,
		BackgroundTransparency = 0.4,
		ZIndex = 6,
		Visible = false,
		Parent = btn,
	}) :: Frame
	Theme.corner(14).Parent = overlay
	local lockSize = math.floor(math.min(w, h) * 0.26)
	local lock = Theme.icon("lock", lockSize, C.cream, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		ZIndex = 7,
		Visible = false,
		Parent = btn,
	})
	local check = Theme.label({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 12),
		Size = UDim2.fromOffset(34, 34),
		BackgroundColor3 = C.green,
		Text = "✔",
		TextSize = 20,
		TextColor3 = C.white,
		ZIndex = 7,
		Visible = false,
		Parent = btn,
	})
	Theme.round().Parent = check
	Theme.stroke(C.greenDark, 2).Parent = check
	local ribbon = Theme.label({
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, 8),
		Size = UDim2.new(1, -20, 0, 30),
		BackgroundColor3 = C.green,
		Text = string.upper(TEXT.claim),
		TextSize = 18,
		TextColor3 = C.white,
		ZIndex = 8,
		Visible = false,
		Parent = btn,
	})
	Theme.round().Parent = ribbon
	Theme.stroke(C.greenDark, 2).Parent = ribbon
	Theme.textStroke(C.greenDark, 1).Parent = ribbon
	local ring = make("Frame", {
		Name = "Selected",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 8, 1, 8),
		BackgroundTransparency = 1,
		ZIndex = 9,
		Visible = false,
		Parent = btn,
	}) :: Frame
	Theme.corner(18).Parent = ring
	Theme.stroke(C.white, 3).Parent = ring
	Theme.hover(btn, 1.04)
	local card: CardUI = {
		button = btn,
		content = content,
		stroke = stroke,
		glow = glow,
		glowStroke = glowStroke,
		shine = shine,
		shineGrad = shineGrad,
		scale = scale,
		overlay = overlay,
		lock = lock,
		check = check,
		ribbon = ribbon,
		ring = ring,
		empty = empty,
		tier = tier,
		track = track,
		phase = tier * 0.7 + (if premium then 1.3 else 0),
	}
	btn.Activated:Connect(function()
		onCard(tier, track)
	end)
	return card
end

local function buildHeader(panel: Frame)
	local s = S
	local L: PassModel.PassLayout = s.lay
	local hr = L.header
	local P = L.headerParts
	local header = make("Frame", {
		Name = "Header",
		Position = UDim2.fromOffset(hr.x, hr.y),
		Size = UDim2.fromOffset(hr.w, hr.h),
		BackgroundColor3 = Color3.fromRGB(70, 46, 96),
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = panel,
	}) :: Frame
	Theme.corner(16).Parent = header
	Theme.gradient(header, Color3.fromRGB(255, 230, 255), Color3.fromRGB(150, 120, 170), 90)
	Theme.goldStroke(2, 0.2).Parent = header
	s.header = header
	local flash = make("Frame", {
		Name = "Flash",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.white,
		BackgroundTransparency = 1,
		ZIndex = 20,
		Parent = header,
	})
	Theme.corner(16).Parent = flash
	s.flash = flash

	-- season name
	local season = make("Frame", {
		Position = UDim2.fromOffset(P.season.x + 14, P.season.y),
		Size = UDim2.fromOffset(P.season.w - 14, P.season.h),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = header,
	})
	s.seasonTag = Theme.badge("SEASON 1", C.purple, {
		Position = UDim2.new(0, 0, 0.5, -40),
		Size = UDim2.fromOffset(0, 26),
		TextSize = 14,
		ZIndex = 4,
		Parent = season,
	})
	s.seasonTitle = Theme.label({
		Position = UDim2.new(0, 0, 0.5, -12),
		Size = UDim2.new(1, 0, 0, 44),
		Text = "",
		TextSize = L.text.title,
		TextColor3 = C.cheese,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		ZIndex = 4,
		Parent = season,
	})
	Theme.textStroke(C.brownDark, 2).Parent = s.seasonTitle
	Theme.label({
		Position = UDim2.new(0, 0, 0.5, 30),
		Size = UDim2.new(1, 0, 0, 20),
		Text = "🐘 Herd Pass",
		TextSize = 14,
		TextColor3 = C.cream,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 4,
		Parent = season,
	})

	-- tier badge
	local badge = make("Frame", {
		Position = UDim2.fromOffset(P.badge.x, P.badge.y),
		Size = UDim2.fromOffset(P.badge.w, P.badge.h),
		BackgroundColor3 = C.cheese,
		ZIndex = 3,
		Parent = header,
	}) :: Frame
	Theme.round().Parent = badge
	Theme.gradient(badge, C.goldLight, C.cheeseDark, 90)
	Theme.stroke(C.brownDark, 3).Parent = badge
	s.badgeScale = make("UIScale", { Scale = 1, Parent = badge })
	Theme.label({
		Position = UDim2.fromScale(0, 0.12),
		Size = UDim2.fromScale(1, 0.24),
		Text = "TIER",
		TextSize = 14,
		TextColor3 = C.brownDark,
		ZIndex = 4,
		Parent = badge,
	})
	s.tierText = Theme.label({
		Position = UDim2.fromScale(0, 0.3),
		Size = UDim2.fromScale(1, 0.58),
		Text = "0",
		TextSize = 44,
		TextColor3 = C.ink,
		ZIndex = 4,
		Parent = badge,
	})

	-- chips + XP bar
	local barArea = make("Frame", {
		Position = UDim2.fromOffset(P.bar.x, P.bar.y),
		Size = UDim2.fromOffset(P.bar.w, P.bar.h),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = header,
	})
	local chipH = 34
	local barH = 32
	local top = math.floor((P.bar.h - chipH - 8 - barH) / 2)
	local chipRow = make("Frame", {
		Position = UDim2.fromOffset(0, top),
		Size = UDim2.new(1, 0, 0, chipH),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = barArea,
	})
	Theme.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left).Parent = chipRow
	local cw = math.floor((P.bar.w - 16) / 3)
	s.cheeseText = chip(chipRow, "🧀", 1, math.min(cw, 140), chipH)
	s.goldenText = chip(chipRow, "✨", 2, math.min(cw, 120), chipH)
	local locker = chip(chipRow, "🎒", 3, math.min(cw, 64), chipH)
	s.chips = { cheese = s.cheeseText, golden = s.goldenText, locker = locker }
	local bar = make("Frame", {
		Position = UDim2.fromOffset(0, top + chipH + 8),
		Size = UDim2.new(1, 0, 0, barH),
		BackgroundColor3 = C.shade,
		BackgroundTransparency = 0.1,
		ClipsDescendants = true,
		ZIndex = 3,
		Parent = barArea,
	})
	Theme.corner(10).Parent = bar
	Theme.stroke(C.brownDark, 2).Parent = bar
	local fill = make("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = C.cheese,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = bar,
	}) :: Frame
	Theme.corner(10).Parent = fill
	Theme.gradient(fill, C.goldLight, C.cheeseDark, 90)
	s.barFill = fill
	s.barText = Theme.label({
		Size = UDim2.fromScale(1, 1),
		Text = "",
		TextSize = 16,
		TextColor3 = C.white,
		ZIndex = 6,
		Parent = bar,
	})
	Theme.textStroke(C.shade, 2).Parent = s.barText

	-- buttons
	s.claimAllBtn = Theme.button(TEXT.claimAll, C.green, {
		Position = UDim2.fromOffset(P.claimAll.x, P.claimAll.y),
		Size = UDim2.fromOffset(P.claimAll.w, P.claimAll.h),
		TextSize = 20,
		TextColor3 = C.white,
		ZIndex = 4,
		Parent = header,
	}, claimAll)
	s.unlockBtn = Theme.button(TEXT.unlock, C.orange, {
		Position = UDim2.fromOffset(P.unlock.x, P.unlock.y),
		Size = UDim2.fromOffset(P.unlock.w, P.unlock.h),
		TextSize = 20,
		TextColor3 = C.white,
		ZIndex = 4,
		Visible = false,
		Parent = header,
	}, promptPremium)
	s.ownedTag = Theme.label({
		Position = UDim2.fromOffset(P.unlock.x, P.unlock.y),
		Size = UDim2.fromOffset(P.unlock.w, P.unlock.h),
		BackgroundColor3 = C.goldDeep,
		Text = TEXT.premiumOwned,
		TextSize = 20,
		TextColor3 = C.white,
		ZIndex = 4,
		Visible = false,
		Parent = header,
	})
	Theme.corner(14).Parent = s.ownedTag
	Theme.stroke(C.brownDark, 2).Parent = s.ownedTag
	Theme.button("✕", C.red, {
		Position = UDim2.fromOffset(P.close.x, P.close.y),
		Size = UDim2.fromOffset(P.close.w, P.close.h),
		TextSize = 24,
		TextColor3 = C.white,
		ZIndex = 4,
		Parent = header,
	}, function()
		PassUI.close()
	end)
end

local function buildTrack(panel: Frame)
	local s = S
	local L: PassModel.PassLayout = s.lay
	local m: PassModel.Model = s.model
	local tr = L.track
	local bg = make("Frame", {
		Name = "TrackBg",
		Position = UDim2.fromOffset(tr.x, tr.y),
		Size = UDim2.fromOffset(tr.w, tr.h),
		BackgroundColor3 = C.shade,
		BackgroundTransparency = 0.35,
		ZIndex = 1,
		Parent = panel,
	})
	Theme.corner(14).Parent = bg
	-- sticky row labels
	local rowY = { free = L.pillH + L.rowGap, premium = L.pillH + 2 * L.rowGap + L.cardH }
	for _, track in { "free", "premium" } do
		local premium = track == "premium"
		local l = Theme.label({
			Position = UDim2.fromOffset(tr.x + 6, tr.y + rowY[track]),
			Size = UDim2.fromOffset(L.labelW - 6, L.cardH),
			BackgroundColor3 = if premium then C.goldDeep else FREE_BG,
			Text = if premium then TEXT.premium else TEXT.free,
			TextSize = 16,
			TextColor3 = C.white,
			TextWrapped = true,
			ZIndex = 3,
			Parent = panel,
		})
		Theme.corner(12).Parent = l
		if premium then
			Theme.gradient(l, C.goldLight, C.goldDeep, 90)
			Theme.textStroke(C.brownDark, 2).Parent = l
			s.premiumLabel = l
		else
			Theme.textStroke(C.shade, 1).Parent = l
		end
	end
	local sr = L.scroller
	local n = m.maxTier
	local canvasW = PassModel.canvasWidth(n, L.cardW, L.colGap, sr.w)
	local scroller = make("ScrollingFrame", {
		Name = "Track",
		Position = UDim2.fromOffset(sr.x, sr.y),
		Size = UDim2.fromOffset(sr.w, sr.h),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollingDirection = Enum.ScrollingDirection.X,
		CanvasSize = UDim2.new(0, canvasW, 1, 0),
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = C.cheese,
		HorizontalScrollBarInset = Enum.ScrollBarInset.None,
		ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
		ClipsDescendants = true,
		Selectable = false,
		ZIndex = 2,
		Parent = panel,
	}) :: ScrollingFrame
	s.scroller = scroller
	-- progress rail behind the tier pills
	local rail = make("Frame", {
		Position = UDim2.fromOffset(0, math.floor(L.pillH / 2) - 4),
		Size = UDim2.fromOffset(canvasW, 8),
		BackgroundColor3 = C.greyDark,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = scroller,
	})
	Theme.round().Parent = rail
	local railFill = make("Frame", {
		Size = UDim2.fromOffset(0, 8),
		BackgroundColor3 = C.cheese,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = rail,
	})
	Theme.round().Parent = railFill
	s.railFill = railFill
	s.cols = {}
	for _, col in m.columns do
		local i = col.tier
		local x = PassModel.columnX(i, L.cardW, L.colGap, sr.w)
		local frame = make("Frame", {
			Name = "Tier" .. i,
			Position = UDim2.fromOffset(x, 0),
			Size = UDim2.fromOffset(L.cardW, sr.h),
			BackgroundTransparency = 1,
			ZIndex = 3,
			Parent = scroller,
		}) :: Frame
		local scale = make("UIScale", { Scale = 1, Parent = frame }) :: UIScale
		local hl = make("Frame", {
			Name = "Current",
			Position = UDim2.fromOffset(-6, 0),
			Size = UDim2.new(1, 12, 1, -4),
			BackgroundColor3 = C.cheese,
			BackgroundTransparency = 0.82,
			ZIndex = 1,
			Visible = false,
			Parent = frame,
		}) :: Frame
		Theme.corner(16).Parent = hl
		Theme.stroke(C.cheese, 2, 0.3).Parent = hl
		local pw = math.min(L.cardW - 20, 88)
		local pill = Theme.label({
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 4),
			Size = UDim2.fromOffset(pw, L.pillH - 8),
			BackgroundColor3 = C.greyDark,
			Text = tostring(i),
			TextSize = 20,
			ZIndex = 4,
			Parent = frame,
		})
		Theme.round().Parent = pill
		local pillStroke = Theme.stroke(C.brownDark, 2)
		pillStroke.Parent = pill
		local cu: ColUI = {
			frame = frame,
			scale = scale,
			homeX = x,
			pill = pill,
			pillStroke = pillStroke,
			hl = hl,
			free = buildCard(frame, i, "free", 0, rowY.free),
			premium = buildCard(frame, i, "premium", 0, rowY.premium),
		}
		s.cols[i] = cu
	end

	-- mouse drag (touch and the wheel use the frame's own scrolling)
	scroller.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			s.drag = { x = input.Position.X, canvas = scroller.CanvasPosition.X, moved = false }
			s.scrollTarget = nil
		end
	end)
	scroller:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		local last = s.lastSetX
		if last == nil or math.abs(scroller.CanvasPosition.X - last) > 0.5 then
			s.userScrollAt = s.t
			s.scrollTarget = nil
		end
	end)
end

local function buildFeatured(panel: Frame)
	local s = S
	local L: PassModel.PassLayout = s.lay
	local fr = L.featured
	local drawer = L.featuredMode == "drawer"
	local f = Theme.card({
		Name = "Featured",
		Position = UDim2.fromOffset(fr.x, fr.y),
		Size = UDim2.fromOffset(fr.w, fr.h),
		BackgroundColor3 = PANEL_BG,
		BackgroundTransparency = 0.02,
		ZIndex = 30,
		Visible = not drawer,
		Parent = panel,
	}, { shadow = drawer })
	s.featured = f
	local pad = 12
	local tagH = 30
	s.featTag = Theme.badge("TIER 1 · FREE", FREE_BG, {
		Position = UDim2.fromOffset(pad, pad),
		Size = UDim2.fromOffset(0, tagH),
		TextSize = 15,
		ZIndex = 31,
		Parent = f,
	})
	if drawer then
		Theme.button("✕", C.red, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -pad, 0, pad),
			Size = UDim2.fromOffset(L.touch, L.touch),
			TextSize = 22,
			TextColor3 = C.white,
			ZIndex = 33,
			Parent = f,
		}, function()
			setDrawer(false)
		end)
	end
	local btnH = L.touch
	local textH = 34 + 26 + 24
	local pitchH = 44
	local topY = pad + math.max(tagH, if drawer then L.touch else 0) + 8
	local boxH = math.max(80, fr.h - topY - textH - pitchH - btnH - pad * 3)
	local boxW = fr.w - 2 * pad
	local side = math.min(boxW, boxH)
	local box = make("Frame", {
		Name = "Preview",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, topY),
		Size = UDim2.fromOffset(boxW, side),
		BackgroundColor3 = Color3.fromRGB(48, 34, 66),
		ClipsDescendants = true,
		ZIndex = 31,
		Parent = f,
	}) :: Frame
	Theme.corner(14).Parent = box
	Theme.gradient(box, Color3.fromRGB(255, 255, 255), Color3.fromRGB(120, 100, 150), 90)
	s.previewBox = box
	-- light rays behind the big icon (a rotating gradient disc)
	local rays = make("ImageLabel", {
		Name = "Rays",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(side * 1.3, side * 1.3),
		BackgroundColor3 = C.white,
		BackgroundTransparency = 0.6,
		ImageTransparency = 1,
		ZIndex = 32,
		Parent = box,
	}) :: ImageLabel
	Theme.round().Parent = rays
	make("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.2, 0.3),
			NumberSequenceKeypoint.new(0.3, 1),
			NumberSequenceKeypoint.new(0.5, 1),
			NumberSequenceKeypoint.new(0.7, 0.3),
			NumberSequenceKeypoint.new(0.8, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = rays,
	})
	s.rays = rays
	local y = topY + side + 8
	s.featTitle = Theme.label({
		Position = UDim2.fromOffset(pad, y),
		Size = UDim2.new(1, -2 * pad, 0, 34),
		Text = "",
		TextSize = 28,
		TextColor3 = C.cheese,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		ZIndex = 31,
		Parent = f,
	})
	Theme.textStroke(C.brownDark, 2).Parent = s.featTitle
	s.featSub = Theme.label({
		Position = UDim2.fromOffset(pad, y + 34),
		Size = UDim2.new(1, -2 * pad, 0, 26),
		Text = "",
		TextSize = 16,
		Font = Theme.FONT_BODY,
		TextColor3 = C.cream,
		ZIndex = 31,
		Parent = f,
	})
	s.featState = Theme.label({
		Position = UDim2.fromOffset(pad, y + 60),
		Size = UDim2.new(1, -2 * pad, 0, 24),
		Text = "",
		TextSize = 16,
		TextColor3 = C.textDim,
		ZIndex = 31,
		Parent = f,
	})
	s.featPitch = Theme.label({
		Position = UDim2.fromOffset(pad, y + textH + 4),
		Size = UDim2.new(1, -2 * pad, 0, pitchH),
		Text = TEXT.premiumPitch,
		TextSize = 12,
		Font = Theme.FONT_LIGHT,
		TextColor3 = C.textDim,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		ZIndex = 31,
		Visible = false,
		Parent = f,
	})
	s.featBtn = Theme.button(TEXT.claim, C.green, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -pad),
		Size = UDim2.new(1, -2 * pad, 0, btnH),
		TextSize = 22,
		TextColor3 = C.white,
		ZIndex = 32,
		Parent = f,
	}, function()
		local sel = s.sel
		if not sel then
			return
		end
		if s.featAction == "claim" then
			claim(sel.tier, sel.track)
		elseif s.featAction == "unlock" then
			promptPremium() -- the player pressed "Unlock Premium"
		end
	end)
	s.featKey = nil
end

local function intro()
	local s = S
	if not s then
		return
	end
	local a: PassModel.Anim = s.anim
	local panel: Frame = s.panel
	if a.intro == "pop" then
		local sc = make("UIScale", { Scale = 0.94, Parent = panel }) :: UIScale
		animate(0.18, 0, "outQuad", function(e)
			sc.Scale = 0.94 + 0.06 * e
		end, function()
			sc:Destroy()
		end)
		return
	elseif a.intro ~= "cascade" then
		return
	end
	local header: Frame = s.header
	local hHome = header.Position
	animate(0.35, 0, "outBack", function(e)
		header.Position = hHome + UDim2.fromOffset(0, math.floor((1 - e) * -40))
	end)
	if s.lay.featuredMode == "side" then
		local f: Frame = s.featured
		local fHome = f.Position
		animate(0.4, 0.1, "outBack", function(e)
			f.Position = fHome + UDim2.fromOffset(math.floor((1 - e) * 80), 0)
		end)
	end
	local focus = s.sel and s.sel.tier or 1
	local reach = math.ceil(s.lay.visibleCols / 2) + 2
	for i, cu in s.cols do
		local d = math.abs(i - focus)
		if d <= reach then
			local frame: Frame = cu.frame
			local sc: UIScale = cu.scale
			local x = cu.homeX
			animate(0.42, d * a.stagger + 0.05, "outBack", function(e)
				sc.Scale = 0.6 + 0.4 * e
				frame.Position = UDim2.fromOffset(x, math.floor((1 - e) * 70))
			end)
		end
	end
end

local function buildPanel(lay: PassModel.PassLayout)
	local s = S
	if s.panel then
		s.panel:Destroy()
	end
	if s.showroom then
		pcall(s.showroom.destroy)
		s.showroom = nil
	end
	table.clear(s.tasks)
	s.lay = lay
	s.bigIcon = nil
	local panel = Theme.card({
		Name = "PassPanel",
		Position = UDim2.fromOffset(lay.panel.x, lay.panel.y),
		Size = UDim2.fromOffset(lay.panel.w, lay.panel.h),
		BackgroundColor3 = PANEL_BG,
		BackgroundTransparency = 0.02,
		Active = true,
		Parent = s.screen.root,
	})
	s.panel = panel
	buildHeader(panel)
	buildTrack(panel)
	buildFeatured(panel)
	s.fxLayer = make("Frame", {
		Name = "Fx",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 50,
		Parent = panel,
	})
	if not s.sel then
		s.sel = { tier = PassModel.focusTier(s.model), track = "free" }
	end
	refreshAll()
	scrollTo(s.sel.tier, true)
	s.barShown = if s.anim.smoothBar then 0 else s.model.frac
	intro()
end

----------------------------------------------------------------------
-- Driver
----------------------------------------------------------------------

local function step(dt: number)
	local s = S
	if not s or not s.panel then
		return
	end
	s.t += dt
	local t = s.t
	local tasks = s.tasks
	for i = #tasks, 1, -1 do
		local ok, keep = pcall(tasks[i], t, dt)
		if not ok or not keep then
			table.remove(tasks, i)
		end
	end
	local a: PassModel.Anim = s.anim
	local L: PassModel.PassLayout = s.lay
	-- XP bar
	local target = s.barTarget or 0
	if s.barWrap then
		s.barShown = PassModel.approach(s.barShown, 1, dt, 9)
		if s.barShown >= 0.995 then
			s.barShown = 0
			s.barWrap = false
		end
	elseif a.smoothBar then
		s.barShown = PassModel.approach(s.barShown, target, dt, 6)
	else
		s.barShown = target
	end
	s.barFill.Size = UDim2.fromScale(math.clamp(s.barShown, 0, 1), 1)
	-- scrolling: eased target, else snap a few frames after the player stops
	local scroller: ScrollingFrame = s.scroller
	local drag = s.drag
	if drag then
		local mp = UserInputService:GetMouseLocation()
		local dx = (mp.X - drag.x) / Theme.scaleOf(scroller)
		if math.abs(dx) > 8 then
			drag.moved = true
		end
		if drag.moved then
			local maxX = math.max(0, scroller.CanvasSize.X.Offset - L.scroller.w)
			local x = math.clamp(drag.canvas - dx, 0, maxX)
			s.lastSetX = x
			scroller.CanvasPosition = Vector2.new(x, 0)
			s.userScrollAt = t
		end
	elseif s.scrollTarget then
		local x = PassModel.approach(scroller.CanvasPosition.X, s.scrollTarget, dt, 12)
		if math.abs(x - s.scrollTarget) < 0.5 then
			x = s.scrollTarget
			s.scrollTarget = nil
		end
		s.lastSetX = x
		scroller.CanvasPosition = Vector2.new(x, 0)
	elseif s.userScrollAt and t - s.userScrollAt > 0.22 and s.touches <= 0 then
		s.userScrollAt = nil
		local i = PassModel.nearestIndex(
			scroller.CanvasPosition.X,
			s.model.maxTier,
			L.cardW,
			L.colGap,
			L.scroller.w
		)
		scrollTo(i)
	end
	-- claimable glow / bob and the premium shine, on visible columns only
	if a.bob or a.glowPulse or a.shine then
		local first = PassModel.nearestIndex(
			scroller.CanvasPosition.X,
			s.model.maxTier,
			L.cardW,
			L.colGap,
			L.scroller.w
		)
		local half = math.ceil(L.visibleCols / 2) + 1
		for i = math.max(1, first - half), math.min(s.model.maxTier, first + half) do
			local cu = s.cols[i]
			if cu then
				for _, card in { cu.free, cu.premium } do
					if card.glow.Visible then
						if a.bob then
							card.content.Position = UDim2.fromOffset(0, PassModel.bob(t, card.phase))
						end
						if a.glowPulse then
							card.glowStroke.Transparency = 0.15 + 0.6 * PassModel.pulse(t, card.phase)
						end
					end
					local g = card.shineGrad
					if g and card.shine and card.shine.Visible then
						g.Offset = Vector2.new(PassModel.shine(t, i), 0)
					end
				end
			end
		end
	end
	if a.previewMotion then
		if s.rays and s.rays.Visible then
			s.rays.Rotation = (t * 25) % 360
		end
		local big = s.bigIcon
		if big then
			big.Position = UDim2.new(0.5, 0, 0.5, PassModel.bob(t, 0) * 1.5)
		end
	end
	-- "Claim all", paced under the server's rate limit
	local q = s.queue
	if q and t >= (s.queueNext or 0) then
		local nextClaim = table.remove(q, 1)
		if nextClaim then
			claim(nextClaim.tier, nextClaim.track, s.queueSent)
			if a.smoothScroll then
				scrollTo(nextClaim.tier)
			end
			-- already sent in one request: only the animation is paced
			s.queueNext = t + (if s.queueSent then (if a.pop then 0.08 else 0) else CLAIM_SPACING)
		end
		if #q == 0 then
			s.queue = nil
			refreshHeader()
		end
	end
	-- unanswered claims revert after PENDING_SECONDS
	if t >= (s.pendingCheckAt or 0) then
		s.pendingCheckAt = t + 0.5
		for _, untilT in s.pending do
			if t >= untilT then
				s.model = computeModel()
				refreshAll()
				break
			end
		end
	end
end

----------------------------------------------------------------------
-- Keyboard / gamepad
----------------------------------------------------------------------

local MOVE_KEYS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.Left] = "left",
	[Enum.KeyCode.A] = "left",
	[Enum.KeyCode.DPadLeft] = "left",
	[Enum.KeyCode.Right] = "right",
	[Enum.KeyCode.D] = "right",
	[Enum.KeyCode.DPadRight] = "right",
	[Enum.KeyCode.Up] = "up",
	[Enum.KeyCode.W] = "up",
	[Enum.KeyCode.DPadUp] = "up",
	[Enum.KeyCode.Down] = "down",
	[Enum.KeyCode.S] = "down",
	[Enum.KeyCode.DPadDown] = "down",
	[Enum.KeyCode.Q] = "pageLeft",
	[Enum.KeyCode.ButtonL1] = "pageLeft",
	[Enum.KeyCode.E] = "pageRight",
	[Enum.KeyCode.ButtonR1] = "pageRight",
}

local function moveSel(dir: string)
	local s = S
	if not s or not s.sel then
		return
	end
	local tier, track = PassModel.move(s.sel.tier, s.sel.track, dir, s.model.maxTier)
	if tier ~= s.sel.tier or track ~= s.sel.track then
		sound("click")
		selectSlot(tier, track, true)
	end
end

local function onAction(
	_name: string,
	state: Enum.UserInputState,
	input: InputObject
): Enum.ContextActionResult
	local s = S
	if not s then
		return Enum.ContextActionResult.Pass
	end
	local key = input.KeyCode
	if key == Enum.KeyCode.Thumbstick1 then
		local x = input.Position.X
		if math.abs(x) > 0.6 and s.t - (s.stickAt or -1) > 0.22 then
			s.stickAt = s.t
			moveSel(if x > 0 then "right" else "left")
		end
		return Enum.ContextActionResult.Sink
	end
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end
	local dir = MOVE_KEYS[key]
	if dir then
		moveSel(dir)
	elseif key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter or key == Enum.KeyCode.ButtonA then
		local sel = s.sel
		local slot = sel and slotOf(sel.tier, sel.track)
		if slot and slot.state == "claimable" then
			claim(slot.tier, slot.track)
		else
			setDrawer(true)
		end
	elseif key == Enum.KeyCode.C or key == Enum.KeyCode.ButtonX then
		claimAll()
	elseif key == Enum.KeyCode.Backspace or key == Enum.KeyCode.ButtonB then
		if s.lay.featuredMode == "drawer" and s.featured.Visible then
			setDrawer(false)
		else
			PassUI.close()
		end
	end
	return Enum.ContextActionResult.Sink
end

local function bindKeys()
	local keys: { Enum.KeyCode } = {
		Enum.KeyCode.Thumbstick1,
		Enum.KeyCode.Return,
		Enum.KeyCode.KeypadEnter,
		Enum.KeyCode.ButtonA,
		Enum.KeyCode.C,
		Enum.KeyCode.ButtonX,
		Enum.KeyCode.Backspace,
		Enum.KeyCode.ButtonB,
	}
	for k in MOVE_KEYS do
		table.insert(keys, k)
	end
	ContextActionService:BindActionAtPriority(
		ACTION,
		onAction,
		false,
		Enum.ContextActionPriority.High.Value + 50,
		table.unpack(keys)
	)
end

----------------------------------------------------------------------
-- Live updates
----------------------------------------------------------------------

local function onPass()
	local s = S
	if not s then
		return
	end
	local old: PassModel.Model = s.model
	local m = computeModel()
	if m.maxTier ~= old.maxTier then
		s.model = m
		s.sel = nil
		s.lay = nil
		buildPanel(PassModel.layout(s.screen.rootSize().X, s.screen.rootSize().Y, Theme.TOUCH, Theme.dense()))
		return
	end
	s.model = m
	if old.known and m.tier > old.tier then
		if s.anim.smoothBar then
			s.barWrap = true
		end
		tierUp(m.tier)
	end
	refreshAll()
end

local function onGfx()
	local s = S
	if not s then
		return
	end
	s.anim = PassModel.anim(State.gfx().fx)
	for _, cu in s.cols do
		for _, card in { cu.free, cu.premium } do
			card.content.Position = UDim2.new()
			card.glowStroke.Transparency = 0.25
		end
	end
	if s.rays then
		s.rays.Rotation = 0
	end
	refreshAll()
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function PassUI.isOpen(): boolean
	return S ~= nil
end

function PassUI.open()
	if S or not State.inLobby() then
		return
	end
	local screen = Theme.screen("TrunkfallPass", 38)
	local s: any = {
		screen = screen,
		t = 0,
		tasks = {},
		pending = {},
		conns = {},
		unsubs = {},
		touches = 0,
		cols = {},
		anim = PassModel.anim(State.gfx().fx),
		barShown = 0,
		barTarget = 0,
	}
	S = s
	s.model = computeModel()
	State.setBusy("pass", true)
	-- dim backdrop; a click outside the panel closes
	make("TextButton", {
		Name = "Backdrop",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.shadow,
		BackgroundTransparency = 0.35,
		AutoButtonColor = false,
		Text = "",
		Selectable = false,
		Parent = screen.root,
	}).Activated:Connect(function()
		PassUI.close()
	end)
	table.insert(
		s.unsubs,
		screen.onResize(function(size: Vector2)
			local lay = PassModel.layout(size.X, size.Y, Theme.TOUCH, Theme.dense())
			local cur = s.lay
			if
				cur
				and cur.panel.w == lay.panel.w
				and cur.panel.h == lay.panel.h
				and cur.featuredMode == lay.featuredMode
				and cur.touch == lay.touch
			then
				return
			end
			buildPanel(lay)
		end)
	)
	table.insert(s.conns, RunService.RenderStepped:Connect(step))
	table.insert(
		s.conns,
		UserInputService.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.Touch then
				s.touches += 1
			end
		end)
	)
	table.insert(
		s.conns,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.Touch then
				s.touches = math.max(0, s.touches - 1)
			elseif input.UserInputType == Enum.UserInputType.MouseButton1 and s.drag then
				if s.drag.moved then
					s.dragEndAt = s.t
				end
				s.drag = nil
			end
		end)
	)
	table.insert(s.unsubs, State.subscribe("pass", onPass))
	table.insert(
		s.unsubs,
		State.subscribe("profile", function()
			refreshHeader()
		end)
	)
	table.insert(s.unsubs, State.subscribe("gfx", onGfx))
	table.insert(
		s.unsubs,
		State.subscribe("run", function()
			if not State.inLobby() then
				PassUI.close()
			end
		end)
	)
	bindKeys()
	sound("click")
end

function PassUI.close()
	local s = S
	if not s then
		return
	end
	S = nil
	pcall(function()
		ContextActionService:UnbindAction(ACTION)
	end)
	for _, c in s.conns do
		c:Disconnect()
	end
	for _, u in s.unsubs do
		pcall(u)
	end
	table.clear(s.tasks)
	if s.showroom then
		pcall(s.showroom.destroy)
	end
	s.screen.destroy()
	State.setBusy("pass", false)
end

function PassUI.toggle()
	if S then
		PassUI.close()
	else
		PassUI.open()
	end
end

-- Nothing to build up front: the screen exists only while open.
function PassUI.init() end

function PassUI.destroy()
	PassUI.close()
end

return PassUI
