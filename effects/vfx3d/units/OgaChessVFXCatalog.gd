extends RefCounted
class_name OgaChessVFXCatalog

# Formal OpenGameArt replacement catalogue for player chess pieces.
# Every ranged chess piece owns a different projectile atlas, motion profile and
# impact atlas. Only signature weapon users receive a basic-attack slash; the
# remaining melee pieces rely on their authored model attack and damage readout
# so a crowded board does not become a wall of identical crescents.

const PLAYER_CHESS_UNITS: Array[String] = [
	"god_priest", "god_priestess", "god_guard", "god_aurora", "god_angel", "god_arbiter", "god_archangel", "god_king",
	"dark_imp", "dark_mage", "dark_fear", "dark_queen", "dark_scythe", "dark_suc", "dark_doom", "dark_dragon",
	"undead_small", "undead_poison", "undead_parasite", "undead_spike", "undead_fly", "undead_bomb", "undead_titan", "undead_mother",
	"human_militia", "human_merchant", "human_archer", "human_swordsman", "human_mage", "human_cleric", "human_death_servant", "human_king",
]

const RANGED_UNIT_ORDER: Array[String] = [
	"god_priest", "god_priestess", "god_angel", "god_archangel", "god_aurora",
	"dark_mage", "dark_queen",
	"human_archer", "human_cleric", "human_mage",
	"undead_spike", "undead_mother",
]

const MELEE_UNIT_RACE := {
	"god_arbiter":"god",
	"god_king":"god",
	"dark_scythe":"dark",
	"human_swordsman":"human",
	"human_king":"human",
}

const DISPLAY_NAMES := {
	"god_priest": "神侍",
	"god_priestess": "大祭司",
	"god_angel": "天使",
	"god_archangel": "大天使",
	"god_aurora": "极光射手",
	"dark_mage": "暗影法师",
	"dark_queen": "痛苦女王",
	"human_archer": "弓箭手",
	"human_cleric": "牧师",
	"human_mage": "法师",
	"undead_spike": "刺灵",
	"undead_mother": "母灵",
}

