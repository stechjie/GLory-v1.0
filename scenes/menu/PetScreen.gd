extends Control
# 备战界面。从主菜单「备战」按钮进入，三个页签：
#   - 宠物：展示所有宠物（拥有的可「设为出战」，未拥有置灰）。
#   - 种族：选定出战种族（RacePick），对局里自己的商店只刷这几族的棋子。
#   - 棋盘皮肤：对局里摆放界面用哪一套图（PrepSkin，docs/棋盘皮肤.md）。只有自己看得见。
# 注意与对局里摆棋子的「摆放界面」（scenes/prep/PrepScreen）区分 —— 两个以前都叫备战。
# 首次（needs_starter_pick）时整页只剩「宠物三选一」：任选一只作为初始宠物（拥有 + 出战），
# 页签和返回按钮都藏起来，选完才放行（用于「进主菜单前的强制关卡」）。
# 卡片统一规格：手绘插画 + 名字 + 效果。缺图时回退模型预览。

const Theming := preload("res://ui/theme/GloryTheme.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const PROFILE_BG_TEX := preload("res://assets/ui/profile/hall_of_glory.png")
const RacePick := preload("res://scripts/units/RacePick.gd")
# 这一页新加的按钮一律实例化这个场景，不写 Button.new() —— procedural_ui_ratchet 按文件只许降。
const ActionButtonScene := preload("res://ui/components/GloryActionButton.tscn")
# 手绘插画和模型预览共用同一个脚本；主菜单、背包仍使用模型。
const PetPreview := preload("res://scripts/pets/PetPreview.gd")
# 与 PrepShopRaceIcon.LOGO_PATHS 同一批图。新种族没出图时这一块留空，不报错。
const RACE_LOGO_PATH := "res://assets/ui/race_logos/%s.png"
const PrepSkin := preload("res://scenes/prep/PrepSkin.gd")
# 点击种族图标查看羁绊效果；选择按钮独立修改出战草稿。
const SynergyBond := preload("res://scenes/prep/panels/SynergyPanel.gd")
# 要在商城集齐棋子才能出战的种族（2026-10-10 赤律族）。规则与商城棋子页同一份。
const UnitCollection := preload("res://scripts/account/UnitCollection.gd")

signal back_requested
signal starter_picked   # 首次三选一选定后发出（用于「进主菜单前的强制关卡」）
signal shop_requested   # 棋盘皮肤页点了「去商城」
signal unit_shop_requested(race: String)   # 种族页点了没解锁的种族 ->「去商城」直接落在棋子页
signal unit_ownership_loaded

enum Tab { PETS, RACES, SKINS }
enum SkinOwnership { NOT_LOADED, LOADING, READY, FAILED }

const CARD_SIZE := Vector2(200, 200)
const PET_ART_SIZE := Vector2(160, 76)
const PET_PAGE_ROWS := 2
const RACE_CARD_SIZE := Vector2(174, 144)
const RACE_LOGO_SIZE := Vector2(62, 62)
const UNIT_TILE_SIZE := Vector2(112, 104)
const SKIN_CARD_SIZE := Vector2(300, 0)
const SKIN_PREVIEW_SIZE := Vector2(276, 155)   # 预览图是实机画面截的 16:9

# 宠物技能浮框（10.15 第 3 点）。宽度固定、高度按文案量（见 _fit_pet_tip）：
# 最长的一条是英文老虎技能说明（361 字符），中文只有 122 —— 写死高度不是留一大片
# 空白就是被裁掉，所以量。
const PET_TIP_WIDTH := 620.0
const PET_TIP_PAD := 16.0
const PET_TIP_GAP := 6.0
const PET_TIP_MIN_HEIGHT := 120.0
const PET_TIP_MAX_HEIGHT := 420.0

var _title_label: Label
var _tab_row: HBoxContainer
var _tab_buttons: Dictionary = {}   # Tab -> Button
var _tab: int = Tab.PETS
var _back_btn: Button

# --- 宠物页 ---
var _pet_box: VBoxContainer
var _cards_row: VBoxContainer
var _hint_label: Label
var _active_label: Label
var _pet_page := 0
var _pet_prev_btn: Button
var _pet_next_btn: Button
var _pet_page_label: Label
# 宠物技能浮框：点模型显示、点别处收起（10.15 第 3 点），见 _build_pet_tip。
var _pet_tip: Panel
var _pet_tip_rows: Array[Control] = []   # 眉标 / 名字 / 分隔线 / 摘要 / 详情（加入顺序）
var _pet_tip_name: Label
var _pet_tip_effect: Label
var _pet_tip_detail: Label
var _pet_tip_pet := ""

# --- 种族页 ---
var _race_box: VBoxContainer
var _race_hint_label: Label
var _race_count_label: Label
var _race_save_btn: Button
var _race_cards: Dictionary = {}   # race -> {"panel", "name", "button", "logo"}
var _viewed_race := ""
var _race_roster_title: Label
var _race_roster_grid: GridContainer
var _race_roster_scroll: ScrollContainer
var _race_notice: PanelContainer
var _race_notice_label: Label
# 商城目录（GET /v1/shop 的 items）与拥有列表（内容 id -> true）。进这一页时拉一次；
# 拉不到就都是空的 -> 哪一族都不锁（真正挡人的是服务端，见 UnitCollection.gd 顶部）。
var _shop_items: Array = []
var _owned_content: Dictionary = {}
var _unit_ownership_ready := false


func tutorial_unit_ownership_ready() -> bool:
	return _unit_ownership_ready
# 草稿：玩家在页面上点来点去的那一份。只有凑满 RacePick.required_count() 个、按了「保存」
# 才交给账号服务器 —— 选到一半（3 个）的状态绝不能存，否则存下来的就是一份不合法的选择。
# 顺序始终跟 RacePick.all_races() 一致，这样才能直接和已保存的那份比较。
var _race_draft: Array[String] = []


func tutorial_pet_target() -> Control:
	return _cards_row


func tutorial_race_tab_target() -> Control:
	return _tab_buttons.get(Tab.RACES) as Control


func tutorial_god_target() -> Control:
	if not _race_cards.has("god"):
		return null
	return _race_cards["god"].get("panel") as Control


# 10.19 教程反馈第 5 条：教学引导走到种族页时，「返回」是唯一该点的键。
func tutorial_back_target() -> Control:
	return _back_btn


# 教学模式下锁掉本页除「返回」以外的所有按钮（10.19 教程反馈第 5 条）。
#
# 为什么只改 mouse_filter、不改 disabled：disabled 会把按钮画成灰底，
# 玩家第一眼会以为页面坏了；IGNORE 只是不响应点击，外观保持原样。
# 为什么必须递归：Godot 的 mouse_filter 不继承，卡片上的点击来自
# logo(TextureButton) / 选择按钮(Button) 这些子节点，只锁父容器等于没锁。
# ⚠ 只在教程里调用（Main._on_tutorial_races_opened），普通玩家进这一页不受影响。
var _tutorial_input_locked := false


func tutorial_lock_page_input(locked: bool) -> void:
	_tutorial_input_locked = locked
	_apply_tutorial_input_lock(self)


func _apply_tutorial_input_lock(node: Node) -> void:
	if not _tutorial_input_locked:
		return
	for child in node.get_children():
		var btn := child as BaseButton
		if btn != null and btn != _back_btn:
			btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_apply_tutorial_input_lock(child)

# --- 棋盘皮肤页 ---
var _skin_box: VBoxContainer
var _skin_cards: Dictionary = {}   # skin id -> {"panel", "name", "status", "button"}
# 哪些皮肤要花钱、买过哪些：进这一页时才拉（商城目录 + 归属）。不在目录里的一律免费。
var _skin_ownership: int = SkinOwnership.NOT_LOADED
var _skin_sold: Dictionary = {}    # 商城里卖的皮肤 id -> true
var _skin_owned: Dictionary = {}   # 买过的内容 id -> true
var _skin_busy := false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_race_draft = PlayerProfile.get_selected_races()
	_build()
	resized.connect(_on_resized)
	if not PlayerProfile.pets_changed.is_connected(_refresh):
		PlayerProfile.pets_changed.connect(_refresh)
	if not PlayerProfile.races_changed.is_connected(_on_races_changed):
		PlayerProfile.races_changed.connect(_on_races_changed)
	if not PlayerProfile.prep_skin_changed.is_connected(_refresh_skins):
		PlayerProfile.prep_skin_changed.connect(_refresh_skins)
	_refresh()
	# 归属、出战种族、棋盘皮肤的真相在服务端，开这一页时拉一次。成功会发 pets_changed /
	# races_changed / prep_skin_changed，页面再刷一遍；失败什么都不做（缓存不动），页面就还是上次那份。
	PlayerProfile.refresh_pets()
	PlayerProfile.refresh_races()
	PlayerProfile.refresh_prep_skin()
	_load_unit_ownership()

func _on_resized() -> void:
	if _cards_row != null:
		_refresh_pets()
	if _race_roster_grid != null:
		_refresh_race_roster()

func _exit_tree() -> void:
	if PlayerProfile.pets_changed.is_connected(_refresh):
		PlayerProfile.pets_changed.disconnect(_refresh)
	if PlayerProfile.races_changed.is_connected(_on_races_changed):
		PlayerProfile.races_changed.disconnect(_on_races_changed)
	if PlayerProfile.prep_skin_changed.is_connected(_refresh_skins):
		PlayerProfile.prep_skin_changed.disconnect(_refresh_skins)

# 「点宠物模型以外的地方 -> 浮框消失」（10.15 第 3 点）。
#
# ★ 为什么由 _input 来收，而不是 _unhandled_input：引擎的派发顺序是
#   `_input` -> GUI 命中测试 -> `_unhandled_input`，而这一页的根节点是个
#   mouse_filter 默认 STOP 的 Control 且铺满整屏 —— 点在空白处会被它自己吃掉，
#   `_unhandled_input` 永远不会响。
#   顺序反过来正好帮了忙：点在**模型**上时这里先收起、紧跟着模型的 gui_input
#   又把它打开，净效果是「保持显示」；点在别处则只有收起这一步。
func _input(event: InputEvent) -> void:
	if _pet_tip == null or not _pet_tip.visible:
		return
	if not is_visible_in_tree():
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_hide_pet_tip()
	elif event is InputEventScreenTouch:
		# 真机触摸：emulate_mouse_from_touch 不一定开着，触摸事件必须自己处理，
		# 否则手指点别处收不起来（与 PrepDetailOverlay.attach_long_press 同一课）。
		if (event as InputEventScreenTouch).pressed:
			_hide_pet_tip()


func _build() -> void:
	# V3 P1-04 验收原文：「无业务按钮使用 Godot 默认主题」。
	# 这一页此前既没有 theme=，也没有任何 add_theme_stylebox_override，
	# 而 project.godot 也没有 gui/theme/custom —— 所以按钮走的是引擎
	# 默认灰色样式，和游戏其它地方长得完全不是一套。
	theme = Theming.get_theme()
	# 与头像详情页共用完整场景，不裁切成局部装饰。
	var bg := TextureRect.new()
	bg.texture = PROFILE_BG_TEX
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# 内容列：铺满屏，但设为 IGNORE，否则会盖住返回按钮把点击吃掉（卡片内按钮仍可点）。
	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 10)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)
	# 灵动岛 / 圆角那几条让出来；背景照样铺满（ui/services/SafeArea.gd）。
	SafeArea.track(col)

	_title_label = Label.new()
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 36)
	_title_label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	_title_label.add_theme_color_override("font_outline_color", Tokens.PREP_INK)
	_title_label.add_theme_constant_override("outline_size", 5)
	col.add_child(_title_label)

	col.add_child(_build_tabs())
	col.add_child(_build_pet_box())
	col.add_child(_build_race_box())
	col.add_child(_build_skin_box())

	# 返回按钮（右上角）。最后添加 = 输入拾取时在最上层，不会被内容列挡住。
	# 仅在非首次（已选过初始宠物）时显示；首次强制三选一时隐藏，逼玩家先选。
	_back_btn = Button.new()
	_back_btn.text = "← " + tr("pet_back")
	_back_btn.custom_minimum_size = Vector2(120, 46)
	_back_btn.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_back_btn.position = Vector2(_back_btn.position.x - 140, 20)
	_style_prep_button(_back_btn)
	_back_btn.pressed.connect(func(): back_requested.emit())
	add_child(_back_btn)
	SafeArea.track(_back_btn)

	# 宠物技能浮框。**最后添加** = 画在所有东西上面；但它整棵子树不吃输入
	# （见 _build_pet_tip），所以不会抢走底下卡片按钮的点击。
	_build_pet_tip()

