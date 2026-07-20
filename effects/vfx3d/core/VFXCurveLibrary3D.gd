extends RefCounted
class_name VFXCurveLibrary3D

static func sample(curve_name: String, t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	match curve_name:
		"explosive_out":
			return 1.0 - pow(1.0 - x, 4.0)
		"fast_attack_slow_decay":
			return sin(minf(x * 3.3, 1.0) * PI * 0.5) * (1.0 - maxf(x - 0.30, 0.0) * 0.42)
		"overshoot", "ease_out_back":
			var c := 1.70158
			var y := x - 1.0
			return 1.0 + (c + 1.0) * y * y * y + c * y * y
		"pulse":
			return sin(x * PI)
		"snap":
			return 0.0 if x < 0.18 else (1.08 if x < 0.42 else 1.0)
		"delayed_fade":
			return 1.0 if x < 0.58 else 1.0 - smoothstep(0.58, 1.0, x)
		_:
			return 1.0 - pow(1.0 - x, 3.0)

static func tween_method(owner: Node, callable: Callable, from_value: float, to_value: float, duration: float, curve_name: String) -> Tween:
	var tween := owner.create_tween()
	tween.tween_method(func(t: float) -> void:
		callable.call(lerpf(from_value, to_value, sample(curve_name, t))), 0.0, 1.0, duration)
	return tween
