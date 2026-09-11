extends Node

# 聊天系统批次 A 的验收（`docs/聊天系统设计.md`）。
#
# 核心判据，每条都对应一个**不会报错、只会静默说错话或开洞**的失败：
#
#   1. 🔴 `_rpc_team_chat_submit` 的签名里**不许出现 slot** —— 客户端一旦能自报
#      座位号就等于能「以队友的名义说话」，而这种伪造在界面上完全看不出来
#   2. 🔴 短语 id 集合被钉死 —— id 重排会让旧客户端发的 7 号在新表里变成另一句话，
#      不报错、不崩溃，只是说错话，且只在版本混用时出现
#   3. 🔴 `RateLimitService.LIMITS` 里必须有 "chat_phrase" —— 删掉它不会报错，
#      `allow()` 会静默退回默认额度 20，等于把限流悄悄放宽四倍
#   4. `text()` 对非法 id 返回**空串**而不是占位符 —— 占位符会让协议错误
#      在界面上长得像一条正常消息，于是没人会去查
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/chat_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const ChatPhrases := preload("res://scripts/multiplayer/ChatPhrases.gd")
const RateLimitService := preload("res://scripts/multiplayer/RateLimitService.gd")
const NetworkConfig := preload("res://scripts/multiplayer/NetworkConfig.gd")

const CHECK_NAME := "chat"

const NETWORK_SERVICE_PATH := "res://scripts/autoload/NetworkService.gd"

# 🔴 这份快照就是「id 不许重排」那条纪律的机器可读版本。
#
# 改这个数组之前先想清楚你在做哪一种改动：
#   - 在 ChatPhrases 末尾**追加**新句子 → 这里也追加。合法
#   - **删掉**一句 → 这里也删掉，且 ChatPhrases 里后面的 id 绝不往前挪。合法
#   - 改某个 id 的文本（错别字）→ 这里不用动。合法
#   - 把某个 id 指向另一句话 → **不合法**，那正是这条断言在挡的
const EXPECTED_IDS := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]

# 🔴 NetworkService 上 @rpc 方法的数量，与协议号绑在一起。同 carrot_online_check
# 的 PINNED_CONTRACT / PINNED_PROTOCOL 那一套，理由见 _case_rpc_count_pinned()。
const PINNED_RPC_COUNT := 55
const PINNED_RPC_PROTOCOL := 22

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_submit_rpc_has_no_slot_param()
	_case_ids_frozen()
	_case_table_shape()
	_case_groups_cover_every_id()
	_case_group_order_stable()
	_case_is_valid_id_rejects_junk()
	_case_text_empty_for_bad_id()
	_case_rate_limit_entry_exists()
	_case_rate_limit_is_soft()
	_case_ui_scripts_parse()
	_case_prep_log_ignores_mouse()
	_case_rpc_count_pinned()
	_case_ws_constants_match_backend()
	_case_chat_constants_match_backend()
	_case_token_refresh_wired()
	_case_chat_entry_wired()
	_h.finish(get_tree())


# --- 7. 🔴 客户端与后端的跨语言常量 ---------------------------------------------

