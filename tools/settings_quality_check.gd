extends Node

# 门禁：设置页的**画质三档**与**四个演出/无障碍开关**是否真的生效、前后差在哪。
#
# 覆盖两件用户直接问的事：
#   1) 「流畅 / 平衡 / 高画质」切换是否真实有效 —— 三档到底改了哪些数值。
#   2) 「命中闪光 / 命中顿帧 / 降低动态效果」开关前后的区别 —— 而且是**行为级**的
#      （真的调 play_hitstop / play_screen_shake 看有没有生效），不是只读开关值。
#
# 本项目现有 `ui_component_check` 只验了 reduced_motion 的「设置→Tokens」这一段；
# 画质三档、闪光、顿帧、屏震的**差异矩阵**此前没有任何门禁覆盖。
#
# ⚠️ 磁盘自毒纪律（见项目长期笔记「门禁读写持久化状态 = 自毒」）：
#   本探针会写 `user://profile.json`（切开关）与 `user://glory_quality_tier.txt`（切档）。
#   收尾**整块还原磁盘原文**（先读原字节，结束时贴回；原本不存在就删掉），
#   不是"把内存迁就成读到的值"。
const SettingsScene := preload("res://scenes/menu/SettingsScreen.tscn")
const QUALITY := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")

const PREF_PATH := "user://glory_quality_tier.txt"
const PROFILE_PATH := "user://profile.json"
const PROFILE_BAK := "user://profile.json.bak"
const PROFILE_TMP := "user://profile.json.tmp"

const PROFILE_DIR := "res://data/vfx/battle_cues/"
const PROFILE_IDS := ["basic_melee", "basic_ranged", "crit", "heal", "death"]

const TIER_NAMES := {0: "流畅(LOW)", 1: "平衡(MEDIUM)", 2: "高画质(HIGH)"}

var _fail := 0
var _checks := 0
var _findings: Array[String] = []

var _snap: Dictionary = {}
var _saved_tier := 1
var _saved_toggles: Dictionary = {}
var _saved_locale := "zh"


func _ready() -> void:
	_snapshot_disk()
	_saved_tier = VFXManager.get_quality_tier()
	for key in ["screen_shake", "flash_effects", "hit_stop", "reduced_motion"]:
		_saved_toggles[key] = PlayerProfile.get_presentation_toggle(key)
	_saved_locale = LocaleManager.get_locale()
	LocaleManager.set_locale("zh")
	await _settle()

	await _check_tier_enum()
	await _check_tier_pref_file()
	await _check_tier_boot_restore()
	await _check_tier_auto_default()
	_check_budget_matrix()
	_check_profile_overrides()
	await _check_ui_live()
	_check_flash()
	_check_hitstop()
	_check_shake()
	_check_reduced_motion()
	_check_reduced_motion_consumers()

	LocaleManager.set_locale(_saved_locale)
	await _restore()

	print("")
	if _fail == 0:
		print("CHECK_RESULT status=PASS checked=%d failures=0" % _checks)
	else:
		print("CHECK_RESULT status=FAIL checked=%d failures=%d" % [_checks, _fail])
	for line in _findings:
		print("FINDING %s" % line)
	print("PROBE_DONE")
	get_tree().quit(0 if _fail == 0 else 1)


# --- 画质档位 -----------------------------------------------------------------

func _check_tier_enum() -> void:
	# SettingsScreen 的按钮高亮是 `i == current` 直接拿索引比档位值的，
	# 所以三个档位值必须是 0/1/2 —— 这条不成立时高亮会静默错位。
	_expect(QUALITY.Tier.LOW, 0, "tier_enum_low_is_zero")
	_expect(QUALITY.Tier.MEDIUM, 1, "tier_enum_medium_is_one")
	_expect(QUALITY.Tier.HIGH, 2, "tier_enum_high_is_two")
	_expect(QUALITY.Tier.size(), 3, "tier_enum_has_three_tiers")


func _check_tier_pref_file() -> void:
	for tier in [0, 1, 2]:
		VFXManager.set_quality_pref(tier)
		await _settle()
		_expect(VFXManager.get_quality_tier(), tier, "set_quality_pref_applies_%s" % TIER_NAMES[tier])
		_expect(_read_text(PREF_PATH), str(tier), "quality_pref_persisted_%s" % TIER_NAMES[tier])


