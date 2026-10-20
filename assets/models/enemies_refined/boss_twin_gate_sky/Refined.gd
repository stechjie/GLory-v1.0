extends "res://assets/models/bosses/boss_twin_gate_animated/BossTwinGateVariantAnimated.gd"
const REFINED_BODY=preload("res://assets/models/enemies_refined/boss_twin_gate_sky/body.tres")
func _load_action_models() -> void:
 super._load_action_models()
 for action in action_nodes:
  _apply_material_override(action_nodes[action],REFINED_BODY)
