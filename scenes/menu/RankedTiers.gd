extends RefCounted

# The account server owns score-to-tier conversion. This file owns presentation only.
const NAMES_ZH := ["初誓", "森卫", "星铸", "天曜", "荣耀之冠"]
const NAMES_EN := ["Oathbound", "Verdant Guard", "Starforged", "Celestial", "Crown of Glory"]
const BADGES := [
	preload("res://assets/ui/ranked/rank_oath.png"),
	preload("res://assets/ui/ranked/rank_verdant.png"),
	preload("res://assets/ui/ranked/rank_starforge.png"),
	preload("res://assets/ui/ranked/rank_celestial.png"),
	preload("res://assets/ui/ranked/reward_crest.png"),
]


static func name_of(tier: int, english: bool = false) -> String:
	var index := clampi(tier, 0, BADGES.size() - 1)
	return NAMES_EN[index] if english else NAMES_ZH[index]


static func badge_of(tier: int) -> Texture2D:
	return BADGES[clampi(tier, 0, BADGES.size() - 1)]
