extends RefCounted

# 房间里的小弹层（2026-11-26 自定义房间改版；排位房 PartyLobby 同一套）。
#
#   open_choice_list   锚在某颗按钮旁的单选列表（自定义房间的 AI 难度；好友界面的「⋯」菜单）。
#   open_friend_card   点朋友列表一行弹出的横条卡片：头像 / 名字 / 状态 和
#                      [查看资料] [邀请] [私聊] 排在**同一排**（用户 11-26 定：不要放下方）。
#   open_private_chat  在房间上面叠一层完整的私聊界面（ChatScreen），返回就回到房间。
#
# 都走 ModalStack：点弹层外面（透明遮罩）或按返回键就关；页面被 free 时
# ModalStack 按 owner 自动收掉 —— 开局切场景时不会留下孤儿弹层。
#
# 尺寸：调用方传「参考画布」上的数字和换算系数 k（屏幕像素 / 参考像素），这里直接按
# 最终像素建控件，不用 Control.scale（缩放节点会让字发虚）。可点控件的短边不低于
# Tokens.TOUCH_MIN。
#
# ⚠️ 本文件不写自绘按钮 / 自绘 StyleBox：procedural_ui_ratchet 盯着 ui/ 下这两类调用的
# 总数，只许降。按钮一律实例化 GloryActionButton.tscn，外观走 ParchmentKit。

