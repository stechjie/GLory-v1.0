extends SceneTree
# Steam 活动（Auto Battler RPG Fest 2026）宣传素材录制：在真实备战界面里按时间轴
# 自动操作，Movie Maker 逐帧落 PNG，再由 tools/fest_capture.ps1 合成 GIF / MP4。
#
#   .\tools\fest_capture.ps1 -Shot cards      # 主菜单商城棋子页：8 张角色属性卡轮播
#   .\tools\fest_capture.ps1 -Shot fourstar   # 萝卜营地抽人石 → 人王 3★ → 4★
#   .\tools\fest_capture.ps1 -Shot treasure   # 抽宝藏凑齐元素套 → 棋盘四元素光柱
#
# 和 promo_capture.gd 的分工：那个录整场战斗、没有操作；这个专录备战界面里
# 「需要有人点一下」的几个镜头，所以是一条按帧号排的时间轴（_timeline）。
# 画面全部是游戏本身的界面和特效，脚本只负责摆状态、按按钮；唯一加的表现是
# 角色卡切换时的淡入缩放（游戏里卡片是瞬间弹出，轮播里瞬切太跳）。
#
# 确定性：--fixed-fps 把每帧的 delta 钉死，时间轴按帧号走，同参数重录逐帧一致。

const PREP_SCREEN_PATH := "res://scenes/prep/PrepScreen.tscn"
# 第 3 回合：下一回合仍是 PvE，开场不会弹 PvP 提示框盖住棋盘（同 promo_capture）。
const PREP_ROUND := 3
const PREP_GOLD := 99

# 用户 11.13 选定的 8 个角色，轮播按这个顺序。
const CARD_UNITS: Array[String] = [
	"dark_dragon", "god_aurora", "Icey", "human_king",
	"undead_mother", "lattern", "dark_suc", "dark_doom",
]
# 4★ 镜头的主角：人王是「人」属性，全屏特效是闪电劈下，三种里最重的一种。
const FOUR_STAR_UNIT := "human_king"
# 棋盘 4×4，index = row * 4 + col，row 0 在画面最上方（离镜头最远）。人王放第 3 排中间，
# 离镜头近、在画面中段，结尾切特写时框得住；第 1 排时被「5/7」人数标压着。
const FOUR_STAR_CELL := 10
# 4★ 镜头里陪衬的棋子，围在人王前后左右，让棋盘不空。
const FOUR_STAR_SUPPORT: Array[String] = ["human_swordsman", "human_archer", "human_mage", "human_cleric"]
const SUPPORT_CELLS: Array[int] = [9, 11, 6, 14]

# 轮播节奏（秒）：每张卡停留 + 切换淡入。
const CARD_HOLD_SEC := 1.6
const CARD_FADE_SEC := 0.22

var _out_dir := ""
var _shot := "cards"
var _fps := 30
var _locale := "en"
var _card_star := 3

var _game_state: Node = null
var _network: Node = null
var _screen: Node = null
var _frame := 0
var _setup_done := false
# 帧号 → Callable；_process 每帧取当前帧要做的事。
var _timeline: Dictionary = {}
var _end_frame := 0
var _markers: Array = []


func _initialize() -> void:
	_parse_arguments()
	if _shot not in ["cards", "fourstar", "treasure"]:
		push_error("Unknown --shot '%s' (cards | fourstar | treasure)" % _shot)
		quit(1)


# 同 promo_capture：等一帧，LocaleManager._ready() 注册完翻译表再搭场景。
func _setup() -> void:
	_game_state = root.get_node_or_null("GameState")
	_network = root.get_node_or_null("NetworkService")
	var data := root.get_node_or_null("DataRegistry")
	var locale_mgr := root.get_node_or_null("LocaleManager")
	if _game_state == null or _network == null or data == null or locale_mgr == null:
		push_error("Autoloads missing - run with --path pointing at the project root.")
		quit(1)
		return
	locale_mgr.call("set_locale", _locale)
	data.call("load_all")
	_game_state.call("reset_run")
	_game_state.set("team_mode", false)
	_network.set("team_active", false)
	_game_state.set("round_index", PREP_ROUND)
	_game_state.set("gold", PREP_GOLD)
	# 每种属性给一颗升级石：卡片底部的「升级至 ★★★★」按钮是亮的金色，
	# 4★ 镜头也靠它通过 four_star_check。
	_game_state.set("team_upgrade_stones", {"sky": 1, "land": 1, "ren": 1})
	var defs := _unit_defs(data)
	if _shot == "cards":
		_setup_store(defs)
		return
	match _shot:
		"fourstar":
			_stage_four_star(defs)
		"treasure":
			_stage_treasure(defs)
	var packed := load(PREP_SCREEN_PATH) as PackedScene
	if packed == null:
		push_error("Failed to load %s" % PREP_SCREEN_PATH)
		quit(1)
		return
	_screen = packed.instantiate()
	root.add_child(_screen)
	print("fest_capture: shot=%s fps=%d locale=%s end_frame=%d" % [_shot, _fps, _locale, _end_frame])


