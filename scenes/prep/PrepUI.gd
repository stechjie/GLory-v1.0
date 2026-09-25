extends "res://scenes/prep/PrepBoardModels.gd"

# PrepDetails 的宝物说明里也要画种族 logo，所以这个 preload 留在链上；
# 商店面板自己也 preload 了一份 —— 两个文件各自声明依赖，指向同一个脚本，不是重复逻辑。
const PrepShopRaceIcon = preload("res://scenes/prep/PrepShopRaceIcon.gd")

const PrepShopRefreshBurnScript = preload("res://scenes/prep/effects/PrepShopRefreshBurn.gd")
const PrepTeamMercAlertScript = preload("res://scenes/prep/effects/PrepTeamMercAlert.gd")
const TutorialTargetProviderScript := preload("res://scripts/tutorial/TutorialTargetProvider.gd")
const GloryToastScript := preload("res://ui/components/GloryToast.gd")
const GloryTheme := preload("res://ui/theme/GloryTheme.gd")
const GloryTokens := preload("res://ui/theme/GloryTokens.gd")
const AvatarCatalog := preload("res://scripts/account/AvatarCatalog.gd")
# 右上角那个静音键要读「设置页的背景音乐开关」，裁决只在 PresentationSettings 一处
# （同 SfxService / MusicService / UiFeedback 的写法，用 preload 常量而不是全局类名）。
const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")
# 只为拿 FillPhase 枚举做**静态**引用（教学第 15 步的子阶段），
# 走 preload 常量而不是从 autoload 实例上取，dynamic_call 棘轮才不会长。
const TutorialModeScript := preload("res://scripts/tutorial/TutorialMode.gd")
const CarrotCampPanelScript := preload("res://scenes/prep/CarrotCampPanelV3.gd")

# Keep the selector API used by preparation-screen regression checks while the
# redesigned code-drawn panel remains the production implementation.
static func _carrot_camp_panel_script() -> Script:
	return CarrotCampPanelScript

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
const CARROT_BTN_PATH := "res://assets/props/carrot_system/ui/button_carrot_camp.png"
# 局内聊天入口。**刻意与主界面用同一张图**（MainMenu.TEX_CHAT），
# 让「聊天」这个入口在两个界面里长得一样 —— 换图要两处一起换。
const CHAT_BTN_PATH := "res://assets/ui/main_menu_live/chat.png"
const CARROT_CURRENCY_ICON_PATH := "res://assets/props/carrot_system/ui/icon_carrot_currency.png"
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
const LinkageFx := preload("res://scenes/prep/fx/LinkageFx.gd")
# 联动 / 套装激活特效的图层：盖在备战界面（画布 0 层）上，
# 但在返回提示（250）、弹窗（1000 起）、公告（1400）和提示条（1500）之下。
const BONUS_FX_LAYER := 200
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
var _carrot_panel
var _carrot_button: Button
var _carrot_button_label: Label
var _carrot_counter_label: Label
# 萝卜数量那块底板。教学里要指着它（收获萝卜那一步），也要跟入口按钮一起显隐。
var _carrot_counter_panel: PanelContainer
var _carrot_dimmer: ColorRect
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
# 宝藏栏按钮：宝藏 id / 联动 id / 套装 id → 按钮。联动特效靠它找光线起点和落位格子。
var _tray_buttons: Dictionary = {}
# 一次领宝可能同时成立好几条（例如第 4 件攻击宝藏同时凑齐套装和一条联动），依次播。
var _bonus_fx_queue: Array[String] = []
var _bonus_fx_busy := false
var _bonus_fx_layer: CanvasLayer
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
	# 9.25 萝卜 / 四星教学。
	provider.bind_target(TutorialTargetProviderScript.TARGET_CARROT_CAMP,
		_tutorial_target_carrot_camp)
	provider.bind_target(TutorialTargetProviderScript.TARGET_CARROT_COUNTER,
		_tutorial_target_carrot_counter)
	provider.bind_target(TutorialTargetProviderScript.TARGET_CARROT_CLOSE,
		_tutorial_target_carrot_close)
	provider.bind_target(TutorialTargetProviderScript.TARGET_CARROT_CAMP_TAB,
		_tutorial_target_carrot_camp_tab)
	provider.bind_target(TutorialTargetProviderScript.TARGET_CARROT_STONE_TAB,
		_tutorial_target_carrot_stone_tab)
	provider.bind_target(TutorialTargetProviderScript.TARGET_HARVEST_UPGRADE,
		_tutorial_target_harvest_upgrade)
	provider.bind_target(TutorialTargetProviderScript.TARGET_STONE_DRAW,
		_tutorial_target_stone_draw)
	provider.bind_target(TutorialTargetProviderScript.TARGET_FOUR_STAR_ROW,
		_tutorial_target_four_star_row)
	provider.bind_action(TutorialTargetProviderScript.ACTION_CLOSE_MERCENARY,
		_close_merc_picker)
	provider.bind_action(TutorialTargetProviderScript.ACTION_REFRESH_VIEW,
		_tutorial_refresh_view)
	provider.bind_action(TutorialTargetProviderScript.ACTION_PLAY_CARROT_HARVEST,
		_tutorial_play_carrot_harvest)
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
	# Once three units are owned, this step asks the player to close the shop.
	if _shop.picker_open and _tutorial_owned_normal_count() >= 3:
		return _tutorial_first_empty_board()
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
			# The open shop covers its wooden toggle. Point outside it so the
			# normal pointer handler can close the shop at a visible location.
			return _tutorial_first_empty_board()
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


# --- 萝卜 / 四星教学的目标（9.25）----------------------------------------------
# 面板控件由 CarrotCampPanelV3 自己暴露（tutorial_* 取值函数），这里只做转交；
# 营地关着时这些控件仍然有效（只是不可见），所以语义目标在实屏上总能解析出来。

func _tutorial_carrot_panel() -> CarrotCampPanelScript:
	if _carrot_panel == null or not is_instance_valid(_carrot_panel):
		return null
	return _carrot_panel as CarrotCampPanelScript


func _tutorial_target_carrot_camp() -> Control:
	return _carrot_button


func _tutorial_target_carrot_counter() -> Control:
	if _carrot_counter_panel != null and is_instance_valid(_carrot_counter_panel):
		return _carrot_counter_panel
	return _carrot_button


func _tutorial_target_carrot_close() -> Control:
	var panel := _tutorial_carrot_panel()
	return panel.tutorial_close_button() if panel != null else _carrot_button


func _tutorial_target_carrot_camp_tab() -> Control:
	var panel := _tutorial_carrot_panel()
	return panel.tutorial_camp_tab() if panel != null else _carrot_button


func _tutorial_target_carrot_stone_tab() -> Control:
	var panel := _tutorial_carrot_panel()
	return panel.tutorial_stone_tab() if panel != null else _carrot_button


func _tutorial_target_harvest_upgrade() -> Control:
	var panel := _tutorial_carrot_panel()
	return panel.tutorial_harvest_button() if panel != null else _carrot_button


func _tutorial_target_stone_draw() -> Control:
	var panel := _tutorial_carrot_panel()
	return panel.tutorial_draw_button() if panel != null else _carrot_button


func _tutorial_target_four_star_row() -> Control:
	var panel := _tutorial_carrot_panel()
	return panel.tutorial_four_star_target() if panel != null else _carrot_button


# 教学那一次收获的表现：与正式局进备战时同一段（宠物挖萝卜 + 「+N」）。
# 单机只有 4 号位一只宠物（见 _carrot_pet_entries）。
func _tutorial_play_carrot_harvest() -> void:
	var gain := TutorialMode.last_harvest_gain()
	_refresh_carrot_counter()
	play_carrot_harvest_feedback.call_deferred({4: gain})


# 萝卜入口在教学里从萝卜那一步才出现（TutorialMode.carrot_ui_unlocked）。
func _carrot_ui_visible() -> bool:
	return not GameState.tutorial_mode or TutorialMode.carrot_ui_unlocked()


func _report_carrot_camp_state() -> void:
	if not GameState.tutorial_mode:
		return
	var panel := _tutorial_carrot_panel()
	if panel == null:
		return
	TutorialMode.record_carrot_camp_state(panel.visible, panel.current_page())


func _build(staged: bool = false) -> void:
	if not LocaleManager.locale_changed.is_connected(_on_locale_changed):
		LocaleManager.locale_changed.connect(_on_locale_changed)
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
	if not NetworkService.economy_receipt.is_connected(_on_carrot_economy_receipt):
		NetworkService.economy_receipt.connect(_on_carrot_economy_receipt)

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
	if staged:
		StartupTrace.mark("tutorial_background_built")
		await get_tree().process_frame
	_setup_prep_river_background()
	if staged:
		StartupTrace.mark("tutorial_board_built")
		await get_tree().process_frame

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 12
	root.offset_top = 10
	root.offset_right = -12
	root.offset_bottom = -10
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	_build_top_bar(root)
	if staged:
		await get_tree().process_frame
	_build_rest(root)
	if staged:
		StartupTrace.mark("tutorial_controls_built")
		await get_tree().process_frame

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


