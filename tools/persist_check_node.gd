extends Node

# 房间持久化的**端到端**验证（B5）。
#
# 对抗台里的 room_snapshot_roundtrip 是同进程存读，证明不了"文件真的活过进程死亡"。
# 这个工具分两阶段跑，中间进程真的退出：
#
#   阶段 save：起一个真的监听服务器 -> 造几个打到一半的房间 -> 落盘 -> 退出
#   阶段 load：新进程起同一个分片 -> 读回来 -> 核对内容
#
# 用法：
#   godot --headless --path <proj> tools/persist_check.tscn -- --persist-phase=save --battle-card-key=user://test_battle_card_public.pem
#   godot --headless --path <proj> tools/persist_check.tscn -- --persist-phase=load --battle-card-key=user://test_battle_card_public.pem
#
# --battle-card-key= 那一段是必须的：专服要出战名片公钥才肯启动，这里现场生成一把、
# 写到那条测试路径（不碰默认路径，理由见 tools/battle_card_test_keys.gd）。
#
# 分片号固定用 7，避开默认端口，不会撞上真在跑的服务器。

const BattleCardTestKeys := preload("res://tools/battle_card_test_keys.gd")

const SHARD := 7
const PORT := 8087
const ROUND_MARK := 11
const HP_MARK := [33, 29]

func _ready() -> void:
	var phase := _arg("--persist-phase", "save")
	NetworkService._shard_index = SHARD
	# 专服没有出战名片公钥就拒绝启动（BattleCard.gd）。这里现场生成一把一次性的；
	# 服务器启动时读进内存，之后文件就没用了，立刻删。
	var key_error := BattleCardTestKeys.install_for_server()
	if not key_error.is_empty():
		print("[PERSIST] FATAL: %s" % key_error)
		get_tree().quit(2)
		return
	var started := NetworkService.start_dedicated_server(PORT)
	BattleCardTestKeys.remove_files()
	if not started:
		print("[PERSIST] FATAL: cannot start server on %d: %s" % [PORT, NetworkService.last_error])
		get_tree().quit(2)
		return

	if phase == "save":
		_do_save()
	else:
		_do_load()

func _do_save() -> void:
	# 造两个"打到一半"的房间：一个备战、一个大厅
	var prep: Dictionary = NetworkService._new_room()
	prep.state = NetworkService.ROOM_PREP
	prep.round_index = ROUND_MARK
	prep.team_hp = HP_MARK.duplicate()
	prep.slot_states = ["player", "player", "dummy", "player", "empty", "empty"]
	prep.leader_slot = 1
	# 出战种族（协议 28）要活过重启。今天只有四族，合法选择只有一份、和默认一模一样，
	# 所以 load 阶段核对的是「座位上这个字段还在」，而不是「内容不等于默认」。
	prep.seat_races = {1: ["god", "dark", "undead", "human"]}
	# 协议 29 的营地展示宠物同样是座位状态；重启后不能退回错误的默认宠物。
	prep.seat_pets = {1: "pet_cat"}
	NetworkService._assign_peer_to_room(7001, prep, "")

	var lobby: Dictionary = NetworkService._new_room()
	NetworkService._assign_peer_to_room(7002, lobby, "")

	NetworkService._save_rooms_snapshot()
	print("[PERSIST] saved rooms=%d prep_id=%d lobby_id=%d tokens=%d" % [
		NetworkService._rooms.size(), int(prep.id), int(lobby.id), NetworkService._token_seat.size()])
	print("[PERSIST] snapshot=%s exists=%s" % [
		NetworkService._snapshot_path(),
		str(FileAccess.file_exists(NetworkService._snapshot_path()))])
	get_tree().quit(0)

func _do_load() -> void:
	# start_dedicated_server 内部已经调过 _load_rooms_snapshot
	var rooms: Array = NetworkService._rooms.values()
	var ok := true
	var detail: Array = []

	detail.append("rooms=%d" % rooms.size())
	if rooms.size() != 2:
		ok = false

	var found_prep := false
	for room in rooms:
		if int(room.get("round_index", 0)) != ROUND_MARK:
			continue
		found_prep = true
		# 关键三条：内容对、peer 清空、宽限按新基准重建
		var hp_ok := str(room.get("team_hp", [])) == str(HP_MARK)
		var phase_ok := str(room.get("state", "")) == NetworkService.ROOM_PREP
		var peers_cleared: bool = (room.get("peer_slot", {}) as Dictionary).is_empty()
		# 每个 "player" 座位都该进宽限。数量动态数 —— _assign_peer_to_room 会把
		# 玩家放进第一个空位，所以最终的 player 数不等于我们初始写的那份。
		var player_seats := 0
		for st in (room.get("slot_states", []) as Array):
			if str(st) == "player":
				player_seats += 1
		var deadline: Dictionary = room.get("reserve_deadline", {})
		var reserved_ok := deadline.size() == player_seats and player_seats > 0
		detail.append("player_seats=%d reserved=%d" % [player_seats, deadline.size()])
		var rebased := true
		for slot in deadline.keys():
			var remain: float = float(deadline[slot]) - NetworkService._now()
			if remain <= 0.0 or remain > NetworkService.RESERVE_GRACE_SEC + 1.0:
				rebased = false
		detail.append("hp=%s phase=%s peers_cleared=%s reserved=%s deadline_rebased=%s" % [
			hp_ok, phase_ok, peers_cleared, reserved_ok, rebased])
		# 出战种族（协议 28）：座位上这个字段要还在，否则重启后回落默认四族
		var races_ok := str((room.get("seat_races", {}) as Dictionary).get(1, [])) \
			== str(["god", "dark", "undead", "human"])
		detail.append("seat_races=%s" % races_ok)
		var pet_ok := str((room.get("seat_pets", {}) as Dictionary).get(1, "")) == "pet_cat"
		detail.append("seat_pet=%s" % pet_ok)
		if not (hp_ok and phase_ok and peers_cleared and reserved_ok and rebased and races_ok and pet_ok):
			ok = false

	if not found_prep:
		detail.append("prep room MISSING")
		ok = false

	detail.append("tokens=%d" % NetworkService._token_seat.size())
	if NetworkService._token_seat.size() < 2:
		ok = false

	print("[PERSIST] %s | %s" % ["PASS" if ok else "FAIL", " ".join(detail)])
	get_tree().quit(0 if ok else 3)

func _arg(key: String, fallback: String) -> String:
	var prefix := key + "="
	# `--` 之后的参数**只**出现在 get_cmdline_user_args()。只查 get_cmdline_args()
	# 会让 --persist-phase 被静默忽略，两阶段退化成每次都跑 save —— load 那一半
	# （也就是"文件真的活过进程死亡"这个唯一的论点）从来没被执行过。
	for source in [OS.get_cmdline_user_args(), OS.get_cmdline_args()]:
		for a in source:
			if str(a).begins_with(prefix):
				return str(a).substr(prefix.length())
	return fallback
