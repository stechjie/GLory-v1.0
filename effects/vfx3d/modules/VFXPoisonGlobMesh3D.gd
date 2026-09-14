extends VFXBlockRoot
class_name VFXPoisonGlobMesh3D

## Blender-authored poison projectile review module.
##
## The travelling silhouette is real low-poly geometry. Existing painted assets
## remain responsible for the impact and ground residue, so the trial tests the
## value of Blender without discarding already approved work.

const MODEL := preload("res://assets/vfx/meshes/poison_glob_trial.glb")
const PAINTED := preload("res://effects/vfx3d/modules/VFXBossTextureLayer3D.gd")
const CURVES := preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")

const IMPACT_TEXTURE := "res://assets/vfx/skills/undead_poison_v2/undead_poison_impact_v2.png"
const RESIDUE_TEXTURE := "res://assets/vfx/skills/undead_poison_v2/undead_poison_residue_v2.png"

var _visual: Node3D


func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	play_projectile(
		context.get("origin", Vector3(-1.4, 0.54, 0.0)),
		context.get("target", Vector3(1.4, 0.54, 0.0)),
		profile,
		context.get("target_node"),
		context
	)


func play_projectile(origin: Vector3, target: Vector3, profile: VFXProfile3D,
		target_node: Variant = null, context: Dictionary = {}) -> void:
	begin()
	position = origin
	_visual = MODEL.instantiate() as Node3D
	if _visual == null:
		push_error("Poison glob Blender model could not be instantiated")
		finish()
		return
	_visual.name = "BlenderPoisonGlob"
	add_child(_visual)
	_prepare_meshes(_visual)

	var base_scale := maxf(0.08, float(profile.parameters.get("model_scale", 0.34)) * profile.size)
	var travel_duration := maxf(0.28, float(profile.parameters.get("travel_duration", 0.68)))
	var arc_height := maxf(0.0, float(profile.parameters.get("arc_height", 0.16)))
	var wobble := maxf(0.0, float(profile.parameters.get("wobble", 0.15)))
	var target_ref: WeakRef = weakref(target_node) if is_instance_valid(target_node) and target_node is Node3D else null
	var tracked_target := _tracked_target(target, target_ref)
	_face_target(tracked_target)
	_visual.scale = Vector3.ONE * base_scale * 0.20
	CURVES.tween_method(self, _set_visual_scale.bind(base_scale), 0.20, 1.0, 0.13, "ease_out_back")

	await get_tree().create_timer(0.12).timeout
	if _finished:
		return
	var elapsed := 0.0
	while elapsed < travel_duration:
		await get_tree().process_frame
		if _finished or not is_instance_valid(_visual):
			return
		var delta := get_process_delta_time()
		elapsed += delta
		tracked_target = _tracked_target(tracked_target, target_ref)
		var ratio := clampf(elapsed / travel_duration, 0.0, 1.0)
		var eased := ratio * ratio * (3.0 - 2.0 * ratio)
		position = origin.lerp(tracked_target, eased) + Vector3(0.0, sin(ratio * PI) * arc_height, 0.0)
		_face_target(tracked_target)
		_visual.rotation.x = sin(ratio * PI * 4.0) * wobble
		_visual.rotation.z = cos(ratio * PI * 3.0) * wobble * 0.55
		var squash := sin(ratio * PI * 5.0) * 0.055
		_visual.scale = Vector3(base_scale * (1.0 + squash), base_scale * (1.0 - squash * 0.65), base_scale * (1.0 - squash * 0.65))

	if _finished or not is_instance_valid(_visual):
		return
	position = tracked_target
	var compression := track_tween(create_tween())
	compression.tween_property(_visual, "scale", Vector3(base_scale * 0.28, base_scale * 1.24, base_scale * 1.24), 0.09).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await get_tree().create_timer(0.09).timeout
	if _finished:
		return
	_visual.visible = false
	# The projectile yaws while travelling. Reset the effect basis before adding
	# camera-facing impact art so its depth offset stays toward the camera rather
	# than rotating sideways with the projectile.
	rotation = Vector3.ZERO
	_spawn_impact(profile, context)
	await get_tree().create_timer(1.52).timeout
	if not _finished:
		finish()


func _prepare_meshes(node: Node) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_prepare_meshes(child)


func _face_target(target: Vector3) -> void:
	var direction := target - position
	direction.y = 0.0
	if direction.length_squared() <= 0.0001:
		return
	# Blender asset forward is +X; yaw it into the battle's XZ travel plane.
	rotation.y = atan2(-direction.z, direction.x)


func _set_visual_scale(value: float, base_scale: float) -> void:
	if is_instance_valid(_visual):
		_visual.scale = Vector3.ONE * base_scale * value


func _tracked_target(fallback: Vector3, target_ref: WeakRef) -> Vector3:
	if target_ref == null:
		return fallback
	var node: Variant = target_ref.get_ref()
	if not (is_instance_valid(node) and node is Node3D):
		return fallback
	var parent := get_parent() as Node3D
	if parent == null:
		return fallback
	var tracked := parent.to_local((node as Node3D).global_position)
	tracked.y = fallback.y
	return tracked


func _spawn_impact(profile: VFXProfile3D, context: Dictionary) -> void:
	var height := maxf(0.12, float(context.get("target_height", 0.98)))
	var impact := VFXBlockRoot.spawn_block(PAINTED, self, true) as VFXBossTextureLayer3D
	if impact != null:
		impact.play_layer(IMPACT_TEXTURE, {
			"name": "BlenderPoison_Impact",
			"position": Vector3(0.0, 0.04, 0.24),
			"size": Vector2(1.82, 1.72) * profile.size,
			"duration": 0.70,
			"start_scale": 0.10,
			"peak_scale": 1.0,
			"end_scale": 1.08,
			"dark_tint": profile.dark_color,
			"body_tint": profile.main_color,
			"core_tint": profile.core_color,
			"flow_strength": 0.020,
			"opacity": 0.94,
			"seed": 317.0,
		})
	var residue := VFXBlockRoot.spawn_block(PAINTED, self, true) as VFXBossTextureLayer3D
	if residue != null:
		residue.play_layer(RESIDUE_TEXTURE, {
			"name": "BlenderPoison_Residue",
			"position": Vector3(0.0, -height * 0.55 + 0.025, 0.0),
			"size": Vector2(2.16, 1.42) * profile.size,
			"ground": true,
			"duration": 1.42,
			"delay": 0.08,
			"start_scale": 0.10,
			"peak_scale": 0.90,
			"end_scale": 1.0,
			"dark_tint": profile.dark_color,
			"body_tint": profile.main_color,
			"core_tint": profile.core_color,
			"flow_strength": 0.008,
			"opacity": 0.86,
			"seed": 331.0,
		})
