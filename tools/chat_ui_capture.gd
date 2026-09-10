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

	print("CHAT_UI_CAPTURE shots=%d dir=%s" % [_shots, OUT_DIR])
	get_tree().quit(0)


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
