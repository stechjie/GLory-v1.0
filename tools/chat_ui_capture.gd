extends Node

# 把房间大厅的聊天框与短语面板真渲染出来存图（docs/聊天系统设计.md 批次 A）。
#
# 为什么需要它：`tools/chat_check.tscn` 验的是合同（RPC 签名、id 集合、限流、
# 脚本能不能解析），它永远回答不了「摆得好不好看、有没有盖住别的东西」。
# 而短语面板正好压在敌方席位旁边 —— 那件事只有出图才看得见。
# 同 `tools/ui_gallery_capture.gd` 的理由。
#
# ⚠️ **必须不带 --headless 运行**：headless 是 dummy 渲染后端，抓出来是空图。
#   Godot_v4.7.1-stable_win64_console.exe --path . res://tools/chat_ui_capture.tscn
# 输出：reports/chat_ui/*.png

const LOBBY_SCENE := preload("res://scenes/menu/Team3v3Lobby.tscn")
const LOBBY_PHONE_WINDOW := Vector2i(1280, 720)

const OUT_DIR := "res://reports/chat_ui"
# 大厅有淡入与异步贴图加载（_setup_asset_loader），抓早了会拍到半成品。
const SETTLE_FRAMES := 30
# 最坏情况的样例：昵称上限 24 字（backend/app/text_guard.py 的 NAME_MAX）、
# 自由文字上限 40 字（ChatText.MAX_CHARS）。两张 *_worst_case 图看的是「整条都在」。
const LONGEST_NAME := "今天也要努力上分的弓手玩家阿泰的第二个小号呀哈哈"
const LONGEST_TEXT := "我这把先存钱不刷新，第五回合一口气升三星弓手，你们俩前排顶住别让他们先推过来啊啊"

var _lobby: Control = null
var _shots := 0


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("chat_ui_capture 需要真实渲染后端，请去掉 --headless")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	# 参考画布就是 1672×941。按它开窗，_layout() 的 scale 正好是 1，
	# 出的图与设计坐标一一对应 —— 缩放过的图没法拿去量间距。
	DisplayServer.window_set_size(Vector2i(1672, 941))

	_stub_online_state()
	_lobby = LOBBY_SCENE.instantiate()
	_lobby.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_lobby)
	for _i in SETTLE_FRAMES:
		await get_tree().process_frame

	_push_sample_messages()
	await _shot("lobby_chat_collapsed")

	# 离线状态下点入口会走「联机对局中才能发送」那条提示，所以直接调内部方法
	# 把面板摆出来 —— 这里要看的是版面，不是那条判断。
	_lobby.call("_set_phrase_panel_visible", true)
	await _shot("lobby_chat_panel_open")
	# 批次 D：顶部输入条（手机键盘从底部弹出，输入条必须在它够不着的地方）。
	_lobby.call("_open_text_input")
	await _shot("lobby_chat_text_input")
	ModalStack.close_all()
	# 最坏情况：24 字昵称 + 40 字。消息列一行约 18 字，这一条要折 4 行、占满整个框 ——
	# 这张图看的是「整条都在、没有被截」，不是好不好看。
	NetworkService.team_seat_profiles[2] = {"player_name": LONGEST_NAME,
		"friend_code": "CCCC3333", "avatar": ""}
	_lobby.call("_on_chat_text_received", 2, LONGEST_TEXT, false)
	await _shot("lobby_chat_worst_case")
	# 语音面板（第九节 v1.1）：同队成员 + 屏蔽。桌面上没有语音插件，面板顶部会写「这个版本没有语音功能」；
	# 这里看的是版面：成员行（含 24 字昵称）、屏蔽按钮、说明文字有没有被挤掉。
	var voice_controls: Variant = _lobby.get("_voice_controls")
	if voice_controls != null:
		voice_controls.call("_on_members_pressed")
		await _shot("lobby_voice_panel")
		ModalStack.close_all()

	# Lobby 的参考画布是 1672×941，但游戏逻辑高度是 720。文字清晰度问题只会在
	# 缩小后暴露：字号跟着缩、描边如果不跟就会把笔画糊在一起。这张专门盯手机比例。
	DisplayServer.window_set_size(LOBBY_PHONE_WINDOW)
	for _i in 8:
		await get_tree().process_frame
	_lobby.call("_layout")
	await _shot("lobby_text_1280")
	_lobby.queue_free()
	await get_tree().process_frame

	await _capture_prep()
	await _capture_chat_screen()

	print("CHAT_UI_CAPTURE shots=%d dir=%s" % [_shots, OUT_DIR])
	get_tree().quit(0)


