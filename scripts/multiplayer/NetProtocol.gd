class_name NetProtocol
extends RefCounted

# v3: 每格新增 uid（棋子唯一标识）。服务端靠它认「这枚四星是不是由一次成功的
#     升级石交易产生的」—— 只凭自报的 star=4 认不出伪造（设计文档 §5）。
#     版本没跟着加字段一起顶，旧客户端的提交会被按新语义解析成「所有棋子 uid 为空」。
const SNAPSHOT_VERSION := 3
const BOARD_SIZE := GameConstants.CELL_COUNT

# --- 载荷硬上限 -------------------------------------------------------------
# 来路是网络：任何容器都必须在常数级步数内被拒，不能「先遍历完再判断大小」。
# 实测（tools/adversarial_client.tscn）：20 万 key 的 race_relations 曾让校验跑掉
# 451ms，而服务器是同步主循环——一个包就能冻住全服所有房间。
const MAX_SLOT_ENTRIES := 64          # board/mercenaries 提交条目数（正常 ≤ 16+8）
const MAX_TREASURE_ENTRIES := 64      # 宝物条目数（正常 ≤ MAX_OWNED）
const MAX_RELATION_KEYS := 16         # 单个单位的种族关系 key 数（规则表只有 4 种）
const MAX_ID_LENGTH := 64             # 任何 id 字符串长度

static func team_board_submission(board_slots: Array, mercenary_slots: Array = []) -> Dictionary:
	return {
		"version": SNAPSHOT_VERSION,
		"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
		"round": GameState.round_index,
		"gold": GameState.gold,
		"board": _minimal_slots(board_slots, false),
		"mercenaries": _minimal_slots(mercenary_slots, true),
		"treasures": _sanitize_treasure_ids(GameState.owned_treasures),
		"syn": SynergyService.current_player_flags(),
		"pet": _sanitize_pet_id(PlayerProfile.get_active()),
	}

static func board_snapshot(board_slots: Array, mercenary_slots: Array = []) -> Dictionary:
	# 3v3: carry this player's treasures + synergy flags + active pet so the host can
	# apply them to THIS player's units only (per-owner effects, synced for everyone).
	return {"version": SNAPSHOT_VERSION, "round": GameState.round_index, "board": sanitize_board(board_slots), "mercenaries": sanitize_mercenaries(mercenary_slots), "treasures": GameState.owned_treasures.duplicate(), "syn": SynergyService.current_player_flags(), "pet": _sanitize_pet_id(PlayerProfile.get_active())}

static func validate_team_snapshot(snapshot: Variant, expected_round: int) -> Dictionary:
	if typeof(snapshot) != TYPE_DICTIONARY:
		return {"ok": false, "reason": "malformed_not_dictionary"}
	var d: Dictionary = snapshot
	# 快照 schema 版本必须校验（C22）。此前客户端发 version、服务端只发不验 ——
	# 协议演进时旧结构会被按新语义解析（同一个 key 换了含义就静默算错），
	# 而这类分歧不会报错，只会让战斗结果悄悄不对。
	if int(d.get("version", -1)) != SNAPSHOT_VERSION:
		return {"ok": false, "reason": "snapshot_version_mismatch"}
	if int(d.get("protocol", -1)) != NetworkConfig.NETWORK_PROTOCOL_VERSION:
		return {"ok": false, "reason": "protocol_mismatch"}
	var round_id := int(d.get("round", -1))
	if round_id != int(expected_round):
		return {"ok": false, "reason": "wrong_round:%d" % round_id}
	var board_result := _validate_slots(d.get("board", []), false, BOARD_SIZE)
	if not bool(board_result.get("ok", false)):
		return board_result
	var merc_result := _validate_slots(d.get("mercenaries", []), true, GameState.MERCENARY_SLOTS)
	if not bool(merc_result.get("ok", false)):
		return merc_result
	var treasures_result := _validate_treasures(d.get("treasures", []))
	if not bool(treasures_result.get("ok", false)):
		return treasures_result
	var clean_board: Array = board_result.get("slots", _empty_board())
	return {
		"ok": true,
		"snapshot": {
			"version": SNAPSHOT_VERSION,
			"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
			"round": round_id,
			"gold": clampi(int(d.get("gold", GameState.START_GOLD)), 0, 99999),
			"board": clean_board,
			"mercenaries": merc_result.get("slots", []),
			"treasures": treasures_result.get("treasures", []),
			# 客户端提交的 syn 一律丢弃，由服务端从已校验的棋盘重建。
			# syn 是纯派生量（种族计数 -> 羁绊标记），服务端有全部输入，没有任何理由
			# 信客户端。原先原样接受的后果实测可复现：提交
			# {"god_invulnerable_opening":true,"god_lifesteal":1e9} 即得无敌+秒杀，
			# 且服务器会把它算进权威 replay 广播给全房。
			"syn": rebuild_syn_from_board(clean_board),
			"pet": _sanitize_pet_id(d.get("pet", "")),
		}
	}