# 页签：与 FriendsScreen 同一个做法 —— toggle_mode，当前页由 _refresh_chrome 按下。
func _build_tabs() -> Control:
	_tab_row = HBoxContainer.new()
	_tab_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_tab_row.add_theme_constant_override("separation", Tokens.GAP_S)
	_tab_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for spec in [[Tab.PETS, "prep_tab_pets"], [Tab.RACES, "prep_tab_races"], [Tab.SKINS, "prep_tab_skins"]]:
		var tab_id: int = spec[0]
		var button := ActionButtonScene.instantiate() as Button
		button.text = tr(str(spec[1]))
		button.custom_minimum_size = Vector2(180, Tokens.TOUCH_MIN)
		button.toggle_mode = true
		_style_prep_button(button)
		button.pressed.connect(func() -> void: _switch_tab(tab_id))
		_tab_buttons[tab_id] = button
		_tab_row.add_child(button)
	return _tab_row

func _build_pet_box() -> Control:
	_pet_box = VBoxContainer.new()
	_pet_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_pet_box.add_theme_constant_override("separation", 10)
	_pet_box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_hint_label = Label.new()
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.add_theme_font_size_override("font_size", 18)
	_hint_label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	_pet_box.add_child(_hint_label)

	_cards_row = VBoxContainer.new()
	_cards_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_cards_row.custom_minimum_size.y = 440
	_cards_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_cards_row.add_theme_constant_override("separation", 12)
	_cards_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pet_box.add_child(_cards_row)

	var pager := HBoxContainer.new()
	pager.alignment = BoxContainer.ALIGNMENT_CENTER
	pager.add_theme_constant_override("separation", 16)
	_pet_box.add_child(pager)
	_pet_prev_btn = ActionButtonScene.instantiate() as Button
	_pet_prev_btn.text = "〈"
	_pet_prev_btn.custom_minimum_size = Vector2(64, Tokens.TOUCH_MIN)
	_style_prep_button(_pet_prev_btn)
	_pet_prev_btn.pressed.connect(_change_pet_page.bind(-1))
	pager.add_child(_pet_prev_btn)
	_pet_page_label = Label.new()
	_pet_page_label.custom_minimum_size = Vector2(100, 0)
	_pet_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pet_page_label.add_theme_font_size_override("font_size", 18)
	_pet_page_label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	pager.add_child(_pet_page_label)
	_pet_next_btn = ActionButtonScene.instantiate() as Button
	_pet_next_btn.text = "〉"
	_pet_next_btn.custom_minimum_size = Vector2(64, Tokens.TOUCH_MIN)
	_style_prep_button(_pet_next_btn)
	_pet_next_btn.pressed.connect(_change_pet_page.bind(1))
	pager.add_child(_pet_next_btn)

	_active_label = Label.new()
	_active_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_active_label.add_theme_font_size_override("font_size", 18)
	_active_label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	_active_label.add_theme_color_override("font_outline_color", Tokens.PREP_INK)
	_active_label.add_theme_constant_override("outline_size", 4)
	_pet_box.add_child(_active_label)
	return _pet_box

