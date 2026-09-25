extends Node

# 根位移全量清点门禁。
#
# 背景：动作 FBX 里可能烘了位移（角色自己往前走），而 Glory 的模拟层已经在移动
# UnitActor3D。两者叠加时，只有蒙皮的身体离开了它的逻辑格子，**脚下的
# GroundShadow3D / TeamGlow3D 圆盘、血条和 VFX 锚点全都留在原地** ——
# 玩家看到的就是「圈还在、人不见了」。
#
# `ModelRootMotionPolicy` 已经能把指定动作原地化，但它是**按单位逐项开关**的
# （数据字段 `model_in_place_actions`）。所以真正的风险不是「策略不存在」，
# 而是「有多少单位 × 动作还没被登记」。这条门禁就数这个。
#
# 与 `model_root_motion_lock_check` 的分工：那条锁死单个已修单位的播放行为契约
# （pve_sky_hymn_spirit 的 attack/run），这条负责全量存量，并逐项证明所有已登记
# 动作确实通过真实运行时策略归零，避免“只写了数据字段”的假绿。
#
# 判据是棘轮：未登记且超出圆盘半径的动作数**只降不升**。
# 不做硬失败，是因为逐个单位补 `model_in_place_actions` 是数据/策略决定，
# 归 P1-04 的负责人，不该由这条门禁替他们一次性做完。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const RootMotionPolicy := preload("res://effects/runtime/presentation/ModelRootMotionPolicy.gd")
const UnitActor3D := preload("res://effects/runtime/presentation/UnitActor3D.gd")

const CHECK_NAME := "model_root_motion_inventory"

# 与 BattleRenderer._add_3d_unit_readability() 里 GroundShadow3D 的半径一致。
# 身体在这个半径内飘是看不出来的；超出去就开始「人圈分离」。
const SHADOW_RADIUS := 0.26
const LOCK_EPS := 0.001

# 未登记且超标的「单位 × 动作」数量上限。**只降不升。**
#
# 2026-09-02 首次全量清点实测 59（72 个模型、218 个单位×动作）。
# 同日把 32 条 `run` 全部登记之后降到 27 —— 剩下的正好是
# **19 条 attack + 8 条 idle**，两者都可能是故意设计的位移
# （扑击、飘浮），必须逐个人工判断，不能批量登记。
# 每处理一条就把这个数字调低；新增带根位移的模型会立刻顶破这条线。
# 2026-09-25: restore 32 missing run registrations and the hymn attack policy;
# register 14 measured non-returning attack/idle clips. Keep the 13 returning
# lunges/sways authored by the artist; they are not locomotion bugs.
const MAX_UNREGISTERED := 13

const POLICY_KEY := "model_in_place_actions"

const TABLES := [
	{"kind": "unit", "path": "res://data/units/race_units.json", "key": "units"},
	{"kind": "merc", "path": "res://data/mercenary/mercenaries.json", "key": "mercenaries"},
	{"kind": "monster", "path": "res://data/pve/pve_monsters.json", "key": "monsters"},
	{"kind": "boss", "path": "res://data/boss/bosses.json", "key": "bosses"},
	{"kind": "ally", "path": "res://data/formation/formation_allies.json", "key": "allies"},
]

