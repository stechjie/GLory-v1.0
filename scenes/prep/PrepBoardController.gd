extends "res://scenes/prep/PrepFlowController.gd"

# 商店档位曲线与服务端共用一份，见 scripts/economy/ShopRoll.gd。
# 用 preload 而非 class_name：新增的全局类要等编辑器重扫才进类缓存，
# 而服务端包是直接打包仓库里的缓存文件的（make_server_zip.ps1）。
const ShopRoll := preload("res://scripts/economy/ShopRoll.gd")
const CarrotEconomy := preload("res://scripts/economy/CarrotEconomy.gd")
func _drop_on_board(board_index: int, data: Variant) -> void:
	_drop_consumed = true
	_set_shop_sell_mode(false)
	if typeof(data) != TYPE_DICTIONARY:
		return
	var d: Dictionary = data
	match str(d.get("kind", "")):
		"shop":
			if GameState.tutorial_mode:
				return
			_buy_or_merge_shop_to_board(int(d.get("index", -1)), board_index)
		"board":
			_move_or_merge_board(int(d.get("index", -1)), board_index)
		"bench":
			if GameState.tutorial_mode and TutorialMode.step == TutorialMode.Step.BUY_3:
				return
			_move_or_merge_bench_to_board(int(d.get("index", -1)), board_index)
func _drop_on_bench(bench_index: int, data: Variant) -> void:
	_drop_consumed = true
	_set_shop_sell_mode(false)
	if typeof(data) != TYPE_DICTIONARY:
		return
	var d: Dictionary = data
	match str(d.get("kind", "")):
		"shop":
			_buy_or_merge_shop_to_bench(int(d.get("index", -1)), bench_index)
		"board":
			_move_or_merge_board_to_bench(int(d.get("index", -1)), bench_index)
		"bench":
			_move_or_merge_bench(int(d.get("index", -1)), bench_index)

func _can_drop_to_sell(data: Variant) -> bool:
	return typeof(data) == TYPE_DICTIONARY and str((data as Dictionary).get("kind", "")) in ["board", "bench"]

func _drop_to_sell(data: Variant) -> void:
	_drop_consumed = true
	_set_shop_sell_mode(false)
	if not _can_drop_to_sell(data):
		return
	var d := data as Dictionary
	match str(d.get("kind", "")):
		"bench":
			_sell_bench_index(int(d.get("index", -1)))
		_:
			_sell_board_index(int(d.get("index", -1)))

func _on_drag_started(payload: Dictionary) -> void:
	_active_drag_payload = payload.duplicate(true)
	_drop_consumed = false
	_set_shop_sell_mode(str(payload.get("kind", "")) in ["board", "bench"])
	_board_hud.drop_highlight_active = str(payload.get("kind", "")) in ["shop", "board", "bench"]
	_board_hud.drop_hover_index = -1
	_board_hud.standby_drop_highlight_active = str(payload.get("kind", "")) in ["shop", "board", "bench"]
	_board_hud.standby_drop_hover_index = -1
	_board_hud.refresh_board()
	_board_hud.refresh_bench()
	if GameState.tutorial_mode:
		TutorialMode.update_overlay()

func _on_drag_ended() -> void:
	# Released without landing on a cell -> snap into the nearest valid cell.
	if not _drop_consumed and not _active_drag_payload.is_empty():
		_snap_drop_to_nearest(get_global_mouse_position(), _active_drag_payload)
	_active_drag_payload = {}
	_drop_consumed = false
	_set_shop_sell_mode(false)
	_board_hud.drop_highlight_active = false
	_board_hud.drop_hover_index = -1
	_board_hud.standby_drop_highlight_active = false
	_board_hud.standby_drop_hover_index = -1
	_board_hud.refresh_board()
	_board_hud.refresh_bench()
	if GameState.tutorial_mode:
		TutorialMode.update_overlay()

func _snap_drop_to_nearest(global_pos: Vector2, payload: Dictionary) -> void:
	# Search board + bench cells for the nearest one that accepts this payload.
	var best_dist := INF
	var best_is_board := false
	var best_index := -1
	for i in _board_hud.buttons.size():
		var btn: Control = _board_hud.buttons[i]
		if not is_instance_valid(btn) or not btn.is_visible_in_tree():
			continue
		if not PrepRules.can_drop_on_board(i, payload):
			continue
		var dist := global_pos.distance_to(btn.get_global_rect().get_center())
		if dist < best_dist:
			best_dist = dist
			best_is_board = true
			best_index = i
	for i in _board_hud.bench_buttons.size():
		var btn: Control = _board_hud.bench_buttons[i]
		if not is_instance_valid(btn) or not btn.is_visible_in_tree():
			continue
		if not PrepRules.can_drop_on_bench(i, payload):
			continue
		var dist := global_pos.distance_to(btn.get_global_rect().get_center())
		if dist < best_dist:
			best_dist = dist
			best_is_board = false
			best_index = i
	if best_index < 0:
		return
	# Only snap from a reasonable distance so far-away releases are ignored.
	if best_dist > 180.0:
		return
	if best_is_board:
		_drop_on_board(best_index, payload)
	else:
		_drop_on_bench(best_index, payload)
func _set_shop_sell_mode(enabled: bool) -> void:
	_shop.drag_sell_mode = enabled
	if _shop.sell_overlay != null:
		_shop.sell_overlay.visible = enabled

func _on_hire_mercenary(index: int) -> void:
	if not PrepRules.can_hire_mercenary(index):
		return
	var empty := PrepRules.first_empty_mercenary_slot()
	if empty < 0:
		return
	_hire_mercenary_to_slot(index, empty)
	if GameState.tutorial_mode:
		TutorialMode.sync()