func _case_ws_constants_match_backend() -> void:
	# 与 friends_check 钉「心跳间隔 vs 后端 TTL」完全同一类问题：
	# **同一个约定写在两种语言里，分开改不会有任何症状。**
	#
	# 这几条对不上的表现分别是：
	#   关闭码   —— 被顶号会被当成普通掉线，于是客户端一直重连，两台设备无限互踢
	#   设备正则 —— 握手被服务端 1008 拒绝，而客户端只看到「连不上」，
	#               排查的人会先去怀疑令牌
	# 两种都不报错。
	var py := FileAccess.get_file_as_string("res://backend/app/realtime.py")
	var gd := FileAccess.get_file_as_string("res://scripts/autoload/RealtimeService.gd")
	_h.item()
	if py.is_empty() or gd.is_empty():
		_h.fail("ws_source_unreadable", "读不到 realtime.py 或 RealtimeService.gd")
		return
	_h.expect(true, "", "")

	for pair in [["CLOSE_KICKED", 4001], ["CLOSE_IDLE", 4002]]:
		var name := str(pair[0])
		var value := int(pair[1])
		_h.item()
		_h.expect(py.contains("%s = %d" % [name, value]), "ws_close_code_drift_py",
			"backend/app/realtime.py 里的 %s 不是 %d 了。" % [name, value]
			+ "客户端 RealtimeService.gd 还按旧值判 —— 被顶号会被当成普通掉线，"
			+ "然后两台设备开始无限互踢。")
		_h.item()
		_h.expect(gd.contains("const %s := %d" % [name, value]), "ws_close_code_drift_gd",
			"RealtimeService.gd 里的 %s 不是 %d 了（后端仍是）。" % [name, value])

	# 设备标识的形状。后端是正则，客户端是逐字符判，写法不同但约定必须一样。
	_h.item()
	_h.expect(FileAccess.get_file_as_string("res://backend/app/routes/ws.py")
			.contains("[A-Za-z0-9_-]{8,64}"),
		"ws_device_regex_drift",
		"backend/app/routes/ws.py 的 _DEVICE_RE 变了。"
		+ "RealtimeService._is_valid_device_id 是照它逐字符实现的，两边必须一起改 —— "
		+ "对不上的症状是握手被 1008 拒绝，而客户端只显示「连不上」。")
	_h.item()
	_h.expect(gd.contains("value.length() < 8 or value.length() > 64"),
		"ws_device_length_drift",
		"RealtimeService._is_valid_device_id 的长度范围与后端 {8,64} 对不上了。")

	# 心跳间隔必须由服务端下发，客户端只留兜底值。
	# 写死两份的话，改了服务端而客户端还按旧值发，会被判成超时掉线。
	_h.item()
	_h.expect(gd.contains("payload.get(\"heartbeat_sec\""), "ws_heartbeat_hardcoded",
		"客户端必须用服务端 ready 里下发的 heartbeat_sec，不能只用本地常量。")


# --- 8. 🔴 私聊（批次 C）的跨语言常量 --------------------------------------------

func _case_chat_constants_match_backend() -> void:
	# 同上一条：同一个约定写在三种地方（Python / SQL / GDScript），分开改不会有任何症状。
	#   "dm"   —— 对不上的话推送全部掉进 RealtimeService 的「未知类型」分支：
	#             不报错，就是收不到，玩家只会觉得「对方的消息要重新打开才看得见」
	#   200 字 —— 客户端放行、服务端 400；或者反过来，客户端先截断了合法的长消息
	#   200 条 —— 客户端缓存与服务端存的对不上，重连补拉时会多出或少掉几条
	var svc := FileAccess.get_file_as_string("res://scripts/autoload/ChatService.gd")
	var routes := FileAccess.get_file_as_string("res://backend/app/routes/chat.py")
	var guard := FileAccess.get_file_as_string("res://backend/app/text_guard.py")
	var chat_py := FileAccess.get_file_as_string("res://backend/app/chat.py")
	var sql := FileAccess.get_file_as_string("res://database/007_chat.sql")
	var screen := FileAccess.get_file_as_string("res://scenes/menu/ChatScreen.gd")
	_h.item()
	for src in [svc, routes, guard, chat_py, sql, screen]:
		if str(src).is_empty():
			_h.fail("chat_source_unreadable",
				"读不到私聊相关的源文件（ChatService.gd / ChatScreen.gd / routes/chat.py / "
				+ "text_guard.py / chat.py / 007_chat.sql）")
			return

	_h.expect(routes.contains("DM_TYPE = \"dm\"") and svc.contains("const DM_TYPE := \"dm\""),
		"chat_dm_type_drift",
		"推送的消息类型两边不是同一个串了（routes/chat.py 的 DM_TYPE vs ChatService.DM_TYPE）。"
		+ "对不上的症状是推送收不到，而且不报错。")
	_h.expect(guard.contains("CHAT_MAX = 200") and svc.contains("const MAX_BODY_CHARS := 200")
			and sql.contains("char_length(body) between 1 and 200"),
		"chat_max_chars_drift",
		"私聊单条上限在 text_guard.CHAT_MAX / ChatService.MAX_BODY_CHARS / "
		+ "007 的 chat_body_length 三处不一致了。")
	_h.expect(chat_py.contains("KEEP_PER_CONVERSATION = 200")
			and svc.contains("const HISTORY_LIMIT := 200"),
		"chat_history_limit_drift",
		"每对保留条数 chat.KEEP_PER_CONVERSATION 与客户端 ChatService.HISTORY_LIMIT 对不上了。")
	# 输入框上限必须引用常量，不许写死一个数 —— 写死的那个数就是下一次漂移的起点。
	_h.expect(screen.contains("max_length = ChatService.MAX_BODY_CHARS"),
		"chat_input_limit_hardcoded",
		"ChatScreen 的输入框上限必须用 ChatService.MAX_BODY_CHARS，不能写死。")


