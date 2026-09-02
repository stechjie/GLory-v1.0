extends "res://scenes/prep/PrepBoardModels.gd"

# PrepDetails 的宝物说明里也要画种族 logo，所以这个 preload 留在链上；
# 商店面板自己也 preload 了一份 —— 两个文件各自声明依赖，指向同一个脚本，不是重复逻辑。
const PrepShopRaceIcon = preload("res://scenes/prep/PrepShopRaceIcon.gd")

const PrepShopRefreshBurnScript = preload("res://scenes/prep/effects/PrepShopRefreshBurn.gd")
const PrepTeamMercAlertScript = preload("res://scenes/prep/effects/PrepTeamMercAlert.gd")
const TutorialTargetProviderScript := preload("res://scripts/tutorial/TutorialTargetProvider.gd")
# 只为拿 FillPhase 枚举做**静态**引用（教学第 15 步的子阶段），
# 走 preload 常量而不是从 autoload 实例上取，dynamic_call 棘轮才不会长。
const TutorialModeScript := preload("res://scripts/tutorial/TutorialMode.gd")
const SHOP_SCROLL_BURN_SHADER: Shader = preload("res://assets/shaders/prep_scroll_burn.gdshader")
const SHOP_REFRESH_WIDTH := 112.0
const SHOP_GOLD_WIDTH := 112.0
const SHOP_POPUP_OFFSET := Vector2(0, 7)     # 商店弹窗判定框中心的平移（正 x 右移、正 y 下移）
const HP_FRAME_EMPTY_PATH := "res://assets/ui/buttons/btn_hp_empty.png"   # 血条石框（深色空槽）
const HP_FRAME_RED_PATH := "res://assets/ui/buttons/btn_hp_red.png"       # 血条红条填充贴图
const HP_FRAME_SIZE := Vector2(246, 82)                                   # 高清框 2172x724，比例 3.0
const START_BTN_PATH := "res://assets/ui/buttons/btn_start.png"           # 开始战斗木牌框（高清透明）
const START_BTN_SIZE := Vector2(240, 80)                                  # 比例 3.0
const STATS_BTN_PATH := "res://assets/ui/buttons/btn_stats.png"           # 统计/战力石板框（高清透明）
const STATS_BTN_SIZE := Vector2(140, 94)                                  # 比例 1.5
const REFRESH_BTN_PATH := "res://assets/ui/buttons/btn_refresh_fire_lowpoly.png"
const MERC_BTN_PATH := "res://assets/ui/buttons/btn_merc_lowpoly.png"
const TEAM_MERCS_BTN_PATH := "res://assets/ui/buttons/btn_team_mercs_lowpoly.png"
const TEAM_MERCS_STAGE_BACKGROUND_PATH := "res://assets/ui/prep/team_mercs_stage.png"
const MERC_BTN_SIZE := Vector2(132, 132)                                  # 方形
const SHOP_REFRESH_FIRE_ATLAS_PATH := "res://assets/vfx/prep/scroll_edge_fire_atlas.png"
const TEAM_MERC_ALERT_ATLAS_PATH := "res://assets/vfx/prep/team_merc_crossed_swords_atlas.png"
const CRYSTAL_FIRE_PATHS := [                 # 火队（slot 0-2 红蓝绿）红水晶：按血量段 0-10..40-50
	"res://assets/ui/crystals/red_0_10.png",
	"res://assets/ui/crystals/red_10_20.png",
	"res://assets/ui/crystals/red_20_30.png",
	"res://assets/ui/crystals/red_30_40.png",
	"res://assets/ui/crystals/red_40_50.png",
]
const CRYSTAL_WATER_PATHS := [                # 水队（slot 3-5 黄紫橙）蓝水晶
	"res://assets/ui/crystals/blue_0_10.png",
	"res://assets/ui/crystals/blue_10_20.png",
	"res://assets/ui/crystals/blue_20_30.png",
	"res://assets/ui/crystals/blue_30_40.png",
	"res://assets/ui/crystals/blue_40_50.png",
]
const TOP_ROW_BTN_SIZE := Vector2(96, 64)                                 # 右上角横排三键（战力/统计/静音）缩小尺寸
# 调试：把所有按钮的点击判定区域用线条画出来。不需要时改成 false。
const SHOW_HIT_AREAS := false
# 调试：把所有布局控件的矩形（空间框）用黑边画出来，方便看排版。不需要时改成 false。
const SHOW_SPACE_FRAMES := false
# 「队伍佣兵」弹窗 3D 检阅台。缩放/相机抄备战河流视口的量级，取景不对就调这几个。
# AREA_HALF / MIN_DIST 是 stage root 本地坐标（stage 再被 STAGE_SCALE 放大）。
const TEAM_MERCS_STAGE_SCALE := 3.2
const TEAM_MERCS_CAMERA_POSITION := Vector3(0.0, 2.4, 1.9)
const TEAM_MERCS_CAMERA_TARGET := Vector3(0.0, 0.05, 0.0)
const TEAM_MERCS_CAMERA_FOV := 40.0
const TEAM_MERCS_AREA_HALF := Vector2(0.42, 0.24)
const TEAM_MERCS_MIN_DIST := 0.15
const TEAM_MERCS_PLATE_RADIUS := 0.055
const TEAM_MERCS_PLATE_HEIGHT := 0.012
const TREASURE_LOGO_DIRECTORY := "res://assets/ui/treasure_logos"
const TREASURE_LINKAGE_LOGOS := {
	"link_phoenix": "凤凰涅槃",
	"link_money_magic": "金钱魔法",
	"link_blood_covenant": "血之契约",
	"link_paralysis_shackles": "瘫痪枷锁",
	"link_oppression_counter": "压迫反击",
	"link_fraud_fate": "诡诈命运",
	"link_iron_maiden": "铁处女",
	"link_toxic_burst": "剧毒爆发",
	"link_rich_path": "富裕之路",
	"link_clearance_sale": "清仓特卖",
	"link_hu_pai_master": "胡牌手",
}
const PVP_WARNING_FRAME_PATH := "res://assets/ui/pvp_warning_frame.png"
# 稳定 id：同 id 重复 push 会被 ModalStack 拒绝，这就是 2 秒内重复触发的去重机制。
const PVP_WARNING_MODAL_ID := "pvp_warning"
# 优先级阶梯：60 警告 < 80 开始战斗加载（PrepScreen.BATTLE_LOADING_MODAL_PRIORITY）
# < 100 确认框（DialogService.MODAL_PRIORITY）。
# 警告是纯播报、没有任何决策；加载层带阶段/重试/返回，确认框要玩家选边。
# 两者同时在栈上时，能操作的那个必须在上面，所以警告取最低的 60。
const PVP_WARNING_MODAL_PRIORITY := 60
# 组队佣兵检阅台（C-11 的 C4）。priority 40：低于 pvp_warning 60 < 战斗加载 80
# < 确认框 100 —— 检阅台是纯展示，任何带决策的层都该压在它上面。
const TEAM_MERCS_MODAL_ID := "team_mercs_review"
const TEAM_MERCS_MODAL_PRIORITY := 40
# 普通佣兵选择层（C-11 的 C3）。与检阅台同为备战普通面板，取同一档 40 ——
# 两者互斥（开一个必关另一个），永远不会同时在栈上，同优先级不产生歧义。
const MERC_PICKER_MODAL_ID := "mercenary_picker"
const MERC_PICKER_MODAL_PRIORITY := 40
const PVP_WARNING_DWELL_SEC := 2.0
const PVP_WARNING_FADE_SEC := 0.18

var _team_mercs_button: Button
var _team_merc_alert
var _team_merc_counts_snapshot: Dictionary = {}
# 迁进 ModalStack 后 content 不再是 center_host 的子节点，失去了自动跟随布局的能力。
# 记住宿主，开合与尺寸变化时把 content 钉回它的屏幕矩形，视觉才和迁移前一致。
var _team_mercs_host: Control
var _team_merc_snapshot_round := -1
var _team_merc_snapshot_initialized := false
var _tutorial_target_provider: TutorialTargetProviderScript

const MERCENARY_PORTRAIT_PATHS := {
	"merc_pisces_bubble": "res://assets/ui/mercenary_portraits/merc_pisces_bubble.png",
	"merc_cancer_shell": "res://assets/ui/mercenary_portraits/merc_cancer_shell.png",
	"merc_libra_judge": "res://assets/ui/mercenary_portraits/merc_libra_judge.png",
	"merc_taurus_charge": "res://assets/ui/mercenary_portraits/merc_taurus_charge.png",
	"merc_virgo_heal": "res://assets/ui/mercenary_portraits/merc_virgo_heal.png",
	"merc_gemini_assassin": "res://assets/ui/mercenary_portraits/merc_gemini_assassin.png",
	"merc_leo_sun": "res://assets/ui/mercenary_portraits/merc_leo_sun.png",
	"merc_sagittarius_rain": "res://assets/ui/mercenary_portraits/merc_sagittarius_rain.png",
	"merc_aries_blood": "res://assets/ui/mercenary_portraits/merc_aries_blood.png",
	"merc_capricorn_steel": "res://assets/ui/mercenary_portraits/merc_capricorn_steel.png",
	"merc_aquarius_time": "res://assets/ui/mercenary_portraits/merc_aquarius_time.png",
	"merc_scorpio_death": "res://assets/ui/mercenary_portraits/merc_scorpio_death.png",
}

var _mute_button: Button
var _shop_refresh_burn: PrepShopRefreshBurn
# 强引用贴图缓存：load() 只在资源仍被引用时命中引擎缓存，
# 这里持有引用保证商店头像/宝物图标等反复刷新的贴图零重复 I/O。
# static：PrepScreen 每回合都被 Main 重建，缓存必须跨实例存活。
# 增量刷新签名：_refresh_all 每次操作都会全量调用各分区刷新，
# 签名没变的分区直接跳过重建。签名必须覆盖该分区渲染的全部数据，漏字段 = UI 不刷新。
var _owned_logos_signature := "unset"
var _merc_overlay_signature := "unset"
# 棋盘 caption 位置（待命的不受影响）：
# DROP=相对格子底往下的【比例】（用格子高度比例、不是固定像素，才能补透视——不同排格子大小不同，
#   固定像素会"越往上越偏"）。负=往上、正=往下；太高调大、太低调小。
# DX =左右【像素】偏移：正=右移、负=左移。
const BOARD_CAPTION_DROP := 0.5
const BOARD_CAPTION_DX := 0


# TutorialMode must not know this screen's private fields. Prep composes the one
# runtime adapter here, where ShopPanel/BoardHud/etc. are statically typed.
func tutorial_target_provider() -> TutorialTargetProviderScript:
	if _tutorial_target_provider != null:
		return _tutorial_target_provider
	var provider: TutorialTargetProviderScript = TutorialTargetProviderScript.new(
		"PrepScreen", self)
	provider.bind_target(TutorialTargetProviderScript.TARGET_BUY_UNIT,
		_tutorial_target_buy_unit)
	provider.bind_target(TutorialTargetProviderScript.TARGET_PLACE_UNIT,
		_tutorial_target_place_unit)
	provider.bind_target(TutorialTargetProviderScript.TARGET_UPGRADE_UNIT,
		_tutorial_target_upgrade_unit)
	provider.bind_target(TutorialTargetProviderScript.TARGET_START_BATTLE,
		_tutorial_target_start_battle)
	provider.bind_target(TutorialTargetProviderScript.TARGET_FORMATION_HP,
		_tutorial_target_formation_hp)
	provider.bind_target(TutorialTargetProviderScript.TARGET_TREASURE_CHOICE,
		_tutorial_target_treasure_choice)
	provider.bind_target(TutorialTargetProviderScript.TARGET_HIRE_MERCENARY,
		_tutorial_target_hire_mercenary)
	provider.bind_target(TutorialTargetProviderScript.TARGET_FILL_SEVEN,
		_tutorial_target_fill_seven)
	provider.bind_target(TutorialTargetProviderScript.TARGET_BOND_ROW,
		_tutorial_target_bond_row)
	provider.bind_target(TutorialTargetProviderScript.TARGET_TREASURE_LOGO,
		_tutorial_target_treasure_logo)
	provider.bind_action(TutorialTargetProviderScript.ACTION_CLOSE_MERCENARY,
		_close_merc_picker)
	provider.bind_action(TutorialTargetProviderScript.ACTION_REFRESH_VIEW,
		_tutorial_refresh_view)
	provider.bind_feedback(show_message)
	# V2 P1-09：教程气泡不得压住这几块。走 provider 的可选合同，
	# 让 TutorialMode 不必再认识备战页的私有字段（那正是 P1-10 拆掉的耦合）。
	provider.bind_keep_clear(_tutorial_keep_clear_rects)
	_tutorial_target_provider = provider
	return provider


