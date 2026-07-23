extends VFXBlockRoot
class_name VFXShockwave
const SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")

const IMPACT := preload("res://effects/vfx3d/VFXTargetImpact.gd")
const DEBRIS_MODULE := preload("res://effects/vfx3d/modules/VFXDebrisBurst3D.gd")

const DUST_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 dust_color : source_color = vec4(0.30, 0.18, 0.12, 0.72);
void vertex() {
    MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}
void fragment() {
    vec2 p = UV - vec2(0.5);
    p.x *= 0.72;
    float r = length(p) * 2.0;
    float angle = atan(p.y, p.x);
    float torn = sin(angle * 7.0 + TIME * 1.7) * 0.09 + sin(angle * 11.0 - TIME) * 0.045;
    float body = smoothstep(0.92 + torn, 0.18, r);
    float center_hole = smoothstep(0.03, 0.24, r);
    float alpha = body * center_hole * dust_color.a;
    ALBEDO = dust_color.rgb;
    ALPHA = alpha;
}
"""

func play_shockwave(target: Vector3, color := Color(1.0, 0.30, 0.08)) -> void:
	begin()
	var ring := MeshInstance3D.new()
	ring.name = "ShockwaveRing"
	var torus := TorusMesh.new()
	torus.inner_radius = 0.22
	torus.outer_radius = 0.31
	torus.rings = 32
	torus.ring_segments = 8
	ring.mesh = torus
	ring.position = target + Vector3(0.0, 0.035, 0.0)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(color.r, color.g, color.b, 0.95)
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 4.0
	material.no_depth_test = true
	ring.material_override = material
	add_child(ring)
	var ring2 := ring.duplicate() as MeshInstance3D
	ring2.name = "ShockwaveRingSecondary"
	ring2.rotation_degrees.z = 18.0
	ring2.scale = Vector3.ONE * 0.78
	add_child(ring2)
	var core := IMPACT.make(color.lightened(0.28), 1.15)
	core.name = "ShockwaveCore"
	core.position = target + Vector3(0.0, 0.045, 0.0)
	add_child(core)
	var sparks := IMPACT.burst(color.lightened(0.18), 18, 4.0, 0.58)
	sparks.position = target + Vector3(0.0, 0.10, 0.0)
	add_child(sparks)
	var debris := GPUParticles3D.new()
	debris.name = "ShockwaveBlockDebris"
	debris.amount = 12
	debris.lifetime = 0.72
	debris.one_shot = true
	debris.explosiveness = 0.95
	debris.randomness = 0.35
	debris.position = target + Vector3(0, 0.10, 0)
	var debris_mesh := DEBRIS_MODULE.make_shard_mesh(color)
	debris.draw_pass_1 = debris_mesh
	debris.process_material = _debris_process()
	add_child(debris)
	var dust := GPUParticles3D.new()
	dust.name = "ShockwaveGroundDust"
	dust.amount = 10
	dust.lifetime = 0.62
	dust.one_shot = true
	dust.explosiveness = 0.9
	dust.position = target + Vector3(0, 0.05, 0)
	var dust_mesh := QuadMesh.new()
	dust_mesh.size = Vector2(0.34, 0.20)
	var dust_mat := ShaderMaterial.new()
	dust_mat.shader = SHADER_CACHE.get_shader(DUST_SHADER)
	dust_mat.set_shader_parameter("dust_color", Color(0.30, 0.18, 0.12, 0.72))
	dust_mesh.material = dust_mat
	dust.draw_pass_1 = dust_mesh
	dust.process_material = _dust_process()
	add_child(dust)
	var player := AnimationPlayer.new()
	add_child(player)
	var library := AnimationLibrary.new()
	var animation := Animation.new()
	animation.length = 0.56
	var scale_track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(scale_track, NodePath("ShockwaveRing:scale"))
	animation.track_insert_key(scale_track, 0.0, Vector3.ONE * 0.35)
	animation.track_insert_key(scale_track, 0.16, Vector3.ONE * 1.0)
	animation.track_insert_key(scale_track, 0.56, Vector3.ONE * 5.4)
	var scale_track_2 := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(scale_track_2, NodePath("ShockwaveRingSecondary:scale"))
	animation.track_insert_key(scale_track_2, 0.0, Vector3.ONE * 0.30)
	animation.track_insert_key(scale_track_2, 0.20, Vector3.ONE * 0.95)
	animation.track_insert_key(scale_track_2, 0.56, Vector3.ONE * 3.5)
	var alpha_track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(alpha_track, NodePath("ShockwaveRing:material_override:albedo_color"))
	animation.track_insert_key(alpha_track, 0.0, Color(color.r, color.g, color.b, 0.95))
	animation.track_insert_key(alpha_track, 0.22, Color(color.r, color.g, color.b, 0.75))
	animation.track_insert_key(alpha_track, 0.56, Color(color.r, color.g, color.b, 0.0))
	var core_progress := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(core_progress, NodePath("ShockwaveCore:material_override:shader_parameter/progress"))
	animation.track_insert_key(core_progress, 0.0, 0.0)
	animation.track_insert_key(core_progress, 0.16, 0.35)
	animation.track_insert_key(core_progress, 0.46, 1.0)
	library.add_animation("play", animation)
	player.add_animation_library("", library)
	player.play("play")
	await get_tree().create_timer(0.68).timeout
	finish()

func _debris_process() -> ParticleProcessMaterial:
	var p := ParticleProcessMaterial.new()
	p.direction = Vector3(0, 1, 0)
	p.spread = 70.0
	p.initial_velocity_min = 1.4
	p.initial_velocity_max = 2.8
	p.gravity = Vector3(0, -5.2, 0)
	p.scale_min = 0.75
	p.scale_max = 1.35
	return p

func _dust_process() -> ParticleProcessMaterial:
	var p := ParticleProcessMaterial.new()
	p.direction = Vector3(0, 0.15, 0)
	p.spread = 180.0
	p.initial_velocity_min = 0.45
	p.initial_velocity_max = 1.1
	p.gravity = Vector3(0, -0.2, 0)
	p.scale_min = 0.8
	p.scale_max = 1.5
	return p
