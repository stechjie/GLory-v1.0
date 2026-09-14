extends Node

# 出战种族（scripts/units/RacePick.gd，协议 28）：规则、本机摇商店、战斗服务器三处摇商店、备战界面。
#
# 🔴 为什么要往棋子表里塞假种族：今天只有四族、必须选四个 = 全选，过滤等于没过滤。
# 只用真实数据测，「忘了过滤」「过滤了但服务器没用上」照样全绿。
# 所以除了钉住真实数据的形状，其余用例先在**内存里**给棋子表加一个假的第五族（zz_fake），
# 选「暗、灵、人、假」—— 神族一个都不许出现，假族必须出现。用完还原，不写任何文件。
#
# 界面用例只点选、不按保存（保存会写 user://profile.json）。
# 恶意载荷、换座 / 离座在 adversarial_client，重启后还在不在在 persist_check（那两处有真服务器）。
#
# 运行：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/race_pick_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const RacePick := preload("res://scripts/units/RacePick.gd")
const ShopRoll := preload("res://scripts/economy/ShopRoll.gd")
const PrepScreenScript := preload("res://scenes/prep/PrepScreen.gd")
const PetScreenScript := preload("res://scenes/menu/PetScreen.gd")

const CHECK_NAME := "race_pick"
const FAKE_PREFIX := "zz_"
const FAKE_RACE := "zz_fake"
# 真实数据的独立副本：故意不从 RacePick 读，否则规则改了检查跟着改，等于没测。
const REAL_RACES := ["god", "dark", "undead", "human"]
const PICK_WITH_FAKE := ["dark", "undead", "human", "zz_fake"]
const EXCLUDED := "god"
const ROOMS := 60

var _h: CheckHarness
var _saved_flag_values: Dictionary = {}
var _saved_flag_loaded := false


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()

	_case_real_data_shape()
	_case_sanitize_rejects()
	_case_sanitize_orders()
	_case_oversized_rejected_fast()

	_inject_fake_race(FAKE_RACE, [1, 2, 3])
	_case_choice_with_fake_race()
	_case_shop_pool_filters()
	await _case_client_roll_respects_run_races()
	_use_ledger_flags()
	_case_server_start_uses_seat_races()
	_case_server_next_prep_uses_seat_races()
	_case_server_refresh_uses_seat_races()
	_case_server_seat_without_races_defaults()
	_case_server_accepts_four_of_five()
	_restore_flags()
	await _case_pet_screen_race_tab()
	_remove_fake_races()

	_case_fallback_stays_in_picked_races()
	await _case_pet_screen_forced_and_starter()

	_h.finish(get_tree())


# --- 小工具 -------------------------------------------------------------------

func _units() -> Array:
	return DataRegistry.get_table("race_units").get("units", [])


func _inject_fake_race(race: String, tiers: Array) -> void:
	var units := _units()
	var template: Dictionary = (units[0] as Dictionary).duplicate(true)
	for tier in tiers:
		var row: Dictionary = template.duplicate(true)
		row["id"] = "%s_t%d" % [race, int(tier)]
		row["race"] = race
		row["tier"] = int(tier)
		row["name"] = "%s%d" % [race, int(tier)]
		row["name_en"] = row["name"]
		units.append(row)


func _remove_fake_races() -> void:
	var units := _units()
	for i in range(units.size() - 1, -1, -1):
		if str((units[i] as Dictionary).get("race", "")).begins_with(FAKE_PREFIX):
			units.remove_at(i)


func _use_ledger_flags() -> void:
	_saved_flag_values = ServerFlags._values.duplicate(true)
	_saved_flag_loaded = ServerFlags._loaded
	ServerFlags._values = {"economy_ledger_enabled": true}
	ServerFlags._loaded = true


func _restore_flags() -> void:
	ServerFlags._values = _saved_flag_values
	ServerFlags._loaded = _saved_flag_loaded


func _tally_offers(seen: Dictionary, offers: Array) -> void:
	for offer in offers:
		if typeof(offer) != TYPE_DICTIONARY:
			continue
		var race := str((offer as Dictionary).get("race", ""))
		seen[race] = int(seen.get(race, 0)) + 1


func _seat_offers(room: Dictionary, slot: int) -> Array:
	var prep: Dictionary = NetworkService._room_prep(room, slot)
	return (prep.get("shop", {}) as Dictionary).get("offers", []) as Array