# --- 9. 🔴 令牌续期接上了 --------------------------------------------------------

func _case_token_refresh_wired() -> void:
	# access token 一小时过期。续期断掉的症状是「开着游戏满一小时，聊天、好友、在线状态
	# 一起开始失败」，而且只在长时间游玩时出现 —— 本机调试几乎撞不到。
	var am := FileAccess.get_file_as_string("res://scripts/autoload/AccountManager.gd")
	var rt := FileAccess.get_file_as_string("res://scripts/autoload/RealtimeService.gd")
	_h.item()
	if am.is_empty() or rt.is_empty():
		_h.fail("refresh_source_unreadable", "读不到 AccountManager.gd 或 RealtimeService.gd")
		return
	# 401 之后只重试一次：重试那一趟必须带 allow_refresh=false，否则续期失败时会无限递归。
	_h.expect(am.contains("return await _request(method, path, payload, authed, false)"),
		"refresh_retry_unbounded",
		"AccountManager._request 收到 401 后的重试必须传 allow_refresh=false（只重试一次）。")
	# 到期判断必须用墙钟：手机切后台时引擎不跑帧，Timer 跟着停，回来时令牌早过期了。
	_h.expect(am.contains("Time.get_unix_time_from_system() >= _token_expires_at"),
		"refresh_not_wall_clock",
		"令牌到期判断必须用墙钟（Time.get_unix_time_from_system），不能用 Timer。")
	# WebSocket 建连前先保证令牌够新 —— 否则断线重连会拿着过期令牌永远握手失败。
	_h.expect(rt.contains("await AccountManager.ensure_fresh_token()"),
		"realtime_stale_token",
		"RealtimeService._open 建连前必须先 AccountManager.ensure_fresh_token()。")


# --- 10. 私聊入口接上了 -----------------------------------------------------------

func _case_chat_entry_wired() -> void:
	# 同 friends_check 里「朋友」按钮那一条：按钮还连着「敬请期待」的话，
	# 整个私聊根本进不去 —— 而这不会报错。
	var menu_src := FileAccess.get_file_as_string("res://scenes/menu/MainMenu.gd")
	var main_src := FileAccess.get_file_as_string("res://scenes/main/Main.gd")
	_h.item()
	if menu_src.is_empty() or main_src.is_empty():
		_h.fail("entry_source_unreadable", "读不到 MainMenu.gd 或 Main.gd")
		return
	_h.expect(menu_src.contains("Vector2(28, 440), Vector2(132, 132), _emit_chat"),
		"chat_menu_button_not_wired",
		"主菜单「聊天」按钮没接到 _emit_chat（还连着 _show_coming_soon？）")
	_h.expect(main_src.contains("_menu.chat_requested.connect(_show_chat_screen)"),
		"chat_route_missing", "Main._show_menu 没把 chat_requested 接到 _show_chat_screen")
	_h.expect(main_src.contains("\t_install_realtime()"), "realtime_not_installed",
		"Main._ready 没调 _install_realtime() —— WebSocket 永远不会连，私聊收不到推送。")


# --- 0. 🔴 加 @rpc 方法必须顶协议号 --------------------------------------------

