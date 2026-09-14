extends Node3D
class_name VFXFirstBatchSkills3D

## Isolated review composer for the first visual-unification batch.
##
## This node is intentionally preview-only. Formal BattleVfx routes continue to
## use the existing composers until these six effects pass battle-camera review.

const VFXBlockRoot := preload("res://effects/vfx3d/VFXBlockRoot.gd")
const VFXQualityBudget := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
const PAINTED := preload("res://effects/vfx3d/modules/VFXBossTextureLayer3D.gd")

const FRONT_STUN_PROFILE := preload("res://effects/vfx3d/profiles/examples/first_batch_front_stun.tres")
const GUARDIAN_PROFILE := preload("res://effects/vfx3d/profiles/examples/first_batch_guardian_taunt.tres")
const SILENCE_PROFILE := preload("res://effects/vfx3d/profiles/examples/first_batch_silence_bolt.tres")
const POISON_PROFILE := preload("res://effects/vfx3d/profiles/examples/first_batch_poison_glob.tres")
const GROUP_HEAL_PROFILE := preload("res://effects/vfx3d/profiles/examples/first_batch_group_heal.tres")
const METEOR_PROFILE := preload("res://effects/vfx3d/profiles/examples/first_batch_element_meteor.tres")

const SWORDSMAN := "res://assets/vfx/skills/human_swordsman/"
const GUARDIAN := "res://assets/vfx/skills/god_guardian/"
const SILENCE := "res://assets/vfx/skills/dark_mage_silence/"
const CLERIC := "res://assets/vfx/skills/human_cleric/"
const POISON := "res://assets/vfx/skills/undead_poison_v2/"
const BOSS := "res://assets/vfx/boss/"

const EFFECT_IDS := [
	"front_cone_stun",
	"guardian_shield_taunt",
	"silence_bolt",
	"poison_attack",
	"every_fifth_group_heal",
	"element_meteor",
]

var last_spawned: Node3D

const LEVEL_FOOT := -0.55
const LEVEL_LOW := -0.30
const LEVEL_BODY := -0.10
const LEVEL_SHOULDER := 0.26
const LEVEL_HEAD := 0.52
const CAMERA_PUSH := 0.62
const UNIT_HEIGHT_FALLBACK := 0.98


func play_review(effect_id: String, origin: Vector3, target: Vector3, context: Dictionary = {}) -> Node3D:
	last_spawned = null
	match effect_id:
		"front_cone_stun":
			_front_cone_stun(origin, target, context, FRONT_STUN_PROFILE)
		"guardian_shield_taunt":
			_guardian_shield_taunt(origin, context, GUARDIAN_PROFILE)
		"silence_bolt":
			_silence_bolt(origin, target, context, SILENCE_PROFILE)
		"poison_attack":
			_poison_attack(origin, target, context, POISON_PROFILE)
		"every_fifth_group_heal":
			_group_heal(origin, context, GROUP_HEAL_PROFILE)
		"element_meteor":
			_element_meteor(target, context, METEOR_PROFILE)
		_:
			push_warning("Unknown first-batch VFX review id: %s" % effect_id)
	return last_spawned


