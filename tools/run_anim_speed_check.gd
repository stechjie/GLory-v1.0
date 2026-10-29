extends Node

# 跑步动画调速与根位移原地化门禁（2026-10-29 滑步修复）。
#
# 锁住这几条：
#   1. 标定表每一条都还对得上当前模型（换了模型的条目失效 → 门禁红，提醒重测）；
#   2. 缩放换算：模型缩放 / 全局缩放改了，脚贴地速度按比例变；模型路径不符返回 0；
#   3. 播放倍率 = 显示速度 / 脚贴地速度，夹在 [MIN, MAX]，没标定的单位保持 1.0；
#   4. 顿帧期间改倍率只记基准值，解冻恢复到基准值而不是 1.0；
#   5. 慢放时跑步锁盖得住两个逻辑帧之间的真实时间（否则每帧闪回待机）；
#   6. 原地化策略：Armature 节点轨道、Z 向上骨架的根骨轨道都能锁住，竖直起伏保留；
#      Y 向上骨架的锁定结果与旧的「钉 X/Z、留 Y」逐字一致。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const RendererScript := preload("res://scenes/battle/BattleRenderer.gd")
const Calibration := preload("res://effects/runtime/presentation/RunAnimCalibration.gd")
const Policy := preload("res://effects/runtime/presentation/ModelRootMotionPolicy.gd")
const HitFeedback := preload("res://effects/runtime/presentation/BattleHitFeedback.gd")
const Resolver := preload("res://effects/runtime/presentation/UnitVisualResolver.gd")

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new("run_anim_speed")
	_case_table_matches_models()
	_case_scale_math()
	var renderer = RendererScript.new()
	add_child(renderer)
	_case_speed_ratio_and_clamp(renderer)
	await _case_hitstop_restores_base(renderer)
	_case_run_lock_covers_slow_tick(renderer)
	_case_display_speed_tracking(renderer)
	renderer.queue_free()
	_case_lock_armature_node_track()
	_case_lock_z_up_root_bone()
	_case_lock_y_up_unchanged()
	_h.finish(get_tree())


func _case_table_matches_models() -> void:
	var by_id := {}
	for entry in Resolver.all_combat_entries():
		by_id[str((entry as Dictionary).get("id", ""))] = entry
	var checked := 0
	for uid in Calibration.GROUND_SPEED.keys():
		var row: Dictionary = Calibration.GROUND_SPEED[uid]
		var def_value: Variant = by_id.get(uid)
		if not _h.expect(def_value is Dictionary, "calibration_unit_missing",
				"标定表里的 %s 已不在战斗单位里" % uid):
			continue
		var d := def_value as Dictionary
		_h.expect(str(d.get("model", "")) == str(row.get("model", "")), "calibration_model_stale",
			"%s 换了模型（%s），标定条目还是 %s —— 要重测" % [uid, d.get("model", ""), row.get("model", "")])
		var scale := float(d.get("model_visual_scale", 1.0)) * (1.2 if int(d.get("tier", 1)) == 3 else 1.0)
		_h.expect(absf(scale - float(row.get("model_scale", 0.0))) < 0.001, "calibration_scale_stale",
			"%s 的模型缩放现在是 %.3f，标定时是 %.3f（运行时会按比例换算，表要同步）" % [uid, scale, float(row.get("model_scale", 0.0))])
		_h.expect(float(row.get("ground_speed", 0.0)) > 0.0, "calibration_speed_invalid",
			"%s 的脚贴地速度不是正数" % uid)
		checked += 1
	_h.expect(checked >= 60, "calibration_table_vacuous", "标定表只有 %d 条，测量结果没进表" % checked)


func _case_scale_math() -> void:
	var uid := "human_archer"
	var row: Dictionary = Calibration.GROUND_SPEED[uid]
	var d := {"model": row.model}
	var base := Calibration.ground_speed_for(uid, d, float(row.model_scale))
	_h.expect(is_equal_approx(base, float(row.ground_speed)), "scale_identity",
		"标定缩放下应原样返回 %.3f，得到 %.3f" % [float(row.ground_speed), base])
	var doubled := Calibration.ground_speed_for(uid, d, float(row.model_scale) * 2.0)
	_h.expect(is_equal_approx(doubled, base * 2.0), "scale_model_ratio", "模型放大一倍，脚贴地速度应翻倍")
	var global_half := Calibration.ground_speed_for(uid, d, float(row.model_scale), Calibration.MEASURED_GLOBAL_SCALE * 0.5)
	_h.expect(is_equal_approx(global_half, base * 0.5), "scale_global_ratio", "全局缩放减半，脚贴地速度应减半")
	_h.expect(Calibration.ground_speed_for(uid, {"model": "placeholder_other_model.tscn"}, 1.0) == 0.0,
		"model_mismatch_ignored", "模型路径不符必须返回 0（回到原速）")
	_h.expect(Calibration.ground_speed_for("no_such_unit", d, 1.0) == 0.0,
		"unknown_unit_ignored", "没收录的单位必须返回 0")


