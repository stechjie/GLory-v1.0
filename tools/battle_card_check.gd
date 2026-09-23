extends Node

# 出战名片（scripts/multiplayer/BattleCard.gd、NetworkService 的座位名片）。
#
# 要守住的只有一句话：**对局里的宠物、种族、名字头像，一律以入座时那张验过章的名片为准；
# 断线重连回来，宠物还是那只、效果照有。**
#
# 分四块：
#   1. 验章本身：好名片过；改一个字节、换一把钥匙、过期、签发时间在将来、版本不对、
#      格式坏、超长 —— 全拒，而且超长要在解码之前就拒
#   2. 公钥文件：缺、坏、放成私钥 —— 都算没有
#   3. 座位：名片写进座位；交棋盘时手机报的宠物不算数；重连、换座、离座、AI 代打
#      都不会让座位上的宠物变成别的
#   4. 入座请求：没名片 / 坏名片 / 用过的名片都进不了座，**而且原来的座位不丢**
#
# 钥匙在运行时现场生成（tools/battle_card_test_keys.gd），不读任何文件、不起监听端口
# （最后一条「缺公钥不占端口」除外，见 _case_host_refuses_without_key）。
#
# 真的过 ENet 的那一路在 channel_check（建房带名片 → 验章 → 入座）。
#
# 日志里会有几行引擎 `ERROR:`（Error parsing key、b64_decode、Parse JSON failed）——
# 那是故意喂坏公钥、坏 base64、坏 JSON 时引擎自己打的，不是失败。判定只看 CHECK_RESULT。
#
# 运行：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/battle_card_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BattleCard := preload("res://scripts/multiplayer/BattleCard.gd")
const TestKeys := preload("res://tools/battle_card_test_keys.gd")

const CHECK_NAME := "battle_card"
# 真实宠物表里的两只。故意写死：从表里读的话，表空了这里也跟着「没东西可测」。
const CARD_PET := "pet_cat"
const CLIENT_PET := "pet_rabbit"
const RACES := ["god", "dark", "undead", "human"]
# 进程内调 RPC 入口时，multiplayer.get_remote_sender_id() 是 0 —— 这个「玩家」就是 0 号连接。
const SENDER := 0
const OTHER_PEER := 5151
const TEST_PORT := 8139
const HUGE_CHARS := 200000

var _h: CheckHarness
var _key: CryptoKey
var _other_key: CryptoKey
var _pem := ""
var _tmp_files: Array[String] = []


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_key = TestKeys.generate()
	_other_key = TestKeys.generate()
	_pem = TestKeys.public_pem(_key)

	_case_verify_good()
	_case_verify_tampered()
	_case_verify_time()
	_case_verify_malformed()
	_case_verify_cleans_fields()
	_case_key_file()

	NetworkService.enter_test_server_mode()
	NetworkService._battle_card_public_key = _pem
	_case_seat_stores_card()
	_case_seat_rejects_bad_content()
	_case_board_uses_seat_pet()
	_case_reconnect_keeps_pet()
	_case_ai_pet_never_leaks()
	_case_move_and_leave()
	_case_request_needs_card()
	_case_replay_and_prune()
	_case_host_refuses_without_key()

	for path in _tmp_files:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_h.finish(get_tree())


# --- 小工具 -------------------------------------------------------------------

func _now() -> int:
	return int(Time.get_unix_time_from_system())


func _signed(overrides: Dictionary = {}, key: CryptoKey = null) -> String:
	return TestKeys.sign(_key if key == null else key, TestKeys.card("player-1", overrides))


func _verify(card_text: String) -> Dictionary:
	return BattleCard.verify(card_text, _now(), _pem)


func _expect_code(card_text: String, code: String, what: String) -> void:
	var got := _verify(card_text)
	_h.expect(not bool(got.get("ok", true)) and str(got.get("code", "")) == code, "verify_" + what,
		"%s：应当拒收并回 %s，实际 ok=%s code=%s" % [what, code, str(got.get("ok")), str(got.get("code"))])


func _write_tmp(name: String, text: String) -> String:
	var path := "user://battle_card_check_%s.pem" % name
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	_tmp_files.append(path)
	return path


