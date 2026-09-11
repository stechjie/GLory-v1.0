extends "res://scenes/prep/PrepUI.gd"

# 已经播过采集反馈的回合号。客机的采集是服务端发的，到达时机与本场景 _ready()
# 是竞态的，所以两条路径都可能触发播放 —— 用它保证一回合只播一次。
var _carrot_feedback_round := -1

func _maybe_start_pending_treasure() -> void:
	# 联机局：候选完全由服务端发放（match_state.pending_treasure / resume payload）。
	# 客户端既不能自己开抽奖，也不能在候选为空时本地补摇——这两条都是「自发宝物」，
	# 会绕开服务端的归属记录：真去选时 _rpc_treasure_choice 会以 not_offered 拒收，
	# 玩家看到的是一个点了没反应的界面。宁可不显示，也不显示一个假的。
	if NetworkService.team_active:
		return
	if bool(GameState.pending_treasure.get("active", false)):
		GameState.pending_treasure.candidates = TreasureService.available_candidates(GameState.pending_treasure.get("candidates", []))
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
	# 联机局：只发意图，等服务端授权后才真正入袋（与黄金祭坛 _on_golden_altar 同一模式）。
	# 本地不做乐观加入——宝物会立刻改变羁绊、经济和图鉴，抢跑后被服务端拒收就要回滚
	# 一串副作用，回滚比等一个 RTT 贵得多。
	if NetworkService.team_active:
		_connect_treasure_signals()
		NetworkService.request_treasure_choice(tid)
		return
	if not TreasureService.claim_local_choice(tid):
		_treasure.clear_pick_pending()
		if bool(GameState.pending_treasure.get("active", false)):
			GameState.pending_treasure.candidates = TreasureService.available_candidates(GameState.pending_treasure.get("candidates", []))
		_refresh_all()
		return
	_claim_pending_treasure_round()
	GameState.pending_treasure.active = false
	SaveManager.save_run()
	_refresh_all()
	if GameState.tutorial_mode:
		TutorialMode.sync()

func _connect_treasure_signals() -> void:
	if not NetworkService.treasure_granted.is_connected(_on_treasure_granted):
		NetworkService.treasure_granted.connect(_on_treasure_granted)
	if not NetworkService.treasure_denied.is_connected(_on_treasure_denied):
		NetworkService.treasure_denied.connect(_on_treasure_denied)
	if not NetworkService.treasure_offer_changed.is_connected(_on_treasure_offer_changed):
		NetworkService.treasure_offer_changed.connect(_on_treasure_offer_changed)

# 服务端授权入袋。走 add_owned 而不是直接覆盖 owned_treasures：它还负责图鉴
# mark_seen 与联动解锁，绕过去会让玩家少解锁东西。
func _on_treasure_granted(tid: String, owned: Array) -> void:
	# 以服务端列表为准同步（helper 内部走 add_owned，保留图鉴/联动副作用）。
	# 不要只 add_owned(tid)：那样本地多出来的项永远裁不掉，两边会一直漂。
	var before := GameState.owned_treasures.size()
	TreasureService.sync_owned_from_server(owned)
	if before + 1 != GameState.owned_treasures.size():
		# 本地曾经存在一条没走 intent 的入袋路径（单机/教学代码漏进联机分支），
		# 或者上一次同步漏了。必须能从日志看出来，不能静默被 helper 抹平。
		push_warning("[NET] treasure owned resynced: local %d -> %d (server=%d, granted=%s)" % [
			before, GameState.owned_treasures.size(), owned.size(), tid])
	_claim_pending_treasure_round()
	GameState.pending_treasure.active = false
	# 意图已经有结果了，解开待定锁。
	_treasure.clear_pick_pending()
	SaveManager.save_run()
	_refresh_all()
	# 宝物入袋（折扣令牌/慷慨命运等）会改变左侧羁绊面板或商店内容，棋盘随之平移。
	# 主动重新对齐 3D 投影的棋盘圆圈，避免「绿/红圈偏移石台」的 bug 复现
	# （进下一轮对战后回正，正是重建 PrepUI 时重新跑了这次对齐）。
	_queue_prep_model_layout_refresh()

