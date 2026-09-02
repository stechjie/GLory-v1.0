extends Control

# 备战界面的**宝物面板** —— D2 步骤 4′。
#
# 两块内容：
#   * 三选一浮层（回合结束后弹出，带倒计时与刷新按钮）
#   * 已持有宝物的 logo 栏（钱袋旁边那一排）
#
# 面板负责「显示候选、显示说明文案、把点击变成信号」；
# 真正的领取由宿主执行 —— 它要走服务端授予流程（NetworkService.treasure_granted），
# 不是面板能自己决定的事。
#
# 那几段 effect_text / link_effect_text 是纯查表的文案函数，
# 由 tools/prep_text_coverage_check.tscn 守着「数据表里每件宝物都有文案」——
# 少写一条不会崩，只会显示占位符。

const PrepWidgets := preload("res://scenes/prep/PrepWidgets.gd")
const TREASURE_CARD_DIRECTORY := "res://assets/ui/treasure_cards"

# 三选一层的 ModalStack 合同（C-11 的 C2）。
# 70：高于纯播报的 pvp_warning=60，低于战斗加载 80 与确认框 100 ——
# 抽宝时弹出的确认框必须盖在它上面，而它必须盖住 PvP 播报。
const TREASURE_MODAL_ID := "treasure_choice"
const TREASURE_MODAL_PRIORITY := 70
const PICK_PENDING_RETRY_MSEC := 5000
# 迁移前这 0.66 的黑是浮层自己那块 ColorRect；现在由 ModalStack 的 backdrop 承担，
# 数值逐字保持，玩家看到的变暗程度不变。
const TREASURE_BACKDROP_COLOR := Color(0.0, 0.0, 0.0, 0.66)

signal pick_requested(tid: String)  # 玩家点了某个候选；领取流程归宿主（要走服务端授予）
signal claim_requested              # 该结算这一轮的宝物了
signal net_signals_needed           # 联机重摇前，请宿主确保 NetworkService 宝物信号已连
signal state_changed                # 需要整屏刷新

# ⚠️ 面板节点是**零尺寸**的逻辑宿主。浮层用 PRESET_FULL_RECT 锚定，
# 挂到零尺寸父节点上锚点会解算成 0 大小 —— 界面直接消失，且不报错。
# 所以顶层控件一律 host.add_child(...)，挂在 PrepScreen 下，位置与原来一致。
# （节点树基线因此只多面板节点本身这一个。）
var host: Control
var overlay: RefCounted
var hover_handler: Callable


func setup(p_host: Control, p_overlay: RefCounted, p_hover: Callable) -> void:
	host = p_host
	overlay = p_overlay
	hover_handler = p_hover


# --- 搬过来的成员 ---
# 迁移后这四个都是**瞬时**节点：ModalStack 每次开层现建、关层销毁。
# 根不再是自带 dim 的 ColorRect，而是一块透明的全屏 Control。
var _treasure_overlay: Control
var _treasure_timer_lbl: Label
var _treasure_choice_row: HBoxContainer
var _treasure_refresh_btn: Button
var _owned_treasure_box: GridContainer

# 联机局点卡片只是发意图，要等服务端 grant/deny。这段等待里必须挡住连点，
# 否则一次选择会发出多份 treasure_choice。锁放在面板上而不是卡片上，并且跨
# ModalStack 的 Back/close_all 自愈保留；UI 重建不是服务端结算，不能顺手解锁。
# 5 秒后允许玩家再点一次作为有限重试，避免丢包变成永久不可操作。
var _pick_pending_tid := ""
var _pick_pending_since_msec := 0


# 原 _refresh_treasure_panel（PrepUI.gd）

