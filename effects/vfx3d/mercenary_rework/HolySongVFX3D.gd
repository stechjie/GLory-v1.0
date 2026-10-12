extends "res://effects/vfx3d/mercenary_rework/MercenaryVFXBase3D.gd"

func start(skill_id: String, origin: Vector3, target: Vector3, context: Dictionary) -> void:
	if skill_id == "holy_song_cleanse":
		_duration = 0.92
		var blossom := _sprite("holy_cleanse.png", target + Vector3(0.0, 0.85, 0.0), 0.82, 1.0, _target_anchor(context), Vector3(0.0, 0.18, 0.0))
		_fade(blossom, 0.82, 0.4, 1.16)
		return
	_duration = 1.25
	var source := _sprite("holy_hymn.png", origin + Vector3(0.0, 0.86, 0.0), 0.85, 0.92, _origin_anchor(context), Vector3.ZERO)
	_fade(source, 0.92, 0.5, 1.16)
	var targets: Array = context.get("targets", [])
	for index in targets.size():
		var point: Vector3 = targets[index]
		var hymn := _sprite("holy_hymn.png", point + Vector3(0.0, 0.55, 0.0), 0.48, 0.82, _group_anchor(context, index), Vector3(0.0, 0.55, 0.0))
		_fade(hymn, 1.05, 0.45, 1.25)
