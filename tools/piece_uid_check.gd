extends Node

# 棋子唯一标识（uid）的血统前提。
#
# 为什么要有这一条：服务端要认「这枚四星是不是由一次成功的升级石交易产生的」。
# 只凭棋盘快照里自报的 star=4 认不出伪造 —— 设计文档
# 《萝卜采集与升级石系统设计实施方案》:246 点名了这个洞。认得出的前提是每一枚
# 棋子有一个稳定、唯一、能跨存档与网络往返的标识。
#
# 这条检查守的全是**前提**，不是四星规则本身（那在 carrot_online_check）。
# 前提塌了的表现全是静默的：uid 撞号 -> 别人的血统被复用；存档丢 uid ->
# 重开游戏后合法四星被判伪造；快照不带 uid -> 服务端永远认不出任何一枚。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/piece_uid_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "piece_uid"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_mint_is_unique()
	_case_snapshot_version_bumped()
	_case_snapshot_carries_uid()
	_case_snapshot_rejects_duplicate_uid()
	_case_save_roundtrip_preserves_uid()
	_case_legacy_save_backfills_uid()
	_case_uid_counter_survives_reload()
	_case_uid_unique_across_runs()
	await _case_merge_keeps_keeper_uid()
	_h.finish(get_tree())


# --- 1. 铸造唯一 ---------------------------------------------------------------
func _case_mint_is_unique() -> void:
	GameState.reset_run()
	var seen := {}
	for _i in 1000:
		var uid := GameState.mint_piece_uid()
		if uid.is_empty():
			_h.fail("mint_empty", "mint_piece_uid() 返回了空串")
			return
		if seen.has(uid):
			_h.fail("mint_collision", "同一局内铸出了重复 uid：%s" % uid)
			return
		seen[uid] = true
	_h.item(1000)


# --- 2. 加了字段就必须顶快照版本 -------------------------------------------------
# 不顶的话，旧客户端的提交会被按新语义解析成「所有棋子 uid 为空」，
# 而空 uid 在血统核验里等于「没有血统」—— 整个座位的四星会被判伪造。
func _case_snapshot_version_bumped() -> void:
	_h.expect(NetProtocol.SNAPSHOT_VERSION >= 3, "snapshot_version_stale",
		"棋盘快照加了 uid 字段，SNAPSHOT_VERSION 却还是 %d" % NetProtocol.SNAPSHOT_VERSION)


# --- 3. 快照必须带 uid，且能过校验 -----------------------------------------------
func _case_snapshot_carries_uid() -> void:
	var d := _first_unit()
	if d.is_empty():
		return
	GameState.reset_run()
	var uid := GameState.mint_piece_uid()
	GameState.board_slots[0] = {"id": str(d.get("id", "")), "uid": uid, "star": 1, "def": d}
	var submission := NetProtocol.team_board_submission(GameState.board_slots)
	var board: Array = submission.get("board", [])
	if not _h.expect(board.size() == 1, "snapshot_board_empty", "快照里没有棋子"):
		return
	var sent_uid := str((board[0] as Dictionary).get("uid", ""))
	_h.expect(sent_uid == uid, "snapshot_uid_missing",
		"提交的快照里 uid 是 %s，应为 %s —— 服务端拿不到 uid 就认不出任何一枚四星"
			% [_q(sent_uid), uid])

	var validated := NetProtocol.validate_team_snapshot(submission, GameState.round_index)
	if not _h.expect(bool(validated.get("ok", false)), "snapshot_rejected",
			"带 uid 的合法快照被校验拒收：%s" % str(validated.get("reason", "?"))):
		return
	var clean_board: Array = (validated.get("snapshot", {}) as Dictionary).get("board", [])
	var cell: Variant = clean_board[0] if clean_board.size() > 0 else null
	if not _h.expect(typeof(cell) == TYPE_DICTIONARY, "validated_board_empty", "校验后 0 号格空了"):
		return
	_h.expect(str((cell as Dictionary).get("uid", "")) == uid, "validated_uid_dropped",
		"校验把 uid 洗掉了 —— 服务端拿到的棋盘就没有血统可查")


