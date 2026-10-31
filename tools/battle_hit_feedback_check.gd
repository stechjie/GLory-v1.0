extends Node

# 10.21 受击反馈（BattleHitFeedback）和战斗屏震的门禁。
#
# 用真实的民兵精修模型跑，守这些行为：
#   闪白：命中时角色网格挂上覆盖层，约 0.1 秒后摘掉；已被光环占用覆盖槽的网格不碰；
#         玩家关掉闪烁时一个都不挂。
#   后仰 + 压扁：只动 ActorRoot 的 rotation / scale（position 归攻击前冲），结束后回原位。
#   局部顿帧：只停这个单位的 AnimationPlayer，时间到恢复；连续命中顺延；关掉开关就不停。
#   节流：70ms 内同一目标的第二次反馈被忽略。
#   屏震：战斗不再走 Camera2D，VFXManager 会把屏震转给登记的战斗接收方；
#         BattleVfx 的接线在对应函数体里（不读注释）。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const Feedback := preload("res://effects/runtime/presentation/BattleHitFeedback.gd")
const CHECK_NAME := "battle_hit_feedback"
const MODEL := "res://assets/models/units/human_refined/human_militia/human_militia_refined.tscn"
const VFX_PATH := "res://scenes/battle/BattleVfx.gd"

