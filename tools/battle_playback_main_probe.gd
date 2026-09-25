extends "res://scenes/main/Main.gd"
var battle_shown := 0
var prep_shown := 0
var replay_failures: Array[String] = []
func _ready() -> void:
	pass
func _hide_reconnect_overlay() -> void:
	pass
func _show_battle(_scene: PackedScene = null) -> void:
	battle_shown += 1
func _show_prep() -> void:
	prep_shown += 1
func _fail_resume_replay(reason: String) -> void:
	_resume_replay_generation += 1
	_resume_replay_pending.clear()
	replay_failures.append(reason)
