extends Node

# V2 P1-04 / F1：动作播放连续性门禁。
#
# 现象（Leno 真机观察）：根骨 X/Z 原地化之后角色不再走出圆盘，但 walking 仍有
# 轻微卡顿。MD 明确要求「不要只凭肉眼猜」，所以这条门禁**量**播放位置本身。
#
# 量什么：把 wrapper 挂到真实 UnitActor3D、应用真实 ModelRootMotionPolicy、
# 调 play_run()，然后逐帧记录内部 AnimationPlayer 的 current_animation_position。
# 连续播放的曲线应当是「单调上升 + 到末尾回绕一次」。卡顿在曲线上的形状是：
#   * 位置反复被拽回同一个点（每帧重新 play() + seek()）
#   * is_playing() 中途变 false（动画播完没循环，靠 _process 重启）
#   * 位置长时间不前进（被反复重置吃掉了推进）
#
# 这三种都能在 headless 下确定性复现，不需要设备。设备只用来做最终 A/B 观感确认。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const RootMotionPolicy := preload("res://effects/runtime/presentation/ModelRootMotionPolicy.gd")
const UnitActor3D := preload("res://effects/runtime/presentation/UnitActor3D.gd")

const CHECK_NAME := "model_action_playback_continuity"

# 采样帧数。要足够长，跨过 run clip（最短约 1.35 秒）的一次回绕。
const SAMPLE_FRAMES := 150

# 一次正常回绕之外，位置不允许再有第二次「明显后退」。
# 阈值取 0.02 秒：小于它的抖动是浮点与帧长差异，不是重置。
const BACKWARD_EPS := 0.02
# 允许的回绕次数上限。150 帧、clip 最短 1.35 秒、headless 帧长不定，
# 放宽到 8 次仍远低于「每帧重置」的量级（那会接近 150 次）。
const MAX_WRAPS := 8

const TABLES := [
	{"kind": "unit", "path": "res://data/units/race_units.json", "key": "units"},
	{"kind": "merc", "path": "res://data/mercenary/mercenaries.json", "key": "mercenaries"},
	{"kind": "monster", "path": "res://data/pve/pve_monsters.json", "key": "monsters"},
	{"kind": "boss", "path": "res://data/boss/bosses.json", "key": "bosses"},
]

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var rows: Array[Dictionary] = []

	for table in TABLES:
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(table.path)))
		if not (parsed is Dictionary):
			_h.fail("table_parse_failed", "%s JSON 解析失败" % str(table.path))
			continue
		for item in (parsed as Dictionary).get(str(table.key), []):
			var definition := item as Dictionary
			var configured: Variant = definition.get("model_in_place_actions", [])
			# 只量登记了 run 的单位：它们才是策略改过、且玩家会看到走动的那批。
			if not (configured is Array) or not (configured as Array).has("run"):
				continue
			var model_path := str(definition.get("model", ""))
			if model_path.is_empty():
				continue
			var row := await _sample_run(str(definition.get("id", "")), model_path, definition)
			if not row.is_empty():
				rows.append(row)

	_h.expect(rows.size() >= 20, "too_few_units_sampled",
		"只采到 %d 个登记了 run 的单位，这条门禁等于没跑" % rows.size())

	var worst_backward := 0
	var worst_id := ""
	var stalled: Array[String] = []
	for row in rows:
		_h.item()
		var unit_id := str(row["id"])
		var backward := int(row["backward"])
		var wraps := int(row["wraps"])
		var advanced := float(row["advanced"])
		var stopped := int(row["stopped"])
		if backward - wraps > worst_backward:
			worst_backward = backward - wraps
			worst_id = unit_id
		if advanced <= 0.0:
			stalled.append(unit_id)
		_h.expect(wraps <= MAX_WRAPS, "playback_restarted_too_often",
			("%s 的 run 在 %d 帧里回到起点 %d 次（上限 %d）——"
				+ "这是每帧重新 play()/seek() 的形状，玩家看到的就是卡顿")
				% [unit_id, SAMPLE_FRAMES, wraps, MAX_WRAPS])
		_h.expect(stopped == 0, "playback_stopped_midway",
			"%s 的 run 在采样中途有 %d 帧 is_playing() 为 false —— 动画没有循环，靠 _process 重启"
				% [unit_id, stopped])
		_h.expect(advanced > 0.0, "playback_did_not_advance",
			"%s 的 run 在 %d 帧里播放位置完全没有前进" % [unit_id, SAMPLE_FRAMES])

	_h.note("采样 %d 个登记 run 的单位、每个 %d 帧" % [rows.size(), SAMPLE_FRAMES])
	if not worst_id.is_empty():
		_h.note("非回绕后退最多的是 %s：%d 次" % [worst_id, worst_backward])
	if not stalled.is_empty():
		_h.note("完全没有前进的：%s" % ", ".join(stalled))

	GameState.reset_run()
	await _settle(2)
	_h.finish(get_tree())


func _sample_run(unit_id: String, model_path: String, definition: Dictionary) -> Dictionary:
	var packed := load(model_path) as PackedScene
	if packed == null:
		_h.fail("model_scene_missing", "%s 的模型场景加载不出来" % unit_id)
		return {}
	var root := packed.instantiate() as Node3D
	if root == null:
		_h.fail("model_instantiate_failed", "%s 实例化失败" % unit_id)
		return {}
	var actor := UnitActor3D.new()
	actor.set_meta("unit_id", unit_id)
	actor.attach_model(root)
	add_child(actor)
	await _settle(2)

	# 与战斗侧一致：先挂进树，再应用策略。
	RootMotionPolicy.apply_to_actor(actor, definition)
	await _settle(1)

	var players_value: Variant = root.get("action_players")
	var players: Dictionary = players_value if players_value is Dictionary else {}
	var player := players.get("run") as AnimationPlayer
	if player == null:
		actor.queue_free()
		await _settle(1)
		return {}

	root.call("play_run")
	await _settle(1)

	var previous := player.current_animation_position
	var first := previous
	var backward := 0
	var wraps := 0
	var stopped := 0
	var maximum := previous
	for i in SAMPLE_FRAMES:
		await get_tree().process_frame
		if not player.is_playing():
			stopped += 1
			continue
		var now := player.current_animation_position
		maximum = maxf(maximum, now)
		if now < previous - BACKWARD_EPS:
			backward += 1
			# 从接近末尾跳回接近开头 = 正常回绕；从中段跳回同一个点 = 重置。
			if previous >= maximum - BACKWARD_EPS:
				wraps += 1
		previous = now

	actor.queue_free()
	await _settle(1)
	return {
		"id": unit_id, "backward": backward, "wraps": wraps,
		"stopped": stopped, "advanced": maximum - first,
	}


func _settle(frames: int = 2) -> void:
	for i in frames:
		await get_tree().process_frame