func _hire_mercenary_to_slot(index: int, mercenary_index: int) -> void:
	var mercs: Array = DataRegistry.get_table("mercenaries").get("mercenaries", [])
	if index < 0 or index >= mercs.size():
		return
	if mercenary_index < 0 or mercenary_index >= GameState.mercenary_slots.size():
		return
	if GameState.mercenary_slots[mercenary_index] != null:
		return
	if not PrepRules.can_hire_mercenary(index):
		return
	var m: Dictionary = mercs[index]
	if not GameState.tutorial_mode and NetworkService.team_active and not NetworkService.is_host:
		if not NetworkService.carrot_economy_enabled():
			show_message("联机萝卜系统尚未开启")
			return
		NetworkService.request_economy("hire_merc_carrot", {
			"merc_id": str(m.get("id", "")),
			"merc_slot": mercenary_index,
		})
		return
	var cost := int(m.get("cost", 0))
	var carrot_cost := int(m.get("carrot_cost", -1))
	if GameState.tutorial_mode:
		if GameState.gold < cost:
			show_message(tr("ui_not_enough_gold"))
			return
		GameState.gold -= cost
	else:
		if carrot_cost < 0 or GameState.carrots < carrot_cost:
			show_message("萝卜不足")
			return
		GameState.carrots -= carrot_cost
		GameState.record_merc_carrot_spend(carrot_cost)
	var def := m.duplicate(true)
	def["is_mercenary"] = true
	GameState.mercenary_slots[mercenary_index] = {"id": def.id, "uid": GameState.mint_piece_uid(), "star": 1, "def": def, "is_mercenary": true}
	_mark_online_board_changed()
	NetworkService.team_send_prep_mercs()
	SaveManager.save_run()
	_refresh_all()
	# A carrot-paid hire can cross a farm threshold. Refresh the world prop in
	# the same transaction so its decoration and level-up VFX change immediately.
	refresh_carrot_gathering()

func request_carrot_harvest_upgrade() -> void:
	if GameState.tutorial_mode:
		return
	if NetworkService.team_active and not NetworkService.is_host:
		if not NetworkService.carrot_economy_enabled():
			show_message("联机萝卜系统尚未开启")
			return
		# In carrot-only rollout the full gold ledger is not authoritative yet.
		# Report the current balance; the server only accepts a value no higher
		# than its last settled balance before applying the upgrade cost.
		NetworkService.request_economy("upgrade_harvest_tech", {"gold": GameState.gold})
		return
	var result := GameState.upgrade_harvest_tech()
	if not bool(result.get("ok", false)):
		show_message("采集科技无法升级：%s" % str(result.get("error", "denied")))
		return
	SaveManager.save_run()
	_refresh_all()

func request_upgrade_stone_draw() -> void:
	if GameState.tutorial_mode:
		return
	if not GameState.can_draw_upgrade_stone(GameState.round_index):
		show_message("本回合已经抽取过升级石")
		return
	if GameState.carrots < CarrotEconomy.STONE_COST:
		show_message("萝卜不足：需要50萝卜")
		return
	if GameState.carrot_capacity() < CarrotEconomy.STONE_COST:
		show_message("萝卜田4级后才能储存50萝卜")
		return
	if NetworkService.team_active and not NetworkService.is_host:
		# 与 request_carrot_harvest_upgrade / _hire_mercenary_to_slot 同一道判据。
		# 少了它，开关关掉时服务端会在 _rpc_economy_intent 直接 return（不发回执），
		# 玩家点了没有任何反应也没有任何提示 —— 面板的 online_blocked 置灰读的是
		# **客户端本机**的 flags 文件，两端不一致时按钮是亮的。
		if not NetworkService.carrot_economy_enabled():
			show_message("联机萝卜系统尚未开启")
			return
		NetworkService.request_economy("draw_upgrade_stone", {})
		return
	GameState.carrots -= CarrotEconomy.STONE_COST
	GameState.stone_draw_used_round = GameState.round_index
	var stone_type := CarrotEconomy.draw_type_from_roll(randf())
	GameState.apply_team_stone(stone_type)
	SaveManager.save_run()
	show_message("获得%s石" % {"sky": "天", "land": "地", "ren": "人"}.get(stone_type, stone_type))
	_refresh_all()

# 用一颗同属性升级石把三星升为四星。
# where 是 "board" / "bench"，index 是该数组下标 —— 面板列出来的就是这两个来源。
#
# 判定全部委托 GameState.four_star_check()：面板置灰用它、这里执行也用它，
# 同一份条件不会分家。四星**不能**靠合成获得（合成封顶在 MAX_MERGE_STAR），
# 所以这是唯一的入口。
func request_four_star_upgrade(where: String, index: int) -> void:
	if GameState.tutorial_mode:
		return
	var slots: Array = GameState.board_slots if where == "board" else GameState.bench_slots
	if index < 0 or index >= slots.size():
		return
	var cell = slots[index]
	# 联机客机：石头在**服务端的队伍仓库**里，本地扣只会被下一份 room_state 还回来
	# （_apply_carrot_state 整块覆盖 team_upgrade_stones）—— 那正是「点了没东西、
	# 而且一颗石头能反复用」的成因。只发意图，等回执落星级。
	if NetworkService.team_active and not NetworkService.is_host:
		if not NetworkService.carrot_economy_enabled():
			show_message("联机萝卜系统尚未开启")
			return
		# 本地这份判据**只**用于即时提示与按钮置灰，裁决权在服务端
		# （EconomyLedger._use_upgrade_stone）。两份判据读的是同一批条件，
		# 但服务端那份是唯一算数的。
		var check := GameState.four_star_check(cell)
		if not bool(check.get("ok", false)):
			show_message("无法升四星：%s" % str(check.get("error", "denied")))
			return
		var c: Dictionary = cell
		NetworkService.request_economy("use_upgrade_stone", {
			"uid": str(c.get("uid", "")),
			"unit_id": str(c.get("id", "")),
		})
		return
	var result := GameState.upgrade_cell_to_four_star(cell)
	if not bool(result.get("ok", false)):
		show_message("无法升四星：%s" % str(result.get("error", "denied")))
		return
	var d: Dictionary = (cell as Dictionary).get("def", {})
	show_message("%s 升为四星" % str(d.get("name", d.get("id", "棋子"))))
	if where == "board":
		_mark_online_board_changed()
	SaveManager.save_run()
	_refresh_all()
