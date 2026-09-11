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

const OUT_DIR := "res://reports/chat_ui"
# 大厅有淡入与异步贴图加载（_setup_asset_loader），抓早了会拍到半成品。
const SETTLE_FRAMES := 30

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

	for pair in [[1, 2], [0, 8]]:
		prep.call("_on_prep_chat_received", int(pair[0]), int(pair[1]))
	await _shot("prep_chat_collapsed")

	prep.call("_toggle_chat_panel")
	await _shot("prep_chat_panel_open")
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
	for pair in [[1, 1], [0, 5], [1, 8], [0, 4]]:
		_lobby.call("_on_chat_received", int(pair[0]), int(pair[1]))


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
