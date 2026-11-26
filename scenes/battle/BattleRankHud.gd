extends RefCounted
## 战斗里的排名 HUD（11-18）：左边 PvP 伤害前三、右边打怪 / Boss 清路前三、左下钱袋。
## 数据全部来自回放（不自己推算）：
##   伤害   = 回放 frame_slot_damage（每帧 6 个座位的累计伤害）
##   清路   = 两队回放的 lane_clear_ticks（BattleSimulator._replay_track_lane_clears）
##   击杀金 = 自己这队回放的 slot_kill_gold_events（和结算同一个 kill_gold_by_slot 账本）
## 名次和奖励用 BattleRankRewards，和战斗服务器发钱是同一个函数，所以屏幕上的名次 = 到账的钱。
## 组件挂在 BattleCombatFeedback 下面（跟着它的安全区和层级）；这里只负责喂数据和摆位置。

const BattleRankRewards := preload("res://scripts/economy/BattleRankRewards.gd")
const DamageBoard := preload("res://effects/runtime/presentation/DamageLeaderboard.gd")
const LaneBoard := preload("res://effects/runtime/presentation/LaneClearBoard.gd")
const Purse := preload("res://effects/runtime/presentation/BattlePurse.gd")

## 和 BattleScreen 右上角那列按钮对齐（VIEW_TOGGLE_* / VOICE_BTN_*，右边距 16）。
const RIGHT_MARGIN := 16.0
const BUTTON_COLUMN_W := 120.0
const VIEW_TOGGLE_W := 68.0
const SOLO_LANE_TOP := 54.0 + 68.0 + 8.0
const VOICE_LANE_TOP := 128.0 + 64.0 * 2.0 + 56.0 + 8.0
const PURSE_MARGIN := 16.0

var _feedback: Control
var _own: Dictionary = {}
var _rival: Dictionary = {}
var _kind := ""
var _round := 0
var _local_slot := -1
var _damage_board: Control
var _lane_board: Control
var _purse: Control
var _clear_ticks: Array = []
var _kill_events: Array = []
var _kill_cursor := 0
var _kill_total := 0
var _last_tick := -1
var _finished := false


## kind 用 BattleUI._effective_kind()（第 21 回合是 "final"）。spectating = 观战：没有自己的钱，不出钱袋。
func setup(feedback: Control, own: Dictionary, rival: Dictionary, kind: String, round_index: int, local_slot: int, spectating: bool) -> void:
	_feedback = feedback
	_own = own
	_rival = rival
	_kind = kind
	_round = round_index
	_local_slot = local_slot
	match kind:
		"pvp", "final":
			_damage_board = DamageBoard.new()
			_damage_board.name = "DamageLeaderboard"
			# 第 21 回合照样排，但不发钱（BattleRankRewards），木牌上也就不挂金币。
			_damage_board.rewards = BattleRankRewards.rewards_for_kind(kind)
			_feedback.add_child(_damage_board)
			_feedback.call("set_single_plate_enabled", false)
		"pve", "boss":
			_lane_board = LaneBoard.new()
			_lane_board.name = "LaneClearBoard"
			_feedback.add_child(_lane_board)
			_clear_ticks = BattleRankRewards.merged_clear_ticks([own, rival])
	# 钱袋：只给自己有钱的人；第 21 回合不出（用户 11-18 定）。
	if not spectating and local_slot >= 0 and kind != "final":
		_purse = Purse.new()
		_purse.name = "BattlePurse"
		_feedback.add_child(_purse)
		# Boss 局服务器不发击杀金（EconomyService 第 1 步），钱袋只等排名奖励。
		if kind != "boss":
			for e in own.get("slot_kill_gold_events", []):
				if e is Array and (e as Array).size() >= 3 and int(e[1]) == local_slot:
					_kill_events.append(e)


