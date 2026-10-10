extends Control

signal start_requested
signal back_requested
signal selftest_requested

const REF_SIZE := Vector2(1672.0, 941.0)
# 在线状态推送的事件名。必须和 backend/app/presence.py 的 PRESENCE_EVENT 一致。
const PRESENCE_PUSH := "presence"
const SLOT_LABELS := ["A", "B", "C", "1", "2", "3"]
const SLOT_POS := [
	Vector2(447, 229), Vector2(739, 229), Vector2(1015, 229),
	Vector2(447, 502), Vector2(739, 502), Vector2(1015, 502),
]
const SLOT_SIZE := Vector2(184, 175)
# 10.01 反馈（第 4 条）：座位框换成玩家在大厅佩戴的头像框。
#
# 同一席位里的层次（后加的子节点在上面）：
#   slot.png 木环底板 → 圆形头像 → **玩家的头像框** → 铭牌复本 → 圈外名牌 / X / ±AI
# 头像框只要插在铭牌之前，就天然盖住木环；圈外名牌那几样本来就是后加的。
#
# 为什么要「铭牌复本」：反馈原文是「框框下面的字符『房主』『准备』『未准备』及
# 周围的边框做保留，覆盖在头像框的上层」。那块六边形铭牌是画在 slot.png 里的，
# 位于头像框**下面**，会被框整个盖住 —— 所以这里再从 slot.png 里把铭牌那一块
# 单独抠出来（AtlasTexture 取 region），在头像框之后再画一遍抬到最上层。
#
# 尺寸来历（10.02 三轮改口径，与大厅资料卡同一套）：
# 头像**永远是 106**（= 没戴框时的尺寸），不再跟着框缩。框按「内孔直径 == 默认圆盘
# 的内孔」反推绘制尺寸（`AvatarCatalog.frame_drawn_size`）—— 旧口径是「头像缩到 78
# 去迁就框」，玩家看到的就是「戴上框头像变小」，那正是这一轮要消灭的。
const SLOT_AVATAR_POS := Vector2(39, 40)
const SLOT_AVATAR_SIZE := Vector2(106, 106)
# 默认圆盘（金棕圆盘）的盒：160x160，素材 850x825，KEEP_ASPECT 居中。
const SLOT_FRAME_POS := Vector2(12, 13)
const SLOT_FRAME_SIZE := Vector2(160, 160)
# 圆盘盒的中心 —— 头像中心、圆盘内孔中心、自定义框的**内孔圆心**，三者都是它。
const SLOT_DISC_CENTER := SLOT_FRAME_POS + SLOT_FRAME_SIZE * 0.5
# 铭牌在 slot.png（400x376）里的像素矩形，以及它换算到席位局部坐标的落点
# （×184/400、×175/376）。比「房主」那行字的框（39,137,106x32）略窄，因为
# 铭牌是六边形、四角本来就收进去。
const SLOT_PLATE_REGION := Rect2(105, 291, 185, 74)
const SLOT_PLATE_POS := Vector2(48, 135)
const SLOT_PLATE_SIZE := Vector2(86, 35)
const AvatarCatalog := preload("res://scripts/account/AvatarCatalog.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
# 9.17 第二批：BGM 走常驻 MusicService，音效走 SfxService。
const MusicService := preload("res://ui/services/MusicService.gd")
const SfxService := preload("res://ui/services/SfxService.gd")
# 右上角「设定」打开的就是主界面那一页（10.11 第 2 条：原来是静音键），见 _open_settings。
const SettingsScreenScript := preload("res://scenes/menu/SettingsScreen.gd")
const SETTINGS_SCENE := preload("res://scenes/menu/SettingsScreen.tscn")
# 房间邀请（bug提交和修复.docx 第 2 条）：文案 / 限流 / 失效判据都在这一份纯逻辑里。
const RoomInvite := preload("res://scripts/multiplayer/RoomInvite.gd")
# 「邀请已过时」「已经邀请过了」走全局 toast —— 与教程的「上阵棋子数目少于 N」同一个出口，
# 所以「中上方 + 同一种格式」是天然的（要求 5）。
const GloryToastScript := preload("res://ui/components/GloryToast.gd")
const TouchScrollContainer := preload("res://ui/components/TouchScrollContainer.gd")
var _slot_avatars: Array[TextureRect] = []
var _friends_box: VBoxContainer
var _friends_loading := false
# 邀请限流状态（要求 4）。只活在本场房间的内存里（界面每次进房重建，初始值自然从零开始）。
# 服务端还会再判一次（权威），这里只是本地先拦一道：反馈即时、省一次往返。
#
# 🔴 10.11 第 6 条 c：「该类消息，同一房间只能发送一次，**发送 CD 5 秒**」——
# 冷却**不再区分换不换房**（旧口径是「换房间才计时 10 秒」，2026-09-28 反馈第 5 条），
# 所以只需要一个时刻，不需要再记「上次是哪个房间」。
var _invite_last_sec := 0
# (房间号:好友码) -> true。同一房间对同一位好友只发一次邀请消息。
var _invited_pairs: Dictionary = {}

# 好友上线 / 换房间的推送。只当**失效信号**用，不拿 payload 里的字段打补丁 ——
# 三个界面各写一份增量合并就有三份和拉回来的数据分叉的机会，而分叉的症状是
# 「列表闪一下又变回去」。并发由 _reload_online_friends 自己的 _friends_loading 挡。
func _on_presence_push(payload: Dictionary) -> void:
	if str(payload.get("t", "")) == PRESENCE_PUSH:
		_reload_online_friends()


func _reload_online_friends() -> void:
	if _friends_loading or not AccountManager.is_logged_in():
		return
	_friends_loading = true
	var result: Dictionary = await AccountManager.fetch_friends()
	_friends_loading = false
	if not is_inside_tree() or _friends_box == null:
		return
	if int(result.get("code", 0)) >= 200 and int(result.get("code", 0)) < 300:
		_render_online_friends((result.get("body", {}) as Dictionary).get("friends", []))

func _render_online_friends(friends: Array) -> void:
	for child in _friends_box.get_children():
		_friends_box.remove_child(child)
		child.queue_free()
	for entry in friends:
		if not _can_invite_online_friend(entry):
			continue
		_friends_box.add_child(_online_friend_row(entry as Dictionary))


# 10.11 第 9 条的唯一判据：**只收「在线且不在对局中」的好友**。
# 不显示的三类：① 不在线；② 在线但在对局里（in_match）；③ 离开了、但对局还没结束
# —— ③ 在后端同样被标成 in_match（客户端 NetworkService.is_in_match 在还留着
# 「这一局已开打」的重连凭证时也算在对局中），所以这里一条判据就够。
#
# ★ 10.11 第 6 条 i 追加第四类：**已经在本房间里**的好友。对他在点邀请没有意义
#   （邀请消息指向的就是他已经在的那个房），用户口径是「点击邀请既不发消息也不弹窗」。
#   后端帮不上忙 —— 自定义房间的成员在战斗服务器上，账号服务器不知道，只能客户端判。
#
# 抽成独立函数（无其他依赖）是为了让门禁能**直接调它**验合同，
# 而不是去 grep _render_online_friends 里那一行 if。
func _can_invite_online_friend(entry: Variant) -> bool:
	if not entry is Dictionary:
		return false
	var friend: Dictionary = entry
	if not bool(friend.get("online", false)):
		return false
	if bool(friend.get("in_match", false)):
		return false
	# 本机不在任何房间（room_id <= 0）时这一条自动放过 —— 「同房间」无从谈起。
	var mine := int(NetworkService.team_room_id)
	if mine > 0 and _friend_room_id(friend) == mine:
		return false
	return true


# 好友此刻所在的房间号；字段缺失 / 不是数字（后端为「不可见」给的是 null）时返回 0。
#
# 单独抽出来是因为**判空必须小心**：`Dictionary.get(key, default)` 只在**键不存在**时
# 才给 default，键存在但值是 `null`（后端 room_id 为 null 就是这个形状）时它照样返回
# null，`int(null)` 会直接抛错。所以要判类型，不能拿 default 兜。
func _friend_room_id(entry: Dictionary) -> int:
	var raw: Variant = entry.get("room_id")
	if raw is int or raw is float:
		return int(raw)
	return 0


# 一行在线好友（要求 2）：显示在线好友的昵称（10.06 起不再显示 #好友码），**点一下即邀请**。
#
# ⚠️ 行用 Label + gui_input，**刻意不用 Button.new()**：
# 门禁 procedural_ui_ratchet_check 对 Team3v3Lobby.gd 的 Button.new() 基线是
# **恰好 3**，棘轮只许降不许涨，多一个就 count_increased 红。所以这里改走
# 手工点击区（同 _add_hit 的思路；但 _add_hit 走 _placed 布局、由 _layout 定位，
# 而这一行挂在滚动容器里，由容器排版，不能混用）。
func _online_friend_row(entry: Dictionary) -> Label:
	var code := str(entry.get("friend_code", ""))
	var label := Label.new()
	# 10.06 反馈第 2 条：朋友列表**只显示昵称**，不再挂着 `#好友码`。
	# code 仍然要留着 —— 邀请是按它发消息的（_on_invite_friend），只是不给玩家看见。
	label.text = AccountManager.display_name(str(entry.get("player_name", "")), code, false)
	# 9.14 反馈：「朋友列表」里的朋友 ID 要贴在框框里边、向左对齐。label 默认就是
	# 左对齐，真正的毛病是列表容器压到了木框上（见 _build() 里 friends_scroll 的
	# 位置说明）—— 两处一起改才看得出来。这里显式写上左对齐，免得将来换主题
	# 把 Label 的默认对齐改掉时又悄悄居中。
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 好友名写在羊皮纸里：深色正文已经有足够对比，不再加浅色粗描边。
	# 旧版白字 + 2px 深边在 14px 下笔画几乎一样粗，看起来像失焦。
	label.add_theme_color_override("font_color", Tokens.PARCHMENT_EDGE)
	label.add_theme_constant_override("outline_size", 0)
	label.add_theme_font_size_override("font_size", 15)
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.tooltip_text = _room_text("点击邀请 %s 进入房间" % label.text,
		"Tap to invite %s" % label.text)
	# 可点：只有 STOP 才收得到 gui_input（IGNORE/PASS 都会漏给下面的滚动容器）。
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# 好友此刻的房间号要**在这一帧取好**再进闭包：闭包只捕获值，
	# 等真点到时 entry 可能已经被下一轮列表刷新换掉了（10.11 第 6 条 i 要用它判同房）。
	var friend_room := _friend_room_id(entry)
	label.gui_input.connect(func(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_on_invite_friend(code, label, friend_room))
	return label


# 点好友名 → 发一条房间邀请（要求 2/4）。这一下**只发消息**，不改自己的房间状态；
# 对方收不收得到、点不点「立即参与」都是对方的事。
#
# `friend_room` = 这一行渲染时好友所在的房间号（0 = 不知道 / 不在房间）。用它判第 6 条 i。
func _on_invite_friend(code: String, row: Control, friend_room: int = 0) -> void:
	if not _online():
		GloryToastScript.show_text(_room_text("联机对局中才能邀请", "Invite is available in online rooms"))
		return
	var room_id := NetworkService.team_room_id
	if room_id <= 0:
		return
	# ★ 10.11 第 6 条 i：好友**已经在本房间**时，这一下既不发邀请消息、也不弹气泡。
	#   列表那一步（_can_invite_online_friend）已经拦掉了他，这里是第二道闸 ——
	#   行是上一帧建的、好友这一帧刚进房时列表还没刷新，点下去仍会走到这里。
	if friend_room > 0 and friend_room == room_id:
		return
	var now := int(Time.get_unix_time_from_system())
	var key := "%d:%s" % [room_id, code]
	# 先亮一下，**再**判能不能发 —— 顺序是有意的（要求 1）。
	# 放在判限流之后的话，「同一房间已经邀请过」时玩家点了什么都不发生，
	# 看起来跟没点到一模一样（这就是实测「点击没有亮一下」的原因）。
	# 而且这一下不能等网络：弱网下那要好几秒，玩家会以为没点到而连点。
	_flash_row(row)
	var blocked := RoomInvite.send_blocked_reason(now, _invite_last_sec, _invited_pairs.has(key))
	if blocked == "duplicate":
		# 同一房间已经邀请过这位好友：**静默返回**。
		# 不再弹「已经邀请过了」—— 亮一下已经说明「点到了」，再弹一句只会打扰；
		# 而对方那边多出来的重复，由服务端去重 + 显示层收敛一起兜掉。
		return
	if blocked == "rate_limited":
		# 5 秒发送冷却（第 6 条 c）：这条要说，否则玩家不知道为什么要等。
		GloryToastScript.show_text(RoomInvite.send_blocked_text("rate_limited"))
		return
	var result: Dictionary = await AccountManager.send_chat_message(
		code, RoomInvite.local_text(), ChatService.new_client_msg_id(),
		RoomInvite.KIND, RoomInvite.make_payload(room_id))
	if not is_inside_tree():
		return
	var status := int(result.get("code", 0))
	if status / 100 == 2:
		# 成功才记账：失败（网络）时不留痕，玩家可以立刻重试。
		_invited_pairs[key] = true
		_invite_last_sec = now
	elif status == 409:
		# 服务端去重兜底（invite_duplicate → 409）：与本地「已经邀请过」同义，也静默。
		pass
	else:
		GloryToastScript.show_text(str(result.get("error",
			_room_text("邀请发送失败", "Failed to send invite"))))


# 「亮一下」（要求 1）。用 modulate 把整行烧到接近过曝再落回常态 ——
# 不换字体颜色：字体色是主题定的，这里只是瞬时高亮，不该留下状态。
#
# 0.28 秒 / 1.6 倍太弱（深色羊皮纸字乘 1.6 仍然偏暗、时间又短），实测肉眼看不出来；
# 改成 2.6 倍 + 0.45 秒缓出回落，一眼能看到「点到了」。
func _flash_row(row: Control) -> void:
	if row == null or not is_instance_valid(row):
		return
	row.modulate = Color(2.6, 2.4, 1.6, 1.0)
	var tween := create_tween()
	tween.set_ease(Tween.EASE_OUT)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(row, "modulate", Color(1, 1, 1, 1), 0.45)


# 「未准备」提醒：右下角按钮缓慢脉动（10.04 bug 文档第 2 条 · 房间手法③）。
#
# ★ 脉动的是**木牌底图 + 文字**，不是 `_start_btn` —— 后者是 hit 层，
#   `modulate.a = 0`，脉动它肉眼看不到任何东西。
# ★ 两块走在**同一条** tween 上：kill 时一起复位，不会留半亮的按钮。
# ★ `Tokens.motion()` 在系统「减弱动态效果」下返回 0 ⇒ 自动退化成「不脉动」；
#   此处的信息本来就靠文字（准备 ✓ / 未准备）承载，脉动只是提醒强度，丢了不丢信息。
#
# ★★ 10.07 第 1 条返工：这块木牌一个按钮两种身份，明暗口径必须分开。
#
#   `as_host = true`（按钮写着「开始游戏」）—— 10.07 新语义：
#       可以开始（_start_block_reason(true) 为空） → 明暗交替脉动
#       不能开始（还有原因）                       → **常暗**（不再脉动）
#     判据是「整局能不能开始」：旧口径下房主没准备时会一直脉动，即使房里还有别人
#     没准备（其实点不了），玩家看不出「现在到底能不能开」。
#
#   `as_host = false`（按钮写着「准备」）—— **完全回到修复前（10.04）**：
#       只按「本人准没准备」决定脉不脉动；不脉动时**一律复亮**，绝不压暗。
#     这里不能沿用上面那套「不可开始就常暗」：队员那个「准备」压暗看起来像被禁用，
#     而它其实随时可点（点一下就是「我准备好了」）—— 用户明确要求恢复原样。
#
#   `_bright` 与 `_dim` 也按身份取：修复前的脉动下界是 0.70 灰，不是 START_PLATE_DIM
#   （0.52）—— 只回退调用点、不回退灰阶的话，「准备」的脉动会比修复前更暗。
func _update_start_pulse(active: bool, as_host: bool = true) -> void:
	if _start_plate == null or _start_lbl == null:
		return
	var bright := Color(1.34, 1.24, 1.04, 1.0)
	# 房主新口径用统一的常暗色；队员用修复前的浅灰下界。
	var dim := START_PLATE_DIM if as_host else READY_PLATE_DIM_LEGACY
	# ★★ 10.07c 返工（用户真机反馈「点击准备后还在脉动」）：
	#   本函数每次 `_refresh()` 都调，而 `_refresh()` 是**高频**的（每次房间快照/轮询）。
	#   旧写法在「应该脉动」这条路上**无条件 `create_tween()`**，只把新 tween 赋给
	#   `_start_pulse_tween` —— **旧 tween 从没被 kill**。于是：
	#     第 1 次刷新 → 建 tween#1；第 2 次 → 建 tween#2 覆盖引用，tween#1 还在跑 …
	#   堆了 N 个 loop tween 同时在写 modulate。等玩家按下「准备」（active=false）时，
	#   `_stop_start_pulse()` 只 kill 到**当前引用那一个**，前面泄漏的全都还在写
	#   ⇒ **「准备√」了木牌照样明暗脉动**，而且越刷越乱。
	#   （房主侧因为 `as_host` 有早退才没暴露；队员侧我上一轮为「严格还原修复前」
	#    把早退去掉了，反而踩出这个泄漏 —— 修复前调用点少，掩盖了这个 bug。）
	#
	#   改法：把「现在该不该脉动」与「有没有在脉动」分开判：
	#     * 该脉动 && 已经在脉动 ⇒ 沿用，不动 tween（避免刷新把脉动重置回起点）；
	#     * 否则 ⇒ **先无条件清干净**（kill 旧 tween、复位标记），再按 active 决定要不要新建。
	#   这样「是否脉动」由 active 唯一决定，且**任何时刻最多只有一个 tween**。
	var want_pulse := active and Tokens.motion(1.0) > 0.0
	if want_pulse and _pulsing:
		return
	# 走到这里：要么不想脉动（要收掉），要么想脉动但还没跑（要新建）。
	# 两种情况都先把可能存在的旧 tween 清干净 —— 这一步就是堵住泄漏的那一刀。
	_clear_pulse_tween()
	if want_pulse:
		if as_host:
			# 房主侧先复位到亮态再起脉动（保证从「常暗」切到「脉动」时不卡在暗档）。
			_set_start_plate(Color(1.0, 1.0, 1.0, 1.0))
		var t := create_tween().set_loops()
		t.set_trans(Tween.TRANS_SINE)
		t.set_ease(Tween.EASE_IN_OUT)
		t.tween_property(_start_plate, "modulate", bright, 0.9)
		t.parallel().tween_property(_start_lbl, "modulate", bright, 0.9)
		t.tween_property(_start_plate, "modulate", dim, 0.9)
		t.parallel().tween_property(_start_lbl, "modulate", dim, 0.9)
		_start_pulse_tween = t
		_pulsing = true
	else:
		# 不脉动 ⇒ 一律复亮（房主「不可开始」再压常暗）。
		# 「准备」按下的那一刻就走这里 ⇒ 木牌立刻停、立刻回亮，不再脉动。
		_set_start_plate(Color(1, 1, 1, 1))
		if as_host and not active:
			# 不可开始 ⇒ 压暗常显。即使系统「减弱动态效果」关了脉动，
			# 这一步也照走 —— 暗态本身就是信息（能开/不能开）。
			_set_start_plate(START_PLATE_DIM)


# 木牌底图 + 文字一起上色调。
func _set_start_plate(color: Color) -> void:
	for node in [_start_plate, _start_lbl]:
		if node != null:
			node.modulate = color


# 杀掉当前的脉动 tween 并把「在跑」标记清掉（不碰 modulate，调用方决定下一步色调）。
func _clear_pulse_tween() -> void:
	if _start_pulse_tween != null and _start_pulse_tween.is_valid():
		_start_pulse_tween.kill()
	_start_pulse_tween = null
	_pulsing = false


func _stop_start_pulse() -> void:
	_clear_pulse_tween()
	_set_start_plate(Color(1, 1, 1, 1))

func _seat_profile(index: int) -> Dictionary:
	if index == _my_slot():
		return AccountManager.profile
	return NetworkService.team_seat_profiles.get(index, NetworkService.team_seat_profiles.get(str(index), {}))

# 自己的资料变了（改名、换头像）就重画。本机座位显示的是 AccountManager.profile，
# 所以这里只需要刷新；别人看到的是入座时名片上的身份（NetworkService._room_store_seat_card）。
func _on_profile_changed(_profile: Dictionary = {}) -> void:
	_refresh()

func _view_seat_profile(index: int) -> void:
	if index == _my_slot() or index < 0 or index >= _states().size() or str(_states()[index]) != "player":
		return
	var identity := _seat_profile(index)
	var code := str(identity.get("friend_code", ""))
	if code.length() != 8:
		DialogService.info({"owner": self, "body": _room_text("玩家资料正在加载，请稍后重试", "Player profile is loading. Please retry shortly.")})
		return
	var screen := load("res://scenes/menu/ProfileScreen.tscn").instantiate() as Control
	screen.configure_public(code)
	var modal_id := "lobby_player_profile"
	screen.back_requested.connect(func(): ModalStack.pop(modal_id))
	ModalStack.push(screen, {"id": modal_id, "owner": self, "priority": 50, "dismiss_on_backdrop": false})
const TEX_BACKGROUND := preload("res://assets/ui/room_v2/background.png")
const TEX_BACK := preload("res://assets/ui/room_v2/back.png")
const TEX_TITLE := preload("res://assets/ui/room_v2/title.png")
const TEX_SLOT := preload("res://assets/ui/room_v2/slot.png")
# 10.02 bug 文档：玩家的座位头像框展示要与大厅的头像保持一致。
# 大厅资料卡在「没戴自定义框」时画的是这张 —— 金棕圆盘垫底 + 大圆头像；
# 戴了自定义框才改画框 + 小头像（MainMenu._refresh_profile_plate）。
# 席位据此对齐同一口径，所以这里复用大厅同一张图，而不是自己造一只木环。
#
# 只此一处 preload：全仓原本只有 MainMenu.gd 引用它，这里新增第二个引用点。
# 若以后换掉 profile_avatar.png，MainMenu 的注释里那句「换了那张框图就要重新量」
# 同样适用 —— 席位的圆盘内孔与头像直径也是按那张量出来的。
const TEX_PROFILE_AVATAR := preload("res://assets/ui/main_menu_live/profile_avatar.png")
const TEX_FRIENDS := preload("res://assets/ui/room_v2/friends.png")
const TEX_CHAT := preload("res://assets/ui/room_v2/chat.png")
const TEX_START := preload("res://assets/ui/room_v2/start.png")
const TEX_VS := preload("res://assets/ui/room/vs.png")
const MENU_MUSIC_PATH := "res://assets/audio/bgm/menu_music.mp3"
# 9.17：组队房间此前和主菜单共用 menu_music，这一批给了它独立的 BGM。
# 两条常量分开而不是让房间读主菜单那条 —— 房间是「等队友」的场景，
# 气氛和大厅本就不同，共用一个常量会让以后想分开时改错地方。
const TEAM_ROOM_MUSIC_PATH := "res://assets/audio/bgm/team_room_music.mp3"
const SELFTEST_SCENE_PATH := "res://officetest/OfficeTestScreen.tscn"

# 开始按钮「不可开始」时的常暗色调（10.07 第 1 条）。可在亮态(1,1,1,1)与暗态间对比。
# 明暗交替的灰阶下界也用同一个值，保证「脉动最暗」与「常暗」看起来一样黑。
const START_PLATE_DIM := Color(0.52, 0.54, 0.56, 1.0)
# 「准备」按钮脉动的最暗档 —— **修复前（10.04）的原值**，不随第 1 条改动。
# 10.07 第 1 条返工：队员侧全部回到这个灰阶，别跟着 START_PLATE_DIM 一起变深。
const READY_PLATE_DIM_LEGACY := Color(0.70, 0.72, 0.72, 1.0)

# ── 布局调试overlay ────────────────────────────────────────────────
# 与主界面同款：黑线 = 空间划分（参考画布边界 / 功能分区 / 席位格 / 每个元素占位框）
#               红线 = 所有按钮的点击判定区（返回 / 入座 / X / ±AI / 自测 / 开始）
# 游戏里按 F3 开关。调完把 DEBUG_LAYOUT 改回 false 即可。
const DEBUG_LAYOUT := false
# 参考画布(1672x941)下的功能分区，只用于画黑色分区带；首尾相接，覆盖整块画布
const DEBUG_BANDS := [
	{"name": "顶部标题区", "y": 0.0, "h": 164.0},
	{"name": "状态/资源行 + 我方名牌", "y": 164.0, "h": 60.0},
	{"name": "我方席位 A/B/C", "y": 224.0, "h": 186.0},
	{"name": "VS 分隔带", "y": 410.0, "h": 92.0},
	{"name": "敌方席位 1/2/3", "y": 502.0, "h": 175.0},
	{"name": "底部：敌方名牌 / 聊天 / 开始", "y": 677.0, "h": 264.0},
]

var _slot_states: Array = ["empty", "empty", "empty", "empty", "empty", "empty"]
var _slot_ready: Array = [false, false, false, false, false, false]
var _local_slot := 0

var _placed: Array[Dictionary] = []
var _slot_name_lbls: Array = []
var _slot_status_lbls: Array = []
var _slot_x_btns: Array = []
var _slot_ai_btns: Array = []
# 10.01 反馈（第 4 条）：每个席位多两个节点 —— 玩家的头像框，和抬到框上面的铭牌复本。
var _slot_frames: Array = []
var _slot_plates: Array = []
# 10.02 bug 文档：玩家席位要去掉「头像框后面的座位」（slot.png 那只木环），
# 换成大厅那套金棕圆盘。这两组引用就是为「能单独控制底图/圆盘的显隐 + 落点」补的：
# 木环底图原先 `_add_texture(TEX_SLOT, ...)` 的返回值直接丢掉了，改不动它。
var _slot_bases: Array = []
var _slot_frame_bases: Array = []
var _status_lbl: Label
var _room_id_lbl: Label
var _start_btn: Button
var _start_lbl: Label
# 10.04 bug 文档第 2 条（房间）：未准备时给本人一个「缓脉动」提醒（手法③）。
# 要脉动的是**看得见的两块** —— 木牌底图与文字；`_start_btn` 是 hit 层，
# 建的时候 `modulate.a = 0`（见 `_add_hit`），脉动它等于没脉动。
var _start_plate: TextureRect
var _start_pulse_tween: Tween
# 现在到底有没有一个脉动 tween 在跑。**不能只靠 `_start_pulse_tween.is_valid()` 判**：
# 那只能说明「引用还活着」，而我要的是「我建过、还没停」。10.07c 的 tween 泄漏
# 就是因为只看引用、每次刷新无条件新建 —— 旧 tween 没被 kill 却在跑。
var _pulsing := false
var _host_hint_lbl: Label
var _selftest_btn: Button
var _screen_bands: Array[Dictionary] = []
var _debug_layer: Control
var _debug_on := DEBUG_LAYOUT
var _layout_scale := 1.0
var _layout_origin := Vector2.ZERO

func _ready() -> void:
	AccountManager.profile_changed.connect(_on_profile_changed)
	# 转屏（灵动岛换边）、切回前台时安全区会变，宽高不一定变。
	if not SafeArea.changed.is_connected(_layout):
		SafeArea.changed.connect(_layout)
	_slot_states[_local_slot] = "player"
	if not NetworkService.session_changed.is_connected(_on_session_changed):
		NetworkService.session_changed.connect(_on_session_changed)
	if not NetworkService.team_lobby_changed.is_connected(_on_session_changed):
		NetworkService.team_lobby_changed.connect(_on_session_changed)
	if not NetworkService.team_start_requested.is_connected(_on_team_start_requested):
		NetworkService.team_start_requested.connect(_on_team_start_requested)
	# 好友上线 / 换房间的推送（backend/app/presence.py）。下面那个 5 秒轮询仍然留着 ——
	# 推送只覆盖上线，**下线没有事件可挂**（见 PartyLobby.FRIENDS_REFRESH_SEC 的说明）。
	if not RealtimeService.message_received.is_connected(_on_presence_push):
		RealtimeService.message_received.connect(_on_presence_push)
	if not NetworkService.room_chat_log.entry_added.is_connected(_on_chat_logged):
		NetworkService.room_chat_log.entry_added.connect(_on_chat_logged)
	_build()
	_refresh()
	var friends_timer := Timer.new()
	friends_timer.wait_time = 5.0
	friends_timer.autostart = true
	friends_timer.timeout.connect(_reload_online_friends)
	add_child(friends_timer)
	_reload_online_friends()
	# 必须在 _layout() 之前：_add_label 只是把控件登记进 _placed，
	# 真正定位是 _layout() 干的。放在它后面创建的标签会停在默认位置、看不见。
	_setup_asset_loader()
	_layout()
	_start_menu_music()

# --- 开局资源预载 --------------------------------------------------------------
#
# 大厅是整个流程里唯一真正空闲的窗口：玩家在等人进房，画面基本静止。
# 备战期不行 —— 那时玩家在拖棋子、看羁绊，3D 棋盘和 UI 都在跑，往里塞几百 MB
# 会直接卡到操作。战斗开始前更不行，那是玩家已经在等的时刻。
#
# 分两段，因为 shared_seed 到达有先后：
#   A 段（进大厅立刻）：与 seed 无关 —— 外部 VFX 8 类、商店池全部候选
#   B 段（收到 seed 后）：本局怪物 / Boss 名单，预载前 3 轮
#
# 只发请求 + 逐帧收割，不阻塞。玩家随时可以按开始 —— 没加载完的部分由
# PrepScreen 的读条兜底。
const ASSET_LOAD_TICK := 0.25

var _asset_total := 0
var _asset_seed_stage_done := false
var _asset_tick := 0.0
var _asset_lbl: Label

func _setup_asset_loader() -> void:
	var vfx := BattleAssetManifest.seed_independent_paths()
	var shop := BattleAssetManifest.shop_pool_paths()
	BattleAssetService.acquire_many(vfx, BattleAssetService.OWNER_PLAYER)
	BattleAssetService.acquire_many(shop, BattleAssetService.OWNER_PLAYER)
	_asset_total = BattleAssetService.pending_count()
	print("[ASSET] 大厅预载启动：外部VFX %d 个、商店池 %d 个 -> 待加载 %d 个"
		% [vfx.size(), shop.size(), _asset_total])
	# Keep preload progress outside the center status/seat-name band. The previous
	# 626..1046 × 197..221 rectangle crossed the top B/C seat titles on device.
	_asset_lbl = _add_label("", Vector2(1340, 600), Vector2(230, 28), 14,
		Color(0.62, 0.86, 0.98), "right", true)
	set_process(true)

func _process(delta: float) -> void:
	_asset_tick += delta
	if _asset_tick < ASSET_LOAD_TICK:
		return
	_asset_tick = 0.0
	# seed 是服务器在开打时下发的；一旦拿到就把本局名单也排进来。
	if not _asset_seed_stage_done and BattleAssetManifest.has_seed():
		_asset_seed_stage_done = true
		var by_round := BattleAssetManifest.rounds_enemy_paths(
			GameState.round_index, BattleAssetManifest.LOOKAHEAD_ROUNDS)
		for n in by_round:
			BattleAssetService.acquire_many(
				by_round[n], BattleAssetService.owner_future(int(n)))
		_asset_total = maxi(_asset_total, BattleAssetService.pending_count())
	var pending := BattleAssetService.harvest()
	if _asset_lbl == null:
		return
	if pending == 0:
		print("[ASSET] 大厅预载完成：缓存 %d 个场景" % BattleAssetService.cached_count())
		_asset_lbl.text = "资源已就绪"
		set_process(false)
		return
	var done := maxi(0, _asset_total - pending)
	_asset_lbl.text = "资源载入 %d%%" % int(round(100.0 * float(done) / maxf(1.0, float(_asset_total))))

func _start_menu_music() -> void:
	# 9.17 第二批：改走常驻 MusicService（播放器挂 root，不随页面释放）。
	# 「同一首不重启」由服务内部判等负责。
	MusicService.play(TEAM_ROOM_MUSIC_PATH)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()

func _exit_tree() -> void:
	if RealtimeService.message_received.is_connected(_on_presence_push):
		RealtimeService.message_received.disconnect(_on_presence_push)
	if SafeArea.changed.is_connected(_layout):
		SafeArea.changed.disconnect(_layout)
	if NetworkService.session_changed.is_connected(_on_session_changed):
		NetworkService.session_changed.disconnect(_on_session_changed)
	if NetworkService.team_lobby_changed.is_connected(_on_session_changed):
		NetworkService.team_lobby_changed.disconnect(_on_session_changed)
	if NetworkService.team_start_requested.is_connected(_on_team_start_requested):
		NetworkService.team_start_requested.disconnect(_on_team_start_requested)
	if NetworkService.room_chat_log.entry_added.is_connected(_on_chat_logged):
		NetworkService.room_chat_log.entry_added.disconnect(_on_chat_logged)
	if _voice_controls != null:
		_voice_controls.teardown()

func _online() -> bool:
	return NetworkService.team_active

func _states() -> Array:
	if _online() and NetworkService.team_slot_states.size() == 6:
		return NetworkService.team_slot_states
	if _online():
		return ["empty", "empty", "empty", "empty", "empty", "empty"]
	return _slot_states

# 房主席位号。联机局以服务端广播的 team_leader_slot 为准（它会因掉线顺延、
# 也会跟着换位搬走）；单机/本地调试没有服务端广播 —— 离线房间里**只有本机一个
# 玩家**，所以房主就是自己，返回自己的座位号。
#
# ★ 9.29 bug 文档第 4 条：这里原来硬编码 `0`，而离线自测时玩家一开局就在 A 座
# 之外的地方（换过座、或本来就在别的座位）—— 于是「房主」被写给 0 号位，那个
# 位子若是假想敌，文案紧接着又被 dummy 分支的「假想敌」覆盖，玩家自己的座位
# 只能落到 else 分支显示「未准备」。实测（离线、玩家在 C 座、其余假想敌）：
#   s0='假想敌'  s2='未准备'   ← 玩家看到的就是「本应房主、现在未准备」
# 改取 `_my_slot()` 后 s2='房主'。注意**不能用 _local_slot 直读**：_my_slot()
# 才是「在线走服务端、离线走本地」这件事的唯一出口，绕过它会在联机局里读错。
func _leader_slot() -> int:
	return NetworkService.team_leader_slot if _online() else _my_slot()

func _ready_arr() -> Array:
	if _online() and NetworkService.team_ready.size() == 6:
		return NetworkService.team_ready
	if _online():
		return [false, false, false, false, false, false]
	return _slot_ready

func _my_slot() -> int:
	return NetworkService.team_local_slot if _online() else _local_slot

func _on_team_start_requested() -> void:
	start_requested.emit()

func _build() -> void:
	var bg := TextureRect.new()
	bg.texture = TEX_BACKGROUND
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	# 左上返回、左下聊天框：锚定屏幕左边（edge="left"）
	_add_texture(TEX_BACK, Vector2(80, 35), Vector2(143, 83), "left")
	_add_hit(Vector2(80, 35), Vector2(143, 83), func(): back_requested.emit(), "left", "hit_back")
	_add_texture(TEX_TITLE, Vector2(599, 21), Vector2(475, 143))
	# 10.01 反馈（第 3 条）：木牌上的三行字重排。
	#   ① 原来第三行（状态行）的框底是 142 + 28 = 170，而木牌只到 y=164 —— 溢出 6px，
	#      字直接压在下边框上（截图里「在线 ｜ 玩家1 AI0 ｜ …」就贴在木牌边缘）；
	#   ② 房间 ID 用的是写死的暗琥珀 Color(0.45, 0.27, 0.08)，在棕木底上几乎看不清，
	#      反馈要求与「自定义房间」同色。
	# 现在三行都按木牌内区（y 32~153）排，行间距统一，第三行框底 142 < 164。
	# 水平框统一成木牌的 475 宽，三行共用一个居中轴（原来是 372 / 250 / 420 三个宽度，
	# 各自居中，看起来是歪的）。
	_room_id_lbl = _add_label("", Vector2(599, 88), Vector2(475, 26), 18, Tokens.TEXT_PRIMARY)
	_add_label(_room_text("自定义房间", "CUSTOM GAME"), Vector2(599, 40), Vector2(475, 44), 32,
		Tokens.TEXT_PRIMARY, "", true)
	# 右侧朋友列表：锚定屏幕右边（edge="right"）
	_add_texture(TEX_FRIENDS, Vector2(1340, 180), Vector2(230, 400), "right")
	_add_label(_room_text("朋友列表", "Friends"), Vector2(1340, 215), Vector2(230, 42), 28,
		Tokens.GOLD_HOVER, "right", true)
	var friends_scroll := TouchScrollContainer.new()
	friends_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(friends_scroll)
	# 9.14 反馈：名字原来从 1350 起，而羊皮纸的内边在 1373 左右 —— 文字压在木框上，
	# 看着「没在框框里边」。按框内区域（实测约 1373 ~ 1540）重设滚动区，列表项显式
	# 左对齐后正好贴着纸的左边。右边保持 1539 不变，框内的宽度不受影响。
	_track(friends_scroll, Vector2(1374, 270), Vector2(165, 290), 0, "right")
	_friends_box = VBoxContainer.new()
	_friends_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	friends_scroll.add_child(_friends_box)
	_add_texture(TEX_CHAT, Vector2(80, 704), Vector2(430, 210), "left")
	_build_chat_box()
	_add_texture(TEX_VS, Vector2(746, 427), Vector2(180, 85))

	_slot_name_lbls.resize(6)
	_slot_status_lbls.resize(6)
	_slot_x_btns.resize(6)
	_slot_ai_btns.resize(6)
	_slot_avatars.resize(6)
	_slot_frames.resize(6)
	_slot_plates.resize(6)
	_slot_bases.resize(6)
	_slot_frame_bases.resize(6)
	for i in 6:
		_build_slot(i)

	# 右下开始按钮组、自测、提示：锚定屏幕右边（edge="right"）
	_start_plate = _add_texture(TEX_START, Vector2(1300, 760), Vector2(270, 130), "right")
	_start_lbl = _add_label("", Vector2(1300, 790), Vector2(270, 95), 28,
		Color(0.96, 0.87, 0.70), "right", true)
	_start_btn = _add_hit(Vector2(1300, 790), Vector2(270, 95), _on_primary_pressed, "right", "hit_start")
	# 离线自测专用入口(officetest):开始游戏上方,仅离线显示,纯追加不动原布局。
	#
	# V3 P1-07 先加了 debug 守卫；V12-12 再补资源能力判断。普通 Debug APK
	# 同样会按 preset 排除 officetest/，所以只看 is_debug_build() 仍会显示死入口。
	_selftest_btn = _add_ai_button(Vector2(1310, 719), Vector2(255, 55), func(): selftest_requested.emit(), "right", "btn_selftest", 24)
	_selftest_btn.text = _room_text("自测开始", "Self-Test")
	_selftest_btn.visible = selftest_available() and not _online()
	_host_hint_lbl = _add_label(_room_text("等待其他玩家准备后可按", "Waiting for players"),
		Vector2(1285, 880), Vector2(310, 28), 20, Tokens.TEXT_PRIMARY, "right", true)
	# 状态行：字号 17 → 15、上移到 y=118（框底 142，木牌底 164，留 22px 余量）。
	# 旧值 (626, 142, 420x28) 的框底 170 已经落到木牌外面了。
	_status_lbl = _add_label("", Vector2(599, 118), Vector2(475, 24), 15,
		Tokens.TEXT_PRIMARY, "", true)
	# 10.11 第 2 条：右上角那颗键从「静音 / 已静音」改成「设定」，打开设置页
	# （内容 = 对局里的设定少个「退出对局」）。音乐开关在设置页里，静音没丢。
	_build_settings_button()
	_build_debug_layer()

func _build_slot(index: int) -> void:
	var pos: Vector2 = SLOT_POS[index]
	# 木环底图。玩家席位会把它整块隐藏（10.02 bug 文档），所以这一行必须留住引用 ——
	# 原先返回值被直接丢掉，想隐藏也没有把手。
	_slot_bases[index] = _add_texture(TEX_SLOT, pos, SLOT_SIZE)
	# 大厅那套「金棕圆盘」：只在玩家席位、且**没戴自定义框**时显示。
	# 插在木环之后、头像之前 —— 垫在头像下面，头像的圆形 shader 会把它的内孔盖住，
	# 露出来的正是外圈那道金环（与大厅资料卡同款）。
	#
	# 同样**不能拉满矩形**：这张图是 850x825（W/H=1.030）也不是方的。大厅那边
	# `MainMenu._profile_base_frame` 走 `_add_texture()` 的默认 `STRETCH_KEEP_ASPECT`，
	# 这里取同一个口径（方盒子里两者等价，都居中）。
	var frame_base := _add_texture(TEX_PROFILE_AVATAR, pos + SLOT_FRAME_POS, SLOT_FRAME_SIZE)
	frame_base.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	frame_base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame_base.visible = false
	_slot_frame_bases[index] = frame_base
	var avatar := _add_texture(null, pos + SLOT_AVATAR_POS, SLOT_AVATAR_SIZE)
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = "shader_type canvas_item; void fragment(){vec4 c=COLOR; c.a*=1.0-smoothstep(0.48,0.5,length(UV-vec2(0.5))); COLOR=c;}"
	var material := ShaderMaterial.new()
	material.shader = shader
	avatar.material = material
	_slot_avatars[index] = avatar
	VoiceControls.attach_speaking_mic(avatar)
	# 玩家的头像框。只画**自定义框**：默认框 / 没框时画的是上面那只金棕圆盘
	# （10.02 改口径，与 MainMenu / ProfileScreen 完全一致 —— 那两处也只画自定义框，
	# 默认框走「圆盘 + 大头像」这条路）。
	#
	# **不能套头像那个圆形 shader**：框的外圈是宝石、冰晶、藤蔓，裁成圆就全没了。
	#
	# ★★ 10.02 二轮：**必须保持长宽比**。五张商城框的素材都不是方图
	# （实测 W/H = 0.773 ~ 0.889，都是竖长），而 `_add_texture()` 默认给的是
	# `STRETCH_SCALE`（拉满整个矩形 = 非等比）⇒ 160x160 的框盒会把它们**横向压成椭圆**。
	# 大厅那边是 `MainMenu._profile_frame_art`，取值 `STRETCH_KEEP_ASPECT_CENTERED`，
	# 这里跟着它一致 —— 这是「与大厅保持一致」在几何上的那一半。
	#
# ★★ 10.02 三轮：盒**不是固定 160**了。原来竖长的框按 160 盒贴满只剩 ~124 宽的内孔，
# 头像（106）塞不进去，旧口径就是靠把头像缩到 78 来迁就它的。现在改成
# 按内孔反推尺寸（`_apply_slot_frame` 里按实际戴的框算），**内孔圆心**压在圆盘中心上。
	var frame := _add_texture(null, pos + SLOT_DISC_CENTER - SLOT_FRAME_SIZE * 0.5,
		SLOT_FRAME_SIZE)
	frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.visible = false
	_slot_frames[index] = frame
	# ★★ 10.02 三轮：把框挪到**头像前面**（= 画在头像下面），与默认圆盘的层次一致。
	# `_add_texture` 是 `add_child()`，后加的盖在上面；框盖在头像上时，它那道圆的
	# 内孔会把头像的边缘切掉一圈 —— 内孔是圆的、头像也是圆的，两个圆只要圆心/半径
	# 差几像素就吃掉几像素（三轮渲染实测：大厅 -0.8% ~ -4.1%），于是「戴哪个框」直接
	# 改变了头像的可见大小。放到头像下面之后，**头像的可见像素在任何框下都逐像素
	# 相同**，这才是「和默认框一样大」的结构性保证，而不是靠把内孔调准去碰运气。
	move_child(frame, avatar.get_index())
	# 铭牌复本：玩家席位一律显示（判定见 _apply_slot_frame）。底下 slot.png 里本来就
	# 画着这块六边形木牌，但玩家席位的底图整块被隐藏了，不再补一份「房主 / 准备 /
	# 未准备」就没了底 —— 10.02 反馈明确要求保留这块铭牌。
	# 空位 / 假想敌仍旧吃底图自带的那块，不重复画。
	var plate_atlas := AtlasTexture.new()
	plate_atlas.atlas = TEX_SLOT
	plate_atlas.region = SLOT_PLATE_REGION
	var plate := _add_texture(plate_atlas, pos + SLOT_PLATE_POS, SLOT_PLATE_SIZE)
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.visible = false
	_slot_plates[index] = plate
	_add_hit(pos + Vector2(0, 0), Vector2(182, 125), _on_slot_pressed.bind(index),
		"", "hit_slot_%s" % SLOT_LABELS[index])
	var name_pos := Vector2(pos.x - 10, pos.y - 46) if index < 3 else Vector2(pos.x - 10, pos.y + SLOT_SIZE.y + 4)
	_slot_name_lbls[index] = _add_label("", name_pos, Vector2(SLOT_SIZE.x + 20, 36), 28,
		Tokens.TEXT_PRIMARY, "", true)
	_slot_status_lbls[index] = _add_label("", pos + Vector2(34, 72), Vector2(122, 42), 20, Color(0.42, 0.28, 0.12))
	var x_btn := _add_x_button(pos + Vector2(138, 30), Vector2(38, 38), _on_slot_x.bind(index),
		"btn_kick_%s" % SLOT_LABELS[index])
	_slot_x_btns[index] = x_btn
	var ai_btn := _add_ai_button(pos + Vector2(51, 133), Vector2(80, 40), _on_slot_ai.bind(index),
		"", "btn_ai_%s" % SLOT_LABELS[index])
	_slot_ai_btns[index] = ai_btn

func _on_slot_pressed(index: int) -> void:
	if str(_states()[index]) == "player":
		if index != _my_slot():
			_view_seat_profile(index)
		return
	if str(_states()[index]) != "empty":
		return
	var from := _my_slot()
	if from < 0:
		return
	# 9.17 第二批：**只有自己换座**才响这一声。
	#
	# 位置选在这里而不是 NetworkService.team_request_move() 里：那是「自己的
	# 换座请求」的入口，而这条音要的是**自己换座这个动作**的反馈 ——
	# 别人换座走的是 room_state 广播，根本不经过这个函数，所以天然不响。
	#
	# 放在两处分支**之前**：上面的校验已经保证了「目标是空位、自己有座位」，
	# 也就是说这一步无论在线还是离线都会真的换过去，不会出现「响了一声但没换」。
	SfxService.play(SfxService.CUE_ROOM_SEAT_CHANGE)
	if _online():
		NetworkService.team_request_move(index)
		return
	if str(_slot_states[from]) == "player":
		_slot_states[from] = "empty"
		_slot_ready[from] = false
	_slot_states[index] = "player"
	_local_slot = index
	_refresh()

func _on_slot_ai(index: int) -> void:
	if not _is_host_seat() or index == _my_slot():
		return
	var state := str(_states()[index])
	if state != "empty" and state != "dummy":
		return
	_toggle_dummy(index)

func _on_slot_x(index: int) -> void:
	if not _is_host_seat() or index == _my_slot():
		return
	var state := str(_states()[index])
	if state == "player":
		if _online():
			NetworkService.team_kick_slot(index)
	else:
		_toggle_dummy(index)

func _on_primary_pressed() -> void:
	if _is_host_seat():
		_on_start()
		return
	var my_slot := _my_slot()
	if my_slot < 0:
		return
	var now_ready := bool(_ready_arr()[my_slot])
	if _online():
		NetworkService.team_set_ready(not now_ready)
	else:
		_slot_ready[my_slot] = not now_ready
		_refresh()
	# 9.18：房间内「准备」切换反馈音。
	SfxService.play(SfxService.CUE_ROOM_READY_SWITCH)

func _toggle_dummy(index: int) -> void:
	if _online():
		NetworkService.team_toggle_slot(index)
		return
	var state := str(_slot_states[index])
	if state == "empty":
		_slot_states[index] = "dummy"
		_slot_ready[index] = true
	elif state == "dummy":
		_slot_states[index] = "empty"
		_slot_ready[index] = false
	_refresh()

func _refresh() -> void:
	var states := _states()
	var ready_arr := _ready_arr()
	var my_slot := _my_slot()
	var is_host_seat := _is_host_seat()
	for i in 6:
		var state := str(states[i])
		var name_lbl: Label = _slot_name_lbls[i]
		var status_lbl: Label = _slot_status_lbls[i]
		var x_btn: Button = _slot_x_btns[i]
		var ai_btn: Button = _slot_ai_btns[i]
		name_lbl.text = _slot_name(i, state, false)
		var identity := _seat_profile(i)
		_apply_slot_frame(i, identity, state)
		_slot_avatars[i].modulate = Color(1, 1, 1, 0.35 if state == "settling" else 1.0)
		_slot_avatars[i].visible = state in ["player", "settling"]
		if state in ["player", "settling"]:
			_slot_avatars[i].texture = AvatarCatalog.texture_for(str(identity.get("avatar", AvatarCatalog.default_avatar())))
			if not identity.is_empty():
				# 10.04 bug 文档第 5 条：房间座位只显示昵称（隐藏 #好友码）。
				name_lbl.text = AccountManager.display_name(str(identity.get("player_name", "")), str(identity.get("friend_code", "")), false)
			name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		elif state == "empty":
			# 9.20 bug 文档第 2 条：空位只留**圈内**那一个「空位」提示。
			# 圈外这条大标签（上排「空位 A/B/C」、下排「空位 1/2/3」）清空 ——
			# 圈里的 status_lbl 已经写了「空位」，两处重复且圈外那条压着席位底板。
			name_lbl.text = ""
		else:
			# 假想敌座位保留圈外标签（要写出它在这一侧的身份），只清掉上一轮的
			# 省略号行为：假想敌名字是定长文案，不需要按玩家昵称那样截断。
			name_lbl.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		var is_me := state in ["player", "settling"] and i == my_slot
		if is_me:
			var suffix := _room_text("（我）", " (Me)")
			var base_name := name_lbl.text
			var font := name_lbl.get_theme_font("font")
			# 给身份后缀预留宽度，长昵称不能把“我”挤出省略区域。
			while base_name.length() > 1 and font.get_string_size(base_name + suffix, HORIZONTAL_ALIGNMENT_LEFT, -1, 20).x > SLOT_SIZE.x + 12:
				base_name = base_name.left(base_name.length() - 1)
			if base_name != name_lbl.text:
				base_name = base_name.left(maxi(0, base_name.length() - 1)) + "…"
			name_lbl.text = base_name + suffix
		name_lbl.add_theme_color_override("font_color",
			Tokens.GOLD_HOVER if is_me else Tokens.TEXT_PRIMARY)
		name_lbl.add_theme_color_override("font_outline_color", Tokens.INK_PANEL)
		name_lbl.add_theme_constant_override("outline_size", 2)
		# 座位状态变了（玩家 ↔ 假想敌 ↔ 空位）就要改这两条标签的字号与落点，
		# 而 _placed 只是「期望值」——**改完必须立刻落到节点上**（见
		# _apply_placement 的长注释：只写 _placed 不落节点 = 那个座位停在旧字号
		# 与旧位置上，就是 bug 文档第 4 条的「字体不一致 + 字消失」）。
		for placement in _placed:
			if placement.node == name_lbl:
				placement.font_size = 20 if state in ["player", "settling"] else 28
				_apply_tracked(placement)
			if placement.node == status_lbl:
				placement.pos = SLOT_POS[i] + (Vector2(39, 137) if state in ["player", "settling"] else Vector2(34, 72))
				placement.size = Vector2(106, 32) if state in ["player", "settling"] else Vector2(122, 42)
				placement.font_size = 17 if state in ["player", "settling"] else 20
				_apply_tracked(placement)
		match state:
			"settling":
				status_lbl.text = _room_text("结算中", "Viewing results")
			"player":
				# 使用当前房主席位，兼容换位及房主迁移。
				status_lbl.text = _room_text("房主", "Host") if i == _leader_slot() else (_room_text("准备", "Ready") if bool(ready_arr[i]) else _room_text("未准备", "Not ready"))
			"dummy":
				status_lbl.text = _room_text("假想敌", "AI")
			_:
				status_lbl.text = _room_text("空位", "Empty")
		x_btn.visible = is_host_seat and i != my_slot and state != "empty"
		ai_btn.visible = is_host_seat and i != my_slot and (state == "empty" or state == "dummy")
		ai_btn.text = "- AI" if state == "dummy" else "+ AI"
	if _status_lbl != null:
		_status_lbl.text = _lobby_status_text()
	if _room_id_lbl != null:
		_room_id_lbl.text = _room_text("房间 ID：%d", "Room ID: %d") % NetworkService.team_room_id if _online() and NetworkService.team_room_id > 0 else ""
	if _start_btn != null:
		# 房主按钮不再因有人未准备而禁用——点了会显示具体原因（房主也不免检）
		_start_btn.disabled = false
	var my_seat_ready := my_slot >= 0 and my_slot < ready_arr.size() and bool(ready_arr[my_slot])
	var my_seat_player := my_slot >= 0 and my_slot < states.size() and str(states[my_slot]) == "player"
	if _start_lbl != null:
		if is_host_seat:
			_start_lbl.text = _room_text("开始游戏", "Start Game")
		else:
			_start_lbl.text = tr("lobby_ready_done") if my_seat_ready else tr("lobby_ready")
	# ★★ 10.07 第 1 条返工（用户真机反馈）：
	#   这块木牌**一个按钮两种身份** —— 房主看到「开始游戏」，队员看到「准备」。
	#   第 1 条的诉求原文只是「开始游戏UI」，指的是**房主那侧**（能不能开局一眼可见）；
	#   初版把两种身份一起改了（统一 `_start_block_reason(true).is_empty()`），
	#   于是队员那个「准备」也被压成常暗 —— 看起来像被禁用，是**误伤**。
	#   用户明确要求：把**准备UI 恢复到修复前**。
	#
	#   所以这里按身份分流：
	#     房主（「开始游戏」）→ 10.07 新口径：整局能不能开 ⇒ 能开脉动 / 不能开常暗。
	#     队员（「准备」）    → 回到 10.04 旧口径：**本人未准备才脉动**，其余一律回亮
	#                            （与 `_stop_start_pulse()` 的复位一致，不留暗块）。
	if is_host_seat:
		_update_start_pulse(_start_block_reason(true).is_empty(), true)
	else:
		_update_start_pulse(my_seat_player and not my_seat_ready, false)
	if _host_hint_lbl != null:
		_host_hint_lbl.visible = is_host_seat
		_host_hint_lbl.text = _start_hint_text()
	if _selftest_btn != null:
		_selftest_btn.visible = selftest_available() and not _online()


# 第 4 条：把席位框换成玩家在大厅佩戴的头像框（10.01）。
#
# 落点沿用座位标签那一套：改完 _placed 必须就地 _apply_tracked()。换座
# （_on_slot_pressed）与加/减 AI 之后只调 _refresh()、不调 _layout()，只写 _placed
# 不落节点的话，头像会停在旧位置旧尺寸 —— 就是 bug 文档第 4 条同型的坑。
#
# 判定「有没有框」的写法与 ProfileScreen / MainMenu 完全一致：
# 认不出 id、或者就是默认框，都算「没有自定义框」。
#
# ── 10.02 bug 文档：玩家席位不再保留「头像框后面的座位」 ──────────────────
# 现按**三种**情况分开画，AI / 空位维持原样（完全不动）：
#
#   玩家 + 自定义框  木环隐藏、圆盘不画；框按内孔反推尺寸 + 头像 106
#   玩家 + 默认框/无框 木环隐藏、画金棕圆盘 160x160 + 头像 106（同大厅）
#   空位 / 假想敌    木环显示、圆盘不画（一切照旧）
#
# 三分支里**头像中心都落在 SLOT_DISC_CENTER (92,93)**：圆盘盒的中心、圆盘内孔的中心、
# 自定义框的中心、头像位都是它 —— 所以切换默认框 ↔ 自定义框时头像不动，只换了外圈。
#
# ★ 10.02 三轮：头像**不再**跟着框缩（旧口径是 78）。框按「内孔直径 == 默认圆盘内孔」
#   反推绘制尺寸 —— 见 `_slot_hole_target()` 与 `AvatarCatalog.frame_drawn_size()`。
#   框画在头像**下面**（`_build_slot` 里的 `move_child`），所以头像的可见大小与
#   戴哪个框无关。
#
# 铭牌复本：玩家席位一律显示。铭牌本来就画在 slot.png 里，底图一隐就跟着没了，
# 而反馈明确要求保留「房主」那一块。
func _apply_slot_frame(index: int, identity: Dictionary, state: String) -> void:
	var occupied := state in ["player", "settling"]
	var frame_value := str(identity.get("avatar_frame", ""))
	var frame_id := AvatarCatalog.id_from_value(frame_value)
	var custom := occupied and not frame_id.is_empty() and frame_id != "frame_default"
	if custom:
		var tex: Texture2D = AvatarCatalog.frame_texture_for(frame_value)
		var drawn := AvatarCatalog.frame_drawn_size(frame_id, _slot_hole_target())
		if tex == null or drawn.x <= 0.0:
			# 图缺失（老包、或资源没打进包）时退回「没框」：宁可少一个装饰，
			# 也不能留一个「框是空的、头像还被让开一块」的席位。
			custom = false
		else:
			_slot_frames[index].texture = tex
			# 框的**内孔圆心**压在圆盘中心上（= 头像中心），尺寸由内孔反推 ——
			# 每个框的内孔占比、内孔在图里的位置都不同，所以落点**必须**跟着框走，
			# 不能只在 _build_slot 里定一次，也不能自己写 `中心 - 尺寸/2`
			# （内孔偏心的框会因此在头像外露一圈背景缝，见 FRAME_HOLE_OFFSET）。
			_place_node(_slot_frames[index],
				SLOT_POS[index] + AvatarCatalog.frame_box_origin(
					frame_id, _slot_hole_target(), SLOT_DISC_CENTER),
				drawn)
	_slot_frames[index].visible = custom
	_slot_bases[index].visible = not occupied
	_slot_frame_bases[index].visible = occupied and not custom
	_slot_plates[index].visible = occupied


# 目标内孔直径 = **默认圆盘的内孔直径**（160 盒 × 默认框内孔占比 0.6271 ≈ 100.3）。
#
# ★ 为什么不是「头像画出来的直径（106）」：内孔只要 ≤ 头像就不会露缝，而取「默认圆盘的内孔」
#   有三个好处：① 与玩家已经认可的默认框**逐像素同款**（内孔直径与圆心都对齐，见
#   `AvatarCatalog.frame_box_origin`）；② 比内孔=106 小一圈 ⇒ 框画得也小一圈，不挤到
#   隔壁席位；③ 头像被内孔盖住的那 3px 是默认圆盘本来就有的观感，不是新引入的。
#   这也正是玩家原话的意思：「内孔贴齐默认框，而默认框也是贴齐头像的」。
#
# ★ 内孔**比头像小**才不会露缝：框画在头像下面（`_build_slot` 里的 `move_child`），
#   缝里露出来的是背景。这条由门禁 lock 在三处：
#   frame_hole_check 的 `room_no_gap_*` / seat_frame_check 的
#   `hole_not_larger_than_avatar`。
#
# ★ 这条是渲染 + 像素测量出来的，不是推的：`其他/work/_qa_1002c/`（7 种框 × 房间/大厅
#   × 有头像/无头像/无框三种渲染）。改回「框在上」会在那里立刻看到各框大小不一。
static func _slot_hole_target() -> float:
	return SLOT_FRAME_SIZE.x * AvatarCatalog.default_disc_hole_fraction()


# 改一个**已登记**节点的落点：改 `_placed` 里那条，并立刻落到节点上。
# 只写 `_placed` 不落节点 = 10.01 第 4 条那个坑（期望值对了，节点还停在旧位置）。
func _place_node(node: Control, pos: Vector2, size: Vector2) -> void:
	for placement in _placed:
		if placement.node == node:
			placement.pos = pos
			placement.size = size
			_apply_tracked(placement)
			return


func selftest_available() -> bool:
	# Debug is necessary but not sufficient: normal debug APKs deliberately exclude
	# officetest/. Capability-gating prevents a visible button whose scene cannot load.
	return OS.is_debug_build() and ResourceLoader.exists(SELFTEST_SCENE_PATH, "PackedScene")

# 3v3 大厅状态：取代原先误显示的 1v1 session_label（棋盘/对手准备那套）。
func _start_hint_text() -> String:
	var reason := _start_block_reason(true)
	return reason if not reason.is_empty() else (_room_text("可以开始", "Ready to start") if _is_host_seat() else _room_text("等待房主开始游戏", "Waiting for host to start"))

func _lobby_status_text() -> String:
	var states := _states()
	var players := 0
	var ais := 0
	for i in 6:
		var st := str(states[i])
		if st in ["player", "settling"]:
			players += 1
		elif st == "dummy":
			ais += 1
	var mode := _room_text("在线", "Online") if _online() else _room_text("离线", "Offline")
	var tail := _start_hint_text()
	return _room_text("%s ｜ 玩家%d AI%d ｜ %s", "%s | Players %d AI %d | %s") % [mode, players, ais, tail]

func _slot_name(index: int, state: String, self_slot: bool) -> String:
	if state == "empty":
		return _room_text("空位 %s", "Empty %s") % SLOT_LABELS[index]
	var base := _room_text("玩家 %s", "Player %s") if state in ["player", "settling"] else _room_text("假想敌 %s", "AI %s")
	return (base % SLOT_LABELS[index]) + (_room_text("（你）", " (You)") if self_slot else "")

func _is_host_seat() -> bool:
	if _online():
		return NetworkService.can_control_room()
	return true

# 返回不能开始的原因（空字符串=可以开始）。房主不再免检：所有 player 座位都要 ready。
# host_ready=true 表示"把本地房主座位视为已准备"（房主按开始游戏即自动 ready）。
func _start_block_reason(host_ready: bool) -> String:
	var states := _states()
	var ready_arr: Array = _ready_arr().duplicate()
	var leader := _leader_slot()
	if host_ready and leader >= 0 and leader < ready_arr.size():
		ready_arr[leader] = true
	if _online() and (states.size() < 6 or ready_arr.size() < 6):
		return _room_text("房间状态同步中", "Room state syncing")
	if states.has("settling"):
		return _room_text("等待结算中的玩家返回", "Waiting for players to return from results")
	var side_a := 0
	var side_b := 0
	for i in 6:
		var state := str(states[i])
		if state != "empty":
			if i < 3:
				side_a += 1
			else:
				side_b += 1
	if side_a <= 0 or side_b <= 0:
		return _room_text("敌我双方至少一个占位", "Both sides need at least one occupant")
	for i in 6:
		if str(states[i]) == "player" and not bool(ready_arr[i]):
			return _room_text("有玩家未准备", "Some players are not ready")
	return ""

func _on_start() -> void:
	GameState.team_mode = true
	var my_slot := _my_slot()
	# 房主按开始游戏即自动提交自己的 ready（不再免检）
	if _online():
		if my_slot >= 0:
			NetworkService.team_set_ready(true)
	else:
		if my_slot >= 0 and my_slot < _slot_ready.size():
			_slot_ready[my_slot] = true
	# 有阻止原因就显示到状态栏、不开始
	var reason := _start_block_reason(true)
	if not reason.is_empty():
		# 9.21「开始游戏失败」音效：**只有房主听得见**。
		# 这条分支天然只走房主 —— 非房主按的是「准备」按钮（_refresh 里
		# _start_lbl 走 lobby_ready / lobby_ready_done），根本到不了这里；
		# 联机时又只有 can_control_room() 的座位能控制房间。所以不做额外身份判断，
		# 耦合在「谁能按到开始」这一条真实闸门上，比另写一个 is_host 判定更不容易分叉。
		SfxService.play(SfxService.CUE_START_GAME_FAIL)
		_refresh()
		return
	if _online():
		NetworkService.team_start()
		return
	GameState.team_slot_states = _slot_states.duplicate()
	start_requested.emit()

func _on_session_changed() -> void:
	_refresh()
	_layout()
	# 换座位不用做任何事：身份在入座时随出战名片写进座位，服务端 _room_do_move
	# 会把 seat_profiles 随座位一起搬（SEAT_SLOT_MAPS），换位后各端看到的本来就是对的。

func _layout() -> void:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	# 按钮和字放进安全区（iPhone 横屏的灵动岛 / 圆角 / 手势条让出来，ui/services/SafeArea.gd）；
	# 背景和上下装饰带照样铺满整屏。没有刘海时 safe 就是整个视口，和以前一模一样。
	var safe := SafeArea.rect()
	var scale := minf(safe.size.x / REF_SIZE.x, safe.size.y / REF_SIZE.y)
	var origin := safe.position + (safe.size - REF_SIZE * scale) * 0.5
	_layout_scale = scale
	_layout_origin = origin
	for band in _screen_bands:
		var rect := band.node as Control
		var height := float(band.height) * scale
		rect.position = Vector2(0.0, viewport_size.y - height if bool(band.from_bottom) else float(band.y) * scale)
		rect.size = Vector2(viewport_size.x, height)
	for item in _placed:
		_apply_placement(item, scale, origin, safe)
	# 只更新内嵌历史的字号，不重建列表，窗口变化时保留阅读位置。
	if _record_panel != null and _record_panel.visible:
		for label in _record_list.get_children():
			label.add_theme_font_size_override("font_size", _record_font_size())
	if _debug_layer != null:
		_debug_layer.queue_redraw()

# 给 _refresh() 用：按**上一次** _layout() 记下的比例与原点，把单条记录落到节点上。
# 屏幕尺寸没变时这是精确的；屏幕尺寸变了的话紧接着就有一次 _layout() 兜底
# （notify 的 resized 会重排全量），所以这里不需要自己重算比例。
func _apply_tracked(item: Dictionary) -> void:
	if _layout_scale <= 0.0:
		return
	_apply_placement(item, _layout_scale, _layout_origin, SafeArea.rect())

# 把一条 _placed 记录落到它的活节点上（位置 / 尺寸 / 字号）。
#
# ★ 9.29 bug 文档第 4 条：这一段**必须能单独调**，不能只活在 _layout() 里。
# 原因：_refresh() 会改写 _placed 里的 pos/size/font_size（座位从「玩家」变成
# 「假想敌」时，圈内状态标签要从框下方挪到框里、圈外名牌要换成大字），但
# **写进 _placed 不等于写进节点** —— 真正落到 Label 上的是这里。
# 只调 _refresh() 不调 _layout() 的路径（换座 _on_slot_pressed、加/减 AI
# _toggle_dummy、以及它们经 session_changed 的兄弟路径）就会让那个座位**停在
# 上一轮的字号和位置上**：实测把玩家从 A 座换到 C 座、再把 A 座设成假想敌后，
# A 座圈外名牌仍是「玩家」时的 20 号字（其余假想敌都是 28），圈内「假想敌」
# 还留在框**下方**「玩家」时代的位置 —— 也就是玩家看到的「字体不一致 + 字消失」。
# 所以 _refresh() 改完 _placed 就地调本函数，两条路共用同一份落点逻辑，
# 不会出现「只在某一条路径上对」的半修。
func _apply_placement(item: Dictionary, scale: float, origin: Vector2, safe: Rect2) -> void:
	var node := item.node as Control
	if node == null or not is_instance_valid(node):
		return
	var pos := item.pos as Vector2
	var size := item.size as Vector2
	# edge=left/right 的元素锚定到安全区的左右边（消除宽屏下的左右留白，又不钻进灵动岛）；
	# 其余保持 16:9 画布居中缩放。垂直方向一律跟随居中画布。
	var x: float
	match str(item.get("edge", "")):
		"left":
			x = safe.position.x + pos.x * scale
		"right":
			x = safe.end.x - (REF_SIZE.x - pos.x) * scale
		_:
			x = origin.x + pos.x * scale
	var resolved_pos := Vector2(x, origin.y + pos.y * scale)
	var resolved_size := size * scale
	# 字形落在半像素上时，FreeType 的覆盖率会平均到两列像素，视觉上就像蒙了一层灰。
	# 贴图保留连续缩放；只把承载文字的控件吸附到整数像素，不改变点击区语义。
	if node is Label or (node is Button and int(item.font_size) > 0):
		resolved_pos = resolved_pos.round()
		resolved_size = resolved_size.round()
	node.position = resolved_pos
	# 字号也要跟着缩放，否则窗口一小文字就撑破按钮框、窗口一大文字又显得过小。
	# font_size=0 的（纯判定区 _add_hit）没有文字，跳过。
	if int(item.font_size) > 0 and (node is Label or node is Button):
		node.add_theme_font_size_override("font_size", maxi(13, roundi(item.font_size * scale)))
	node.size = resolved_size

# 素材都是裁好的成品图（一张 PNG = 一个元素），所以整张画、不再做图集裁切。
# STRETCH_SCALE = 拉满给定的框，不保持原始宽高比：框写多大就画多大，
# 不会像 KEEP_ASPECT 那样在框里居中留边。想要不变形就把框调成图的比例。
func _add_texture(texture: Texture2D, pos: Vector2, size: Vector2, edge: String = "") -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = texture
	if texture == TEX_CHAT:
		var chat_material := ShaderMaterial.new()
		chat_material.shader = preload("res://scenes/menu/chat_no_badge.gdshader")
		rect.material = chat_material
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(rect)
	_track(rect, pos, size, 0, edge)
	return rect

func _add_rect(color: Color, pos: Vector2, size: Vector2) -> ColorRect:
	var rect := ColorRect.new()
	rect.color = color
	add_child(rect)
	_track(rect, pos, size)
	return rect

func _add_screen_band(color: Color, y: float, height: float, from_bottom: bool) -> ColorRect:
	var rect := ColorRect.new()
	rect.color = color
	add_child(rect)
	_screen_bands.append({"node": rect, "y": y, "height": height, "from_bottom": from_bottom})
	return rect

func _add_label(
	text: String,
	pos: Vector2,
	size: Vector2,
	font_size: int,
	color := Color(0.47, 0.28, 0.08),
	edge: String = "",
	scene_text: bool = false
) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", color)
	# 羊皮纸上的深字不需要描边；浮在场景或木牌上的浅字才用 2px 深边。
	# 旧版所有文字统一 3px 浅边，缩到 720 高时正文只有 13~15px，描边占比过大而发虚。
	label.add_theme_color_override("font_outline_color", Tokens.INK_PANEL)
	label.add_theme_constant_override("outline_size", 2 if scene_text else 0)
	label.add_theme_font_size_override("font_size", font_size)
	add_child(label)
	_track(label, pos, size, font_size, edge)
	return label

func _add_hit(pos: Vector2, size: Vector2, cb: Callable, edge: String = "", dbg_name: String = "") -> Button:
	var btn := Button.new()
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.modulate = Color(1, 1, 1, 0)
	btn.pressed.connect(cb)
	if not dbg_name.is_empty():
		btn.name = dbg_name
	add_child(btn)
	_track(btn, pos, size, 0, edge)
	return btn

func _add_ai_button(pos: Vector2, size: Vector2, cb: Callable, edge: String = "", dbg_name: String = "", font_size: int = 15) -> Button:
	var btn := Button.new()
	btn.text = "+ AI"
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.add_theme_font_size_override("font_size", font_size)
	btn.add_theme_color_override("font_color", Color(0.43, 0.26, 0.08))
	btn.add_theme_constant_override("outline_size", 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1.0, 0.93, 0.80, 0.82)
	sb.border_color = Color(0.70, 0.42, 0.14)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	for s in ["normal", "hover", "pressed", "focus", "disabled"]:
		btn.add_theme_stylebox_override(s, sb)
	btn.pressed.connect(cb)
	if not dbg_name.is_empty():
		btn.name = dbg_name
	add_child(btn)
	_track(btn, pos, size, font_size, edge)
	return btn

func _add_x_button(pos: Vector2, size: Vector2, cb: Callable, dbg_name: String = "") -> Button:
	var btn := Button.new()
	btn.text = "X"
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.add_theme_font_size_override("font_size", 18)
	btn.add_theme_color_override("font_color", Color(0.82, 0.06, 0.08))
	btn.add_theme_constant_override("outline_size", 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1.0, 0.93, 0.80, 0.88)
	sb.border_color = Color(0.70, 0.42, 0.14)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(18)
	for s in ["normal", "hover", "pressed", "focus", "disabled"]:
		btn.add_theme_stylebox_override(s, sb)
	btn.pressed.connect(cb)
	if not dbg_name.is_empty():
		btn.name = dbg_name
	add_child(btn)
	_track(btn, pos, size, 18)
	return btn

func _track(node: Control, pos: Vector2, size: Vector2, font_size: int = 0, edge: String = "") -> void:
	_placed.append({"node": node, "pos": pos, "size": size, "font_size": font_size, "edge": edge})

# ── 房间快捷短语（docs/聊天系统设计.md 批次 A）────────────────────────────
# 预留位置就是原来那句「目前暂无聊天功能」所在的 TEX_CHAT 框：(80,704) 430×210。
#
# ⚠️ 这块是 edge="left" 左锚列的**宽度基准** —— 见 _draw_debug_layer 里那句
# 「左列最宽的是聊天框(147+432)」。往右扩会推动 edge=left 那条分界线，
# 进而影响所有左锚元素的位置。改宽度前先按 F3 看一眼那条线。
#
# 网络上只走 phrase_id，文本在本地查表。理由见 ChatPhrases.gd 顶部。

const ChatPhrases := preload("res://scripts/multiplayer/ChatPhrases.gd")
# 自由文字（批次 D）：输入条贴在屏幕顶部，理由见 ChatInputBar.gd 顶部（手机键盘）。
const ChatInputBar := preload("res://ui/components/ChatInputBar.gd")

# 短语面板的样式与控件**直接复用备战期那套**（PrepWidgets），不是照着抄一份参数。
# 它是「全静态、不持任何界面状态」的工具箱，且 make_menu_button 的注释写着
# 「仿主界面『离线自测』样式」—— 在大厅用它是回到本源，不是跨界引用。
# 这样两个界面的短语按钮是**同一份样式代码**，不存在改了一边忘了另一边。
const PrepWidgets := preload("res://scenes/prep/PrepWidgets.gd")

const CHAT_LINES := 4                              # 210 高的框放得下的行数上限
const CHAT_LINE_H := 28.0
# 🔴 文字区不能贴聊天框的边（框是 80,704 430×210），要让开贴图自带的边框装饰。
# 实测两轮（tools/chat_ui_capture.tscn 出的图）：714 时第一行上半截被压住，
# 726 仍蹭到，732 才干净；左边同理，96 时首字紧贴边框，收到 104。
# **这件事在代码里完全看不出来，只有出图才看得见** —— 那个截图工具因此值得留着。
# 框内可用区约 732 ~ 890：4 行 ×28 = 112 到 844，底下 848 起是短语入口，正好填满。
const CHAT_FIRST_LINE_Y := 732.0
const CHAT_ENTRY_Y := 848.0
const CHAT_TEXT_X := 104.0
const CHAT_TEXT_W := 392.0                         # 右边界 496，与下面那块判定区一致
# 🔴 消息那 4 行还要再让开贴图左上角自带的**对话气泡图标**（约 x 97~130、y 725~762）。
# 上面的 732 / 104 只让开了边框，气泡图标仍压着第一行开头两个字 ——
# 2026-09-11 把截图放大两倍才看清，原尺寸下它像是边框的一部分。
# 只动消息列，不动下面的入口行（图标够不到 848 那一行）。
# 右边界不变（496），一行少放一两个字；折行按 CHAT_MSG_W 算，不会被截断。
const CHAT_MSG_X := 138.0
const CHAT_MSG_W := 358.0
# 聊天框里的字（消息和下面两个入口）一律用 Tokens.CHAT_INK 黑字：
# 2026-09-27 用户反映原来沿用的浅棕色（占位文字那个色）在羊皮纸上看不清。
# 入口那一行对半分：左「快捷短语」、右「打字」（批次 D）。
const CHAT_ENTRY_SPLIT := 196.0

# 消息从哪来：NetworkService.room_chat_log（整个房间一份，界面重建也不丢）。
const RoomChatLog := preload("res://scripts/multiplayer/RoomChatLog.gd")
# 历史记录内嵌在原聊天框，用户上翻时显示悬浮滚动条。
const RECORD_FONT_SIZE := 19
var _record_panel: PanelContainer = null
var _record_scroll: ScrollContainer = null
var _record_list: VBoxContainer = null
var _record_round := -1             # 列表里最后一条的回合（追加时判断要不要插分隔线）

# 短语面板：从聊天框顶部往上弹。往下、往左都没地方 —— 聊天框已经贴着左下角。
#
# 宽度刻意收到 360（比聊天框的 430 窄）：再宽就会盖到敌方席位 1 的左半边
# （SLOT_POS[3] 的 x 是 447）。面板是临时 UI，盖住一点无所谓，但能不盖就不盖。
const PHRASE_PANEL_POS := Vector2(80, 392)
const PHRASE_PANEL_SIZE := Vector2(360, 304)
const PHRASE_BTN_SIZE := Vector2(162, 40)
const PHRASE_BTN_STEP := Vector2(170, 48)          # 按钮间距 8
const PHRASE_BTN_ORIGIN := Vector2(92, 404)        # 面板内边距 12
const PHRASE_BTN_FONT := 15
const PHRASE_COLUMNS := 2

var _phrase_panel: Panel = null
var _phrase_buttons: Array[Button] = []
var _phrase_btn_label: Label = null
var _type_btn_label: Label = null

func _build_chat_box() -> void:
	# 消息直接在原聊天框内滚动，不再弹出独立记录面板。
	_phrase_btn_label = _add_label(_room_text("＋ 快捷短语", "＋ Quick chat"),
		Vector2(CHAT_TEXT_X, CHAT_ENTRY_Y), Vector2(CHAT_ENTRY_SPLIT, 40), 20, Tokens.CHAT_INK, "left")
	_phrase_btn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_add_hit(Vector2(CHAT_TEXT_X, CHAT_ENTRY_Y), Vector2(CHAT_ENTRY_SPLIT, 40), _toggle_phrase_panel,
		"left", "hit_chat_phrase")
	_type_btn_label = _add_label(_room_text("＋ 打字", "＋ Type"),
		Vector2(CHAT_TEXT_X + CHAT_ENTRY_SPLIT, CHAT_ENTRY_Y),
		Vector2(CHAT_TEXT_W - CHAT_ENTRY_SPLIT, 40), 20, Tokens.CHAT_INK, "left")
	_type_btn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	# 右半边判定区的右边界 496，**刻意把贴图右下角那个黄色箭头也圈进来** ——
	# 那个箭头是聊天框贴图自带的，看着就是「发送」，玩家一定会去点它。
	# 圈不进来的话它点了没反应，而没反应的按钮比没有按钮更让人困惑。
	# 批次 A 时它归「快捷短语」；有了打字之后归「打字」，语义更对得上。
	_add_hit(Vector2(CHAT_TEXT_X + CHAT_ENTRY_SPLIT, CHAT_ENTRY_Y),
		Vector2(CHAT_TEXT_W - CHAT_ENTRY_SPLIT, 40), _open_text_input, "left", "hit_chat_text")
	_build_voice_button()
	_build_phrase_panel()
	_build_record_panel()
	_render_record()

# 语音按钮 + 队友按钮（docs/聊天系统设计.md 第九节）。行为都在 VoiceControls 里（大厅 / 备战期 / 战斗界面共用）。
# 放在聊天框正上方：语音 x 180~330、队友 x 336~426，y 650~696。左边是石柱装饰，
# 右边从 x=447 起是敌方席位 1。短语面板打开时会盖住它们（面板 z=40），面板本来就是临时的。
const VoiceControls := preload("res://ui/components/VoiceControls.gd")
const VOICE_BTN_POS := Vector2(180, 636)
const VOICE_BTN_SIZE := Vector2(78, 60)
const VOICE_AUDIENCE_POS := Vector2(266, 636)
const VOICE_AUDIENCE_SIZE := VOICE_BTN_SIZE
const VOICE_MEMBERS_POS := Vector2(352, 636)
const VOICE_MEMBERS_SIZE := VOICE_BTN_SIZE
# 10.11 第 5 条：VOICE_MEMBERS_POS 目前**没有调用点** —— 自定义房间不再摆放「全房间」那颗键
# （见 _build_voice_button）。尺寸仍传给 VoiceControls.build()，留着是为了收回去时只改一行。
const VOICE_BTN_FONT := 15
var _voice_controls: VoiceControls = null

func _build_voice_button() -> void:
	_voice_controls = VoiceControls.new()
	_voice_controls.build(self, VOICE_BTN_SIZE, VOICE_MEMBERS_SIZE, VOICE_BTN_FONT,
		{"panel_context": "lobby"})
	_place_voice_button(_voice_controls.voice_button, VOICE_BTN_POS, VOICE_BTN_SIZE)
	_place_voice_button(_voice_controls.audience_button, VOICE_AUDIENCE_POS, VOICE_AUDIENCE_SIZE)
	# 10.11 第 5 条：自定义房间**隐藏**「全房间」那颗键（用户原话「隐藏自定义房间『全房间』UI」）。
	#
	# 那颗键就是 VoiceControls.members_button —— 在大厅语境里它是「语音范围」的显示位，
	# `VoiceControls.refresh()` 会因为 `VoiceService.lobby_open_to_room()` 把它写成
	# 「全房间 / Room」（绿字，见 VoiceControls.gd 那两行）。但自定义房间里**没有可选范围**：
	# 开局前本来就全房间互通，按下去只会弹一句「开局前房间所有人都能听到」的说明
	# （VoiceControls._on_audience_pressed 的 lobby 分支）—— 一个点了没有动作的键。
	#
	# 做法＝**不调 `_place_voice_button`**：它压根不进树，也就不会被 _track 定位、不占位。
	# 语音面板没有丢：长按扬声器键（VoiceControls 里那个 700ms 长按）照样打开。
	_voice_controls.members_button.visible = false
	# 座位头像上的「正在说话」小麦克风（10-08）。_process 在资源载入完会关掉，所以单独用计时器。
	var speaking_timer := Timer.new()
	speaking_timer.wait_time = SPEAKING_REFRESH_SEC
	speaking_timer.autostart = true
	speaking_timer.timeout.connect(_refresh_speaking)
	add_child(speaking_timer)


const SPEAKING_REFRESH_SEC := 0.2

func _refresh_speaking() -> void:
	for slot in _slot_avatars.size():
		VoiceControls.show_speaking_mic(_slot_avatars[slot], VoiceService.slot_speaking(slot))

func _place_voice_button(button: Button, pos: Vector2, size: Vector2) -> void:
	# 同短语按钮：清掉 make_menu_button 设的最小尺寸，否则窗口缩小时被顶回原尺寸（见 _build_phrase_panel）。
	button.custom_minimum_size = Vector2.ZERO
	add_child(button)
	_track(button, pos, size, VOICE_BTN_FONT, "left")


# ── 房间里的「设定」按键（10.11 第 2 条）────────────────────────────────────
# 这颗键**原来**是「静音 / 已静音」（10.06 反馈第 8 条），10.11 改成「设定」。
#
# 用户口径：「自定义房间和排位房间的静音UI改为设定UI，内容上要比对局里的设定少个
# 『退出对局』按钮」。所以位置 / 尺寸 / 字体全部照旧（右上角、140×62），只换文案与动作；
# 打开的是主界面那一页（同 PrepUI._open_settings），用 `lobby_mode` 关掉
# 「重新体验教学」与「退出对局」两行（房间还没开打，退出对局无从谈起）。
#
# 静音没丢：设置页里的「背景音乐」是同一个开关，而且比原来那颗键多控了音效与画质。
const MENU_BTN_POS := Vector2(1500, 26)
const MENU_BTN_SIZE := Vector2(140, 62)
const MENU_BTN_FONT := 18
const LOBBY_SETTINGS_MODAL_ID := "lobby_settings"
var _settings_button: Button = null

func _build_settings_button() -> void:
	var settings_btn := PrepWidgets.make_menu_button(_room_text("设定", "Settings"),
		MENU_BTN_SIZE, MENU_BTN_FONT, _open_settings)
	_settings_button = settings_btn
	settings_btn.name = "SettingsButton"
	# 同语音键：清掉 make_menu_button 设的最小尺寸，否则窗口缩小时被顶回原尺寸。
	settings_btn.custom_minimum_size = Vector2.ZERO
	add_child(settings_btn)
	_track(settings_btn, MENU_BTN_POS, MENU_BTN_SIZE, MENU_BTN_FONT, "right")


# 房间里的设置页。`lobby_mode` 让页脚只剩「返回」—— 既没有「重新体验教学」，
# 也没有「退出对局」（10.11 第 2 条）。
func _open_settings() -> void:
	if ModalStack.has(LOBBY_SETTINGS_MODAL_ID):
		return
	var settings := SETTINGS_SCENE.instantiate() as SettingsScreenScript
	settings.lobby_mode = true
	settings.can_leave_match = false
	settings.back_requested.connect(func() -> void: ModalStack.pop(LOBBY_SETTINGS_MODAL_ID))
	ModalStack.push(settings, {
		"id": LOBBY_SETTINGS_MODAL_ID,
		"owner": self,
		"priority": 50,
		"dismiss_on_backdrop": false,
	})

func _build_phrase_panel() -> void:
	# 面板与按钮**都在 _build 期建好、默认隐藏**，不是点开时才创建。
	# 这是被 _layout() 逼出来的：它只给 _placed 里登记过的控件定位与缩放，
	# 而登记发生在创建时。点开时才 new 的控件不在 _placed 里，
	# 会停在默认位置（左上角、原始尺寸）—— 那正是 _ready() 里那句
	# 「放在 _layout() 后面创建的标签会停在默认位置、看不见」说的坑。
	_phrase_panel = Panel.new()
	_phrase_panel.name = "PhrasePanel"
	# 与备战期那块面板同一套参数（PrepUI._build_chat_panel）。
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.075, 0.095, 0.055, 0.96)
	style.border_color = Color(0.78, 0.57, 0.20, 0.92)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	_phrase_panel.add_theme_stylebox_override("panel", style)
	# 面板与按钮都要盖在后面才创建的席位/开始按钮之上，所以显式给 z_index，
	# 不依赖 add_child 的先后顺序（_build_chat_box 在 _build 中段就被调了）。
	_phrase_panel.z_index = 40
	_phrase_panel.visible = false
	add_child(_phrase_panel)
	_track(_phrase_panel, PHRASE_PANEL_POS, PHRASE_PANEL_SIZE, 0, "left")

	# 按 id 升序铺 2 列。**不放分组标题** —— 两列网格里塞不下，
	# 备战期那块也没有，两边保持一致。12 条扫一眼就完了，标题是噪音。
	var index := 0
	for group in ChatPhrases.GROUP_ORDER:
		for phrase_id in ChatPhrases.ids_in_group(group):
			var btn := PrepWidgets.make_menu_button(
				ChatPhrases.text(phrase_id), PHRASE_BTN_SIZE, PHRASE_BTN_FONT,
				_on_phrase_picked.bind(int(phrase_id)))
			# 🔴 必须清掉。make_menu_button 会设 custom_minimum_size = size，
			# 而 Control.size 的 setter 会把值 clamp 到 custom_minimum_size ——
			# 于是 _layout() 在窗口缩小（scale < 1）时设的尺寸会被顶回原值，
			# 按钮不缩小、整块布局散开。备战期那边不用清，它走的是容器布局。
			btn.custom_minimum_size = Vector2.ZERO
			btn.z_index = 41
			btn.visible = false
			add_child(btn)
			_track(btn, PHRASE_BTN_ORIGIN + Vector2(
				float(index % PHRASE_COLUMNS) * PHRASE_BTN_STEP.x,
				float(index / PHRASE_COLUMNS) * PHRASE_BTN_STEP.y),
				PHRASE_BTN_SIZE, PHRASE_BTN_FONT, "left")
			_phrase_buttons.append(btn)
			index += 1

func _toggle_phrase_panel() -> void:
	if not _online():
		DialogService.info({"owner": self,
			"body": _room_text("联机对局中才能发送", "Available in online matches only")})
		return
	_set_phrase_panel_visible(not _phrase_panel.visible)

func _set_phrase_panel_visible(shown: bool) -> void:
	if _phrase_panel == null or not is_instance_valid(_phrase_panel):
		return
	_phrase_panel.visible = shown
	for btn in _phrase_buttons:
		btn.visible = shown


func _on_phrase_picked(phrase_id: int) -> void:
	# 只发不显示。本地回显要等服务器广播回来 —— 服务器是唯一定序者，
	# 本地抢先显示会让自己看到的顺序和别人不一样。见 NetworkService.team_send_phrase。
	NetworkService.team_send_phrase(phrase_id)
	# 发完收起，同备战期。面板压着敌方席位的一角，没理由让它一直开着。
	_set_phrase_panel_visible(false)

# 记录里多了一条（NetworkService.room_chat_log）。大厅只发全部（2026-09-14 定：开局前还在换座位，
# 队伍没定），所以大厅阶段的记录不带范围标记（RoomChatLog.line_text 按回合判断）。
# 会收到 team_only 的只有一种情况：同队有人已经进了摆放界面发消息、这台还停在大厅
# （切场景的那一两秒）。那条本来就只发给了同队，照常显示。
func _on_chat_logged(entry: Dictionary) -> void:
	_show_chat_entry(entry)
	if _record_panel != null and is_instance_valid(_record_panel) and _record_panel.visible:
		var stick := _record_near_bottom()
		_append_record_row(entry)
		if stick:
			_scroll_record_to_bottom()


func _show_chat_entry(entry: Dictionary) -> void:
	# 历史内容由 _append_record_row 写入，保留统一的已读标记。
	NetworkService.room_chat_log.mark_entry_seen(entry)


# 打字入口（批次 D）。离线时同短语那句提示 —— 一个点了没反应的入口比没有更让人困惑。
func _open_text_input() -> void:
	if not _online():
		DialogService.info({"owner": self,
			"body": _room_text("联机对局中才能发送", "Available in online matches only")})
		return
	_set_phrase_panel_visible(false)
	ChatInputBar.new().present(self, func(text: String) -> String:
		return NetworkService.team_send_text(text))


# 消息标签的字号（_build_chat_box 建标签用的也是它）。
const CHAT_FONT_SIZE := 19
# 不能出现在行首的标点（中文排版的「避头」）。碰到它们换行时，把上一行最后一个字
# 一起带下来，而不是让逗号、句号孤零零地顶在下一行开头。
const CHAT_NO_LINE_START := "，。、；：！？）」』】》…,.;:!?)"

# 逐字符折行：中文没有空格可断；英文单词偶尔会被拆开，聊天里可以接受。
# 静态、不碰界面状态 —— tools/chat_check 直接调它量「最长的一条放不放得下」。
static func wrap_chat_text(line: String, font: Font, font_size: int, width: float) -> PackedStringArray:
	var out := PackedStringArray()
	var current := ""
	for i in line.length():
		var ch := line[i]
		var candidate := current + ch
		if current.is_empty() or font.get_string_size(
				candidate, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= width:
			current = candidate
		elif CHAT_NO_LINE_START.contains(ch) and current.length() > 1:
			# 避头：上一行让出最后一个字，陪这个标点一起换行。
			out.append(current.left(-1))
			current = current.right(1) + ch
		else:
			out.append(current)
			current = ch
	if not current.is_empty():
		out.append(current)
	return out

# 记录容器的尺寸跟随原聊天框，保留快捷短语与打字入口。
func _build_record_panel() -> void:
	_record_panel = PanelContainer.new()
	_record_panel.name = "LobbyInlineHistory"
	_record_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	add_child(_record_panel)
	_track(_record_panel, Vector2(CHAT_MSG_X, CHAT_FIRST_LINE_Y),
		Vector2(CHAT_MSG_W, CHAT_LINES * CHAT_LINE_H), 0, "left")
	_record_scroll = preload("res://ui/components/FloatingChatScroll.gd").new()
	_record_scroll.name = "LobbyChatHistoryScroll"
	_record_panel.add_child(_record_scroll)
	_record_list = VBoxContainer.new()
	_record_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_record_list.add_theme_constant_override("separation", 4)
	var padding := MarginContainer.new()
	padding.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	padding.add_theme_constant_override("margin_right", 16)
	_record_scroll.add_child(padding)
	padding.add_child(_record_list)


func _render_record() -> void:
	for child in _record_list.get_children():
		_record_list.remove_child(child)
		child.queue_free()
	_record_round = -1
	var entries := NetworkService.room_chat_log.entries_for(NetworkService.team_room_id)
	if entries.is_empty():
		_record_list.add_child(_record_label(_room_text("还没有人说话", "No messages yet"),
			Tokens.PARCHMENT_EDGE, HORIZONTAL_ALIGNMENT_CENTER))
		return
	for entry in entries:
		_append_record_row(entry)
	NetworkService.room_chat_log.mark_all_seen()
	_scroll_record_to_bottom()


func _append_record_row(entry: Dictionary) -> void:
	var en := _room_en()
	if _record_round < 0 and _record_list.get_child_count() > 0:
		# 列表里只有「还没有人说话」那一行：第一条真消息进来时把它换掉。
		for child in _record_list.get_children():
			_record_list.remove_child(child)
			child.queue_free()
	var entry_round := int(entry.get("round", 0))
	if entry_round != _record_round:
		_record_list.add_child(_record_label("—— %s ——" % RoomChatLog.round_label(entry_round, en),
			Tokens.PARCHMENT_EDGE, HORIZONTAL_ALIGNMENT_CENTER))
		_record_round = entry_round
	_record_list.add_child(_record_label(RoomChatLog.line_text(entry, en), Tokens.CHAT_INK,
		HORIZONTAL_ALIGNMENT_LEFT))


func _record_label(text: String, color: Color, align: HorizontalAlignment) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = align
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var size := _record_font_size()
	lbl.add_theme_font_size_override("font_size", size if align == HORIZONTAL_ALIGNMENT_LEFT else maxi(13, size - 3))
	lbl.add_theme_color_override("font_color", color)
	return lbl


# 同 _layout 给 _placed 里的文字缩字号的规则（最小 13）。
func _record_font_size() -> int:
	return maxi(13, roundi(RECORD_FONT_SIZE * _layout_scale))


# 在最底下（或差一点）才跟着新消息滚；往上翻着看的时候不把人拽回底部（同私聊界面）。
func _record_near_bottom() -> bool:
	var bar := _record_scroll.get_v_scroll_bar()
	return _record_scroll.scroll_vertical >= int(bar.max_value - bar.page) - 2


func _scroll_record_to_bottom() -> void:
	# 新行要等排完版才知道高度，现在滚只会滚到旧的底部（同 ChatScreen._scroll_to_bottom_later）。
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree() or _record_scroll == null or not is_instance_valid(_record_scroll):
		return
	_record_scroll.scroll_vertical = int(_record_scroll.get_v_scroll_bar().max_value)

func _room_text(zh: String, en: String) -> String:
	return en if _room_en() else zh

func _room_en() -> bool:
	return TranslationServer.get_locale().begins_with("en")

# ── 布局调试overlay ────────────────────────────────────────────────
func _build_debug_layer() -> void:
	_debug_layer = Control.new()
	_debug_layer.name = "DebugLayoutOverlay"
	_debug_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_debug_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_debug_layer.z_index = 4096
	_debug_layer.visible = _debug_on
	_debug_layer.draw.connect(_draw_debug_layout)
	add_child(_debug_layer)

func _unhandled_key_input(event: InputEvent) -> void:
	# V3 P1-07：F3 切排布调试网格，也只在 debug 包响应 —— Release 桌面版有真实
	# 键盘，玩家按到 F3 不该看见内部调试线。
	if not OS.is_debug_build():
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.keycode != KEY_F3:
		return
	_debug_on = not _debug_on
	if _debug_layer != null:
		_debug_layer.visible = _debug_on
		_debug_layer.queue_redraw()
	get_viewport().set_input_as_handled()

func _draw_debug_layout() -> void:
	if _debug_layer == null:
		return
	var viewport_size := get_viewport_rect().size
	var scale := _layout_scale
	var origin := _layout_origin
	var font := ThemeDB.fallback_font
	var black := Color(0.0, 0.0, 0.0, 0.95)
	var black_soft := Color(0.0, 0.0, 0.0, 0.45)
	var red := Color(1.0, 0.10, 0.10, 0.95)

	# 1) 参考画布 1672x941 的外框（居中缩放的那块 16:9 区域）
	var canvas := Rect2(origin, REF_SIZE * scale)
	_debug_layer.draw_rect(canvas, black, false, 3.0)
	_debug_layer.draw_string(font, origin + Vector2(6.0, -6.0),
		"参考画布 %dx%d  scale=%.3f  视口 %dx%d" % [int(REF_SIZE.x), int(REF_SIZE.y), scale,
		int(viewport_size.x), int(viewport_size.y)],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, black)

	# 2) 画布中线 + 四等分竖线（摆按钮时用来对齐）
	for i in range(1, 4):
		var gx := origin.x + REF_SIZE.x * scale * float(i) / 4.0
		_debug_layer.draw_line(Vector2(gx, canvas.position.y), Vector2(gx, canvas.end.y),
			black if i == 2 else black_soft, 2.0 if i == 2 else 1.0)

	# 3) 功能分区带（横向黑带，标注参考坐标 y 范围）
	for band in DEBUG_BANDS:
		var by := origin.y + float(band.y) * scale
		var bh := float(band.h) * scale
		_debug_layer.draw_rect(Rect2(canvas.position.x, by, canvas.size.x, bh), black, false, 2.0)
		_debug_layer.draw_string(font, Vector2(canvas.position.x + 8.0, by + 18.0),
			"%s  y=%d~%d" % [band.name, int(band.y), int(band.y) + int(band.h)],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, black)

	# 3.5) 六个席位格：底板范围 + 席位号（入座判定比底板小一圈，看红框对比）
	for i in 6:
		var sp: Vector2 = SLOT_POS[i]
		var slot_rect := Rect2(origin + sp * scale, SLOT_SIZE * scale)
		_debug_layer.draw_rect(slot_rect, black, false, 2.0)
		_debug_layer.draw_string(font, slot_rect.position + Vector2(6.0, -4.0),
			"席位%s (%d,%d) %dx%d" % [SLOT_LABELS[i], int(sp.x), int(sp.y),
			int(SLOT_SIZE.x), int(SLOT_SIZE.y)],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, black)

	# 4) edge=left / edge=right 锚定边（这两列贴安全区的左右边，不跟画布走）
	#    左列最宽的是聊天框(147+432)、右列最靠左的是房主提示(1285)
	var safe := SafeArea.rect()
	var left_edge_x := safe.position.x + 579.0 * scale
	var right_edge_x := safe.end.x - (REF_SIZE.x - 1285.0) * scale
	_debug_layer.draw_line(Vector2(left_edge_x, 0.0), Vector2(left_edge_x, viewport_size.y), black, 2.0)
	_debug_layer.draw_line(Vector2(right_edge_x, 0.0), Vector2(right_edge_x, viewport_size.y), black, 2.0)
	_debug_layer.draw_string(font, Vector2(6.0, viewport_size.y - 26.0),
		"edge=left 贴安全区左", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, black)
	_debug_layer.draw_string(font, Vector2(right_edge_x + 6.0, viewport_size.y - 26.0),
		"edge=right 贴安全区右", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, black)

	# 5) 每个元素的占位框：按钮判定区红色，其余（图片/文字）黑色细框
	for item in _placed:
		var node := item.node as Control
		if node == null or not node.is_visible_in_tree():
			continue
		var rect := Rect2(node.position, node.size)
		var pos := item.pos as Vector2
		var size := item.size as Vector2
		if node is Button:
			_debug_layer.draw_rect(rect, red, false, 2.0)
			var edge_tag := str(item.get("edge", ""))
			var tag := "%s  (%d,%d) %dx%d%s" % [node.name, int(pos.x), int(pos.y),
				int(size.x), int(size.y), "" if edge_tag.is_empty() else "  edge=" + edge_tag]
			_debug_layer.draw_string(font, rect.position + Vector2(2.0, -4.0), tag,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, red)
		else:
			_debug_layer.draw_rect(rect, black_soft, false, 1.0)
