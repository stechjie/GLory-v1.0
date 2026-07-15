extends Node3D

const UNIT_DATA_PATH := "res://data/units/race_units.json"
const MONSTER_DATA_PATH := "res://data/pve/pve_monsters.json"
const MERCENARY_DATA_PATH := "res://data/mercenary/mercenaries.json"
const BOSS_DATA_PATH := "res://data/boss/bosses.json"
const FORMATION_BOSS_DATA_PATH := "res://data/formation/formation_allies.json"
const TARGET_HEIGHT := 1.32
const TARGET_WIDTH := 1.06
const ATTACK_PERIOD := 2.2
const ATTACK_WINDOW := 0.34
const WALK_IN_TIME := 0.85
const SPAWN_DEPTH := 1.72
const ENGAGE_DEPTH := 0.48
const CAMERA_MIN_HEIGHT := 4.8
const CAMERA_MIN_DISTANCE := 7.2
const CAMERA_FRAME_MARGIN := 1.85
const SIDE_LEFT := -1
const SIDE_RIGHT := 1
const SIDE_BOTH := 0
const FALLBACK_MODELS := [
	{"id": "pve_land_rock_beast", "name": "岩甲兽", "source": "怪物", "model": "res://assets/models/monsters/land/pve_land_rock_beast_animated/pve_land_rock_beast_animated.tscn", "model_visual_scale": 1.0, "model_base_yaw": 180.0},
	{"id": "pve_sky_wind_falcon", "name": "风刃隼", "source": "怪物", "model": "res://assets/models/monsters/sky/pve_sky_wind_falcon_animated/pve_sky_wind_falcon_animated.tscn", "model_visual_scale": 1.0, "model_base_yaw": 180.0}
]

@onready var left_slot: Node3D = $Stage/LeftSlot
@onready var right_slot: Node3D = $Stage/RightSlot
@onready var camera: Camera3D = $Camera3D
@onready var canvas_layer: CanvasLayer = $CanvasLayer
@onready var info_label: Label = $CanvasLayer/InfoLabel
@onready var hit_flash: MeshInstance3D = $Stage/HitFlash

var rng := RandomNumberGenerator.new()
var model_entries: Array = []
var units: Array = []
var selected_left_index := 0
var selected_right_index := 1
var phase_time := 0.0
var last_cycle := -1
var last_attack_cycle := -1
var preview_names := ""
var auto_fight_enabled := true
var camera_target := Vector3(0.0, 0.68, 0.0)
var camera_height := 5.4
var camera_distance := 8.4
var camera_yaw_deg := 0.0
var camera_fov := 48.0
var left_model_select: OptionButton
var right_model_select: OptionButton
var auto_button: Button

func _ready() -> void:
	rng.randomize()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 7.2
	camera.fov = 39.0
	camera.near = 0.03
	camera.far = 80.0
	camera.look_at(Vector3(0.0, 0.72, 0.0), Vector3.UP)
	_setup_info_label()
	_build_control_panel()
	model_entries = _load_model_entries()
	_populate_model_selects()
	_select_default_models()
	_ensure_preview_camera_current()
	_load_selected_pair()

