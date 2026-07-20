extends VFXBlockRoot
class_name VFXLightningBall

const IMPACT := preload("res://effects/vfx3d/VFXTargetImpact.gd")
const BEAM := preload("res://effects/vfx3d/VFXLightningBeam.gd")

const BALL_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 core_color : source_color = vec4(0.05, 0.42, 1.0, 1.0);
uniform float pulse = 0.0;
void fragment() {
    vec2 p = UV - vec2(0.5);
    float r = length(p) * 2.0;
    float flow = sin(p.x * 21.0 + TIME * 7.0 + sin(p.y * 13.0 - TIME * 4.0));
    flow *= cos(p.y * 19.0 - TIME * 5.0 + p.x * 8.0);
    float torn_edge = smoothstep(1.02, 0.66 + flow * 0.10, r);
    float veins = smoothstep(0.56, 0.94, abs(flow)) * torn_edge;
    float rim = smoothstep(0.92, 0.52, r) - smoothstep(0.62, 0.20, r);
    float alpha = clamp(torn_edge * 0.24 + rim * 0.54 + veins * 0.44, 0.0, 0.92);
    vec3 cyan = vec3(0.36, 0.92, 1.0);
    ALBEDO = mix(core_color.rgb, cyan, veins * 0.62 + rim * 0.22);
    EMISSION = ALBEDO * (3.2 + pulse * 1.8 + veins * 2.6);
    ALPHA = alpha;
}
"""

const TAIL_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 head_color : source_color = vec4(0.58, 0.96, 1.0, 1.0);
uniform vec4 tail_color : source_color = vec4(0.02, 0.24, 0.92, 1.0);
uniform float strength = 1.0;
void fragment() {
    float center = smoothstep(0.50, 0.08, abs(UV.y - 0.5));
    float fade = pow(clamp(1.0 - UV.x, 0.0, 1.0), 1.35);
    float flow = 0.64 + 0.36 * sin(UV.x * 19.0 - TIME * 9.0 + UV.y * 5.0);
    float torn = smoothstep(0.14, 0.54, flow + fade * 0.24);
    vec3 color = mix(tail_color.rgb, head_color.rgb, pow(fade, 0.72));
    float alpha = center * fade * torn * strength;
    ALBEDO = color * (0.72 + center * 0.55);
    EMISSION = ALBEDO * (2.2 + fade * 2.4);
    ALPHA = clamp(alpha, 0.0, 0.94);
}
"""

const SPARK_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 spark_color : source_color = vec4(0.28, 0.82, 1.0, 1.0);
void vertex() {
    MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}