# 开始战斗按钮、商店入口、待命区整排、宝藏刷新按钮 —— 气泡压住任何一块，
# 玩家都会卡在「看得见提示但点不到东西」的状态。
func _tutorial_keep_clear_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	for control in [
		_start_battle_button,
		_merc_button,
		_shop.open_button if _shop != null else null,
		_treasure._treasure_refresh_btn if _treasure != null else null,
	]:
		_append_visible_rect(control as Control, out)
	if _board_hud != null:
		# 待命区按整排算一个矩形：逐格加进去会让评分被格数放大。
		var bench := Rect2()
		var has_bench := false
		for button in _board_hud.bench_buttons:
			var control := button as Control
			if control == null or not is_instance_valid(control) or not control.is_visible_in_tree():
				continue
			bench = control.get_global_rect() if not has_bench else bench.merge(control.get_global_rect())
			has_bench = true
		if has_bench:
			out.append(bench)
	return out


func _append_visible_rect(control: Control, out: Array[Rect2]) -> void:
	if control == null or not is_instance_valid(control) or not control.is_visible_in_tree():
		return
	var rect := control.get_global_rect()
	if rect.size.x > 0.0 and rect.size.y > 0.0:
		out.append(rect)


func release_tutorial_target_provider() -> void:
	if _tutorial_target_provider == null:
		return
	_tutorial_target_provider.release()
	_tutorial_target_provider = null


func _tutorial_target_buy_unit() -> Control:
	return _tutorial_shop_purchase_target()


func _tutorial_target_place_unit() -> Control:
	if _tutorial_placing_from_bench():
		return _tutorial_first_empty_board_middle()
	return _tutorial_first_occupied_bench()


func _tutorial_target_upgrade_unit() -> Control:
	return _tutorial_shop_purchase_target()


func _tutorial_target_start_battle() -> Control:
	return _start_battle_button


func _tutorial_target_formation_hp() -> Control:
	return _enemy_formation_art


func _tutorial_target_treasure_choice() -> Control:
	# 三选一层迁进 ModalStack 后（C-11 的 C2），这一行是每次开合都会被销毁重建的
	# 瞬时节点，所以除了 null 还要判有效性 —— 绝不能把已释放的实例交给教程去高亮。
	var row: Control = _treasure._treasure_choice_row
	if row != null and is_instance_valid(row):
		if row.get_child_count() > 0:
			return row.get_child(0) as Control
		return row
	# 层关着时它根本不在树上。迁移前这里能返回那个常驻的空 HBox，现在没有了，
	# 于是退回同为宝物区、且页面常驻的已持有 logo 栏 —— 教程的取宝步只在这一层
	# 开着时才会问这个目标，所以兜底值不会真的被拿去高亮，但它必须是个有效 Control：
	# tutorial_target_check 要求每个语义目标在实屏上都解析得出来。
	return _treasure._owned_treasure_box


func _tutorial_target_hire_mercenary() -> Control:
	if not _merc_picker_open:
		return _merc_button
	# content 现在每次开合都会被 ModalStack 销毁重建，所以除了 null 还要判有效性 ——
	# 绝不能把一个已释放的实例交给教程去高亮。
	if (_merc_overlay_grid != null and is_instance_valid(_merc_overlay_grid)
			and _merc_overlay_grid.get_child_count() > 0):
		return _merc_overlay_grid.get_child(0) as Control
	return _merc_button


func _tutorial_target_fill_seven() -> Control:
	# 三个子阶段各指各的目标（V2 P1-07）。阶段由 TutorialMode 的显式状态给出，
	# 不再靠「拥有数 > 上阵数」反推 —— 那个反推在「买够了但还没关商店」时会
	# 直接把箭头甩到待命区，而那时候待命格还被商店盖着、点不到。
	match TutorialMode.fill_phase():
		TutorialModeScript.FillPhase.BUY:
			return _tutorial_shop_purchase_target()
		TutorialModeScript.FillPhase.CLOSE_SHOP:
			# 商店按钮本身就是开合开关，关闭时要指的还是它。
			return _shop.open_button
		_:
			if _tutorial_placing_from_bench():
				return _tutorial_first_empty_board()
			return _tutorial_first_occupied_bench()


func _tutorial_target_bond_row() -> Control:
	var panel: Control = _synergy._left_panel
	if panel == null:
		return null
	for child in panel.get_children():
		if child is HBoxContainer and (child as Control).visible:
			return child as Control
	return panel


func _tutorial_target_treasure_logo() -> Control:
	var box: Control = _treasure._owned_treasure_box
	if box != null and box.get_child_count() > 0 and box.get_child(0) is Control:
		return box.get_child(0) as Control
	return box


func _tutorial_shop_purchase_target() -> Control:
	if not _shop.picker_open:
		return _shop.open_button
	if _tutorial_shop_index_available(_shop.selected):
		return _shop.buy_button
	return _tutorial_first_available_shop()


func _tutorial_first_available_shop() -> Control:
	for i in _shop.buttons.size():
		if _tutorial_shop_index_available(i):
			var button := _shop.buttons[i] as Control
			if button != null and button.visible:
				return button
	return null


func _tutorial_shop_index_available(index: int) -> bool:
	if index < 0 or index >= GameState.shop_offers.size() \
			or index >= GameState.shop_sold.size():
		return false
	if bool(GameState.shop_sold[index]):
		return false
	var offer: Variant = GameState.shop_offers[index]
	return typeof(offer) == TYPE_DICTIONARY and not (offer as Dictionary).is_empty()


func _tutorial_first_occupied_bench() -> Control:
	for i in _board_hud.bench_buttons.size():
		if i < GameState.bench_slots.size() and GameState.bench_slots[i] != null:
			var button := _board_hud.bench_buttons[i] as Control
			if button != null and button.visible:
				return button
	return null


func _tutorial_first_empty_board() -> Control:
	for i in _board_hud.buttons.size():
		if i < GameState.board_slots.size() and GameState.board_slots[i] == null:
			var button := _board_hud.buttons[i] as Control
			if button != null and button.visible:
				return button
	return null


func _tutorial_first_empty_board_middle() -> Control:
	for preferred_row in [2, 1]:
		for column in GameConstants.BOARD_COLUMNS:
			var index: int = int(preferred_row) * GameConstants.BOARD_COLUMNS + column
			if index >= _board_hud.buttons.size() or index >= GameState.board_slots.size():
				continue
			if GameState.board_slots[index] == null:
				var button := _board_hud.buttons[index] as Control
				if button != null and button.visible:
					return button
	return _tutorial_first_empty_board()


func _tutorial_placing_from_bench() -> bool:
	if _board_hud._selected_bench >= 0:
		return true
	return str(_active_drag_payload.get("kind", "")) == "bench"


func _tutorial_owned_normal_count() -> int:
	var count := 0
	for cell in GameState.board_slots + GameState.bench_slots:
		if typeof(cell) == TYPE_DICTIONARY:
			count += 1
	return count


func _tutorial_refresh_view() -> void:
	_refresh_all.call_deferred()


func _build() -> void:
	# 面板的依赖与信号必须在**构建之前**接好：build_* 里会用到 overlay 与 host，
	# 也会把按钮的 pressed 连到面板自己的方法上。放到末尾接的话，
	# 构建期 overlay 还是 null —— 表现是长按详情静默失效，不报错。
	_shop.setup(self, _overlay, _on_portrait_card_hover)
	_synergy.setup(_overlay)
	_stats.setup(_overlay)
	_treasure.setup(self, _overlay, _on_portrait_card_hover)
	_board_hud.setup(_prep_display_unit_def, _board_cell_quad, cell_size, board_cell_rest_line)
	if not _board_hud.state_changed.is_connected(_refresh_all):
		_board_hud.state_changed.connect(_refresh_all)
		_board_hud.visuals_dirty.connect(_on_board_visuals_dirty)
	if not _treasure.pick_requested.is_connected(_pick_treasure):
		_treasure.pick_requested.connect(_pick_treasure)
		_treasure.claim_requested.connect(_claim_pending_treasure_round)
		_treasure.state_changed.connect(_refresh_all)
	if not _synergy.altar_requested.is_connected(_on_golden_altar):
		_synergy.altar_requested.connect(_on_golden_altar)
		_synergy.gamble_requested.connect(_on_generous_fate_gamble)
		_synergy.treasure_detail_requested.connect(_treasure.show_detail)
	if not _shop.card_selected.is_connected(_on_shop_card_selected):
		_shop.card_selected.connect(_on_shop_card_selected)
		_shop.buy_requested.connect(_on_shop_buy_requested)
		_shop.detail_requested.connect(_show_shop_detail)
		_shop.picker_toggled.connect(_on_shop_picker_toggled)
		_shop.refresh_requested.connect(_on_refresh_shop)
		_shop.message_requested.connect(show_message)
		_shop.state_changed.connect(_refresh_all)

	var bg := ColorRect.new()
	bg.color = Color(0.38, 0.70, 0.88)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	bg.z_index = -21

	# 满屏 2D 背景垫底：用同一张棋盘 base 图，KEEP_ASPECT_COVERED 铺满任何屏幕；
	# 3D 视口已设透明，棋盘没盖到的角落就露出这张图的草地，不再有黑角。
	var sky_background := TextureRect.new()
	sky_background.name = "PrepFullscreenBackground"
	sky_background.texture = PrepWidgets.cached_texture(PREP_BOARD_BASE_PATH)
	sky_background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sky_background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	sky_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sky_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sky_background.z_index = -20
	add_child(sky_background)
	_setup_prep_river_background()

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 12
	root.offset_top = 10
	root.offset_right = -12
	root.offset_bottom = -10
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	_build_top_bar(root)
	_build_rest(root)

	# 调试空间框：满屏覆盖层，扫描整棵界面树，把每个可见控件的矩形用黑边画出来。
	if SHOW_SPACE_FRAMES:
		var space_overlay := SpaceFrameDebugOverlay.new()
		space_overlay.name = "SpaceFrameDebugOverlay"
		space_overlay.scan_root = self
		add_child(space_overlay)

	# 调试判定线条：满屏覆盖层，扫描整棵界面树，画出每个按钮的点击判定区域。
	if SHOW_HIT_AREAS:
		var hit_overlay := HitAreaDebugOverlay.new()
		hit_overlay.name = "HitAreaDebugOverlay"
		hit_overlay.scan_root = self
		add_child(hit_overlay)

	# 面板节点**最后**才进树：加在前面会把所有兄弟节点的次序整体后移，
	# 而 PrepUI 的注释明确记着树顺序影响输入拾取。加在末尾则原有次序一字不动。
	# 零尺寸 + IGNORE：它只是逻辑宿主，不参与布局也不吃输入 ——
	# 商店的可见控件仍在原位（顶层 ShopSideControls 与主布局里的弹窗）。
	if _shop.get_parent() == null:
		_shop.name = "ShopPanel"
		_shop.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_shop.custom_minimum_size = Vector2.ZERO
		add_child(_shop)
	if _synergy.get_parent() == null:
		_synergy.name = "SynergyPanel"
		_synergy.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_synergy.custom_minimum_size = Vector2.ZERO
		add_child(_synergy)
	if _stats.get_parent() == null:
		_stats.name = "BattleStatsPanel"
		_stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_stats.custom_minimum_size = Vector2.ZERO
		add_child(_stats)
	if _treasure.get_parent() == null:
		_treasure.name = "TreasureChoicePanel"
		_treasure.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_treasure.custom_minimum_size = Vector2.ZERO
		add_child(_treasure)
	if _board_hud.get_parent() == null:
		_board_hud.name = "BoardHud"
		_board_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_board_hud.custom_minimum_size = Vector2.ZERO
		add_child(_board_hud)


