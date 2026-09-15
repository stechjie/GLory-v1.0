extends Node

# 公告的客户端状态（docs/公告系统设计.md）。
#
# 分工：
#   AccountManager       拉列表（HTTPS）
#   RealtimeService      收紧急公告推送（WebSocket）
#   AnnouncementImages   下载、校验、缓存图片（本节点的子节点 images）
#   本文件               列表快照、红点、登录弹窗该弹哪条、顶部横条 —— 界面只看这里
#
# 为什么单独一个 autoload：红点在主菜单与公告界面上要一致，推送随时可能到（同 ChatService 的理由）。
# 弹窗**什么时候**弹不归这里管，归 Main（只在主菜单上、没有别的弹窗、新手教学走完之后）。
#
# ## 看过哪些、弹过哪些存本机
#
# user://glory_announcements_seen.json，按「公告 id -> revision」记。换手机、清数据会再提醒一遍 ——
# 可以接受（同出战宠物）。**不上传服务器**：那要多一张表和一个写接口，只为了红点。
#
# 🔴 **不按当前列表裁剪这份记录。** 账号服务器刚重启时会短暂返回空列表，按列表裁剪的话
# 那一下就把所有「看过」清掉，全服重新弹一遍。只按条数封顶，丢最老的 id。

signal changed

const Text := preload("res://scripts/account/AnnouncementText.gd")
const Images := preload("res://scripts/account/AnnouncementImages.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")

# 与 backend/app/announcements.py 的 PUSH_TYPE / KINDS 一致（tools/announcement_check 钉着）。
# 对不上的话推送落进 RealtimeService 的「未知类型」分支：不报错，就是收不到。
const PUSH_TYPE := "announcement"
const KINDS := ["event", "news", "update", "urgent"]
const KIND_URGENT := "urgent"

const SEEN_FILE := "user://glory_announcements_seen.json"
const SEEN_LIMIT := 300
# 回主菜单时最多多久拉一次。普通公告靠它刷新；紧急公告有推送。
const REFRESH_MIN_INTERVAL_SEC := 60.0
# 一次启动最多弹几条。管理员同时开了五条弹窗时，玩家不该被连着糊五次。
const MAX_POPUPS_PER_SESSION := 3
# 顶部横条的层号：高于 ModalStack（1000 起）—— 停服预告要盖在弹窗之上；低于 GloryToast（1500）。
const BANNER_LAYER := 1400
const BANNER_SEC := 12.0

# 空串 = 不落盘（门禁用，免得改到开发机上真实的记录）。
var seen_file := SEEN_FILE
var images: Images

var _items: Array = []
var _loaded := false
var _fetching := false
var _last_fetch_msec := -1
var _seen: Dictionary = {}  # "id" -> 看过的 revision
var _popped: Dictionary = {}  # "id" -> 弹过的 revision
var _popups_this_session := 0
var _bannered: Dictionary = {}  # "id:revision" -> true，只记这次启动
var _banner: CanvasLayer


func _ready() -> void:
	images = Images.new()
	images.name = "Images"
	add_child(images)
	# 专服也会加载全部 autoload，但那里没有玩家、没有界面。
	if "--server" in OS.get_cmdline_args() or "--dedicated-server" in OS.get_cmdline_args():
		return
	_load_seen()
	RealtimeService.message_received.connect(_on_realtime_message)
	RealtimeService.connection_changed.connect(_on_connection_changed)


# --- 列表 ---------------------------------------------------------------------

# 服务器排好的顺序（置顶、新的在前）。
func items() -> Array:
	return _items


func is_loaded() -> bool:
	return _loaded


func find_item(id: int) -> Dictionary:
	for item in _items:
		if int((item as Dictionary).get("id", 0)) == id:
			return item
	return {}