func _on_locale_changed(_locale: String) -> void:
	if _carrot_button_label != null and is_instance_valid(_carrot_button_label):
		_carrot_button_label.text = "Carrot Camp" if LocaleManager.get_locale().begins_with("en") else "萝卜营地"
	_refresh_carrot_counter()

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
	side_col.offset_bottom = 2 + TOP_ROW_BTN_SIZE.y + 6 + MERC_BTN_SIZE.y * 3.0 + 50
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

	# 独立的萝卜入口放在两枚既有佣兵按钮下方。
	var carrot_btn := PrepWidgets.make_framed_text_button("", CARROT_BTN_PATH,
		MERC_BTN_SIZE, 16, _toggle_carrot_camp)
	_carrot_button = carrot_btn
	var carrot_lbl := Label.new()
	_carrot_button_label = carrot_lbl
	carrot_lbl.text = "Carrot Camp" if LocaleManager.get_locale().begins_with("en") else "萝卜营地"
	carrot_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	carrot_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	carrot_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	carrot_lbl.anchor_left = 0.12
	carrot_lbl.anchor_right = 0.88
	carrot_lbl.anchor_top = 0.72
	carrot_lbl.anchor_bottom = 0.93
	carrot_lbl.add_theme_font_size_override("font_size", 14)
	carrot_lbl.add_theme_color_override("font_color", Color(1.0, 0.94, 0.78))
	carrot_lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	carrot_lbl.add_theme_constant_override("outline_size", 3)
	carrot_btn.add_child(carrot_lbl)
	carrot_btn.visible = _carrot_ui_visible()
	side_col.add_child(carrot_btn)

	# 萝卜持有量常驻在入口下方，玩家无需打开营地即可查看。
	var carrot_counter := PanelContainer.new()
	carrot_counter.name = "CarrotResourceCounter"
	carrot_counter.custom_minimum_size = Vector2(MERC_BTN_SIZE.x, 32)
	carrot_counter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	carrot_counter.visible = _carrot_ui_visible()
	_carrot_counter_panel = carrot_counter
	var counter_style := StyleBoxFlat.new()
	counter_style.bg_color = Color(0.075, 0.095, 0.055, 0.94)
	counter_style.border_color = Color(0.78, 0.57, 0.20, 0.92)
	counter_style.set_border_width_all(2)
	counter_style.set_corner_radius_all(10)
	counter_style.content_margin_left = 10
	counter_style.content_margin_right = 10
	counter_style.content_margin_top = 3
	counter_style.content_margin_bottom = 3
	carrot_counter.add_theme_stylebox_override("panel", counter_style)
	var counter_row := HBoxContainer.new()
	counter_row.alignment = BoxContainer.ALIGNMENT_CENTER
	counter_row.add_theme_constant_override("separation", 5)
	counter_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	carrot_counter.add_child(counter_row)
	var counter_icon := TextureRect.new()
	counter_icon.custom_minimum_size = Vector2(22, 22)
	counter_icon.texture = load(CARROT_CURRENCY_ICON_PATH)
	counter_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	counter_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	counter_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	counter_row.add_child(counter_icon)
	_carrot_counter_label = Label.new()
	_carrot_counter_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_carrot_counter_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_carrot_counter_label.add_theme_font_size_override("font_size", 16)
	_carrot_counter_label.add_theme_color_override("font_color", Color(1.0, 0.94, 0.70))
	_carrot_counter_label.add_theme_color_override("font_outline_color", Color(0.02, 0.025, 0.01, 0.95))
	_carrot_counter_label.add_theme_constant_override("outline_size", 2)
	_carrot_counter_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	counter_row.add_child(_carrot_counter_label)
	side_col.add_child(carrot_counter)
	_refresh_carrot_counter()

	# The camp is a focused mobile modal.  A restrained scrim keeps the busy
	# battlefield readable as context while giving the controls clear priority.
	_carrot_dimmer = ColorRect.new()
	_carrot_dimmer.name = "CarrotCampDimmer"
	_carrot_dimmer.color = Color(0.02, 0.035, 0.025, 0.68)
	_carrot_dimmer.mouse_filter = Control.MOUSE_FILTER_STOP
	_carrot_dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_carrot_dimmer.z_index = 34
	_carrot_dimmer.visible = false
	_carrot_dimmer.gui_input.connect(_on_carrot_dimmer_input)
	add_child(_carrot_dimmer)

	_carrot_panel = _carrot_camp_panel_script().new()
	_carrot_panel.name = "CarrotCampPanel"
	_carrot_panel.anchor_left = 0.5
	_carrot_panel.anchor_right = 0.5
	_carrot_panel.anchor_top = 0.5
	_carrot_panel.anchor_bottom = 0.5
	_carrot_panel.offset_left = -380
	_carrot_panel.offset_right = 380
	_carrot_panel.offset_top = -260
	_carrot_panel.offset_bottom = 260
	_carrot_panel.z_index = 35
	_carrot_panel.visible = false
	# The concrete economy handlers live farther down the PrepScreen inheritance
	# chain. String callables keep this reusable UI layer independently parsable.
	_carrot_panel.setup(Callable(self, "request_carrot_harvest_upgrade"),
		Callable(self, "request_upgrade_stone_draw"),
		Callable(self, "request_four_star_upgrade"))
	_carrot_panel.closed.connect(_close_carrot_camp)
	_carrot_panel.page_changed.connect(func(_page: int): _report_carrot_camp_state())
	add_child(_carrot_panel)

	_build_chat_entry()

# ── 局内快捷短语（docs/聊天系统设计.md 批次 A）─────────────────────────────
#
# 走 ③ 的 ENet，网络上只有 {seat, phrase_id} 两个整数和一个范围开关 team_only。协议与理由见
# NetworkService.team_send_phrase 与 scripts/multiplayer/ChatPhrases.gd。
#
# 🔴 **备战阶段不能挡棋盘。** 这是玩家操作最密集的阶段（拖棋子、买卖），所以：
#   - 入口是折叠的：平时只有一颗按钮，短语面板点开才有
#   - **不上遮罩** —— 萝卜营地那种全屏 dimmer 在这里是错的，
#     玩家要能一边看着棋盘一边发短语
#   - 消息条的 mouse_filter 一律 IGNORE，绝不能吃掉落在它下面的棋盘点击
#
# 收到的消息**常驻显示在按钮上方并自动淡出**，不点开面板也看得见，
# 所以这里不需要未读红点。局内的聊天是「瞥一眼」，不是「读列表」。

const ChatPhrases := preload("res://scripts/multiplayer/ChatPhrases.gd")

const CHAT_BTN_SIZE := Vector2(72, 72)

# 🔴 **聊天整块必须让开右侧那一列，横竖两个方向都要让。**
#
# 2026-09-10 实测（tools/chat_ui_capture.tscn，1280×720）：第一版把聊天贴着屏幕
# 右缘、按钮锚在 offset_top=-340，结果正好盖住萝卜计数器，消息条压在萝卜按钮旁边。
# **941 高时一点问题都没有** —— 因为两边用的是不同的锚：
#
#   side_col（佣兵 / 队伍佣兵 / 萝卜 / 萝卜计数）  从**屏幕顶部**往下固定排到 y=518
#   聊天入口                                      从**屏幕底部**往上锚
#
# 窗口越矮，两者越近；到 720 就撞上了。所以：
#   横向 —— 右边界收到 -148，让开那一列（STATS_BTN_SIZE.x=140 + 贴边 8）
#   纵向 —— 整组收在底边 -120 ~ -32，给备战席留出 40px 以上的空档。
#
# 改这几个数之前先跑一次那个截图工具，**用矮窗口看**，别用参考画布的高度。
const CHAT_RIGHT := 148.0
const COMMS_DOCK_WIDTH := 288.0
const COMMS_DOCK_HEIGHT := 88.0
const COMMS_DOCK_BOTTOM := -32.0
const CHAT_BTN_BOTTOM := -40.0
const CHAT_LOG_WIDTH := 360.0
const CHAT_PANEL_HEIGHT := 410.0
const CHAT_FLOAT_GAP := 10.0

const CHAT_LOG_LINES := 3
# 消息条高度。批次 A 时是 122（3 条单行短语）；批次 D 加了会折行的自由文字，放大到 156。
const CHAT_LOG_HEIGHT := 156.0
const CHAT_LOG_FONT_SIZE := 17
# 折行之后合计最多几行（_push_chat_line 按它整条移走旧消息）。6 行加上条与条之间的
# 间距放得进 156。最坏的一条（24 字昵称 + 40 字）在 352 宽里是 4 行，最新那条永远放得下。
const CHAT_LOG_TEXT_LINES := 6
# 自由文字（批次 D）：输入条贴在屏幕顶部，理由见 ChatInputBar.gd 顶部（手机键盘）。
const ChatInputBar := preload("res://ui/components/ChatInputBar.gd")
const CHAT_LINE_HOLD_SEC := 6.0        # 停留多久之后开始淡出
const CHAT_LINE_FADE_SEC := 1.0
# 与 Team3v3Lobby.SLOT_LABELS 一致。⚠️ 两处都有，改一个必须改另一个 ——
# 对不上的症状是同一个人在大厅显示成「席位B」、局内显示成「席位2」。
const CHAT_SEAT_LABELS := ["A", "B", "C", "1", "2", "3"]

var _chat_button: Button = null
var _chat_panel: PanelContainer = null
var _chat_log: VBoxContainer = null
var _comms_dock: PanelContainer = null

