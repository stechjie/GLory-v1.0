extends RefCounted
class_name CrimsonVFXCatalog

# 赤律族（race = "crimson"）特效的唯一查表。
#
# 普攻弹体速度既决定 VFXCrimsonAttack3D 的飞行时长，也决定
# BattleVfx.cue_ranged_flight_time() 把命中/伤害数字推迟多久 —— 两边都读这里，
# 不再像旧 _RANGED_BOLT_SPEED 那样靠手工同步两张表。
#
# 颜色沿用赤律 4（共鸣球）/ 赤律 7（红潮环）已上线的色板，
# 与模型精修的 race_hue≈356°、发光 (1.0, 0.16, 0.18) 同调。

const RACE := "crimson"

const UNIT_IDS: Array[String] = [
	"crimson", "dancer", "drumer", "hunter", "armbreaker", "Icey", "skypierce", "lattern",
]

const DARK := Color(0.12, 0.006, 0.02)
const MAIN := Color(0.74, 0.018, 0.055)
const CORE := Color(1.0, 0.28, 0.17)
const EMBER := Color(1.0, 0.47, 0.37)
const WHITE_HOT := Color(1.0, 0.77, 0.88)
# 霜印使只用这一点冷白做冰面高光；主体仍是赤律红（模型批次已把白发统一染红）。
const FROST_GLINT := Color(0.94, 0.96, 1.0)
# 霜印使技能（霜印）专用冰蓝：手上蓝光与命中目标的短暂结冰。只用于这一个技能，
# 赤律红仍是全族主色。
const ICE_EDGE := Color(0.02, 0.07, 0.18)
const ICE_TINT := Color(0.12, 0.45, 0.95)
const ICE_HOT := Color(0.62, 0.88, 1.0)
const ICE_WHITE := Color(0.94, 0.98, 1.0)
const ICE_BODY_DARK := Color(0.03, 0.10, 0.30)
const ICE_BODY_MAIN := Color(0.20, 0.52, 0.95)
const ICE_BODY_CORE := Color(0.86, 0.96, 1.0)

# 远程普攻（模拟器 range > 1 即 basic_ranged）。每个单位一个专属弹体。
const PROJECTILES := {
	"dancer": {"kind": "petal_blade", "speed": 7.0, "arc": 0.14},
	"hunter": {"kind": "blood_arrow", "speed": 11.5, "arc": 0.04},
	"Icey": {"kind": "frost_shard", "speed": 8.4, "arc": 0.08},
	"skypierce": {"kind": "javelin", "speed": 11.0, "arc": 0.16},
	"lattern": {"kind": "lantern_ember", "speed": 6.2, "arc": 0.18},
}
const DEFAULT_PROJECTILE := {"kind": "blood_arrow", "speed": 9.0, "arc": 0.06}

# 近战只给招牌武器：战鼓、巨锤。赤卫与其它玩家近战棋子同一规则，
# 只靠模型攻击动作 + 伤害数字，不画通用刀光（OgaChessVFXCatalog 头注释）。
const MELEE := {
	"drumer": "drum_shock",
	"armbreaker": "hammer_smash",
}

# 与 VFXFlipbookProjectile3D / VFXRaceBasicAttack3D 同一可读区间。
const MIN_TRAVEL := 0.24
const MAX_TRAVEL := 0.80

# 主动技（skill_ready 上升沿）与被动触发（模拟器补的 unit_skill_proc 事件 /
# 已有 impact、hit_number 事件）。全部是纯表现入口。
const ACTIVE_SKILLS: Array[String] = ["random_ally_buff", "frost_status", "aoe_silence"]
const PROC_SKILLS: Array[String] = ["block_guard", "stacking_def_break"]
# 战鼓使的鼓点分享不单独出技能特效：头顶音符徽章（CrimsonDrumBadge）已经表达层数，
# 表现落在它的招牌普攻上（每次出手从身上扩散红色音波）。保留在路由表里只为
# 防止该 skill_id 落进 Boss composer 的兜底刀光。
const ATTACK_SKILLS: Array[String] = ["team_random_stack"]
const EVENT_SKILLS: Array[String] = ["current_hp_strike", "line_pierce"]

const BASIC_EFFECTS: Array[String] = ["basic_attack_ranged_crimson", "basic_attack_melee_crimson"]


static func is_crimson_unit(unit_id: String) -> bool:
	return unit_id in UNIT_IDS


static func all_skill_effects() -> Array[String]:
	var out: Array[String] = []
	out.append_array(ACTIVE_SKILLS)
	out.append_array(PROC_SKILLS)
	out.append_array(ATTACK_SKILLS)
	out.append_array(EVENT_SKILLS)
	return out


static func projectile_for(unit_id: String) -> Dictionary:
	return (PROJECTILES.get(unit_id, DEFAULT_PROJECTILE) as Dictionary).duplicate(true)


static func melee_kind_for(unit_id: String) -> String:
	return str(MELEE.get(unit_id, ""))


static func projectile_speed(unit_id: String) -> float:
	return maxf(0.5, float(projectile_for(unit_id).get("speed", 9.0)))


# 世界坐标地面距离 -> 飞行秒数。BattleVfx.cue_ranged_flight_time() 与
# VFXCrimsonAttack3D 共用，保证伤害数字落在弹体到达的那一帧。
static func flight_time(distance: float, unit_id: String) -> float:
	return clampf(distance / projectile_speed(unit_id), MIN_TRAVEL, MAX_TRAVEL)
