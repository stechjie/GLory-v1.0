extends Control

# 备战界面的**商店面板** —— D2 步骤 3′。
#
# 它现在是一个**真正的节点**，不再是 PrepShared 里的一个内部类。
# 之前那个内部类只是把 19 个变量归了个组 —— 一个变量袋子，没有任何行为；
# 商店的 18 个函数（593 行）仍然长在 6470 行的 PrepScreen 上。
#
# 这一步只做**换家**：状态搬进节点、节点进树，行为一行不动。
# 把状态和行为一起搬会让一次改动同时动 593 行代码和 19 个字段，
# 出问题时分不清是搬错了还是改错了。先换家、跑绿，再搬行为。
#
# 为什么树会 +1 个节点：
# 商店的控件分在**两处根**（顶层的 ShopSideControls 15 个节点，
# 主布局深处的 SellDropPanel 50 个节点），没有任何单一容器能同时拥有它们。
# 所以面板节点是新增的一个逻辑宿主，零尺寸、不吃输入、不影响布局。
# 节点树基线已显式重建（-- --update），差异只有这一个节点。

const DragButton := preload("res://scenes/prep/PrepDragButton.gd")
const SellDropPanel := preload("res://scenes/prep/PrepSellDropPanel.gd")
const PrepWidgets := preload("res://scenes/prep/PrepWidgets.gd")
const PrepRules := preload("res://scenes/prep/PrepRules.gd")


# D2 第三步：把备战界面「商店」这一簇从 PrepShared 的共享状态池里抽出来。
#
# 背景数据（见 docs/CHECKS.md 4.8）：
# 备战界面是 7 层继承合成的一个类，6727 行、409 个函数、148 个成员变量，
# 其中 `PrepShared.gd` 一层就声明了 110 个 —— 95 个跨层共用，是耦合的根。
# 按功能聚类，最大的两簇是 board（16 个）和 shop（19 个）。
#
# 本类接管 shop 那 19 个。抽出来之后：
#   * 归属明确：谁拥有商店状态一眼可见，不用在 110 个变量里翻
#   * 共享池从 110 降到 91
#   * 后续要把商店做成真正的组合节点（Control 子类）时，边界已经画好了
#
# **这一步不改任何行为**：只是把变量换了个家、引用加个前缀。
# 验证靠三样：节点树快照逐字节一致、prep_shop_check 24 项、board_4x4_smoke 62 项。
#
# 不用 class_name：与本仓库其它抽出来的服务保持一致 ——
# make_server_zip.ps1 会打包 .godot/global_script_class_cache.cfg，
# 新增全局类若未先重建缓存就打包，服务器会在解析阶段挂（见 docs/CHECKS.md）。
#
# 命名：去掉原来的 `_shop_` / `_shop` 前缀，因为它已经体现在 `_shop.` 上了。
# 原名与新名一一对应（单射），映射表在本文件末尾的注释里，改名时照着核对。

# --- 节点 ---------------------------------------------------------------------

var row: HBoxContainer                 # 原 _shop_row：手牌区一排卡
var panel: SellDropPanel               # 原 _shop_panel：商店弹窗本体
var open_button: Button                # 原 _shop_open_button：底部「商店」按钮
var buy_button: Button                 # 原 _buy_shop_button：钱袋 A 上的透明「采购」热区，教学箭头要指它
var sell_overlay: PanelContainer       # 原 _shop_sell_overlay：拖拽出售的红区
var side_controls: Control             # 原 _shop_side_controls：商店"外挂"控件层
                                       #（钱袋A购买键 + 刷新），挂屏幕上、不受商店面板矩形限制
var refresh_button: Button             # 原 _refresh_shop_button
var refresh_icon: Label                # 原 _refresh_shop_icon
var refresh_cost_label: Label          # 原 _refresh_shop_cost_label

# --- 每个卡位一份的子控件（下标与 GameState.shop_offers 对齐）------------------

var buttons: Array[DragButton] = []    # 原 _shop_buttons
var portraits: Array[TextureRect] = [] # 原 _shop_portraits
var card_frames: Array[TextureRect] = []  # 原 _shop_card_frames
var card_labels: Array[Label] = []     # 原 _shop_card_labels
var price_labels: Array[Label] = []    # 原 _shop_price_labels
var race_icons: Array[Control] = []    # 原 _shop_race_icons
var reason_labels: Array[Label] = []   # 原 _shop_reason_labels

# --- 状态 ---------------------------------------------------------------------

var picker_open := false               # 原 _shop_picker_open：弹窗是否展开
var selected := -1                     # 原 _selected_shop：当前选中的卡位，-1 = 未选
var drag_sell_mode := false            # 原 _shop_drag_sell_mode：是否处于拖拽出售态


