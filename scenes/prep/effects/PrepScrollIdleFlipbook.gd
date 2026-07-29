extends Control
class_name PrepScrollIdleFlipbook

const FRAME_SIZE := Vector2i(256, 128)
const FRAME_COLUMNS := 6
const FRAME_COUNT := 12
const FRAME_RATE := 8.0
const FLOAT_DISTANCE := 5.0
const SWAY_RADIANS := deg_to_rad(1.4)
const HALF_CYCLE_SECONDS := 1.45

var _target: Control
var _shine: TextureRect
var _atlas_texture: AtlasTexture
var _frame_accumulator := 0.0
var _frame_index := 0
var _float_tween: Tween
var _rest_position := Vector2.ZERO
var _active := true


func setup(target: Control, atlas: Texture2D) -> void:
	_target = target
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	z_index = 2

	_atlas_texture = AtlasTexture.new()
	_atlas_texture.atlas = atlas
	_atlas_texture.region = Rect2(Vector2.ZERO, FRAME_SIZE)

	_shine = TextureRect.new()
	_shine.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shine.texture = _atlas_texture
	_shine.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_shine.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_shine.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_shine.modulate = Color(1.0, 1.0, 1.0, 0.88)
	add_child(_shine)

	call_deferred("_start_float")


func set_effect_active(value: bool) -> void:
	_active = value
	visible = value
	set_process(value)
	if value:
		_start_float()
	else:
		_stop_float()


func _process(delta: float) -> void:
	if not _active or _atlas_texture == null:
		return
	_frame_accumulator += delta
	var frame_duration := 1.0 / FRAME_RATE
	while _frame_accumulator >= frame_duration:
		_frame_accumulator -= frame_duration
		_frame_index = (_frame_index + 1) % FRAME_COUNT
		var column := _frame_index % FRAME_COLUMNS
		var row := _frame_index / FRAME_COLUMNS
		_atlas_texture.region = Rect2(
			Vector2(column * FRAME_SIZE.x, row * FRAME_SIZE.y),
			FRAME_SIZE
		)


func _start_float() -> void:
	if not _active or not is_instance_valid(_target):
		return
	_stop_float()
	_rest_position = _target.position
	_target.pivot_offset = _target.size * 0.5
	_float_tween = create_tween().set_loops()
	_float_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_float_tween.tween_property(
		_target,
		"position",
		_rest_position + Vector2(0.0, -FLOAT_DISTANCE),
		HALF_CYCLE_SECONDS
	)
	_float_tween.parallel().tween_property(
		_target,
		"rotation",
		SWAY_RADIANS,
		HALF_CYCLE_SECONDS
	)
	_float_tween.tween_property(
		_target,
		"position",
		_rest_position + Vector2(0.0, FLOAT_DISTANCE * 0.35),
		HALF_CYCLE_SECONDS
	)
	_float_tween.parallel().tween_property(
		_target,
		"rotation",
		-SWAY_RADIANS,
		HALF_CYCLE_SECONDS
	)


func _stop_float() -> void:
	if _float_tween != null and _float_tween.is_valid():
		_float_tween.kill()
	_float_tween = null
	if is_instance_valid(_target):
		_target.position = _rest_position
		_target.rotation = 0.0


func _exit_tree() -> void:
	_stop_float()