func refresh() -> void:
	# 迁移前这里守的是 `_treasure_overlay == null`（常驻节点还没建好）。浮层现在是
	# 瞬时的，关着的时候本来就是 null —— 再守它，强制选择层就永远开不起来。
	# 改守 host：setup() 还没跑过时才是真的什么都做不了。
	if host == null or not is_instance_valid(host):
		return
	var active := bool(GameState.pending_treasure.get("active", false))
	if not active:
		# 玩法状态已经结算，旧意图锁不再属于任何待选 offer。
		clear_pick_pending()
		# 关：交给 ModalStack。三张卡随 content 一起销毁。
		# 注意 pending 已经由生产链（_pick_treasure / _on_treasure_granted）置成 false
		# 了才会走到这里 —— 关层本身从不改玩法状态。
		if ModalStack.has(TREASURE_MODAL_ID):
			ModalStack.pop(TREASURE_MODAL_ID, ModalStack.REASON_PROGRAMMATIC)
		else:
			_teardown_modal_state()
		return
	if not ModalStack.has(TREASURE_MODAL_ID):
		var content := _create_content()
		var modal_id := ModalStack.push(content, {
			"id": TREASURE_MODAL_ID,
			"owner": host,
			"priority": TREASURE_MODAL_PRIORITY,
			# 强制选择层：点外面**不能**关。玩家必须选一件宝物才能继续。
			"dismiss_on_backdrop": false,
			"backdrop_color": TREASURE_BACKDROP_COLOR,
		})
		if modal_id.is_empty():
			# 上面已用 has() 挡过重复；走到这里说明 push 真的失败了。
			# content 已被 push 收走，不能再 free，只清引用。
			_teardown_modal_state()
			return
		_treasure_overlay = content
		# 不清待定锁：Back / close_all 只重建 UI，同一份服务端意图仍在飞行中。
	if _treasure_choice_row == null or not is_instance_valid(_treasure_choice_row):
		return
	_treasure_timer_lbl.text = tr("ui_treasure_pick")
	for child in _treasure_choice_row.get_children():
		child.queue_free()
	var cands: Array = GameState.pending_treasure.get("candidates", [])
	for i in cands.size():
		var tid := str(cands[i])
		var t := TreasureService.treasure_by_id(tid)
		var tname := str(t.get("name", tid))
		var card := Button.new()
		card.custom_minimum_size = _treasure_card_size(cands.size())
		card.focus_mode = Control.FOCUS_NONE
		PrepWidgets.apply_empty_button_styles(card)
		PrepWidgets.configure_unframed_portrait_card(card, hover_handler)
		card.pressed.connect(_on_candidate_pressed.bind(tid))
		overlay.attach_long_press(card, show_detail.bind(tid))
		var tex := TextureRect.new()
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var _card_suffix := "_en" if LocaleManager.get_locale() == "en" else ""
		var _tex_path := "%s/%s%s.png" % [TREASURE_CARD_DIRECTORY, tname, _card_suffix]
		var _loaded_tex := PrepWidgets.cached_texture(_tex_path)
		if _loaded_tex == null:
			_loaded_tex = PrepWidgets.cached_texture("%s/%s.png" % [TREASURE_CARD_DIRECTORY, tname])
		tex.texture = _loaded_tex
		card.add_child(tex)
		# Safety net: if the card art is missing, never leave the card invisible —
		# show the treasure name so it stays selectable.
		if _loaded_tex == null:
			var fallback := Label.new()
			fallback.text = PrepWidgets.unit_name(t)
			fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
			fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			fallback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			fallback.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			fallback.add_theme_font_size_override("font_size", 28)
			fallback.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
			fallback.add_theme_constant_override("outline_size", 4)
			card.add_child(fallback)
		_treasure_choice_row.add_child(card)
	var cost := TreasureService.refresh_cost(int(GameState.pending_treasure.get("refresh_index", 0)), TreasureService.has_set("money"))
	_treasure_refresh_btn.text = tr("ui_treasure_refresh_free") if cost == 0 else tr("ui_treasure_refresh_cost") % cost
	_treasure_refresh_btn.disabled = GameState.gold < cost



# 原 _refresh_treasure_candidates（PrepFlowController.gd）

# 三选一抽宝藏卡的基准尺寸（336×448 整体放大 30% 得来）。
const TREASURE_CARD_BASE := Vector2(437, 582)
# 卡之间的水平间距，与 _create_content() 里 _treasure_choice_row 的 separation 一致。
const TREASURE_CARD_SEPARATION := 28.0
# 标题、刷新按钮与上下留白合计占掉的高度，用来算卡面还剩多少纵向空间。
const TREASURE_CHROME_HEIGHT := 138.0
# 再窄也不缩到看不清；低于这个比例就该改布局而不是继续缩。
const TREASURE_CARD_MIN_SCALE := 0.55
# 与 TutorialMode.BUBBLE_EDGE_MARGIN 同一条边距。两处各自定义是刻意的：
# scripts/tutorial 不应该反向依赖 scenes/prep。数值若要改，两边一起改。
const TREASURE_SAFE_INSET := 18.0