# 卡位相关的数组一次性清空。构建前调用，避免重建界面时残留上一批控件引用
# （残留的引用指向已被 queue_free 的节点，访问时报 "previously freed"）。
func clear_slot_arrays() -> void:
	buttons.clear()
	portraits.clear()
	card_frames.clear()
	card_labels.clear()
	price_labels.clear()
	race_icons.clear()
	reason_labels.clear()


# 改名映射表（原名 -> 新名），单射。改引用时照此核对：
#   _shop_row                -> _shop.row
#   _shop_panel              -> _shop.panel
#   _shop_open_button        -> _shop.open_button
#   _buy_shop_button         -> _shop.buy_button
#   _shop_sell_overlay       -> _shop.sell_overlay
#   _shop_side_controls      -> _shop.side_controls
#   _refresh_shop_button     -> _shop.refresh_button
#   _refresh_shop_icon       -> _shop.refresh_icon
#   _refresh_shop_cost_label -> _shop.refresh_cost_label
#   _shop_buttons            -> _shop.buttons
#   _shop_portraits          -> _shop.portraits
#   _shop_card_frames        -> _shop.card_frames
#   _shop_card_labels        -> _shop.card_labels
#   _shop_price_labels       -> _shop.price_labels
#   _shop_race_icons         -> _shop.race_icons
#   _shop_reason_labels      -> _shop.reason_labels
#   _shop_picker_open        -> _shop.picker_open
#   _selected_shop           -> _shop.selected
#   _shop_drag_sell_mode     -> _shop.drag_sell_mode

# --- 依赖与对外信号（D2 步骤 3′b）-------------------------------------------
#
# 面板不认识 PrepScreen。它需要的东西只有三样，由 setup() 注入：
#   host           少数控件仍要挂在宿主节点下（这一步刻意不动节点树）
#   overlay        详情浮层组件，四个面板共用
#   hover_handler  立绘卡片的悬停动画回调，宿主与其它面板共用同一份
#
# 所有会改变游戏状态的操作都以**信号**发出，由宿主执行 ——
# 买入要动金币和待命区、刷新要扣钱、关别的弹窗要碰别的面板，
# 这些都不该由商店面板直接伸手去做。

signal card_selected(index: int)          # 选中一张卡；宿主负责清掉棋盘/待命的选中
signal buy_requested(index: int)          # 请求买入到待命区（找空位、扣钱、合成都归宿主）
signal detail_requested(index: int)       # 长按看详情（文案格式化在宿主那边）
signal picker_toggled(is_open: bool)      # 商店开合；宿主据此关别的弹窗、调待命格的输入
signal refresh_requested                  # 请求刷新商店（燃烧特效与扣钱都归宿主）
signal message_requested(text: String)    # 「钱不够」「待命区满」之类的提示
signal state_changed                      # 需要整屏刷新

var host: Control
var overlay: RefCounted
var hover_handler: Callable


func setup(p_host: Control, p_overlay: RefCounted, p_hover: Callable) -> void:
	host = p_host
	overlay = p_overlay
	hover_handler = p_hover


# --- 搬过来的常量（全仓只有商店簇在用，实测簇外引用为 0）--------------------

const SHOP_CLOSED_BTN_PATH := "res://assets/ui/buttons/shop_closed.png"   # 底部商店按钮图（自带文字，无需再叠字）
const SHOP_BTN_SIZE := Vector2(200, 66)      # 底部「商店」按钮（木牌框）
const SHOP_IDLE_ATLAS_PATH := "res://assets/vfx/prep/scroll_idle_shimmer_atlas.png"
const SHOP_IDLE_HALO_PATH := "res://assets/vfx/prep/scroll_idle_halo.png"
const SHOP_POPUP_SIZE := Vector2(896, 230)   # 商店弹窗判定框：宽=屏宽70%(1280*0.7)、高=屏高40%(720*0.4)
const SHOP_BG_SIZE := Vector2(920, 280)     # 背景卷轴显示尺寸（像素）：独立于判定框，改这里只变视觉不变判定
const SHOP_BG_OFFSET := Vector2(0, -2)        # 背景相对弹窗中心的平移（正 x 右移、正 y 下移）
const SHOP_PANEL_BACKGROUND_PATH := "res://assets/ui/shop/btm_stone_frame_v4.png"
const MONEY_BAG_GLOW_SHADER: Shader = preload("res://assets/shaders/prep_money_bag_glow.gdshader")
const GOLD_NUMBER_FONT: Font = preload("res://assets/fonts/Knewave-Regular.ttf")
const SHOP_CARD_SEPARATION := 12             # 手牌卡间距
const SHOP_CARD_SIZE := Vector2(180, 180)    # 手牌卡尺寸（稀有度框比例 ~1:1）
const UNIT_PORTRAIT_DIR := "res://assets/ui/unit_portraits"   # 头像 = <dir>/<unit_id>.png
const SHOP_CARD_FRAME_PATHS := {             # tier(1/2/3) → 普通/稀有/史诗框
	1: "res://assets/ui/shop/card_frame_common.png",
	2: "res://assets/ui/shop/card_frame_rare.png",
	3: "res://assets/ui/shop/card_frame_epic.png",
}
const PrepScrollIdleFlipbookScript = preload("res://scenes/prep/effects/PrepScrollIdleFlipbook.gd")
const PrepMoneyBagIcon = preload("res://scenes/prep/PrepMoneyBagIcon.gd")
const PrepMoneyBagAttentionGlowScript = preload("res://scenes/prep/effects/PrepMoneyBagAttentionGlow.gd")
const PrepShopRaceIcon = preload("res://scenes/prep/PrepShopRaceIcon.gd")


