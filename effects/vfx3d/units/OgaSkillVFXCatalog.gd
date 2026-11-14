extends RefCounted
class_name OgaSkillVFXCatalog

const ROOT := "res://assets/vfx/oga/skill_packs/"
# pixelfx（MIT，third_party/pixelfx）按平滑版重新渲染的序列帧，见 tools/pixelfx_smooth/。
const PFX := "res://assets/vfx/skills/pixelfx/"

const SKILLS := {
	# 11.13 起，带 PFX 前缀的条目是 pixelfx 平滑序列帧（tools/pixelfx_smooth 导出，参数见 jobs_batch1.json），
	# 这些条目原来用的 OGA 5 帧贴图已停用（文件保留，别的条目还在用的照旧）。
	"lowest_ally_heal": {"layers": [
		{"name":"PfxHolyHeal", "path":PFX+"holy_heal.png", "columns":8, "rows":4, "frame_count":29, "fps":15.0, "duration":1.933, "anchor":"target_ground", "ground":false, "billboard":true, "size":Vector2(1.11,2.02), "lift":0.50, "toward_camera":0.45, "start_scale":1.0, "peak_scale":1.0, "end_scale":1.0, "fade_in":0.04, "fade_out":0.18, "emission_scale":0.25, "track_target":true},
	]},
	"nearest_ally_bless": {"layers": [
		{"name":"PfxBlessBeam", "path":PFX+"holy_blessing.png", "columns":9, "rows":3, "frame_count":25, "fps":15.0, "duration":1.667, "anchor":"target_ground", "ground":false, "billboard":true, "size":Vector2(1.06,2.78), "lift":0.74, "toward_camera":0.45, "start_scale":1.0, "peak_scale":1.0, "end_scale":1.0, "fade_in":0.04, "fade_out":0.18, "emission_scale":0.25, "track_target":true},
		{"name":"PfxBlessHalo", "path":PFX+"holy_halo.png", "columns":4, "rows":5, "frame_count":19, "fps":15.0, "duration":1.267, "delay":0.22, "anchor":"target_head", "ground":false, "billboard":true, "size":Vector2(0.81,0.76), "lift":0.06, "toward_camera":0.45, "start_scale":1.0, "peak_scale":1.0, "end_scale":1.0, "fade_in":0.04, "fade_out":0.18, "emission_scale":0.25, "track_target":true},
	]},
	"nearby_ally_heal_buff": {"group_targets":true, "layers": [
		{"name":"PfxAngelFeathers", "path":PFX+"holy_feather_burst.png", "columns":5, "rows":5, "frame_count":25, "fps":12.0, "duration":2.083, "anchor":"origin_body", "ground":false, "billboard":true, "size":Vector2(2.04,1.82), "lift":-0.17, "toward_camera":0.45, "start_scale":1.0, "peak_scale":1.0, "end_scale":1.0, "fade_in":0.04, "fade_out":0.18, "emission_scale":0.3},
	], "target_layers": [
		{"name":"PfxAngelHeal", "path":PFX+"holy_heal.png", "columns":8, "rows":4, "frame_count":29, "fps":15.0, "duration":1.933, "delay":0.18, "anchor":"target_ground", "ground":false, "billboard":true, "size":Vector2(0.92,1.68), "lift":0.42, "toward_camera":0.45, "start_scale":1.0, "peak_scale":1.0, "end_scale":1.0, "fade_in":0.04, "fade_out":0.18, "emission_scale":0.25},
	]},
	# 11.13：光之卫士 = 金色蜂巢半球罩（跟护罩状态）+ 脚下金色符文法阵（跟嘲讽状态，护罩破了还在）。实际播放走 VFXGuardianSanctuary3D（护罩/嘲讽状态由战斗数据驱动），
	# 模块从这里按 name 取贴图参数；这份条目同时供预加载清单使用。旧的灰色水晶壳与 OGA 图层停用。
	"guardian_shield_taunt": {"layers": [
		{"name":"PfxGuardDome", "path":PFX+"guard_dome.png", "columns":4, "rows":8, "frame_count":29, "fps":12.0, "duration":2.417, "loop":true, "size":Vector2(2.53,1.30), "pivot_y":0.7667, "color":Color(1.0,1.0,1.0,0.78), "emission_scale":0.15},
		{"name":"PfxGuardRunes", "path":PFX+"guard_runes.png", "columns":6, "rows":7, "frame_count":40, "fps":10.0, "duration":4.0, "loop":true, "size":Vector2(1.85,1.39), "pivot_y":0.6897, "emission_scale":0.25},
	]},
	# 11.13：魅魔眩晕 = 目标头顶跳动的粉色爱心（status/charmed 平滑版，爱心改成按心形公式画）。
	# _stun_hit 按眩晕时长截短 duration；旧的钩斩 / 荆棘结在战斗镜头里几乎看不见，停用。
	"stun": {"layers": [
		{"name":"PfxCharmHearts", "path":PFX+"charm_hearts.png", "columns":6, "rows":5, "frame_count":29, "fps":12.0, "duration":2.417, "anchor":"target_head", "ground":false, "billboard":true, "size":Vector2(0.73,0.96), "lift":0.05, "toward_camera":0.45, "start_scale":1.0, "peak_scale":1.0, "end_scale":1.0, "fade_in":0.06, "fade_out":0.25, "emission_scale":0.3, "track_target":true},
	]},
	# 11.13：大天使「降临」起手光柱换成金色光束扇形 + 光柱（holy/holy-pillar），约 0.5 秒落地；羽翼护盾不变。
	# 由 UnitSkillVFXComposer3D._angel_guard 播放，不是整条技能路由。
	"random_ally_damage_reduction": {"layers": [
		{"name":"PfxAngelPillar", "path":PFX+"angel_pillar.png", "columns":6, "rows":5, "frame_count":28, "fps":15.0, "duration":1.867, "anchor":"target_ground", "ground":false, "billboard":true, "size":Vector2(2.43,2.83), "lift":0.83, "toward_camera":0.45, "start_scale":1.0, "peak_scale":1.0, "end_scale":1.0, "fade_in":0.04, "fade_out":0.3, "emission_scale":0.25, "track_target":true},
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
		{"name":"PfxCrimsonCurse", "path":PFX+"curse_crimson.png", "columns":6, "rows":5, "frame_count":27, "fps":12.0, "duration":2.25, "anchor":"target_ground", "ground":false, "billboard":true, "size":Vector2(1.88,2.14), "lift":1.15, "toward_camera":0.45, "start_scale":1.0, "peak_scale":1.0, "end_scale":1.0, "fade_in":0.04, "fade_out":0.18, "emission_scale":0.2, "track_target":true},
	]},
	"same_target_damage_stack": {"layers": [
		{"name":"PfxPainBurst", "path":PFX+"pain_burst.png", "columns":3, "rows":5, "frame_count":13, "fps":20.0, "duration":0.65, "anchor":"target_body", "ground":false, "billboard":true, "size":Vector2(2.12,1.38), "lift":0.25, "toward_camera":0.45, "start_scale":1.0, "peak_scale":1.0, "end_scale":1.0, "fade_in":0.04, "fade_out":0.18, "emission_scale":0.3, "track_target":true},
	]},
	# 11.13：毒灵/飞灵从贴地酸液池换成往上翻涌的毒云（spore-burst 去掉蘑菇本体），更立体。
	# 毒是每次攻击都挂的：云要小、短（1.25s）、半透明，且 UnitSkillVFXComposer3D 对同一目标 1.6 秒内只放一次。
	"poison_attack": {"layers": [
		{"name":"PfxToxicCloud", "path":PFX+"toxic_cloud.png", "columns":4, "rows":4, "frame_count":15, "fps":12.0, "duration":1.25, "anchor":"target_ground", "ground":false, "billboard":true, "size":Vector2(1.33,1.24), "lift":0.32, "toward_camera":0.45, "start_scale":1.0, "peak_scale":1.0, "end_scale":1.0, "fade_in":0.04, "fade_out":0.35, "color":Color(1.0,1.0,1.0,0.72), "emission_scale":0.2, "track_target":true},
	]},
	"poison_reflect_armor_stack": {"layers": [
		{"name":"PfxToxicShield", "path":PFX+"toxic_shield.png", "columns":5, "rows":4, "frame_count":19, "fps":15.0, "duration":1.267, "anchor":"origin_ground", "ground":false, "billboard":true, "size":Vector2(1.09,1.13), "lift":0.26, "toward_camera":0.45, "start_scale":1.0, "peak_scale":1.0, "end_scale":1.0, "fade_in":0.04, "fade_out":0.18, "emission_scale":0.25, "track_origin":true},
	]},
	"death_poison_explosion": {"layers": [
		{"name":"PfxToxicBurst", "path":PFX+"toxic_burst.png", "columns":5, "rows":5, "frame_count":23, "fps":15.0, "duration":1.533, "anchor":"origin_body", "ground":false, "billboard":true, "size":Vector2(2.41,2.10), "lift":0.00, "toward_camera":0.45, "start_scale":1.0, "peak_scale":1.0, "end_scale":1.0, "fade_in":0.04, "fade_out":0.18, "emission_scale":0.3},
	]},
}