# V2 P1-09：卡面按 content 的实际可用矩形等比收缩，不再写死 437×582。
#
# 项目基准视口是 1600×720 且 stretch=canvas_items/expand，canvas 高度恒为 720、
# 宽度随设备宽高比在 1280（16:9）到 1600（20:9）之间变化。写死尺寸时：
#   * 16:9 与 1280×720 下三张卡要 437*3 + 28*2 = 1367 > 1280，两侧的卡被切掉 87px；
#   * 582 高的卡加上标题与刷新按钮约占 720 的 96%，安全区一压就出界。
# 等比收缩同时解决这两条，且宽高比保持不变，美术比例不会被拉伸。
func _treasure_card_size(count: int) -> Vector2:
	var slots := maxi(1, count)
	var available := Vector2.ZERO
	if _treasure_overlay != null and is_instance_valid(_treasure_overlay):
		available = _treasure_overlay.size
	if available.x <= 0.0 or available.y <= 0.0:
		# 还没入树时拿不到真实尺寸，退回基准视口，至少不会算出 0。
		available = Vector2(
			float(ProjectSettings.get_setting("display/window/size/viewport_width", 1600)),
			float(ProjectSettings.get_setting("display/window/size/viewport_height", 720)))
	# 上下各留一条安全边距再算可用高度 —— 否则 20:9（canvas 1600×720）与
	# 2640×1216 下正好差这一圈：582 + 138 = 720 塞满整块画布，安全区一收就出界。
	var usable_w := available.x - TREASURE_CARD_SEPARATION * float(slots - 1) - TREASURE_CARD_SEPARATION * 2.0
	var usable_h := available.y - TREASURE_CHROME_HEIGHT - TREASURE_SAFE_INSET * 2.0
	var scale_w := (usable_w / float(slots)) / TREASURE_CARD_BASE.x
	var scale_h := usable_h / TREASURE_CARD_BASE.y
	var scale := clampf(minf(scale_w, scale_h), TREASURE_CARD_MIN_SCALE, 1.0)
	return (TREASURE_CARD_BASE * scale).floor()


func _refresh_candidates() -> void:
	var cost := TreasureService.refresh_cost(int(GameState.pending_treasure.get("refresh_index", 0)), TreasureService.has_set("money"))
	if GameState.gold < cost:
		return
	GameState.gold -= cost
	# 联机局：钱仍在本地扣（金币还没有权威账本，见 A5/P1），但候选必须由服务端重摇——
	# 本地摇出来的东西不在服务端 offer 里，选的时候会被 not_offered 拒收。
	if NetworkService.team_active:
		# 联机重摇要先确保 NetworkService 的宝物信号已连上宿主 —— 那是宿主的事。
		net_signals_needed.emit()
		NetworkService.request_treasure_refresh()
		SaveManager.save_run()
		state_changed.emit()
		return
	GameState.pending_treasure.refresh_index = int(GameState.pending_treasure.get("refresh_index", 0)) + 1
	GameState.pending_treasure.candidates = TreasureService.roll_candidates(3)
	SaveManager.save_run()
	state_changed.emit()



# 原 _build_treasure_overlay（PrepUI.gd）

func build_overlay() -> void:
	# 迁移后这里不再建任何节点：浮层由 refresh() 在 pending 变 active 时现建，
	# 并 push 进 ModalStack（C-11 的 C2）。函数名保留 —— PrepUI._build() 在调它，
	# 改名会牵动本任务范围外的文件。
	#
	# 连 modal_closed 是这一层比前几层多出来的一步：它是**强制选择层**，
	# 被外部（close_all / Back / owner 释放）关掉时不能就这么算了，得自己回来。
	if not ModalStack.modal_closed.is_connected(_on_modal_closed):
		ModalStack.modal_closed.connect(_on_modal_closed)