# --- 搬过来的成员 -----------------------------------------------------------
# 名字刻意不改：改名会让 500 多行搬运代码里多出一批要核对的替换，
# 而这一步的风险已经够大了。

var _gold_amount_label: Label
var _closed_gold_label: Label
var _shop_scroll_idle: PrepScrollIdleFlipbook
var _closed_money_bag: Control    # 商店关闭时的钱袋按钮（商店按钮左边）
var _shop_cards_signature := "unset"
var _shop_background: TextureRect



# 原 _build_shop_button_and_purse（PrepUI.gd）


# 底部商店按钮与钱袋 B。由 _build_rest 拆出（D2）。
# 原函数 638 行，全函数只有 2 处完全干净的切点 —— body 与 center_host
# 两个局部量跨越几乎整段。所以切点取在「除它们之外没有其它局部量跨越」处，
# 这些容器以参数传入（段内只读，不重新赋值）。
func build_button_and_purse(body: HBoxContainer, center_host: Control, center: Control) -> void:

	var board_bottom_reserve := Control.new()
	board_bottom_reserve.custom_minimum_size = Vector2(0, 248)
	board_bottom_reserve.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(board_bottom_reserve)

	# 底部「商店」按钮：点击打开/关闭商店弹窗（弹窗打开时被弹窗盖住）。保留 shop_closed.png 贴图框、图自带文字。
	var shop_open_btn := PrepWidgets.make_framed_text_button("", SHOP_CLOSED_BTN_PATH, SHOP_BTN_SIZE, 18, toggle_picker)
	open_button = shop_open_btn
	shop_open_btn.anchor_left = 0.5
	shop_open_btn.anchor_top = 1.0
	shop_open_btn.anchor_right = 0.5
	shop_open_btn.anchor_bottom = 1.0
	shop_open_btn.offset_left = -SHOP_BTN_SIZE.x * 0.5
	shop_open_btn.offset_right = SHOP_BTN_SIZE.x * 0.5
	shop_open_btn.offset_top = -SHOP_BTN_SIZE.y - 40
	shop_open_btn.offset_bottom = -40
	shop_open_btn.z_index = 6
	center_host.add_child(shop_open_btn)
	_shop_scroll_idle = PrepScrollIdleFlipbookScript.new()
	_shop_scroll_idle.setup(
		shop_open_btn,
		PrepWidgets.cached_texture(SHOP_IDLE_ATLAS_PATH),
		PrepWidgets.cached_texture(SHOP_IDLE_HALO_PATH)
	)
	shop_open_btn.add_child(_shop_scroll_idle)

	# 钱袋 B（商店关闭时显示）：放在「商店」按钮左边，显示金币，长按看利息。商店打开时隐藏（那时看钱袋 A）。
	var closed_money_btn := Button.new()
	_closed_money_bag = closed_money_btn
	closed_money_btn.flat = true
	closed_money_btn.focus_mode = Control.FOCUS_NONE
	closed_money_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	closed_money_btn.anchor_left = 0.5
	closed_money_btn.anchor_top = 1.0
	closed_money_btn.anchor_right = 0.5
	closed_money_btn.anchor_bottom = 1.0
	closed_money_btn.offset_left = -SHOP_BTN_SIZE.x * 0.5 - 8 - 60   # 商店按钮左边 8px 间隙，宽 60
	closed_money_btn.offset_right = -SHOP_BTN_SIZE.x * 0.5 - 8
	closed_money_btn.offset_top = -SHOP_BTN_SIZE.y - 40
	closed_money_btn.offset_bottom = -40
	closed_money_btn.z_index = 6
	center_host.add_child(closed_money_btn)
	var closed_bag_icon: Control = PrepMoneyBagIcon.new()
	closed_bag_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	closed_bag_icon.anchor_left = 0.5
	closed_bag_icon.anchor_top = 0.5
	closed_bag_icon.anchor_right = 0.5
	closed_bag_icon.anchor_bottom = 0.5
	closed_bag_icon.offset_left = -22
	closed_bag_icon.offset_top = -34
	closed_bag_icon.offset_right = 22
	closed_bag_icon.offset_bottom = 10
	closed_money_btn.add_child(closed_bag_icon)
	_closed_gold_label = Label.new()
	_closed_gold_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_closed_gold_label.anchor_left = 0.5
	_closed_gold_label.anchor_top = 0.5
	_closed_gold_label.anchor_right = 0.5
	_closed_gold_label.anchor_bottom = 0.5
	_closed_gold_label.offset_left = -30
	_closed_gold_label.offset_right = 30
	_closed_gold_label.offset_top = 12
	_closed_gold_label.offset_bottom = 40
	_closed_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_closed_gold_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_closed_gold_label.add_theme_font_size_override("font_size", 15)
	_closed_gold_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.34))
	_closed_gold_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_closed_gold_label.add_theme_constant_override("outline_size", 3)
	closed_money_btn.add_child(_closed_gold_label)
	# 长按看利息（短按不做事，纯金币显示）
	overlay.attach_long_press(closed_money_btn, func() -> void: overlay.show_gold_interest(format_gold_interest_detail()))