func _expect_only_picked(seen: Dictionary, where: String) -> void:
	var total := 0
	for key in seen:
		total += int(seen[key])
	if not _h.expect(total > 0, where + "_no_offers", "%s：一个商品都没摇出来" % where):
		return
	_h.expect(int(seen.get(EXCLUDED, 0)) == 0, where + "_leaks_unpicked",
		"%s：选的是 %s，%d 个商品里却有 %d 个神族 —— 这条路径没按出战种族过滤" % [
			where, str(PICK_WITH_FAKE), total, int(seen.get(EXCLUDED, 0))])
	_h.expect(int(seen.get(FAKE_RACE, 0)) > 0, where + "_ignores_pick",
		"%s：选了假种族，%d 个商品里一个都没有 —— 摇商店用的多半是默认四族，不是这一份选择" % [
			where, total])


# --- 规则 ---------------------------------------------------------------------

func _case_real_data_shape() -> void:
	var races := RacePick.all_races()
	_h.expect(str(races) == str(REAL_RACES), "real_races_changed",
		"棋子表里的种族是 %s，期望 %s。加 / 删种族时更新这里，并一起改 SynergyService 等写死四族的地方" % [
			str(races), str(REAL_RACES)])
	_h.expect(RacePick.PICK_COUNT == 4, "pick_count_changed",
		"PICK_COUNT 是 %d，设计是正好 4 个" % RacePick.PICK_COUNT)
	_h.expect(RacePick.required_count() == 4, "required_count_wrong",
		"四族时应当要选 4 个，实际 %d" % RacePick.required_count())
	_h.expect(RacePick.is_forced(), "four_of_four_not_forced",
		"四族选四个没有选择余地，界面应当整页锁定")
	_h.expect(str(RacePick.default_races()) == str(REAL_RACES), "default_wrong",
		"默认出战种族是 %s，期望表里前四族 %s" % [str(RacePick.default_races()), str(REAL_RACES)])
	for race in REAL_RACES:
		_h.expect(RacePick.unit_count(race) > 0, "race_without_units", "%s 族一个棋子都没有" % race)


func _case_sanitize_rejects() -> void:
	var bad := {
		"not_array": "god,dark,undead,human",
		"dictionary": {"god": true, "dark": true, "undead": true, "human": true},
		"null": null,
		"too_few": ["god", "dark", "undead"],
		"too_many": ["god", "dark", "undead", "human", "god"],
		"duplicate": ["god", "god", "undead", "human"],
		"unknown": ["god", "dark", "undead", "elf"],
		"non_string": ["god", "dark", "undead", 7],
		"empty_string": ["god", "dark", "undead", ""],
		"empty": [],
	}
	for key in bad:
		_h.expect(RacePick.sanitize(bad[key]).is_empty(), "sanitize_accepted_bad",
			"%s 这份不合法的选择被收下了：%s" % [str(key), str(bad[key])])
	_h.expect(str(RacePick.resolve(["god"])) == str(REAL_RACES), "resolve_bad_not_default",
		"不合法的选择没有回落到默认，实际 %s" % str(RacePick.resolve(["god"])))


func _case_sanitize_orders() -> void:
	var shuffled := ["human", "god", "undead", "dark"]
	_h.expect(str(RacePick.sanitize(shuffled)) == str(REAL_RACES), "sanitize_not_ordered",
		"乱序的合法选择没有按棋子表顺序整理：%s" % str(RacePick.sanitize(shuffled)))
	var names := [&"god", &"dark", &"undead", &"human"]
	_h.expect(str(RacePick.sanitize(names)) == str(REAL_RACES), "sanitize_rejects_string_name",
		"StringName 写的合法选择被拒了")


func _case_oversized_rejected_fast() -> void:
	var huge: Array = []
	huge.resize(200000)
	huge.fill("god")
	var t0 := Time.get_ticks_usec()
	var out := RacePick.sanitize(huge)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	_h.expect(out.is_empty(), "oversized_accepted", "20 万个元素的种族数组被收下了")
	_h.expect(ms < 5.0, "oversized_slow",
		"20 万个元素的种族数组用了 %.2f ms 才拒掉 —— 要先判大小再遍历（NetProtocol 顶部那条）" % ms)


