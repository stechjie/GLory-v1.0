extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BootstrapScript := preload("res://scenes/bootstrap/Bootstrap.gd")
const BootstrapScene := preload("res://scenes/bootstrap/Bootstrap.tscn")
const CHECK_NAME := "bootstrap"
const FIXTURE_PATH := "res://tools/fixtures/BootstrapTarget.tscn"
const MISSING_PATH := "res://tools/fixtures/BootstrapTargetMissing.tscn"  # asset-manifest-ignore

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_project_and_dependency_contract()
	_check_phase_honesty_and_ownership()
	_check_splash_continuity()
	await _check_success_path()
	await _check_failure_and_retry()
	await _check_watchdog_escalation()
	await _check_watchdog_resets_on_progress()
	_check_entry_gate_view()
	await _check_entry_phase_is_not_watchdogged()
	_h.finish(get_tree())


func _check_project_and_dependency_contract() -> void:
	var project := FileAccess.get_file_as_string("res://project.godot")
	var source := FileAccess.get_file_as_string("res://scenes/bootstrap/Bootstrap.gd")
	var scene_text := FileAccess.get_file_as_string("res://scenes/bootstrap/Bootstrap.tscn")
	var export_template := FileAccess.get_file_as_string("res://export_presets.template.cfg")
	_h.expect(project.contains('run/main_scene="res://scenes/bootstrap/Bootstrap.tscn"'),
		"bootstrap_not_main", "project.godot 的主场景不是 Bootstrap")
	_h.expect(project.contains('boot_splash/image="res://ui/branding/glory_bootstrap.png"'),
		"project_splash_missing", "项目 boot splash 没有使用现有 Glory 图标")
	_h.expect(export_template.contains('splash_screen/icon="res://ui/branding/glory_bootstrap.png"')
		and export_template.contains('splash_screen/branding_image="res://ui/branding/glory_bootstrap.png"'),
		"android_splash_missing", "Android 模板没有接入同一 Glory 品牌图标")
	for forbidden in ["assets/models", "effects/vfx", "Node3D", "SubViewport", "GPUParticles"]:
		_h.expect(not source.contains(forbidden) and not scene_text.contains(forbidden),
			"heavy_bootstrap_dependency", "Bootstrap 引用了禁止的重依赖：%s" % forbidden)
	_h.expect(scene_text.contains('path="res://ui/branding/glory_bootstrap.png"'),
		"unapproved_brand_asset", "Bootstrap 没有复用由现有 icon.svg 转出的品牌 PNG")
	_h.expect(source.contains("load_threaded_request") and source.contains("load_threaded_get_status"),
		"main_load_not_threaded", "Main 不是通过 ResourceLoader 线程请求加载")
	_h.expect(source.contains("await RenderingServer.frame_post_draw"),
		"load_before_first_frame", "Bootstrap 没有等首帧显示就开始载入 Main")
	_h.expect(source.contains("func retry()") and source.contains("func exit_app()"),
		"failure_actions_missing", "启动失败没有重试/退出入口")


func _new_bootstrap(path: String) -> BootstrapScript:
	var bootstrap := BootstrapScene.instantiate() as BootstrapScript
	bootstrap.auto_start = false
	bootstrap.auto_transition = false
	# 进门那一步要真的去登录、连账号后端。这里测的是线程载入本身，关掉它；
	# 进门的判定另由 _check_entry_gate_view 用纯函数测。
	bootstrap.entry_gate = false
	bootstrap.next_scene_path = path
	add_child(bootstrap)
	return bootstrap


func _check_success_path() -> void:
	var bootstrap := _new_bootstrap(FIXTURE_PATH)
	await get_tree().process_frame
	bootstrap.start_loading()
	var loaded := await _wait_for_phase(bootstrap, "READY")
	_h.expect(loaded, "success_never_ready", "轻量目标场景没有完成线程加载")
	var snap := bootstrap.snapshot()
	_h.expect(bool(snap.get("loaded", false)), "success_resource_missing", "READY 时没有 PackedScene")
	_h.expect(is_equal_approx(float(snap.get("progress", 0.0)), 1.0),
		"success_progress_incomplete", "READY 时进度不是 100%")
	_h.expect(not bool(snap.get("error_visible", true)),
		"success_error_visible", "成功路径仍显示错误操作")
	bootstrap.queue_free()
	await get_tree().process_frame


