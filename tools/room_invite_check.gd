extends Node

# 房间邀请好友（bug提交和修复.docx 第 2 条）的门禁。
#
# ## 两类断言都要有（9.24 的教训：缺哪类就有哪类盲区）
#
#   · **行为断言** —— 直接驱动生产实现 scripts/multiplayer/RoomInvite.gd 的 static 纯函数：
#     失效四判据、限流两判据、payload 组装/解析、文案。探针**只驱动那一份实现**，
#     绝不在这里复刻一份判据（复刻版会跟生产漂移，测了等于没测）。
#   · **结构断言** —— 「谁在调用它」。行为断言看不见接线：把 lobby 的邀请调用删掉，
#     纯函数照样全绿。所以另加一组「调用点还在不在」的存在性断言
#     （注释感知：只认**没被注释掉**的代码，见 _has_live_code）。
#
# ## 判据不自证
#
# 失效判据的期望值由**需求原文**独立写出（20 分钟 = 1200 秒、异房间隔 10 秒、
# 同房一次），不从被测量反推。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const RoomInvite := preload("res://scripts/multiplayer/RoomInvite.gd")

const CHECK_NAME := "room_invite"

# 需求里的数，**在这里独立写死**，不引用 RoomInvite 的常量 ——
# 否则把 EXPIRE_SEC 改成 5 分钟，断言会跟着一起改，等于没判。
const WANT_EXPIRE_SEC := 1200
const WANT_RATE_SEC := 10

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_behavior_constants()
	_behavior_payload()
	_behavior_expiry()
	_behavior_rate_limit()
	_behavior_dedupe()
	_structure_client()
	_structure_backend_pipeline()
	_structure_single_spelling()
	_h.finish(get_tree())


# --- 行为：常量与文案 ----------------------------------------------------------

func _behavior_constants() -> void:
	_h.expect(RoomInvite.KIND == "room_invite", "kind_value",
		"kind 必须是 room_invite（与 backend/app/chat.py 的 ROOM_INVITE_KIND 同值）")
	_h.expect(RoomInvite.EXPIRE_SEC == WANT_EXPIRE_SEC, "expire_const",
		"有效期常量必须是需求里的 20 分钟（%d 秒）" % WANT_EXPIRE_SEC)
	_h.expect(RoomInvite.RATE_LIMIT_SEC == WANT_RATE_SEC, "rate_const",
		"异房间隔常量必须是需求里的 10 秒")
	# 文案逐字等于需求（要求 3）。
	_h.expect(RoomInvite.TEXT_ZH == "我开启了新的房间，一起来玩吧", "text_zh",
		"邀请框文案必须逐字等于需求给的那句")
	_h.expect(RoomInvite.EXPIRED_ZH == "邀请已过时", "expired_zh",
		"失效提示必须逐字等于「邀请已过时」")
	# 后端常量对得上（对不上的症状是「邀请发出去对方收不到」，不报错）。
	var backend := FileAccess.get_file_as_string("res://backend/app/chat.py")
	_h.expect(backend.contains('ROOM_INVITE_KIND = "room_invite"'), "backend_kind",
		"后端 chat.py 必须定义同一个 ROOM_INVITE_KIND 字面量")


# --- 行为：payload -------------------------------------------------------------

func _behavior_payload() -> void:
	var payload := RoomInvite.make_payload(123)
	_h.expect(int(payload.get("room_id", 0)) == 123, "payload_room",
		"make_payload 把房间号放进 room_id")

	var invite := {"kind": "room_invite", "body": "x", "payload": {"room_id": 77}}
	_h.expect(RoomInvite.is_invite(invite), "is_invite_true", "kind 对了就是邀请")
	_h.expect(not RoomInvite.is_invite({"kind": "text", "body": "hi"}), "is_invite_false",
		"普通文本不是邀请")
	_h.expect(not RoomInvite.is_invite({"body": "hi"}), "is_invite_missing_kind",
		"没有 kind 字段时不是邀请（老消息不能崩）")
	_h.expect(RoomInvite.room_id_of(invite) == 77, "room_id_of", "从 payload 取到房间号")
	_h.expect(RoomInvite.room_id_of({"kind": "text", "body": "hi"}) == 0, "room_id_of_text",
		"普通文本取房间号返回 0")
	_h.expect(RoomInvite.room_id_of({"kind": "room_invite", "payload": "oops"}) == 0,
		"room_id_of_bad_payload", "payload 不是字典时返回 0 而不是崩")
	# 显示文案优先用服务端存下来的 body。
	_h.expect(RoomInvite.display_text({"body": "服务端存的", "kind": "room_invite"}) == "服务端存的",
		"display_prefers_body", "有 body 就用 body")
	_h.expect(not RoomInvite.display_text({"body": "", "kind": "room_invite"}).is_empty(),
		"display_fallback", "body 空时退回本地文案，不留空白框")


