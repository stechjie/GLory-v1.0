class_name ModelRootMotionPolicy
extends RefCounted

# Imported attack clips may contain authored locomotion even though Glory's
# authoritative simulation already moves the UnitActor3D. When such a clip is
# played directly, only the skinned body leaves its logical cell while the
# shadow, team ring, health bar and VFX anchors stay behind. This policy turns
# explicitly configured actions into in-place clips once, when the actor enters
# the battle tree. It never edits the imported FBX resource on disk.

const CONFIG_KEY := "model_in_place_actions"
const ROOT_MOTION_EPS := 0.0005


static func apply_to_actor(actor: Node, unit_def: Dictionary) -> Dictionary:
	var configured_value: Variant = unit_def.get(CONFIG_KEY, [])
	var configured: Array = configured_value if configured_value is Array else []
	var result := {
		"requested": not configured.is_empty(),
		"locked_tracks": 0,
		"source_planar_span": 0.0,
		"actions": [],
	}
	if configured.is_empty() or actor == null:
		return result
	var visual := _visual_root(actor)
	if visual == null:
		actor.set_meta("root_motion_policy", result)
		return result
	for raw_action in configured:
		var action := str(raw_action).strip_edges().to_lower()
		if action.is_empty():
			continue
		var action_result := _make_action_in_place(visual, action)
		(result.actions as Array).append(action_result)
		result.locked_tracks = int(result.locked_tracks) + int(action_result.get("locked_tracks", 0))
		result.source_planar_span = maxf(float(result.source_planar_span),
			float(action_result.get("source_planar_span", 0.0)))
	actor.set_meta("root_motion_policy", result)
	return result


static func _make_action_in_place(visual: Node, action: String) -> Dictionary:
	var out := {
		"action": action,
		"locked_tracks": 0,
		"source_planar_span": 0.0,
		"animation": "",
	}
	var action_root := _action_root(visual, action)
	if action_root == null:
		# 单播放器模型（如 god_guard_refined）没有 Run_model 这类分动作节点，
		# 所有动作都在同一个 AnimationPlayer 里。只有整棵树恰好一个播放器时才这样取，
		# 分节点包装缺某个动作时不能退回去锁到别的动作分支上。
		if _count_animation_players(visual) != 1:
			return out
		action_root = visual
	var player := _find_animation_player(action_root)
	var skeleton := _find_skeleton(action_root)
	if player == null or skeleton == null:
		return out
	var animation_name := _best_animation_name(player, action)
	var source := player.get_animation(animation_name) if not animation_name.is_empty() else null
	if source == null:
		return out
	var private_animation := source.duplicate(true) as Animation
	var lock_result := _lock_root_bone_planar_tracks(private_animation, skeleton, player)
	out.animation = animation_name
	out.locked_tracks = int(lock_result.get("tracks", 0))
	out.source_planar_span = float(lock_result.get("source_span", 0.0))
	if int(out.locked_tracks) <= 0:
		return out
	if not _replace_default_library_animation(player, animation_name, private_animation):
		out.locked_tracks = 0
		return out
	player.set_meta("in_place_root_tracks", int(out.locked_tracks))
	player.set_meta("in_place_source_planar_span", float(out.source_planar_span))
	return out


static func _lock_root_bone_planar_tracks(animation: Animation,
		skeleton: Skeleton3D, player: AnimationPlayer = null) -> Dictionary:
	var root_bones := root_bone_names(skeleton)
	var locked := 0
	var source_span := 0.0
	for track_index in animation.get_track_count():
		if animation.track_get_type(track_index) != Animation.TYPE_POSITION_3D:
			continue
		var space := root_motion_track_space(animation, track_index, root_bones, skeleton, player)
		if space == null:
			continue
		var key_count := animation.track_get_key_count(track_index)
		if key_count <= 0:
			continue
		var up := local_up(space)
		var first := animation.track_get_key_value(track_index, 0) as Vector3
		var track_span := 0.0
		for key_index in key_count:
			var value := animation.track_get_key_value(track_index, key_index) as Vector3
			track_span = maxf(track_span, planar_offset(value - first, up).length())
		if track_span <= ROOT_MOTION_EPS:
			continue
		for key_index in key_count:
			var value := animation.track_get_key_value(track_index, key_index) as Vector3
			# 只留竖直分量（起伏），水平面内一律钉在第一帧。
			animation.track_set_key_value(track_index, key_index,
				first + up * (value - first).dot(up))
		locked += 1
		source_span = maxf(source_span, track_span)
	return {"tracks": locked, "source_span": source_span}


static func root_bone_names(skeleton: Skeleton3D) -> Dictionary:
	var root_bones := {}
	for bone_index in skeleton.get_bone_count():
		if skeleton.get_bone_parent(bone_index) < 0:
			root_bones[str(skeleton.get_bone_name(bone_index))] = true
	return root_bones