func _case_choice_with_fake_race() -> void:
	var races := RacePick.all_races()
	_h.expect(races.size() == 5 and races.has(FAKE_RACE), "fake_race_not_seen",
		"注入假种族后 all_races() 是 %s —— 种族列表没有从棋子表里读" % str(races))
	_h.expect(not RacePick.is_forced(), "five_races_still_forced", "五族选四个应当可以选")
	_h.expect(RacePick.required_count() == 4, "required_count_not_capped",
		"五族时应当仍然只选 4 个，实际 %d" % RacePick.required_count())
	_h.expect(str(RacePick.sanitize(PICK_WITH_FAKE)) == str(PICK_WITH_FAKE), "four_of_five_rejected",
		"五族里选四个被拒了：%s" % str(PICK_WITH_FAKE))
	_h.expect(RacePick.sanitize(["god", "dark", "undead", "human", FAKE_RACE]).is_empty(),
		"five_of_five_accepted", "五族全选被收下了 —— 卡池比规定的深")
	_h.expect(str(RacePick.default_races()) == str(REAL_RACES), "default_not_first_four",
		"五族时默认应当是表里前四族，实际 %s" % str(RacePick.default_races()))


func _case_shop_pool_filters() -> void:
	var seen := {}
	_tally_offers(seen, RacePick.shop_pool(_units(), PICK_WITH_FAKE))
	_expect_only_picked(seen, "shop_pool")
	_h.expect(seen.size() == 4, "shop_pool_race_count",
		"选四族，池子里却有 %d 族：%s" % [seen.size(), str(seen.keys())])


# ShopRoll.pick_offer 在「这一档没有棋子」时退回传进去的那张表。所选四族一个三档都没有时，
# 回落也只能落在这四族里 —— 先过滤再交给它才成立（RacePick.shop_pool 的注释）。
func _case_fallback_stays_in_picked_races() -> void:
	var picks: Array = []
	for race in ["zz_a", "zz_b", "zz_c", "zz_d"]:
		_inject_fake_race(race, [1])
		picks.append(race)
	var pool := RacePick.shop_pool(_units(), picks)
	var leaked := 0
	for j in 20:
		# 第 21 回合、tier_roll=0.99 -> 要三档
		var offer := ShopRoll.pick_offer(pool, 21, 0.99, float(j) / 20.0)
		if not str(offer.get("race", "")).begins_with(FAKE_PREFIX):
			leaked += 1
	_h.expect(leaked == 0, "fallback_leaks_unpicked",
		"所选种族没有三档时，20 次回落里有 %d 次刷出了没选的族" % leaked)
	_remove_fake_races()


# --- 本机摇商店（离线局 / 本机房主）--------------------------------------------

func _case_client_roll_respects_run_races() -> void:
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "PrepScreen.tscn 无法加载"):
		return
	var prep := packed.instantiate() as PrepScreenScript
	if not _h.expect(prep != null, "prep_screen_cast_failed", "PrepScreen 没能实例化成备战脚本"):
		return
	add_child(prep)
	await get_tree().process_frame
	await get_tree().process_frame
	var saved_round := GameState.round_index
	GameState.round_index = 21
	GameState.run_races.assign(PICK_WITH_FAKE)
	var seen := {}
	for _i in 300:
		prep._roll_shop()
		_tally_offers(seen, GameState.shop_offers)
	_expect_only_picked(seen, "client_roll")
	GameState.run_races.clear()
	GameState.round_index = saved_round
	prep.queue_free()
	await get_tree().process_frame


# --- 战斗服务器：三处摇商店都要按座位的出战种族 --------------------------------

func _new_lobby_room(with_races: bool) -> Dictionary:
	var room: Dictionary = NetworkService._new_room()
	room.slot_states = ["player", "empty", "empty", "dummy", "empty", "empty"]
	room.ready = [true, false, false, true, false, false]
	if with_races:
		(room.seat_races as Dictionary)[0] = PICK_WITH_FAKE.duplicate()
	return room


# 开局第一份商店（_room_start_authoritative）。
func _case_server_start_uses_seat_races() -> void:
	var ns := NetworkService
	var seen := {}
	for _i in ROOMS:
		var room := _new_lobby_room(true)
		ns._room_start_authoritative(room)
		var started := str(room.get("state", "")) == ns.ROOM_PREP
		if started:
			_tally_offers(seen, _seat_offers(room, 0))
		ns._rooms.erase(int(room.id))
		if not _h.expect(started, "start_did_not_run",
				"_room_start_authoritative 没有把房间推进备战（state=%s）" % str(room.get("state", ""))):
			return
	_expect_only_picked(seen, "server_start")


# 每回合开始（_room_begin_next_prep）。
func _case_server_next_prep_uses_seat_races() -> void:
	var ns := NetworkService
	var seen := {}
	for _i in ROOMS:
		var room: Dictionary = ns._new_room()
		room.state = ns.ROOM_RESULT
		room.slot_states = ["player", "empty", "empty", "empty", "empty", "empty"]
		room.round_index = 20
		(room.seat_races as Dictionary)[0] = PICK_WITH_FAKE.duplicate()
		ns._room_prep(room, 0)
		ns._room_begin_next_prep(room)
		_tally_offers(seen, _seat_offers(room, 0))
		ns._rooms.erase(int(room.id))
	_expect_only_picked(seen, "server_next_prep")


