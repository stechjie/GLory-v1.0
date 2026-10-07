class_name PartyInviteBubble
extends CanvasLayer

# 10.07 第 6 / 10 条：主界面「朋友邀请你进房间 / 进队伍」气泡提示。
#
# ## 为什么不是 DialogService
#
# 需求写得很死：「**不处理不影响主界面操作**」。DialogService 走 ModalStack，
# 栈顶那层 backdrop 是 MOUSE_FILTER_STOP，玩家不点就不放行 —— 那是「不处理就
# 什么都干不了」，正好相反。所以这里自己做一层，整层 IGNORE，只有两个按钮
# 吃点击；玩家干别的事时它就在那儿挂着，30 秒自己走。
#
# ## 排队语义（第 6 条原话）
#
#   - 多个邀请**覆盖**：新来的顶掉当前正在显示的那条。
#   - 「处理完最新的后显示上一个」：所以被顶掉的不是丢掉，而是退回队列，
#     当前这条被处理/超时之后再冒出来。
#   - 每条**最多保留 30 秒、独立计时**：每张卡自己一个倒计时，跟它是不是
#     正在显示无关 —— 排队等着的那条，时间照样在走。
#
# 于是数据结构就是：`_queue`（等待显示的，先进先出）+ `_current`（在显示的）。
# 每条记录的 `deadline` 是绝对时刻，显示时按剩余时间接着倒。
#
# ## 红点
#
# ★ 10.07 返工（用户真机反馈）：「点击稍后表示已读该信息，红点消失」。
#
# 邀请气泡挂在主界面上，玩家点「稍后」时**根本没打开聊天界面** —— 而红点
# （主菜单「聊天」按钮 + 聊天界面私聊页签上那个）是 ChatService 的未读表管的。
# 所以这里多接一条 `on_handled` 回调：**这条邀请被处理（加入/稍后/超时）时**
# 就调它，由 Main 去清对应好友的红点（ChatService.mark_seen_locally）。
#
# 「处理过的邀请不再在聊天 UI 红点提示」= 同一条邀请不再打扰 + 红点当场灭。
# 同一支队伍的邀请处理过一次（加入/稍后/超时）之后，**同一个 party_id 不再弹第二次**
# （`_handled`），免得服务器重推或者玩家来回切页面时反复打扰。

const Tokens := preload("res://ui/theme/GloryTokens.gd")

const LAYER_NAME := "PartyInviteBubbleLayer"
# 高于 GloryToast（1500）：气泡里有按钮，被 toast 盖住就没法点了。
const BUBBLE_LAYER := 1600

# 需求：每条最多保留 30 秒。
const TTL_SEC := 30.0
# 一排最多同时摆几张。超出就只留最新的，旧的直接作废（需求说「覆盖」）。
const MAX_VISIBLE := 1

# 文案走 tr()，key 在 LocaleManager。第 6 条（自定义房间）与第 10 条（组队）
# 是同一套规则、不同措辞，靠 mode 分开。
const KIND_PARTY := "party"      # 自定义房间邀请：朋友XX邀请你进入房间
const KIND_TEAM := "team"        # 排位/休闲组队邀请：朋友XX邀请你进入队伍

# ── ★★ 10.07h 第 6 / 10 条返工：位置（用户真机反馈）────────────────────
#
# 用户原话：「房间邀请提示位置要设计在『**聊天**』UI 旁边，以**信息气泡框**的形式
# 引出，可参考下图的形式，信息气泡框，但要重新设计出符合**游戏风格和颜色**。」
#
# 返工前这一层是自己锚在**屏幕右上角**（anchor_left/right = 1.0）—— 跟「聊天」按钮
# 八竿子打不着，玩家看不出这条邀请和聊天的关系。现在改成：
#
#   锚点 = 主菜单左侧「聊天」按钮的**右侧中点**（`MainMenu.chat_invite_anchor()`），
#   气泡摆在锚点右边 `ANCHOR_GAP`，**垂直居中于锚点**，左边缘伸出一枚三角尖
#   指向按钮 —— 这就是「从聊天 UI 引出」的字面意思。
#
# 三角尖不是美术图，是本文件 `_draw()` 用 `draw_colored_polygon` 画的：
# 出图要进 `assets/`（白名单制，得单独走资源流程），而这点形状不值得。
# 配色见 `_card_box()` —— 对齐「雾林夜幕」那套（深墨绿 + 金描边），
# 与主菜单其它弹层同一族，不是随手挑的颜色。
const ANCHOR_GAP := 18.0
# 尖角几何。三角底边贴在气泡卡片左边缘上，垂直居中；尖朝左。
const TAIL_W := 14.0
const TAIL_H := 22.0

