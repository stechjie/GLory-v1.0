extends Node
const Harness = preload("res://tools/CheckHarness.gd")
class LobbyProbe:
	extends "res://scenes/menu/Team3v3Lobby.gd"
	var leader := 0
	var viewed := -1
	func _ready() -> void:
		pass
	func _online() -> bool:
		return false
	func _leader_slot() -> int:
		return leader
	func _is_host_seat() -> bool:
		return _local_slot == leader
	func _view_seat_profile(index: int) -> void:
		viewed = index

func _ready() -> void:
	var h = Harness.new("lobby050607")
	var lobby = LobbyProbe.new()
	lobby._slot_states = ["player", "player", "empty", "empty", "empty", "empty"]
	lobby._slot_ready = [false, false, false, false, false, false]
	lobby._on_slot_pressed(0)
	h.expect(lobby.viewed == -1, "self", "本机头像不打开资料")
	lobby._on_slot_pressed(1)
	h.expect(lobby.viewed == 1, "other", "其他玩家头像仍打开资料")
	h.expect(lobby._lobby_status_text().contains("敌我双方至少一个占位"), "priority", "缺阵营优先于未准备")
	lobby._slot_states[3] = "dummy"
	h.expect(lobby._lobby_status_text().contains("有玩家未准备"), "unready", "两侧有占位后检查玩家准备")
	lobby._slot_ready[1] = true
	h.expect(lobby._lobby_status_text().contains("可以开始"), "host", "房主无需准备即可显示可以开始")
	lobby._local_slot = 1
	h.expect(lobby._lobby_status_text().contains("等待房主开始游戏"), "guest", "客人等待房主")
	h.expect(lobby._lobby_status_text().contains("玩家2"), "count", "保留玩家数")
	lobby.free()
	var saved := [NetworkService.team_active, NetworkService.team_local_slot, NetworkService.team_leader_slot, NetworkService.team_ready.duplicate(), NetworkService._pending_ready]
	var main = load("res://scenes/main/Main.gd").new()
	NetworkService.team_active = true
	NetworkService.team_local_slot = 1
	NetworkService.team_leader_slot = 0
	NetworkService.team_ready = [false, true, false, false, false, false]
	NetworkService._pending_ready = -1
	h.expect(main._lobby_exit_requires_cancel(), "ready_exit", "准备后禁止退出")
	NetworkService._pending_ready = 0
	h.expect(main._lobby_exit_requires_cancel(), "cancel_pending", "取消准备等待确认")
	NetworkService.team_ready[1] = false
	h.expect(not main._lobby_exit_requires_cancel(), "cancelled", "取消确认后允许退出")
	NetworkService._pending_ready = 1
	h.expect(main._lobby_exit_requires_cancel(), "ready_pending", "在途准备不能绕过限制")
	NetworkService.team_leader_slot = 1
	h.expect(not main._lobby_exit_requires_cancel(), "leader_exit", "房主不受退出限制")
	NetworkService.team_active = saved[0]
	NetworkService.team_local_slot = saved[1]
	NetworkService.team_leader_slot = saved[2]
	NetworkService.team_ready = saved[3]
	NetworkService._pending_ready = saved[4]
	main.free()
	h.finish(get_tree())
