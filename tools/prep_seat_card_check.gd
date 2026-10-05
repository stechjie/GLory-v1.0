extends Node

# 门禁：摆放界面左上角头像（2026-10-06 用户要求：放大，点开看名字、不看留言、不听语音）。
#
# 三段，失败时都不报错，只是「点了没用」：
#   1. 聊天记录按人屏蔽（RoomChatLog）：被屏蔽的人说的不出现在记录里、新消息不冒出来；
#      换座位还认得出；取消后旧消息回来；座位号那条离开房间就清。
#   2. 卡片（PrepSeatCard）：别人才有两个按钮；按下去真的改了留言屏蔽和语音屏蔽；自己和 AI 没有按钮。
#   3. 真的摆放界面：头像 56 像素、能点、自己队在左边；点了弹出卡片。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const RoomChatLog := preload("res://scripts/multiplayer/RoomChatLog.gd")
const PrepSeatCard := preload("res://scenes/prep/panels/PrepSeatCard.gd")
const PrepScreenScript := preload("res://scenes/prep/PrepScreen.gd")

const ME := 3
const PROFILES := {
	0: {"player_name": "房主小明", "friend_code": "AB12CD34"},
	1: {"player_name": "阿强", "friend_code": "QQ88WW77"},
	4: {"player_name": "队友阿美", "friend_code": "MM55NN66"},
}

var _h: CheckHarness
var _saved := {}


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new("prep_seat_card")
	_case_chat_log_mutes()
	_save_network()
	_fake_team()
	await _case_card_buttons()
	await _case_prep_screen_avatars()
	_restore_network()
	_h.finish(get_tree())


# --- 1. 聊天记录按人屏蔽 ----------------------------------------------------------

func _case_chat_log_mutes() -> void:
	var log := RoomChatLog.new()
	var me := {"player_name": "我"}
	var shown: Array = []
	log.entry_added.connect(func(entry: Dictionary) -> void: shown.append(int(entry.slot)))
	log.add(501, RoomChatLog.make_entry(1, 0, "第一句", true, ME, PROFILES, me, 1, false))
	log.add(501, RoomChatLog.make_entry(4, 0, "我顶前排", true, ME, PROFILES, me, 1, false))
	log.add(501, RoomChatLog.make_entry(ME, 0, "收到", true, ME, PROFILES, me, 1, false))
	var changed := [0]
	log.mutes_changed.connect(func() -> void: changed[0] += 1)

	log.set_muted(1, PROFILES, true)
	_h.expect(changed[0] == 1, "mute_no_signal", "屏蔽之后要发 mutes_changed，界面才会重画")
	_h.expect(_slots(log.entries_for(501)) == [4, ME], "muted_still_listed",
		"屏蔽阿强之后记录里不该还有他的话：%s" % str(_slots(log.entries_for(501))))
	log.add(501, RoomChatLog.make_entry(1, 0, "又来了", true, ME, PROFILES, me, 1, false))
	_h.expect(not shown.has(1) or shown.count(1) == 1, "muted_new_message_shown",
		"屏蔽之后阿强的新消息还在冒出来（entry_added 不该发）")

	# 换座位：阿强（好友码 QQ88WW77）换到 2 号位，还是他 —— 照样屏蔽。
	var swapped := PROFILES.duplicate(true)
	swapped[2] = swapped[1]
	swapped.erase(1)
	_h.expect(log.is_muted(2, swapped), "mute_lost_on_seat_swap", "换座位之后屏蔽失效了 —— 要按人认，不是按座位")
	log.add(501, RoomChatLog.make_entry(2, 0, "换了座还说", true, ME, swapped, me, 1, false))
	_h.expect(not _slots(log.entries_for(501)).has(2), "swapped_message_shown", "换了座位的阿强说的话又出现了")

	# 自己说的永远屏蔽不到。
	_h.expect(_slots(log.entries_for(501)).has(ME), "self_hidden", "自己说的话被藏起来了")

	log.set_muted(1, PROFILES, false)
	_h.expect(_slots(log.entries_for(501)).count(1) == 2, "unmute_lost_history",
		"取消屏蔽之后阿强之前的两句应该回来：%s" % str(_slots(log.entries_for(501))))

	# 资料还没到（只有座位号）时屏蔽：离开房间就清掉，下一个房间同一个座位是别人。
	log.set_muted(5, {}, true)
	log.add(502, RoomChatLog.make_entry(5, 0, "新房间的 5 号", true, ME, {}, me, 0, false))
	_h.expect(_slots(log.entries_for(502)) == [5], "seat_mute_survived_room_change",
		"按座位号记的屏蔽带到了下一个房间：%s" % str(_slots(log.entries_for(502))))
	# 按人记的跨房间还在。
	log.set_muted(4, PROFILES, true)
	log.add(503, RoomChatLog.make_entry(4, 0, "下一个房间", true, ME, PROFILES, me, 0, false))
	_h.expect(log.entries_for(503).is_empty(), "person_mute_lost_on_room_change", "按人屏蔽在换房间后丢了")


func _slots(entries: Array) -> Array:
	var out := []
	for entry in entries:
		out.append(int((entry as Dictionary).slot))
	return out


# --- 2. 卡片 -----------------------------------------------------------------------

