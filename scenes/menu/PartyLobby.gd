extends Control

signal back_requested
signal queue_started(mode: String, host: bool)

const REF := Vector2(1672, 941)
const BG := preload("res://assets/ui/main_menu_live/background.png")
const PET_STAGE := preload("res://scenes/menu/MainMenuPet.gd")
const PARTY_VOICE := preload("res://scenes/menu/PartyVoice.gd")
const AVATARS := preload("res://scripts/account/AvatarCatalog.gd")
const RANKS := preload("res://scenes/menu/RankedTiers.gd")
const PROFILE_DISC := preload("res://assets/ui/main_menu_live/profile_avatar.png")
const ACTION := preload("res://ui/components/GloryActionButton.tscn")
const BUTTON_PRIMARY := preload("res://assets/ui/party_lobby/party_button_primary.png")
const BUTTON_SECONDARY := preload("res://assets/ui/party_lobby/party_button_secondary.png")
const BUTTON_MODE_IDLE := preload("res://assets/ui/party_lobby/party_button_mode_idle.png")
const BUTTON_MODE_ACTIVE := preload("res://assets/ui/party_lobby/party_button_mode_active.png")
const GOLD := Color("e6c984")
const CREAM := Color("f8f0d8")
const MUTED := Color("bbc5b9")
const GREEN := Color("9cdbba")
const DARK := Color("101b1c")

var _initial_mode := "casual"
var _invite_id := ""
var _preview := ""
var _room: Dictionary = {}
var _friends: Array = []
var _local_only := true
var _load_error := ""
var _loading_room := false
var _busy := false
var _queue_opened := false
var _match_found := false
var _canvas: Control
var _stage: Control
var _seat_layer: Control
var _friend_list: VBoxContainer
var _pet_list: VBoxContainer
var _friend_rail: VBoxContainer
var _friends_drawer: Panel
var _pets_drawer: Panel
var _friends_toggle: Button
var _pet_toggle: Button
var _chat_panel: Panel
var _chat_toggle: Button
var _chat_expanded := false
var _chat_list: VBoxContainer
var _chat_scroll: ScrollContainer
var _chat_input: LineEdit
var _send_button: Button
var _mode_casual: Button
var _mode_ranked: Button
var _action: Button
var _notice: Label
var _voice: Button
var _party_voice: Node
var _poll_elapsed := 0.0


func configure(mode: String, invite_id: String = "") -> void:
	_initial_mode = mode
	_invite_id = invite_id


func configure_preview(role: String) -> void:
	_preview = role
	_initial_mode = "ranked"


func _ready() -> void:
	_build()
	get_viewport().size_changed.connect(_layout)
	_layout()
	if not RealtimeService.message_received.is_connected(_on_realtime):
		RealtimeService.message_received.connect(_on_realtime)
	if _preview != "":
		_apply(_preview_room())
		_friends = [
			{"friend_code": "KLMN2345", "player_name": "月影", "online": true},
			{"friend_code": "QWER7788", "player_name": "小木", "online": true},
			{"friend_code": "RSTU5621", "player_name": "北辰", "online": false},
		]
		_render_friends()
	else:
		if not AccountManager.profile_changed.is_connected(_on_local_profile_changed):
			AccountManager.profile_changed.connect(_on_local_profile_changed)
		if not PlayerProfile.pets_changed.is_connected(_on_local_pets_changed):
			PlayerProfile.pets_changed.connect(_on_local_pets_changed)
		_show_local_identity()
		_load_room()
		_load_friends()


func _exit_tree() -> void:
	if RealtimeService.message_received.is_connected(_on_realtime):
		RealtimeService.message_received.disconnect(_on_realtime)
	if AccountManager.profile_changed.is_connected(_on_local_profile_changed):
		AccountManager.profile_changed.disconnect(_on_local_profile_changed)
	if PlayerProfile.pets_changed.is_connected(_on_local_pets_changed):
		PlayerProfile.pets_changed.disconnect(_on_local_pets_changed)