# 点刷新（_room_apply_economy -> _economy_ctx）。
func _case_server_refresh_uses_seat_races() -> void:
	var ns := NetworkService
	var room: Dictionary = ns._new_room()
	room.state = ns.ROOM_PREP
	room.slot_states = ["player", "empty", "empty", "empty", "empty", "empty"]
	room.round_index = 21
	(room.seat_races as Dictionary)[0] = PICK_WITH_FAKE.duplicate()
	var prep: Dictionary = ns._room_prep(room, 0)
	var seen := {}
	for _i in ROOMS:
		# 同 shop_roll_parity：刷新价翻倍递增，每次复位金币与次数；影子模式要自报刷新前余额。
		prep["gold"] = 999999
		(prep.get("shop", {}) as Dictionary)["refresh_uses"] = 0
		var r: Dictionary = ns._room_apply_economy(room, 0, "shop_refresh",
			{"gold": int(prep.get("gold", 0))})
		if not bool(r.get("ok", false)):
			_h.fail("refresh_denied", "shop_refresh 被拒：%s" % str(r.get("error", "?")))
			break
		_tally_offers(seen, _seat_offers(room, 0))
	ns._rooms.erase(int(room.id))
	_expect_only_picked(seen, "server_refresh")


# 座位上没有出战种族（正常路径到不了，只可能是内部 bug）：回落默认，不刷空商店。
func _case_server_seat_without_races_defaults() -> void:
	var ns := NetworkService
	var seen := {}
	for _i in ROOMS:
		var room := _new_lobby_room(false)
		ns._room_start_authoritative(room)
		_tally_offers(seen, _seat_offers(room, 0))
		ns._rooms.erase(int(room.id))
	_h.expect(int(seen.get(FAKE_RACE, 0)) == 0 and int(seen.get(EXCLUDED, 0)) > 0,
		"seat_without_races_not_default",
		"座位没有出战种族时应当回落默认（表里前四族：有神族、没有假族），实际 %s" % str(seen))


# 恶意载荷在 adversarial_client；这里补「种族多于四个时」的两条 —— 真实数据下测不到。
func _case_server_accepts_four_of_five() -> void:
	var ns := NetworkService
	var room: Dictionary = ns._new_room()
	_h.expect(ns._room_accept_seat_races(room, 0, PICK_WITH_FAKE.duplicate()), "four_of_five_refused",
		"大厅里五族选四个被服务器拒了")
	_h.expect(str((room.seat_races as Dictionary).get(0, [])) == str(PICK_WITH_FAKE),
		"four_of_five_not_stored",
		"收下了但座位上没存对：%s" % str((room.seat_races as Dictionary).get(0, [])))
	_h.expect(not ns._room_accept_seat_races(room, 1, ["god", "dark", "undead", "human", FAKE_RACE]),
		"five_of_five_admitted", "大厅里五族全选被服务器收下了")
	ns._rooms.erase(int(room.id))


# --- 备战界面 -----------------------------------------------------------------

# 实例化失败必须记成 FAIL：PetScreen.gd 编译不过时 `as` 会给 null，后面的用例在访问成员时
# 直接崩掉、一条断言都没跑到 —— 结果是日志一片红、CHECK_RESULT 却是 PASS（第一版就这样过）。
func _open_pet_screen() -> PetScreenScript:
	var packed := load("res://scenes/menu/PetScreen.tscn") as PackedScene
	var screen: PetScreenScript = null
	if packed != null:
		screen = packed.instantiate() as PetScreenScript
	if not _h.expect(screen != null, "pet_screen_load_failed",
			"PetScreen 没能实例化成备战页脚本（多半是 PetScreen.gd 编译失败）"):
		return null
	add_child(screen)
	return screen


func _press_race(screen: PetScreenScript, race: String) -> void:
	((screen._race_cards[race] as Dictionary)["button"] as Button).pressed.emit()


