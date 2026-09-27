extends VFXBlockRoot
class_name VFXAuthoredUnitProjectile3D

# Uses the same proven camera-facing renderer as the approved player-chess
# projectiles. The source art is one frame; movement, scale, echo and impact are
# animated in code so the result reads as a projectile rather than a rigid icon.
const CURVES := preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")
const FLIPBOOK := preload("res://effects/vfx3d/modules/VFXSpriteFlipbook3D.gd")

# These seven units are non-OGA NPC routes, so their presentation delay is
# governed by BattleVfx._RANGED_MIN/MAX_TRAVEL rather than the OGA constants.
const MIN_TRAVEL_TIME := 0.28
const MAX_TRAVEL_TIME := 0.80
const MAX_AFTERIMAGES := 3

var _texture: Texture2D
var _sprites: Array[VFXSpriteFlipbook3D] = []


func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	set_meta("source_unit_id", str(context.get("source_unit_id", "")))
	play_projectile(
		context.get("origin", Vector3(-1.35, 0.54, 0.0)),
		context.get("target", Vector3(1.35, 0.42, 0.0)),
		profile,
		context.get("target_node")
	)


func play_projectile(origin: Vector3, target: Vector3, profile: VFXProfile3D, target_node: Variant = null) -> void:
	begin()
	var active := profile.duplicate_runtime()
	var texture_path := str(active.parameters.get("texture", ""))
	_texture = vfx_texture(texture_path)
	if _texture == null:
		push_warning("Authored unit projectile texture missing: %s" % texture_path)
		finish()
		return

	var target_ref: WeakRef = null
	if is_instance_valid(target_node) and target_node is Node3D:
		target_ref = weakref(target_node)
	var tracked_target := _tracked_target_position(target, target_ref)
	var facing := _screen_facing(origin, tracked_target)
	position = origin + vfx_toward_camera(0.10)
	_spawn_release(active, facing)

	await get_tree().create_timer(0.045).timeout
	if _finished:
		return

	var travel_distance := origin.distance_to(tracked_target)
	var speed := maxf(0.5, float(active.parameters.get("speed", 6.4)))
	var travel_duration := clampf(travel_distance / speed, MIN_TRAVEL_TIME, MAX_TRAVEL_TIME)
	var body_size := Vector2.ONE * active.size * 1.50
	var body := _make_sprite(
		"ProjectileBody", body_size, Color.WHITE,
		travel_duration + 0.18, facing, clampf(active.emission_energy * 0.46, 0.55, 1.05)
	)
	body.scale = Vector3.ONE * 0.70

	var arc_height := maxf(0.0, float(active.parameters.get("arc_height", 0.12)))
	var trail_interval := clampf(float(active.parameters.get("trail_interval", 0.095)), 0.07, 0.16)
	var motion_style := str(active.parameters.get("motion_style", "steady"))
	var motion_amplitude := clampf(float(active.parameters.get("motion_amplitude", 0.025)), 0.0, 0.12)
	var motion_frequency := clampf(float(active.parameters.get("motion_frequency", 2.0)), 0.5, 5.0)
	var elapsed := 0.0
	var trail_elapsed := trail_interval * 0.55
	var trail_index := 0

	while elapsed < travel_duration:
		await get_tree().process_frame
		if _finished or not is_instance_valid(body):
			return
		var delta := get_process_delta_time()
		elapsed += delta
		trail_elapsed += delta
		tracked_target = _tracked_target_position(tracked_target, target_ref)
		var ratio := clampf(elapsed / travel_duration, 0.0, 1.0)
		var motion := _motion_sample(motion_style, ratio, motion_amplitude, motion_frequency)
		position = origin.lerp(tracked_target, ratio) \
			+ Vector3(0.0, arc_height * sin(ratio * PI) + motion.x, 0.0) \
			+ vfx_toward_camera(0.10)
		facing = _screen_facing(origin, tracked_target) + motion.y
		body.set_uv_rotation(facing)
		var launch_t := clampf(elapsed / 0.09, 0.0, 1.0)
		var launch_scale := lerpf(0.70, 1.0, CURVES.sample("ease_out_back", launch_t))
		var breathe := 1.0 + sin(ratio * TAU * motion_frequency) * 0.025
		body.scale = Vector3(motion.z, motion.w, 1.0) * launch_scale * breathe
		if trail_elapsed >= trail_interval and trail_index < MAX_AFTERIMAGES:
			trail_elapsed = 0.0
			_spawn_afterimage(active, facing, trail_index)
			trail_index += 1

	if is_instance_valid(body):
		body.finish()
	_spawn_impact(active, facing)
	await get_tree().create_timer(0.34).timeout
	if not _finished:
		finish()


