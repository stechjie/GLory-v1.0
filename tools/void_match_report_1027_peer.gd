extends "res://tools/mobile_reconnect_peer.gd"
const Report := preload("res://scripts/multiplayer/BattleReport.gd")
var key: CryptoKey
var captured: Dictionary = {}
var signed_report := ""
func _broadcast_room_lobby(_room: Dictionary) -> void: pass
func _resend_result_state(_peer_id: int, _ms: Dictionary) -> void: pass
func _room_sign_report(room: Dictionary, rounds: int, outcome: int, hp_a: int, hp_b: int, final_data: Dictionary) -> String:
 captured=Report.build(_room_report_ctx(room,rounds,outcome,hp_a,hp_b,final_data))
 signed_report=Report.sign(captured,key)
 return signed_report