const MELEE_SKILLS := {
	# 11.13 起，带 PFX 前缀的条目是 pixelfx 平滑序列帧（tools/pixelfx_smooth 导出，参数见 jobs_batch1.json），
	# 这些条目原来用的 OGA 5 帧贴图已停用（文件保留，别的条目还在用的照旧）。
	"front_cone_stun": {"path":PFX+"sword_slash.png", "columns":3, "rows":4, "frame_count":12, "fps":20.0, "size":Vector2(1.90,1.42), "duration":0.6, "impact_delay":0.12, "height_ratio":0.40, "emission_scale":0.3, "impact_path":PFX+"stun_stars.png", "impact_columns":4, "impact_rows":5, "impact_frames":19, "impact_fps":15.0, "impact_size":Vector2(0.97,0.67), "impact_duration":1.267, "impact_billboard":true, "impact_lift":1.05, "impact_emission_scale":0.3},
	"judgement_strike": {"path":ROOT+"slash_gold.png", "columns":6, "rows":1, "frame_count":6, "fps":19.0, "size":Vector2(1.12,0.96), "duration":0.42, "impact_delay":0.11, "height_ratio":0.43, "impact_path":ROOT+"earth_debris.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":16.0, "impact_size":Vector2(0.88,0.88), "impact_duration":0.42, "impact_color":Color(1.0,0.82,0.46,0.86)},
	"global_divine_blast": {"path":ROOT+"slash_gold.png", "columns":6, "rows":1, "frame_count":6, "fps":17.0, "size":Vector2(0.94,0.84), "duration":0.42, "impact_delay":0.11, "height_ratio":0.40, "impact_path":ROOT+"earth_smoke.png", "impact_columns":5, "impact_rows":1, "impact_frames":5, "impact_fps":13.0, "impact_size":Vector2(0.72,0.72), "impact_duration":0.42, "impact_color":Color(0.62,0.74,0.94,0.74)},
}