const PROJECTILES := {
	# 9.24 订正 #2：神侍 ↔ 极光射手普攻投射物对换。
	#
	# ⚠️ 这张表才是**玩家棋子远程普攻的真正入口**。`UnitSkillVFXComposer3D._basic_attack`
	# 一开头就 `OGA_CHESS_CATALOG.projectile_for(uid)`，命中就 `return` ——
	# 同一文件里的 `BOLT_KIND_BY_UNIT` / `PROJECTILE_TEX_BY_UNIT` 对**玩家棋子根本不生效**。
	# 上一版把对换写在那边 = 白改（用户报的「未对换完成」就是这个）。
	#
	# 用户口径：**只对换模型，飞行速度不变**。所以这里只换「模型」那一组字段
	# （path / columns / rows / frame_count / fps / size / color / emission_scale），
	# `speed` / `arc_height` / `wobble` 与 `impact_*` 全部**留在原主身上**不动。
	"god_priest": {
		"path":"res://assets/vfx/oga/projectiles/god_aurora_light_spear.png", "columns":5, "rows":1, "frame_count":5,
		"fps":18.0, "size":Vector2(0.78,0.34), "speed":5.6, "arc_height":0.10, "wobble":0.015,
		"color":Color(0.52,0.78,1.0,0.94), "emission_scale":0.60,
		"impact_path":"res://assets/vfx/oga/impacts/god_priest_hit.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":15.0, "impact_size":Vector2(0.74,0.74),
	},
	"god_priestess": {
		"path":"res://assets/vfx/oga/projectiles/god_priestess_halo_disc.png", "columns":5, "rows":1, "frame_count":5,
		"fps":11.0, "size":Vector2(0.70,0.70), "speed":5.0, "arc_height":0.18, "wobble":0.025,
		"impact_path":"res://assets/vfx/oga/impacts/god_priestess_hit.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":14.0, "impact_size":Vector2(0.78,0.78),
	},
	"god_angel": {
		"path":"res://assets/vfx/oga/projectiles/god_angel_wing.png", "columns":5, "rows":1, "frame_count":5,
		"fps":16.0, "size":Vector2(0.70,0.52), "speed":7.5, "arc_height":0.26, "wobble":0.035,
		"color":Color(1.0,0.88,0.62,0.92), "emission_scale":0.62,
		"impact_path":"res://assets/vfx/oga/impacts/god_angel_hit.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":18.0, "impact_size":Vector2(0.72,0.72), "impact_color":Color(1.0,0.90,0.68,0.90), "impact_emission_scale":0.58,
	},
	"god_archangel": {
		"path":"res://assets/vfx/oga/projectiles/god_archangel_seraph_orb.png", "columns":5, "rows":1, "frame_count":5,
		"fps":10.0, "size":Vector2(0.48,0.48), "speed":6.2, "arc_height":0.06, "wobble":0.012,
		"color":Color(0.88,0.94,1.0,0.92), "emission_scale":0.60,
		"impact_path":"res://assets/vfx/oga/impacts/god_archangel_hit.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":13.0, "impact_size":Vector2(0.62,0.62), "impact_emission_scale":0.62,
	},
	# 9.24 订正 #2：接过神侍原本的「星矛」模型（模型对换的另一半）。
	# 速度/弧线/摆动/命中依旧属于极光射手自己（10.5 / 0.02 / 0.0 / god_aurora_hit）。
	"god_aurora": {
		"path":"res://assets/vfx/oga/projectiles/god_priest_star_lance.png", "columns":5, "rows":1, "frame_count":5,
		"fps":13.0, "size":Vector2(0.72,0.72), "speed":10.5, "arc_height":0.02, "wobble":0.0,
		"impact_path":"res://assets/vfx/oga/impacts/god_aurora_hit.png", "impact_columns":4, "impact_rows":4, "impact_frames":16, "impact_fps":22.0, "impact_size":Vector2(0.58,0.58), "impact_emission_scale":0.64,
	},
	"dark_mage": {
		"path":"res://assets/vfx/oga/skill_packs/cosmic_orb.png", "columns":5, "rows":1, "frame_count":5,
		"fps":12.0, "size":Vector2(0.54,0.54), "speed":6.4, "arc_height":0.10, "wobble":0.038,
		"color":Color(0.58,0.34,0.90,0.92), "emission_scale":0.72,
		"impact_path":"res://assets/vfx/oga/skill_packs/cosmic_seal.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":15.0, "impact_size":Vector2(0.64,0.64), "impact_color":Color(0.68,0.40,0.96,0.90), "impact_emission_scale":0.66,
	},
	"dark_queen": {
		"path":"res://assets/vfx/oga/projectiles/dark_queen_blood_thorn.png", "columns":5, "rows":1, "frame_count":5,
		"fps":17.0, "size":Vector2(0.88,0.50), "speed":8.2, "arc_height":0.03, "wobble":0.020,
		"impact_path":"res://assets/vfx/oga/impacts/dark_queen_hit.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":16.0, "impact_size":Vector2(0.88,0.88),
	},
	# 9.24 订正 #6：弓箭手普攻投射物「形态和角色不符」→ 改成金属箭矢。
	#
	# ⚠️ 这条**只能改在这里**。9.24 第一版把 `BOLT_KIND_BY_UNIT` 改成 "metal_arrow"
	# 并给 `VFXRaceBasicAttack3D` 加了一个程序化金属箭网格体 —— 那是**死代码**：
	# 弓箭手是玩家棋子，`_basic_attack` 会先命中本表并 return，永远走不到 race bolt。
	#
	# 为什么最终没有走「程序化网格箭体」而是换一张手绘贴图：
	#   ① 本表自带 `impact_path` = human_archer_hit.png（4x4 / 16 帧的专属命中爆）。
	#      一旦改走程序化弹体路径，命中特效会被一并换成通用 `_spawn_linear_hit` ——
	#      而这条需求只要求改「投射物形态」，命中特效属于误伤。
	#   ② 12 只玩家棋子的弹道全是手绘贴图，插一个硬边网格体会「不贴合画风」。
	#   ③ 换贴图的影响面最小：speed / fps / size / impact_* 全部不动。
	#
	# 新图由 work/_qa_922/make_metal_arrow_924.py 依**原图实测的 45° 前向轴**生成
	# （960x176 = 6x160x176，与原图同分格），无需向美术要新资源。
	"human_archer": {
		"path":"res://assets/vfx/oga/projectiles/human_archer_metal_arrow.png", "columns":6, "rows":1, "frame_count":6,
		"fps":20.0, "size":Vector2(0.92,0.40), "speed":11.5, "arc_height":0.05, "wobble":0.0,
		"impact_path":"res://assets/vfx/oga/impacts/human_archer_hit.png", "impact_columns":4, "impact_rows":4, "impact_frames":16, "impact_fps":24.0, "impact_size":Vector2(0.58,0.58),
	},
	"human_cleric": {
		"path":"res://assets/vfx/oga/projectiles/human_cleric_nature_seed.png", "columns":5, "rows":1, "frame_count":5,
		"fps":9.0, "size":Vector2(0.62,0.86), "speed":5.2, "arc_height":0.30, "wobble":0.045,
		"impact_path":"res://assets/vfx/oga/impacts/human_cleric_hit.png", "impact_columns":7, "impact_rows":1, "impact_frames":7, "impact_fps":12.0, "impact_size":Vector2(0.92,0.78),
	},
	"human_mage": {
		"path":"res://assets/vfx/oga/projectiles/human_mage_arcane_satellites.png", "columns":7, "rows":1, "frame_count":7,
		"fps":13.0, "size":Vector2(0.54,0.54), "speed":6.6, "arc_height":0.16, "wobble":0.070,
		"color":Color(0.48,0.62,1.0,0.92), "emission_scale":0.62,
		"impact_path":"res://assets/vfx/oga/impacts/human_mage_hit.png", "impact_columns":7, "impact_rows":1, "impact_frames":7, "impact_fps":15.0, "impact_size":Vector2(0.64,0.64), "impact_color":Color(0.52,0.66,1.0,0.90), "impact_emission_scale":0.58,
	},
	"undead_spike": {
		"path":"res://assets/vfx/oga/projectiles/undead_spike_bone_fan.png", "columns":5, "rows":1, "frame_count":5,
		"fps":19.0, "size":Vector2(0.78,0.34), "speed":9.3, "arc_height":0.0, "wobble":0.010,
		"color":Color(0.78,0.74,0.62,0.94), "emission_scale":0.52,
		"impact_path":"res://assets/vfx/oga/impacts/undead_spike_hit.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":16.0, "impact_size":Vector2(0.62,0.62),
	},
	"undead_mother": {
		"path":"res://assets/vfx/oga/projectiles/undead_mother_blood_lance.png", "columns":5, "rows":1, "frame_count":5,
		"fps":10.0, "size":Vector2(0.82,0.58), "speed":5.7, "arc_height":0.20, "wobble":0.080,
		"impact_path":"res://assets/vfx/oga/impacts/undead_mother_hit.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":11.0, "impact_size":Vector2(0.98,0.98),
	},
}

