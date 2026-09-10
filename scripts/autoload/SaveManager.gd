extends Node

const CarrotEconomy = preload("res://scripts/economy/CarrotEconomy.gd")
const SAVE_PATH := "user://glory_beta_004.save"
const RECONNECT_PATH := "user://glory_reconnect.json"
const PUBLIC_TOKEN_PATH := "user://glory_public_token.txt"
# 教程断点（V2 P1-08）。与主存档分开，见下面 save_tutorial() 上的说明。
const TUTORIAL_PATH := "user://glory_tutorial.json"
# 账号凭证（refresh token）。**单独一个文件**，不进 profile.json ——
# 那个文件里全是可以随便看的展示设置，凭证不该跟着它一起被读写、被截图、被贴出来。
# 详见 save_account_credentials()。
const ACCOUNT_PATH := "user://glory_account.json"
const SAVE_DEBOUNCE_SEC := 0.5

var _save_pending := false

# --- 原子写（C21）------------------------------------------------------------
# `FileAccess.open(path, WRITE)` 会先把目标文件截断成 0 字节再写。进程在这中间被杀
# （手机锁屏后被系统回收、崩溃、玩家强退）就留下空文件或半截 JSON，而读取方拿到坏
# 内容只能当"没有存档"——一次本来可以恢复的断线因此升级成永久丢档。
# 顺序：写临时文件 → flush → 回读校验 → 旧文件转 .bak → 临时文件转正。
# 任何一步失败都保留原文件不动，绝不用半成品覆盖一份好的存档。
const TMP_SUFFIX := ".tmp"
const BAK_SUFFIX := ".bak"

func _atomic_write(path: String, content: String) -> bool:
	var tmp := path + TMP_SUFFIX
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("[SAVE] cannot open temp file: %s" % tmp)
		return false
	f.store_string(content)
	f.flush()
	f = null   # 句柄归零即关闭落盘
	# 回读校验：确认完整落地后才碰正式文件
	if FileAccess.get_file_as_string(tmp) != content:
		push_warning("[SAVE] temp verify failed, keeping previous file: %s" % path)
		DirAccess.remove_absolute(tmp)
		return false
	var bak := path + BAK_SUFFIX
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(bak)
		DirAccess.rename_absolute(path, bak)
	if DirAccess.rename_absolute(tmp, path) != OK:
		# 转正失败：把上一份换回来，宁可回退一步也不留下空档
		if FileAccess.file_exists(bak):
			DirAccess.rename_absolute(bak, path)
		push_warning("[SAVE] atomic rename failed: %s" % path)
		return false
	return true

# 读取时先试正式文件，坏了再试 .bak。返回 "" 表示两份都不可用。
func _read_with_fallback(path: String) -> String:
	for candidate in [path, path + BAK_SUFFIX]:
		if not FileAccess.file_exists(candidate):
			continue
		var text := FileAccess.get_file_as_string(candidate)
		if not text.strip_edges().is_empty():
			return text
	return ""

# 二进制版原子写（服务器房间快照用）。
# 房间数据里有大量 int，走 JSON 会在 parse 时全变成 float，读回来每个字段都得手动
# int() 一遍，漏一个就是静默的类型错误。`var_to_bytes` 保留类型，也更紧凑。
func atomic_write_bytes(path: String, data: PackedByteArray) -> bool:
	var tmp := path + TMP_SUFFIX
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("[SAVE] cannot open temp file: %s" % tmp)
		return false
	f.store_buffer(data)
	f.flush()
	f = null
	if FileAccess.get_file_as_bytes(tmp) != data:
		push_warning("[SAVE] temp verify failed: %s" % path)
		DirAccess.remove_absolute(tmp)
		return false
	var bak := path + BAK_SUFFIX
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(bak)
		DirAccess.rename_absolute(path, bak)
	if DirAccess.rename_absolute(tmp, path) != OK:
		if FileAccess.file_exists(bak):
			DirAccess.rename_absolute(bak, path)
		push_warning("[SAVE] atomic rename failed: %s" % path)
		return false
	return true

func read_bytes_with_fallback(path: String) -> PackedByteArray:
	for candidate in [path, path + BAK_SUFFIX]:
		if not FileAccess.file_exists(candidate):
			continue
		var data := FileAccess.get_file_as_bytes(candidate)
		if not data.is_empty():
			return data
	return PackedByteArray()

