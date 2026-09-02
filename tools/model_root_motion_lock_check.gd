extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const RootMotionPolicy := preload("res://effects/runtime/presentation/ModelRootMotionPolicy.gd")
const UnitActor3D := preload("res://effects/runtime/presentation/UnitActor3D.gd")
const CHECK_NAME := "model_root_motion_lock"
const MODEL_SCENE := "res://assets/models/monsters/sky/pve_sky_hymn_spirit_animated/pve_sky_hymn_spirit_animated.tscn"
const ATTACK_SCENE := "res://assets/models/monsters/sky/pve_sky_hymn_spirit_animated/pve_sky_hymn_spirit_attack.fbx"
const RUN_SCENE := "res://assets/models/monsters/sky/pve_sky_hymn_spirit_animated/pve_sky_hymn_spirit_walking.fbx"
const MONSTER_TABLE := "res://data/pve/pve_monsters.json"
const RENDERER_SOURCE := "res://scenes/battle/BattleRenderer.gd"
const EPS := 0.001

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var source := _load_action(ATTACK_SCENE)
	var run_source := _load_action(RUN_SCENE)
	if source.is_empty() or run_source.is_empty():
		_h.finish(get_tree())
		return
	var source_animation: Animation = source.animation
	var source_skeleton: Skeleton3D = source.skeleton
	var source_span := _root_planar_span(source_animation, source_skeleton)
	_h.expect(source_span > EPS, "source_scenario_vacuous",
		"攻击 FBX 的根骨水平位移只有 %.6f；删除原地化逻辑后门禁也不会红" % source_span)
	var source_root: Node = source.root
	var run_source_animation: Animation = run_source.animation
	var run_source_skeleton: Skeleton3D = run_source.skeleton
	var run_source_span := _root_planar_span(run_source_animation, run_source_skeleton)
	_h.expect(run_source_span > 0.26, "run_source_scenario_vacuous",
		"奔跑 FBX 的根骨水平位移 %.6f 没有超出圆盘半径" % run_source_span)
	var run_source_root: Node = run_source.root
	source_root.queue_free()
	run_source_root.queue_free()
	await get_tree().process_frame

	var unit_def := _hymn_def()
	_h.expect(not unit_def.is_empty(), "unit_def_missing", "pve_sky_hymn_spirit 数据不存在")
	# 2026-09-02 由「恰好等于 ["attack"]」放宽成「包含 attack」。
	# 原写法把这个单位钉死在只能登记一个动作上，而全量清点
	# （model_root_motion_inventory）实测：它的 attack 位移 ≤ 0.26、身体还在脚下圆盘里，
	# 真正会让玩家看到「圈在人不见」的是 run = 2.998（约 11 倍圆盘半径）。
	# 保持 == 就永远不能给它补上 run，等于用断言锁死了真正的缺陷。
	var configured_actions: Array = unit_def.get("model_in_place_actions", [])
	_h.expect(configured_actions.has("attack") and configured_actions.has("run"),
		"policy_not_configured", "圣歌灵没有同时登记 attack/run 原地化")
	var renderer_text := FileAccess.get_file_as_string(RENDERER_SOURCE)
	_h.expect(renderer_text.contains("ModelRootMotionPolicyScript.apply_to_actor"),
		"battle_hook_missing", "真实战斗创建 actor 后没有应用根位移策略")

	var packed := load(MODEL_SCENE) as PackedScene
	if not _h.expect(packed != null, "wrapper_load_failed", "圣歌灵 wrapper 无法加载"):
		_h.finish(get_tree())
		return
	var model := packed.instantiate() as Node3D
	if not _h.expect(model != null, "wrapper_instantiate_failed", "圣歌灵 wrapper 不是 Node3D"):
		_h.finish(get_tree())
		return
	var actor := UnitActor3D.new()
	actor.set_meta("unit_id", "pve_sky_hymn_spirit")
	actor.set_meta("resolved_visual", unit_def)
	actor.attach_model(model)
	add_child(actor)
	for _i in 3:
		await get_tree().process_frame
	var policy_result := RootMotionPolicy.apply_to_actor(actor, unit_def)
	_h.expect(bool(policy_result.get("requested", false)), "policy_not_requested",
		"数据开关没有触发根位移策略")
	_h.expect(int(policy_result.get("locked_tracks", 0)) > 0,
		"policy_locked_nothing", "根位移策略没有锁定任何轨道")
	_h.note("源攻击根骨水平位移 %.4f；原地化后目标上限 %.4f" % [
		float(policy_result.get("source_planar_span", 0.0)), EPS])

	var players_value: Variant = model.get("action_players")
	var nodes_value: Variant = model.get("action_nodes")
	var players: Dictionary = players_value if players_value is Dictionary else {}
	var nodes: Dictionary = nodes_value if nodes_value is Dictionary else {}
	var attack_player := players.get("attack") as AnimationPlayer
	var attack_root := nodes.get("attack") as Node3D
	_h.expect(attack_player != null, "attack_player_missing", "运行时没有 attack AnimationPlayer")
	_h.expect(attack_root != null, "attack_root_missing", "运行时没有 attack 动作节点")
	if attack_player != null and attack_root != null:
		var attack_name := _best_animation_name(attack_player)
		var attack_animation := attack_player.get_animation(attack_name)
		var attack_skeleton := _find_skeleton(attack_root)
		_h.expect(attack_animation != null, "attack_animation_missing", "运行时攻击动画不存在")
		_h.expect(attack_skeleton != null, "attack_skeleton_missing", "运行时攻击骨架不存在")
		if attack_animation != null and attack_skeleton != null:
			var locked_span := _root_planar_span(attack_animation, attack_skeleton)
			_h.expect(locked_span <= EPS, "root_motion_not_locked",
				"攻击动画原地化后根骨仍水平移动 %.6f（圆盘半径 0.26）" % locked_span)
			_h.expect(is_equal_approx(attack_animation.length, source_animation.length),
				"attack_length_changed", "原地化改变了攻击时长")
		_h.expect(int(attack_player.get_meta("in_place_root_tracks", 0)) > 0,
			"no_track_was_locked", "wrapper 没有记录任何被锁定的根骨轨道")
		_h.expect(float(attack_player.get_meta("in_place_source_planar_span", 0.0)) > EPS,
			"source_motion_not_recorded", "wrapper 没有记录源攻击动画的真实水平位移")

		var start_position := attack_root.position
		model.call("play_attack")
		for sample in 12:
			await get_tree().process_frame
			_h.expect(Vector2(attack_root.position.x, attack_root.position.z).distance_to(
				Vector2(start_position.x, start_position.z)) <= EPS,
				"action_node_drifted", "攻击播放第 %d 个采样时动作节点离开逻辑站位" % sample)

	var idle_root := nodes.get("idle") as Node3D
	var run_root := nodes.get("run") as Node3D
	_h.expect(idle_root != null and run_root != null, "other_actions_missing", "idle/run 动作节点被破坏")
	var run_player := players.get("run") as AnimationPlayer
	_h.expect(run_player != null, "run_player_missing", "运行时没有 run AnimationPlayer")
	if run_player != null and run_root != null:
		var run_name := _best_animation_name(run_player)
		var run_animation := run_player.get_animation(run_name)
		var run_skeleton := _find_skeleton(run_root)
		_h.expect(run_animation != null, "run_animation_missing", "运行时奔跑动画不存在")
		_h.expect(run_skeleton != null, "run_skeleton_missing", "运行时奔跑骨架不存在")
		if run_animation != null and run_skeleton != null:
			var locked_run_span := _root_planar_span(run_animation, run_skeleton)
			_h.expect(locked_run_span <= EPS, "run_root_motion_not_locked",
				"奔跑动画原地化后根骨仍水平移动 %.6f（圆盘半径 0.26）" % locked_run_span)
			_h.expect(is_equal_approx(run_animation.length, run_source_animation.length),
				"run_length_changed", "原地化改变了奔跑时长")
			_h.expect(int(run_player.get_meta("in_place_root_tracks", 0)) > 0,
				"run_track_not_locked", "wrapper 没有记录被锁定的奔跑根骨轨道")
			_h.expect(float(run_player.get_meta("in_place_source_planar_span", 0.0)) > 0.26,
				"run_source_motion_not_recorded", "wrapper 没有记录奔跑动画的超标水平位移")
	model.call("play_idle")
	await get_tree().process_frame
	_h.expect(str(model.get("current_action")) == "idle", "idle_contract_broken", "play_idle() 合同失效")
	model.call("play_run")
	await get_tree().process_frame
	_h.expect(str(model.get("current_action")) == "run", "run_contract_broken", "play_run() 合同失效")

	actor.queue_free()
	await get_tree().process_frame
	_h.finish(get_tree())


