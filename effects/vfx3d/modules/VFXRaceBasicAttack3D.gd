extends VFXBlockRoot
class_name VFXRaceBasicAttack3D

const SLASH_ARC := preload("res://effects/vfx3d/modules/VFXSlashArc3D.gd")
const IMPACT_FLASH := preload("res://effects/vfx3d/modules/VFXImpactFlash3D.gd")

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	var mode := str(context.get("mode", "ranged"))
	var race := str(context.get("race", profile.parameters.get("race", "human")))
	var origin: Vector3 = context.get("origin", Vector3(-0.7, 0.72, 0.0))
	var target: Vector3 = context.get("target", Vector3(0.8, 0.48, 0.0))
	if mode == "melee":
		_play_melee(origin, target, race, profile)
	else:
		_play_ranged(origin, target, race, profile, context.get("target_node"))

func _play_ranged(origin: Vector3, target: Vector3, race: String, profile: VFXProfile3D, target_node: Variant) -> void:
	begin()
	var active := _runtime_profile(profile, race, true)
	var target_ref: WeakRef = null
	if target_node is Node3D and is_instance_valid(target_node):
		target_ref = weakref(target_node)
	var tracked_target := _tracked_target_position(target, target_ref)
	var direction := _safe_direction(origin, tracked_target)
	_spawn_shards(origin, direction, active, race, false)
	var needle := _make_projectile_needle(active, race)
	needle.position = origin + Vector3(0.0, 0.0, 0.10)
	needle.rotation.z = atan2(direction.y, direction.x)
	add_child(needle)
	var travel_duration := active.duration * 0.54
	var travel_elapsed := 0.0
	var trail_elapsed := 0.0
	var trail_index := 0
	while travel_elapsed < travel_duration:
		await get_tree().process_frame
		if _finished:
			return
		var delta := get_process_delta_time()
		travel_elapsed += delta
		trail_elapsed += delta
		tracked_target = _tracked_target_position(tracked_target, target_ref)
		direction = _safe_direction(origin, tracked_target)
		var ratio := clampf(travel_elapsed / travel_duration, 0.0, 1.0)
		var attack_curve := 1.0 - pow(1.0 - ratio, 2.35)
		needle.position = origin.lerp(tracked_target, attack_curve) + Vector3(0.0, 0.0, 0.10)
		needle.rotation.z = atan2(direction.y, direction.x)
		if trail_elapsed >= 0.045:
			trail_elapsed = 0.0
			_spawn_needle_trail(needle.position, direction, active, race, trail_index)
			trail_index += 1
	needle.queue_free()
	_spawn_linear_hit(tracked_target + Vector3(0.0, 0.04, 0.04), direction, active, race)
	await get_tree().create_timer(active.duration * 0.34).timeout
	finish()

func _play_melee(origin: Vector3, target: Vector3, race: String, profile: VFXProfile3D) -> void:
	begin()
	var active := _runtime_profile(profile, race, false)
	var direction := (target - origin).normalized()
	if direction.length_squared() < 0.001:
		direction = Vector3.RIGHT
	var slash := SLASH_ARC.new()
	slash.name = "RaceSlash_%s" % race
	add_child(slash)
	slash.play_slash(target + Vector3(0.0, 0.22, 0.02), direction, active)
	await get_tree().create_timer(active.duration * 0.16).timeout
	if _finished:
		return
	_spawn_shards(target + Vector3(0.0, 0.24, 0.04), direction, active, race, true)
	var flash := IMPACT_FLASH.new()
	flash.name = "RaceMeleeImpact_%s" % race
	add_child(flash)
	flash.play_flash(target, active.core_color, active.size * 0.72, active.duration * 0.24)
	await get_tree().create_timer(active.duration * 0.82).timeout
	finish()

func _tracked_target_position(fallback: Vector3, target_ref: WeakRef) -> Vector3:
	if target_ref == null:
		return fallback
	var target_node: Variant = target_ref.get_ref()
	if not (target_node is Node3D) or not is_instance_valid(target_node):
		return fallback
	var tracked := to_local((target_node as Node3D).global_position)
	tracked.y = fallback.y
	return tracked

func _safe_direction(origin: Vector3, target: Vector3) -> Vector3:
	var direction := target - origin
	if direction.length_squared() < 0.0001:
		return Vector3.RIGHT
	return direction.normalized()

func _make_projectile_needle(profile: VFXProfile3D, race: String) -> Node3D:
	var root := Node3D.new()
	root.name = "StraightRaceBolt_%s" % race
	var length := profile.size * (0.92 if race == "human" else 1.02)
	var layers := [
		{"name": "DarkEdge", "length": length * 1.10, "width": profile.size * 0.075, "color": profile.dark_color.lerp(profile.main_color, 0.18), "energy": profile.emission_energy * 0.52, "z": 0.000},
		{"name": "ColorBody", "length": length, "width": profile.size * 0.052, "color": profile.main_color, "energy": profile.emission_energy * 0.82, "z": 0.008},
		{"name": "HotCore", "length": length * 0.84, "width": profile.size * 0.020, "color": profile.core_color, "energy": profile.emission_energy, "z": 0.016},
	]
	for layer: Dictionary in layers:
		var lance := _lance_mesh(float(layer["length"]), float(layer["width"]), layer["color"], float(layer["energy"]))
		lance.name = str(layer["name"])
		lance.position.z = float(layer["z"])
		root.add_child(lance)
	return root