func _f(sec: float) -> int:
	return int(round(sec * _fps))


# ---- cards ------------------------------------------------------------------

# 用户 11.13：角色卡在**主菜单进去的商城**里播 —— 商城「棋子」页按种族分页，
# 点棋子头像弹出居中的羊皮纸属性卡（ShopScreen._show_unit_detail_card）。
#
# 商城目录平时从服务端拉（AccountManager.fetch_shop）。录制时离线，走 ShopScreen
# 自带的 ui_capture_fixture：进树前灌好目录与余额，_ready 就不发网络请求
# （tools/shop_bag_ui_capture.gd 同一套）。目录取 data/shop.json 的棋子条目，价格照抄。
#
# 人族 / 神族是人人默认拥有的基础种族，商城不卖、也没有分页（ShopScreen._unit_items
# 直接读 shop.json，enabled=false 的条目进不了棋子页）。用户要的 8 个里极光射手、人王
# 在这两族，只能借别族的页面弹卡：卡片弹出时背景压暗，页面本身不是焦点。
const STORE_SCREEN_PATH := "res://scenes/menu/ShopScreen.tscn"
# 按种族分页的播放顺序：[种族, [棋子 id…]]。
const STORE_PAGES: Array = [
	["dark", ["dark_dragon", "dark_suc", "dark_doom"]],
	["crimson", ["Icey", "lattern", "god_aurora"]],
	["undead", ["undead_mother", "human_king"]],
]
# 收藏进度：每族先「拥有」这么多个（展示的角色除外），中间的种族徽章亮起 5/8 的进度环。
# 0/8 时徽章是一块黑色剪影，宣传画面里太闷。展示的角色保持未拥有，卡上照样是 Buy + 价格。
const STORE_OWNED_PER_RACE := 5
# 黑龙那张卡停住后点一下「查看四星属性与技能」，展示四星数值和技能。
const STORE_FOUR_STAR_PREVIEW := "dark_dragon"


func _setup_store(defs: Dictionary) -> void:
	var catalog: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/shop.json"))
	var items: Array = []
	var owned := {}
	var owned_count := {}
	for raw in (catalog as Dictionary).get("items", []):
		var item := (raw as Dictionary).duplicate(true)
		if str(item.get("kind", "")) != "unit" or not bool(item.get("enabled", true)):
			continue
		items.append(item)
		var unit_id := str(item.get("grants", "")).trim_prefix("unit:")
		var race := str((defs.get(unit_id, {}) as Dictionary).get("race", ""))
		if unit_id in CARD_UNITS or int(owned_count.get(race, 0)) >= STORE_OWNED_PER_RACE:
			continue
		owned[str(item.get("grants", ""))] = true
		owned_count[race] = int(owned_count.get(race, 0)) + 1
	var packed := load(STORE_SCREEN_PATH) as PackedScene
	if packed == null:
		push_error("Failed to load %s" % STORE_SCREEN_PATH)
		quit(1)
		return
	_screen = packed.instantiate()
	_screen.set_meta("ui_capture_fixture", true)
	_screen.set("_loading", false)
	_screen.set("_diamond", 500)
	_screen.set("_coin", 2400)
	_screen.set("_items", items)
	_screen.set("_owned", owned)
	_screen.set("_active_category", "unit")
	_screen.set("_unit_race", str(STORE_PAGES[0][0]))
	root.add_child(_screen)
	# 时间轴：1.2s 暖场（页面入场动效）；每页先停 0.6s 看收藏页，再逐个点棋子。
	var t := 1.2
	for page_i in STORE_PAGES.size():
		var race := str(STORE_PAGES[page_i][0])
		if page_i > 0:
			_at(_f(t), func(): _store_switch_race(race))
			_markers.append({"frame": _f(t), "event": "race_" + race})
		t += 0.6
		for id in STORE_PAGES[page_i][1]:
			var unit_id := str(id)
			_at(_f(t), func(): _store_open_card(defs, unit_id))
			_markers.append({"frame": _f(t), "unit": unit_id})
			t += CARD_HOLD_SEC
			if unit_id == STORE_FOUR_STAR_PREVIEW:
				_at(_f(t), func(): _store_toggle_four_star())
				_markers.append({"frame": _f(t), "event": "four_star_preview"})
				t += CARD_HOLD_SEC
			_at(_f(t), func(): _store_close_card())
			t += 0.25
	_end_frame = _f(t + 0.3)
	print("fest_capture: shot=cards (store) fps=%d locale=%s end_frame=%d" % [_fps, _locale, _end_frame])