# 🔴 聊天范围（2026-09-14 定，协议 26）：**备战期默认只发给队友**，点「发给：…」切到全部。
# 局内说的基本是战术（存钱、升星、谁顶前排），默认全部的话忘了切就被对面看到。
# 开关跟着这个界面走：PrepScreen 每回合重建（Main._show_prep），所以每回合备战期开始时回到「队友」——
# 上回合为了跟对面说一句切到了「全部」，这回合不会带着它把战术发出去。
# 谁收得到由 ③ 决定（NetworkService.chat_recipients），这里只是选。
var _chat_team_only := true
var _chat_scope_button: Button = null
# 消息前面的范围标记。队友频道是默认，**不加标记**，只标出例外。
# tools/chat_check 读这两个常量算「最长一条放不放得下」，改字要跟着跑一次。
const CHAT_TAG_ALL := "【全部】"      # 自己人发到全部：这条对面也看得到
const CHAT_TAG_ENEMY := "【对方】"    # 对面的人发的（他们只能发到全部）
const CHAT_TEAM_COLOR := Color(1.0, 0.94, 0.78)
const CHAT_ALL_COLOR := Color(1.0, 0.76, 0.42)
const CHAT_ENEMY_COLOR := Color(1.0, 0.56, 0.50)
const CHAT_MENU_FONT_COLOR := Color(1.0, 0.90, 0.60)   # make_menu_button 的默认字色

func _build_chat_entry() -> void:
	# 只在联机 3v3 里建。单机与教学没有队友，一个永远不会有人说话的入口是纯噪音 ——
	# 同 carrot_btn / team_mercs_btn 那两句 `visible = not GameState.tutorial_mode`。
	if GameState.tutorial_mode or not NetworkService.team_active:
		return

	_build_comms_dock()
	_chat_button = PrepWidgets.make_framed_text_button("", CHAT_BTN_PATH, CHAT_BTN_SIZE, 16,
		_toggle_chat_panel)
	_chat_button.name = "PrepChatButton"
	_chat_button.anchor_left = 1.0
	_chat_button.anchor_right = 1.0
	_chat_button.anchor_top = 1.0
	_chat_button.anchor_bottom = 1.0
	# 右侧保留 148，让开佣兵 / 萝卜的侧栏；按钮与语音两键共用同一底板。
	_chat_button.offset_right = -CHAT_RIGHT
	_chat_button.offset_left = -CHAT_RIGHT - CHAT_BTN_SIZE.x
	_chat_button.offset_bottom = CHAT_BTN_BOTTOM
	_chat_button.offset_top = CHAT_BTN_BOTTOM - CHAT_BTN_SIZE.y
	# z_index 刻意低于商店弹窗(40)与卖出区(50)：**商店开着的时候聊天就该点不到**。
	# 那时玩家在买卖，一个压在商店上的聊天按钮只会造成误触。
	_chat_button.z_index = 20
	add_child(_chat_button)
	_build_voice_button()

	_chat_log = VBoxContainer.new()
	_chat_log.name = "PrepChatLog"
	_chat_log.anchor_left = 1.0
	_chat_log.anchor_right = 1.0
	_chat_log.anchor_top = 1.0
	_chat_log.anchor_bottom = 1.0
	# 贴在整个通讯栏正上方，右边界与聊天按钮对齐。
	_chat_log.offset_right = -CHAT_RIGHT
	_chat_log.offset_left = -CHAT_RIGHT - CHAT_LOG_WIDTH
	_chat_log.offset_bottom = COMMS_DOCK_BOTTOM - COMMS_DOCK_HEIGHT - CHAT_FLOAT_GAP
	_chat_log.offset_top = _chat_log.offset_bottom - CHAT_LOG_HEIGHT
	_chat_log.alignment = BoxContainer.ALIGNMENT_END
	# 内容万一比 CHAT_LOG_HEIGHT 高（字体行高与估算不符时），往上长、不往下长 ——
	# 往下会压到聊天按钮上。正常情况下行数预算已经保证放得下。
	_chat_log.grow_vertical = Control.GROW_DIRECTION_BEGIN
	# 🔴 消息条压在棋盘右下方的空域上。IGNORE 不能省 —— 少了它，
	# 一条飘过的消息会把它盖住的那格棋盘变成点不动的，而玩家只会觉得「卡了」。
	_chat_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chat_log.add_theme_constant_override("separation", 4)
	_chat_log.z_index = 20
	add_child(_chat_log)

	_build_chat_panel()
	if not NetworkService.team_chat_received.is_connected(_on_prep_chat_received):
		NetworkService.team_chat_received.connect(_on_prep_chat_received)
	if not NetworkService.team_chat_text_received.is_connected(_on_prep_chat_text_received):
		NetworkService.team_chat_text_received.connect(_on_prep_chat_text_received)

# 语音按钮 + 队友按钮：缩短整组宽度，但两键都不低于 48px 触控下限。
# 72 + 8 + 56 + 4 + 128 = 268，比旧布局窄 26px，与金币卷轴的距离反而更大。
# 改这几个数之前同样先跑 tools/chat_ui_capture.tscn，用矮窗口看。行为都在 VoiceControls 里。
const VoiceControls := preload("res://ui/components/VoiceControls.gd")
const VOICE_BTN_SIZE := Vector2(128, 56)
const VOICE_MEMBERS_SIZE := Vector2(56, 56)
const VOICE_BTN_GAP := 8.0
const VOICE_INNER_GAP := 4.0
const VOICE_BTN_BOTTOM := -48.0
const VOICE_BTN_FONT := 13
var _voice_controls: VoiceControls = null

func _build_comms_dock() -> void:
	_comms_dock = PanelContainer.new()
	_comms_dock.name = "PrepCommsDock"
	_comms_dock.anchor_left = 1.0
	_comms_dock.anchor_right = 1.0
	_comms_dock.anchor_top = 1.0
	_comms_dock.anchor_bottom = 1.0
	_comms_dock.offset_right = -CHAT_RIGHT + 10.0
	_comms_dock.offset_left = _comms_dock.offset_right - COMMS_DOCK_WIDTH
	_comms_dock.offset_bottom = COMMS_DOCK_BOTTOM
	_comms_dock.offset_top = COMMS_DOCK_BOTTOM - COMMS_DOCK_HEIGHT
	_comms_dock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_comms_dock.z_index = 19
	_comms_dock.add_theme_stylebox_override("panel",
		GloryTokens.flat_box(GloryTokens.INK_PANEL, GloryTokens.INK_EDGE, 2, 18))
	add_child(_comms_dock)

func _build_voice_button() -> void:
	_voice_controls = VoiceControls.new()
	_voice_controls.build(self, VOICE_BTN_SIZE, VOICE_MEMBERS_SIZE, VOICE_BTN_FONT,
		{"panel_context": "prep"})
	var right := -CHAT_RIGHT - CHAT_BTN_SIZE.x - VOICE_BTN_GAP
	_place_voice_button(_voice_controls.members_button, right, VOICE_MEMBERS_SIZE)
	_place_voice_button(_voice_controls.voice_button, right - VOICE_MEMBERS_SIZE.x - VOICE_INNER_GAP, VOICE_BTN_SIZE)

func _place_voice_button(button: Button, right: float, size: Vector2) -> void:
	button.anchor_left = 1.0
	button.anchor_right = 1.0
	button.anchor_top = 1.0
	button.anchor_bottom = 1.0
	button.offset_right = right
	button.offset_left = right - size.x
	button.offset_bottom = VOICE_BTN_BOTTOM
	button.offset_top = VOICE_BTN_BOTTOM - size.y
	# 同聊天按钮：低于商店弹窗（40）与卖出区（50），商店开着时点不到。
	button.z_index = 20
	add_child(button)

func _build_chat_panel() -> void:
	_chat_panel = PanelContainer.new()
	_chat_panel.name = "PrepChatPanel"
	_chat_panel.anchor_left = 1.0
	_chat_panel.anchor_right = 1.0
	_chat_panel.anchor_top = 1.0
	_chat_panel.anchor_bottom = 1.0
	# **往上弹**，与消息条同一列（右边界对齐、同宽）。
	# 不往左弹：那会横穿到棋盘中央去；往上只压掉自己那几条消息，代价最小。
	_chat_panel.offset_right = -CHAT_RIGHT
	_chat_panel.offset_left = -CHAT_RIGHT - CHAT_LOG_WIDTH
	_chat_panel.offset_bottom = COMMS_DOCK_BOTTOM - COMMS_DOCK_HEIGHT - CHAT_FLOAT_GAP
	_chat_panel.offset_top = _chat_panel.offset_bottom - CHAT_PANEL_HEIGHT
	_chat_panel.z_index = 30
	_chat_panel.visible = false
	var style := GloryTokens.flat_box(GloryTokens.INK_PANEL, GloryTokens.INK_EDGE, 2, 12)
	style.set_content_margin_all(12)
	_chat_panel.add_theme_stylebox_override("panel", style)
	add_child(_chat_panel)

	# 两列。一列放不下 12 条（会比棋盘还高），三列会让「我这边有点难」这种
	# 六字短语被截断。
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	_chat_panel.add_child(col)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	col.add_child(header)
	var title := Label.new()
	title.text = "Team Chat" if LocaleManager.get_locale() == "en" else "队伍交流"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 19)
	title.add_theme_color_override("font_color", GloryTokens.GOLD_HOVER)
	header.add_child(title)
	var close_button := PrepWidgets.make_menu_button("×", Vector2(42, 38), 19, _toggle_chat_panel)
	close_button.name = "PrepChatClose"
	header.add_child(close_button)
	# 自由输入是一个会弹出键盘的输入入口，不是第 13 条快捷短语。它保持在面板最上面，
	# 用浅羊皮纸底与左对齐的 placeholder 语言明确表达「点这里输入」；右边范围按钮仍是
	# 次要操作。合起来等于下面两列短语的宽度（206 + 间距 6 + 114 = 160 × 2 + 6）。
	# 用 make_menu_button 而不是 Button.new()：不涨 V3 P1-08 棘轮的计数，再单独覆盖外观。
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 6)
	col.add_child(top_row)
	var type_button := PrepWidgets.make_menu_button(
		"✎  Type a message…" if LocaleManager.get_locale() == "en" else "✎  点击输入文字…",
		Vector2(206, 48), 17, _open_text_input)
	type_button.name = "PrepChatType"
	_apply_chat_type_button_style(type_button)
	top_row.add_child(type_button)
	_chat_scope_button = PrepWidgets.make_menu_button(_chat_scope_text(), Vector2(114, 48), 15,
		_toggle_chat_scope)
	_chat_scope_button.name = "PrepChatScope"
	top_row.add_child(_chat_scope_button)
	_refresh_chat_scope_button()

	var phrases_label := Label.new()
	phrases_label.text = "QUICK PHRASES" if LocaleManager.get_locale() == "en" else "快捷短语"
	phrases_label.add_theme_font_size_override("font_size", 13)
	phrases_label.add_theme_color_override("font_color", GloryTokens.TEXT_SECONDARY)
	col.add_child(phrases_label)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	col.add_child(grid)
	for group in ChatPhrases.GROUP_ORDER:
		for phrase_id in ChatPhrases.ids_in_group(group):
			grid.add_child(PrepWidgets.make_menu_button(
				ChatPhrases.text(phrase_id), Vector2(160, 38), 15,
				_send_chat_phrase.bind(int(phrase_id))))