func _on_board_pressed(index: int) -> void:
	if _shop.selected >= 0:
		_buy_or_merge_shop_to_board(_shop.selected, index)
		return
	if _board_hud._selected_bench >= 0:
		_move_or_merge_bench_to_board(_board_hud._selected_bench, index)
		return
	if _board_hud._selected_board >= 0 and _board_hud._selected_board != index:
		_move_or_merge_board(_board_hud._selected_board, index)
		return
	if GameState.board_slots[index] != null:
		_board_hud._selected_board = index
		_board_hud._selected_bench = -1
	else:
		_board_hud._selected_board = -1
	_refresh_all()

func _on_bench_pressed(index: int) -> void:
	if _shop.selected >= 0:
		_buy_or_merge_shop_to_bench(_shop.selected, index)
		return
	if _board_hud._selected_board >= 0:
		_move_or_merge_board_to_bench(_board_hud._selected_board, index)
		return
	if _board_hud._selected_bench >= 0 and _board_hud._selected_bench != index:
		_move_or_merge_bench(_board_hud._selected_bench, index)
		return
	if GameState.bench_slots[index] != null:
		_board_hud._selected_bench = index
		_board_hud._selected_board = -1
	else:
		_board_hud._selected_bench = -1
	_refresh_all()

func _buy_or_merge_shop_to_board(shop_index: int, board_index: int) -> void:
	if GameState.tutorial_mode:
		_shop.selected = -1
		_refresh_all()
		return
	if shop_index < 0 or shop_index >= GameState.shop_offers.size() or bool(GameState.shop_sold[shop_index]):
		return
	if board_index < 0 or board_index >= GameState.board_slots.size():
		return
	var offer: Dictionary = GameState.shop_offers[shop_index]
	var cost := _shop_unit_cost(offer)
	var target = GameState.board_slots[board_index]
	var incoming := {"id": offer.id, "uid": GameState.mint_piece_uid(), "star": 1, "def": offer.duplicate(true)}
	if target == null:
		if bool(offer.get("unique_on_board", false)) and PrepRules.has_unique_board_unit(str(offer.get("id", "")), PrepRules.board_limit_for_def(offer)):
			show_message(tr("toast_unique_limit"))
			return
		if GameState.normal_unit_count() >= GameState.normal_unit_cap():
			show_message(tr("toast_board_full") % GameState.normal_unit_cap())
			return
		if GameState.gold < cost:
			show_message(tr("ui_not_enough_gold"))
			return
		GameState.gold -= cost
		GameState.board_slots[board_index] = incoming
		GameState.shop_sold[shop_index] = true
		_shadow_report_buy(shop_index, incoming)
	elif PrepRules.can_merge_cells(target, incoming):
		if GameState.gold < cost:
			show_message(tr("ui_not_enough_gold"))
			return
		if not _merge_copies_into_cell(target, incoming, [board_index], []):
			return
		GameState.gold -= cost
		GameState.shop_sold[shop_index] = true
		_shadow_report_buy(shop_index, incoming)
		_shadow_report_merge()
	else:
		return
	_shop.selected = -1
	if GameState.tutorial_mode:
		TutorialMode.record_shop_purchase()
	_mark_online_board_changed()
	SaveManager.save_run()
	_refresh_all()

func _buy_or_merge_shop_to_bench(shop_index: int, bench_index: int) -> void:
	if shop_index < 0 or shop_index >= GameState.shop_offers.size() or bool(GameState.shop_sold[shop_index]):
		return
	if bench_index < 0 or bench_index >= GameState.bench_slots.size():
		return
	var offer: Dictionary = GameState.shop_offers[shop_index]
	var cost := _shop_unit_cost(offer)
	var target = GameState.bench_slots[bench_index]
	var incoming := {"id": offer.id, "uid": GameState.mint_piece_uid(), "star": 1, "def": offer.duplicate(true)}
	if target == null:
		if GameState.gold < cost:
			show_message(tr("ui_not_enough_gold"))
			return
		GameState.gold -= cost
		GameState.bench_slots[bench_index] = incoming
		GameState.shop_sold[shop_index] = true
		_shadow_report_buy(shop_index, incoming)
	elif PrepRules.can_merge_cells(target, incoming):
		if GameState.gold < cost:
			show_message(tr("ui_not_enough_gold"))
			return
		if not _merge_copies_into_cell(target, incoming, [], [bench_index]):
			return
		GameState.gold -= cost
		GameState.shop_sold[shop_index] = true
		_shadow_report_buy(shop_index, incoming)
		_shadow_report_merge()
	else:
		return
	_shop.selected = -1
	if GameState.tutorial_mode:
		TutorialMode.record_shop_purchase()
	SaveManager.save_run()
	_refresh_all()