# 原 _build_shop_popup（PrepUI.gd）
# 商店外挂控件层、商店弹窗、钱袋 A。由 _build_rest 拆出（D2）。
# 原函数 638 行，全函数只有 2 处完全干净的切点 —— body 与 center_host
# 两个局部量跨越几乎整段。所以切点取在「除它们之外没有其它局部量跨越」处，
# 这些容器以参数传入（段内只读，不重新赋值）。
func build_popup(body: HBoxContainer, center_host: Control) -> void:

	# 商店「外挂控件层」：钱袋A（购买键）和刷新按钮挂这里，不再是商店面板的子节点。
	# 满屏 + IGNORE（空白处不吃点击），z=41 盖过宝藏(z-5)和商店面板(z40)；只在商店开时显示；
	# 点它里面的控件不会被判成"点商店外面"而误关店（PrepScreen._input 里有白名单）。
	side_controls = Control.new()
	side_controls.name = "ShopSideControls"
	side_controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	side_controls.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	side_controls.z_index = 41
	side_controls.visible = false
	host.add_child(side_controls)

	# 商店弹窗：卷轴背景，底部中央 896x288（SHOP_POPUP_SIZE），默认隐藏，点「商店」按钮打开
	var shop_panel := SellDropPanel.new()
	panel = shop_panel
	shop_panel.screen = self
	shop_panel.visible = false
	shop_panel.z_index = 40
	shop_panel.anchor_left = 0.5
	shop_panel.anchor_top = 1.0
	shop_panel.anchor_right = 0.5
	shop_panel.anchor_bottom = 1.0
	shop_panel.offset_left = -SHOP_POPUP_SIZE.x * 0.5
	shop_panel.offset_right = SHOP_POPUP_SIZE.x * 0.5
	shop_panel.offset_top = -SHOP_POPUP_SIZE.y - 8
	shop_panel.offset_bottom = -8
	shop_panel.custom_minimum_size = SHOP_POPUP_SIZE
	PrepWidgets.apply_transparent_panel_style(shop_panel)
	shop_panel.clip_contents = false
	center_host.add_child(shop_panel)
	var shop_background_host := Control.new()
	shop_background_host.name = "ShopBackgroundHost"
	shop_background_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shop_background_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shop_panel.add_child(shop_background_host)
	var shop_background := TextureRect.new()
	_shop_background = shop_background
	shop_background.name = "ShopPanelBackground"
	shop_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shop_background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shop_background.stretch_mode = TextureRect.STRETCH_SCALE   # 卷轴图(1672x941)拉伸到 SHOP_BG_SIZE，接受轻微变形
	# 居中于弹窗、独立尺寸：只由 SHOP_BG_SIZE / SHOP_BG_OFFSET 决定显示大小和位置，
	# 与弹窗判定框(SHOP_POPUP_SIZE)解耦；背景层 IGNORE 输入，改大改小都不影响判定。
	shop_background.anchor_left = 0.5
	shop_background.anchor_top = 0.5
	shop_background.anchor_right = 0.5
	shop_background.anchor_bottom = 0.5
	shop_background.offset_left = -SHOP_BG_SIZE.x * 0.5 + SHOP_BG_OFFSET.x
	shop_background.offset_right = SHOP_BG_SIZE.x * 0.5 + SHOP_BG_OFFSET.x
	shop_background.offset_top = -SHOP_BG_SIZE.y * 0.5 + SHOP_BG_OFFSET.y
	shop_background.offset_bottom = SHOP_BG_SIZE.y * 0.5 + SHOP_BG_OFFSET.y
	var shop_background_source := PrepWidgets.cached_texture(SHOP_PANEL_BACKGROUND_PATH)
	shop_background.texture = shop_background_source
	shop_background_host.add_child(shop_background)
	var shop_layout := Control.new()
	shop_layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shop_panel.add_child(shop_layout)
	# 钱袋A（购买键）：挂在外挂层 = 【屏幕坐标】，锚左下角。改这 4 个 offset 就能自由摆，
	# 不受商店面板范围限制，也不会被宝藏抢走点击（外挂层 z=41 在宝藏之上）。
	var gold_area := Control.new()
	gold_area.anchor_left = 0.0
	gold_area.anchor_top = 1.0
	gold_area.anchor_right = 0.0
	gold_area.anchor_bottom = 1.0
	gold_area.offset_left = 117
	gold_area.offset_right = 255
	gold_area.offset_top = -201
	gold_area.offset_bottom = -60
	side_controls.add_child(gold_area)
	var money_bag_glow := PrepMoneyBagAttentionGlowScript.new()
	money_bag_glow.anchor_left = 0.5
	money_bag_glow.anchor_top = 0.5
	money_bag_glow.anchor_right = 0.5
	money_bag_glow.anchor_bottom = 0.5
	money_bag_glow.offset_left = -75
	money_bag_glow.offset_top = -81
	money_bag_glow.offset_right = 75
	money_bag_glow.offset_bottom = 69
	gold_area.add_child(money_bag_glow)
	money_bag_glow.setup(
		PrepWidgets.cached_texture("res://assets/ui/buttons/btn_buy_lowpoly.png"),
		MONEY_BAG_GLOW_SHADER
	)
	var money_bag: Control = PrepMoneyBagIcon.new()
	money_bag.set("use_lowpoly_texture", true)
	money_bag.anchor_left = 0.5
	money_bag.anchor_top = 0.5
	money_bag.anchor_right = 0.5
	money_bag.anchor_bottom = 0.5
	money_bag.offset_left = -58
	money_bag.offset_top = -64
	money_bag.offset_right = 58
	money_bag.offset_bottom = 52
	gold_area.add_child(money_bag)
	_gold_amount_label = Label.new()
	_gold_amount_label.anchor_left = 0.5
	_gold_amount_label.anchor_top = 0.5
	_gold_amount_label.anchor_right = 0.5
	_gold_amount_label.anchor_bottom = 0.5
	_gold_amount_label.offset_left = -44
	_gold_amount_label.offset_right = 44
	_gold_amount_label.offset_top = 10
	_gold_amount_label.offset_bottom = 38
	_gold_amount_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gold_amount_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_gold_amount_label.pivot_offset = Vector2(44, 14)
	_gold_amount_label.rotation_degrees = -4.0
	_gold_amount_label.add_theme_font_override("font", GOLD_NUMBER_FONT)
	_gold_amount_label.add_theme_font_size_override("font_size", 24)
	_gold_amount_label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.30))
	_gold_amount_label.add_theme_color_override("font_outline_color", Color(0.20, 0.08, 0.01, 0.98))
	_gold_amount_label.add_theme_constant_override("outline_size", 3)
	gold_area.add_child(_gold_amount_label)
	var buy_action_label := Label.new()
	buy_action_label.text = tr("ui_buy")
	buy_action_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	buy_action_label.anchor_left = 0.5
	buy_action_label.anchor_top = 0.5
	buy_action_label.anchor_right = 0.5
	buy_action_label.anchor_bottom = 0.5
	buy_action_label.offset_left = -52
	buy_action_label.offset_top = 49
	buy_action_label.offset_right = 52
	buy_action_label.offset_bottom = 75
	buy_action_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	buy_action_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	buy_action_label.add_theme_font_size_override("font_size", 19)
	buy_action_label.add_theme_color_override("font_color", Color(1.0, 0.94, 0.72))
	buy_action_label.add_theme_color_override("font_outline_color", Color(0.12, 0.04, 0.01, 0.98))
	buy_action_label.add_theme_constant_override("outline_size", 4)
	gold_area.add_child(buy_action_label)
	var gold_info_btn := Button.new()
	buy_button = gold_info_btn
	gold_info_btn.flat = true
	gold_info_btn.focus_mode = Control.FOCUS_NONE
	gold_info_btn.modulate = Color(1, 1, 1, 0)
	gold_info_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	gold_info_btn.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	gold_area.add_child(gold_info_btn)
	# 钱袋 A（商店内）：短按=购买选中的卡（没选卡时 buy_selected 直接返回）；长按=看利息
	gold_info_btn.pressed.connect(func() -> void:
		if bool(gold_info_btn.get_meta("long_press_triggered", false)):
			return
		buy_selected())
	overlay.attach_long_press(gold_info_btn, func() -> void: overlay.show_gold_interest(format_gold_interest_detail()))
	# 手牌区：4 张随机棋子卡，横排居中在卷轴空白区。
	# 卡片层级（从底到顶）：头像 → 稀有度框（tier 换图） → 左上种族 logo → 右上价格（框自带金币） → 底部铭牌名字 → 灰色不可买覆盖层
	var shop_card_area := Control.new()
	shop_card_area.anchor_left = 0.0
	shop_card_area.anchor_top = 0.10
	shop_card_area.anchor_right = 1.0
	shop_card_area.anchor_bottom = 0.92
	shop_layout.add_child(shop_card_area)
	row = HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", SHOP_CARD_SEPARATION)
	shop_card_area.add_child(row)