func _apply_chat_type_button_style(button: Button) -> void:
	# 做成「可点击的输入框」，而不是另一颗快捷短语按钮。颜色全部取 GloryTokens，
	# 避免这块以后与主菜单的羊皮纸/暖金方向分叉。
	var normal := GloryTokens.flat_box(
		GloryTokens.PARCHMENT_BUTTON, GloryTokens.GOLD_EDGE, 2, 10)
	var hover := GloryTokens.flat_box(
		GloryTokens.PARCHMENT, GloryTokens.GOLD_HOVER, 2, 10)
	var pressed := GloryTokens.flat_box(
		GloryTokens.PARCHMENT_SOFT, GloryTokens.GOLD_PRESSED, 2, 10)
	for style in [normal, hover, pressed]:
		style.content_margin_left = 14
		style.content_margin_right = 12
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_color_override("font_color", GloryTokens.TEXT_ON_GOLD)
	button.add_theme_color_override("font_hover_color", GloryTokens.TEXT_ON_GOLD)
	button.add_theme_color_override("font_pressed_color", GloryTokens.TEXT_ON_GOLD)
	button.add_theme_font_size_override("font_size", 17)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT

func _toggle_chat_panel() -> void:
	if _chat_panel == null or not is_instance_valid(_chat_panel):
		return
	_chat_panel.visible = not _chat_panel.visible

func _send_chat_phrase(phrase_id: int) -> void:
	NetworkService.team_send_phrase(phrase_id, _chat_team_only)
	# 发完就收起：备战期每一次多余的点击都是从摆棋时间里扣的。
	# **不在这里回显** —— 等服务器广播回来，理由见 NetworkService.team_send_phrase。
	if _chat_panel != null and is_instance_valid(_chat_panel):
		_chat_panel.visible = false

func _on_prep_chat_received(slot: int, phrase_id: int, team_only: bool) -> void:
	var body := ChatPhrases.text(phrase_id)
	if body.is_empty():
		# id 不合法。text() 刻意返回空串而不是占位符，见 ChatPhrases.gd。
		return
	_push_chat_line(_chat_line_head(slot, team_only) + body, _chat_line_color(slot, team_only))

func _on_prep_chat_text_received(slot: int, text: String, team_only: bool) -> void:
	_push_chat_line(_chat_line_head(slot, team_only) + text, _chat_line_color(slot, team_only))


# 打字入口（批次 D）。先收起短语面板：输入条弹在顶部，短语面板留着只会挡棋盘。
# 输入条上也放同一个范围按钮：打到一半发现范围不对，点一下就改，不用关掉重打。
func _open_text_input() -> void:
	if _chat_panel != null and is_instance_valid(_chat_panel):
		_chat_panel.visible = false
	var send := func(text: String) -> String:
		return NetworkService.team_send_text(text, _chat_team_only)
	ChatInputBar.new().present(self, send,
		{"scope_text": _chat_scope_text, "on_scope_pressed": _toggle_chat_scope})


func _toggle_chat_scope() -> void:
	_chat_team_only = not _chat_team_only
	_refresh_chat_scope_button()


func _chat_scope_text() -> String:
	if LocaleManager.get_locale() == "en":
		return "To: Team" if _chat_team_only else "To: All"
	return "发给：队友" if _chat_team_only else "发给：全部"


func _refresh_chat_scope_button() -> void:
	if _chat_scope_button == null or not is_instance_valid(_chat_scope_button):
		return
	_chat_scope_button.text = _chat_scope_text()
	# 发给全部时按钮字变橙：一眼看出「这条对面也看得到」。
	_chat_scope_button.add_theme_color_override("font_color",
		CHAT_MENU_FONT_COLOR if _chat_team_only else CHAT_ALL_COLOR)


# 「【对方】小林：」这样的开头。队友频道不加标记（备战期默认就是它），只标出例外。
func _chat_line_head(slot: int, team_only: bool) -> String:
	var tag := ""
	if not team_only:
		var en := LocaleManager.get_locale() == "en"
		if _chat_is_enemy(slot):
			tag = "[Enemy] " if en else CHAT_TAG_ENEMY
		else:
			tag = "[All] " if en else CHAT_TAG_ALL
	return "%s%s：" % [tag, _chat_speaker_name(slot)]


func _chat_line_color(slot: int, team_only: bool) -> Color:
	if team_only:
		return CHAT_TEAM_COLOR
	return CHAT_ENEMY_COLOR if _chat_is_enemy(slot) else CHAT_ALL_COLOR


func _chat_is_enemy(slot: int) -> bool:
	var me := int(NetworkService.team_local_slot)
	return me >= 0 and GameConstants.team_of_slot(slot) != GameConstants.team_of_slot(me)


func _chat_speaker_name(slot: int) -> String:
	var who := ""
	if slot == int(NetworkService.team_local_slot):
		# 自己的资料不在 team_seat_profiles 里（那张表是别人广播过来的）。
		who = str(AccountManager.profile.get("player_name", "")).strip_edges()
	else:
		var profiles: Dictionary = NetworkService.team_seat_profiles
		var identity: Dictionary = profiles.get(slot, profiles.get(str(slot), {}))
		who = str(identity.get("player_name", "")).strip_edges()
	if not who.is_empty():
		return who
	# 这个座位没有身份（AI 座位，或进程内门禁不带名片建的座位）。用座位号顶着 ——
	# 空名字会让这条消息看起来像是没有人说的。
	var seat: String = CHAT_SEAT_LABELS[slot] if slot >= 0 and slot < CHAT_SEAT_LABELS.size() else "?"
	return ("Seat " + seat) if LocaleManager.get_locale() == "en" else ("席位" + seat)

func _push_chat_line(text: String, color: Color = CHAT_TEAM_COLOR) -> void:
	if _chat_log == null or not is_instance_valid(_chat_log):
		return
	var lbl := Label.new()
	lbl.text = text
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	# 自由文字（批次 D）一行放不下，要折行。**不设 max_lines_visible**：
	# 设了（第一版是 2）就会把长消息的后半截悄悄吞掉 —— 40 字加昵称在 352 宽里要 3~4 行，
	# 读的人只看到半句话、还不知道少了。高度改由下面的行数预算管。
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_font_size_override("font_size", CHAT_LOG_FONT_SIZE)
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color(0.02, 0.025, 0.01, 0.95))
	lbl.add_theme_constant_override("outline_size", 3)
	_chat_log.add_child(lbl)
	# 两道上限：最多 CHAT_LOG_LINES 条，且折行后合计不超过 CHAT_LOG_TEXT_LINES 行。
	# 超了就从最老的一条开始**整条**移走 —— 宁可少显示一条旧的，也不截断任何一条。
	# 最新那条永远留着（它自己最多 4 行，放得下）。
	while _chat_log.get_child_count() > 1 and (_chat_log.get_child_count() > CHAT_LOG_LINES
			or _chat_log_text_lines() > CHAT_LOG_TEXT_LINES):
		var oldest := _chat_log.get_child(0)
		_chat_log.remove_child(oldest)
		oldest.queue_free()
	# 每条自己管自己的寿命，**不要共用一个 Timer**：共用的话后到的消息会重置
	# 前一条的计时，表现为「一直有人说话时最早那条永远不消失」。
	#
	# tween 挂在 lbl 上（不是 self）—— 上面那个 while 提前把它 free 掉时
	# tween 跟着失效，不会对着一个已销毁的节点写属性。
	var tween := lbl.create_tween()
	tween.tween_interval(CHAT_LINE_HOLD_SEC)
	tween.tween_property(lbl, "modulate:a", 0.0, CHAT_LINE_FADE_SEC)
	tween.tween_callback(lbl.queue_free)

