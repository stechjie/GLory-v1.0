extends Node

# 11-26（第二轮）：排位 / 休闲房间（PartyLobby）的聊天框、麦克风 / 听筒、开始匹配、朋友列表
# **照自定义房间**（Team3v3Lobby）摆 —— 大小、位置、底图都一样；宠物区改成「一个成员一只
# 出战宠物、脚下写名字」。
#
# 这里钉三件事：
#   1. 两个房间的数是同一套（结构）：PartyLobby 的常量直接和 Team3v3Lobby 源码里的数对。
#      以后只改一边，这条会红。
#   2. 真把预览房间搭起来量一遍（行为）：聊天框 / 语音键 / 开始键 / 朋友列表落在说好的位置上，
#      朋友列表列出全部好友，「宠物」键队员也有，点开能换。
#   3. 宠物舞台的成员表合同（MainMenuPet.normalize_members / plan_member_sync）。
#
# 没覆盖（要真机 / 真窗口看）：羊皮纸底图上的字对不对得齐、名字牌跟着宠物走的观感、
# 刘海屏上左右两块贴边后的样子。
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/party_room_1126_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const LOBBY := preload("res://scenes/menu/PartyLobby.gd")
const LobbyScene := preload("res://scenes/menu/PartyLobby.tscn")
const PetStage := preload("res://scenes/menu/MainMenuPet.gd")

const CHECK_NAME := "party_room_1126"
const LOBBY_SRC := "res://scenes/menu/PartyLobby.gd"
const CUSTOM_SRC := "res://scenes/menu/Team3v3Lobby.gd"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_same_numbers_as_custom_room()
	_case_stage_member_contract()
	await _case_preview_room_layout()
	_h.finish(get_tree())


func _case_same_numbers_as_custom_room() -> void:
	var custom := FileAccess.get_file_as_string(CUSTOM_SRC).replace("\r\n", "\n")
	if not _h.expect(not custom.is_empty(), "custom_src_readable", "读不到 Team3v3Lobby.gd"):
		return
	# 聊天框：自定义房间是 _add_texture(TEX_CHAT, Vector2(80, 704), Vector2(430, 210), "left")。
	_h.expect(custom.contains("_add_texture(TEX_CHAT, Vector2(80, 704), Vector2(430, 210), \"left\")")
			and LOBBY.CHAT_POS == Vector2(80, 704) and LOBBY.CHAT_SIZE == Vector2(430, 210),
		"chat_box_same", "聊天框位置 / 大小要和自定义房间一样（80,704 430×210）")
	_h.expect(custom.contains("const CHAT_TEXT_X := 143.0") and is_equal_approx(LOBBY.CHAT_TEXT_X, 143.0)
			and custom.contains("const CHAT_TEXT_W := 309.0") and is_equal_approx(LOBBY.CHAT_TEXT_W, 309.0)
			and custom.contains("const CHAT_FIRST_LINE_Y := 757.0") and is_equal_approx(LOBBY.CHAT_FIRST_LINE_Y, 757.0)
			and custom.contains("const CHAT_ENTRY_Y := 836.0") and is_equal_approx(LOBBY.CHAT_ENTRY_Y, 836.0)
			and custom.contains("const CHAT_ENTRY_SPLIT := 154.0") and is_equal_approx(LOBBY.CHAT_ENTRY_SPLIT, 154.0),
		"chat_text_area_same", "聊天框里写字的范围、底下两个入口的位置要和自定义房间一样")
	# 开始键：自定义房间是 _add_texture(TEX_START, Vector2(1300, 760), Vector2(270, 130), "right")。
	_h.expect(custom.contains("_add_texture(TEX_START, Vector2(1300, 760), Vector2(270, 130), \"right\")")
			and LOBBY.ACTION_POS == Vector2(1300, 760) and LOBBY.ACTION_SIZE == Vector2(270, 130),
		"start_button_same", "开始键位置 / 大小要和自定义房间一样（1300,760 270×130）")
	# 朋友列表。
	_h.expect(custom.contains("const FRIENDS_PANEL_POS := Vector2(1255, 180)")
			and LOBBY.FRIENDS_PANEL_POS == Vector2(1255, 180)
			and custom.contains("const FRIENDS_PANEL_SIZE := Vector2(345, 400)")
			and LOBBY.FRIENDS_PANEL_SIZE == Vector2(345, 400)
			and custom.contains("const FRIENDS_LIST_POS := Vector2(1295, 273)")
			and LOBBY.FRIENDS_LIST_POS == Vector2(1295, 273)
			and custom.contains("const FRIENDS_LIST_SIZE := Vector2(264, 266)")
			and LOBBY.FRIENDS_LIST_SIZE == Vector2(264, 266)
			and custom.contains("const FRIEND_ROW_H := 54.0") and is_equal_approx(LOBBY.FRIEND_ROW_H, 54.0),
		"friends_panel_same", "朋友列表的位置 / 大小 / 行高要和自定义房间一样")
	# 麦克风 / 听筒：聊天框右缘外 12，垂直对齐聊天框中线（自定义房间的摆法）。
	var chat_right := LOBBY.CHAT_POS.x + LOBBY.CHAT_SIZE.x
	var chat_mid := LOBBY.CHAT_POS.y + LOBBY.CHAT_SIZE.y * 0.5
	_h.expect(is_equal_approx(LOBBY.VOICE_MIC_POS.x, chat_right + 12.0)
			and is_equal_approx(LOBBY.VOICE_SPEAKER_POS.x, LOBBY.VOICE_MIC_POS.x + LOBBY.VOICE_BTN_SIZE.x + 8.0)
			and is_equal_approx(LOBBY.VOICE_MIC_POS.y + LOBBY.VOICE_BTN_SIZE.y * 0.5, chat_mid)
			and is_equal_approx(LOBBY.VOICE_SPEAKER_POS.y, LOBBY.VOICE_MIC_POS.y),
		"voice_buttons_outside_chat", "麦克风 / 听筒在聊天框外右侧、对齐聊天框中线")
	_h.expect(custom.contains("Vector2(522, 779)") and custom.contains("Vector2(608, 779)"),
		"voice_buttons_same_as_custom", "自定义房间那两颗键也在 (522,779) / (608,779)")
	# 同一套底图。
	var src := FileAccess.get_file_as_string(LOBBY_SRC)
	for art in ["room_parchment/chat.png", "room_parchment/start.png", "room_parchment/friends_wide.png"]:
		_h.expect(src.contains(art) and custom.contains(art), "same_art_%s" % art.get_file().get_basename(),
			"两个房间要用同一张底图：%s" % art)
	_h.expect(src.contains("ChatInputBar.new().present(self,"),
		"typing_uses_input_bar", "打字走 ChatInputBar（贴屏幕顶的输入条），同自定义房间")
	_h.expect(not src.contains("LineEdit.new()"),
		"no_inline_line_edit", "聊天框里不再放输入框（手机键盘会把它盖住）")