func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := TextureRect.new()
	bg.texture = BG
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var shade := ColorRect.new()
	shade.color = Color(0.025, 0.065, 0.07, 0.12)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)
	_stage = PET_STAGE.new() as Control
	_stage.configure_party_display([], Vector2(385, 315), Vector2(920, 355))
	add_child(_stage)
	_canvas = Control.new()
	_canvas.custom_minimum_size = REF
	_canvas.size = REF
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_canvas)

	var back := _button(_canvas, "‹  " + _text("返回", "Back"), Vector2(43, 39), Vector2(126, 52))
	_style_paper_button(back, false)
	back.pressed.connect(_leave)
	_mode_casual = _button(_canvas, _text("休闲", "CASUAL"), Vector2(685, 46), Vector2(145, 56))
	_mode_ranked = _button(_canvas, _text("排位", "RANKED"), Vector2(842, 46), Vector2(145, 56))
	_mode_casual.pressed.connect(func() -> void: _change_mode("casual"))
	_mode_ranked.pressed.connect(func() -> void: _change_mode("ranked"))
	_pet_toggle = _button(_canvas, _text("宠物", "PETS"), Vector2(1375, 49), Vector2(91, 50))
	_style_paper_button(_pet_toggle, false)
	_pet_toggle.pressed.connect(_toggle_pets_drawer)

	_chat_panel = _paper_panel(_canvas, Vector2(37, 730), Vector2(342, 164), 0.91)
	_label(_chat_panel, _text("队内聊天", "PARTY CHAT"), Vector2(18, 11), Vector2(225, 33), 22, Color("425331"))
	_chat_toggle = _button(_chat_panel, "⌃", Vector2(290, 8), Vector2(38, 34))
	_style_paper_button(_chat_toggle, false)
	_chat_toggle.pressed.connect(_toggle_chat)
	_chat_scroll = ScrollContainer.new()
	_chat_scroll.position = Vector2(17, 47)
	_chat_scroll.size = Vector2(308, 57)
	_chat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_chat_panel.add_child(_chat_scroll)
	_chat_list = VBoxContainer.new()
	_chat_list.custom_minimum_size.x = 292
	_chat_list.add_theme_constant_override("separation", 7)
	_chat_scroll.add_child(_chat_list)
	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = _text("给队友发消息…", "Message your team…")
	_chat_input.position = Vector2(15, 111)
	_chat_input.size = Vector2(248, 40)
	_style_chat_input(_chat_input)
	_chat_input.text_submitted.connect(func(_t: String) -> void: _send_chat())
	_chat_panel.add_child(_chat_input)
	_send_button = _button(_chat_panel, _text("发送", "Send"), Vector2(269, 111), Vector2(60, 40))
	_style_paper_button(_send_button, true)
	_send_button.pressed.connect(_send_chat)

	_seat_layer = Control.new()
	_seat_layer.position = Vector2(377, 179)
	_seat_layer.size = Vector2(922, 237)
	_seat_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(_seat_layer)
	_notice = _label(_canvas, "", Vector2(642, 887), Vector2(402, 36), 18, CREAM)
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_action = _button(_canvas, _text("开始匹配", "START MATCH"), Vector2(704, 805), Vector2(264, 75))
	_action.pressed.connect(_act)

	_friends_toggle = _button(_canvas, _text("好友", "FRIENDS"), Vector2(1481, 169), Vector2(159, 59))
	_style_paper_button(_friends_toggle, false)
	_friends_toggle.pressed.connect(_toggle_friends_drawer)
	_friend_rail = VBoxContainer.new()
	_friend_rail.position = Vector2(1520, 248)
	_friend_rail.size = Vector2(104, 354)
	_friend_rail.add_theme_constant_override("separation", 12)
	_canvas.add_child(_friend_rail)

	_friends_drawer = _paper_panel(_canvas, Vector2(1221, 157), Vector2(419, 567), 0.97)
	_label(_friends_drawer, _text("在线好友", "FRIENDS ONLINE"), Vector2(25, 22), Vector2(280, 39), 27, Color("425331"))
	var close_friends := _button(_friends_drawer, "×", Vector2(361, 18), Vector2(37, 37))
	_style_paper_button(close_friends, false)
	close_friends.pressed.connect(_toggle_friends_drawer)
	var friends_scroll := ScrollContainer.new()
	friends_scroll.position = Vector2(20, 78)
	friends_scroll.size = Vector2(379, 463)
	friends_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_friends_drawer.add_child(friends_scroll)
	_friend_list = VBoxContainer.new()
	_friend_list.custom_minimum_size.x = 359
	_friend_list.add_theme_constant_override("separation", 8)
	friends_scroll.add_child(_friend_list)
	_friends_drawer.visible = false

	_pets_drawer = _paper_panel(_canvas, Vector2(1203, 123), Vector2(343, 394), 0.97)
	_label(_pets_drawer, _text("展示宠物", "DISPLAY PETS"), Vector2(21, 15), Vector2(241, 38), 25, Color("425331"))
	var close_pets := _button(_pets_drawer, "×", Vector2(286, 14), Vector2(38, 37))
	_style_paper_button(close_pets, false)
	close_pets.pressed.connect(_toggle_pets_drawer)
	var pet_scroll := ScrollContainer.new()
	pet_scroll.position = Vector2(18, 66)
	pet_scroll.size = Vector2(307, 305)
	pet_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_pets_drawer.add_child(pet_scroll)
	_pet_list = VBoxContainer.new()
	_pet_list.custom_minimum_size.x = 295
	_pet_list.add_theme_constant_override("separation", 8)
	pet_scroll.add_child(_pet_list)
	_pets_drawer.visible = false

	_voice = _button(_canvas, _text("语音 · 关闭", "VOICE · OFF"), Vector2(395, 835), Vector2(203, 50))
	_style_paper_button(_voice, false)
	_voice.pressed.connect(_toggle_voice)
	_party_voice = PARTY_VOICE.new()
	_party_voice.state_changed.connect(func(label: String) -> void:
		if is_instance_valid(_voice):
			_voice.tooltip_text = label
			var voice_mode := int(_party_voice.get("mode"))
			_voice.text = _text("语音 · 开麦", "VOICE · TALK") if voice_mode == 2 else \
				(_text("语音 · 收听", "VOICE · LISTEN") if voice_mode == 1 else _text("语音 · 关闭", "VOICE · OFF")))
	add_child(_party_voice)


