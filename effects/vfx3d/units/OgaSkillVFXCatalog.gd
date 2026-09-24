extends RefCounted
class_name OgaSkillVFXCatalog

const ROOT := "res://assets/vfx/oga/skill_packs/"

const SKILLS := {
	"lowest_ally_heal": {"layers": [
		{"name":"HolyHealCross", "path":ROOT+"holy_heal.png", "columns":5, "rows":1, "frame_count":5, "fps":13.0, "duration":0.58, "anchor":"target_body", "size":Vector2(0.78,0.78), "color":Color(1.0,0.92,0.72,0.92), "emission_scale":0.62, "track_target":true},
		{"name":"HolyHealBless", "path":ROOT+"holy_bless.png", "columns":5, "rows":1, "frame_count":5, "fps":11.0, "duration":0.76, "delay":0.12, "anchor":"target_ground", "ground":true, "billboard":false, "size":Vector2(1.12,1.12), "color":Color(1.0,0.92,0.72,0.86)},
	]},
	"nearest_ally_bless": {"layers": [
		{"name":"HolyBlessSigil", "path":ROOT+"holy_bless.png", "columns":5, "rows":1, "frame_count":5, "fps":10.0, "duration":0.78, "anchor":"target_ground", "ground":true, "billboard":false, "size":Vector2(1.22,1.22), "color":Color(0.88,0.92,1.0,0.92)},
		{"name":"HolyBlessCore", "path":ROOT+"holy_heal.png", "columns":5, "rows":1, "frame_count":5, "fps":14.0, "duration":0.52, "delay":0.16, "anchor":"target_body", "size":Vector2(0.82,0.82), "track_target":true},
	]},
	"nearby_ally_heal_buff": {"group_targets":true, "layers": [
		{"name":"AngelGroupCast", "path":ROOT+"holy_burst.png", "columns":5, "rows":1, "frame_count":5, "fps":15.0, "duration":0.50, "anchor":"origin_body", "size":Vector2(1.18,1.18)},
	], "target_layers": [
		{"name":"AngelGroupHeal", "path":ROOT+"holy_heal.png", "columns":5, "rows":1, "frame_count":5, "fps":13.0, "duration":0.62, "anchor":"target_body", "size":Vector2(0.74,0.74)},
	]},
	"guardian_shield_taunt": {"layers": [
		{"name":"GuardianBlueShield", "path":"res://assets/vfx/oga/skills/angel_shield_event_frame.tres", "columns":1, "rows":1, "frame_count":1, "fps":1.0, "duration":1.10, "anchor":"origin_body", "size":Vector2(0.92,0.84), "start_scale":0.30, "peak_scale":1.0, "end_scale":0.96, "color":Color(0.54,0.76,1.0,0.88), "fade_out":0.22, "emission_scale":0.58},
		{"name":"GuardianTauntPulse", "path":ROOT+"holy_burst.png", "columns":5, "rows":1, "frame_count":5, "fps":14.0, "duration":0.52, "delay":0.10, "anchor":"origin_ground", "ground":true, "billboard":false, "size":Vector2(1.46,1.46), "color":Color(0.30,0.58,1.0,0.78)},
	]},
	"silence_bolt": {"layers": [
		{"name":"SilenceGather", "path":ROOT+"cosmic_orb.png", "columns":5, "rows":1, "frame_count":5, "fps":14.0, "duration":0.42, "anchor":"origin_body", "size":Vector2(0.70,0.70), "color":Color(0.58,0.34,0.84,0.94), "start_scale":0.80, "peak_scale":0.46, "end_scale":0.24},
		{"name":"SilenceSeal", "path":ROOT+"cosmic_seal.png", "columns":5, "rows":1, "frame_count":5, "fps":12.0, "duration":0.72, "delay":0.28, "anchor":"target_head", "size":Vector2(0.76,0.76), "color":Color(0.78,0.54,1.0,0.92), "track_target":true},
	]},
	"black_hole": {"layers": [
		{"name":"BlackHoleSeal", "path":ROOT+"cosmic_seal.png", "columns":5, "rows":1, "frame_count":5, "fps":9.0, "duration":1.12, "anchor":"origin_ground", "ground":true, "billboard":false, "size":Vector2(1.86,1.86), "color":Color(0.20,0.08,0.36,0.76), "rotation_speed":0.38, "emission_scale":0.48, "fade_out":0.20},
		{"name":"BlackHoleBody", "path":ROOT+"cosmic_vortex.png", "columns":5, "rows":1, "frame_count":5, "fps":10.0, "duration":1.22, "delay":0.12, "anchor":"origin_ground", "ground":true, "billboard":false, "size":Vector2(1.52,1.52), "color":Color(0.42,0.20,0.72,0.90), "rotation_speed":-0.92, "emission_scale":0.62, "fade_out":0.22},
		{"name":"BlackHoleCore", "path":ROOT+"mage_arcane.png", "columns":7, "rows":1, "frame_count":7, "fps":14.0, "duration":0.70, "delay":0.24, "anchor":"origin_body", "size":Vector2(0.58,0.48), "color":Color(0.72,0.48,0.98,0.70), "emission_scale":0.54},
	]},
	"curse_attack": {"layers": [
		{"name":"BloodCurseSlash", "path":ROOT+"blood_slash.png", "columns":5, "rows":1, "frame_count":5, "fps":16.0, "duration":0.44, "anchor":"target_body", "size":Vector2(1.12,0.92), "track_target":true},
		{"name":"BloodCurseMark", "path":ROOT+"blood_orb.png", "columns":5, "rows":1, "frame_count":5, "fps":10.0, "duration":0.82, "delay":0.13, "anchor":"target_ground", "ground":true, "billboard":false, "size":Vector2(0.92,0.92), "color":Color(0.86,0.32,0.48,0.80)},
	]},
	"same_target_damage_stack": {"layers": [
		{"name":"PainThorn", "path":ROOT+"blood_thorn.png", "columns":5, "rows":1, "frame_count":5, "fps":15.0, "duration":0.48, "anchor":"target_body", "size":Vector2(1.18,0.82), "track_target":true},
		{"name":"PainBloom", "path":ROOT+"blood_bloom.png", "columns":5, "rows":1, "frame_count":5, "fps":11.0, "duration":0.76, "delay":0.16, "anchor":"target_body", "size":Vector2(0.94,0.94), "color":Color(0.92,0.26,0.40,0.86), "track_target":true},
	]},
	"poison_attack": {"layers": [
		{"name":"PoisonVines", "path":ROOT+"nature_poison.png", "columns":7, "rows":1, "frame_count":7, "fps":15.0, "duration":0.58, "anchor":"target_body", "size":Vector2(0.78,0.52), "color":Color(0.34,0.68,0.24,0.84), "emission_scale":0.40, "track_target":true},
		{"name":"PoisonSpore", "path":ROOT+"special_green.png", "columns":5, "rows":2, "frame_count":10, "fps":14.0, "duration":0.70, "delay":0.12, "anchor":"target_body", "size":Vector2(0.52,0.52), "color":Color(0.46,0.82,0.18,0.72), "emission_scale":0.38, "track_target":true},
	]},
	"poison_reflect_armor_stack": {"layers": [
		{"name":"PoisonArmor", "path":ROOT+"nature_armor.png", "columns":7, "rows":1, "frame_count":7, "fps":12.0, "duration":0.82, "anchor":"origin_body", "size":Vector2(0.80,0.86), "color":Color(0.30,0.64,0.16,0.82), "emission_scale":0.40},
		{"name":"PoisonArmorSparks", "path":ROOT+"special_green.png", "columns":5, "rows":2, "frame_count":10, "fps":16.0, "duration":0.60, "delay":0.16, "anchor":"origin_body", "size":Vector2(0.50,0.50), "color":Color(0.58,0.88,0.24,0.68), "emission_scale":0.42},
	]},
	"death_poison_explosion": {"layers": [
		{"name":"PoisonDeathBurst", "path":ROOT+"poison_explosion.png", "columns":4, "rows":4, "frame_count":16, "fps":22.0, "duration":0.68, "anchor":"origin_body", "size":Vector2(0.90,0.90), "color":Color(0.26,0.68,0.14,0.82), "emission_scale":0.46},
		{"name":"PoisonDeathDebris", "path":ROOT+"poison_debris.png", "columns":4, "rows":4, "frame_count":16, "fps":22.0, "duration":0.68, "delay":0.08, "anchor":"origin_body", "size":Vector2(0.78,0.78), "color":Color(0.42,0.76,0.18,0.76), "emission_scale":0.42},
		{"name":"PoisonResidue", "path":ROOT+"nature_bloom.png", "columns":5, "rows":1, "frame_count":5, "fps":8.0, "duration":0.94, "delay":0.18, "anchor":"origin_ground", "ground":true, "billboard":false, "size":Vector2(0.98,0.98), "color":Color(0.20,0.54,0.10,0.68), "emission_scale":0.32},
	]},
}