# 消息条里全部消息折行之后的总行数。按消息条的宽度自己排一遍版，
# 不读 Label.get_line_count() —— 那要等容器排完版才准，而调用处是刚 add_child 的同一帧。
func _chat_log_text_lines() -> int:
	var total := 0
	for child in _chat_log.get_children():
		var lbl := child as Label
		if lbl == null:
			continue
		var para := TextParagraph.new()
		para.width = CHAT_LOG_WIDTH
		# 与 Label 的 AUTOWRAP_WORD_SMART 同一组断行规则，否则算出的行数和显示的对不上。
		para.break_flags = (TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND
			| TextServer.BREAK_ADAPTIVE)
		para.add_string(lbl.text, lbl.get_theme_font("font"), CHAT_LOG_FONT_SIZE)
		total += para.get_line_count()
	return total

func _teardown_chat_entry() -> void:
	# NetworkService 是 autoload（活得比本场景久），连接必须显式断开。
	# 由 PrepScreen._exit_tree 调用 —— 生命周期钩子只在那一层有。
	if NetworkService.team_chat_received.is_connected(_on_prep_chat_received):
		NetworkService.team_chat_received.disconnect(_on_prep_chat_received)
	if NetworkService.team_chat_text_received.is_connected(_on_prep_chat_text_received):
		NetworkService.team_chat_text_received.disconnect(_on_prep_chat_text_received)
	if _voice_controls != null:
		_voice_controls.teardown()

# 「已静音」的判据，按钮文案与点击方向**共用这一处**。两处各判一次的话迟早分叉，
# 而分叉的症状是「键上写着已静音、按下去却更静」——那种键按了像坏了。
#
# 两种情况都算静音：
#   ① Master 总线被静音 —— 就是本页这个按键自己按下去的那一步；
#   ② 设置页把「背景音乐」关了 —— 9.17 第二批反馈：在大厅里关了 BGM，
#      进对局也该显示已静音，而不是两处各说各话。
#
# 只看「背景音乐」，**不看**「界面音效」：后者只掐 SFX，玩家还听得见 BGM，
# 把它也算成「已静音」是句假话。这条范围由 prep_mute_state_check 钉住，
# 将来要改成「任一开关关掉都算静音」得显式改断言，不能顺手漂移。
func _is_audio_muted() -> bool:
	var master := AudioServer.get_bus_index("Master")
	if master >= 0 and AudioServer.is_bus_mute(master):
		return true
	return not Presentation.music_allowed()


func _toggle_mute() -> void:
	# 全局静音开关：静音 Master 总线（BGM + 音效都停），引擎级状态，切场景仍生效。
	#
	# 目标状态从 _is_audio_muted() 反推，**不是**直接翻转总线：设置页关过
	# 「背景音乐」时按钮显示的是「已静音」，这一次按下去必须把声音打开
	# （清总线静音 + 打开音乐开关）。照旧直接翻总线的话，那种局面下第一下是把
	# 一个本来就没静音的总线翻成静音 —— 键上写着已静音、按下去更静，按了没反应。
	var master := AudioServer.get_bus_index("Master")
	var want_mute := not _is_audio_muted()
	if master >= 0:
		AudioServer.set_bus_mute(master, want_mute)
	# 9.17 反馈第 5 条：「若在这里（设置页）关闭音乐，在游戏对局中可以通过右上的
	# 『已静音』按键重新打开音乐。」
	#
	# 清总线静音只算半条：设置页那个「背景音乐」开关是**另一条**闸门
	# （PresentationSettings.music_allowed()，由 MusicService 执行 stream_paused）。
	# 只解总线的话，设置里关过音乐的玩家按这个键仍然听不到 BGM —— 反馈要的正是
	# 这条路径能把音乐重新打开，所以这里一并把那个偏好打开。
	#
	# 只在**解除静音**时做：把整体静音这一步定义成「声音都回来」，
	# 而按下去要静音时不该顺手改玩家的音乐偏好（那是设置页的事）。
	if not want_mute:
		PlayerProfile.set_presentation_toggle("music", true)
	if _mute_button != null:
		_mute_button.text = _mute_label_text()

func _toggle_carrot_camp() -> void:
	if _carrot_panel == null or not is_instance_valid(_carrot_panel):
		return
	_carrot_panel.toggle()
	if _carrot_dimmer != null:
		_carrot_dimmer.visible = _carrot_panel.visible
	if _carrot_panel.visible:
		_close_team_mercs_picker()
		_close_merc_picker()
	_report_carrot_camp_state()

func _close_carrot_camp() -> void:
	if _carrot_panel != null and is_instance_valid(_carrot_panel):
		_carrot_panel.visible = false
	if _carrot_dimmer != null and is_instance_valid(_carrot_dimmer):
		_carrot_dimmer.visible = false
	_report_carrot_camp_state()

func _on_carrot_dimmer_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_close_carrot_camp()
	elif event is InputEventScreenTouch and event.pressed:
		_close_carrot_camp()

func _on_carrot_economy_receipt(receipt: Dictionary) -> void:
	var action := str(receipt.get("action", ""))
	if action == "shop_refresh":
		if bool(receipt.get("ok", false)):
			call("_adopt_server_shop")
			_shop.selected = -1
			# 9.17：客机玩家主动刷新成功的确切时刻。单机/房主那条在
			# PrepBoardController._on_refresh_shop 里，两边都要接 ——
			# 只接一边就是「联机时刷新没声音」。
			SfxService.play(SfxService.CUE_SHOP_REFRESH)
			_refresh_all()
		else:
			show_message(NetworkService.shop_refresh_error_text(str(receipt.get("error", "denied"))))
		return
	# 只处理这四个**玩家发起、等服务端裁决**的动作。
	# buy / merge / sell / shop_refresh 也会发意图，但那是影子记账（L2）：
	# 本地那一笔早就生效了，服务端只是跟着记账。它们被拒（比如卖一枚开关上线前
	# 买的棋子会 unknown_uid）是影子期的正常噪音，弹给玩家只会制造困惑 ——
	# 差异由 _shadow_audit_economy 记进服务端日志，那才是翻 authoritative 的依据。
	if action not in ["upgrade_harvest_tech", "hire_merc_carrot", "draw_upgrade_stone", "use_upgrade_stone"]:
		return
	if not bool(receipt.get("ok", false)):
		show_message(("Carrot action failed: %s" if LocaleManager.get_locale().begins_with("en") else "萝卜交易失败：%s") % str(receipt.get("error", "denied")))
		# 9.17：服务端拒绝 = 按钮被拒绝，与单机时「钱不够」同一个反馈。
		SfxService.play(SfxService.CUE_UI_REJECT)
		return
	# 9.17：按 action 分流音效。**必须按分支**，不能在这条公共路径上无条件播 ——
	# 四个动作共用这个函数，无条件播会让抽石头响成佣兵音。
	match action:
		"upgrade_harvest_tech":
			SfxService.play(SfxService.CUE_HARVEST_TECH_UPGRADE)
		"hire_merc_carrot":
			SfxService.play(SfxService.CUE_MERC_SUMMON)
		"draw_upgrade_stone":
			SfxService.play(SfxService.CUE_UPGRADE_STONE_DRAW)
	if action == "use_upgrade_stone":
		# 星级已由 NetworkService._apply_carrot_receipt 按 uid 落到棋子上；
		# 棋盘变了要重新提交，否则服务端还按三星那份快照结算。
		call("_mark_online_board_changed")
	if action == "hire_merc_carrot":
		call("_mark_online_board_changed")
		NetworkService.team_send_prep_mercs()
	if _carrot_panel != null and is_instance_valid(_carrot_panel):
		_carrot_panel.refresh()
	refresh_carrot_gathering()
	_refresh_all()
	if action == "use_upgrade_stone":
		_overlay.hide_detail()
		var upgraded_uid := str((receipt.get("result", {}) as Dictionary).get("uid", ""))
		# 9.17：回执里只有 uid，没有 def。按 uid 反查棋子拿 def.id 来分流音效 ——
		# 星级此刻已由 NetworkService._apply_carrot_receipt 落到棋子上，
		# 所以格子一定已经在了。查不到就退回通用那条（star4_cue_for 的默认分支）。
		SfxService.play(SfxService.star4_cue_for(_unit_id_for_uid(upgraded_uid)))
		call_deferred("play_four_star_upgrade", upgraded_uid)


# 按棋子唯一 uid 反查它的数据表 id。四星音效要用它分流，而服务端回执只带 uid。
#
# 棋盘和待命区都要查：四星升级的入口两条都通（PrepBoardController 的
# request_four_star_upgrade 接受 where="board"/"bench"）。用 def.id 而不是
# def.name —— 客机路径的名字会被按本地化覆写。
func _unit_id_for_uid(uid: String) -> String:
	if uid.is_empty():
		return ""
	for slots in [GameState.board_slots, GameState.bench_slots]:
		for cell in (slots as Array):
			if cell is Dictionary and str((cell as Dictionary).get("uid", "")) == uid:
				return str(((cell as Dictionary).get("def", {}) as Dictionary).get("id", ""))
	return ""