func _layout() -> void:
	var viewport_size := get_viewport_rect().size
	var factor := minf(viewport_size.x / REF.x, viewport_size.y / REF.y)
	_canvas.scale = Vector2.ONE * factor
	_canvas.position = (viewport_size - REF * factor) * 0.5


func _on_local_profile_changed(_profile: Dictionary) -> void:
	if _local_only:
		_show_local_identity()


func _on_local_pets_changed() -> void:
	if _local_only:
		_show_local_identity()


func _show_local_identity() -> void:
	var profile: Dictionary = AccountManager.profile
	var code := str(profile.get("friend_code", ""))
	var name := str(profile.get("player_name", AccountManager.player_name))
	if name.is_empty():
		name = _text("我", "Me")
	var selected: Array = []
	for pet_id in PlayerProfile.owned_pets:
		if selected.size() >= 5:
			break
		selected.append(pet_id)
	_room = {"state": "room", "mode": _initial_mode, "host_code": code,
		"members": [{"friend_code": code, "player_name": name,
			"avatar": str(profile.get("avatar", AVATARS.default_avatar())),
			"avatar_frame": str(profile.get("avatar_frame", AVATARS.default_frame())),
			"tier": -1, "host": true, "ready": true}],
		"pets": selected, "messages": [], "queued": false}
	_render_seats()
	_render_pets()
	_stage.configure_party_display(selected, Vector2(385, 315), Vector2(920, 355))
	_mode_casual.disabled = true
	_mode_ranked.disabled = true
	_style_mode(_mode_casual, _initial_mode == "casual")
	_style_mode(_mode_ranked, _initial_mode == "ranked")
	_pet_toggle.visible = false
	_pets_drawer.visible = false
	_chat_input.editable = false
	_chat_input.placeholder_text = _text("队伍服务未连接", "Party service unavailable")
	_send_button.disabled = true
	_voice.disabled = true
	_action.text = _text("开始匹配", "START MATCH")
	_action.disabled = true
	_style_action()
	_notice.text = _load_error if not _load_error.is_empty() else _text("正在连接队伍…", "Connecting to party…")


func _apply(next: Dictionary) -> void:
	if str(next.get("state", "")) != "room":
		return
	_local_only = false
	_load_error = ""
	_room = next
	_chat_input.editable = true
	_chat_input.placeholder_text = _text("给队友发消息…", "Message your team…")
	_send_button.disabled = false
	_voice.disabled = false
	var host := _is_host()
	var mode := str(_room.get("mode", _initial_mode))
	_pet_toggle.visible = host and not bool(_room.get("queued", false))
	if not _pet_toggle.visible:
		_pets_drawer.visible = false
	_mode_casual.disabled = not host or bool(_room.get("queued", false))
	_mode_ranked.disabled = not host or bool(_room.get("queued", false))
	_style_mode(_mode_casual, mode == "casual")
	_style_mode(_mode_ranked, mode == "ranked")
	_render_seats()
	_render_chat()
	_render_pets()
	_stage.configure_party_display(_room.get("pets", []), Vector2(385, 315), Vector2(920, 355))
	if _preview == "":
		_party_voice.configure(_room)
	var members: Array = _room.get("members", [])
	if host:
		var all_ready := true
		for raw in members:
			var entry: Dictionary = raw
			if not bool(entry.get("host", false)) and not bool(entry.get("ready", false)):
				all_ready = false
		_action.text = _text("开始匹配", "START MATCH")
		_action.disabled = not all_ready or bool(_room.get("queued", false))
		_notice.text = _text("等待队友准备", "Waiting for team") if not all_ready else ""
	else:
		var mine := _my_member()
		var ready := bool(mine.get("ready", false))
		_action.text = _text("取消准备" if ready else "准备", "CANCEL READY" if ready else "READY")
		_action.disabled = bool(_room.get("queued", false))
		_notice.text = _text("等待房主开始", "Waiting for host") if ready else ""
	if bool(_room.get("queued", false)) and not _queue_opened and _preview == "":
		_queue_opened = true
		queue_started.emit(mode, host)
	elif not bool(_room.get("queued", false)):
		_queue_opened = false
	_style_action()


