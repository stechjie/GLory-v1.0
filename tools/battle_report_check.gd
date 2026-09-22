extends Node

# 门禁：战报的组装与签章（scripts/multiplayer/BattleReport.gd）。
#
# 设计见 docs/排位系统设计.md 第七节。账号服务器那一侧的门禁在
# backend/tests/test_battle_report.py。
#
# ## 这条门禁验什么
#
# 五件**会静默出错**的事：
#
#   1. 签的字节和发出去的字节不是同一串 —— 账号服务器先验签再解析，
#      这边要是签一份发另一份（比如重新序列化了），所有战报都验不过，
#      而战斗服务器这边一点异常都看不到。
#   2. 战报里混进了 uid / race_relations —— 它们一局之外没有意义，
#      混进去只是让每份战报大一倍，而且是慢慢变大、没人会发现。
#   3. 没有私钥时崩掉 —— 私钥缺失是**允许的**（对局照常，只是不记历史），
#      崩了就是把一个记账功能变成了全服故障。
#   4. 把公钥当私钥放进来 —— 签不出东西，但要在加载那一步就失败，
#      不能等到签出一堆验不过的战报之后。
#   5. 上限失效 —— 战报大小必须是可预测的，不能由棋盘内容决定。
#
# 还有一件不是断言、但要打印出来的：**实测线格式大小**。
# 文档里的「5～20 KB」不该是猜的。
#
# ## 🔴 钥匙现场生成
#
# 不要把任何私钥放进 tools/ —— make_server_zip.ps1 会把整个 tools/ 打进
# 战斗服务器包。这里的钥匙每次运行现场生成，只落在 user:// 下。
#
# 跑：
#   godot --headless --path <项目> tools/battle_report_check.tscn
#
# ⚠️ 输出里有两条 `ERROR: Error parsing key` 是**负例故意触发的**（把公钥当私钥放进来、
# 放一段不是 PEM 的垃圾）。mbedTLS 自己会打这条，GDScript 侧正确返回了失败。
# 判结果看 CHECK_RESULT，不要看这两条。

const BattleReport := preload("res://scripts/multiplayer/BattleReport.gd")

const TMP_PRIVATE := "user://_check_report_key.pem"
const TMP_PUBLIC := "user://_check_report_pub.pem"
const TMP_GARBAGE := "user://_check_report_garbage.pem"

var _fail := 0
var _checks := 0