func remove_all_variants(path: String) -> void:
	_remove_all_variants(path)

func _remove_all_variants(path: String) -> void:
	for candidate in [path, path + BAK_SUFFIX, path + TMP_SUFFIX]:
		if FileAccess.file_exists(candidate):
			DirAccess.remove_absolute(candidate)

# --- 断线重连凭证（token + 服务器地址），app 被杀重开后凭它恢复对局 ---
# port 必须一起存（多进程）。座位 token 是**进程内**的字典，连错进程就等于凭证失效。
# 此前只存 address，app 重开时端口被填成 DEFAULT_PORT —— 单进程时碰巧对，
# 多进程时是 (N-1)/N 的概率连错。
func save_reconnect(token: String, address: String, port: int = NetworkConfig.SERVER_PORT) -> void:
	var rc := {"token": token, "address": address, "port": port}
	var previous := load_reconnect()
	if str(previous.get("token", "")) == token and str(previous.get("address", "")) == address \
			and int(previous.get("port", NetworkConfig.SERVER_PORT)) == port and bool(previous.get("match_started", false)):
		rc["match_started"] = true
	# A late credential refresh must not undo the user's leave intent.
	if str(previous.get("token", "")) == token and str(previous.get("address", "")) == address \
			and int(previous.get("port", NetworkConfig.SERVER_PORT)) == port \
			and not str(previous.get("pending_leave", "")).is_empty():
		rc["pending_leave"] = previous["pending_leave"]
	_atomic_write(RECONNECT_PATH, JSON.stringify(rc))

func mark_match_started() -> void:
	var rc := load_reconnect()
	if rc.is_empty() or bool(rc.get("match_started", false)):
		return
	rc["match_started"] = true
	rc.erase("pending_leave")
	_atomic_write(RECONNECT_PATH, JSON.stringify(rc))

# 标记"这一局是玩家主动退的，还没拿到服务端回执"（状态信封 E3 / R1）。
# 落盘的意义：进程在发出退出意图后被杀，下次启动能凭它知道**不要提示重连**，
# 并用同一个 request_id 重发 —— 服务端按幂等重放同一份回执。
func mark_pending_leave(request_id: String) -> void:
	var rc := load_reconnect()
	if rc.is_empty():
		return
	rc["pending_leave"] = request_id
	_atomic_write(RECONNECT_PATH, JSON.stringify(rc))

func has_pending_leave() -> bool:
	return not str(load_reconnect().get("pending_leave", "")).is_empty()

func load_reconnect() -> Dictionary:
	var text := _read_with_fallback(RECONNECT_PATH)
	if text.is_empty():
		return {}
	var parsed = JSON.parse_string(text)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

# Keep raw credentials for the leave receipt, but never offer them for resuming.
func load_resumable_reconnect() -> Dictionary:
	var rc := load_reconnect()
	if not str(rc.get("pending_leave", "")).is_empty() \
			or str(rc.get("token", "")).is_empty() \
			or str(rc.get("address", "")).is_empty():
		return {}
	return rc

func clear_reconnect() -> void:
	# 凭证作废必须连 .bak/.tmp 一起清，否则下次启动会从兜底文件里把死 token 读回来。
	_remove_all_variants(RECONNECT_PATH)

# --- 账号凭证（refresh token）-------------------------------------------------
#
# 与断线重连凭证是两回事：那个是「这一局的座位」，一局一换；这个是「我是谁」，
# 跨设备生命周期长期有效。
#
# **只存 refresh token，不存 access token。** access token 一小时就过期，
# 存它没有收益，却多一处会泄漏的地方 —— AccountManager 只把它放在内存里。
#
# ⚠️ Supabase 默认**轮换** refresh token：每次刷新返回的那个和传进去的不同。
# 必须存回新的，否则下次刷新失败、玩家被踢回匿名注册、进度看起来就没了。
#
# 复用同一套原子写（C21）。凭证写坏的后果和存档写坏一样严重：
# 半截 JSON 读不出来 = 认不回自己的账号。
func save_account_credentials(refresh_token: String, player_id: String) -> void:
	_atomic_write(ACCOUNT_PATH, JSON.stringify({
		"refresh_token": refresh_token,
		# 只作缓存，方便离线时先把昵称显示出来。**身份以服务器返回的为准** ——
		# 本地这份被改了也没用，服务器只认令牌解出来的 auth_uid。
		"player_id": player_id,
	}))