# 每次开层现建一份 content。节点结构、字号、颜色、描边、间距 16 与 28、
# 刷新按钮 220×46 与迁移前逐项一致。两处差别：
#   1. 根不再是自带 0.66 黑的 ColorRect —— 变暗交给 backdrop，避免叠成两层黑；
#   2. 不再设 z_index=60 —— 层级由 ModalStack 的 CanvasLayer 管。
# 全链 IGNORE 到卡片为止：全屏 STOP 只能有 backdrop 一块。卡片缝隙的点击会落到
# backdrop 上被吃掉（dismiss_on_backdrop=false），既不穿透到底层备战页、也不关层。
func _create_content() -> Control:
	var root := Control.new()
	root.name = "TreasureChoiceOverlay"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var treasure_box := VBoxContainer.new()
	treasure_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	treasure_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	treasure_box.alignment = BoxContainer.ALIGNMENT_CENTER
	treasure_box.add_theme_constant_override("separation", 16)
	root.add_child(treasure_box)
	_treasure_timer_lbl = Label.new()
	_treasure_timer_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_treasure_timer_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_treasure_timer_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_treasure_timer_lbl.add_theme_font_size_override("font_size", 24)
	_treasure_timer_lbl.add_theme_color_override("font_color", Color(1.0, 0.92, 0.66))
	_treasure_timer_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_treasure_timer_lbl.add_theme_constant_override("outline_size", 3)
	treasure_box.add_child(_treasure_timer_lbl)
	_treasure_choice_row = HBoxContainer.new()
	_treasure_choice_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_treasure_choice_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_treasure_choice_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_treasure_choice_row.add_theme_constant_override("separation", 28)
	treasure_box.add_child(_treasure_choice_row)
	var treasure_refresh_holder := HBoxContainer.new()
	treasure_refresh_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	treasure_refresh_holder.alignment = BoxContainer.ALIGNMENT_CENTER
	treasure_refresh_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	treasure_box.add_child(treasure_refresh_holder)
	_treasure_refresh_btn = Button.new()
	_treasure_refresh_btn.custom_minimum_size = Vector2(220, 46)
	_treasure_refresh_btn.focus_mode = Control.FOCUS_NONE
	PrepWidgets.apply_refresh_button_styles(_treasure_refresh_btn)
	_treasure_refresh_btn.pressed.connect(_refresh_candidates)
	treasure_refresh_holder.add_child(_treasure_refresh_btn)
	return root


# 一次有效点击只发一次意图。联机局要等服务端 grant/deny，这中间连点必须无效。
func _on_candidate_pressed(tid: String) -> void:
	if not _pick_pending_tid.is_empty():
		var elapsed := Time.get_ticks_msec() - _pick_pending_since_msec
		if elapsed < PICK_PENDING_RETRY_MSEC:
			return
		# 没有 grant/deny 的有限重试。只在玩家再次点击时解锁，不建常驻 Timer。
		clear_pick_pending()
	_pick_pending_tid = tid
	_pick_pending_since_msec = Time.get_ticks_msec()
	pick_requested.emit(tid)


# 待定锁的结算口。grant / deny / offer_changed 三条由 PrepFlowController 调；
# pending 变 inactive 时本文件也会清。单纯关闭/重开 UI 不是结算，不得清锁。
func clear_pick_pending() -> void:
	_pick_pending_tid = ""
	_pick_pending_since_msec = 0


# 任何一条关闭路径（程序化 pop、close_all、Back、owner 释放）都会走到这里。
#
# ⚠️ 这里**绝不碰玩法状态**：不清 pending_treasure.active、不 claim round、
# 不发宝物。外部关掉这一层不等于玩家做出了选择 —— 那样等于白送一轮抽奖机会。
func _on_modal_closed(id: String, _reason: String) -> void:
	if id != TREASURE_MODAL_ID:
		return
	_teardown_modal_state()
	# ⚠️ 必须 deferred。ModalStack.close_all() 是 `while not _entries.is_empty()`，
	# 而 pop() 同步 emit modal_closed —— 在这里直接重新 push，_entries 永远不空，
	# 整个进程原地转死。deferred 回调在 close_all() 返回之后才跑。
	_restore_if_still_pending.call_deferred()