func _make_sprite(node_name: String, size: Vector2, tint: Color, duration: float, facing: float, emission_scale: float) -> VFXSpriteFlipbook3D:
	var sprite := FLIPBOOK.new() as VFXSpriteFlipbook3D
	sprite.name = node_name
	add_child(sprite)
	sprite.play_flipbook_advanced(Vector3.ZERO, _texture, {
		"columns": 1,
		"rows": 1,
		"frame_count": 1,
		"loop": false,
		"random_start": false,
		"speed_min": 1.0,
		"speed_max": 1.0,
		"billboard": true,
		"duration": duration,
		"color": tint,
		"size": size,
		"position_offset": Vector3.ZERO,
		"rotation_radians": facing,
		"fade_in": 0.012,
		"fade_out": 0.0,
		"emission_scale": emission_scale,
	})
	_sprites.append(sprite)
	return sprite


# Returns vertical offset, rotation offset, width scale and height scale.
func _motion_sample(style: String, ratio: float, amplitude: float, frequency: float) -> Vector4:
	var phase := ratio * TAU * frequency
	var vertical := 0.0
	var rotation := 0.0
	var scale_x := 1.0
	var scale_y := 1.0
	match style:
		"echo":
			vertical = sin(phase) * amplitude * 0.42
			rotation = sin(phase * 0.52) * amplitude * 0.55
			scale_x += sin(phase) * amplitude * 0.55
		"wobble":
			vertical = sin(phase) * amplitude
			rotation = sin(phase * 0.86) * amplitude * 1.35
			scale_y += cos(phase) * amplitude * 0.65
		"tumble":
			vertical = sin(phase) * amplitude * 0.32
			rotation = sin(phase * 0.72) * amplitude * 1.70
		"resonance":
			vertical = sin(phase) * amplitude * 0.45
			scale_x += cos(phase) * amplitude * 0.45
			scale_y += sin(phase) * amplitude * 1.45
		"flutter":
			vertical = sin(phase) * amplitude * 1.15
			rotation = sin(phase * 0.70) * amplitude * 0.75
			scale_y += sin(phase * 1.35) * amplitude * 2.10
		"heavy":
			vertical = sin(phase) * amplitude * 0.28
			rotation = sin(phase * 0.55) * amplitude * 0.42
		"swing":
			vertical = sin(phase * 0.72) * amplitude * 0.42
			rotation = sin(phase) * amplitude * 1.85
	return Vector4(vertical, rotation, scale_x, scale_y)