func _ready() -> void:
	_check_match_uid()
	_check_key_loading()
	_check_build_shape()
	_check_caps()
	_check_sign_roundtrip()
	_cleanup()

	if _fail == 0:
		print("CHECK_RESULT status=PASS checked=%d failures=0" % _checks)
	else:
		print("CHECK_RESULT status=FAIL checked=%d failures=%d" % [_checks, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- match_uid ----------------------------------------------------------------

func _check_match_uid() -> void:
	print("-- match_uid --")
	var a := BattleReport.new_match_uid()
	var b := BattleReport.new_match_uid()
	_expect(a.length(), 32, "长度 32")
	_expect(_is_lower_hex(a), true, "只含小写十六进制")
	# 与 database/013_match_history.sql 的 match_uid_format 约束一致：
	# 那边是 '^[0-9a-f]{32}$'，这边生成的要能过。
	_expect(a != b, true, "两次不重复")


# --- 钥匙 ---------------------------------------------------------------------

func _check_key_loading() -> void:
	print("-- 钥匙 --")
	# 1. 路径不存在：必须温和失败，不能崩、不能返回一把假钥匙
	var missing := BattleReport.load_signing_key("user://_definitely_not_here.pem")
	_expect(missing.get("key") == null, true, "缺文件时 key 为 null")
	_expect(not str(missing.get("error", "")).is_empty(), true, "缺文件时有错误文案")

	var key := Crypto.new().generate_rsa(2048)
	_write(TMP_PRIVATE, key.save_to_string(false))
	_write(TMP_PUBLIC, key.save_to_string(true))
	_write(TMP_GARBAGE, "not a pem at all")

	# 2. 只放了公钥：必须在加载这一步就失败 —— 拿公钥签不出任何东西，
	#    晚失败的代价是签出一堆验不过的战报
	var pub_only := BattleReport.load_signing_key(TMP_PUBLIC)
	_expect(pub_only.get("key") == null, true, "公钥当私钥放进来要失败")

	# 3. 垃圾内容
	var garbage := BattleReport.load_signing_key(TMP_GARBAGE)
	_expect(garbage.get("key") == null, true, "非 PEM 要失败")

	# 4. 真私钥
	var ok := BattleReport.load_signing_key(TMP_PRIVATE)
	_expect(ok.get("key") != null, true, "真私钥能加载")
	_expect(str(ok.get("error", "")), "", "真私钥不带错误文案")


# --- 组装 ---------------------------------------------------------------------

func _check_build_shape() -> void:
	print("-- 组装 --")
	var payload: Dictionary = BattleReport.build(_sample_ctx())
	_expect(int(payload.get("v", 0)), BattleReport.VERSION, "版本号")
	_expect(str(payload.get("mid", "")).length(), 32, "mid 透传")
	_expect(str(payload.get("out", "")), "team_a", "胜负照抄，不重算")

	var seats: Array = payload.get("seats", [])
	_expect(seats.size(), 6, "永远六个座位")
	# 座位不足时补空位：一局历史缺一行比多一行难查得多
	_expect(int((seats[0] as Dictionary).get("team", -1)), 0, "slot 0 是 A 队")
	_expect(int((seats[2] as Dictionary).get("team", -1)), 0, "slot 2 是 A 队")
	_expect(int((seats[3] as Dictionary).get("team", -1)), 1, "slot 3 是 B 队")
	_expect(int((seats[5] as Dictionary).get("team", -1)), 1, "slot 5 是 B 队")

	# 没名片的座位（房主加的 AI / 进程内门禁）pid 是空串，账号服务器据此写 null
	_expect(str((seats[5] as Dictionary).get("pid", "x")), "", "无名片座位 pid 为空")
	_expect(bool((seats[5] as Dictionary).get("ai", false)), true, "AI 座位标记")

	# 🔴 uid / race_relations 绝不能进战报
	var unit: Dictionary = ((seats[0] as Dictionary).get("board", []) as Array)[0]
	_expect(unit.has("uid"), false, "棋子不带 uid")
	_expect(unit.has("race_relations"), false, "棋子不带 race_relations")
	_expect(unit.has("id") and unit.has("star") and unit.has("slot"), true, "棋子带 id/star/slot")
	_expect(bool(unit.get("merc", true)), false, "棋盘位 merc=false")

	# 佣兵位接在棋盘后面，merc 一律 true（即使源数据没写这个字段）
	var board: Array = (seats[0] as Dictionary).get("board", [])
	_expect(bool((board[board.size() - 1] as Dictionary).get("merc", false)), true, "佣兵位 merc=true")

	# 不认识的模式回落 custom —— 013 的 match_mode_known 约束只认三个值，
	# 回落比让账号服务器整份丢掉好
	var bad_mode: Dictionary = BattleReport.build({"mode": "whatever"})
	_expect(str(bad_mode.get("mode", "")), "custom", "未知模式回落 custom")


func _check_caps() -> void:
	print("-- 上限 --")
	# 造一个远超上限的座位：棋盘 100 条、佣兵 100 条、宝藏 100 条。
	# 来源是服务器自己的房间状态，正常不会这么大 —— 但战报的大小必须是
	# 可预测的，不能由内容决定。
	var fat_units := []
	for i in 100:
		fat_units.append({"slot": i, "id": "unit_%d" % i, "star": 9, "uid": "u%d" % i})
	var fat_ids := []
	for i in 100:
		fat_ids.append("treasure_%d" % i)
	var ctx := _sample_ctx()
	ctx["seats"][0] = {
		"pid": "p", "board": fat_units, "mercenaries": fat_units, "treasures": fat_ids,
	}
	var seat: Dictionary = (BattleReport.build(ctx).get("seats", []) as Array)[0]
	var board: Array = seat.get("board", [])
	_expect(board.size(), BattleReport.MAX_BOARD_ENTRIES + BattleReport.MAX_MERC_ENTRIES, "棋盘+佣兵封顶 16+8")
	_expect((seat.get("treasures", []) as Array).size(), BattleReport.MAX_TREASURE_ENTRIES, "宝藏封顶")
	# star 超范围要被夹住，不是原样带过去（数据库那边没有这个约束）
	_expect(int((board[0] as Dictionary).get("star", 0)), GameConstants.MAX_STAR, "star 夹到上限")

	# 没有 id 的条目直接丢，不是塞一个空 id 进历史
	var holed: Dictionary = BattleReport.build({"seats": [{"board": [{"slot": 0, "id": ""}, {"slot": 1, "id": "ok"}]}]})
	var kept: Array = ((holed.get("seats", []) as Array)[0] as Dictionary).get("board", [])
	_expect(kept.size(), 1, "空 id 的棋子丢掉")


# --- 签章 ---------------------------------------------------------------------

func _check_sign_roundtrip() -> void:
	print("-- 签章 --")
	var payload: Dictionary = BattleReport.build(_sample_ctx())

	# 没钥匙时返回空串而不是崩 —— 这是「私钥缺失不拒绝启动」那条的另一半
	_expect(BattleReport.sign(payload, null), "", "没钥匙返回空串")

	var loaded := BattleReport.load_signing_key(TMP_PRIVATE)
	var key: CryptoKey = loaded.get("key")
	if key == null:
		_expect(false, true, "签章前置：私钥可用")
		return
	var wire := BattleReport.sign(payload, key)
	_expect(wire.is_empty(), false, "签得出来")

	var parts := wire.split(".")
	_expect(parts.size(), 2, "线格式是 body.sig")
	var body := Marshalls.base64_to_raw(parts[0])
	var sig := Marshalls.base64_to_raw(parts[1])
	_expect(sig.size(), 256, "RSA-2048 签名 256 字节")

	# 🔴 最重要的一条：签的字节解回来必须还是同一份 payload。
	# 账号服务器验完签就直接解析这串字节，两边对不上的话所有战报都会被丢掉。
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	_expect(typeof(parsed) == TYPE_DICTIONARY, true, "body 能解回字典")
	if typeof(parsed) == TYPE_DICTIONARY:
		_expect(str((parsed as Dictionary).get("mid", "")), str(payload.get("mid", "")), "mid 往返一致")
		_expect(((parsed as Dictionary).get("seats", []) as Array).size(), 6, "座位数往返一致")

	# 自己验一遍（公钥在手边）。跨语言那一半在 backend/tests/test_battle_report.py。
	var pub := CryptoKey.new()
	pub.load_from_string(FileAccess.get_file_as_string(TMP_PUBLIC), true)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(body)
	var digest := ctx.finish()
	_expect(Crypto.new().verify(HashingContext.HASH_SHA256, digest, sig, pub), true, "自验签名通过")

	# 改一个字节必须验不过
	var tampered := body.duplicate()
	tampered[0] = (tampered[0] + 1) % 256
	var ctx2 := HashingContext.new()
	ctx2.start(HashingContext.HASH_SHA256)
	ctx2.update(tampered)
	_expect(Crypto.new().verify(HashingContext.HASH_SHA256, ctx2.finish(), sig, pub), false, "改一个字节验不过")

	# 实测大小。文档里那句「5～20 KB」按这个数字写，不是猜的。
	print("   实测线格式 %d 字节（body %d / 签名 %d）" % [wire.length(), body.size(), sig.size()])


# --- 夹具 ---------------------------------------------------------------------

# 一份满配座位：16 个棋子 + 8 个佣兵 + 5 个宝藏，六个座位都这样。
# 目的是让上面那个「实测大小」是**最坏情况**，不是空房间。
func _sample_ctx() -> Dictionary:
	var seats := []
	for slot in 6:
		var board := []
		for i in GameConstants.CELL_COUNT:
			board.append({
				"slot": i, "id": "unit_dark_dragon", "star": 3,
				# 这两个故意塞进来：断言它们不会出现在战报里
				"uid": "uid-%d-%d" % [slot, i],
				"race_relations": {"sky": 1, "land": 2, "ren": 3, "dark": 4},
			})
		var mercs := []
		for i in 8:
			mercs.append({"slot": i, "id": "merc_scorpio_death", "star": 2, "uid": "m%d" % i})
		var treasures := []
		for i in 5:
			treasures.append("treasure_blood_pact_%d" % i)
		seats.append({
			# 最后一个座位没名片（房主加的 AI）—— 断言 pid 为空、ai 为 true
			"pid": "" if slot == 5 else "11111111-1111-1111-1111-11111111111%d" % slot,
			"was_ai": slot == 5,
			"online_at_end": slot != 5,
			"ai_rounds": 3 if slot == 5 else 0,
			"gold": 137, "carrots": 12, "carrots_spent": 40,
			"board": board, "mercenaries": mercs, "treasures": treasures,
		})
	return {
		"match_uid": BattleReport.new_match_uid(),
		"mode": "custom",
		"protocol": 31, "server_epoch": 2, "room_id": 123456,
		"started_at": 1758500000, "ended_at": 1758501500,
		"rounds": 21, "outcome": "team_a", "team_hp": [17, 0],
		"gold_authoritative": false, "carrot_authoritative": true,
		"seats": seats,
	}


func _cleanup() -> void:
	for path in [TMP_PRIVATE, TMP_PUBLIC, TMP_GARBAGE]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_expect(false, true, "写得出 %s" % path)
		return
	f.store_string(text)
	f.close()


func _is_lower_hex(s: String) -> bool:
	for i in s.length():
		var c := s.unicode_at(i)
		var digit := c >= 48 and c <= 57
		var lower := c >= 97 and c <= 102
		if not (digit or lower):
			return false
	return true


func _expect(got, want, label: String) -> void:
	_checks += 1
	var ok: bool = got == want
	if not ok:
		_fail += 1
	print("  %s %-38s got=%s want=%s" % ["PASS" if ok else "FAIL", label, str(got), str(want)])