func _check_tier_boot_restore() -> void:
	# 模拟重启：把内存档位打乱，再走一次启动期的 _detect_quality_tier()。
	for tier in [0, 1, 2]:
		VFXManager.set_quality_pref(tier)
		QUALITY.tier = 2 if tier != 2 else 0
		VFXManager._detect_quality_tier()
		_expect(VFXManager.get_quality_tier(), tier,
			"boot_restores_saved_tier_%s" % TIER_NAMES[tier])


func _check_tier_auto_default() -> void:
	# 从没手选过（文件不存在）：桌面走 HIGH，安卓按内存分档。
	_delete_file(PREF_PATH)
	VFXManager._detect_quality_tier()
	var expected: int = 2 if not OS.has_feature("mobile") else -1
	if expected < 0:
		print("  SKIP no_manual_pick_default（移动端按内存分档，本机不适用）")
	else:
		_expect(VFXManager.get_quality_tier(), expected, "no_manual_pick_defaults_high_on_desktop")
	# 文件确实被删掉了才算测到「没选过」这条路。
	_expect(FileAccess.file_exists(PREF_PATH), false, "auto_default_leaves_no_pref_file")


func _check_budget_matrix() -> void:
	# 用超出所有上限的基准值，量出来的是纯上限本身。
	var base := 1000
	var rows := {}
	for tier in [0, 1, 2]:
		QUALITY.tier = tier
		rows[TIER_NAMES[tier]] = {
			"allow_dynamic_light": QUALITY.allow_dynamic_light(),
			"flipbook_frame_limit": QUALITY.flipbook_frame_limit(base),
			"distortion_layers": QUALITY.distortion_layers(base),
			"max_simultaneous_effects": QUALITY.max_simultaneous_effects(),
			"max_aoe_targets": QUALITY.max_aoe_targets(base),
			"max_particles_per_effect": QUALITY.max_particles_per_effect(),
			"particle_count": QUALITY.particle_count(base),
			"auxiliary_layers": QUALITY.auxiliary_layers(base),
			"shader_octaves": QUALITY.shader_octaves(base),
			"cues_per_tick_important": QUALITY.max_cues_per_tick("important"),
			"cues_per_tick_ambient": QUALITY.max_cues_per_tick("ambient"),
			"live_cues_important": QUALITY.max_live_cues("important"),
			"live_cues_ambient": QUALITY.max_live_cues("ambient"),
			"ambient_merge_window_ms": QUALITY.ambient_merge_window_ms(),
			"priority_cost_important": QUALITY.priority_cost_scale("important"),
			"priority_cost_ambient": QUALITY.priority_cost_scale("ambient"),
		}
	print("BUDGET_DUMP %s" % JSON.stringify(rows))

	# 单调性：三档必须真的分了层（低 ≤ 中 ≤ 高），否则「平衡」形同虚设
	# ——这种"档位不分层"的 bug 在 VFXQualityBudget 的注释里被记过一次。
	var mono_keys := ["flipbook_frame_limit", "distortion_layers", "max_simultaneous_effects",
		"max_aoe_targets", "max_particles_per_effect", "particle_count", "auxiliary_layers",
		"shader_octaves", "cues_per_tick_important", "cues_per_tick_ambient",
		"live_cues_important", "live_cues_ambient"]
	for key in mono_keys:
		var low: int = int(rows[TIER_NAMES[0]][key])
		var med: int = int(rows[TIER_NAMES[1]][key])
		var high: int = int(rows[TIER_NAMES[2]][key])
		_expect(low <= med and med <= high, true, "budget_monotonic_%s" % key)

	# 合并窗口是**反向**的：越大越省，所以低档窗口必须最宽。
	var w_low: int = int(rows[TIER_NAMES[0]]["ambient_merge_window_ms"])
	var w_med: int = int(rows[TIER_NAMES[1]]["ambient_merge_window_ms"])
	var w_high: int = int(rows[TIER_NAMES[2]]["ambient_merge_window_ms"])
	_expect(w_low >= w_med and w_med >= w_high, true, "merge_window_wider_when_cheaper")

	# 以 HIGH 为基准（美术原始数量），高画质不得放大。
	QUALITY.tier = QUALITY.Tier.HIGH
	_expect(QUALITY.particle_count(base), base, "high_tier_is_reference_not_inflated")
	_expect(QUALITY.max_aoe_targets(base), base, "high_tier_aoe_not_capped")
	_expect(QUALITY.auxiliary_layers(base), base, "high_tier_aux_not_capped")
	_expect(QUALITY.shader_octaves(base), base, "high_tier_octaves_not_capped")
	# 关键 cue 在任何档都不受限 —— 「绝不丢 Boss/死亡/控制提示」这条硬规矩。
	for tier in [0, 1, 2]:
		QUALITY.tier = tier
		_expect(QUALITY.max_cues_per_tick("critical"), -1, "critical_cues_uncapped_%s" % TIER_NAMES[tier])
		_expect(QUALITY.max_live_cues("critical"), -1, "critical_live_uncapped_%s" % TIER_NAMES[tier])
		_expect(QUALITY.recovery_scale_when_over_budget("critical"), 1.0,
			"critical_keeps_full_recovery_%s" % TIER_NAMES[tier])


