extends RefCounted
class_name VFXQualityBudget

enum Tier { LOW, MEDIUM, HIGH }

static var tier := Tier.MEDIUM

static func allow_dynamic_light() -> bool:
	return tier != Tier.LOW

static func flipbook_frame_limit(base_count: int) -> int:
	return mini(base_count, 12 if tier == Tier.LOW else (24 if tier == Tier.MEDIUM else 48))

static func distortion_layers(base_count: int) -> int:
	return mini(base_count, 1 if tier == Tier.LOW else (2 if tier == Tier.MEDIUM else 3))

static func max_simultaneous_effects() -> int:
	return 18 if tier == Tier.LOW else (30 if tier == Tier.MEDIUM else 48)

# 群体技能的特效目标数上限。全场 8 个目标同时开花是最容易掉帧的场景，
# 而且视觉上前几个目标就已经把"这是个群体技"讲清楚了。
# 只影响表现，伤害/命中判定仍然作用于全部目标。
static func max_aoe_targets(base_count: int) -> int:
	match tier:
		Tier.LOW:
			return mini(base_count, 4)
		Tier.HIGH:
			return base_count
		_:
			return mini(base_count, 6)

static func max_particles_per_effect() -> int:
	return 48 if tier == Tier.LOW else (96 if tier == Tier.MEDIUM else 160)

# 三档系数 0.45 / 0.75 / 1.0。
#
# 原本是 0.52 / 1.0 / 1.25 —— MEDIUM 等于"原样不减"、HIGH 反而加量，
# 于是中档形同虚设：实测这台 8 核 Redmi A5 被判成 MEDIUM，37 个调用点全部空转。
# 现在以 HIGH 为基准（美术给的原始数量），中低档往下减。
static func particle_count(base_count: int) -> int:
	match tier:
		Tier.LOW:
			return maxi(4, int(round(base_count * 0.45)))
		Tier.HIGH:
			return maxi(4, base_count)
		_:
			return maxi(4, int(round(base_count * 0.75)))

static func auxiliary_layers(base_count: int) -> int:
	match tier:
		Tier.LOW:
			return mini(base_count, 1)
		Tier.HIGH:
			return base_count
		_:
			return mini(base_count, 2)

static func shader_octaves(base_count: int) -> int:
	match tier:
		Tier.LOW:
			return mini(base_count, 3)
		Tier.HIGH:
			return base_count
		_:
			return mini(base_count, 5)
