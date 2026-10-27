extends Control

const Deadline := preload("res://scripts/rounds/PrepDeadline.gd")
var _screen: Control
var _deadline := 0.0
var _last_second := -1
var _expired := false
var _cue: Label
var _pulse: Tween

func _ready() -> void:
	_screen = get_parent()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	z_index = 90
	var ruleset := "seedling" if GameState.FINAL_ROUND == 13 else "normal"
	_deadline = Time.get_ticks_msec() / 1000.0 + Deadline.duration(
		GameState.round_index, ruleset, NetworkService.match_mode)
	_cue = Label.new()
	_cue.name = "FinalSeconds"
	_cue.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cue.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cue.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_cue.add_theme_font_size_override("font_size", 68)
	_cue.add_theme_color_override("font_color", Color("f6d88e"))
	_cue.add_theme_color_override("font_outline_color", Color("42241b"))
	_cue.add_theme_constant_override("outline_size", 5)
	_cue.visible = false
	add_child(_cue)
	_cue.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_cue.position = size * 0.5 - Vector2(64, 50)
	_cue.size = Vector2(128, 100)
	_cue.pivot_offset = _cue.size * 0.5

func _process(_delta: float) -> void:
	if _expired or GameState.tutorial_mode or not is_instance_valid(_screen):
		return
	if bool(_screen.get("_battle_transition_running")):
		_cue.hide()
		return
	var left := _deadline - Time.get_ticks_msec() / 1000.0
	if NetworkService.team_active and not NetworkService.is_host:
		# ★★ 10.12 第 6 条**返修**（用户口径：「第 6 点只不生效于离线自测房间，其他房间
		#    对局要生效」）：联机客机这里**只把服务端倒计时当优先来源**，绝不因为
		#    「服务端还没广播到 prep / 没带 prep_seconds_left」就把整块倒计时藏起来。
		#
		#    ⚠ 原实现是 `if not server_prep_confirmed(): _cue.hide(); return`，后面还有一条
		#      `if left < 0.0: return`。后果 —— 只要服务器是旧包（`_build_room_state` 不发
		#      `prep_seconds_left`）或者阶段还没推到 prep，**整间房的人都看不到倒计时**：
		#      按钮没有「（xx s）」后缀、3/2/1 也不弹。
		#      而**自定义房间的房主在专服上同样是 `is_host == false` 的客机** ⇒
		#      「自定义房间没有倒计时」就是这一条，与离线自测那条守卫无关
		#      （离线自测 `team_active` 恒为假，根本走不进这个分支）。
		#    ★ 仍然不越权：客机到点只走下面 `left <= 0` 里的本地自动上阵；
		#      「提交开战」（`not team_active`）与「置 ready + 判断开回合」（`is_host`）
		#      这两条分支本来就轮不到客机 —— 服务端始终是唯一权威。
		if NetworkService.server_prep_confirmed(GameState.round_index):
			var server_left := NetworkService.prep_seconds_left()
			if server_left >= 0.0:
				left = server_left
	var second := maxi(0, int(ceil(left)))
	if second != _last_second:
		_last_second = second
		_screen.set_meta("prep_countdown_seconds", second)
		_screen.call("_refresh_start_button_label")
		_show_cue(second)
	if left <= 0.0:
		_expired = true
		_cue.hide()
		_screen.call("_auto_deploy_at_deadline")
		if not NetworkService.team_active:
			_screen.call("_emit_battle_request_once")
		elif NetworkService.is_host:
			for i in NetworkService.team_ready.size():
				NetworkService.team_ready[i] = true
			NetworkService._team_maybe_start_round()

func _show_cue(second: int) -> void:
	_cue.visible = second >= 1 and second <= 3
	if not _cue.visible:
		return
	if _pulse != null and _pulse.is_valid():
		_pulse.kill()
	_cue.text = "%d!" % second
	_cue.scale = Vector2.ONE * 1.25
	_cue.modulate.a = 0.86
	_pulse = create_tween().set_parallel(true)
	_pulse.tween_property(_cue, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_QUAD)
	_pulse.tween_property(_cue, "modulate:a", 0.28, 0.85)