# 和种族页签按钮的 pressed 回调做同一件事（ShopScreen._render_units 里的 race_btn）。
func _store_switch_race(race: String) -> void:
	_screen.set("_unit_race", race)
	_screen.call("_render")


# 棋子头像的点击回调就是这一句（ShopScreen._unit_card 里 portrait.gui_input）。
func _store_open_card(defs: Dictionary, unit_id: String) -> void:
	if not defs.has(unit_id):
		push_warning("Unknown unit %s" % unit_id)
		return
	_screen.call("_show_unit_detail_card", defs[unit_id])


func _store_card() -> Node:
	var layer := _screen.get_node_or_null("UnitDetailOverlay")
	if layer == null:
		return null
	for node in layer.find_children("*", "PanelContainer", true, false):
		if node.has_method("setup_preview"):
			return node
	return null


func _store_toggle_four_star() -> void:
	var card := _store_card()
	if card != null:
		card.call("_toggle_four_preview")
	else:
		push_warning("No store detail card to toggle")


# 点卡外的暗底 = 关卡（ShopScreen._show_unit_detail_card 里 dim.gui_input → queue_free）。
func _store_close_card() -> void:
	var layer := _screen.get_node_or_null("UnitDetailOverlay")
	if layer != null:
		layer.name = "UnitDetailOverlayClosing"
		layer.queue_free()


# ---- treasure ---------------------------------------------------------------

# 用户 11.13：抽宝藏要抽到元素套装，之后棋盘上的棋子都带四元素效果
# （PrepBoardModels.sync_prep_treasure_visuals：脚下元素纹 + 四色螺旋光柱）。
# 元素套 4 件。开场已有前 2 件，现场连抽两次拿到后 2 件，凑齐那一刻套装成立。
const ELEMENT_SET: Array[String] = ["elem_flame_shatter", "elem_frost_blade", "elem_thunder_haste", "elem_toxic_spread"]
# 两次三选一里的陪衬候选（元素那张放中间 / 右边，镜头读得出「挑了它」）。
const TREASURE_ROUND_1: Array[String] = ["atk_burst_core", "elem_thunder_haste", "def_iron_wall"]
const TREASURE_ROUND_2: Array[String] = ["ctrl_shockwave", "money_compound", "elem_toxic_spread"]


func _stage_treasure(defs: Dictionary) -> void:
	var board: Array = []
	board.resize(GameConstants.CELL_COUNT)
	# 上阵上限 7：用户选的 8 个角色里放 7 个（魅魔留在商店镜头里），都是 3★，
	# 套装光柱挂在每个人身上。
	var units: Array[String] = ["dark_dragon", "god_aurora", "Icey", "human_king", "undead_mother", "lattern", "dark_doom"]
	var cells: Array[int] = [1, 2, 5, 6, 9, 10, 13]
	for i in units.size():
		board[cells[i]] = _cell(defs, units[i], 3)
	_game_state.set("board_slots", board)
	var owned: Array[String] = [ELEMENT_SET[0], ELEMENT_SET[1]]
	_game_state.set("owned_treasures", owned)
	# 时间轴：
	#   0–2.0s  棋盘（已有 2 件元素宝藏，套装未成立，没有光柱）
	#   2.0s    弹出抽宝藏三选一
	#   4.2s    选「雷霆加速」→ 立刻进入第二次三选一
	#   6.6s    选「剧毒蔓延」→ 元素套 4/4 成立，界面收起，棋盘亮起四元素
	#  12.0s    结束
	_at(_f(2.0), func(): _open_treasure_choice(TREASURE_ROUND_1, 2))
	_at(_f(4.2), func(): _pick_treasure_card(TREASURE_ROUND_1.find("elem_thunder_haste"), TREASURE_ROUND_2))
	_at(_f(6.6), func(): _pick_treasure_card(TREASURE_ROUND_2.find("elem_toxic_spread"), []))
	for m in [[2.0, "open"], [4.2, "pick_thunder"], [6.6, "pick_toxic"]]:
		_markers.append({"frame": _f(m[0]), "event": m[1]})
	_end_frame = _f(12.0)


