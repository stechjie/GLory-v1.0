extends "res://assets/models/units/human_militia_little_knight/HumanMilitiaLittleKnightAnimated.gd"
const REFINED_BODY = preload("res://assets/models/units/human_refined/human_militia/body.tres")
const GEAR = preload("res://assets/models/units/human_refined/human_militia/gear.res")
const GEAR_SKIN = preload("res://assets/models/units/human_refined/human_militia/gear_skin.tres")
const GEAR_MATERIAL = preload("res://assets/models/units/human_refined/human_militia/gear.tres")
func _load_action_models() -> void:
	super._load_action_models()
	for action in action_nodes:
		var node = action_nodes[action]
		_apply_material_override(node, REFINED_BODY)
		var skeleton = node.find_children("*", "Skeleton3D", true, false)[0]
		var gear = MeshInstance3D.new()
		gear.name = "FieldEquipment"
		gear.skin = GEAR_SKIN
		gear.mesh = GEAR
		gear.material_override = GEAR_MATERIAL
		skeleton.add_child(gear)
		gear.skeleton = NodePath("..")
