extends "res://assets/models/bosses/boss_blood_demon_animated/bossblooddemonAnimated.gd"
const REFINED_BODY=preload("res://assets/models/enemies_refined/boss_blood_demon/body.tres")
func _load_action_models() -> void:
 super._load_action_models()
 for action in action_nodes:
  _apply_material_override(action_nodes[action],REFINED_BODY)
