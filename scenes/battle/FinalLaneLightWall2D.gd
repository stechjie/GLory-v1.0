extends Node2D
class_name FinalLaneLightWall2D

signal release_finished

const WALL_TEXTURE := preload("res://assets/vfx/battlefield/final_lane_light_wall.png")
const RELEASE_SEC := 0.32
# This is the final-round horizontal light wall, not the user-approved full-height
# BattleLaneBarrier2D crystal. At 0.20 the 241 px source occupied about 48 px on
# screen and crossed several unit silhouettes; 0.08 keeps the full lane width but
# turns it into a roughly 19 px floor separator.
const SCREEN_HEIGHT_SCALE := 0.08
const STEADY_ALPHA := 0.36

var _sprite: Sprite2D
var _released := false


func _ready() -> void:
	_sprite = Sprite2D.new()
	_sprite.name = "LightWallSprite"
	_sprite.texture = WALL_TEXTURE
	_sprite.centered = true
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_sprite.modulate = Color(0.82, 0.88, 1.0, STEADY_ALPHA)
	add_child(_sprite)
	set_process(false)


func play_loop(_start_frame := 0) -> void:
	_released = false
	visible = true
	modulate = Color.WHITE
	scale.y = absf(scale.y)
	set_process(false)


func play_release() -> void:
	if _released:
		return
	_released = true
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "modulate:a", 0.0, RELEASE_SEC).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(self, "scale:y", scale.y * 0.12, RELEASE_SEC).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(_finish_release)


func is_released() -> bool:
	return _released


func _finish_release() -> void:
	visible = false
	release_finished.emit()
