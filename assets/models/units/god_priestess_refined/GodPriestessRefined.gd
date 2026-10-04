extends "res://assets/models/units/god_priestess_animated/GodpriestessAnimated.gd"

# Original action scenes, proxy timing, skin and expression tracks stay authoritative.
const REFINED_BODY = preload("res://assets/models/units/god_priestess_refined/priestess_body.tres")
const MITRE = preload("res://assets/models/units/god_priestess_refined/priestess_mitre.glb")
const CLASP = preload("res://assets/models/units/god_priestess_refined/priestess_clasp.glb")
const ORNAMENT_SHADER = preload("res://assets/models/units/god_priestess_refined/priestess_ornament.gdshader")
var _ornament_materials: Dictionary = {}

func _load_action_models() -> void:
	super._load_action_models()
	for action in action_nodes:
		var node: Node3D = action_nodes[action]
		_apply_material_override(node, REFINED_BODY)
		var skeletons := node.find_children("*", "Skeleton3D", true, false)
		if skeletons.is_empty():
			push_error("大祭司精修模型缺少骨架：" + str(action))
			continue
		var skeleton := skeletons[0] as Skeleton3D
		_attach(skeleton, "CC_Base_Head", MITRE, "MitreInlay")
		_attach(skeleton, "CC_Base_Spine02", CLASP, "BlessingClasp")

func _attach(skeleton: Skeleton3D, bone: String, scene: PackedScene, label: String) -> void:
	var index := skeleton.find_bone(bone)
	if index < 0:
		push_error("大祭司精修挂点不存在：" + bone)
		return
	var attachment := BoneAttachment3D.new()
	attachment.name = label
	attachment.bone_name = bone
	skeleton.add_child(attachment)
	var ornament := scene.instantiate() as Node3D
	attachment.add_child(ornament)
	# Authored in skeleton rest coordinates; cancel rest once, then follow pose.
	ornament.transform = skeleton.get_bone_global_rest(index).affine_inverse()
	for mesh in ornament.find_children("*", "MeshInstance3D", true, false):
		for surface in mesh.mesh.get_surface_count():
			var source: Material = mesh.mesh.surface_get_material(surface)
			var key := source.resource_name
			if not _ornament_materials.has(key):
				var material := ShaderMaterial.new()
				material.shader = ORNAMENT_SHADER
				var color := Color(0.94, 0.93, 0.87)
				if "gold" in key:
					color = Color(0.87, 0.67, 0.32)
				elif "sapphire" in key:
					color = Color(0.22, 0.57, 0.76)
				material.set_shader_parameter("base_color", color)
				_ornament_materials[key] = material
			mesh.set_surface_override_material(surface, _ornament_materials[key])