func _check_profile_overrides() -> void:
	# 画质档还会改**每个 cue 档案**的时长/镜头/并发（BattleCueProfile.quality_overrides）。
	var with_override := 0
	for id in PROFILE_IDS:
		var path := "%s%s.tres" % [PROFILE_DIR, id]
		var profile: BattleCueProfile = load(path)
		if profile == null:
			_expect(type_of(profile), 0, "cue_profile_loads_%s" % id)
			continue
		var low: Dictionary = profile.resolved_for_tier("LOW")
		var med: Dictionary = profile.resolved_for_tier("MEDIUM")
		var high: Dictionary = profile.resolved_for_tier("HIGH")
		print("PROFILE_DUMP id=%s base_max_concurrent=%d base_recovery_ms=%d camera=%s"
			% [id, int(high["max_concurrent"]), int(high["recovery_ms"]), str(high["camera_mode"])])
		for tier_name in ["LOW", "MEDIUM"]:
			var got: Dictionary = low if tier_name == "LOW" else med
			var diff := {}
			for key in ["max_concurrent", "windup_ms", "impact_ms", "recovery_ms", "camera_mode"]:
				if str(got[key]) != str(high[key]):
					diff[key] = "%s -> %s" % [str(high[key]), str(got[key])]
			if not diff.is_empty():
				print("PROFILE_DIFF tier=%s id=%s %s" % [tier_name, id, JSON.stringify(diff)])
				if tier_name == "LOW":
					with_override += 1
		# 中档可以等于高档，但**不能比高档还贵**（"overrides may only make a cue cheaper"）。
		_expect(int(low["max_concurrent"]) <= int(med["max_concurrent"]), true,
			"cue_profile_concurrency_monotonic_%s" % id)
		_expect(int(low["recovery_ms"]) <= int(med["recovery_ms"]), true,
			"cue_profile_recovery_monotonic_%s" % id)
	_expect(with_override > 0, true, "at_least_one_profile_differs_on_low_tier")


# --- 设置页端到端（真场景） ---------------------------------------------------

func _check_ui_live() -> void:
	var screen := SettingsScene.instantiate()
	add_child(screen)
	await _settle()

	var btns: Array[Button] = screen._quality_btns
	_expect(btns.size(), 3, "settings_has_three_quality_buttons")
	if btns.size() != 3:
		screen.queue_free()
		return

	# 选中的那个按钮会带 ✓ 前缀（不靠颜色单独表达状态）。
	var texts: Array = []
	for btn in btns:
		texts.append(btn.text)
	print("UI_QUALITY_LABELS %s" % str(texts))
	var bare: Array = []
	for t in texts:
		bare.append(str(t).trim_prefix("✓ "))
	_expect(bare[0], "流畅", "quality_button_0_is_smooth")
	_expect(bare[1], "平衡", "quality_button_1_is_balanced")
	_expect(bare[2], "高画质", "quality_button_2_is_high")

	# 逐个点真按钮，断言档位**当场**落地并落盘。
	for i in [0, 1, 2]:
		btns[i].pressed.emit()
		await _settle()
		_expect(VFXManager.get_quality_tier(), i, "click_quality_button_%d_applies" % i)
		_expect(_read_text(PREF_PATH), str(i), "click_quality_button_%d_persists" % i)
		# 高亮唯一：只有点击的那个带 ✓
		var marked: Array = []
		for j in btns.size():
			if btns[j].text.begins_with("✓ "):
				marked.append(j)
		_expect(str(marked), str([i]), "click_quality_button_%d_marks_only_itself" % i)

	# 开关端到端：点真 CheckButton，看 PlayerProfile 与裁决层是否跟着变。
	var flash_btn: CheckButton = screen._presentation_btns.get("flash_effects")
	if flash_btn == null:
		_expect(false, true, "settings_has_flash_toggle")
	else:
		var want := not flash_btn.button_pressed
		flash_btn.button_pressed = want
		await _settle()
		_expect(PlayerProfile.get_presentation_toggle("flash_effects"), want,
			"click_flash_toggle_updates_profile")
		_expect(Presentation.flash_allowed(), want, "click_flash_toggle_updates_ruling")

	screen.queue_free()
	await _settle()


