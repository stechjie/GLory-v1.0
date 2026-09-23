extends Node

# 门禁：匹配出来的对局，战斗服务器这一侧（协议 32）。
#
# 设计见 docs/排位系统设计.md 第五、九节。账号服务器那一半的门禁在
# backend/tests/test_matchmaking.py；名片本身的门禁在 tools/battle_card_check.tscn。
#
# ## 这条门禁验什么
#
# 六件**会静默出错**的事：
#
#   1. 会合键认错亲。六个人应该进同一个房间，认错了就是六个人各自开一间空房 ——
#      而每一间看起来都很正常，只是永远等不到人。
#   2. 不按名片上的 team 落座。串队之后 3v3 变成 4v2，**不报错**，
#      只是有一队从开局就注定输。
#   3. 匹配房间能被路人按房间号加入 / 出现在房间列表里。那等于把一个已经确认过、
#      手里还拿着名片的人挤掉。
#   4. 开局时把会合键覆盖掉。那样同一局在匹配日志和对局历史里是两个编号，对不上。
#   5. 战报里的 mode 退回 custom。休闲局会被记成自定义局，以后统计全错。
#   6. 重启后索引没重建。房间还在、但后到的人认不出亲，会去开一间新的。
#
# ## 🔴 钥匙现场生成
#
# 复用 tools/battle_card_test_keys.gd。不要把任何私钥放进 tools/ ——
# make_server_zip.ps1 会把整个 tools/ 打进战斗服务器包。
#
# 跑：
#   godot --headless --path <项目> tools/matchmaking_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const TestKeys := preload("res://tools/battle_card_test_keys.gd")
const BattleCard := preload("res://scripts/multiplayer/BattleCard.gd")

const CHECK_NAME := "matchmaking"

const MATCH_A := "aaaaaaaabbbbbbbbccccccccdddddddd"
const MATCH_B := "11111111222222223333333344444444"

var _h: CheckHarness
var _key: CryptoKey
var _pem := ""


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_key = TestKeys.generate()
	_pem = TestKeys.public_pem(_key)
	NetworkService.enter_test_server_mode()

	_case_card_fields()
	_case_team_slots()
	_case_rendezvous()
	_case_seating_follows_the_card()
	_case_matched_rooms_are_private()
	_case_match_uid_is_not_overwritten()
	_case_report_mode()
	_case_index_rebuild()
	_case_constants_line_up()

	_h.finish(get_tree())


# --- 夹具 ---------------------------------------------------------------------

func _card(overrides: Dictionary) -> Dictionary:
	var got := BattleCard.verify(
		TestKeys.sign(_key, TestKeys.card("player-x", overrides)),
		int(Time.get_unix_time_from_system()), _pem)
	return got.get("card", {})


func _matched_card(match_uid: String, team: int) -> Dictionary:
	return _card({"match": match_uid, "team": team})


func _drop(room: Dictionary) -> void:
	NetworkService._room_close(room, "check_done")
	NetworkService._rooms.erase(int(room.get("id", 0)))


# --- 1. 名片上的两个字段 ---------------------------------------------------------

func _case_card_fields() -> void:
	var plain := _card({})
	_eq(BattleCard.match_of(plain), "", "plain_card_has_no_match",
		"自定义房间那条路的名片不该有会合键")
	_eq(BattleCard.team_of(plain), -1, "plain_card_team_is_minus_one",
		"🔴 没有分配时 team 必须是 -1，不是 0 —— 0 是 A 队，"
		+ "默认成 0 会让所有普通名片都被当成「A 队的匹配对局」")

	var good := _matched_card(MATCH_A, 1)
	_eq(BattleCard.match_of(good), MATCH_A, "match_passes_through", "会合键要原样透传")
	_eq(BattleCard.team_of(good), 1, "team_passes_through", "队伍号要原样透传")

	# 格式不对一律当作「没有」，不当作错误：名片是账号服务器签的，
	# 格式不对说明它那边有 bug，那时候放玩家走自定义房间比挡在门外强。
	for bad in ["", "ZZZZ", MATCH_A.to_upper(), MATCH_A + "ff", "not-hex-at-all-nope-nope-nope"]:
		_eq(BattleCard.match_of(_card({"match": bad})), "", "bad_match_ignored",
			"会合键 %s 格式不对，应当当作没有" % bad)
	for bad in [-1, 2, 99]:
		_eq(BattleCard.team_of(_card({"team": bad})), -1, "bad_team_ignored",
			"队伍号 %d 超范围，应当当作没有" % bad)


# --- 2. 按队伍找空位 -------------------------------------------------------------

func _case_team_slots() -> void:
	var room: Dictionary = NetworkService._new_room()
	var svc = NetworkService._room_service
	_eq(int(svc.room_next_free_slot_on_team(room, 0)), 0, "team_a_first_slot", "A 队从 0 号位开始")
	_eq(int(svc.room_next_free_slot_on_team(room, 1)), 3, "team_b_first_slot", "B 队从 3 号位开始")

	# 把 A 队坐满，B 队不受影响
	var states: Array = room.get("slot_states", [])
	for i in 3:
		states[i] = "player"
	room.slot_states = states
	_eq(int(svc.room_next_free_slot_on_team(room, 0)), -1, "team_a_full", "A 队满了要回 -1")
	_eq(int(svc.room_next_free_slot_on_team(room, 1)), 3, "team_b_still_open", "A 队满不该影响 B 队")
	_drop(room)