# 备战期的聊天入口（PrepUI._build_chat_entry）。
#
# 🔴 **刻意用 1280×720 这个矮窗口**，不用参考画布的 941 高。
# 备战界面右侧那一列（佣兵 / 队伍佣兵 / 萝卜 / 萝卜计数）是**从屏幕顶部往下固定
# 排到 y=518** 的，而聊天按钮是**从屏幕底部往上锚**的 —— 窗口越矮，两者越容易撞。
# 941 高时看不出任何问题，720 高就会压到萝卜按钮上。
# 用户 2026-09-10 报的正是这个，而 941 那张图完全拍不到它。
const PREP_WINDOW := Vector2i(1280, 720)
const PREP_SETTLE_FRAMES := 60


func _capture_prep() -> void:
	DisplayServer.window_set_size(PREP_WINDOW)
	for _i in 5:
		await get_tree().process_frame

	# 与 tools/carrot_online_check.gd 的 _case_client_ui_tracks_room_state 同一套起法。
	GameState.reset_run()
	GameState.tutorial_mode = false
	NetworkService.team_active = true
	NetworkService.is_host = false
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if packed == null:
		push_error("PrepScreen.tscn 加载失败")
		return
	var prep: Node = packed.instantiate()
	add_child(prep)
	for _i in PREP_SETTLE_FRAMES:
		await get_tree().process_frame

	# 聊天范围（2026-09-14）：队友频道不加标记；自己人发到全部是橙字「【全部】」，
	# 对面的人发的是红字「【对方】」。本地是 0 号位（红方），3~5 号位是对面。
	prep.call("_on_prep_chat_received", 1, 2, true)
	prep.call("_on_prep_chat_received", 0, 8, false)
	# 批次 D：一条会折行的自由文字（最多两行）。
	prep.call("_on_prep_chat_text_received", 1, "下回合我先卖掉那个两星民兵，你们别抢弓手", true)
	await _shot("prep_chat_collapsed")
	# 最坏情况：对面的人发全部频道，「【对方】」+ 24 字昵称 + 40 字（4 行）。条数上限 3 先挤掉最老的短语，
	# 合计 1 + 2 + 4 = 7 行超了 6 行预算，再挤掉一条 —— 应当剩上面那条两行的
	# 和这条四行的，**两条都完整**。
	NetworkService.team_seat_profiles[3] = {"player_name": LONGEST_NAME,
		"friend_code": "DDDD4444", "avatar": ""}
	prep.call("_on_prep_chat_text_received", 3, LONGEST_TEXT, false)
	await _shot("prep_chat_worst_case")

	prep.call("_toggle_chat_panel")
	await _shot("prep_chat_panel_open")
	# 切到「全部」：按钮字变橙。再打开输入条，看输入框左边的范围按钮。
	# 按真按钮（发 pressed），不按名字调方法：顺带验了按钮确实接到了回调，也不涨 dynamic_call 的计数。
	var scope_button := prep.find_child("PrepChatScope", true, false) as Button
	var type_button := prep.find_child("PrepChatType", true, false) as Button
	if scope_button == null or type_button == null:
		push_error("备战期聊天面板里找不到 PrepChatScope / PrepChatType 按钮")
	else:
		scope_button.pressed.emit()
		await _shot("prep_chat_panel_scope_all")
		type_button.pressed.emit()
		await _shot("prep_chat_text_input")
		ModalStack.close_all()
	# 通讯栏的「队友」入口会打开 Prep 专用语音面板。先收起快捷聊天，
	# 避免截图里两个层同时展开，也顺带验证关闭入口仍然可用。
	var prep_chat_panel := prep.find_child("PrepChatPanel", true, false) as Control
	if prep_chat_panel != null and prep_chat_panel.visible:
		prep.call("_toggle_chat_panel")
	var prep_voice_controls: Variant = prep.get("_voice_controls")
	if prep_voice_controls == null:
		push_error("备战期找不到 VoiceControls")
	else:
		prep_voice_controls.call("_on_members_pressed")
		await _shot("prep_voice_panel_open")
		ModalStack.close_all()
	prep.queue_free()
	await get_tree().process_frame


# 私聊界面（批次 C，scenes/menu/ChatScreen.gd）。
#
# 同样用 1280×720 的矮窗口：左栏固定 440 宽，消息区是剩下的部分 ——
# 窗口越窄，气泡的最大宽度越小，长消息折行、「发送失败」那一行和「重发」按钮
# 越容易挤出问题。按参考画布那么宽出图，什么都看不出来。
const CHAT_SCREEN := preload("res://scenes/menu/ChatScreen.tscn")
const CHAT_WINDOW := Vector2i(1280, 720)