# --- 行为：失效四判据（要求 5）-------------------------------------------------

func _behavior_expiry() -> void:
	var room := 1000
	var now := 1_000_000
	var created := now - 60  # 一分钟前发的，没过期

	# 基线：一切都正常 → 有效。
	_h.expect(not RoomInvite.is_expired(room, created, now, room, false), "valid_baseline",
		"房间在、没超时、邀请人还在、没开打 → 有效")

	# ① 房间已解散（拿不到号）。
	_h.expect(RoomInvite.is_expired(0, created, now, 0, false), "expired_dissolved",
		"房间已解散（号回收）→ 失效")

	# ② 20 分钟到了。边界两侧都要判：1199 秒有效、1200 秒失效。
	var t1199 := now - (WANT_EXPIRE_SEC - 1)
	var t1200 := now - WANT_EXPIRE_SEC
	_h.expect(not RoomInvite.is_expired(room, t1199, now, room, false), "boundary_1199",
		"过去 %d 秒仍然有效（边界内侧）" % (WANT_EXPIRE_SEC - 1))
	_h.expect(RoomInvite.is_expired(room, t1200, now, room, false), "boundary_1200",
		"过去 %d 秒即失效（边界上）" % WANT_EXPIRE_SEC)

	# ③ 邀请人已离开该房间：换到别的号、或确定不在任何房间（0），都要失效。
	_h.expect(RoomInvite.is_expired(room, created, now, room + 1, false), "expired_left_room",
		"邀请人换到别的房间 → 失效")
	_h.expect(RoomInvite.is_expired(room, created, now, 0, false), "expired_left_all",
		"邀请人已不在任何房间（0 = 确定）→ 失效")

	# ④ 对局已开始。
	_h.expect(RoomInvite.is_expired(room, created, now, room, true), "expired_started",
		"该房间已开打 → 失效")

	# 🔴 「查不到」一律当有效 —— 但必须与「0 = 确定不在房间」分开：
	#    0 走上面 expired_left_all（失效），UNKNOWN_ROOM 才放过。
	_h.expect(not RoomInvite.is_expired(room, 0, now, room, false), "unknown_created_ok",
		"拿不到创建时间 → 当有效（误杀比漏判严重）")
	_h.expect(not RoomInvite.is_expired(room, created, now, RoomInvite.UNKNOWN_ROOM, false),
		"unknown_inviter_ok", "查不到邀请人房间（哨兵）→ 不因这一条判失效")
	_h.expect(RoomInvite.UNKNOWN_ROOM != 0, "unknown_room_sentinel",
		"哨兵必须不等于 0 —— 否则「查不到」与「确定不在房间」又混成一个值")

	# 便捷重载与主函数同口径。
	var invite := {"kind": "room_invite", "body": "x", "payload": {"room_id": room}}
	_h.expect(not RoomInvite.message_is_expired(invite, created, now, room, false),
		"message_overload_valid", "从消息直接判：有效")
	_h.expect(RoomInvite.message_is_expired(invite, created, now, room, true),
		"message_overload_expired", "从消息直接判：已开打 → 失效")


# --- 行为：发送限流（要求 4）---------------------------------------------------

