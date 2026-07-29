extends Node2D
class_name BattleLaneBarrier2D

signal release_finished

const LOOP_TEXTURE := preload("res://assets/vfx/battlefield/lane_barrier_lowpoly_loop.png")
const RELEASE_TEXTURE := preload("res://assets/vfx/battlefield/lane_barrier_lowpoly_release.png")
const CELL_SIZE := Vector2(128.0, 512.0)
const COLUMNS := 4
const LOOP_FRAME_COUNT := 16
const RELEASE_FRAME_COUNT := 8
const RELEASE_FPS := 18.0

var _sprite: Sprite2D
var _atlas: AtlasTexture
var _frame := 0
var _elapsed := 0.0
var _frame_count := LOOP_FRAME_COUNT
var _fps := RELEASE_FPS
var _released := false


func _ready() -> void:
	_sprite = Sprite2D.new()
	_sprite.name = "BarrierSprite"
	_sprite.centered = true
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(_sprite)
	_atlas = AtlasTexture.new()
	_sprite.texture = _atlas
	play_loop()


func play_loop(_start_frame := 0) -> void:
	_released = false
	_frame_count = LOOP_FRAME_COUNT
	_frame = 0
	_elapsed = 0.0
	visible = true
	if _atlas != null:
		_atlas.atlas = LOOP_TEXTURE
		_apply_frame()
	# The low-poly obstacle is a rigid object. Keep it completely still until
	# the lane-clear event starts the one-shot release animation.
	set_process(false)


func play_release() -> void:
	if _released:
		return
	_released = true
	_frame_count = RELEASE_FRAME_COUNT
	_fps = RELEASE_FPS
	_frame = 0
	_elapsed = 0.0
	if _atlas != null:
		_atlas.atlas = RELEASE_TEXTURE
		_apply_frame()
	set_process(true)


func is_released() -> bool:
	return _released


func _process(delta: float) -> void:
	_elapsed += delta
	var wanted := int(floor(_elapsed * _fps))
	if wanted >= _frame_count:
		visible = false
		set_process(false)
		release_finished.emit()
		return
	if wanted == _frame:
		return
	_frame = wanted
	_apply_frame()


func _apply_frame() -> void:
	if _atlas == null:
		return
	var column := _frame % COLUMNS
	var row := int(_frame / COLUMNS)
	_atlas.region = Rect2(Vector2(column, row) * CELL_SIZE, CELL_SIZE)