func _refresh_carrot_counter() -> void:
	# 教学推进到萝卜那一步时入口才出现 —— 显隐要跟着每次刷新走，不只在建页面时定一次。
	var carrot_visible := _carrot_ui_visible()
	if _carrot_button != null and is_instance_valid(_carrot_button):
		_carrot_button.visible = carrot_visible
	if _carrot_counter_panel != null and is_instance_valid(_carrot_counter_panel):
		_carrot_counter_panel.visible = carrot_visible
	if _carrot_counter_label == null or not is_instance_valid(_carrot_counter_label):
		return
	var amount := int(GameState.carrots)
	var capacity := int(GameState.carrot_capacity())
	_carrot_counter_label.text = "%d / %d" % [amount, capacity]
	_carrot_counter_label.tooltip_text = ("Current carrots" if LocaleManager.get_locale() == "en" else "现有萝卜")
	_carrot_counter_label.add_theme_color_override("font_color",
		Color(0.72, 1.0, 0.58) if amount >= capacity else Color(1.0, 0.94, 0.70))

func _mute_label_text() -> String:
	# 判据与点击方向同源（_is_audio_muted）：设置页关了背景音乐，这里也要写「已静音」。
	var muted := _is_audio_muted()
	if LocaleManager.get_locale() == "en":
		return "Muted" if muted else "Mute"
	return "已静音" if muted else "静音"
func _build_detail_popups() -> void:
	_detail = PopupPanel.new()
	_detail.theme = GloryTheme.get_theme()
	add_child(_detail)
	var detail_margin := MarginContainer.new()
	detail_margin.add_theme_constant_override("margin_left", GloryTokens.GAP_M)
	detail_margin.add_theme_constant_override("margin_top", GloryTokens.GAP_M)
	detail_margin.add_theme_constant_override("margin_right", GloryTokens.GAP_M)
	detail_margin.add_theme_constant_override("margin_bottom", GloryTokens.GAP_M)
	_detail.add_child(detail_margin)
	var detail_content := VBoxContainer.new()
	detail_margin.add_child(detail_content)
	_detail_text = RichTextLabel.new()
	_detail_text.bbcode_enabled = true
	_detail_text.fit_content = false
	_detail_text.scroll_active = true
	_detail_text.custom_minimum_size = Vector2(500, 340)
	_detail_text.add_theme_font_size_override("normal_font_size", GloryTokens.FONT_BODY)
	_detail_text.add_theme_font_size_override("bold_font_size", GloryTokens.FONT_BODY)
	_detail_text.add_theme_color_override("default_color", GloryTokens.TEXT_PRIMARY)
	detail_content.add_child(_detail_text)
	_detail_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var upgrade_panel := preload("res://scenes/prep/FourStarUpgradePanel.gd").new()
	detail_content.add_child(upgrade_panel)
	upgrade_panel.hide()
	_overlay.upgrade_panel = upgrade_panel
	upgrade_panel.preview_requested.connect(func(enabled: bool, cell: Dictionary):
		_detail_text.text = UnitDetailFormat.format_unit_def(cell.get("def", {}), \
			4 if enabled else int(cell.get("star", 1)), cell))
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
	# V3 P1-04：转发给全局 GloryToast。
	#
	# 函数名保留：9 个调用点、_shop.message_requested 的连接、以及
	# provider.bind_feedback(show_message) 都不用动。
	#
	# 观感上有一处**可见**变化：旧实现是 5px 描边的裸 Label，而备战页背景是
	# 浅蓝水面（ColorRect 0.38/0.70/0.88）——Main._show_back_exit_hint 的注释
	# 早就记着「描边在浅色水面上一样糊」。新的底板是实心面板，可读性更好。
	# 位置和时长照旧（anchor 0.34 / 1.3s + 0.6s）。
	GloryToastScript.show_text(text)


func _build_ready_indicator() -> void:
	# 3v3 准备状态：上排=敌队 3 个、下排=自己队 3 个（自己队永远在下，和战斗演示一致）。
	# _ready_dots 按「位置」存头像徽章：0-2=上排左中右、3-5=下排左中右；刷新时再映射到对应 slot。
	_ready_indicator = VBoxContainer.new()
	# (7) Ready checks live in the empty TOP-LEFT corner, not the right side.
	_ready_indicator.anchor_left = 0.0
	_ready_indicator.anchor_right = 0.0
	_ready_indicator.anchor_top = 0.0
	_ready_indicator.anchor_bottom = 0.0
	_ready_indicator.offset_left = 16
	_ready_indicator.offset_right = 16 + 128
	_ready_indicator.offset_top = 8
	_ready_indicator.offset_bottom = 8 + 84
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
			var badge := _create_ready_avatar_badge()
			row_box.add_child(badge)
			_ready_dots.append(badge)
	_refresh_ready_indicator()


func _create_ready_avatar_badge() -> Control:
	var badge := Control.new()
	badge.custom_minimum_size = Vector2(40, 40)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 当前默认框的圆心是不透明的，和主菜单一样先画框，再把头像裁圆后画在上面。
	# 头像缩进在金环内，不会盖住框；未来换框只需更新 avatars.json。
	var frame := TextureRect.new()
	frame.name = "Frame"
	frame.texture = AvatarCatalog.frame_texture_for("")
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_child(frame)

	var mask := Panel.new()
	mask.name = "PortraitMask"
	mask.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mask.offset_left = 7
	mask.offset_top = 7
	mask.offset_right = -7
	mask.offset_bottom = -7
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var circle := StyleBoxFlat.new()
	circle.bg_color = Color.WHITE
	circle.set_corner_radius_all(26)
	mask.add_theme_stylebox_override("panel", circle)
	badge.add_child(mask)

	var portrait := TextureRect.new()
	portrait.name = "Portrait"
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.add_child(portrait)

	var check := Label.new()
	check.name = "ReadyCheck"
	check.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	check.offset_left = -20
	check.offset_top = -22
	check.offset_right = 2
	check.offset_bottom = 0
	check.text = "✓"
	check.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	check.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	check.add_theme_font_size_override("font_size", 19)
	check.add_theme_color_override("font_color", Color(0.34, 1.0, 0.28))
	check.add_theme_color_override("font_outline_color", Color(0.02, 0.08, 0.01, 1.0))
	check.add_theme_constant_override("outline_size", 4)
	check.mouse_filter = Control.MOUSE_FILTER_IGNORE
	check.visible = false
	badge.add_child(check)
	return badge


func _ready_slot_identity(slot: int) -> Dictionary:
	if slot == int(NetworkService.team_local_slot):
		return AccountManager.profile
	var profiles: Dictionary = NetworkService.team_seat_profiles
	return profiles.get(slot, profiles.get(str(slot), {})) as Dictionary


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
		var badge: Control = _ready_dots[pos]
		var slot: int = int(pos_to_slot[pos])
		var st := str(states[slot]) if slot < states.size() else "empty"
		badge.visible = st != "empty"
		if st == "empty":
			continue
		var identity := _ready_slot_identity(slot)
		var portrait := badge.get_node("PortraitMask/Portrait") as TextureRect
		var frame := badge.get_node("Frame") as TextureRect
		portrait.texture = AvatarCatalog.texture_for(str(identity.get("avatar", "")))
		frame.texture = AvatarCatalog.frame_texture_for(str(identity.get("avatar_frame", "")))
		var is_ready := st == "dummy" or (slot < ready_arr.size() and bool(ready_arr[slot]))
		var check := badge.get_node("ReadyCheck") as Label
		check.visible = is_ready

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
	# 9.25：教学也用萝卜雇佣兵（与正式局一致），并且从「召唤佣兵」那一步起才开放。
	if GameState.tutorial_mode and not TutorialMode.allows_carrot_action("hire_merc"):
		return TutorialMode.follow_arrow_hint()
	if GameState.carrots < int(mercenary.get("carrot_cost", 0)):
		return "Not enough carrots" if LocaleManager.get_locale().begins_with("en") else "萝卜不足"
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
	# 9.25 订正：本函数是刷新按钮的**前置**判定（决定放不放燃烧动画），原先只抄了
	# TreasureService.has_set("money")，漏掉教学分支。教程里 shop_refresh_all_free()
	# 恒真 ⇒ cost 恒 0；漏抄后 cost 按 shop_refresh_uses_this_round 递增
	# （EconomyService.shop_refresh_cost 在 all_free=false 且 uses>0 时走递增价），
	# 刷几次就超过金币，这里静默 return —— 表现正是「按钮写着免费（ShopPanel 那边
	# 用的是正确判定）、点下去毫无反应」。判定只能接 TutorialMode.shop_refresh_all_free()
	# 这一处，与 PrepBoardController._on_refresh_shop / ShopPanel.refresh 同源。
	var all_free := TutorialMode.shop_refresh_all_free()
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
	# 9.25：教学与正式局一样按萝卜标价。
	var price_text := ("Carrots %d" if LocaleManager.get_locale().begins_with("en") else "萝卜 %d") % int(mercenary.get("carrot_cost", 0))
	card.set_meta("drag_preview_text", "%s\n%s" % [str(mercenary.get("name", tr("ui_mercenary"))), price_text])
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
	price_label.text = price_text
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

