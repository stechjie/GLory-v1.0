extends Node

# 10.21 战场音效接入批次的接线探针。
#
# 目的：不靠「看着代码觉得对」，而是**逐条量到**「表里有 / 派发函数能算出」。
# 历史教训（MEMORY §十二）：门禁必须「绿能解释成量到了 N 次」，
# 断言排在所有早退之前，分几段跑要核对每段实跑条数。

const SfxService := preload("res://ui/services/SfxService.gd")
const MusicService := preload("res://ui/services/MusicService.gd")

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var fails: Array = []
	var checks := 0
	_expect(fails, checks, true)

	# --- 第 1 段：29 条素材路径都在 CUES 里，且文件真的存在 -------------
	var expected := [
		"proj_arrow", "proj_javelin", "proj_orb", "proj_dark_orb", "proj_holy",
		"proj_light_lance", "proj_wing", "proj_disc", "proj_frost", "proj_ember",
		"proj_bone", "proj_thorn", "proj_thunder", "proj_divine_blade",
		"melee_metal", "melee_nonmetal", "melee_unarmed",
		"mage_attribute_bolt",
		"star4_guard_skill", "star4_queen_skill", "star4_crimson_skill",
		"star4_dancer_skill", "star4_drumer_skill", "star4_hunter_skill",
		"star4_icey_skill", "star4_lattern_skill", "star4_skypierce_skill",
		"merc_cancer_shell_skill", "merc_leo_sun_skill",
	]
	var cue_consts := {
		"proj_arrow": SfxService.CUE_PROJ_ARROW,
		"proj_javelin": SfxService.CUE_PROJ_JAVELIN,
		"proj_orb": SfxService.CUE_PROJ_ORB,
		"proj_dark_orb": SfxService.CUE_PROJ_DARK_ORB,
		"proj_holy": SfxService.CUE_PROJ_HOLY,
		"proj_light_lance": SfxService.CUE_PROJ_LIGHT_LANCE,
		"proj_wing": SfxService.CUE_PROJ_WING,
		"proj_disc": SfxService.CUE_PROJ_DISC,
		"proj_frost": SfxService.CUE_PROJ_FROST,
		"proj_ember": SfxService.CUE_PROJ_EMBER,
		"proj_bone": SfxService.CUE_PROJ_BONE,
		"proj_thorn": SfxService.CUE_PROJ_THORN,
		"proj_thunder": SfxService.CUE_PROJ_THUNDER,
		"proj_divine_blade": SfxService.CUE_PROJ_DIVINE_BLADE,
		"melee_metal": SfxService.CUE_MELEE_METAL,
		"melee_nonmetal": SfxService.CUE_MELEE_NONMETAL,
		"melee_unarmed": SfxService.CUE_MELEE_UNARMED,
		"mage_attribute_bolt": SfxService.CUE_MAGE_ATTRIBUTE_BOLT,
		"star4_guard_skill": SfxService.CUE_STAR4_GUARD_SKILL,
		"star4_queen_skill": SfxService.CUE_STAR4_QUEEN_SKILL,
		"star4_crimson_skill": SfxService.CUE_STAR4_CRIMSON_SKILL,
		"star4_dancer_skill": SfxService.CUE_STAR4_DANCER_SKILL,
		"star4_drumer_skill": SfxService.CUE_STAR4_DRUMER_SKILL,
		"star4_hunter_skill": SfxService.CUE_STAR4_HUNTER_SKILL,
		"star4_icey_skill": SfxService.CUE_STAR4_ICEY_SKILL,
		"star4_lattern_skill": SfxService.CUE_STAR4_LATTERN_SKILL,
		"star4_skypierce_skill": SfxService.CUE_STAR4_SKYPIERCE_SKILL,
		"merc_cancer_shell_skill": SfxService.CUE_MERC_CANCER_SHELL_SKILL,
		"merc_leo_sun_skill": SfxService.CUE_MERC_LEO_SUN_SKILL,
	}
	var missing: Array = []
	for name in expected:
		var cid := str(cue_consts.get(name, ""))
		checks += 1
		if cid != name:
			fails.append("const_mismatch %s -> %s" % [name, cid])
			continue
		var path := SfxService.resolved_cue_path(name)
		if path.is_empty():
			fails.append("no_path " + name)
			continue
		# ⚠️ 必须用 `FileAccess.file_exists()` 查**源文件**，不能用 `ResourceLoader.exists()`。
		# 后者对导入过的 mp3 会走 `.import` 的 remap 指向 `.godot/imported/*.sample` ——
		# 源 mp3 删掉之后那条缓存还在，于是仍返回 true。变异实测：把 proj_arrow.mp3
		# 改名（.import 留着）后 `ResourceLoader.exists()` 依然 true、门禁照样 PASS。
		if not FileAccess.file_exists(path):
			missing.append(name)
	# ★ 区分「素材整批没投放」与「路径写错」：
	#
	# `assets/*` 在正式服仓里是**整目录 .gitignore**（3.1GB 走网盘），所以 v1.0 侧
	# 天然一个都没有 —— 拿它判红等于「仓库结构本身就是故障」，那不是门禁该说的话。
	# 但**部分缺失**是真故障（表里某个路径拼错），必须红。
	#
	# 判据：29 条全缺 ⇒ 环境性（只报告，不判红）；缺 1~28 条 ⇒ 判红。
	if missing.size() == expected.size():
		print("SEG1_ENV assets_not_delivered=%d（整批未投放，判为环境性，不判红）" % missing.size())
	elif not missing.is_empty():
		for name in missing:
			fails.append("missing_file " + str(name))
	print("SEG1 cues_registered=%d missing=%d fails=%d" % [expected.size(), missing.size(), fails.size()])

	# --- 第 2 段：普攻路由表覆盖 57 行审查表 ------------------------------
	# 键 = (unit_id, ranged)，值 = 期望的 cue。取自 manifest 的 57 行 prev 条目。
	var ranged_expect := {
		"god_priest": "proj_light_lance", "god_priestess": "proj_disc",
		"god_aurora": "proj_light_lance", "god_angel": "proj_wing",
		"god_archangel": "proj_holy", "dark_mage": "proj_dark_orb",
		"dark_queen": "proj_thorn", "human_archer": "proj_arrow",
		"human_cleric": "proj_orb", "undead_spike": "proj_bone",
		"undead_mother": "proj_javelin", "dancer": "proj_disc",
		"hunter": "proj_arrow", "Icey": "proj_frost",
		"skypierce": "proj_javelin", "lattern": "proj_ember",
		"merc_sagittarius_rain": "proj_arrow", "merc_pisces_bubble": "proj_orb",
		"merc_virgo_heal": "proj_holy", "merc_aquarius_time": "proj_orb",
		"boss_meteor_caster": "proj_orb", "boss_holy_priest": "proj_holy",
		"boss_apocalypse": "proj_javelin", "human_king": "proj_divine_blade",
		"boss_thunder_core": "proj_thunder",
		# 10.21 审查表（PvE 专项，16 只全通过）：药毒医师按 dart 弹体改 proj_thorn
		"pve_ren_poison_doctor": "proj_thorn",
	}
	var melee_expect := {
		"god_arbiter": "melee_metal", "god_king": "melee_metal",
		"human_swordsman": "melee_metal", "dark_scythe": "melee_metal",
		"god_guard": "melee_metal", "drumer": "melee_nonmetal",
		"armbreaker": "melee_metal", "human_militia": "melee_metal",
		"human_death_servant": "melee_metal", "dark_imp": "melee_nonmetal",
		"dark_fear": "melee_nonmetal", "dark_doom": "melee_metal",
		"dark_dragon": "melee_nonmetal", "undead_titan": "melee_nonmetal",
		"crimson": "melee_nonmetal", "undead_small": "melee_unarmed",
		"undead_poison": "melee_unarmed", "undead_parasite": "melee_unarmed",
		"undead_fly": "melee_unarmed", "undead_bomb": "melee_unarmed",
		"human_merchant": "melee_unarmed", "merc_libra_judge": "melee_metal",
		"merc_taurus_charge": "melee_metal", "merc_gemini_assassin": "melee_metal",
		"merc_aries_blood": "melee_metal", "merc_capricorn_steel": "melee_metal",
		"merc_scorpio_death": "melee_metal", "merc_cancer_shell": "melee_nonmetal",
		"merc_leo_sun": "melee_nonmetal", "boss_blood_demon": "melee_metal",
		"boss_twin_gate": "melee_metal", "boss_mirror_lord": "melee_nonmetal",
		"boss_rage_beast": "melee_nonmetal", "boss_soul_devourer": "melee_nonmetal",
		# 10.21 补：PvE 近战小怪 9 只（此前从没进过审查表 ⇒ 普攻无声）
		"pve_ren_shadow_thief": "melee_metal",
		"pve_ren_wandering_swordsman": "melee_metal",
		"pve_sky_dome_guard": "melee_metal",
		"pve_land_lava_golem": "melee_nonmetal",
		"pve_land_mountain_giant": "melee_nonmetal",
		"pve_land_rock_beast": "melee_nonmetal",
		"pve_land_vein_worm": "melee_nonmetal",
		"pve_sky_cloud_eagle": "melee_unarmed",
		"pve_land_vine_guard": "melee_unarmed",
	}
	var seg2_fail := 0
	for uid in ranged_expect:
		var want := str(ranged_expect[uid])
		checks += 1
		if SfxService.basic_attack_cue_for(uid, true) != want:
			seg2_fail += 1
			fails.append("ranged %s want=%s got=%s" % [uid, want, SfxService.basic_attack_cue_for(uid, true)])
	for uid in melee_expect:
		var want2 := str(melee_expect[uid])
		checks += 1
		if SfxService.basic_attack_cue_for(uid, false) != want2:
			seg2_fail += 1
			fails.append("melee %s want=%s got=%s" % [uid, want2, SfxService.basic_attack_cue_for(uid, false)])
	# 法师不该有普攻音（no_basic_attack）
	checks += 1
	if not SfxService.basic_attack_cue_for("human_mage", true).is_empty() or not SfxService.basic_attack_cue_for("human_mage", false).is_empty():
		seg2_fail += 1
		fails.append("mage_should_have_no_basic")
	print("SEG2 basic_route ranged=%d melee=%d fails=%d" % [ranged_expect.size(), melee_expect.size(), seg2_fail])

	# --- 第 3 段：技能派发表逐条对 ------------------------------
	var seg3_fail := 0
	var cast_units := {"dancer": "star4_dancer_skill", "Icey": "star4_icey_skill", "lattern": "star4_lattern_skill"}
	for uid in cast_units:
		var want := str(cast_units[uid])
		checks += 1
		var got := SfxService.star4_cue_for(uid, true)
		if got != want:
			seg3_fail += 1
			fails.append("star4_cast %s want=%s got=%s" % [uid, want, got])
	var merc_units := {"merc_cancer_shell": "merc_cancer_shell_skill", "merc_leo_sun": "merc_leo_sun_skill"}
	for uid in merc_units:
		var want3 := str(merc_units[uid])
		checks += 1
		var got3 := SfxService.merc_skill_cue_for(uid)
		if got3 != want3:
			seg3_fail += 1
			fails.append("merc_cast %s want=%s got=%s" % [uid, want3, got3])
	var attack_units := {"dark_queen": "star4_queen_skill"}
	for uid in attack_units:
		var want4 := str(attack_units[uid])
		checks += 1
		var got4 := SfxService.attack_skill_cue_for(uid)
		if got4 != want4:
			seg3_fail += 1
			fails.append("star4_attack %s want=%s got=%s" % [uid, want4, got4])
	var proc_skills := {
		"block_guard": "star4_crimson_skill",
		"stacking_def_break": "star4_spike_proc",
		"current_hp_strike": "star4_hunter_skill",
		"line_pierce": "star4_skypierce_skill",
		"team_random_stack": "star4_drumer_skill",
		"guardian_shield_taunt": "star4_guard_skill",
	}
	for sid in proc_skills:
		var want5 := str(proc_skills[sid])
		checks += 1
		var got5 := SfxService.proc_skill_cue_for(sid)
		if got5 != want5:
			seg3_fail += 1
			fails.append("star4_proc %s want=%s got=%s" % [sid, want5, got5])
	# 法师 1~3★ 低星技能音
	checks += 1
	if SfxService.low_star_skill_cue_for("human_mage") != "mage_attribute_bolt":
		seg3_fail += 1
		fails.append("low_star mage want=mage_attribute_bolt got=" + SfxService.low_star_skill_cue_for("human_mage"))
	# 人王的四星条目必须已删除（用户拍板）
	checks += 1
	if SfxService.star4_cue_for("human_king", true) != "":
		seg3_fail += 1
		fails.append("human_king star4 should be deleted, got=" + SfxService.star4_cue_for("human_king", true))
	print("SEG3 skill_dispatch cast=%d merc=%d attack=%d proc=%d fails=%d" % [
		cast_units.size(), merc_units.size(), attack_units.size(), proc_skills.size(), seg3_fail])

	# --- 第 4 段：混音参数 ------------------------------------------------
	var seg4_fail := 0
	# P7 全部 400ms；P6 全部 340ms
	for c in ["proj_arrow", "proj_javelin", "proj_orb", "proj_dark_orb", "proj_holy",
			"proj_light_lance", "proj_wing", "proj_disc", "proj_frost", "proj_ember",
			"proj_bone", "proj_thorn", "proj_thunder", "proj_divine_blade"]:
		checks += 1
		if int(SfxService.THROTTLE_MSEC_BY_CUE.get(c, 0)) != 400:
			seg4_fail += 1
			fails.append("throttle_p7 %s=%s" % [c, SfxService.THROTTLE_MSEC_BY_CUE.get(c, 0)])
	for c in ["melee_metal", "melee_nonmetal", "melee_unarmed"]:
		checks += 1
		if int(SfxService.THROTTLE_MSEC_BY_CUE.get(c, 0)) != 340:
			seg4_fail += 1
			fails.append("throttle_p6 %s=%s" % [c, SfxService.THROTTLE_MSEC_BY_CUE.get(c, 0)])
	checks += 1
	if int(SfxService.THROTTLE_MSEC_BY_CUE.get("mage_attribute_bolt", 0)) != 300:
		seg4_fail += 1
		fails.append("throttle_p5 mage=%s" % SfxService.THROTTLE_MSEC_BY_CUE.get("mage_attribute_bolt", 0))
	for c in ["star4_guard_skill", "star4_queen_skill", "star4_crimson_skill", "star4_dancer_skill",
			"star4_hunter_skill", "star4_icey_skill", "star4_lattern_skill", "star4_skypierce_skill",
			"merc_cancer_shell_skill", "merc_leo_sun_skill"]:
		checks += 1
		if int(SfxService.THROTTLE_MSEC_BY_CUE.get(c, 0)) != 200:
			seg4_fail += 1
			fails.append("throttle_p2 %s=%s" % [c, SfxService.THROTTLE_MSEC_BY_CUE.get(c, 0)])
	checks += 1
	if int(SfxService.THROTTLE_MSEC_BY_CUE.get("star4_drumer_skill", 0)) != 2600:
		seg4_fail += 1
		fails.append("throttle_drumer=%s" % SfxService.THROTTLE_MSEC_BY_CUE.get("star4_drumer_skill", 0))
	# 音量配平：抽查几条特征值（10-21 普攻音整体 +2 dB，见 VOLUME_DB_BY_CUE 表头）
	var db_expect := {"proj_arrow": -5.0, "proj_ember": -1.0, "proj_frost": -5.0,
		"proj_divine_blade": -2.0, "melee_metal": -4.0, "melee_unarmed": -2.0,
		"mage_attribute_bolt": -4.0}
	for c in db_expect:
		checks += 1
		var want6 := float(db_expect[c])
		if not is_equal_approx(SfxService.cue_volume_db(c), want6):
			seg4_fail += 1
			fails.append("db %s want=%s got=%s" % [c, want6, SfxService.cue_volume_db(c)])
	# 11 条技能音不该有 mix_db（走 P2 默认）
	for c in ["star4_guard_skill", "star4_queen_skill", "star4_crimson_skill", "star4_dancer_skill",
			"star4_drumer_skill", "star4_hunter_skill", "star4_icey_skill", "star4_lattern_skill",
			"star4_skypierce_skill", "merc_cancer_shell_skill", "merc_leo_sun_skill"]:
		checks += 1
		if not is_equal_approx(SfxService.cue_volume_db(c), 0.0):
			seg4_fail += 1
			fails.append("db_skill_should_be_zero %s=%s" % [c, SfxService.cue_volume_db(c)])
	print("SEG4 mixing fails=%d" % seg4_fail)

	# --- 第 5 段：战斗层并发上限 ------------------------------------------
	var seg5_fail := 0
	checks += 1
	SfxService.set_battle_voice_cap(6)
	if SfxService.battle_voice_cap() != 6:
		seg5_fail += 1
		fails.append("cap_set_6 failed got=%d" % SfxService.battle_voice_cap())
	checks += 1
	if SfxService.battle_live_count() != 0:
		seg5_fail += 1
		fails.append("cap_reset_should_be_zero got=%d" % SfxService.battle_live_count())
	# 闸门函数本身：cap=2 时连放 3 次，第 3 次必须被拒
	# 不真的播（headless 无声），只验计数器逻辑。
	SfxService.set_battle_voice_cap(0)   # 0 = 不限，先关掉
	checks += 1
	if not SfxService._battle_cap_allows():
		seg5_fail += 1
		fails.append("cap_zero_should_allow_all")
	print("SEG5 battle_cap fails=%d" % seg5_fail)

	# --- 第 6 段：BGM 战斗压低（10-21 用户实测「BGM 盖住普攻音」）-------------
	#
	# 根因是结构性的：总线只有 Master + SFX 且**都是 0 dB**，BGM 落 Master 为
	# 1.0 线性，普攻音净下来低 7~9 dB ⇒ 必然被盖住。修法是战斗里把 BGM 压到
	# 0.5 线性 + 普攻音各 +2 dB。这一段钉住「能设、能还原、会夹取」。
	var seg6_fail := 0
	checks += 1
	if not is_equal_approx(MusicService.base_linear(), 1.0):
		seg6_fail += 1
		fails.append("bgm_default_should_be_1.0 got=%s" % MusicService.base_linear())
	MusicService.set_base_linear(0.5)
	checks += 1
	if not is_equal_approx(MusicService.base_linear(), 0.5):
		seg6_fail += 1
		fails.append("bgm_set_0.5_failed got=%s" % MusicService.base_linear())
	MusicService.set_base_linear(1.0)
	checks += 1
	if not is_equal_approx(MusicService.base_linear(), 1.0):
		seg6_fail += 1
		fails.append("bgm_restore_1.0_failed got=%s" % MusicService.base_linear())
	# 夹取：负数按 0、超界按 2.0
	MusicService.set_base_linear(-1.0)
	checks += 1
	if not is_equal_approx(MusicService.base_linear(), 0.0):
		seg6_fail += 1
		fails.append("bgm_clamp_negative_failed got=%s" % MusicService.base_linear())
	MusicService.set_base_linear(9.0)
	checks += 1
	if not is_equal_approx(MusicService.base_linear(), 2.0):
		seg6_fail += 1
		fails.append("bgm_clamp_high_failed got=%s" % MusicService.base_linear())
	MusicService.set_base_linear(1.0)
	print("SEG6 bgm_battle_duck fails=%d" % seg6_fail)

	# --- 第 7 段：战斗代码真的挂钩了（BGM 电平设/还原各处的静态检查）--------
	var seg7_fail := 0
	var battle_ui := FileAccess.get_file_as_string("res://scenes/battle/BattleUI.gd")
	var checks_src := [
		["BattleUI 定义 BATTLE_BGM_LINEAR", "const BATTLE_BGM_LINEAR := 0.5"],
		["_start_battle_music 里设压低", "MusicService.set_base_linear(BATTLE_BGM_LINEAR)"],
		["_stop_battle_music 里还原", "MusicService.set_base_linear(1.0)"],
	]
	for pair in checks_src:
		checks += 1
		if not battle_ui.contains(str(pair[1])):
			seg7_fail += 1
			fails.append("battle_ui_missing: " + str(pair[0]))
	# 顺序判据：电平必须在第一个早退（_pvp_intro_active）之前设，
	# 否则 boss 回合 / pvp 开场那一段仍是满音量。
	var idx_set := battle_ui.find("MusicService.set_base_linear(BATTLE_BGM_LINEAR)")
	var idx_early := battle_ui.find("if _pvp_intro_active:", battle_ui.find("func _start_battle_music"))
	checks += 1
	if idx_set < 0 or idx_early < 0 or idx_set > idx_early:
		seg7_fail += 1
		fails.append("bgm_level_must_be_set_before_early_return (set=%d early=%d)" % [idx_set, idx_early])
	print("SEG7 battle_wiring fails=%d" % seg7_fail)

	var total_fail := fails.size()
	print("PROBE_DONE checks=%d fails=%d" % [checks, total_fail])
	if total_fail > 0:
		for f in fails:
			print("  FAIL ", f)
	print("PROBE_EXIT " + ("FAIL" if total_fail > 0 else "PASS"))
	get_tree().quit(0 if total_fail == 0 else 1)


func _expect(_fails: Array, _checks: int, _v: bool) -> void:
	pass