func _change_pet_page(delta: int) -> void:
	_pet_page += delta
	_refresh_pets()

# --- 宠物技能浮框（10.15 第 3 点）-----------------------------------------------
#
# 需求原文：「备战-宠物界面，增加一个功能：点击宠物的模型可以显示出对应的宠物技能
# 文本框，点击除宠物模型外的地方文本框消失，文本内容可以参考背包-宠物档案里的文本
# 说明。」
#
# 文案与 BagScreen 的「伙伴档案」同源：都用 PetService 的三个取文案助手
#（display_name / effect_text / skill_detail_text），所以两处永远是同一份文字。

func _build_pet_tip() -> void:
	# ★ 底板用 `Panel`（普通 Control），行的高度和位置自己摆 —— **刻意不用
	#   PanelContainer / VBoxContainer**。容器版有三个坑叠在一起，10.15 实测
	#   「第一次弹出会变成一个 814px 高的大黑框」（门禁 pet_skill_tip 抓到）：
	#     ① 容器在 hidden 时完全不排版（`Container::_sort_children()` 一进门就是
	#        `if (!is_visible_in_tree()) return;`），子标签一直停在 0 宽；
	#     ② 0 宽下按自动换行算出来的最小高度是「每行一个字」的天文数字（实测 2961px）；
	#     ③ `Control.set_size()` 会把尺寸**夹到不小于最小尺寸**，那个天文数字就被写进了
	#        size；而容器的最小尺寸是缓存，标签重排后并不会同步失效（实测标签自己的
	#        `get_minimum_size()` 已经是 29，外层容器按 0 宽算出来的老值却还在），
	#        于是这 814px 再也降不下来。
	#   自己算、自己摆则全程同步，与「什么时候排版」无关 —— 同一个探针里，容器版
	#   在 `_ready` 里调是正常的、在输入回调里调就出错，这种看时机的坑不值得留。
	_pet_tip = Panel.new()
	_pet_tip.visible = false
	_pet_tip.custom_minimum_size = Vector2(PET_TIP_WIDTH, PET_TIP_MIN_HEIGHT)
	_pet_tip.size = Vector2(PET_TIP_WIDTH, PET_TIP_MIN_HEIGHT)
	_pet_tip.add_theme_stylebox_override("panel",
		Tokens.panel_box(Tokens.INK_PANEL, Tokens.GOLD_EDGE, int(PET_TIP_PAD)))
	_pet_tip_rows = []

	var eyebrow := Label.new()
	eyebrow.text = tr("pet_skill_tip_title")
	eyebrow.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	eyebrow.add_theme_color_override("font_color", Tokens.GOLD)
	_add_pet_tip_row(eyebrow)

	_pet_tip_name = Label.new()
	_pet_tip_name.add_theme_font_size_override("font_size", 24)
	_pet_tip_name.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	_add_pet_tip_row(_pet_tip_name)

	_add_pet_tip_row(HSeparator.new())

	_pet_tip_effect = Label.new()
	_pet_tip_effect.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pet_tip_effect.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	_pet_tip_effect.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	_add_pet_tip_row(_pet_tip_effect)

	_pet_tip_detail = Label.new()
	_pet_tip_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pet_tip_detail.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	_pet_tip_detail.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	_add_pet_tip_row(_pet_tip_detail)

	# 整棵子树一律 IGNORE。浮框只是提示，**绝不能吃掉底下的点击**：mouse_filter
	# 不继承，漏掉任何一个后代，那一块区域就会替它收走点击（10.15 第二轮
	#「被弹窗盖住的控件仍被命中」是同一类坑的反面）。
	_ignore_mouse_tree(_pet_tip)
	add_child(_pet_tip)


# 浮框里的一行：按加入顺序记下来，高度和位置由 _fit_pet_tip 统一摆。
func _add_pet_tip_row(row: Control) -> void:
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pet_tip.add_child(row)
	_pet_tip_rows.append(row)