func _lobby_room() -> Dictionary:
	var room: Dictionary = NetworkService._new_room()
	return room


func _slot_of(room: Dictionary, peer: int) -> int:
	return int((room.get("peer_slot", {}) as Dictionary).get(peer, -1))


func _seat_card(pet: String = CARD_PET, races: Array = RACES) -> Dictionary:
	var got := _verify(_signed({"pet": pet, "races": races.duplicate()}))
	return got.get("card", {})


func _board_for(room: Dictionary, claimed_pet: String) -> Dictionary:
	GameState.reset_run()
	GameState.round_index = int(room.get("round_index", 1))
	var snap := NetProtocol.team_board_submission(GameState.board_slots)
	snap["pet"] = claimed_pet
	return snap


func _drop_room(room: Dictionary) -> void:
	for peer in (room.get("peer_slot", {}) as Dictionary).keys():
		NetworkService._peer_room.erase(peer)
	NetworkService._rooms.erase(int(room.get("id", 0)))


# --- 1. 验章 ------------------------------------------------------------------

func _case_verify_good() -> void:
	var got := _verify(_signed({"pet": CARD_PET, "name": "阿明"}))
	if not _h.expect(bool(got.get("ok", false)), "good_card_rejected",
			"一张正常签发的名片被拒了：%s" % str(got.get("code"))):
		return
	var card: Dictionary = got.get("card", {})
	_h.expect(str(card.get("pid")) == "player-1" and str(card.get("pet")) == CARD_PET
			and str(card.get("name")) == "阿明" and str(card.get("races")) == str(RACES),
		"good_card_fields", "验过的名片内容不对：%s" % str(card))
	_h.expect(str(BattleCard.races_of(card)) == str(RACES), "races_of",
		"races_of 应当原样给出合规的四族，实际 %s" % str(BattleCard.races_of(card)))
	_h.expect(BattleCard.pet_of(card) == CARD_PET, "pet_of", "pet_of 应为 %s" % CARD_PET)
	var profile := BattleCard.profile_of(card)
	_h.expect(str(profile.get("player_name")) == "阿明" and str(profile.get("friend_code")) == "TESTCODE"
			and str(profile.get("avatar_frame")) == str(card.get("frame")),
		"profile_of", "profile_of 形状不对：%s" % str(profile))


func _case_verify_tampered() -> void:
	var good := _signed({"pet": ""})
	var parts := good.split(".")
	# 改名片内容一个字节（空宠物改成猫），签名原样 —— 这就是「手机改了能用没买的」。
	var body := Marshalls.base64_to_raw(parts[0]).get_string_from_utf8()
	var forged := body.replace("\"pet\":\"\"", "\"pet\":\"%s\"" % CARD_PET)
	_h.expect(forged != body, "tamper_setup", "造篡改名片失败：找不到 pet 字段（JSON 格式变了？）%s" % body)
	_expect_code(Marshalls.utf8_to_base64(forged) + "." + parts[1], "card_bad_signature", "tampered_body")
	_expect_code(_signed({}, _other_key), "card_bad_signature", "other_key")
	# 签名换成同长度的别的字节
	var sig := Marshalls.base64_to_raw(parts[1])
	sig[0] = sig[0] ^ 0xff
	_expect_code(parts[0] + "." + Marshalls.raw_to_base64(sig), "card_bad_signature", "tampered_signature")
	var no_key := BattleCard.verify(good, _now(), "")
	_h.expect(str(no_key.get("code")) == "card_key_missing", "verify_no_key",
		"没有公钥时应回 card_key_missing，实际 %s" % str(no_key.get("code")))
	var garbage_key := BattleCard.verify(good, _now(), "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----")
	_h.expect(str(garbage_key.get("code")) == "card_key_missing", "verify_garbage_key",
		"公钥是坏的时应回 card_key_missing，实际 %s" % str(garbage_key.get("code")))