func _build_top_bar(root: VBoxContainer) -> void:
	var top := SellDropPanel.new()
	top.screen = self
	top.custom_minimum_size = Vector2(0, 68)
	PrepWidgets.apply_transparent_panel_style(top)
	root.add_child(top)
	var top_content := Control.new()
	top_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	top.add_child(top_content)

	var formation_row := HBoxContainer.new()
	formation_row.anchor_left = 0.5
	formation_row.anchor_top = 0.5
	formation_row.anchor_right = 0.5
	formation_row.anchor_bottom = 0.5
	formation_row.offset_left = -470
	formation_row.offset_top = -46
	formation_row.offset_right = 470
	formation_row.offset_bottom = 46
	formation_row.alignment = BoxContainer.ALIGNMENT_CENTER
	formation_row.add_theme_constant_override("separation", 8)
	top_content.add_child(formation_row)

	var player_bar_stack := PrepWidgets.create_formation_health_bar(false)
	formation_row.add_child(player_bar_stack)
	_player_formation_bar = null   # 血条红条已删，只留数字
	_player_formation_hp_label = player_bar_stack.get_child(0) as Label

	_player_formation_art = _create_formation_crystal(false)
	formation_row.add_child(_player_formation_art)

	var battle := GloryBusyButtonScript.new()
	_start_battle_button = battle
	battle.custom_minimum_size = START_BTN_SIZE
	battle.focus_mode = Control.FOCUS_NONE
	battle.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var battle_style := PrepWidgets.menu_button_style()          # 统一「离线自测」样式
	battle.add_theme_stylebox_override("normal", battle_style)
	battle.add_theme_stylebox_override("hover", battle_style)
	battle.add_theme_stylebox_override("pressed", battle_style)
	battle.button_down.connect(_on_start_battle_input_down)
	battle.pressed.connect(_on_start_battle)
	var battle_label := Label.new()          # 单独 Label：_refresh_start_button_label 会改它的文字
	battle_label.text = tr("ui_start_battle_btn")
	battle_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	battle_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	battle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	battle_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	battle_label.add_theme_font_size_override("font_size", 20)
	battle_label.add_theme_color_override("font_color", Color(1.0, 0.90, 0.60))
	battle.add_child(battle_label)
	battle.bind_content_label(battle_label)
	battle.set_idle_text(tr("ui_start_battle_btn"))
	_start_battle_label = battle_label
	# (3) Round number + next battle type (PVE / PVP / BOSS), stacked under the button.
	var battle_col := VBoxContainer.new()
	battle_col.alignment = BoxContainer.ALIGNMENT_CENTER
	battle_col.add_theme_constant_override("separation", 1)
	battle_col.add_child(battle)
	var round_lbl := Label.new()
	round_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	round_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	round_lbl.add_theme_font_size_override("font_size", 14)
	round_lbl.add_theme_color_override("font_color", Color(0.98, 0.92, 0.74))
	round_lbl.add_theme_color_override("font_outline_color", Color(0.10, 0.05, 0.0, 0.95))
	round_lbl.add_theme_constant_override("outline_size", 3)
	_round_info_label = round_lbl
	battle_col.add_child(round_lbl)
	formation_row.add_child(battle_col)

	# Top-right: per-player ready indicator (6 colored dots, ✓ when ready).
	_build_ready_indicator()

	_enemy_formation_art = _create_formation_crystal(true)
	formation_row.add_child(_enemy_formation_art)

	var enemy_bar_stack := PrepWidgets.create_formation_health_bar(true)
	formation_row.add_child(enemy_bar_stack)
	_enemy_formation_bar = null   # 血条红条已删，只留数字
	_enemy_formation_hp_label = enemy_bar_stack.get_child(0) as Label

func _build_rest(root: VBoxContainer) -> void:
	_build_top_actions()

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	root.add_child(body)

	var left_drop := SellDropPanel.new()
	left_drop.screen = self
	left_drop.custom_minimum_size = Vector2(260, 0)
	PrepWidgets.apply_transparent_panel_style(left_drop)
	body.add_child(left_drop)
	# 种族羁绊面板：不滚动，直接把 VBox 放进面板（内容确定放得下）。
	_synergy._left_panel = VBoxContainer.new()
	_synergy._left_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_synergy._left_panel.add_theme_constant_override("separation", 8)
	left_drop.add_child(_synergy._left_panel)

	var center_host := Control.new()
	center_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(center_host)

	# 待命区背景已改为 3D 地面 quad（见 PrepBoardModels._add_prep_standby_bg_plane），不再用 2D 贴图。

	var center := VBoxContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center.add_theme_constant_override("separation", 6)
	center_host.add_child(center)

	_treasure.build_overlay()

	_treasure.build_logos_panel()

	var board_and_bench := HBoxContainer.new()
	board_and_bench.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	board_and_bench.size_flags_vertical = Control.SIZE_EXPAND_FILL
	board_and_bench.alignment = BoxContainer.ALIGNMENT_BEGIN
	board_and_bench.add_theme_constant_override("separation", 8)
	center.add_child(board_and_bench)

	# 待命区容器：只当 8 个待命格子的父节点 + 投影原点用。它的位置在投影里会被减掉，
	# 摆哪都不影响格子出现的位置（格子由 STANDBY_SPOTS 的 3D 投影定位），所以保持最简。
	var left_bench := Control.new()
	left_bench.name = "StandbyFrame"
	_board_hud.bench_row = left_bench
	_board_hud.standby_frame = left_bench
	left_bench.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center_host.add_child(left_bench)
	for i in mini(GameState.BENCH_SLOTS, STANDBY_SLOT_COUNT):
		var standby_slot := _create_bench_portrait_card(i)
		# 位置/大小/多边形由 _realign_prep_standby_cells 每帧按 STANDBY_SPOTS 投影设定。
		left_bench.add_child(standby_slot)

	var board_frame := Control.new()
	var board_size := _board_hud.grid_size()
	board_frame.custom_minimum_size = board_size
	board_frame.size = board_size
	board_frame.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN   # 棋盘框靠左（C 需求）
	board_frame.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	board_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 同上：布局框不吃点击
	board_and_bench.add_child(board_frame)

	_setup_prep_board_model_view(board_frame)

	_board_hud.grid = Control.new()
	_board_hud.grid.custom_minimum_size = board_size
	_board_hud.grid.size = board_size
	_board_hud.grid.position = board_grid_offset
	_board_hud.grid.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 同上：格子自己接输入
	board_frame.add_child(_board_hud.grid)
	_board_hud.readability_layer = BoardReadabilityLayerScene.instantiate() as BoardReadabilityLayer
	_board_hud.readability_layer.name = "PrepBoardReadabilityLayer"
	_board_hud.readability_layer.configure_prep()
	_board_hud.readability_layer.set_guides_enabled(PlayerProfile.board_readability_enabled)
	_board_hud.readability_layer.set_low_quality(VFXManager.get_quality_tier() == VFXQualityBudget.Tier.LOW)
	_board_hud.readability_layer.set_direction_texts(tr("board_frontline"), tr("board_backline"))
	_board_hud.grid.add_child(_board_hud.readability_layer)
	for i in GameConstants.CELL_COUNT:
		var cell := BoardCellButton.new()
		cell.board_index = i
		cell.screen = self
		cell.hud = _board_hud
		cell.drag_owner = self
		var quad := _board_cell_quad(i, board_size)
		var bounds := Rect2(quad[0], Vector2.ZERO)
		for point in quad:
			bounds = bounds.expand(point)
		var hit_bounds := bounds.grow(18.0)
		cell.position = hit_bounds.position
		cell.size = hit_bounds.size
		cell.custom_minimum_size = hit_bounds.size
		var local_circle := PackedVector2Array()
		var circle_center := bounds.get_center() - hit_bounds.position
		var radius := minf(bounds.size.x, bounds.size.y) * 0.32
		for segment in BOARD_CELL_SEGMENTS:
			var angle := TAU * float(segment) / float(BOARD_CELL_SEGMENTS)
			local_circle.append(circle_center + Vector2(cos(angle), sin(angle)) * radius)
		cell.configure_polygon(local_circle)
		cell.add_theme_font_size_override("font_size", 11)
		cell.add_theme_color_override("font_outline_color", Color(0.01, 0.01, 0.01, 0.96))
		cell.add_theme_constant_override("outline_size", 2)
		cell.add_theme_stylebox_override("normal", _board_hud.empty_style)
		cell.add_theme_stylebox_override("hover", _board_hud.hover_style)
		cell.add_theme_stylebox_override("pressed", _board_hud.hover_style)
		cell.add_theme_stylebox_override("focus", _board_hud.hover_style)
		cell.pressed.connect(_on_board_pressed.bind(i))
		_overlay.attach_long_press(cell, func(): _show_board_detail(i))
		_board_hud.grid.add_child(cell)
		_board_hud.buttons.append(cell)
		var relation_overlay := RelationProgressOverlay.new()
		relation_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		relation_overlay.z_index = 8
		cell.add_child(relation_overlay)
		_board_hud.relation_overlays.append(relation_overlay)
		var caption := PrepWidgets.make_cell_caption()
		# 棋盘：跟「圆圈真正的中心」定位（在 _fit_cell_to_screen_polygon 里按椭圆质心摆），补透视。
		caption.set_meta("caption_centroid", true)
		caption.set_meta("caption_dx", BOARD_CAPTION_DX)      # 左右像素微调
		caption.set_meta("caption_drop", BOARD_CAPTION_DROP)  # 相对格子高度往下的比例（负=往上，绕圆心）
		cell.add_child(caption)
		_board_hud.cell_captions.append(caption)
	_sync_prep_board_readability_geometry()
	_sync_prep_board_readability_state()

	var right_board_spacer := Control.new()
	right_board_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 主犯：手机宽屏(aspect=expand)下棋盘投影右移，右列格子滑进这个占位控件底下，
	# 它默认 STOP 且树顺序在 board_frame 之后（拾取优先），把右列点击全吃了。
	right_board_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	board_and_bench.add_child(right_board_spacer)

	# 以下按原顺序逐段构建。**顺序不能动**：树顺序决定输入拾取优先级，
	# 换先后会让右列棋格被后面的控件吃掉点击（见段内注释）。
	# 拆分前后用 tools/prep_tree_snapshot.tscn 比对过完整节点树（303 个节点），
	# 路径、类名、次序、z_index、visible、mouse_filter 全部逐字节一致。
	_shop.build_button_and_purse(body, center_host, center)
	_shop.build_popup(body, center_host)
	_shop.build_hand_cards(body, center_host)
	_build_sell_zone_and_refresh(body, center_host)
	_build_merc_panels(body, center_host)