# --- 4. 同一次提交内 uid 不许重复 -------------------------------------------------
# 允许重复 = 一枚合法四星的 uid 能被复制到整块棋盘上。
func _case_snapshot_rejects_duplicate_uid() -> void:
	var d := _first_unit()
	if d.is_empty():
		return
	GameState.reset_run()
	var unit_id := str(d.get("id", ""))
	var submission := {
		"version": NetProtocol.SNAPSHOT_VERSION,
		"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
		"round": GameState.round_index,
		"gold": 0,
		"board": [
			{"slot": 0, "id": unit_id, "uid": "dup-1", "star": 1, "race_relations": {}},
			{"slot": 1, "id": unit_id, "uid": "dup-1", "star": 1, "race_relations": {}},
		],
		"mercenaries": [],
		"treasures": [],
		"syn": {},
		"pet": {},
	}
	var validated := NetProtocol.validate_team_snapshot(submission, GameState.round_index)
	_h.expect(not bool(validated.get("ok", true)), "duplicate_uid_accepted",
		"两格用同一个 uid 的提交被接受了 —— 一枚合法四星的血统能被复制到整块棋盘")
	_h.expect(str(validated.get("reason", "")).begins_with("duplicate_uid"),
		"duplicate_uid_wrong_reason",
		"拒绝理由是 %s，应为 duplicate_uid —— 被别的判据顺带挡下不算数"
			% str(validated.get("reason", "?")))


# --- 5. 存档往返 ---------------------------------------------------------------
func _case_save_roundtrip_preserves_uid() -> void:
	var d := _first_unit()
	if d.is_empty():
		return
	GameState.reset_run()
	var uid := GameState.mint_piece_uid()
	GameState.board_slots[0] = {"id": str(d.get("id", "")), "uid": uid, "star": 1, "def": d}
	if not _save_and_reload():
		return
	var cell: Variant = GameState.board_slots[0]
	if not _h.expect(typeof(cell) == TYPE_DICTIONARY, "save_lost_piece", "存读一轮后 0 号格空了"):
		return
	var back := str((cell as Dictionary).get("uid", ""))
	_h.expect(back == uid, "save_lost_uid",
		"存读一轮后 uid 从 %s 变成 %s —— 重开游戏合法四星就会被判伪造" % [uid, _q(back)])


# --- 6. 老存档补发 uid ----------------------------------------------------------
func _case_legacy_save_backfills_uid() -> void:
	var d := _first_unit()
	if d.is_empty():
		return
	GameState.reset_run()
	GameState.board_slots[0] = {"id": str(d.get("id", "")), "star": 1, "def": d}
	GameState.bench_slots[0] = {"id": str(d.get("id", "")), "star": 1, "def": d}
	if not _save_stripped():
		return
	if not _h.expect(SaveManager.load_run(), "legacy_read_failed", "去掉 uid 的存档读不回来"):
		return
	var uids := {}
	for slots in [GameState.board_slots, GameState.bench_slots]:
		for cell in slots:
			if typeof(cell) != TYPE_DICTIONARY:
				continue
			var uid := str((cell as Dictionary).get("uid", ""))
			if uid.is_empty():
				_h.fail("legacy_uid_not_backfilled",
					"老存档读回来之后还有棋子没有 uid —— 那一枚在服务端永远没有血统")
				return
			if uids.has(uid):
				_h.fail("legacy_uid_collision", "补发出了重复 uid：%s" % uid)
				return
			uids[uid] = true
	_h.expect(uids.size() == 2, "legacy_backfill_count",
		"补发后应有 2 枚带 uid 的棋子，实际 %d" % uids.size())


# --- 7a. 计数器要跨读档 ---------------------------------------------------------
# 读档后继续铸的 uid 不能和档里已有的撞号。
func _case_uid_counter_survives_reload() -> void:
	var d := _first_unit()
	if d.is_empty():
		return
	GameState.reset_run()
	var existing := {}
	for i in 3:
		var uid := GameState.mint_piece_uid()
		existing[uid] = true
		GameState.bench_slots[i] = {"id": str(d.get("id", "")), "uid": uid, "star": 1, "def": d}
	if not _save_and_reload():
		return
	for _i in 10:
		var fresh := GameState.mint_piece_uid()
		if existing.has(fresh):
			_h.fail("uid_collision_after_reload",
				"读档后新铸的 uid %s 与存档里已有的撞号 —— 计数器或 run_nonce 没跟着存档走" % fresh)
			return
		_h.item()


