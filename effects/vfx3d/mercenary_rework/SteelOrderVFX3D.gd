extends "res://effects/vfx3d/mercenary_rework/MercenaryVFXBase3D.gd"

var _marks: Dictionary = {}

func start(_skill_id: String, origin: Vector3, _target: Vector3, context: Dictionary) -> void:
	_duration = 8.1
	var flag := _sprite("steel_standard.png", origin + Vector3(0.0, 1.36, 0.0), 0.96, 0.95, _origin_anchor(context), Vector3(0.0, 0.5, 0.0))
	_fade(flag, 0.95, 0.52, 1.13)
	var targets: Array = context.get("targets", [])
	var target_uids: Array = context.get("target_sim_uids", [])
	for index in targets.size():
		var point: Vector3 = targets[index]
		var plate := _sprite("steel_plate.png", point + Vector3(0.0, 0.67, 0.0), 0.44, 0.85, _group_anchor(context, index), Vector3(0.0, 0.67, 0.0))
		if plate != null:
			if index < target_uids.size():
				_marks[str(target_uids[index])] = plate
			var tween := create_tween()
			tween.tween_property(plate, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.4).set_delay(7.6)

func tracked_uids() -> Array:
	return _marks.keys()

func sync_statuses(status_by_uid: Dictionary) -> void:
	for uid in _marks:
		var sprite: Variant = _marks[uid]
		if not is_instance_valid(sprite):
			continue
		var info: Dictionary = status_by_uid.get(uid, {})
		var statuses: Dictionary = info.get("statuses", {})
		if not bool(info.get("alive", false)) or not (statuses.has("damage_reduction") or statuses.has("speed_bonus") or statuses.has("control_time_reduction")):
			sprite.set_meta("status_suppressed", true)
			sprite.visible = false