func _would_exceed_board_limit(cell: Dictionary, ignore_index: int = -1) -> bool:
	var d: Dictionary = cell.get("def", {})
	return bool(d.get("unique_on_board", false)) and PrepRules.has_unique_board_unit(str(cell.get("id", "")), PrepRules.board_limit_for_def(d), ignore_index)

func _move_or_merge_board(from_index: int, to_index: int) -> void:
	if from_index < 0 or from_index >= GameState.board_slots.size() or to_index < 0 or to_index >= GameState.board_slots.size():
		_board_hud._selected_board = -1
		return
	var from_cell = GameState.board_slots[from_index]
	var to_cell = GameState.board_slots[to_index]
	if from_cell == null:
		_board_hud._selected_board = -1
		return
	if to_cell == null:
		GameState.board_slots[to_index] = from_cell
		GameState.board_slots[from_index] = null
	elif PrepRules.can_merge_cells(to_cell, from_cell):
		if not _merge_copies_into_cell(to_cell, from_cell, [from_index, to_index], []):
			_board_hud._selected_board = -1
			_refresh_all()
			return
		_shadow_report_merge()
		GameState.board_slots[from_index] = null
	else:
		GameState.board_slots[to_index] = from_cell
		GameState.board_slots[from_index] = to_cell
	_board_hud._selected_board = -1
	_mark_online_board_changed()
	SaveManager.save_run()
	_refresh_all()

func _move_or_merge_board_to_bench(from_index: int, bench_index: int) -> void:
	if from_index < 0 or from_index >= GameState.board_slots.size() or bench_index < 0 or bench_index >= GameState.bench_slots.size():
		_board_hud._selected_board = -1
		return
	var from_cell = GameState.board_slots[from_index]
	var to_cell = GameState.bench_slots[bench_index]
	if from_cell == null:
		_board_hud._selected_board = -1
		return
	if to_cell == null:
		GameState.bench_slots[bench_index] = from_cell
		GameState.board_slots[from_index] = null
	elif PrepRules.can_merge_cells(to_cell, from_cell):
		if not _merge_copies_into_cell(to_cell, from_cell, [from_index], [bench_index]):
			_board_hud._selected_board = -1
			_refresh_all()
			return
		_shadow_report_merge()
		GameState.board_slots[from_index] = null
	else:
		if _would_exceed_board_limit(to_cell, from_index):
			show_message(tr("toast_unique_limit"))
			_board_hud._selected_board = -1
			_refresh_all()
			return
		GameState.bench_slots[bench_index] = from_cell
		GameState.board_slots[from_index] = to_cell
	_board_hud._selected_board = -1
	_mark_online_board_changed()
	SaveManager.save_run()
	_refresh_all()

func _move_or_merge_bench_to_board(from_index: int, board_index: int) -> void:
	if GameState.tutorial_mode and TutorialMode.step == TutorialMode.Step.BUY_3:
		_board_hud._selected_bench = -1
		return
	if from_index < 0 or from_index >= GameState.bench_slots.size() or board_index < 0 or board_index >= GameState.board_slots.size():
		_board_hud._selected_bench = -1
		return
	var from_cell = GameState.bench_slots[from_index]
	var to_cell = GameState.board_slots[board_index]
	if from_cell == null:
		_board_hud._selected_bench = -1
		return
	if to_cell == null:
		var from_def: Dictionary = from_cell.get("def", {})
		if bool(from_def.get("unique_on_board", false)) and PrepRules.has_unique_board_unit(str(from_cell.get("id", "")), PrepRules.board_limit_for_def(from_def)):
			show_message(tr("toast_unique_limit"))
			_board_hud._selected_bench = -1
			_refresh_all()
			return
		if GameState.normal_unit_count() >= GameState.normal_unit_cap():
			show_message(tr("toast_board_full") % GameState.normal_unit_cap())
			_board_hud._selected_bench = -1
			_refresh_all()
			return
		GameState.board_slots[board_index] = from_cell
		GameState.bench_slots[from_index] = null
	elif PrepRules.can_merge_cells(to_cell, from_cell):
		if not _merge_copies_into_cell(to_cell, from_cell, [board_index], [from_index]):
			_board_hud._selected_bench = -1
			_refresh_all()
			return
		_shadow_report_merge()
		GameState.bench_slots[from_index] = null
	else:
		# Occupied by a different unit -> swap the two (bench piece goes on the
		# board, the board piece returns to that bench slot).
		var from_def: Dictionary = from_cell.get("def", {})
		if bool(from_def.get("unique_on_board", false)) and PrepRules.has_unique_board_unit(str(from_cell.get("id", "")), PrepRules.board_limit_for_def(from_def), board_index):
			show_message(tr("toast_unique_limit"))
			_board_hud._selected_bench = -1
			_refresh_all()
			return
		GameState.board_slots[board_index] = from_cell
		GameState.bench_slots[from_index] = to_cell
	_board_hud._selected_bench = -1
	_mark_online_board_changed()
	SaveManager.save_run()
	_refresh_all()

