extends Node

# 安全区门禁（ui/services/SafeArea.gd，docs/安全区适配.md）。
#
# 假装是一台横屏 iPhone（灵动岛 / 圆角占掉左右两条、手势条占掉底下一条），把每一页真的打开，
# 然后逐个看：**能点的东西、要看的字，有没有落进被挡住的那几条**。
#
# 口径：
#   * 能点的：按钮、输入框、滑条 —— 整个判定区都要在安全区里；
#   * 要看的字：有内容的 Label / RichTextLabel —— 同上；
#   * 铺满大半个屏幕的东西（背景、遮罩、滚动区本身）不算：它们本来就该铺满，被挡的只是边角；
#   * 3D 画面（SubViewport 里的东西）不算：棋盘和战场这一轮不动（见文档「暂时不做」）。
#
# 同一页再用「没有刘海」跑一遍：安全区是整屏时版面必须和以前一样能用（电脑、安卓不受影响）。
#
# 运行：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/safe_area_check.tscn
#   （加 -- --list 只列出问题、不判失败，改版面时当工作清单用）

const CheckHarness := preload("res://tools/CheckHarness.gd")
const CHECK_NAME := "safe_area"

# iPhone 17 横屏：874×402 pt，左右各 62 pt、底 21 pt。按 2 倍开窗 = 1748×804。
# 根视口 1600×720 expand 之后是 1600×736，换算成逻辑单位约左右 114、底 38。
const PHONE_WINDOW := Vector2i(1748, 804)
const PHONE_INSETS := Vector4(114, 0, 114, 38)

# 大于视口这个比例的控件当成背景 / 遮罩 / 滚动区，不查。
const BACKDROP_SHARE := 0.6
# 取整、发光描边这一类几像素的出入不算。
const TOLERANCE := 4.0
const SETTLE_FRAMES := 12

const PAGES: Array = [
	["main_menu", "res://scenes/menu/MainMenu.tscn"],
	["lobby", "res://scenes/menu/Team3v3Lobby.tscn"],
	["prep", "res://scenes/prep/PrepScreen.tscn"],
	["settings", "res://scenes/menu/SettingsScreen.tscn"],
	["profile", "res://scenes/menu/ProfileScreen.tscn"],
	["shop", "res://scenes/menu/ShopScreen.tscn"],
	["bag", "res://scenes/menu/BagScreen.tscn"],
	["mail", "res://scenes/menu/MailScreen.tscn"],
	["friends", "res://scenes/menu/FriendsScreen.tscn"],
	["chat", "res://scenes/menu/ChatScreen.tscn"],
	["announcements", "res://scenes/menu/AnnouncementScreen.tscn"],
	["pet", "res://scenes/menu/PetScreen.tscn"],
	["codex", "res://scenes/menu/CodexScreen.tscn"],
	["battle", "res://scenes/battle/BattleScreen.tscn"],
	["diamond_store", "res://scenes/menu/DiamondStoreDialog.tscn"],
	["pet_draw", "res://scenes/menu/PetDrawDialog.tscn"],
]

var _h: CheckHarness
var _list_only := false


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_list_only = "--list" in OS.get_cmdline_user_args()
	var restore := get_window().size
	get_window().size = PHONE_WINDOW
	await _settle(4)
	for page in PAGES:
		await _check_page(str(page[0]), str(page[1]), PHONE_INSETS)
		await _check_page(str(page[0]), str(page[1]), Vector4.ZERO)
	SafeArea.set_test_insets(null)
	GameState.team_mode = false
	get_window().size = restore
	await _settle(2)
	_h.finish(get_tree())


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame


