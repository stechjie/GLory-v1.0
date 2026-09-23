extends RefCounted
class_name OgaChessVFXCatalog

# Formal OpenGameArt replacement catalogue for player chess pieces.
# Every ranged chess piece owns a different projectile atlas, motion profile and
# impact atlas. Player melee attacks and the three approved semantic skill
# replacements are also routed here so the formal composer can bypass the old
# effect rather than stacking both versions.

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
	"god_priest": {
		"path":"res://assets/vfx/oga/projectiles/god_priest_star_lance.png", "columns":5, "rows":1, "frame_count":5,
		"fps":13.0, "size":Vector2(0.72,0.72), "speed":5.6, "arc_height":0.10, "wobble":0.015,
		"impact_path":"res://assets/vfx/oga/impacts/god_priest_hit.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":15.0, "impact_size":Vector2(0.74,0.74),
	},
	"god_priestess": {
		"path":"res://assets/vfx/oga/projectiles/god_priestess_halo_disc.png", "columns":5, "rows":1, "frame_count":5,
		"fps":11.0, "size":Vector2(0.70,0.70), "speed":5.0, "arc_height":0.18, "wobble":0.025,
		"impact_path":"res://assets/vfx/oga/impacts/god_priestess_hit.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":14.0, "impact_size":Vector2(0.78,0.78),
	},
	"god_angel": {
		"path":"res://assets/vfx/oga/projectiles/god_angel_wing.png", "columns":5, "rows":1, "frame_count":5,
		"fps":16.0, "size":Vector2(0.84,0.62), "speed":7.5, "arc_height":0.26, "wobble":0.035,
		"impact_path":"res://assets/vfx/oga/impacts/god_angel_hit.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":18.0, "impact_size":Vector2(0.92,0.92),
	},
	"god_archangel": {
		"path":"res://assets/vfx/oga/projectiles/god_archangel_seraph_orb.png", "columns":5, "rows":1, "frame_count":5,
		"fps":10.0, "size":Vector2(0.62,0.62), "speed":6.2, "arc_height":0.06, "wobble":0.012,
		"impact_path":"res://assets/vfx/oga/impacts/god_archangel_hit.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":13.0, "impact_size":Vector2(0.76,0.76),
	},
	"god_aurora": {
		"path":"res://assets/vfx/oga/projectiles/god_aurora_light_spear.png", "columns":5, "rows":1, "frame_count":5,
		"fps":18.0, "size":Vector2(0.94,0.48), "speed":10.5, "arc_height":0.02, "wobble":0.0,
		"impact_path":"res://assets/vfx/oga/impacts/god_aurora_hit.png", "impact_columns":4, "impact_rows":4, "impact_frames":16, "impact_fps":22.0, "impact_size":Vector2(0.70,0.70),
	},
	"dark_mage": {
		"path":"res://assets/vfx/oga/projectiles/dark_mage_arcane_skull.png", "columns":7, "rows":1, "frame_count":7,
		"fps":14.0, "size":Vector2(0.78,0.66), "speed":6.0, "arc_height":0.12, "wobble":0.055,
		"impact_path":"res://assets/vfx/oga/impacts/dark_mage_hit.png", "impact_columns":7, "impact_rows":1, "impact_frames":7, "impact_fps":16.0, "impact_size":Vector2(0.82,0.82),
	},
	"dark_queen": {
		"path":"res://assets/vfx/oga/projectiles/dark_queen_blood_thorn.png", "columns":5, "rows":1, "frame_count":5,
		"fps":17.0, "size":Vector2(0.88,0.50), "speed":8.2, "arc_height":0.03, "wobble":0.020,
		"impact_path":"res://assets/vfx/oga/impacts/dark_queen_hit.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":16.0, "impact_size":Vector2(0.88,0.88),
	},
	"human_archer": {
		"path":"res://assets/vfx/oga/projectiles/human_archer_blue_wind_arrow.png", "columns":6, "rows":1, "frame_count":6,
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
		"fps":13.0, "size":Vector2(0.72,0.72), "speed":6.6, "arc_height":0.16, "wobble":0.070,
		"impact_path":"res://assets/vfx/oga/impacts/human_mage_hit.png", "impact_columns":7, "impact_rows":1, "impact_frames":7, "impact_fps":15.0, "impact_size":Vector2(0.86,0.86),
	},
	"undead_spike": {
		"path":"res://assets/vfx/oga/projectiles/undead_spike_bone_fan.png", "columns":5, "rows":1, "frame_count":5,
		"fps":19.0, "size":Vector2(0.92,0.44), "speed":9.3, "arc_height":0.0, "wobble":0.010,
		"impact_path":"res://assets/vfx/oga/impacts/undead_spike_hit.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":16.0, "impact_size":Vector2(0.78,0.78),
	},
	"undead_mother": {
		"path":"res://assets/vfx/oga/projectiles/undead_mother_blood_lance.png", "columns":5, "rows":1, "frame_count":5,
		"fps":10.0, "size":Vector2(0.82,0.58), "speed":5.7, "arc_height":0.20, "wobble":0.080,
		"impact_path":"res://assets/vfx/oga/impacts/undead_mother_hit.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":11.0, "impact_size":Vector2(0.98,0.98),
	},
}