func _check_failure_and_retry() -> void:
	var bootstrap := _new_bootstrap(MISSING_PATH)
	await get_tree().process_frame
	bootstrap.start_loading()
	var failed := await _wait_for_phase(bootstrap, "FAILED")
	_h.expect(failed, "missing_scene_not_failed", "缺失 Main 没有进入 FAILED")
	var failed_snap := bootstrap.snapshot()
	_h.expect(bool(failed_snap.get("error_visible", false)),
		"failure_actions_hidden", "失败后重试/退出操作没有显示")
	_h.expect(str(failed_snap.get("error_text", "")).contains("BOOT-MAIN-LOAD"),
		"failure_code_missing", "失败页没有稳定短错误码")

	bootstrap.next_scene_path = FIXTURE_PATH
	bootstrap.retry()
	var recovered := await _wait_for_phase(bootstrap, "READY")
	_h.expect(recovered, "retry_never_ready", "修正路径后 Retry 没有恢复")
	var recovered_snap := bootstrap.snapshot()
	_h.expect(bool(recovered_snap.get("loaded", false)),
		"retry_resource_missing", "Retry 完成但没有 PackedScene")
	bootstrap.queue_free()
	await get_tree().process_frame


func _wait_for_phase(bootstrap: BootstrapScript, wanted: String) -> bool:
	for _frame in 180:
		if not is_instance_valid(bootstrap):
			return false
		var snap := bootstrap.snapshot()
		if str(snap.get("phase_name", "")) == wanted:
			return true
		await get_tree().process_frame
	return false


# V3 P0-02 §6.1：Bootstrap 只能声明它真正执行的阶段。
#
# 任务书要求"补齐真正发生的存档/profile 恢复阶段；不得只显示一个假的『恢复存档』
# 字符串"。审计时发现前半句的前提不成立：PlayerProfile 是 autoload，排在
# [autoload] 第 5 位，它的 _ready() 直接读 user://profile.json —— 而 Godot 要等
# **所有 autoload 构造完**才加载第一个场景。也就是说 profile 恢复在 Bootstrap
# 画出第一帧之前就已经完成了。
#
# 所以照字面加一个"恢复存档"阶段，只能是假阶段 —— 正是同一句话禁止的东西。
# 这里改为把责任边界钉死：
#   * Bootstrap 不得自己读 profile / 存档（那会变成重复读档）
#   * Bootstrap 不得声明它没有执行的阶段
#
# 真正的选项是把 PlayerProfile 改成惰性、由 Bootstrap 显式驱动并显示真实阶段，
# 但那会改变启动时序并影响所有调用点，属于需要用户批准的改动，本批不做。
func _check_phase_honesty_and_ownership() -> void:
	var source := FileAccess.get_file_as_string("res://scenes/bootstrap/Bootstrap.gd")
	if not _h.expect(not source.is_empty(), "bootstrap_unreadable", "读不到 Bootstrap.gd"):
		return

	# 责任边界：读档不归 Bootstrap。
	for forbidden in ["PlayerProfile.load_profile", "SaveManager.load_run",
			"SaveManager.load_tutorial", "PlayerProfile.save_profile"]:
		_h.expect(not source.contains(forbidden),
			"bootstrap_reads_save",
			("Bootstrap 调用了 %s —— profile 在 autoload 阶段已经读过，"
				+ "这里再读一次是重复读档；存档归 Main/SaveManager") % forbidden)

	# 阶段诚实：每个 Phase 枚举值都必须有对应的 _set_phase 调用，
	# 否则就是一个声明了却从不进入的阶段。
	var enum_at := source.find("enum Phase {")
	if not _h.expect(enum_at >= 0, "phase_enum_missing", "找不到 Phase 枚举"):
		return
	var enum_end := source.find("}", enum_at)
	var enum_body := source.substr(enum_at, enum_end - enum_at)
	for raw in enum_body.trim_prefix("enum Phase {").split(","):
		var phase_name := raw.strip_edges()
		if phase_name.is_empty():
			continue
		_h.expect(source.contains("Phase.%s" % phase_name),
			"phase_declared_but_unused",
			"Phase.%s 声明了但没有任何地方进入它 —— 声明一个不发生的阶段就是假阶段" % phase_name)

	# 不得出现只有文案没有动作的"恢复存档"类阶段。
	for fake in ["恢复存档", "Restoring save", "读取存档", "Loading save"]:
		_h.expect(not source.contains(fake),
			"fake_restore_phase",
			("Bootstrap 显示了「%s」，但它并不执行读档 —— "
				+ "profile 在 autoload 阶段已完成，这个阶段是假的") % fake)