const MELEE_PREVIEWS := [
	{"label":"神族金弧", "path":"res://assets/vfx/oga/skill_packs/slash_gold.png", "columns":6, "frames":6, "color":Color.WHITE},
	{"label":"人族蓝弧", "path":"res://assets/vfx/oga/skill_packs/slash_blue.png", "columns":6, "frames":6, "color":Color.WHITE},
	{"label":"暗族紫弧", "path":"res://assets/vfx/oga/skill_packs/slash_purple.png", "columns":6, "frames":6, "color":Color.WHITE},
	{"label":"灵族火弧", "path":"res://assets/vfx/oga/skill_packs/slash_fire.png", "columns":6, "frames":6, "color":Color.WHITE},
]

const MELEE_BY_RACE := {
	"god": {
		"path":"res://assets/vfx/oga/skill_packs/slash_gold.png", "columns":6, "rows":1, "frame_count":6,
		"fps":18.0, "size":Vector2(0.88,0.78), "duration":0.38, "impact_delay":0.09, "height_ratio":0.40,
		"impact_path":"res://assets/vfx/oga/skill_packs/earth_crack.png", "impact_columns":5, "impact_rows":1,
		"impact_frames":5, "impact_fps":16.0, "impact_size":Vector2(0.62,0.62), "impact_duration":0.34,
	},
	"human": {
		"path":"res://assets/vfx/oga/skill_packs/slash_blue.png", "columns":6, "rows":1, "frame_count":6,
		"fps":19.0, "size":Vector2(0.84,0.74), "duration":0.36, "impact_delay":0.08, "height_ratio":0.40,
		"impact_path":"res://assets/vfx/oga/skill_packs/earth_crack.png", "impact_columns":5, "impact_rows":1,
		"impact_frames":5, "impact_fps":16.0, "impact_size":Vector2(0.56,0.56), "impact_duration":0.32,
	},
	"dark": {
		"path":"res://assets/vfx/oga/skill_packs/slash_purple.png", "columns":6, "rows":1, "frame_count":6,
		"fps":18.0, "size":Vector2(0.90,0.76), "duration":0.39, "impact_delay":0.09, "height_ratio":0.40,
		"impact_path":"res://assets/vfx/oga/skill_packs/earth_smoke.png", "impact_columns":5, "impact_rows":1,
		"impact_frames":5, "impact_fps":14.0, "impact_size":Vector2(0.60,0.60), "impact_duration":0.36, "impact_color":Color(0.54,0.28,0.78,0.78),
	},
	"undead": {
		"path":"res://assets/vfx/oga/skill_packs/slash_fire.png", "columns":6, "rows":1, "frame_count":6,
		"fps":17.0, "size":Vector2(1.12,1.06), "duration":0.44, "impact_delay":0.11,
		"impact_path":"res://assets/vfx/oga/skill_packs/earth_debris.png", "impact_columns":5, "impact_rows":1,
		"impact_frames":5, "impact_fps":16.0, "impact_size":Vector2(0.76,0.76), "impact_duration":0.40, "impact_color":Color(0.56,0.86,0.58,0.88),
	},
}

