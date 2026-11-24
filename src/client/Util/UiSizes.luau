--!strict
-- v3 compact UI sizes (owner feedback: "all of the UI and popups need to be
-- smaller"). Pure data and maths (no Roblox APIs), so specs can check every
-- popup's screen coverage and that each text line fits its box after the
-- Layout text floor (tests/specs/ClientLayout.spec.luau).
--
-- Every function takes `dense` (Layout.dense: PC / laptop) and, where buttons
-- are involved, `touch` (Theme.TOUCH) and `slim` (Theme.SLIM) in design px.
-- Dense sizes are the compact v3 ones. Phones keep roomier boxes because the
-- text floor renders all text <= 24 design px at ~25 design px there.
--
-- `lines` lists { name, h, text } text boxes: a box `h` design px tall holding
-- one line of `text` design px text (multi-line boxes list h / lines).

local UiSizes = {}

export type Line = { name: string, h: number, text: number }

-- Toast stack (top-centre, under the HUD header).
function UiSizes.toast(dense: boolean)
	if dense then
		return {
			w = 340,
			text = 15,
			padX = 10,
			padY = 5,
			gap = 4,
			maxVisible = 3,
			seconds = 2.4,
			lineH = 18,
		}
	end
	return {
		w = 420,
		text = 18,
		padX = 12,
		padY = 6,
		gap = 5,
		maxVisible = 3,
		seconds = 2.6,
		lineH = 26,
	}
end

-- In-run HUD.
function UiSizes.hud(dense: boolean, touch: number)
	if dense then
		local hud = {
			margin = 12,
			-- own status card (top-left)
			statusW = 250,
			statusH = 82, -- live fix (iteration 6): room for a readable XP bar
			badge = 46,
			levelText = 24,
			showLevelCaption = false,
			barX = 60,
			barW = 180,
			classY = 4,
			classH = 16,
			classText = 13,
			hpY = 22,
			hpH = 18,
			hpText = 13,
			-- live fix (iteration 6): the 7 px caption-less XP bar was unreadable;
			-- 15 px with its "XP n / m" caption (>= the v2 / phone 14 px bar)
			xpY = 43,
			xpH = 15,
			xpText = 12,
			showXpText = true,
			windY = 62,
			windH = 16,
			windText = 13,
			-- squad panel (under the status card)
			squadW = 210,
			squadPad = 6,
			squadGap = 4,
			squadTitleH = 16,
			squadTitleText = 13,
			mateH = 40,
			mateIcon = 26,
			mateNameH = 16,
			mateNameText = 13,
			mateSubW = 64,
			mateSubText = 12,
			mateBarY = 21,
			mateBarH = 15,
			mateBarText = 12,
			-- header (top-centre): thin scoreboard bar + run rows
			headerY = 6,
			headerW = 540,
			headerGap = 3,
			tileW = 130,
			tileH = 36,
			tileGap = 4,
			tileBand = 3,
			tileLineH = 15,
			tileText = 12,
			tileIcon = 12,
			tilePip = 6,
			titleH = 22,
			titleText = 19,
			phaseH = 20,
			phaseText = 16,
			cheeseH = 24,
			cheeseIcon = 18,
			cheeseText = 16,
			chipsH = 26,
			bossW = 440,
			bossH = 42,
			bossNameH = 18,
			bossNameText = 16,
			bossBarY = 22,
			bossBarH = 16,
			bossBarText = 13,
			bannerW = 480,
			bannerH = 28,
			bannerText = 22,
			bannerSeconds = 2.5,
			-- top-right
			minimap = 120,
			killRows = 4,
			killW = 230,
			killH = 22,
			killGap = 3,
			killText = 13,
			killNameMax = 92,
			killIcon = 15,
			buffW = 190,
			buffH = 18,
			buffText = 14,
			-- bottom-centre
			bottomY = 10,
			slot = 52,
			slotTagH = 15,
			slotTagText = 11,
			ability = 60,
			abilityIcon = 30,
			abilityText = 26,
			abilityHintH = 16,
			abilityHintText = 13,
			rowGap = 8,
			dockPad = 6, -- live fix: the backing dock's padding around the bottom tiles
			poiRing = 48,
			poiText = 14,
			poiNameH = 18,
			poiNameText = 14,
			-- downed overlay
			downW = 340,
			downTitleH = 28,
			downTitleText = 24,
			downSubY = 34,
			downSubH = 20,
			downSubText = 14,
			downButtonW = 240,
			downButtonText = 18,
			downShortH = 62,
		}
		hud.rowH = math.max(hud.ability, hud.slot)
		hud.downFullH = 58 + touch + 10
		return hud
	end
	local hud = {
		margin = 14,
		statusW = 330,
		statusH = 106, -- live fix (iteration 6): a taller XP bar
		badge = 62,
		levelText = 30,
		showLevelCaption = true,
		barX = 84,
		barW = 236,
		classY = 6,
		classH = 18,
		classText = 14,
		hpY = 26,
		hpH = 26,
		hpText = 18,
		xpY = 55,
		xpH = 24, -- live fix (iteration 6): was 14 (the phone caption renders at 12 px = 24 design px)
		xpText = 13,
		showXpText = true,
		windY = 82,
		windH = 20,
		windText = 14,
		squadW = 270,
		squadPad = 8,
		squadGap = 6,
		squadTitleH = 18,
		squadTitleText = 14,
		mateH = 50,
		mateIcon = 32,
		mateNameH = 18,
		mateNameText = 15,
		mateSubW = 70,
		mateSubText = 12,
		mateBarY = 26,
		mateBarH = 16,
		mateBarText = 12,
		headerY = 8,
		headerW = 560,
		headerGap = 4,
		tileW = 128,
		tileH = 56,
		tileGap = 6,
		tileBand = 6,
		tileLineH = 18,
		tileText = 14,
		tileIcon = 16,
		tilePip = 8,
		titleH = 28,
		titleText = 24,
		phaseH = 24,
		phaseText = 20,
		cheeseH = 32,
		cheeseIcon = 24,
		cheeseText = 20,
		chipsH = 36,
		bossW = 520,
		bossH = 58,
		bossNameH = 26,
		bossNameText = 24,
		bossBarY = 30,
		bossBarH = 24,
		bossBarText = 18,
		bannerW = 600,
		bannerH = 32,
		bannerText = 26,
		bannerSeconds = 3,
		-- v4 phone diet (review B S2-6): bigger minimap, 2 kill-feed rows
		minimap = 150,
		killRows = 2,
		killW = 280,
		killH = 28,
		killGap = 4,
		killText = 15,
		killNameMax = 116,
		killIcon = 18,
		buffW = 220,
		buffH = 24,
		buffText = 18,
		bottomY = 14,
		slot = math.max(64, math.floor(touch * 0.92)),
		slotTagH = 14,
		slotTagText = 12,
		ability = 96,
		abilityIcon = 44,
		abilityText = 34,
		abilityHintH = 20,
		abilityHintText = 14,
		rowGap = 10,
		dockPad = 8,
		poiRing = 64,
		poiText = 18,
		poiNameH = 22,
		poiNameText = 16,
		downW = 420,
		downTitleH = 36,
		downTitleText = 30,
		downSubY = 44,
		downSubH = 26,
		downSubText = 17,
		downButtonW = 300,
		downButtonText = 22,
		downShortH = 90,
	}
	hud.rowH = math.max(96, touch)
	hud.downFullH = 82 + touch + 12
	return hud
end

-- Live fix (iteration 6): the dock behind the in-run bottom row. Tiles, left
-- to right: `gear` gear slots (Z.slot square), then `abilities` ability tiles
-- (slot 1 Z.ability, slots 2-3 82% of it), Z.rowGap apart, Z.dockPad inside
-- the dock, bottom-aligned. Returns the dock size and every tile's box in dock
-- px ({x, y, w, h}), so HudUI sizes the dock from it and the specs check that
-- every tile sits on it.
export type DockTile = { x: number, y: number, w: number, h: number, kind: string }
function UiSizes.bottomDock(
	Z: any,
	gear: number,
	abilities: number
): { w: number, h: number, tiles: { DockTile } }
	local pad, gap = Z.dockPad or 6, Z.rowGap
	local list: { DockTile } = {}
	for _ = 1, gear do
		table.insert(list, { x = 0, y = 0, w = Z.slot, h = Z.slot, kind = "gear" })
	end
	for i = 1, abilities do
		local size = if i == 1 then Z.ability else math.floor(Z.ability * 0.82)
		table.insert(list, { x = 0, y = 0, w = size, h = size, kind = "ability" })
	end
	local inner, tallest = 0, 0
	for i, t in list do
		inner += t.w + (if i > 1 then gap else 0)
		tallest = math.max(tallest, t.h)
	end
	local h = math.max(Z.rowH, tallest) + 2 * pad
	local w = inner + 2 * pad
	local x = pad
	for _, t in list do
		t.x = x
		t.y = h - pad - t.h
		x += t.w + gap
	end
	return { w = w, h = h, tiles = list }
end

-- Max height of the HUD header column (every row shown), for the toast stack.
function UiSizes.headerHeight(dense: boolean, touch: number): number
	local h = UiSizes.hud(dense, touch)
	return h.tileH + h.titleH + h.phaseH + h.cheeseH + h.chipsH + h.bossH + h.bannerH + 6 * h.headerGap
end

-- Top of the free area under the HUD header (design px from the root top).
function UiSizes.underHeader(dense: boolean, touch: number): number
	local h = UiSizes.hud(dense, touch)
	return h.headerY + UiSizes.headerHeight(dense, touch) + 6
end

-- PC (dense): slim bars sit top-centre under the header in fixed slots
-- (1 = Extract, 2 = vote / route chooser) and open downward in place, so a
-- hover never moves them away from the pointer. Phones put them at the bottom.
function UiSizes.barSlotY(dense: boolean, touch: number, slim: number, slot: number): number
	return UiSizes.underHeader(dense, touch) + (slot - 1) * (slim + 8 + 6)
end

-- Toast stack top: under the header, below the two bar slots on PC.
function UiSizes.toastTop(dense: boolean, touch: number, slim: number?): number
	if dense then
		return UiSizes.barSlotY(dense, touch, slim or 36, 3)
	end
	return UiSizes.underHeader(dense, touch)
end

-- Gear swap prompt.
function UiSizes.swap(dense: boolean, touch: number)
	if dense then
		local s = {
			w = 380,
			padX = 10,
			padY = 8,
			titleH = 22,
			titleText = 17,
			barY = 26,
			barH = 6,
			cardY = 38,
			cardH = 68,
			icon = 38,
			capY = 2,
			capH = 16,
			capText = 12,
			nameY = 18,
			nameH = 18,
			nameText = 15,
			descY = 36,
			descH = 30,
			descText = 12,
			buttonText = 16,
		}
		s.h = s.cardY + s.cardH + 8 + touch + 2 * s.padY
		return s
	end
	local s = {
		w = 470,
		padX = 12,
		padY = 10,
		titleH = 26,
		titleText = 22,
		barY = 30,
		barH = 8,
		cardY = 44,
		cardH = 72,
		icon = 48,
		capY = 4,
		capH = 14,
		capText = 12,
		nameY = 18,
		nameH = 20,
		nameText = 17,
		descY = 38,
		descH = 32,
		descText = 12,
		buttonText = 22,
	}
	s.h = 44 + 78 + touch + 30
	return s
end

-- Extraction window: compact cards + the slim bar it minimises to.
function UiSizes.extract(dense: boolean, _touch: number, slim: number)
	local e
	if dense then
		e = {
			cardW = 200,
			cardH = 150,
			gap = 8,
			pad = 8,
			bandH = 30,
			bandIcon = 20,
			bandText = 17,
			rewardY = 34,
			rewardH = 34,
			rewardText = 14,
			riskY = 70,
			riskH = 16,
			riskText = 12,
			riskLineY = 88,
			riskLineH = 18,
			riskLineText = 13,
			footerH = 28,
			votesText = 15,
			pickText = 13,
			headH = math.max(40, slim + 4),
			headIcon = 22,
			titleText = 18,
			timerText = 18,
			timeBarH = 5,
			barW = 360,
			barText = 15,
			openW = 84,
		}
	else
		e = {
			cardW = 240,
			cardH = 220,
			gap = 10,
			pad = 10,
			bandH = 44,
			bandIcon = 30,
			bandText = 24,
			rewardY = 48,
			rewardH = 54,
			rewardText = 17,
			riskY = 104,
			riskH = 26,
			riskText = 12,
			riskLineY = 132,
			riskLineH = 28,
			riskLineText = 14,
			footerH = 44,
			votesText = 20,
			pickText = 17,
			headH = 52,
			headIcon = 30,
			titleText = 26,
			timerText = 26,
			timeBarH = 8,
			barW = 460,
			barText = 18,
			openW = 130,
		}
	end
	e.slim = slim
	e.tabInside = dense -- phones: the ▾ tab hangs over the top edge (touch-sized)
	e.cardsY = e.headH + e.timeBarH + 6
	e.panelW = 3 * e.cardW + 4 * e.gap
	e.panelH = e.cardsY + e.cardH + e.pad
	e.barH = slim + (if dense then 8 else 12)
	return e
end

-- Route / bank / cycle votes: compact cards + slim bar.
function UiSizes.vote(dense: boolean, _touch: number, slim: number)
	local v
	if dense then
		v = {
			routeW = 200,
			choiceW = 270,
			cardH = 168,
			gap = 8,
			pad = 8,
			bandH = 28,
			bandText = 16,
			lineY = 32,
			mapH = 18,
			mapText = 15,
			lineH = 17,
			lineText = 13,
			rewardH = 18,
			rewardText = 14,
			extraH = 16,
			extraText = 12,
			bodyH = 72,
			bodyText = 13,
			noteH = 18,
			noteText = 14,
			footerH = 24,
			tallyText = 15,
			pickText = 13,
			headH = math.max(40, slim + 4),
			titleText = 20,
			timerText = 18,
			hintH = 20,
			hintText = 13,
			barW = 380,
			barText = 15,
			openW = 84,
			chooserW = 400,
			chooserH = 46,
			chooserIcon = 24,
			chooserText = 16,
			chooserSubText = 12,
		}
	else
		v = {
			routeW = 230,
			choiceW = 330,
			cardH = 246,
			gap = 10,
			pad = 10,
			bandH = 40,
			bandText = 24,
			lineY = 44,
			mapH = 26,
			mapText = 20,
			lineH = 26,
			lineText = 17,
			rewardH = 26,
			rewardText = 19,
			extraH = 26,
			extraText = 15,
			bodyH = 126,
			bodyText = 17,
			noteH = 26,
			noteText = 18,
			footerH = 40,
			tallyText = 22,
			pickText = 18,
			headH = 52,
			titleText = 26,
			timerText = 26,
			hintH = 28,
			hintText = 18,
			barW = 480,
			barText = 18,
			openW = 130,
			chooserW = 520,
			chooserH = 64,
			chooserIcon = 34,
			chooserText = 22,
			chooserSubText = 14,
		}
	end
	v.slim = slim
	v.tabInside = dense
	v.cardsY = v.headH + 4
	v.panelW = math.max(3 * v.routeW + 4 * v.gap, 2 * v.choiceW + 3 * v.gap)
	v.panelH = v.cardsY + v.cardH + v.pad
	v.panelHintH = v.panelH + v.hintH
	v.barH = slim + (if dense then 8 else 12)
	return v
end

-- Level-up picker: a compact bottom strip.
function UiSizes.upgrade(dense: boolean)
	local u
	if dense then
		u = {
			cardW = 190,
			cardH = 92,
			gap = 8,
			bandH = 22,
			bandText = 13,
			nameY = 25,
			nameH = 18,
			nameText = 15,
			descY = 44,
			descH = 46,
			descText = 12,
			rerollW = 70,
			rerollText = 13,
			titleY = 4,
			titleH = 22,
			titleText = 16,
			badgeW = 84,
			badgeText = 13,
			cardsY = 30,
			stroke = 3,
		}
	else
		u = {
			cardW = 220,
			cardH = 150,
			gap = 8,
			bandH = 30,
			bandText = 17,
			nameY = 34,
			nameH = 28,
			nameText = 22,
			descY = 64,
			descH = 80,
			descText = 15,
			rerollW = 100,
			rerollText = 20,
			titleY = 4,
			titleH = 30,
			titleText = 22,
			badgeW = 110,
			badgeText = 18,
			cardsY = 38,
			stroke = 4,
		}
	end
	u.panelW = 3 * u.cardW + 3 * u.gap + u.rerollW + 2 * u.gap
	u.panelH = u.cardsY + u.cardH + u.gap
	return u
end

-- First-session hint card (a small corner card).
function UiSizes.hint(dense: boolean)
	if dense then
		return {
			w = 280,
			pad = 10,
			gap = 6,
			icon = 26,
			iconText = 22,
			text = 14,
			buttonText = 15,
			iconBox = 30,
		}
	end
	return { w = 340, pad = 12, gap = 8, icon = 34, iconText = 30, text = 18, buttonText = 20, iconBox = 40 }
end

-- v4 in-run widgets (UI/CombatHudUI): storm pill under the minimap, the
-- outside-the-Melt warning and Herd Call countdown (upper centre), the
-- kill-streak counter (mid-left), the objective arrow ring and the ping wheel.
function UiSizes.combat(dense: boolean, touch: number)
	if dense then
		return {
			stormW = 150,
			stormH = 22,
			stormText = 13,
			warnW = 380,
			warnH = 30,
			warnText = 18,
			warnY = 0.27,
			redeployW = 300,
			redeployH = 30,
			redeployText = 18,
			streakW = 170,
			streakH = 30,
			streakText = 22,
			streakY = 0.44,
			arrowR = 120,
			arrow = 30,
			arrowText = 12,
			wheelR = 92,
			wheelSlot = 74,
			wheelText = 12,
			pingButton = 0,
			vignette = 120,
			walletW = 170,
			walletH = 22,
			walletText = 13,
		}
	end
	return {
		stormW = 180,
		stormH = 26,
		stormText = 15,
		warnW = 440,
		warnH = 34,
		warnText = 20,
		warnY = 0.25,
		redeployW = 360,
		redeployH = 34,
		redeployText = 20,
		streakW = 190,
		streakH = 34,
		streakText = 24,
		streakY = 0.46,
		arrowR = 120,
		arrow = 36,
		arrowText = 14,
		wheelR = 120,
		wheelSlot = math.max(88, touch),
		wheelText = 14,
		pingButton = math.max(64, math.floor(touch * 0.9)),
		vignette = 110,
		walletW = 190,
		walletH = 28,
		walletText = 15,
	}
end

-- Rest scale for the big non-combat panels on dense screens (Theme.compact).
UiSizes.PANEL_COMPACT = 0.9

-- Scoreboard (Tab) panel.
function UiSizes.scoreboard(dense: boolean): (number, number)
	if dense then
		return 760, 470
	end
	return 700, 400
end

-- Phones: how far an open Extract / vote panel (bottom-centre) moves up to
-- sit above a visible level-up strip, capped so the panel (and its ▾ tab,
-- `tab` px above it) never leaves the top of a `rootH` tall screen.
function UiSizes.stackLift(
	dense: boolean,
	touch: number,
	rootH: number,
	panelH: number,
	upgradeShown: boolean
): number
	if dense or not upgradeShown then
		return 0
	end
	local hud = UiSizes.hud(dense, touch)
	local base = hud.rowH + hud.bottomY + 12
	local want = UiSizes.upgrade(dense).panelH + 8
	local tab = touch * 0.6
	return math.max(0, math.min(want, rootH - base - panelH - tab - 4))
end

-- Covered rectangles (design px) of every popup that can show during combat,
-- for the coverage spec. `upgrade` + `extract` may stack.
function UiSizes.combatPopups(
	dense: boolean,
	touch: number,
	slim: number
): { [string]: { w: number, h: number } }
	local e = UiSizes.extract(dense, touch, slim)
	local v = UiSizes.vote(dense, touch, slim)
	local u = UiSizes.upgrade(dense)
	local s = UiSizes.swap(dense, touch)
	local hd = UiSizes.hud(dense, touch)
	local t = UiSizes.toast(dense)
	local hi = UiSizes.hint(dense)
	local sbW, sbH = UiSizes.scoreboard(dense)
	local cb = UiSizes.combat(dense, touch)
	local f = if dense then UiSizes.PANEL_COMPACT else 1
	local toastH = t.maxVisible * (t.lineH * 2 + 2 * t.padY + t.gap) -- two-line toasts
	return {
		extractPanel = { w = e.panelW, h = e.panelH + (if e.tabInside then 0 else touch / 2) },
		extractBar = { w = e.barW, h = e.barH },
		votePanel = { w = v.panelW, h = v.panelHintH + (if v.tabInside then 0 else touch / 2) },
		voteBar = { w = v.barW, h = v.barH },
		upgradeStrip = { w = u.panelW, h = u.panelH },
		swapPrompt = { w = s.w, h = s.h },
		downed = { w = hd.downW, h = hd.downFullH },
		toasts = { w = t.w, h = toastH },
		banner = { w = hd.bannerW, h = hd.bannerH },
		hint = { w = hi.w, h = hi.iconBox * 3 + touch + 2 * hi.pad + hi.gap },
		scoreboard = { w = sbW * f, h = sbH * f },
		shopCart = { w = 420 * f, h = (96 + 3 * (math.max(96, touch + 20) + 8)) * f },
		pingWheel = { w = 2 * cb.wheelR + cb.wheelSlot, h = 2 * cb.wheelR + cb.wheelSlot },
		meltWarning = { w = cb.warnW, h = cb.warnH + cb.redeployH + 8 },
	}
end

return UiSizes