## 换下一场 / 重开回放前把这一套收掉，单人伤害木牌恢复。
func teardown() -> void:
	for node in [_damage_board, _lane_board, _purse]:
		if node != null and is_instance_valid(node):
			(node as Node).queue_free()
	_damage_board = null
	_lane_board = null
	_purse = null
	if _feedback != null and is_instance_valid(_feedback):
		_feedback.call("set_single_plate_enabled", true)
	_feedback = null


func refresh(tick: int, animate: bool, has_voice: bool) -> void:
	if _feedback == null or not is_instance_valid(_feedback) or _finished:
		return
	_layout(has_voice)
	if _damage_board != null:
		var frames: Array = _own.get("frame_slot_damage", [])
		if not frames.is_empty():
			_damage_board.update_entries(_damage_entries(frames[clampi(tick, 0, frames.size() - 1)]),
				_local_slot, _round, animate, false)
	if _lane_board != null:
		_lane_board.update_entries(_lane_entries(tick), animate)
	_refresh_purse(tick, animate)


## 播完 / 跳过：按最终数据精确排一次，然后自己的排名奖励从木牌 / 绶带飞进钱袋。
func finish(has_voice: bool) -> void:
	if _feedback == null or not is_instance_valid(_feedback) or _finished:
		return
	_layout(has_voice)
	var ranking: Array = []
	if _damage_board != null:
		var frames: Array = _own.get("frame_slot_damage", [])
		if not frames.is_empty():
			_damage_board.update_entries(_damage_entries(frames[-1]), _local_slot, _round, true, true)
		ranking = BattleRankRewards.pvp_damage_ranking(frames)
	if _lane_board != null:
		_lane_board.update_entries(_lane_entries(-1), true)
		ranking = BattleRankRewards.lane_clear_ranking(_clear_ticks)
	_refresh_purse(1 << 30, true)
	_finished = true
	if _purse == null:
		return
	# 11.26：Boss 局不发击杀金，以前钱袋整场是 0，没进清路前三的人会以为「赢了 Boss 没钱」。
	# 战斗结束把 Boss 奖励（赢：固定奖励；输：按打掉的血量比例补偿）也飞进钱袋。
	# 金额和 EconomyService.settle_post_battle_breakdown 的 "boss" 分支同一对函数、同一批输入，只是显示。
	var boss_gold := _boss_reward()
	if boss_gold > 0:
		var english := LocaleManager.get_locale().begins_with("en")
		var boss_won := bool((_own.get("result", {}) as Dictionary).get("player_wins", false))
		var boss_reason := ("Boss defeated" if english else "击败 Boss") if boss_won else ("Boss damage reward" if english else "Boss 伤害补偿")
		_purse.fly_in(_feedback.global_position + _feedback.size * Vector2(0.5, 0.35), boss_gold, boss_reason)
	var rewards := BattleRankRewards.rewards_for_kind(_kind)
	var reward_rank := BattleRankRewards.rank_of(ranking, _local_slot)
	if reward_rank < 0 or reward_rank >= rewards.size():
		return
	var anchor: Variant = null
	if _damage_board != null:
		anchor = _damage_board.anchor_global(_local_slot)
	elif _lane_board != null:
		anchor = _lane_board.anchor_global(_local_slot)
	if anchor == null:
		anchor = _purse.global_position
	_purse.fly_in(anchor, int(rewards[reward_rank]), _reason_text(reward_rank))


## Boss 局结算会到账的 Boss 奖励 / 补偿；别的局型是 0。
func _boss_reward() -> int:
	if _kind != "boss":
		return 0
	var result_value: Variant = _own.get("result", {})
	if not result_value is Dictionary:
		return 0
	var result: Dictionary = result_value
	if bool(result.get("player_wins", false)):
		return EconomyService.boss_win_reward(_round)
	return EconomyService.boss_loss_reward(_round, int(result.get("enemy_hp_current", 0)), maxi(1, int(result.get("enemy_hp_max", 1))))


func _reason_text(rank: int) -> String:
	var english := LocaleManager.get_locale().begins_with("en")
	if _damage_board != null:
		return ("Damage #%d" if english else "伤害第 %d 名") % (rank + 1)
	return ("Lane clear #%d" if english else "清路第 %d 名") % (rank + 1)


