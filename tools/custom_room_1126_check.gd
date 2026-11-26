extends Node

# 2026-11-26 自定义房间改版（Team3v3Lobby）的判据。用户原话四条：
#   1. 朋友列表宽多 50%
#   2. 不要一按就邀请，按了弹窗（查看资料 / 邀请 / 私聊，同一排）
#   3. AI 难度直接出列表选，不要按一下调一下
#   4. 麦克风和听筒移到聊天窗外右侧
# 排位房（PartyLobby）的好友卡片统一由 party_lobby_rules_check 钉结构。
#
# 运行：Godot_v4.7-stable_win64_console.exe --headless --path . tools/custom_room_1126_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const LobbyScene := preload("res://scenes/menu/Team3v3Lobby.tscn")

# 三种典型画面：20:9 手机、16:9、4:3 平板（stretch=canvas_items + expand 下的基准坐标）。
const SIZES := [Vector2i(1600, 720), Vector2i(1600, 900), Vector2i(1600, 1200)]

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new("custom_room_1126")
	call_deferred("_run")


func _frames(n := 4) -> void:
	for i in n:
		await get_tree().process_frame


func _run() -> void:
	NetworkService.set_process(false)
	NetworkService.team_active = false
	NetworkService.team_room_id = 0
	NetworkService.team_local_slot = 0
	var restore_size := get_tree().root.size
	var restore_scale := get_tree().root.content_scale_size
	var lobby: Control = LobbyScene.instantiate()
	add_child(lobby)
	await _frames(10)
	for view in SIZES:
		get_tree().root.content_scale_size = view
		get_tree().root.size = view
		await _frames(6)
		lobby._layout()
		await _frames(2)
		_case_voice_beside_chat(lobby, "%dx%d" % [view.x, view.y])
		_case_friends_panel_width(lobby, "%dx%d" % [view.x, view.y])
	await _case_ai_level_list(lobby)
	await _case_friend_card(lobby)
	ModalStack.close_all()
	lobby.queue_free()
	await _frames(2)
	get_tree().root.content_scale_size = restore_scale
	get_tree().root.size = restore_size
	_h.finish(get_tree())


# 4. 麦克风 / 听筒：在聊天框右缘外侧、垂直落在聊天框的高度范围里；
#    不压下排左边那个座位（名牌、+AI、难度键）。
func _case_voice_beside_chat(lobby: Control, tag: String) -> void:
	var chat := _chat_rect(lobby)
	_h.item()
	if not _h.expect(chat.size.x > 0.0, "chat_frame_found_" + tag, "找不到聊天框底图"):
		return
	var mic: Button = lobby._voice_controls.voice_button
	var speaker: Button = lobby._voice_controls.audience_button
	for pair in [["mic", mic], ["speaker", speaker]]:
		var b: Button = pair[1]
		var r := b.get_global_rect()
		_h.expect(r.position.x >= chat.end.x - 1.0, "%s_right_of_chat_%s" % [pair[0], tag],
			"%s 要在聊天框右缘外侧：键左缘 %.1f，聊天框右缘 %.1f" % [pair[0], r.position.x, chat.end.x])
		_h.expect(r.get_center().y > chat.position.y and r.get_center().y < chat.end.y,
			"%s_beside_chat_%s" % [pair[0], tag], "%s 要与聊天框同一高度（中心 y=%.1f，聊天框 %.1f~%.1f）"
				% [pair[0], r.get_center().y, chat.position.y, chat.end.y])
		for node in [lobby._slot_name_lbls[3], lobby._slot_ai_btns[3], lobby._slot_level_btns[3]]:
			var other := (node as Control).get_global_rect()
			_h.expect(not r.intersects(other), "%s_clear_of_seat1_%s" % [pair[0], tag],
				"%s 压到了下排左边座位的 %s（%s vs %s）" % [pair[0], (node as Control).name, r, other])
	_h.expect(mic.get_global_rect().end.x <= speaker.get_global_rect().position.x + 0.5,
		"mic_left_of_speaker_" + tag, "麦克风在左、听筒在右，不重叠")