const PROJECTILES := {
	# 11.13 起，带 PFX 前缀的条目是 pixelfx 平滑序列帧（tools/pixelfx_smooth 导出，参数见 jobs_batch1.json），
	# 这些条目原来用的 OGA 5 帧贴图已停用（文件保留，别的条目还在用的照旧）。
	"fire": {"path":PFX+"fire_bolt.png", "columns":2, "rows":5, "frame_count":10, "fps":15.0, "loop":true, "size":Vector2(1.07,0.52), "speed":7.1, "arc_height":0.18, "wobble":0.025, "emission_scale":0.3, "impact_path":PFX+"fire_impact.png", "impact_columns":3, "impact_rows":5, "impact_frames":13, "impact_fps":20.0, "impact_size":Vector2(1.85,1.20), "impact_duration":0.65, "impact_lift":0.22, "impact_emission_scale":0.3},
	"ice": {"path":PFX+"ice_bolt.png", "columns":2, "rows":4, "frame_count":8, "fps":15.0, "loop":true, "size":Vector2(1.15,0.46), "speed":7.6, "arc_height":0.12, "wobble":0.018, "emission_scale":0.3, "impact_path":PFX+"ice_impact.png", "impact_columns":4, "impact_rows":4, "impact_frames":16, "impact_fps":12.0, "impact_size":Vector2(1.11,1.03), "impact_duration":1.333, "impact_lift":0.34, "impact_emission_scale":0.3},
	"thunder": {"path":PFX+"thunder_bolt.png", "columns":2, "rows":4, "frame_count":8, "fps":15.0, "loop":true, "size":Vector2(1.12,0.56), "speed":10.5, "arc_height":0.04, "wobble":0.0, "emission_scale":0.3, "impact_path":PFX+"thunder_impact.png", "impact_columns":4, "impact_rows":5, "impact_frames":19, "impact_fps":20.0, "impact_size":Vector2(1.42,0.91), "impact_duration":0.95, "impact_lift":0.00, "impact_emission_scale":0.3},
	"poison": {"path":PFX+"poison_bolt.png", "columns":2, "rows":4, "frame_count":8, "fps":15.0, "loop":true, "size":Vector2(1.12,0.56), "speed":6.4, "arc_height":0.24, "wobble":0.045, "emission_scale":0.3, "impact_path":PFX+"acid_splash.png", "impact_columns":5, "impact_rows":5, "impact_frames":25, "impact_fps":12.0, "impact_size":Vector2(1.34,1.21), "impact_duration":2.083, "impact_lift":-0.06, "impact_emission_scale":0.3},
	"arcane": {"path":PFX+"arcane_bolt.png", "columns":4, "rows":4, "frame_count":16, "fps":15.0, "loop":true, "size":Vector2(0.87,0.84), "speed":7.0, "arc_height":0.14, "wobble":0.055, "emission_scale":0.3, "impact_path":PFX+"arcane_impact.png", "impact_columns":4, "impact_rows":5, "impact_frames":17, "impact_fps":12.0, "impact_size":Vector2(1.36,1.19), "impact_duration":1.417, "impact_lift":0.27, "impact_emission_scale":0.3},
	# 9.24 #4：暗影法师「沉默箭」的投射物本体。原版只有「聚气 + 凭空落封印」，
	# 没有真正飞出去的箭体。11.13 起箭体是 pixelfx 虚空球、命中落六芒封印（原 cosmic_orb / cosmic_seal 停用），
	# 拼一条会飞的沉默箭：发射 → 命中目标 → 落封印。speed 与 BattleVfx 的
	# cue_silence_hit_delay 对齐（9.0），命中音才能卡在箭体落地那一刻。
	"silence": {"path":PFX+"silence_bolt.png", "columns":4, "rows":4, "frame_count":16, "fps":15.0, "loop":true, "size":Vector2(0.90,0.90), "speed":9.0, "arc_height":0.05, "wobble":0.012, "emission_scale":0.3, "impact_path":PFX+"silence_seal.png", "impact_columns":5, "impact_rows":6, "impact_frames":29, "impact_fps":12.0, "impact_size":Vector2(1.19,1.13), "impact_duration":2.417, "impact_lift":0.68, "impact_emission_scale":0.3},
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

static func layer_named(skill_id: String, layer_name: String) -> Dictionary:
	for layer: Variant in (SKILLS.get(skill_id, {}) as Dictionary).get("layers", []):
		if layer is Dictionary and str((layer as Dictionary).get("name", "")) == layer_name:
			return (layer as Dictionary).duplicate(true)
	return {}

static func blood_link_projectile() -> Dictionary:
	return BLOOD_LINK_PROJECTILE.duplicate(true)
