extends "res://scenes/battle/BattleVfx.gd"

# 结算水晶演出的编排住在这一层（而不是 BattleArena），因为让棋子发射后消失需要
# _visual_id() / _battle_3d_models / _unit_nodes，那几个都定义在 BattleRenderer，
# 在继承链上比 BattleArena 更低，BattleArena 调不到。水晶生成、飘带、血条这些
# 底层构件仍留在 BattleArena。

func _finish_simulation() -> void:
	if _return_emitted:
		return
	_finished = true
	# 本地模拟即结果。组队联机不走这里——那条路播的是服务器下发的权威 replay，
	# 结算取 match_state（见 Main._on_network_match_state_received）。
	_result = BattleSim.result_from_state(_state)
	_refresh_summary()
	_emit_finished()

func _emit_finished() -> void:
	if _return_emitted:
		return
	_return_emitted = true
	_stop_battle_music()
	await _play_crystal_attack_sequence(_result)
	_show_result_overlay()
	await get_tree().create_timer(_result_linger_seconds()).timeout
	battle_finished.emit(_result if not _result.is_empty() else BattleSim.result_from_state(_state))

# 结算画面停留多久。
#
# **取「面板展示时长」与「胜负音实际时长」里更长的那个。**
#
# 9.17 反馈第 3 条原文：「回合战斗结束，bgm 未播放完毕，就进入其他界面的问题，
# 现改为至少要等待胜利或者失败的 bgm 播放完毕后才能其他界面。」
#
# `battle_finished` 一发出去，Main 就会释放整个战斗场景并跳到下一页。胜负音
# 虽然挂在 SfxService 的 root 池里、不会被当场掐断，但「界面已经换了、音乐还在响」
# 正是玩家反馈的那件事。所以这里按**素材的真实长度**算，不写死一个「够长」的常数：
# 以后换了更长的胜负音，这条会自动跟上（写死的数只会静默失效）。
const RESULT_SOUND_MARGIN_SEC := 0.25

func _result_linger_seconds() -> float:
	var result := _result if not _result.is_empty() else BattleSim.result_from_state(_state)
	var cue := SfxService.CUE_BATTLE_VICTORY if _local_player_wins(result) else SfxService.CUE_BATTLE_DEFEAT
	return maxf(RESULT_DISPLAY_SECONDS, SfxService.cue_length(cue) + RESULT_SOUND_MARGIN_SEC)

func _skip_animation() -> void:
	if _return_emitted:
		return
	while not bool(_state.get("finished", false)):
		BattleSim.step_state(_state)
	_finish_simulation()

func _show_result_overlay() -> void:
	if _result_overlay_lbl == null:
		return
	var result := _result if not _result.is_empty() else BattleSim.result_from_state(_state)
	# 3v3 PvP 的 player_wins 是 A 队视角，B 队显示前必须换成本地视角（helper 在 BattleUI）。
	var player_wins := _local_player_wins(result)
	_result_overlay_lbl.text = tr("battle_result_win") if player_wins else tr("battle_result_lose")
	_result_overlay_lbl.add_theme_font_size_override("font_size", 58)
	_result_overlay_lbl.add_theme_color_override("font_color", Color(1.0, 0.94, 0.62) if player_wins else Color(0.95, 0.38, 0.34))
	_result_overlay_lbl.visible = true
	# 9.17：胜负音。
	#
	# 这里是**胜负显示的唯一收口点**：replay 那条路（BattleScreen._finish_replay）
	# 和本地模拟那条路（_emit_finished）最后都走到这里，而 _return_emitted 保证了
	# 每场只走一次。挂在别处会重复 —— `BattleRenderer.play_victory_finish()`
	# 名字像胜利信号，实际上 BattleScreen 无条件调它，赢了输了都调，不能挂。
	#
	# 播放器在 SfxService 的 root 池里，不是本场景的子节点：结算之后
	# Main._clear() 会立刻释放整个战斗场景，挂本节点上会被当场掐断。
	#
	# 平局（双杀 / 超时战力相等，result.is_draw）走 _local_player_wins 的结果 ——
	# 素材只给了「胜利」和「失败」两条，不为平局另造一个。
	SfxService.play(SfxService.CUE_BATTLE_VICTORY if player_wins else SfxService.CUE_BATTLE_DEFEAT)


# --- 结算水晶演出 -----------------------------------------------------------

# 返回挨打的那座水晶属于哪一队；-1 表示这一局不演出。
func _crystal_demo_losing_team(result: Dictionary) -> int:
	# 第 21 回合直接结算整场胜负，不做单回合的水晶演出。
	if GameState.round_index >= GameState.FINAL_ROUND:
		return -1
	# 双方同归于尽：没有棋子活着去攻击，没得演。
	if int(result.get("player_alive", 0)) <= 0 and int(result.get("enemy_alive", 0)) <= 0:
		return -1
	var player_wins := bool(result.get("player_wins", false))
	if str(result.get("kind", _state.get("kind", ""))) == "pvp":
		# PvP 的 replay 是 canonical 的："player" 恒指红队（槽位 0-2），跟观看者无关，
		# 所以这里算出来的是绝对队伍，六个客户端得到同一个答案。
		return GameConstants.TEAM_BLUE if player_wins else GameConstants.TEAM_RED
	# PvE / Boss：敌方是怪物，没有水晶也不扣任何队伍血量，所以只有我方被打穿时才演。
	if player_wins:
		return -1
	return GameConstants.team_of_slot(NetworkService.team_local_slot)

