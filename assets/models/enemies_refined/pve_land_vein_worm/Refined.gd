extends "res://assets/models/monsters/land/pve_land_vein_worm_animated/PvelandveinwormAnimated.gd"
const REFINED_BODY=preload("res://assets/models/enemies_refined/pve_land_vein_worm/body.tres")
func _load_action_models() -> void:
 super._load_action_models()
 for action in action_nodes:
  _apply_material_override(action_nodes[action],REFINED_BODY)
