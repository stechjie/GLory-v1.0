extends "res://scenes/prep/PrepFlowController.gd"

# 商店档位曲线与服务端共用一份，见 scripts/economy/ShopRoll.gd。
# 用 preload 而非 class_name：新增的全局类要等编辑器重扫才进类缓存，
# 而服务端包是直接打包仓库里的缓存文件的（make_server_zip.ps1）。
const ShopRoll := preload("res://scripts/economy/ShopRoll.gd")
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
	var cost := int(m.get("cost", 0))
	if GameState.gold < cost:
		return
	GameState.gold -= cost
	var def := m.duplicate(true)
	def["is_mercenary"] = true
	GameState.mercenary_slots[mercenary_index] = {"id": def.id, "star": 1, "def": def, "is_mercenary": true}
	_mark_online_board_changed()
	NetworkService.team_send_prep_mercs()
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
	var incoming := {"id": offer.id, "star": 1, "def": offer.duplicate(true)}
	if target == null:
		if bool(offer.get("unique_on_board", false)) and PrepRules.has_unique_board_unit(str(offer.get("id", "")), PrepRules.board_limit_for_def(offer)):
			show_message(tr("toast_unique_limit"))
			return
		if GameState.normal_unit_count() >= GameState.normal_unit_cap():
			show_message(tr("toast_board_full") % GameState.normal_unit_cap())
			return
		if GameState.gold < cost:
			return
		GameState.gold -= cost
		GameState.board_slots[board_index] = incoming
		GameState.shop_sold[shop_index] = true
	elif PrepRules.can_merge_cells(target, incoming):
		if GameState.gold < cost:
			return
		if not _merge_copies_into_cell(target, incoming, [board_index], []):
			return
		GameState.gold -= cost
		GameState.shop_sold[shop_index] = true
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
	var incoming := {"id": offer.id, "star": 1, "def": offer.duplicate(true)}
	if target == null:
		if GameState.gold < cost:
			return
		GameState.gold -= cost
		GameState.bench_slots[bench_index] = incoming
		GameState.shop_sold[shop_index] = true
	elif PrepRules.can_merge_cells(target, incoming):
		if GameState.gold < cost:
			return
		if not _merge_copies_into_cell(target, incoming, [], [bench_index]):
			return
		GameState.gold -= cost
		GameState.shop_sold[shop_index] = true
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

func _sell_board_index(index: int) -> void:
	if index < 0 or index >= GameState.board_slots.size() or GameState.board_slots[index] == null:
		return
	var cell: Dictionary = GameState.board_slots[index]
	var refund := _sell_refund_for_cell(cell)
	GameState.gold += refund
	GameState.board_slots[index] = null
	_board_hud._selected_board = -1
	_mark_online_board_changed()
	SaveManager.save_run()
	_refresh_all()

func _sell_bench_index(index: int) -> void:
	if index < 0 or index >= GameState.bench_slots.size() or GameState.bench_slots[index] == null:
		return
	var cell: Dictionary = GameState.bench_slots[index]
	var refund := _sell_refund_for_cell(cell)
	GameState.gold += refund
	GameState.bench_slots[index] = null
	_board_hud._selected_bench = -1
	SaveManager.save_run()
	_refresh_all()

func _first_empty_board_slot() -> int:
	for i in GameState.board_slots.size():
		if GameState.board_slots[i] == null:
			return i
	return -1
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

func _preserve_unique_king_growth_on_merge(target: Dictionary, incoming: Dictionary, extra: Dictionary) -> void:
	var best_def: Dictionary = {}
	var best_score := -1.0
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
	if best_def.is_empty():
		return
	target.def = best_def.duplicate(true)
	target.id = str(best_def.get("id", target.get("id", "")))

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
	for star in range(1, GameState.MAX_UNIT_STAR):
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

func _preserve_unique_king_growth_among(keeper: Dictionary, cells: Array) -> void:
	var best_def: Dictionary = {}
	var best_score := -1.0
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
	if best_def.is_empty():
		return
	keeper.def = best_def.duplicate(true)
	keeper.id = str(best_def.get("id", keeper.get("id", "")))

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
	return int(floor(float(price * int(cell.get("star", 1))) * 0.5))

func _on_refresh_shop() -> void:
	var all_free := TreasureService.has_set("money")
	var cost := EconomyService.shop_refresh_cost(GameState.shop_refresh_uses_this_round, all_free)
	if GameState.gold < cost:
		return
	GameState.gold -= cost
	GameState.shop_refresh_uses_this_round += 1
	_roll_shop()
	_shop.selected = -1
	SaveManager.save_run()
	_refresh_all()

func _roll_shop() -> void:
	if GameState.tutorial_mode:
		TutorialMode.call("_apply_shop", TutorialMode.tutorial_shop_ids())
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

func _format_treasure_detail(t: Dictionary) -> String:
	var tid := str(t.get("id", ""))
	var category := str(t.get("category", ""))
	var tname := PrepWidgets.localized_name(t)
	var lines: Array[String] = []
	lines.append(tname)
	if PrepWidgets.is_en():
		lines.append("Effect: %s" % _treasure.effect_text(tid))
	else:
		lines.append("效果：%s" % _treasure.effect_text(tid))
	var set_status := _treasure.set_status(category)
	if not set_status.is_empty():
		lines.append(set_status)
	var link_lines := _treasure.linkage_status(tid)
	for line in link_lines:
		lines.append(line)
	return "\n".join(lines)