# 拉一次列表。force=false 时 REFRESH_MIN_INTERVAL_SEC 内只拉一次（回主菜单时这么调）。
func refresh(force: bool = false) -> void:
	if _fetching or not AccountManager.is_logged_in():
		return
	var now := Time.get_ticks_msec()
	if not force and _last_fetch_msec >= 0 and now - _last_fetch_msec < int(REFRESH_MIN_INTERVAL_SEC * 1000.0):
		return
	_fetching = true
	var result: Dictionary = await AccountManager.fetch_announcements()
	_fetching = false
	_last_fetch_msec = Time.get_ticks_msec()
	if int(result.get("code", 0)) / 100 != 2:
		# 拉不到就保留上一份：公告不是必需品，不值得弹错误。
		return
	apply_list((result.get("body", {}) as Dictionary).get("announcements", []))


func apply_list(raw: Variant) -> void:
	var fresh: Array = []
	if raw is Array:
		for entry in raw:
			if entry is Dictionary and int((entry as Dictionary).get("id", 0)) > 0:
				fresh.append(entry)
	_items = fresh
	_loaded = true
	# 空列表不清图片缓存：理由同文件头那条 🔴。
	if images != null and not fresh.is_empty():
		images.prune(referenced_hashes())
	_show_next_banner()
	changed.emit()


func referenced_hashes() -> Dictionary:
	var out := {}
	for item in _items:
		var image: Variant = (item as Dictionary).get("image", null)
		if image is Dictionary:
			out[str((image as Dictionary).get("sha256", ""))] = true
	return out


# 登出时由 Main 调。「看过哪些」是这台设备的，不清。
func reset() -> void:
	_items = []
	_loaded = false
	_last_fetch_msec = -1
	_popups_this_session = 0
	_bannered.clear()
	hide_banner()
	changed.emit()


# --- 红点 ---------------------------------------------------------------------

static func key_of(item: Dictionary) -> String:
	return str(int(item.get("id", 0)))


# 这条的 revision 比记录里的新 = 没看过，或者管理员大改过。
static func is_newer(item: Dictionary, record: Dictionary) -> bool:
	return int(item.get("revision", 1)) > int(record.get(key_of(item), 0))


func is_unread(item: Dictionary) -> bool:
	return is_newer(item, _seen)


func any_unread() -> bool:
	for item in _items:
		if is_unread(item):
			return true
	return false


func mark_seen(item: Dictionary) -> void:
	if item.is_empty() or not is_unread(item):
		return
	_seen[key_of(item)] = int(item.get("revision", 1))
	_save_seen()
	changed.emit()


# --- 登录弹窗 -----------------------------------------------------------------

# 下一条该弹的：勾了 popup、这个 revision 没弹过。按服务器给的顺序取第一条。
static func pick_popup(list: Array, popped: Dictionary) -> Dictionary:
	for item in list:
		if not (item is Dictionary):
			continue
		# 先判类型再取值：Godot 4 里 "true" == true 不是 false，是运行时报错。
		var popup: Variant = (item as Dictionary).get("popup", false)
		if popup is bool and popup and is_newer(item, popped):
			return item
	return {}


func next_popup() -> Dictionary:
	if _popups_this_session >= MAX_POPUPS_PER_SESSION:
		return {}
	return pick_popup(_items, _popped)


# 弹出来那一刻就记下（Main 在 push 成功之后调）：图片还没下完玩家就切走了，也不该下次再弹同一条。
func mark_popped(item: Dictionary) -> void:
	_popped[key_of(item)] = int(item.get("revision", 1))
	_popups_this_session += 1
	_save_seen()


# --- 顶部横条（紧急公告）------------------------------------------------------

func english() -> bool:
	return LocaleManager.get_locale().begins_with("en")


# 显示一条横条。同一条（id + revision）这次启动只出一次；新的会顶掉旧的。返回有没有显示。
func show_banner(data: Dictionary) -> bool:
	var key := "%d:%d" % [int(data.get("id", 0)), int(data.get("revision", 1))]
	var title := Text.pick_text(data, "title", english())
	if title.is_empty() or _bannered.has(key):
		return false
	_bannered[key] = true
	hide_banner()
	_banner = _build_banner(("[Notice] " if english() else "【公告】") + title)
	add_child(_banner)
	return true