# 赢的那一方才发起攻击。战斗打到全灭为止，所以另一方必然没有存活单位。
# 伤害公式（BattleSimulator.stamp_team_round_damages / _team_replay_self_damage）
# 就是「赢方存活数」，所以一个存活棋子发一条飘带、一条扣 1 点，加起来正好等于
# 结算面板显示的伤害，不需要另外凑数。
func _crystal_attackers(player_wins: bool) -> Array:
	var attacker_team := "player" if player_wins else "enemy"
	var out: Array = []
	for fighter in (_state.get(attacker_team, []) as Array):
		if typeof(fighter) != TYPE_DICTIONARY or not bool(fighter.get("alive", false)):
			continue
		out.append(fighter)
	return out

func _crystal_attacker_muzzle(fighter: Dictionary) -> Vector3:
	var id := _visual_id(fighter)
	var cast_anchor: Node3D = _unit_actor_registry.get_anchor(id, "CastAnchor")
	if cast_anchor != null:
		return cast_anchor.global_position
	var model: Node3D = _unit_actor_registry.get_actor(id)
	if model != null and is_instance_valid(model):
		return model.global_position + Vector3(0.0, 0.34, 0.0)
	var world_pos := _sim_to_world_pos(fighter.get("pos", Vector2.ZERO) as Vector2)
	return Vector3(world_pos.x, battle_unit_y_offset + 0.34, world_pos.z)

# 棋子发射后就此退场：快速淡出 + 轻微上浮，像被抽走。3D 模型和 2D 单位控件
# （血条、名字）都要一起收掉，否则会留下一个没有身体的血条。
func _vanish_crystal_attacker(fighter: Dictionary) -> void:
	var id := _visual_id(fighter)
	var model: Node3D = _battle_3d_models.get(id)
	if model != null and is_instance_valid(model):
		_battle_3d_models.erase(id)
		_unit_actor_registry.unregister_actor(id)
		var lift := create_tween()
		lift.tween_property(model, "position:y", model.position.y + 0.45, CRYSTAL_UNIT_VANISH_SEC)
		lift.parallel().tween_property(model, "scale", model.scale * 0.05, CRYSTAL_UNIT_VANISH_SEC).set_ease(Tween.EASE_IN)
		lift.tween_callback(model.queue_free)
	var unit_node: Control = _unit_nodes.get(id)
	if unit_node != null and is_instance_valid(unit_node):
		_unit_nodes.erase(id)
		var fade := create_tween()
		fade.tween_property(unit_node, "modulate:a", 0.0, CRYSTAL_UNIT_VANISH_SEC)
		fade.tween_callback(unit_node.queue_free)

