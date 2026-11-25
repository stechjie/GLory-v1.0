extends Node3D
# 动作分开导出的 FBX 宠物（11-25 起白虎、猴子用）。
#
# 做法和 assets/models/pets/pet_cat/PetCatAnimated.gd 一样：每个动作一个子模型，同一时间只显示
# 一个，全部套同一份 BA 卡通材质。区别只是动作文件和材质由场景里的导出变量指定，
# 不用每只宠物再抄一份脚本：
#   * idle_scene / attack_scene / run_scene：三个动作的模型。可以是同一个文件（猴子的三个动作
#     在一个 FBX 里），按动作名挑片段（ACTION_ALIASES）。attack_scene 不填就回退待机。
#   * body_material：BA 卡通材质（ba_toon + ba_outline）。FBX 导入时丢掉内嵌贴图
#     （.import 里 fbx/embedded_image_handling=0），颜色全靠这份材质 —— 白虎原文件每个 FBX
#     都内嵌同一套 4 张 2048 贴图，不丢掉的话三个动作就是三套进包。
#
# 对外接口与其他宠物相同（PetPreview / MainMenuPet 用 has_method 调）：
#   play_idle()   待机，循环
#   play_run()    跑（走），循环
#   play_attack() 攻击 / 技能，播一遍回到待机
# 模型进树之前就被调用时（PetPreview.build_runner 会这样）先记下，_ready 里补上。

@export var idle_scene: PackedScene
@export var attack_scene: PackedScene
@export var run_scene: PackedScene
@export var body_material: Material

const ACTIONS := ["idle", "attack", "run"]
# 只有这两个动作循环；attack 播完一遍回到 idle。
const LOOPING := {"idle": true, "run": true}
# 片段名里含这些词就优先选它（与 PetCatAnimated._action_aliases 同口径，多了技能类的叫法）。
const ACTION_ALIASES := {
	"idle": ["idle", "idel", "stand", "breath"],
	"attack": ["attack", "punch", "slash", "hit", "skill", "pounce", "jump"],
	"run": ["run", "walk", "move"],
}

@onready var model_root: Node3D = $ModelRoot

var _nodes: Dictionary = {}    # 动作 -> 子模型
var _players: Dictionary = {}  # 动作 -> 子模型里的 AnimationPlayer
var _clips: Dictionary = {}    # 动作 -> 选中的片段名
var _current := ""
var _pending := "idle"


func _ready() -> void:
	_load_action_models()
	_activate(_pending, true)


func _process(_delta: float) -> void:
	if _current != "attack":
		return
	var player := _players.get("attack") as AnimationPlayer
	if player == null or not player.is_playing():
		play_idle()


func play_idle() -> void:
	_request("idle", false)


func play_run() -> void:
	_request("run", false)


func play_attack() -> void:
	_request("attack", true)


func _request(action: String, restart: bool) -> void:
	if not is_node_ready():
		_pending = action
		return
	_activate(action, restart)


func _load_action_models() -> void:
	var scenes := {"idle": idle_scene, "attack": attack_scene, "run": run_scene}
	for action in ACTIONS:
		var scene := scenes[action] as PackedScene
		if scene == null:
			continue
		var node := scene.instantiate() as Node3D
		if node == null:
			push_warning("宠物动作模型实例化失败：%s / %s" % [name, action])
			continue
		node.name = "%sModel" % str(action).capitalize()
		node.visible = false
		model_root.add_child(node)
		_remove_imported_lights(node)
		if body_material != null:
			_apply_material(node, body_material)
		var player := _find_player(node)
		_nodes[action] = node
		_players[action] = player
		if player != null:
			_clips[action] = _pick_clip(player, action)


func _activate(action: String, restart: bool) -> void:
	if not _nodes.has(action):
		action = "idle"
		if not _nodes.has(action):
			return
	if action == _current and not restart:
		return
	_current = action
	for key in _nodes:
		(_nodes[key] as Node3D).visible = str(key) == action
	for key in _players:
		var other := _players[key] as AnimationPlayer
		if other != null and str(key) != action:
			other.stop()
	var player := _players.get(action) as AnimationPlayer
	var clip := str(_clips.get(action, ""))
	if player == null or clip.is_empty():
		return
	if restart:
		player.stop()
	player.play(clip)


# 挑这个动作要播的片段：名字带动作别名的优先，其次挑最长的（跳过 RESET）。
# 同一个文件被几个动作共用时（猴子），各动作挑到的是各自那一段。
func _pick_clip(player: AnimationPlayer, action: String) -> String:
	var best := ""
	var best_score := -INF
	for clip_name in player.get_animation_list():
		var text := String(clip_name)
		var lower := text.to_lower()
		var animation := player.get_animation(text)
		var score := animation.length if animation != null else 0.0
		if lower.contains("reset"):
			score -= 10000.0
		for alias in ACTION_ALIASES.get(action, []):
			if lower.contains(str(alias)):
				score += 1000.0
		if score > best_score:
			best_score = score
			best = text
	if best.is_empty():
		return ""
	var picked := player.get_animation(best)
	if picked != null:
		picked.loop_mode = Animation.LOOP_LINEAR if LOOPING.has(action) else Animation.LOOP_NONE
	return best


func _find_player(root: Node) -> AnimationPlayer:
	if root is AnimationPlayer:
		return root as AnimationPlayer
	for child in root.get_children():
		var found := _find_player(child)
		if found != null:
			return found
	return null


func _remove_imported_lights(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is Light3D or node is Camera3D:
			node.queue_free()


func _apply_material(root: Node, material: Material) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is MeshInstance3D:
			var mesh_instance := node as MeshInstance3D
			var surface_count := 1
			if mesh_instance.mesh != null:
				surface_count = maxi(1, mesh_instance.mesh.get_surface_count())
			for i in surface_count:
				mesh_instance.set_surface_override_material(i, material)
