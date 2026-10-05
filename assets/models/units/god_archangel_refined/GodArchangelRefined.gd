extends "res://assets/models/units/god_archangel_animated/GodarchangelAnimated.gd"
# Keep original action resources and timing. Body compaction retains all skin,
# UV and blend-shape channels outside the explicitly replaced wing/halo faces.
const BODY=preload("res://assets/models/units/god_archangel_refined/archangel_body.tres")
const GEAR=preload("res://assets/models/units/god_archangel_refined/archangel_gear.res")
const GEAR_SKIN=preload("res://assets/models/units/god_archangel_refined/archangel_gear_skin.tres")
const GEAR_MATERIAL=preload("res://assets/models/units/god_archangel_refined/archangel_gear.tres")

func _load_action_models() -> void:
	super._load_action_models()
	for action in action_nodes:
		var node:Node3D=action_nodes[action]
		for body in node.find_children("*","MeshInstance3D",true,false):
			body.mesh=load("res://assets/models/units/god_archangel_refined/body_"+str(action)+".res")
		_apply_material_override(node,BODY)
		var skeleton:Skeleton3D=node.find_children("*","Skeleton3D",true,false)[0]
		var gear:=MeshInstance3D.new()
		gear.name="ArchangelWingsAndAureole"
		gear.mesh=GEAR
		gear.skin=GEAR_SKIN
		gear.skeleton=NodePath("..")
		gear.material_override=GEAR_MATERIAL
		skeleton.add_child(gear)