func _on_treasure_denied(reason: String) -> void:
	# 不静默：拒收后界面必须回到一个玩家能理解的状态，否则就是「点了没反应」。
	show_message(tr("net_err_treasure_denied") % reason)
	# 被拒也是结果：必须解锁，否则一次拒收就把三张卡永久锁死。
	_treasure.clear_pick_pending()
	_refresh_all()

func _on_treasure_offer_changed(candidates: Array, refresh_index: int) -> void:
	GameState.pending_treasure.candidates = candidates.duplicate()
	GameState.pending_treasure.refresh_index = refresh_index
	# 候选换了一批，之前那次意图作废，解锁让玩家能在新候选里重新选。
	_treasure.clear_pick_pending()
	SaveManager.save_run()
	_refresh_all()
func _claim_pending_treasure_round() -> void:
	var completed_round := int(GameState.pending_treasure.get("round", 0))
	if completed_round > 0 and completed_round not in GameState.claimed_treasure_rounds:
		GameState.claimed_treasure_rounds.append(completed_round)

func _on_start_battle() -> void:
	# Cancelling an existing (including in-flight) ready intent is always allowed.
	if NetworkService.team_active and NetworkService.local_ready_intent():
		NetworkService.team_set_ready(false)
		_refresh_all()
		return
	if not _has_any_board_unit():
		show_message("At least 1 unit must be on the board before you can ready up" if LocaleManager.get_locale().begins_with("en") else "至少有1个棋子在棋盘上才能准备")
		return
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
		NetworkService.team_set_ready(true)
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
		# 3v3：改棋盘就取消准备，免得被锁在编辑到一半的状态。
		# 判断依据必须是 local_ready_intent()，不能直接读 team_ready（C24）——
		# 后者要等服务器广播回来才更新，"按下准备 → 回包到达前挪棋子"这段窗口里
		# 它还是 false，取消请求根本不会发出，而服务器已经按已准备锁盘了。
		if NetworkService.local_ready_intent():
			NetworkService.team_set_ready(false)

func _on_network_session_changed() -> void:
	var incoming_offer := str(NetworkService.server_shop.get("offer_id", ""))
	if not incoming_offer.is_empty() and incoming_offer != GameState.shop_offer_id:
		if bool(call("_adopt_server_shop")):
			_refresh_all()
	_refresh_formation_status()
	_refresh_merc_panel()
	# room_state 是客机**唯一**的萝卜来源（NetworkService._apply_carrot_state）。
	# 不在这里刷新，客机的萝卜营地面板和 3D 萝卜田就冻在上一次本地操作的状态：
	# 服务端发了萝卜、涨了田等级、队友抽到的共享石头进了仓库，面板上一个数字都不动，
	# 抽石/升科技按钮也保持旧的置灰状态，直到玩家关掉面板再打开（toggle 会 refresh）。
	if _carrot_panel != null and is_instance_valid(_carrot_panel):
		_carrot_panel.refresh()
	_refresh_carrot_counter()
	refresh_carrot_gathering()
	_maybe_play_pending_carrot_harvest()


# 客机进备战时，本回合的采集**还没到**：服务端是先建 match_state（带的是上一回合
# 的采集）、再推进回合并采集、最后才广播 room_state。PrepScreen._ready() 里那条
# `last_harvest_round == round_index` 判据在那个时刻结构性不成立，于是挖土动画和
# `+N 萝卜` 飘字对专服客机**从来没播过**。
#
# 权威采集随后才由 room_state 送达，这里补播。房主与单机不走这条路（他们在
# _ready() 里本地采集并当场播），_carrot_feedback_round 保证不会重播。
func _maybe_play_pending_carrot_harvest() -> void:
	if GameState.tutorial_mode:
		return
	if not (NetworkService.team_active and not NetworkService.is_host):
		return
	if GameState.last_harvest_round != GameState.round_index:
		return
	if _carrot_feedback_round == GameState.round_index:
		return
	var gain := NetworkService.last_carrot_harvest_gain
	if gain <= 0:
		return
	_carrot_feedback_round = GameState.round_index
	play_carrot_harvest_feedback(gain)

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
	# 赌博同样会改变面板内容并触发棋盘平移，重新对齐圆圈以防偏移。
	_queue_prep_model_layout_refresh()

