extends "res://effects/vfx3d/mercenary_rework/MercenaryVFXBase3D.gd"

func start(_skill_id: String, _origin: Vector3, target: Vector3, context: Dictionary) -> void:
	_duration = 0.62
	var anchor := _target_anchor(context)
	var blade := _sprite("judge_verdict.png", target, 1.55, 1.0, anchor, Vector3.ZERO)
	_fade(blade, 0.52, 0.56, 1.2)
	var seal := _sprite("judge_seal.png", target + Vector3(0.0, 0.13, 0.0), 0.55, 0.9, anchor, Vector3(0.0, 0.13, 0.0))
	_fade(seal, 0.60, 0.45, 0.95)
