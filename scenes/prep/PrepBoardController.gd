extends "res://scenes/prep/PrepFlowController.gd"

func _can_drop_on_board(board_index: int, data: Variant) -> bool:
	if board_index < 0 or board_index >= GameState.board_slots.size() or typeof(data) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = data
	match str(d.get("kind", "")):
		"shop":
			if GameState.tutorial_mode:
				return false
			var idx := int(d.get("index", -1))
			return idx >= 0 and idx < GameState.shop_offers.size() and not bool(GameState.shop_sold[idx])
		"board":
			return int(d.get("index", -1)) != board_index
		"bench":
			if GameState.tutorial_mode and TutorialMode.step == TutorialMode.Step.BUY_3:
				return false
			return int(d.get("index", -1)) >= 0
	return false

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

func _can_drop_on_bench(bench_index: int, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = data
	match str(d.get("kind", "")):
		"shop":
			var idx := int(d.get("index", -1))
			return idx >= 0 and idx < GameState.shop_offers.size() and not bool(GameState.shop_sold[idx])
		"board":
			var idx2 := int(d.get("index", -1))
			return idx2 >= 0 and idx2 < GameState.board_slots.size()
		"bench":
			return int(d.get("index", -1)) != bench_index
	return false

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
	_board_drop_highlight_active = str(payload.get("kind", "")) in ["shop", "board", "bench"]
	_board_drop_hover_index = -1
	_standby_drop_highlight_active = str(payload.get("kind", "")) in ["shop", "board", "bench"]
	_standby_drop_hover_index = -1
	_refresh_board()
	_refresh_bench()
	if GameState.tutorial_mode:
		TutorialMode.update_overlay()

func _on_drag_ended() -> void:
	# Released without landing on a cell -> snap into the nearest valid cell.
	if not _drop_consumed and not _active_drag_payload.is_empty():
		_snap_drop_to_nearest(get_global_mouse_position(), _active_drag_payload)
	_active_drag_payload = {}
	_drop_consumed = false
	_set_shop_sell_mode(false)
	_board_drop_highlight_active = false
	_board_drop_hover_index = -1
	_standby_drop_highlight_active = false
	_standby_drop_hover_index = -1
	_refresh_board()
	_refresh_bench()
	if GameState.tutorial_mode:
		TutorialMode.update_overlay()

func _snap_drop_to_nearest(global_pos: Vector2, payload: Dictionary) -> void:
	# Search board + bench cells for the nearest one that accepts this payload.
	var best_dist := INF
	var best_is_board := false
	var best_index := -1
	for i in _board_buttons.size():
		var btn: Control = _board_buttons[i]
		if not is_instance_valid(btn) or not btn.is_visible_in_tree():
			continue
		if not _can_drop_on_board(i, payload):
			continue
		var dist := global_pos.distance_to(btn.get_global_rect().get_center())
		if dist < best_dist:
			best_dist = dist
			best_is_board = true
			best_index = i
	for i in _bench_buttons.size():
		var btn: Control = _bench_buttons[i]
		if not is_instance_valid(btn) or not btn.is_visible_in_tree():
			continue
		if not _can_drop_on_bench(i, payload):
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

func _set_board_drop_hover(board_index: int) -> void:
	var next_index := board_index if _board_drop_highlight_active else -1
	if _board_drop_hover_index == next_index:
		return
	_board_drop_hover_index = next_index
	for index in _board_buttons.size():
		_board_buttons[index].set_deployment_highlight(
			_board_drop_highlight_active,
			index == _board_drop_hover_index
		)

func _set_standby_drop_hover(bench_index: int) -> void:
	var next_index := bench_index if _standby_drop_highlight_active else -1
	if _standby_drop_hover_index == next_index:
		return
	_standby_drop_hover_index = next_index
	for index in _bench_buttons.size():
		_bench_buttons[index].set_standby_highlight(
			_standby_drop_highlight_active,
			index == _standby_drop_hover_index
		)

func _set_shop_sell_mode(enabled: bool) -> void:
	_shop_drag_sell_mode = enabled
	if _shop_row != null:
		_shop_row.visible = not enabled
	if _shop_sell_overlay != null:
		_shop_sell_overlay.visible = enabled

func _on_hire_mercenary(index: int) -> void:
	if not _can_hire_mercenary(index):
		return
	var empty := _first_empty_mercenary_slot()
	if empty < 0:
		return
	_hire_mercenary_to_slot(index, empty)
	if GameState.tutorial_mode:
		TutorialMode.sync()

func _can_hire_mercenary(index: int) -> bool:
	var mercs: Array = DataRegistry.get_table("mercenaries").get("mercenaries", [])
	if index < 0 or index >= mercs.size():
		return false
	if _first_empty_mercenary_slot() < 0:
		return false
	return GameState.gold >= int((mercs[index] as Dictionary).get("cost", 0))

func _hire_mercenary_to_slot(index: int, mercenary_index: int) -> void:
	var mercs: Array = DataRegistry.get_table("mercenaries").get("mercenaries", [])
	if index < 0 or index >= mercs.size():
		return
	if mercenary_index < 0 or mercenary_index >= GameState.mercenary_slots.size():
		return
	if GameState.mercenary_slots[mercenary_index] != null:
		return
	if not _can_hire_mercenary(index):
		return
	var m: Dictionary = mercs[index]
	var cost := int(m.get("cost", 0))
	if GameState.gold < cost:
		return
	GameState.gold -= cost
	var def := m.duplicate(true)
	def["is_mercenary"] = true
	GameState.mercenary_slots[mercenary_index] = {"id": def.id, "star": 1, "def": def, "is_mercenary": true, "merc_cost": cost}
	_mark_online_board_changed()
	SaveManager.save_run()
	_refresh_all()

func _on_shop_pressed(index: int) -> void:
	if index < 0 or index >= GameState.shop_offers.size() or bool(GameState.shop_sold[index]):
		return
	_selected_shop = index
	_selected_board = -1
	_selected_bench = -1
	_refresh_all()

func _on_buy_selected_shop() -> void:
	if _selected_shop < 0:
		return
	var empty_bench := _first_empty_bench_slot()
	if empty_bench < 0:
		return
	_buy_or_merge_shop_to_bench(_selected_shop, empty_bench)

func _on_board_pressed(index: int) -> void:
	if _selected_shop >= 0:
		_buy_or_merge_shop_to_board(_selected_shop, index)
		return
	if _selected_bench >= 0:
		_move_or_merge_bench_to_board(_selected_bench, index)
		return
	if _selected_board >= 0 and _selected_board != index:
		_move_or_merge_board(_selected_board, index)
		return
	if GameState.board_slots[index] != null:
		_selected_board = index
		_selected_bench = -1
	else:
		_selected_board = -1
	_refresh_all()

func _on_bench_pressed(index: int) -> void:
	if _selected_shop >= 0:
		_buy_or_merge_shop_to_bench(_selected_shop, index)
		return
	if _selected_board >= 0:
		_move_or_merge_board_to_bench(_selected_board, index)
		return
	if _selected_bench >= 0 and _selected_bench != index:
		_move_or_merge_bench(_selected_bench, index)
		return
	if GameState.bench_slots[index] != null:
		_selected_bench = index
		_selected_board = -1
	else:
		_selected_bench = -1
	_refresh_all()

func _buy_or_merge_shop_to_board(shop_index: int, board_index: int) -> void:
	if GameState.tutorial_mode:
		_selected_shop = -1
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
		if bool(offer.get("unique_on_board", false)) and _has_unique_board_unit(str(offer.get("id", "")), _board_limit_for_def(offer)):
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
	elif _can_merge_cells(target, incoming):
		if GameState.gold < cost:
			return
		if not _merge_three_into_cell(target, incoming, [board_index], []):
			return
		GameState.gold -= cost
		GameState.shop_sold[shop_index] = true
	else:
		return
	_selected_shop = -1
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
	elif _can_merge_cells(target, incoming):
		if GameState.gold < cost:
			return
		if not _merge_three_into_cell(target, incoming, [], [bench_index]):
			return
		GameState.gold -= cost
		GameState.shop_sold[shop_index] = true
	else:
		return
	_selected_shop = -1
	if GameState.tutorial_mode:
		TutorialMode.record_shop_purchase()
	SaveManager.save_run()
	_refresh_all()

func _has_unique_board_unit(unit_id: String, limit: int = 1, ignore_index: int = -1) -> bool:
	if unit_id.is_empty():
		return false
	var count := 0
	for i in GameState.board_slots.size():
		if i == ignore_index:
			continue
		var cell = GameState.board_slots[i]
		if cell != null and str(cell.get("id", "")) == unit_id:
			count += 1
	return count >= maxi(1, limit)

func _board_limit_for_def(d: Dictionary) -> int:
	return maxi(1, int(d.get("board_limit", 1)))

func _would_exceed_board_limit(cell: Dictionary, ignore_index: int = -1) -> bool:
	var d: Dictionary = cell.get("def", {})
	return bool(d.get("unique_on_board", false)) and _has_unique_board_unit(str(cell.get("id", "")), _board_limit_for_def(d), ignore_index)

func _move_or_merge_board(from_index: int, to_index: int) -> void:
	if from_index < 0 or from_index >= GameState.board_slots.size() or to_index < 0 or to_index >= GameState.board_slots.size():
		_selected_board = -1
		return
	var from_cell = GameState.board_slots[from_index]
	var to_cell = GameState.board_slots[to_index]
	if from_cell == null:
		_selected_board = -1
		return
	if to_cell == null:
		GameState.board_slots[to_index] = from_cell
		GameState.board_slots[from_index] = null
	elif _can_merge_cells(to_cell, from_cell):
		if not _merge_three_into_cell(to_cell, from_cell, [from_index, to_index], []):
			_selected_board = -1
			_refresh_all()
			return
		GameState.board_slots[from_index] = null
	else:
		GameState.board_slots[to_index] = from_cell
		GameState.board_slots[from_index] = to_cell
	_selected_board = -1
	_mark_online_board_changed()
	SaveManager.save_run()
	_refresh_all()

func _move_or_merge_board_to_bench(from_index: int, bench_index: int) -> void:
	if from_index < 0 or from_index >= GameState.board_slots.size() or bench_index < 0 or bench_index >= GameState.bench_slots.size():
		_selected_board = -1
		return
	var from_cell = GameState.board_slots[from_index]
	var to_cell = GameState.bench_slots[bench_index]
	if from_cell == null:
		_selected_board = -1
		return
	if bool(from_cell.get("is_mercenary", false)):
		_selected_board = -1
		return
	if to_cell == null:
		GameState.bench_slots[bench_index] = from_cell
		GameState.board_slots[from_index] = null
	elif _can_merge_cells(to_cell, from_cell):
		if not _merge_three_into_cell(to_cell, from_cell, [from_index], [bench_index]):
			_selected_board = -1
			_refresh_all()
			return
		GameState.board_slots[from_index] = null
	else:
		if _would_exceed_board_limit(to_cell, from_index):
			show_message(tr("toast_unique_limit"))
			_selected_board = -1
			_refresh_all()
			return
		GameState.bench_slots[bench_index] = from_cell
		GameState.board_slots[from_index] = to_cell
	_selected_board = -1
	_mark_online_board_changed()
	SaveManager.save_run()
	_refresh_all()

func _move_or_merge_bench_to_board(from_index: int, board_index: int) -> void:
	if GameState.tutorial_mode and TutorialMode.step == TutorialMode.Step.BUY_3:
		_selected_bench = -1
		return
	if from_index < 0 or from_index >= GameState.bench_slots.size() or board_index < 0 or board_index >= GameState.board_slots.size():
		_selected_bench = -1
		return
	var from_cell = GameState.bench_slots[from_index]
	var to_cell = GameState.board_slots[board_index]
	if from_cell == null:
		_selected_bench = -1
		return
	if to_cell == null:
		var from_def: Dictionary = from_cell.get("def", {})
		if bool(from_def.get("unique_on_board", false)) and _has_unique_board_unit(str(from_cell.get("id", "")), _board_limit_for_def(from_def)):
			show_message(tr("toast_unique_limit"))
			_selected_bench = -1
			_refresh_all()
			return
		if GameState.normal_unit_count() >= GameState.normal_unit_cap():
			show_message(tr("toast_board_full") % GameState.normal_unit_cap())
			_selected_bench = -1
			_refresh_all()
			return
		GameState.board_slots[board_index] = from_cell
		GameState.bench_slots[from_index] = null
	elif _can_merge_cells(to_cell, from_cell):
		if not _merge_three_into_cell(to_cell, from_cell, [board_index], [from_index]):
			_selected_bench = -1
			_refresh_all()
			return
		GameState.bench_slots[from_index] = null
	else:
		# Occupied by a different unit -> swap the two (bench piece goes on the
		# board, the board piece returns to that bench slot).
		var from_def: Dictionary = from_cell.get("def", {})
		if bool(from_def.get("unique_on_board", false)) and _has_unique_board_unit(str(from_cell.get("id", "")), _board_limit_for_def(from_def), board_index):
			show_message(tr("toast_unique_limit"))
			_selected_bench = -1
			_refresh_all()
			return
		GameState.board_slots[board_index] = from_cell
		GameState.bench_slots[from_index] = to_cell
	_selected_bench = -1
	_mark_online_board_changed()
	SaveManager.save_run()
	_refresh_all()

func _move_or_merge_bench(from_index: int, to_index: int) -> void:
	if from_index < 0 or from_index >= GameState.bench_slots.size() or to_index < 0 or to_index >= GameState.bench_slots.size():
		_selected_bench = -1
		return
	var from_cell = GameState.bench_slots[from_index]
	var to_cell = GameState.bench_slots[to_index]
	if from_cell == null:
		_selected_bench = -1
		return
	if to_cell == null:
		GameState.bench_slots[to_index] = from_cell
		GameState.bench_slots[from_index] = null
	elif _can_merge_cells(to_cell, from_cell):
		if not _merge_three_into_cell(to_cell, from_cell, [], [from_index, to_index]):
			_selected_bench = -1
			_refresh_all()
			return
		GameState.bench_slots[from_index] = null
	else:
		GameState.bench_slots[to_index] = from_cell
		GameState.bench_slots[from_index] = to_cell
	_selected_bench = -1
	SaveManager.save_run()
	_refresh_all()

func _on_sell_selected() -> void:
	if _selected_bench >= 0:
		_sell_bench_index(_selected_bench)
		return
	if _selected_board < 0:
		return
	_sell_board_index(_selected_board)

func _sell_board_index(index: int) -> void:
	if index < 0 or index >= GameState.board_slots.size() or GameState.board_slots[index] == null:
		return
	var cell: Dictionary = GameState.board_slots[index]
	var refund := _sell_refund_for_cell(cell)
	GameState.gold += refund
	GameState.board_slots[index] = null
	_selected_board = -1
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
	_selected_bench = -1
	SaveManager.save_run()
	_refresh_all()

func _first_empty_board_slot() -> int:
	for i in GameState.board_slots.size():
		if GameState.board_slots[i] == null:
			return i
	return -1

func _first_empty_bench_slot() -> int:
	for i in GameState.bench_slots.size():
		if GameState.bench_slots[i] == null:
			return i
	return -1

func _first_empty_mercenary_slot() -> int:
	for i in GameState.mercenary_slots.size():
		if GameState.mercenary_slots[i] == null:
			return i
	return -1

func _bench_count() -> int:
	var count := 0
	for cell in GameState.bench_slots:
		if cell != null:
			count += 1
	return count

func _can_merge_cells(target: Dictionary, incoming: Dictionary) -> bool:
	if target.is_empty() or incoming.is_empty():
		return false
	if bool(target.get("is_mercenary", false)) or bool(incoming.get("is_mercenary", false)):
		return false
	return str(target.get("id", "")) == str(incoming.get("id", "")) and int(target.get("star", 1)) == int(incoming.get("star", 1)) and int(target.get("star", 1)) < GameState.MAX_UNIT_STAR

func _merge_three_into_cell(target: Dictionary, incoming: Dictionary, excluded_board: Array = [], excluded_bench: Array = []) -> bool:
	if not _can_merge_cells(target, incoming):
		return false
	var id := str(target.get("id", ""))
	var star := int(target.get("star", 1))
	var extra := _take_extra_merge_piece(id, star, excluded_board, excluded_bench)
	if extra.is_empty():
		return false
	_preserve_unique_king_growth_on_merge(target, incoming, extra)
	target.star = int(target.get("star", 1)) + 1
	return true

func _take_extra_merge_piece(id: String, star: int, excluded_board: Array, excluded_bench: Array) -> Dictionary:
	for i in GameState.board_slots.size():
		if i in excluded_board:
			continue
		var cell = GameState.board_slots[i]
		if _is_merge_piece(cell, id, star):
			var taken: Dictionary = cell
			GameState.board_slots[i] = null
			return taken
	for i in GameState.bench_slots.size():
		if i in excluded_bench:
			continue
		var cell = GameState.bench_slots[i]
		if _is_merge_piece(cell, id, star):
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

func _is_merge_piece(cell: Variant, id: String, star: int) -> bool:
	if typeof(cell) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = cell
	if bool(d.get("is_mercenary", false)):
		return false
	return str(d.get("id", "")) == id and int(d.get("star", 1)) == star

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
			if (groups[id] as Array).size() >= 3:
				_combine_three_auto(star, groups[id])
				return true
	return false

func _gather_star_pieces(slots: Array, location: String, star: int, groups: Dictionary) -> void:
	for i in slots.size():
		var c = slots[i]
		if typeof(c) != TYPE_DICTIONARY or bool(c.get("is_mercenary", false)):
			continue
		if int(c.get("star", 1)) != star:
			continue
		var id := str(c.get("id", ""))
		if id.is_empty():
			continue
		if not groups.has(id):
			groups[id] = []
		groups[id].append([location, i])

func _combine_three_auto(star: int, locs: Array) -> void:
	var trio: Array = locs.slice(0, 3)
	# Keeper: prefer a board cell so the upgraded unit stays on the board.
	var keeper_loc: Array = trio[0]
	for loc in trio:
		if str(loc[0]) == "board":
			keeper_loc = loc
			break
	var cells: Array = []
	for loc in trio:
		var arr: Array = GameState.board_slots if str(loc[0]) == "board" else GameState.bench_slots
		cells.append(arr[int(loc[1])])
	var keeper_arr: Array = GameState.board_slots if str(keeper_loc[0]) == "board" else GameState.bench_slots
	var keeper: Dictionary = keeper_arr[int(keeper_loc[1])]
	_preserve_unique_king_growth_among(keeper, cells)
	keeper.star = star + 1
	for loc in trio:
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

func _sell_refund_for_cell(cell: Dictionary) -> int:
	if bool(cell.get("is_mercenary", false)):
		return int(cell.get("merc_cost", 0))
	return int(floor(float(int(cell.def.get("cost", 1)) * int(cell.get("star", 1))) * 0.5))

func _on_refresh_shop() -> void:
	var all_free := TreasureService.has_set("money")
	var cost := EconomyService.shop_refresh_cost(GameState.shop_refresh_uses_this_round, all_free)
	if GameState.gold < cost:
		return
	GameState.gold -= cost
	GameState.shop_refresh_uses_this_round += 1
	_roll_shop()
	_selected_shop = -1
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
		var tier := _roll_shop_tier(rng)
		var pool := units.filter(func(u): return int(u.get("tier", 1)) == tier)
		if pool.is_empty():
			pool = units
		GameState.shop_offers[i] = pool[rng.randi_range(0, pool.size() - 1)].duplicate(true)
		GameState.shop_sold[i] = false

func _roll_shop_tier(rng: RandomNumberGenerator) -> int:
	if GameState.round_index >= 15:
		var late_roll := rng.randf()
		if late_roll < 0.15:
			return 1
		if late_roll < 0.75:
			return 2
		return 3
	if GameState.round_index >= 10:
		var roll := rng.randf()
		if roll < 0.25:
			return 1
		if roll < 0.85:
			return 2
		return 3
	if GameState.round_index >= 5:
		return 1 if rng.randf() < 0.50 else 2
	return 1 if rng.randf() < 0.80 else 2

func _shop_unit_cost(unit_def: Dictionary) -> int:
	var cost := int(unit_def.get("cost", 1))
	if unit_def.has("shop_cost_multiplier"):
		cost = maxi(1, int(ceil(float(cost) * float(unit_def.shop_cost_multiplier))))
	if TreasureService.has_linkage("link_clearance_sale"):
		cost = maxi(1, int(ceil(float(cost) * 0.6)))
	elif GameState.owned_treasures.has("money_discount"):
		cost = maxi(1, int(ceil(float(cost) * 0.8)))
	return cost