func _case_verify_time() -> void:
	var now := _now()
	var lee := BattleCard.CLOCK_LEEWAY_SEC
	_expect_code(_signed({"iat": now - 200, "exp": now - lee - 5}), "card_expired", "expired")
	var in_leeway := _verify(_signed({"iat": now - 70, "exp": now - lee + 5}))
	_h.expect(bool(in_leeway.get("ok", false)), "leeway_rejected",
		"刚过期但还在钟差宽限内的名片被拒了：%s" % str(in_leeway.get("code")))
	_expect_code(_signed({"iat": now + lee + 60, "exp": now + lee + 120}), "card_expired", "future_iat")
	_expect_code(_signed({"exp": 0}), "card_expired", "no_exp")
	_expect_code(_signed({"v": BattleCard.VERSION + 1}), "card_version", "version")


func _case_verify_malformed() -> void:
	_expect_code("", "card_required", "empty")
	for bad in ["abc", "a.b.c", ".", "!!!.!!!", "YWJj.", ".YWJj"]:
		_expect_code(bad, "card_malformed", "shape_" + bad.uri_encode())
	# 签名对、内容不是字典 / 缺关键字段
	var arr := TestKeys.sign(_key, {}, "[1,2,3]".to_utf8_buffer())
	_expect_code(arr, "card_malformed", "array_body")
	var not_json := TestKeys.sign(_key, {}, "not json".to_utf8_buffer())
	_expect_code(not_json, "card_malformed", "not_json")
	_expect_code(_signed({"pid": ""}), "card_malformed", "no_pid")
	_expect_code(_signed({"jti": ""}), "card_malformed", "no_jti")
	_expect_code(_signed({"pid": 12345}), "card_malformed", "pid_not_string")
	# 签名长度不对（RSA-2048 固定 256 字节）
	var parts := _signed().split(".")
	_expect_code(parts[0] + "." + Marshalls.raw_to_base64(PackedByteArray([1, 2, 3])), "card_malformed", "short_signature")
	# 超长：必须在解码之前就拒，而且快
	var huge := "A".repeat(HUGE_CHARS) + "." + parts[1]
	var t0 := Time.get_ticks_usec()
	var got := _verify(huge)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	_h.expect(str(got.get("code")) == "card_malformed", "oversized_admitted",
		"%d 字符的名片应当回 card_malformed，实际 %s" % [huge.length(), str(got.get("code"))])
	_h.expect(ms < 5.0, "oversized_slow", "超长名片花了 %.2fms 才拒 —— 长度检查应当在解码之前" % ms)
	# 正常名片离上限要有余量（账号服务器那边 test_loadout 量的是最大名片）
	_h.expect(_signed().length() < BattleCard.MAX_CARD_CHARS, "normal_card_over_limit",
		"一张普通名片就有 %d 字符，超过上限 %d" % [_signed().length(), BattleCard.MAX_CARD_CHARS])


func _case_verify_cleans_fields() -> void:
	var many: Array = []
	for i in BattleCard.MAX_RACES + 5:
		many.append("r%d" % i)
	many[1] = 42
	# 名字 100 个汉字 = 300 字节：超过字段上限、但整张名片没超总长上限（超了就是另一条用例了）。
	var got := _verify(_signed({
		"name": "长".repeat(100), "pet": 77, "avatar": ["x"], "races": many,
	}))
	if not _h.expect(bool(got.get("ok", false)), "dirty_card_rejected",
			"字段类型不对不该让整张名片被拒（签过章就是账号服务器的意思），实际 %s" % str(got.get("code"))):
		return
	var card: Dictionary = got.get("card", {})
	_h.expect(str(card.get("name")).length() == int(BattleCard.MAX_TEXT["name"]), "name_not_truncated",
		"名字应截到 %d 字，实际 %d" % [int(BattleCard.MAX_TEXT["name"]), str(card.get("name")).length()])
	_h.expect(str(card.get("pet")) == "" and str(card.get("avatar")) == "", "non_string_kept",
		"不是字符串的字段应当清成空串：pet=%s avatar=%s" % [str(card.get("pet")), str(card.get("avatar"))])
	var races: Array = card.get("races", [])
	# many[1] 是数字 42：丢掉之后第二个应当是 r2
	_h.expect(races.size() == BattleCard.MAX_RACES and str(races[1]) == "r2", "races_not_capped",
		"种族应当丢掉非字符串、截到 %d 个，实际 %s" % [BattleCard.MAX_RACES, str(races)])
	# 不合规则的种族组合：清洗保留原样，由 races_of 回落默认（和 RacePick 口径一致）
	_h.expect(str(BattleCard.races_of(card)) == str(BattleCard.RacePick.resolve([])), "bad_races_not_default",
		"不合规则的种族应回落默认，实际 %s" % str(BattleCard.races_of(card)))
	# 宠物表里没有的宠物：当作没带
	var unknown := _verify(_signed({"pet": "pet_does_not_exist"}))
	_h.expect(BattleCard.pet_of(unknown.get("card", {})) == "", "unknown_pet_kept",
		"宠物表里没有的宠物应当当作没带")


