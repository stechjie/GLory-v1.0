extends Node

# Default/headless: check every material using the shared character shader.
# Add -- --rendered for the GPU regression: two overlapping faces in ONE mesh,
# submitted in both triangle orders, must show only the nearer red face. A
# legacy ALPHA-writing shader is rendered as a negative control, so a missing
# camera/empty viewport cannot make this test pass.
const CheckHarness := preload("res://tools/CheckHarness.gd")
const CHARACTER_SHADER := "res://shaders/character_toon.gdshader"

var _h: CheckHarness
var _textures: Dictionary = {}
var _material_count := 0
var _partial_alpha_count := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new("character_opaque_depth")
	var source := FileAccess.get_file_as_string(CHARACTER_SHADER)
	var code := _without_comments(source)
	var alpha_token := RegEx.create_from_string("\\bALPHA\\b")
	_h.expect(not source.is_empty(), "shader_missing", CHARACTER_SHADER)
	_h.expect(alpha_token.search(code) == null, "character_in_transparent_pipeline",
		"Opaque character bodies must not read/write ALPHA; it disables their opaque depth writes.")
	_h.expect(not code.contains("depth_draw_never") and not code.contains("depth_test_disabled"),
		"character_depth_disabled", "Characters must write and test opaque depth.")
	_scan_materials("res://assets/models")
	_h.expect(_material_count >= 60, "material_scan_incomplete",
		"Expected the shared shader's full character material set, found %d." % _material_count)
	_h.note("Scanned %d character materials and %d unique source albedos; %d source textures contain partial alpha."
		% [_material_count, _textures.size(), _partial_alpha_count])
	if OS.get_cmdline_user_args().has("--rendered"):
		if _h.expect(DisplayServer.get_name() != "headless", "rendered_check_without_gpu",
			"Run --rendered without --headless; a dummy renderer cannot verify depth."):
			await _check_rendered_depth(source)
	else:
		_h.note("GPU overlap check not requested; run this scene with -- --rendered to verify pixels.")
	_h.finish(get_tree())


func _without_comments(source: String) -> String:
	var block := RegEx.create_from_string("(?s)/\\*.*?\\*/")
	var line := RegEx.create_from_string("//[^\\n]*")
	return line.sub(block.sub(source, "", true), "", true)


func _scan_materials(directory: String) -> void:
	for subdirectory in DirAccess.get_directories_at(directory):
		if not subdirectory.begins_with("."):
			_scan_materials(directory.path_join(subdirectory))
	for filename in DirAccess.get_files_at(directory):
		if not filename.ends_with(".tres"):
			continue
		var path := directory.path_join(filename)
		if not FileAccess.get_file_as_string(path).contains(CHARACTER_SHADER):
			continue
		var material := load(path) as ShaderMaterial
		if not _h.expect(material != null, "character_material_missing", path):
			continue
		_material_count += 1
		var color: Variant = material.get_shader_parameter("albedo_color")
		_h.expect(color == null or (color is Color and is_equal_approx((color as Color).a, 1.0)),
			"character_requests_opacity", "%s: a transparent character needs its own material/shader." % path)
		var texture := material.get_shader_parameter("albedo_texture") as Texture2D
		if not _h.expect(texture != null, "character_albedo_missing", path):
			continue
		var texture_path := texture.resource_path
		if _textures.has(texture_path):
			continue
		_textures[texture_path] = true
		var image := Image.load_from_file(ProjectSettings.globalize_path(texture_path))
		if not _h.expect(image != null and not image.is_empty(), "source_albedo_missing", texture_path):
			continue
		if image.detect_alpha() != Image.ALPHA_NONE:
			_partial_alpha_count += 1
			if OS.get_cmdline_user_args().has("--require-opaque-textures"):
				_h.fail("source_albedo_has_alpha", texture_path)


func _check_rendered_depth(source: String) -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(96, 96)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color.BLACK
	environment.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	viewport.add_child(environment)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	camera.position = Vector3(0.0, 0.0, 3.0)
	camera.current = true
	viewport.add_child(camera)
	var instance := MeshInstance3D.new()
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	viewport.add_child(instance)
	var shader := Shader.new()
	shader.code = source
	var material := _fixture_material(shader)
	instance.material_override = material
	for front_first in [true, false]:
		instance.mesh = _overlap_mesh(front_first)
		var pixel := await _center_pixel(viewport)
		_h.expect(_is_opaque_red(pixel), "rear_face_leaks_through",
			"front_first=%s center=%s: nearer red face must occlude the blue face in the same surface."
			% [str(front_first), str(pixel)])
	var legacy := Shader.new()
	legacy.code = source.replace("ALBEDO = base.rgb;", "ALBEDO = base.rgb;\n\tALPHA = base.a;")
	instance.material_override = _fixture_material(legacy)
	instance.mesh = _overlap_mesh(true)
	var broken_pixel := await _center_pixel(viewport)
	_h.expect(not _is_opaque_red(broken_pixel), "negative_control_did_not_fail",
		"The legacy ALPHA-writing shader must expose the overlap bug; got %s." % str(broken_pixel))
	_h.note("GPU overlap sampled with %s / %s; legacy center=%s."
		% [DisplayServer.get_name(), RenderingServer.get_current_rendering_method(), str(broken_pixel)])
	viewport.queue_free()
	await get_tree().process_frame


func _fixture_material(shader: Shader) -> ShaderMaterial:
	var image := Image.create(4, 1, false, Image.FORMAT_RGBA8)
	for x in 4:
		image.set_pixel(x, 0, Color(1.0, 0.0, 0.0, 0.5) if x < 2 else Color(0.0, 0.0, 1.0, 0.5))
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("albedo_texture", ImageTexture.create_from_image(image))
	material.set_shader_parameter("albedo_color", Color.WHITE)
	material.set_shader_parameter("shadow_tint", Color.WHITE)
	material.set_shader_parameter("rim_strength", 0.0)
	return material


func _overlap_mesh(front_first: bool) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for front in ([true, false] if front_first else [false, true]):
		var base := vertices.size()
		var z := 0.3 if front else 0.0
		vertices.append_array(PackedVector3Array([
			Vector3(-0.8, 0.8, z), Vector3(0.8, 0.8, z),
			Vector3(0.8, -0.8, z), Vector3(-0.8, -0.8, z)]))
		for corner in 4:
			normals.append(Vector3(0.0, 0.0, 1.0))
			uvs.append(Vector2(0.125 if front else 0.625, 0.5))
		indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _center_pixel(viewport: SubViewport) -> Color:
	for frame in 3:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image().get_pixel(48, 48)


func _is_opaque_red(pixel: Color) -> bool:
	return pixel.r > 0.90 and pixel.g < 0.05 and pixel.b < 0.05 and pixel.a > 0.98
