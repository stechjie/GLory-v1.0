extends Node

const SAVE_PATH := "user://glory_beta_004.save"
const RECONNECT_PATH := "user://glory_reconnect.json"
const PUBLIC_TOKEN_PATH := "user://glory_public_token.txt"
const SAVE_DEBOUNCE_SEC := 0.5

var _save_pending := false

# --- 断线重连凭证（token + 服务器地址），app 被杀重开后凭它恢复对局 ---
func save_reconnect(token: String, address: String) -> void:
	var f := FileAccess.open(RECONNECT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"token": token, "address": address}))

func load_reconnect() -> Dictionary:
	if not FileAccess.file_exists(RECONNECT_PATH):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(RECONNECT_PATH))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func clear_reconnect() -> void:
	if FileAccess.file_exists(RECONNECT_PATH):
		DirAccess.remove_absolute(RECONNECT_PATH)

func save_public_token(token_id: String) -> void:
	var f := FileAccess.open(PUBLIC_TOKEN_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(token_id.strip_edges().to_upper())

func load_public_token() -> String:
	if not FileAccess.file_exists(PUBLIC_TOKEN_PATH):
		return ""
	return FileAccess.get_file_as_string(PUBLIC_TOKEN_PATH).strip_edges().to_upper()

# 合并短时间内的多次存档请求（拖拽/连买会连续触发 save_run），
# 真正的磁盘写入最多每 SAVE_DEBOUNCE_SEC 一次。
func save_run() -> void:
	if GameState.tutorial_mode:
		return
	if _save_pending:
		return
	_save_pending = true
	get_tree().create_timer(SAVE_DEBOUNCE_SEC).timeout.connect(_flush_pending_save)

# 应用被切后台/关闭时必须立即落盘，否则去抖会在进程被杀时丢进度。
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_APPLICATION_FOCUS_OUT:
			_flush_pending_save()

func _flush_pending_save() -> void:
	if not _save_pending:
		return
	_save_pending = false
	_write_now()

func _write_now() -> void:
	if GameState.tutorial_mode:
		return
	var payload := {
		"round_index": GameState.round_index,
		"player_formation_hp": GameState.player_formation_hp,
		"enemy_formation_hp": GameState.enemy_formation_hp,
		"gold": GameState.gold,
		"board_slots": GameState.board_slots,
		"bench_slots": GameState.bench_slots,
		"mercenary_slots": GameState.mercenary_slots,
		"shop_offers": GameState.shop_offers,
		"shop_sold": GameState.shop_sold,
		"shop_refresh_uses_this_round": GameState.shop_refresh_uses_this_round,
		"owned_treasures": GameState.owned_treasures,
		"claimed_treasure_rounds": GameState.claimed_treasure_rounds,
		"pending_treasure": GameState.pending_treasure,
		"pve_completed": GameState.pve_completed,
		"boss_completed": GameState.boss_completed,
		"loss_streak": GameState.loss_streak,
		"used_boss_ids": GameState.used_boss_ids,
		"golden_altar_uses": GameState.golden_altar_uses,
		"gamble_used": GameState.gamble_used,
		# 组队局字段（重连恢复用；team_mode 本身由 Main 显式控制，不入档）
		"team_hp": GameState.team_hp,
		"enemy_team_hp": GameState.enemy_team_hp,
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload))

func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)

func load_run() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	GameState.round_index = int(parsed.get("round_index", 1))
	GameState.player_formation_hp = int(parsed.get("player_formation_hp", GameState.START_FORMATION_HP))
	GameState.enemy_formation_hp = int(parsed.get("enemy_formation_hp", GameState.START_FORMATION_HP))
	GameState.gold = int(parsed.get("gold", GameState.START_GOLD))
	GameState.board_slots = parsed.get("board_slots", [])
	GameState.bench_slots = parsed.get("bench_slots", [])
	GameState.mercenary_slots = parsed.get("mercenary_slots", [])
	GameState.shop_offers = parsed.get("shop_offers", [])
	GameState.shop_sold = parsed.get("shop_sold", [])
	GameState.shop_refresh_uses_this_round = int(parsed.get("shop_refresh_uses_this_round", 0))
	GameState.owned_treasures.assign(parsed.get("owned_treasures", []))
	GameState.claimed_treasure_rounds.clear()
	for round_value in parsed.get("claimed_treasure_rounds", []):
		GameState.claimed_treasure_rounds.append(int(round_value))
	GameState.pending_treasure = parsed.get("pending_treasure", {"active": false, "round": 0, "candidates": [], "refresh_index": 0})
	GameState.pve_completed = int(parsed.get("pve_completed", 0))
	GameState.boss_completed = int(parsed.get("boss_completed", 0))
	GameState.loss_streak = int(parsed.get("loss_streak", 0))
	GameState.used_boss_ids.assign(parsed.get("used_boss_ids", []))
	GameState.golden_altar_uses = int(parsed.get("golden_altar_uses", 0))
	GameState.gamble_used = bool(parsed.get("gamble_used", false))
	GameState.team_hp = int(parsed.get("team_hp", GameState.team_hp))
	GameState.enemy_team_hp = int(parsed.get("enemy_team_hp", GameState.enemy_team_hp))
	_normalize_arrays()
	return true

func new_run() -> void:
	GameState.reset_run()
	save_run()

func _normalize_arrays() -> void:
	GameState.board_slots = _normalize_board_slots(GameState.board_slots)
	GameState.bench_slots.resize(GameState.BENCH_SLOTS)
	GameState.mercenary_slots.resize(GameState.MERCENARY_SLOTS)
	GameState.shop_offers.resize(GameState.SHOP_UNIT_SLOTS)
	GameState.shop_sold.resize(GameState.SHOP_UNIT_SLOTS)

func _normalize_board_slots(raw_slots: Array) -> Array:
	var normalized: Array = []
	normalized.resize(GameConstants.CELL_COUNT)
	normalized.fill(null)
	var overflow: Array = []
	for index in raw_slots.size():
		var cell = raw_slots[index]
		if cell == null:
			continue
		if index < GameConstants.CELL_COUNT and normalized[index] == null:
			normalized[index] = cell
		else:
			overflow.append(cell)
	for cell in overflow:
		var empty_index := normalized.find(null)
		if empty_index < 0:
			break
		normalized[empty_index] = cell
	return normalized