func _move_or_merge_bench(from_index: int, to_index: int) -> void:
	if from_index < 0 or from_index >= GameState.bench_slots.size() or to_index < 0 or to_index >= GameState.bench_slots.size():
		_board_hud._selected_bench = -1
		return
	var from_cell = GameState.bench_slots[from_index]
	var to_cell = GameState.bench_slots[to_index]
	if from_cell == null:
		_board_hud._selected_bench = -1
		return
	if to_cell == null:
		GameState.bench_slots[to_index] = from_cell
		GameState.bench_slots[from_index] = null
	elif PrepRules.can_merge_cells(to_cell, from_cell):
		if not _merge_copies_into_cell(to_cell, from_cell, [], [from_index, to_index]):
			_board_hud._selected_bench = -1
			_refresh_all()
			return
		_shadow_report_merge()
		GameState.bench_slots[from_index] = null
	else:
		GameState.bench_slots[to_index] = from_cell
		GameState.bench_slots[from_index] = to_cell
	_board_hud._selected_bench = -1
	SaveManager.save_run()
	_refresh_all()

func _on_sell_selected() -> void:
	if _board_hud._selected_bench >= 0:
		_sell_bench_index(_board_hud._selected_bench)
		return
	if _board_hud._selected_board < 0:
		return
	_sell_board_index(_board_hud._selected_board)

func _sell_board_index(index: int, confirmed: bool = false) -> void:
	if index < 0 or index >= GameState.board_slots.size() or GameState.board_slots[index] == null:
		return
	var cell: Dictionary = GameState.board_slots[index]
	if not confirmed and _needs_four_star_sell_confirm(cell):
		_ask_four_star_sell("board", index, cell)
		return
	var refund := _sell_refund_for_cell(cell)
	var sold_uid := str(cell.get("uid", ""))
	GameState.gold += refund
	GameState.board_slots[index] = null
	_shadow_report("sell", {"uid": sold_uid})
	_board_hud._selected_board = -1
	_mark_online_board_changed()
	SaveManager.save_run()
	_refresh_all()

func _sell_bench_index(index: int, confirmed: bool = false) -> void:
	if index < 0 or index >= GameState.bench_slots.size() or GameState.bench_slots[index] == null:
		return
	var cell: Dictionary = GameState.bench_slots[index]
	if not confirmed and _needs_four_star_sell_confirm(cell):
		_ask_four_star_sell("bench", index, cell)
		return
	var refund := _sell_refund_for_cell(cell)
	var sold_uid := str(cell.get("uid", ""))
	GameState.gold += refund
	GameState.bench_slots[index] = null
	_shadow_report("sell", {"uid": sold_uid})
	_board_hud._selected_bench = -1
	SaveManager.save_run()
	_refresh_all()

# 四星出售前的二次确认（设计文档《萝卜采集与升级石系统设计实施方案》:117）。
#
# 一个四星 = 6 份同名棋子 + 50 萝卜抽到的一颗**队伍共享**升级石。出售不返还石头
# （EconomyLedger.STAR_REFUND_MULTIPLIER 只给金币），而拖拽卖棋是一步到位的：
# 一次误拖就把队友一起攒的石头也扔了。三星及以下不弹，避免打断正常的卖棋节奏。
const FOUR_STAR_SELL_DIALOG := "prep_four_star_sell"
# 读枚举而不是写 1：Intent 的成员顺序一改，硬写的数字会静默指向别的意图。
const ConfirmDialog := preload("res://ui/components/GloryConfirmDialog.gd")

func _needs_four_star_sell_confirm(cell: Variant) -> bool:
	if typeof(cell) != TYPE_DICTIONARY:
		return false
	return int((cell as Dictionary).get("star", 1)) >= GameState.MAX_UNIT_STAR

func _ask_four_star_sell(where: String, index: int, cell: Dictionary) -> void:
	var d: Dictionary = cell.get("def", {})
	var unit_name := str(d.get("name", d.get("id", "棋子")))
	# 对话框解析时棋盘可能已经变了（拖拽、合成、服务端覆盖）。记下 id，回来再核对，
	# 否则确认键会卖掉**换到这一格上的另一枚棋子**。
	var unit_id := str(cell.get("id", ""))
	var refund := _sell_refund_for_cell(cell)
	var english := LocaleManager.get_locale() == "en"
	DialogService.confirm({
		"request_id": FOUR_STAR_SELL_DIALOG,
		"owner": self,
		"intent": ConfirmDialog.Intent.DANGER,   # 不可逆，焦点默认留在取消
		"title": "出售四星棋子" if not english else "Sell a Four-Star Unit",
		"body": ("卖掉「%s」只退 %d 金，**升级石不返还**。这颗石头是队伍共享的。" % [unit_name, refund]
			if not english else
			"Selling \"%s\" refunds only %d gold. The upgrade stone is NOT returned, and it came from the shared team stock." % [unit_name, refund]),
		"confirm_text": "确认出售" if not english else "Sell",
		"cancel_text": "留着" if not english else "Keep",
		"on_result": func(result: String, _rid: String) -> void:
			if result != ConfirmDialog.RESULT_CONFIRMED:
				return
			var slots: Array = GameState.board_slots if where == "board" else GameState.bench_slots
			if index < 0 or index >= slots.size():
				return
			var current: Variant = slots[index]
			if typeof(current) != TYPE_DICTIONARY:
				return
			if str((current as Dictionary).get("id", "")) != unit_id 					or int((current as Dictionary).get("star", 1)) < GameState.MAX_UNIT_STAR:
				return   # 这一格已经不是当初那枚四星了
			if where == "board":
				_sell_board_index(index, true)
			else:
				_sell_bench_index(index, true),
	})

func _first_empty_board_slot() -> int:
	for i in GameState.board_slots.size():
		if GameState.board_slots[i] == null:
			return i
	return -1
# 上一次成功合成参与的 uid，供影子记账把同一笔合成也报给服务端账本
# （EconomyLedger._merge 按 uid 收，keeper 留 target 那一枚）。
var _last_merge_uids: Array = []
var _last_merge_keeper_uid := ""