func _behavior_rate_limit() -> void:
	var now := 2_000_000
	# 同一房间对同一位好友只发一次。
	_h.expect(RoomInvite.send_blocked_reason(now, 0, true) == "duplicate", "block_duplicate",
		"同房同好友已发过 → duplicate")
	# 异房间隔 10 秒：9 秒拦、10 秒放（边界两侧）。
	_h.expect(RoomInvite.send_blocked_reason(now, now - 9, false) == "rate_limited",
		"block_rate_9s", "距上次 9 秒 → rate_limited")
	_h.expect(RoomInvite.send_blocked_reason(now, now - WANT_RATE_SEC, false) == "",
		"allow_rate_10s", "距上次正好 10 秒 → 放行（边界上）")
	_h.expect(RoomInvite.send_blocked_reason(now, now - 60, false) == "", "allow_after_minute",
		"距上次一分钟 → 放行")
	# 从没发过。
	_h.expect(RoomInvite.send_blocked_reason(now, 0, false) == "", "allow_first",
		"本场第一次邀请 → 放行")
	# 两个原因都给得出人话（不给空串，否则提示是一条空白）。
	_h.expect(not RoomInvite.send_blocked_text("duplicate").is_empty()
		and not RoomInvite.send_blocked_text("rate_limited").is_empty(),
		"block_text", "两种拦截原因都有可读文案")


# --- 行为：显示去重（要求 4：被邀请方只会收到一次）------------------------------

func _behavior_dedupe() -> void:
	var a := {"message_id": 1, "kind": "room_invite", "payload": {"room_id": 7}, "body": "x"}
	var b := {"message_id": 2, "kind": "text", "body": "hi"}
	var c := {"message_id": 3, "kind": "room_invite", "payload": {"room_id": 7}, "body": "x"}
	var d := {"message_id": 4, "kind": "room_invite", "payload": {"room_id": 9}, "body": "x"}
	var out := RoomInvite.dedupe_for_display([a, b, c, d])
	_h.expect(out.size() == 3, "dedupe_count", "同房重复邀请只留一条，实测 %d 条" % out.size())
	var kept: Array[int] = []
	for m in out:
		kept.append(int((m as Dictionary).get("message_id", 0)))
	_h.expect(not kept.has(1) and kept.has(3), "dedupe_keeps_latest",
		"同一房间保留最后一条（1 隐藏、3 保留），实测 %s" % str(kept))
	_h.expect(kept.has(2) and kept.has(4), "dedupe_keeps_others",
		"普通消息与其他房间的邀请都要保留，实测 %s" % str(kept))
	_h.expect(RoomInvite.dedupe_for_display([b]).size() == 1, "dedupe_noop",
		"没有邀请时原样返回（不去重）")
	# payload 坏的邀请不参与去重（各算各的），也不能崩。
	var broken := {"message_id": 5, "kind": "room_invite", "payload": "oops", "body": "x"}
	_h.expect(RoomInvite.dedupe_for_display([broken, broken.duplicate()]).size() == 2,
		"dedupe_broken_payload", "坏 payload 的邀请不去重，也不崩")


# --- 结构：接线还在不在 --------------------------------------------------------

