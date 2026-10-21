extends "res://assets/models/bosses/boss_rage_beast_animated/bossragebeastAnimated.gd"
const REFINED_BODY=preload("res://assets/models/enemies_refined/boss_rage_beast/body.tres")
func _load_action_models() -> void:
 super._load_action_models()
 for action in action_nodes:
  _apply_material_override(action_nodes[action],REFINED_BODY)