func _ignore_mouse_tree(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore_mouse_tree(child)


func _on_pet_art_gui_input(event: InputEvent, pet_id: String, art: Control) -> void:
	var pressed := false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		pressed = mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT
	elif event is InputEventScreenTouch:
		pressed = (event as InputEventScreenTouch).pressed
	if pressed:
		_show_pet_tip(pet_id, art)


func _show_pet_tip(pet_id: String, art: Control) -> void:
	if _pet_tip == null:
		return
	_pet_tip_pet = pet_id
	_pet_tip_name.text = PetService.display_name(pet_id)
	_pet_tip_effect.text = PetService.effect_text(pet_id)
	var detail := PetService.skill_detail_text(pet_id)
	_pet_tip_detail.text = detail
	# 与背包一致：详情和摘要重复时不重复写一遍（蘑菇、兔子就是这种）。
	_pet_tip_detail.visible = not detail.is_empty() and detail != _pet_tip_effect.text
	_fit_pet_tip()
	_place_pet_tip(art)
	_pet_tip.visible = true


func _hide_pet_tip() -> void:
	if _pet_tip == null:
		return
	if _pet_tip.visible:
		_pet_tip.visible = false
	_pet_tip_pet = ""


# 逐行算高度、就地摆好（宽度固定）。全程同步，不看排版时机。
#
# 高度按文案量是有必要的：中文和英文差一倍多（英文老虎技能说明 361 字符、中文 122），
# 写死高度不是留一大片空白就是被裁掉。
# 量的口径是**标签自己**的 `get_minimum_size()` —— Label 收到 RESIZED 会当场按
# 当前宽度重排，这个值立刻就是真的；不去读外层控件的 `get_combined_minimum_size()`，
# 那个是缓存（见 _build_pet_tip 里的三个坑）。
func _fit_pet_tip() -> void:
	var inner := PET_TIP_WIDTH - PET_TIP_PAD * 2.0
	var cursor := PET_TIP_PAD
	var first := true
	for row in _pet_tip_rows:
		if row == null or not is_instance_valid(row):
			continue
		row.size.x = inner          # 先定宽，下面量到的高度才是按这个宽度换行的
		if not row.visible:
			continue
		if not first:
			cursor += PET_TIP_GAP
		first = false
		var row_height := row.get_minimum_size().y
		row.size = Vector2(inner, row_height)
		row.position = Vector2(PET_TIP_PAD, cursor)
		cursor += row_height
	_pet_tip.size = Vector2(PET_TIP_WIDTH,
		clampf(cursor + PET_TIP_PAD, PET_TIP_MIN_HEIGHT, PET_TIP_MAX_HEIGHT))


# 贴着被点的模型放：优先放它下面，下面放不下就翻到上面，最后一律夹回屏内
#（圆角屏的安全区、窄屏都不至于把它顶出画面）。
func _place_pet_tip(art: Control) -> void:
	var view := get_viewport_rect().size
	var tip_size := _pet_tip.size
	var pos := Vector2((view.x - tip_size.x) * 0.5, (view.y - tip_size.y) * 0.5)
	if art != null and is_instance_valid(art) and art.is_inside_tree():
		var rect := art.get_global_rect()
		pos.x = rect.get_center().x - tip_size.x * 0.5
		pos.y = rect.position.y + rect.size.y + 10.0
		if pos.y + tip_size.y > view.y - 12.0:
			pos.y = rect.position.y - tip_size.y - 10.0
	pos.x = clampf(pos.x, 12.0, maxf(12.0, view.x - tip_size.x - 12.0))
	pos.y = clampf(pos.y, 12.0, maxf(12.0, view.y - tip_size.y - 12.0))
	_pet_tip.global_position = pos


func _switch_tab(tab_id: int) -> void:
	_tab = tab_id
	_hide_pet_tip()
	_refresh_chrome()
	if _tab == Tab.RACES:
		_refresh_races()
	elif _tab == Tab.SKINS:
		if _skin_ownership == SkinOwnership.NOT_LOADED or _skin_ownership == SkinOwnership.FAILED:
			_load_skin_ownership()
		_refresh_skins()

func _refresh() -> void:
	if _cards_row == null:
		return
	_refresh_chrome()
	_refresh_pets()
	_refresh_races()
	_refresh_skins()
	# 重建卡片会新建按钮：教学锁必须跟着重新套一遍（否则刷新一次就又点得动了）。
	_apply_tutorial_input_lock(self)

# 标题、页签、返回按钮、哪一页可见。
func _refresh_chrome() -> void:
	var starter_mode := PlayerProfile.needs_starter_pick
	# 首次三选一：只剩宠物页，页签、返回都藏起来（选完才放行）。
	if starter_mode:
		_tab = Tab.PETS
	_title_label.text = tr("pet_title") if starter_mode else tr("prep_title")
	_tab_row.visible = not starter_mode
	for tab_id in _tab_buttons:
		(_tab_buttons[tab_id] as Button).button_pressed = tab_id == _tab
	_pet_box.visible = _tab == Tab.PETS
	_race_box.visible = _tab == Tab.RACES
	_skin_box.visible = _tab == Tab.SKINS
	if _back_btn != null:
		_back_btn.visible = not starter_mode

func _refresh_pets() -> void:
	# 下面会把卡片整批 remove_child 重建，浮框贴着的那个 art 随之消失 —— 先收起。
	_hide_pet_tip()
	var starter_mode := PlayerProfile.needs_starter_pick
	_hint_label.text = tr("pet_starter_hint") if starter_mode else ""
	_hint_label.visible = starter_mode
	_active_label.text = tr("pet_active_label") % PetService.display_name(PlayerProfile.get_active())
	for c in _cards_row.get_children():
		_cards_row.remove_child(c)
		c.queue_free()
	var ids: Array[String] = []
	if starter_mode:
		for pet_id in PetService.starter_ids():
			ids.append(str(pet_id))
	else:
		for p in PetService.all_pets():
			ids.append(str((p as Dictionary).get("id", "")))
	var columns := 3 if starter_mode or get_viewport_rect().size.x < 1250.0 else 4
	var page_size := columns * PET_PAGE_ROWS
	var page_count := maxi(1, ceili(float(ids.size()) / float(page_size)))
	_pet_page = 0 if starter_mode else clampi(_pet_page, 0, page_count - 1)
	var row: HBoxContainer = null
	for i in range(_pet_page * page_size, mini(ids.size(), (_pet_page + 1) * page_size)):
		if (i - _pet_page * page_size) % columns == 0:
			row = HBoxContainer.new()
			row.alignment = BoxContainer.ALIGNMENT_CENTER
			row.add_theme_constant_override("separation", 14)
			_cards_row.add_child(row)
		row.add_child(_build_card(ids[i], starter_mode))
	_pet_page_label.text = "%d / %d" % [_pet_page + 1, page_count]
	_pet_page_label.get_parent().visible = not starter_mode and page_count > 1
	_pet_prev_btn.disabled = _pet_page == 0
	_pet_next_btn.disabled = _pet_page >= page_count - 1

func _build_card(pet_id: String, starter_mode: bool) -> Control:
	var owned := PlayerProfile.is_owned(pet_id)
	var is_active := PlayerProfile.get_active() == pet_id
	var greyed := not owned and not starter_mode

	var card := PanelContainer.new()
	card.custom_minimum_size = CARD_SIZE
	card.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.PREP_GLASS, Tokens.GOLD_EDGE if is_active else Tokens.PREP_EDGE, 4))
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 2)
	card.add_child(content)

	# 操作条在立绘上方；以后增加宠物也不会盖住脸或让按钮上下漂移。
	# 10.10：口味反转 —— **出战中**才是金框（disabled 也要金框），可点的「设为出战」不再带金框；
	# 选初始宠物的「选择」仍按主操作给金框。
	var action := _build_card_button(pet_id, owned, is_active, starter_mode)
	_style_prep_button(action, starter_mode or is_active)
	content.add_child(action)
	var art := PetPreview.build_illustration(pet_id, PET_ART_SIZE, false)
	art.modulate = Color(0.73, 0.73, 0.73) if greyed else Color.WHITE
	art.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	content.add_child(art)
	# 点模型 -> 弹出这只宠物的技能框（10.15 第 3 点）。立绘在卡片里是唯一「像模型」
	# 的那块；PetPreview 默认把它设成 IGNORE，这里必须改成 STOP 才收得到 gui_input
	# （卡片面板本身也是 STOP，所以这一个改动不会让别处的点击漏下去）。
	art.mouse_filter = Control.MOUSE_FILTER_STOP
	art.gui_input.connect(_on_pet_art_gui_input.bind(pet_id, art))

	var name_lbl := Label.new()
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 19)
	name_lbl.add_theme_color_override("font_color", Tokens.PREP_TEXT)
	name_lbl.text = PetService.display_name(pet_id)
	if is_active:
		name_lbl.text += "  ✓"
	content.add_child(name_lbl)

	var effect_lbl := Label.new()
	effect_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	effect_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	effect_lbl.max_lines_visible = 2
	effect_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	effect_lbl.add_theme_font_size_override("font_size", Tokens.FONT_MIN_READABLE)
	effect_lbl.add_theme_color_override("font_color", Tokens.PREP_TEXT)
	effect_lbl.text = PetService.effect_text(pet_id)
	content.add_child(effect_lbl)
	return card