# V3 P0-02 §6.1：系统 splash -> Godot splash -> Bootstrap 的背景色必须一致，
# 否则玩家会看到两次底色切换，那正是"点了没反应"观感的一部分。
#
# 三者现在确实相同，但没有任何东西保证它继续相同 —— 改其中一个是单行改动。
func _check_splash_continuity() -> void:
	var project := FileAccess.get_file_as_string("res://project.godot")
	var scene_text := FileAccess.get_file_as_string("res://scenes/bootstrap/Bootstrap.tscn")

	var splash_color := _color_after(project, "boot_splash/bg_color=")
	_h.expect(not splash_color.is_empty(), "splash_bg_missing",
		"project.godot 没有声明 boot_splash/bg_color")

	# Bootstrap 场景里第一个 ColorRect 就是全屏背景。
	var bg_at := scene_text.find("[node name=\"Background\" type=\"ColorRect\"")
	if not _h.expect(bg_at >= 0, "bootstrap_background_missing",
			"Bootstrap 场景里没有名为 Background 的 ColorRect"):
		return
	var bg_color := _color_after(scene_text.substr(bg_at), "color = ")
	_h.expect(not bg_color.is_empty(), "bootstrap_bg_unreadable",
		"读不到 Bootstrap Background 的颜色")
	_h.expect(splash_color == bg_color, "splash_bg_mismatch",
		("Godot splash 底色 %s 与 Bootstrap 背景 %s 不一致 —— "
			+ "玩家会看到一次底色跳变") % [splash_color, bg_color])

	# 横屏必须是**声明**的，不能靠引擎默认值。默认值会随引擎版本变，
	# 而"竖屏启动一瞬再转横"正是这类问题最常见的表现。
	_h.expect(project.contains("window/handheld/orientation="),
		"orientation_not_declared",
		("project.godot 没有显式声明 window/handheld/orientation —— "
			+ "横屏靠的是引擎默认值，换版本就可能变"))


# 从 "<key>Color(a, b, c, d)" 里取出规范化的数字串，用于跨文件比较。
# 两个文件的写法不同（一个有空格一个没有），所以比数字而不是比原文。
func _color_after(text: String, key: String) -> String:
	var at := text.find(key)
	if at < 0:
		return ""
	var open_paren := text.find("(", at)
	var close_paren := text.find(")", open_paren)
	if open_paren < 0 or close_paren < 0:
		return ""
	var inner := text.substr(open_paren + 1, close_paren - open_paren - 1)
	var parts := PackedStringArray()
	for piece in inner.split(","):
		parts.append("%.5f" % float(piece.strip_edges()))
	return ",".join(parts)


