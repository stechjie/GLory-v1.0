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
const RacePick := preload("res://scripts/units/RacePick.gd")
# 这一页新加的按钮一律实例化这个场景，不写 Button.new() —— procedural_ui_ratchet 按文件只许降。
const ActionButtonScene := preload("res://ui/components/GloryActionButton.tscn")
# 手绘插画和模型预览共用同一个脚本；主菜单、背包仍使用模型。
const PetPreview := preload("res://scripts/pets/PetPreview.gd")
# 与 PrepShopRaceIcon.LOGO_PATHS 同一批图。新种族没出图时这一块留空，不报错。
const RACE_LOGO_PATH := "res://assets/ui/race_logos/%s.png"
const PrepSkin := preload("res://scenes/prep/PrepSkin.gd")
# 10.01 第 12 条：点种族卡片时弹该族的羁绊效果（只列效果，不含达成条件）。
const SynergyBond := preload("res://scenes/prep/panels/SynergyPanel.gd")

signal back_requested
signal starter_picked   # 首次三选一选定后发出（用于「进主菜单前的强制关卡」）
signal shop_requested   # 棋盘皮肤页点了「去商城」

enum Tab { PETS, RACES, SKINS }
enum SkinOwnership { NOT_LOADED, LOADING, READY, FAILED }

const CARD_SIZE := Vector2(210, 280)
const RACE_CARD_SIZE := Vector2(190, 250)
const RACE_LOGO_SIZE := Vector2(96, 96)
const SKIN_CARD_SIZE := Vector2(300, 0)
const SKIN_PREVIEW_SIZE := Vector2(276, 155)   # 预览图是实机画面截的 16:9

var _title_label: Label
var _tab_row: HBoxContainer
var _tab_buttons: Dictionary = {}   # Tab -> Button
var _tab: int = Tab.PETS
var _back_btn: Button

# --- 宠物页 ---
var _pet_box: VBoxContainer
var _cards_row: HBoxContainer
var _hint_label: Label
var _active_label: Label

# --- 种族页 ---
var _race_box: VBoxContainer
var _race_hint_label: Label
var _race_count_label: Label
var _race_save_btn: Button
var _race_cards: Dictionary = {}   # race -> {"panel": PanelContainer, "name": Label, "button": Button}
# 草稿：玩家在页面上点来点去的那一份。只有凑满 RacePick.required_count() 个、按了「保存」
# 才交给账号服务器 —— 选到一半（3 个）的状态绝不能存，否则存下来的就是一份不合法的选择。
# 顺序始终跟 RacePick.all_races() 一致，这样才能直接和已保存的那份比较。
var _race_draft: Array[String] = []

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

func _exit_tree() -> void:
	if PlayerProfile.pets_changed.is_connected(_refresh):
		PlayerProfile.pets_changed.disconnect(_refresh)
	if PlayerProfile.races_changed.is_connected(_on_races_changed):
		PlayerProfile.races_changed.disconnect(_on_races_changed)
	if PlayerProfile.prep_skin_changed.is_connected(_refresh_skins):
		PlayerProfile.prep_skin_changed.disconnect(_refresh_skins)

func _build() -> void:
	# V3 P1-04 验收原文：「无业务按钮使用 Godot 默认主题」。
	# 这一页此前既没有 theme=，也没有任何 add_theme_stylebox_override，
	# 而 project.godot 也没有 gui/theme/custom —— 所以按钮走的是引擎
	# 默认灰色样式，和游戏其它地方长得完全不是一套。
	theme = Theming.get_theme()
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.08)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# 内容列：铺满屏，但设为 IGNORE，否则会盖住返回按钮把点击吃掉（卡片内按钮仍可点）。
	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 18)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)
	# 灵动岛 / 圆角那几条让出来；背景照样铺满（ui/services/SafeArea.gd）。
	SafeArea.track(col)

	_title_label = Label.new()
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 40)
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
	_back_btn.pressed.connect(func(): back_requested.emit())
	add_child(_back_btn)
	SafeArea.track(_back_btn)

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
		button.pressed.connect(func() -> void: _switch_tab(tab_id))
		_tab_buttons[tab_id] = button
		_tab_row.add_child(button)
	return _tab_row

func _build_pet_box() -> Control:
	_pet_box = VBoxContainer.new()
	_pet_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_pet_box.add_theme_constant_override("separation", 18)
	_pet_box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_hint_label = Label.new()
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.add_theme_font_size_override("font_size", 18)
	_hint_label.add_theme_color_override("font_color", Color(0.75, 0.78, 0.85))
	_pet_box.add_child(_hint_label)

	_cards_row = HBoxContainer.new()
	_cards_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_cards_row.add_theme_constant_override("separation", 24)
	_cards_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pet_box.add_child(_cards_row)

	_active_label = Label.new()
	_active_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_active_label.add_theme_font_size_override("font_size", 20)
	_active_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.55))
	_pet_box.add_child(_active_label)
	return _pet_box