# --- 2. 公钥文件 --------------------------------------------------------------

func _case_key_file() -> void:
	var ok := BattleCard.load_server_key(_write_tmp("public", _pem))
	_h.expect(str(ok.get("pem", "")) == _pem and str(ok.get("error", "x")).is_empty(), "key_file_good",
		"合法公钥文件没读进来：%s" % str(ok.get("error")))
	var missing := BattleCard.load_server_key("user://battle_card_check_does_not_exist.pem")
	_h.expect(str(missing.get("pem", "x")).is_empty() and not str(missing.get("error", "")).is_empty(),
		"key_file_missing", "文件不存在时应当给出原因、pem 为空")
	var garbage := BattleCard.load_server_key(_write_tmp("garbage", "hello"))
	_h.expect(str(garbage.get("pem", "x")).is_empty(), "key_file_garbage", "内容不是公钥也被收下了")
	var private := BattleCard.load_server_key(_write_tmp("private", _key.save_to_string(false)))
	_h.expect(str(private.get("pem", "x")).is_empty(), "key_file_private",
		"公钥位置放的是**私钥**也被收下了 —— 战斗服务器不该持有能签名片的钥匙")


# --- 3. 座位 ------------------------------------------------------------------

func _case_seat_stores_card() -> void:
	var ns := NetworkService
	var room := _lobby_room()
	var card := _seat_card()
	card["name"] = "阿明"
	ns._assign_peer_to_room(OTHER_PEER, room, "", card)
	var slot := _slot_of(room, OTHER_PEER)
	_h.expect(ns._room_seat_pet(room, slot) == CARD_PET, "seat_pet_not_stored",
		"座位上的宠物应为名片上的 %s，实际 %s" % [CARD_PET, ns._room_seat_pet(room, slot)])
	_h.expect(str(ns._room_seat_races(room, slot)) == str(RACES), "seat_races_not_stored",
		"座位上的种族应为名片上的，实际 %s" % str(ns._room_seat_races(room, slot)))
	var profile: Dictionary = (room.get("seat_profiles", {}) as Dictionary).get(slot, {})
	_h.expect(str(profile.get("player_name", "")) == "阿明", "seat_profile_not_stored",
		"座位上的名字应为名片上的，实际 %s" % str(profile))
	_drop_room(room)


func _case_seat_rejects_bad_content() -> void:
	var ns := NetworkService
	var room := _lobby_room()
	ns._assign_peer_to_room(OTHER_PEER, room, "", _seat_card("pet_does_not_exist", ["god", "dark"]))
	var slot := _slot_of(room, OTHER_PEER)
	_h.expect(ns._room_seat_pet(room, slot) == "", "seat_unknown_pet",
		"宠物表里没有的宠物被写进了座位：%s" % ns._room_seat_pet(room, slot))
	_h.expect(not (room.get("seat_races", {}) as Dictionary).has(slot), "seat_bad_races_stored",
		"不合规则的种族组合被写进了座位：%s" % str((room.get("seat_races", {}) as Dictionary).get(slot)))
	_drop_room(room)