const Kit := preload("res://ui/theme/ParchmentKit.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const AvatarCatalog := preload("res://scripts/account/AvatarCatalog.gd")
const ACTION := preload("res://ui/components/GloryActionButton.tscn")
const GloryToast := preload("res://ui/components/GloryToast.gd")
const CHAT_SCENE_PATH := "res://scenes/menu/ChatScreen.tscn"
const PROFILE_SCENE_PATH := "res://scenes/menu/ProfileScreen.tscn"

const CHAT_MODAL_ID := "room_private_chat"
const CHAT_PROFILE_MODAL_ID := "room_private_chat_profile"
# 小弹层压在房间之上、设定 / 资料（50）之下；私聊里再点资料要盖过私聊，所以 55。
const POPOVER_PRIORITY := 45
const CHAT_PRIORITY := 50
const CHAT_PROFILE_PRIORITY := 55

const CLEAR := Color(0, 0, 0, 0)
const ANCHOR_GAP := 8.0      # 弹层离锚点的距离（参考像素）
const EDGE_MARGIN := 6.0     # 贴屏幕边时至少留的空（屏幕像素）
# 单选列表的「挖洞暗幕」（open_choice_list 的 spotlight 参数，11-26 好友界面「⋯」菜单用）：
# 除了洞以外整屏压暗，让玩家看清这个菜单是对哪一行的。用户 11-26 定 50%。
const SPOTLIGHT_DIM := Color(0, 0, 0, 0.5)
const SPOTLIGHT_FADE := 0.12

# 卡片里各块的参考尺寸。
const CARD_AVATAR := 58.0
const CARD_NAME_W := 168.0
const CARD_BUTTON_W := 112.0
const CARD_BUTTON_H := 58.0
const CARD_FONT := 18
const CARD_NAME_FONT := 20
const CARD_STATE_FONT := 16


# --- 单选列表 -------------------------------------------------------------------

# items: [{"text": String, "value": Variant, "selected": bool}]
# anchor: 锚点控件的全局矩形（get_global_rect()）。open_up=true 时列表长在锚点上方。
# 选中某一项：先关列表，再 on_pick.call(value)。返回 ModalStack 的 id（没推上去为空串）。
# item_h_ref：每项的参考高度（11-26 好友界面「⋯」菜单要更大的项才加的；默认 52 = 原来的值）。
# spotlight：全局坐标的矩形。给了（有面积）就铺一层 SPOTLIGHT_DIM 暗幕，只把这块留亮；
#            不给 = 不压暗（AI 难度列表就是这样）。洞按打开那一刻的位置挖，之后不跟随 ——
#            调用方要保证菜单开着时洞底下的东西不挪（见 FriendsScreen._render 的说明）。
static func open_choice_list(owner: Control, id: String, anchor: Rect2, k: float, items: Array,
		on_pick: Callable, open_up := false, width_ref := 150.0, font_ref := 17,
		item_h_ref := 52.0, spotlight := Rect2()) -> String:
	if owner == null or not owner.is_inside_tree() or ModalStack.has(id):
		return ""
	var root := _overlay()
	var dim: Control = null
	if spotlight.has_area():
		# 先加暗幕再加列表：列表要盖在暗幕上面，不能被一起压暗。
		dim = _spotlight_dim(spotlight)
		root.add_child(dim)
	var panel := PanelContainer.new()
	panel.name = "ChoiceList"
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", Kit.box("slot", Vector4(14, 14, 14, 14)))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", maxi(2, roundi(4.0 * k)))
	panel.add_child(column)
	var item_size := Vector2(roundf(width_ref * k), _touch(item_h_ref * k))
	for raw in items:
		var item: Dictionary = raw
		var selected := bool(item.get("selected", false))
		var choice := ACTION.instantiate() as Button
		choice.name = "Choice_%s" % str(item.get("value", ""))
		choice.custom_minimum_size = item_size
		choice.size_flags_horizontal = Control.SIZE_FILL
		choice.focus_mode = Control.FOCUS_NONE
		choice.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		choice.text = ("✓ " if selected else "") + str(item.get("text", ""))
		Kit.style_plate(choice, selected)
		choice.add_theme_font_size_override("font_size", maxi(13, roundi(font_ref * k)))
		var value: Variant = item.get("value")
		choice.pressed.connect(func() -> void:
			ModalStack.pop(id)
			if on_pick.is_valid():
				on_pick.call(value))
		column.add_child(choice)
	root.add_child(panel)
	var pushed := ModalStack.push(root, {
		"id": id, "owner": owner, "priority": POPOVER_PRIORITY,
		"dismiss_on_backdrop": true, "backdrop_color": CLEAR,
		# 下拉列表不是对话框，不响弹窗音。
		"popup_sfx": false,
	})
	if pushed.is_empty():
		return ""
	_follow_anchor(panel, anchor, "above" if open_up else "below", ANCHOR_GAP * k)
	# 暗幕淡入。只在已经进树时做：ModalStack 偶尔把挂载推迟到帧末，那时不做淡入、直接全暗，
	# 免得补间没跑起来、暗幕一直停在全透明。
	var fade := Tokens.motion(SPOTLIGHT_FADE)
	if dim != null and fade > 0.0 and dim.is_inside_tree():
		dim.modulate.a = 0.0
		dim.create_tween().tween_property(dim, "modulate:a", 1.0, fade)
	return pushed


# --- 好友卡片 -------------------------------------------------------------------