# 出售区与商店刷新按钮。由 _build_rest 拆出（D2）。
# 原函数 638 行，全函数只有 2 处完全干净的切点 —— body 与 center_host
# 两个局部量跨越几乎整段。所以切点取在「除它们之外没有其它局部量跨越」处，
# 这些容器以参数传入（段内只读，不重新赋值）。
func _build_sell_zone_and_refresh(body: HBoxContainer, center_host: Control) -> void:
	# 出售区域覆盖层本身做成 SellDropPanel：放下去直接卖，不靠穿透传递
	var sell_overlay := SellDropPanel.new()
	sell_overlay.screen = self
	sell_overlay.is_sell_zone = true  # 唯一的有效出售区：拖动棋盘/待命单位时点亮的红色区域
	_shop.sell_overlay = sell_overlay
	_shop.sell_overlay.visible = false
	_shop.sell_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	# 常驻底部中央（与商店弹窗同一位置），独立于商店弹窗：仅拖拽 board/bench 单位时显示。
	# z_index 高于弹窗(40)：弹窗开着时红区盖在弹窗上，丢上来直接卖，不会误触购买。
	_shop.sell_overlay.z_index = 50
	_shop.sell_overlay.anchor_left = 0.5
	_shop.sell_overlay.anchor_right = 0.5
	_shop.sell_overlay.anchor_top = 1.025
	_shop.sell_overlay.anchor_bottom = 1.025
	_shop.sell_overlay.offset_left = -_shop.SHOP_POPUP_SIZE.x * 0.5
	_shop.sell_overlay.offset_right = _shop.SHOP_POPUP_SIZE.x * 0.5
	_shop.sell_overlay.offset_top = -_shop.SHOP_POPUP_SIZE.y + 80
	_shop.sell_overlay.offset_bottom = 0
	var sell_style := StyleBoxFlat.new()
	sell_style.bg_color = Color(0.34, 0.07, 0.07, 0.94)
	sell_style.border_color = Color(0.94, 0.35, 0.25, 0.92)
	sell_style.set_border_width_all(2)
	sell_style.set_corner_radius_all(4)
	_shop.sell_overlay.add_theme_stylebox_override("panel", sell_style)
	center_host.add_child(_shop.sell_overlay)
	var sell_label := Label.new()
	sell_label.text = tr("ui_sell_zone")
	sell_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sell_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	sell_label.add_theme_font_size_override("font_size", 24)
	sell_label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.72))
	_shop.sell_overlay.add_child(sell_label)

	# 只包住刷新按钮的小框（132×132）。锚在面板右侧中间，别再撑成巨框吃卡片点击。
	# 要移动刷新：改下面 4 个 offset（框小才不会误吃点击）；锚点保持 left≤right、都在 0~1。
	var refresh_shop := Button.new()
	_shop.refresh_button = refresh_shop
	refresh_shop.text = ""
	refresh_shop.tooltip_text = tr("ui_refresh_shop_tooltip")
	refresh_shop.flat = true                  # 去默认样式，只显示循环箭头框
	# 直接挂外挂层 =【屏幕坐标】，锚右下角。只剩这一套 offset，改它就能挪按钮。
	refresh_shop.anchor_left = 1.0           
	refresh_shop.anchor_top = 1.0
	refresh_shop.anchor_right = 1.0
	refresh_shop.anchor_bottom = 1.0
	refresh_shop.offset_left = -105
	refresh_shop.offset_top = -200
	refresh_shop.offset_right = 25
	refresh_shop.offset_bottom = -70
	refresh_shop.focus_mode = Control.FOCUS_NONE
	var refresh_frame := TextureRect.new()    # 循环箭头图标框（箭头已画死）
	refresh_frame.texture = PrepWidgets.cached_texture(REFRESH_BTN_PATH)
	refresh_frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	refresh_frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	refresh_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	refresh_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	refresh_shop.add_child(refresh_frame)
	refresh_shop.pressed.connect(_on_refresh_shop_control_pressed)
	_shop.side_controls.add_child(refresh_shop)

	var refresh_icon := Label.new()
	_shop.refresh_icon = refresh_icon
	refresh_icon.text = "↻"
	refresh_icon.visible = false              # 框已自带循环箭头，隐藏文字图标（旋转动画无害）
	refresh_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	refresh_icon.anchor_left = 0.5
	refresh_icon.anchor_top = 0.5
	refresh_icon.anchor_right = 0.5
	refresh_icon.anchor_bottom = 0.5
	refresh_icon.offset_left = -14
	refresh_icon.offset_top = -22
	refresh_icon.offset_right = 14
	refresh_icon.offset_bottom = 2
	refresh_icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	refresh_icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	refresh_icon.add_theme_font_size_override("font_size", 19)
	refresh_icon.pivot_offset = Vector2(14, 12)
	refresh_shop.add_child(refresh_icon)

	var refresh_cost_label := Label.new()
	_shop.refresh_cost_label = refresh_cost_label
	refresh_cost_label.text = tr("ui_free")
	refresh_cost_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	refresh_cost_label.anchor_left = 0.5
	refresh_cost_label.anchor_top = 0.5
	refresh_cost_label.anchor_right = 0.5
	refresh_cost_label.anchor_bottom = 0.5
	refresh_cost_label.offset_left = -28
	refresh_cost_label.offset_top = 18
	refresh_cost_label.offset_right = 28
	refresh_cost_label.offset_bottom = 40
	refresh_cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	refresh_cost_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	refresh_cost_label.pivot_offset = Vector2(28, 11)
	refresh_cost_label.rotation_degrees = -4.0
	refresh_cost_label.add_theme_font_size_override("font_size", 18)
	refresh_cost_label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.30))
	refresh_cost_label.add_theme_color_override("font_outline_color", Color(0.20, 0.04, 0.01, 0.98))
	refresh_cost_label.add_theme_constant_override("outline_size", 3)
	refresh_shop.add_child(refresh_cost_label)
	var refresh_action_label := Label.new()
	refresh_action_label.text = tr("ui_refresh")
	refresh_action_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	refresh_action_label.anchor_left = 0.0
	refresh_action_label.anchor_top = 1.0
	refresh_action_label.anchor_right = 1.0
	refresh_action_label.anchor_bottom = 1.0
	refresh_action_label.offset_top = 0
	refresh_action_label.offset_bottom = 28
	refresh_action_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	refresh_action_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	refresh_action_label.add_theme_font_size_override("font_size", 19)
	refresh_action_label.add_theme_color_override("font_color", Color(1.0, 0.94, 0.72))
	refresh_action_label.add_theme_color_override("font_outline_color", Color(0.12, 0.04, 0.01, 0.98))
	refresh_action_label.add_theme_constant_override("outline_size", 4)
	refresh_shop.add_child(refresh_action_label)


# 佣兵面板与雇佣浮层。由 _build_rest 拆出（D2）。
# 原函数 638 行，全函数只有 2 处完全干净的切点 —— body 与 center_host
# 两个局部量跨越几乎整段。所以切点取在「除它们之外没有其它局部量跨越」处，
# 这些容器以参数传入（段内只读，不重新赋值）。
func _build_merc_panels(body: HBoxContainer, center_host: Control) -> void:
	_shop_refresh_burn = PrepShopRefreshBurnScript.new()
	add_child(_shop_refresh_burn)
	_shop_refresh_burn.setup(
		_shop._shop_background,
		_shop.refresh_button,
		PrepWidgets.cached_texture(SHOP_REFRESH_FIRE_ATLAS_PATH),
		SHOP_SCROLL_BURN_SHADER
	)

	var right_drop := PanelContainer.new()
	right_drop.custom_minimum_size = Vector2(110, 0)
	right_drop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	PrepWidgets.apply_transparent_panel_style(right_drop)
	body.add_child(right_drop)
	_merc_scroll = ScrollContainer.new()
	_merc_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_merc_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_merc_scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_merc_scroll.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	right_drop.add_child(_merc_scroll)
	_merc_panel = VBoxContainer.new()
	_merc_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_merc_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_merc_panel.add_theme_constant_override("separation", 8)
	_merc_scroll.add_child(_merc_panel)

	# 佣兵选择层已迁进 ModalStack（C-11 的 C3）：这里不再建常驻 content。
	# push() 接管 content、pop() 会销毁它，常驻一份再靠 visible 开关的老做法
	# 会在 close_all / owner 释放之后留下死指针。content 每次打开现建、关闭即弃，
	# 宿主矩形与 modal_closed 的接线由 _build_team_mercs_overlay() 统一装配
	# （两层共用同一个 center_host 与同一条 modal_closed 连接）。
	_build_team_mercs_overlay(center_host)

	_build_detail_popups()
func _build_top_actions() -> void:
	# 右上角横排：战力推荐 | 统计 | 静音（缩小，A 需求）。加到 self 顶层（z 高，不被 body 拦点击）。
	var top_row := HBoxContainer.new()
	top_row.anchor_left = 1.0
	top_row.anchor_right = 1.0
	top_row.anchor_top = 0.0
	top_row.anchor_bottom = 0.0
	var row_w := TOP_ROW_BTN_SIZE.x * 3.0 + 6.0 * 2.0
	top_row.offset_left = -row_w - 8
	top_row.offset_right = -8
	top_row.offset_top = 2
	top_row.offset_bottom = 2 + TOP_ROW_BTN_SIZE.y
	top_row.alignment = BoxContainer.ALIGNMENT_END
	top_row.add_theme_constant_override("separation", 6)
	top_row.z_index = 20
	add_child(top_row)
	top_row.add_child(PrepWidgets.make_menu_button(tr("ui_power"), TOP_ROW_BTN_SIZE, 13, _stats.show_power_recommendation))
	top_row.add_child(PrepWidgets.make_menu_button(tr("ui_stats"), TOP_ROW_BTN_SIZE, 13, _stats.show_last_battle))
	# 静音按钮：切换全局 Master 总线静音
	var mute_btn := PrepWidgets.make_menu_button(_mute_label_text(), TOP_ROW_BTN_SIZE, 13, _toggle_mute)
	_mute_button = mute_btn
	top_row.add_child(mute_btn)

	# 佣兵盾牌 / 队伍佣兵：不改，仍竖排，挪到横排下面（A1-a）。宽度保持 140，尺寸不变。
	var side_col := VBoxContainer.new()
	side_col.anchor_left = 1.0
	side_col.anchor_right = 1.0
	side_col.anchor_top = 0.0
	side_col.anchor_bottom = 0.0
	side_col.offset_left = -STATS_BTN_SIZE.x - 8
	side_col.offset_right = -8
	side_col.offset_top = 2 + TOP_ROW_BTN_SIZE.y + 6
	side_col.offset_bottom = 2 + TOP_ROW_BTN_SIZE.y + 6 + MERC_BTN_SIZE.y + STATS_BTN_SIZE.y + 6
	side_col.alignment = BoxContainer.ALIGNMENT_BEGIN
	side_col.add_theme_constant_override("separation", 6)
	side_col.z_index = 20
	add_child(side_col)
	# 佣兵按钮：盾牌框 + 下方写「佣兵」（保留原贴图框，不改）
	var merc_btn := PrepWidgets.make_framed_text_button("", MERC_BTN_PATH, MERC_BTN_SIZE, 16, _toggle_merc_picker)
	_merc_button = merc_btn
	var merc_lbl := Label.new()
	merc_lbl.text = tr("ui_mercenary")
	merc_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	merc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	merc_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	merc_lbl.anchor_left = 0.2
	merc_lbl.anchor_right = 0.8
	merc_lbl.anchor_top = 0.72
	merc_lbl.anchor_bottom = 0.93
	merc_lbl.add_theme_font_size_override("font_size", 15)
	merc_lbl.add_theme_color_override("font_color", Color(0.96, 0.97, 1.0))
	merc_lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	merc_lbl.add_theme_constant_override("outline_size", 3)
	merc_btn.add_child(merc_lbl)
	side_col.add_child(merc_btn)
	# 队伍佣兵检阅台：教学模式没有队友，直接藏
	var team_mercs_btn := PrepWidgets.make_framed_text_button("", TEAM_MERCS_BTN_PATH, MERC_BTN_SIZE, 16, _toggle_team_mercs_picker)
	_team_mercs_button = team_mercs_btn
	var team_mercs_lbl := Label.new()
	team_mercs_lbl.text = tr("ui_team_mercs")
	team_mercs_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	team_mercs_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	team_mercs_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	team_mercs_lbl.anchor_left = 0.15
	team_mercs_lbl.anchor_right = 0.85
	team_mercs_lbl.anchor_top = 0.72
	team_mercs_lbl.anchor_bottom = 0.93
	team_mercs_lbl.add_theme_font_size_override("font_size", 14)
	team_mercs_lbl.add_theme_color_override("font_color", Color(0.96, 0.97, 1.0))
	team_mercs_lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	team_mercs_lbl.add_theme_constant_override("outline_size", 3)
	team_mercs_btn.add_child(team_mercs_lbl)
	_team_merc_alert = PrepTeamMercAlertScript.new()
	team_mercs_btn.add_child(_team_merc_alert)
	_team_merc_alert.setup(team_mercs_btn, load(TEAM_MERC_ALERT_ATLAS_PATH))
	team_mercs_btn.visible = not GameState.tutorial_mode
	side_col.add_child(team_mercs_btn)

func _toggle_mute() -> void:
	# 全局静音开关：静音 Master 总线（BGM + 音效都停），引擎级状态，切场景仍生效
	var master := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_mute(master, not AudioServer.is_bus_mute(master))
	if _mute_button != null:
		_mute_button.text = _mute_label_text()

func _mute_label_text() -> String:
	var muted := AudioServer.is_bus_mute(AudioServer.get_bus_index("Master"))
	if LocaleManager.get_locale() == "en":
		return "Muted" if muted else "Mute"
	return "已静音" if muted else "静音"
func _build_detail_popups() -> void:
	_detail = PopupPanel.new()
	add_child(_detail)
	var detail_margin := MarginContainer.new()
	detail_margin.add_theme_constant_override("margin_left", 12)
	detail_margin.add_theme_constant_override("margin_top", 12)
	detail_margin.add_theme_constant_override("margin_right", 12)
	detail_margin.add_theme_constant_override("margin_bottom", 12)
	_detail.add_child(detail_margin)
	_detail_text = RichTextLabel.new()
	_detail_text.bbcode_enabled = true
	_detail_text.fit_content = true
	_detail_text.custom_minimum_size = Vector2(500, 360)
	detail_margin.add_child(_detail_text)
	# 节点造好了，交给详情浮层组件接管（它持有关闭时序等状态）。
	_overlay.bind(_detail, _detail_text)

	_stats._stats_popup = PopupPanel.new()
	add_child(_stats._stats_popup)
	var stats_margin := MarginContainer.new()
	stats_margin.add_theme_constant_override("margin_left", 12)
	stats_margin.add_theme_constant_override("margin_top", 12)
	stats_margin.add_theme_constant_override("margin_right", 12)
	stats_margin.add_theme_constant_override("margin_bottom", 12)
	_stats._stats_popup.add_child(stats_margin)
	var stats_box := VBoxContainer.new()
	stats_box.add_theme_constant_override("separation", 8)
	stats_margin.add_child(stats_box)
	var stats_tabs := HBoxContainer.new()
	stats_tabs.add_theme_constant_override("separation", 8)
	stats_box.add_child(stats_tabs)
	for item in [["player", tr("ui_stats_player")], ["boss", "Boss"]]:
		var tab := Button.new()
		tab.text = str(item[1])
		tab.custom_minimum_size = Vector2(96, 34)
		tab.pressed.connect(_set_stats_group.bind(str(item[0])))
		stats_tabs.add_child(tab)
	_stats._stats_text = RichTextLabel.new()
	_stats._stats_text.bbcode_enabled = true
	_stats._stats_text.scroll_active = true
	_stats._stats_text.custom_minimum_size = Vector2(920, 420)
	stats_box.add_child(_stats._stats_text)