var _h: CheckHarness
var _runtime_verified_actions := 0


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var rows: Array[Dictionary] = []
	var unregistered := 0
	var registered := 0
	var scanned := 0

	for table in TABLES:
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(table.path)))
		if not (parsed is Dictionary):
			_h.fail("table_parse_failed", "%s JSON 解析失败" % str(table.path))
			continue
		for item in (parsed as Dictionary).get(str(table.key), []):
			var definition := item as Dictionary
			var model_path := str(definition.get("model", ""))
			if model_path.is_empty():
				continue
			var unit_id := str(definition.get("id", ""))
			var configured := _configured_actions(definition)
			var measured := await _measure(unit_id, model_path, definition, configured)
			if measured.is_empty():
				continue
			scanned += 1
			for action in measured.keys():
				_h.item()
				var span := float(measured[action])
				if span <= SHADOW_RADIUS:
					continue
				var is_registered := configured.has(str(action))
				if is_registered:
					registered += 1
				else:
					unregistered += 1
				rows.append({
					"id": unit_id, "kind": str(table.kind), "action": str(action),
					"span": span, "registered": is_registered,
				})

	_h.expect(scanned >= 60, "too_few_models_scanned",
		"只扫到 %d 个模型，这条门禁等于没跑" % scanned)
	# 非空过守卫：棘轮最危险的失效模式是“测量链断了 -> 数出 0 -> 继续绿”。
	# 登记只在运行时原地化、**不改 FBX**，所以源 clip 的位移永远存在：
	# 即使将来 59 条全补完，这条断言依然成立。
	var peak := 0.0
	for row in rows:
		peak = maxf(peak, float(row["span"]))
	_h.expect(peak > SHADOW_RADIUS, "measurement_vacuous",
		("全扫下来最大根骨位移只有 %.4f，低于圆盘半径 %.2f —— "
			+ "测量链已经断了，这条门禁现在只是在空转") % [peak, SHADOW_RADIUS])

	rows.sort_custom(func(a, b): return float(a["span"]) > float(b["span"]))
	_h.note("扫描 %d 个模型；超出圆盘半径 %.2f 的动作 %d 个（已登记 %d、未登记 %d）"
		% [scanned, SHADOW_RADIUS, rows.size(), registered, unregistered])
	_h.note("运行时逐项验证 %d 个已登记动作：策略锁定成功且锁后水平位移 <= %.3f"
		% [_runtime_verified_actions, LOCK_EPS])
	# 全部列出：这份日志就是 P1-04 负责人逐个补 model_in_place_actions 的工作清单，
	# 截断就等于让他们自己再跑一遍。
	for row in rows:
		_h.note("  %-28s %-6s %-7s span=%.3f%s" % [
			str(row["id"]), str(row["kind"]), str(row["action"]), float(row["span"]),
			"  [已登记]" if bool(row["registered"]) else ""])

	_h.expect(unregistered <= MAX_UNREGISTERED, "root_motion_backlog_grew",
		("未登记且超出圆盘半径的动作有 %d 个，上限 %d（只降不升）。"
			+ "每给一个单位补上 %s 就把上限调低；新增模型带根位移会立刻顶破这条线。")
			% [unregistered, MAX_UNREGISTERED, POLICY_KEY])

	_h.finish(get_tree())


func _configured_actions(definition: Dictionary) -> Array:
	var raw: Variant = definition.get(POLICY_KEY, [])
	var out: Array = []
	if raw is Array:
		for value in (raw as Array):
			out.append(str(value).strip_edges().to_lower())
	return out


# 返回 {action: 根骨水平位移最大值}。拿不到就返回空字典；有数据开关时还会把
# 同一个 wrapper 挂到真实 UnitActor3D，调用 ModelRootMotionPolicy 后逐项复测。
func _measure(unit_id: String, model_path: String, definition: Dictionary,
		configured: Array) -> Dictionary:
	var out := {}
	var packed := load(model_path) as PackedScene
	if packed == null:
		_h.fail("model_scene_missing", "%s 的模型场景加载不出来：%s" % [unit_id, model_path])
		return out
	var root := packed.instantiate() as Node3D
	if root == null:
		_h.fail("model_instantiate_failed", "%s 实例化失败：%s" % [unit_id, model_path])
		return out
	var actor := UnitActor3D.new()
	actor.set_meta("unit_id", unit_id)
	actor.set_meta("resolved_visual", definition)
	actor.attach_model(root)
	add_child(actor)
	await get_tree().process_frame

	var model_root := root.get_node_or_null("ModelRoot")
	var action_roots := {}
	if model_root != null:
		for child in model_root.get_children():
			var action := _action_of(str(child.name))
			if action.is_empty():
				continue
			action_roots[action] = child
			out[action] = _max_planar_span(child, action)
	if not configured.is_empty():
		_verify_configured_policy(unit_id, definition, configured, out, action_roots, actor)
	actor.queue_free()
	await get_tree().process_frame
	return out


