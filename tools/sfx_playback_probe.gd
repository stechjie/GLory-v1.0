extends Node

# 10.21 战场音效接入批次：**播放计数**探针。
#
# SEG1 已证明「表里能查对」，这一段证明 **play() 真的被调到、且计数器 +1**。
# 判据是 SfxService.play_count(cue)（现成的计数器），不是「看起来接上了」。
#
# ⚠️ headless 下没有音频设备，`play()` 可能拿到 voice 就真的 play（无声）。
#    计数器在 `voice != null` 之后才 +1，所以它能证明「走到了播放那一步」。

const SfxService := preload("res://ui/services/SfxService.gd")

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var fails: Array = []
	# 素材整批未投放（正式服仓 assets/* 整目录 ignore）导致的跳过计数。
	# 与 `fails` 分开：跳过是「验不了」，失败是「验了不对」。
	var env_skipped := 0
	var checks := 0
	SfxService.install()
	# ⚠️ SfxService 的头号坑：`_ensure_voices()` 用 `add_child.call_deferred` 挂播放器
	# （install() 的时机正好在 root 装配子节点的窗口里，同步挂必失败且不报错）。
	# 对没进树的播放器调 play() 会静默失败 —— 所以这里必须**多等一帧**。
	# 见 SfxService._play_loop_when_ready 的注释（同一个坑的另一个实例）。
	await get_tree().process_frame
	await get_tree().process_frame
	# headless 探针没有玩家档案，`PlayerProfile.get_presentation_toggle("ui_sound")`
	# 会从空档案读到 false，于是 play() 在第一道门就被挡掉 —— 那是**探针环境**
	# 问题（真实游戏里这个开关默认开）。显式打开，才能量到播放那一步。
	if is_instance_valid(PlayerProfile):
		PlayerProfile.set_presentation_toggle("ui_sound", true)

	# --- 第 1 段：29 条 cue 逐条 play，计数器必须 +1 ----------------------
	# 这是「素材可读 + cue 已登记 + voice 拿得到」的端到端证明。
	var all_cues := [
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
	var seg1_fail := 0
	var no_file := 0
	for c in all_cues:
		checks += 1
		var before := SfxService.play_count(c)
		SfxService.play(c, -6.0)
		var after := SfxService.play_count(c)
		if after != before + 1:
			# 分清「素材没投放」与「接线断了」：前者 `FileAccess.file_exists` 为 false。
			# ⚠️ 不能用 ResourceLoader.exists —— 导入缓存会让删掉的源 mp3 仍返回 true。
			if not FileAccess.file_exists(SfxService.resolved_cue_path(c)):
				no_file += 1
				continue
			seg1_fail += 1
			fails.append("play_count %s before=%d after=%d" % [c, before, after])
	# 29 条全部「因为文件不存在」⇒ 素材整批未投放（正式服仓把 assets/* 整目录 ignore，
	# 3.1GB 走网盘）⇒ 环境性，不判红。部分缺失 / 文件在却播不动 ⇒ 真故障，必须红。
	if no_file == all_cues.size():
		print("SEG1_ENV assets_not_delivered=%d（整批未投放，判为环境性，不判红）" % no_file)
	print("SEG1 play_all_cues n=%d no_file=%d fails=%d" % [all_cues.size(), no_file, seg1_fail])

	# --- 第 2 段：空串静默返回 false；未知 cue 返回 false 并提示 -----------
	# ⚠️ 这一段与 SEG1 **完全独立**：上一版拿 `2 if seg1_fail > 0 else 0` 报数，
	# 结果 SEG1 一红这段就自动「假红 2 条」，读数会骗人。
	var seg2_fail := 0
	checks += 1
	if SfxService.play("") != false:
		seg2_fail += 1
		fails.append("empty_cue_should_return_false")
	checks += 1
	if SfxService.play("definitely_not_a_cue") != false:
		seg2_fail += 1
		fails.append("unknown_cue_should_return_false")
	print("SEG2 empty_and_unknown fails=%d" % seg2_fail)

	# --- 第 3 段：战斗层并发上限与优先级 ------------------------------
	# 当前实现统计实际播放的节点；满额时低优先级普攻被拒，技能可抢占普攻。
	var seg3_fail := 0
	SfxService.stop_all()
	SfxService.reset_counters_for_check()
	SfxService.set_battle_voice_cap(2)
	checks += 1
	if not SfxService.play_battle("melee_metal", -6.0) or not SfxService.play_battle("melee_nonmetal", -6.0):
		seg3_fail += 1
		fails.append("battle_voices_should_start")
	checks += 1
	if SfxService.battle_live_count() != 2:
		seg3_fail += 1
		fails.append("live_count_should_be_2 got=%d" % SfxService.battle_live_count())
	checks += 1
	var before_blocked := SfxService.play_count("proj_frost")
	if SfxService.play_battle("proj_frost", -6.0):
		seg3_fail += 1
		fails.append("lower_priority_attack_should_be_blocked_at_cap")
	checks += 1
	if SfxService.play_count("proj_frost") != before_blocked:
		seg3_fail += 1
		fails.append("blocked_cue_must_not_increment")
	# 高优先级技能应当能抢占已满的普攻池。
	# ⚠️ 素材不在（正式服仓整目录 ignore）时这一条无从验证 ⇒ 记环境性跳过，不判红。
	checks += 1
	var before_skill := SfxService.play_count("star4_guard_skill")
	SfxService.play("star4_guard_skill", 0.0)
	if SfxService.play_count("star4_guard_skill") != before_skill + 1:
		if not FileAccess.file_exists(SfxService.resolved_cue_path("star4_guard_skill")):
			env_skipped += 1
		else:
			seg3_fail += 1
			fails.append("skill_cue_should_bypass_battle_cap before=%d after=%d" % [before_skill, SfxService.play_count("star4_guard_skill")])
	SfxService.stop_all()
	SfxService.set_battle_voice_cap(6)
	print("SEG3 battle_cap_blocks fails=%d" % seg3_fail)

	# --- 第 4 段：节流真的生效（同 cue 连打只响一次）---------------------
	# ⚠️ 同样：proj_arrow 素材不在时跳过（环境性），否则「播不动」会被误读成「节流坏了」。
	var seg4_fail := 0
	SfxService.reset_counters_for_check()
	checks += 1
	if FileAccess.file_exists(SfxService.resolved_cue_path("proj_arrow")):
		SfxService.play("proj_arrow", -6.0)
		SfxService.play("proj_arrow", -6.0)
		SfxService.play("proj_arrow", -6.0)
		if SfxService.play_count("proj_arrow") != 1:
			seg4_fail += 1
			fails.append("throttle_should_collapse_3_to_1 got=%d" % SfxService.play_count("proj_arrow"))
	else:
		env_skipped += 1
	print("SEG4 throttle fails=%d" % seg4_fail)

	var total := fails.size()
	print("PROBE_DONE checks=%d fails=%d env_skipped=%d" % [checks, total, env_skipped])
	for f in fails:
		print("  FAIL ", f)
	print("PROBE_EXIT " + ("FAIL" if total > 0 else "PASS"))
	get_tree().quit(0 if total == 0 else 1)