# 交棋盘：手机报的宠物一律不算。
func _case_board_uses_seat_pet() -> void:
	var ns := NetworkService
	for card_pet in [CARD_PET, ""]:
		var room := _lobby_room()
		ns._assign_peer_to_room(SENDER, room, "", _seat_card(card_pet))
		ns._assign_peer_to_room(OTHER_PEER, room, "", _seat_card())
		var slot := _slot_of(room, SENDER)
		room.state = ns.ROOM_BATTLE
		room.round_index = 3
		ns._rate_forget(SENDER)
		ns._rpc_team_submit_board(slot, _board_for(room, CLIENT_PET))
		var board: Dictionary = (room.get("boards", {}) as Dictionary).get(slot, {})
		var last: Dictionary = (room.get("last_board", {}) as Dictionary).get(slot, {})
		if _h.expect(not board.is_empty(), "board_not_accepted",
				"合法棋盘没被收下（card_pet=%s），后面的断言没法做" % card_pet):
			_h.expect(str(board.get("pet", "?")) == card_pet, "board_pet_from_client",
				"名片宠物=%s、手机报 %s，收下的棋盘里是 %s —— 应当以名片为准"
					% [card_pet, CLIENT_PET, str(board.get("pet"))])
			_h.expect(str(last.get("pet", "?")) == card_pet, "last_board_pet_from_client",
				"跨回合缓存（掉线代打 / 重连补交用）里的宠物是 %s，应为 %s" % [str(last.get("pet")), card_pet])
		# 缓存重盖戳：缓存里是什么都以座位为准
		var restamped := ns._restamp_cached_board(room, slot, _board_for(room, CLIENT_PET))
		_h.expect(str(restamped.get("pet", "?")) == card_pet, "restamp_pet_from_cache",
			"重盖戳后的缓存棋盘宠物是 %s，应为 %s" % [str(restamped.get("pet")), card_pet])
		_drop_room(room)


# 验收标准原话：「对局重连回来，宠物必须和出战宠物一样，也必须有效果」。
func _case_reconnect_keeps_pet() -> void:
	var ns := NetworkService
	var room := _lobby_room()
	ns._assign_peer_to_room(OTHER_PEER, room, "", _seat_card())
	ns._assign_peer_to_room(SENDER + 777, room, "", _seat_card())
	var slot := _slot_of(room, OTHER_PEER)
	var token := str((room.get("seat_tokens", {}) as Dictionary).get(slot, ""))
	room.state = ns.ROOM_PREP
	room.round_index = 4
	ns._room_reserve_peer(room, OTHER_PEER)
	_h.expect(ns._room_seat_pet(room, slot) == CARD_PET, "reserve_lost_pet",
		"掉线保留座位时宠物没了：%s" % ns._room_seat_pet(room, slot))
	# 重连：新连接号，**不带任何名片**。这一次换成 SENDER（0 号），后面交棋盘要用。
	ns._resume_seat(SENDER, token)
	_h.expect(_slot_of(room, SENDER) == slot, "resume_failed",
		"持 token 重连没回到原座位（slot=%d，实际 %d）" % [slot, _slot_of(room, SENDER)])
	_h.expect(ns._room_seat_pet(room, slot) == CARD_PET, "resume_lost_pet",
		"重连后座位上的宠物是 %s，应为 %s" % [ns._room_seat_pet(room, slot), CARD_PET])
	_h.expect(str(ns._room_seat_races(room, slot)) == str(RACES), "resume_lost_races",
		"重连后座位上的种族变了：%s" % str(ns._room_seat_races(room, slot)))
	# 重连的手机本机宠物缓存还是空的，交上来的棋盘 pet 为空 —— 战斗里照样是名片那只。
	room.state = ns.ROOM_BATTLE
	ns._rate_forget(SENDER)
	ns._rpc_team_submit_board(slot, _board_for(room, ""))
	var board: Dictionary = (room.get("boards", {}) as Dictionary).get(slot, {})
	_h.expect(str(board.get("pet", "?")) == CARD_PET, "resume_board_pet",
		"重连后交的棋盘（手机报空宠物）收下时宠物是 %s，应为 %s —— 宠物效果会丢"
			% [str(board.get("pet")), CARD_PET])
	_drop_room(room)