# 1. 朋友列表：宽 345 / 高 400（原 230 的 1.5 倍），左缘不压右上座位（C）的名牌和底板。
func _case_friends_panel_width(lobby: Control, tag: String) -> void:
	var panel: Control = lobby._friends_panel
	_h.item()
	if not _h.expect(panel != null, "friends_panel_found_" + tag, "找不到朋友列表底图（_friends_panel）"):
		return
	var r := panel.get_global_rect()
	_h.expect(is_equal_approx(snappedf(r.size.x / r.size.y, 0.01), snappedf(345.0 / 400.0, 0.01)),
		"friends_panel_ratio_" + tag, "朋友列表应是 345×400 的比例，实测 %s" % r.size)
	var k: float = lobby._layout_scale
	_h.expect(absf(r.size.x - 345.0 * k) < 2.0, "friends_panel_width_" + tag,
		"朋友列表宽应是 345 参考像素（原 230 的 1.5 倍），实测 %.1f（缩放 %.3f）" % [r.size.x, k])
	for node in [lobby._slot_name_lbls[2], lobby._slot_bases[2]]:
		var other := (node as Control).get_global_rect()
		_h.expect(r.position.x > other.end.x, "friends_panel_clear_of_seat_c_" + tag,
			"朋友列表左缘 %.1f 压到了右上座位的 %s（右缘 %.1f）" % [r.position.x, (node as Control).name, other.end.x])


# 3. AI 难度：点难度键弹出五档列表；选哪档设哪档（列表随之收起）；座位不再是 AI 时列表自动收起。
func _case_ai_level_list(lobby: Control) -> void:
	_h.item()
	lobby._toggle_dummy(1)
	await _frames(2)
	_h.expect(str(lobby._states()[1]) == "dummy", "ai_seat_ready", "离线房主应能在 B 座放一个 AI")
	var before: int = lobby._ai_level_of(1)
	lobby._on_slot_level(1)
	await _frames(2)
	_h.expect(ModalStack.has(lobby.AI_LEVEL_MODAL_ID), "ai_level_list_opens",
		"点难度键要弹出难度列表（11-26 起不再点一下换一档）")
	_h.expect(lobby._ai_level_of(1) == before, "ai_level_tap_does_not_cycle",
		"只是打开列表，难度不能变（原来点一下就换一档）")
	var content: Control = ModalStack.top().get("content")
	var choices: Array = content.find_children("Choice_*", "Button", true, false) if content != null else []
	_h.expect(choices.size() == 5, "ai_level_five_choices", "列表要列出五档，实测 %d" % choices.size())
	var target := 5 if before != 5 else 1
	var pick: Button = content.find_child("Choice_%d" % target, true, false) if content != null else null
	if _h.expect(pick != null, "ai_level_choice_found", "找不到第 %d 档" % target):
		pick.pressed.emit()
		await _frames(2)
		_h.expect(lobby._ai_level_of(1) == target, "ai_level_picked", "选第 %d 档后 B 座应是第 %d 档，实测 %d"
			% [target, target, lobby._ai_level_of(1)])
		_h.expect(not ModalStack.has(lobby.AI_LEVEL_MODAL_ID), "ai_level_list_closes_on_pick", "选完列表要收起")
	# 列表开着时把 AI 撤掉 ⇒ 列表自动收起（不能留一张对着空位的难度表）。
	lobby._on_slot_level(1)
	await _frames(2)
	lobby._toggle_dummy(1)
	await _frames(2)
	_h.expect(not ModalStack.has(lobby.AI_LEVEL_MODAL_ID), "ai_level_list_closes_when_seat_changes",
		"座位不再是 AI 时难度列表要自动收起")