func _case_stage_member_contract() -> void:
	var cleaned: Array = PetStage.normalize_members([
		{"key": "A", "pet": "pet_cat", "name": "甲", "audible": true},
		{"key": "B", "pet": "", "name": "乙"},
		{"key": "", "pet": "pet_dog", "name": "丙"},
		{"key": "A", "pet": "pet_fox", "name": "重复"},
		"nonsense",
		{"key": "D", "pet": "pet_rabbit"},
	])
	_h.expect(cleaned.size() == 2, "members_cleaned", "没宠物 / 没 key / 重复 key / 脏数据都不出（实得 %d）" % cleaned.size())
	if cleaned.size() == 2:
		_h.expect(str(cleaned[0].key) == "A" and str(cleaned[0].pet) == "pet_cat" and bool(cleaned[0].audible)
				and str(cleaned[0].name) == "甲",
			"member_fields_kept", "成员条目的 key / pet / name / audible 原样带过去")
		_h.expect(str(cleaned[1].key) == "D" and not bool(cleaned[1].audible) and str(cleaned[1].name) == "",
			"member_defaults", "没写的字段有默认值（不发声、名字为空）")
	# 增量同步：没变的不动（它们接着走，不会全场重新出生）。
	var members: Array = PetStage.normalize_members([
		{"key": "A", "pet": "pet_cat"}, {"key": "B", "pet": "pet_fox"}, {"key": "C", "pet": "pet_dog"}])
	var plan: Dictionary = PetStage.plan_member_sync(
		[{"key": "A", "id": "pet_cat"}, {"key": "B", "id": "pet_rabbit"}, {"key": "X", "id": "pet_dog"}], members)
	var remove: Array = plan.get("remove", [])
	var spawn: Array = plan.get("spawn", [])
	_h.expect(not remove.has("A") and not spawn.has("A"), "unchanged_member_untouched",
		"宠物没变的成员不收也不重出")
	_h.expect(remove.has("B") and spawn.has("B"), "switched_member_respawned",
		"换了宠物的成员：旧的收掉、新的出来")
	_h.expect(remove.has("X") and not spawn.has("X"), "left_member_removed", "走了的成员：宠物收掉")
	_h.expect(spawn.has("C") and not remove.has("C"), "new_member_spawned", "新来的成员：出一只")