# --- 9.17 羁绊激活音 ---------------------------------------------------------
#
# SynergyService 全是无状态纯函数：每次调用全量重算，没有信号、没有 prev 快照。
# 所以「某个羁绊刚跨过某档」只能靠前后对比，没有现成的钩子可挂。
#
# 采样点选在 _refresh_all() 的末尾，而不是 SynergyPanel.refresh() 里：
# 后者有签名早退（_left_panel_signature 不变就直接 return），
# 拿它当采样点会把整档变化整个漏掉。
#
# ---------------------------------------------------------------------------
# 2026-09-17 追加修复：口径从「人数前后比」改成「已解锁档位集合」
#
# 反馈：凑齐「同族 7 人」羁绊时没有声音（面板已经写着「已解锁」）。
#
# 原实现拿人数前后比（was < 档位 <= now），并且「回合号变了就只记基线、不比较」。
# 那条守卫的本意是「下一回合的棋盘可能被服务端整块覆盖，那不是玩家刚做的操作」，
# 可它是拿**回合号**当「棋盘是外面送来的」的代理判断，于是一个真实场景被整帧吃掉：
# ③ 的服务端 state payload 把 round_id 与棋盘**一起**下发（Main.gd:337 / :2491），
# 于是「玩家把第 7 个神放上棋盘」和「回合号 +1」落在同一次 _refresh_all() 里 ——
# 面板显示神7 已解锁，声音一声不响，而快照已经被写成 7，整局不会再补。
# 线上实测（探针 tools/_probe_synergy_roundguard）：同回合 6->7 响 1 次，
# 换回合同帧 6->7 响 0 次。
#
# 现在比的是**集合**：
#   * 「已解锁」= 人数 >= 档位，于是 6->8->6->8 这类人数波动不再是事件，
#     只有档位真的从「未解锁」变「已解锁」才算一次跨档；
#   * 卖掉一个再买回来（掉档后又跨回来）会重新响 —— 那是玩家真的又做了一次
#     这个操作，本来就该有反馈；
#   * 换回合不再重置：那条守卫会把跨档吃掉，而集合口径下每次解锁最多一声，
#     不会因为「服务端整块覆盖」刷屏。
# 「刚进备战页」那一帧仍然只认账不发声：那一刻的棋盘是既有战果
# （上一回合留下的 / 读档 / 服务端下发），进场就为它响是把旧成果当新闻。
# ---------------------------------------------------------------------------
var _synergy_unlocked_before: Dictionary = {}
var _synergy_sampled := false


# 档位键："god@7"。用它而不是人数，是因为人数在档位之间怎么走都不该算事件。
func _synergy_tier_key(race: String, threshold: int) -> String:
	return "%s@%d" % [race, threshold]


# 当前已解锁的档位集合。人数取自 SynergyService（唯一权威），
# 档位取自 RACE_THRESHOLDS —— 与 SynergyPanel 显示的那几档同源，
# tools/audio_sfx_check 会拿这两张表对一遍。
func _synergy_unlocked_tiers() -> Dictionary:
	var counts := SynergyService.count_races_from_board()
	var unlocked: Dictionary = {}
	for race in SynergyService.RACE_THRESHOLDS.keys():
		var race_name := str(race)
		var have := int(counts.get(race_name, 0))
		for threshold in SynergyService.RACE_THRESHOLDS[race]:
			if have >= int(threshold):
				unlocked[_synergy_tier_key(race_name, int(threshold))] = true
	return unlocked


# 由 _refresh_all() 调用。
#
# 一次采样最多响一声：一次操作可能同时跨两档（比如一次性从 6 只补到 8 只，
# god 的 7 档与 human 的 7 档都可能过），那种时候连续两声反而像卡带。
# 快照在**判断之后无条件更新**，所以同一状态被反复采样不会重复响。
#
# 9.17 反馈第 1 条：「目前是激活羁绊就会生效，现在改为只在激活**终极羁绊**时
# 才会生效，例如羁绊『神7·无敌』、『人7·狂战士』。」
#
# 也就是说 2 档 / 4 档的激活不再出声，只有每族的**最高档**（7 档：人7 / 神7 /
# 暗7 / 灵7）才响。判据取自 RACE_THRESHOLDS 的最后一档，不写死 7 ——
# 以后把某一族调成 8 档，这里会跟着走。
#
# **掉档再跨回来仍然算事件**：判据是「这个档位键从无到有」，快照在判断后无条件
# 更新，所以 7→6→7 会响第二声（玩家确实重新激活了终极羁绊）。
func _check_synergy_activation() -> void:
	var unlocked := _synergy_unlocked_tiers()
	if not _synergy_sampled:
		# 刚进备战页的第一帧：只认账，不发声。
		_synergy_sampled = true
		_synergy_unlocked_before = unlocked
		return
	var crossed := false
	for key in unlocked.keys():
		if _synergy_unlocked_before.has(key):
			continue
		if not _is_ultimate_synergy_tier(str(key)):
			continue
		crossed = true
		break
	_synergy_unlocked_before = unlocked
	if crossed:
		SfxService.play(SfxService.CUE_SYNERGY_ACTIVATE)