func _build_card_button(pet_id: String, owned: bool, is_active: bool, starter_mode: bool) -> Button:
	var btn := ActionButtonScene.instantiate() as Button
	btn.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if starter_mode:
		btn.text = tr("pet_pick")
		btn.pressed.connect(func():
			if await PlayerProfile.pick_starter(pet_id):
				starter_picked.emit())
	elif not owned:
		btn.text = tr("pet_locked")
		btn.disabled = true
	elif is_active:
		btn.text = tr("pet_active_tag")
		btn.disabled = true
	else:
		btn.text = tr("pet_set_active")
		btn.pressed.connect(func(): await PlayerProfile.set_active(pet_id))
	return btn

func _style_prep_button(btn: Button, primary: bool = false) -> void:
	# primary = 金框（「出战中」/选宠主操作）。10.10 起 disabled 也跟随 primary，
	# 否则「出战中」作为 disabled 会被这条覆盖成无框。
	var idle := Tokens.PREP_GLASS_RAISED if primary else Tokens.PREP_GLASS
	btn.add_theme_stylebox_override("normal", Tokens.button_box(idle, Tokens.GOLD_EDGE if primary else Tokens.PREP_EDGE))
	btn.add_theme_stylebox_override("hover", Tokens.button_box(Tokens.PREP_GLASS_RAISED, Tokens.GOLD_EDGE))
	btn.add_theme_stylebox_override("pressed", Tokens.button_box(Tokens.PREP_GLASS_RAISED, Tokens.GOLD_EDGE))
	btn.add_theme_stylebox_override("disabled", Tokens.button_box(
		Tokens.PREP_GLASS, Tokens.GOLD_EDGE if primary else Tokens.PREP_EDGE))
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_disabled_color"]:
		btn.add_theme_color_override(state, Tokens.PREP_TEXT_MUTED if state == "font_disabled_color" else Tokens.PREP_TEXT)

# --- 种族页 -------------------------------------------------------------------

func _build_race_box() -> Control:
	_race_box = VBoxContainer.new()
	_race_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_race_box.add_theme_constant_override("separation", 10)
	_race_box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_race_hint_label = Label.new()
	_race_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_race_hint_label.add_theme_font_size_override("font_size", 17)
	_race_hint_label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	_race_box.add_child(_race_hint_label)

	var cards := HFlowContainer.new()
	cards.alignment = FlowContainer.ALIGNMENT_CENTER
	cards.add_theme_constant_override("h_separation", 12)
	cards.add_theme_constant_override("v_separation", 10)
	cards.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_race_box.add_child(cards)
	for race in RacePick.all_races():
		cards.add_child(_build_race_card(race))
	if not RacePick.all_races().is_empty():
		_viewed_race = RacePick.all_races()[0]

	var roster := PanelContainer.new()
	roster.add_theme_stylebox_override("panel",
		Tokens.panel_box(Tokens.PREP_GLASS, Tokens.PREP_EDGE, 12))
	roster.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	roster.custom_minimum_size.x = 990
	_race_box.add_child(roster)
	var roster_col := VBoxContainer.new()
	roster_col.add_theme_constant_override("separation", 8)
	roster.add_child(roster_col)
	var roster_header := HBoxContainer.new()
	roster_header.alignment = BoxContainer.ALIGNMENT_CENTER
	roster_col.add_child(roster_header)
	_race_roster_title = Label.new()
	_race_roster_title.add_theme_font_size_override("font_size", 20)
	_race_roster_title.add_theme_color_override("font_color", Tokens.PREP_TEXT)
	roster_header.add_child(_race_roster_title)
	var bond_btn := ActionButtonScene.instantiate() as Button
	bond_btn.text = tr("race_pick_view_bond")
	bond_btn.custom_minimum_size = Vector2(120, Tokens.TOUCH_MIN)
	_style_prep_button(bond_btn)
	bond_btn.pressed.connect(func() -> void: _show_race_bond(_viewed_race))
	roster_header.add_child(bond_btn)
	_race_roster_scroll = ScrollContainer.new()
	_race_roster_scroll.custom_minimum_size = Vector2(0, 122)
	_race_roster_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	roster_col.add_child(_race_roster_scroll)
	_race_roster_grid = GridContainer.new()
	_race_roster_grid.columns = 8
	_race_roster_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_race_roster_grid.add_theme_constant_override("h_separation", 8)
	_race_roster_grid.add_theme_constant_override("v_separation", 8)
	_race_roster_scroll.add_child(_race_roster_grid)

	_race_notice = PanelContainer.new()
	_race_notice.add_theme_stylebox_override("panel",
		Tokens.panel_box(Tokens.PREP_NOTICE, Tokens.PREP_EDGE, 8))
	_race_notice.visible = false
	_race_notice.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_race_notice.custom_minimum_size.x = 990
	_race_box.add_child(_race_notice)
	_race_notice_label = Label.new()
	_race_notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_race_notice_label.add_theme_font_size_override("font_size", 17)
	_race_notice_label.add_theme_color_override("font_color", Tokens.PREP_INK)
	_race_notice.add_child(_race_notice_label)

	_race_count_label = Label.new()
	_race_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_race_count_label.add_theme_font_size_override("font_size", 18)
	_race_count_label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	_race_box.add_child(_race_count_label)
	_race_save_btn = ActionButtonScene.instantiate() as Button
	_race_save_btn.text = tr("race_pick_save")
	_race_save_btn.custom_minimum_size = Vector2(240, Tokens.TOUCH_MIN)
	_style_prep_button(_race_save_btn, true)
	_race_save_btn.pressed.connect(_on_race_save_pressed)
	_race_box.add_child(_race_save_btn)
	return _race_box