# --- 命中闪光 -----------------------------------------------------------------

func _check_flash() -> void:
	# 关闭开关：任何画质档都不许闪。
	PlayerProfile.set_presentation_toggle("flash_effects", false)
	for tier in [0, 1, 2]:
		QUALITY.tier = tier
		_expect(Presentation.flash_allowed(), false, "flash_off_blocks_%s" % TIER_NAMES[tier])

	# 打开开关：中/高画质允许，**低画质仍然不许** —— 这是低档唯一的"强行关掉"。
	PlayerProfile.set_presentation_toggle("flash_effects", true)
	QUALITY.tier = QUALITY.Tier.LOW
	_expect(Presentation.flash_allowed(), false, "flash_low_tier_forces_off")
	QUALITY.tier = QUALITY.Tier.MEDIUM
	_expect(Presentation.flash_allowed(), true, "flash_medium_tier_allows")
	QUALITY.tier = QUALITY.Tier.HIGH
	_expect(Presentation.flash_allowed(), true, "flash_high_tier_allows")

	# ⚠ FINDING：开关显示"开"，实际不闪。设置页的 CheckButton 读的是 PlayerProfile，
	# 而裁决层还叠了画质档 —— 于是「流畅」档下开关与效果不一致，玩家会以为开关坏了。
	QUALITY.tier = QUALITY.Tier.LOW
	PlayerProfile.set_presentation_toggle("flash_effects", true)
	var switch_state := PlayerProfile.get_presentation_toggle("flash_effects")
	var effective := Presentation.flash_allowed()
	if switch_state and not effective:
		_findings.append(
			"flash_switch_lies_on_low_tier 设置页「命中闪光」显示为开，但 tier=流畅 时 flash_allowed()=false，实际不闪（切回平衡/高画质又自己亮起来）")


# --- 命中顿帧 -----------------------------------------------------------------

func _check_hitstop() -> void:
	# 行为级：真的调 play_hitstop，看 VFXManager 认不认。
	PlayerProfile.set_presentation_toggle("hit_stop", false)
	VFXManager._hitstop_until_msec = 0
	VFXManager.play_hitstop(0.2)
	_expect(VFXManager.is_hitstop_active(), false, "hitstop_off_blocks_play_call")

	PlayerProfile.set_presentation_toggle("hit_stop", true)
	VFXManager._hitstop_until_msec = 0
	VFXManager.play_hitstop(0.2)
	_expect(VFXManager.is_hitstop_active(), true, "hitstop_on_allows_play_call")

	# 顿帧不随画质档降级：它不花性能，降它只会让打击感变差（设计决定，这里钉住）。
	for tier in [0, 1, 2]:
		QUALITY.tier = tier
		_expect(Presentation.hit_stop_allowed(), true, "hitstop_unaffected_by_tier_%s" % TIER_NAMES[tier])
	VFXManager._hitstop_until_msec = 0


# --- 屏震（同组，用户没点名但和上面两个共用裁决层）----------------------------

func _check_shake() -> void:
	PlayerProfile.set_presentation_toggle("screen_shake", false)
	_expect(Presentation.screen_shake_scale(), 0.0, "shake_off_scale_is_zero")
	VFXManager._shake_strength = 0.0
	VFXManager._shake_until_msec = 0
	VFXManager.play_screen_shake(1.0, 0.3)
	_expect(VFXManager._shake_strength, 0.0, "shake_off_does_not_register")

	PlayerProfile.set_presentation_toggle("screen_shake", true)
	QUALITY.tier = QUALITY.Tier.LOW
	_expect(Presentation.screen_shake_scale(), 0.6, "shake_low_tier_scaled_to_60pct")
	VFXManager._shake_strength = 0.0
	VFXManager._shake_until_msec = 0
	VFXManager.play_screen_shake(1.0, 0.3)
	_expect(snappedf(VFXManager._shake_strength, 0.01), 0.6, "shake_low_tier_amplitude_actually_scaled")

	QUALITY.tier = QUALITY.Tier.MEDIUM
	_expect(Presentation.screen_shake_scale(), 1.0, "shake_medium_tier_full")
	QUALITY.tier = QUALITY.Tier.HIGH
	_expect(Presentation.screen_shake_scale(), 1.0, "shake_high_tier_full")
	VFXManager._shake_strength = 0.0
	VFXManager._shake_until_msec = 0