func _process(delta: float) -> void:
	phase_time += delta
	if auto_fight_enabled:
		var cycle := int(floor(phase_time / ATTACK_PERIOD))
		var cycle_pos: float = fmod(phase_time, ATTACK_PERIOD)
		if cycle != last_cycle:
			last_cycle = cycle
			last_attack_cycle = -1
			_play_action_for_side("run", SIDE_BOTH, false)
		if cycle_pos >= WALK_IN_TIME and cycle != last_attack_cycle:
			last_attack_cycle = cycle
			_play_action_for_side("attack", SIDE_BOTH, false)
	_animate_units()
	_update_hit_flash()
	_update_camera_controls(delta)
	_ensure_preview_camera_current()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mouse_button := event as InputEventMouseButton
		match mouse_button.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				camera_distance = maxf(1.0, camera_distance - 0.55)
				_apply_preview_camera()
				_update_label()
			MOUSE_BUTTON_WHEEL_DOWN:
				camera_distance = minf(30.0, camera_distance + 0.55)
				_apply_preview_camera()
				_update_label()
		return
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		var motion := event as InputEventMouseMotion
		camera_yaw_deg = wrapf(camera_yaw_deg - motion.relative.x * 0.18, -180.0, 180.0)
		camera_height = clampf(camera_height - motion.relative.y * 0.018, 0.35, 18.0)
		_apply_preview_camera()
		_update_label()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_R:
				_load_random_pair()
			KEY_1:
				_play_action_for_side("idle", SIDE_BOTH, true)
			KEY_2:
				_play_action_for_side("attack", SIDE_BOTH, true)
			KEY_3:
				_play_action_for_side("run", SIDE_BOTH, true)
			KEY_SPACE:
				_play_action_for_side("attack", SIDE_BOTH, true)
			KEY_H:
				_frame_preview_camera()
				_update_label()
			KEY_ESCAPE:
				get_tree().quit()

func _setup_info_label() -> void:
	info_label.offset_left = 16.0
	info_label.offset_top = 14.0
	info_label.offset_right = 980.0
	info_label.offset_bottom = 220.0
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_label.add_theme_font_size_override("font_size", 14)

func _build_control_panel() -> void:
	var panel := PanelContainer.new()
	panel.name = "ModelControlPanel"
	panel.anchor_left = 1.0
	panel.anchor_top = 0.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 0.0
	panel.offset_left = -560.0
	panel.offset_top = 14.0
	panel.offset_right = -16.0
	panel.offset_bottom = 184.0
	canvas_layer.add_child(panel)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 6)
	panel.add_child(rows)

	var select_row := HBoxContainer.new()
	select_row.add_theme_constant_override("separation", 8)
	rows.add_child(select_row)

	var left_label := Label.new()
	left_label.text = "左模型"
	select_row.add_child(left_label)
	left_model_select = OptionButton.new()
	left_model_select.custom_minimum_size = Vector2(210.0, 0.0)
	left_model_select.item_selected.connect(_on_left_model_selected)
	select_row.add_child(left_model_select)

	var right_label := Label.new()
	right_label.text = "右模型"
	select_row.add_child(right_label)
	right_model_select = OptionButton.new()
	right_model_select.custom_minimum_size = Vector2(210.0, 0.0)
	right_model_select.item_selected.connect(_on_right_model_selected)
	select_row.add_child(right_model_select)

	var left_action_row := HBoxContainer.new()
	left_action_row.add_theme_constant_override("separation", 6)
	rows.add_child(left_action_row)
	_add_button(left_action_row, "左 Idle", _on_left_idle_pressed)
	_add_button(left_action_row, "左 Attack", _on_left_attack_pressed)
	_add_button(left_action_row, "左 Run", _on_left_run_pressed)
	_add_button(left_action_row, "右 Idle", _on_right_idle_pressed)
	_add_button(left_action_row, "右 Attack", _on_right_attack_pressed)
	_add_button(left_action_row, "右 Run", _on_right_run_pressed)

	var both_action_row := HBoxContainer.new()
	both_action_row.add_theme_constant_override("separation", 6)
	rows.add_child(both_action_row)
	_add_button(both_action_row, "双 Idle", _on_both_idle_pressed)
	_add_button(both_action_row, "双 Attack", _on_both_attack_pressed)
	_add_button(both_action_row, "双 Run", _on_both_run_pressed)
	_add_button(both_action_row, "随机", _on_random_pressed)
	auto_button = _add_button(both_action_row, "自动战斗 ON", _on_auto_fight_pressed)

