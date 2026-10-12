extends "res://effects/vfx3d/mercenary_rework/MercenaryVFXBase3D.gd"

var _marks: Dictionary = {}

func start(_skill_id: String, origin: Vector3, _target: Vector3, context: Dictionary) -> void:
	_duration = 2.25
	var crown := _sprite("king_sun.png", origin + Vector3(0.0, 1.48, 0.0), 1.0, 1.0, _origin_anchor(context), Vector3(0.0, 0.62, 0.0))
	_fade(crown, 0.94, 0.55, 1.22)
	var targets: Array = context.get("targets", [])
	var target_uids: Array = context.get("target_sim_uids", [])
	for index in targets.size():
		var point: Vector3 = targets[index]
		var badge := _sprite("king_ally.png", point + Vector3(0.0, 1.14, 0.0), 0.42, 0.84, _group_anchor(context, index), Vector3(0.0, 1.14, 0.0))
		if badge != null:
			if index < target_uids.size():
				_marks[str(target_uids[index])] = badge
			var tween := create_tween()
			tween.tween_property(badge, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.25).set_delay(1.95)

func tracked_uids() -> Array:
	return _marks.keys()

func sync_statuses(status_by_uid: Dictionary) -> void:
	for uid in _marks:
		var sprite: Variant = _marks[uid]
		if not is_instance_valid(sprite):
			continue
		var info: Dictionary = status_by_uid.get(uid, {})
		var statuses: Dictionary = info.get("statuses", {})
		if not bool(info.get("alive", false)) or not statuses.has("speed_bonus"):
			sprite.set_meta("status_suppressed", true)
			sprite.visible = false