# 没带宠物的玩家掉线 → AI 接手配了一只展示宠物 → 玩家重连：战斗里不能多出那只宠物。
func _case_ai_pet_never_leaks() -> void:
	var ns := NetworkService
	var room := _lobby_room()
	ns._assign_peer_to_room(OTHER_PEER, room, "", _seat_card(""))
	var slot := _slot_of(room, OTHER_PEER)
	var token := str((room.get("seat_tokens", {}) as Dictionary).get(slot, ""))
	room.state = ns.ROOM_PREP
	ns._room_reserve_peer(room, OTHER_PEER)
	var shown := ns._ensure_dummy_seat_pet(room, slot)
	_h.expect(not shown.is_empty(), "ai_pet_missing", "AI 座位没配到展示宠物（首发宠物表空了？）")
	_h.expect(ns._room_seat_pet(room, slot) == "", "ai_pet_in_seat_pets",
		"AI 的展示宠物 %s 写进了 seat_pets —— 玩家重连后会用上一只没有的宠物" % ns._room_seat_pet(room, slot))
	ns._resume_seat(OTHER_PEER + 1, token)
	_h.expect(ns._room_seat_pet(room, slot) == "", "ai_pet_after_resume",
		"重连后座位宠物是 %s，应为空（名片上没带）" % ns._room_seat_pet(room, slot))
	# 有名片宠物的座位被 AI 代打：展示的是玩家自己那只，不另配
	var room2 := _lobby_room()
	ns._assign_peer_to_room(OTHER_PEER + 2, room2, "", _seat_card())
	var slot2 := _slot_of(room2, OTHER_PEER + 2)
	_h.expect(ns._ensure_dummy_seat_pet(room2, slot2) == CARD_PET, "ai_shows_other_pet",
		"代打座位应当展示玩家自己的 %s" % CARD_PET)
	_drop_room(room)
	_drop_room(room2)


func _case_move_and_leave() -> void:
	var ns := NetworkService
	var room := _lobby_room()
	ns._assign_peer_to_room(OTHER_PEER, room, "", _seat_card())
	var slot := _slot_of(room, OTHER_PEER)
	ns._room_do_move(room, OTHER_PEER, slot, 5)
	_h.expect(ns._room_seat_pet(room, 5) == CARD_PET and ns._room_seat_pet(room, slot) == "",
		"move_pet", "换座后宠物应跟人走：新座位 %s、旧座位 %s" % [ns._room_seat_pet(room, 5), ns._room_seat_pet(room, slot)])
	ns._room_remove_peer(room, OTHER_PEER)
	var left := ns._room_seat_pet(room, 5).is_empty() \
		and not (room.get("seat_races", {}) as Dictionary).has(5) \
		and not (room.get("seat_profiles", {}) as Dictionary).has(5)
	_h.expect(left, "leave_not_cleared", "离座后座位上还留着上一个人的名片内容")
	# 后来的人不带名片（只有进程内门禁会这样）：绝不能继承前一个人的
	(room.seat_pets as Dictionary)[0] = CLIENT_PET
	ns._assign_peer_to_room(OTHER_PEER + 3, room, "", {})
	var slot3 := _slot_of(room, OTHER_PEER + 3)
	_h.expect(slot3 == 0 and ns._room_seat_pet(room, 0) == "", "seat_inherited",
		"新入座的人继承了座位上残留的宠物 %s" % ns._room_seat_pet(room, 0))
	_drop_room(room)


# --- 4. 入座请求 --------------------------------------------------------------

