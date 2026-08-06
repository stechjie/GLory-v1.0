extends VFXBlockRoot
class_name VFXDoomBloodLink3D

# Doom Guard's blood pact link.
#
# How this differs from the generic VFXTrackedLink3D: the body is a hand-painted
# rope plate tiled along its length, each end carries an incomplete knot, and it
# tears from the middle when it breaks.  Design bible 8 asks for "a dark red /
# black-violet life chain with weight, undulating irregularly"; the generic link
# is a glowing ribbon with neither weight nor endpoint knots.
#
# Endpoint tracking reuses VFXTrackedLink3D's convention
# (to_local(node.global_position)) so both read the same under the battle camera.

const SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")
const CHAIN_TEXTURE := "res://assets/vfx/skills/dark_doom_link/doom_link_chain.png"
const KNOT_TEXTURE := "res://assets/vfx/skills/dark_doom_link/doom_link_knot.png"
const TEAR_TEXTURE := "res://assets/vfx/skills/dark_doom_link/doom_link_tear.png"

const CHAIN_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform sampler2D chain_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 dark_tint : source_color = vec4(0.14, 0.05, 0.12, 1.0);
uniform vec4 body_tint : source_color = vec4(1.0);
uniform vec4 core_tint : source_color = vec4(1.0);
uniform float opacity = 1.0;
uniform float tiling = 3.0;
uniform float scroll = 0.0;