const MELEE_SKILLS := {
	"front_cone_stun": {"path":ROOT+"slash_blue.png", "columns":6, "rows":1, "frame_count":6, "fps":20.0, "size":Vector2(1.02,0.90), "duration":0.40, "impact_delay":0.10, "height_ratio":0.42, "impact_path":ROOT+"earth_crack.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":16.0, "impact_size":Vector2(0.76,0.76), "impact_duration":0.38},
	"judgement_strike": {"path":ROOT+"slash_gold.png", "columns":6, "rows":1, "frame_count":6, "fps":19.0, "size":Vector2(1.12,0.96), "duration":0.42, "impact_delay":0.11, "height_ratio":0.43, "impact_path":ROOT+"earth_debris.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":16.0, "impact_size":Vector2(0.88,0.88), "impact_duration":0.42, "impact_color":Color(1.0,0.82,0.46,0.86)},
	"global_divine_blast": {"path":ROOT+"slash_gold.png", "columns":6, "rows":1, "frame_count":6, "fps":17.0, "size":Vector2(0.94,0.84), "duration":0.42, "impact_delay":0.11, "height_ratio":0.40, "impact_path":ROOT+"earth_smoke.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":13.0, "impact_size":Vector2(0.72,0.72), "impact_duration":0.42, "impact_color":Color(0.62,0.74,0.94,0.74)},
}

