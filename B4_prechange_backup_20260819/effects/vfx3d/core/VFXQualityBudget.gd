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


# --- D5: per-priority presentation budget -------------------------------------
#
# Everything above caps a single effect (particles, layers, octaves). These cap the
# *scheduler*: how many cues of each visibility priority may start in one replay
# tick and how many may be alive at once.
#
# The one rule that must never bend (checklist 7 D5, "Boss/死亡/控制 cue 不消失"):
# an overflow may only degrade. A critical cue is never merged, never shortened
# away and never dropped; important cues lose their recovery tail first; ambient
# cues may be merged inside a short window on the same target.

const PRIORITY_CRITICAL := "critical"
const PRIORITY_IMPORTANT := "important"
const PRIORITY_AMBIENT := "ambient"

# -1 means "no cap". Critical is uncapped on every tier by design.
static func max_cues_per_tick(priority: String) -> int:
	if priority == PRIORITY_CRITICAL:
		return -1
	if priority == PRIORITY_IMPORTANT:
		return 4 if tier == Tier.LOW else (8 if tier == Tier.MEDIUM else 14)
	return 3 if tier == Tier.LOW else (6 if tier == Tier.MEDIUM else 10)


static func max_live_cues(priority: String) -> int:
	if priority == PRIORITY_CRITICAL:
		return -1
	if priority == PRIORITY_IMPORTANT:
		return 6 if tier == Tier.LOW else (12 if tier == Tier.MEDIUM else 20)
	return 4 if tier == Tier.LOW else (8 if tier == Tier.MEDIUM else 14)


# Two ambient cues of the same type on the same target inside this window are one
# cue as far as the player is concerned (checklist 4.4).
static func ambient_merge_window_ms() -> int:
	return 160 if tier == Tier.LOW else (100 if tier == Tier.MEDIUM else 60)


static func may_merge(priority: String) -> bool:
	return priority == PRIORITY_AMBIENT


# How much of a cue's recovery tail survives when its priority is over budget.
# Critical keeps all of it; the tail is the first thing important cues give up.
static func recovery_scale_when_over_budget(priority: String) -> float:
	if priority == PRIORITY_CRITICAL:
		return 1.0
	if priority == PRIORITY_IMPORTANT:
		return 0.35
	return 0.0
