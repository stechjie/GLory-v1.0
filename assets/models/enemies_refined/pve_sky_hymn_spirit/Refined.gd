extends "res://assets/models/monsters/sky/pve_sky_hymn_spirit_animated/pve_sky_hymn_spirit_Animated.gd"
const REFINED_BODY=preload("res://assets/models/enemies_refined/pve_sky_hymn_spirit/body.tres")
const GEAR_MATERIAL=preload("res://assets/models/enemies_refined/pve_sky_hymn_spirit/gear.tres")
func _load_action_models() -> void:
 super._load_action_models()
 for action in action_nodes:
  var node=action_nodes[action]
  _apply_material_override(node,REFINED_BODY)
  var skeleton=node.find_children("*","Skeleton3D",true,false)[0]
  var gear=MeshInstance3D.new();gear.name="HymnSpiritVestments"
  gear.skin=load("res://assets/models/enemies_refined/pve_sky_hymn_spirit/hymn_"+action+"_skin.tres")
  gear.mesh=load("res://assets/models/enemies_refined/pve_sky_hymn_spirit/hymn_"+action+"_gear.res")
  gear.material_override=GEAR_MATERIAL
  skeleton.add_child(gear);gear.skeleton=NodePath("..")