func _front_cone_stun(origin: Vector3, target: Vector3, context: Dictionary, profile: VFXProfile3D) -> void:
	var flip := _flip_for(origin, target)
	var oh := _unit_height(context, "origin_height")
	var th := _unit_height(context, "target_height")
	_layer(SWORDSMAN + "human_swordsman_blade_charge.png", {
		"name": "FrontStun_Charge",
		"position": _lvl(origin, oh, LEVEL_BODY),
		"size": Vector2(0.68, 1.10) * profile.size,
		"duration": 0.36,
		"start_scale": 0.16,
		"peak_scale": 0.88,
		"end_scale": 0.42,
		"rotation_z": flip,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.012,
		"opacity": 0.88,
		"seed": 101.0,
	})
	_layer(SWORDSMAN + "human_swordsman_arc_180.png", {
		"name": "FrontStun_WideArc",
		"position": _lvl(target, th, LEVEL_BODY),
		"size": Vector2(2.22, 1.22) * profile.size,
		"duration": 0.56,
		"delay": 0.10,
		"start_scale": 0.10,
		"peak_scale": 1.0,
		"end_scale": 1.08,
		"rotation_z": flip,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.016,
		"opacity": 0.96,
		"seed": 107.0,
	})
	_layer(SWORDSMAN + "human_swordsman_front_impact.png", {
		"name": "FrontStun_Impact",
		"position": _lvl(target, th, LEVEL_BODY) + Vector3(0.0, 0.0, 0.03),
		"size": Vector2(1.12, 1.02) * profile.size,
		"duration": 0.42,
		"delay": 0.22,
		"start_scale": 0.08,
		"peak_scale": 0.88,
		"end_scale": 1.12,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.010,
		"opacity": 0.90,
		"seed": 113.0,
	})
	if VFXQualityBudget.auxiliary_layers_for(2, VFXQualityBudget.PRIORITY_CRITICAL) > 1:
		_layer(SWORDSMAN + "human_swordsman_after_shards.png", {
			"name": "FrontStun_Breakup",
			"position": _lvl(target, th, LEVEL_BODY) + Vector3(0.0, 0.0, 0.04),
			"size": Vector2(1.42, 1.04) * profile.size,
			"duration": 0.66,
			"delay": 0.30,
			"start_scale": 0.12,
			"peak_scale": 0.74,
			"end_scale": 1.14,
			"rotation_z": flip,
			"dark_tint": profile.dark_color,
			"body_tint": profile.main_color,
			"core_tint": profile.core_color,
			"flow_strength": 0.022,
			"opacity": 0.74,
			"seed": 127.0,
		})
	_layer(SWORDSMAN + "human_swordsman_stun_ring.png", {
		"name": "FrontStun_StatusPulse",
		"position": _lvl(target, th, LEVEL_FOOT, 0.0) + Vector3(0.0, 0.025, 0.0),
		"size": Vector2(1.36, 1.36) * profile.size,
		"ground": true,
		"duration": 0.88,
		"delay": 0.28,
		"start_scale": 0.10,
		"peak_scale": 0.78,
		"end_scale": 1.02,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.008,
		"opacity": 0.72,
		"seed": 131.0,
	})


func _guardian_shield_taunt(origin: Vector3, context: Dictionary, profile: VFXProfile3D) -> void:
	var oh := _unit_height(context, "origin_height")
	_layer(GUARDIAN + "guardian_shield_sigil.png", {
		"name": "Guardian_Sigil",
		"position": _lvl(origin, oh, LEVEL_FOOT, 0.0) + Vector3(0.0, 0.025, 0.0),
		"size": Vector2(1.92, 1.92) * profile.size,
		"ground": true,
		"duration": 1.20,
		"start_scale": 0.08,
		"peak_scale": 0.82,
		"end_scale": 1.04,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.006,
		"opacity": 0.80,
		"seed": 151.0,
	})
	_layer(GUARDIAN + "guardian_shield_shell.png", {
		"name": "Guardian_Shell",
		"position": _lvl(origin, oh, LEVEL_BODY) + Vector3(0.0, 0.0, 0.03),
		"size": Vector2(1.34, 1.92) * profile.size,
		"duration": 1.26,
		"delay": 0.08,
		"start_scale": 0.12,
		"peak_scale": 0.92,
		"end_scale": 0.96,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.010,
		"opacity": 0.90,
		"seed": 157.0,
	})
	_layer(GUARDIAN + "guardian_taunt_ring.png", {
		"name": "Guardian_TauntPulse",
		"position": _lvl(origin, oh, LEVEL_FOOT, 0.0) + Vector3(0.0, 0.03, 0.0),
		"size": Vector2(2.30, 2.30) * profile.size,
		"ground": true,
		"duration": 0.94,
		"delay": 0.20,
		"start_scale": 0.08,
		"peak_scale": 0.76,
		"end_scale": 1.0,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.010,
		"opacity": 0.72,
		"seed": 163.0,
	})
	if VFXQualityBudget.auxiliary_layers_for(2, VFXQualityBudget.PRIORITY_CRITICAL) > 1:
		_layer(GUARDIAN + "guardian_crystal_shards.png", {
			"name": "Guardian_Shards",
			"position": _lvl(origin, oh, LEVEL_BODY) + Vector3(0.0, 0.0, 0.05),
			"size": Vector2(1.62, 1.54) * profile.size,
			"duration": 1.02,
			"delay": 0.28,
			"start_scale": 0.08,
			"peak_scale": 0.72,
			"end_scale": 1.02,
			"dark_tint": profile.dark_color,
			"body_tint": profile.main_color,
			"core_tint": profile.core_color,
			"flow_strength": 0.020,
			"opacity": 0.72,
			"seed": 167.0,
		})