# 原 _build_shop_hand_cards（PrepUI.gd）
# 手牌区：4 张随机棋子卡。由 _build_rest 拆出（D2）。
# 原函数 638 行，全函数只有 2 处完全干净的切点 —— body 与 center_host
# 两个局部量跨越几乎整段。所以切点取在「除它们之外没有其它局部量跨越」处，
# 这些容器以参数传入（段内只读，不重新赋值）。
func build_hand_cards(body: HBoxContainer, center_host: Control) -> void:
	for i in GameState.SHOP_UNIT_SLOTS:
		var slot := DragButton.new()
		slot.drag_owner = self
		slot.custom_minimum_size = SHOP_CARD_SIZE
		slot.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		slot.clip_contents = false
		slot.pressed.connect(_on_card_pressed.bind(slot, i))
		overlay.attach_long_press(slot, func(): detail_requested.emit(i))
		PrepWidgets.configure_unframed_portrait_card(slot, hover_handler)
		row.add_child(slot)
		buttons.append(slot)

		# 头像：先加（画在框下面），稍微伸进框梁内侧，由框盖住毛边
		var portrait := TextureRect.new()
		portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
		portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		portrait.anchor_left = 0.09
		portrait.anchor_top = 0.07
		portrait.anchor_right = 0.91
		portrait.anchor_bottom = 0.80
		slot.add_child(portrait)
		portraits.append(portrait)

		# 稀有度框：刷新时按棋子 tier 换普通/稀有/史诗贴图
		var card_frame := TextureRect.new()
		card_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card_frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		card_frame.stretch_mode = TextureRect.STRETCH_SCALE
		card_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		slot.add_child(card_frame)
		card_frames.append(card_frame)

		# 左上角种族 logo（复用详情弹窗的静态 logo 控件）
		var race_icon: Control = PrepShopRaceIcon.new()
		race_icon.anchor_left = 0.02
		race_icon.anchor_top = 0.02
		race_icon.anchor_right = 0.26
		race_icon.anchor_bottom = 0.26
		race_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(race_icon)
		race_icons.append(race_icon)

		# 右上角价格：写在框自带的金币圆牌上（金币是亮金色，用深棕字不加描边）
		var price_label := Label.new()
		price_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		price_label.anchor_left = 0.75
		price_label.anchor_top = 0.02
		price_label.anchor_right = 0.98
		price_label.anchor_bottom = 0.23
		price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		price_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		price_label.pivot_offset = Vector2(14, 11)
		price_label.rotation_degrees = -5.0
		price_label.add_theme_font_override("font", GOLD_NUMBER_FONT)
		price_label.add_theme_font_size_override("font_size", 22)
		price_label.add_theme_color_override("font_color", Color(0.28, 0.16, 0.02))
		price_label.add_theme_color_override("font_outline_color", Color(1.0, 0.77, 0.20, 0.55))
		price_label.add_theme_constant_override("outline_size", 1)
		slot.add_child(price_label)
		price_labels.append(price_label)

		# 底部铭牌：棋子名字（切英文时自动显示英文名）
		var name_label := Label.new()
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_label.anchor_left = 0.14
		name_label.anchor_top = 0.76
		name_label.anchor_right = 0.86
		name_label.anchor_bottom = 0.95
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.clip_text = true
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_label.add_theme_font_size_override("font_size", 16)
		name_label.add_theme_color_override("font_color", Color(0.94, 0.90, 0.80))
		name_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
		name_label.add_theme_constant_override("outline_size", 3)
		slot.add_child(name_label)
		card_labels.append(name_label)

		var reason_label := _create_purchase_reason_overlay(slot)
		reason_labels.append(reason_label)