# 强制选择层的自愈：只要这一轮的宝物还没选，层就得回来。
# 不需要判断关闭原因 —— 玩家正常选中时生产链已经先把 active 置成 false，
# 这里读到 false 就什么都不做；外部关闭时 active 仍是 true，层就放回去。
func _restore_if_still_pending() -> void:
	if not is_instance_valid(self) or not is_inside_tree():
		return
	if host == null or not is_instance_valid(host) or not host.is_inside_tree():
		# owner 已经没了：只清 UI，pending 留着。下次进备战页由
		# _maybe_start_pending_treasure() / _refresh_all() 恢复。
		return
	if not bool(GameState.pending_treasure.get("active", false)):
		return
	if ModalStack.has(TREASURE_MODAL_ID):
		return
	refresh()


# content 已由 ModalStack 销毁（或即将销毁），这里只清本面板持有的引用。
# 不 free 任何节点 —— 所有权在 push 时就交出去了。
# 三张卡的 pressed 与长按连接随卡片一起消失，不会累积。
func _teardown_modal_state() -> void:
	_treasure_overlay = null
	_treasure_timer_lbl = null
	_treasure_choice_row = null
	_treasure_refresh_btn = null
	# 不清 _pick_pending_tid：外部 Back/close_all 后若 pending 仍 active，层会自愈；
	# 等待中的服务端意图必须继续锁住新建卡片，直到结算或有限重试到期。



# 原 _build_treasure_logos_panel（PrepUI.gd）
func build_logos_panel() -> void:
	# Active treasure/linkage logos, pinned to the bottom-left corner of the screen.
	# Grows up-right so it can hold 8-9 icons (owned treasures + active linkages).
	# 宝藏 logo：只保留图标，不再加左下灰色底框。
	var tp_w := 303.0
	var tp_h := 161.0
	var treasure_panel := Control.new()
	treasure_panel.name = "TreasurePanel"
	treasure_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	treasure_panel.anchor_left = 0.0
	treasure_panel.anchor_top = 1.0
	treasure_panel.anchor_right = 0.0
	treasure_panel.anchor_bottom = 1.0
	treasure_panel.offset_left = 6
	treasure_panel.offset_right = 6 + tp_w
	treasure_panel.offset_top = -10 - tp_h
	treasure_panel.offset_bottom = -10
	treasure_panel.z_index = -5            # 河流(z-19)之上、石框(z0)之下：石框画在灰框上面，不被挡
	host.add_child(treasure_panel)
	# 宝藏 grid 左对齐（4 列 × 2 行横排，66px）。
	_owned_treasure_box = GridContainer.new()
	_owned_treasure_box.columns = 4
	_owned_treasure_box.anchor_left = 0.0
	_owned_treasure_box.anchor_top = 0.0
	_owned_treasure_box.anchor_right = 0.0
	_owned_treasure_box.anchor_bottom = 0.0
	_owned_treasure_box.offset_left = 0
	_owned_treasure_box.offset_top = 0
	_owned_treasure_box.grow_horizontal = Control.GROW_DIRECTION_END
	_owned_treasure_box.grow_vertical = Control.GROW_DIRECTION_END
	_owned_treasure_box.add_theme_constant_override("h_separation", 5)
	_owned_treasure_box.add_theme_constant_override("v_separation", 5)
	treasure_panel.add_child(_owned_treasure_box)



# 原 _show_treasure_detail（PrepShared.gd）

func show_detail(tid: String) -> void:
	pass



# 原 _treasure_category_name（PrepDetails.gd）

func category_name(category: String) -> String:
	if PrepWidgets.is_en():
		match category:
			"defense": return "Defense"
			"control": return "Control"
			"attack":  return "Attack"
			"money":   return "Money"
			"element": return "Element"
		return category
	match category:
		"defense": return "防御"
		"control": return "控制"
		"attack":  return "攻击"
		"money":   return "金钱"
		"element": return "元素"
	return category



# 原 _treasure_set_status（PrepDetails.gd）
func set_status(category: String) -> String:
	if category.is_empty() or not TreasureService.has_set(category):
		return ""
	var names: Array[String] = []
	for tid in GameState.owned_treasures:
		var t := TreasureService.treasure_by_id(str(tid))
		if str(t.get("category", "")) == category:
			names.append(PrepWidgets.localized_name(t))
	if PrepWidgets.is_en():
		return "Set: %s\nSet Bonus: %s" % [" + ".join(names), set_effect_text(category)]
	return "套装：%s\n套装效果：%s" % [" + ".join(names), set_effect_text(category)]