# --- 降低动态效果 -------------------------------------------------------------

func _check_reduced_motion() -> void:
	PlayerProfile.set_presentation_toggle("reduced_motion", false)
	_expect(Tokens.reduced_motion(), false, "reduced_motion_off_reads_false")
	_expect(Tokens.motion(0.5), 0.5, "motion_passthrough_when_off")

	PlayerProfile.set_presentation_toggle("reduced_motion", true)
	_expect(PlayerProfile.get_presentation_toggle("reduced_motion"), true, "reduced_motion_persists_in_profile")
	# 它必须同步进 ProjectSettings —— GloryTokens 是 static，拿不到 autoload。
	_expect(ProjectSettings.get_setting(PlayerProfile.REDUCED_MOTION_SETTING), true,
		"reduced_motion_syncs_project_settings")
	_expect(Tokens.reduced_motion(), true, "reduced_motion_reader_agrees")
	_expect(Tokens.motion(0.5), 0.0, "motion_zeroed_when_on")

	PlayerProfile.set_presentation_toggle("reduced_motion", false)
	_expect(Tokens.motion(0.5), 0.5, "motion_restored_when_off_again")


func _check_reduced_motion_consumers() -> void:
	# 光是开关能读还不够 —— 得真的有消费点，否则等于没接上。
	var sources := [
		"res://ui/services/UiFeedback.gd",
		"res://ui/components/GloryLoadingOverlay.gd",
		"res://scripts/tutorial/TutorialMode.gd",
	]
	var hits := 0
	for path in sources:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var text := f.get_as_text()
		f.close()
		if text.contains("Tokens.reduced_motion()") or text.contains("reduced_motion"):
			hits += 1
	_expect(hits, sources.size(), "reduced_motion_has_live_consumers")


# --- 磁盘快照 / 还原 ----------------------------------------------------------

func _snapshot_disk() -> void:
	for path in [PROFILE_PATH, PROFILE_BAK, PROFILE_TMP, PREF_PATH]:
		_snap[path] = _read_bytes(path)


func _restore() -> void:
	# 1) 磁盘整块还原：原本有的贴回原字节，原本没有的删掉。
	for path in _snap.keys():
		var original = _snap[path]
		if original == null:
			_delete_file(path)
		else:
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f != null:
				f.store_buffer(original)
				f.close()
	# 2) 内存也摆回原值（进程接下来还要被别的检查用）。
	VFXManager.set_quality_tier(_saved_tier)
	for key in _saved_toggles.keys():
		PlayerProfile.set_presentation_toggle(key, bool(_saved_toggles[key]))
	PlayerProfile.set_presentation_toggle("reduced_motion", bool(_saved_toggles["reduced_motion"]))
	# 3) 自证：还原后再贴一次原字节，覆盖 set_presentation_toggle 刚才的落盘。
	for path in _snap.keys():
		var original = _snap[path]
		if original == null:
			_delete_file(path)
		else:
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f != null:
				f.store_buffer(original)
				f.close()
	_expect(_read_text(PREF_PATH), _snap_text(PREF_PATH), "disk_restored_quality_pref")
	_expect(_profile_digest(), _snap_digest(), "disk_restored_profile")


func _snap_text(path: String) -> String:
	var buf = _snap.get(path)
	if buf == null:
		return ""
	return (buf as PackedByteArray).get_string_from_utf8().strip_edges()


func _snap_digest() -> String:
	var buf = _snap.get(PROFILE_PATH)
	if buf == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf)
	return ctx.finish().hex_encode()


func _profile_digest() -> String:
	var buf = _read_bytes(PROFILE_PATH)
	if buf == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf)
	return ctx.finish().hex_encode()


func _read_bytes(path: String):
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var buf := f.get_buffer(f.get_length())
	f.close()
	return buf


func _read_text(path: String) -> String:
	var buf = _read_bytes(path)
	if buf == null:
		return ""
	return (buf as PackedByteArray).get_string_from_utf8().strip_edges()


func _delete_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _settle() -> void:
	for i in 4:
		await get_tree().process_frame


func _expect(got, want, label: String) -> void:
	_checks += 1
	var ok: bool = got == want
	if not ok:
		_fail += 1
	print("  %s %-52s got=%s want=%s" % ["PASS" if ok else "FAIL", label, str(got), str(want)])