# V3 P0-10：启动看门狗 3 / 8 / 15 秒。
#
# 迁移前 Bootstrap 完全没有看门狗：线程载入卡住的话，玩家看到的是一张无限呼吸的
# 启动画面 —— 没有升级提示、没有解释、没有出路。
#
# 三条硬性约束都在这里查：
#   1. 只提示**真实**阶段（写死一句「正在载入」在 PREPARE_DATA 卡住时就是假话）
#   2. 不在主线程强杀（15 秒之后仍然不进 FAILED，线程载入继续跑）
#   3. 不伪造进度（看门狗一格进度条都不许推）
func _check_watchdog_escalation() -> void:
	var bootstrap := _new_bootstrap(FIXTURE_PATH)
	await get_tree().process_frame
	# 停在 LOAD_MAIN 而不真的去载：手工设阶段，然后按秒喂 delta。
	bootstrap._set_phase(BootstrapScript.Phase.LOAD_MAIN, "load", "detail", 0.12)
	# .get() 返回 Variant，:= 推不出类型（推不出来会让整个脚本编译失败，
	# 而门禁表现为挂住而不是报错）。
	var progress_before: float = bootstrap.snapshot().get("progress", -1.0)

	var levels: Array[String] = []
	var texts: Array[String] = []
	# 逐秒推进到 16 秒。每秒记一次等级，最后核对三个门槛各自的落点。
	for i in 16:
		bootstrap._tick_watchdog(1.0)
		levels.append(str(bootstrap.snapshot().get("watchdog_level_name", "")))
		texts.append(bootstrap._detail.text)

	# levels[i] 是「喂完第 i+1 秒」之后的等级。
	_h.expect(levels[1] == "QUIET", "watchdog_fires_too_early",
		"2 秒就升级了（%s）—— 正常启动会被它吵到" % levels[1])
	_h.expect(levels[2] == "NOTICE", "watchdog_notice_missed",
		"3 秒没有进入 NOTICE，实际是 %s" % levels[2])
	_h.expect(levels[7] == "EXPLAIN", "watchdog_explain_missed",
		"8 秒没有进入 EXPLAIN，实际是 %s" % levels[7])
	_h.expect(levels[14] == "STUCK", "watchdog_stuck_missed",
		"15 秒没有进入 STUCK，实际是 %s" % levels[14])

	var snap := bootstrap.snapshot()
	# 卡住 ≠ 失败。载入还在后台跑，随时可能完成 —— 主线程强杀只会把一次「慢」
	# 变成一次「坏」，而且丢掉本来能自己恢复的那条路。
	_h.expect(str(snap.get("phase_name", "")) == "LOAD_MAIN",
		"watchdog_killed_on_main_thread",
		"15 秒之后阶段变成了 %s —— 看门狗不该结束载入" % str(snap.get("phase_name", "")))
	_h.expect(bool(snap.get("stuck", false)), "watchdog_stuck_flag_missing",
		"STUCK 之后没有置 stuck 标志，重试入口打不开")
	_h.expect(bool(snap.get("error_visible", false)), "watchdog_offers_no_way_out",
		"卡住 15 秒之后没有给玩家任何出路")
	_h.expect(is_equal_approx(float(snap.get("progress", -1.0)), float(progress_before)),
		"watchdog_fakes_progress",
		"看门狗推动了进度条 —— 那是在用等待时间伪造完成度")

	# 文案必须指向真实阶段：换个阶段，同样卡住，说法必须跟着变。
	#
	# 三级各自查一次，不能只查一处。NOTICE 只用到阶段名词，EXPLAIN 多一句解释，
	# STUCK 是错误面板 —— 只查合起来的那一句时，任何一处写死都会被另一处的差异
	# 盖过去（这条断言第一版就是这么漏掉的）。
	var notice_load := texts[2]
	var explain_load := texts[7]
	var stuck_load := bootstrap._error_text.text
	bootstrap._set_phase(BootstrapScript.Phase.PREPARE_DATA, "prep", "detail", 0.08)
	var notice_prep := ""
	var explain_prep := ""
	for i in 16:
		bootstrap._tick_watchdog(1.0)
		if i == 2:
			notice_prep = bootstrap._detail.text
		elif i == 7:
			explain_prep = bootstrap._detail.text
	_h.expect(notice_prep != notice_load, "watchdog_notice_text_ignores_phase",
		"两个阶段的 3 秒提示是同一句：%s —— 阶段名词被写死了" % notice_load)
	# 只比第二行。EXPLAIN 的第一行还是阶段名词，连着比的话，解释写死了也会被
	# 名词的差异盖过去 —— 那样这条断言就成了上一条的复读，做不出能让它单独转红
	# 的变异。第二行才是它名字里说的那一句。
	_h.expect(_second_line(explain_prep) != _second_line(explain_load),
		"watchdog_explain_text_ignores_phase",
		"两个阶段的 8 秒解释是同一句「%s」—— 玩家看不出卡在哪一步"
			% _second_line(explain_load))
	_h.expect(bootstrap._error_text.text != stuck_load, "watchdog_stuck_text_ignores_phase",
		"两个阶段卡死 15 秒后的错误面板是同一句")
	_h.expect(bootstrap._error_text.text.contains(BootstrapScript.ERROR_STUCK),
		"watchdog_stuck_has_no_code", "卡住提示没有带错误码，用户报障时说不清")

	bootstrap.queue_free()
	await get_tree().process_frame