func _render_seats() -> void:
	_clear_children(_seat_layer)
	var members: Array = _room.get("members", [])
	for i in range(3):
		var x := float(i) * 313.0
		var seat := Control.new()
		seat.position = Vector2(x, 0)
		seat.size = Vector2(214, 231)
		seat.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_seat_layer.add_child(seat)
		if i >= members.size():
			var add := _button(seat, "+", Vector2(37, 12), Vector2(140, 140))
			_style_empty_seat(add)
			add.disabled = _local_only or not _is_host() or bool(_room.get("queued", false))
			add.pressed.connect(_toggle_friends_drawer)
			var empty_text := _text("空位", "OPEN SEAT") if _local_only else \
				(_text("邀请好友", "INVITE FRIEND") if _is_host() else _text("等待队友", "OPEN SEAT"))
			var empty_name := _label(seat, empty_text,
				Vector2(0, 169), Vector2(214, 34), 21, CREAM)
			empty_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			continue
		var member: Dictionary = members[i]
		var frame := TextureRect.new()
		frame.texture = AVATARS.frame_texture_for(str(member.get("avatar_frame", "")))
		if frame.texture == null:
			frame.texture = PROFILE_DISC
		frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		seat.add_child(frame)
		frame.position = Vector2(30, 0)
		frame.size = Vector2(154, 154)
		var mask := Panel.new()
		mask.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
		mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var circle := StyleBoxFlat.new()
		circle.bg_color = Color.WHITE
		circle.set_corner_radius_all(55)
		mask.add_theme_stylebox_override("panel", circle)
		seat.add_child(mask)
		mask.position = Vector2(57, 27)
		mask.size = Vector2(100, 100)
		var portrait := TextureRect.new()
		portrait.texture = AVATARS.texture_for(str(member.get("avatar", "")), true)
		portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
		mask.add_child(portrait)
		portrait.position = Vector2.ZERO
		portrait.size = mask.size
		var name := str(member.get("player_name", ""))
		var code := str(member.get("friend_code", ""))
		var name_label := _label(seat, AccountManager.display_name(name, code, false),
			Vector2(0, 163), Vector2(214, 35), 23, CREAM)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var rank_text := _text("段位加载中", "Rank loading") if _local_only else \
			RANKS.name_of(int(member.get("tier", -1)), _is_en())
		var rank_label := _label(seat, rank_text,
			Vector2(0, 198), Vector2(214, 29), 19, GOLD)
		rank_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var state := _text("房主", "HOST") if bool(member.get("host", false)) else \
			(_text("已准备", "READY") if bool(member.get("ready", false)) else _text("未准备", "WAITING"))
		var badge := _paper_panel(seat, Vector2(134, 110), Vector2(83, 33), 0.92)
		var badge_label := _label(badge, state, Vector2.ZERO, badge.size, 16,
			Color("5e512f") if bool(member.get("host", false)) else (Color("366a4d") if bool(member.get("ready", false)) else Color("6b6b60")))
		badge_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER


func _render_friends() -> void:
	_clear_children(_friend_list)
	_clear_children(_friend_rail)
	var drawer_height := minf(567.0, maxf(180.0, 103.0 + float(_friends.size()) * 90.0))
	_friends_drawer.custom_minimum_size.y = drawer_height
	_friends_drawer.size.y = drawer_height
	(_friend_list.get_parent() as ScrollContainer).size.y = drawer_height - 101.0
	var room_count := (_room.get("members", []) as Array).size()
	var online_count := 0
	var quick_count := 0
	for raw in _friends:
		var friend: Dictionary = raw
		if bool(friend.get("online", false)):
			online_count += 1
	_friends_toggle.text = _text("好友  %d 在线" % online_count, "FRIENDS  %d" % online_count)
	for online_pass in [true, false]:
		for raw in _friends:
			var friend: Dictionary = raw
			var online := bool(friend.get("online", false))
			if online != online_pass:
				continue
			var row := _paper_panel(_friend_list, Vector2.ZERO, Vector2(359, 82), 0.75)
			row.custom_minimum_size = Vector2(359, 82)
			var avatar := _friend_avatar(row, friend, Vector2(8, 7), 67)
			avatar.disabled = _local_only or not _is_host() or not online or room_count >= 3
			var code := str(friend.get("friend_code", ""))
			avatar.pressed.connect(func() -> void: _invite(code))
			var name := _label(row, str(friend.get("player_name", "")), Vector2(85, 13), Vector2(152, 31), 21,
				Color("31412e") if online else Color("8b8d7b"))
			name.clip_text = true
			_label(row, _text("在线", "Online") if online else _text("离线", "Offline"),
				Vector2(85, 46), Vector2(140, 24), 16, Color("438663") if online else Color("8b8d7b"))
			var invite := _button(row, _text("邀请", "Invite"), Vector2(254, 20), Vector2(87, 42))
			_style_paper_button(invite, true)
			invite.disabled = _local_only or not _is_host() or not online or room_count >= 3
			invite.pressed.connect(func() -> void: _invite(code))
			if online and quick_count < 3:
				var quick := _friend_avatar(_friend_rail, friend, Vector2.ZERO, 72)
				quick.disabled = _local_only or not _is_host() or room_count >= 3
				quick.pressed.connect(func() -> void: _invite(code))
				quick_count += 1
	if _friends.is_empty():
		_label(_friend_list, _text("暂无好友", "No friends yet"), Vector2(18, 16), Vector2(312, 36), 19, Color("657057"))
	elif online_count == 0:
		_label(_friend_rail, _text("暂无在线好友", "No one online"), Vector2.ZERO, Vector2(105, 50), 16, CREAM)