func _spawn_afterimage(profile: VFXProfile3D, facing: float, index: int) -> void:
	var tint := profile.core_color
	tint.a = clampf(float(profile.parameters.get("trail_alpha", 0.16)), 0.08, 0.24)
	var ghost := _make_sprite(
		"ProjectileAfterimage_%d" % index,
		Vector2.ONE * profile.size * 1.18,
		tint, 0.18, facing, 0.22
	)
	ghost.top_level = true
	ghost.global_position = global_position - vfx_toward_camera(0.012)
	ghost.scale = Vector3.ONE * (0.82 - float(index) * 0.05)
	var tween := track_tween(create_tween())
	tween.set_parallel(true)
	tween.tween_property(ghost, "scale", Vector3(0.34, 0.22, 1.0), 0.16).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_IN)
	tween.tween_method(ghost.set_vfx_alpha, 1.0, 0.0, 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.set_parallel(false)
	tween.tween_callback(ghost.finish)


func _spawn_release(profile: VFXProfile3D, facing: float) -> void:
	var tint := profile.core_color
	tint.a = 0.34
	var release := _make_sprite(
		"ProjectileRelease", Vector2.ONE * profile.size * 0.78,
		tint, 0.14, facing, 0.42
	)
	release.top_level = true
	release.global_position = global_position
	release.scale = Vector3.ONE * 0.20
	var tween := track_tween(create_tween())
	tween.set_parallel(true)
	tween.tween_property(release, "scale", Vector3.ONE * 0.88, 0.11).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_method(release.set_vfx_alpha, 1.0, 0.0, 0.14).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.set_parallel(false)
	tween.tween_callback(release.finish)


func _spawn_impact(profile: VFXProfile3D, facing: float) -> void:
	var impact_scale := float(profile.parameters.get("impact_scale", 1.45))
	var tint := profile.core_color.lerp(Color.WHITE, 0.28)
	tint.a = 0.70
	var impact := _make_sprite(
		"ProjectileImpact", Vector2.ONE * profile.size * impact_scale,
		tint, 0.24, facing + PI * 0.5, 0.72
	)
	impact.scale = Vector3.ONE * 0.18
	var tween := track_tween(create_tween())
	tween.set_parallel(true)
	tween.tween_property(impact, "scale", Vector3.ONE * 1.04, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_method(impact.set_vfx_alpha, 1.0, 0.0, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.set_parallel(false)
	tween.tween_callback(impact.finish)
	_spawn_impact_shards(profile, facing)


func _spawn_impact_shards(profile: VFXProfile3D, facing: float) -> void:
	var shard_count := clampi(profile.particle_count, 4, 6)
	for index in range(shard_count):
		var angle := facing + (-0.92 + float(index) * 1.84 / maxf(1.0, float(shard_count - 1)))
		var direction := Vector3(cos(angle), sin(angle), 0.0).normalized()
		var shard := _make_shard(profile, index)
		shard.position = vfx_toward_camera(0.02 + float(index) * 0.003)
		shard.rotation.z = angle
		var tween := track_tween(create_tween())
		tween.set_parallel(true)
		tween.tween_property(shard, "position", direction * profile.size * (0.58 + 0.08 * float(index % 2)), 0.24).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		tween.tween_property(shard, "scale", Vector3(0.05, 0.05, 1.0), 0.24).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.tween_property(shard, "transparency", 1.0, 0.24)
		tween.set_parallel(false)
		tween.tween_callback(shard.queue_free)


func _make_shard(profile: VFXProfile3D, index: int) -> MeshInstance3D:
	var length := profile.size * (0.22 + 0.025 * float(index % 3))
	var width := profile.size * (0.035 + 0.008 * float(index % 2))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-length * 0.40, -width, 0.0),
		Vector3(-length * 0.34, width, 0.0),
		Vector3(length * 0.60, 0.0, 0.0),
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := MeshInstance3D.new()
	node.name = "ProjectileImpactShard_%d" % index
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.no_depth_test = true
	material.albedo_color = profile.core_color if index % 3 == 0 else profile.main_color
	material.emission_enabled = true
	material.emission = material.albedo_color
	material.emission_energy_multiplier = minf(profile.emission_energy, 2.6)
	node.material_override = material
	add_child(node)
	return node


func _tracked_target_position(fallback: Vector3, target_ref: WeakRef) -> Vector3:
	if target_ref == null:
		return fallback
	var target_node: Variant = target_ref.get_ref()
	if not is_instance_valid(target_node) or not (target_node is Node3D):
		return fallback
	var tracked := (target_node as Node3D).global_position
	if get_parent() is Node3D:
		tracked = (get_parent() as Node3D).to_local(tracked)
	tracked.y = fallback.y
	return tracked


func _screen_facing(from: Vector3, to: Vector3) -> float:
	var delta := to - from
	var screen_y := delta.y * 0.688 - delta.z * 0.726
	if absf(delta.x) < 0.0001 and absf(screen_y) < 0.0001:
		return PI * 0.5
	return atan2(screen_y, delta.x)


func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	for sprite in _sprites:
		if is_instance_valid(sprite):
			sprite.set_vfx_alpha(vfx_alpha)
