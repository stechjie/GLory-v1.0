extends "res://scenes/prep/PrepUI.gd"

const DiceRollFxScript := preload("res://scenes/prep/fx/DiceRollFx.gd")
const AltarCoinBurstFxScript := preload("res://scenes/prep/fx/AltarCoinBurstFx.gd")

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
			"remaining": RoundService.treasure_pick_count(completed_round),
		}

func _pick_treasure(tid: String) -> void:
	# 联机局：只发意图，等服务端授权后才真正入袋（与黄金祭坛 _on_golden_altar 同一模式）。
	# 本地不做乐观加入——宝物会立刻改变羁绊、经济和图鉴，抢跑后被服务端拒收就要回滚
	# 一串副作用，回滚比等一个 RTT 贵得多。
	if NetworkService.team_active:
		_connect_treasure_signals()
		NetworkService.request_treasure_choice(tid)
		return
	var bonus_before := _active_bonus_ids()
	if not TreasureService.claim_local_choice(tid):
		_treasure.clear_pick_pending()
		if bool(GameState.pending_treasure.get("active", false)):
			GameState.pending_treasure.candidates = TreasureService.available_candidates(GameState.pending_treasure.get("candidates", []))
		_refresh_all()
		return
	var remaining := maxi(0, int(GameState.pending_treasure.get("remaining", 1)) - 1)
	if remaining > 0 and TreasureService.can_draw():
		GameState.pending_treasure["remaining"] = remaining
		GameState.pending_treasure["candidates"] = TreasureService.roll_candidates(3)
		GameState.pending_treasure["refresh_index"] = 0
		GameState.pending_treasure["active"] = not GameState.pending_treasure["candidates"].is_empty()
	else:
		GameState.pending_treasure["active"] = false
	if not bool(GameState.pending_treasure.get("active", false)):
		_claim_pending_treasure_round()
	elif GameState.tutorial_mode:
		# 教程一轮要连选 2 个：本地已入袋，面板不关、换下一组候选。
		# 防连点锁是给联机等服务端回复用的，这里不清会吞掉 5 秒内的第二次点击。
		_treasure.clear_pick_pending()
	if "link_hu_pai_master" not in bonus_before and TreasureService.has_linkage("link_hu_pai_master"):
		if GameState.team_mode:
			var max_hp := TutorialMode.TUTORIAL_HP if GameState.tutorial_mode else GameState.START_FORMATION_HP
			GameState.team_hp = mini(max_hp, GameState.team_hp + 2)
		else:
			GameState.player_formation_hp = mini(GameState.START_FORMATION_HP, GameState.player_formation_hp + 2)
	SaveManager.save_run()
	_finish_treasure_change(bonus_before)
	if GameState.tutorial_mode:
		TutorialMode.sync()