# 2. 好友：全部好友都列（在线排前），点一行弹卡片；卡片在朋友列表左边，
#    [查看资料] [邀请] [私聊] 与头像、名字同一排；离线好友的邀请键禁用并写「离线」。
func _case_friend_card(lobby: Control) -> void:
	_h.item()
	var entries := [
		{"friend_code": "BCDEFGHJ", "player_name": "Offline", "online": false, "room_id": null},
		{"friend_code": "ABCDEFGH", "player_name": "Online", "online": true, "in_match": false, "room_id": null},
		{"friend_code": "CDEFGHJK", "player_name": "Busy", "online": true, "in_match": true, "room_id": 7},
	]
	lobby._render_online_friends(entries)
	await _frames(3)
	var rows: Array = lobby._friends_box.get_children()
	_h.expect(rows.size() == 3, "all_friends_listed", "全部好友都要列出来（含离线、对局中），实测 %d 行" % rows.size())
	if rows.size() != 3:
		return
	_h.expect(str(rows[0].name) == "FriendRow_ABCDEFGH" and str(rows[1].name) == "FriendRow_CDEFGHJK"
			and str(rows[2].name) == "FriendRow_BCDEFGHJ", "friends_sorted_by_bucket",
		"排序应是 可邀请 → 对局中 → 离线")
	for row in rows:
		_h.expect(row is BaseButton, "friend_row_is_button",
			"好友行要是按钮类：拖动列表时 TouchScrollContainer 才能取消这次点击（不误弹卡片）")
	# 点在线好友。
	(rows[0] as Button).pressed.emit()
	await _frames(3)
	_h.expect(ModalStack.has(lobby.FRIEND_CARD_MODAL_ID), "friend_card_opens", "点好友行要弹卡片，不能直接发邀请")
	_h.expect(lobby._invited_pairs.is_empty() and lobby._invite_last_sec == 0, "row_tap_does_not_invite",
		"点好友行不能发邀请")
	var invite: Button = lobby._card_invite_btn
	if _h.expect(invite != null and is_instance_valid(invite), "friend_card_invite_found", "卡片上找不到邀请键"):
		var row_box := invite.get_parent()
		var profile: Button = row_box.find_child("ProfileButton", false, false)
		var chat: Button = row_box.find_child("ChatButton", false, false)
		var avatar: Control = row_box.find_child("Avatar", false, false)
		_h.expect(profile != null and chat != null and avatar != null and row_box is HBoxContainer,
			"friend_card_one_row", "查看资料 / 邀请 / 私聊要和头像、名字在同一排（同一个横排容器）")
		if profile != null and chat != null:
			_h.expect(profile.text == lobby._room_text("查看资料", "Profile")
					and chat.text == lobby._room_text("私聊", "Chat"), "friend_card_labels", "三个键：查看资料 / 邀请 / 私聊")
			var ys := [profile.get_global_rect().get_center().y, invite.get_global_rect().get_center().y,
				chat.get_global_rect().get_center().y]
			_h.expect(absf(ys[0] - ys[1]) < 1.0 and absf(ys[1] - ys[2]) < 1.0, "friend_card_buttons_aligned",
				"三个键要在同一水平线上，实测中心 y %s" % str(ys))
			var card := row_box.get_parent() as Control
			_h.expect(card.get_global_rect().end.x <= lobby._friends_panel.get_global_rect().position.x + 1.0,
				"friend_card_left_of_panel", "卡片要在朋友列表左边，不压住列表本身")
	ModalStack.pop(lobby.FRIEND_CARD_MODAL_ID)
	await _frames(2)
	# 点离线好友：卡片照样能开（看资料 / 私聊），邀请键禁用并写「离线」。
	(rows[2] as Button).pressed.emit()
	await _frames(3)
	var offline_invite: Button = lobby._card_invite_btn
	_h.expect(offline_invite != null and offline_invite.disabled
			and offline_invite.text == lobby._room_text("离线", "Offline"),
		"offline_invite_disabled", "离线好友的卡片上邀请键要禁用并写「离线」")
	ModalStack.pop(lobby.FRIEND_CARD_MODAL_ID)
	await _frames(2)


func _chat_rect(lobby: Control) -> Rect2:
	for item in lobby._placed:
		var node: Control = item.node
		if node is TextureRect and (node as TextureRect).texture == lobby.TEX_CHAT:
			return node.get_global_rect()
	return Rect2()
