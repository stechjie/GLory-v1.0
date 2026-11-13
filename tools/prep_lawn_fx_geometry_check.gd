extends SceneTree

const Harness := preload("res://tools/CheckHarness.gd")
const Lawn := preload("res://scenes/prep/PrepLawnFx.gd")
const LOCAL_TOLERANCE := 0.0001
const SCREEN_TOLERANCE := 0.001
const BENCHMARK_WINGS := 3000
var _checksum := 0.0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var h := Harness.new("prep_lawn_fx_geometry")
	var lawn := Lawn.new()
	lawn._ensure_wing_geometry()
	h.expect(lawn._fore_wing.raw.size() == 7 and lawn._fore_wing.smooth.size() == 21
		and lawn._fore_wing.core.size() == 21 and lawn._fore_wing.ring.size() == 22,
		"fore_point_counts", "forewing must retain all original raw, smooth, core and closed-edge vertices")
	h.expect(lawn._hind_wing.raw.size() == 8 and lawn._hind_wing.smooth.size() == 24
		and lawn._hind_wing.core.size() == 24 and lawn._hind_wing.ring.size() == 25,
		"hind_point_counts", "hindwing must retain all original raw, smooth, core and closed-edge vertices")
	h.expect(Lawn.BUTTERFLY_COUNT == 5 and Lawn.MOTE_COUNT == 12 and Lawn.TRAIL_SECONDS == 1.1 and Lawn.TRAIL_STEP == 0.035,
		"population_timing", "butterflies, motes and trail timing must remain unchanged")
	var geometry := _check_equivalence(h, lawn)
	var benchmark := _benchmark(lawn)
	var report := {"geometry": geometry, "benchmark": benchmark,
		"passed": h.failure_count() == 0, "checked": h.checked_count(),
		"limits": ["Geometry-only local desktop microbenchmark; excludes Canvas calls, GPU/driver work and rendering.",
			"Affine-equivalent float32 operations have different rounding after a large screen-space translation.",
			"Local wing coordinates must differ by <=1e-4px; translated screen coordinates by <=0.001px.",
			"This does not establish iPhone FPS or heating improvement."]}
	var output := "user://prep_lawn_fx_geometry_check.json"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--report="):
			output = arg.trim_prefix("--report=")
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print("LAWN_GEOMETRY %s" % JSON.stringify(geometry))
	print("LAWN_BENCHMARK %s" % JSON.stringify(benchmark))
	lawn.free()
	h.finish(self)