func _verify_configured_policy(unit_id: String, definition: Dictionary,
		configured: Array, source_spans: Dictionary, action_roots: Dictionary,
		actor: UnitActor3D) -> void:
	var policy_result := RootMotionPolicy.apply_to_actor(actor, definition)
	_h.expect(bool(policy_result.get("requested", false)), "policy_not_requested",
		"%s 已登记动作但运行时策略没有启动" % unit_id)
	var results_value: Variant = policy_result.get("actions", [])
	var action_results: Array = results_value if results_value is Array else []
	for action_value in configured:
		var action := str(action_value)
		var source_span := float(source_spans.get(action, 0.0))
		var action_root := action_roots.get(action) as Node
		var action_result := _policy_result_for(action_results, action)
		_h.expect(source_spans.has(action) and action_root != null,
			"configured_action_missing", "%s 已登记 %s，但 wrapper 没有这个动作" % [unit_id, action])
		_h.expect(source_span > RootMotionPolicy.ROOT_MOTION_EPS,
			"configured_action_vacuous", "%s/%s 已登记原地化，但源根骨没有可锁水平位移" % [unit_id, action])
		_h.expect(not action_result.is_empty(), "policy_action_result_missing",
			"%s/%s 没有运行时策略结果" % [unit_id, action])
		_h.expect(int(action_result.get("locked_tracks", 0)) > 0,
			"policy_action_locked_nothing", "%s/%s 没有锁定任何根骨轨道" % [unit_id, action])
		if action_root != null:
			var locked_span := _max_planar_span(action_root, action)
			_h.expect(locked_span <= LOCK_EPS, "registered_action_not_locked",
				"%s/%s 策略执行后根骨仍水平移动 %.6f" % [unit_id, action, locked_span])
		_runtime_verified_actions += 1


func _policy_result_for(results: Array, action: String) -> Dictionary:
	for value in results:
		if value is Dictionary and str((value as Dictionary).get("action", "")) == action:
			return value as Dictionary
	return {}


# 包装脚本把动作节点命名成 Idle_model / Attack_model / Run_model。
func _action_of(node_name: String) -> String:
	var lower := node_name.to_lower()
	if lower.begins_with("idle"):
		return "idle"
	if lower.begins_with("attack"):
		return "attack"
	if lower.begins_with("run"):
		return "run"
	return ""


# 只量**包装脚本实际会播的那条** clip，不是取所有 clip 的最大值。
# 241 个 FBX 里有 14 个含多条动画；取最大值会把根本不会被播到的 clip 也算进来，
# 那是实打实的误报。评分规则与 `*_Animated.gd` 的 `_best_animation_name()` 一致。
func _max_planar_span(action_root: Node, action: String) -> float:
	var player := _find_animation_player(action_root)
	var skeleton := _find_skeleton(action_root)
	if player == null or skeleton == null:
		return 0.0
	var chosen := _best_animation_name(player, action)
	if chosen.is_empty():
		return 0.0
	var animation := player.get_animation(chosen)
	if animation == null:
		return 0.0
	return _root_planar_span(animation, skeleton)


func _best_animation_name(player: AnimationPlayer, action: String) -> String:
	var names := player.get_animation_list()
	if names.is_empty():
		return ""
	var best_name := ""
	var best_score := -999999.0
	for name in names:
		var text := String(name)
		var lower := text.to_lower()
		var animation := player.get_animation(text)
		var length := animation.length if animation != null else 0.0
		var score := length
		if lower.contains("reset"):
			score -= 10000.0
		for alias in _action_aliases(action):
			if lower.contains(alias):
				score += 1000.0
		if score > best_score:
			best_score = score
			best_name = text
	return best_name


func _action_aliases(action: String) -> Array[String]:
	match action:
		"idle":
			return ["idle", "idel", "stand", "breath"]
		"attack":
			return ["attack", "punch", "slash", "hit", "cast"]
		"run":
			return ["run", "walk", "move", "catwalk"]
		_:
			return []


# 与 model_root_motion_lock_check 里的量法逐字一致，两条门禁的数字才可比：
# 只看无父骨骼（根骨）的 POSITION_3D 轨道，取相对第一帧的最大水平位移。
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