func _render_pets() -> void:
	_clear_children(_pet_list)
	var selected: Array = _room.get("pets", [])
	var owned: Array = PlayerProfile.owned_pets
	if _preview != "":
		owned = ["pet_cat", "pet_rabbit", "pet_mushroom"]
	for raw in owned:
		var pet_id := str(raw)
		var choice := ACTION.instantiate() as Button
		choice.text = ("✓  " if selected.has(pet_id) else "○  ") + _pet_name(pet_id)
		choice.custom_minimum_size = Vector2(295, 50)
		_style_paper_button(choice, selected.has(pet_id))
		choice.disabled = _local_only or not _is_host() or bool(_room.get("queued", false))
		choice.pressed.connect(func() -> void: _toggle_pet(pet_id))
		_pet_list.add_child(choice)
	if owned.is_empty():
		var hint := Label.new()
		hint.text = _text("当前没有可展示的宠物", "No pets to display")
		hint.add_theme_color_override("font_color", Color("657057"))
		_pet_list.add_child(hint)
	_render_friends()


func _render_chat() -> void:
	_clear_children(_chat_list)
	var messages: Array = _room.get("messages", [])
	var first := 0 if _chat_expanded else maxi(0, messages.size() - 1)
	for index in range(first, messages.size()):
		var raw: Variant = messages[index]
		var message: Dictionary = raw
		var label := Label.new()
		label.text = "%s：%s" % [str(message.get("name", "")), str(message.get("text", ""))]
		label.custom_minimum_size.x = 292
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_color_override("font_color", Color("405039"))
		label.add_theme_font_size_override("font_size", 18)
		_chat_list.add_child(label)
	call_deferred("_scroll_chat_bottom")


func _scroll_chat_bottom() -> void:
	if is_instance_valid(_chat_scroll):
		_chat_scroll.scroll_vertical = int(_chat_scroll.get_v_scroll_bar().max_value)


func _load_room() -> void:
	if _loading_room:
		return
	_loading_room = true
	var result: Dictionary
	if _invite_id != "":
		result = await AccountManager.join_party(_invite_id)
	else:
		result = await AccountManager.fetch_party()
		if int(result.get("code", 0)) == 200:
			var state: Dictionary = (result.get("body", {}) as Dictionary).get("state", {})
			if str(state.get("state", "")) != "room":
				result = await AccountManager.create_party(_initial_mode)
			elif str(state.get("mode", "")) != _initial_mode and \
				str(state.get("host_code", "")) == str(AccountManager.profile.get("friend_code", "")) and \
				(state.get("members", []) as Array).size() == 1 and not bool(state.get("queued", false)):
				result = await AccountManager.set_party_mode(_initial_mode)
	_loading_room = false
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) == 200:
		_apply((result.get("body", {}) as Dictionary).get("state", {}))
	elif _local_only:
		if int(result.get("code", 0)) == 404 and str(result.get("error", "")) == "Not Found":
			_load_error = _text("组队服务未更新（404）", "Party service unavailable (404)")
		else:
			_load_error = str(result.get("error", _text("无法进入队伍", "Unable to join party")))
		_notice.text = _load_error


func _load_friends() -> void:
	var result: Dictionary = await AccountManager.fetch_friends()
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) == 200:
		_friends = (result.get("body", {}) as Dictionary).get("friends", [])
		_render_friends()


func _on_realtime(payload: Dictionary) -> void:
	if str(payload.get("t", "")) == "party":
		if str(payload.get("state", "")) == "room":
			_apply(payload)
		elif str(payload.get("state", "")) == "closed" and _preview == "":
			back_requested.emit()
	elif str(payload.get("t", "")) == "match":
		var match_state := str(payload.get("state", ""))
		if match_state == "found":
			_match_found = true
		elif _match_found and match_state in ["queued", "idle"]:
			stop_party_voice()
			back_requested.emit()


func _process(delta: float) -> void:
	if _preview != "" or _busy:
		return
	_poll_elapsed += delta
	if _poll_elapsed >= (30.0 if _local_only else 7.0):
		_poll_elapsed = 0.0
		if _local_only:
			_load_room()
			return
		var result: Dictionary = await AccountManager.fetch_party()
		if is_inside_tree() and int(result.get("code", 0)) == 200:
			var state: Dictionary = (result.get("body", {}) as Dictionary).get("state", {})
			if str(state.get("state", "")) == "room":
				_apply(state)
			elif bool(_room.get("queued", false)):
				stop_party_voice()
				back_requested.emit()


