extends SceneTree

# 逐个实例化合并后的角色场景，确认三个动作都能解析、都能播、轨道都能落到骨架上。
# 这是批量改完 67 个角色之后的回归检查。

# 检查必须在 _process 里做，不能在 _init 里：_init 阶段 root 还没进树，
# add_child() 不会触发 _ready，模型也就不会被建起来。
func _process(_delta: float) -> bool:
	var scenes := _collect_scenes("res://assets/models")
	scenes.sort()
	var pass_count := 0
	var problems: Array[String] = []

	for path in scenes:
		var scene := ResourceLoader.load(path) as PackedScene
		if scene == null:
			problems.append("%s: 场景加载失败" % path)
			continue
		var node := scene.instantiate()
		if node == null:
			problems.append("%s: 实例化失败" % path)
			continue
		root.add_child(node)   # 触发 _ready
		var issues := _check(node, path)
		if issues.is_empty():
			pass_count += 1
		else:
			problems.append_array(issues)
		root.remove_child(node)
		node.free()

	print("")
	print("=== 合并后角色场景检查：%d/%d 通过 ===" % [pass_count, scenes.size()])
	for p in problems:
		print("  " + p)
	quit(0 if problems.is_empty() else 1)
	return true

func _collect_scenes(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not name.begins_with("."):
			var full := dir_path.path_join(name)
			if dir.current_is_dir():
				out.append_array(_collect_scenes(full))
			elif name.ends_with(".tscn"):
				# 只看挂了新基类的场景
				var text := FileAccess.get_file_as_string(full)
				if text.contains("UnitActionModel.gd"):
					out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	return out

func _check(node: Node, path: String) -> Array[String]:
	var issues: Array[String] = []
	var short := path.get_base_dir().get_file()

	var player := _find_player(node)
	if player == null:
		issues.append("%s: 没有 AnimationPlayer（模型没建起来）" % short)
		return issues

	var skeleton := _find_skeleton(node)
	if skeleton == null:
		issues.append("%s: 没有 Skeleton3D" % short)
		return issues

	# 三个动作各播一次，确认真的切到了不同动画且在播
	var seen := {}
	for action in ["idle", "attack", "run"]:
		node.call("play_" + action)
		var current := String(player.current_animation)
		if current.is_empty():
			issues.append("%s: play_%s 之后没有动画在播" % [short, action])
			continue
		seen[action] = current
	if seen.size() == 3 and seen["idle"] == seen["attack"] and seen["attack"] == seen["run"]:
		issues.append("%s: 三个动作解析到同一条动画（%s）" % [short, seen["idle"]])

	# 每条动画的轨道都要能落到目标节点上。必须先把节点路径解析出来再判断，
	# 不能见到冒号就当骨骼名——像 Armature:position 这种轨道的冒号后面是属性名，
	# 拿去 find_bone 一定找不到，会报一堆假问题。
	var anim_root := player.get_node_or_null(player.root_node)
	if anim_root == null:
		issues.append("%s: AnimationPlayer.root_node 解析不到（%s）" % [short, player.root_node])
		return issues
	for anim_name in player.get_animation_list():
		var anim := player.get_animation(anim_name)
		if anim == null:
			continue
		var unresolved := 0
		for t in anim.get_track_count():
			var track_path := String(anim.track_get_path(t))
			var target := anim_root.get_node_or_null(NodePath(track_path.get_slice(":", 0)))
			if target == null:
				unresolved += 1
				continue
			var sub := track_path.get_slice(":", 1)
			if target is Skeleton3D and not sub.is_empty() and (target as Skeleton3D).find_bone(sub) < 0:
				unresolved += 1
		if unresolved > 0:
			issues.append("%s: 动画 %s 有 %d/%d 条轨道解析不到" % [short, anim_name, unresolved, anim.get_track_count()])
	return issues

func _find_player(root_node: Node) -> AnimationPlayer:
	if root_node is AnimationPlayer:
		return root_node as AnimationPlayer
	for c in root_node.get_children():
		var f := _find_player(c)
		if f != null: return f
	return null

func _find_skeleton(root_node: Node) -> Skeleton3D:
	if root_node is Skeleton3D:
		return root_node as Skeleton3D
	for c in root_node.get_children():
		var f := _find_skeleton(c)
		if f != null: return f
	return null