func _silence_bolt(origin: Vector3, target: Vector3, context: Dictionary, profile: VFXProfile3D) -> void:
	var flip := _flip_for(origin, target)
	var oh := _unit_height(context, "origin_height")
	var th := _unit_height(context, "target_height")
	_layer(SILENCE + "mage_ink_gather.png", {
		"name": "Silence_Gather",
		"position": _lvl(origin, oh, LEVEL_BODY),
		"size": Vector2(1.18, 1.34) * profile.size,
		"duration": 0.38,
		"start_scale": 0.82,
		"peak_scale": 0.48,
		"end_scale": 0.24,
		"rotation_z": flip,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.026,
		"opacity": 0.94,
		"seed": 181.0,
	})
	_layer(SILENCE + "mage_ink_spike.png", {
		"name": "Silence_Travel",
		"from": _lvl(origin, oh, LEVEL_BODY),
		"to": _lvl(target, th, LEVEL_BODY),
		"track_node": context.get("target_node"),
		"size": Vector2(1.72, 0.46) * profile.size,
		"duration": 0.72,
		"travel_ratio": 0.70,
		"delay": 0.10,
		"start_scale": 0.24,
		"peak_scale": 1.0,
		"end_scale": 0.80,
		"rotation_z": flip,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.020,
		"opacity": 0.98,
		"seed": 191.0,
	})
	_layer(SILENCE + "mage_silence_seal.png", {
		"name": "Silence_Seal",
		"position": _lvl(target, th, LEVEL_HEAD) + Vector3(0.0, 0.0, 0.03),
		"size": Vector2(0.90, 0.98) * profile.size,
		"duration": 0.52,
		"delay": 0.62,
		"start_scale": 0.08,
		"peak_scale": 0.86,
		"end_scale": 0.96,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.022,
		"opacity": 0.94,
		"seed": 193.0,
	})
	_layer(SILENCE + "mage_silence_wrap.png", {
		"name": "Silence_Wrap",
		"position": _lvl(target, th, LEVEL_SHOULDER) + Vector3(0.0, 0.0, 0.02),
		"follow_node": context.get("target_node"),
		"size": Vector2(0.84, 1.04) * profile.size,
		"duration": 1.70,
		"delay": 0.72,
		"start_scale": 0.10,
		"peak_scale": 0.78,
		"end_scale": 0.88,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.016,
		"opacity": 0.68,
		"seed": 197.0,
	})