func _spawn_needle_trail(at: Vector3, direction: Vector3, profile: VFXProfile3D, race: String, index: int) -> void:
	var length := profile.size * (0.54 + 0.06 * float(index % 2))
	var body := _lance_mesh(length, profile.size * 0.040, profile.main_color, profile.emission_energy * 0.58)
	body.name = "StraightTrail_%s_%d" % [race, index]
	body.position = at - direction * profile.size * 0.28 + Vector3(0.0, 0.0, 0.006)
	body.rotation.z = atan2(direction.y, direction.x)
	body.scale = Vector3(0.84, 0.72, 1.0)
	body.transparency = 0.18
	add_child(body)
	var tween := track_tween(create_tween())
	tween.set_parallel(true)
	tween.tween_property(body, "position", body.position - direction * profile.size * 0.18, profile.duration * 0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(body, "scale", Vector3(0.34, 0.10, 1.0), profile.duration * 0.20).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_IN)
	tween.tween_property(body, "transparency", 1.0, profile.duration * 0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.set_parallel(false)
	tween.tween_callback(body.queue_free)

func _spawn_linear_hit(at: Vector3, direction: Vector3, profile: VFXProfile3D, race: String) -> void:
	var angles := [-0.42, -0.18, 0.0, 0.18, 0.42]
	for i in range(angles.size()):
		var out := direction.rotated(Vector3.FORWARD, float(angles[i])).normalized()
		var color := profile.core_color if i == 2 else profile.main_color
		var streak := _lance_mesh(profile.size * (0.42 + 0.08 * float(i % 2)), profile.size * (0.024 if i == 2 else 0.036), color, profile.emission_energy)
		streak.name = "LinearHit_%s_%d" % [race, i]
		streak.position = at + Vector3(0.0, 0.0, 0.02 + float(i) * 0.002)
		streak.rotation.z = atan2(out.y, out.x)
		streak.scale = Vector3(0.30, 0.44, 1.0)
		add_child(streak)
		var tween := track_tween(create_tween())
		tween.set_parallel(true)
		tween.tween_property(streak, "position", streak.position + out * profile.size * (0.32 + 0.05 * float(i % 3)), profile.duration * 0.18).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		tween.tween_property(streak, "scale", Vector3(1.0, 0.08, 1.0), profile.duration * 0.18).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		tween.tween_property(streak, "transparency", 1.0, profile.duration * 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.set_parallel(false)
		tween.tween_callback(streak.queue_free)

func _lance_mesh(length: float, width: float, color: Color, energy: float) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-length * 0.56, 0.0, 0.0),
		Vector3(-length * 0.43, -width, 0.0),
		Vector3(length * 0.56, 0.0, 0.0),
		Vector3(-length * 0.43, width, 0.0),
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = true
	material.render_priority = 3
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = minf(energy, 4.2)
	node.material_override = material
	return node

func _runtime_profile(source: VFXProfile3D, race: String, ranged: bool) -> VFXProfile3D:
	var p := source.duplicate_runtime()
	p.parameters = p.parameters.duplicate()
	p.parameters["race"] = race
	match race:
		"god":
			p.parameters["radius"] = 0.62 if ranged else 0.78
			p.parameters["arc_degrees"] = 112.0
			p.parameters["tilt_degrees"] = 24.0
			p.parameters["width"] = 0.18
		"dark":
			p.parameters["radius"] = 0.78 if ranged else 0.94
			p.parameters["arc_degrees"] = 148.0
			p.parameters["tilt_degrees"] = -14.0
			p.parameters["width"] = 0.25
		"undead":
			p.parameters["radius"] = 0.70 if ranged else 0.86
			p.parameters["arc_degrees"] = 126.0
			p.parameters["tilt_degrees"] = 8.0
			p.parameters["width"] = 0.23
		_:
			p.parameters["radius"] = 0.58 if ranged else 0.74
			p.parameters["arc_degrees"] = 94.0
			p.parameters["tilt_degrees"] = 18.0
			p.parameters["width"] = 0.16
	return p

func _spawn_shards(at: Vector3, direction: Vector3, profile: VFXProfile3D, race: String, impact: bool) -> void:
	var count := 7 if impact else 4
	var fan := _fan_width(race)
	for i in range(count):
		var t := 0.5 if count <= 1 else float(i) / float(count - 1)
		var angle := lerpf(-fan, fan, t)
		var out := direction.rotated(Vector3.FORWARD, angle).normalized()
		if impact:
			out = -out
		var length := profile.size * (0.24 + 0.09 * float(i % 3))
		var shard := _triangle_shard(length, profile.size * (0.026 + 0.009 * float(i % 2)), profile.core_color if i % 3 == 0 else profile.main_color, profile.emission_energy)
		shard.position = at
		shard.rotation.z = atan2(out.y, out.x)
		shard.scale = Vector3.ONE * 0.22
		add_child(shard)
		var travel := profile.size * (0.34 + 0.10 * float((i + 1) % 3))
		var duration := profile.duration * (0.16 + 0.025 * float(i % 2))
		var tween := track_tween(create_tween())
		tween.set_parallel(true)
		tween.tween_property(shard, "position", at + out * travel, duration).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		tween.tween_property(shard, "scale", Vector3(0.04, 0.04, 1.0), duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.set_parallel(false)
		tween.tween_callback(shard.queue_free)

func _triangle_shard(length: float, width: float, color: Color, energy: float) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-length * 0.45, -width, 0.0), Vector3(length * 0.55, 0.0, 0.0), Vector3(-length * 0.45, width, 0.0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = minf(energy, 4.2)
	node.material_override = material
	return node

func _fan_width(race: String) -> float:
	match race:
		"god": return 0.72
		"dark": return 1.18
		"undead": return 0.96
		_: return 0.52

func _impact_scale(race: String) -> float:
	match race:
		"dark": return 1.30
		"undead": return 1.18
		"god": return 1.08
		_: return 0.92