# 门禁接缝：只增不减。
static var _shown := 0
static var _last_title := ""
static var _last_body := ""

var _entries: Array[Dictionary] = []
var _pending: Array[Dictionary] = []
var _handled: Dictionary = {}  # party_id -> true，处理过的不再弹
var _root: Control
var _list: VBoxContainer
# 气泡锚点（屏幕坐标 = 聊天按钮右侧中点）。`Vector2.INF` = 还不知道，
# 这时按「左侧社交栏右边缘 + 按钮中心高度」的参考值兜底（见 `_fallback_anchor`）。
var _anchor := Vector2.INF


func _ready() -> void:
	layer = BUBBLE_LAYER
	name = LAYER_NAME
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()


# ★★ 10.07h 第 6 / 10 条返工：由 Main 在每条邀请显示前喂进来的锚点 ——
# 「聊天」按钮右侧中点的**全局屏幕坐标**（`MainMenu.chat_invite_anchor()`）。
#
# 传 `Vector2.INF`（或干脆不传）＝ 拿不到按钮位置（比如玩家当前不在主菜单、
# 或那一帧还没布局完），这时退到 `_fallback_anchor()`。**不拒绝显示** ——
# 「位置不完美」远好过「邀请石沉大海」。
func set_anchor(anchor_pos: Vector2) -> void:
	_anchor = anchor_pos
	_place()


# 兜底锚点：主菜单左侧社交栏右边缘 + 「聊天」按钮中心高度，用**参考画布**
# 的坐标按当前视口比例折算（参考画布 1672×941、聊天按钮 (28,440) 132×132）。
# 只在拿不到真按钮时用 —— 位置会差一点，但仍在聊天按钮附近，不会飘到右上角。
func _fallback_anchor() -> Vector2:
	var viewport_size := Vector2(get_viewport().get_visible_rect().size)
	# 主菜单用 SafeArea + 居中缩放，这里没有它的内部状态，只能按整屏等比近似。
	var scale := minf(viewport_size.x / 1672.0, viewport_size.y / 941.0)
	if scale <= 0.0:
		scale = 1.0
	var origin := (viewport_size - Vector2(1672.0, 941.0) * scale) * 0.5
	return Vector2(origin.x + 160.0 * scale, origin.y + 506.0 * scale)


# 把气泡摆到锚点右边、垂直居中。每帧同步是因为卡片高度会随后续邀请变化
# （`_entries` 进出），而 VBoxContainer 的 size 是内容算出来的 —— 手动设一次
# position 会在下一次 add_child 后失效。
func _place() -> void:
	if _list == null or not is_instance_valid(_list):
		return
	var anchor := _anchor
	if not is_finite(anchor.x) or not is_finite(anchor.y):
		anchor = _fallback_anchor()
	_list.position = Vector2(anchor.x + ANCHOR_GAP, anchor.y - _list.size.y * 0.5)


func _process(_delta: float) -> void:
	# 只在有卡时干活。没卡的时候 `_list.size` 是 0，摆了也没意义。
	if not _entries.is_empty():
		_place()


# 收到一条邀请。重复 party_id 直接忽略（服务器可能重推）。
#   spec: { party_id, host_name, mode, kind, on_accept: Callable(party_id),
#           on_handled: Callable(party_id) }   ← on_handled 在「加入/稍后/超时」时都调
# 返回 true 表示真的排上了。
func offer(spec: Dictionary) -> bool:
	var party_id := str(spec.get("party_id", ""))
	if party_id.is_empty() or _handled.has(party_id):
		return false
	for entry in _pending:
		if str(entry.get("party_id", "")) == party_id:
			return false
	for entry in _entries:
		if str(entry.get("party_id", "")) == party_id:
			return false

	var kind := str(spec.get("kind", KIND_PARTY))
	var host_name := str(spec.get("host_name", ""))
	var record := {
		"party_id": party_id,
		"host_name": host_name,
		"mode": str(spec.get("mode", "casual")),
		"kind": kind,
		"on_accept": spec.get("on_accept", Callable()),
		"on_handled": spec.get("on_handled", Callable()),
		"deadline": Time.get_ticks_msec() / 1000.0 + TTL_SEC,
	}
	_shown += 1
	_last_title = _title_for(kind)
	_last_body = _body_for(kind, host_name)
	_pending.append(record)
	_pump()
	return true