# 原 _treasure_linkage_status（PrepDetails.gd）
func linkage_status(tid: String) -> Array[String]:
	var lines: Array[String] = []
	var links: Array = DataRegistry.get_table("treasures").get("linkages", [])
	for link in links:
		var d: Dictionary = link
		var requires: Array = d.get("requires", [])
		if not requires.has(tid):
			continue
		var link_id := str(d.get("id", ""))
		if not TreasureService.has_linkage(link_id):
			continue
		var names: Array[String] = []
		for req in requires:
			var req_id := str(req)
			var req_t := TreasureService.treasure_by_id(req_id)
			names.append(PrepWidgets.localized_name(req_t))
		if PrepWidgets.is_en():
			lines.append("Synergy: %s\nSynergy Effect: %s" % [" + ".join(names), link_effect_text(link_id)])
		else:
			lines.append("联动：%s\n联动效果：%s" % [" + ".join(names), link_effect_text(link_id)])
	return lines



# 原 _treasure_set_effect_text（PrepDetails.gd）
func set_effect_text(category: String) -> String:
	if PrepWidgets.is_en():
		match category:
			"defense": return "4 Defense: Normal units gain HP/DEF +30% and Dodge +15% at battle start."
			"control": return "4 Control: Each debuff application randomly triggers one of: slow / ATK down / silence / stun / poison / disarm / bleed."
			"attack":  return "4 Attack: Normal units prioritize the lowest-HP enemy."
			"money":   return "4 Money: Shop refresh and treasure refresh are free."
			"element": return "4 Element: Normal units' attacks have a 20% chance to trigger an AoE (radius 180) elemental burst dealing 10% max HP true damage."
		return ""
	match category:
		"defense": return "4防御：普通棋子开战 HP/DEF +30%，闪避 +15%。"
		"control": return "4控制：每次触发负面效果，随机再触发减速/减攻/沉默/眩晕/中毒/缴械/失血之一。"
		"attack":  return "4攻击：普通棋子优先攻击当前低血敌人。"
		"money":   return "4金钱：商店刷新和宝藏刷新免费。"
		"element": return "4元素：普通棋子攻击 20% 概率触发 180 范围元素爆发，对范围敌人造成最大生命 10% 真实伤害。"
	return ""



# 原 _treasure_effect_text（PrepDetails.gd）
func effect_text(tid: String) -> String:
	if PrepWidgets.is_en():
		return effect_text_en(tid)
	match tid:
		"def_iron_wall":        return "开战时我方普通棋子 DEF +10。"
		"def_life_monument":    return "开战时我方普通棋子最大生命 +20%，当前生命同步提高；胡牌手激活后改为 +40%。"
		"def_formation_heal":   return "每次战后我方法阵 HP +1，不超过初始上限；胡牌手激活后改为 +2。"
		"def_soul_counter":     return "我方普通棋子死亡时，对击杀者造成其最大生命 35% 真实伤害。"
		"def_lifesteal_emblem": return "我方普通棋子造成伤害后，回复实际伤害 20% 的生命。"
		"def_phantom_step":     return "开战时我方普通棋子闪避 +20%。"
		"ctrl_shockwave":       return "我方普通棋子攻击时触发，对当前目标眩晕 1 秒，冷却 5 秒；胡牌手激活后眩晕 2 秒。"
		"ctrl_corrosive_needle":return "我方普通棋子每第 4 次攻击使目标失血，冷却 5 秒。"
		"ctrl_interrupt_chain": return "我方普通棋子攻击时 25% 概率缴械目标（1 秒内无法普攻），冷却 5 秒。"
		"ctrl_time_compress":   return "我方普通棋子技能冷却缩短 25%，首次与后续冷却均乘以 0.75。"
		"ctrl_binding_weight":  return "我方普通棋子攻击时使目标移动 -25%、攻速 -20%，持续 2 秒，冷却 5 秒。"
		"atk_blood_pact":       return "开战时我方普通棋子 ATK x1.25，但自身永久失血；胡牌手激活后改为 ATK x1.50。"
		"atk_fury_roster":      return "普通棋子上限从 7 提高到 8。"
		"atk_burst_core":       return "开战时我方普通棋子暴击率 +25%。"
		"atk_wail_resonance":   return "击杀敌人时，对死亡目标周围 180 范围敌人造成其最大生命 15% 真实伤害。"
		"atk_frenzy_assault":   return "攻击同一目标时自身攻速 x1.15，可叠；换目标重置。"
		"money_compound":       return "单件战后利息额外 +5% 当前金币。与雷霆加速联动后造成伤害有概率获得金币。"
		"money_generous_fate":  return "准备阶段每回合可手动参与 1 次赌博：50% 概率胜利使当前金币翻倍；50% 概率失败并损失当前金币的 80%。与幻影步伐联动后变为 60% 翻倍、40% 损失当前金币 50%。"
		"money_discount":       return "棋子商店价格 -20%；与狂怒阵容联动后变为 -40%。"
		"money_golden_altar":   return "准备阶段出现黄金祭坛按钮：-1 法阵 HP，+50 金，每回合最多 3 次，HP <=10 不可用。"
		"money_lucky_envelope": return "战后随机 +10~30 金；与时空压缩联动后额外随机 +50~70 金，10% 概率额外 +100 金。"
		"elem_flame_shatter":   return "攻击有 25% 概率额外造成 40% ATK 真实伤害；与吸血纹章联动后提高到 100%。"
		"elem_frost_blade":     return "攻击有 25% 概率使目标移动/攻速 -35%，持续 1.5 秒；与打断锁链联动后目标受伤 +15%。"
		"elem_thunder_haste":   return "攻击有 25% 概率使自身攻速 +60%，持续 3 秒，重复触发只刷新时间；与复利之道联动后造成伤害 10% 概率 +10 金。"
		"elem_toxic_spread":    return "攻击有 25% 概率使目标中毒；与爆裂核心联动后，造成伤害时中毒目标有 50% 概率提前结算剩余毒伤。"
	return "暂未写入详细说明。"