func _structure_client() -> void:
	var chat := FileAccess.get_file_as_string("res://scenes/menu/ChatScreen.gd")
	var lobby := FileAccess.get_file_as_string("res://scenes/menu/Team3v3Lobby.gd")
	var main := FileAccess.get_file_as_string("res://scenes/main/Main.gd")
	var account := FileAccess.get_file_as_string("res://scripts/autoload/AccountManager.gd")

	# ChatScreen：邀请框 + 立即参与 + 失效出口。
	_h.expect(_has_live_code(chat, "signal join_room_requested"),
		"chat_signal", "ChatScreen 必须有 join_room_requested 信号")
	_h.expect(_has_live_code(chat, "RoomInvite.is_invite(msg)"),
		"chat_branch", "ChatScreen 的气泡必须分流邀请（否则邀请渲染成普通文本）")
	_h.expect(_has_live_code(chat, "RoomInvite.expired_text()"),
		"chat_expired", "失效时必须走 RoomInvite.expired_text()（单一文案源）")
	_h.expect(chat.contains("立即参与"), "chat_join_label", "邀请框上必须有「立即参与」按钮")
	_h.expect(_has_live_code(chat, "join_room_requested.emit(room_id)"),
		"chat_emit", "有效邀请必须发 join_room_requested 去加入")
	_h.expect(_has_live_code(chat, "RoomInvite.is_expired("),
		"chat_expiry_call", "点「立即参与」必须过 RoomInvite.is_expired 这一关")

	# Team3v3Lobby：点好友名发邀请 + 亮一下 + 走限流。
	_h.expect(_has_live_code(lobby, "RoomInvite.send_blocked_reason"),
		"lobby_rate", "大厅发邀请前必须过 send_blocked_reason（要求 4）")
	_h.expect(_has_live_code(lobby, "RoomInvite.make_payload"),
		"lobby_payload", "大厅邀请必须带 make_payload 造的 payload")
	_h.expect(_has_live_code(lobby, "_flash_row("),
		"lobby_flash", "点击成功要亮一下（要求 1）")
	_h.expect(_has_live_code(lobby, "gui_input.connect"),
		"lobby_clickable", "朋友列表每一行必须可点（点击好友 ID 即邀请）")

	# Main：把信号接到已有的加入路径。
	_h.expect(_has_live_code(main, "join_room_requested.connect"),
		"main_route", "Main 必须把 join_room_requested 接进加入流程")

	# AccountManager：发送必须能带 kind/payload。
	_h.expect(account.contains("func send_chat_message(") and account.contains("kind: String"),
		"account_kind_param", "send_chat_message 必须能带 kind 参数")

	# 点击反馈的顺序（要求 1）：必须**先亮一下、再判限流**。
	# 反过来的话，「同一房间已经邀请过」时点了什么都不发生 —— 玩家以为没点到，
	# 而那正是实测「点击没有亮一下」的原因。
	var flash_at := lobby.find("_flash_row(row)")
	var check_at := lobby.find("send_blocked_reason")
	_h.expect(flash_at >= 0 and check_at >= 0 and flash_at < check_at, "lobby_flash_first",
		"必须先 _flash_row 再 send_blocked_reason，实测 flash@%d check@%d" % [flash_at, check_at])

	# 不再弹「已经邀请过了」：旧写法把拦截原因整个交给 send_blocked_text(blocked)，
	# 于是 duplicate 也被弹出来。断言那个写法与那句话都消失（注释感知）。
	_h.expect(not _has_live_code(lobby, "send_blocked_text(blocked)"), "lobby_no_dup_toast",
		"不得再用 send_blocked_text(blocked) —— 那会把「已经邀请过了」弹给玩家")
	_h.expect(not _has_live_code(lobby, "已经邀请过了"), "lobby_no_dup_word",
		"大厅源码里不该再有「已经邀请过了」这句提示")

	# 显示层去重 + 邀请框方框化（要求 3/4）。
	_h.expect(_has_live_code(chat, "RoomInvite.dedupe_for_display("), "chat_dedupe",
		"ChatScreen 渲染前必须过 dedupe_for_display（同房重复邀请只显示一条）")
	_h.expect(_has_live_code(chat, "RoomInvite.title_text()"), "chat_invite_title",
		"邀请框要有小标题（与普通气泡区分开）")


# --- 结构：后端把 kind 带出去的三处管道 -----------------------------------------
#
# 这三处任何一处漏掉，症状都是「邀请在收件人那头渲染成普通文本 / 收不到」，都不报错。
# 实测（2026-09-27 第二轮）踩到的就是：客户端传了 kind，后端**根本没读**
# （SendBody 没字段），于是邀请按 text 落库、按 text 推送；连 history 也把 kind 丢了。
func _structure_backend_pipeline() -> void:
	var routes := FileAccess.get_file_as_string("res://backend/app/routes/chat.py")
	var chat := FileAccess.get_file_as_string("res://backend/app/chat.py")

	_h.expect(chat.contains("import json"), "backend_json_import",
		"chat.py 必须 import json —— payload 编解码用它，漏了邀请一进库就 NameError")
	_h.expect(_has_live_code(chat, "select message_id, sender_id, body, created_at, kind, payload"),
		"backend_history_select", "history 的 SQL 必须把 kind/payload 选出来")
	_h.expect(_has_live_code(chat, "_decode_payload(r[\"payload\"])"), "backend_history_decode",
		"history 组装 Message 时必须解出 payload")
	_h.expect(_has_live_code(chat, "Message(message_id, sender_id, body, row[\"created_at\"], kind, payload)"),
		"backend_send_return_kind", "chat.send 的返回 Message 必须带 kind/payload")
	# 🔴 「SendBody 有 kind」这条必须**限定在 SendBody 类体里**判 ——
	# MessageItem 也有一个同名的 `kind: str = "text"`，直接对整份 routes 做 contains
	# 会被它顶上：SendBody 把字段删了，断言照样绿（本轮实测踩到的假绿）。
	var send_body := _class_body(routes, "class SendBody(BaseModel):")
	_h.expect(send_body.contains("kind: str = \"text\""), "backend_sendbody_kind",
		"routes 的 SendBody 类体里必须有 kind 字段（没有它，客户端传了也丢）")
	_h.expect(send_body.contains("payload: dict | None"), "backend_sendbody_payload",
		"routes 的 SendBody 类体里必须有 payload 字段")
	_h.expect(_has_live_code(routes, "_validated_invite_payload(body)"), "backend_invite_validate",
		"routes 必须校验 invite payload（房间号 > 0）")
	_h.expect(_has_live_code(routes, "text, body.client_msg_id, kind, payload"), "backend_pass_through",
		"routes 必须把 kind/payload 转发给 chat.send —— 不转发就是「传了没人读」")