func _check_equivalence(h: RefCounted, lawn: Control) -> Dictionary:
	var local_error := 0.0
	var screen_error := 0.0
	var screen_ulp := 0
	var cases := 0
	var compared_vertices := 0
	var branch_mismatches := 0
	var worst := {}
	var poses: Array[Dictionary] = []
	for yaw in [0.0, 0.3, 0.9, 1.57, 2.4, 3.14, 4.3, 5.9]:
		poses.append({"axis": Vector3(cos(yaw), 0.0, sin(yaw))})
	poses.append({"axis": Vector3(0.8, 0.2, -0.4).normalized()})
	var snapshot := var_to_bytes([lawn._fore_wing, lawn._hind_wing])
	for origin in [Vector2.ZERO, Vector2(100, 80), Vector2(350, 250), Vector2(1000, 600), Vector2(1600, 900), Vector2(2400, 1400)]:
		for pose in poses:
			var axis: Vector3 = pose.axis
			var side := Vector3.UP.cross(axis).normalized()
			for flap in [-0.25, 0.0, 0.4, 0.9, 1.25, 1.35, 1.4]:
				for sign_value in [-1.0, 1.0]:
					var wing_dir: Vector3 = side * sign_value * cos(flap) + Vector3.UP * sin(flap)
					for scale in [7.5, 10.0, 12.5, 16.0]:
						for pair in [[Lawn.FORE_WING, lawn._fore_wing], [Lawn.HIND_WING, lawn._hind_wing]]:
							var old := _reference_geometry(pair[0], origin, axis, wing_dir, scale)
							var current := _cached_geometry(lawn, pair[1], origin, axis, wing_dir, scale)
							cases += 1
							if (absf(_signed_area(old.raw)) < 6.0) != (absf(_signed_area(current.raw)) < 6.0):
								branch_mismatches += 1
							for part in ["raw", "smooth", "core", "ring"]:
								var before: PackedVector2Array = old[part]
								var after: PackedVector2Array = current[part]
								for i in before.size():
									compared_vertices += 1
									var error := before[i].distance_to(after[i])
									if origin == Vector2.ZERO:
										local_error = maxf(local_error, error)
									else:
										screen_ulp = maxi(screen_ulp, maxi(_float_ulp_distance(before[i].x, after[i].x), _float_ulp_distance(before[i].y, after[i].y)))
										if error > screen_error:
											screen_error = error
											worst = {"origin": str(origin), "axis": str(axis), "flap": flap, "side": sign_value,
												"size": scale, "part": part, "vertex": i, "before": str(before[i]), "after": str(after[i])}
	# Alpha affects draw colors only; exercising its original coefficients also
	# confirms no geometry cache entry changes when a differently faded wing draws.
	for alpha in [0.0, 0.15, 0.5, 0.88, 1.0]:
		var gold := Color(Lawn.WING_GOLD, 0.95 * alpha)
		var core_color := Color(Lawn.WING_LIGHT, 0.7 * alpha)
		h.expect(is_equal_approx(gold.a, 0.95 * alpha) and is_equal_approx(core_color.a, 0.7 * alpha),
			"alpha_coefficients", "original opacity coefficients must remain unchanged")
	h.expect(local_error <= LOCAL_TOLERANCE, "local_affine_error", "local-space vertex error %.9f exceeds %.9f" % [local_error, LOCAL_TOLERANCE])
	h.expect(screen_error <= SCREEN_TOLERANCE, "screen_affine_error", "screen-space vertex error %.9f exceeds %.9f" % [screen_error, SCREEN_TOLERANCE])
	h.expect(branch_mismatches == 0, "edge_on_branch", "tested poses must retain the original edge-on line/polygon decision")
	h.expect(var_to_bytes([lawn._fore_wing, lawn._hind_wing]) == snapshot, "cache_mutated", "projecting a wing must never mutate canonical geometry")
	return {"cases": cases, "compared_vertices": compared_vertices,
		"local_max_error_px": local_error, "screen_max_error_px": screen_error,
		"screen_max_component_ulp": screen_ulp, "screen_worst_case": worst,
		"edge_on_branch_mismatches": branch_mismatches, "local_tolerance_px": LOCAL_TOLERANCE,
		"screen_tolerance_px": SCREEN_TOLERANCE}

func _cached_geometry(lawn: Control, cached: Dictionary, origin: Vector2, axis: Vector3, direction: Vector3, scale: float) -> Dictionary:
	var projection: Transform2D = lawn._wing_projection(origin, axis, direction, scale)
	return {"raw": projection * cached.raw, "smooth": projection * cached.smooth,
		"core": projection * cached.core, "ring": projection * cached.ring}

# Frozen pre-optimization geometry path: project first, then smooth, average and
# make the two lerps in screen coordinates. It intentionally retains old rounding.
func _reference_geometry(shape: Array, origin: Vector2, axis: Vector3, direction: Vector3, scale: float) -> Dictionary:
	var raw := PackedVector2Array()
	for vertex in shape:
		var p: Vector3 = direction * float(vertex.x) + axis * float(vertex.y)
		raw.append(origin + Vector2(p.x, -p.y * 0.92 + p.z * 0.38) * scale)
	var points := _reference_smooth(raw)
	var center := Vector2.ZERO
	for point in points:
		center += point
	center /= points.size()
	var core := PackedVector2Array()
	for point in points:
		core.append(center.lerp(point, 0.55).lerp(origin, 0.15))
	var ring := points.duplicate()
	ring.append(points[0])
	return {"raw": raw, "smooth": points, "core": core, "ring": ring}