# 宝物入袋后的统一收尾 —— **单机与联机必须走同一条路**。
#
# 为什么需要：宝物（折扣令牌 / 慷慨命运 / 黄金祭坛…）会改变左侧羁绊面板与商店
# 内容，棋盘框 `board_frame` 被 HBox 整体挤动。这是**平移**不是 resize。
# `item_rect_changed` 信号只在 rect 变化的当帧发出，落在
# `_apply_prep_model_layout_after_frames` 稳定轮询窗口之外的二次平移会被漏掉 ——
# 现象就是用户实测的「选了宝藏后上阵光圈偏移石台，**点赌博又恢复原样**」：
# 因为赌博那条路径（`_on_generous_fate_gamble`）显式调了重排，而单机选宝藏
# （`_pick_treasure` 的非 team_active 分支）原来漏了这一步，联机分支
# （`_on_treasure_granted`）却有。两条路径各写一份 = 只修一条。
func _finish_treasure_change(bonus_before: Array) -> void:
	_refresh_all()
	_queue_bonus_fx(bonus_before)
	_queue_prep_model_layout_refresh()

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
	var bonus_before := _active_bonus_ids()
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
	_finish_treasure_change(bonus_before)

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
		# 10.18：取消准备 = 作废提交。客户端同步丢掉「最后一次提交」缓存，
		# 否则被拒后的校准重交(_rpc_board_rejected)会把作废的棋盘又发回去。
		NetworkService.clear_last_team_submission()
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
	# 9.25 教程优化第 4/5 条：步骤 3/5/14 要至少 3 个上阵棋子、步骤 22 要至少 7 个。
	# 不够时同样直接 return（理由同上：不能烧掉一次性发射锁）。判据在 TutorialMode 里，
	# 这里只负责把提示弹出来。
	if GameState.tutorial_mode:
		var gate := TutorialMode.battle_board_gate_message()
		if not gate.is_empty():
			show_message(gate)
			return
	RaceRelationService.finalize_for_battle(GameState.board_slots, GameState.bench_slots)
	SaveManager.save_run()
	if NetworkService.team_active and not GameState.tutorial_mode:
		# 3v3: the button is "准备" — toggle ready and stay in prep. The round
		# launches for everyone (team_round_start) once all players are ready.
		# 教学不算联机：残留会话不能让「准备」变成发给服务端的 ready 意图
		# （那样教学里的战斗永远开不起来）。9.13 #3。
		# 10.18「准备即提交棋盘」：客机在发 ready 之前先把棋盘交上去，之后哪怕
		# 立刻掉线，服务端也有棋盘可 finalize，其他人不必干等。房主路径不提前交
		# （它的提交流程在 _prepare_team_battle_package 里，本地路径无掉线保留）。
		if not NetworkService.is_host:
			NetworkService.team_submit_board(NetProtocol.team_board_submission(GameState.board_slots, GameState.mercenary_slots))
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
	if NetworkService.team_active and not GameState.tutorial_mode:
		# 3v3：改棋盘就取消准备，免得被锁在编辑到一半的状态。
		# 判断依据必须是 local_ready_intent()，不能直接读 team_ready（C24）——
		# 后者要等服务器广播回来才更新，"按下准备 → 回包到达前挪棋子"这段窗口里
		# 它还是 false，取消请求根本不会发出，而服务器已经按已准备锁盘了。
		if NetworkService.local_ready_intent():
			NetworkService.team_set_ready(false)
			# 10.18：改棋盘即取消准备 = 作废提交，缓存一起清（同 _on_start_battle）。
			NetworkService.clear_last_team_submission()

func _on_team_treasure_effects_changed() -> void:
	SaveManager.save_run()
	_refresh_all()

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
	var gains: Dictionary = {}
	if NetworkService.team_carrot_harvest_round == GameState.round_index:
		gains = NetworkService.team_carrot_harvest_gains.duplicate(true)
	if gains.is_empty():
		var gain := NetworkService.last_carrot_harvest_gain
		if gain <= 0:
			return
		gains[clampi(NetworkService.team_local_slot, 0, 5)] = gain
	if gains.is_empty():
		return
	_carrot_feedback_round = GameState.round_index
	play_carrot_harvest_feedback(gains)

func _on_golden_altar() -> void:
	if not GameState.tutorial_mode and NetworkService.team_active and not NetworkService.is_host and not NetworkService.server_prep_confirmed(GameState.round_index):
		show_message(tr("battle_waiting_others"))
		return
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
	GameState.player_formation_hp -= 0 if TreasureService.has_linkage("link_hu_pai_master") else TreasureService.golden_altar_hp_cost()
	GameState.gold += NetworkService.ALTAR_GOLD
	GameState.prep_income_total += NetworkService.ALTAR_GOLD
	GameState.golden_altar_uses += 1
	SaveManager.save_run()
	_refresh_all()
	_play_altar_coin_burst(NetworkService.ALTAR_GOLD)