func _case_speed_ratio_and_clamp(renderer) -> void:
	var n := Node3D.new()
	n.set_meta("run_ground_speed", 1.0)
	n.set_meta("display_speed", 1.8)
	_h.expect(is_equal_approx(renderer._run_anim_speed_for(n), 1.8), "ratio",
		"显示速度 1.8 / 脚贴地 1.0 应播 1.8 倍")
	n.set_meta("display_speed", 30.0)
	_h.expect(is_equal_approx(renderer._run_anim_speed_for(n), renderer.RUN_ANIM_SPEED_MAX), "clamp_max",
		"倍率必须封顶在 %.1f" % renderer.RUN_ANIM_SPEED_MAX)
	n.set_meta("display_speed", 0.0)
	_h.expect(is_equal_approx(renderer._run_anim_speed_for(n), renderer.RUN_ANIM_SPEED_MIN), "clamp_min",
		"起步时倍率不低于 %.1f" % renderer.RUN_ANIM_SPEED_MIN)
	n.set_meta("run_ground_speed", 0.0)
	n.set_meta("display_speed", 3.0)
	_h.expect(renderer._run_anim_speed_for(n) == 1.0, "uncalibrated_stays_1",
		"没标定的单位必须保持原速")
	n.free()


func _case_hitstop_restores_base(renderer) -> void:
	var actor := Node3D.new()
	var player := AnimationPlayer.new()
	actor.add_child(player)
	add_child(actor)
	renderer._set_model_anim_speed(actor, 2.0)
	_h.expect(is_equal_approx(player.speed_scale, 2.0), "speed_written", "跑步倍率要写到播放器上")
	HitFeedback.freeze_animation(actor, 0.05)
	_h.expect(player.speed_scale == 0.0, "hitstop_freezes", "顿帧要把播放器停住")
	renderer._set_model_anim_speed(actor, 1.5)
	_h.expect(player.speed_scale == 0.0, "hitstop_not_overwritten", "顿帧期间改倍率不能把 0 覆盖掉")
	# 解冻按墙钟判定（Time.get_ticks_msec），headless 下计时器会比墙钟跑得快，
	# 所以这里也按墙钟等，与 battle_hit_feedback_check 一致。
	var until := Time.get_ticks_msec() + 200
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
	_h.expect(is_equal_approx(player.speed_scale, 1.5), "hitstop_restores_base",
		"解冻后应恢复到最新基准倍率 1.5，实际 %.2f" % player.speed_scale)
	renderer._set_model_anim_speed(actor, 1.0)
	_h.expect(player.speed_scale == 1.0, "back_to_1", "离开跑步要回到 1.0")
	actor.queue_free()


func _case_run_lock_covers_slow_tick(renderer) -> void:
	renderer.set_visual_sim_time_scale(1.0)
	_h.expect(is_equal_approx(renderer._run_lock_sec(), renderer.RUN_LOCK_BASE_SEC), "lock_normal_unchanged",
		"正常倍率下跑步锁保持 %.2f 秒" % renderer.RUN_LOCK_BASE_SEC)
	renderer.set_visual_sim_time_scale(0.5)
	var tick_wall: float = renderer.SIM_TICK_SEC / 0.5
	_h.expect(renderer._run_lock_sec() > tick_wall, "lock_covers_slow_tick",
		"0.5 倍慢放时一个逻辑帧 %.2f 秒，跑步锁 %.2f 秒盖不住 —— 每帧都会闪回待机" % [tick_wall, renderer._run_lock_sec()])
	renderer.set_visual_sim_time_scale(1.0)


func _case_display_speed_tracking(renderer) -> void:
	var n := Node3D.new()
	var t := 10.0
	for i in 60:
		n.position = Vector3(0.0, 0.0, 3.0 * (t - 10.0))
		renderer._track_display_speed(n, t)
		t += 1.0 / 60.0
	var v := float(n.get_meta("display_speed", 0.0))
	_h.expect(absf(v - 3.0) < 0.05, "display_speed_converges", "匀速 3.0 应收敛到 3.0，得到 %.3f" % v)
	n.position += Vector3(50.0, 0.0, 0.0)
	renderer._track_display_speed(n, t)
	_h.expect(absf(float(n.get_meta("display_speed", 0.0)) - 3.0) < 0.05, "teleport_ignored",
		"瞬移样本不能计入速度")
	renderer._track_display_speed(n, t)
	_h.expect(absf(float(n.get_meta("display_speed", 0.0)) - 3.0) < 0.05, "same_frame_ignored",
		"同一帧重复刷新（dt=0）不能改速度")
	n.free()


