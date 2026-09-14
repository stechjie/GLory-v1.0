extends Node3D
class_name ModelBattlePreviewV3

## Isolated V3 validation scene.  It intentionally has no production battle
## dependency and no reference to earlier experimental scripts, GLBs, shaders or Effekseer data.

@onready var camera: Camera3D = $Camera3D
@onready var caster: Node3D = $Stage/CasterSlot/Caster
@onready var target: Node3D = $Stage/TargetSlot/Target
@onready var caster_slot: Node3D = $Stage/CasterSlot
@onready var target_slot: Node3D = $Stage/TargetSlot
@onready var strike: UndeadSmallSpiritStrikeV3 = $Stage/UndeadSmallSpiritStrikeV3
@onready var status_label: Label = $CanvasLayer/Panel/Margin/Rows/Status

const SIM_W := 1000.0
const SIM_H := 520.0
const PLAYABLE_WIDTH := 14.5
const PLAYABLE_DEPTH := 10.0
const VISUAL_SCALE := 0.88
const DOWN_SHIFT := 0.1
const UNIT_Y := 1.0
const MELEE_RANGE_SIM := 72.0
const CASTER_SIM := Vector2(500.0, 296.0)
const TARGET_SIM := Vector2(500.0, 224.0)

func _ready() -> void:
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 7.2
	camera.near = 0.03
	camera.far = 80.0
	camera.look_at(Vector3.ZERO, Vector3.UP)
	var background := $Stage/BackgroundBillboard as MeshInstance3D
	var view_direction := (Vector3.ZERO - camera.position).normalized()
	background.position = view_direction * 4.0
	background.look_at(camera.position, Vector3.UP)
	_layout_real_melee_contact()
	_replay()

func _layout_real_melee_contact() -> void:
	caster_slot.position = _sim_to_world(CASTER_SIM)
	target_slot.position = _sim_to_world(TARGET_SIM)
	_face(caster_slot, target_slot.position - caster_slot.position)
	_face(target_slot, caster_slot.position - target_slot.position)

func _replay() -> void:
	if caster.has_method("play_attack"):
		caster.call("play_attack")
	if target.has_method("play_idle"):
		target.call("play_idle")
	strike.play(caster_slot.global_position, target_slot.global_position)
	status_label.text = "小灵 V3 · Blender 双爪痕剪影 · 实机同路近战 72px · Space Replay"

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and (event as InputEventKey).keycode == KEY_SPACE:
		_replay()

func _sim_to_world(sim: Vector2) -> Vector3:
	var x := (sim.x / SIM_W - 0.5) * PLAYABLE_WIDTH * VISUAL_SCALE
	var z := (sim.y / SIM_H - 0.5) * PLAYABLE_DEPTH * VISUAL_SCALE
	z += PLAYABLE_DEPTH * DOWN_SHIFT
	return Vector3(x, UNIT_Y, z)

func _face(slot: Node3D, direction: Vector3) -> void:
	var aim := Vector2(direction.x, direction.z)
	if aim.length_squared() > 0.0001:
		slot.rotation.y = atan2(aim.x, aim.y)