func _add_button(parent: Control, text: String, callable: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(callable)
	parent.add_child(button)
	return button

func _load_model_entries() -> Array:
	var result: Array = []
	_append_entries_from_json(result, UNIT_DATA_PATH, "units", "棋子")
	_append_entries_from_json(result, MONSTER_DATA_PATH, "monsters", "怪物")
	_append_entries_from_json(result, MERCENARY_DATA_PATH, "mercenaries", "佣兵", true)
	_append_entries_from_json(result, BOSS_DATA_PATH, "bosses", "Boss", true)
	_append_entries_from_json(result, FORMATION_BOSS_DATA_PATH, "allies", "法阵Boss", true)
	if result.is_empty():
		result = FALLBACK_MODELS.duplicate(true)
	for i in range(result.size()):
		var entry: Dictionary = result[i]
		var model_path := str(entry.get("model", ""))
		var model_state := "" if model_path.begins_with("res://") else "｜未接入模型"
		var variant_text := str(entry.get("preview_variant", ""))
		var variant_suffix := " [%s]" % variant_text if not variant_text.is_empty() else ""
		entry["display_name"] = "%s｜%s%s (%s)%s" % [str(entry.get("source", "模型")), str(entry.get("name", "未命名")), variant_suffix, str(entry.get("id", "no_id")), model_state]
		result[i] = entry
	return result

func _append_entries_from_json(result: Array, path: String, list_key: String, source: String, include_without_model: bool = false) -> void:
	if not FileAccess.file_exists(path):
		return
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var root: Dictionary = parsed
	var list_value: Variant = root.get(list_key, [])
	if typeof(list_value) != TYPE_ARRAY:
		return
	var list: Array = list_value
	for value in list:
		if typeof(value) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = value.duplicate(true)
		var variants_value: Variant = entry.get("model_by_element", {})
		if typeof(variants_value) == TYPE_DICTIONARY and not (variants_value as Dictionary).is_empty():
			var variants: Dictionary = variants_value
			for element_key in variants.keys():
				var variant_entry := entry.duplicate(true)
				variant_entry["model"] = str(variants[element_key])
				variant_entry["element"] = str(element_key)
				variant_entry["preview_variant"] = _element_display_name(str(element_key))
				variant_entry["source"] = source
				result.append(variant_entry)
			continue
		var model_path := str(entry.get("model", ""))
		if not include_without_model and not model_path.begins_with("res://"):
			continue
		entry["source"] = source
		result.append(entry)

func _element_display_name(element: String) -> String:
	match element:
		"land":
			return "地"
		"sky":
			return "天"
		_:
			return element

func _populate_model_selects() -> void:
	left_model_select.clear()
	right_model_select.clear()
	for i in range(model_entries.size()):
		var entry: Dictionary = model_entries[i]
		var label := str(entry.get("display_name", entry.get("name", "模型")))
		left_model_select.add_item(label, i)
		right_model_select.add_item(label, i)

func _select_default_models() -> void:
	selected_left_index = _find_entry_index("god_guard", 0)
	selected_right_index = _find_entry_index("dark_imp", 1 if model_entries.size() > 1 else 0)
	if selected_left_index == selected_right_index and model_entries.size() > 1:
		selected_right_index = 1 if selected_left_index != 1 else 0
	left_model_select.select(selected_left_index)
	right_model_select.select(selected_right_index)

func _find_entry_index(id: String, fallback: int) -> int:
	for i in range(model_entries.size()):
		var entry: Dictionary = model_entries[i]
		if str(entry.get("id", "")) == id:
			return i
	return clampi(fallback, 0, maxi(model_entries.size() - 1, 0))

func _load_random_pair() -> void:
	if model_entries.size() < 2:
		return
	selected_left_index = rng.randi_range(0, model_entries.size() - 1)
	selected_right_index = rng.randi_range(0, model_entries.size() - 1)
	while selected_right_index == selected_left_index and model_entries.size() > 1:
		selected_right_index = rng.randi_range(0, model_entries.size() - 1)
	left_model_select.select(selected_left_index)
	right_model_select.select(selected_right_index)
	_load_selected_pair()

func _load_selected_pair() -> void:
	_clear_slot(left_slot)
	_clear_slot(right_slot)
	units.clear()
	phase_time = 0.0
	last_cycle = -1
	last_attack_cycle = -1
	hit_flash.visible = false
	left_slot.position = Vector3(-1.35, 0.0, float(SIDE_LEFT) * SPAWN_DEPTH)
	right_slot.position = Vector3(1.35, 0.0, float(SIDE_RIGHT) * SPAWN_DEPTH)
	if model_entries.is_empty():
		_update_label()
		return
	var left_entry: Dictionary = model_entries[selected_left_index]
	var right_entry: Dictionary = model_entries[selected_right_index]
	_spawn_unit(left_slot, left_entry, SIDE_LEFT)
	_spawn_unit(right_slot, right_entry, SIDE_RIGHT)
	preview_names = "%s  vs  %s" % [str(left_entry.get("name", "模型A")), str(right_entry.get("name", "模型B"))]
	_frame_preview_camera()
	_update_label()

func _spawn_unit(slot: Node3D, entry: Dictionary, side: int) -> void:
	var path := str(entry.get("model", ""))
	if not path.begins_with("res://"):
		units.append(_make_missing_unit(slot, entry, side, "尚未在数据表配置模型资源"))
		return
	if not ResourceLoader.exists(path):
		units.append(_make_missing_unit(slot, entry, side, "模型路径不存在"))
		return
	var scene := ResourceLoader.load(path) as PackedScene
	if scene == null:
		units.append(_make_missing_unit(slot, entry, side, "模型加载失败"))
		return
	var model := scene.instantiate() as Node3D
	if model == null:
		units.append(_make_missing_unit(slot, entry, side, "实例不是 Node3D"))
		return
	slot.add_child(model)
	_cleanup_imported_preview_visuals(model)
	model.position = Vector3.ZERO
	model.rotation_degrees = Vector3(0.0, float(entry.get("model_base_yaw", 180.0)), 0.0)
	model.scale = Vector3.ONE * float(entry.get("model_visual_scale", 1.0))
	_fit_model_to_slot(model)

	var target := right_slot.global_position if side < 0 else left_slot.global_position
	slot.look_at(Vector3(target.x, slot.global_position.y, target.z), Vector3.UP)
	var player := _find_animation_player(model)
	var animations := _animation_list(player)
	var actions := {
		"idle": _resolve_action_animation(player, entry, "idle", ["idle", "Idle", "mixamo_com", "breath", "stand"]),
		"attack": _resolve_action_animation(player, entry, "attack", ["attack", "Attack", "punch", "Punch", "slash", "Slash", "hit", "Hit"]),
		"run": _resolve_action_animation(player, entry, "run", ["run", "Run", "walk", "Walk", "running", "Running"])
	}
	_mark_script_action_methods(model, actions)
	var unit := {
		"slot": slot,
		"model": model,
		"base_pos": Vector3(slot.position.x, slot.position.y, float(side) * SPAWN_DEPTH),
		"side": side,
		"name": str(entry.get("name", "模型")),
		"id": str(entry.get("id", "")),
		"source": str(entry.get("source", "")),
		"path": path,
		"player": player,
		"animations": animations,
		"actions": actions,
		"current_action": "idle",
		"load_note": ""
	}
	units.append(unit)
	slot.position = unit["base_pos"]
	_play_unit_action(unit, "idle", false)

func _make_missing_unit(slot: Node3D, entry: Dictionary, side: int, note: String) -> Dictionary:
	return {
		"slot": slot,
		"model": null,
		"base_pos": slot.position,
		"side": side,
		"name": str(entry.get("name", "模型")),
		"id": str(entry.get("id", "")),
		"source": str(entry.get("source", "")),
		"path": str(entry.get("model", "")),
		"player": null,
		"animations": [],
		"actions": {"idle": "", "attack": "", "run": ""},
		"current_action": "missing",
		"load_note": note
	}

func _resolve_action_animation(player: AnimationPlayer, entry: Dictionary, action: String, candidates: Array) -> String:
	if player == null:
		return ""
	var explicit_key := "model_%s_animation_name" % action
	var explicit_name := str(entry.get(explicit_key, ""))
	if not explicit_name.is_empty() and player.has_animation(explicit_name):
		return explicit_name
	for candidate in candidates:
		var name := str(candidate)
		if player.has_animation(name):
			return name
	for anim in player.get_animation_list():
		var lower := String(anim).to_lower()
		for candidate in candidates:
			if lower.contains(str(candidate).to_lower()):
				return String(anim)
	return ""

func _animation_list(player: AnimationPlayer) -> Array:
	var result: Array = []
	if player == null:
		return result
	for anim in player.get_animation_list():
		result.append(String(anim))
	return result

func _play_action_for_side(action: String, side: int, manual: bool) -> void:
	if manual:
		auto_fight_enabled = false
		_update_auto_button()
	for unit in units:
		if side == SIDE_BOTH or int(unit.get("side", 0)) == side:
			_play_unit_action(unit, action, true)
	_update_label()

func _play_unit_action(unit: Dictionary, action: String, restart: bool) -> void:
	unit["current_action"] = action
	var model := unit.get("model") as Node
	var method_name := _action_method_name(action)
	if model != null and model.has_method(method_name):
		model.call(method_name)
		unit["last_method_call"] = method_name
		unit["wrapper_current_action"] = _wrapper_current_action(model)
		unit["visible_action_nodes"] = _visible_action_nodes(model)
		return
	var player := unit.get("player") as AnimationPlayer
	var actions: Dictionary = unit.get("actions", {})
	var animation_name := str(actions.get(action, ""))
	if player == null or animation_name.is_empty() or not player.has_animation(animation_name):
		return
	if restart:
		player.stop()
	player.play(animation_name)
	if action == "attack":
		player.seek(0.0, true)
		player.advance(0.001)

func _mark_script_action_methods(model: Node, actions: Dictionary) -> void:
	if model == null:
		return
	for action in ["idle", "attack", "run"]:
		var method_name := _action_method_name(action)
		if model.has_method(method_name):
			actions[action] = "%s()" % method_name

func _action_method_name(action: String) -> String:
	match action:
		"idle":
			return "play_idle"
		"attack":
			return "play_attack"
		"run":
			return "play_run"
		_:
			return ""
func _frame_preview_camera() -> void:
	var bounds: AABB = _combined_unit_bounds()
	if bounds.size == Vector3.ZERO:
		camera_target = Vector3(0.0, 0.68, 0.0)
		camera_height = 5.4
		camera_distance = 8.4
		camera_yaw_deg = 0.0
		camera_fov = 7.2
		_apply_preview_camera()
		return
	var center: Vector3 = bounds.get_center()
	var width: float = maxf(bounds.size.x, bounds.size.z) + CAMERA_FRAME_MARGIN
	var height: float = bounds.size.y + CAMERA_FRAME_MARGIN * 0.5
	var frame_size: float = maxf(width, height * 1.55)
	var target_y: float = maxf(center.y + height * 0.02, 0.58)
	camera_target = Vector3(center.x, target_y, center.z)
	camera_height = maxf(CAMERA_MIN_HEIGHT, 4.6 + frame_size * 0.16)
	camera_distance = maxf(CAMERA_MIN_DISTANCE, 6.8 + frame_size * 0.28)
	camera_yaw_deg = 0.0
	camera_fov = 7.2
	_apply_preview_camera()

func _apply_preview_camera() -> void:
	camera_height = clampf(camera_height, 0.35, 18.0)
	camera_distance = clampf(camera_distance, 1.0, 30.0)
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		camera_fov = clampf(camera_fov, 5.8, 12.0)
		camera.size = camera_fov
	else:
		camera_fov = clampf(camera_fov, 18.0, 85.0)
	var yaw_basis := Basis(Vector3.UP, deg_to_rad(camera_yaw_deg))
	var offset: Vector3 = yaw_basis * Vector3(0.0, camera_height, camera_distance)
	camera.fov = camera_fov
	camera.global_position = camera_target + offset
	camera.look_at(camera_target, Vector3.UP)
	_ensure_preview_camera_current()

func _update_camera_controls(delta: float) -> void:
	var changed := false
	var distance_step: float = 4.0 * delta
	var height_step: float = 3.0 * delta
	var yaw_step: float = 68.0 * delta
	var fov_step: float = 28.0 * delta
	if Input.is_key_pressed(KEY_W):
		camera_distance -= distance_step
		changed = true
	if Input.is_key_pressed(KEY_S):
		camera_distance += distance_step
		changed = true
	if Input.is_key_pressed(KEY_Q):
		camera_height -= height_step
		changed = true
	if Input.is_key_pressed(KEY_E):
		camera_height += height_step
		changed = true
	if Input.is_key_pressed(KEY_A):
		camera_yaw_deg += yaw_step
		changed = true
	if Input.is_key_pressed(KEY_D):
		camera_yaw_deg -= yaw_step
		changed = true
	if Input.is_key_pressed(KEY_Z):
		camera_fov -= fov_step
		changed = true
	if Input.is_key_pressed(KEY_X):
		camera_fov += fov_step
		changed = true
	if changed:
		camera_yaw_deg = wrapf(camera_yaw_deg, -180.0, 180.0)
		_apply_preview_camera()
		_update_label()

func _ensure_preview_camera_current() -> void:
	if camera == null:
		return
	var active_camera: Camera3D = get_viewport().get_camera_3d()
	if active_camera != camera:
		camera.make_current()

func _combined_unit_bounds() -> AABB:
	var has_bounds := false
	var combined := AABB()
	for unit in units:
		var model := unit.get("model") as Node3D
		if model == null:
			continue
		var bounds: AABB = _node_bounds_relative(model, self)
		if bounds.size == Vector3.ZERO:
			continue
		if not has_bounds:
			combined = bounds
			has_bounds = true
		else:
			combined = combined.merge(bounds)
	return combined if has_bounds else AABB()

func _clear_slot(slot: Node) -> void:
	for child in slot.get_children():
		child.queue_free()

func _animate_units() -> void:
	var cycle_pos: float = fmod(phase_time, ATTACK_PERIOD)
	var walk_t: float = clampf(cycle_pos / WALK_IN_TIME, 0.0, 1.0)
	walk_t = walk_t * walk_t * (3.0 - 2.0 * walk_t)
	var attack_t: float = clampf((cycle_pos - WALK_IN_TIME) / ATTACK_WINDOW, 0.0, 1.0)
	var in_attack: bool = auto_fight_enabled and cycle_pos >= WALK_IN_TIME and cycle_pos <= WALK_IN_TIME + ATTACK_WINDOW
	for unit in units:
		var slot := unit.get("slot") as Node3D
		if slot == null:
			continue
		var base_pos: Vector3 = unit.get("base_pos", Vector3.ZERO)
		var side: int = int(unit.get("side", 1))
		var action := str(unit.get("current_action", "idle"))
		var bob: float = sin(phase_time * TAU * 0.9) * 0.035
		var engage_pos := Vector3(base_pos.x, base_pos.y, float(side) * ENGAGE_DEPTH)
		var current_base := base_pos
		if auto_fight_enabled:
			current_base = base_pos.lerp(engage_pos, walk_t)
		var lunge: float = 0.0
		if in_attack or action == "attack":
			lunge = sin(attack_t * PI) * 0.46
		elif action == "run":
			lunge = sin(phase_time * TAU * 0.85) * 0.12
		slot.position = current_base + Vector3(0.0, bob, float(-side) * lunge)

func _update_hit_flash() -> void:
	var show_flash := false
	if auto_fight_enabled:
		var cycle_pos: float = fmod(phase_time, ATTACK_PERIOD)
		var hit_t: float = absf(cycle_pos - (WALK_IN_TIME + ATTACK_WINDOW * 0.52))
		show_flash = hit_t < 0.08
		if show_flash:
			var pulse: float = 1.0 - hit_t / 0.08
			hit_flash.scale = Vector3.ONE * lerpf(0.18, 0.52, pulse)
	else:
		for unit in units:
			if str(unit.get("current_action", "")) == "attack":
				show_flash = true
				break
		if show_flash:
			hit_flash.scale = Vector3.ONE * 0.32
	hit_flash.visible = show_flash

func _update_label() -> void:
	var left_text := _unit_debug_text(SIDE_LEFT)
	var right_text := _unit_debug_text(SIDE_RIGHT)
	info_label.text = "%s\n%s\n%s\n镜头 W/S 远近  Q/E 高低  A/D 左右旋转  Z/X FOV  鼠标滚轮缩放  右键拖拽旋转/高低  H 重置\n动作快捷键：1 Idle  2 Attack  3 Run  Space Attack  R 随机  Esc 退出\n自动战斗：%s  高度 %.2f  距离 %.2f  旋转 %.0f  FOV %.0f" % [preview_names, left_text, right_text, "ON" if auto_fight_enabled else "OFF", camera_height, camera_distance, camera_yaw_deg, camera_fov]

func _unit_debug_text(side: int) -> String:
	var unit: Dictionary = _unit_for_side(side)
	if unit.is_empty():
		return "%s：未加载" % ("左" if side == SIDE_LEFT else "右")
	var actions: Dictionary = unit.get("actions", {})
	var animations: Array = unit.get("animations", [])
	var anim_text := ", ".join(animations) if not animations.is_empty() else "无 AnimationPlayer / 无动画"
	var note := str(unit.get("load_note", ""))
	var prefix := "左" if side == SIDE_LEFT else "右"
	var action_text := "idle=%s  attack=%s  run=%s" % [_fmt_action(actions.get("idle", "")), _fmt_action(actions.get("attack", "")), _fmt_action(actions.get("run", ""))]
	var base := "%s：%s [%s/%s] 当前=%s | %s | 动画列表：%s" % [prefix, str(unit.get("name", "模型")), str(unit.get("source", "")), str(unit.get("id", "")), str(unit.get("current_action", "")), action_text, anim_text]
	var model := unit.get("model") as Node
	if model != null and _supports_action_methods(model):
		base += " | wrapper当前=%s 可见=%s 最近调用=%s" % [str(unit.get("wrapper_current_action", _wrapper_current_action(model))), str(unit.get("visible_action_nodes", _visible_action_nodes(model))), str(unit.get("last_method_call", "无"))]
	if not note.is_empty():
		base += " | " + note
	return base

func _supports_action_methods(model: Node) -> bool:
	return model.has_method("play_idle") or model.has_method("play_attack") or model.has_method("play_run")

func _wrapper_current_action(model: Node) -> String:
	var value: Variant = model.get("current_action")
	return str(value) if value != null else "未知"

func _visible_action_nodes(model: Node) -> String:
	var visible_names: Array[String] = []
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node != model and node is Node3D and (node as Node3D).visible:
			var name_text := str(node.name)
			if name_text.ends_with("_model"):
				visible_names.append(name_text)
		for child in node.get_children():
			stack.append(child)
	return ",".join(visible_names) if not visible_names.is_empty() else "无"
func _fmt_action(value: Variant) -> String:
	var text := str(value)
	return text if not text.is_empty() else "缺失"

func _unit_for_side(side: int) -> Dictionary:
	for unit in units:
		if int(unit.get("side", 0)) == side:
			return unit
	return {}

func _find_animation_player(root: Node) -> AnimationPlayer:
	if root is AnimationPlayer:
		return root as AnimationPlayer
	for child in root.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null

func _fit_model_to_slot(model: Node3D) -> void:
	var bounds: AABB = _node_bounds_relative(model, model)
	if bounds.size == Vector3.ZERO:
		return
	var height: float = maxf(bounds.size.y, 0.001)
	var width: float = maxf(maxf(bounds.size.x, bounds.size.z), 0.001)
	var fit_scale: float = minf(TARGET_HEIGHT / height, TARGET_WIDTH / width)
	model.scale *= fit_scale
	bounds = _node_bounds_relative(model, model)
	var center: Vector3 = bounds.get_center()
	model.position -= Vector3(center.x, bounds.position.y, center.z)

func _node_bounds_relative(root: Node3D, relative_to: Node3D) -> AABB:
	var has_bounds := false
	var bounds := AABB()
	var to_relative := relative_to.global_transform.affine_inverse()
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			var mesh_node := node as MeshInstance3D
			var aabb := mesh_node.get_aabb()
			var points := [
				aabb.position,
				aabb.position + Vector3(aabb.size.x, 0.0, 0.0),
				aabb.position + Vector3(0.0, aabb.size.y, 0.0),
				aabb.position + Vector3(0.0, 0.0, aabb.size.z),
				aabb.position + Vector3(aabb.size.x, aabb.size.y, 0.0),
				aabb.position + Vector3(aabb.size.x, 0.0, aabb.size.z),
				aabb.position + Vector3(0.0, aabb.size.y, aabb.size.z),
				aabb.position + aabb.size
			]
			for p in points:
				var rel_point: Vector3 = to_relative * (mesh_node.global_transform * p)
				if not has_bounds:
					bounds = AABB(rel_point, Vector3.ZERO)
					has_bounds = true
				else:
					bounds = bounds.expand(rel_point)
		for child in node.get_children():
			stack.append(child)
	return bounds if has_bounds else AABB()

func _cleanup_imported_preview_visuals(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is Light3D or node is Camera3D:
			node.queue_free()

func _update_auto_button() -> void:
	if auto_button != null:
		auto_button.text = "自动战斗 ON" if auto_fight_enabled else "自动战斗 OFF"

func _on_left_model_selected(index: int) -> void:
	selected_left_index = index
	_load_selected_pair()

func _on_right_model_selected(index: int) -> void:
	selected_right_index = index
	_load_selected_pair()

func _on_left_idle_pressed() -> void:
	_play_action_for_side("idle", SIDE_LEFT, true)

func _on_left_attack_pressed() -> void:
	_play_action_for_side("attack", SIDE_LEFT, true)

func _on_left_run_pressed() -> void:
	_play_action_for_side("run", SIDE_LEFT, true)

func _on_right_idle_pressed() -> void:
	_play_action_for_side("idle", SIDE_RIGHT, true)

func _on_right_attack_pressed() -> void:
	_play_action_for_side("attack", SIDE_RIGHT, true)

func _on_right_run_pressed() -> void:
	_play_action_for_side("run", SIDE_RIGHT, true)

func _on_both_idle_pressed() -> void:
	_play_action_for_side("idle", SIDE_BOTH, true)

func _on_both_attack_pressed() -> void:
	_play_action_for_side("attack", SIDE_BOTH, true)

func _on_both_run_pressed() -> void:
	_play_action_for_side("run", SIDE_BOTH, true)

func _on_random_pressed() -> void:
	_load_random_pair()

func _on_auto_fight_pressed() -> void:
	auto_fight_enabled = not auto_fight_enabled
	_update_auto_button()
	if auto_fight_enabled:
		phase_time = 0.0
		last_cycle = -1
		last_attack_cycle = -1
	else:
		_play_action_for_side("idle", SIDE_BOTH, false)
	_update_label()