func _case_rpc_count_pinned() -> void:
	# **2026-09-10 实测踩过**：本系统加了两个 @rpc 方法却没顶
	# NETWORK_PROTOCOL_VERSION，客户端连线上服务器时直接刷
	#     process_simplify_path: The rpc node checksum failed.
	#     Make sure to have the same methods on both nodes. Node path: NetworkService
	# 这条错误本身还不是最要命的 —— 它背后的事实是两端方法表已经不一致，
	# 而那意味着**方法编号错位、RPC 可能被派发到别的方法上**（v17 注释）。
	# 方法表不一致时联机行为是未定义的，不要靠观察症状判断"是不是还能用"。
	#
	# NetworkConfig 的 v17 注释早就写过同一条（"加 @rpc 方法会平移整套 RPC 的
	# wire ID"），v18 那格更是"补顶的"。踩过三次的东西该由断言挡着，不该靠记性。
	#
	# 这条只要求「数量变了就必须顶号」。顶号之后**还要重新打包部署战斗服务器**，
	# 那一步机器验不了 —— 服务器启动日志里的 `server started protocol=N` 才是证据。
	_h.item()
	var src := FileAccess.get_file_as_string(NETWORK_SERVICE_PATH)
	if src.is_empty():
		_h.fail("network_service_unreadable", "读不到 %s" % NETWORK_SERVICE_PATH)
		return
	var count := 0
	for line in src.split("\n"):
		if line.begins_with("@rpc("):
			count += 1
	if count == PINNED_RPC_COUNT:
		return
	_h.expect(int(NetworkConfig.NETWORK_PROTOCOL_VERSION) != PINNED_RPC_PROTOCOL,
		"rpc_added_without_protocol_bump",
		"NetworkService 的 @rpc 方法数变了（%d -> %d），但 NETWORK_PROTOCOL_VERSION "
			% [PINNED_RPC_COUNT, count]
		+ "还是 %d。旧服务器与新客户端的 scene cache 校验会失败，"
			% int(NetworkConfig.NETWORK_PROTOCOL_VERSION)
		+ "整个 NetworkService 的 RPC 全部失效。请顶协议号、把 PINNED_RPC_COUNT / "
		+ "PINNED_RPC_PROTOCOL 一起改成新值，**并重新打包部署战斗服务器**。")


# --- 1. 🔴 客户端不许自报座位号 ------------------------------------------------

func _case_submit_rpc_has_no_slot_param() -> void:
	_h.item()
	var src := FileAccess.get_file_as_string(NETWORK_SERVICE_PATH)
	if src.is_empty():
		_h.fail("network_service_unreadable", "读不到 %s" % NETWORK_SERVICE_PATH)
		return
	# 源码断言而不是反射：反射拿不到参数名，而这条要挡的正是「多了一个叫 slot
	# 的参数」。同 backend 那条钉着 optional_claims 里不许出现 raise 的 AST 断言。
	var expected := "func _rpc_team_chat_submit(phrase_id: int) -> void:"
	_h.expect(src.contains(expected), "chat_submit_signature_changed",
		"`_rpc_team_chat_submit` 的签名变了。它必须**只收 phrase_id**：座位号一律由"
		+ "服务端从 sender 反查（peer_slot[sender]）。让客户端带 slot 就是开放"
		+ "「以队友的名义说话」，收到的人没有任何东西能让他起疑。期望：%s" % expected)

	_h.item()
	# 服务端那一跳必须限流，且必须是软限（不计 strike）。漏掉限流的历史踩法见
	# NetworkService 里 prep_mercs 那条注释：「配置表里明明有这一项，只是从来没人调过」。
	_h.expect(src.contains("_rate_ok(sender, \"chat_phrase\", false)"),
		"chat_rate_limit_not_called",
		"服务端的 `_rpc_team_chat_submit` 必须调 `_rate_ok(sender, \"chat_phrase\", false)`。"
		+ "配置表里有额度但没人调它 = 限流根本没生效，且这件事不会有任何症状。")


# --- 2. 🔴 短语 id 集合被钉死 --------------------------------------------------

func _case_ids_frozen() -> void:
	_h.item()
	var actual: Array = ChatPhrases.PHRASES.keys()
	actual.sort()
	_h.expect(actual == EXPECTED_IDS, "phrase_ids_changed",
		"短语 id 集合变了。期望 %s，实际 %s。如果这是有意的追加/删除，"
		% [EXPECTED_IDS, actual]
		+ "同步改 tools/chat_check.gd 的 EXPECTED_IDS；如果是把某个 id 指向了另一句话，"
		+ "**那是不允许的** —— 旧客户端发的同一个 id 会在新表里变成另一句话。")


# --- 3. 表结构 ----------------------------------------------------------------

func _case_table_shape() -> void:
	for phrase_id in ChatPhrases.PHRASES.keys():
		_h.item()
		var ok := typeof(phrase_id) == TYPE_INT and int(phrase_id) > 0
		if not ok:
			_h.fail("phrase_id_not_positive_int", "短语 id 必须是正整数，实际 %s" % [phrase_id])
			continue
		var entry: Variant = ChatPhrases.PHRASES[phrase_id]
		if typeof(entry) != TYPE_DICTIONARY:
			_h.fail("phrase_entry_not_dict", "短语 %d 的条目不是字典" % int(phrase_id))
			continue
		var d: Dictionary = entry
		var missing: Array[String] = []
		for key in ["zh", "en", "group"]:
			if not d.has(key) or str(d[key]).strip_edges().is_empty():
				missing.append(key)
		_h.expect(missing.is_empty(), "phrase_entry_incomplete",
			"短语 %d 缺字段 %s。缺 en 的后果是英文环境下显示空白，"
			% [int(phrase_id), str(missing)]
			+ "而空白在界面上看着像「这条消息没内容」，不像一个配置错误。")