func _open_treasure_choice(candidates: Array[String], remaining: int) -> void:
	_game_state.set("pending_treasure", {
		"active": true,
		"round": PREP_ROUND,
		"candidates": candidates.duplicate(),
		"refresh_index": 0,
		"remaining": remaining,
	})
	_screen.call("_refresh_all")


# 按的是三选一里那张真卡（TreasureChoicePanel._wire_candidate_card 接的 pressed）。
# 本地领取后游戏会随机摇下一轮候选，这里马上换成编排好的 next_round。
func _pick_treasure_card(index: int, next_round: Array[String]) -> void:
	var panel = _screen.get("_treasure")
	var row = panel.get("_treasure_choice_row") if panel != null else null
	if not (row is Container):
		push_warning("Treasure choice row missing")
		return
	var live: Array = []
	for child in (row as Container).get_children():
		if not child.is_queued_for_deletion():
			live.append(child)
	if index < 0 or index >= live.size():
		push_warning("No treasure card %d" % index)
		return
	(live[index] as BaseButton).pressed.emit()
	if not next_round.is_empty() and bool((_game_state.get("pending_treasure") as Dictionary).get("active", false)):
		(_game_state.get("pending_treasure") as Dictionary)["candidates"] = next_round.duplicate()
		panel.call("refresh")


# ---- fourstar ---------------------------------------------------------------

func _stage_four_star(defs: Dictionary) -> void:
	var board: Array = []
	board.resize(GameConstants.CELL_COUNT)
	board[FOUR_STAR_CELL] = _cell(defs, FOUR_STAR_UNIT, 3)
	# 陪衬放 2★：四星页只列三星棋子，这样右边只有人王一张卡，镜头不分散。
	for i in FOUR_STAR_SUPPORT.size():
		board[SUPPORT_CELLS[i]] = _cell(defs, FOUR_STAR_SUPPORT[i], 2)
	_game_state.set("board_slots", board)
	# 3 阶棋子升 4★ 要 1100 金币，留点余量。
	var king_cost := int(_game_state.call("four_star_cost", (board[FOUR_STAR_CELL] as Dictionary).get("def", {})))
	_game_state.set("gold", maxi(PREP_GOLD, king_cost + 200))
	# 用户 11.13：从萝卜营地开始，先让人看到升级石。所以开场一颗石头都没有，
	# 现场抽一颗人石，人王那张卡的「升级」才亮。
	_game_state.set("team_upgrade_stones", {"sky": 0, "land": 0, "ren": 0})
	var cost := int(_game_state.call("upgrade_stone_draw_cost"))
	_game_state.set("carrots", cost + 10)
	# 萝卜田容量也得装得下这次抽取的费用（request_upgrade_stone_draw 的第二道门槛）。
	var spent := 0
	while int(_game_state.call("carrot_capacity")) < cost and spent < 10000:
		spent += 10
		_game_state.set("merc_carrots_spent_total", spent)
	# 时间轴（真实点击路径，按的都是面板上那颗按钮）：
	#   0–2.0s   棋盘，人王 3★
	#   2.0s     打开萝卜营地
	#   3.4s     点「4-Star Upgrade」页签：左边抽石头，右边人王卡（缺石头，按钮灰）
	#   4.8s     点「Draw Once」→ 揭晓动画 → 人石；人王卡的「Upgrade」变金
	#   7.2s     点人王卡的「Upgrade」→ 营地收起，弹人王详情卡
	#   8.7s     点「Upgrade to ★★★★」→「Confirm upgrade」
	#   9.6s     点确认 → 全屏闪电劈下、3D 爆发、★★★★
	#  13.0s     结束
	_at(_f(2.0), func(): _screen.call("_toggle_carrot_camp"))
	_at(_f(3.4), func(): _press_camp("_stone_tab"))
	_at(_f(4.8), _draw_ren_stone)
	_at(_f(7.2), func(): _press_four_star_candidate())
	_at(_f(8.7), func(): _press_upgrade())
	_at(_f(9.6), func(): _press_upgrade())
	for m in [[2.0, "open_camp"], [3.4, "stone_tab"], [4.8, "draw"], [7.2, "candidate"],
			[8.7, "upgrade"], [9.6, "confirm"]]:
		_markers.append({"frame": _f(m[0]), "event": m[1]})
	_end_frame = _f(13.0)


func _draw_ren_stone() -> void:
	_rig_stone_roll("ren")
	_press_camp("_draw_button")


func _camp_panel() -> Object:
	return _screen.get("_carrot_panel")


