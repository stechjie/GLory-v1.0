extends Node

const LAYER_SCENE := preload("res://effects/runtime/presentation/BoardReadabilityLayer.tscn")
const REVIEW_SCENE := preload("res://scenes/debug/BoardReadabilityReview.tscn")

var _failures: Array[String] = []


func _ready() -> void:
	_check_style_budget()
	_check_prep_contract()
	_check_battle_contract()
	_check_profile_migration()
	_check_review_scene()
	if _failures.is_empty():
		print("BOARD_READABILITY_CHECK PASS checks=5 prep_cells=16 battle_zones=6")
		get_tree().quit(0)
		return
	for failure in _failures:
		push_error("BOARD_READABILITY_CHECK FAIL %s" % failure)
	get_tree().quit(1)


func _check_style_budget() -> void:
	var style := load("res://data/presentation/board_readability_default.tres") as BoardReadabilityStyle
	_expect(style != null, "default style resource must load")
	if style == null:
		return
	_expect(style.battle_zone_fill_alpha <= 0.05, "battle zone fill must stay low contrast")
	_expect(style.prep_rest_fill_alpha <= 0.08, "prep rest fill must stay low contrast")
	_expect(style.target_line_width <= 3.0, "target line must not become a dominant laser")


func _check_prep_contract() -> void:
	var layer := LAYER_SCENE.instantiate() as BoardReadabilityLayer
	add_child(layer)
	layer.configure_prep()
	var cells: Array[PackedVector2Array] = []
	for index in 16:
		var x := float(index % 4) * 24.0
		var y := float(index / 4) * 20.0
		cells.append(PackedVector2Array([Vector2(x, y), Vector2(x + 18, y), Vector2(x + 18, y + 14), Vector2(x, y + 14)]))
	layer.set_prep_cells(cells)
	layer.set_prep_state(5, PackedInt32Array([1, 4, 5, 6, 9]), true, 6, Color(0.2, 0.8, 0.8))
	var snapshot := layer.contract_snapshot()
	_expect(int(snapshot.get("prep_cell_count", 0)) == 16, "prep layer must own exactly 16 cells")
	_expect(int(snapshot.get("prep_selected_index", -1)) == 5, "prep selected cell must propagate")
	_expect(int(snapshot.get("prep_range_count", 0)) == 5, "prep range cells must propagate")
	layer.set_guides_enabled(false)
	_expect(not layer.visible, "setting off must hide the whole layer")
	layer.queue_free()


func _check_battle_contract() -> void:
	var layer := LAYER_SCENE.instantiate() as BoardReadabilityLayer
	add_child(layer)
	layer.configure_battle()
	var zones: Array[Dictionary] = []
	for lane in 3:
		zones.append({"polygon": PackedVector2Array([Vector2(lane * 20, 0), Vector2(lane * 20 + 18, 0), Vector2(lane * 20 + 18, 20), Vector2(lane * 20, 20)]), "friendly": false})
		zones.append({"polygon": PackedVector2Array([Vector2(lane * 20, 20), Vector2(lane * 20 + 18, 20), Vector2(lane * 20 + 18, 40), Vector2(lane * 20, 40)]), "friendly": true})
	layer.set_battle_geometry(zones, PackedVector2Array([Vector2(0, 20), Vector2(58, 20)]))
	var range_polygon := PackedVector2Array()
	for index in 40:
		var angle := TAU * float(index) / 40.0
		range_polygon.append(Vector2(30, 30) + Vector2(cos(angle), sin(angle)) * 20.0)
	layer.set_battle_focus("unit_a", Vector2(30, 30), range_polygon, Vector2(44, 10), true, Color.CYAN)
	var snapshot := layer.contract_snapshot()
	_expect(int(snapshot.get("battle_zone_count", 0)) == 6, "battle layer must represent three lanes by two halves")
	_expect(int(snapshot.get("battle_range_point_count", 0)) == 40, "battle range must preserve sampled geometry")
	_expect(bool(snapshot.get("battle_has_target", false)), "real target telemetry must propagate")
	layer.queue_free()


func _check_profile_migration() -> void:
	var old_profile := {
		"version": 2,
		"owned_pets": ["pet_rabbit"],
		"active_pet": "pet_rabbit",
		"codex_seen": ["human_archer"],
	}
	var migrated := SaveSchema.migrate_profile(old_profile)
	_expect(int(migrated.get("version", 0)) == SaveSchema.PROFILE_VERSION, "profile version must migrate to current")
	_expect(bool(migrated.get("board_readability_enabled", false)), "old profiles must default guides on")
	_expect((migrated.get("codex_seen", []) as Array).has("human_archer"), "migration must preserve codex progress")


func _check_review_scene() -> void:
	var review := REVIEW_SCENE.instantiate()
	_expect(review != null, "review scene must instantiate")
	if review != null:
		review.queue_free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
