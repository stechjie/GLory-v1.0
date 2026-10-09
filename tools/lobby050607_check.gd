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

	# ================= 10.09 bug 文档第 3 条 =====================================
	# 现场：3v3 打完一局 → 结算面板「返回主菜单」→ 从大厅重进刚结算完的自定义房间
	#       → 按「准备」无反应 → 按「离开房间」提示「请先取消准备」。
	#
	# 复现出来的死锁只需要两个状态同时成立：
	#   ① team_local_slot == -1 —— 本次会话没有座位（结算房把没回来的人标成 settling、
	#      且不放进 peer_slot，`_send_room_state` 因此整份不发，客户端留着旧状态）；
	#   ② _pending_ready == 1  —— 上一次「准备」的在途意图，而它是「离开」那条守卫的
	#      **唯一**判据；服务器那两条路（settling 座位直接 return、peer 不在 peer_slot
	#      就整份不发）会让确认回包永远不来，于是它撤不掉。
	# 两条叠起来玩家没有任何出口：Team3v3Lobby._on_primary_pressed() 因为 my_slot < 0
	# 静默 return（NetworkService.team_set_ready() 同样），离开又被这个意图挡住。
	# 逐条判据（改前 ①② 都是红的）：
	# ①「没有座位」不能再被在途意图锁住 —— 座位都没了，准备无从谈起。
	NetworkService.team_leader_slot = 0
	NetworkService.team_local_slot = -1
	NetworkService._pending_ready = 1
	h.expect(not main._lobby_exit_requires_cancel(), "no_seat_not_locked",
		"没有座位（team_local_slot=-1）时不该被「在途准备」锁住：按准备发不出请求、按离开又被挡住 ⇒ 永久出不了房间")
	h.expect(not NetworkService.local_ready_intent(), "no_seat_no_intent",
		"没有座位时 local_ready_intent() 必须是 false（PrepFlowController 也按它决定要不要发取消）")

	# ② 会话终结路径必须把在途意图一起清掉（reset() 一直清，这三条没有）。
	NetworkService.team_active = true
	NetworkService.team_local_slot = 1
	NetworkService.team_ready = [false, false, false, false, false, false]
	NetworkService._pending_ready = 1
	NetworkService._rpc_team_room_closed("check")
	h.expect(NetworkService._pending_ready == -1, "room_closed_clears_intent",
		"房间被关（_rpc_team_room_closed）必须把在途 ready 意图一起清掉")
	NetworkService.team_active = true
	NetworkService.team_local_slot = 1
	NetworkService._pending_ready = 1
	NetworkService.session_token = ""
	NetworkService._on_server_disconnected()
	h.expect(NetworkService._pending_ready == -1, "server_gone_clears_intent",
		"服务器断开（_on_server_disconnected）必须把在途 ready 意图一起清掉")

	# ③ 服务器既不确认也不回绝时，意图必须自己有期限（这一版没有 request/ACK）。
	NetworkService.team_active = true
	NetworkService.team_local_slot = 1
	NetworkService._pending_ready = 1
	NetworkService._ready_deadline = NetworkService._now() - 1.0
	NetworkService._tick_pending_ready(0.0)
	h.expect(NetworkService._pending_ready == -1, "intent_expires",
		"在途 ready 意图应当 %s 秒后自动作废，否则玩家被永久锁在大厅"
			% str(NetworkService.READY_CONFIRM_TIMEOUT_SEC))

	# ④ C24 的原窗口不许被上面三条误伤：座位还在 + 意图在途 ⇒ 仍然不许退出。
	NetworkService.team_active = true
	NetworkService.team_local_slot = 1
	NetworkService.team_leader_slot = 0
	NetworkService.team_ready = [false, false, false, false, false, false]
	NetworkService._pending_ready = 1
	NetworkService._ready_deadline = NetworkService._now() + 100.0
	h.expect(main._lobby_exit_requires_cancel(), "c24_window_kept",
		"座位还在、准备请求在途时仍旧不许退出（C24 的在途窗口不能被这条修复打开）")
	NetworkService._clear_pending_ready()

	NetworkService.team_active = saved[0]
	NetworkService.team_local_slot = saved[1]
	NetworkService.team_leader_slot = saved[2]
	NetworkService.team_ready = saved[3]
	NetworkService._pending_ready = saved[4]
	main.free()
	h.finish(get_tree())
