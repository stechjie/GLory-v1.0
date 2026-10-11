extends "res://assets/models/units/human_king_animated/HumanKingAnimated.gd"
const REFINED_BODY = preload("res://assets/models/units/human_refined/human_king/body.tres")


const GEAR_MATERIAL = preload("res://assets/models/units/human_refined/human_king/gear.tres")
func _load_action_models() -> void:
	super._load_action_models()
	for action in action_nodes:
		var node = action_nodes[action]
		_apply_material_override(node, REFINED_BODY)
		var skeleton = node.find_children("*", "Skeleton3D", true, false)[0]
		var gear = MeshInstance3D.new()
		gear.name = "KingEquipment"
		gear.skin = load("res://assets/models/units/human_refined/human_king/king_" + str(action) + "_skin.tres")
		gear.mesh = load("res://assets/models/units/human_refined/human_king/king_" + str(action) + "_gear.res")
		gear.material_override = GEAR_MATERIAL
		skeleton.add_child(gear)
		gear.skeleton = NodePath("..")