# 服务端权威羁绊：只数棋盘、不含佣兵栏——口径必须和客户端
# SynergyService.count_races_from_board 完全一致，否则服务端算出的战斗会和玩家
# 界面显示的羁绊对不上。
static func rebuild_syn_from_board(board_slots: Array) -> Dictionary:
	var counts := {"god": 0, "dark": 0, "undead": 0, "human": 0}
	for cell in board_slots:
		if typeof(cell) != TYPE_DICTIONARY:
			continue
		var race := str(((cell as Dictionary).get("def", {}) as Dictionary).get("race", ""))
		if counts.has(race):
			counts[race] += 1
	return SynergyService.flags_from_counts(counts)

static func normalize_snapshot(snapshot: Variant) -> Dictionary:
	if typeof(snapshot) == TYPE_DICTIONARY:
		var d: Dictionary = snapshot
		return {"version": int(d.get("version", SNAPSHOT_VERSION)), "round": int(d.get("round", 0)), "board": sanitize_board(d.get("board", [])), "mercenaries": sanitize_mercenaries(d.get("mercenaries", [])), "treasures": d.get("treasures", []), "syn": d.get("syn", {}), "pet": _sanitize_pet_id(d.get("pet", ""))}
	if typeof(snapshot) == TYPE_ARRAY:
		return {"version": SNAPSHOT_VERSION, "round": 0, "board": sanitize_board(snapshot), "mercenaries": [], "treasures": [], "syn": {}, "pet": ""}
	return {"version": SNAPSHOT_VERSION, "round": 0, "board": _empty_board(), "mercenaries": [], "treasures": [], "syn": {}, "pet": ""}

static func extract_treasures(snapshot: Variant) -> Array:
	return normalize_snapshot(snapshot).get("treasures", [])

static func extract_pet(snapshot: Variant) -> String:
	return str(normalize_snapshot(snapshot).get("pet", ""))

static func extract_syn(snapshot: Variant) -> Dictionary:
	return normalize_snapshot(snapshot).get("syn", {})

static func extract_board(snapshot: Variant) -> Array:
	return normalize_snapshot(snapshot).get("board", [])

static func extract_mercenaries(snapshot: Variant) -> Array:
	return normalize_snapshot(snapshot).get("mercenaries", [])

static func snapshot_has_units(snapshot: Variant) -> bool:
	for cell in extract_board(snapshot):
		if typeof(cell) == TYPE_DICTIONARY:
			return true
	for cell in extract_mercenaries(snapshot):
		if typeof(cell) == TYPE_DICTIONARY:
			return true
	return false

static func snapshot_round(snapshot: Variant) -> int:
	return int(normalize_snapshot(snapshot).get("round", 0))

static func sanitize_board(board_slots: Variant) -> Array:
	var out := _empty_board()
	if typeof(board_slots) != TYPE_ARRAY:
		return out
	var raw: Array = board_slots
	var overflow: Array = []
	for i in raw.size():
		var clean = sanitize_cell(raw[i])
		if clean == null:
			continue
		if i < BOARD_SIZE and out[i] == null:
			out[i] = clean
		else:
			overflow.append(clean)
	for clean in overflow:
		var empty_index := out.find(null)
		if empty_index < 0:
			break
		out[empty_index] = clean
	return out

