--!strict
-- Account level rewards (v4 plan, QC-C M10): one reward every 5 account levels up
-- to level 100, claimed with Net.C2S.ClaimAccountReward(level) (Data/AccountRewards).
-- Cosmetic, title or currency only. The level cosmetics of Config/Cosmetics
-- (source "level", levels 5-30) are still granted automatically on level-up; the
-- rewards here come on top.

export type Reward = { cheese: number?, goldenCheese: number?, cosmetic: string?, title: string? }

local A = {}

A.STEP = 5
A.MAX_LEVEL = 100

A.REWARDS = {
	[5] = { cheese = 300 },
	[10] = { goldenCheese = 25 },
	[15] = { cheese = 500 },
	[20] = { goldenCheese = 25 },
	[25] = { cheese = 750 },
	[30] = { goldenCheese = 50 },
	[35] = { cheese = 1000 },
	[40] = { title = "title_veteran", goldenCheese = 25 },
	[45] = { cheese = 1000 },
	[50] = { cosmetic = "trail_half_century", goldenCheese = 50 },
	[55] = { cheese = 1500 },
	[60] = { title = "title_elder", goldenCheese = 25 },
	[65] = { cheese = 1500 },
	[70] = { goldenCheese = 50 },
	[75] = { cosmetic = "hat_laurel" },
	[80] = { title = "title_legend", goldenCheese = 25 },
	[85] = { cheese = 2000 },
	[90] = { goldenCheese = 50 },
	[95] = { cheese = 2000 },
	[100] = { cosmetic = "trail_centennial", title = "title_centennial", goldenCheese = 100 },
} :: { [number]: Reward }

function A.get(level: any): Reward?
	if type(level) ~= "number" or level ~= level then
		return nil
	end
	return A.REWARDS[level]
end

-- Every reward level in ascending order.
function A.levels(): { number }
	local out = {}
	for level in A.REWARDS do
		table.insert(out, level)
	end
	table.sort(out)
	return out
end

return A
