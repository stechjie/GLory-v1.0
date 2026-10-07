extends Node3D
# The authored idle and walking FBX files have different rigs. Keep each action
# as its own imported scene so Godot never retargets animation to the wrong bones.
@export var idle_model: PackedScene
@export var run_model: PackedScene
# Scale of the run model relative to the idle model. The two files are exported
# separately and their units do not always agree: the tiger's walk export
# (pet_tiger_walk.glb) was scaled down twice and renders about 488x smaller than
# its idle model, so the tiger vanished whenever it ran (10-07, the carrot camp
# loops the run clip). Measured by skinning both meshes at rest pose; every other
# pet's pair already matches and keeps 1.0.
@export var run_model_scale := 1.0

@onready var model_root: Node3D = $ModelRoot
var _actions: Dictionary = {}
var _current := ""

func _ready() -> void:
    for entry in [{"name": "idle", "scene": idle_model}, {"name": "run", "scene": run_model}]:
        var scene: PackedScene = entry.scene
        if scene == null:
            continue
        var model := scene.instantiate() as Node3D
        if model == null:
            continue
        model.name = str(entry.name).capitalize() + "Model"
        model.visible = false
        if str(entry.name) == "run":
            model.scale *= run_model_scale
        model_root.add_child(model)
        _actions[str(entry.name)] = model
    play_idle()

func play_idle() -> void:
    _activate("idle")

func play_run() -> void:
    _activate("run")

func play_attack() -> void:
    # Harvest feedback animates the root above the carrot. Reuse the authored
    # idle motion because no separate attack clip was supplied for these pets.
    _activate("idle", true)

func _activate(action: String, restart: bool = false) -> void:
    if _current == action and not restart:
        return
    _current = action
    for key in _actions:
        var model: Node3D = _actions[key]
        model.visible = str(key) == action
        var player := _find_player(model)
        if player == null:
            continue
        if not model.visible:
            player.stop()
            continue
        var animations := player.get_animation_list()
        if animations.is_empty():
            continue
        var animation := player.get_animation(animations[0])
        if animation != null:
            animation.loop_mode = Animation.LOOP_LINEAR
        player.play(animations[0])

func _find_player(node: Node) -> AnimationPlayer:
    if node is AnimationPlayer:
        return node as AnimationPlayer
    for child in node.get_children():
        var found := _find_player(child)
        if found != null:
            return found
    return null