# 这个档位键是不是「终极羁绊」。键的格式见 _synergy_tier_key()："god@7"。
#
# 判据 = 该族 RACE_THRESHOLDS 里的**最后一档**。取数组末项而不是判 `== 7`：
# 阈值表是唯一权威（SynergyPanel 与门禁都对它），写死数字会在表变了之后
# 静默失效 —— 而这一条失效的症状是「终极羁绊激活时没声音」，很难联想到这里。
func _is_ultimate_synergy_tier(key: String) -> bool:
	var parts := key.split("@")
	if parts.size() != 2:
		return false
	var thresholds: Array = SynergyService.RACE_THRESHOLDS.get(parts[0], [])
	if thresholds.is_empty():
		return false
	return int(parts[1]) == int(thresholds[thresholds.size() - 1])


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
	if _carrot_panel != null and is_instance_valid(_carrot_panel):
		_carrot_panel.refresh()
	_refresh_carrot_counter()
	if GameState.tutorial_mode:
		TutorialMode.update_overlay()
	_check_team_merc_alert()
	# 9.17：羁绊激活音。放最后 —— 前面的 _auto_combine_all() 可能刚把棋子合成掉、
	# 改变棋盘构成，先采样再判会拿到中间态。
	_check_synergy_activation()
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
	# 卡片价格与可买判据在非教学局读的是**萝卜**（_mercenary_purchase_reason），
	# 签名却只有金币 —— 萝卜变了卡片不重建：涨了还挂着「萝卜不足」点不动，
	# 跌了（比如抽了一次 50 萝卜的升级石）还显示可买，点下去在
	# PrepBoardController._on_hire_mercenary 静默 return，没有任何提示。
	# 签名必须覆盖该分区渲染的全部数据（见本文件 :138 的约定）。
	var sig := JSON.stringify([
		GameState.gold,
		GameState.carrots,
		GameState.mercenary_slots,
		GameState.tutorial_mode,
		# 教学里佣兵是否开放随步骤变化（allows_carrot_action("hire_merc")），也要进签名。
		GameState.tutorial_mode and TutorialMode.allows_carrot_action("hire_merc"),
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
		_close_carrot_camp()
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
		_close_carrot_camp()
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
	# 9.17：`_team_merc_alert == null` 的早退**从函数开头挪到了控件交互那两行**。
	# 原先它和 tutorial 一起挡在最前面，于是「数变化」这段也跟着控件走了 ——
	# 而队伍召唤音应当由「队友多了一个佣兵」这个事实决定，不该由某个控件建没建出来决定。
	# 拆开之后：数照常采样，控件相关的分支各自判空。
	if GameState.tutorial_mode:
		return
	var current := _team_merc_counts()
	if not _team_merc_snapshot_initialized or _team_merc_snapshot_round != GameState.round_index:
		_team_merc_counts_snapshot = current
		_team_merc_snapshot_round = GameState.round_index
		_team_merc_snapshot_initialized = true
		return

	var increased := false
	var teammate_increased := false
	# 自己那一格的口径必须和 `_team_merc_counts()` 里**完全一致**（同一个三元 + 同一个
	# `< 0` 归一），否则下面「这是不是我自己的座位」判错，房主那条会双响或干脆不响。
	var my_slot := NetworkService.team_local_slot if NetworkService.team_active else 0
	if my_slot < 0:
		my_slot = 0
	for slot_value in current:
		var slot := int(slot_value)
		if int(current.get(slot, 0)) > int(_team_merc_counts_snapshot.get(slot, 0)):
			increased = true
			if slot != my_slot:
				teammate_increased = true
	_team_merc_counts_snapshot = current

	# 9.17：队伍召唤音 —— **队友**多雇了一个佣兵，全队都该听到这条召唤音。
	#
	# 只补队友那一半：自己那一次由「确认自己成功了」的本地路径播 ——
	#   客机：服务端回执落地处 `_on_carrot_economy_receipt`（action == hire_merc_carrot）
	#   房主 / 单机 / 教程：成交那行 `PrepBoardController._hire_mercenary_to_slot`
	# 这里若连自己那格也播就会双响：`_team_merc_counts()` 把自己的座位也算进 current，
	# 而 `_refresh_all()` 结尾就会调到本函数。
	#
	# 不按增量条数分次播：雇佣是一次一个（每回只填一个空槽），增量恒为 1；
	# 真出现 +N 只可能是中途重连后的整表重发，那种也该只响一声。
	# 「首次观察」与「换回合」两种误响来源已经在上面 return 掉，迟到同步不会凭空响。
	if teammate_increased:
		SfxService.play(SfxService.CUE_MERC_SUMMON)

	if not increased or _team_merc_alert == null:
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
	# 联动与套装的 logo 完全由已拥有宝物推导，所以签名只需 owned_treasures。
	var sig := JSON.stringify(GameState.owned_treasures)
	if sig == _owned_logos_signature:
		return
	_owned_logos_signature = sig
	for child in _treasure._owned_treasure_box.get_children():
		child.queue_free()
	_tray_buttons.clear()
	# Owned treasures.
	for tid in GameState.owned_treasures:
		var tid_str := str(tid)
		var t := TreasureService.treasure_by_id(tid)
		_add_owned_treasure_logo(tid_str, str(t.get("name", tid_str)), _treasure.show_detail.bind(tid_str))
	# Active linkages (their required treasures are all owned) get their own logo too.
	var links: Array = DataRegistry.get_table("treasures").get("linkages", [])
	for link in links:
		var lid := str(link.get("id", ""))
		if TREASURE_LINKAGE_LOGOS.has(lid) and TreasureService.has_linkage(lid):
			_add_owned_treasure_logo(lid, str(TREASURE_LINKAGE_LOGOS[lid]), _show_linkage_detail.bind(lid))
	# 凑齐 4 件的套装排在联动后面（与图鉴「联动」分类同序）。
	# 5 件持有上限下，套装最多再伴随 1 条联动，栏位最多 7 格，放得下两行 4 格。
	for category in TreasureService.SET_CATEGORIES:
		if TreasureService.has_set(category):
			var art := str(CodexService.SET_ART_NAME.get(category, ""))
			var set_name := str(CodexService.set_text(category).get("name", art))
			_add_owned_treasure_logo(TreasureService.set_id(category), art,
				_show_set_detail.bind(category), set_name)

func _add_owned_treasure_logo(key: String, logo_name: String, detail: Callable, tooltip: String = "") -> void:
	var b := Button.new()
	b.text = ""
	b.tooltip_text = tooltip if not tooltip.is_empty() else logo_name
	b.custom_minimum_size = Vector2(66, 66)
	b.focus_mode = Control.FOCUS_NONE
	PrepWidgets.apply_empty_button_styles(b)
	var logo := TextureRect.new()
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	logo.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var logo_path := "%s/%s.png" % [TREASURE_LOGO_DIRECTORY, logo_name]
	var logo_tex := PrepWidgets.cached_texture(logo_path)
	logo.texture = logo_tex
	b.add_child(logo)
	# 同 TreasureChoicePanel 三选一卡片的规矩：贴图缺失时绝不能让按钮看起来是空的
	# （玩家分不清"没这个联动"和"图丢了"）。之前这里没有兜底，缺图会完全静默——
	# 不报错、不留痕迹，排查只能靠肉眼比对文件名。现在缺图时既留日志、也留文字。
	if logo_tex == null:
		push_warning("PrepUI: treasure/linkage logo texture missing at %s" % logo_path)
		var fallback := Label.new()
		fallback.text = logo_name
		fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		fallback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		fallback.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		fallback.add_theme_font_size_override("font_size", 14)
		fallback.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
		fallback.add_theme_constant_override("outline_size", 3)
		b.add_child(fallback)
	if detail.is_valid():
		b.pressed.connect(detail)
	_treasure._owned_treasure_box.add_child(b)
	_tray_buttons[key] = b


func _show_set_detail(category: String) -> void:
	var status := _treasure.set_status(category)
	if status.is_empty():
		return
	var entry := CodexService.set_text(category)
	var title := str(entry.get("name_en", "")) if PrepWidgets.is_en() else str(entry.get("name", ""))
	_overlay.show_text("%s\n%s" % [title, status])


# --- 联动 / 套装激活特效 --------------------------------------------------------
#
# 领宝的两条路（单机 _pick_treasure、联机 _on_treasure_granted）在入袋前取一次
# _active_bonus_ids()，_refresh_all() 之后把它交给 _queue_bonus_fx() 求差集。
# 断线重连的补同步不走这两条路，所以重连时不会补播。

func _active_bonus_ids() -> Array[String]:
	var out := TreasureService.active_linkage_ids()
	out.append_array(TreasureService.active_set_ids())
	return out


func _queue_bonus_fx(before: Array[String]) -> void:
	for id in _active_bonus_ids():
		if before.has(id) or _bonus_fx_queue.has(id):
			continue
		_bonus_fx_queue.append(id)
		# 新格子这一帧就会画出来，先藏住，等特效里的图标飞到再显示。
		var slot: Control = _tray_buttons.get(id, null)
		if slot != null:
			slot.modulate.a = 0.0
	if not _bonus_fx_busy:
		_play_next_bonus_fx()


func _play_next_bonus_fx() -> void:
	if _bonus_fx_queue.is_empty() or not is_inside_tree():
		_bonus_fx_busy = false
		return
	_bonus_fx_busy = true
	var id: String = _bonus_fx_queue.pop_front()
	# 旧按钮是 queue_free 的，要等它们真正释放、栅格重新排版，新按钮的位置才是真的。
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree():
		return
	var sources: Array = []
	for tid in TreasureService.bonus_sources(id, GameState.owned_treasures):
		var icon: Control = _tray_buttons.get(tid, null)
		if icon != null and is_instance_valid(icon):
			sources.append({
				"rect": _screen_rect(icon),
				"category": str(TreasureService.treasure_by_id(tid).get("category", "")),
			})
	var slot: Control = _tray_buttons.get(id, null)
	var target := Rect2()
	if slot != null and is_instance_valid(slot):
		target = _screen_rect(slot)
	var fx: LinkageFx = LinkageFx.new()
	_bonus_fx_host().add_child(fx)
	fx.landed.connect(func() -> void:
		if is_instance_valid(slot):
			slot.modulate.a = 1.0)
	fx.finished.connect(_play_next_bonus_fx)
	fx.play(sources, _bonus_logo(id), _bonus_title(id), target)


func _bonus_fx_host() -> CanvasLayer:
	if _bonus_fx_layer == null or not is_instance_valid(_bonus_fx_layer):
		_bonus_fx_layer = CanvasLayer.new()
		_bonus_fx_layer.name = "BonusFxLayer"
		_bonus_fx_layer.layer = BONUS_FX_LAYER
		add_child(_bonus_fx_layer)
	return _bonus_fx_layer


# 宝藏栏在画布 0 层、特效在自己的图层：用带画布变换的矩形换到同一个屏幕坐标里。
func _screen_rect(c: Control) -> Rect2:
	var xf := c.get_global_transform_with_canvas()
	return Rect2(xf.origin, c.size * xf.get_scale())


func _bonus_logo(id: String) -> Texture2D:
	var category := TreasureService.set_category_of(id)
	var art := str(TREASURE_LINKAGE_LOGOS.get(id, ""))
	if not category.is_empty():
		art = str(CodexService.SET_ART_NAME.get(category, ""))
	return PrepWidgets.cached_texture("%s/%s.png" % [TREASURE_LOGO_DIRECTORY, art])


func _bonus_title(id: String) -> String:
	var category := TreasureService.set_category_of(id)
	var entry := CodexService.set_text(category) if not category.is_empty() else CodexService.link_text(id)
	var bonus_name := str(entry.get("name_en", "")) if PrepWidgets.is_en() else str(entry.get("name", ""))
	if bonus_name.is_empty():
		bonus_name = str(TREASURE_LINKAGE_LOGOS.get(id, id))
	return tr("ui_set_fx_banner" if not category.is_empty() else "ui_linkage_fx_banner") % bonus_name

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
	# 9.13 #6：语音按钮（宽 150、右对齐到 -292）的左半截正好压在商店弹窗
	# （底部中央 896×230）的右下角里。商店面板本身是 Container（PASS）且背景层
	# 一律 IGNORE，挡不住下层控件 —— 于是玩家在商店右端操作会穿透到语音按钮上，
	# 弹出「这个版本没有语音功能」。和待命格同一套处理：商店开着就整块不吃输入。
	# 语音 v1.1（2026-09-14）起这一块是「语音」「队友」两个按钮（VoiceControls，合起来仍是 150 宽），两个一起挡。
	# 这一行原本写的是 v1 的 _voice_button：与 v1.1 合并时 git 没报冲突，但那个变量已经没有了，PrepUI 会解析失败。
	if _voice_controls != null:
		_set_overlay_blocked(_voice_controls.voice_button, is_open)
		_set_overlay_blocked(_voice_controls.members_button, is_open)
	_set_overlay_blocked(_chat_button, is_open)


# 商店打开时禁用被它盖住的按钮；关闭时**下一帧**再恢复。
#
# 为什么要延迟：如果是「点商店外面关店」的那一下点击，PrepScreen._input 会在
# 这里就把商店关掉；若当场恢复 STOP，同一次点击紧接着的 GUI 命中测试就又能打到
# 语音按钮上 —— 正是要修的那个现象。set_deferred 让它错过这一次事件，同时不影响
# 棋盘那侧「一点即选中」的穿透（棋盘不是被禁用的控件）。
func _set_overlay_blocked(btn: Control, blocked: bool) -> void:
	if btn == null or not is_instance_valid(btn):
		return
	if blocked:
		btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	else:
		btn.set_deferred("mouse_filter", Control.MOUSE_FILTER_STOP)



# 棋盘面板要求刷新 3D 层 / 可读性层。这三样都在 PrepBoardModels 那一层，
# 面板不该直接伸手 —— 它只说「哪块脏了」。
func _on_board_visuals_dirty(what: String) -> void:
	match what:
		"board":       _refresh_prep_board_models()
		"standby":     _refresh_prep_standby_models()
		"readability": _sync_prep_board_readability_state()