# 进度在动就不算卡住。慢不等于坏 —— 冷启动第一次解压资源本来就慢，
# 那种情况下弹「启动失败」比不弹更糟。
func _check_watchdog_resets_on_progress() -> void:
	var bootstrap := _new_bootstrap(FIXTURE_PATH)
	await get_tree().process_frame
	bootstrap._set_phase(BootstrapScript.Phase.LOAD_MAIN, "load", "detail", 0.0)
	for i in 10:
		# 每秒推进 10% —— 慢，但一直在动。
		bootstrap._progress.value = float(i + 1) * 10.0
		bootstrap._tick_watchdog(1.0)
	var snap := bootstrap.snapshot()
	_h.expect(str(snap.get("watchdog_level_name", "")) == "QUIET",
		"watchdog_ignores_progress",
		"进度一直在推进却升到了 %s —— 慢被当成了卡住"
			% str(snap.get("watchdog_level_name", "")))
	_h.expect(not bool(snap.get("stuck", false)), "watchdog_stuck_while_progressing",
		"进度还在推进就被判定卡住")

	# 换阶段也要重置：新阶段从零开始计时，不继承上一段的等待。
	bootstrap._set_phase(BootstrapScript.Phase.LOAD_MAIN, "load", "detail", 0.5)
	for i in 4:
		bootstrap._tick_watchdog(1.0)
	_h.expect(str(bootstrap.snapshot().get("watchdog_level_name", "")) == "NOTICE",
		"watchdog_phase_reset_broken", "同阶段停住 4 秒之后没有进入 NOTICE")
	bootstrap._set_phase(BootstrapScript.Phase.PREPARE_DATA, "prep", "detail", 0.08)
	_h.expect(str(bootstrap.snapshot().get("watchdog_level_name", "")) == "QUIET",
		"watchdog_not_reset_on_phase_change",
		"换阶段之后等级没有归零 —— 新阶段会立刻继承上一段的告警")

	bootstrap.queue_free()
	await get_tree().process_frame