void fragment() {
	vec2 uv = vec2(UV.x * tiling + scroll, UV.y);
	vec4 tex = texture(chain_tex, uv);
	float source_alpha = tex.a;
	vec3 color = mix(tex.rgb * dark_tint.rgb, tex.rgb * body_tint.rgb, smoothstep(0.06, 0.55, source_alpha));
	float hot = smoothstep(0.62, 1.0, max(tex.r, max(tex.g, tex.b)));
	color = mix(color, core_tint.rgb, hot * 0.30);
	float alpha = source_alpha * opacity;
	if (alpha < 0.02) { discard; }
	ALBEDO = color;
	EMISSION = color * (0.30 + hot * 1.30);
	ALPHA = alpha;
}
"""

const SEGMENTS := 20

var _origin_ref: WeakRef
var _target_ref: WeakRef
var _origin_fallback := Vector3.ZERO
var _target_fallback := Vector3.ZERO
var _chain: MeshInstance3D
var _chain_mesh: ArrayMesh
var _chain_material: ShaderMaterial
var _knots: Array[MeshInstance3D] = []
var _profile: VFXProfile3D
var _elapsed := 0.0
var _mesh_accum := 0.0
var _persistent := false
var _released := false
var _buf_verts := PackedVector3Array()
var _buf_uvs := PackedVector2Array()
var _buf_indices := PackedInt32Array()
var _buf_arrays: Array = []

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	play_link(context.get("origin", Vector3(-1.0, .8, 0.0)), context.get("target", Vector3(1.0, .8, 0.0)),
		profile, context.get("origin_node"), context.get("target_node"), bool(context.get("persistent", false)))

func play_link(origin: Vector3, target: Vector3, profile: VFXProfile3D = null, origin_node: Variant = null, target_node: Variant = null, persistent: bool = false) -> void:
	begin()
	_persistent = persistent
	_released = false
	_profile = profile if profile != null else _fallback_profile()
	_origin_fallback = origin
	_target_fallback = target
	if is_instance_valid(origin_node) and origin_node is Node3D:
		_origin_ref = weakref(origin_node)
	if is_instance_valid(target_node) and target_node is Node3D:
		_target_ref = weakref(target_node)
	_update_endpoints()
	_init_buffers()
	_build_chain()
	_knots.append(_make_knot("DoomLinkKnot_Origin"))
	_knots.append(_make_knot("DoomLinkKnot_Target"))
	_update_ribbon()
	if not _persistent:
		await get_tree().create_timer(_profile.duration).timeout
		release_link(.24)

# Pact broken: tear from the middle, then fade the body out.  BattleVfx calls
# this when the target dies or the guard rebinds.
func release_link(fade_duration: float = 0.20) -> void:
	if _finished or _released:
		return
	_released = true
	_spawn_tear()
	var tw := track_tween(create_tween())
	tw.tween_method(func(value: float) -> void:
		if is_instance_valid(_chain_material):
			_chain_material.set_shader_parameter("opacity", value)
		for knot in _knots:
			if is_instance_valid(knot):
				knot.transparency = 1.0 - value / maxf(.001, vfx_alpha),
		vfx_alpha, 0.0, fade_duration)
	tw.tween_callback(finish)

func _process(delta: float) -> void:
	if _finished or _profile == null:
		return
	_elapsed += delta
	_mesh_accum += delta
	if is_instance_valid(_chain_material):
		# Slow scroll along the body so it reads as alive rather than a rope
		# decal stuck to the screen.
		_chain_material.set_shader_parameter("scroll", _elapsed * .12)
	if _mesh_accum >= .055:
		_mesh_accum = 0.0
		_update_endpoints()
		_update_ribbon()

func _endpoint(ref: WeakRef, fallback: Vector3) -> Vector3:
	if ref == null:
		return fallback
	var node: Variant = ref.get_ref()
	if is_instance_valid(node) and node is Node3D:
		return to_local((node as Node3D).global_position)
	return fallback

func _update_endpoints() -> void:
	_origin_fallback = _endpoint(_origin_ref, _origin_fallback)
	_target_fallback = _endpoint(_target_ref, _target_fallback)

# Same curve as VFXTrackedLink3D, with a slightly larger amplitude so the
# undulation carries more weight.
func _curve_point(t: float) -> Vector3:
	var a := _origin_fallback
	var b := _target_fallback
	var d := b - a
	var side := Vector3(-d.y, d.x, 0.0).normalized()
	var sag := Vector3.DOWN * sin(t * PI) * _profile.size * .16
	var wave := side * sin(t * PI * 2.6 + _elapsed * 3.4) * _profile.size * .085
	return a.lerp(b, t) + Vector3.UP * .52 + sag + wave

func _init_buffers() -> void:
	var vcount := (SEGMENTS + 1) * 2
	_buf_verts.resize(vcount)
	_buf_uvs.resize(vcount)
	_buf_indices.resize(SEGMENTS * 6)
	for i in range(SEGMENTS):
		var k := i * 2
		var o := i * 6
		_buf_indices[o] = k
		_buf_indices[o + 1] = k + 1
		_buf_indices[o + 2] = k + 3
		_buf_indices[o + 3] = k
		_buf_indices[o + 4] = k + 3
		_buf_indices[o + 5] = k + 2
	for i in range(SEGMENTS + 1):
		var t := float(i) / float(SEGMENTS)
		var k := i * 2
		_buf_uvs[k] = Vector2(t, 0.0)
		_buf_uvs[k + 1] = Vector2(t, 1.0)
	_buf_arrays.resize(Mesh.ARRAY_MAX)
	_buf_arrays[Mesh.ARRAY_TEX_UV] = _buf_uvs
	_buf_arrays[Mesh.ARRAY_INDEX] = _buf_indices

func _build_chain() -> void:
	_chain = MeshInstance3D.new()
	_chain.name = "DoomLinkChain"
	_chain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_chain_mesh = ArrayMesh.new()
	_chain.mesh = _chain_mesh
	_chain_material = ShaderMaterial.new()
	_chain_material.shader = SHADER_CACHE.get_shader(CHAIN_SHADER)
	var texture := load(CHAIN_TEXTURE) as Texture2D
	if texture != null:
		_chain_material.set_shader_parameter("chain_tex", texture)
	_chain_material.set_shader_parameter("dark_tint", _profile.dark_color)
	_chain_material.set_shader_parameter("body_tint", _profile.main_color)
	_chain_material.set_shader_parameter("core_tint", _profile.core_color)
	_chain_material.set_shader_parameter("opacity", vfx_alpha)
	_chain_material.set_shader_parameter("tiling", 1.8)
	_chain.material_override = _chain_material
	add_child(_chain)

func _make_knot(node_name: String) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(_profile.size * .46, _profile.size * .50)
	var knot := MeshInstance3D.new()
	knot.name = node_name
	knot.mesh = quad
	knot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.no_depth_test = true
	material.render_priority = 2
	material.albedo_texture = load(KNOT_TEXTURE) as Texture2D
	material.albedo_color = _profile.main_color
	material.emission_enabled = true
	material.emission = _profile.core_color
	material.emission_texture = material.albedo_texture
	material.emission_energy_multiplier = minf(_profile.emission_energy, 1.6)
	knot.material_override = material
	add_child(knot)
	return knot

func _update_ribbon() -> void:
	var width := _profile.size * .21
	for i in range(SEGMENTS + 1):
		var t := float(i) / float(SEGMENTS)
		var point := _curve_point(t)
		var prev := _curve_point(maxf(0.0, t - .02))
		var next := _curve_point(minf(1.0, t + .02))
		var tangent := (next - prev).normalized()
		# Side vector is tangent x UP.  TrackedLink's (-y, x, 0) cannot be reused:
		# it degenerates to a zero vector when the tangent is near horizontal,
		# which is exactly the case for two units facing off in the same lane, and
		# the body gets pinched into a broken hairline.  That was the "rope turns
		# into a dotted line" artefact in the first capture.
		var side := tangent.cross(Vector3.UP)
		if side.length_squared() < .0001:
			side = tangent.cross(Vector3.FORWARD)
		side = side.normalized()
		# Narrow slightly at both ends so the body reads as tucked into the knots
		# rather than cut off.
		var taper := .42 + sin(t * PI) * .58
		var k := i * 2
		_buf_verts[k] = point - side * width * taper
		_buf_verts[k + 1] = point + side * width * taper
	_buf_arrays[Mesh.ARRAY_VERTEX] = _buf_verts
	_chain_mesh.clear_surfaces()
	_chain_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _buf_arrays)
	if _knots.size() == 2:
		if is_instance_valid(_knots[0]):
			_knots[0].position = _curve_point(.04)
		if is_instance_valid(_knots[1]):
			_knots[1].position = _curve_point(.96)

func _spawn_tear() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(_profile.size * .92, _profile.size * .46)
	var tear := MeshInstance3D.new()
	tear.name = "DoomLinkTear"
	tear.mesh = quad
	tear.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tear.position = _curve_point(.5)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.no_depth_test = true
	material.render_priority = 3
	material.albedo_texture = load(TEAR_TEXTURE) as Texture2D
	material.albedo_color = _profile.main_color
	material.emission_enabled = true
	material.emission = _profile.core_color
	material.emission_texture = material.albedo_texture
	material.emission_energy_multiplier = minf(_profile.emission_energy, 2.0)
	tear.material_override = material
	tear.scale = Vector3.ONE * .30
	add_child(tear)
	var tw := track_tween(create_tween())
	tw.set_parallel(true)
	tw.tween_property(tear, "scale", Vector3.ONE * 1.10, .34).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(tear, "transparency", 1.0, .46).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)

func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	if is_instance_valid(_chain_material):
		_chain_material.set_shader_parameter("opacity", vfx_alpha)

func _fallback_profile() -> VFXProfile3D:
	var p := VFXProfile3D.new()
	p.dark_color = Color(.14, .05, .12)
	p.main_color = Color(1.0, .88, .94)
	p.core_color = Color(1.0, .74, .84)
	p.size = 1.0
	p.duration = 2.4
	p.particle_count = 6
	p.emission_energy = 1.6
	return p