func _switch_tab(tab_id: int) -> void:
	_tab = tab_id
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
	var starter_mode := PlayerProfile.needs_starter_pick
	_hint_label.text = tr("pet_starter_hint") if starter_mode else ""
	_hint_label.visible = starter_mode
	_active_label.text = tr("pet_active_label") % PetService.display_name(PlayerProfile.get_active())
	for c in _cards_row.get_children():
		c.queue_free()
	for p in PetService.all_pets():
		_cards_row.add_child(_build_card(str((p as Dictionary).get("id", "")), starter_mode))

func _build_card(pet_id: String, starter_mode: bool) -> Control:
	var owned := PlayerProfile.is_owned(pet_id)
	var is_active := PlayerProfile.get_active() == pet_id
	# 未拥有且非首次三选一时置灰。
	var greyed := not owned and not starter_mode

	var card := PanelContainer.new()
	card.custom_minimum_size = CARD_SIZE
	var m := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 12)
	card.add_child(m)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	m.add_child(content)

	content.add_child(PetPreview.build_illustration(pet_id, PetPreview.CARD_SIZE, greyed))

	var name_lbl := Label.new()
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 24)
	name_lbl.text = PetService.display_name(pet_id)
	if is_active:
		name_lbl.text += "  ✓"
	if greyed:
		name_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	content.add_child(name_lbl)

	var effect_lbl := Label.new()
	effect_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	effect_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	effect_lbl.add_theme_font_size_override("font_size", 16)
	effect_lbl.text = PetService.effect_text(pet_id)
	effect_lbl.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45) if greyed else Color(0.55, 0.85, 0.55))
	content.add_child(effect_lbl)

	content.add_child(_build_card_button(pet_id, owned, is_active, starter_mode))
	return card

func _build_card_button(pet_id: String, owned: bool, is_active: bool, starter_mode: bool) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(0, 44)
	if starter_mode:
		# 首次三选一：任选一只作为初始宠物，选定后发信号让上层放行进主菜单。
		btn.text = tr("pet_pick")
		# 归属上云之后这是一次服务端往返（同购买的发货路径）。
		# 失败就什么都不做 —— PlayerProfile 不会动缓存，界面保持原样。
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

# --- 种族页 -------------------------------------------------------------------

func _build_race_box() -> Control:
	_race_box = VBoxContainer.new()
	_race_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_race_box.add_theme_constant_override("separation", 18)
	_race_box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_race_hint_label = Label.new()
	_race_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_race_hint_label.add_theme_font_size_override("font_size", 18)
	_race_hint_label.add_theme_color_override("font_color", Color(0.75, 0.78, 0.85))
	_race_box.add_child(_race_hint_label)

	# 种族以后会变多：用流式容器，一行放不下就折行，而不是把卡片挤出屏幕。
	var cards := HFlowContainer.new()
	cards.alignment = FlowContainer.ALIGNMENT_CENTER
	cards.add_theme_constant_override("h_separation", 24)
	cards.add_theme_constant_override("v_separation", 18)
	cards.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_race_box.add_child(cards)
	# 卡片只建一次，之后点选只改状态：在按钮自己的 pressed 回调里把它从树上摘掉会出问题。
	for race in RacePick.all_races():
		cards.add_child(_build_race_card(race))

	_race_count_label = Label.new()
	_race_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_race_count_label.add_theme_font_size_override("font_size", 20)
	_race_count_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.55))
	_race_box.add_child(_race_count_label)

	_race_save_btn = ActionButtonScene.instantiate() as Button
	_race_save_btn.text = tr("race_pick_save")
	_race_save_btn.theme_type_variation = Theming.VARIATION_PRIMARY
	_race_save_btn.custom_minimum_size = Vector2(240, Tokens.TOUCH_MIN)
	_race_save_btn.pressed.connect(_on_race_save_pressed)
	_race_box.add_child(_race_save_btn)
	return _race_box

func _build_race_card(race: String) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = RACE_CARD_SIZE
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	card.add_child(content)

	var logo := TextureRect.new()
	logo.custom_minimum_size = RACE_LOGO_SIZE
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var logo_path := RACE_LOGO_PATH % race
	# 先问 exists：load 一个不存在的路径会打引擎错误，而新种族没出图是正常情况。
	if ResourceLoader.exists(logo_path):
		logo.texture = load(logo_path) as Texture2D
	content.add_child(logo)

	var name_lbl := Label.new()
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 24)
	content.add_child(name_lbl)

	var units_lbl := Label.new()
	units_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	units_lbl.add_theme_font_size_override("font_size", 16)
	units_lbl.add_theme_color_override("font_color", Color(0.72, 0.74, 0.80))
	units_lbl.text = tr("race_pick_units") % RacePick.unit_count(race)
	content.add_child(units_lbl)

	var btn := ActionButtonScene.instantiate() as Button
	btn.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	btn.size_flags_horizontal = Control.SIZE_FILL
	btn.pressed.connect(_on_race_card_pressed.bind(race))
	content.add_child(btn)

	_race_cards[race] = {"panel": card, "name": name_lbl, "button": btn}
	return card