# 同时在线上限与排队（2026-09-14）：主界面载完之后要登录成功、账号后端放行才进门。
#
# 核心判据，每条对应一种**不报错**的失败：
#   🔴 连不上就不让进（已定）：登录中、登录失败、被顶号、连不上，等多久都不放行
#   🔴 排着队的人不会因为等久了被放进去（唯一的按时长放行只针对「连上了但从不回名额」）
#   🔴 被顶号之后不能自动重连（两台设备会无限互踢）
func _check_entry_gate_view() -> void:
	var admitted := BootstrapScript.entry_view({"login": "logged_in", "online": true, "admitted": true})
	_h.expect(bool(admitted.get("pass", false)), "entry_admitted_not_passed", "服务器放行了却不进门")

	var forever := 99999.0
	var closed_cases := {
		"登录中": {"login": "working", "offline_sec": forever, "unanswered_sec": forever},
		"登录失败": {"login": "failed", "offline_sec": forever, "unanswered_sec": forever},
		"被顶号": {"login": "logged_in", "kicked": true, "offline_sec": forever, "unanswered_sec": forever},
		"一直连不上": {"login": "logged_in", "online": false, "failed_handshakes": 99,
			"offline_sec": forever, "unanswered_sec": forever},
		"排队很久": {"login": "logged_in", "online": true, "queue_position": 7, "unanswered_sec": forever},
	}
	for case_name in closed_cases:
		var view: Dictionary = BootstrapScript.entry_view(closed_cases[case_name])
		_h.expect(not bool(view.get("pass", false)), "entry_fails_open",
			("进门这一步在「%s」时放行了 —— 已定连不上账号服务器就不让进，"
				+ "排着队的人也不能等久了自己进去") % case_name)

	var failed: Dictionary = BootstrapScript.entry_view(closed_cases["登录失败"])
	_h.expect(str(failed.get("state", "")) == "login_failed" and bool(failed.get("actions", false)),
		"entry_login_failed_no_way_out", "登录失败时没有摆出重试 / 退出")
	var kicked: Dictionary = BootstrapScript.entry_view(closed_cases["被顶号"])
	_h.expect(str(kicked.get("state", "")) == "kicked" and bool(kicked.get("actions", false)),
		"entry_kicked_no_way_out", "被顶号时没有让玩家自己选择在这台设备上继续")
	var queued: Dictionary = BootstrapScript.entry_view(closed_cases["排队很久"])
	_h.expect(str(queued.get("state", "")) == "queued" and int(queued.get("position", 0)) == 7,
		"entry_queue_position_lost", "排队时位次没有带到界面上")

	var connecting := BootstrapScript.entry_view(
		{"login": "logged_in", "online": false, "failed_handshakes": 0, "offline_sec": 1.0})
	_h.expect(str(connecting.get("state", "")) == "connecting" and not bool(connecting.get("actions", false)),
		"entry_error_flashes_on_reconnect", "刚登录上、连接还没失败过就弹出了错误面板")
	var failing := BootstrapScript.entry_view({"login": "logged_in", "online": false,
		"failed_handshakes": BootstrapScript.ENTRY_CONNECT_FAILURES})
	_h.expect(str(failing.get("state", "")) == "connect_failed" and bool(failing.get("actions", false)),
		"entry_connect_failure_hidden", "连续握手失败之后仍只显示「正在连接」，玩家不知道出了问题")

	var checking := BootstrapScript.entry_view(
		{"login": "logged_in", "online": true, "queue_position": 0, "unanswered_sec": 1.0})
	_h.expect(not bool(checking.get("pass", false)), "entry_passes_before_answer", "还没收到名额消息就放行了")
	var legacy := BootstrapScript.entry_view({"login": "logged_in", "online": true, "queue_position": 0,
		"unanswered_sec": BootstrapScript.ENTRY_LEGACY_SERVER_SEC})
	_h.expect(bool(legacy.get("pass", false)) and bool(legacy.get("legacy_server", false)),
		"entry_legacy_server_blocks_everyone",
		"账号后端是没有排队功能的旧版时，全体玩家会一直卡在启动画面")

	# 维护公告（docs/公告系统设计.md）：只把「连不上」换成维护说明，不改变放不放行。
	var maintenance_login: Dictionary = BootstrapScript.entry_view({"login": "failed", "maintenance": true})
	_h.expect(str(maintenance_login.get("state", "")) == "maintenance"
			and bool(maintenance_login.get("actions", false)) and not bool(maintenance_login.get("pass", false)),
		"entry_maintenance_hidden", "登录失败且有维护公告时没有显示维护说明，或者放行了")
	var maintenance_connect: Dictionary = BootstrapScript.entry_view({"login": "logged_in", "online": false,
		"failed_handshakes": BootstrapScript.ENTRY_CONNECT_FAILURES, "maintenance": true})
	_h.expect(str(maintenance_connect.get("state", "")) == "maintenance"
			and not bool(maintenance_connect.get("pass", false)),
		"entry_maintenance_connect_hidden", "连不上服务器且有维护公告时没有显示维护说明，或者放行了")
	var rate_limited: Dictionary = BootstrapScript.entry_view(
		{"login": "failed", "rate_limited": true, "maintenance": true})
	_h.expect(str(rate_limited.get("state", "")) == "login_failed", "entry_rate_limit_shown_as_maintenance",
		"注册被限流时显示成了「服务器维护中」—— 服务器根本没在维护，玩家会一直干等")
	var admitted_during_notice: Dictionary = BootstrapScript.entry_view(
		{"login": "logged_in", "online": true, "admitted": true, "maintenance": true})
	_h.expect(bool(admitted_during_notice.get("pass", false)), "entry_maintenance_blocks_admitted",
		"维护公告文件忘了删、但服务器已经放行时，玩家被挡在了门外")
	var connecting_during_notice: Dictionary = BootstrapScript.entry_view(
		{"login": "logged_in", "online": false, "failed_handshakes": 0, "offline_sec": 1.0, "maintenance": true})
	_h.expect(str(connecting_during_notice.get("state", "")) == "connecting", "entry_maintenance_flashes",
		"连接还没失败过就显示了维护说明")

	# 封号（backend/app/bans.py）：压过一切，包括游戏中被封回来时名额那一侧还记着的「放行过」。
	for banned_facts in [
		{"login": "failed", "banned": true},
		{"login": "logged_in", "online": true, "admitted": true, "banned": true},
		{"login": "failed", "banned": true, "maintenance": true},
	]:
		var banned_view: Dictionary = BootstrapScript.entry_view(banned_facts)
		_h.expect(str(banned_view.get("state", "")) == "banned" and not bool(banned_view.get("pass", false))
				and bool(banned_view.get("actions", false)),
			"entry_banned_not_shown", "账号被封时没有显示封号说明，或者放行了：%s" % str(banned_facts))
	var timed := BootstrapScript.ban_text({"reason": "使用外挂", "ends_at": "2026-10-01T12:00:00+00:00"}, false, 480)
	_h.expect(timed.contains("原因：使用外挂") and timed.contains("2026-10-01 20:00"),
		"entry_ban_text_wrong", "封号说明没有原因或解封时间没换成本地时区：%s" % timed)
	var forever_text := BootstrapScript.ban_text({"reason": "盗号", "ends_at": null}, true, 0)
	_h.expect(forever_text.contains("Permanent") and forever_text.contains("Reason: 盗号"),
		"entry_ban_text_permanent", "永久封号的英文说明不对：%s" % forever_text)
	var account_source := FileAccess.get_file_as_string("res://scripts/autoload/AccountManager.gd")
	_h.expect(account_source.contains("elif bool(refreshed.get(\"banned\", false)):"),
		"entry_ban_clears_credentials",
		"登录时被封没有单独处理 —— 落进 401 分支会清掉凭证、自动注册新号，封号白封")

	var source := FileAccess.get_file_as_string("res://scenes/bootstrap/Bootstrap.gd")
	_h.expect(source.contains("if _entry_gate_required():\n\t\t_begin_entry()"),
		"entry_gate_bypassed", "主界面载完之后没有经过进门这一步就直接 READY 了")
	_h.expect(source.contains("if not RealtimeService.is_kicked():\n\t\tRealtimeService.start()"),
		"entry_auto_reconnect_after_kick", "进门那一步在被顶号之后仍会自动重连 —— 两台设备会无限互踢")


# 排队可能要等十几分钟，那不是「启动卡住」。
func _check_entry_phase_is_not_watchdogged() -> void:
	var bootstrap := _new_bootstrap(FIXTURE_PATH)
	await get_tree().process_frame
	# 不让 _process 去驱动进门（那会真的去登录），只看看门狗对这个阶段的反应。
	bootstrap.set_process(false)
	bootstrap._set_phase(BootstrapScript.Phase.ENTRY, "entry", "", 1.0)
	for i in 30:
		bootstrap._tick_watchdog(1.0)
	var snap := bootstrap.snapshot()
	_h.expect(str(snap.get("watchdog_level_name", "")) == "QUIET" and not bool(snap.get("stuck", false)),
		"entry_watchdogged", "排队 30 秒被看门狗判成了启动卡住")
	_h.expect(not bool(snap.get("error_visible", false)), "entry_watchdog_error_panel",
		"排队时看门狗弹出了「启动比预期慢很多」")
	bootstrap.queue_free()
	await get_tree().process_frame


# 取多行文案的第二行。空则返回空串。
func _second_line(text: String) -> String:
	var lines := text.split("
")
	return str(lines[1]) if lines.size() > 1 else ""