# 捕获实际引擎错误，让“计时器报错但检查场景仍退出0”也能成为失败。
class FreezeErrorCapture:
	extends Logger
	var _errors: Array[String] = []
	var _mutex := Mutex.new()

	func _log_error(_function: String, _file: String, _line: int, code: String,
			rationale: String, _editor_notify: bool, error_type: int,
			_script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == Logger.ERROR_TYPE_WARNING:
			return
		_mutex.lock()
		_errors.append("%s %s" % [code, rationale])
		_mutex.unlock()

	func messages() -> Array[String]:
		_mutex.lock()
		var result: Array[String] = _errors.duplicate()
		_mutex.unlock()
		return result


var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	await _check_flash_and_flinch()
	await _check_hitstop()
	await _check_hitstop_actor_freed_before_timer()
	await _check_toggles_and_throttle()
	_check_shake_sink()
	_check_battle_vfx_wiring()
	_h.finish(get_tree())


func _make_actor() -> Node3D:
	var actor := Node3D.new()
	actor.set_meta("base_yaw", 180.0)
	var root := Node3D.new()
	root.name = "ActorRoot"
	actor.add_child(root)
	var model := (load(MODEL) as PackedScene).instantiate() as Node3D
	model.scale = Vector3.ONE * 0.42
	root.add_child(model)
	add_child(actor)
	return actor


func _meshes(actor: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for node in actor.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh.mesh is ArrayMesh and mesh.is_visible_in_tree():
			out.append(mesh)
	return out


## 按墙钟逐帧等。不能用 create_timer：加载模型后的第一帧帧间隔很大，计时器会当场到点。
func _wait(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame


func _check_flash_and_flinch() -> void:
	var victim := _make_actor()
	var attacker := _make_actor()
	attacker.position = Vector3(-1.0, 0.0, 0.0)
	await get_tree().process_frame
	var meshes := _meshes(victim)
	if not _h.expect(meshes.size() >= 2, "too_few_meshes", "民兵只找到 %d 个可见角色网格，测不了「光环占用」分支" % meshes.size()):
		return
	# 模拟四星光环已占用第一个网格的覆盖槽。
	var aura := StandardMaterial3D.new()
	meshes[0].material_overlay = aura
	var root := victim.get_node("ActorRoot") as Node3D
	var root_position := root.position
	Feedback.play(victim, attacker, "crit", true, false)
	_h.expect(meshes[0].material_overlay == aura, "aura_overwritten", "闪白把已被光环占用的覆盖层换掉了")
	var flashed := 0
	for i in range(1, meshes.size()):
		if meshes[i].material_overlay is ShaderMaterial:
			flashed += 1
	_h.expect(flashed == meshes.size() - 1, "flash_missing", "命中时只有 %d / %d 个空闲网格挂上了闪白" % [flashed, meshes.size() - 1])
	_h.expect(not root.quaternion.is_equal_approx(Quaternion.IDENTITY), "no_flinch", "命中那一帧 ActorRoot 没有后仰")
	_h.expect(root.scale.y < 0.99, "no_squash", "命中那一帧没有压扁")
	# 攻击者在 -X 一侧：受击者应该往 +X 倒（头顶朝远离攻击者的方向）。
	var head := root.global_transform.basis * Vector3.UP
	_h.expect(head.x > 0.01, "flinch_wrong_way", "受击者朝攻击者那边倒了（头顶 x=%.3f，应为正）" % head.x)
	_h.expect(root.position.is_equal_approx(root_position), "flinch_moved_root", "后仰改了 ActorRoot.position —— 那是攻击前冲的槽位")
	await _wait(0.35)
	var leftover := 0
	for i in range(1, meshes.size()):
		if meshes[i].material_overlay != null:
			leftover += 1
	_h.expect(leftover == 0, "flash_not_removed", "闪白结束后还有 %d 个网格挂着覆盖层" % leftover)
	_h.expect(meshes[0].material_overlay == aura, "aura_lost", "闪白结束时把光环的覆盖层也摘了")
	_h.expect(root.quaternion.is_equal_approx(Quaternion.IDENTITY) and root.scale.is_equal_approx(Vector3.ONE),
			"flinch_not_restored", "后仰结束后 ActorRoot 没回原位：rotation=%s scale=%s" % [root.quaternion, root.scale])
	victim.queue_free()
	attacker.queue_free()
	await get_tree().process_frame


func _check_hitstop() -> void:
	var victim := _make_actor()
	var attacker := _make_actor()
	await get_tree().process_frame
	var players := victim.find_children("*", "AnimationPlayer", true, false)
	if not _h.expect(not players.is_empty(), "no_animation_player", "民兵模型里没有 AnimationPlayer"):
		return
	Feedback.play(victim, attacker, "crit", false, true)
	var frozen := true
	for node in players + attacker.find_children("*", "AnimationPlayer", true, false):
		frozen = frozen and is_zero_approx((node as AnimationPlayer).speed_scale)
	_h.expect(frozen, "crit_not_frozen", "暴击时攻击者和受击者的动画没有一起停")
	await _wait(0.03)
	# 顺延：中途再来一次技能命中（绕过节流），恢复时间要往后推。
	victim.set_meta("hit_feedback_msec", -100000)
	Feedback.play(victim, null, "skill", false, true)
	await _wait(0.045)
	_h.expect(is_zero_approx((players[0] as AnimationPlayer).speed_scale), "hitstop_not_extended",
			"连续命中时顿帧被前一次的计时器提前恢复了")
	await _wait(0.12)
	var restored := true
	for node in players + attacker.find_children("*", "AnimationPlayer", true, false):
		restored = restored and is_equal_approx((node as AnimationPlayer).speed_scale, 1.0)
	_h.expect(restored, "hitstop_not_released", "顿帧结束后动画没有恢复到 1 倍速")
	# 计时器提前到点（卡顿帧）时不能直接放弃恢复，要按剩余时间重排。
	Feedback.freeze_animation(victim, 0.08)
	Feedback._release_freeze(victim)
	_h.expect(is_zero_approx((players[0] as AnimationPlayer).speed_scale), "released_too_early", "时间没到就恢复了动画")
	await _wait(0.2)
	_h.expect(is_equal_approx((players[0] as AnimationPlayer).speed_scale, 1.0), "early_timer_strands_freeze",
			"计时器提前触发后这个单位一直停着，没有按剩余时间重排恢复")
	# 普攻不顿帧。
	victim.set_meta("hit_feedback_msec", -100000)
	Feedback.play(victim, attacker, "basic", false, true)
	_h.expect(is_equal_approx((players[0] as AnimationPlayer).speed_scale, 1.0), "basic_frozen", "普通命中也顿帧了")
	victim.queue_free()
	attacker.queue_free()
	await get_tree().process_frame


func _check_toggles_and_throttle() -> void:
	var victim := _make_actor()
	await get_tree().process_frame
	var meshes := _meshes(victim)
	var players := victim.find_children("*", "AnimationPlayer", true, false)
	Feedback.play(victim, null, "skill", false, false)
	var any_overlay := false
	for mesh in meshes:
		any_overlay = any_overlay or mesh.material_overlay != null
	_h.expect(not any_overlay, "flash_ignores_toggle", "关掉闪烁时仍然挂了闪白")
	_h.expect(players.is_empty() or is_equal_approx((players[0] as AnimationPlayer).speed_scale, 1.0),
			"hitstop_ignores_toggle", "关掉顿帧时动画仍被停住")
	# 节流：紧接着第二次命中应被忽略（闪白开着也不该挂上）。
	Feedback.play(victim, null, "skill", true, false)
	any_overlay = false
	for mesh in meshes:
		any_overlay = any_overlay or mesh.material_overlay != null
	_h.expect(not any_overlay, "throttle_missing", "70ms 内同一目标的第二次反馈没有被节流")
	victim.queue_free()
	await get_tree().process_frame


func _check_hitstop_actor_freed_before_timer() -> void:
	var capture := FreezeErrorCapture.new()
	OS.add_logger(capture)
	var victim := _make_actor()
	await get_tree().process_frame
	Feedback.freeze_animation(victim, 0.08)
	# 同时覆盖初次计时器和“提前触发后顺延”的恢复计时器。
	Feedback._release_freeze(victim)
	var actor_ref: WeakRef = weakref(victim)
	victim.queue_free()
	await get_tree().process_frame
	_h.expect(actor_ref.get_ref() == null, "freed_hitstop_actor_survives",
		"测试中的冻结单位未提前回收，无法覆盖死亡先于恢复计时器的情况")
	await _wait(0.18)
	await get_tree().process_frame
	OS.remove_logger(capture)
	var errors := capture.messages()
	_h.expect(errors.is_empty(), "freed_hitstop_timer_errors",
		"冻结单位先回收后，恢复计时器仍产生引擎错误：%s" % str(errors))


func _check_shake_sink() -> void:
	var manager := get_tree().root.get_node_or_null("VFXManager")
	if not _h.expect(manager != null, "vfx_manager_missing", "VFXManager autoload 不在"):
		return
	var received: Array = []
	var sink := func(strength: float, duration: float) -> void: received.append([strength, duration])
	manager.call("set_battle_shake_sink", sink)
	manager.call("play_screen_shake", 6.5, 0.2)
	manager.call("clear_battle_shake_sink", sink)
	manager.call("play_screen_shake", 6.5, 0.2)
	var shake_on := PresentationSettings.screen_shake_allowed()
	if shake_on:
		_h.expect(received.size() == 1 and is_equal_approx(float(received[0][0]), 6.5), "sink_not_called",
				"VFXManager.play_screen_shake 没有把原始强度转给战斗接收方（收到 %s）" % str(received))
	else:
		_h.note("玩家设置里屏震是关的，只检查「关掉时不转发」")
		_h.expect(received.is_empty(), "sink_ignores_toggle", "屏震关掉时仍然转发给了战斗接收方")


func _check_battle_vfx_wiring() -> void:
	var src := FileAccess.get_file_as_string(VFX_PATH)
	var shake := _strip(_function_body(src, "_screen_shake"))
	_h.expect(not shake.is_empty() and not shake.contains("VFXManager.play_screen_shake"), "shake_still_camera2d",
			"_screen_shake 还在转给 VFXManager 的 Camera2D 抖动 —— 战斗里没有 Camera2D")
	_h.expect(shake.contains("PresentationSettings.screen_shake_scale()"), "shake_ignores_setting",
			"战斗屏震没有乘玩家的屏震强度设置")
	var update := _strip(_function_body(src, "_update_vfx_camera_shake"))
	_h.expect(update.contains("_arena.position") and update.contains("set_battle_shake_sink"), "shake_not_applied",
			"_update_vfx_camera_shake 没有平移战场容器或没有登记为屏震接收方")
	_h.expect(not update.contains("randf"), "shake_random_jitter", "屏震用了每帧随机偏移，会抖成雪花")
	var number := _strip(_function_body(src, "cue_spawn_hit_number"))
	_h.expect(number.contains("_play_hit_reaction("), "reaction_not_wired", "伤害数字那一拍没有触发受击反馈")
	var reaction := _strip(_function_body(src, "_play_hit_reaction"))
	_h.expect(reaction.contains("PresentationSettings.flash_allowed()") and reaction.contains("PresentationSettings.hit_stop_allowed()"),
			"reaction_ignores_settings", "受击反馈没有读玩家的闪烁 / 顿帧开关")
	_h.expect(not reaction.contains("Engine.time_scale"), "global_time_scale", "受击反馈改了全局 time_scale")
	var basic := _strip(_function_body(src, "cue_play_basic_attack"))
	_h.expect(basic.contains("_last_basic_attacker[target_uid]"), "attacker_not_recorded",
			"普攻没有记下攻击者，后仰方向和暴击双人顿帧拿不到攻击者")


func _function_body(src: String, name: String) -> String:
	var start := src.find("\nfunc %s(" % name)
	if start < 0:
		return ""
	var next := src.find("\nfunc ", start + 1)
	return src.substr(start, (next if next > 0 else src.length()) - start)


func _strip(src: String) -> String:
	var lines: PackedStringArray = []
	for line in src.split("\n"):
		var at := line.find("#")
		lines.append(line.substr(0, at) if at >= 0 else line)
	return "\n".join(lines)