# friend:      好友条目（AccountManager.fetch_friends 返回的一项）。
# state_text / state_color: 状态字（在线 / 对局中 / 离线）和颜色，由调用方按自己的分档给。
# invite:      {"text": String, "enabled": bool}，邀请键此刻的字和能不能点。
# actions:     {"profile": Callable(), "invite": Callable(button: Button), "chat": Callable()}
#              查看资料 / 私聊会先关卡片再调；邀请**不关**卡片（发完要把键改成「已邀请」），
#              回调拿到那颗键，自己改字、自己禁用。
# 卡片长在锚点（那一行）的左边，垂直居中对齐；左边放不下时按屏幕边夹住。
# 返回邀请键；没推上去返回 null。
static func open_friend_card(owner: Control, id: String, anchor: Rect2, k: float, friend: Dictionary,
		state_text: String, state_color: Color, invite: Dictionary, actions: Dictionary) -> Button:
	if owner == null or not owner.is_inside_tree() or ModalStack.has(id):
		return null
	var code := str(friend.get("friend_code", ""))
	var root := _overlay()
	var panel := PanelContainer.new()
	panel.name = "FriendCard"
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", Kit.box("slot", Vector4(18, 14, 18, 14)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", maxi(4, roundi(10.0 * k)))
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(row)

	var avatar := TextureRect.new()
	avatar.name = "Avatar"
	avatar.custom_minimum_size = Vector2.ONE * roundf(CARD_AVATAR * k)
	avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	AvatarCatalog.set_avatar_texture(avatar, AvatarCatalog.texture_for(
		str(friend.get("avatar", AvatarCatalog.default_avatar())), true))
	row.add_child(avatar)

	var info := VBoxContainer.new()
	info.custom_minimum_size.x = roundf(CARD_NAME_W * k)
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	info.add_theme_constant_override("separation", 0)
	row.add_child(info)
	var name_label := Label.new()
	name_label.name = "Name"
	# 房间里一律只显示昵称（10.04 bug 文档第 5 条），与座位、朋友列表一致。
	name_label.text = AccountManager.display_name(str(friend.get("player_name", "")), code, false)
	name_label.tooltip_text = name_label.text
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.add_theme_font_size_override("font_size", maxi(13, roundi(CARD_NAME_FONT * k)))
	name_label.add_theme_color_override("font_color", Kit.INK)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.add_child(name_label)
	var state_label := Label.new()
	state_label.name = "State"
	state_label.text = state_text
	state_label.add_theme_font_size_override("font_size", maxi(12, roundi(CARD_STATE_FONT * k)))
	state_label.add_theme_color_override("font_color", state_color)
	state_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.add_child(state_label)

	var button_size := Vector2(roundf(CARD_BUTTON_W * k), _touch(CARD_BUTTON_H * k))
	var font := maxi(13, roundi(CARD_FONT * k))
	var profile_btn := _card_button(_t("查看资料", "Profile"), button_size, font, false)
	profile_btn.name = "ProfileButton"
	profile_btn.pressed.connect(func() -> void:
		ModalStack.pop(id)
		var cb: Callable = actions.get("profile", Callable())
		if cb.is_valid():
			cb.call())
	row.add_child(profile_btn)

	var invite_enabled := bool(invite.get("enabled", false))
	var invite_btn := _card_button(str(invite.get("text", _t("邀请", "Invite"))), button_size, font, invite_enabled)
	invite_btn.name = "InviteButton"
	invite_btn.disabled = not invite_enabled
	invite_btn.pressed.connect(func() -> void:
		var cb: Callable = actions.get("invite", Callable())
		if cb.is_valid():
			cb.call(invite_btn))
	row.add_child(invite_btn)

	var chat_btn := _card_button(_t("私聊", "Chat"), button_size, font, false)
	chat_btn.name = "ChatButton"
	chat_btn.pressed.connect(func() -> void:
		ModalStack.pop(id)
		var cb: Callable = actions.get("chat", Callable())
		if cb.is_valid():
			cb.call())
	if not code.is_empty() and ChatService.has_unread(code):
		_attach_unread_dot(chat_btn)
	row.add_child(chat_btn)

	root.add_child(panel)
	var pushed := ModalStack.push(root, {
		"id": id, "owner": owner, "priority": POPOVER_PRIORITY,
		"dismiss_on_backdrop": true, "backdrop_color": CLEAR,
	})
	if pushed.is_empty():
		return null
	_follow_anchor(panel, anchor, "left", ANCHOR_GAP * k)
	return invite_btn


# 改邀请键的字和能不能点（发送中 / 已邀请 / 失败后恢复，由调用方决定）。
# 参数故意不标类型：调用方常在 await 网络之后才调，那时卡片可能已经被关掉、键已经释放 ——
# 带类型的参数接一个已释放的对象会直接报错，这里先判有效再转。
static func set_card_invite(button: Variant, text: String, enabled: bool) -> void:
	if not is_instance_valid(button) or not (button is Button):
		return
	var b: Button = button
	b.text = text
	b.disabled = not enabled
	Kit.style_plate(b, enabled)


