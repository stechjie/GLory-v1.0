extends Control

const EffectDatabase := preload("res://effects/EffectDatabase.gd")
const SkillVFXConfig := preload("res://effects/SkillVFXConfig.gd")

var _effect_ids := EffectDatabase.EFFECT_SCENES.keys()
var _index := 0
var _label: Label
var _status: Label
var _loop_timer: Timer
var _play_count := 0

func _ready() -> void:
	_build_ui()
	_update_label()
	# Wait until current_scene is assigned before VFXManager chooses its FX layer.
	call_deferred("_preview_current")

func _input(event: InputEvent) -> void:
	if event.is_echo():
		return
	if event.is_action_pressed("ui_right"):
		_select_effect(1)
	elif event.is_action_pressed("ui_left"):
		_select_effect(-1)
	elif event.is_action_pressed("ui_accept"):
		_preview_current()
	else:
		return
	get_viewport().set_input_as_handled()

func _select_effect(direction: int) -> void:
	_index = posmod(_index + direction, _effect_ids.size())
	_update_label()
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
	button.focus_mode = Control.FOCUS_NONE
	add_child(button)
	var previous := Button.new()
	previous.text = "Previous"
	previous.position = Vector2(200.0, 96.0)
	previous.focus_mode = Control.FOCUS_NONE
	previous.pressed.connect(_select_effect.bind(-1))
	add_child(previous)
	var next := Button.new()
	next.text = "Next"
	next.position = Vector2(320.0, 96.0)
	next.focus_mode = Control.FOCUS_NONE
	next.pressed.connect(_select_effect.bind(1))
	add_child(next)
	var loop := CheckButton.new()
	loop.text = "Loop playback"
	loop.position = Vector2(420.0, 90.0)
	loop.button_pressed = true
	loop.focus_mode = Control.FOCUS_NONE
	loop.toggled.connect(_set_loop)
	add_child(loop)
	_status = Label.new()
	_status.position = Vector2(24.0, 150.0)
	add_child(_status)
	_loop_timer = Timer.new()
	_loop_timer.wait_time = 1.5
	_loop_timer.timeout.connect(_preview_current)
	add_child(_loop_timer)
	_loop_timer.start()

func _set_loop(enabled: bool) -> void:
	if enabled:
		_loop_timer.start()
		_preview_current()
	else:
		_loop_timer.stop()

func _update_label() -> void:
	_label.text = "VFX Preview: %s\nLeft/Right select, Enter replays. Auto-loop: every 1.5 seconds." % str(_effect_ids[_index])

func _preview_current() -> void:
	var id := str(_effect_ids[_index])
	var center := get_viewport_rect().size * 0.5
	var effect: Node2D
	if id.begins_with("PROJECTILE_"):
		var target := Node2D.new()
		target.global_position = center + Vector2(160.0, 0.0)
		add_child(target)
		# Preview the projectile alone; its legacy default HIT_RANGED is no
		# longer registered in EffectDatabase.
		effect = VFXManager.spawn_projectile_vfx(id, center - Vector2(160.0, 0.0), target, {"target_position": target.global_position, "impact_id": ""})
		get_tree().create_timer(0.8).timeout.connect(func():
			if is_instance_valid(target):
				target.queue_free()
		)
	elif id == "SKILL_TEXTURE":
		# This generic renderer needs an authored texture set to draw anything.
		effect = VFXManager.spawn_vfx(id, center, {"textures": SkillVFXConfig.get_textures("god_priest")})
	else:
		effect = VFXManager.spawn_vfx(id, center)
	if effect != null:
		_play_count += 1
		_status.text = "Played %d times | %s | Look at the center of the window" % [_play_count, id]
	else:
		_status.text = "Could not spawn %s (missing resource or effect limit reached)" % id