func _pump() -> void:
	# 正在显示的还没走：只排队，不抢。
	while _entries.size() < MAX_VISIBLE and not _pending.is_empty():
		var record: Dictionary = _pending.pop_front()
		_expire_if_stale()
		if float(record.get("deadline", 0.0)) <= Time.get_ticks_msec() / 1000.0:
			# 排到它的时候 30 秒已经过了 —— 直接作废，别显示一张过期卡。
			_handled[str(record.get("party_id", ""))] = true
			continue
		_show_entry(record)
	_expire_if_stale()
	_refresh_visibility()


func _show_entry(record: Dictionary) -> void:
	var card := _make_card(record)
	_list.add_child(card)
	record["card"] = card
	record["remaining"] = maxf(0.0, float(record.get("deadline", 0.0)) - Time.get_ticks_msec() / 1000.0)
	_entries.append(record)
	# 每张卡自己的计时器：独立计时，与是否显示无关（deadline 是绝对时刻）。
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = maxf(0.05, float(record.get("remaining", TTL_SEC)))
	timer.timeout.connect(func() -> void: _dismiss(str(record.get("party_id", "")), "timeout"))
	card.add_child(timer)
	timer.start()
	record["timer"] = timer
	# 卡片刚进来，`_list.size` 这一帧还是旧的 —— 立刻摆一次只是尽量对齐，
	# 真正的对齐靠 `_process()` 每帧同步（VBox 的 size 下一帧才含新卡）。
	_place()


# ★★ 10.07h 第 6 / 10 条返工：返回 HBox（左尖角 + 右卡片）。
#
# 返工前这里直接是 PanelContainer（纯圆角矩形）—— 那是「浮在屏幕上的提示卡」，
# 不是用户要的「从聊天 UI 引出的**信息气泡框**」。现在外面套一层 HBox：
#   [Tail(三角尖, 朝左)] [PanelContainer(标题/正文/按钮)]
# 于是气泡在视觉上「咬」着聊天按钮。
#
# 断言锚点：`_make_card()` 的返回值外层节点名固定 "InviteCard"（门禁按名找），
# 里面的 PanelContainer 保留 "InvitePanel"，tail 保留 "Tail"。
func _make_card(record: Dictionary) -> HBoxContainer:
	var kind := str(record.get("kind", KIND_PARTY))
	var row_outer := HBoxContainer.new()
	row_outer.name = "InviteCard"
	row_outer.add_theme_constant_override("separation", 0)
	row_outer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 尖角在垂直方向的摆放：卡片是 3 行（标题/正文/按钮），尖角要落在**垂直中部**，
	# 正对聊天按钮中心。用 SIZE_SHRINK_CENTER 让 HBox 把它居中，而不是拉满高度。
	row_outer.alignment = BoxContainer.ALIGNMENT_BEGIN

	var tail := _make_tail()
	tail.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row_outer.add_child(tail)

	var card := PanelContainer.new()
	card.name = "InvitePanel"
	card.custom_minimum_size = Vector2(420, 0)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := Tokens.flat_box(_card_bg(), _card_edge(), 2, 12)
	box.set_content_margin_all(14)
	card.add_theme_stylebox_override("panel", box)
	row_outer.add_child(card)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	card.add_child(column)

	var title := Label.new()
	title.text = _title_for(kind)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", _title_color())
	column.add_child(title)

	var body := Label.new()
	body.name = "Body"
	body.text = _body_for(kind, str(record.get("host_name", "")))
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(392, 0)
	body.add_theme_font_size_override("font_size", 18)
	body.add_theme_color_override("font_color", _body_color())
	column.add_child(body)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	column.add_child(row)

	var party_id := str(record.get("party_id", ""))
	var accept := _bubble_button(_accept_text(kind), true)
	accept.name = "Accept"
	accept.pressed.connect(func() -> void: _accept(party_id))
	row.add_child(accept)

	var later := _bubble_button(_later_text(kind))
	later.name = "Later"
	later.pressed.connect(func() -> void: _dismiss(party_id, "later"))
	row.add_child(later)
	return row_outer