# 结构：Model / Armature / Skeleton3D(根骨 Root)，播放器 root_node 指向 Model。
func _make_rig(skeleton_basis: Basis) -> Dictionary:
	var model := Node3D.new()
	var armature := Node3D.new()
	armature.name = "Armature"
	model.add_child(armature)
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	skeleton.transform.basis = skeleton_basis
	armature.add_child(skeleton)
	skeleton.add_bone("Root")
	skeleton.add_bone("Child")
	skeleton.set_bone_parent(1, 0)
	var player := AnimationPlayer.new()
	model.add_child(player)
	player.root_node = player.get_path_to(model)
	return {"model": model, "skeleton": skeleton, "player": player}


func _position_track(animation: Animation, path: String, values: Array) -> int:
	var track := animation.add_track(Animation.TYPE_POSITION_3D)
	animation.track_set_path(track, NodePath(path))
	for i in values.size():
		animation.position_track_insert_key(track, float(i) * 0.1, values[i])
	return track


func _case_lock_armature_node_track() -> void:
	var rig := _make_rig(Basis.IDENTITY)
	var animation := Animation.new()
	var t := _position_track(animation, "Armature", [Vector3(0, 0, 0), Vector3(0, 0.1, 1.0), Vector3(0, 0, 2.0)])
	var child := _position_track(animation, "Armature/Skeleton3D:Child", [Vector3(0, 1, 0), Vector3(0.3, 1, 0.4)])
	var result: Dictionary = Policy._lock_root_bone_planar_tracks(animation, rig.skeleton, rig.player)
	_h.expect(int(result.tracks) == 1, "armature_track_locked",
		"Armature 节点轨道应锁 1 条（非根骨不动），实际 %d" % int(result.tracks))
	_h.expect(animation.track_get_key_value(t, 2) == Vector3(0, 0, 0), "armature_forward_removed",
		"Armature 前冲没被钉住：%s" % str(animation.track_get_key_value(t, 2)))
	_h.expect(is_equal_approx((animation.track_get_key_value(t, 1) as Vector3).y, 0.1), "armature_bob_kept",
		"竖直起伏要保留")
	_h.expect(animation.track_get_key_value(child, 1) == Vector3(0.3, 1, 0.4), "non_root_untouched",
		"非根骨轨道不能动")
	(rig.model as Node).free()


func _case_lock_z_up_root_bone() -> void:
	# 绕 X 转 -90°：骨架本地 Y 指向水平（前冲写在这），本地 Z 指向上方。
	var rig := _make_rig(Basis(Vector3.RIGHT, -PI * 0.5))
	var animation := Animation.new()
	var t := _position_track(animation, "Armature/Skeleton3D:Root",
		[Vector3(0, 0, 1.0), Vector3(0.02, 0.5, 1.1), Vector3(0, 1.0, 1.0)])
	var result: Dictionary = Policy._lock_root_bone_planar_tracks(animation, rig.skeleton, rig.player)
	_h.expect(int(result.tracks) == 1, "z_up_locked", "Z 向上骨架的根骨轨道应被锁")
	var v1 := animation.track_get_key_value(t, 1) as Vector3
	var v2 := animation.track_get_key_value(t, 2) as Vector3
	_h.expect(v2.is_equal_approx(Vector3(0, 0, 1.0)), "z_up_forward_removed",
		"本地 Y 上的前冲应被钉住：%s" % str(v2))
	_h.expect(v1.is_equal_approx(Vector3(0, 0, 1.1)), "z_up_bob_kept",
		"本地 Z（竖直）起伏应保留、本地 X/Y 归位：%s" % str(v1))
	(rig.model as Node).free()


func _case_lock_y_up_unchanged() -> void:
	var rig := _make_rig(Basis.IDENTITY)
	var animation := Animation.new()
	var values := [Vector3(0.1, 1.0, 0.2), Vector3(0.5, 1.2, 1.5), Vector3(-0.4, 0.9, 3.0)]
	var t := _position_track(animation, "Armature/Skeleton3D:Root", values)
	Policy._lock_root_bone_planar_tracks(animation, rig.skeleton, rig.player)
	for i in values.size():
		var want := Vector3(0.1, (values[i] as Vector3).y, 0.2)
		_h.expect((animation.track_get_key_value(t, i) as Vector3).is_equal_approx(want), "y_up_equivalent",
			"Y 向上骨架必须与旧规则（钉 X/Z、留 Y）一致：第 %d 帧 %s" % [i, str(animation.track_get_key_value(t, i))])
	(rig.model as Node).free()