func has_banner() -> bool:
	return _banner != null and is_instance_valid(_banner)


func hide_banner() -> void:
	if has_banner():
		# 先摘树再释放（同 ModalStack._teardown）：只 queue_free 的话，这一帧的点击还会打到它身上。
		# 横条收起就整个释放，不留一个看不见却 STOP 的控件（ModalStack.find_invisible_stop_controls）。
		if _banner.get_parent() != null:
			_banner.get_parent().remove_child(_banner)
		_banner.queue_free()
	_banner = null


func _show_next_banner() -> void:
	for item in _items:
		if str((item as Dictionary).get("kind", "")) == KIND_URGENT and show_banner(item):
			return


func _build_banner(text: String) -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.name = "AnnouncementBanner"
	layer.layer = BANNER_LAYER

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.INK_PANEL, Tokens.GOLD_EDGE, Tokens.GAP_M))
	# 贴顶居中。只有横条本身吃点击（点一下收起），两侧和下面照常能点。
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.offset_top = Tokens.GAP_M
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.gui_input.connect(_on_banner_input)
	layer.add_child(panel)

	var label := Label.new()
	label.name = "Text"
	label.text = text
	label.custom_minimum_size = Vector2(560, 0)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	panel.add_child(label)

	# 计时器挂在层自己身上：被新横条顶掉时一起释放，回调不会落到已释放的节点上。
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = BANNER_SEC
	timer.autostart = true
	timer.timeout.connect(hide_banner)
	layer.add_child(timer)
	return layer


func _on_banner_input(event: InputEvent) -> void:
	var released := (event is InputEventMouseButton and not (event as InputEventMouseButton).pressed) \
		or (event is InputEventScreenTouch and not (event as InputEventScreenTouch).pressed)
	if released:
		# deferred：在控件自己的输入回调里把它摘掉，引擎这一帧后面还会碰它。
		hide_banner.call_deferred()


func _on_realtime_message(payload: Dictionary) -> void:
	if str(payload.get("t", "")) != PUSH_TYPE:
		return
	show_banner(payload)
	# 推送只带标题。列表跟上，玩家点进公告栏时才看得到全文。
	refresh(true)


func _on_connection_changed(_state: int) -> void:
	# 连上（含断线重连）之后拉一次：断线期间的推送全漏了。
	if RealtimeService.is_online():
		refresh(true)


# --- 本机记录 -----------------------------------------------------------------

func _load_seen() -> void:
	if seen_file.is_empty() or not FileAccess.file_exists(seen_file):
		return
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(seen_file)) != OK or not (json.data is Dictionary):
		return  # 坏了就当都没看过：最坏是多提醒一次
	var data: Dictionary = json.data
	_seen = revision_map(data.get("seen", {}))
	_popped = revision_map(data.get("popped", {}))


func _save_seen() -> void:
	_seen = capped(_seen)
	_popped = capped(_popped)
	if seen_file.is_empty():
		return
	# 不走 SaveManager 的原子写：这份丢了最多多提醒一次（同 RealtimeService 设备标识那条）。
	var f := FileAccess.open(seen_file, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"seen": _seen, "popped": _popped}))
	f.close()


static func revision_map(raw: Variant) -> Dictionary:
	var out := {}
	if not (raw is Dictionary):
		return out
	var source: Dictionary = raw
	for key in source:
		var id := str(key).to_int()
		var value: Variant = source[key]
		if id > 0 and (value is int or value is float):
			out[str(id)] = maxi(1, int(value))
	return out


# 只按条数封顶、丢最老的 id —— 不按当前列表裁剪（文件头那条 🔴）。
static func capped(record: Dictionary) -> Dictionary:
	if record.size() <= SEEN_LIMIT:
		return record
	var ids: Array[int] = []
	for key in record:
		ids.append(str(key).to_int())
	ids.sort()
	var out := {}
	for id in ids.slice(ids.size() - SEEN_LIMIT):
		out[str(id)] = record[str(id)]
	return out