# --- 3. 会合：谁先到谁建房，后到的进同一间 ------------------------------------------

func _case_rendezvous() -> void:
	var first: Dictionary = NetworkService._matched_room_for(MATCH_A)
	_eq(first.is_empty(), false, "first_creates_room", "第一个人应该建出房间")
	_eq(bool(first.get("matched", false)), true, "room_is_marked_matched",
		"匹配房间要带 matched 标记（房间列表靠它排除）")
	_eq(str(first.get("match_uid", "")), MATCH_A, "room_takes_the_rendezvous_key",
		"🔴 会合键就是这一局的 match_uid，不该另摇一个")
	_eq(str(first.get("mode", "")), "casual", "room_mode_is_casual", "匹配房间的 mode 要写上")

	var second: Dictionary = NetworkService._matched_room_for(MATCH_A)
	_eq(int(second.get("id", 0)), int(first.get("id", 0)), "same_key_same_room",
		"🔴 同一个会合键必须进同一间房 —— 认错亲 = 六个人各开一间空房")

	var other: Dictionary = NetworkService._matched_room_for(MATCH_B)
	_eq(int(other.get("id", 0)) != int(first.get("id", 0)), true, "different_key_different_room",
		"不同会合键不能混进同一间")
	_drop(first)
	_drop(other)


# --- 4. 按名片上的 team 落座 ------------------------------------------------------

func _case_seating_follows_the_card() -> void:
	var room: Dictionary = NetworkService._matched_room_for(MATCH_A)
	var svc = NetworkService._room_service
	# 三个 B 队的人先到：他们必须坐 3/4/5，不能占 0 号位
	for i in 3:
		var slot := int(svc.room_next_free_slot_on_team(room, 1))
		NetworkService._assign_peer_to_room(9000 + i, room, "", _matched_card(MATCH_A, 1), slot)
	var states: Array = room.get("slot_states", [])
	for i in 3:
		_eq(str(states[i]), "empty", "team_b_did_not_take_team_a_slots",
			"🔴 B 队的人占了 A 队的座位 —— 串队之后 3v3 变 4v2，而且不报错")
	for i in range(3, 6):
		_eq(str(states[i]), "player", "team_b_seated", "B 队座位 %d 应当有人" % i)

	# 还没坐满：不该开局
	_eq(str(room.get("state", "")), NetworkService.ROOM_LOBBY, "not_started_when_half_full",
		"只有三个人时不该开局")
	NetworkService._matched_try_start(room)
	_eq(str(room.get("state", "")), NetworkService.ROOM_LOBBY, "try_start_is_a_noop_when_not_full",
		"没坐满时 _matched_try_start 应该什么都不做")
	_drop(room)


# --- 5. 匹配房间是私有的 ---------------------------------------------------------

func _case_matched_rooms_are_private() -> void:
	var matched: Dictionary = NetworkService._matched_room_for(MATCH_A)
	var normal: Dictionary = NetworkService._new_room()
	var listed: Array = NetworkService._room_service.public_room_list()
	var ids := []
	for entry in listed:
		ids.append(int((entry as Dictionary).get("id", 0)))
	_eq(ids.has(int(normal.get("id", 0))), true, "normal_room_is_listed",
		"普通空房应该出现在房间列表里（守卫：列表本身没坏）")
	_eq(ids.has(int(matched.get("id", 0))), false, "matched_room_is_hidden",
		"🔴 匹配房间出现在房间列表里 —— 路人进去会挤掉一个已经确认过的人")

	# 判据必须是 matched 标记，不是 match_uid 非空：
	# 自定义房间开局时也会写 match_uid（战报要用，第 1 步）。
	var custom_started: Dictionary = NetworkService._new_room()
	custom_started["match_uid"] = MATCH_B
	var listed2: Array = NetworkService._room_service.public_room_list()
	var ids2 := []
	for entry in listed2:
		ids2.append(int((entry as Dictionary).get("id", 0)))
	_eq(ids2.has(int(custom_started.get("id", 0))), true, "custom_room_with_uid_still_listed",
		"自定义房间只是有 match_uid，不该被当成匹配房间藏起来")
	_drop(matched)
	_drop(normal)
	_drop(custom_started)


# --- 6. 开局不覆盖会合键 ---------------------------------------------------------

