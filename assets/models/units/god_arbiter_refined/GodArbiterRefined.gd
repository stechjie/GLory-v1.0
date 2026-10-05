extends "res://assets/models/units/god_arbiter_animated/GodarbiterAnimated.gd"
# Each action retains its own body bind space, original animations and weapon.
const REFINED_BODY=preload("res://assets/models/units/god_arbiter_refined/arbiter_body.tres")
const REFINED_ASSETS={
 "idle":[preload("res://assets/models/units/god_arbiter_refined/arbiter_idle_body.res"),preload("res://assets/models/units/god_arbiter_refined/arbiter_idle_combined_skin.tres")],
 "run":[preload("res://assets/models/units/god_arbiter_refined/arbiter_run_body.res"),preload("res://assets/models/units/god_arbiter_refined/arbiter_run_combined_skin.tres")],
 "attack":[preload("res://assets/models/units/god_arbiter_refined/arbiter_attack_body.res"),preload("res://assets/models/units/god_arbiter_refined/arbiter_attack_combined_skin.tres")]
}
func _load_action_models() -> void:
 super._load_action_models()
 for action in action_nodes:
  var node:Node3D=action_nodes[action]
  for body in node.find_children("*","MeshInstance3D",true,false):
   if body.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()!=4748:continue
   # Install the extended skin before its mesh: every joint is valid during AABB updates.
   body.skin=REFINED_ASSETS[action][1]
   body.mesh=REFINED_ASSETS[action][0]
   body.set_surface_override_material(0,REFINED_BODY)
