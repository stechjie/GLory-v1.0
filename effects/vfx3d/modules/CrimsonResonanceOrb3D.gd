extends Node3D
class_name CrimsonResonanceOrb3D

# A persistent head-mounted Crimson 4 cue. The simulation owns the stack count;
# this node only grows, spins and fades to represent that count.
const DEFAULT_PROFILE := preload("res://effects/vfx3d/profiles/examples/crimson_resonance_orb.tres")
const MAX_STACKS := 10

const CORE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never, blend_mix;
uniform vec4 dark_color : source_color;
uniform vec4 main_color : source_color;
uniform vec4 core_color : source_color;
uniform float opacity = 0.0;
uniform float flare = 0.0;
uniform float phase = 0.0;
varying vec3 local_pos;
void vertex() {
	float broken = sin(VERTEX.x * 15.0 + VERTEX.y * 8.0 + phase) * 0.064
		+ sin(VERTEX.z * 18.0 - VERTEX.y * 13.0 + phase * 0.7) * 0.045;
	VERTEX += NORMAL * broken;
	local_pos = VERTEX;
}
void fragment() {
	float stream = sin(atan(local_pos.z, local_pos.x) * 5.0 + local_pos.y * 9.0 - TIME * 2.5 + phase)
		* sin(local_pos.x * 12.0 - local_pos.z * 10.0 + TIME * 1.7);
	float vein = smoothstep(0.30, 0.75, stream);
	float fleck = pow(max(0.0, sin(local_pos.x * 23.0 + local_pos.z * 19.0 + TIME * 2.6)), 20.0);
	float edge = pow(1.0 - max(dot(NORMAL, VIEW), 0.0), 2.0);
	vec3 body = mix(dark_color.rgb, main_color.rgb, clamp(vein * 0.95 + edge * 0.31, 0.0, 1.0));
	body = mix(body, core_color.rgb, clamp(fleck * 0.13 + vein * 0.09 + flare * 0.11, 0.0, 0.37));
	ALBEDO = body;
	EMISSION = body * (0.48 + vein * 2.0 + edge * 0.9 + flare * 1.1);
	ALPHA = opacity;
}
"""

const HALO_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, blend_add;
uniform vec4 main_color : source_color;
uniform vec4 core_color : source_color;
uniform float opacity = 0.0;
uniform float flare = 0.0;
uniform float world_radius = 0.0;
void vertex() {
	VERTEX.xy *= world_radius;
	VERTEX.z = -0.20;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}
void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float a = atan(p.y, p.x);
	float r = length(p);
	float irregular = 0.045 * sin(a * 7.0 - TIME * 1.8) + 0.026 * sin(a * 13.0 + TIME * 2.3);
	float gaps = smoothstep(-0.30, 0.48, sin(a * 5.0 - TIME * 0.9) + sin(a * 9.0 + TIME * 1.4) * 0.45);
	float mist = smoothstep(1.09 + irregular, 0.26, r) * gaps;
	float hot = smoothstep(0.72, 0.12, r);
	float white_hot = smoothstep(0.35, 0.045, r);
	float rays = 0.0;
	for (int i = 0; i < 4; i++) {
		float ray_angle = float(i) * 1.5707963 + 0.45 + sin(TIME * 0.9 + float(i) * 2.2) * 0.22;
		float crooked = sin(r * 20.0 + float(i) * 3.2 - TIME * 5.0) * 0.10;
		float distance_to_ray = abs(sin(a - ray_angle - crooked)) * r;
		float thread = 1.0 - smoothstep(0.008, 0.044, distance_to_ray);
		float span = smoothstep(0.27, 0.39, r) * (1.0 - smoothstep(0.76, 1.0, r));
		rays = max(rays, thread * span * (0.60 + 0.40 * sin(TIME * 12.0 + float(i) * 2.0)));
	}
	float alpha = (mist * 0.18 + hot * 0.42 + white_hot * 0.95 + rays * 0.92) * opacity * (1.0 + flare * 0.45);
	vec3 color = mix(main_color.rgb, core_color.rgb, hot * 0.46);
	color = mix(color, vec3(1.0, 0.77, 0.88), white_hot);
	color = mix(color, vec3(1.0, 0.47, 0.37), rays * 0.8);
	ALBEDO = color;
	EMISSION = color * (2.0 + white_hot * 3.6 + rays * 2.8 + flare * 1.0);
	ALPHA = clamp(alpha, 0.0, 0.95);
}
"""

