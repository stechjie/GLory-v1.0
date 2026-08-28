extends Node

# Non-visual hook shared by the two existing review scenes. Keeping this node
# invisible means their screenshot baselines do not change. F10 opens the matrix
# interactively; --model-visual-matrix provides the same route for automation.

const MATRIX_SCENE := "res://tools/model_visual_matrix_capture.tscn"

var _launching := false


func _ready() -> void:
	if "--model-visual-matrix" in OS.get_cmdline_user_args():
		_launch.call_deferred()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F10:
		_launch()
		get_viewport().set_input_as_handled()


func _launch() -> void:
	if _launching:
		return
	_launching = true
	var error := get_tree().change_scene_to_file(MATRIX_SCENE)
	if error != OK:
		_launching = false
		push_error("MODEL_VISUAL_MATRIX launch failed: %s (%d)" % [MATRIX_SCENE, error])