# 原 _refresh_shop（PrepUI.gd）

func refresh() -> void:
	var gold_text := TutorialMode.GOLD_TEXT if GameState.tutorial_mode else tr("ui_gold_format") % GameState.gold
	if _gold_amount_label != null:
		_gold_amount_label.text = TutorialMode.GOLD_TEXT if GameState.tutorial_mode else str(GameState.gold)
	if _closed_gold_label != null:
		_closed_gold_label.text = gold_text
	overlay.refresh_gold_interest(format_gold_interest_detail())
	if refresh_button != null:
		var all_free := TreasureService.has_set("money")
		var refresh_cost := EconomyService.shop_refresh_cost(GameState.shop_refresh_uses_this_round, all_free)
		refresh_button.disabled = GameState.gold < refresh_cost
		refresh_icon.modulate = Color(0.46, 0.46, 0.46) if refresh_button.disabled else Color.WHITE
		refresh_cost_label.text = tr("ui_free") if refresh_cost == 0 else str(refresh_cost)
		if refresh_cost == 0:
			refresh_cost_label.remove_theme_font_override("font")
			refresh_cost_label.add_theme_font_size_override("font_size", 14)
			refresh_cost_label.rotation_degrees = 0.0
		else:
			refresh_cost_label.add_theme_font_override("font", GOLD_NUMBER_FONT)
			refresh_cost_label.add_theme_font_size_override("font_size", 20)
			refresh_cost_label.rotation_degrees = -4.0
		refresh_cost_label.modulate = Color(0.46, 0.46, 0.46) if refresh_button.disabled else Color.WHITE
	var selected_valid: bool = (
		selected >= 0
		and selected < GameState.shop_offers.size()
		and not GameState.shop_offers[selected].is_empty()
		and not bool(GameState.shop_sold[selected])
	)
	if not selected_valid:
		selected = -1
	var offer_identity: Array = []
	for offer_entry in GameState.shop_offers:
		# Name is part of the cache identity too. This matters when the same unit id
		# survives a refresh while an old server/save display name is canonicalized.
		offer_identity.append([
			str((offer_entry as Dictionary).get("id", "")),
			DataRegistry.unit_display_name(offer_entry as Dictionary, LocaleManager.get_locale() == "en"),
		])
	var cards_sig := JSON.stringify([
		offer_identity,
		GameState.shop_sold,
		GameState.gold,
		selected,
		PrepRules.first_empty_bench_slot() < 0,
		GameState.tutorial_mode,
		LocaleManager.get_locale(),
		# 宝物持有变了要立刻重算价格（折扣令牌 / 狂怒+折扣清仓联动），
		# 否则签名命中旧值，refresh 提前返回，新折扣要等下次刷新商店才生效。
		GameState.owned_treasures,
	])
	if cards_sig == _shop_cards_signature:
		return
	_shop_cards_signature = cards_sig
	for i in buttons.size():
		var btn := buttons[i]
		var portrait := portraits[i]
		var card_frame := card_frames[i]
		var name_label := card_labels[i]
		var price_label := price_labels[i]
		var race_icon := race_icons[i]
		var reason_label := reason_labels[i]
		var offer: Dictionary = GameState.shop_offers[i]
		if offer.is_empty():
			btn.text = ""
			btn.set_meta("drag_preview_text", "")
			btn.disabled = true
			btn.drag_payload = {}
			portrait.texture = null
			portrait.visible = false
			card_frame.visible = false
			name_label.text = tr("ui_empty_slot")
			price_label.text = ""
			race_icon.visible = false
			_set_purchase_reason(reason_label, tr("ui_no_item"))
			btn.modulate = Color.WHITE
			continue
		var sold := bool(GameState.shop_sold[i])
		var cost := EconomyLedger.unit_cost(offer, GameState.owned_treasures)
		var can_purchase := not sold and GameState.gold >= cost
		var unit_name := DataRegistry.unit_display_name(offer, LocaleManager.get_locale() == "en")
		btn.disabled = false
		btn.text = ""
		btn.set_meta("drag_preview_text", "%s\n%s" % [unit_name, tr("ui_gold_format") % cost])
		portrait.texture = PrepWidgets.cached_texture("%s/%s.png" % [UNIT_PORTRAIT_DIR, str(offer.get("id", ""))])
		portrait.visible = portrait.texture != null
		card_frame.visible = true
		card_frame.texture = PrepWidgets.cached_texture(str(SHOP_CARD_FRAME_PATHS.get(int(offer.get("tier", 1)), SHOP_CARD_FRAME_PATHS[1])))
		name_label.text = unit_name
		price_label.text = str(cost)   # 金币图案已画死在框右上角，只写数字
		race_icon.visible = true
		race_icon.call("set_race", str(offer.get("race", "")))
		btn.drag_payload = {} if GameState.tutorial_mode else ({"kind": "shop", "index": i} if can_purchase else {})
		var purchase_reason := _purchase_reason(i)
		_set_purchase_reason(reason_label, purchase_reason)
		btn.modulate = Color(0.52, 0.64, 0.72, 0.92) if purchase_reason.is_empty() and i == selected else Color.WHITE