func _build_race_card(race: String) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = RACE_CARD_SIZE
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	card.add_child(content)

	var logo := TextureButton.new()
	logo.custom_minimum_size = RACE_LOGO_SIZE
	logo.ignore_texture_size = true
	logo.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	logo.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	logo.tooltip_text = SynergyBond.format_synergy_title(race)
	logo.pressed.connect(_select_race_detail.bind(race))
	var logo_path := RACE_LOGO_PATH % race
	if ResourceLoader.exists(logo_path):
		logo.texture_normal = load(logo_path) as Texture2D
	content.add_child(logo)

	var name_lbl := Label.new()
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 19)
	name_lbl.add_theme_color_override("font_color", Tokens.PREP_TEXT)
	content.add_child(name_lbl)

	var btn := ActionButtonScene.instantiate() as Button
	btn.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	btn.size_flags_horizontal = Control.SIZE_FILL
	_style_prep_button(btn)
	btn.pressed.connect(_on_race_card_pressed.bind(race))
	content.add_child(btn)

	_race_cards[race] = {"panel": card, "name": name_lbl, "button": btn, "logo": logo}
	return card

func _refresh_races() -> void:
	if _race_count_label == null:
		return
	var need := mini(RacePick.PICK_COUNT, _available_race_count())
	var forced := _available_race_count() <= RacePick.PICK_COUNT
	var saved: Array[String] = PlayerProfile.get_selected_races()
	if forced:
		_race_draft = saved
	_race_hint_label.text = (tr("race_pick_forced") % need) if forced else (tr("race_pick_hint") % need)
	for race in _race_cards:
		_refresh_race_card(str(race), forced)
	_refresh_race_roster()
	var dirty: bool = _race_draft != saved
	_race_count_label.text = tr("race_pick_count") % [_race_draft.size(), need]
	if dirty and not forced:
		_race_count_label.text += "  ·  " + tr("race_pick_unsaved")
	_race_save_btn.visible = not forced
	var all_complete := true
	for race in _race_draft:
		if not _race_complete(race):
			all_complete = false
	_race_save_btn.disabled = _race_draft.size() != need or not dirty or not all_complete

func _refresh_race_card(race: String, forced: bool) -> void:
	var parts: Dictionary = _race_cards[race]
	var picked := _race_draft.has(race)
	var complete := _race_complete(race)
	var name_lbl: Label = parts["name"]
	name_lbl.text = tr("race_pick_name") % UnitDetailFormat.unit_race_name(race)
	if race == "god" and not complete and not _owned_content.is_empty():
		name_lbl.add_theme_font_size_override("font_size", 16)
		name_lbl.text += "  %d/%d" % [UnitCollection.owned_count(race, _owned_content),
			UnitCollection.total_count(race)]
	if picked:
		name_lbl.text += "  ✓"
	var panel: PanelContainer = parts["panel"]
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.PREP_GLASS if complete else Tokens.PREP_GLASS.darkened(0.22),
		Tokens.GOLD_EDGE if picked and complete else Tokens.PREP_EDGE, 8))
	var logo: TextureButton = parts["logo"]
	# 没解锁的种族 logo 压暗，一眼能看出来（点它会弹「去商城」）。
	logo.modulate = Color.WHITE if complete else Color(0.38, 0.38, 0.38)
	var btn: Button = parts["button"]
	if not complete:
		btn.text = "未解锁" if not TranslationServer.get_locale().begins_with("en") else "Locked"
		btn.disabled = false
	elif forced:
		btn.text = tr("race_pick_locked")
		btn.disabled = false
	else:
		btn.text = tr("race_pick_deselect") if picked else tr("race_pick_select")
		btn.disabled = false
	# 10.11 第 4 条：选中态（按钮写着「取消选择」）要带金边，一眼看出这一族已选。
	# 未解锁的不算选中，不给金边。
	_style_prep_button(btn, picked and complete)

func _select_race_detail(race: String) -> void:
	_viewed_race = race
	_race_notice.visible = false
	_refresh_race_roster()
	if not _race_complete(race):
		_prompt_race_shop(race)