const SKILL_PREVIEWS := [
	{"label":"天使护盾", "path":"res://assets/vfx/oga/skills/angel_shield.png", "columns":5, "rows":4, "frames":20, "fps":18.0, "size":Vector2(1.05,0.92)},
	{"label":"黑洞", "path":"res://assets/vfx/oga/skills/black_hole.png", "columns":5, "rows":1, "frames":5, "fps":11.0, "size":Vector2(0.92,0.92)},
	{"label":"大地冲击", "path":"res://assets/vfx/oga/skills/earth_impact.png", "columns":5, "rows":1, "frames":5, "fps":15.0, "size":Vector2(0.88,0.88)},
]

# Only semantically matching chess skills are replaced. Each entry is an
# exclusive formal route: when selected, the old skill VFX function is not run.
const FORMAL_SKILLS := {
	"random_ally_damage_reduction": {
		"path":"res://assets/vfx/oga/skills/angel_shield.png", "columns":5, "rows":4, "frame_count":20,
		"fps":18.0, "size":Vector2(1.18,1.30), "duration":1.18, "anchor":"target_body",
		"billboard":true, "loop":false, "track_target":true,
	},
	"black_hole": {
		"path":"res://assets/vfx/oga/skills/black_hole.png", "columns":5, "rows":1, "frame_count":5,
		"fps":9.0, "size":Vector2(2.65,2.65), "duration":1.26, "anchor":"origin_ground",
		"billboard":false, "ground":true, "loop":true,
	},
	"judgement_strike": {
		"path":"res://assets/vfx/oga/skills/earth_impact.png", "columns":5, "rows":1, "frame_count":5,
		"fps":15.0, "size":Vector2(1.36,1.36), "duration":0.58, "anchor":"target_ground",
		"billboard":false, "ground":true, "loop":false,
	},
}

static func projectile_for(unit_id: String) -> Dictionary:
	return (PROJECTILES.get(unit_id, {}) as Dictionary).duplicate(true)

static func is_player_chess(unit_id: String) -> bool:
	return unit_id in PLAYER_CHESS_UNITS

static func melee_for(unit_id: String, _race: String) -> Dictionary:
	var melee_race := str(MELEE_UNIT_RACE.get(unit_id, ""))
	if melee_race.is_empty():
		return {}
	return (MELEE_BY_RACE.get(melee_race, {}) as Dictionary).duplicate(true)

static func formal_skill_for(skill_id: String) -> Dictionary:
	return (FORMAL_SKILLS.get(skill_id, {}) as Dictionary).duplicate(true)

static func display_name(unit_id: String) -> String:
	return str(DISPLAY_NAMES.get(unit_id, unit_id))

static func validate_unique_projectiles() -> PackedStringArray:
	var errors := PackedStringArray()
	var paths := {}
	for unit_id in RANGED_UNIT_ORDER:
		var spec: Dictionary = PROJECTILES.get(unit_id, {})
		if spec.is_empty():
			errors.append("missing:%s" % unit_id)
			continue
		var path := str(spec.get("path", ""))
		if path.is_empty():
			errors.append("empty_path:%s" % unit_id)
		elif paths.has(path):
			errors.append("duplicate:%s:%s" % [paths[path], unit_id])
		else:
			paths[path] = unit_id
	return errors