static func sanitize_mercenaries(mercenary_slots: Variant) -> Array:
	var out := []
	if typeof(mercenary_slots) != TYPE_ARRAY:
		return out
	var raw: Array = mercenary_slots
	for cell in raw:
		var clean = sanitize_cell(cell)
		if clean != null and typeof(clean) == TYPE_DICTIONARY:
			clean.is_mercenary = true
			out.append(clean)
	return out

static func sanitize_cell(cell: Variant) -> Variant:
	if cell == null or typeof(cell) != TYPE_DICTIONARY:
		return null
	var c: Dictionary = cell
	var is_merc := bool(c.get("is_mercenary", false))
	var def := _trusted_def(str(c.get("id", "")), is_merc)
	if def.is_empty():
		def = _safe_def(c)
	if def.is_empty():
		return null
	return {
		"id": str(c.get("id", def.get("id", ""))),
		# uid 必须原样带过 —— 这条路径（normalize_snapshot / 本机房主）丢掉它，
		# 棋子过一次就没血统了，之后再提交会被服务端判成伪造四星。
		"uid": str(c.get("uid", "")),
		"star": clampi(int(c.get("star", 1)), 1, GameState.MAX_UNIT_STAR),
		"def": def,
		"is_mercenary": bool(c.get("is_mercenary", def.get("is_mercenary", false))),
		"race_relations": _safe_race_relations(c.get("race_relations", {})),
	}

