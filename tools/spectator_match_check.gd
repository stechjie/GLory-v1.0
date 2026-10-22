extends Node

# 门禁：对局内观战（第三步，2026-10-22）。真图在 tools/spectator_match_capture。
#
# 观战只读备战页的失败全是**静默**的，所以逐条钉住：
#   * 观战时不写存档 —— GameState 里装的是别人的阵容，写进去就成了观战者自己的存档；
#   * 只读备战页不采集萝卜、不摇商店、不倒计时（没有 PrepCountdown）、有输入遮罩；
#   * 换到蓝队座位：我方 / 对方血量跟着换（观战者没有「己方」，按被看的那位摆）；
#   * 选座 = 本机 team_local_slot 借成被看的座位（界面和那位选手一样）；离开观战要清回 -1，
#     否则下一次入座流程会以为自己坐着。

const Harness := preload("res://tools/CheckHarness.gd")
const PrepScene := preload("res://scenes/prep/PrepScreen.tscn")
const SpectatorSeat := preload("res://scripts/multiplayer/SpectatorSeat.gd")

var h := Harness.new("spectator_match")
var _saved := {}
const KEYS := ["team_active", "spectating", "spectate_state", "spectate_view", "spectate_view_slot",
	"team_local_slot", "team_room_id"]


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	NetworkService.set_process(false)
	for key in KEYS:
		_saved[key] = NetworkService.get(key)
	var saved_round := GameState.round_index
	var saved_harvest := GameState.last_harvest_round
	_setup()
	_case_no_save()
	_case_seat_apply()
	await _case_prep_read_only()
	_case_slot_borrow_and_reset()
	for key in _saved:
		NetworkService.set(key, _saved[key])
	GameState.round_index = saved_round
	GameState.last_harvest_round = saved_harvest
	h.finish(get_tree())


func _unit(i: int) -> Dictionary:
	var rows: Array = DataRegistry.get_table("race_units").get("units", [])
	return {"id": str(rows[i % rows.size()].get("id", "")), "uid": "chk-%d" % i, "star": 2}


func _setup() -> void:
	var board := []
	board.resize(GameConstants.CELL_COUNT)
	board[0] = _unit(0)
	board[5] = _unit(4)
	NetworkService.team_active = true
	NetworkService.spectating = true
	NetworkService.spectate_view = {"round": 3, "battle_id": "1:3:1", "seats": {
		0: {"board": board, "bench": [_unit(7)], "mercenaries": [], "treasures": [], "gold": 17},
		3: {"board": [], "bench": [], "mercenaries": [], "treasures": [], "gold": 4},
	}}
	NetworkService.spectate_state = {"phase": "prep", "round_id": 4, "final_round": 21, "team_hp": [40, 22],
		"slot_states": ["player", "dummy", "dummy", "player", "dummy", "dummy"], "seat_profiles": {}}


func _case_no_save() -> void:
	SaveManager.save_run()
	h.expect(not bool(SaveManager.get("_save_pending")), "save_while_spectating",
		"观战时不能写存档：GameState 里装的是被看选手的阵容")


func _case_seat_apply() -> void:
	SpectatorSeat.apply(NetworkService.spectate_view, NetworkService.spectate_state, 3)
	h.expect(GameState.team_hp == 22 and GameState.enemy_team_hp == 40, "blue_hp_not_swapped",
		"看蓝队座位时我方血量应是蓝队的（22），对方是红队的（40）")
	SpectatorSeat.apply(NetworkService.spectate_view, NetworkService.spectate_state, 0)
	h.expect(GameState.team_hp == 40 and GameState.gold == 17 and GameState.round_index == 4,
		"red_seat_wrong", "看红队 A 座：血量 40、金币 17、回合 4（正在备战的那一回合）")
	h.expect(typeof(GameState.board_slots[0]) == TYPE_DICTIONARY and typeof(GameState.bench_slots[0]) == TYPE_DICTIONARY,
		"board_or_bench_missing", "上一回合的棋盘和备战区要装进 GameState")
	var empty_shop := GameState.shop_offers.size() == GameState.SHOP_UNIT_SLOTS
	for offer in GameState.shop_offers:
		empty_shop = empty_shop and (offer as Dictionary).is_empty()
	h.expect(empty_shop, "shop_not_hidden", "观战不看商店：商店格子要全空（且格数要满，商店面板按下标读）")


func _case_prep_read_only() -> void:
	GameState.last_harvest_round = -7
	var prep: Control = PrepScene.instantiate()
	prep.spectator_view = true
	add_child(prep)
	for _i in 20:
		await get_tree().process_frame
	h.expect(prep.get_node_or_null("SpectatorInputShield") != null, "no_input_shield", "只读备战页要有输入遮罩")
	h.expect(prep.get_node_or_null("PrepCountdown") == null, "countdown_running", "只读备战页不该有倒计时（到点会自动上阵）")
	h.expect(GameState.last_harvest_round == -7, "harvested", "只读备战页不该采集萝卜")
	var still_empty := true
	for offer in GameState.shop_offers:
		still_empty = still_empty and (offer as Dictionary).is_empty()
	h.expect(still_empty, "shop_rolled", "只读备战页不该摇商店")
	h.expect(not bool(SaveManager.get("_save_pending")), "prep_saved", "只读备战页不该写存档")
	prep.queue_free()
	await get_tree().process_frame


func _case_slot_borrow_and_reset() -> void:
	NetworkService.spectate_select_slot(4)
	h.expect(NetworkService.team_local_slot == 4 and NetworkService.spectate_view_slot == 4, "slot_not_borrowed",
		"选座后本机 team_local_slot 要借成被看的座位（界面和那位选手一样）")
	NetworkService._spectate_reset()
	h.expect(NetworkService.team_local_slot == -1 and not NetworkService.spectating and NetworkService.spectate_view_slot == 0,
		"reset_keeps_slot", "离开观战要把借来的座位号清回 -1、默认座位回到红队 A")