func _merge_copies_into_cell(target: Dictionary, incoming: Dictionary, excluded_board: Array = [], excluded_bench: Array = []) -> bool:
	if not PrepRules.can_merge_cells(target, incoming):
		return false
	var id := str(target.get("id", ""))
	var star := int(target.get("star", 1))
	# target + incoming already provide 2 copies. 1-star fuses from those 2 alone;
	# 2-star needs one more copy pulled from the board or bench.
	var extra := {}
	if GameState.copies_to_upgrade(star) > 2:
		extra = _take_extra_merge_piece(id, star, excluded_board, excluded_bench)
		if extra.is_empty():
			return false
	_preserve_unique_king_growth_on_merge(target, incoming, extra)
	target.star = star + 1
	_last_merge_keeper_uid = str(target.get("uid", ""))
	_last_merge_uids = [_last_merge_keeper_uid, str(incoming.get("uid", ""))]
	if not extra.is_empty():
		_last_merge_uids.append(str(extra.get("uid", "")))
	return true

func _take_extra_merge_piece(id: String, star: int, excluded_board: Array, excluded_bench: Array) -> Dictionary:
	for i in GameState.board_slots.size():
		if i in excluded_board:
			continue
		var cell = GameState.board_slots[i]
		if PrepRules.is_merge_piece(cell, id, star):
			var taken: Dictionary = cell
			GameState.board_slots[i] = null
			return taken
	for i in GameState.bench_slots.size():
		if i in excluded_bench:
			continue
		var cell = GameState.bench_slots[i]
		if PrepRules.is_merge_piece(cell, id, star):
			var taken: Dictionary = cell
			GameState.bench_slots[i] = null
			return taken
	return {}

# The merged king keeps the strongest def among the pieces consumed. The growth
# counter must travel with that def: carrying the def but keeping the keeper's
# own counter lets a player grow a king to its cap, merge it with fresh copies,
# and resume growing from zero with the grown stats intact — a cap bypass that
# repeats indefinitely.
func _preserve_unique_king_growth_on_merge(target: Dictionary, incoming: Dictionary, extra: Dictionary) -> void:
	var best_def: Dictionary = {}
	var best_score := -1.0
	var best_stacks := 0
	for cell in [target, incoming, extra]:
		if typeof(cell) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = cell.get("def", {})
		if str(d.get("skill_id", "")) != "unique_king_growth":
			continue
		var score := _unique_king_growth_score(d)
		if score > best_score:
			best_score = score
			best_def = d
			best_stacks = int((cell as Dictionary).get("king_growth_stacks", 0))
	if best_def.is_empty():
		return
	target.def = best_def.duplicate(true)
	target.id = str(best_def.get("id", target.get("id", "")))
	target.king_growth_stacks = best_stacks

func _unique_king_growth_score(d: Dictionary) -> float:
	return float(d.get("hp", 0))
# TFT-style auto combine: any 3 copies of the same id+star across the board AND
# the bench fuse into one of the next star, cascading (9 copies -> a 3★). Runs
# after every board/bench change so the standby area levels up too.
func _auto_combine_all() -> void:
	var guard := 0
	while guard < 60 and _auto_combine_pass():
		guard += 1

func _auto_combine_pass() -> bool:
	# 上界是**合成**上限，不是星级上限。写成 MAX_UNIT_STAR 时这个循环会包含 star=3，
	# 而 copies_to_upgrade(3) 落到 STAR_UPGRADE_COPIES.get(star, 3) 的默认值 3 ——
	# 于是三个三星在这里自动融成四星，不看 element、不看队伍仓库、也不走
	# GameState.four_star_check()，整个升级石经济被绕过。而本函数是 _refresh_all()
	# 的第一步，玩家连点都不用点。四星只能靠升级石（GameConstants.gd 顶部有说明）。
	#
	# 这是客户端的**第三份**合成实现（另外两份：PrepRules.can_merge_cells 手动合成、
	# EconomyLedger._merge 服务端）。三份都读同一个常量，但各自遍历、各自写 star，
	# 所以改上限时三处都要看。守它的是 tools/merge_rule_parity_check.gd 的
	# _case_auto_combine_caps_at_merge_star / _case_auto_combine_still_cascades。
	for star in range(1, GameState.MAX_MERGE_STAR):
		var groups: Dictionary = {}   # id -> Array of [location, index]
		_gather_star_pieces(GameState.board_slots, "board", star, groups)
		_gather_star_pieces(GameState.bench_slots, "bench", star, groups)
		for id in groups:
			if (groups[id] as Array).size() >= GameState.copies_to_upgrade(star):
				_combine_copies_auto(star, groups[id])
				return true
	return false

func _gather_star_pieces(slots: Array, location: String, star: int, groups: Dictionary) -> void:
	for i in slots.size():
		var c = slots[i]
		if typeof(c) != TYPE_DICTIONARY:
			continue
		if int(c.get("star", 1)) != star:
			continue
		var id := str(c.get("id", ""))
		if id.is_empty():
			continue
		if not groups.has(id):
			groups[id] = []
		groups[id].append([location, i])

