extends "res://assets/models/units/god_aurora_animated/GodauroraAnimated.gd"
# Original body and action clips stay authoritative. All equipment shares one
# rigidly weighted surface; named identity binds use bone-local mesh vertices.
const BODY=preload("res://assets/models/units/god_aurora_refined/aurora_body.tres")
const GEAR=preload("res://assets/models/units/god_aurora_refined/aurora_gear.res")
const GEAR_SKIN=preload("res://assets/models/units/god_aurora_refined/aurora_gear_skin.tres")
const GEAR_MATERIAL=preload("res://assets/models/units/god_aurora_refined/aurora_gear.tres")

func _load_action_models() -> void:
	super._load_action_models()
	for action in action_nodes:
		var node:Node3D=action_nodes[action]
		_apply_material_override(node,BODY)
		var skeleton:Skeleton3D=node.find_children("*","Skeleton3D",true,false)[0]
		var gear:=MeshInstance3D.new()
		gear.name="AuroraRangerEquipment"
		gear.mesh=GEAR
		gear.skin=GEAR_SKIN
		gear.skeleton=NodePath("..")
		gear.material_override=GEAR_MATERIAL
		skeleton.add_child(gear)
