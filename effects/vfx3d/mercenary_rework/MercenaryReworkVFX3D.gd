extends Node3D

const JUDGE := preload("res://effects/vfx3d/mercenary_rework/JudgeVFX3D.gd")
const CHARGE := preload("res://effects/vfx3d/mercenary_rework/GoldChargeVFX3D.gd")
const HOLY := preload("res://effects/vfx3d/mercenary_rework/HolySongVFX3D.gd")
const KING := preload("res://effects/vfx3d/mercenary_rework/KingAuraVFX3D.gd")
const BLOOD := preload("res://effects/vfx3d/mercenary_rework/BloodRampageVFX3D.gd")
const STEEL := preload("res://effects/vfx3d/mercenary_rework/SteelOrderVFX3D.gd")
const DEATH := preload("res://effects/vfx3d/mercenary_rework/DeathHuntVFX3D.gd")

const SKILLS := ["balance_judge", "gold_charge", "holy_song", "holy_song_cleanse", "king_aura", "blood_rampage", "steel_order", "death_hunt", "death_hunt_kill"]

func play_skill(skill_id: String, origin: Vector3, target: Vector3, context: Dictionary = {}) -> Node3D:
	var module: Script
	match skill_id:
		"balance_judge": module = JUDGE
		"gold_charge": module = CHARGE
		"holy_song", "holy_song_cleanse": module = HOLY
		"king_aura": module = KING
		"blood_rampage": module = BLOOD
		"steel_order": module = STEEL
		"death_hunt", "death_hunt_kill": module = DEATH
		_: return null
	var effect: Node3D = module.new()
	effect.name = "MercenaryRework_" + skill_id
	effect.set_meta("skill_id", skill_id)
	effect.set_meta("source_sim_uid", str(context.get("source_sim_uid", "")))
	effect.set_meta("target_sim_uid", str(context.get("target_sim_uid", "")))
	add_child(effect)
	effect.call("start", skill_id, origin, target, context)
	return effect

func active_target_uids() -> Array:
	var ids: Dictionary = {}
	for effect in get_children():
		if effect.has_method("tracked_uids"):
			for uid in effect.call("tracked_uids"):
				if not str(uid).is_empty():
					ids[str(uid)] = true
	return ids.keys()

func sync_statuses(status_by_uid: Dictionary) -> void:
	for effect in get_children():
		if effect.has_method("sync_statuses"):
			effect.call("sync_statuses", status_by_uid)