# 服务端对祭坛请求的裁决。uses < 0 表示这是队友用祭坛导致的共享 HP 同步，
# 本人不加金币、只刷新显示。
func _on_altar_result(granted: bool, team_hp: int, uses: int) -> void:
	if uses < 0:
		_refresh_all()
		# 10.18：队友献祭 —— 共享水晶上同样爆一把金币，不带数字。
		_play_altar_coin_burst(0)
		return
	if not granted:
		_refresh_all()
		return
	GameState.team_hp = team_hp
	GameState.golden_altar_uses = uses
	GameState.gold += NetworkService.ALTAR_GOLD
	GameState.prep_income_total += NetworkService.ALTAR_GOLD
	SaveManager.save_run()
	_refresh_all()
	_play_altar_coin_burst(NetworkService.ALTAR_GOLD)
	# 祭坛按钮的文案（剩余次数）会改变左面板高度 ⇒ 同样挤动棋盘。收尾与宝物入袋一致：
	# 只靠 `item_rect_changed` 信号会在「平移落在稳定轮询窗口之外」时漏掉。
	_queue_prep_model_layout_refresh()

func _on_generous_fate_gamble() -> void:
	if not GameState.tutorial_mode and NetworkService.team_active and not NetworkService.is_host and not NetworkService.server_prep_confirmed(GameState.round_index):
		show_message(tr("battle_waiting_others"))
		return
	if not GameState.owned_treasures.has("money_generous_fate"):
		return
	if GameState.gamble_used:
		return
	var before := GameState.gold
	GameState.gamble_used = true
	var fraud_fate := TreasureService.has_linkage("link_fraud_fate")
	var win_chance := 0.60 if fraud_fate else 0.50
	var loss_keep := 0.50 if fraud_fate else 0.20
	# 10.18：开奖先定，再掷骰演 2 秒；骰子落定（revealed）那一刻才改金币、刷新界面。
	# 骰面只是演出：赢在 4-6 里挑、输在 1-3 里挑，概率仍是上面这一行（联动 60%）。
	var won := randf() < win_chance
	var after := int(floor(float(before) * 2.5)) if won else maxi(0, int(floor(float(before) * loss_keep)))
	# 先把 logo 置灰，防止演出期间再点一次。
	_refresh_all()
	var apply_result := func() -> void:
		GameState.gold = after
		if won:
			GameState.prep_income_total += maxi(0, after - before)
		elif after < before:
			GameState.gold_spent_this_round = true
		SaveManager.save_run()
		if is_inside_tree():
			_refresh_all()
			# 赌博同样会改变面板内容并触发棋盘平移，重新对齐圆圈以防偏移。
			_queue_prep_model_layout_refresh()
	_play_dice_roll(won, after - before, apply_result)


# 黄金祭坛爆金币：从顶栏正中自家法阵水晶喷出。gold_gain <= 0 是队友献祭，不显示数字。
func _play_altar_coin_burst(gold_gain: int) -> void:
	if _player_formation_art == null or not is_instance_valid(_player_formation_art) or not is_inside_tree():
		return
	var rect := _screen_rect(_player_formation_art)
	var fx := AltarCoinBurstFxScript.new()
	_bonus_fx_host().add_child(fx)
	fx.play(rect.position + rect.size * 0.5, gold_gain)


# 掷骰演出。起点取骰子 logo 的屏幕中心；拿不到（面板正在重建）就从屏幕中央起手。
# revealed 只会发一次，节点被提前移出树也会补发，所以结算不会丢。
func _play_dice_roll(won: bool, gold_delta: int, on_reveal: Callable) -> void:
	var fx := DiceRollFxScript.new()
	_bonus_fx_host().add_child(fx)
	fx.revealed.connect(on_reveal, CONNECT_ONE_SHOT)
	var from := get_viewport_rect().size * Vector2(0.5, 0.6)
	var logo: Control = _synergy.gamble_logo
	if logo != null and is_instance_valid(logo):
		var rect := _screen_rect(logo)
		from = rect.position + rect.size * 0.5
	fx.play(from, won, gold_delta)
