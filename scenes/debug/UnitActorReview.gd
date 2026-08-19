extends Node3D

const UnitVisualResolverScript := preload("res://effects/runtime/presentation/UnitVisualResolver.gd")
const UnitActor3DScript := preload("res://effects/runtime/presentation/UnitActor3D.gd")

const SAMPLE_ID := "human_militia"
const ACTOR_HEIGHT := 0.98


func _ready() -> void:
	_setup_stage()
	var definition := UnitVisualResolverScript.resolve_definition(SAMPLE_ID)
	_spawn_model_actor(definition, Vector3(-0.78, 0.0, 0.0))
	_spawn_fallback_actor(definition, Vector3(0.78, 0.0, 0.0))
	if "--capture" in OS.get_cmdline_user_args():
		_capture_after_frames.call_deferred()


func _setup_stage() -> void:
	var environment_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("17231d")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.52, 0.58, 0.48)
	environment.ambient_light_energy = 0.72
	environment_node.environment = environment
	add_child(environment_node)
	var light := DirectionalLight3D.new()
	light.light_color = Color(1.0, 0.86, 0.68)
	light.light_energy = 1.25
	light.rotation_degrees = Vector3(-52.0, 28.0, 0.0)
	add_child(light)
	var ground := MeshInstance3D.new()
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(4.2, 2.3)
	ground.mesh = ground_mesh
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color("314b35")
	ground_material.roughness = 0.88
	ground.material_override = ground_material
	ground.position.y = -0.02
	add_child(ground)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.5
	camera.look_at_from_position(Vector3(0.0, 2.05, 4.4), Vector3(0.0, 0.58, 0.0), Vector3.UP)
	camera.current = true
	add_child(camera)


func _spawn_model_actor(definition: Dictionary, position_value: Vector3) -> void:
	var actor = UnitActor3DScript.new()
	actor.name = "ModelActor"
	actor.configure_contract(ACTOR_HEIGHT)
	actor.position = position_value
	add_child(actor)
	var scene := load(str(definition.get("model", ""))) as PackedScene
	if scene == null:
		return
	var instance := scene.instantiate()
	if not (instance is Node3D):
		instance.queue_free()
		return
	var model := instance as Node3D
	var visual_scale := float(definition.get("model_visual_scale", 1.0)) * 0.42
	model.scale = Vector3.ONE * visual_scale
	actor.attach_model(model)
	_center_model(model)
	_add_anchor_markers(actor)
	_add_label(actor, "Validated Actor3D", Color(0.72, 0.92, 1.0))


func _spawn_fallback_actor(definition: Dictionary, position_value: Vector3) -> void:
	var actor = UnitActor3DScript.new()
	actor.name = "PortraitFallbackActor"
	actor.configure_contract(ACTOR_HEIGHT)
	actor.position = position_value
	add_child(actor)
	actor.attach_portrait_fallback(
		str(definition.get("portrait", "")),
		str(definition.get("fallback_frame", "")),
		Color(0.25, 0.85, 1.0, 0.58),
		ACTOR_HEIGHT
	)
	_add_anchor_markers(actor)
	_add_label(actor, "Portrait fallback", Color(1.0, 0.82, 0.38))


func _add_anchor_markers(actor: Node3D) -> void:
	var colors := {
		"FootAnchor": Color(0.2, 0.95, 0.45),
		"CastAnchor": Color(0.25, 0.75, 1.0),
		"HitAnchor": Color(1.0, 0.38, 0.28),
		"HeadAnchor": Color(1.0, 0.86, 0.25),
	}
	for anchor_name in colors:
		var anchor := actor.get_node(anchor_name) as Node3D
		var marker := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = 0.025
		mesh.height = 0.05
		marker.mesh = mesh
		var material := StandardMaterial3D.new()
		material.albedo_color = colors[anchor_name]
		material.emission_enabled = true
		material.emission = colors[anchor_name]
		material.emission_energy_multiplier = 0.8
		marker.material_override = material
		anchor.add_child(marker)


func _add_label(actor: Node3D, text_value: String, color: Color) -> void:
	var label := Label3D.new()
	label.text = text_value
	label.font_size = 34
	label.pixel_size = 0.0024
	label.modulate = color
	label.outline_size = 8
	label.position = Vector3(0.0, -0.12, 0.0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	actor.add_child(label)


func _center_model(model: Node3D) -> void:
	var bounds := _node3d_bounds(model)
	if bounds.size == Vector3.ZERO:
		return
	var center := bounds.get_center()
	model.position -= model.transform.basis * Vector3(center.x, bounds.position.y, center.z)


func _node3d_bounds(root_node: Node3D) -> AABB:
	var bounds := AABB()
	var has_bounds := false
	var root_inv := root_node.global_transform.affine_inverse()
	var stack: Array[Node] = [root_node]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is MeshInstance3D:
			var mesh_node := node as MeshInstance3D
			if mesh_node.mesh == null:
				continue
			var box := mesh_node.get_aabb()
			var transform := root_inv * mesh_node.global_transform
			var transformed := AABB(transform * box.position, Vector3.ZERO)
			for corner in _aabb_corners(box):
				transformed = transformed.expand(transform * corner)
			bounds = transformed if not has_bounds else bounds.merge(transformed)
			has_bounds = true
	return bounds if has_bounds else AABB()


func _aabb_corners(box: AABB) -> Array[Vector3]:
	var p := box.position
	var s := box.size
	return [p, p + Vector3(s.x, 0, 0), p + Vector3(0, s.y, 0), p + Vector3(0, 0, s.z), p + Vector3(s.x, s.y, 0), p + Vector3(s.x, 0, s.z), p + Vector3(0, s.y, s.z), p + s]


func _capture_after_frames() -> void:
	for _i in 6:
		await get_tree().process_frame
	var output_path := "user://unit_actor_review.png"
	var image := get_viewport().get_texture().get_image()
	if image == null:
		print("UNIT_ACTOR_REVIEW_CAPTURE unavailable (renderer has no viewport texture)")
		get_tree().quit(1)
		return
	var error := image.save_png(output_path)
	print("UNIT_ACTOR_REVIEW_CAPTURE path=%s error=%d" % [ProjectSettings.globalize_path(output_path), error])
	get_tree().quit(0 if error == OK else 1)