# 原 _refresh_shop_picker（PrepUI.gd）

func _refresh_picker() -> void:
	if panel != null:
		panel.visible = picker_open
	if _shop_scroll_idle != null:
		_shop_scroll_idle.set_effect_active(not picker_open)
	if side_controls != null:
		side_controls.visible = picker_open     # 外挂层（钱袋A+刷新）跟商店一起显隐
	if _closed_money_bag != null:
		_closed_money_bag.visible = not picker_open   # 商店关时才显示钱袋 B
	# 商店开着时待命格子被商店盖住，要禁用它们的输入，别去抢商店区域的点击。
	# 但待命格属于**棋盘面板**，商店不该伸手去改别人的控件 —— 发信号，宿主去调。
	picker_toggled.emit(picker_open)


# 原 _toggle_shop_picker（PrepUI.gd）

func toggle_picker() -> void:
	picker_open = not picker_open
	# 打开商店要关掉佣兵与队伍佣兵弹窗 —— 同样由宿主协调，见 picker_toggled。
	_refresh_picker()


# 原 _close_shop_picker（PrepUI.gd）
func close_picker() -> void:
	if not picker_open:
		return
	picker_open = false
	_refresh_picker()

# 原 _on_shop_pressed（PrepBoardController.gd）

func _on_card_selected(index: int) -> void:
	if index < 0 or index >= GameState.shop_offers.size() or bool(GameState.shop_sold[index]):
		return
	selected = index
	# 棋盘与待命的选中态归它们自己管，商店只宣布「我选中了第几张」。
	card_selected.emit(index)