# --- 7b. 跨局不许复用 uid（run_nonce 的存在理由）---------------------------------
# 服务端的四星血统记录（prep.four_star_uids）活在**房间**里，而 reset_run() 会把
# 棋子计数器打回 1。只用自增计数器时，新一局的第 5 枚棋子拿到的 uid 与上一局的
# 第 5 枚一模一样 —— 上一局那枚如果升过四星，新棋子会直接继承它的血统。
#
# ⚠️ 这条用例的第一版是**假绿**：它测的是「读档后继续铸不撞号」，而 next_piece_uid
# 本来就跟着存档走，所以把 run_nonce 拿掉它照样通过。撞号只发生在**跨局**，
# 用例必须跨 reset_run() 才测得到。
func _case_uid_unique_across_runs() -> void:
	var first := {}
	GameState.reset_run()
	for _i in 20:
		first[GameState.mint_piece_uid()] = true
	GameState.reset_run()
	for _i in 20:
		var uid := GameState.mint_piece_uid()
		if first.has(uid):
			_h.fail("uid_reused_across_runs",
				"新一局铸出了上一局用过的 uid %s —— 服务端按 uid 记四星血统，" % uid
				+ "这等于新棋子白继承上一局那枚四星的血统")
			return
		_h.item()


# --- 8. 合成：keeper 的 uid 存活，被吞的消失 --------------------------------------
# 服务端的血统记录是按 uid 记的。合成时如果换了新 uid（或留错了那一枚），
# 一枚合法四星在合成之后就变成「没有血统」，下一次提交棋盘会被判伪造。
func _case_merge_keeps_keeper_uid() -> void:
	var d := _first_unit()
	if d.is_empty():
		return
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "PrepScreen.tscn 无法加载"):
		return
	var was_active := NetworkService.team_active
	var was_host := NetworkService.is_host
	GameState.reset_run()
	NetworkService.team_active = false
	NetworkService.is_host = false
	var screen: Node = packed.instantiate()
	add_child(screen)
	await get_tree().process_frame

	var need := GameState.copies_to_upgrade(1)
	var minted := {}
	for i in need:
		var uid := GameState.mint_piece_uid()
		minted[uid] = true
		GameState.bench_slots[i] = {"id": str(d.get("id", "")), "uid": uid, "star": 1, "def": d}
	screen.call("_auto_combine_all")

	var survivors: Array = []
	for slots in [GameState.board_slots, GameState.bench_slots]:
		for cell in slots:
			if typeof(cell) == TYPE_DICTIONARY:
				survivors.append(cell)
	if _h.expect(survivors.size() == 1, "merge_survivor_count",
			"%d 个一星合成后应只剩 1 枚，实际 %d" % [need, survivors.size()]):
		var kept := str((survivors[0] as Dictionary).get("uid", ""))
		_h.expect(minted.has(kept), "merge_minted_new_uid",
			"合成后存活的那一枚 uid 是 %s，不在合成前的那几枚里 —— 血统断了" % _q(kept))
		_h.expect(int((survivors[0] as Dictionary).get("star", 1)) == 2, "merge_star_wrong",
			"合成后星级是 %d，应为 2" % int((survivors[0] as Dictionary).get("star", 1)))

	screen.queue_free()
	await get_tree().process_frame
	NetworkService.team_active = was_active
	NetworkService.is_host = was_host


# --- 工具 ---------------------------------------------------------------------

func _q(text: String) -> String:
	return "「%s」" % text


func _first_unit() -> Dictionary:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	if not _h.expect(not units.is_empty(), "units_empty", "race_units 表为空"):
		return {}
	return units[0]


# save_run() 是去抖的，检查里必须显式落盘，否则会读到上一次的文件
# （carrot_economy_check.gd 里记过这条）。
func _save_and_reload() -> bool:
	SaveManager.save_run()
	SaveManager._flush_pending_save()
	return _h.expect(SaveManager.load_run(), "save_read_failed", "存档写入后读不回来")


# 造一份「老存档」：正常落盘之后把 uid 键和两个计数器标量从 JSON 里删掉。
func _save_stripped() -> bool:
	SaveManager.save_run()
	SaveManager._flush_pending_save()
	var text := FileAccess.get_file_as_string(SaveManager.SAVE_PATH)
	var parsed: Variant = JSON.parse_string(text)
	if not _h.expect(typeof(parsed) == TYPE_DICTIONARY, "save_parse_failed", "存档不是 JSON 对象"):
		return false
	var payload: Dictionary = parsed
	payload.erase("run_nonce")
	payload.erase("next_piece_uid")
	for key in ["board_slots", "bench_slots", "mercenary_slots"]:
		var slots: Variant = payload.get(key, [])
		if typeof(slots) != TYPE_ARRAY:
			continue
		for cell in (slots as Array):
			if typeof(cell) == TYPE_DICTIONARY:
				(cell as Dictionary).erase("uid")
	var f := FileAccess.open(SaveManager.SAVE_PATH, FileAccess.WRITE)
	if not _h.expect(f != null, "save_write_failed", "写不了存档文件"):
		return false
	f.store_string(JSON.stringify(payload))
	f.close()
	return true
