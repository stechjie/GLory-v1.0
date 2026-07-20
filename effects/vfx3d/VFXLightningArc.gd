extends VFXBlockRoot
class_name VFXLightningArc

const IMPACT := preload("res://effects/vfx3d/VFXTargetImpact.gd")
const BEAM := preload("res://effects/vfx3d/VFXLightningBeam.gd")

func play_arc(origin: Vector3, target: Vector3) -> void:
	begin()
	var delta := origin - target
	var strike_origin := origin
	if delta.length() > 2.95:
		strike_origin = target + delta.normalized() * 2.95
	var guide := _build_arc(strike_origin, target, Color(0.12, 0.40, 0.95), 0.012, 9, 0.12, 1.9)
	guide.name = "LeaderFlash"
	add_child(guide)
	await get_tree().create_timer(0.045).timeout
	guide.visible = false
	await get_tree().create_timer(0.035).timeout
	var outer := _build_arc(strike_origin, target, Color(0.025, 0.20, 0.92), 0.040, 10, 0.15, 1.0)
	outer.name = "MainBoltOuter"
	add_child(outer)
	var middle := _build_arc(strike_origin + Vector3(0.012, 0.0, 0.01), target, Color(0.12, 0.65, 1.0), 0.026, 10, 0.12, 1.0)
	middle.name = "MainBoltMiddle"
	add_child(middle)
	var core := _build_arc(strike_origin + Vector3(-0.008, 0.0, -0.006), target + Vector3(0.0, 0.025, 0.0), Color(0.82, 0.98, 1.0), 0.011, 9, 0.075, 1.0)
	core.name = "MainBoltCore"
	add_child(core)
	_play_target_impact(target)
	await get_tree().create_timer(0.085).timeout
	outer.visible = false
	middle.visible = false
	core.visible = false
	await get_tree().create_timer(0.045).timeout
	core.visible = true
	middle.visible = true
	var branch_a := _build_arc(strike_origin.lerp(target, 0.42), target + Vector3(-0.48, 0.06, 0.12), Color(0.22, 0.74, 1.0), 0.016, 6, 0.095, 1.0)
	branch_a.name = "BranchFlashA"
	add_child(branch_a)
	var branch_b := _build_arc(strike_origin.lerp(target, 0.61), target + Vector3(0.42, 0.05, -0.10), Color(0.48, 0.90, 1.0), 0.013, 5, 0.075, 1.0)
	branch_b.name = "BranchFlashB"
	add_child(branch_b)
	await get_tree().create_timer(0.075).timeout
	core.visible = false
	middle.visible = false
	branch_a.visible = false
	branch_b.visible = false
	_play_ground_residual(target)
	await get_tree().create_timer(0.40).timeout
	finish()

func _play_target_impact(target: Vector3) -> void:
	var flash := IMPACT.make(Color(0.70, 0.97, 1.0), 1.28)
	flash.name = "TargetImpactCore"
	flash.position = target + Vector3(0.0, 0.04, 0.0)
	add_child(flash)
	var sparks := IMPACT.burst(Color(0.76, 0.98, 1.0), 24, 4.4, 0.36)
	sparks.position = target + Vector3(0.0, 0.20, 0.0)
	add_child(sparks)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(flash, "scale", Vector3.ONE * 1.72, 0.34)
	tween.tween_property(flash.material_override, "shader_parameter/progress", 1.0, 0.34)

func _play_ground_residual(target: Vector3) -> void:
	for i in 4:
		var angle := float(i) * TAU / 4.0 + 0.32
		var length := 0.48 + float(i % 2) * 0.22
		var start := target + Vector3(0.0, 0.07, 0.0)
		var end := target + Vector3(cos(angle) * length, 0.065, sin(angle) * length)
		var arc := _build_arc(start, end, Color(0.18, 0.64, 1.0), 0.012, 4, 0.055, 1.0)
		arc.name = "GroundResidual%d" % i
		add_child(arc)

func _build_arc(from_pos: Vector3, to_pos: Vector3, color: Color, width: float, segments: int, jitter: float, width_multiplier: float) -> Node3D:
	var root := Node3D.new()
	var points: Array[Vector3] = [from_pos]
	var direction := to_pos - from_pos
	var normalized := direction.normalized()
	var side_a := normalized.cross(Vector3.FORWARD)
	if side_a.length_squared() < 0.001:
		side_a = Vector3.RIGHT
	else:
		side_a = side_a.normalized()
	var side_b := normalized.cross(side_a).normalized()
	for i in range(1, segments):
		var t := float(i) / float(segments)
		var taper := sin(t * PI)
		var jag_a := sin(float(i) * 8.73 + segments * 0.41) * jitter * taper
		var jag_b := cos(float(i) * 5.91 + segments * 0.27) * jitter * 0.62 * taper
		points.append(from_pos.lerp(to_pos, t) + side_a * jag_a + side_b * jag_b)
	points.append(to_pos)
	for i in range(points.size() - 1):
		var segment_t := float(i) / maxf(float(points.size() - 2), 1.0)
		var tapered_width := width * lerpf(1.0, 0.58, segment_t) * width_multiplier
		root.add_child(BEAM.make_ribbon(points[i], points[i + 1], tapered_width * 14.0, color))
	return root