func _case_request_needs_card() -> void:
	var ns := NetworkService
	var rooms_before := ns._rooms.size()
	ns._rate_forget(SENDER)
	ns._rpc_team_create_room("", "")
	_h.expect(ns._rooms.size() == rooms_before and ns._room_for_peer(SENDER).is_empty(), "create_without_card",
		"不带名片也建出了房间")
	ns._rate_forget(SENDER)
	ns._rpc_team_create_room("", _signed({}, _other_key))
	_h.expect(ns._rooms.size() == rooms_before, "create_bad_card", "坏名片也建出了房间")

	# 已经坐在大厅 A 里，想换去 B 但名片不行：必须还坐在 A、A 座位上的名片内容还在
	ns._rate_forget(SENDER)
	ns._rpc_team_create_room("", _signed({"pet": CARD_PET, "races": RACES.duplicate()}))
	var room_a := ns._room_for_peer(SENDER)
	if not _h.expect(not room_a.is_empty(), "create_with_card",
			"带合法名片建房失败（后面的用例没法做）"):
		return
	var slot_a := _slot_of(room_a, SENDER)
	_h.expect(ns._room_seat_pet(room_a, slot_a) == CARD_PET, "create_card_not_on_seat",
		"建房后座位上没有名片宠物：%s" % ns._room_seat_pet(room_a, slot_a))
	var room_b := _lobby_room()
	ns._assign_peer_to_room(OTHER_PEER, room_b, "", _seat_card())
	for bad in ["", _signed({}, _other_key), "garbage"]:
		ns._rate_forget(SENDER)
		ns._rpc_team_join_room(int(room_b.id), "", bad)
		var still := ns._room_for_peer(SENDER)
		_h.expect(int(still.get("id", -1)) == int(room_a.id) and _slot_of(room_a, SENDER) == slot_a
				and ns._room_seat_pet(room_a, slot_a) == CARD_PET,
			"join_bad_card_lost_seat",
			"加入请求因名片被拒，玩家却离开了原来的座位（名片检查必须在任何改状态之前）")
	# 合法名片换房：新座位是新名片的内容，旧座位清掉
	ns._rate_forget(SENDER)
	ns._rpc_team_join_room(int(room_b.id), "", _signed({"pet": CLIENT_PET, "races": RACES.duplicate()}))
	var now_in := ns._room_for_peer(SENDER)
	_h.expect(int(now_in.get("id", -1)) == int(room_b.id), "join_with_card", "带合法名片加入房间失败")
	_h.expect(ns._room_seat_pet(room_b, _slot_of(room_b, SENDER)) == CLIENT_PET, "join_card_not_on_seat",
		"换房后新座位的宠物应为新名片上的 %s" % CLIENT_PET)
	_h.expect(ns._room_seat_pet(room_a, slot_a) == "", "join_old_seat_kept",
		"换房后旧座位上还留着宠物 %s" % ns._room_seat_pet(room_a, slot_a))
	ns._room_remove_peer(now_in, SENDER)
	_drop_room(room_a)
	_drop_room(room_b)


func _case_replay_and_prune() -> void:
	var ns := NetworkService
	var card := _signed({"pet": CARD_PET})
	ns._rate_forget(SENDER)
	ns._rpc_team_create_room("", card)
	var first := ns._room_for_peer(SENDER)
	if not _h.expect(not first.is_empty(), "replay_setup", "第一次交名片就建房失败"):
		return
	# 同一张名片再交一次：被拒 → 一人一房那段不会跑 → 人还在原来的房间
	ns._rate_forget(SENDER)
	ns._rpc_team_create_room("", card)
	_h.expect(int(ns._room_for_peer(SENDER).get("id", -1)) == int(first.id), "card_replayed",
		"同一张名片交了第二次还被收下了（换进了新房间）")
	var jti := str(_verify(card).get("card", {}).get("jti", ""))
	_h.expect(ns._seen_card_jti.has(jti), "jti_not_recorded", "用过的名片编号没记下来")
	ns._prune_seen_card_jti(_now() + 3600)
	_h.expect(not ns._seen_card_jti.has(jti), "jti_not_pruned", "过期很久的名片编号没被清掉（会一直占内存）")
	ns._room_remove_peer(first, SENDER)
	_drop_room(first)


# 专服没有公钥就拒绝启动，而且**不占端口**（检查在开端口之前）。
# 只在默认路径确实没有公钥时做 —— 开发机上若放着一把，这条就测不了，不去动它。
func _case_host_refuses_without_key() -> void:
	if BattleCard.server_key_path() != BattleCard.DEFAULT_KEY_PATH \
			or FileAccess.file_exists(BattleCard.DEFAULT_KEY_PATH):
		_h.note("本机 %s 有公钥（或命令行指了别的），跳过「缺公钥拒绝启动」—— 回归脚本里另有真进程验证"
			% BattleCard.server_key_path())
		_h.item()
		return
	var ns := NetworkService
	var started := ns.team_host(TEST_PORT, true)
	_h.expect(not started and ns.state == ns.SessionState.FAILED, "host_without_key",
		"专服缺出战名片公钥却启动了")
	var probe := ENetMultiplayerPeer.new()
	var err := probe.create_server(TEST_PORT, 1)
	_h.expect(err == OK, "host_held_port", "缺公钥启动失败后端口 %d 还被占着（err=%d）" % [TEST_PORT, err])
	probe.close()
	ns.reset()