const MELEE_PREVIEWS := [
	{"label":"神族金弧", "path":"res://assets/vfx/oga/melee/god_gold_arc.png", "columns":6, "frames":6, "color":Color.WHITE},
	{"label":"人族蓝弧", "path":"res://assets/vfx/oga/melee/human_blue_arc.png", "columns":6, "frames":6, "color":Color.WHITE},
	{"label":"暗族紫弧", "path":"res://assets/vfx/oga/melee/dark_purple_arc.png", "columns":6, "frames":6, "color":Color.WHITE},
]

const MELEE_BY_RACE := {
	"god": {
		"path":"res://assets/vfx/oga/melee/god_gold_arc.png", "columns":6, "rows":1, "frame_count":6,
		"fps":18.0, "size":Vector2(1.12,1.10), "duration":0.42, "impact_delay":0.10,
		"impact_path":"res://assets/vfx/oga/impacts/god_angel_hit.png", "impact_columns":5, "impact_rows":1,
		"impact_frames":5, "impact_fps":18.0, "impact_size":Vector2(0.78,0.78), "impact_duration":0.36,
	},
	"human": {
		"path":"res://assets/vfx/oga/melee/human_blue_arc.png", "columns":6, "rows":1, "frame_count":6,
		"fps":19.0, "size":Vector2(1.08,1.04), "duration":0.40, "impact_delay":0.09,
		"impact_path":"res://assets/vfx/oga/impacts/human_archer_hit.png", "impact_columns":4, "impact_rows":4,
		"impact_frames":16, "impact_fps":24.0, "impact_size":Vector2(0.64,0.64), "impact_duration":0.40,
	},
	"dark": {
		"path":"res://assets/vfx/oga/melee/dark_purple_arc.png", "columns":6, "rows":1, "frame_count":6,
		"fps":18.0, "size":Vector2(1.16,1.08), "duration":0.43, "impact_delay":0.10,
		"impact_path":"res://assets/vfx/oga/impacts/dark_mage_hit.png", "impact_columns":7, "impact_rows":1,
		"impact_frames":7, "impact_fps":17.0, "impact_size":Vector2(0.78,0.78), "impact_duration":0.42,
	},
	"undead": {
		"path":"res://assets/vfx/oga/melee/dark_purple_arc.png", "columns":6, "rows":1, "frame_count":6,
		"fps":17.0, "size":Vector2(1.12,1.06), "duration":0.44, "impact_delay":0.11,
		"impact_path":"res://assets/vfx/oga/impacts/undead_spike_hit.png", "impact_columns":5, "impact_rows":1,
		"impact_frames":5, "impact_fps":16.0, "impact_size":Vector2(0.76,0.76), "impact_duration":0.40,
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

static func melee_for(unit_id: String, race: String) -> Dictionary:
	if not unit_id in PLAYER_CHESS_UNITS or unit_id in RANGED_UNIT_ORDER:
		return {}
	return (MELEE_BY_RACE.get(race, {}) as Dictionary).duplicate(true)

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
