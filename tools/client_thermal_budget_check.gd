extends Node

const Harness := preload("res://tools/CheckHarness.gd")
const ViewBudget := preload("res://ui/components/Budgeted3DView.gd")
const BattleVfxScript := preload("res://scenes/battle/BattleVfx.gd")
const FrameBudget := preload("res://scripts/autoload/ClientFrameBudget.gd")

class CounterActor extends Node3D:
	var writes := 0
	func _notification(what: int) -> void:
		if what == NOTIFICATION_LOCAL_TRANSFORM_CHANGED:
			writes += 1

class RendererProbe extends BattleVfxScript:
	var aim := Vector2(0.0, 1.0)
	func _visual_sim_pos_for_fighter(f: Dictionary) -> Vector2:
		return f.pos
	func _sim_to_world_pos(pos: Vector2, _apply_down_shift := true) -> Vector3:
		return Vector3(pos.x, 0.0, pos.y)
	func _model_aim_dir(_model: Node3D, _fighter: Dictionary, _world: Vector3) -> Vector2:
		return aim

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var h := Harness.new("client_thermal_budget")
	var renderer := RendererProbe.new()
	add_child(renderer)
	var actor := CounterActor.new()
	add_child(actor)
	actor.set_notify_local_transform(true)
	var fighter := {"pos": Vector2(2.0, 3.0)}
	renderer._position_3d_model_node(actor, fighter, 1.0 / 60.0)
	actor.writes = 0
	for i in 120:
		renderer._position_3d_model_node(actor, fighter, 1.0 / 60.0)
	h.expect(actor.writes == 0, "stationary_transform_writes", "stationary actors must not invalidate their model trees")
	fighter.pos = Vector2(2.000001, 3.0)
	renderer._position_3d_model_node(actor, fighter, 1.0 / 60.0)
	h.expect(actor.position.x == fighter.pos.x and actor.writes > 0,
		"small_movement_lost", "even tiny real movement must reach the model")
	renderer.aim = Vector2.RIGHT
	var before := actor.rotation.y
	var step := deg_to_rad(renderer.MODEL_FACING_TURN_SPEED_DEG) / 60.0
	renderer._position_3d_model_node(actor, fighter, 1.0 / 60.0)
	h.expect(is_equal_approx(actor.rotation.y - before, minf(step, PI / 2.0)),
		"turn_timing_changed", "turn speed must match the original visual timing")
	for i in 120:
		renderer._position_3d_model_node(actor, fighter, 1.0 / 60.0)
	actor.writes = 0
	for i in 120:
		renderer._position_3d_model_node(actor, fighter, 1.0 / 60.0)
	h.expect(actor.writes == 0, "settled_facing_writes", "settled facing must stop invalidating descendants")
	var host := Control.new()
	host.size = Vector2(1600.0, 720.0)
	add_child(host)
	var view := ViewBudget.create(host, "BudgetView", 0, Vector2i(1280, 720), true)
	await get_tree().process_frame
	h.expect(view.size == Vector2i(1280, 576), "container_overrode_budget", "a full-size UI must not override the 3D pixel budget")
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 10.0
	view.add_child(camera)
	var point := Vector3(1.0, 1.0, -5.0)
	var limited_uv := camera.unproject_position(point) / Vector2(view.size)
	var high_view := ViewBudget.create(host, "FullView", 0, Vector2i.ZERO, true)
	var high_camera := Camera3D.new()
	high_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	high_camera.size = camera.size
	high_view.add_child(high_camera)
	var full_uv := high_camera.unproject_position(point) / Vector2(high_view.size)
	h.expect(limited_uv.distance_to(full_uv) < 0.001, "projection_shift", "pixel budgeting must preserve screen-space unit and HUD placement")
	host.hide()
	h.expect(view.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"hidden_view_rendering", "hidden 3D layers must stop drawing")
	host.show()
	h.expect(view.render_target_update_mode == SubViewport.UPDATE_ALWAYS,
		"visible_view_stopped", "visible battle layers must resume drawing")
	host.size = Vector2(1200.0, 900.0)
	await get_tree().process_frame
	h.expect(view.size == Vector2i(960, 720) and high_view.size == Vector2i(1200, 900),
		"resize_budget", "resizing must preserve aspect and full-size high quality")
	h.expect(ViewBudget.mobile_limit(2, true) == Vector2i.ZERO and ViewBudget.mobile_limit(1, false) == Vector2i.ZERO,
		"high_desktop_reduced", "high quality and desktop resolution must remain unchanged")
	var old_fps := Engine.max_fps
	FrameBudget.apply(true)
	h.expect(Engine.max_fps == old_fps, "headless_fps_changed", "server/check processes must not inherit mobile waiting limits")
	for node in [actor, renderer, host]:
		node.queue_free()
	await get_tree().process_frame
	h.finish(get_tree())