const PROJECTILES := {
	"fire": {"path":ROOT+"mage_fireball.png", "columns":5, "rows":1, "frame_count":5, "fps":16.0, "size":Vector2(0.68,0.68), "speed":7.1, "arc_height":0.18, "wobble":0.025, "impact_path":ROOT+"mage_fire_impact.png", "impact_columns":7, "impact_rows":2, "impact_frames":14, "impact_fps":22.0, "impact_size":Vector2(0.88,0.72), "impact_duration":0.58},
	"ice": {"path":ROOT+"mage_ice.png", "columns":6, "rows":4, "frame_count":22, "fps":24.0, "size":Vector2(0.64,0.88), "speed":7.6, "arc_height":0.12, "wobble":0.018, "impact_path":ROOT+"holy_burst.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":16.0, "impact_size":Vector2(0.74,0.74), "impact_color":Color(0.46,0.84,1.0,0.92)},
	"thunder": {"path":ROOT+"mage_lightning.png", "columns":6, "rows":4, "frame_count":20, "fps":28.0, "size":Vector2(0.68,0.78), "speed":10.5, "arc_height":0.04, "wobble":0.0, "impact_path":ROOT+"mage_lightning.png", "impact_columns":6, "impact_rows":4, "impact_frames":20, "impact_fps":30.0, "impact_size":Vector2(0.86,0.86), "impact_duration":0.44},
	"poison": {"path":ROOT+"nature_cast.png", "columns":5, "rows":1, "frame_count":5, "fps":14.0, "size":Vector2(0.74,0.54), "speed":6.4, "arc_height":0.24, "wobble":0.045, "impact_path":ROOT+"nature_poison.png", "impact_columns":7, "impact_rows":1, "impact_frames":7, "impact_fps":17.0, "impact_size":Vector2(0.90,0.66), "impact_duration":0.52},
	"arcane": {"path":ROOT+"mage_arcane.png", "columns":7, "rows":1, "frame_count":7, "fps":17.0, "size":Vector2(0.68,0.60), "speed":7.0, "arc_height":0.14, "wobble":0.055, "impact_path":ROOT+"cosmic_orb.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":15.0, "impact_size":Vector2(0.82,0.82), "impact_duration":0.50},
	# 9.24 #4：暗影法师「沉默箭」的投射物本体。原版只有「聚气 + 凭空落封印」，
	# 没有真正飞出去的箭体。这里用既有 cosmic_orb（暗紫箭体）+ cosmic_seal（封印）
	# 拼一条会飞的沉默箭：发射 → 命中目标 → 落封印。speed 与 BattleVfx 的
	# cue_silence_hit_delay 对齐（9.0），命中音才能卡在箭体落地那一刻。
	"silence": {"path":ROOT+"cosmic_orb.png", "columns":5, "rows":1, "frame_count":5, "fps":16.0, "size":Vector2(0.60,0.60), "speed":9.0, "arc_height":0.05, "wobble":0.012, "color":Color(0.62,0.36,0.92,0.96), "emission_scale":0.84, "impact_path":ROOT+"cosmic_seal.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":12.0, "impact_size":Vector2(0.78,0.78), "impact_color":Color(0.78,0.54,1.0,0.92), "impact_duration":0.72},
}

const BLOOD_LINK_PROJECTILE := {"path":ROOT+"blood_link.png", "columns":5, "rows":1, "frame_count":5, "fps":15.0, "size":Vector2(1.04,0.48), "speed":5.2, "arc_height":0.04, "wobble":0.02, "impact_path":ROOT+"blood_bloom.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":13.0, "impact_size":Vector2(0.92,0.92), "impact_duration":0.62}

static func skill_for(skill_id: String) -> Dictionary:
	return (SKILLS.get(skill_id, {}) as Dictionary).duplicate(true)

static func melee_for(skill_id: String) -> Dictionary:
	return (MELEE_SKILLS.get(skill_id, {}) as Dictionary).duplicate(true)

static func projectile_for_element(element: String) -> Dictionary:
	var key := element.to_lower()
	if key == "frost": key = "ice"
	if key == "nature": key = "poison"
	if key == "lightning": key = "thunder"
	return (PROJECTILES.get(key, PROJECTILES["arcane"]) as Dictionary).duplicate(true)

static func blood_link_projectile() -> Dictionary:
	return BLOOD_LINK_PROJECTILE.duplicate(true)