func _change_mode(mode: String) -> void:
	if _local_only:
		return
	if _preview != "":
		_room["mode"] = mode
		_apply(_room)
		return
	_run(AccountManager.set_party_mode.bind(mode))


func _invite(code: String) -> void:
	if _local_only:
		return
	if _preview != "":
		_notice.text = _text("已发送邀请", "Invitation sent")
		return
	_run(AccountManager.invite_to_party.bind(code))


func _toggle_pet(pet_id: String) -> void:
	if _local_only:
		return
	var chosen: Array = (_room.get("pets", []) as Array).duplicate()
	if chosen.has(pet_id):
		chosen.erase(pet_id)
	elif chosen.size() < 5:
		chosen.append(pet_id)
	else:
		_notice.text = _text("最多展示 5 只宠物", "Display up to 5 pets")
		return
	if _preview != "":
		_room["pets"] = chosen
		_apply(_room)
		return
	_run(AccountManager.set_party_pets.bind(chosen))


func _send_chat() -> void:
	if _local_only:
		return
	var message := _chat_input.text.strip_edges()
	if message.is_empty() or _busy:
		return
	_chat_input.clear()
	if _preview != "":
		var log: Array = _room.get("messages", [])
		log.append({"name": "我", "text": message})
		_room["messages"] = log
		_render_chat()
		return
	_run(AccountManager.send_party_chat.bind(message))


func _act() -> void:
	if _local_only:
		return
	if _preview != "":
		_notice.text = _text("预览模式", "Preview mode")
		return
	if _is_host():
		_run(AccountManager.start_party_match)
	else:
		_run(AccountManager.set_party_ready.bind(not bool(_my_member().get("ready", false))))


func _leave() -> void:
	if _preview == "" and not _local_only:
		await AccountManager.leave_party()
	back_requested.emit()


func _run(action: Callable) -> void:
	if _busy:
		return
	_busy = true
	var result: Dictionary = await action.call()
	_busy = false
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) == 200:
		_apply((result.get("body", {}) as Dictionary).get("state", {}))
	else:
		_notice.text = str(result.get("error", _text("操作失败", "Action failed")))


func _is_host() -> bool:
	if _preview != "":
		return _preview == "host"
	return str(_room.get("host_code", "")) == str(AccountManager.profile.get("friend_code", ""))


func _my_member() -> Dictionary:
	if _preview == "guest":
		return (_room.get("members", []) as Array)[1]
	var code := str(AccountManager.profile.get("friend_code", ""))
	for raw in _room.get("members", []):
		var entry: Dictionary = raw
		if str(entry.get("friend_code", "")) == code:
			return entry
	return {}


func _preview_room() -> Dictionary:
	return {"state": "room", "id": "preview", "mode": "ranked", "host_code": "ABCD1234",
		"members": [
			{"friend_code": "ABCD1234", "player_name": "星河", "avatar": AVATARS.default_avatar(),
			 "avatar_frame": AVATARS.default_frame(), "tier": 3, "host": true, "ready": true},
			{"friend_code": "EFGH5678", "player_name": "风铃", "avatar": AVATARS.default_avatar(),
			 "avatar_frame": AVATARS.default_frame(), "tier": 2, "host": false, "ready": _preview == "host"},
		], "pets": ["pet_cat", "pet_rabbit", "pet_mushroom"], "messages": [
			{"name": "星河", "text": "等你准备，我们就去排位。"},
			{"name": "风铃", "text": "好，宠物都在这里呢！"}], "queued": false}


func _toggle_voice() -> void:
	if _local_only:
		return
	if _preview != "":
		_notice.text = _text("预览模式未连接语音", "Voice is offline in preview")
		return
	var error: String = _party_voice.cycle()
	if not error.is_empty():
		_notice.text = error


func stop_party_voice() -> void:
	if _party_voice != null:
		_party_voice.stop()


func _toggle_friends_drawer() -> void:
	_pets_drawer.visible = false
	_friends_drawer.visible = not _friends_drawer.visible
	_friend_rail.visible = not _friends_drawer.visible
	_friends_toggle.visible = not _friends_drawer.visible


func _toggle_pets_drawer() -> void:
	_friends_drawer.visible = false
	_friend_rail.visible = true
	_friends_toggle.visible = true
	_pets_drawer.visible = not _pets_drawer.visible


func _toggle_chat() -> void:
	_chat_expanded = not _chat_expanded
	_chat_panel.position.y = 483 if _chat_expanded else 730
	_chat_panel.size.y = 411 if _chat_expanded else 164
	_chat_scroll.size.y = 304 if _chat_expanded else 57
	_chat_input.position.y = 358 if _chat_expanded else 111
	_chat_toggle.text = "⌄" if _chat_expanded else "⌃"
	for child in _chat_panel.get_children():
		if child is Button and child != _chat_toggle:
			child.position.y = 358 if _chat_expanded else 111
	_render_chat()


