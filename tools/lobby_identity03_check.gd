extends Node
const Harness = preload("res://tools/CheckHarness.gd")
class LobbyProbe:
	extends "res://scenes/menu/Team3v3Lobby.gd"
	var leader := 0
	func _ready() -> void:
		_build()
	func _online() -> bool:
		return false
	func _leader_slot() -> int:
		return leader
	func _seat_profile(index: int) -> Dictionary:
		return {"player_name": "Player%d" % index, "friend_code": "ABCDEFGH"}

func _ready() -> void:
	var h = Harness.new("lobby_identity03")
	var lobby = LobbyProbe.new()
	add_child(lobby)
	lobby._slot_states = ["player", "player", "empty", "dummy", "empty", "empty"]
	lobby._slot_ready = [false, true, false, true, false, false]
	lobby._local_slot = 0
	lobby._refresh()
	h.expect(lobby._slot_status_lbls[0].text == lobby._room_text("房主", "Host"), "host", "房主显示身份而非未准备")
	h.expect(lobby._slot_status_lbls[1].text == lobby._room_text("准备", "Ready"), "ready", "其他玩家保留准备状态")
	h.expect(lobby._slot_name_lbls[0].text.ends_with(lobby._room_text("（我）", " (Me)")), "me", "资料昵称后标记本机")
	h.expect(lobby._slot_name_lbls[0].get_theme_color("font_color") == Color(1, 0.82, 0.18), "gold", "本机昵称金黄色")
	lobby.leader = 1
	lobby._local_slot = 1
	lobby._refresh()
	h.expect(lobby._slot_status_lbls[1].text == lobby._room_text("房主", "Host"), "migration", "房主迁移到新座位")
	h.expect(lobby._slot_status_lbls[0].text == lobby._room_text("未准备", "Not ready"), "old_host", "旧房主恢复准备状态")
	h.expect(not lobby._slot_name_lbls[0].text.contains(lobby._room_text("（我）", " (Me)")) and lobby._slot_name_lbls[0].get_theme_color("font_color") == Color(0.47, 0.28, 0.08), "reset", "旧座位移除本机标记及高亮")
	lobby._refresh()
	h.expect(lobby._slot_name_lbls[1].text.count(lobby._room_text("（我）", " (Me)")) == 1, "no_duplicate", "刷新不会累加标记")
	lobby.free()
	h.finish(get_tree())
