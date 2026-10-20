extends "res://assets/models/monsters/ren/pve_ren_poison_doctor_animated/pverenpoisondoctorAnimated.gd"
const REFINED_BODY=preload("res://assets/models/enemies_refined/pve_ren_poison_doctor/body.tres")
const GEAR_MATERIAL=preload("res://assets/models/enemies_refined/pve_ren_poison_doctor/gear.tres")
func _load_action_models() -> void:
 super._load_action_models()
 for action in action_nodes:
  var node=action_nodes[action]
  _apply_material_override(node,REFINED_BODY)
  var skeleton=node.find_children("*","Skeleton3D",true,false)[0]
  var gear=MeshInstance3D.new();gear.name="PoisonDoctorHarness"
  gear.skin=load("res://assets/models/enemies_refined/pve_ren_poison_doctor/doctor_"+action+"_skin.tres")
  gear.mesh=load("res://assets/models/enemies_refined/pve_ren_poison_doctor/doctor_"+action+"_gear.res")
  gear.material_override=GEAR_MATERIAL
  skeleton.add_child(gear);gear.skeleton=NodePath("..")