func load_account_credentials() -> Dictionary:
	var text := _read_with_fallback(ACCOUNT_PATH)
	if text.is_empty():
		return {}
	var parsed = JSON.parse_string(text)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func clear_account_credentials() -> void:
	# 同 clear_reconnect：连 .bak/.tmp 一起清。留着兜底文件会让下次启动
	# 拿一个已经被服务器吊销的 refresh token 去刷新，然后又失败一次。
	_remove_all_variants(ACCOUNT_PATH)

# --- 教程断点（V2 P1-08）------------------------------------------------------
#
# 走**独立文件**而不是主存档：`_write_now()` 第一行就是 `if GameState.tutorial_mode: return`，
# 教程期间主存档整个被跳过 —— 那正是「Back 退出后回到语言页、教程从头开始」的根因。
# 不去动那条早退，是因为主存档参与 replay / final-state SHA，
# 而 V2 收尾明确要求这些字节不变。
#
# 复用同一套原子写：写临时文件 → flush → 回读校验 → 旧文件转 .bak → 转正。
# 清除时连 .bak/.tmp 一起删，否则下次启动会从兜底文件里读回一个死断点。
func save_tutorial(payload: Dictionary) -> void:
	_atomic_write(TUTORIAL_PATH, JSON.stringify(payload))


func load_tutorial() -> Dictionary:
	var text := _read_with_fallback(TUTORIAL_PATH)
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	return parsed as Dictionary if parsed is Dictionary else {}


func has_tutorial() -> bool:
	return not _read_with_fallback(TUTORIAL_PATH).strip_edges().is_empty()


func clear_tutorial() -> void:
	_remove_all_variants(TUTORIAL_PATH)


func save_public_token(token_id: String) -> void:
	_atomic_write(PUBLIC_TOKEN_PATH, token_id.strip_edges().to_upper())

func load_public_token() -> String:
	return _read_with_fallback(PUBLIC_TOKEN_PATH).strip_edges().to_upper()

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
		"carrots": GameState.carrots,
		"harvest_tech_level": GameState.harvest_tech_level,
		"merc_carrots_spent_total": GameState.merc_carrots_spent_total,
		"last_harvest_round": GameState.last_harvest_round,
		"stone_draw_used_round": GameState.stone_draw_used_round,
		"team_upgrade_stones": GameState.team_upgrade_stones,
		# 棋子的 uid 键随 board_slots/bench_slots 整块序列化，这里只需要存计数器本身。
		"run_nonce": GameState.run_nonce,
		"next_piece_uid": GameState.next_piece_uid,
		"board_slots": GameState.board_slots,
		"bench_slots": GameState.bench_slots,
		"mercenary_slots": GameState.mercenary_slots,
		"shop_offer_id": GameState.shop_offer_id,
		"shop_offers": GameState.shop_offers,
		"shop_sold": GameState.shop_sold,
		"shop_refresh_uses_this_round": GameState.shop_refresh_uses_this_round,
		"owned_treasures": GameState.owned_treasures,
		"claimed_treasure_rounds": GameState.claimed_treasure_rounds,
		"pending_treasure": GameState.pending_treasure,
		"pve_completed": GameState.pve_completed,
		"boss_completed": GameState.boss_completed,
		"loss_streak": GameState.loss_streak,
		"golden_altar_uses": GameState.golden_altar_uses,
		"gamble_used": GameState.gamble_used,
		# 组队局字段（重连恢复用；team_mode 本身由 Main 显式控制，不入档）
		"team_hp": GameState.team_hp,
		"enemy_team_hp": GameState.enemy_team_hp,
	}
	_atomic_write(SAVE_PATH, JSON.stringify(payload))

func has_save() -> bool:
	return not _read_with_fallback(SAVE_PATH).is_empty()