func _create_formation_crystal(_is_enemy: bool) -> FormationCrystal:
	# 图片式水晶：贴图（火队红/水队蓝，按血量段）在 _refresh_formation_status 里按队伍指定。
	var crystal := FormationCrystal.new()
	crystal.custom_minimum_size = Vector2(56, 56)
	return crystal

func _crystal_textures_for_element(is_fire: bool) -> Array:
	# 火队 → 红水晶 5 段图；水队 → 蓝水晶 5 段图。缓存复用，顺序 0-10..40-50。
	var paths: Array = CRYSTAL_FIRE_PATHS if is_fire else CRYSTAL_WATER_PATHS
	var texs: Array = []
	for p in paths:
		texs.append(PrepWidgets.cached_texture(str(p)))
	return texs
func _refresh_formation_status() -> void:
	# (1) 3v3 uses the shared team HP, not the 1v1 formation HP fields.
	var player_hp: int
	var enemy_hp: int
	if GameState.team_mode:
		player_hp = clampi(GameState.team_hp, 0, GameState.START_FORMATION_HP)
		enemy_hp = clampi(GameState.enemy_team_hp, 0, GameState.START_FORMATION_HP)
	else:
		player_hp = clampi(GameState.player_formation_hp, 0, GameState.START_FORMATION_HP)
		enemy_hp = clampi(GameState.enemy_formation_hp, 0, GameState.START_FORMATION_HP)
	if _player_formation_bar != null:
		_player_formation_bar.value = player_hp
	if _enemy_formation_bar != null:
		_enemy_formation_bar.value = enemy_hp
	if _player_formation_hp_label != null:
		_player_formation_hp_label.text = "%d/%d" % [player_hp, GameState.START_FORMATION_HP]
	if _enemy_formation_hp_label != null:
		_enemy_formation_hp_label.text = "%d/%d" % [enemy_hp, GameState.START_FORMATION_HP]
	var max_hp := maxi(1, GameState.START_FORMATION_HP)
	# 队伍元素：组队时本人 slot<3=火队(红)、slot>=3=水队(蓝)，敌方取反；非组队默认本方火/敌方水。
	var local_fire := true
	if NetworkService.team_active and NetworkService.team_local_slot >= 0:
		local_fire = NetworkService.team_local_slot < 3
	if _player_formation_art != null:
		_player_formation_art.set_bracket_textures(_crystal_textures_for_element(local_fire))
		_player_formation_art.set_hp_ratio(float(player_hp) / float(max_hp))
	if _enemy_formation_art != null:
		_enemy_formation_art.set_bracket_textures(_crystal_textures_for_element(not local_fire))
		_enemy_formation_art.set_hp_ratio(float(enemy_hp) / float(max_hp))
	_refresh_start_button_label()
	_refresh_round_info_label()
	_refresh_ready_indicator()

func _refresh_round_info_label() -> void:
	if _round_info_label == null:
		return
	var kind: String
	if GameState.team_mode:
		kind = RoundService.schedule_kind_for_round(GameState.round_index)
	else:
		# 教学：和 BattleScreen 用同一个来源，标签才不会和实战对不上。
		kind = TutorialMode.battle_kind()
	var type_txt := "Final Round" if kind == "final" else kind.to_upper()
	if LocaleManager.get_locale() == "en":
		_round_info_label.text = "Round %d · %s" % [GameState.round_index, type_txt]
	else:
		_round_info_label.text = "第 %d 回合 · %s" % [GameState.round_index, type_txt]

func _refresh_start_button_label() -> void:
	if _start_battle_label == null:
		return
	if NetworkService.team_active:
		var my := NetworkService.team_local_slot
		var ready := my >= 0 and my < NetworkService.team_ready.size() and bool(NetworkService.team_ready[my])
		_start_battle_button.set_idle_text(tr("lobby_ready_done") if ready else tr("lobby_ready"))
	else:
		_start_battle_button.set_idle_text(tr("ui_start_battle_btn"))

func show_message(text: String) -> void:
	# Transient centered toast that fades out (used for rejected placements, etc.).
	if _toast_label == null:
		_toast_label = Label.new()
		_toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_toast_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_toast_label.anchor_left = 0.0
		_toast_label.anchor_right = 1.0
		_toast_label.anchor_top = 0.34
		_toast_label.anchor_bottom = 0.34
		_toast_label.offset_bottom = 44
		_toast_label.add_theme_font_size_override("font_size", 24)
		_toast_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.7))
		_toast_label.add_theme_color_override("font_outline_color", Color(0.12, 0.02, 0.0, 0.96))
		_toast_label.add_theme_constant_override("outline_size", 5)
		_toast_label.z_index = 60
		add_child(_toast_label)
	_toast_label.text = text
	_toast_label.visible = true
	_toast_label.modulate = Color(1, 1, 1, 1)
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(1.3)
	_toast_tween.tween_property(_toast_label, "modulate:a", 0.0, 0.6)

func _build_ready_indicator() -> void:
	# 3v3 准备状态：上排=敌队 3 个、下排=自己队 3 个（自己队永远在下，和战斗演示一致）。
	# _ready_dots 按「位置」存：0-2=上排左中右、3-5=下排左中右；刷新时再映射到对应 slot。
	_ready_indicator = VBoxContainer.new()
	# (7) Ready checks live in the empty TOP-LEFT corner, not the right side.
	_ready_indicator.anchor_left = 0.0
	_ready_indicator.anchor_right = 0.0
	_ready_indicator.anchor_top = 0.0
	_ready_indicator.anchor_bottom = 0.0
	_ready_indicator.offset_left = 16
	_ready_indicator.offset_right = 16 + 92
	_ready_indicator.offset_top = 8
	_ready_indicator.offset_bottom = 8 + 56
	_ready_indicator.add_theme_constant_override("separation", 4)
	_ready_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ready_indicator.z_index = 25
	add_child(_ready_indicator)
	_ready_dots = []
	for row in 2:
		var row_box := HBoxContainer.new()
		row_box.alignment = BoxContainer.ALIGNMENT_BEGIN
		row_box.add_theme_constant_override("separation", 4)
		row_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ready_indicator.add_child(row_box)
		for col in 3:
			var dot := Label.new()
			dot.custom_minimum_size = Vector2(24, 24)
			dot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			dot.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			dot.add_theme_font_size_override("font_size", 20)
			dot.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
			dot.add_theme_constant_override("outline_size", 3)
			dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row_box.add_child(dot)
			_ready_dots.append(dot)
	_refresh_ready_indicator()

func _refresh_ready_indicator() -> void:
	if _ready_indicator == null or _ready_dots.size() < 6:
		return
	_ready_indicator.visible = NetworkService.team_active
	if not NetworkService.team_active:
		return
	var states: Array = NetworkService.team_slot_states
	var ready_arr: Array = NetworkService.team_ready
	# 自己队永远在下排：team_local_slot<3=火队(0,1,2)、≥3=水队(3,4,5)；-1(没入队)默认火队在下。
	var local_fire := NetworkService.team_local_slot < 3
	var own_slots: Array = [0, 1, 2] if local_fire else [3, 4, 5]
	var enemy_slots: Array = [3, 4, 5] if local_fire else [0, 1, 2]
	var pos_to_slot: Array = enemy_slots + own_slots   # 位置 0-2=上排(敌)、3-5=下排(自己)
	for pos in 6:
		var dot: Label = _ready_dots[pos]
		var slot: int = int(pos_to_slot[pos])
		var st := str(states[slot]) if slot < states.size() else "empty"
		if st == "empty":
			dot.text = ""   # 空位保留占位，保持上下 3×3 对齐
			continue
		var col := GameConstants.team_slot_color(slot)
		var is_ready := st == "dummy" or (slot < ready_arr.size() and bool(ready_arr[slot]))
		dot.text = "✓" if is_ready else "○"
		dot.add_theme_color_override("font_color", col if is_ready else Color(col.r, col.g, col.b, 0.5))

func _create_bench_portrait_card(index: int) -> BenchCellButton:
	var card := BenchCellButton.new()
	card.hud = _board_hud
	card.bench_index = index
	card.screen = self
	card.drag_owner = self
	card.custom_minimum_size = Vector2(80, 72)   # 仅投影生效前的占位；真正大小由 _realign_prep_standby_cells 设定
	card.clip_contents = false   # 关裁剪：格子下方的名字/星级标签才不会被裁掉
	card.text = ""
	card.tooltip_text = tr("ui_bench_slot")
	card.pressed.connect(_on_bench_pressed.bind(index))
	_overlay.attach_long_press(card, func(): _show_bench_detail(index))
	PrepWidgets.configure_unframed_portrait_card(card, _on_portrait_card_hover)
	_board_hud.bench_buttons.append(card)

	var name_label := PrepWidgets.make_cell_caption()   # 待命格子下方的「名字 ★星级」，和棋盘一致
	card.add_child(name_label)
	_board_hud.bench_card_labels.append(name_label)
	return card
func _mercenary_purchase_reason(index: int) -> String:
	var mercenaries: Array = DataRegistry.get_table("mercenaries").get("mercenaries", [])
	if index < 0 or index >= mercenaries.size():
		return tr("ui_cannot_buy")
	if PrepRules.first_empty_mercenary_slot() < 0:
		return tr("ui_merc_full")
	var mercenary: Dictionary = mercenaries[index]
	if GameState.gold < int(mercenary.get("cost", 0)):
		return tr("ui_not_enough_gold")
	return ""

func _on_portrait_card_hover(card: Control, hovered: bool) -> void:
	if card.has_meta("portrait_hover_tween"):
		var previous: Variant = card.get_meta("portrait_hover_tween")
		if previous is Tween:
			(previous as Tween).kill()
	card.pivot_offset = card.size * 0.5
	card.z_index = 20 if hovered else 0
	var tween: Tween = create_tween()
	card.set_meta("portrait_hover_tween", tween)
	var target_scale := Vector2(1.07, 1.07) if hovered else Vector2.ONE
	tween.tween_property(card, "scale", target_scale, 0.12).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

func _on_refresh_shop_control_pressed() -> void:
	if _shop_refresh_burn == null or _shop_refresh_burn.is_playing():
		return
	var all_free := TreasureService.has_set("money")
	var refresh_cost := EconomyService.shop_refresh_cost(GameState.shop_refresh_uses_this_round, all_free)
	if GameState.gold < refresh_cost:
		return
	_shop_refresh_burn.play(Callable(self, "_on_refresh_shop"))
func _create_mercenary_purchase_card(mercenary: Dictionary, index: int) -> DragButton:
	var card := DragButton.new()
	card.drag_owner = self
	card.custom_minimum_size = Vector2(120, 120)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.clip_contents = false
	card.text = ""
	card.drag_enabled = false
	card.set_meta("drag_preview_text", "%s\n%s" % [str(mercenary.get("name", tr("ui_mercenary"))), tr("ui_gold_format") % int(mercenary.get("cost", 0))])
	var purchase_reason := _mercenary_purchase_reason(index)
	var can_purchase := purchase_reason.is_empty()
	card.set_meta("can_purchase", can_purchase)
	card.drag_payload = {}
	card.pressed.connect(_on_mercenary_purchase_card_pressed.bind(card, index))
	_overlay.attach_long_press(card, func(): _overlay.show_text(UnitDetailFormat.format_unit_def(mercenary)))
	PrepWidgets.configure_unframed_portrait_card(card, _on_portrait_card_hover)
	card.modulate = Color.WHITE

	var portrait := TextureRect.new()
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	portrait.offset_left = 4
	portrait.offset_top = 2
	portrait.offset_right = -4
	portrait.offset_bottom = -38
	var portrait_path := str(MERCENARY_PORTRAIT_PATHS.get(str(mercenary.get("id", "")), ""))
	portrait.texture = PrepWidgets.cached_texture(portrait_path)
	card.add_child(portrait)

	var name_label := Label.new()
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.anchor_left = 0.0
	name_label.anchor_top = 1.0
	name_label.anchor_right = 1.0
	name_label.anchor_bottom = 1.0
	name_label.offset_left = 1
	name_label.offset_top = -38
	name_label.offset_right = -1
	name_label.offset_bottom = -19
	name_label.text = PrepWidgets.unit_name(mercenary)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 20)
	name_label.add_theme_color_override("font_color", Color.WHITE)
	name_label.add_theme_color_override("font_outline_color", Color.TRANSPARENT)
	name_label.add_theme_constant_override("outline_size", 0)
	card.add_child(name_label)

	var price_label := Label.new()
	price_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	price_label.anchor_left = 0.0
	price_label.anchor_top = 1.0
	price_label.anchor_right = 1.0
	price_label.anchor_bottom = 1.0
	price_label.offset_left = 1
	price_label.offset_top = -19
	price_label.offset_right = -1
	price_label.offset_bottom = 0
	price_label.text = tr("ui_gold_format") % int(mercenary.get("cost", 0))
	price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	price_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	price_label.add_theme_font_size_override("font_size", 10)
	price_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	price_label.add_theme_constant_override("outline_size", 2)
	card.add_child(price_label)
	var reason_label := _shop._create_purchase_reason_overlay(card)
	_shop._set_purchase_reason(reason_label, purchase_reason)
	return card

