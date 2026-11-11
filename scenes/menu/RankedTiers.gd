extends RefCounted

# The account server owns score-to-tier conversion. This file owns presentation only.
const NAMES_ZH := ["初誓", "森卫", "星铸", "天曜", "荣耀之冠"]
const NAMES_EN := ["Oathbound", "Verdant Guard", "Starforged", "Celestial", "Crown of Glory"]
# 11.11 段位图换成羊皮纸风徽章（萌芽 / 叶盾 / 星盾 / 翼日 / 桂冠）
const BADGES := [
	preload("res://assets/ui/ranked/tier_0_oath.png"),
	preload("res://assets/ui/ranked/tier_1_verdant.png"),
	preload("res://assets/ui/ranked/tier_2_starforge.png"),
	preload("res://assets/ui/ranked/tier_3_celestial.png"),
	preload("res://assets/ui/ranked/tier_4_crown.png"),
]


static func name_of(tier: int, english: bool = false) -> String:
	var index := clampi(tier, 0, BADGES.size() - 1)
	return NAMES_EN[index] if english else NAMES_ZH[index]


static func badge_of(tier: int) -> Texture2D:
	return BADGES[clampi(tier, 0, BADGES.size() - 1)]
