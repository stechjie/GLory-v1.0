extends RefCounted

# 跑步动画的「脚贴地速度」标定表（纯表现数据，不进模拟、不进回放摘要）。
#
# 背景（2026-10-29 实测）：插值让移动连续之后，滑步就露出来了 —— 游戏里单位约每秒
# 移动 3 个身高（冲刺速度），而各模型的跑步片段按原速播放时，脚着地那段对应的地面
# 速度从 0.1 到 2.4 世界单位/秒不等，一个统一系数救不了。
#
# ground_speed 的量法：单位原地播跑步片段（走 BattleRenderer 同一套建模、缩放和
# ModelRootMotionPolicy 原地化），采样脚骨，脚处在最低段（着地）时相对身体往后滑的
# 水平速度。脚贴地时身体就该以这个速度前进，所以
#     播放倍率 = 实际显示移动速度 / ground_speed
# 量的是 speed_scale = 1、模型缩放 = model_scale（model_visual_scale × 三阶加成）、
# 全局 battle_unit_visual_scale = MEASURED_GLOBAL_SCALE 时的数值；任一缩放改了按比例换算。
#
# 失效保护：model 路径对不上（换了模型）就不用这条，回到原速，宁可滑也不乱调。
# 没收录的单位：找不到脚骨的、拿跳舞/待机/「边走边想」当跑步的 —— 前者没法量，
# 后者调速没有意义，要换片段。
# 收录的走路片段（catwalk / walk-relaxed 等）需要 5–30 倍，播放侧会封顶，仍会滑，
# 根治要换成真正的跑步片段。
#
# 重测：探针做法见记忆 run-anim-foot-sliding；换了模型或片段要重测对应条目。

const MEASURED_GLOBAL_SCALE := 0.42