func _on_mercenary_purchase_card_pressed(card: BaseButton, index: int) -> void:
	if bool(card.get_meta("long_press_triggered", false)):
		return
	if not bool(card.get_meta("can_purchase", false)):
		return
	_on_hire_mercenary(index)

func _refresh_all() -> void:
	# 教学局也走自动合成：正式局就是这个规则，教学不能教一套正式局用不上的操作。
	_auto_combine_all()
	if GameState.tutorial_mode:
		TutorialMode.sync()
	RaceRelationService.reconcile_board(GameState.board_slots, GameState.bench_slots, false, true)
	_refresh_formation_status()
	_board_hud.refresh_board()
	_board_hud.refresh_bench()
	_shop.refresh()
	_synergy.refresh()
	_refresh_merc_panel()
	_treasure.refresh()
	_refresh_owned_treasure_logos()
	if GameState.tutorial_mode:
		TutorialMode.update_overlay()
	_check_team_merc_alert()
func _sync_prep_board_readability_geometry() -> void:
	if _board_hud.readability_layer == null or not is_instance_valid(_board_hud.readability_layer):
		return
	var polygons: Array[PackedVector2Array] = []
	for button in _board_hud.buttons:
		var polygon := PackedVector2Array()
		for point in button.cell_polygon:
			polygon.append(button.position + point)
		polygons.append(polygon)
	_board_hud.readability_layer.set_prep_cells(polygons)

func _sync_prep_board_readability_state() -> void:
	if _board_hud.readability_layer == null or not is_instance_valid(_board_hud.readability_layer):
		return
	_board_hud.readability_layer.set_guides_enabled(PlayerProfile.board_readability_enabled)
	_board_hud.readability_layer.set_low_quality(VFXManager.get_quality_tier() == VFXQualityBudget.Tier.LOW)
	_board_hud.readability_layer.set_direction_texts(tr("board_frontline"), tr("board_backline"))
	_board_hud.readability_layer.set_prep_state(
		_board_hud._selected_board,
		_prep_attack_range_indices(_board_hud._selected_board),
		_board_hud.drop_highlight_active,
		_board_hud.drop_hover_index,
		_board_hud.player_color()
	)