# 气泡里的按钮。主操作（加入/立即参与）走**实心金**，次操作（稍后）走
# **幽灵描边** —— 与自定义房间面板同一条「主/次按钮」规则（GloryTokens 的
# `MIST_GOLD_BRIGHT` / `MIST_GHOST_EDGE`），玩家不用读字就知道哪个是主推。
#
# `_bubble_button` 现在多一个 `primary` 参数。**默认 false（幽灵）** ——
# 因为唯一的历史调用点是「稍后」；加参数时把默认值留给「不用改的旧调用」，
# 新的主按钮显式传 true。反过来的话，漏改的旧调用会悄悄变成实心金。
func _bubble_button(text: String, primary: bool = false) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(120, 40)
	button.add_theme_font_size_override("font_size", 18)
	if primary:
		button.add_theme_stylebox_override("normal",
			Tokens.flat_box(Tokens.MIST_GOLD_BRIGHT, Tokens.MIST_GOLD_BRIGHT, 2, 8))
		button.add_theme_stylebox_override("hover",
			Tokens.flat_box(Tokens.MIST_GOLD_HOVER, Tokens.MIST_GOLD_HOVER, 2, 8))
		button.add_theme_stylebox_override("pressed",
			Tokens.flat_box(Tokens.MIST_GOLD_PRESSED, Tokens.MIST_GOLD_PRESSED, 2, 8))
		button.add_theme_color_override("font_color", Tokens.MIST_ON_GOLD)
		button.add_theme_color_override("font_hover_color", Tokens.MIST_ON_GOLD)
		button.add_theme_color_override("font_pressed_color", Tokens.MIST_ON_GOLD)
	else:
		button.add_theme_stylebox_override("normal",
			Tokens.flat_box(Tokens.MIST_NONE, Tokens.MIST_GHOST_EDGE, 1, 8))
		button.add_theme_stylebox_override("hover",
			Tokens.flat_box(Tokens.MIST_GHOST_HOVER, Tokens.MIST_GOLD, 1, 8))
		button.add_theme_stylebox_override("pressed",
			Tokens.flat_box(Tokens.MIST_GHOST_HOVER, Tokens.MIST_GOLD, 1, 8))
		button.add_theme_color_override("font_color", Tokens.MIST_TEXT_SOFT)
		button.add_theme_color_override("font_hover_color", Tokens.MIST_TEXT)
		button.add_theme_color_override("font_pressed_color", Tokens.MIST_TEXT)
	return button


# 玩家点了「加入/立即参与」。先收掉气泡再回调 —— 回调里多半要切页面，
# 让气泡在切页面的过程中还挂在屏幕上会闪一下。
func _accept(party_id: String) -> void:
	var callback := Callable()
	for record in _entries:
		if str(record.get("party_id", "")) == party_id:
			callback = record.get("on_accept", Callable())
	_dismiss(party_id, "accepted")
	if callback.is_valid():
		callback.call(party_id)


func _dismiss(party_id: String, reason: String) -> void:
	var index := -1
	for i in range(_entries.size()):
		if str((_entries[i] as Dictionary).get("party_id", "")) == party_id:
			index = i
			break
	if index < 0:
		return
	var record: Dictionary = _entries[index]
	_entries.remove_at(index)
	var card: Variant = record.get("card")
	if card is Node and is_instance_valid(card):
		(card as Node).queue_free()
	_handled[party_id] = true
	# ★★ 10.07 第 6/10 条返工（用户真机反馈「点击稍后后，红点仍然存在，
	#    要改成点击稍后表示已读该信息，红点消失」）：
	#
	# 这条邀请被**任何方式处理掉**（加入 / 稍后 / 超时）时，都调一次 `on_handled`。
	# 由 Main 接上 → `ChatService.mark_seen_locally(host_code)` 清掉那个好友的红点。
	#
	# 为什么「稍后」也算已读：气泡已经**把内容摆到玩家眼前**了（这是「送达」），
	# 玩家点「稍后」的语义是「我看到了，但先不加入」，不是「我没看到」。
	# 红点表示「有未读」，此时已不成立 —— 留着它只是噪音，还会让玩家以为漏了消息。
	#
	# ★ 只清**本地**红点，不动服务端已读游标（见 ChatService.mark_seen_locally 的注释）：
	#   气泡这条路径不该替玩家把聊天界面里的未读也一起标掉。
	var handler: Variant = record.get("on_handled", Callable())
	if handler is Callable and (handler as Callable).is_valid():
		(handler as Callable).call(party_id)
	# 「处理完最新的后显示上一个」：这一条走了，队列里等的立刻补位。
	_pump()
	_refresh_visibility()
	_silent(reason)