func _check_page(label: String, path: String, insets: Vector4) -> void:
	SafeArea.set_test_insets(insets)
	if label == "prep" or label == "battle":
		GameState.reset_run()
	# 组队对局才有的那几样（队伍法阵血量）也要摆出来查。
	GameState.team_mode = label == "battle"
	var page := (load(path) as PackedScene).instantiate() as Control
	add_child(page)
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await _settle(SETTLE_FRAMES)
	var safe := SafeArea.rect().grow(TOLERANCE)
	var view := get_viewport().get_visible_rect()
	var tag := "%s%s" % [label, "" if insets == Vector4.ZERO else "@iphone"]
	var bad := 0
	for control in _visible_controls(page):
		var rect := _content_rect(control)
		if rect.get_area() <= 0.0 or rect.get_area() > view.get_area() * BACKDROP_SHARE:
			continue
		_h.item()
		# 放在滚动框里的：上下滚得到，只查左右。
		if _in_scroll(control):
			if rect.position.x >= safe.position.x and rect.end.x <= safe.end.x:
				continue
		# 整屏也要在视口里（没有刘海时查的就是这条：以前能用的版面不能被这次改坏）。
		elif safe.encloses(rect):
			continue
		bad += 1
		var what := _describe(control)
		if _list_only:
			_h.note("[%s] %s %s 超出安全区 %s" % [tag, what, str(rect), str(safe)])
		else:
			_h.fail("outside_safe_area", "[%s] %s %s 超出安全区 %s" % [tag, what, str(rect), str(safe)])
	if bad == 0:
		_h.note("[%s] 全部在安全区内" % tag)
	page.queue_free()
	await _settle(2)


# 看得见的、能点的或有字的控件。不下钻 SubViewport（3D 画面）。
func _visible_controls(root: Node) -> Array[Control]:
	var out: Array[Control] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is SubViewport:
			continue
		if node is CanvasItem and not (node as CanvasItem).is_visible_in_tree():
			continue
		if node is Control and _matters(node as Control):
			out.append(node as Control)
		for child in node.get_children():
			stack.append(child)
	return out


func _matters(control: Control) -> bool:
	if control is BaseButton or control is LineEdit or control is TextEdit or control is Range:
		return control.mouse_filter != Control.MOUSE_FILTER_IGNORE or control is Range
	if control is Label:
		return not (control as Label).text.strip_edges().is_empty()
	if control is RichTextLabel:
		return not (control as RichTextLabel).get_parsed_text().strip_edges().is_empty()
	# 能点的图标（种族徽章之类：点了看说明）。纯装饰的图标是 IGNORE，不查。
	if control is TextureRect:
		return (control as TextureRect).texture != null and control.mouse_filter == Control.MOUSE_FILTER_STOP
	return false


# 字要看的是字本身占的那一段：一整行宽、文字居中的标题，两头空着的部分被挡不要紧。
func _content_rect(control: Control) -> Rect2:
	var rect := control.get_global_rect()
	if not (control is Label) or (control as Label).autowrap_mode != TextServer.AUTOWRAP_OFF:
		return rect
	var label := control as Label
	var font := label.get_theme_font("font")
	var size := label.get_theme_font_size("font_size")
	var width := 0.0
	for line in label.text.split("\n"):
		width = maxf(width, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x)
	width = minf(width * label.get_global_transform().get_scale().x, rect.size.x)
	match label.horizontal_alignment:
		HORIZONTAL_ALIGNMENT_CENTER:
			rect.position.x += (rect.size.x - width) * 0.5
		HORIZONTAL_ALIGNMENT_RIGHT:
			rect.position.x += rect.size.x - width
	rect.size.x = width
	# 上下同理：一整列高、文字竖直居中的提示，只有中间那几行是字。
	var height := minf(label.get_line_count() * label.get_line_height() * label.get_global_transform().get_scale().y,
		rect.size.y)
	match label.vertical_alignment:
		VERTICAL_ALIGNMENT_CENTER:
			rect.position.y += (rect.size.y - height) * 0.5
		VERTICAL_ALIGNMENT_BOTTOM:
			rect.position.y += rect.size.y - height
	rect.size.y = height
	return rect


func _in_scroll(control: Node) -> bool:
	var node := control.get_parent()
	while node != null:
		if node is ScrollContainer:
			return true
		node = node.get_parent()
	return false


func _describe(control: Control) -> String:
	var text := ""
	if control is Label:
		text = (control as Label).text
	elif control is Button:
		text = (control as Button).text
	elif control is RichTextLabel:
		text = (control as RichTextLabel).get_parsed_text()
	text = text.strip_edges().replace("\n", " ").left(20)
	return "%s%s" % [str(control.get_path()).get_file() if control.name.is_empty() else control.name,
		"「%s」" % text if not text.is_empty() else "(%s)" % control.get_class()]