func _poison_attack(origin: Vector3, target: Vector3, context: Dictionary, profile: VFXProfile3D) -> void:
	# The generated glob is painted with its heavy head on the left, so rotate it
	# for the usual left-to-right preview travel. This keeps the leading mass ahead
	# of the tail in either battle direction.
	var flip := PI if target.x >= origin.x else 0.0
	var oh := _unit_height(context, "origin_height")
	var th := _unit_height(context, "target_height")
	_layer(POISON + "undead_poison_glob_v2.png", {
		"name": "Poison_ViscousGlob",
		"from": _lvl(origin, oh, LEVEL_BODY),
		"to": _lvl(target, th, LEVEL_BODY),
		"track_node": context.get("target_node"),
		"size": Vector2(1.62, 0.66) * profile.size,
		"duration": 0.76,
		"travel_ratio": 0.70,
		"start_scale": 0.18,
		"peak_scale": 1.0,
		"end_scale": 0.82,
		"rotation_z": flip,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.026,
		"opacity": 0.98,
		"seed": 211.0,
	})
	_layer(POISON + "undead_poison_impact_v2.png", {
		"name": "Poison_AsymmetricImpact",
		"position": _lvl(target, th, LEVEL_BODY) + Vector3(0.0, 0.0, 0.03),
		"size": Vector2(1.36, 1.36) * profile.size,
		"duration": 0.72,
		"delay": 0.52,
		"start_scale": 0.08,
		"peak_scale": 0.88,
		"end_scale": 1.08,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.022,
		"opacity": 0.94,
		"seed": 223.0,
	})
	_layer(POISON + "undead_poison_residue_v2.png", {
		"name": "Poison_GroundResidue",
		"position": _lvl(target, th, LEVEL_FOOT, 0.0) + Vector3(0.0, 0.028, 0.0),
		"size": Vector2(1.74, 1.12) * profile.size,
		"ground": true,
		"duration": 1.48,
		"delay": 0.62,
		"start_scale": 0.12,
		"peak_scale": 0.88,
		"end_scale": 0.98,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.010,
		"opacity": 0.76,
		"seed": 227.0,
	})


func _group_heal(origin: Vector3, context: Dictionary, profile: VFXProfile3D) -> void:
	var oh := _unit_height(context, "origin_height")
	_layer(CLERIC + "human_cleric_life_mark.png", {
		"name": "GroupHeal_CastMark",
		"position": _lvl(origin, oh, LEVEL_FOOT, 0.0) + Vector3(0.0, 0.025, 0.0),
		"size": Vector2(1.42, 1.42) * profile.size,
		"ground": true,
		"duration": 1.04,
		"start_scale": 0.08,
		"peak_scale": 0.82,
		"end_scale": 1.02,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.006,
		"opacity": 0.78,
		"seed": 241.0,
	})
	_layer(CLERIC + "human_cleric_prayer_wisp.png", {
		"name": "GroupHeal_Prayer",
		"position": _lvl(origin, oh, LEVEL_SHOULDER) + Vector3(0.0, 0.0, 0.02),
		"size": Vector2(1.04, 1.24) * profile.size,
		"duration": 0.86,
		"delay": 0.04,
		"start_scale": 0.10,
		"peak_scale": 0.82,
		"end_scale": 0.94,
		"rise": 0.12,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.012,
		"opacity": 0.88,
		"seed": 251.0,
	})
	var targets: Array = context.get("targets", [origin])
	var target_limit := mini(4, VFXQualityBudget.max_aoe_targets(targets.size()))
	for i in range(target_limit):
		var ally: Vector3 = targets[i]
		var stagger := 0.16 + float(i) * 0.055
		_layer(CLERIC + "human_cleric_heal_ribbon.png", {
			"name": "GroupHeal_Lift_%d" % i,
			"position": _lvl_foot(ally, UNIT_HEIGHT_FALLBACK, LEVEL_BODY) + Vector3(0.0, 0.0, 0.02),
			"size": Vector2(1.20, 0.52) * profile.size,
			"duration": 0.76,
			"delay": stagger,
			"start_scale": 0.10,
			"peak_scale": 0.90,
			"end_scale": 0.98,
			"rotation_z": -0.18 if i % 2 == 0 else 0.18,
			"rise": 0.14,
			"dark_tint": profile.dark_color,
			"body_tint": profile.main_color,
			"core_tint": profile.core_color,
			"flow_strength": 0.014,
			"opacity": 0.82,
			"seed": 257.0 + float(i) * 7.0,
		})
		_layer(CLERIC + "human_cleric_prayer_wisp.png", {
			"name": "GroupHeal_Contact_%d" % i,
			"position": _lvl_foot(ally, UNIT_HEIGHT_FALLBACK, LEVEL_SHOULDER) + Vector3(0.0, 0.0, 0.04),
			"size": Vector2(0.72, 0.82) * profile.size,
			"duration": 0.58,
			"delay": stagger + 0.12,
			"start_scale": 0.08,
			"peak_scale": 0.78,
			"end_scale": 0.90,
			"rise": 0.10,
			"dark_tint": profile.dark_color,
			"body_tint": profile.main_color,
			"core_tint": profile.core_color,
			"flow_strength": 0.010,
			"opacity": 0.76,
			"seed": 263.0 + float(i) * 11.0,
		})