# 原 _treasure_effect_text_en（PrepDetails.gd）
func effect_text_en(tid: String) -> String:
	match tid:
		"def_iron_wall":        return "At battle start, friendly normal units gain DEF +10."
		"def_life_monument":    return "At battle start, friendly normal units gain max HP +20% (current HP increases too). With Hu Pai Master: +40%."
		"def_formation_heal":   return "After each battle, restore 1 Formation HP (up to the starting cap). With Hu Pai Master: +2."
		"def_soul_counter":     return "When a friendly normal unit dies, deal 35% of the killer's max HP as true damage."
		"def_lifesteal_emblem": return "Friendly normal units restore 20% of actual damage dealt as HP."
		"def_phantom_step":     return "At battle start, friendly normal units gain Dodge +20%."
		"ctrl_shockwave":       return "On attack, stun the current target for 1s (CD 5s). With Hu Pai Master: stun 2s."
		"ctrl_corrosive_needle":return "Every 4th attack causes the target to bleed (CD 5s)."
		"ctrl_interrupt_chain": return "25% chance to disarm the target on attack (cannot use normal attacks for 1s; CD 5s)."
		"ctrl_time_compress":   return "Friendly normal units' skill cooldowns are reduced by 25% (multiplied by 0.75)."
		"ctrl_binding_weight":  return "On attack, reduce target movement by 25% and AS by 20% for 2s (CD 5s)."
		"atk_blood_pact":       return "At battle start, friendly normal units gain ATK ×1.25 but permanently bleed. With Hu Pai Master: ATK ×1.50."
		"atk_fury_roster":      return "Normal unit board limit increased from 7 to 8."
		"atk_burst_core":       return "At battle start, friendly normal units gain Crit +25%."
		"atk_wail_resonance":   return "On kill, deal 15% of the target's max HP as true damage to all enemies within radius 180."
		"atk_frenzy_assault":   return "Attacking the same target stacks own AS ×1.15 (stackable); resets on target switch."
		"money_compound":       return "After battle, gain bonus interest equal to +5% of current gold. Synergy with Thunder Haste: chance to earn 1G on damage."
		"money_generous_fate":  return "Once per prep phase, gamble: 50% chance to double current gold; 50% chance to lose 80% of current gold. Synergy with Phantom Step: becomes 60%/40% with 50% loss."
		"money_discount":       return "Shop unit prices -20%. Synergy with Fury Roster: -40%."
		"money_golden_altar":   return "Adds a Golden Altar button during prep: spend 1 Formation HP to gain +50G (max 3 times per round; unavailable at HP ≤10)."
		"money_lucky_envelope": return "After battle, gain a random +10~30G. Synergy with Time Compress: +50~70G extra, with 10% chance of +100G."
		"elem_flame_shatter":   return "25% chance on attack to deal extra 40% ATK true damage. Synergy with Lifesteal Emblem: increases to 100%."
		"elem_frost_blade":     return "25% chance on attack to reduce target movement and AS by 35% for 1.5s. Synergy with Interrupt Chain: target takes +15% damage."
		"elem_thunder_haste":   return "25% chance on attack to grant own AS +60% for 3s (refreshes on re-trigger). Synergy with Compound Interest: 10% chance to gain +10G on damage."
		"elem_toxic_spread":    return "25% chance on attack to poison the target. Synergy with Burst Core: 50% chance to instantly resolve remaining poison damage."
	return "Description not yet available."