func _case_pet_screen_race_tab() -> void:
	var saved_starter: bool = PlayerProfile.needs_starter_pick
	var saved_races: Array = PlayerProfile.selected_races.duplicate()
	# 只改内存，不落盘：清空 = 从没选过 = 默认前四族。
	PlayerProfile.needs_starter_pick = false
	PlayerProfile.selected_races.clear()
	var screen := _open_pet_screen()
	if screen == null:
		PlayerProfile.needs_starter_pick = saved_starter
		PlayerProfile.selected_races.assign(saved_races)
		return
	await get_tree().process_frame
	_h.expect(screen._tab_row.visible, "tabs_hidden", "非首次进入备战页，页签却没显示")
	_h.expect(screen._pet_box.visible and not screen._race_box.visible, "default_tab_not_pets",
		"备战页默认应当停在宠物页")
	(screen._tab_buttons[PetScreenScript.Tab.RACES] as Button).pressed.emit()
	_h.expect(screen._race_box.visible and not screen._pet_box.visible, "race_tab_not_shown",
		"点了「种族」页签，种族页没出来")
	_h.expect(screen._race_cards.size() == 5, "race_cards_count",
		"五族应当有五张卡，实际 %d" % screen._race_cards.size())
	_h.expect(screen._race_save_btn.visible and screen._race_save_btn.disabled, "save_state_unchanged",
		"没改动时保存按钮应当看得见、点不了")

	# 选满四个再点第五个：拒绝并提示，草稿不变
	GloryToast.reset_counters_for_check()
	_press_race(screen, FAKE_RACE)
	_h.expect(screen._race_draft.size() == 4 and not screen._race_draft.has(FAKE_RACE), "fifth_pick_accepted",
		"已经选满 4 个，再点第五族被加进去了：%s" % str(screen._race_draft))
	_h.expect(GloryToast.shown_count() > 0, "fifth_pick_silent", "选满之后再点，没有任何提示")

	# 取消神族 -> 3 个，保存点不了
	_press_race(screen, EXCLUDED)
	_h.expect(screen._race_draft.size() == 3 and screen._race_save_btn.disabled, "save_enabled_at_three",
		"只选了 3 个时保存按钮能点 —— 会把一份不合法的选择存进档案")

	# 选假族 -> 4 个且和已存的不同，保存能点；顺序跟棋子表一致
	_press_race(screen, FAKE_RACE)
	_h.expect(str(screen._race_draft) == str(PICK_WITH_FAKE), "draft_order_wrong",
		"草稿应当是 %s，实际 %s" % [str(PICK_WITH_FAKE), str(screen._race_draft)])
	_h.expect(not screen._race_save_btn.disabled, "save_disabled_when_valid",
		"选满 4 个且有改动，保存按钮却点不了")
	_h.expect(PlayerProfile.selected_races.is_empty(), "draft_saved_without_press",
		"没按保存，档案里的出战种族就变了")

	screen.queue_free()
	await get_tree().process_frame
	PlayerProfile.needs_starter_pick = saved_starter
	PlayerProfile.selected_races.assign(saved_races)


func _case_pet_screen_forced_and_starter() -> void:
	var saved_starter: bool = PlayerProfile.needs_starter_pick
	PlayerProfile.needs_starter_pick = false
	var screen := _open_pet_screen()
	if screen == null:
		PlayerProfile.needs_starter_pick = saved_starter
		return
	await get_tree().process_frame
	(screen._tab_buttons[PetScreenScript.Tab.RACES] as Button).pressed.emit()
	_h.expect(screen._race_cards.size() == 4, "forced_card_count",
		"四族应当四张卡，实际 %d" % screen._race_cards.size())
	var all_locked := true
	for race in screen._race_cards:
		if not ((screen._race_cards[race] as Dictionary)["button"] as Button).disabled:
			all_locked = false
	_h.expect(all_locked, "forced_cards_clickable", "四族选四个时卡片按钮应当全部锁定")
	_h.expect(not screen._race_save_btn.visible, "forced_save_visible", "没得选时不该出现保存按钮")
	_h.expect(screen._race_draft.size() == 4, "forced_draft_not_full",
		"没得选时草稿应当就是全部四族，实际 %s" % str(screen._race_draft))
	screen.queue_free()
	await get_tree().process_frame

	# 首次三选一宠物：只剩宠物页，页签、种族页、返回都藏起来
	PlayerProfile.needs_starter_pick = true
	var gate := _open_pet_screen()
	if gate == null:
		PlayerProfile.needs_starter_pick = saved_starter
		return
	await get_tree().process_frame
	_h.expect(not gate._tab_row.visible and gate._pet_box.visible and not gate._race_box.visible \
			and not gate._back_btn.visible, "starter_gate_changed",
		"首次三选一时应当只剩宠物页（页签 %s、种族页 %s、返回 %s）" % [
			str(gate._tab_row.visible), str(gate._race_box.visible), str(gate._back_btn.visible)])
	gate.queue_free()
	await get_tree().process_frame
	PlayerProfile.needs_starter_pick = saved_starter
