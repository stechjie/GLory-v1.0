extends "res://assets/models/units/god_angel_animated/GodangelAnimated.gd"
const BODY = preload("res://assets/models/units/god_angel_refined/angel_body.tres")
const HALO = preload("res://assets/models/units/god_angel_refined/angel_halo.glb")
const HALO_MATERIAL = preload("res://assets/models/units/god_angel_refined/angel_halo.tres")

func _load_action_models() -> void:
	super._load_action_models()
	for action in action_nodes:
		var node: Node3D = action_nodes[action]
		for body in node.find_children("*", "MeshInstance3D", true, false):
			body.mesh = load("res://assets/models/units/god_angel_refined/body_" + str(action) + ".res")
			body.set_surface_override_material(0, BODY)
		var skeleton: Skeleton3D = node.find_children("*", "Skeleton3D", true, false)[0]
		var attachment := BoneAttachment3D.new()
		attachment.name = "RefinedHaloAttachment"
		attachment.bone_name = "CC_Base_Head"
		skeleton.add_child(attachment)
		var halo := HALO.instantiate()
		attachment.add_child(halo)
		for mesh in halo.find_children("*", "MeshInstance3D", true, false):
			mesh.material_override = HALO_MATERIAL