func _press_camp(member: String) -> void:
	var panel := _camp_panel()
	var btn = panel.get(member) if panel != null else null
	if btn is Button and not (btn as Button).disabled:
		(btn as Button).pressed.emit()
	else:
		push_warning("Camp button %s missing or disabled" % member)


# 抽石头用的是全局 randf()（PrepBoardController.request_upgrade_stone_draw）。
# 找一个让下一次 randf() 落在目标属性的种子再 seed —— 抽取本身照常走游戏代码。
func _rig_stone_roll(stone_type: String) -> void:
	var economy := load("res://scripts/economy/CarrotEconomy.gd")
	for s in range(1, 1000):
		seed(s)
		if str(economy.draw_type_from_roll(randf())) == stone_type:
			seed(s)
			return
	push_warning("No seed found for stone %s" % stone_type)


# 四星页右边的候选卡：能升的排前面，抽完人石后人王就是第一张。
func _press_four_star_candidate() -> void:
	var panel := _camp_panel()
	var buttons: Array = panel.get("_four_star_buttons") if panel != null else []
	for b in buttons:
		if b is Button and is_instance_valid(b) and not (b as Button).disabled:
			(b as Button).pressed.emit()
			return
	push_warning("No enabled four-star candidate button")


# 按的是卡片里那颗真实的升级按钮（FourStarUpgradePanel.action），走的是玩家点击
# 同一条路径：第一次进入确认态，第二次 submit → _commit_four_star_uid → 本地结算。
func _press_upgrade() -> void:
	var overlay = _screen.get("_overlay")
	var panel = overlay.get("upgrade_panel") if overlay != null else null
	if panel == null:
		push_warning("No upgrade panel to press")
		return
	var btn = panel.get("action")
	if btn is Button and not (btn as Button).disabled:
		(btn as Button).pressed.emit()
	else:
		push_warning("Upgrade button disabled: %s" % str(panel.get("reason").text if panel.get("reason") else "?"))


# ---- shared -----------------------------------------------------------------

func _at(frame: int, cb: Callable) -> void:
	if not _timeline.has(frame):
		_timeline[frame] = []
	(_timeline[frame] as Array).append(cb)


func _cell(defs: Dictionary, id: String, star: int) -> Dictionary:
	if not defs.has(id):
		push_warning("Unknown unit id '%s'" % id)
		return {}
	return {
		"id": id,
		"star": star,
		"uid": str(_game_state.call("mint_piece_uid")),
		"def": (defs[id] as Dictionary).duplicate(true),
	}


func _unit_defs(data: Node) -> Dictionary:
	var defs: Dictionary = {}
	var table: Dictionary = data.call("get_table", "race_units")
	for entry in table.get("units", []):
		if typeof(entry) == TYPE_DICTIONARY:
			defs[str((entry as Dictionary).get("id", ""))] = entry
	return defs


func _process(_delta: float) -> bool:
	_frame += 1
	if not _setup_done:
		_setup_done = true
		_setup()
		_write_manifest()
		return false
	if _screen == null or not is_instance_valid(_screen):
		return true
	# 调试版左上角的「FPS n」不能进宣传素材（PrepScreen._setup_fps_overlay）。
	var fps_label = _screen.get("_fps_label")
	if fps_label is Label and is_instance_valid(fps_label):
		(fps_label as Label).visible = false
	if _timeline.has(_frame):
		for cb in _timeline[_frame]:
			(cb as Callable).call()
	if _frame >= _end_frame:
		_write_manifest()
		return true
	return false


func _finalize() -> void:
	if _screen != null and is_instance_valid(_screen):
		root.remove_child(_screen)
		_screen.free()
		_screen = null


func _write_manifest() -> void:
	if _out_dir.is_empty():
		return
	var manifest := {
		"shot": _shot,
		"fps": _fps,
		"locale": _locale,
		"end_frame": _end_frame,
		"total_frames": _frame,
		# Movie Maker 从 frame00000000.png 编号，帧号 N 的文件下标是 N-1。
		"markers": _markers,
	}
	var file := FileAccess.open(_out_dir.path_join("manifest.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(manifest, "  "))
		file.close()


func _parse_arguments() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var key := str(args[i])
		var value := str(args[i + 1]) if i + 1 < args.size() else ""
		match key:
			"--out": _out_dir = value
			"--shot": _shot = value
			"--fps": _fps = int(value)
			"--locale": _locale = value
			"--card-star": _card_star = clampi(int(value), 1, 4)
			_:
				push_warning("Unknown argument '%s'" % key)
				i += 1
				continue
		i += 2