func _case_preview_room_layout() -> void:
	var lobby := LobbyScene.instantiate() as Control
	lobby.configure_preview("guest")
	add_child(lobby)
	await get_tree().process_frame
	await get_tree().process_frame
	var left: Control = lobby.get("_left")
	var right: Control = lobby.get("_right")
	if not _h.expect(left != null and right != null, "edge_groups_exist", "要有贴左 / 贴右两块（_left / _right）"):
		lobby.queue_free()
		return
	var chat: Control = lobby.get("_chat_scroll")
	_h.expect(chat != null and left.is_ancestor_of(chat)
			and chat.position.is_equal_approx(Vector2(LOBBY.CHAT_TEXT_X, LOBBY.CHAT_FIRST_LINE_Y)),
		"chat_on_left", "聊天框在左边那块里、消息区在纸面内")
	var mic: Control = lobby.get("_voice_mic")
	var speaker: Control = lobby.get("_voice_speaker")
	_h.expect(left.is_ancestor_of(mic) and mic.position.is_equal_approx(LOBBY.VOICE_MIC_POS)
			and speaker.position.is_equal_approx(LOBBY.VOICE_SPEAKER_POS)
			and mic.size.is_equal_approx(LOBBY.VOICE_BTN_SIZE),
		"voice_buttons_placed", "麦克风 / 听筒摆在说好的位置、78×60")
	var action: Button = lobby.get("_action")
	_h.expect(right.is_ancestor_of(action) and action.position.is_equal_approx(LOBBY.ACTION_POS)
			and action.size.is_equal_approx(LOBBY.ACTION_SIZE),
		"start_button_placed", "开始键在右边那块里、270×130（实得 %s %s）" % [action.position, action.size])
	var panel: Control = lobby.get("_friends_panel")
	_h.expect(panel != null and right.is_ancestor_of(panel) and panel.is_visible_in_tree()
			and panel.position.is_equal_approx(LOBBY.FRIENDS_PANEL_POS)
			and panel.size.is_equal_approx(LOBBY.FRIENDS_PANEL_SIZE),
		"friends_panel_always_shown", "朋友列表一直摆在右边（不是点开才出来的抽屉）")
	# 预览房间塞了 3 个好友（2 在线 1 离线）：三个都要列出来，离线的排最后。
	var list: Control = lobby.get("_friend_list")
	var rows: Array = []
	for child in list.get_children():
		if child is Button:
			rows.append(child)
	_h.expect(rows.size() == 3, "all_friends_listed", "朋友列表要列出全部好友，含离线的（实得 %d 行）" % rows.size())
	if rows.size() == 3:
		_h.expect(str((rows[2] as Node).name) == "FriendRow_RSTU5621", "offline_friend_last", "离线的排在最后")
		_h.expect((rows[0] as Control).custom_minimum_size.y >= 48.0, "friend_row_touchable", "好友行高不低于 48")
	# 聊天：预览房间有两条消息，直接写在纸面上。
	var chat_list: Control = lobby.get("_chat_list")
	_h.expect(chat_list.get_child_count() == 2 and chat_list.get_child(0) is Label
			and (chat_list.get_child(0) as Label).text.begins_with("星河："),
		"chat_lines_plain", "消息一条一行「名字：内容」写在聊天框里")
	# 「宠物」键：队员也有；点开列出自己的宠物，当前出战那只打勾。
	var pet_button: Button = lobby.get("_pet_toggle")
	_h.expect(pet_button.visible and not pet_button.disabled, "guest_has_pet_button", "队员也有「宠物」键（原来只有房主有）")
	pet_button.pressed.emit()
	var drawer: Control = lobby.get("_pets_drawer")
	var pet_list: Control = lobby.get("_pet_list")
	_h.expect(drawer.visible and pet_list.get_child_count() == 3, "pet_panel_lists_owned", "点「宠物」键出面板，列出自己的宠物")
	var checked := 0
	var rabbit: Button = null
	var cat: Button = null
	for child in pet_list.get_children():
		var row := child as Button
		if row == null:
			continue
		if row.text.begins_with("✓"):
			checked += 1
			rabbit = row
		elif cat == null:
			cat = row
	_h.expect(checked == 1, "one_active_pet_checked", "面板上只有当前出战那一只打勾（实得 %d）" % checked)
	# 预览里队员（第二个人）的出战宠物是 pet_rabbit；点另一只 ⇒ 自己那条成员记录换掉。
	if cat != null:
		cat.pressed.emit()
		await get_tree().process_frame
		var members: Array = (lobby.get("_room") as Dictionary).get("members", [])
		_h.expect(members.size() == 2 and str((members[1] as Dictionary).get("pet", "")) != "pet_rabbit"
				and str((members[0] as Dictionary).get("pet", "")) == "pet_cat",
			"switch_changes_only_mine", "点另一只：只换自己的出战宠物，队友的不动")
		var staged: Array = lobby.call("_stage_members")
		_h.expect(staged.size() == 2 and bool((staged[1] as Dictionary).get("audible", false))
				and not bool((staged[0] as Dictionary).get("audible", true)),
			"only_own_pet_audible", "只有自己那只有脚步声")
	# 排队中：「宠物」键禁用、面板收起。
	var queued: Dictionary = (lobby.get("_room") as Dictionary).duplicate(true)
	queued["queued"] = true
	lobby.call("_apply", queued)
	_h.expect(pet_button.disabled and not drawer.visible, "pet_locked_in_queue", "排队中不能换出战宠物（键禁用、面板收起）")
	lobby.queue_free()
	await get_tree().process_frame