# 原 _on_shop_card_pressed（PrepUI.gd）

func _on_card_pressed(card: BaseButton, index: int) -> void:
	if bool(card.get_meta("long_press_triggered", false)):
		return
	_on_card_selected(index)


# 原 _shop_purchase_reason（PrepUI.gd）

func _purchase_reason(index: int) -> String:
	if index < 0 or index >= GameState.shop_offers.size():
		return tr("ui_cannot_buy")
	var offer: Dictionary = GameState.shop_offers[index]
	if offer.is_empty():
		return tr("ui_no_item")
	if bool(GameState.shop_sold[index]):
		return tr("ui_sold")
	if GameState.gold < EconomyLedger.unit_cost(offer, GameState.owned_treasures):
		return tr("ui_not_enough_gold")
	if PrepRules.first_empty_bench_slot() < 0:
		return tr("ui_bench_full")
	return ""


# 原 _on_buy_selected_shop（PrepBoardController.gd）
func buy_selected() -> void:
	if selected < 0 or selected >= GameState.shop_offers.size():
		return
	var offer: Dictionary = GameState.shop_offers[selected]
	if offer.is_empty() or bool(GameState.shop_sold[selected]):
		return
	# 买不了时给提示（原推车按钮的 tooltip 逻辑搬过来）
	if GameState.gold < EconomyLedger.unit_cost(offer, GameState.owned_treasures):
		message_requested.emit(tr("ui_not_enough_gold"))
		return
	var empty_bench := PrepRules.first_empty_bench_slot()
	if empty_bench < 0:
		message_requested.emit(tr("ui_bench_full"))
		return
	buy_requested.emit(selected)


# 原 _format_gold_interest_detail（PrepUI.gd）

func format_gold_interest_detail() -> String:
	var gold := maxi(0, GameState.gold)
	var base_interest := EconomyService.base_interest(gold)
	var money_compound_bonus := 0
	if GameState.owned_treasures.has("money_compound"):
		money_compound_bonus = int(floor(float(gold) * 0.05))
	var pet_interest_bonus := EconomyService.pet_interest_bonus(gold, PlayerProfile.get_active())
	var total_interest := base_interest + money_compound_bonus + pet_interest_bonus
	var is_en := TranslationServer.get_locale().begins_with("en")
	var lines: Array[String] = []
	if is_en:
		lines.append("Current gold: %d" % gold)
		lines.append("Interest: +%d" % total_interest)
	else:
		lines.append("当前金币：%d" % gold)
		lines.append("利息：+%d" % total_interest)
	return "\n".join(lines)


# 原 _create_purchase_reason_overlay（PrepUI.gd）
func _create_purchase_reason_overlay(card: Control) -> Label:
	var dimmer := ColorRect.new()
	dimmer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dimmer.visible = false
	dimmer.color = Color(0.015, 0.02, 0.025, 0.64)
	dimmer.z_index = 29
	dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	card.add_child(dimmer)
	var overlay := PanelContainer.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.visible = false
	overlay.z_index = 30
	overlay.anchor_left = 0.08
	overlay.anchor_top = 0.35
	overlay.anchor_right = 0.92
	overlay.anchor_bottom = 0.65
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.015, 0.018, 0.92)
	style.border_color = Color(1.0, 0.34, 0.24, 0.96)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	overlay.add_theme_stylebox_override("panel", style)
	card.add_child(overlay)
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.72))
	label.add_theme_color_override("font_outline_color", Color(0.05, 0.0, 0.0, 1.0))
	label.add_theme_constant_override("outline_size", 4)
	overlay.add_child(label)
	label.set_meta("purchase_dimmer", dimmer)
	return label


# 原 _set_purchase_reason（PrepUI.gd）
func _set_purchase_reason(label: Label, reason: String) -> void:
	label.text = reason
	var overlay := label.get_parent() as Control
	if overlay != null:
		overlay.visible = not reason.is_empty()
	if label.has_meta("purchase_dimmer"):
		var dimmer := label.get_meta("purchase_dimmer") as ColorRect
		if dimmer != null:
			dimmer.visible = not reason.is_empty()