func _case_card_buttons() -> void:
	var other := PrepSeatCard.describe(1)
	_h.expect(str(other.title) == "阿强 #QQ88WW77" and bool(other.can_mute), "card_other_title",
		"别人的卡片要显示「名字 #好友码」并且能屏蔽：%s" % str(other))
	var mine := PrepSeatCard.describe(ME)
	_h.expect(str(mine.title).ends_with("（我）") and not bool(mine.can_mute), "card_self",
		"自己的卡片要标「（我）」、没有屏蔽按钮：%s" % str(mine))
	var ai := PrepSeatCard.describe(5)
	_h.expect(str(ai.title) == "AI" and bool(ai.is_ai) and not bool(ai.can_mute), "card_ai",
		"没有资料的 AI 座位叫 AI、不能屏蔽：%s" % str(ai))

	var card: PrepSeatCard = PrepSeatCard.new()
	card.setup(1)
	add_child(card)
	await get_tree().process_frame
	var chat: Button = card.get_node_or_null("VBoxContainer/MuteChat") as Button
	var voice: Button = card.get_node_or_null("VBoxContainer/MuteVoice") as Button
	if chat == null:
		chat = card.find_child("MuteChat", true, false) as Button
	if voice == null:
		voice = card.find_child("MuteVoice", true, false) as Button
	if not _h.expect(chat != null and voice != null, "card_buttons_missing", "别人的卡片上没有两个屏蔽按钮"):
		card.queue_free()
		return
	_h.expect(chat.text == "不看留言" and voice.text == "不听语音", "card_button_text",
		"按钮文案应是「不看留言」「不听语音」，实际「%s」「%s」" % [chat.text, voice.text])
	chat.pressed.emit()
	_h.expect(NetworkService.room_chat_log.is_muted(1, NetworkService.team_seat_profiles) and chat.text == "恢复看留言",
		"card_chat_toggle", "点「不看留言」没有屏蔽他的留言，或按钮没变成「恢复看留言」（%s）" % chat.text)
	voice.pressed.emit()
	_h.expect(VoiceService.is_muted(1) and voice.text == "恢复听语音", "card_voice_toggle",
		"点「不听语音」没有屏蔽他的语音，或按钮没变成「恢复听语音」（%s）" % voice.text)
	chat.pressed.emit()
	voice.pressed.emit()
	_h.expect(not NetworkService.room_chat_log.is_muted(1, NetworkService.team_seat_profiles)
			and not VoiceService.is_muted(1), "card_untoggle", "再点一次没有恢复")
	card.queue_free()
	await get_tree().process_frame


# --- 3. 真的摆放界面 -----------------------------------------------------------------

func _case_prep_screen_avatars() -> void:
	GameState.reset_run()
	var was_active := NetworkService.team_active
	NetworkService.team_active = false
	var prep: PrepScreenScript = (load("res://scenes/prep/PrepScreen.tscn") as PackedScene).instantiate()
	add_child(prep)
	for _frame in 12:
		await get_tree().process_frame
	NetworkService.team_active = true
	_fake_team()
	prep._refresh_ready_indicator()
	await get_tree().process_frame
	var dots: Array = prep._ready_dots
	_h.expect(dots.size() == 6, "avatar_count", "左上角应该有 6 个头像，实际 %d" % dots.size())
	if dots.size() == 6:
		var first: Control = dots[0]
		_h.expect(first.custom_minimum_size == Vector2(56, 56), "avatar_size",
			"头像应该放大到 56 像素，实际 %s" % str(first.custom_minimum_size))
		_h.expect(first.mouse_filter == Control.MOUSE_FILTER_STOP, "avatar_not_clickable", "头像点不到（mouse_filter 不是 STOP）")
		var slots := []
		for dot in dots:
			slots.append(int((dot as Control).get_meta("slot", -1)))
		_h.expect(slots == [3, 4, 5, 0, 1, 2], "avatar_order",
			"自己队（3-5）应该在左边、对面在右边，实际 %s" % str(slots))
		_h.expect((dots[0] as Control).global_position.y == (dots[5] as Control).global_position.y,
			"avatar_not_one_row", "六个头像应该排成一排（两排会压到下面的羁绊栏）")
		# 手机上是手指点：发一次触摸按下，走真的 gui_input 处理，不直接调 open_seat_card。
		var tap := InputEventScreenTouch.new()
		tap.pressed = true
		(dots[4] as Control).gui_input.emit(tap)
		await get_tree().process_frame
		_h.expect(ModalStack.has(PrepScreenScript.SEAT_CARD_MODAL_ID), "card_not_opened", "点头像没有弹出卡片")
		var top: Dictionary = ModalStack.top()
		_h.expect(top.get("content") is PrepSeatCard and int((top.get("content") as PrepSeatCard).slot) == 1,
			"card_wrong_slot", "弹出来的不是这个座位的卡片")
		ModalStack.pop(PrepScreenScript.SEAT_CARD_MODAL_ID)
	prep.queue_free()
	await get_tree().process_frame
	NetworkService.team_active = was_active


# --- 假的组队状态 ---------------------------------------------------------------------

func _fake_team() -> void:
	NetworkService.team_active = true
	NetworkService.team_local_slot = ME
	NetworkService.team_slot_states = ["player", "player", "empty", "player", "player", "dummy"]
	NetworkService.team_ready = [true, false, false, false, true, true]
	NetworkService.team_seat_profiles = PROFILES.duplicate(true)


func _save_network() -> void:
	for key in ["team_active", "team_local_slot", "team_slot_states", "team_ready", "team_seat_profiles"]:
		var value: Variant = NetworkService.get(key)
		_saved[key] = value.duplicate(true) if value is Array or value is Dictionary else value


func _restore_network() -> void:
	for slot in 6:
		NetworkService.room_chat_log.set_muted(slot, NetworkService.team_seat_profiles, false)
		VoiceService.set_muted(slot, false)
	for key in _saved:
		NetworkService.set(key, _saved[key])
