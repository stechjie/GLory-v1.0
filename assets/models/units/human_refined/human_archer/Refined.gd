extends "res://assets/models/units/human_archer_animated/humanarcherAnimated.gd"
const REFINED_BODY = preload("res://assets/models/units/human_refined/human_archer/body.tres")


const GEAR_MATERIAL = preload("res://assets/models/units/human_refined/human_archer/gear.tres")
func _load_action_models() -> void:
	super._load_action_models()
	for action in action_nodes:
		var node = action_nodes[action]
		_apply_material_override(node, REFINED_BODY)
		var skeleton = node.find_children("*", "Skeleton3D", true, false)[0]
		var gear = MeshInstance3D.new()
		gear.name = "ArcherEquipment"
		gear.skin = load("res://assets/models/units/human_refined/human_archer/archer_" + str(action) + "_skin.tres")
		gear.mesh = load("res://assets/models/units/human_refined/human_archer/archer_" + str(action) + "_gear.res")
		gear.material_override = GEAR_MATERIAL
		skeleton.add_child(gear)
		gear.skeleton = NodePath("..")
