extends "res://assets/models/monsters/land/pve_land_rock_beast_animated/PvelandrockbeastAnimated.gd"
const REFINED_BODY=preload("res://assets/models/enemies_refined/pve_land_rock_beast/body.tres")
const GEAR_MATERIAL=preload("res://assets/models/enemies_refined/pve_land_rock_beast/gear.tres")
func _load_action_models() -> void:
 super._load_action_models()
 for action in action_nodes:
  var node=action_nodes[action]
  _apply_material_override(node,REFINED_BODY)
  var skeleton=node.find_children("*","Skeleton3D",true,false)[0]
  var gear=MeshInstance3D.new();gear.name="RockBeastMinerals"
  gear.skin=load("res://assets/models/enemies_refined/pve_land_rock_beast/rock_"+action+"_skin.tres")
  gear.mesh=load("res://assets/models/enemies_refined/pve_land_rock_beast/rock_"+action+"_gear.res")
  gear.material_override=GEAR_MATERIAL
  skeleton.add_child(gear);gear.skeleton=NodePath("..")