const FILAMENT_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, blend_add;
uniform float opacity = 0.0;
uniform float flare = 0.0;
uniform float world_radius = 0.0;
uniform float spin_angle = 0.0;
void vertex() {
	float s = sin(spin_angle);
	float c = cos(spin_angle);
	VERTEX.xy = mat2(vec2(c, s), vec2(-s, c)) * VERTEX.xy * world_radius;
	VERTEX.z = -0.18;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}
void fragment() {
	ALBEDO = COLOR.rgb;
	EMISSION = COLOR.rgb * (2.9 + flare * 1.5);
	ALPHA = COLOR.a * opacity * (0.81 + 0.19 * sin(TIME * 13.0 + COLOR.g * 11.0));
}
"""

static var _sphere_mesh: SphereMesh
static var _filament_mesh: ArrayMesh
static var _core_shader: Shader
static var _halo_shader: Shader
static var _filament_shader: Shader

var _profile: VFXProfile3D
var _body: Node3D
var _core_material: ShaderMaterial
var _halo_material: ShaderMaterial
var _filament_material: ShaderMaterial
var _stacks := 0
var _radius := 0.0
var _opacity := 0.0
var _flare := 0.0
var _phase := 0.0
var _arc_spin := 0.0


func _ready() -> void:
	if _profile == null:
		_profile = DEFAULT_PROFILE
	position = Vector3(0.0, 0.24, -0.04)
	_phase = float(get_instance_id() % 71) * 0.19
	_build_once()
	visible = false
	set_process(false)


func configure(profile: VFXProfile3D) -> void:
	_profile = profile if profile != null else DEFAULT_PROFILE
	if is_inside_tree():
		_apply_colors()


func set_stacks(value: int) -> void:
	var next_count := clampi(value, 0, MAX_STACKS)
	if next_count == _stacks:
		return
	var gained := next_count > _stacks
	_stacks = next_count
	if gained:
		_flare = 1.0
		if _radius <= 0.001:
			_radius = _target_radius() * 0.55
	visible = true
	set_process(true)


func _process(delta: float) -> void:
	var follow := 1.0 - exp(-delta * (10.0 if _stacks > 0 else 13.0))
	_radius = lerpf(_radius, _target_radius(), follow)
	_opacity = lerpf(_opacity, 1.0 if _stacks > 0 else 0.0, follow)
	_flare = maxf(0.0, _flare - delta * 3.6)
	_body.scale = Vector3.ONE * (_radius * 0.55 * (1.0 + _flare * 0.075))
	var speed := float(_profile.parameters.get("spin_speed", 2.1))
	_body.rotate_y(delta * speed)
	_body.rotate_z(delta * speed * 0.32)
	_arc_spin += delta * speed * 0.72
	_set_material_state()
	if _stacks == 0 and _opacity < 0.015:
		visible = false
		set_process(false)


func _target_radius() -> float:
	if _stacks <= 0:
		return 0.0
	return float(_profile.parameters.get("base_radius", 0.106)) \
		+ float(_stacks - 1) * float(_profile.parameters.get("radius_per_stack", 0.010))


func _build_once() -> void:
	if _sphere_mesh == null:
		_sphere_mesh = SphereMesh.new()
		_sphere_mesh.radius = 1.0
		_sphere_mesh.height = 2.0
		_sphere_mesh.radial_segments = 16
		_sphere_mesh.rings = 8
	if _filament_mesh == null:
		_filament_mesh = _make_filament_mesh()
	if _core_shader == null:
		_core_shader = Shader.new()
		_core_shader.code = CORE_SHADER
	if _halo_shader == null:
		_halo_shader = Shader.new()
		_halo_shader.code = HALO_SHADER
	if _filament_shader == null:
		_filament_shader = Shader.new()
		_filament_shader.code = FILAMENT_SHADER

	_body = Node3D.new()
	_body.name = "RotatingEnergy"
	add_child(_body)
	var core := MeshInstance3D.new()
	core.name = "BrokenCrimsonCore"
	core.mesh = _sphere_mesh
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_core_material = ShaderMaterial.new()
	_core_material.shader = _core_shader
	_core_material.set_shader_parameter("phase", _phase)
	core.material_override = _core_material
	_body.add_child(core)

	var filament := MeshInstance3D.new()
	filament.name = "SpinningFilaments"
	filament.mesh = _filament_mesh
	filament.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_filament_material = ShaderMaterial.new()
	_filament_material.shader = _filament_shader
	_filament_material.render_priority = 1
	filament.material_override = _filament_material
	_body.add_child(filament)

	var halo := MeshInstance3D.new()
	halo.name = "SoftCrimsonGlow"
	var quad := QuadMesh.new()
	quad.size = Vector2(4.0, 4.0)
	halo.mesh = quad
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_halo_material = ShaderMaterial.new()
	_halo_material.shader = _halo_shader
	_halo_material.render_priority = 2
	halo.material_override = _halo_material
	_body.add_child(halo)
	_apply_colors()
	_set_material_state()


func _apply_colors() -> void:
	if _profile == null or _core_material == null:
		return
	for key in ["dark_color", "main_color", "core_color"]:
		_core_material.set_shader_parameter(key, _profile.get(key))
	_halo_material.set_shader_parameter("main_color", _profile.main_color)
	_halo_material.set_shader_parameter("core_color", _profile.core_color)


func _set_material_state() -> void:
	for material in [_core_material, _halo_material, _filament_material]:
		material.set_shader_parameter("opacity", _opacity)
		material.set_shader_parameter("flare", _flare)
	# Billboard vertex shaders replace the parent's basis with the camera basis.
	# Restore the actor's scale explicitly so glow/arcs match the 3D core.
	var actor_scale := 1.0
	if get_parent() is Node3D:
		actor_scale = maxf(0.01, (get_parent() as Node3D).global_basis.get_scale().x)
	var screen_radius := _radius * actor_scale
	_halo_material.set_shader_parameter("world_radius", screen_radius)
	_filament_material.set_shader_parameter("world_radius", screen_radius)
	_filament_material.set_shader_parameter("spin_angle", _arc_spin)


static func _make_filament_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	# Four sparse, crooked discharges. A darker wide body and narrow hot thread
	# share each path; their vertex alpha tapers before a visible line end forms.
	for branch in 4:
		var angle := float(branch) * TAU / 4.0 + 0.31
		var direction := Vector2(cos(angle), sin(angle))
		var sideways := Vector2(-direction.y, direction.x)
		for layer in 2:
			var start := verts.size()
			for i in 6:
				var t := float(i) / 5.0
				var crooked := sin(float(i) * 2.7 + float(branch) * 1.9) * 0.21 * t
				var center := direction * (0.62 + t * (1.93 + 0.20 * float(branch % 2))) + sideways * crooked
				var side := sideways * (0.22 * (1.0 - t) + 0.04) * (1.0 if layer == 0 else 0.42)
				var color := Color(0.76, 0.035, 0.09, (1.0 - t) * 0.53) if layer == 0 \
					else Color(1.0, 0.31 + 0.10 * t, 0.31 - 0.12 * t, (1.0 - t) * 0.93)
				verts.append(Vector3(center.x - side.x, center.y - side.y, 0.0))
				verts.append(Vector3(center.x + side.x, center.y + side.y, 0.0))
				colors.append(color)
				colors.append(color)
				if i < 5:
					var n := start + i * 2
					indices.append_array(PackedInt32Array([n, n + 1, n + 2, n + 1, n + 3, n + 2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