func _hymn_def() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MONSTER_TABLE))
	if not (parsed is Dictionary):
		return {}
	for raw in (parsed as Dictionary).get("monsters", []):
		if raw is Dictionary and str((raw as Dictionary).get("id", "")) == "pve_sky_hymn_spirit":
			return (raw as Dictionary).duplicate(true)
	return {}


func _load_action(path: String) -> Dictionary:
	var packed := load(path) as PackedScene
	if not _h.expect(packed != null, "source_load_failed", "攻击 FBX 无法加载：%s" % path):
		return {}
	var root := packed.instantiate()
	if not _h.expect(root != null, "source_instantiate_failed", "攻击 FBX 无法实例化"):
		return {}
	var player := _find_animation_player(root)
	var skeleton := _find_skeleton(root)
	_h.expect(player != null, "source_player_missing", "攻击 FBX 没有 AnimationPlayer")
	_h.expect(skeleton != null, "source_skeleton_missing", "攻击 FBX 没有 Skeleton3D")
	if player == null or skeleton == null:
		root.queue_free()
		return {}
	var animation_name := _best_animation_name(player)
	var animation := player.get_animation(animation_name)
	if not _h.expect(animation != null, "source_animation_missing", "攻击 FBX 没有可用动画"):
		root.queue_free()
		return {}
	return {"root": root, "animation": animation, "skeleton": skeleton}


