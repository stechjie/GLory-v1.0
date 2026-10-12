extends "res://effects/vfx3d/mercenary_rework/MercenaryVFXBase3D.gd"

var _mark: Sprite3D
var _mark_uid := ""

func start(skill_id: String, origin: Vector3, target: Vector3, context: Dictionary) -> void:
	if skill_id == "death_hunt_kill":
		_duration = 0.8
		var soul := _sprite("death_return.png", target + Vector3(0.0, 0.7, 0.0), 0.56, 1.0)
		if soul != null:
			var tween := create_tween().set_parallel(true)
			tween.tween_property(soul, "global_position", origin + Vector3(0.0, 0.7, 0.0), 0.72)
			tween.tween_property(soul, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.72)
		return
	_duration = maxf(0.5, float(context.get("status_duration", 4.0)))
	var anchor := _target_anchor(context)
	var slash := _sprite("death_cut.png", target, 1.12, 0.98, anchor, Vector3.ZERO)
	_fade(slash, 0.6, 0.55, 1.2)
	var mark := _sprite("death_brand.png", target + Vector3(0.0, 0.16, 0.0), 0.42, 0.88, anchor, Vector3(0.0, 0.16, 0.0))
	if mark != null:
		_mark = mark
		_mark_uid = str(context.get("target_sim_uid", ""))
		var tween := create_tween()
		tween.tween_property(mark, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.3).set_delay(_duration - 0.3)

func tracked_uids() -> Array:
	return [_mark_uid] if not _mark_uid.is_empty() else []

func sync_statuses(status_by_uid: Dictionary) -> void:
	if _mark_uid.is_empty() or not is_instance_valid(_mark):
		return
	var info: Dictionary = status_by_uid.get(_mark_uid, {})
	var statuses: Dictionary = info.get("statuses", {})
	if not bool(info.get("alive", false)) or not (statuses.has("defense_flat_down") or statuses.has("heal_reduction")):
		_mark.set_meta("status_suppressed", true)
		_mark.visible = false