func _play_crystal_attack_sequence(result: Dictionary) -> void:
	if _crystal_attack_running or _battle_3d_world == null:
		return
	var losing_team := _crystal_demo_losing_team(result)
	if losing_team < 0:
		return
	var player_wins := bool(result.get("player_wins", false))
	var attackers := _crystal_attackers(player_wins)
	if attackers.is_empty():
		return
	_crystal_attack_running = true
	await get_tree().create_timer(0.22).timeout

	# --- 召唤：从底部长出来，落位时回弹一下 ---
	var is_red_crystal := losing_team == GameConstants.TEAM_RED
	var target := _spawn_demo_crystal(losing_team, 1.0)
	if target == null:
		_crystal_attack_running = false
		return
	var crystal_color := GameConstants.team_color(losing_team)
	var settled_position := _demo_crystal_base_position
	var settled_scale := target.scale
	# 战场没有 3D 地面（BATTLE_USE_3D_ARENA 为 false，地面是背后那张 2.5D 背景图），
	# 所以"从地下升上来"不能靠往下挪 Y——挪下去也不会被遮住。改成从底部长出来：
	# 缩放和位置用同一条曲线同步插值，底面就一直钉在地面那个点上。
	target.scale = Vector3.ZERO
	target.position = BATTLE_CRYSTAL_DEMO_POSITION
	_make_crystal_summon_ring(crystal_color)
	var rise := create_tween()
	rise.tween_property(target, "scale", settled_scale, CRYSTAL_RISE_SEC).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	rise.parallel().tween_property(target, "position", settled_position, CRYSTAL_RISE_SEC).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# 等计时器而不是等 tween.finished：tween 绑在本节点上，玩家中途退出战斗时会被
	# 连带 kill，那样 await 永远不会返回，_finish_replay 就卡住不发 battle_finished。
	await get_tree().create_timer(CRYSTAL_RISE_SEC).timeout
	if not is_inside_tree():
		return
	_demo_crystal_floating = true

	# 起始血量由「战后血量 + 飘带数」倒推，而不是直接读演出前的血量：伤害恒等于
	# 赢方存活数，两者本该相同，但倒推能保证扣完最后一发之后的数字一定等于结算
	# 面板和下一回合用的那个值——终点对齐比起点对齐重要。
	# （战斗场景还在时 match_state 不会被应用，见 Main._on_network_match_state_received，
	#  所以此刻 GameState 里的血量仍是战前值。）
	var hp_max := int(GameState.START_FORMATION_HP)
	var hp_after := int(round(_crystal_hp_ratio(losing_team, result) * float(hp_max)))
	var hp_before: int = clampi(hp_after + attackers.size(), 0, hp_max)
	_make_crystal_hp_label(hp_before, hp_max, crystal_color)
	await get_tree().create_timer(0.18).timeout
	if not is_inside_tree():
		return

	# --- 攻击：一发一发打。总时长恒定，人多就变连射。 ---
	# 飘带用赢方的队伍色：红队赢 -> 红飘带打蓝水晶，反之亦然。
	var ribbon_color := GameConstants.team_color(GameConstants.TEAM_BLUE if is_red_crystal else GameConstants.TEAM_RED)
	var gap: float = maxf(CRYSTAL_VOLLEY_MIN_GAP_SEC, CRYSTAL_VOLLEY_BUDGET_SEC / float(attackers.size()))
	var impact_point := target.global_position + Vector3(0.0, 0.35, 0.0)
	# 9.17 第二批：己方法阵受击音（**循环**）。
	#
	# 判据 = 「挨打的这座水晶是不是我们自己的」。`losing_team` 用的是与
	# `_crystal_demo_losing_team()` 同一条队伍口径（PvE 下我方被打穿才演、
	# 返回的就是我方；PvP 下可能是红也可能是蓝），所以这里再比一次本地队即可。
	#
	# 循环而不是逐发播：`gap` 很密（人多时是连射），逐发播会互相切断成
	# 一串断音；而这条音的语义就是「正在被打」—— 起于第一发、止于末发。
	var our_crystal := losing_team == GameConstants.team_of_slot(NetworkService.team_local_slot)
	var hit_loop := our_crystal and SfxService.start_loop(SfxService.CUE_FORMATION_HIT)
	# 9.18：敌方法阵受击（我方打敌水晶）循环音。判据取反于己方那条 —— 被攻击的是
	# 敌方水晶 = 我方棋子在输出，仍属「自身棋子造成」，符合用户的战斗音效约束。
	var enemy_crystal := not our_crystal
	var enemy_hit_loop := enemy_crystal and SfxService.start_loop(SfxService.CUE_ENEMY_FORMATION_HIT)
	for fighter in attackers:
		var muzzle := _crystal_attacker_muzzle(fighter)
		_make_crystal_attack_ribbon(muzzle, impact_point, ribbon_color, _apply_crystal_hit.bind(is_red_crystal))
		_vanish_crystal_attacker(fighter)
		await get_tree().create_timer(gap).timeout
		if not is_inside_tree():
			# 中途退出战斗也必须停循环音：播放器挂在 root 下，
			# 场景没了它照样在响（这正是它当初挂 root 的目的）。
			if hit_loop or enemy_hit_loop:
				SfxService.stop_loop()
			return
	# 等最后一发飞完并结算。
	await get_tree().create_timer(CRYSTAL_RIBBON_FLIGHT_SEC + 0.35).timeout
	# 攻击演完了就停 —— 后面的碎裂/淡出是「收场」，不再算受击。
	if hit_loop or enemy_hit_loop:
		SfxService.stop_loop()
	if not is_inside_tree():
		return

	# --- 收场：打穿了碎裂，没打穿就淡出（水晶只为这段演出存在） ---
	_demo_crystal_floating = false
	var outro := create_tween()
	var outro_sec := CRYSTAL_FADE_SEC
	if _crystal_hp_current <= 0:
		outro_sec = CRYSTAL_SHATTER_PUNCH_SEC + CRYSTAL_SHATTER_SEC
		outro.tween_property(target, "scale", target.scale * 1.16, CRYSTAL_SHATTER_PUNCH_SEC).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		outro.tween_property(target, "scale", Vector3.ZERO, CRYSTAL_SHATTER_SEC).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	else:
		outro.tween_property(target, "position", settled_position + Vector3(0.0, 0.35, 0.0), CRYSTAL_FADE_SEC).set_trans(Tween.TRANS_SINE)
		outro.parallel().tween_property(target, "scale", Vector3.ZERO, CRYSTAL_FADE_SEC).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	if _crystal_hp_label != null and is_instance_valid(_crystal_hp_label):
		outro.parallel().tween_property(_crystal_hp_label, "modulate:a", 0.0, outro_sec)
	await get_tree().create_timer(outro_sec).timeout
	if not is_inside_tree():
		return
	_clear_crystal_hp_label()
	target.queue_free()
	_demo_crystal = null
	_crystal_attack_running = false