void fragment() {
    vec2 p = abs(UV - vec2(0.5)) * 2.0;
    float horizontal = smoothstep(0.22, 0.015, p.y) * smoothstep(1.0, 0.08, p.x);
    float vertical = smoothstep(0.22, 0.015, p.x) * smoothstep(1.0, 0.08, p.y);
    float diamond = smoothstep(0.92, 0.16, p.x + p.y);
    float core = smoothstep(0.34, 0.02, length(p));
    float flicker = 0.78 + 0.22 * sin(TIME * 18.0 + UV.x * 11.0);
    float mask = clamp(max(max(horizontal, vertical) * 0.76, diamond * 0.58) + core, 0.0, 1.0);
    vec3 cyan_white = mix(spark_color.rgb, vec3(0.82, 0.98, 1.0), core);
    ALBEDO = cyan_white * flicker;
    EMISSION = cyan_white * (3.0 + core * 3.2) * flicker;
    ALPHA = mask * flicker;
}
"""

func play_ball(origin: Vector3, target: Vector3, target_node: Node3D = null) -> void:
	begin()
	var tracked_target := _tracked_target_position(target, target_node)
	var direction := (tracked_target + Vector3(0.0, 0.30, 0.0) - (origin + Vector3(0.0, 1.05, 0.0))).normalized()
	var ball := Node3D.new()
	ball.name = "BallMotion"
	ball.position = origin + Vector3(0.0, 1.05, 0.0)
	add_child(ball)
	var core := _make_irregular_core()
	core.name = "LightningBallCore"
	ball.add_child(core)
	var shell := _make_shell()
	shell.name = "LightningBallShell"
	ball.add_child(shell)
	for i in 3:
		ball.add_child(_make_orbit_arc(i))
	ball.add_child(_make_front_arc(direction))
	ball.add_child(_make_comet_tail(direction))
	var trail := _make_directional_trail(-direction)
	trail.name = "BallTrail"
	ball.add_child(trail)
	var player := AnimationPlayer.new()
	add_child(player)
	var library := AnimationLibrary.new()
	var animation := Animation.new()
	animation.length = 0.92
	var pulse_track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(pulse_track, NodePath("BallMotion/LightningBallShell:material_override:shader_parameter/pulse"))
	animation.track_insert_key(pulse_track, 0.0, 0.2)
	animation.track_insert_key(pulse_track, 0.22, 1.0)
	animation.track_insert_key(pulse_track, 0.66, 0.35)
	animation.track_insert_key(pulse_track, 0.92, 1.5)
	var scale_track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(scale_track, NodePath("BallMotion/LightningBallCore:scale"))
	animation.track_insert_key(scale_track, 0.0, Vector3.ONE * 0.66)
	animation.track_insert_key(scale_track, 0.22, Vector3.ONE * 1.08)
	animation.track_insert_key(scale_track, 0.72, Vector3.ONE * 0.94)
	animation.track_insert_key(scale_track, 0.92, Vector3.ONE * 1.28)
	for i in 3:
		var rotation_track := animation.add_track(Animation.TYPE_VALUE)
		animation.track_set_path(rotation_track, NodePath("BallMotion/ArcOrbit%d:rotation" % i))
		var start_rotation := Vector3(0.35 + i * 0.68, i * 1.7, i * 0.42)
		animation.track_insert_key(rotation_track, 0.0, start_rotation)
		animation.track_insert_key(rotation_track, 0.92, start_rotation + Vector3(2.2 + i * 0.35, 3.8 - i * 0.4, 1.4 + i * 0.3))
	library.add_animation("play", animation)
	player.add_animation_library("", library)
	player.play("play")
	var start_position := ball.position
	var travel_elapsed := 0.0
	while travel_elapsed < 0.92:
		await get_tree().process_frame
		if _finished or not is_instance_valid(ball):
			return
		travel_elapsed += get_process_delta_time()
		tracked_target = _tracked_target_position(tracked_target, target_node)
		var ratio := clampf(travel_elapsed / 0.92, 0.0, 1.0)
		var eased := ratio * ratio
		ball.position = start_position.lerp(tracked_target + Vector3(0.0, 0.30, 0.0), eased)
	if is_instance_valid(ball):
		ball.queue_free()
	_play_impact(tracked_target)
	await get_tree().create_timer(0.54).timeout
	finish()

func _tracked_target_position(fallback: Vector3, target_node: Node3D) -> Vector3:
	if target_node == null or not is_instance_valid(target_node):
		return fallback
	var tracked := to_local(target_node.global_position)
	# The supplied point owns the intended impact height; the model node supplies
	# the live ground-plane position while it moves during the projectile flight.
	tracked.y = fallback.y
	return tracked

func _play_impact(target: Vector3) -> void:
	var impact := IMPACT.make(Color(0.42, 0.90, 1.0), 1.42)
	impact.name = "LightningBallImpact"
	impact.position = target + Vector3(0.0, 0.045, 0.0)
	add_child(impact)
	var sparks := IMPACT.burst(Color(0.70, 0.96, 1.0), 22, 4.2, 0.42)
	sparks.position = target + Vector3(0.0, 0.22, 0.0)
	add_child(sparks)
	for i in 3:
		var end := target + Vector3(cos(float(i) * 2.094) * 0.72, 0.06, sin(float(i) * 2.094) * 0.72)
		add_child(_make_ground_arc(target + Vector3(0.0, 0.07, 0.0), end, i))
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(impact, "scale", Vector3.ONE * 1.82, 0.40)
	tween.tween_property(impact.material_override, "shader_parameter/progress", 1.0, 0.40)

func _make_irregular_core() -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var vertices := PackedVector3Array([
		Vector3(0.02, 0.34, -0.03), Vector3(-0.04, -0.30, 0.02),
		Vector3(0.30, 0.03, 0.02), Vector3(0.12, -0.02, 0.27),
		Vector3(-0.22, 0.05, 0.25), Vector3(-0.31, -0.03, -0.04),
		Vector3(-0.10, 0.02, -0.29), Vector3(0.23, -0.05, -0.22)
	])
	var indices := PackedInt32Array([
		0,2,3, 0,3,4, 0,4,5, 0,5,6, 0,6,7, 0,7,2,
		1,3,2, 1,4,3, 1,5,4, 1,6,5, 1,7,6, 1,2,7
	])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	node.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.012, 0.045, 0.28, 1.0)
	material.emission_enabled = true
	material.emission = Color(0.02, 0.28, 1.0)
	material.emission_energy_multiplier = 5.8
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

func _make_shell() -> MeshInstance3D:
	var shell := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.39
	sphere.height = 0.78
	sphere.radial_segments = 12
	sphere.rings = 6
	shell.mesh = sphere
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = BALL_SHADER
	material.shader = shader
	material.set_shader_parameter("core_color", Color(0.03, 0.35, 1.0, 1.0))
	material.set_shader_parameter("pulse", 0.4)
	shell.material_override = material
	shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return shell

func _make_orbit_arc(index: int) -> Node3D:
	var arc := Node3D.new()
	arc.name = "ArcOrbit%d" % index
	arc.rotation = Vector3(0.35 + index * 0.68, index * 1.7, index * 0.42)
	var radius := 0.45 + index * 0.035
	var points: Array[Vector3] = []
	for i in 8:
		var angle := -1.28 + float(i) * 0.37
		var wobble := sin(float(i) * 5.1 + index * 1.7) * 0.045
		points.append(Vector3(cos(angle) * (radius + wobble), sin(angle) * (radius - wobble), sin(angle * 2.0 + index) * 0.06))
	for i in range(points.size() - 1):
		arc.add_child(BEAM.make_ribbon(points[i], points[i + 1], 0.32, Color(0.42, 0.94, 1.0)))
	return arc

func _make_front_arc(direction: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "FrontCompressionArc"
	var side := direction.cross(Vector3.FORWARD)
	if side.length_squared() < 0.001:
		side = direction.cross(Vector3.UP)
	side = side.normalized()
	var center := direction * 0.38
	var points: Array[Vector3] = [
		center - side * 0.22 - direction * 0.04,
		center - side * 0.08 + direction * 0.07,
		center + side * 0.08 + direction * 0.07,
		center + side * 0.22 - direction * 0.04
	]
	for i in range(points.size() - 1):
		root.add_child(BEAM.make_ribbon(points[i], points[i + 1], 0.16, Color(0.68, 0.98, 1.0)))
	return root

func _make_comet_tail(direction: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "CometRibbonTail"
	root.add_child(_make_tapered_ribbon(direction, 0.92, 0.24, 0.10, 0.00, 1.0))
	root.add_child(_make_tapered_ribbon(direction, 0.67, 0.11, 0.08, 0.12, 0.72))
	root.add_child(_make_tapered_ribbon(direction, 0.54, 0.09, -0.07, -0.10, 0.58))
	return root

func _make_tapered_ribbon(direction: Vector3, length: float, head_width: float, bend: float, lateral_offset: float, strength: float) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var side := direction.cross(Vector3.FORWARD)
	if side.length_squared() < 0.001:
		side = direction.cross(Vector3.UP)
	side = side.normalized()
	var vertical := direction.cross(side).normalized()
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var segment_count := 7
	for i in range(segment_count + 1):
		var t := float(i) / float(segment_count)
		var width := lerpf(head_width, 0.012, pow(t, 0.72))
		var curve := sin(t * PI) * bend
		var point := -direction * (0.22 + length * t)
		point += side * (lateral_offset * t + curve)
		point += vertical * sin(t * PI * 1.35) * bend * 0.32
		vertices.append(point - side * width)
		vertices.append(point + side * width)
		uvs.append(Vector2(t, 0.0))
		uvs.append(Vector2(t, 1.0))
		if i < segment_count:
			var base := i * 2
			indices.append_array(PackedInt32Array([base, base + 1, base + 3, base, base + 3, base + 2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	node.mesh = mesh
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = TAIL_SHADER
	material.shader = shader
	material.set_shader_parameter("head_color", Color(0.62, 0.97, 1.0, 1.0))
	material.set_shader_parameter("tail_color", Color(0.015, 0.18, 0.82, 1.0))
	material.set_shader_parameter("strength", strength)
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

func _make_directional_trail(direction: Vector3) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = 8
	particles.lifetime = 0.46
	particles.one_shot = false
	particles.local_coords = false
	particles.randomness = 0.34
	var process := ParticleProcessMaterial.new()
	process.direction = direction
	process.spread = 22.0
	process.initial_velocity_min = 0.45
	process.initial_velocity_max = 1.05
	process.gravity = Vector3.ZERO
	process.scale_min = 0.82
	process.scale_max = 1.35
	particles.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2(0.13, 0.085)
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SPARK_SHADER
	material.shader = shader
	material.set_shader_parameter("spark_color", Color(0.18, 0.72, 1.0, 1.0))
	quad.material = material
	particles.draw_pass_1 = quad
	return particles

func _make_ground_arc(from_pos: Vector3, to_pos: Vector3, index: int) -> Node3D:
	var root := Node3D.new()
	var mid := from_pos.lerp(to_pos, 0.5) + Vector3(sin(index * 2.1) * 0.10, 0.03, cos(index * 1.7) * 0.10)
	root.add_child(BEAM.make_ribbon(from_pos, mid, 0.18, Color(0.25, 0.72, 1.0)))
	root.add_child(BEAM.make_ribbon(mid, to_pos, 0.13, Color(0.60, 0.96, 1.0)))
	return root

func _energy_material(color: Color, energy: float, alpha: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.albedo_color = Color(color.r, color.g, color.b, alpha)
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = energy
	material.no_depth_test = true
	return material