# --- 结构：文案只有一处拼法 ----------------------------------------------------

func _structure_single_spelling() -> void:
	# 「我开启了新的房间」这句话**只能出现在 RoomInvite.gd**（脚本/场景范围内）。
	# 两处抄一遍的结果是：改文案时只改一处，两边的邀请长得不一样，且不报错。
	var dupes := _files_containing("res://scripts", "我开启了新的房间")
	dupes += _files_containing("res://scenes", "我开启了新的房间")
	_h.expect(dupes.size() == 1 and dupes[0].ends_with("RoomInvite.gd"), "single_text_spelling",
		"邀请文案只许在 RoomInvite.gd 出现，实测：%s" % str(dupes))

	var dup_expired := _files_containing("res://scripts", "邀请已过时")
	dup_expired += _files_containing("res://scenes", "邀请已过时")
	_h.expect(dup_expired.size() == 1 and dup_expired[0].ends_with("RoomInvite.gd"),
		"single_expired_spelling", "「邀请已过时」只许在 RoomInvite.gd 出现，实测：%s" % str(dup_expired))


# --- 小工具 -------------------------------------------------------------------

# 注释感知的「这段代码还活着吗」：把 GDScript 的 `#` 行注释剥掉再找。
#
# 为什么不能裸 contains：9.24 的坑 —— 把整行**注释掉**（或改成 `if false and ...`）
# 之后，源码文本里那个标识符照样在，裸 contains 依旧绿。这里只做
# 「调用点还在不在」这类存在性判断，所以剥行注释就够了（不做字符串字面量感知，
# 那需要完整词法；本文件里没有把 `#` 放进字符串的情况）。
func _has_live_code(source: String, needle: String) -> bool:
	for line in source.split("\n"):
		var code := line
		var hash := code.find("#")
		if hash >= 0:
			code = code.substr(0, hash)
		if code.contains(needle):
			return true
	return false


# 取出某个 Python 类的源码块（class 行 → 下一个顶层 class/def/装饰器之前）。
#
# 用途：把「SendBody 必须有 kind」这类断言**限定在那个类里**。直接对整份文件
# contains('kind: str = "text"') 会被 MessageItem 的同名字段顶上 ——
# 两个类共用一个字段名时，那个断言就永远绿（本轮实测踩到的假绿）。
func _class_body(source: String, header: String) -> String:
	var start := source.find(header)
	if start < 0:
		return ""
	var rest := source.substr(start + header.length())
	var cut := rest.length()
	for marker in ["\nclass ", "\ndef ", "\nasync def ", "\n@"]:
		var at := rest.find(marker)
		if at >= 0:
			cut = mini(cut, at)
	return rest.substr(0, cut)


# 在某个目录下递归找出**含该字符串**的 .gd 文件（用于「文案只有一处」）。
func _files_containing(root: String, needle: String) -> Array[String]:
	var out: Array[String] = []
	_walk(root, needle, out)
	out.sort()
	return out


func _walk(dir_path: String, needle: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full: String = dir_path.path_join(name)
		if dir.current_is_dir():
			_walk(full, needle, out)
		elif name.ends_with(".gd"):
			# 注释感知：注释里出现那句话不算「第二处拼法」——
			# 把说明写成注释是正常的，判据该盯的是**真在代码里拼的那一份**。
			if _has_live_code(FileAccess.get_file_as_string(full), needle):
				out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
