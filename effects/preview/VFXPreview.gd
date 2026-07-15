extends Control

const EffectDatabase := preload("res://effects/EffectDatabase.gd")

var _effect_ids := EffectDatabase.EFFECT_SCENES.keys()
var _index := 0
var _label: Label

func _ready() -> void:
	_build_ui()
	_update_label()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_right"):
		_index = (_index + 1) % _effect_ids.size()
		_update_label()
	elif event.is_action_pressed("ui_left"):
		_index = (_index - 1 + _effect_ids.size()) % _effect_ids.size()
		_update_label()
	elif event.is_action_pressed("ui_accept"):
		_preview_current()

func _build_ui() -> void:
	_label = Label.new()
	_label.position = Vector2(24.0, 20.0)
	_label.size = Vector2(680.0, 72.0)
	_label.add_theme_font_size_override("font_size", 22)
	add_child(_label)
	var button := Button.new()
	button.text = "Preview Current"
	button.position = Vector2(24.0, 96.0)
	button.pressed.connect(_preview_current)
	add_child(button)

func _update_label() -> void:
	_label.text = "VFX Preview: %s\nLeft/Right select, Enter previews." % str(_effect_ids[_index])

func _preview_current() -> void:
	var id := str(_effect_ids[_index])
	var center := get_viewport_rect().size * 0.5
	if id.begins_with("PROJECTILE_"):
		var target := Node2D.new()
		target.global_position = center + Vector2(160.0, 0.0)
		add_child(target)
		VFXManager.spawn_projectile_vfx(id, center - Vector2(160.0, 0.0), target, {"target_position": target.global_position})
		await get_tree().create_timer(0.8).timeout
		if is_instance_valid(target):
			target.queue_free()
	else:
		VFXManager.spawn_vfx(id, center)