static func _safe_race_relations(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	var raw: Dictionary = value
	# 先看总量再遍历：这里过去是无界的，20 万 key 会让服务器同步跑掉几百毫秒。
	# 超限直接整个丢弃（关系数据是派生量，丢了不影响结算正确性）。
	if raw.size() > MAX_RELATION_KEYS:
		return {}
	var out: Dictionary = {}
	for key_value in raw.keys():
		var key := str(key_value)
		if key.length() > MAX_ID_LENGTH:
			continue
		var state_value = raw.get(key_value, {})
		if typeof(state_value) != TYPE_DICTIONARY:
			continue
		var state: Dictionary = state_value
		out[key] = {
			"kind": str(state.get("kind", "")).substr(0, MAX_ID_LENGTH),
			"progress": clampi(int(state.get("progress", 0)), 0, RaceRelationService.MAX_PROGRESS),
			"active": bool(state.get("active", false)),
		}
	return out

static func _safe_def(cell: Dictionary) -> Dictionary:
	var id := str(cell.get("id", ""))
	if id.is_empty():
		return {}
	for table_name in ["race_units", "mercenaries"]:
		var key := "units" if table_name == "race_units" else "mercenaries"
		var rows: Array = DataRegistry.get_table(table_name).get(key, [])
		for row in rows:
			if str(row.get("id", "")) == id:
				return row.duplicate(true)
	return {}

static func _minimal_slots(slots: Variant, mercenary: bool) -> Array:
	var out := []
	if typeof(slots) != TYPE_ARRAY:
		return out
	var raw: Array = slots
	for i in raw.size():
		var cell = raw[i]
		if cell == null or typeof(cell) != TYPE_DICTIONARY:
			continue
		out.append({
			"slot": i,
			"id": str((cell as Dictionary).get("id", "")),
			"uid": str((cell as Dictionary).get("uid", "")),
			"star": clampi(int((cell as Dictionary).get("star", 1)), 1, GameState.MAX_UNIT_STAR),
			"is_mercenary": mercenary or bool((cell as Dictionary).get("is_mercenary", false)),
			"race_relations": _safe_race_relations((cell as Dictionary).get("race_relations", {})),
		})
	return out

static func _validate_slots(value: Variant, mercenary: bool, max_slots: int) -> Dictionary:
	var out := [] if mercenary else _empty_board()
	if typeof(value) != TYPE_ARRAY:
		return {"ok": false, "reason": "malformed_slots"}
	if (value as Array).size() > MAX_SLOT_ENTRIES:
		return {"ok": false, "reason": "too_many_slots"}
	var used := {}
	var used_uids := {}
	for item in (value as Array):
		if typeof(item) != TYPE_DICTIONARY:
			return {"ok": false, "reason": "malformed_slot_entry"}
		var d: Dictionary = item
		var slot := int(d.get("slot", -1))
		if slot < 0 or slot >= max_slots:
			return {"ok": false, "reason": "invalid_slot:%d" % slot}
		if used.has(slot):
			return {"ok": false, "reason": "duplicate_slot:%d" % slot}
		used[slot] = true
		var id := str(d.get("id", ""))
		var def := _trusted_def(id, mercenary)
		if def.is_empty():
			return {"ok": false, "reason": "invalid_unit_id:%s" % id}
		var star := int(d.get("star", 1))
		if star < 1 or star > GameState.MAX_UNIT_STAR:
			return {"ok": false, "reason": "invalid_star:%d" % star}
		# uid 在这里只做**语法**校验：长度、以及本次提交内不重复。
		#
		# 「这个 uid 有没有血统」是**语义**问题，必须留给 NetworkService：
		# 本函数是纯静态的、拿不到 room，而 _restamp_cached_board() 会拿一份跨回合
		# 缓存的棋盘重跑本校验 —— 把血统判据塞进来，看门狗代打会因为服务器重启后
		# boards/last_board 没持久化而莫名其妙拒掉一整个座位的棋盘。
		var uid := str(d.get("uid", ""))
		if uid.length() > MAX_ID_LENGTH:
			return {"ok": false, "reason": "invalid_uid_length:%d" % uid.length()}
		if not uid.is_empty():
			if used_uids.has(uid):
				return {"ok": false, "reason": "duplicate_uid:%s" % uid}
			used_uids[uid] = true
		var clean := {
			"id": id,
			"uid": uid,
			"star": star,
			"def": def,
			"is_mercenary": mercenary,
			"race_relations": _safe_race_relations(d.get("race_relations", {})),
		}
		if mercenary:
			out.append(clean)
		else:
			out[slot] = clean
	return {"ok": true, "slots": out}

static func _trusted_def(id: String, mercenary: bool) -> Dictionary:
	if id.is_empty():
		return {}
	var table_name := "mercenaries" if mercenary else "race_units"
	var key := "mercenaries" if mercenary else "units"
	var rows: Array = DataRegistry.get_table(table_name).get(key, [])
	for row in rows:
		if str(row.get("id", "")) == id:
			return (row as Dictionary).duplicate(true)
	return {}

static func _validate_treasures(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_ARRAY:
		return {"ok": false, "reason": "malformed_treasures"}
	if (value as Array).size() > MAX_TREASURE_ENTRIES:
		return {"ok": false, "reason": "too_many_treasures"}
	var out := _sanitize_treasure_ids(value)
	if out.size() != (value as Array).size():
		return {"ok": false, "reason": "invalid_treasure_id"}
	if out.size() > TreasureService.MAX_OWNED:
		return {"ok": false, "reason": "too_many_treasures"}
	return {"ok": true, "treasures": out}

static func _sanitize_treasure_ids(value: Variant) -> Array:
	var out := []
	if typeof(value) != TYPE_ARRAY:
		return out
	if (value as Array).size() > MAX_TREASURE_ENTRIES:
		return out
	var known := {}
	for t in DataRegistry.get_table("treasures").get("treasures", []):
		known[str((t as Dictionary).get("id", ""))] = true
	for tid_value in (value as Array):
		var tid := str(tid_value)
		if tid.is_empty() or out.has(tid) or not known.has(tid):
			continue
		out.append(tid)
	return out

static func _sanitize_pet_id(value: Variant) -> String:
	var pid := str(value)
	if pid.is_empty():
		return ""
	for p in DataRegistry.get_table("pets").get("pets", []):
		if str((p as Dictionary).get("id", "")) == pid:
			return pid
	return ""

static func _empty_board() -> Array:
	var out := []
	out.resize(BOARD_SIZE)
	out.fill(null)
	return out