# 根位移轨道有两种，返回轨道数值所在的坐标空间节点；不是根位移轨道返回 null：
#   * 根骨轨道（`Skeleton3D:RL_BoneRoot`、`...:mixamorig_Hips`）—— 数值在骨架空间；
#   * 骨架自身或其祖先节点的轨道（`Armature`）—— 数值在该节点父级空间。Reallusion
#     角色经 Mixamo 导出的跑步片段把整段前进写在 Armature 节点上，根骨不动 —— 只认根骨
#     时这类片段锁 0 条，身体照样每圈往前冲一段再弹回（2026-10-29 实测
#     cancer/gemini/scorpio/aquarius）。
# 节点轨道按播放器的 root_node 解析，别的节点（武器、特效挂点）不动。
static func root_motion_track_space(animation: Animation, track_index: int,
		root_bones: Dictionary, skeleton: Skeleton3D, player: AnimationPlayer) -> Node:
	var path := animation.track_get_path(track_index)
	if path.get_subname_count() > 0:
		return skeleton if root_bones.has(str(path.get_subname(0))) else null
	if player == null or skeleton == null:
		return null
	var base := player.get_node_or_null(player.root_node)
	if base == null:
		return null
	var target := base.get_node_or_null(NodePath(str(path)))
	if not (target is Node3D):
		return null
	if target != skeleton and not (target as Node).is_ancestor_of(skeleton):
		return null
	return target.get_parent()


# 某坐标空间里的「竖直向上」。不能写死本地 Y：Blender 导出的 Z 向上骨架
# （merc_virgo_heal）前进写在根骨本地 Y 上，按 X/Z 锁只锁掉了左右晃，前冲原样保留。
# 沿父链累乘本地变换，不依赖节点已在场景树里；Y 向上的骨架结果就是 (0,1,0)，
# 与旧的 X/Z 锁定逐字等价。
static func local_up(space: Node) -> Vector3:
	var basis := Basis.IDENTITY
	var node := space
	while node != null:
		if node is Node3D:
			basis = (node as Node3D).transform.basis * basis
		node = node.get_parent()
	var up := basis.inverse() * Vector3.UP
	if up.length_squared() < 0.000001:
		return Vector3.UP
	return up.normalized()


static func planar_offset(delta: Vector3, up: Vector3) -> Vector3:
	return delta - up * delta.dot(up)


static func _count_animation_players(root: Node) -> int:
	var count := 1 if root is AnimationPlayer else 0
	for child in root.get_children():
		count += _count_animation_players(child)
	return count


static func _replace_default_library_animation(player: AnimationPlayer,
		animation_name: String, replacement: Animation) -> bool:
	if not player.has_animation_library(""):
		return false
	var source_library := player.get_animation_library("")
	if source_library == null or not source_library.has_animation(animation_name):
		return false
	var private_library := AnimationLibrary.new()
	for name in source_library.get_animation_list():
		var animation := replacement if str(name) == animation_name else source_library.get_animation(name)
		private_library.add_animation(name, animation)
	player.remove_animation_library("")
	player.add_animation_library("", private_library)
	return true


static func _visual_root(actor: Node) -> Node:
	for property in actor.get_property_list():
		if str(property.get("name", "")) == "visual_root":
			var value: Variant = actor.get("visual_root")
			return value as Node if value is Node else null
	return null


static func _action_root(visual: Node, action: String) -> Node:
	for property in visual.get_property_list():
		if str(property.get("name", "")) != "action_nodes":
			continue
		var value: Variant = visual.get("action_nodes")
		if value is Dictionary:
			var node_value: Variant = (value as Dictionary).get(action)
			if node_value is Node:
				return node_value as Node
		break
	var wanted := "%s_model" % action.to_lower()
	var stack: Array[Node] = [visual]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.name.to_lower() == wanted:
			return node
		for child in node.get_children():
			stack.append(child)
	return null


static func _best_animation_name(player: AnimationPlayer, action: String) -> String:
	var best := ""
	var best_score := -INF
	for raw_name in player.get_animation_list():
		var name := str(raw_name)
		var lower := name.to_lower()
		var animation := player.get_animation(name)
		if animation == null:
			continue
		var score := animation.length
		if lower.contains("reset"):
			score -= 10000.0
		if lower.contains(action):
			score += 1000.0
		if action == "attack" and (lower.contains("slash") or lower.contains("cast")
				or lower.contains("hit") or lower.contains("punch")):
			score += 500.0
		if score > best_score:
			best_score = score
			best = name
	return best


static func _find_animation_player(root: Node) -> AnimationPlayer:
	if root is AnimationPlayer:
		return root as AnimationPlayer
	for child in root.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null


static func _find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root as Skeleton3D
	for child in root.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null