func _capture_chat_screen() -> void:
	DisplayServer.window_set_size(CHAT_WINDOW)
	for _i in 5:
		await get_tree().process_frame
	var screen: Control = CHAT_SCREEN.instantiate()
	add_child(screen)
	for _i in 10:
		await get_tree().process_frame

	# 出图时没有登录，列表拉取必然失败 —— 这里要看的是版面，直接灌样例数据；
	# 渲染走的仍是界面自己的函数，红点也走 ChatService（和线上同一条路）。
	var chats := [
		{"friend_code": "BBBB2222", "player_name": "小林", "avatar": "", "avatar_frame": "",
			"online": true, "unread": false, "last_message": {"message_id": 8, "from_me": true,
			"body": "好，八点见", "created_at": "2026-09-11T12:31:00+00:00"}},
		{"friend_code": "CCCC3333", "player_name": "阿泰的小号", "avatar": "", "avatar_frame": "",
			"online": false, "unread": true, "last_message": {"message_id": 3, "from_me": false,
			"body": "你上把那个阵容哪抄的，教教我", "created_at": "2026-09-10T09:00:00+00:00"}},
		{"friend_code": "DDDD4444", "player_name": "路人甲", "avatar": "", "avatar_frame": "",
			"online": false, "unread": false, "last_message": null},
	]
	screen.set("_chats", chats)
	ChatService.apply_chat_list(chats)
	screen.set("_open_code", "BBBB2222")
	ChatService.set_open_conversation("BBBB2222")
	var messages: Array[Dictionary] = [
		{"message_id": 5, "from_me": false, "body": "在吗",
			"created_at": "2026-09-11T12:00:00+00:00", "state": "sent"},
		{"message_id": 6, "from_me": true, "body": "在，刚打完一把",
			"created_at": "2026-09-11T12:01:00+00:00", "state": "sent"},
		{"message_id": 7, "from_me": false,
			"body": "今晚八点开一局三排？我拉上阿泰，你把上次那套四星弓手阵带上，别又开局就把棋子卖光了哈哈哈",
			"created_at": "2026-09-11T12:30:00+00:00", "state": "sent"},
		{"message_id": 8, "from_me": true, "body": "好，八点见",
			"created_at": "2026-09-11T12:31:00+00:00", "state": "sent"},
		{"message_id": 0, "from_me": true, "body": "我先去领一下萝卜",
			"created_at": "", "state": "pending", "seq": 1},
		{"message_id": 0, "from_me": true, "body": "这条是发送失败的样子",
			"created_at": "", "state": "failed", "error": "你们不是好友，发不了消息", "seq": 2},
	]
	screen.set("_messages", messages)
	screen.call("_set_notice", "", false)
	screen.call("_update_peer_label")
	screen.call("_render_list")
	screen.call("_render_messages", true)
	await _shot("chat_screen_conversation")

	# 被顶号：消息区上方的原因条 +「在本设备重新连接」，输入框禁用。
	ChatService.call("_set_kicked", true)
	await _shot("chat_screen_kicked")
	ChatService.reset()
	screen.queue_free()
	await get_tree().process_frame


func _stub_online_state() -> void:
	# 只动展示需要的三个字段。大厅读的是 NetworkService 上的这些值，
	# 不设的话席位全空、消息里的名字会退化成「席位A」这类占位。
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.team_seat_profiles = {
		0: {"player_name": "阿泰", "friend_code": "AAAA1111", "avatar": ""},
		1: {"player_name": "小林", "friend_code": "BBBB2222", "avatar": ""},
	}
	# 自己那一格走的**不是** team_seat_profiles —— Team3v3Lobby._seat_profile()
	# 对本人直接返回 AccountManager.profile（那张表是别人广播过来的，不含自己）。
	# 不 stub 它的话，自己发的消息会显示成「席位A」，图就骗人了。
	AccountManager.profile = {"player_name": "阿泰", "friend_code": "AAAA1111", "avatar": ""}


func _push_sample_messages() -> void:
	# 走真实入口 _on_chat_received(slot, phrase_id)，不是直接往标签里塞字符串 ——
	# 这样连「谁说的」的取名逻辑与短语查表一起被拍进图里。
	# 大厅只发全部（2026-09-14），team_only 一律 false。
	for pair in [[1, 1], [0, 5], [1, 8], [0, 4]]:
		_lobby.call("_on_chat_received", int(pair[0]), int(pair[1]), false)
	# 批次 D：一条会折行的自由文字，看 4 行里折得对不对、有没有把框撑破。
	_lobby.call("_on_chat_text_received", 1, "今晚八点开一局三排？我拉上阿泰，你带四星弓手", false)


func _shot(shot_name: String) -> void:
	for _i in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	var err := image.save_png(path)
	if err == OK:
		_shots += 1
		print("  saved %s (%dx%d)" % [path, image.get_width(), image.get_height()])
	else:
		push_error("保存失败 %s: %d" % [path, err])