func _prep_attack_range_indices(selected_index: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	if selected_index < 0 or selected_index >= GameState.board_slots.size():
		return result
	var cell_value = GameState.board_slots[selected_index]
	if typeof(cell_value) != TYPE_DICTIONARY:
		return result
	var definition := _prep_display_unit_def(cell_value as Dictionary)
	var range_cells := maxf(0.0, float(definition.get("range", 1.0)))
	var selected_col := selected_index % GameConstants.BOARD_COLUMNS
	var selected_row := floori(float(selected_index) / float(GameConstants.BOARD_COLUMNS))
	for index in GameConstants.CELL_COUNT:
		var col := index % GameConstants.BOARD_COLUMNS
		var row := floori(float(index) / float(GameConstants.BOARD_COLUMNS))
		var delta := Vector2(float(col - selected_col), float(row - selected_row))
		if delta.length() <= range_cells + 0.001:
			result.append(index)
	return result
func _load_board_art_texture() -> Texture2D:
	return null
func _show_gold_interest_detail() -> void:
	_overlay.show_gold_interest(_shop.format_gold_interest_detail())
func _refresh_merc_panel() -> void:
	if _merc_scroll != null:
		_merc_scroll.visible = true
	for child in _merc_panel.get_children():
		child.queue_free()
	# 佣兵「佣兵」开启按钮已移到右上角统计/战力列下面（盾牌框）。
	# 已购佣兵不在备战界面出模型，只在佣兵弹窗右上角显示「已雇 N/8」。
	_refresh_mercenary_overlay()

func _hired_mercenary_count() -> int:
	var n := 0
	for cell in GameState.mercenary_slots:
		if cell != null:
			n += 1
	return n

func _refresh_mercenary_overlay() -> void:
	if not _merc_picker_open:
		# 关：交给 ModalStack。content 连同 12 张卡一起被销毁 ——
		# 迁移前是「留在树里、手动清空网格」，现在整棵子树都不在了。
		# 业务状态由 modal_closed 统一收口（见 _on_merc_picker_modal_closed）。
		if ModalStack.has(MERC_PICKER_MODAL_ID):
			ModalStack.pop(MERC_PICKER_MODAL_ID, ModalStack.REASON_PROGRAMMATIC)
		else:
			_merc_picker_teardown_state()
		return

	if not ModalStack.has(MERC_PICKER_MODAL_ID):
		var content := _create_merc_picker_content()
		var modal_id := ModalStack.push(content, {
			"id": MERC_PICKER_MODAL_ID,
			"owner": self,
			"priority": MERC_PICKER_MODAL_PRIORITY,
			# 取代迁移前 PrepScreen._unhandled_input() 里那段手写的矩形外点击判定。
			"dismiss_on_backdrop": true,
			# 迁移前面板外没有任何变暗，backdrop 再上色就是改视觉。
			"backdrop_color": Color.TRANSPARENT,
		})
		if modal_id.is_empty():
			# 上面已用 has() 挡过重复；走到这里说明 push 真的失败了。
			# content 已由 push 收走，不能再 free，只清引用。
			_merc_picker_open = false
			_merc_picker_teardown_state()
			return
		_merc_overlay = content
		_sync_merc_picker_content_rect()

	if _merc_overlay_grid == null or not is_instance_valid(_merc_overlay_grid):
		return
	# 计数放在下面的签名短路之前，否则签名没变时会漏更新。
	if _merc_count_label != null:
		_merc_count_label.text = tr("ui_merc_hired_count") % [_hired_mercenary_count(), GameState.MERCENARY_SLOTS]
	# 打开状态下只有影响卡片内容的数据变了才重建 12 张卡。
	var sig := JSON.stringify([
		GameState.gold,
		GameState.mercenary_slots,
		GameState.tutorial_mode,
		LocaleManager.get_locale(),
	])
	if sig == _merc_overlay_signature:
		return
	_merc_overlay_signature = sig
	for child in _merc_overlay_grid.get_children():
		child.queue_free()
	var mercs: Array = DataRegistry.get_table("mercenaries").get("mercenaries", [])
	for i in mercs.size():
		var m: Dictionary = mercs[i]
		_merc_overlay_grid.add_child(_create_mercenary_purchase_card(m, i))

func _toggle_merc_picker() -> void:
	_merc_picker_open = not _merc_picker_open
	if _merc_picker_open:
		_close_team_mercs_picker()
		_shop.close_picker()
	_refresh_merc_panel()

func _close_merc_picker() -> void:
	if not _merc_picker_open:
		return
	_merc_picker_open = false
	_refresh_merc_panel()
# 每次打开现建一份佣兵选择层 content。节点结构、样式、边距、4 列网格与间距
# 与迁移前逐项一致；唯一的差别是不再设 z_index（ModalStack 的 CanvasLayer 接管层级）。
#
# 根节点**保留 MOUSE_FILTER_STOP**：迁移后 content 只占 center_host 的矩形、不是全屏，
# 所以它不构成「另一块全屏 STOP」。若改成 IGNORE，卡片之间的 8px 间隙和 12px 边距会
# 穿透到 backdrop —— 玩家在 4 列网格里挑佣兵时手指偏一点就把面板关掉。
# 这一点与 C4 的检阅台不同：那一层是纯展示、没有可交互子节点。
func _create_merc_picker_content() -> PanelContainer:
	var overlay := PanelContainer.new()
	overlay.name = "MercPickerOverlay"
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var overlay_style := StyleBoxFlat.new()
	overlay_style.bg_color = Color(0.055, 0.065, 0.075, 0.98)
	overlay_style.border_color = Color(0.42, 0.50, 0.58, 0.92)
	overlay_style.set_border_width_all(2)
	overlay_style.set_corner_radius_all(4)
	overlay.add_theme_stylebox_override("panel", overlay_style)
	var overlay_margin := MarginContainer.new()
	overlay_margin.add_theme_constant_override("margin_left", 12)
	overlay_margin.add_theme_constant_override("margin_top", 10)
	overlay_margin.add_theme_constant_override("margin_right", 12)
	overlay_margin.add_theme_constant_override("margin_bottom", 12)
	overlay.add_child(overlay_margin)
	var overlay_box := VBoxContainer.new()
	overlay_box.add_theme_constant_override("separation", 8)
	overlay_margin.add_child(overlay_box)
	var overlay_header := HBoxContainer.new()
	overlay_box.add_child(overlay_header)
	var overlay_title := Label.new()
	overlay_title.text = tr("ui_choose_mercenary")
	overlay_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	overlay_title.add_theme_font_size_override("font_size", 18)
	overlay_header.add_child(overlay_title)
	# 右上角「已雇 N/8」：备战界面没有其它已购佣兵的提示，这里是唯一的计数反馈。
	_merc_count_label = Label.new()
	_merc_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_merc_count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_merc_count_label.add_theme_font_size_override("font_size", 18)
	_merc_count_label.add_theme_color_override("font_color", Color(0.96, 0.97, 1.0))
	_merc_count_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	_merc_count_label.add_theme_constant_override("outline_size", 3)
	overlay_header.add_child(_merc_count_label)
	_merc_overlay_grid = GridContainer.new()
	_merc_overlay_grid.columns = 4
	_merc_overlay_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_merc_overlay_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_merc_overlay_grid.add_theme_constant_override("h_separation", 8)
	_merc_overlay_grid.add_theme_constant_override("v_separation", 8)
	overlay_box.add_child(_merc_overlay_grid)
	return overlay


func _sync_merc_picker_content_rect() -> void:
	_sync_modal_content_to_host(_merc_overlay)


# 模态被任何一条路关掉时（点外面、close_all、owner 释放、程序化 pop）都会走到这里。
func _on_merc_picker_modal_closed(id: String, _reason: String) -> void:
	if id != MERC_PICKER_MODAL_ID:
		return
	_merc_picker_open = false
	_merc_picker_teardown_state()


# content 已由 ModalStack 销毁（或即将销毁），这里只清本页面持有的引用。
# 不 free 任何节点 —— 所有权在 push 时就交出去了。
# 卡片的 pressed / 长按连接随卡片一起消失，不会累积。
func _merc_picker_teardown_state() -> void:
	_merc_overlay_signature = "unset"
	_merc_overlay = null
	_merc_overlay_grid = null
	_merc_count_label = null


# ─── team mercs review stage ──────────────────────────────────────────────────

func _build_team_mercs_overlay(center_host: Control) -> void:
	# 迁进 ModalStack 之后这里**不再建 content**。ModalStack.push() 接管 content、
	# pop() 会销毁它，所以常驻一份再靠 visible 开关的老做法在这里行不通：
	# 任何一次 close_all / owner 释放都会让常驻引用变成死指针。
	#
	# 这里只保留三样必须跨开合存活的东西：宿主引用、30Hz 渲染节流计时器、
	# 以及网络刷新的信号连接。content 每次打开现建、关闭即弃（见 §3.3 的第一条）。
	# 代价比看上去小：舞台模型**本来就是每次打开重建**的（关闭时清空、
	# 打开时 _rebuild_team_mercs_stage()），新增的只有 SubViewport + 环境 + 两盏灯 + 相机。
	_team_mercs_host = center_host
	if not center_host.item_rect_changed.is_connected(_sync_team_mercs_content_rect):
		center_host.item_rect_changed.connect(_sync_team_mercs_content_rect)
	if not center_host.item_rect_changed.is_connected(_sync_merc_picker_content_rect):
		center_host.item_rect_changed.connect(_sync_merc_picker_content_rect)
	# 30Hz 渲染节流：和河流视口同一采样率，动画推进不受影响。
	# 挂在 self 上而不是 content 里 —— 它要跨开合存活，且 pop() 不该带走它。
	_team_mercs_render_timer = Timer.new()
	_team_mercs_render_timer.wait_time = 1.0 / PREP_RIVER_RENDER_HZ
	_team_mercs_render_timer.timeout.connect(_on_team_mercs_render_tick)
	add_child(_team_mercs_render_timer)
	if not NetworkService.team_prep_mercs_changed.is_connected(_on_team_prep_mercs_changed):
		NetworkService.team_prep_mercs_changed.connect(_on_team_prep_mercs_changed)
	# backdrop / close_all / owner 释放都能绕过本页面直接关掉模态，
	# 统一在这里把业务状态同步回来，避免 _team_mercs_open 与栈不一致。
	if not ModalStack.modal_closed.is_connected(_on_team_mercs_modal_closed):
		ModalStack.modal_closed.connect(_on_team_mercs_modal_closed)
	if not ModalStack.modal_closed.is_connected(_on_merc_picker_modal_closed):
		ModalStack.modal_closed.connect(_on_merc_picker_modal_closed)


# 每次打开现建一份 content。节点结构、尺寸、背景、灯光、相机、缩放与迁移前逐项一致，
# 唯一的差别是全链 MOUSE_FILTER_IGNORE：输入拦截交给 ModalStack 的 backdrop。
func _create_team_mercs_content() -> Control:
	var overlay := PanelContainer.new()
	overlay.name = "TeamMercsReviewOverlay"
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var stage_holder := Control.new()
	stage_holder.clip_contents = true
	stage_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage_holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(stage_holder)
	var stage_background := TextureRect.new()
	stage_background.texture = PrepWidgets.cached_texture(TEAM_MERCS_STAGE_BACKGROUND_PATH)
	stage_background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stage_background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	stage_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage_holder.add_child(stage_background)
	var viewport_container := SubViewportContainer.new()
	viewport_container.stretch = true
	viewport_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage_holder.add_child(viewport_container)
	_team_mercs_viewport = SubViewport.new()
	_team_mercs_viewport.own_world_3d = true
	_team_mercs_viewport.transparent_bg = true
	_team_mercs_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport_container.add_child(_team_mercs_viewport)
	# 灯光/环境照抄备战河流视口，让模型观感一致；背景色同弹窗底色，视觉上无缝
	var env_node := WorldEnvironment.new()
	var stage_env := Environment.new()
	stage_env.background_mode = Environment.BG_COLOR
	stage_env.background_color = Color(0.0, 0.0, 0.0, 0.0)
	stage_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	stage_env.ambient_light_color = Color(0.58, 0.68, 0.61)
	stage_env.ambient_light_energy = 0.40
	stage_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env_node.environment = stage_env
	_team_mercs_viewport.add_child(env_node)
	var key_light := DirectionalLight3D.new()
	key_light.light_color = Color(1.0, 0.92, 0.76)
	key_light.light_energy = 0.64
	key_light.rotation_degrees = Vector3(-52.0, -28.0, 0.0)
	key_light.shadow_enabled = false
	_team_mercs_viewport.add_child(key_light)
	var fill_light := DirectionalLight3D.new()
	fill_light.light_color = Color(0.48, 0.68, 0.82)
	fill_light.light_energy = 0.18
	fill_light.rotation_degrees = Vector3(-38.0, 142.0, 0.0)
	fill_light.shadow_enabled = false
	_team_mercs_viewport.add_child(fill_light)
	var camera := Camera3D.new()
	camera.fov = TEAM_MERCS_CAMERA_FOV
	camera.look_at_from_position(TEAM_MERCS_CAMERA_POSITION, TEAM_MERCS_CAMERA_TARGET, Vector3.UP)
	camera.current = true
	_team_mercs_viewport.add_child(camera)
	_team_mercs_stage_root = Node3D.new()
	_team_mercs_stage_root.name = "TeamMercsStageRoot"
	_team_mercs_stage_root.scale = Vector3.ONE * TEAM_MERCS_STAGE_SCALE
	_team_mercs_viewport.add_child(_team_mercs_stage_root)
	_team_mercs_empty_label = Label.new()
	_team_mercs_empty_label.text = tr("ui_team_mercs_empty")
	_team_mercs_empty_label.visible = false
	_team_mercs_empty_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_team_mercs_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_team_mercs_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_team_mercs_empty_label.add_theme_font_size_override("font_size", 18)
	_team_mercs_empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage_holder.add_child(_team_mercs_empty_label)
	return overlay


# content 挂在 ModalStack 的全屏 root 下，不再自动跟随 center_host 的布局，
# 所以开合与尺寸变化时都要把它钉回宿主的屏幕矩形 —— 否则舞台会铺满整屏，
# 那就是改视觉了。
func _sync_team_mercs_content_rect() -> void:
	_sync_modal_content_to_host(_team_mercs_overlay)


# 备战页两个模态共用：content 挂在 ModalStack 的全屏 root 下，不再自动跟随
# center_host 的布局，所以开合与尺寸变化时都要把它钉回宿主的屏幕矩形 ——
# 否则面板会铺满整屏，那就是改视觉了。
func _sync_modal_content_to_host(content: Control) -> void:
	if content == null or not is_instance_valid(content):
		return
	if _team_mercs_host == null or not is_instance_valid(_team_mercs_host):
		return
	if not _team_mercs_host.is_inside_tree():
		return
	var host_rect := _team_mercs_host.get_global_rect()
	content.set_anchors_preset(Control.PRESET_TOP_LEFT, true)
	content.global_position = host_rect.position
	content.size = host_rect.size


# 模态被任何一条路关掉时（点外面、close_all、owner 释放、程序化 pop）都会走到这里。
# 业务状态、计时器、SubViewport、舞台引用统一在这里收口，避免出现
# 「栈里没了但 _team_mercs_open 还是 true」这种两边不一致。
func _on_team_mercs_modal_closed(id: String, _reason: String) -> void:
	if id != TEAM_MERCS_MODAL_ID:
		return
	_team_mercs_open = false
	_team_mercs_teardown_state()


# content 已由 ModalStack 销毁（或即将销毁），这里只负责把本页面持有的引用清干净。
# 不 free 任何节点 —— 所有权在 push 时就交出去了。
func _team_mercs_teardown_state() -> void:
	_team_mercs_stage_signature = "unset"
	if _team_mercs_render_timer != null and is_instance_valid(_team_mercs_render_timer):
		_team_mercs_render_timer.stop()
	if _team_mercs_viewport != null and is_instance_valid(_team_mercs_viewport):
		_team_mercs_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_team_mercs_overlay = null
	_team_mercs_viewport = null
	_team_mercs_stage_root = null
	_team_mercs_empty_label = null


func _on_team_mercs_render_tick() -> void:
	# content 现在每次开合都会被 ModalStack 销毁重建，所以除了 null 还要判有效性。
	if not _team_mercs_open or not is_visible_in_tree():
		return
	if _team_mercs_viewport != null and is_instance_valid(_team_mercs_viewport):
		_team_mercs_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func _on_team_prep_mercs_changed() -> void:
	_check_team_merc_alert()
	if _team_mercs_open:
		_refresh_team_mercs_overlay()

func _toggle_team_mercs_picker() -> void:
	_team_mercs_open = not _team_mercs_open
	if _team_mercs_open:
		_close_merc_picker()
		if _team_merc_alert != null:
			_team_merc_alert.mark_seen()
		# Opening the stage acknowledges everything already received.
		_team_merc_counts_snapshot = _team_merc_counts()
		_team_merc_snapshot_round = GameState.round_index
		_team_merc_snapshot_initialized = true
	_refresh_team_mercs_overlay()

func _team_merc_counts() -> Dictionary:
	var counts: Dictionary = {}
	var my_slot := NetworkService.team_local_slot if NetworkService.team_active else 0
	if my_slot < 0:
		my_slot = 0
	if not NetworkService.team_active:
		var local_count := 0
		for cell in GameState.mercenary_slots:
			if typeof(cell) == TYPE_DICTIONARY:
				local_count += 1
		counts[my_slot] = local_count
		return counts

	var first := GameConstants.team_first_slot(GameConstants.team_of_slot(my_slot))
	for slot in range(first, first + GameConstants.TEAM_SIDE_SIZE):
		if slot == my_slot:
			var local_count := 0
			for cell in GameState.mercenary_slots:
				if typeof(cell) == TYPE_DICTIONARY:
					local_count += 1
			counts[slot] = local_count
		else:
			counts[slot] = NetworkService.team_prep_merc_ids(slot, GameState.round_index).size()
	return counts

func _check_team_merc_alert() -> void:
	if GameState.tutorial_mode or _team_merc_alert == null:
		return
	var current := _team_merc_counts()
	if not _team_merc_snapshot_initialized or _team_merc_snapshot_round != GameState.round_index:
		_team_merc_counts_snapshot = current
		_team_merc_snapshot_round = GameState.round_index
		_team_merc_snapshot_initialized = true
		return

	var increased := false
	for slot_value in current:
		var slot := int(slot_value)
		if int(current.get(slot, 0)) > int(_team_merc_counts_snapshot.get(slot, 0)):
			increased = true
			break
	_team_merc_counts_snapshot = current
	if not increased:
		return
	if _team_mercs_open:
		_team_merc_alert.mark_seen()
		_refresh_team_mercs_overlay()
	else:
		_team_merc_alert.notify_summon()

func _close_team_mercs_picker() -> void:
	if not _team_mercs_open:
		return
	_team_mercs_open = false
	_refresh_team_mercs_overlay()

func _refresh_team_mercs_overlay() -> void:
	if not _team_mercs_open:
		# 关：交给 ModalStack。content 连同 SubViewport、舞台模型和它们的
		# AnimationPlayer 一起被销毁 —— 迁移前是「留在树里但不渲染」，
		# 靠手动清空子节点防止空转；现在整棵子树都不在了，那个隐患从根上消失。
		# 业务状态由 modal_closed 统一收口（见 _on_team_mercs_modal_closed）。
		if ModalStack.has(TEAM_MERCS_MODAL_ID):
			ModalStack.pop(TEAM_MERCS_MODAL_ID, ModalStack.REASON_PROGRAMMATIC)
		else:
			_team_mercs_teardown_state()
		return

	if not ModalStack.has(TEAM_MERCS_MODAL_ID):
		var content := _create_team_mercs_content()
		var modal_id := ModalStack.push(content, {
			"id": TEAM_MERCS_MODAL_ID,
			"owner": self,
			"priority": TEAM_MERCS_MODAL_PRIORITY,
			# 点内容矩形之外即关。迁移前玩家就是靠侧栏那个按钮再点一下关掉的，
			# 而 backdrop 现在会吃掉那一下 —— 对玩家而言仍是「点它就关」。
			"dismiss_on_backdrop": true,
			# 迁移前 overlay 之外没有任何变暗，backdrop 再上色就是改视觉。
			"backdrop_color": Color.TRANSPARENT,
		})
		if modal_id.is_empty():
			# 上面已用 has() 挡过重复，走到这里说明 push 真的失败了。
			# content 已由 push 收走，不能再 free；把刚写进成员的引用清掉。
			_team_mercs_open = false
			_team_mercs_teardown_state()
			return
		_team_mercs_overlay = content
		_sync_team_mercs_content_rect()

	_rebuild_team_mercs_stage()
	if _team_mercs_render_timer != null and _team_mercs_render_timer.is_stopped():
		_team_mercs_render_timer.start()

func _team_mercs_entries() -> Array:
	# 自己的佣兵直接读本地状态（永远最新）；队友的走备战期同步。
	# AI/占位座位不会有同步数据，自然空着。
	var my_slot := NetworkService.team_local_slot if NetworkService.team_active else 0
	if my_slot < 0:
		my_slot = 0
	var first := GameConstants.team_first_slot(GameConstants.team_of_slot(my_slot))
	var out: Array = []
	for slot in range(first, first + GameConstants.TEAM_SIDE_SIZE):
		var ids: Array = []
		if slot == my_slot:
			for cell in GameState.mercenary_slots:
				if typeof(cell) == TYPE_DICTIONARY:
					ids.append(str((cell as Dictionary).get("id", "")))
		else:
			ids = NetworkService.team_prep_merc_ids(slot, GameState.round_index)
		for i in ids.size():
			out.append({"slot": slot, "index": i, "id": str(ids[i])})
	return out

func _rebuild_team_mercs_stage() -> void:
	if _team_mercs_stage_root == null:
		return
	var entries := _team_mercs_entries()
	var sig := JSON.stringify([GameState.round_index, entries])
	if sig == _team_mercs_stage_signature:
		return
	_team_mercs_stage_signature = sig
	for child in _team_mercs_stage_root.get_children():
		child.queue_free()
	if _team_mercs_empty_label != null:
		_team_mercs_empty_label.visible = entries.is_empty()
	var defs := {}
	for row in (DataRegistry.get_table("mercenaries").get("mercenaries", []) as Array):
		defs[str((row as Dictionary).get("id", ""))] = row
	var taken: Array = []
	for entry_value in entries:
		var entry: Dictionary = entry_value
		var def_value = defs.get(str(entry.get("id", "")))
		if typeof(def_value) != TYPE_DICTIONARY:
			continue
		var def: Dictionary = def_value
		var slot := int(entry.get("slot", 0))
		# 每回合固定的随机站位：种子=回合+槽位+序号，重开弹窗不变，
		# 后买的佣兵也不会挪动先前佣兵的位置。
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("team_mercs_%d_%d_%d" % [GameState.round_index, slot, int(entry.get("index", 0))])
		var pos := _team_mercs_spot(rng, taken)
		taken.append(pos)
		var cell := {"id": str(entry.get("id", "")), "star": 1, "def": def, "is_mercenary": true}
		var pivot := _make_prep_board_model(cell, def)
		if pivot == null:
			continue
		# 模型已不带 3D 名字/星级浮标，队伍佣兵检阅台本就不需要显示，无需再隐藏。
		pivot.position = pos
		pivot.rotation_degrees = Vector3(0.0, float(def.get("model_base_yaw", 180.0)) + rng.randf_range(-20.0, 20.0), 0.0)
		_team_mercs_stage_root.add_child(pivot)
		_team_mercs_stage_root.add_child(_make_team_mercs_plate(slot, pos))

func _team_mercs_spot(rng: RandomNumberGenerator, taken: Array) -> Vector3:
	var candidate := Vector3.ZERO
	for attempt in 24:
		candidate = Vector3(
			rng.randf_range(-TEAM_MERCS_AREA_HALF.x, TEAM_MERCS_AREA_HALF.x),
			0.0,
			rng.randf_range(-TEAM_MERCS_AREA_HALF.y, TEAM_MERCS_AREA_HALF.y)
		)
		var clear := true
		for taken_pos in taken:
			if candidate.distance_to(taken_pos) < TEAM_MERCS_MIN_DIST:
				clear = false
				break
		if clear:
			return candidate
	return candidate

func _make_team_mercs_plate(slot: int, pos: Vector3) -> MeshInstance3D:
	var plate := MeshInstance3D.new()
	var plate_mesh := CylinderMesh.new()
	plate_mesh.top_radius = TEAM_MERCS_PLATE_RADIUS
	plate_mesh.bottom_radius = TEAM_MERCS_PLATE_RADIUS
	plate_mesh.height = TEAM_MERCS_PLATE_HEIGHT
	plate.mesh = plate_mesh
	var plate_material := StandardMaterial3D.new()
	plate_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	plate_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var slot_color := GameConstants.team_slot_color(slot)
	plate_material.albedo_color = Color(slot_color.r, slot_color.g, slot_color.b, 0.92)
	plate.material_override = plate_material
	plate.position = Vector3(pos.x, TEAM_MERCS_PLATE_HEIGHT * 0.5, pos.z)
	return plate
func _refresh_owned_treasure_logos() -> void:
	if _treasure._owned_treasure_box == null:
		return
	# 联动 logo 完全由已拥有宝物推导，所以签名只需 owned_treasures。
	var sig := JSON.stringify(GameState.owned_treasures)
	if sig == _owned_logos_signature:
		return
	_owned_logos_signature = sig
	for child in _treasure._owned_treasure_box.get_children():
		child.queue_free()
	# Owned treasures.
	for tid in GameState.owned_treasures:
		var tid_str := str(tid)
		var t := TreasureService.treasure_by_id(tid)
		_add_owned_treasure_logo(str(t.get("name", tid_str)), _treasure.show_detail.bind(tid_str))
	# Active linkages (their required treasures are all owned) get their own logo too.
	var links: Array = DataRegistry.get_table("treasures").get("linkages", [])
	for link in links:
		var lid := str(link.get("id", ""))
		if TREASURE_LINKAGE_LOGOS.has(lid) and TreasureService.has_linkage(lid):
			_add_owned_treasure_logo(str(TREASURE_LINKAGE_LOGOS[lid]), _show_linkage_detail.bind(lid))

func _add_owned_treasure_logo(logo_name: String, detail: Callable) -> void:
	var b := Button.new()
	b.text = ""
	b.tooltip_text = logo_name
	b.custom_minimum_size = Vector2(66, 66)
	b.focus_mode = Control.FOCUS_NONE
	PrepWidgets.apply_empty_button_styles(b)
	var logo := TextureRect.new()
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	logo.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	logo.texture = PrepWidgets.cached_texture("%s/%s.png" % [TREASURE_LOGO_DIRECTORY, logo_name])
	b.add_child(logo)
	if detail.is_valid():
		b.pressed.connect(detail)
	_treasure._owned_treasure_box.add_child(b)

func _maybe_show_pvp_warning(kind: String) -> void:
	if kind != "pvp" and kind != "final":
		return
	_show_pvp_warning_overlay()

# PvP / 最终战的开战播报。**没有任何决策**：不确认、不取消、不可点掉，
# 停 2 秒自己淡出。
#
# 输入拦截由 ModalStack 的 backdrop 独占（V3 P0-07 / P1-03，C-11 的 C5）。
# 迁移前这里自己铺了一层全屏 MOUSE_FILTER_STOP，代价是两个真实缺陷：
#   * 2 秒内二次触发会叠出第二层 STOP —— 函数没有任何防叠守卫；
#   * 函数里有 await，宿主在这 2 秒内被释放时，恢复后会在已释放节点上
#     建 tween 并 queue_free。
# 现在两条都由 ModalStack 兜住：同 id 去重挡住前者，owner + 内容自持的
# 计时器挡住后者（计时器随模态摘树而停，协程永远不会在死对象上恢复）。
func _show_pvp_warning_overlay() -> void:
	var tex := PrepWidgets.cached_texture(PVP_WARNING_FRAME_PATH)
	if tex == null:
		return
	var overlay := Control.new()
	overlay.name = "PvPWarningOverlay"
	# content 不再拦输入：全屏 STOP 只能有一块，且必须是 ModalStack 管理的那块，
	# 否则 _reindex() 管不到它，就会变成清点里说的「看不见却仍然 STOP」。
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.0)
	# ColorRect 的默认 mouse_filter 就是 STOP，必须显式关掉。
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)

	var center := Control.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.anchor_left = 0.5
	center.anchor_top = 0.5
	center.anchor_right = 0.5
	center.anchor_bottom = 0.5
	center.offset_left = -600
	center.offset_top = -310
	center.offset_right = 600
	center.offset_bottom = 310
	center.pivot_offset = Vector2(600, 310)
	center.modulate.a = 0.0
	center.scale = Vector2(0.90, 0.90)
	overlay.add_child(center)

	var glow := TextureRect.new()
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.texture = tex
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glow.modulate = Color(1.0, 0.05, 0.02, 0.28)
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var glow_mat := CanvasItemMaterial.new()
	glow_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	glow.material = glow_mat
	center.add_child(glow)

	var frame := TextureRect.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.texture = tex
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.add_child(frame)

	var title := Label.new()
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.text = "Showdown Time!" if LocaleManager.get_locale() == "en" else "敌袭快准备！"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	title.offset_top = 90
	title.offset_bottom = -70
	title.add_theme_font_size_override("font_size", 72)
	title.add_theme_color_override("font_color", Color(1.0, 0.05, 0.02))
	title.add_theme_color_override("font_outline_color", Color(0.10, 0.0, 0.0, 0.95))
	title.add_theme_constant_override("outline_size", 6)
	center.add_child(title)

	# 停留计时器挂在 content 上，**不是** get_tree().create_timer()。
	# 这是「协程绝不会在死对象上恢复」的关键：模态因任何原因被 pop（owner 释放、
	# close_all、程序化关闭）时，ModalStack._teardown() 会同帧 remove_child，
	# content 连同这个 Timer 一起离树、停止计时，timeout 永远不发，
	# 下面的 await 就永远不恢复 —— 而不是恢复之后再去判「我还活着吗」。
	var dwell := Timer.new()
	dwell.name = "PvPWarningDwell"
	dwell.one_shot = true
	dwell.wait_time = PVP_WARNING_DWELL_SEC
	overlay.add_child(dwell)

	# 入栈。同 id 已在栈上（2 秒内重复触发）时返回空串，且 push 已经把 overlay
	# 收掉了 —— 这里绝不能再 queue_free 一次。
	var modal_id := ModalStack.push(overlay, {
		"id": PVP_WARNING_MODAL_ID,
		"owner": self,
		"priority": PVP_WARNING_MODAL_PRIORITY,
		"dismiss_on_backdrop": false,
		# 变暗由下面的 dim 用 tween 做（0 → 0.48），backdrop 只负责挡输入，
		# 不能再叠一层颜色，否则画面比迁移前更暗。
		"backdrop_color": Color.TRANSPARENT,
	})
	if modal_id.is_empty():
		return

	dwell.start()

	# tween 绑到 content：模态被提前 pop 时随之作废，不会在已释放节点上继续跑。
	var tween := create_tween().bind_node(overlay)
	tween.set_parallel(true)
	tween.tween_property(dim, "color:a", 0.48, 0.12)
	tween.tween_property(center, "modulate:a", 1.0, 0.12)
	tween.tween_property(center, "scale", Vector2(1.04, 1.04), 0.12)
	tween.set_parallel(false)
	tween.tween_property(center, "scale", Vector2.ONE, 0.13)

	var glow_tween := create_tween().bind_node(overlay).set_loops()
	glow_tween.tween_property(glow, "modulate:a", 0.58, 0.35)
	glow_tween.tween_property(glow, "modulate:a", 0.22, 0.35)

	await dwell.timeout

	# 走到这里说明计时器真的响了，也就说明 content 还在树上。仍然再判一次：
	# 同一帧内仍可能有别的路径先把它 pop 掉。
	if not is_instance_valid(overlay) or not ModalStack.has(PVP_WARNING_MODAL_ID):
		return
	if glow_tween != null and glow_tween.is_valid():
		glow_tween.kill()

	var out := create_tween().bind_node(overlay)
	out.set_parallel(true)
	out.tween_property(dim, "color:a", 0.0, PVP_WARNING_FADE_SEC)
	out.tween_property(center, "modulate:a", 0.0, PVP_WARNING_FADE_SEC)
	out.tween_property(center, "scale", Vector2(0.96, 0.96), PVP_WARNING_FADE_SEC)
	await out.finished

	# 收尾走 ModalStack.pop，不是 overlay.queue_free() —— content 的所有权在
	# push 时就交给 ModalStack 了，自己 free 会让栈里留一条指向死节点的记录。
	if ModalStack.has(PVP_WARNING_MODAL_ID):
		ModalStack.pop(PVP_WARNING_MODAL_ID, ModalStack.REASON_PROGRAMMATIC)