# --- 私聊 -----------------------------------------------------------------------

# 在房间上面叠一层完整的私聊界面，定位到 code 这个人。
#
# 不走 Main._show_chat_screen：那条路先 _clear() 掉当前页面 —— 在房间里点私聊
# 等于离开房间页。这里推上 ModalStack，房间照常在底下跑（座位、语音、开局都不受影响），
# 返回就回到房间；开局切场景时房间页被 free，ModalStack 按 owner 自动收掉这一层。
#
# ChatScreen 里的「立即参与」（房间邀请）和「加入」（组队邀请）在房间里不能直接走 ——
# 那等于不退房就进另一个房。这里接住这两个信号，只提示「先退出当前房间」。
static func open_private_chat(owner: Control, code: String) -> void:
	if owner == null or not owner.is_inside_tree() or ModalStack.has(CHAT_MODAL_ID):
		return
	var scene := load(CHAT_SCENE_PATH) as PackedScene
	if scene == null:
		GloryToast.show_text(_t("私聊暂时打不开，请稍后重试", "Chat is unavailable. Try again later."))
		return
	# 同 Team3v3Lobby._view_player_profile 的写法：按 Control 拿实例，直接调脚本方法 / 接信号
	# （不走 call("名字") —— 按名字的调用编译器管不到，见 tools/dynamic_call_check.gd）。
	var screen := scene.instantiate() as Control
	screen.configure(code)
	screen.back_requested.connect(func() -> void: ModalStack.pop(CHAT_MODAL_ID))
	screen.join_room_requested.connect(func(_room_id: int) -> void: _toast_already_in_room())
	screen.join_party_requested.connect(func(_party_id: String, _mode: String) -> void: _toast_already_in_room())
	screen.profile_requested.connect(func(friend_code: String, _tab: String, _conversation: String) -> void: open_public_profile(owner, friend_code, CHAT_PROFILE_MODAL_ID, CHAT_PROFILE_PRIORITY))
	ModalStack.push(screen, {
		"id": CHAT_MODAL_ID, "owner": owner, "priority": CHAT_PRIORITY,
		"dismiss_on_backdrop": false,
	})


# 公开资料（同 Team3v3Lobby._view_player_profile / PartyLobby._view_member_profile）。
# 自己的码、或者码还没拿到（不是 8 位）时不开。
static func open_public_profile(owner: Control, code: String, modal_id: String, priority := 50) -> void:
	if owner == null or not owner.is_inside_tree() or ModalStack.has(modal_id):
		return
	var target := AccountManager.normalize_friend_code(code)
	var own := AccountManager.normalize_friend_code(str(AccountManager.profile.get("friend_code", "")))
	if target.length() != 8 or target == own:
		return
	var screen := (load(PROFILE_SCENE_PATH) as PackedScene).instantiate() as Control
	screen.configure_public(target)
	screen.back_requested.connect(func() -> void: ModalStack.pop(modal_id))
	ModalStack.push(screen, {"id": modal_id, "owner": owner, "priority": priority, "dismiss_on_backdrop": false})


# --- 内部 -----------------------------------------------------------------------

static func _toast_already_in_room() -> void:
	GloryToast.show_text(_t("你已在房间里，请先退出当前房间再加入", "You're already in a room. Leave it first."))


# ModalStack 的内容根：铺满、自己不吃点击 —— 点到卡片外面的地方落到 ModalStack 的
# 透明遮罩上，遮罩按 dismiss_on_backdrop 把弹层关掉。
static func _overlay() -> Control:
	var root := Control.new()
	root.name = "LobbyPopover"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return root