func _paper_panel(parent: Control, pos: Vector2, dimensions: Vector2, opacity: float) -> Panel:
	var panel := Panel.new()
	panel.position = pos
	panel.size = dimensions
	panel.custom_minimum_size = dimensions
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.93, 0.90, 0.77, opacity)
	style.border_color = Color(0.83, 0.68, 0.34, 0.88)
	style.set_border_width_all(1)
	style.set_corner_radius_all(18)
	panel.add_theme_stylebox_override("panel", style)
	parent.add_child(panel)
	return panel


func _friend_avatar(parent: Control, entry: Dictionary, pos: Vector2, diameter: int) -> Button:
	var button := Button.new()
	button.position = pos
	button.size = Vector2(diameter, diameter)
	button.custom_minimum_size = button.size
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.tooltip_text = str(entry.get("player_name", ""))
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.98, 0.95, 0.83, 0.96)
	style.border_color = GOLD
	style.set_border_width_all(2)
	style.set_corner_radius_all(diameter / 2)
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		button.add_theme_stylebox_override(state, style)
	parent.add_child(button)
	var mask := Panel.new()
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	var circle := StyleBoxFlat.new()
	circle.bg_color = Color.WHITE
	circle.set_corner_radius_all(diameter / 2)
	mask.add_theme_stylebox_override("panel", circle)
	button.add_child(mask)
	mask.position = Vector2(8, 8)
	mask.size = Vector2(diameter - 16, diameter - 16)
	var portrait := TextureRect.new()
	portrait.texture = AVATARS.texture_for(str(entry.get("avatar", "")), true)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.add_child(portrait)
	portrait.position = Vector2.ZERO
	portrait.size = mask.size
	var dot := Panel.new()
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dot_style := StyleBoxFlat.new()
	dot_style.bg_color = Color("4fc980") if bool(entry.get("online", false)) else Color("999b8e")
	dot_style.border_color = Color.WHITE
	dot_style.set_border_width_all(2)
	dot_style.set_corner_radius_all(10)
	dot.add_theme_stylebox_override("panel", dot_style)
	button.add_child(dot)
	dot.position = Vector2(diameter - 22, diameter - 22)
	dot.size = Vector2(17, 17)
	return button


func _style_paper_button(button: Button, selected: bool) -> void:
	if button.size.x <= 80.0:
		_style_compact_button(button, selected)
		return
	var normal := _button_plate(BUTTON_SECONDARY,
		Color(1.0, 0.97, 0.88) if selected else Color.WHITE)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("focus", normal)
	button.add_theme_stylebox_override("hover", _button_plate(BUTTON_SECONDARY,
		Color(1.12, 1.08, 0.96)))
	button.add_theme_stylebox_override("pressed", _button_plate(BUTTON_SECONDARY,
		Color(0.84, 0.82, 0.78)))
	button.add_theme_stylebox_override("hover_pressed", _button_plate(BUTTON_SECONDARY,
		Color(0.84, 0.82, 0.78)))
	button.add_theme_stylebox_override("disabled", _button_plate(BUTTON_SECONDARY,
		Color(0.66, 0.67, 0.63, 0.74)))
	button.add_theme_color_override("font_color", CREAM)
	button.add_theme_color_override("font_hover_color", Color("fff7df"))
	button.add_theme_color_override("font_pressed_color", CREAM)
	button.add_theme_color_override("font_disabled_color", Color("d1c8ad"))
	button.add_theme_color_override("font_outline_color", Color("2c1b11"))
	button.add_theme_constant_override("outline_size", 2)
	button.add_theme_font_size_override("font_size", 18)


func _style_compact_button(button: Button, selected: bool) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("a16c30") if selected else Color("684528")
	normal.border_color = Color("e6c984")
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(10)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color("b17a38")
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color("503c29")
	for state in ["normal", "focus", "disabled"]:
		button.add_theme_stylebox_override(state, normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("hover_pressed", pressed)
	button.add_theme_color_override("font_color", CREAM)
	button.add_theme_color_override("font_hover_color", CREAM)
	button.add_theme_color_override("font_pressed_color", CREAM)
	button.add_theme_color_override("font_disabled_color", Color("c5b796"))
	button.add_theme_font_size_override("font_size", 18)


func _button_plate(texture: Texture2D, tint: Color) -> StyleBoxTexture:
	var atlas := AtlasTexture.new()
	atlas.atlas = texture
	# Crop the generated transparent padding in source-image coordinates.
	# The region scales with Godot's mobile-friendly texture import size limit.
	var source_size: Vector2
	var crop: Rect2
	if texture == BUTTON_PRIMARY:
		source_size = Vector2(1916, 821)
		crop = Rect2(26, 96, 1866, 620)
	elif texture == BUTTON_SECONDARY:
		source_size = Vector2(1944, 809)
		crop = Rect2(31, 168, 1886, 472)
	elif texture == BUTTON_MODE_IDLE:
		source_size = Vector2(2022, 778)
		crop = Rect2(27, 135, 1969, 506)
	else:
		source_size = Vector2(2023, 777)
		crop = Rect2(23, 125, 1977, 512)
	var scale: Vector2 = texture.get_size() / source_size
	atlas.region = Rect2(crop.position * scale, crop.size * scale)
	var style := StyleBoxTexture.new()
	style.texture = atlas
	style.modulate_color = tint
	return style


func _style_chat_input(input: LineEdit) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1.0, 0.98, 0.90, 0.86)
	style.border_color = Color("c5ad75")
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	input.add_theme_stylebox_override("normal", style)
	input.add_theme_stylebox_override("focus", style)
	input.add_theme_color_override("font_color", Color("354330"))
	input.add_theme_color_override("font_placeholder_color", Color("7c816e"))