func _combine_copies_auto(star: int, locs: Array) -> void:
	# Consume exactly the copies this star needs to fuse (2 for 1-star, 3 for 2-star).
	var fuse: Array = locs.slice(0, GameState.copies_to_upgrade(star))
	# Keeper: prefer a board cell so the upgraded unit stays on the board.
	var keeper_loc: Array = fuse[0]
	for loc in fuse:
		if str(loc[0]) == "board":
			keeper_loc = loc
			break
	var cells: Array = []
	for loc in fuse:
		var arr: Array = GameState.board_slots if str(loc[0]) == "board" else GameState.bench_slots
		cells.append(arr[int(loc[1])])
	var keeper_arr: Array = GameState.board_slots if str(keeper_loc[0]) == "board" else GameState.bench_slots
	var keeper: Dictionary = keeper_arr[int(keeper_loc[1])]
	_preserve_unique_king_growth_among(keeper, cells)
	keeper.star = star + 1
	for loc in fuse:
		if str(loc[0]) == str(keeper_loc[0]) and int(loc[1]) == int(keeper_loc[1]):
			continue
		var arr: Array = GameState.board_slots if str(loc[0]) == "board" else GameState.bench_slots
		arr[int(loc[1])] = null

# Same rule as _preserve_unique_king_growth_on_merge: the growth counter travels
# with the def that won, or the cap can be reset by merging.
func _preserve_unique_king_growth_among(keeper: Dictionary, cells: Array) -> void:
	var best_def: Dictionary = {}
	var best_score := -1.0
	var best_stacks := 0
	for c in cells:
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = (c as Dictionary).get("def", {})
		if str(d.get("skill_id", "")) != "unique_king_growth":
			continue
		var score := _unique_king_growth_score(d)
		if score > best_score:
			best_score = score
			best_def = d
			best_stacks = int((c as Dictionary).get("king_growth_stacks", 0))
	if best_def.is_empty():
		return
	keeper.def = best_def.duplicate(true)
	keeper.id = str(best_def.get("id", keeper.get("id", "")))
	keeper.king_growth_stacks = best_stacks

# 出售退款 = 棋子自身售价 x 星级 x 0.5。
#
# 这里原本读的是 `cell.def.cost` —— **打折前的定价表原值**，不是玩家看到的售价。
# 小灵的 cost 是 10、shop_cost_multiplier 是 0.5，商店卖 5；
# 而退款算 floor(10 x 1 x 0.5) = 5 —— 那个 x0.5 正好把乘数抵消掉，变成全额退款。
# 带上折扣宝物买入（x0.8 / x0.6）就直接变成净赚，合成 2 星后翻倍。
# 全表只有小灵带这个字段，所以改这一行只有小灵的退款会变（1星 5->2、2星 10->5、
# 3星 15->7），其余 31 个棋子的三个星级一个数字都不动。
#
# 用 EconomyLedger.base_unit_cost() 而不是在这里再抄一遍乘数逻辑 ——
# 「同一套算钱逻辑存两份」正是这个洞的成因。
#
# 注意：这里**不含**玩家身上的折扣宝物，所以退款率会高于名义的 50%
# （最高一组 83%：clearance 下花 12 退 10）。那仍然是亏本卖出、刷不出钱。
# 要让退款严格等于「实付的一半」需要给棋子记 cost_basis，
# 属于 docs/P1经济账本RFC.md 第 4.1 节那个待拍板的数值改动，与本次堵洞分开。
func _sell_refund_for_cell(cell: Dictionary) -> int:
	var def: Dictionary = cell.get("def", {})
	var price := EconomyLedger.base_unit_cost(def)
	# 倍率表也放在 EconomyLedger —— 1~3 星与旧公式 `售价 × 星级 × 0.5` 逐字等价，
	# 4 星不能照那个公式外推（见那边的说明）。
	return EconomyLedger.star_sell_refund(price, int(cell.get("star", 1)))

# --- 影子记账（P1 账本 L2）------------------------------------------------------
# 备战期的金币仍由客户端自己算（authoritative 还没翻），但每一笔都同时报给服务端
# 账本，让它把账记起来。服务端 _shadow_audit_economy 会在棋盘提交时把两边的余额
# 对一遍 —— **影子期零差异是翻 authoritative 开关的唯一依据**
# （见 NetworkService 里那条注释与 docs/P1经济账本RFC.md）。
#
# 拒绝在这里是**正常**的：账本刚上线时 roster 是空的，卖掉一枚开关之前买的棋子
# 必然 unknown_uid。这些都进影子日志，不影响玩家 —— 本地那一笔已经生效了。
func _shadow_report(action: String, payload: Dictionary) -> void:
	if GameState.tutorial_mode:
		return
	if not (NetworkService.team_active and not NetworkService.is_host):
		return
	NetworkService.request_economy(action, payload)


func _shadow_report_buy(shop_index: int, cell: Dictionary) -> void:
	_shadow_report("buy", {
		"shop_index": shop_index,
		"offer_id": GameState.shop_offer_id,
		"uid": str(cell.get("uid", "")),
	})


func _shadow_report_merge() -> void:
	if _last_merge_uids.is_empty():
		return
	_shadow_report("merge", {
		"uids": _last_merge_uids.duplicate(),
		"keeper_uid": _last_merge_keeper_uid,
	})
	_last_merge_uids = []
	_last_merge_keeper_uid = ""


func _on_refresh_shop() -> void:
	var all_free := TreasureService.has_set("money")
	var cost := EconomyService.shop_refresh_cost(GameState.shop_refresh_uses_this_round, all_free)
	if GameState.gold < cost:
		show_message(tr("ui_not_enough_gold"))
		return
	GameState.gold -= cost
	GameState.shop_refresh_uses_this_round += 1
	# 先报账再摇：服务端摇好的新一轮商店随回执/下一份 room_state 回来，
	# _roll_shop() 里的 _adopt_server_shop() 负责采用它。
	_shadow_report("shop_refresh", {})
	_roll_shop()
	_shop.selected = -1
	SaveManager.save_run()
	_refresh_all()