# 原 _treasure_link_effect_text（PrepDetails.gd）
func link_effect_text(link_id: String) -> String:
	if PrepWidgets.is_en():
		match link_id:
			"link_phoenix":           return "Friendly normal units revive at full HP with invulnerability for 3s after dying, then die for real."
			"link_money_magic":       return "After battle, gain an extra random +50~70G, with a 10% chance of +100G."
			"link_blood_covenant":    return "Flame Shatter true damage increases from 40% ATK to 100% ATK."
			"link_paralysis_shackles":return "On successful disarm, also apply ice effect; ice-affected targets take +15% damage."
			"link_oppression_counter":return "When a friendly normal unit is hit, apply ATK -20% to the attacker for 2s; also stacks Frenzy Assault AS logic on them."
			"link_fraud_fate":        return "Generous Fate becomes: 60% chance to double gold, 40% chance to lose 50% of gold."
			"link_iron_maiden":       return "When a friendly normal unit is hit, inflict bleed and armor break on the attacker (CD 5s)."
			"link_toxic_burst":       return "On dealing damage, 50% chance to instantly resolve remaining poison on poisoned targets."
			"link_rich_path":         return "10% chance to gain +10G on dealing damage."
			"link_clearance_sale":    return "Auto-activates when Fury Roster + Discount Token are both owned: shop prices -40%."
			"link_hu_pai_master":     return "Activates when Life Monument + Formation Heal + Shockwave + Blood Pact + Fury Roster are all owned: doubles the positive values of the first four treasures, and Fury Roster's unit cap gains +1 more (7 -> 9); cooldowns, chances, and costs unchanged."
		return "Synergy description not yet available."
	match link_id:
		"link_phoenix":           return "我方普通棋子死亡后满血复活并获得无敌，持续 3 秒，之后强制真死。"
		"link_money_magic":       return "战后额外随机 +50~70 金，10% 概率额外 +100 金。"
		"link_blood_covenant":    return "炎焰碎裂触发时，真实伤害从 ATK 40% 提高到 ATK 100%。"
		"link_paralysis_shackles":return "缴械成功后额外触发冰效果，被冰影响目标受伤 +15%。"
		"link_oppression_counter":return "我方普通棋子被攻击时，对攻击者施加减攻 20%，持续 2 秒；攻击者也会被叠加狂暴进攻攻速逻辑。"
		"link_fraud_fate":        return "慷慨命运变为每回合手动赌博 1 次：60% 金币翻倍，40% 损失当前金币 50%。"
		"link_iron_maiden":       return "我方普通棋子受击时反施失血和破甲，冷却 5 秒。"
		"link_toxic_burst":       return "造成伤害时，中毒目标有 50% 概率提前结算剩余毒伤。"
		"link_rich_path":         return "造成伤害后 10% 概率 +10 金。"
		"link_clearance_sale":    return "狂怒阵容与折扣令牌同时拥有时自动激活，棋子商店价格 -40%。"
		"link_hu_pai_master":     return "生命丰碑、法阵回春、震荡余波、血契之刃、狂怒阵容同时拥有时激活：前四件宝藏的正面数值翻倍，狂怒阵容棋子上限再 +1（7→9）；冷却、概率、次数和负面代价不变。"
	return "联动效果待说明。"