func _element_meteor(target: Vector3, context: Dictionary, profile: VFXProfile3D) -> void:
	var tracked_target := _tracked_target(target, context)
	var th := _unit_height(context, "target_height")
	_layer(BOSS + "boss_meteor_warning.png", {
		"name": "Meteor_BrokenWarning",
		"position": _lvl(tracked_target, th, LEVEL_FOOT, 0.0) + Vector3(0.0, 0.028, 0.0),
		"size": Vector2(2.10, 1.88) * profile.size,
		"ground": true,
		"duration": 1.12,
		"start_scale": 0.12,
		"peak_scale": 0.84,
		"end_scale": 0.96,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.006,
		"opacity": 0.82,
		"seed": 281.0,
	}, true)
	_layer(BOSS + "boss_meteor_trail.png", {
		"name": "Meteor_Descent",
		"from": _lvl(tracked_target, th, LEVEL_HEAD) + Vector3(-0.50, 2.68, 0.02),
		"to": _lvl(tracked_target, th, LEVEL_LOW),
		"track_node": context.get("target_node"),
		"size": Vector2(0.82, 2.10) * profile.size,
		"duration": 0.88,
		"delay": 0.14,
		"travel_ratio": 0.72,
		"start_scale": 0.24,
		"peak_scale": 0.94,
		"end_scale": 0.80,
		"rotation_z": -0.16,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.018,
		"opacity": 0.98,
		"seed": 283.0,
	}, true)
	_layer(BOSS + "boss_meteor_explosion.png", {
		"name": "Meteor_RockImpact",
		"position": _lvl(tracked_target, th, LEVEL_FOOT, 0.0) + Vector3(0.0, 0.035, 0.0),
		"size": Vector2(2.32, 2.18) * profile.size,
		"ground": true,
		"duration": 1.06,
		"delay": 0.68,
		"start_scale": 0.06,
		"peak_scale": 0.92,
		"end_scale": 1.08,
		"dark_tint": profile.dark_color,
		"body_tint": profile.main_color,
		"core_tint": profile.core_color,
		"flow_strength": 0.010,
		"opacity": 0.96,
		"seed": 293.0,
	}, true)


func _layer(texture_path: String, params: Dictionary, force := false) -> void:
	var node := VFXBlockRoot.spawn_block(PAINTED, self, force) as VFXBossTextureLayer3D
	if node == null:
		return
	if last_spawned == null:
		last_spawned = node
	node.play_layer(texture_path, params)


func _flip_for(origin: Vector3, target: Vector3) -> float:
	return PI if target.x < origin.x else 0.0


func _tracked_target(fallback: Vector3, context: Dictionary) -> Vector3:
	var target_node: Variant = context.get("target_node")
	if not (is_instance_valid(target_node) and target_node is Node3D):
		return fallback
	var parent := get_parent() as Node3D
	if parent == null:
		return fallback
	var tracked := parent.to_local((target_node as Node3D).global_position)
	tracked.y = fallback.y
	return tracked


func _unit_height(context: Dictionary, key: String) -> float:
	return maxf(0.12, float(context.get(key, UNIT_HEIGHT_FALLBACK)))


func _lvl(base: Vector3, height: float, level: float, push := 1.0) -> Vector3:
	return base + Vector3(0.0, height * level, 0.0) + VFXBlockRoot.vfx_toward_camera(height * CAMERA_PUSH * push)


func _lvl_foot(base: Vector3, height: float, level: float, push := 1.0) -> Vector3:
	return base + Vector3(0.0, height * (level + 0.55), 0.0) + VFXBlockRoot.vfx_toward_camera(height * CAMERA_PUSH * push)
