extends "res://effects/vfx3d/mercenary_rework/MercenaryVFXBase3D.gd"

func start(_skill_id: String, origin: Vector3, target: Vector3, context: Dictionary) -> void:
	_duration = maxf(0.9, float(context.get("status_duration", 1.6)))
	var span := target - origin
	var distance := Vector2(span.x, span.z).length()
	var foot: Vector3 = context.get("target_foot", target - Vector3(0.0, 0.12, 0.0))
	if distance > 0.08:
		# A textured plane lies in the actual XZ travel corridor. A billboard
		# cannot encode this direction under the elevated battle camera.
		var lane := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(clampf(distance * 1.15, 0.8, 4.4), 0.75)
		lane.mesh = plane
		var material := StandardMaterial3D.new()
		material.albedo_texture = load(TEXTURE_ROOT + "gold_lance.png")
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		lane.material_override = material
		lane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(lane)
		lane.global_position = Vector3((origin.x + target.x) * 0.5, foot.y + 0.04, (origin.z + target.z) * 0.5)
		lane.rotation.y = atan2(-span.z, span.x)
		var streak_fade := create_tween()
		streak_fade.tween_property(material, "albedo_color", Color(1.0, 1.0, 1.0, 0.0), 0.55)
	var anchor := _target_anchor(context)
	var hit := _sprite("gold_impact.png", foot + Vector3(0.0, 0.3, 0.0), 1.25, 1.0, anchor, Vector3(0.0, -0.2, 0.0))
	_fade(hit, 0.65, 0.5, 1.28)