# 挖洞暗幕：四块 ColorRect 围着 hole 拼成一圈（不用着色器，也不算自绘 StyleBox）。
# 只用锚点 + 偏移：父节点（_overlay）铺满全屏，所以不用知道屏幕多大，四块总能盖到屏幕边。
# 全部 MOUSE_FILTER_IGNORE —— 点哪里都落到 ModalStack 的透明遮罩上，照常「点外面就关」，
# 洞里那一行也点不到（菜单开着时只做这一件事）。
static func _spotlight_dim(hole: Rect2) -> Control:
	var dim := Control.new()
	dim.name = "SpotlightDim"
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 上：整宽，到洞顶。下：洞底到屏幕底，整宽。左 / 右：洞的高度那一截。
	dim.add_child(_dim_piece("Top", 1.0, 0.0, 0.0, 0.0, 0.0, hole.position.y))
	dim.add_child(_dim_piece("Bottom", 1.0, 1.0, 0.0, hole.end.y, 0.0, 0.0))
	dim.add_child(_dim_piece("Left", 0.0, 0.0, 0.0, hole.position.y, hole.position.x, hole.end.y))
	dim.add_child(_dim_piece("Right", 1.0, 0.0, hole.end.x, hole.position.y, 0.0, hole.end.y))
	return dim


# 左、上锚点恒为 0；先设锚点再设偏移，偏移就是最终值。
static func _dim_piece(piece_name: String, anchor_r: float, anchor_b: float,
		left: float, top: float, right: float, bottom: float) -> ColorRect:
	var piece := ColorRect.new()
	piece.name = piece_name
	piece.color = SPOTLIGHT_DIM
	piece.mouse_filter = Control.MOUSE_FILTER_IGNORE
	piece.anchor_left = 0.0
	piece.anchor_top = 0.0
	piece.anchor_right = anchor_r
	piece.anchor_bottom = anchor_b
	piece.offset_left = left
	piece.offset_top = top
	piece.offset_right = right
	piece.offset_bottom = bottom
	return piece


static func _card_button(text: String, button_size: Vector2, font: int, gold: bool) -> Button:
	var button := ACTION.instantiate() as Button
	button.text = text
	button.custom_minimum_size = button_size
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.clip_text = true
	Kit.style_plate(button, gold)
	button.add_theme_font_size_override("font_size", font)
	return button


# 同 FriendsScreen._attach_unread_dot：按钮右上角一颗红点，颜色 Tokens.UNREAD_DOT。
static func _attach_unread_dot(button: Control) -> void:
	var dot := Label.new()
	dot.name = "UnreadDot"
	dot.text = "●"
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.add_theme_color_override("font_color", Tokens.UNREAD_DOT)
	button.add_child(dot)
	dot.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	dot.position.x -= 16


static func _touch(value: float) -> float:
	return roundf(maxf(Tokens.TOUCH_MIN, value))


# 内容最小尺寸要等进树、主题和字体都就位才准，所以先放一次，尺寸变了再放一次。
static func _follow_anchor(panel: Control, anchor: Rect2, side: String, gap: float) -> void:
	panel.resized.connect(func() -> void: _place(panel, anchor, side, gap))
	panel.reset_size()
	_place(panel, anchor, side, gap)


static func _place(panel: Control, anchor: Rect2, side: String, gap: float) -> void:
	if panel == null or not is_instance_valid(panel) or not panel.is_inside_tree():
		return
	var bounds := SafeArea.rect()
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		bounds = panel.get_viewport_rect()
	var s := panel.size
	var pos: Vector2
	match side:
		"above":
			pos = Vector2(anchor.get_center().x - s.x * 0.5, anchor.position.y - gap - s.y)
		"left":
			pos = Vector2(anchor.position.x - gap - s.x, anchor.get_center().y - s.y * 0.5)
		_:
			pos = Vector2(anchor.get_center().x - s.x * 0.5, anchor.end.y + gap)
	var min_x := bounds.position.x + EDGE_MARGIN
	var min_y := bounds.position.y + EDGE_MARGIN
	pos.x = clampf(pos.x, min_x, maxf(min_x, bounds.end.x - s.x - EDGE_MARGIN))
	pos.y = clampf(pos.y, min_y, maxf(min_y, bounds.end.y - s.y - EDGE_MARGIN))
	panel.position = pos


static func _t(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