func _case_match_uid_is_not_overwritten() -> void:
	var room: Dictionary = NetworkService._matched_room_for(MATCH_A)
	var svc = NetworkService._room_service
	for team in 2:
		for i in 3:
			var slot := int(svc.room_next_free_slot_on_team(room, team))
			NetworkService._assign_peer_to_room(9100 + team * 3 + i, room, "",
				_matched_card(MATCH_A, team), slot)
	NetworkService._matched_try_start(room)
	_eq(str(room.get("state", "")), NetworkService.ROOM_PREP, "full_room_starts",
		"六个人到齐应该自己开打（匹配对局没有「准备」那一步）")
	_eq(str(room.get("match_uid", "")), MATCH_A, "start_keeps_the_rendezvous_key",
		"🔴 开局时把会合键覆盖掉了 —— 同一局在匹配日志和对局历史里会是两个编号")
	_drop(room)

	# 对照组：自定义房间开局时**要**摇一个新的
	var custom: Dictionary = NetworkService._new_room()
	var states: Array = custom.get("slot_states", [])
	var ready: Array = custom.get("ready", [])
	for i in 6:
		states[i] = "player"
		ready[i] = true
	custom.slot_states = states
	custom.ready = ready
	NetworkService._room_start_authoritative(custom)
	# 🔴 守卫：开局必须真的把房间推到备战阶段。
	# 少了 _set_room_state(ROOM_PREP) 的话服务器停在 lobby，而 team_start 已经广播 ——
	# 客户端进了对局、服务器以为还在大厅。2026-09-22 真的踩过一次（第 1 步加
	# match_uid 时手滑删掉了那一行），而当时跑的四条门禁一条都没覆盖这一步。
	_eq(str(custom.get("state", "")), NetworkService.ROOM_PREP, "custom_room_reaches_prep",
		"开始游戏之后房间没进备战阶段")
	_eq(str(custom.get("match_uid", "")).length(), 32, "custom_room_gets_a_fresh_uid",
		"自定义房间开局时要自己摇一个 match_uid（战报要用）")
	_drop(custom)


# --- 7. 战报里的 mode ------------------------------------------------------------

func _case_report_mode() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/autoload/NetworkService.gd")
	_eq(src.contains('str(room.get("mode", "custom"))'), true, "report_reads_room_mode",
		"🔴 战报的 mode 写死成 custom 了 —— 休闲局会被记成自定义局，以后统计全错")


# --- 8. 重启后索引重建 -----------------------------------------------------------

func _case_index_rebuild() -> void:
	var matched: Dictionary = NetworkService._matched_room_for(MATCH_A)
	# 自定义房间也有 match_uid，但没有 matched 标记 —— 它不该进索引。
	var custom: Dictionary = NetworkService._new_room()
	custom["match_uid"] = MATCH_B

	NetworkService._matched_rooms.clear()
	NetworkService._rebuild_matched_index()
	_eq(int(NetworkService._matched_rooms.get(MATCH_A, 0)), int(matched.get("id", 0)),
		"index_rebuilds_matched_room",
		"🔴 重启后索引没重建 —— 房间还在，但后到的人认不出亲，会去开一间新的")
	_eq(NetworkService._matched_rooms.has(MATCH_B), false, "index_skips_custom_rooms",
		"自定义房间的 match_uid 进了索引 —— 一张伪造的名片就能挤进别人的自定义房间")
	_drop(matched)
	_drop(custom)
	NetworkService._matched_rooms.clear()


# --- 9. 常量对齐 -----------------------------------------------------------------

func _case_constants_line_up() -> void:
	_eq(NetworkConfig.NETWORK_PROTOCOL_VERSION, 32, "protocol_is_32",
		"匹配入座是新 RPC，协议号要顶到 32（战斗服务器与 APK 一起上）")

	# 会合键的长度上限：名片清洗时按 MAX_TEXT 截断，比 32 小的话**每一张都会被截掉尾巴**，
	# 然后 match_of 的正则不过 → 所有匹配对局都退回自定义房间那条路，而且不报错。
	_eq(int(BattleCard.MAX_TEXT.get("match", 0)) >= 32, true, "match_field_long_enough",
		"MAX_TEXT['match'] 小于 32，会合键会被截断")

	# 三处正则必须一致：GDScript / Python / SQL。
	var sql := FileAccess.get_file_as_string("res://database/013_match_history.sql")
	_eq(sql.contains(BattleCard.MATCH_UID_RE), true, "regex_matches_sql",
		"BattleCard.MATCH_UID_RE 与 013 的 match_uid_format 约束对不上")
	var py := FileAccess.get_file_as_string("res://backend/app/matchmaking.py")
	_eq(py.contains("token_hex(16)"), true, "python_generates_16_bytes",
		"账号服务器那边的会合键不是 16 字节十六进制了")

	# 匹配房间的三个字段必须活过进程重启。
	var persisted := FileAccess.get_file_as_string("res://scripts/multiplayer/DedicatedServerService.gd")
	for field in ["matched", "mode", "match_uid"]:
		_eq(persisted.contains('"%s"' % field), true, "persisted_" + field,
			"%s 没进 PERSISTED_ROOM_FIELDS —— 重启后匹配房间会退化成普通房间" % field)


# CheckHarness.expect 是 (条件, code, 文案) 三参数。这里的断言几乎都是「相等」，
# 每处手写 `a == b` 会让失败信息丢掉实际值 —— 包一层，把两边都打出来。
func _eq(got, want, code: String, message: String) -> void:
	_h.expect(got == want, code, "%s（实际 %s，期望 %s）" % [message, str(got), str(want)])