func _style_empty_seat(button: Button) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.96, 0.91, 0.69, 0.13)
	normal.border_color = Color(GOLD.r, GOLD.g, GOLD.b, 0.92)
	normal.set_border_width_all(3)
	normal.set_corner_radius_all(70)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.96, 0.91, 0.69, 0.31)
	for state in ["normal", "disabled", "focus"]:
		button.add_theme_stylebox_override(state, normal)
	for state in ["hover", "pressed", "hover_pressed"]:
		button.add_theme_stylebox_override(state, hover)
	button.add_theme_color_override("font_color", CREAM)
	button.add_theme_color_override("font_disabled_color", CREAM)
	button.add_theme_font_size_override("font_size", 64)


func _label(parent: Control, value: String, pos: Vector2,
		dimensions: Vector2, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.position = pos
	label.size = dimensions
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label


func _button(parent: Control, value: String, pos: Vector2, dimensions: Vector2) -> Button:
	var button := Button.new()
	button.text = value
	button.position = pos
	button.custom_minimum_size = dimensions
	button.size = dimensions
	parent.add_child(button)
	return button


func _style_mode(button: Button, selected: bool) -> void:
	var texture: Texture2D = BUTTON_MODE_ACTIVE if selected else BUTTON_MODE_IDLE
	var normal := _button_plate(texture, Color.WHITE)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("focus", normal)
	button.add_theme_stylebox_override("hover", _button_plate(texture,
		Color(1.10, 1.08, 1.02)))
	button.add_theme_stylebox_override("pressed", _button_plate(texture,
		Color(0.87, 0.86, 0.83)))
	button.add_theme_stylebox_override("hover_pressed", _button_plate(texture,
		Color(0.87, 0.86, 0.83)))
	button.add_theme_stylebox_override("disabled", _button_plate(texture,
		Color(0.64, 0.65, 0.62, 0.72)))
	var text_color := CREAM
	button.add_theme_color_override("font_color", text_color)
	button.add_theme_color_override("font_hover_color", text_color)
	button.add_theme_color_override("font_pressed_color", text_color)
	button.add_theme_color_override("font_disabled_color", Color("d1c8ad"))
	button.add_theme_color_override("font_outline_color", Color("342010"))
	button.add_theme_constant_override("outline_size", 2)
	button.add_theme_font_size_override("font_size", 24)


func _style_action() -> void:
	var normal := _button_plate(BUTTON_PRIMARY, Color.WHITE)
	_action.add_theme_stylebox_override("normal", normal)
	_action.add_theme_stylebox_override("focus", normal)
	_action.add_theme_stylebox_override("hover", _button_plate(BUTTON_PRIMARY,
		Color(1.10, 1.08, 1.02)))
	_action.add_theme_stylebox_override("pressed", _button_plate(BUTTON_PRIMARY,
		Color(0.85, 0.83, 0.80)))
	_action.add_theme_stylebox_override("hover_pressed", _button_plate(BUTTON_PRIMARY,
		Color(0.85, 0.83, 0.80)))
	_action.add_theme_stylebox_override("disabled", _button_plate(BUTTON_PRIMARY,
		Color(0.65, 0.66, 0.63, 0.73)))
	_action.add_theme_color_override("font_color", CREAM)
	_action.add_theme_color_override("font_hover_color", Color("fff7df"))
	_action.add_theme_color_override("font_pressed_color", CREAM)
	_action.add_theme_color_override("font_disabled_color", Color("d6d0b4"))
	_action.add_theme_color_override("font_outline_color", Color("342010"))
	_action.add_theme_constant_override("outline_size", 3)
	_action.add_theme_font_size_override("font_size", 28)


func _clear_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()


func _pet_name(pet_id: String) -> String:
	match pet_id:
		"pet_cat": return _text("猫", "Cat")
		"pet_rabbit": return _text("兔子", "Rabbit")
		"pet_mushroom": return _text("蘑菇", "Mushroom")
	return pet_id


func _is_en() -> bool:
	return LocaleManager.get_locale().begins_with("en")


func _text(zh: String, en: String) -> String:
	return en if _is_en() else zh