func _best_animation_name(player: AnimationPlayer) -> String:
	var best := ""
	var best_length := -1.0
	for raw_name in player.get_animation_list():
		var name := str(raw_name)
		if name.to_lower().contains("reset"):
			continue
		var animation := player.get_animation(name)
		if animation != null and animation.length > best_length:
			best = name
			best_length = animation.length
	return best


func _root_planar_span(animation: Animation, skeleton: Skeleton3D) -> float:
	var roots := {}
	for bone_index in skeleton.get_bone_count():
		if skeleton.get_bone_parent(bone_index) < 0:
			roots[str(skeleton.get_bone_name(bone_index))] = true
	var maximum := 0.0
	for track_index in animation.get_track_count():
		if animation.track_get_type(track_index) != Animation.TYPE_POSITION_3D:
			continue
		var bone_name := str(animation.track_get_path(track_index)).get_slice(":", 1)
		if not roots.has(bone_name) or animation.track_get_key_count(track_index) <= 0:
			continue
		var first := animation.track_get_key_value(track_index, 0) as Vector3
		var origin := Vector2(first.x, first.z)
		for key_index in animation.track_get_key_count(track_index):
			var value := animation.track_get_key_value(track_index, key_index) as Vector3
			maximum = maxf(maximum, origin.distance_to(Vector2(value.x, value.z)))
	return maximum


func _find_animation_player(root: Node) -> AnimationPlayer:
	if root is AnimationPlayer:
		return root as AnimationPlayer
	for child in root.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null


func _find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root as Skeleton3D
	for child in root.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null