func _roll_shop() -> void:
	if GameState.tutorial_mode:
		TutorialMode.call("_apply_shop", TutorialMode.tutorial_shop_ids())
		return
	# 联机客机：商店由服务端摇（每回合随 room_state 下发）。
	# 以前这里无条件本机另摇一份，两边的 offer_id 对不上，买入意图必然被
	# EconomyLedger._buy 判 stale_offer —— 账本因此永远记不成账。
	if _adopt_server_shop():
		return
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	if units.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in GameState.SHOP_UNIT_SLOTS:
		GameState.shop_offers[i] = ShopRoll.pick_offer(
			units, GameState.round_index, rng.randf(), rng.randf())
		GameState.shop_sold[i] = false

# 采用服务端下发的这一轮商店。成功返回 true。
# 只对「联机且不是房主」生效：单机与本机房主没有服务端账本，仍走本机摇。
func _adopt_server_shop() -> bool:
	if not (NetworkService.team_active and not NetworkService.is_host):
		return false
	var shop: Dictionary = NetworkService.server_shop
	var offers: Variant = shop.get("offers", [])
	var offer_id := str(shop.get("offer_id", ""))
	if offer_id.is_empty() or typeof(offers) != TYPE_ARRAY or (offers as Array).is_empty():
		return false
	var sold: Variant = shop.get("sold", [])
	for i in GameState.SHOP_UNIT_SLOTS:
		GameState.shop_offers[i] = ((offers as Array)[i] as Dictionary).duplicate(true) 			if i < (offers as Array).size() and typeof((offers as Array)[i]) == TYPE_DICTIONARY else {}
		GameState.shop_sold[i] = bool((sold as Array)[i]) 			if typeof(sold) == TYPE_ARRAY and i < (sold as Array).size() else false
	GameState.shop_offer_id = offer_id
	return true


# 档位曲线本体已移到 ShopRoll —— 服务端的 _server_roll_shop_offers() 要用同一份。
# 之前服务端是全表均匀随机，第一回合就能刷出三档单位（设计上应为 0%），
# 而影子比对只对金币，抓不到这个差异。详见 ShopRoll.gd 顶部说明。
func _roll_shop_tier(rng: RandomNumberGenerator) -> int:
	return ShopRoll.tier_for_roll(GameState.round_index, rng.randf())

# 定价改为委托服务端的权威实现 EconomyLedger.unit_cost()。
#
# 抽这一步的起因：这里原本有一份与 EconomyLedger.unit_cost() **逐行相同**的公式
# （基础价 → shop_cost_multiplier → link_clearance_sale ×0.6 / money_discount ×0.8，
#  两者互斥、不叠加，每步都 maxi(1, ceil(...))）。同一套算钱逻辑存两份，
# 改一处忘另一处 = 客户端显示一个价、服务端扣另一个价，而且不会有任何报错。
# 服务端那份是权威裁决方，所以以它为准。
func _shop_unit_cost(unit_def: Dictionary) -> int:
	return EconomyLedger.unit_cost(unit_def, GameState.owned_treasures)


# ─── 详情弹窗（原 PrepDetails.gd，D2 步骤 6′ 并入本层）──────────────────────
#
# PrepDetails 曾经是 769 行的一整层，五个面板抽走之后只剩下这 6 个函数：
# 三个「点某个格子/卡片 -> 弹详情」和三个文案格式化。
# 其余全是转发给 UnitDetailFormat / PrepPowerFormat / PrepPowerEstimate 的薄包装，
# 面板抽走后**没有任何调用点**（连同 PrepShared 里配对的抽象桩共 28 个），已删除。
#
# 一层只剩 6 个函数就不该继续占一层继承 —— 继承链 7 层减到 6 层。

func _set_stats_group(group: String) -> void:
	_stats._stats_group = group
	_stats._refresh_popup()
# ─── unit detail popup ────────────────────────────────────────────────────────

func _show_shop_detail(index: int) -> void:
	if index >= 0 and index < GameState.shop_offers.size():
		_overlay.show_text(UnitDetailFormat.format_unit_def(GameState.shop_offers[index]))

func _show_board_detail(index: int) -> void:
	var cell = GameState.board_slots[index]
	if cell != null:
		_overlay.show_text(UnitDetailFormat.format_unit_def(cell.def, int(cell.star), cell))

func _show_bench_detail(index: int) -> void:
	if index < 0 or index >= GameState.bench_slots.size():
		return
	var cell = GameState.bench_slots[index]
	if cell != null:
		_overlay.show_text(UnitDetailFormat.format_unit_def(cell.def, int(cell.star)))
func _show_linkage_detail(link_id: String) -> void:
	var links: Array = DataRegistry.get_table("treasures").get("linkages", [])
	var link: Dictionary = {}
	for l in links:
		if str((l as Dictionary).get("id", "")) == link_id:
			link = l
			break
	if link.is_empty():
		return
	var names: Array[String] = []
	for req in link.get("requires", []):
		names.append(PrepWidgets.localized_name(TreasureService.treasure_by_id(str(req))))
	var title := str(TREASURE_LINKAGE_LOGOS.get(link_id, link_id))
	var lines: Array[String] = [title]
	if PrepWidgets.is_en():
		lines.append("Treasures: %s" % " + ".join(names))
		lines.append("Effect: %s" % _treasure.link_effect_text(link_id))
	else:
		lines.append("宝藏：%s" % " + ".join(names))
		lines.append("联动效果：%s" % _treasure.link_effect_text(link_id))
	_overlay.show_text("\n".join(lines))
