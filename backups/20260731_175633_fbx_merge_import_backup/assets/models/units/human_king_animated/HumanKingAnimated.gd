extends Node3D

const ACTION_SCENES := {
	"idle": "res://assets/models/units/human_king_animated/idle.fbx",
	"attack": "res://assets/models/units/human_king_animated/attack.fbx",
	"run": "res://assets/models/units/human_king_animated/run.fbx"
}
const BODY_MATERIAL_PATH := "res://assets/models/units/human_king_animated/human_king_body_material.tres"

@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var model_root: Node3D = $ModelRoot

var action_nodes: Dictionary = {}
var action_players: Dictionary = {}
var current_action := "idle"

func _ready() -> void:
	_load_action_models()
	if not animation_player.animation_started.is_connected(_on_proxy_animation_started):
		animation_player.animation_started.connect(_on_proxy_animation_started)
	if not animation_player.animation_finished.is_connected(_on_proxy_animation_finished):
		animation_player.animation_finished.connect(_on_proxy_animation_finished)
	play_idle()

func _process(_delta: float) -> void:
	var proxy_action := String(animation_player.current_animation)
	if ACTION_SCENES.has(proxy_action) and proxy_action != current_action:
		_activate_action(proxy_action, false)
	if current_action == "attack" and not animation_player.is_playing():
		play_idle()
		return
	var internal_player := action_players.get(current_action) as AnimationPlayer
	if internal_player != null and not internal_player.is_playing():
		_play_internal_animation(current_action, false)

func play_idle() -> void:
	animation_player.play("idle")
	_activate_action("idle", false)

func play_attack() -> void:
	animation_player.play("attack")
	_activate_action("attack", true)

func play_run() -> void:
	animation_player.play("run")
	_activate_action("run", false)

func _load_action_models() -> void:
	var material := ResourceLoader.load(BODY_MATERIAL_PATH) as Material
	var ref_armature_scale := Vector3.ONE
	var ref_set := false
	var load_actions: Array = ["idle"] if bool(get_meta("load_idle_only", false)) else ["idle", "attack", "run"]
	for action in load_actions:
		var path := str(ACTION_SCENES.get(action, ""))
		var scene := ResourceLoader.load(path) as PackedScene
		if scene == null:
			push_warning("人王动作 FBX 加载失败：%s" % path)
			continue
		var node := scene.instantiate() as Node3D
		if node == null:
			push_warning("人王动作 FBX 实例化失败：%s" % path)
			continue
		node.name = "%s_model" % action.capitalize()
		node.visible = false
		model_root.add_child(node)
		_cleanup_imported_model_visuals(node)
		# 对齐各 FBX 子骨骼比例，避免 attack 与 idle 大小不一
		var armature := _find_armature_node(node)
		if armature != null:
			if not ref_set:
				ref_armature_scale = armature.scale
				ref_set = true
			else:
				armature.scale = ref_armature_scale
		if material != null:
			_apply_material_override(node, material)
		action_nodes[action] = node
		var player := _find_animation_player(node)
		if player == null:
			push_warning("人王动作缺少 AnimationPlayer：%s" % path)
		action_players[action] = player

func _on_proxy_animation_started(animation_name: StringName) -> void:
	_activate_action(String(animation_name), true)

func _on_proxy_animation_finished(animation_name: StringName) -> void:
	if String(animation_name) == "attack":
		play_idle()

func _activate_action(action: String, restart: bool) -> void:
	if action_nodes.is_empty():
		push_warning("人王没有加载到任何动作子模型，请检查 ACTION_SCENES 路径和 FBX .import。")
		return
	if not action_nodes.has(action):
		push_warning("人王缺少动作子模型：%s，回退 idle。" % action)
		action = "idle"
		if not action_nodes.has(action):
			return
	current_action = action
	for key in action_nodes.keys():
		var node := action_nodes[key] as Node3D
		if node != null:
			node.visible = str(key) == action
	_play_internal_animation(action, restart)

func _play_internal_animation(action: String, restart: bool) -> void:
	var player := action_players.get(action) as AnimationPlayer
	if player == null:
		return
	var animation_name := _best_animation_name(player, action)
	if animation_name.is_empty():
		return
	if restart:
		player.stop()
	player.play(animation_name)
	if action == "attack":
		player.seek(0.0, true)
		player.advance(0.001)

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
		if lower.contains("mixamo"):
			score += 100.0
		if lower.contains("take"):
			score += 10.0
		if score > best_score:
			best_score = score
			best_name = text
	if best_name.is_empty():
		best_name = String(names[0])
	# DEBUG：显示 attack.fbx 里所有 track 和最终选中的
	if action == "attack":
		print("[人王 DEBUG] attack.fbx 里的所有动画 track：", names)
		print("[人王 DEBUG] 选中的 track：%s（长度 %.2fs）" % [best_name, player.get_animation(best_name).length if player.get_animation(best_name) else 0.0])
	var best_animation := player.get_animation(best_name)
	if best_animation != null:
		best_animation.loop_mode = Animation.LOOP_LINEAR if action != "attack" else Animation.LOOP_NONE
	return best_name

func _action_aliases(action: String) -> Array[String]:
	match action:
		"idle":
			return ["idle", "idel", "stand", "breath"]
		"attack":
			return ["attack", "punch", "slash", "hit", "cast"]
		"run":
			return ["run", "walk", "move", "catwalk", "relaxed"]
		_:
			return []

func _find_animation_player(root: Node) -> AnimationPlayer:
	if root is AnimationPlayer:
		return root as AnimationPlayer
	for child in root.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null

func _cleanup_imported_model_visuals(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is Light3D or node is Camera3D:
			node.queue_free()

func _apply_material_override(root: Node, material: Material) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			var mesh_instance := node as MeshInstance3D
			var surface_count := 1
			if mesh_instance.mesh != null:
				surface_count = max(1, mesh_instance.mesh.get_surface_count())
			for i in range(surface_count):
				mesh_instance.set_surface_override_material(i, material)
		for child in node.get_children():
			stack.append(child)

func _find_armature_node(root: Node) -> Node3D:
	# 返回第一个直属 Node3D 子节点（通常是 Armature/骨架根）
	for child in root.get_children():
		if child is Node3D and not (child is AnimationPlayer):
			return child as Node3D
	return null