func _refresh_purse(tick: int, animate: bool) -> void:
	if _purse == null:
		return
	if tick < _last_tick:
		# 往回 seek（换观战目标会把进度重放一遍）：静默重算到这一帧，不再跳字。
		_kill_cursor = 0
		_kill_total = 0
		while _kill_cursor < _kill_events.size() and int(_kill_events[_kill_cursor][0]) <= tick:
			_kill_total = int(_kill_events[_kill_cursor][2])
			_kill_cursor += 1
		_purse.set_total(_kill_total)
		_last_tick = tick
		return
	_last_tick = tick
	while _kill_cursor < _kill_events.size() and int(_kill_events[_kill_cursor][0]) <= tick:
		var total := int(_kill_events[_kill_cursor][2])
		var delta := total - _kill_total
		_kill_total = total
		_kill_cursor += 1
		if delta <= 0:
			continue
		if animate:
			_purse.add_kill(delta)
		else:
			_purse.set_total(_purse.total() + delta)


func _layout(has_voice: bool) -> void:
	var size: Vector2 = _feedback.size
	# 左边伤害榜跟原来的单人伤害木牌同一个起点、同一个缩放（BattleCombatFeedback._layout）。
	var factor := clampf(minf(size.x / 1600.0, size.y / 720.0), 0.65, 1.4)
	if _damage_board != null:
		_damage_board.position = Vector2(8, 141) * factor
		_damage_board.scale = Vector2.ONE * factor
	# 右边清路榜接在右上角按钮下面：那列按钮是固定像素，这里也不缩放。
	if _lane_board != null:
		var column_x := size.x - RIGHT_MARGIN - BUTTON_COLUMN_W
		if has_voice:
			_lane_board.position = Vector2(column_x, VOICE_LANE_TOP)
		else:
			_lane_board.position = Vector2(column_x + (BUTTON_COLUMN_W - VIEW_TOGGLE_W) * 0.5, SOLO_LANE_TOP)
	if _purse != null:
		_purse.scale = Vector2.ONE * factor
		_purse.position = Vector2(PURSE_MARGIN, size.y - PURSE_MARGIN - Purse.PURSE_SIZE.y * factor)


func _damage_entries(final_frame: Variant) -> Array:
	var out: Array = []
	var frame: Array = final_frame if final_frame is Array else []
	for slot in 6:
		var e := _identity(slot)
		e["damage"] = int(frame[slot]) if slot < frame.size() else 0
		out.append(e)
	return out


func _lane_entries(tick: int) -> Array:
	var out: Array = []
	for slot in 6:
		var t := int(_clear_ticks[slot]) if slot < _clear_ticks.size() else -1
		if t < 0 or (tick >= 0 and t > tick):
			continue
		var e := _identity(slot)
		# LaneClearBoard 只拿 clear_sec 排先后；帧号同一个时钟，直接当秒数用。
		e["clear_sec"] = float(t)
		out.append(e)
	return out


## 座位的名字 / 头像 / 头像框：自己读本机资料，别人读房间下发的 seat_profiles（AI 座位也有）。
func _identity(slot: int) -> Dictionary:
	var is_self := slot == _local_slot
	var profiles: Dictionary = NetworkService.team_seat_profiles
	var identity: Dictionary = AccountManager.profile if is_self else profiles.get(slot, profiles.get(str(slot), {}))
	var who := str(identity.get("player_name", "")).strip_edges()
	if who.is_empty():
		var states: Array = NetworkService.team_slot_states
		var dummy := slot < states.size() and str(states[slot]) == "dummy"
		who = "AI" if dummy else (("Player %d" if LocaleManager.get_locale().begins_with("en") else "玩家 %d") % (slot + 1))
	return {
		"slot": slot,
		"name": who,
		"avatar": str(identity.get("avatar", "")),
		"frame": str(identity.get("avatar_frame", "")),
		"team": GameConstants.team_of_slot(slot),
	}
