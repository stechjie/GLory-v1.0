extends "res://scenes/prep/PrepUI.gd"

func _maybe_start_pending_treasure() -> void:
	if bool(GameState.pending_treasure.get("active", false)):
		if GameState.pending_treasure.get("candidates", []).is_empty() and TreasureService.can_draw():
			GameState.pending_treasure.candidates = TreasureService.roll_candidates(3)
		return
	var completed_round := maxi(0, GameState.round_index - 1)
	if completed_round in GameState.claimed_treasure_rounds:
		return
	if RoundService.is_treasure_round(completed_round) and TreasureService.can_draw():
		GameState.pending_treasure = {
			"active": true,
			"round": completed_round,
			"candidates": TreasureService.roll_candidates(3),
			"refresh_index": 0,
		}

func _pick_treasure(tid: String) -> void:
	TreasureService.add_owned(tid)
	_claim_pending_treasure_round()
	GameState.pending_treasure.active = false
	SaveManager.save_run()
	_refresh_all()
	if GameState.tutorial_mode:
		TutorialMode.sync()

func _refresh_treasure_candidates() -> void:
	var cost := TreasureService.refresh_cost(int(GameState.pending_treasure.get("refresh_index", 0)), TreasureService.has_set("money"))
	if GameState.gold < cost:
		return
	GameState.gold -= cost
	GameState.pending_treasure.refresh_index = int(GameState.pending_treasure.get("refresh_index", 0)) + 1
	GameState.pending_treasure.candidates = TreasureService.roll_candidates(3)
	SaveManager.save_run()
	_refresh_all()

func _claim_pending_treasure_round() -> void:
	var completed_round := int(GameState.pending_treasure.get("round", 0))
	if completed_round > 0 and completed_round not in GameState.claimed_treasure_rounds:
		GameState.claimed_treasure_rounds.append(completed_round)

func _on_start_battle() -> void:
	# 教学：当前步还不能开战时，给提示并直接返回——不要触发 _emit_battle_request_once，
	# 否则一次性发射锁 _battle_launch_emitted 会被烧掉，导致之后真到可开战步时按钮无反应。
	if GameState.tutorial_mode and not TutorialMode.can_start_battle():
		show_message(TutorialMode.follow_arrow_hint())
		return
	RaceRelationService.finalize_for_battle(GameState.board_slots, GameState.bench_slots)
	SaveManager.save_run()
	if NetworkService.team_active:
		# 3v3: the button is "准备" — toggle ready and stay in prep. The round
		# launches for everyone (team_round_start) once all players are ready.
		var my := NetworkService.team_local_slot
		var is_ready := my >= 0 and my < NetworkService.team_ready.size() and bool(NetworkService.team_ready[my])
		NetworkService.team_set_ready(not is_ready)
		_refresh_all()
		return
	_emit_battle_request_once()

func _emit_battle_request_once() -> void:
	if _battle_launch_emitted:
		return
	RaceRelationService.finalize_for_battle(GameState.board_slots, GameState.bench_slots)
	_battle_launch_emitted = true
	battle_requested.emit()

func _has_any_board_unit() -> bool:
	for cell in GameState.board_slots:
		if cell != null:
			return true
	for cell in GameState.mercenary_slots:
		if cell != null:
			return true
	return false

func _mark_online_board_changed() -> void:
	RaceRelationService.reconcile_board(GameState.board_slots, GameState.bench_slots, false, true)
	if NetworkService.team_active:
		# 3v3: editing the board cancels your ready so you can't be locked mid-edit.
		var my := NetworkService.team_local_slot
		if my >= 0 and my < NetworkService.team_ready.size() and bool(NetworkService.team_ready[my]):
			NetworkService.team_set_ready(false)

func _on_network_session_changed() -> void:
	_refresh_formation_status()
	_refresh_merc_panel()

func _on_golden_altar() -> void:
	if not GameState.owned_treasures.has("money_golden_altar"):
		return
	# 联机局：祭坛拿服务端权威的法阵 HP 换金币，本地扣 HP 会被下一份 match_state
	# 覆盖掉（代价蒸发、金币白拿）。所以只发意图，等服务端扣完 HP 授权后才加金币。
	if NetworkService.team_active:
		if not NetworkService.altar_result.is_connected(_on_altar_result):
			NetworkService.altar_result.connect(_on_altar_result)
		NetworkService.request_golden_altar()
		return
	# 单机：本地就是权威，直接结算。
	if GameState.player_formation_hp <= NetworkService.ALTAR_MIN_HP or GameState.golden_altar_uses >= NetworkService.ALTAR_MAX_USES_PER_ROUND:
		return
	GameState.player_formation_hp -= 1
	GameState.gold += NetworkService.ALTAR_GOLD
	GameState.golden_altar_uses += 1
	SaveManager.save_run()
	_refresh_all()

# 服务端对祭坛请求的裁决。uses < 0 表示这是队友用祭坛导致的共享 HP 同步，
# 本人不加金币、只刷新显示。
func _on_altar_result(granted: bool, team_hp: int, uses: int) -> void:
	if uses < 0:
		_refresh_all()
		return
	if not granted:
		_refresh_all()
		return
	GameState.team_hp = team_hp
	GameState.golden_altar_uses = uses
	GameState.gold += NetworkService.ALTAR_GOLD
	SaveManager.save_run()
	_refresh_all()

func _on_generous_fate_gamble() -> void:
	if not GameState.owned_treasures.has("money_generous_fate"):
		return
	if GameState.gamble_used:
		return
	var before := GameState.gold
	GameState.gamble_used = true
	var fraud_fate := TreasureService.has_linkage("link_fraud_fate")
	var win_chance := 0.60 if fraud_fate else 0.50
	var loss_keep := 0.50 if fraud_fate else 0.20
	if randf() < win_chance:
		GameState.gold = before * 2
	else:
		GameState.gold = maxi(0, int(floor(float(before) * loss_keep)))
	SaveManager.save_run()
	_refresh_all()