func _reference_smooth(raw: PackedVector2Array) -> PackedVector2Array:
	var points := PackedVector2Array()
	var n := raw.size()
	for i in n:
		var p0 := raw[(i - 1 + n) % n]
		var p1 := raw[i]
		var p2 := raw[(i + 1) % n]
		var p3 := raw[(i + 2) % n]
		for k in 3:
			var t := float(k) / 3.0
			var t2 := t * t
			var t3 := t2 * t
			points.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))
	return points

func _signed_area(raw: PackedVector2Array) -> float:
	var area := 0.0
	for i in raw.size():
		var a := raw[i]
		var b := raw[(i + 1) % raw.size()]
		area += a.x * b.y - b.x * a.y
	return area

func _float_ulp_distance(a: float, b: float) -> int:
	var bits := PackedFloat32Array([a, b]).to_byte_array()
	var first := int(bits.decode_u32(0))
	var second := int(bits.decode_u32(4))
	first = 0x80000000 - (first & 0x7fffffff) if first & 0x80000000 else 0x80000000 + first
	second = 0x80000000 - (second & 0x7fffffff) if second & 0x80000000 else 0x80000000 + second
	return absi(first - second)

func _benchmark(lawn: Control) -> Dictionary:
	var old_us: Array[int] = []
	var cached_us: Array[int] = []
	var poses: Array[Dictionary] = []
	for i in 32:
		var axis := Vector3(cos(i * 0.19), 0.0, sin(i * 0.19))
		poses.append({"axis": axis, "direction": Vector3.UP.cross(axis) * cos(0.2 + i * 0.025) + Vector3.UP * sin(0.2 + i * 0.025)})
	_benchmark_batch(lawn, poses, false, 200)
	_benchmark_batch(lawn, poses, true, 200)
	for round_index in 7:
		# Alternate order so a consistently warm second batch does not get all the credit.
		if round_index % 2 == 0:
			old_us.append(_benchmark_batch(lawn, poses, false, BENCHMARK_WINGS))
			cached_us.append(_benchmark_batch(lawn, poses, true, BENCHMARK_WINGS))
		else:
			cached_us.append(_benchmark_batch(lawn, poses, true, BENCHMARK_WINGS))
			old_us.append(_benchmark_batch(lawn, poses, false, BENCHMARK_WINGS))
	var sorted_old := old_us.duplicate()
	var sorted_cached := cached_us.duplicate()
	sorted_old.sort()
	sorted_cached.sort()
	return {"wings_per_round": BENCHMARK_WINGS, "rounds": 7,
		"reference_us": old_us, "cached_us": cached_us,
		"reference_median_us_per_wing": float(sorted_old[3]) / BENCHMARK_WINGS,
		"cached_median_us_per_wing": float(sorted_cached[3]) / BENCHMARK_WINGS,
		"geometry_speedup": float(sorted_old[3]) / maxf(1.0, sorted_cached[3]),
		"checksum": _checksum, "engine_version": Engine.get_version_info().get("string", "unknown"),
		"scope": "full-polygon geometry generation only; both paths materialize raw/smooth/core/ring; excludes edge-on early return, Canvas/driver work and phone performance"}

func _benchmark_batch(lawn: Control, poses: Array[Dictionary], cached: bool, iterations: int) -> int:
	var started := Time.get_ticks_usec()
	for i in iterations:
		var pose: Dictionary = poses[i % poses.size()]
		var geometry: Dictionary
		if cached:
			geometry = _cached_geometry(lawn, lawn._fore_wing if i % 2 == 0 else lawn._hind_wing,
				Vector2(250, 150), pose.axis, pose.direction, 12.0)
		else:
			geometry = _reference_geometry(Lawn.FORE_WING if i % 2 == 0 else Lawn.HIND_WING,
				Vector2(250, 150), pose.axis, pose.direction, 12.0)
		_checksum += Vector2(geometry.core[2]).x
	return Time.get_ticks_usec() - started