func load_run() -> bool:
	var text := _read_with_fallback(SAVE_PATH)
	if text.is_empty():
		return false
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	GameState.round_index = int(parsed.get("round_index", 1))
	GameState.player_formation_hp = int(parsed.get("player_formation_hp", GameState.START_FORMATION_HP))
	GameState.enemy_formation_hp = int(parsed.get("enemy_formation_hp", GameState.START_FORMATION_HP))
	GameState.gold = int(parsed.get("gold", GameState.START_GOLD))
	GameState.carrots = maxi(0, int(parsed.get("carrots", 0)))
	GameState.harvest_tech_level = clampi(int(parsed.get("harvest_tech_level", 0)), 0, CarrotEconomy.MAX_HARVEST_TECH_LEVEL)
	GameState.merc_carrots_spent_total = maxi(0, int(parsed.get("merc_carrots_spent_total", 0)))
	# Old saves have no carrot round marker. Treat the saved round as already
	# harvested so migration cannot grant a retroactive first-round payout.
	GameState.last_harvest_round = int(parsed.get("last_harvest_round", GameState.round_index))
	GameState.stone_draw_used_round = int(parsed.get("stone_draw_used_round", -1))
	GameState.team_upgrade_stones = CarrotEconomy.empty_stones()
	var saved_stones: Variant = parsed.get("team_upgrade_stones", {})
	if typeof(saved_stones) == TYPE_DICTIONARY:
		for stone_type in CarrotEconomy.STONE_TYPES:
			GameState.team_upgrade_stones[stone_type] = maxi(0, int((saved_stones as Dictionary).get(stone_type, 0)))
	GameState.run_nonce = str(parsed.get("run_nonce", ""))
	GameState.next_piece_uid = maxi(1, int(parsed.get("next_piece_uid", 1)))
	GameState.board_slots = parsed.get("board_slots", [])
	GameState.bench_slots = parsed.get("bench_slots", [])
	GameState.mercenary_slots = parsed.get("mercenary_slots", [])
	GameState.shop_offer_id = str(parsed.get("shop_offer_id", ""))
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
	_normalize_unit_display_names()
	_backfill_piece_uids()

# Unit rows are saved by value, so renamed units in existing saves keep their old
# English name unless migrated. Touch presentation fields only: replacing `def`
# would destroy live four-star/skill overrides, uid lineage and king growth.
func _normalize_unit_display_names() -> void:
	DataRegistry.ensure_loaded()
	for slots in [GameState.board_slots, GameState.bench_slots, GameState.mercenary_slots]:
		for raw_cell in slots:
			if typeof(raw_cell) != TYPE_DICTIONARY:
				continue
			var cell := raw_cell as Dictionary
			var raw_def: Variant = cell.get("def", {})
			if typeof(raw_def) == TYPE_DICTIONARY:
				DataRegistry.canonicalize_unit_display_names(raw_def as Dictionary)
	for raw_offer in GameState.shop_offers:
		if typeof(raw_offer) == TYPE_DICTIONARY:
			DataRegistry.canonicalize_unit_display_names(raw_offer as Dictionary)

# 老存档里的棋子没有 uid。现铸一个 run_nonce 并给每一枚补发，然后把计数器推到
# 已用序号之上 —— 不推的话下一次 mint 会和刚补发的撞号，而撞号在服务端表现为
# 「别人的四星血统被我复用」。
#
# 补发出来的 uid 在服务端没有任何血统记录，这是**对的**：老档里不可能有合法四星
# （四星只能靠升级石，而升级石是这一批才上线的），补发的都是 1~3 星。
func _backfill_piece_uids() -> void:
	if GameState.run_nonce.is_empty():
		GameState.new_run_nonce()
	var highest := 0
	var missing: Array = []
	for slots in [GameState.board_slots, GameState.bench_slots, GameState.mercenary_slots]:
		for cell in slots:
			if typeof(cell) != TYPE_DICTIONARY:
				continue
			var uid := str((cell as Dictionary).get("uid", ""))
			if uid.is_empty():
				missing.append(cell)
				continue
			var parts := uid.rsplit("-", true, 1)
			if parts.size() == 2 and str(parts[1]).is_valid_int():
				highest = maxi(highest, int(parts[1]))
	GameState.next_piece_uid = maxi(GameState.next_piece_uid, highest + 1)
	for cell in missing:
		(cell as Dictionary)["uid"] = GameState.mint_piece_uid()

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
