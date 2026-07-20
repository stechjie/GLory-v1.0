extends Node3D
class_name BossProceduralVFX3D

const VFXLightningArc := preload("res://effects/vfx3d/VFXLightningArc.gd")
const VFXLightningBall := preload("res://effects/vfx3d/VFXLightningBall.gd")

const IMPACT_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 core_color : source_color = vec4(0.3, 0.75, 1.0, 1.0);
uniform float progress = 0.0;
void fragment() {
    vec2 p = UV - vec2(0.5);
    float r = length(p) * 2.0;
    float ring = smoothstep(0.16, 0.02, abs(r - progress));
    float core = smoothstep(0.30, 0.0, r) * (1.0 - progress * 0.55);
    float rays = pow(max(0.0, cos(atan(p.y, p.x) * 8.0)), 12.0) * smoothstep(0.95, 0.15, r);
    ALBEDO = core_color.rgb;
    EMISSION = core_color.rgb * (2.5 + rays * 2.0);
    ALPHA = clamp(max(ring, core * 0.9) + rays * 0.35, 0.0, 1.0) * (1.0 - progress);
}
"""

var _impact_mesh: QuadMesh

func play(skill_id: String, origin: Vector3, target: Vector3) -> void:

	match skill_id:
		"lightning_strike":
			_play_lightning(origin, target)
		"lightning_ball":
			_play_lightning_ball(origin, target)
		"meteor_strike":
			_play_meteor(origin, target)

func _play_lightning(origin: Vector3, target: Vector3) -> void:
	# The old implementation created a nearly vertical blue cylinder from the
	# target, which read as a rigid line. The reusable arc block now owns the
	# attack path, target impact and AnimationPlayer timing.
	var fx := VFXLightningArc.new()
	fx.name = "LightningArc"
	add_child(fx)
	fx.play_arc(target + Vector3(0.0, 2.85, 0.0), target)

func _play_lightning_ball(origin: Vector3, target: Vector3) -> void:
	var fx := VFXLightningBall.new()
	fx.name = "LightningBall"
	add_child(fx)
	fx.play_ball(origin, target)

func _play_meteor(origin: Vector3, target: Vector3) -> void:
	var fx := Node3D.new()
	fx.name = "MeteorStrike"
	add_child(fx)
	var warning := _impact_quad(Color(0.95, 0.22, 0.08), 1.7)
	warning.name = "Warning"
	warning.position = target + Vector3(0.0, 0.025, 0.0)
	fx.add_child(warning)
	var rock := MeshInstance3D.new()
	rock.name = "Meteor"
	var sphere := SphereMesh.new()
	sphere.radius = 0.22
	sphere.height = 0.44
	sphere.radial_segments = 8
	sphere.rings = 4
	rock.mesh = sphere
	rock.material_override = _glow_material(Color(1.0, 0.20, 0.04), 2.8)
	rock.position = origin + Vector3(0.0, 4.0, 0.0)
	fx.add_child(rock)
	var trail := _burst_particles(Color(1.0, 0.36, 0.06), 30, 3.2, 0.42)
	trail.position = rock.position
	fx.add_child(trail)
	var impact := _impact_quad(Color(1.0, 0.24, 0.05), 1.8)
	impact.name = "Impact"
	impact.position = target + Vector3(0.0, 0.035, 0.0)
	impact.scale = Vector3.ZERO
	fx.add_child(impact)
	var debris := _burst_particles(Color(1.0, 0.55, 0.10), 34, 3.8, 0.45)
	debris.position = target + Vector3(0.0, 0.12, 0.0)
	debris.emitting = false
	fx.add_child(debris)
	_play_meteor_animation(fx, rock, trail, warning, impact, debris)

func _beam(from_pos: Vector3, to_pos: Vector3, color: Color, width: float) -> MeshInstance3D:
	var beam := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = width
	cyl.bottom_radius = width * 1.35
	cyl.height = from_pos.distance_to(to_pos)
	cyl.radial_segments = 6
	beam.mesh = cyl
	beam.material_override = _glow_material(color, 4.0)
	beam.position = (from_pos + to_pos) * 0.5
	var direction := (to_pos - from_pos).normalized()
	beam.quaternion = Quaternion(Vector3.UP, direction)
	return beam

func _lightning_chain(from_pos: Vector3, to_pos: Vector3, color: Color, width: float, segment_count: int) -> Node3D:
	var chain := Node3D.new()
	var points: Array[Vector3] = [from_pos]
	var direction := to_pos - from_pos
	var side := Vector3(1.0, 0.0, 0.0)
	if absf(direction.normalized().dot(side)) > 0.88:
		side = Vector3(0.0, 0.0, 1.0)
	for i in range(1, segment_count):
		var t := float(i) / float(segment_count)
		var jitter := side * (sin(float(i) * 17.0) * 0.11)
		points.append(from_pos.lerp(to_pos, t) + jitter)
	points.append(to_pos)
	for i in range(points.size() - 1):
		chain.add_child(_beam(points[i], points[i + 1], color, width))
	return chain

func _impact_quad(color: Color, size: float) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	node.mesh = quad
	var mat := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = IMPACT_SHADER
	mat.shader = shader
	mat.set_shader_parameter("core_color", color)
	mat.set_shader_parameter("progress", 0.0)
	node.material_override = mat
	node.rotation_degrees.x = -90.0
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

func _glow_material(color: Color, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(color.r, color.g, color.b, 0.95)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	mat.no_depth_test = true
	return mat

func _burst_particles(color: Color, amount: int, speed: float, lifetime: float) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = amount
	particles.lifetime = lifetime
	particles.one_shot = true
	particles.explosiveness = 0.92
	particles.emitting = true
	var process := ParticleProcessMaterial.new()
	process.direction = Vector3(0.0, 1.0, 0.0)
	process.spread = 58.0
	process.initial_velocity_min = speed * 0.45
	process.initial_velocity_max = speed
	process.gravity = Vector3(0.0, -4.5, 0.0)
	process.scale_min = 0.035
	process.scale_max = 0.10
	particles.process_material = process
	var draw := QuadMesh.new()
	draw.size = Vector2(0.09, 0.09)
	draw.material = _glow_material(color, 3.2)
	particles.draw_pass_1 = draw
	return particles

func _play_animation(fx: Node3D, duration: float, impact: MeshInstance3D, keep_particles: bool) -> void:
	var player := AnimationPlayer.new()
	fx.add_child(player)
	var lib := AnimationLibrary.new()
	var anim := Animation.new()
	anim.length = duration
	var track := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(track, NodePath("../Impact:material_override:shader_parameter/progress"))
	anim.track_insert_key(track, 0.0, 0.0)
	anim.track_insert_key(track, duration * 0.28, 0.5)
	anim.track_insert_key(track, duration, 1.0)
	lib.add_animation("play", anim)
	player.add_animation_library("", lib)
	player.play("play")
	await get_tree().create_timer(duration + 0.15).timeout
	if is_instance_valid(fx):
		fx.queue_free()

func _play_meteor_animation(fx: Node3D, rock: MeshInstance3D, trail: GPUParticles3D, warning: MeshInstance3D, impact: MeshInstance3D, debris: GPUParticles3D) -> void:
	var player := AnimationPlayer.new()
	fx.add_child(player)
	var lib := AnimationLibrary.new()
	var anim := Animation.new()
	anim.length = 1.65
	var move := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(move, NodePath("../Meteor:position"))
	var start := rock.position
	var end := Vector3(rock.position.x, 0.26, rock.position.z)
	anim.track_insert_key(move, 0.38, start)
	anim.track_insert_key(move, 1.18, end)
	var warn := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(warn, NodePath("../Warning:material_override:shader_parameter/progress"))
	anim.track_insert_key(warn, 0.0, 0.0)
	anim.track_insert_key(warn, 0.35, 0.35)
	anim.track_insert_key(warn, 1.18, 1.0)
	var burst := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(burst, NodePath("../Impact:material_override:shader_parameter/progress"))
	anim.track_insert_key(burst, 1.18, 0.0)
	anim.track_insert_key(burst, 1.40, 0.45)
	anim.track_insert_key(burst, 1.65, 1.0)
	lib.add_animation("play", anim)
	player.add_animation_library("", lib)
	player.play("play")
	await get_tree().create_timer(1.18).timeout
	if is_instance_valid(debris):
		debris.restart()
	await get_tree().create_timer(0.65).timeout
	if is_instance_valid(fx):
		fx.queue_free()
