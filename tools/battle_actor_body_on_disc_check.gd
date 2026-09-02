extends Node

# V2 P1-04 / F2：身体必须留在自己的圆盘上（播放期实测）。
#
# 玩家看到的缺陷长这样：脚下的 GroundShadow3D / TeamGlow3D 圆盘、血条和名字都在，
# 身体却不在圈上 —— 因为动作 FBX 里烘了位移，而模拟层已经在移动 UnitActor3D。
#
# 与既有两条门禁的分工（三条不重叠）：
#   * model_root_motion_inventory  —— 验**clip 数据**：源位移多大、有没有登记、
#                                     登记的是否被策略归零。
#   * model_root_motion_lock       —— 验**单个已修单位**（圣歌灵）的完整播放契约。
#   * 本条                         —— 验**所有已登记单位**在真实播放期间，
#                                     蒙皮骨架的世界坐标是否真的没离开圆盘半径。
#
# 前两条都只看动画资源里的数字；这一条看的是「播起来之后骨头实际到了哪」，
# 会连带覆盖 wrapper 的 seek、动作节点 transform、策略未生效等资源层看不到的问题。
#
# 只断言**已登记**的动作。未登记的 27 条（19 attack + 8 idle）是已知存量，
# 归 inventory 的棘轮管，需要 Leno 逐项判断是否属于故意扑击/飘浮，不在这里重复计。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const RootMotionPolicy := preload("res://effects/runtime/presentation/ModelRootMotionPolicy.gd")
const UnitActor3D := preload("res://effects/runtime/presentation/UnitActor3D.gd")

const CHECK_NAME := "battle_actor_body_on_disc"

# 与 BattleRenderer._add_3d_unit_readability() 里 GroundShadow3D 的 top_radius 一致。
const SHADOW_RADIUS := 0.26
# 播放采样帧数。要跨过最短的 run clip（约 1.35 秒）。
const SAMPLE_FRAMES := 90

const TABLES := [
	{"kind": "unit", "path": "res://data/units/race_units.json", "key": "units"},
	{"kind": "merc", "path": "res://data/mercenary/mercenaries.json", "key": "mercenaries"},
	{"kind": "monster", "path": "res://data/pve/pve_monsters.json", "key": "monsters"},
	{"kind": "boss", "path": "res://data/boss/bosses.json", "key": "bosses"},
	{"kind": "ally", "path": "res://data/formation/formation_allies.json", "key": "allies"},
]

const ACTION_METHODS := {"idle": "play_idle", "attack": "play_attack", "run": "play_run"}

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var measured := 0
	var worst := 0.0
	var worst_label := ""

	for table in TABLES:
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(table.path)))
		if not (parsed is Dictionary):
			_h.fail("table_parse_failed", "%s JSON 解析失败" % str(table.path))
			continue
		for item in (parsed as Dictionary).get(str(table.key), []):
			var definition := item as Dictionary
			var configured: Variant = definition.get("model_in_place_actions", [])
			if not (configured is Array) or (configured as Array).is_empty():
				continue
			var model_path := str(definition.get("model", ""))
			if model_path.is_empty():
				continue
			var unit_id := str(definition.get("id", ""))
			var results := await _sample(unit_id, model_path, definition, configured as Array)
			for action in results.keys():
				_h.item()
				measured += 1
				var drift := float(results[action])
				if drift > worst:
					worst = drift
					worst_label = "%s/%s" % [unit_id, action]
				_h.expect(drift <= SHADOW_RADIUS, "body_left_its_disc",
					("%s 播放 %s 时身体离开逻辑站位 %.3f，超过圆盘半径 %.2f —— "
						+ "玩家会看到「圈还在、人不见了」")
						% [unit_id, action, drift, SHADOW_RADIUS])

	_h.expect(measured >= 30, "too_few_actions_measured",
		"只量到 %d 个已登记动作，这条门禁等于没跑" % measured)
	_h.note("播放期实测 %d 个已登记动作；最大偏移 %.4f（%s），圆盘半径 %.2f"
		% [measured, worst, worst_label, SHADOW_RADIUS])

	GameState.reset_run()
	await _settle(2)
	_h.finish(get_tree())


# 返回 {action: 播放期间骨架根骨相对 actor 原点的最大水平距离}
func _sample(unit_id: String, model_path: String, definition: Dictionary,
		configured: Array) -> Dictionary:
	var out := {}
	var packed := load(model_path) as PackedScene
	if packed == null:
		_h.fail("model_scene_missing", "%s 的模型场景加载不出来" % unit_id)
		return out
	var root := packed.instantiate() as Node3D
	if root == null:
		_h.fail("model_instantiate_failed", "%s 实例化失败" % unit_id)
		return out
	var actor := UnitActor3D.new()
	actor.set_meta("unit_id", unit_id)
	actor.attach_model(root)
	add_child(actor)
	await _settle(2)
	# 与战斗侧同序：先挂进树，再应用策略。
	RootMotionPolicy.apply_to_actor(actor, definition)
	await _settle(1)

	var nodes_value: Variant = root.get("action_nodes")
	var nodes: Dictionary = nodes_value if nodes_value is Dictionary else {}

	for raw_action in configured:
		var action := str(raw_action).strip_edges().to_lower()
		if not ACTION_METHODS.has(action) or not nodes.has(action):
			continue
		var action_root := nodes[action] as Node3D
		var skeleton := _find_skeleton(action_root)
		if skeleton == null:
			continue
		var root_bone := _root_bone_index(skeleton)
		if root_bone < 0:
			continue
		root.call(str(ACTION_METHODS[action]))
		await _settle(1)
		var origin := actor.global_position
		var maximum := 0.0
		for i in SAMPLE_FRAMES:
			await get_tree().process_frame
			var world := skeleton.global_transform * skeleton.get_bone_global_pose(root_bone).origin
			maximum = maxf(maximum, Vector2(world.x - origin.x, world.z - origin.z).length())
		out[action] = maximum

	actor.queue_free()
	await _settle(1)
	return out


func _root_bone_index(skeleton: Skeleton3D) -> int:
	for i in skeleton.get_bone_count():
		if skeleton.get_bone_parent(i) < 0:
			return i
	return -1


func _find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root as Skeleton3D
	for child in root.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


func _settle(frames: int = 2) -> void:
	for i in frames:
		await get_tree().process_frame