func _refresh_race_roster() -> void:
	if _race_roster_grid == null or _viewed_race.is_empty():
		return
	_race_roster_title.text = "%s · %d" % [
		UnitDetailFormat.unit_race_name(_viewed_race), RacePick.unit_count(_viewed_race)]
	_race_roster_grid.columns = 4 if get_viewport_rect().size.x < 1250.0 else 8
	_race_roster_scroll.custom_minimum_size = Vector2(0, 224 if _race_roster_grid.columns == 4 else 122)
	for child in _race_roster_grid.get_children():
		child.queue_free()
	for raw in DataRegistry.get_table("race_units").get("units", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var unit := raw as Dictionary
		if str(unit.get("race", "")) == _viewed_race:
			_race_roster_grid.add_child(_build_unit_tile(unit))

func _build_unit_tile(unit: Dictionary) -> Control:
	var id := str(unit.get("id", ""))
	var race_of_unit := str(unit.get("race", ""))
	var missing := not _owned_content.has(UnitCollection.content_id(id)) \
		and not (race_of_unit == "human" and _shop_items.is_empty())
	var tile := PanelContainer.new()
	tile.custom_minimum_size = UNIT_TILE_SIZE
	tile.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.PREP_GLASS_RAISED if not missing else Tokens.PREP_GLASS,
		Tokens.PREP_EDGE, 4))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	tile.add_child(col)
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(48, 48)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var portrait_path := "res://assets/ui/unit_portraits/%s.png" % id
	var fallback_path := RACE_LOGO_PATH % str(unit.get("race", ""))
	if ResourceLoader.exists(portrait_path):
		icon.texture = load(portrait_path) as Texture2D
	elif ResourceLoader.exists(fallback_path):
		icon.texture = load(fallback_path) as Texture2D
	icon.modulate = Color(0.72, 0.72, 0.72) if missing else Color.WHITE
	col.add_child(icon)
	var name_lbl := Label.new()
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", Tokens.PREP_TEXT)
	name_lbl.text = str(unit.get("name_en", id)) if TranslationServer.get_locale().begins_with("en") else str(unit.get("name", id))
	col.add_child(name_lbl)
	var status := Label.new()
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.add_theme_font_size_override("font_size", Tokens.FONT_MIN_READABLE)
	status.add_theme_color_override("font_color", Tokens.PREP_TEXT)
	status.text = ("Not owned" if missing else "Tier %d" % int(unit.get("tier", 1))) if TranslationServer.get_locale().begins_with("en") else ("未拥有" if missing else "%d 阶" % int(unit.get("tier", 1)))
	col.add_child(status)
	return tile

func _race_has_products(race: String) -> bool:
	return UnitCollection.race_requires_purchase(race, _shop_items)

# 种族只有集齐全部棋子并收到服务端的种族归属后才能出战。
func _race_complete(race: String) -> bool:
	return _owned_content.has(race) or (race == "human" and _shop_items.is_empty())


func _available_race_count() -> int:
	var count := 0
	for race in RacePick.all_races():
		if _race_complete(race):
			count += 1
	return count

func _load_unit_ownership() -> void:
	var catalog: Dictionary = await AccountManager.fetch_shop()
	var owned: Dictionary = await AccountManager.fetch_entitlements()
	if not is_inside_tree():
		return
	if int(catalog.get("code", 0)) / 100 != 2 or int(owned.get("code", 0)) / 100 != 2:
		return
	_shop_items = ((catalog.get("body", {}) as Dictionary).get("items", []) as Array).duplicate()
	_owned_content.clear()
	for id in ((owned.get("body", {}) as Dictionary).get("items", []) as Array):
		_owned_content[str(id)] = true
	await PlayerProfile.refresh_races()
	_refresh_races()
	_unit_ownership_ready = true
	unit_ownership_loaded.emit()

# 没解锁的种族：点 logo 或卡片按钮都弹这个，「去商城」直接落在棋子页那一族。
func _prompt_race_shop(race: String) -> void:
	var en := TranslationServer.get_locale().begins_with("en")
	var race_name: String = UnitDetailFormat.unit_race_name(race)
	var title_name: String = race_name if en else "%s族" % race_name
	var have := UnitCollection.owned_count(race, _owned_content)
	var total := UnitCollection.total_count(race)
	DialogService.confirm({
		"owner": self,
		"title": ("%s is locked" % title_name) if en else ("%s未解锁" % title_name),
		"body": ("Collect all %d %s units in the Shop to unlock it. You have %d / %d." % [total, title_name, have, total]) if en
			else ("去商城集齐%s的全部 %d 个棋子即可解锁出战。当前已拥有 %d / %d。" % [title_name, total, have, total]),
		"confirm_text": "Go to Shop" if en else "去商城",
		"cancel_text": "Later" if en else "稍后",
		"on_result": func(answer: String, _id: String) -> void:
			if answer == "confirmed":
				unit_shop_requested.emit(race),
	})

# 从商城「去备战」进来：切到种族页、看那一族。
func show_races(race: String = "") -> void:
	if PlayerProfile.needs_starter_pick:
		return
	if not race.is_empty() and _race_cards.has(race):
		_viewed_race = race
	_switch_tab(Tab.RACES)
	_refresh_race_roster()

# 种族卡片的按钮：**只改选中草稿**，不再顺手弹羁绊窗。
#
# ★ 10.11 第 4 条：原来选中和取消两侧都调 `_show_race_bond()`，于是点「取消选择」
#   也会弹一个「XX族羁绊」窗（用户实拍到的就是这个）。羁绊窗现在只由「查看羁绊」
#   按钮打开 —— 卡片按钮只管选/取消。
func _on_race_card_pressed(race: String) -> void:
	_viewed_race = race
	_refresh_race_roster()
	if not _race_complete(race):
		_race_notice.visible = false
		_prompt_race_shop(race)
		return
	_race_notice.visible = false
	if _available_race_count() <= RacePick.PICK_COUNT:
		return
	var need := mini(RacePick.PICK_COUNT, _available_race_count())
	if _race_draft.has(race):
		_race_draft.erase(race)
	elif _race_draft.size() >= need:
		GloryToast.show_text(tr("race_pick_full") % need)
		return
	else:
		var next: Array[String] = []
		for known in RacePick.all_races():
			if known == race or _race_draft.has(known):
				next.append(known)
		_race_draft = next
	_refresh_races()

func _show_race_bond(race: String) -> void:
	var body: String = SynergyBond.format_synergy_effects(race)
	if body.is_empty():
		return
	DialogService.info({
		"title": SynergyBond.format_synergy_title(race),
		"body": body,
		"confirm_text": tr("codex_bond_gotit"),
		"owner": self,
	})


func _on_race_save_pressed() -> void:
	# 存要走一次网络。期间先把按钮按住，免得连点发出好几次。
	_race_save_btn.disabled = true
	var ok: bool = await PlayerProfile.set_selected_races(_race_draft)
	if not is_inside_tree():
		return
	# 没存上时草稿原样留着（页面上仍标「还没保存」），玩家可以直接再点一次。
	GloryToast.show_text(tr("race_pick_saved") if ok else tr("race_pick_save_failed"))
	_refresh_races()

func _on_races_changed() -> void:
	_race_draft = PlayerProfile.get_selected_races()
	_refresh_races()

# --- 棋盘皮肤页 ---------------------------------------------------------------

func _build_skin_box() -> Control:
	_skin_box = VBoxContainer.new()
	_skin_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_skin_box.add_theme_constant_override("separation", 18)
	_skin_box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var hint := Label.new()
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 18)
	hint.add_theme_color_override("font_color", Color(0.75, 0.78, 0.85))
	hint.text = tr("skin_tab_hint")
	_skin_box.add_child(hint)

	var cards := HFlowContainer.new()
	cards.alignment = FlowContainer.ALIGNMENT_CENTER
	cards.add_theme_constant_override("h_separation", 24)
	cards.add_theme_constant_override("v_separation", 18)
	cards.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_skin_box.add_child(cards)
	# 同种族页：卡片只建一次（目录随安装包走，开着这一页不会变），之后只改状态。
	for entry in PrepSkin.catalog():
		cards.add_child(_build_skin_card(str((entry as Dictionary).get("id", ""))))
	return _skin_box