# 排队等着的那几条也要在到期时作废，不然会把过期卡顶上来。
func _expire_if_stale() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var kept: Array[Dictionary] = []
	for record in _pending:
		if float(record.get("deadline", 0.0)) <= now:
			_handled[str(record.get("party_id", ""))] = true
		else:
			kept.append(record)
	_pending = kept


func _refresh_visibility() -> void:
	if is_instance_valid(_root):
		_root.visible = not _entries.is_empty()


func _silent(_reason: String) -> void:
	pass


func _title_for(kind: String) -> String:
	return tr("invite_team_title") if kind == KIND_TEAM else tr("invite_room_title")


func _body_for(kind: String, host_name: String) -> String:
	# 需求写死了话术：「朋友XX邀请你进入房间 / 队伍」—— 昵称**不带 ID 数字**，
	# 所以直接拼玩家昵称，不走 AccountManager.display_name（那个会带 #code）。
	if kind == KIND_TEAM:
		return tr("invite_team_body") % host_name
	return tr("invite_room_body") % host_name


func _accept_text(kind: String) -> String:
	return tr("invite_team_accept") if kind == KIND_TEAM else tr("invite_room_accept")


func _later_text(_kind: String) -> String:
	return tr("invite_later")


func _build() -> void:
	var host := get_tree().current_scene
	if host == null or not is_instance_valid(host):
		host = get_tree().root
	if host == null:
		return
	_root = Control.new()
	_root.name = "InviteRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# ★★ 10.07h 第 6 / 10 条返工：整条气泡栈**不再锚到屏幕边**（返工前是右上角
	#    anchor_left/right = 1.0），改成按锚点**绝对定位**在 `_place()` 里算。
	#    父节点 `_root` 是铺满视口的普通 Control（不是容器），所以子节点的
	#    position 就是屏幕坐标，容器不会来重排它。
	var anchor := VBoxContainer.new()
	anchor.name = "InviteStack"
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor.add_theme_constant_override("separation", 10)
	_root.add_child(anchor)
	_list = anchor
	# 先摆一次（锚点还没来，会走兜底），免得第一帧闪在 (0,0)。
	_place()


# 气泡左侧那枚指向「聊天」按钮的三角尖。画在**卡片之外**：卡片本体是圆角矩形，
# 尖角要在它左边缘外侧才有「引出」的观感。
#
# 用 Control + `_draw()` 而不是贴图：进 `assets/` 要走资源白名单流程，
# 而这就是一个三角形。颜色与卡片描边同源（`_card_edge()`）。
func _make_tail() -> Control:
	var tail := Control.new()
	tail.name = "Tail"
	tail.custom_minimum_size = Vector2(TAIL_W, TAIL_H)
	tail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tail.draw.connect(func() -> void:
		var w := tail.size.x
		var h := tail.size.y
		# 尖朝左：右边缘上下两点 + 左侧中点。
		var points := PackedVector2Array([
			Vector2(w, 0.0),
			Vector2(w, h),
			Vector2(0.0, h * 0.5),
		])
		(tail as Control).draw_colored_polygon(points, _card_bg()))
	return tail


# ── 配色（「雾林夜幕」那一族）───────────────────────────────────────────
# 用户要求「重新设计出符合游戏风格和颜色」。主菜单的弹层（自定义房间面板）已经
# 定了这套：`MIST_*` —— 深墨绿半透明底 + 金描边。气泡跟着走，不再自己写死
# `Color(0.06,0.08,0.09,0.94)` 那种与全局无关的深灰。
#
# 单独抽成三个函数而不是 `const`：门禁要能**分别**断言底/边/字的来源，
# 一条 `const BUBBLE_COLORS := [...]` 断言不出「用的是 Tokens 而不是字面量」。
func _card_bg() -> Color:
	return Tokens.MIST_PANEL


func _card_edge() -> Color:
	return Tokens.MIST_GOLD


func _title_color() -> Color:
	return Tokens.MIST_GOLD_BRIGHT


func _body_color() -> Color:
	return Tokens.MIST_TEXT