const GROUND_SPEED := {
	"Icey": {"model": "res://assets/models/units/crimson_refined/Icey/Icey_refined.tscn", "model_scale": 1.21, "clip": "run", "ground_speed": 0.415},
	"boss_apocalypse": {"model": "res://assets/models/enemies_refined/boss_apocalypse/boss_apocalypse_refined.tscn", "model_scale": 2.0, "clip": "move_run_f", "ground_speed": 2.437},
	"boss_blood_demon": {"model": "res://assets/models/enemies_refined/boss_blood_demon/boss_blood_demon_refined.tscn", "model_scale": 2.0, "clip": "move_run_f", "ground_speed": 1.527},
	"boss_holy_priest": {"model": "res://assets/models/enemies_refined/boss_holy_priest/boss_holy_priest_refined.tscn", "model_scale": 2.0, "clip": "move_run_f", "ground_speed": 1.889},
	"boss_meteor_caster": {"model": "res://assets/models/enemies_refined/boss_meteor_caster/boss_meteor_caster_refined.tscn", "model_scale": 2.0, "clip": "move_run_f", "ground_speed": 2.051},
	"boss_mirror_lord": {"model": "res://assets/models/enemies_refined/boss_mirror_lord/boss_mirror_lord_refined.tscn", "model_scale": 2.0, "clip": "move_run_f", "ground_speed": 2.360},
	"boss_rage_beast": {"model": "res://assets/models/enemies_refined/boss_rage_beast/boss_rage_beast_refined.tscn", "model_scale": 2.0, "clip": "move_run_f", "ground_speed": 1.676},
	"boss_soul_devourer": {"model": "res://assets/models/enemies_refined/boss_soul_devourer/boss_soul_devourer_refined.tscn", "model_scale": 2.0, "clip": "move_run_f", "ground_speed": 2.470},
	"boss_thunder_core": {"model": "res://assets/models/enemies_refined/boss_thunder_core/boss_thunder_core_refined.tscn", "model_scale": 2.0, "clip": "move_run_f", "ground_speed": 2.259},
	"boss_twin_gate": {"model": "res://assets/models/enemies_refined/boss_twin_gate/boss_twin_gate_refined.tscn", "model_scale": 2.0, "clip": "move_run_f", "ground_speed": 2.075},
	"crimson": {"model": "res://assets/models/units/crimson_refined/crimson/crimson_refined.tscn", "model_scale": 1.09, "clip": "run", "ground_speed": 2.477},
	"dark_doom": {"model": "res://assets/models/units/dark_refined/dark_doom/dark_doom_refined.tscn", "model_scale": 1.2, "clip": "Armature|move_run_f", "ground_speed": 1.210},
	"dark_dragon": {"model": "res://assets/models/units/dark_refined/dark_dragon/dark_dragon_refined.tscn", "model_scale": 1.2, "clip": "catwalk-loop-378982", "ground_speed": 0.356},
	"dark_fear": {"model": "res://assets/models/units/dark_refined/dark_fear/dark_fear_refined.tscn", "model_scale": 1.0, "clip": "walk-relaxed-loop-378936", "ground_speed": 0.160},
	"dark_mage": {"model": "res://assets/models/units/dark_refined/dark_mage/dark_mage_refined.tscn", "model_scale": 1.0, "clip": "walk-relaxed-2loop-378986", "ground_speed": 0.101},
	"dark_queen": {"model": "res://assets/models/units/dark_refined/dark_queen/dark_queen_refined.tscn", "model_scale": 1.0, "clip": "catwalk-loop-378982", "ground_speed": 0.233},
	"dark_scythe": {"model": "res://assets/models/units/dark_refined/dark_scythe/dark_scythe_refined.tscn", "model_scale": 1.0, "clip": "catwalk-loop-378982", "ground_speed": 0.289},
	"dark_suc": {"model": "res://assets/models/units/dark_refined/dark_suc/dark_suc_refined.tscn", "model_scale": 1.0, "clip": "catwalk-loop-378982", "ground_speed": 0.275},
	"god_angel": {"model": "res://assets/models/units/god_angel_refined/god_angel_refined.tscn", "model_scale": 1.0, "clip": "catwalk-loop-378982", "ground_speed": 0.266},
	"god_archangel": {"model": "res://assets/models/units/god_archangel_refined/god_archangel_refined.tscn", "model_scale": 1.2, "clip": "walk-relaxed-2loop-378986", "ground_speed": 0.142},
	"god_aurora": {"model": "res://assets/models/units/god_aurora_refined/god_aurora_refined.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 0.794},
	"god_guard": {"model": "res://assets/models/units/god_guard_refined/god_guard_refined.tscn", "model_scale": 1.0, "clip": "run", "ground_speed": 0.975},
	"god_king": {"model": "res://assets/models/units/god_king_refined/god_king_refined.tscn", "model_scale": 1.2, "clip": "walk-relaxed-2loop-378986", "ground_speed": 0.155},
	"god_priest": {"model": "res://assets/models/units/god_priest_refined/god_priest_refined.tscn", "model_scale": 1.0, "clip": "walk-relaxed-loop-378936", "ground_speed": 0.095},
	"god_priestess": {"model": "res://assets/models/units/god_priestess_refined/god_priestess_refined.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 0.384},
	"human_archer": {"model": "res://assets/models/units/human_refined/human_archer/human_archer_refined.tscn", "model_scale": 1.0, "clip": "walk-relaxed-2loop-378986", "ground_speed": 0.179},
	"human_cleric": {"model": "res://assets/models/units/human_refined/human_cleric/human_cleric_refined.tscn", "model_scale": 1.0, "clip": "catwalk-loop-378982", "ground_speed": 0.203},
	"human_death_servant": {"model": "res://assets/models/units/human_refined/human_death_servant/human_death_servant_refined.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 1.775},
	"human_king": {"model": "res://assets/models/units/human_refined/human_king/human_king_refined.tscn", "model_scale": 1.2, "clip": "walk-relaxed-2loop-378986", "ground_speed": 0.266},
	"human_mage": {"model": "res://assets/models/units/human_refined/human_mage/human_mage_refined.tscn", "model_scale": 1.0, "clip": "catwalk-loop-378982", "ground_speed": 0.287},
	"human_merchant": {"model": "res://assets/models/units/human_refined/human_merchant/human_merchant_refined.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 0.806},
	"human_militia": {"model": "res://assets/models/units/human_refined/human_militia/human_militia_refined.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 0.793},
	"human_swordsman": {"model": "res://assets/models/units/human_refined/human_swordsman/human_swordsman_refined.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 0.671},
	"merc_aquarius_time": {"model": "res://assets/models/mercenaries/merc_aquarius_time_animated/merc_aquarius_time_animated.tscn", "model_scale": 1.0, "clip": "mixamo_com", "ground_speed": 0.318},
	"merc_aries_blood": {"model": "res://assets/models/mercenaries/merc_aries_blood_animated/merc_aries_blood_animated.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 0.972},
	"merc_cancer_shell": {"model": "res://assets/models/mercenaries/merc_cancer_shell_animated/merc_cancer_shell_animated.tscn", "model_scale": 2.0, "clip": "mixamo_com", "ground_speed": 0.853},
	"merc_capricorn_steel": {"model": "res://assets/models/mercenaries/merc_capricorn_steel_animated/merc_capricorn_steel_animated.tscn", "model_scale": 1.0, "clip": "catwalk-loop-378982", "ground_speed": 0.339},
	"merc_gemini_assassin": {"model": "res://assets/models/mercenaries/merc_gemini_assassin_animated/merc_gemini_assassin_animated.tscn", "model_scale": 1.0, "clip": "mixamo_com", "ground_speed": 0.446},
	"merc_libra_judge": {"model": "res://assets/models/mercenaries/merc_libra_judge_animated/merc_libra_judge_animated.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 0.972},
	"merc_pisces_bubble": {"model": "res://assets/models/mercenaries/merc_pisces_bubble_animated/merc_pisces_bubble_animated.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 1.049},
	"merc_sagittarius_rain": {"model": "res://assets/models/mercenaries/merc_sagittarius_rain_animated/merc_sagittarius_rain_animated.tscn", "model_scale": 1.0, "clip": "walk-2loop-379004", "ground_speed": 0.128},
	"merc_scorpio_death": {"model": "res://assets/models/mercenaries/merc_scorpio_death_animated/merc_scorpio_death_animated.tscn", "model_scale": 1.0, "clip": "mixamo_com", "ground_speed": 0.330},
	"merc_virgo_heal": {"model": "res://assets/models/mercenaries/merc_virgo_heal_animated/merc_virgo_heal_animated.tscn", "model_scale": 1.0, "clip": "Armature|mixamo_com|Layer0", "ground_speed": 0.354},
	"pve_land_ancient_tree": {"model": "res://assets/models/enemies_refined/pve_land_ancient_tree/pve_land_ancient_tree_refined.tscn", "model_scale": 1.0, "clip": "catwalk-loop-378982", "ground_speed": 0.386},
	"pve_land_lava_golem": {"model": "res://assets/models/enemies_refined/pve_land_lava_golem/pve_land_lava_golem_refined.tscn", "model_scale": 1.0, "clip": "catwalk-loop-378982", "ground_speed": 0.394},
	"pve_land_mountain_giant": {"model": "res://assets/models/enemies_refined/pve_land_mountain_giant/pve_land_mountain_giant_refined.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 1.195},
	"pve_land_rock_beast": {"model": "res://assets/models/enemies_refined/pve_land_rock_beast/pve_land_rock_beast_refined.tscn", "model_scale": 1.0, "clip": "catwalk-loop-378982", "ground_speed": 0.494},
	"pve_land_vein_worm": {"model": "res://assets/models/enemies_refined/pve_land_vein_worm/pve_land_vein_worm_refined.tscn", "model_scale": 1.0, "clip": "catwalk-loop-378982", "ground_speed": 0.833},
	"pve_land_vine_guard": {"model": "res://assets/models/enemies_refined/pve_land_vine_guard/pve_land_vine_guard_refined.tscn", "model_scale": 1.0, "clip": "catwalk-loop-378982", "ground_speed": 0.309},
	"pve_ren_poison_doctor": {"model": "res://assets/models/enemies_refined/pve_ren_poison_doctor/pve_ren_poison_doctor_refined.tscn", "model_scale": 1.0, "clip": "catwalk-loop-378982", "ground_speed": 0.339},
	"pve_ren_shadow_thief": {"model": "res://assets/models/enemies_refined/pve_ren_shadow_thief/pve_ren_shadow_thief_refined.tscn", "model_scale": 1.0, "clip": "catwalk-loop-378982", "ground_speed": 0.338},
	"pve_ren_voodoo_witch": {"model": "res://assets/models/enemies_refined/pve_ren_voodoo_witch/pve_ren_voodoo_witch_refined.tscn", "model_scale": 1.0, "clip": "catwalk-loop-378982", "ground_speed": 0.325},
	"pve_ren_wandering_swordsman": {"model": "res://assets/models/enemies_refined/pve_ren_wandering_swordsman/pve_ren_wandering_swordsman_refined.tscn", "model_scale": 1.0, "clip": "catwalk-loop-378982", "ground_speed": 0.266},
	"pve_sky_cloud_eagle": {"model": "res://assets/models/enemies_refined/pve_sky_cloud_eagle/pve_sky_cloud_eagle_refined.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 0.949},
	"pve_sky_dome_guard": {"model": "res://assets/models/enemies_refined/pve_sky_dome_guard/pve_sky_dome_guard_refined.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 0.998},
	"pve_sky_hymn_spirit": {"model": "res://assets/models/enemies_refined/pve_sky_hymn_spirit/pve_sky_hymn_spirit_refined.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 0.439},
	"pve_sky_star_butterfly": {"model": "res://assets/models/enemies_refined/pve_sky_star_butterfly/pve_sky_star_butterfly_refined.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 0.991},
	"pve_sky_thunder_spirit": {"model": "res://assets/models/enemies_refined/pve_sky_thunder_spirit/pve_sky_thunder_spirit_refined.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 1.052},
	"pve_sky_wind_falcon": {"model": "res://assets/models/enemies_refined/pve_sky_wind_falcon/pve_sky_wind_falcon_refined.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 0.968},
	"undead_bomb": {"model": "res://assets/models/units/undead_refined/undead_bomb/undead_bomb_refined.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 0.828},
	"undead_fly": {"model": "res://assets/models/units/undead_refined/undead_fly/undead_fly_refined.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 0.834},
	"undead_mother": {"model": "res://assets/models/units/undead_refined/undead_mother/undead_mother_refined.tscn", "model_scale": 1.2, "clip": "catwalk-loop-378982", "ground_speed": 0.271},
	"undead_parasite": {"model": "res://assets/models/units/undead_refined/undead_parasite/undead_parasite_refined.tscn", "model_scale": 1.0, "clip": "move_run_f", "ground_speed": 0.909},
	"undead_poison": {"model": "res://assets/models/units/undead_refined/undead_poison/undead_poison_refined.tscn", "model_scale": 1.0, "clip": "walk-relaxed-2loop-378986", "ground_speed": 0.149},
	"undead_spike": {"model": "res://assets/models/units/undead_refined/undead_spike/undead_spike_refined.tscn", "model_scale": 1.0, "clip": "walk-relaxed-2loop-378986", "ground_speed": 0.120},
	"undead_titan": {"model": "res://assets/models/units/undead_refined/undead_titan/undead_titan_refined.tscn", "model_scale": 1.0, "clip": "walk-relaxed-loop-378936", "ground_speed": 0.120},
}


## 返回该单位跑步片段在当前模型缩放下的脚贴地速度（世界单位/秒）；没有可靠数据返回 0。
static func ground_speed_for(unit_id: String, unit_def: Dictionary, model_scale: float,
		global_scale: float = MEASURED_GLOBAL_SCALE) -> float:
	var entry: Variant = GROUND_SPEED.get(unit_id)
	if not (entry is Dictionary):
		return 0.0
	var row := entry as Dictionary
	if str(row.get("model", "")) != str(unit_def.get("model", "")):
		return 0.0
	var measured_scale := float(row.get("model_scale", 0.0))
	if measured_scale <= 0.0 or model_scale <= 0.0 or global_scale <= 0.0:
		return 0.0
	var model_ratio := model_scale / measured_scale
	var global_ratio := global_scale / MEASURED_GLOBAL_SCALE
	return float(row.get("ground_speed", 0.0)) * model_ratio * global_ratio