func _build_skin_card(skin_id: String) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = SKIN_CARD_SIZE
	card.add_theme_stylebox_override("panel",
		Tokens.panel_box(Tokens.PREP_GLASS, Tokens.PREP_EDGE, 10))
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	card.add_child(content)

	var preview := TextureRect.new()
	preview.custom_minimum_size = SKIN_PREVIEW_SIZE
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	preview.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var preview_path := PrepSkin.preview_path(skin_id)
	if ResourceLoader.exists(preview_path):
		preview.texture = load(preview_path) as Texture2D
	content.add_child(preview)

	var name_lbl := Label.new()
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 24)
	name_lbl.add_theme_color_override("font_color", Tokens.PREP_TEXT)
	content.add_child(name_lbl)

	var status_lbl := Label.new()
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_lbl.add_theme_font_size_override("font_size", 16)
	status_lbl.add_theme_color_override("font_color", Tokens.PREP_TEXT)
	content.add_child(status_lbl)

	var btn := ActionButtonScene.instantiate() as Button
	btn.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	btn.size_flags_horizontal = Control.SIZE_FILL
	_style_prep_button(btn)
	btn.pressed.connect(_on_skin_card_pressed.bind(skin_id))
	content.add_child(btn)

	_skin_cards[skin_id] = {"panel": card, "name": name_lbl, "status": status_lbl, "button": btn}
	return card

# 商城目录 + 归属。只在进这一页时拉，失败下次进来再拉。
func _load_skin_ownership() -> void:
	_skin_ownership = SkinOwnership.LOADING
	var catalog: Dictionary = await AccountManager.fetch_shop()
	var owned: Dictionary = await AccountManager.fetch_entitlements()
	if not is_inside_tree():
		return
	if int(catalog.get("code", 0)) / 100 != 2 or int(owned.get("code", 0)) / 100 != 2:
		_skin_ownership = SkinOwnership.FAILED
		_refresh_skins()
		return
	_skin_sold.clear()
	for raw in ((catalog.get("body", {}) as Dictionary).get("items", []) as Array):
		var item := raw as Dictionary
		if str(item.get("kind", "")) == "prep_skin":
			_skin_sold[str(item.get("grants", ""))] = true
	_skin_owned.clear()
	for id in ((owned.get("body", {}) as Dictionary).get("items", []) as Array):
		_skin_owned[str(id)] = true
	_skin_ownership = SkinOwnership.READY
	_refresh_skins()

# 能不能直接用。知道在卖的，买了才能用；不在卖的清单里：拉到了清单就是免费，
# 没拉到（失败）先当能用 —— 账号服务器会把没买的挡回来，比「网络一抖整页都锁住」好。
func _skin_usable(skin_id: String) -> bool:
	if skin_id == PrepSkin.DEFAULT_ID:
		return true
	if _skin_sold.has(skin_id):
		return _skin_owned.has(skin_id)
	return _skin_ownership == SkinOwnership.READY or _skin_ownership == SkinOwnership.FAILED

func _refresh_skins() -> void:
	if _skin_cards.is_empty():
		return
	# 用着的那张这个包里没有（在更新的包上选的）：摆放界面显示的是默认，这里也标默认。
	var active := PrepSkin.active_id if PrepSkin.has_skin(PrepSkin.active_id) else PrepSkin.DEFAULT_ID
	for skin_id in _skin_cards:
		_refresh_skin_card(str(skin_id), str(skin_id) == active)

func _refresh_skin_card(skin_id: String, is_active: bool) -> void:
	var parts: Dictionary = _skin_cards[skin_id]
	var name_lbl: Label = parts["name"]
	name_lbl.text = PrepSkin.display_name(skin_id)
	if is_active:
		name_lbl.text += "  ✓"
	var panel: PanelContainer = parts["panel"]
	panel.add_theme_stylebox_override("panel",
		Tokens.panel_box(Tokens.PREP_GLASS,
			Tokens.GOLD_EDGE if is_active else Tokens.PREP_EDGE, 10))
	var status_lbl: Label = parts["status"]
	var btn: Button = parts["button"]
	var loading := _skin_ownership == SkinOwnership.LOADING or _skin_ownership == SkinOwnership.NOT_LOADED
	if skin_id == PrepSkin.DEFAULT_ID:
		status_lbl.text = tr("skin_status_free")
	elif _skin_sold.has(skin_id):
		status_lbl.text = tr("skin_status_owned") if _skin_owned.has(skin_id) else tr("skin_status_locked")
	elif loading:
		status_lbl.text = tr("skin_status_loading")
	elif _skin_ownership == SkinOwnership.FAILED:
		# 没拉到目录：不知道要不要钱，宁可不写，也别把卖的写成「免费」。
		status_lbl.text = ""
	else:
		status_lbl.text = tr("skin_status_free")
	if is_active:
		btn.text = tr("skin_in_use")
		btn.disabled = true
	elif skin_id != PrepSkin.DEFAULT_ID and loading:
		btn.text = tr("skin_use")
		btn.disabled = true
	elif _skin_usable(skin_id):
		btn.text = tr("skin_use")
		btn.disabled = _skin_busy
	else:
		btn.text = tr("skin_to_shop")
		btn.disabled = false
	# 10.11 第 4 条：正在使用的那张（按钮写着「使用中」）要带金边。
	_style_prep_button(btn, is_active)

func _on_skin_card_pressed(skin_id: String) -> void:
	if not _skin_usable(skin_id):
		shop_requested.emit()
		return
	if _skin_busy:
		return
	# 存要走一次网络。期间按住所有「使用」，免得连点发出好几次。
	_skin_busy = true
	_refresh_skins()
	var code: int = await PlayerProfile.set_prep_skin(skin_id)
	if not is_inside_tree():
		return
	_skin_busy = false
	if code / 100 == 2:
		GloryToast.show_text(tr("skin_saved") % PrepSkin.display_name(skin_id))
	elif code == 403:
		# 账号服务器说这张要买、还没买（页面以为它免费，比如拿到的商城目录不全）。按它说的算。
		_skin_sold[skin_id] = true
		_skin_owned.erase(skin_id)
		GloryToast.show_text(tr("skin_not_owned"))
	else:
		GloryToast.show_text(tr("skin_save_failed"))
	_refresh_skins()