func _case_groups_cover_every_id() -> void:
	# 每个 id 都必须落在 GROUP_ORDER 的某个组里，否则它在表里存在、能被发送，
	# 但**永远不会出现在选择面板上** —— 一条谁也点不到的短语，没有任何症状。
	var covered: Array = []
	for group in ChatPhrases.GROUP_ORDER:
		for phrase_id in ChatPhrases.ids_in_group(group):
			covered.append(int(phrase_id))
	covered.sort()
	var all_ids: Array = ChatPhrases.PHRASES.keys()
	all_ids.sort()
	_h.item()
	_h.expect(covered == all_ids, "phrase_group_orphan",
		"有短语不属于 GROUP_ORDER 里的任何一组（面板上点不到，但仍然能被发送）。"
		+ "分组覆盖 %s，全表 %s" % [covered, all_ids])

	for group in ChatPhrases.GROUP_ORDER:
		_h.item()
		_h.expect(not ChatPhrases.ids_in_group(group).is_empty(), "phrase_group_empty",
			"分组 %s 是空的 —— 面板上会出现一个没有内容的分隔标题。" % group)
		_h.item()
		_h.expect(not ChatPhrases.group_title(group).is_empty(), "phrase_group_untitled",
			"分组 %s 在 GROUP_TITLES 里没有标题。" % group)


func _case_group_order_stable() -> void:
	# 升序是刻意的：顺序不稳定会让面板每次打开时按钮跳位，
	# 而玩家是靠肌肉记忆点这些按钮的。
	for group in ChatPhrases.GROUP_ORDER:
		_h.item()
		var ids: Array = ChatPhrases.ids_in_group(group)
		var sorted_ids: Array = ids.duplicate()
		sorted_ids.sort()
		_h.expect(ids == sorted_ids, "phrase_group_unsorted",
			"ids_in_group(%s) 不是升序：%s" % [group, ids])


# --- 4. 协议层的门 -------------------------------------------------------------

func _case_is_valid_id_rejects_junk() -> void:
	# 来路是网络。这些值必须被拒，且必须在常数级步数内被拒
	# （同 NetProtocol.gd 顶部那条）。
	for bad in [0, -1, -99999, 999999, 13, 2147483647]:
		_h.item()
		_h.expect(not ChatPhrases.is_valid_id(bad), "is_valid_id_accepted_junk",
			"is_valid_id(%d) 应该返回 false" % bad)
	for good in ChatPhrases.PHRASES.keys():
		_h.item()
		_h.expect(ChatPhrases.is_valid_id(int(good)), "is_valid_id_rejected_real",
			"is_valid_id(%d) 应该返回 true" % int(good))


func _case_text_empty_for_bad_id() -> void:
	for bad in [0, -1, 13, 999999]:
		_h.item()
		_h.expect(ChatPhrases.text(bad).is_empty(), "text_returned_placeholder",
			"text(%d) 必须返回**空串**，不能返回「未知短语」这类占位符 —— " % bad
			+ "占位符会让一个协议错误在界面上长得像一条正常消息，于是没人会去查。")
	for good in ChatPhrases.PHRASES.keys():
		_h.item()
		_h.expect(not ChatPhrases.text(int(good)).is_empty(), "text_empty_for_real_id",
			"text(%d) 不该是空串" % int(good))


# --- 5. 🔴 限流配置 ------------------------------------------------------------

func _case_rate_limit_entry_exists() -> void:
	_h.item()
	_h.expect(RateLimitService.LIMITS.has("chat_phrase"), "chat_rate_limit_missing",
		"RateLimitService.LIMITS 里必须有 \"chat_phrase\"。删掉它不会报错 —— "
		+ "`allow()` 对未知 action 用默认额度 20，等于把 5 悄悄放宽成 20。")
	if not RateLimitService.LIMITS.has("chat_phrase"):
		return
	_h.item()
	var limit := int(RateLimitService.LIMITS["chat_phrase"])
	# 上下界都要有：太小会把正常连点限掉，太大等于没限。
	_h.expect(limit >= 3 and limit <= 12, "chat_rate_limit_out_of_range",
		"chat_phrase 额度 %d 落在 [3,12] 之外（窗口 %.0f 秒）。"
		% [limit, RateLimitService.WINDOW_SEC]
		+ "太小会把正常连点限掉，太大等于没限。")


