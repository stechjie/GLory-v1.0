extends "res://assets/models/units/human_swordsman_animated/HumanswordsmanAnimated.gd"
const REFINED_BODY = preload("res://assets/models/units/human_refined/human_swordsman/body.tres")
const GEAR = preload("res://assets/models/units/human_refined/human_swordsman/gear.res")
const GEAR_SKIN = preload("res://assets/models/units/human_refined/human_swordsman/gear_skin.tres")
const GEAR_MATERIAL = preload("res://assets/models/units/human_refined/human_swordsman/gear.tres")
func _load_action_models() -> void:
	super._load_action_models()
	for action in action_nodes:
		var node = action_nodes[action]
		_apply_material_override(node, REFINED_BODY)
		var skeleton = node.find_children("*", "Skeleton3D", true, false)[0]
		var gear = MeshInstance3D.new()
		gear.name = "SwordsmanEquipment"
		gear.skin = GEAR_SKIN
		gear.mesh = GEAR
		gear.material_override = GEAR_MATERIAL
		skeleton.add_child(gear)
		gear.skeleton = NodePath("..")