# --- 商店面板信号的宿主侧处理（D2 步骤 3′b）---------------------------------

# 商店选中了一张卡：棋盘与待命的选中态归宿主管，清掉它们再整屏刷新。
func _on_shop_card_selected(_index: int) -> void:
	_board_hud._selected_board = -1
	_board_hud._selected_bench = -1
	_refresh_all()


# 商店请求买入：找空位、扣钱、合成都在宿主这边（它们要动棋盘与联机同步）。
func _on_shop_buy_requested(index: int) -> void:
	var empty_bench := PrepRules.first_empty_bench_slot()
	if empty_bench < 0:
		show_message(tr("ui_bench_full"))
		return
	_buy_or_merge_shop_to_bench(index, empty_bench)


# 商店开合：关掉别的弹窗，并调整待命格的输入 ——
# 商店开着时待命格被商店盖住，不禁用的话它们会抢走商店区域的点击。
func _on_shop_picker_toggled(is_open: bool) -> void:
	# 教学第 15 步的「关闭商店」子阶段靠这个真实开合事件推进（V2 P1-07），
	# 不靠延时、不靠轮询面板可见性。与 record_shop_purchase() 同一种接线方式。
	if GameState.tutorial_mode:
		TutorialMode.record_shop_toggled(is_open)
	if is_open:
		_close_merc_picker()
		_close_team_mercs_picker()
	var bench_filter := Control.MOUSE_FILTER_IGNORE if is_open else Control.MOUSE_FILTER_STOP
	for btn in _board_hud.bench_buttons:
		if btn != null:
			btn.mouse_filter = bench_filter



# 棋盘面板要求刷新 3D 层 / 可读性层。这三样都在 PrepBoardModels 那一层，
# 面板不该直接伸手 —— 它只说「哪块脏了」。
func _on_board_visuals_dirty(what: String) -> void:
	match what:
		"board":       _refresh_prep_board_models()
		"standby":     _refresh_prep_standby_models()
		"readability": _sync_prep_board_readability_state()