func _case_rate_limit_is_soft() -> void:
	# 行为用例：连续超限**不能**触发踢人。
	# 这条比源码断言硬 —— 它验的是 RateLimitService 真的把 count_strike=false 当回事。
	_h.item()
	var kicked: Array[int] = []
	var service := RateLimitService.new()
	service.configure(
		func() -> float: return 100.0,
		func(_m: String) -> void: pass,
		func(peer: int) -> void: kicked.append(peer))
	var limit := int(RateLimitService.LIMITS.get("chat_phrase", 5))
	# 打到额度的十倍，远超 STRIKES_BEFORE_KICK
	for i in (limit * 10):
		service.allow(7, "chat_phrase", false)
	_h.expect(kicked.is_empty(), "chat_rate_limit_kicks",
		"聊天限流把 peer 踢下线了（kicked=%s）。刷屏是烦人，不是攻击 —— " % [kicked]
		+ "对局中被踢的代价是整局崩掉。超限的正确后果只是这一条不转发。")


# --- 6. 两个 UI 入口 -----------------------------------------------------------

func _case_ui_scripts_parse() -> void:
	# 看着平淡，但这是本门禁里唯一能抓到「UI 层写出语法错误」的断言。
	# GDScript 解析错误在 headless 下只打一行 SCRIPT ERROR：既不是 PASS 也不是 FAIL，
	# 是**没有结果**（docs/CHECKS.md 记过这个踩法 —— Godot 会直接挂住）。
	# 这两个文件都不会被 autoload 拉起来，不显式 load 一次就没有任何东西验过它们。
	for path in [
		"res://scenes/menu/Team3v3Lobby.gd",
		"res://scenes/prep/PrepUI.gd",
		"res://scenes/prep/PrepScreen.gd",
		"res://scripts/autoload/RealtimeService.gd",
		"res://scripts/autoload/ChatService.gd",
		"res://scenes/menu/ChatScreen.gd",
		"res://scenes/menu/FriendsScreen.gd",
		"res://scenes/menu/MainMenu.gd",
	]:
		_h.item()
		# 🔴 判据是 `can_instantiate()`，**不是 `load() != null`**。
		# 实测（2026-09-10）：脚本有解析错误时 load() 照样返回一个非 null 的
		# GDScript 对象，于是 `!= null` 那版断言在引擎已经打了
		# "Parse Error" 的同一次运行里报了 PASS —— 正是 CHECKS.md 要消灭的
		# 「红日志、绿结果」。解析失败的脚本无法实例化，这个判据才咬得住。
		var script := load(path) as Script
		_h.expect(script != null and script.can_instantiate(), "ui_script_load_failed",
			"解析或加载失败：%s（看同一次运行的 stderr 里那行 Parse Error）" % path)


func _case_prep_log_ignores_mouse() -> void:
	_h.item()
	var src := FileAccess.get_file_as_string("res://scenes/prep/PrepUI.gd")
	if src.is_empty():
		_h.fail("prep_ui_unreadable", "读不到 PrepUI.gd")
		return
	# 消息条压在棋盘右下方的空域上，且是**自动出现**的（不是玩家点出来的）。
	# 少了 IGNORE，一条飘过的消息会把它盖住的那格棋盘变成点不动的 ——
	# 玩家只会觉得「卡了」，而这件事只在有人正好说话时发生，极难复现。
	_h.expect(src.contains("_chat_log.mouse_filter = Control.MOUSE_FILTER_IGNORE"),
		"prep_chat_log_eats_clicks",
		"PrepUI 的 _chat_log 必须设 mouse_filter = MOUSE_FILTER_IGNORE。"
		+ "它是备战期唯一会自动盖到棋盘上的控件。")

	_h.item()
	# 连接必须显式断开：NetworkService 是 autoload，活得比场景久。
	_h.expect(FileAccess.get_file_as_string("res://scenes/prep/PrepScreen.gd")
			.contains("_teardown_chat_entry()"),
		"prep_chat_not_disconnected",
		"PrepScreen._exit_tree 必须调 _teardown_chat_entry()。")