func _refresh_races() -> void:
	if _race_count_label == null:
		return
	var need := RacePick.required_count()
	var forced := RacePick.is_forced()
	var saved: Array[String] = PlayerProfile.get_selected_races()
	if forced:
		# 没得选（种族数 ≤ 要选的数量）：草稿就是全部，整页锁定。
		_race_draft = saved
	if forced:
		_race_hint_label.text = tr("race_pick_forced") % RacePick.all_races().size()
	else:
		_race_hint_label.text = tr("race_pick_hint") % need
	for race in _race_cards:
		_refresh_race_card(str(race), forced)
	var dirty: bool = _race_draft != saved
	_race_count_label.text = tr("race_pick_count") % [_race_draft.size(), need]
	if dirty and not forced:
		_race_count_label.text += "  ·  " + tr("race_pick_unsaved")
	_race_save_btn.visible = not forced
	_race_save_btn.disabled = _race_draft.size() != need or not dirty

func _refresh_race_card(race: String, forced: bool) -> void:
	var parts: Dictionary = _race_cards[race]
	var picked := _race_draft.has(race)
	var name_lbl: Label = parts["name"]
	name_lbl.text = tr("race_pick_name") % UnitDetailFormat.unit_race_name(race)
	if picked:
		name_lbl.text += "  ✓"
	# 选中的描金边：光看按钮上的字，几张卡并排时一眼分不出哪几族在出战。
	var panel: PanelContainer = parts["panel"]
	panel.add_theme_stylebox_override("panel",
		Tokens.panel_box(Tokens.SURFACE, Tokens.GOLD_EDGE if picked else Tokens.BORDER, 12))
	var btn: Button = parts["button"]
	if forced:
		# ★ 10.01 第 12 条真机踩的坑：这里以前是 tr("race_pick_locked")（「出战中」）+ disabled = true。
		#   **禁用的 Button 根本不发 pressed** —— 所以四族全出战时（今天就是）这四张卡
		#   一个都点不动，羁绊弹窗写得再对也永远弹不出来。门禁当时只做源码文本断言，
		#   于是照样 PASS 70/0，真机上却是「点了没反应」。
		#   锁定语义没丢，只是换了表达：不再靠「按钮点不动」，改成「点了也改不了选择」
		#   （拦在 _on_race_card_pressed 里）。按钮这就腾出来做「查看羁绊」。
		btn.text = tr("race_pick_view_bond")
		btn.disabled = false
	else:
		btn.text = tr("race_pick_deselect") if picked else tr("race_pick_select")
		btn.disabled = false

func _on_race_card_pressed(race: String) -> void:
	# 10.01 第 12 条：点种族卡片，第一件事就是摊开这一族的羁绊效果。
	# **必须排在下面那道 is_forced 早退之前**：没得选的那一页（今天四族全出战就是）
	# 要是先 return，羁绊弹窗就永远点不出来 —— 真机就是这么点不动的。
	_show_race_bond(race)
	# 没得选（今天：四族全出战）：弹窗已经把第 12 条要的东西给了，到此为止。
	# 再往下走只会去改 _race_draft —— 那会把一个「锁定页」变成能改出非法选择的页。
	if RacePick.is_forced():
		return
	var need := RacePick.required_count()
	if _race_draft.has(race):
		_race_draft.erase(race)
	elif _race_draft.size() >= need:
		# 满了不自动顶掉最早选的那个：玩家没说要换掉哪一族，替他决定只会让人困惑。
		GloryToast.show_text(tr("race_pick_full") % need)
		return
	else:
		var next: Array[String] = []
		for known in RacePick.all_races():
			if known == race or _race_draft.has(known):
				next.append(known)
		_race_draft = next
	_refresh_races()

# 10.01 第 12 条：点种族卡片时把该族的羁绊**效果**摊开给玩家看。
#
# 用 DialogService.info（只有一个「知道了」的提示框，长文自动滚）。
# 正文纯文本：弹窗正文是 Label 不吃 BBCode，而且全文同一字号同一颜色，
# 正好满足「字体和颜色深浅要一致」——不像战场羁绊面板那样分两种亮度。
func _show_race_bond(race: String) -> void:
	var body: String = SynergyBond.format_synergy_effects(race)
	if body.is_empty():
		return
	DialogService.info({
		"title": SynergyBond.format_synergy_title(race),
		"body": body,
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
	content.add_child(name_lbl)

	var status_lbl := Label.new()
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_lbl.add_theme_font_size_override("font_size", 16)
	status_lbl.add_theme_color_override("font_color", Color(0.72, 0.74, 0.80))
	content.add_child(status_lbl)

	var btn := ActionButtonScene.instantiate() as Button
	btn.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	btn.size_flags_horizontal = Control.SIZE_FILL
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
		Tokens.panel_box(Tokens.SURFACE, Tokens.GOLD_EDGE if is_active else Tokens.BORDER, 12))
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
