extends Node

# Run without --headless. Uses actual pixels to guard the projected outline:
# opaque interiors stay visible, an outline remains, and the silhouette cannot
# expand beyond the 1.25 px cap plus rasterization tolerance. No asset bundle is
# needed; all geometry is generated and the production outline is loaded.
var _failures: Array[String] = []
var _results: Array[Dictionary] = []

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("character_outline_projection requires a real rendering device.")
		get_tree().quit(1)
		return
	var viewport := SubViewport.new()
	viewport.size = Vector2i(192, 192)
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.25, 0.25, 0.25)
	environment.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	viewport.add_child(environment)
	var camera := Camera3D.new()
	camera.current = true
	viewport.add_child(camera)
	var object := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 96
	sphere.rings = 48
	object.mesh = sphere
	object.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	viewport.add_child(object)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color.WHITE
	object.material_override = material
	var outline := ShaderMaterial.new()
	outline.shader = load("res://shaders/character_outline.gdshader")
	outline.set_shader_parameter("outline_color", Color.BLACK)
	outline.set_shader_parameter("outline_width", 0.06)
	for projection in [Camera3D.PROJECTION_ORTHOGONAL, Camera3D.PROJECTION_PERSPECTIVE]:
		camera.projection = projection
		for object_scale in [0.01, 1.0, 100.0]:
			for stretched in [false, true]:
				object.scale = Vector3(1.2, 0.8, 1.0) * object_scale if stretched else Vector3.ONE * object_scale
				camera.position = Vector3(0, 0, 2.0 * object_scale)
				camera.size = 1.6 * object_scale
				camera.near = 0.001 * object_scale
				camera.far = 10.0 * object_scale
				var label := "%s scale=%s stretched=%s" % ["ortho" if projection == Camera3D.PROJECTION_ORTHOGONAL else "perspective", object_scale, stretched]
				material.next_pass = null
				var baseline := await _capture(viewport)
				material.next_pass = outline
				var outlined := await _capture(viewport)
				_check_pixels(label, baseline, outlined)
	# Just in front of the near plane: verifies small positive perspective w.
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.near = 0.001
	camera.far = 1.0
	camera.position = Vector3(0, 0, 0.008)
	object.scale = Vector3.ONE * 0.006
	material.next_pass = null
	var near_base := await _capture(viewport)
	material.next_pass = outline
	_check_pixels("perspective near plane", near_base, await _capture(viewport))
	print("CHARACTER_OUTLINE_PROJECTION " + JSON.stringify({"renderer": RenderingServer.get_current_rendering_method(), "cases": _results, "failures": _failures}))
	print("CHECK_RESULT name=character_outline_projection status=%s checked=%d failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _results.size(), _failures.size()])
	viewport.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if _failures.is_empty() else 1)

func _capture(viewport: SubViewport) -> Image:
	for frame in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func _white(image: Image, x: int, y: int) -> bool:
	var color := image.get_pixel(x, y)
	return minf(color.r, minf(color.g, color.b)) > 0.9

func _check_pixels(label: String, baseline: Image, outlined: Image) -> void:
	var interior := 0
	var covered := 0
	var border := 0
	var escaped := 0
	for y in range(3, 189):
		for x in range(3, 189):
			var dark := outlined.get_pixel(x, y).r < 0.1
			var deep_inside := _white(baseline, x, y) and _white(baseline, x - 2, y) and _white(baseline, x + 2, y) and _white(baseline, x, y - 2) and _white(baseline, x, y + 2)
			if deep_inside:
				interior += 1
				if dark:
					covered += 1
			if dark and not _white(baseline, x, y):
				border += 1
				var nearby := false
				for dy in range(-3, 4):
					for dx in range(-3, 4):
						nearby = nearby or _white(baseline, x + dx, y + dy)
				if not nearby:
					escaped += 1
	var result := {"name": label, "interior_pixels": interior, "covered_interior_pixels": covered, "outline_pixels": border, "outline_beyond_3px": escaped}
	_results.append(result)
	if interior < 100 or covered != 0 or border < 20 or escaped != 0:
		_failures.append(JSON.stringify(result))
