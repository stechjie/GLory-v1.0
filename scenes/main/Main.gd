extends Control

var _menu: Control
var _prep: Control
var _battle: Control
var _reconnect_overlay: CanvasLayer
var _pending_team_menu_action := ""
var _pending_team_room_id := 0
var _pending_public_token := ""
# 离线自测·单位测试模式(officetest):进入前的 team_mode 快照,退出时还原。
var _selftest_prev_team_mode := false

func _ready() -> void:
	DataRegistry.load_all()
	if not NetworkService.match_state_received.is_connected(_on_network_match_state_received):
		NetworkService.match_state_received.connect(_on_network_match_state_received)
	if not NetworkService.session_changed.is_connected(_on_global_session_changed):
		NetworkService.session_changed.connect(_on_global_session_changed)
	if not NetworkService.resume_completed.is_connected(_on_resume_completed):
		NetworkService.resume_completed.connect(_on_resume_completed)
	if not NetworkService.resume_failed.is_connected(_on_resume_failed):
		NetworkService.resume_failed.connect(_on_resume_failed)
	if not NetworkService.team_room_list_received.is_connected(_on_team_room_list_received):
		NetworkService.team_room_list_received.connect(_on_team_room_list_received)
	if not NetworkService.team_room_action_failed.is_connected(_on_team_room_action_failed):
		NetworkService.team_room_action_failed.connect(_on_team_room_action_failed)
	if not NetworkService.public_token_changed.is_connected(_on_public_token_changed):
		NetworkService.public_token_changed.connect(_on_public_token_changed)
	if not TutorialMode.skip_requested.is_connected(_on_tutorial_skip):
		TutorialMode.skip_requested.connect(_on_tutorial_skip)
	_show_language_select()

# --- 断线重连 UI 与恢复落地 --------------------------------------------------

func _on_global_session_changed() -> void:
	if NetworkService.state == NetworkService.SessionState.RECONNECTING:
		_show_reconnect_overlay()
	else:
		_hide_reconnect_overlay()

func _show_reconnect_overlay() -> void:
	if _reconnect_overlay != null and is_instance_valid(_reconnect_overlay):
		return
	# 挂在 root 上：Main._clear() 切界面时不会误删
	_reconnect_overlay = CanvasLayer.new()
	_reconnect_overlay.name = "ReconnectOverlay"
	_reconnect_overlay.layer = 100
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.72)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_reconnect_overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 18)
	center.add_child(box)
	var lbl := Label.new()
	lbl.text = "连接中断，正在重连…" if not LocaleManager.get_locale().begins_with("en") else "Connection lost, reconnecting..."
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 30)
	lbl.add_theme_color_override("font_color", Color(0.95, 0.92, 0.80))
	box.add_child(lbl)
	var cancel := Button.new()
	cancel.text = "取消并返回主菜单" if not LocaleManager.get_locale().begins_with("en") else "Cancel and return to menu"
	cancel.custom_minimum_size = Vector2(260, 48)
	cancel.pressed.connect(_on_reconnect_cancel)
	box.add_child(cancel)
	get_tree().root.add_child(_reconnect_overlay)

func _hide_reconnect_overlay() -> void:
	if _reconnect_overlay != null and is_instance_valid(_reconnect_overlay):
		_reconnect_overlay.queue_free()
	_reconnect_overlay = null

func _on_reconnect_cancel() -> void:
	NetworkService.cancel_reconnect()
	GameState.team_mode = false
	_hide_reconnect_overlay()
	_show_menu()

func _on_resume_completed(payload: Dictionary) -> void:
	_hide_reconnect_overlay()
	GameState.team_mode = true
	# 只有内存里没有对局数据（app 重开导致 GameState 全新）才从磁盘恢复棋盘/备战席；
	# 活着的重连（网络抖动）内存就是最新状态，不能用可能过期的磁盘存档覆盖它。
	if _team_run_state_is_fresh():
		SaveManager.load_run()
	# 服务器权威数值覆盖本地
	GameState.round_index = int(payload.get("round_index", GameState.round_index))
	GameState.team_hp = int(payload.get("team_hp", GameState.team_hp))
	GameState.enemy_team_hp = int(payload.get("enemy_team_hp", GameState.enemy_team_hp))
	GameState.gold = int(payload.get("gold", GameState.gold))
	# 商店按恢复后的当前回合重新滚：旧商店在重连/跨回合后无意义，磁盘存档也可能是空的。
	# 清空后 PrepScreen._ready 会自动 _roll_shop() 出一批新的。
	GameState.clear_shop()
	if str(payload.get("phase", "prep")) == NetworkService.ROOM_LOBBY:
		_show_team3v3_lobby()
		return
	# prep/battle/result 一律落回备战：battle 阶段等本回合 match_state 到达后
	# 由全局处理器直接推进（= 跳过战斗），result 阶段服务器已补发 match_state。
	_show_prep()

func _team_run_state_is_fresh() -> bool:
	for cell in GameState.board_slots:
		if cell != null:
			return false
	for cell in GameState.bench_slots:
		if cell != null:
			return false
	return true

func _on_resume_failed(reason: String) -> void:
	_hide_reconnect_overlay()
	GameState.team_mode = false
	_show_menu()
	if is_instance_valid(_menu) and _menu.has_method("show_room_error"):
		_menu.show_room_error(reason)
	if is_instance_valid(_menu) and _menu.has_method("show_connection_error"):
		_menu.show_connection_error(reason)

func _on_tutorial_skip() -> void:
	# 跳过整段教学：结束教学态，回到主菜单让玩家自己选普通/组队。
	if not TutorialMode.active:
		return
	TutorialMode.finish()
	_show_menu()

func _clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

func _show_language_select() -> void:
	_clear()
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.075)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	bg.z_index = -10

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(420, 0)
	panel.add_theme_constant_override("separation", 18)
	center.add_child(panel)

	var title := Label.new()
	title.text = "Select Language / 选择语言"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(0.96, 0.94, 0.82))
	panel.add_child(title)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	panel.add_child(row)

	var zh_btn := Button.new()
	zh_btn.text = "中文"
	zh_btn.custom_minimum_size = Vector2(150, 54)
	zh_btn.pressed.connect(_select_language.bind("zh"))
	row.add_child(zh_btn)

	var en_btn := Button.new()
	en_btn.text = "English"
	en_btn.custom_minimum_size = Vector2(150, 54)
	en_btn.pressed.connect(_select_language.bind("en"))
	row.add_child(en_btn)

func _select_language(locale: String) -> void:
	LocaleManager.set_locale(locale)
	TutorialMode.start()
	_show_prep()

func _show_menu() -> void:
	_clear()
	# 重连改为手动：主菜单的"游戏重连"按钮（有本地凭证才显示）才连回上一场，
	# 不再一进菜单就偷偷自动连（那会把玩家拽进夹生半状态、按不动开始）。
	_menu = preload("res://scenes/menu/MainMenu.tscn").instantiate()
	_menu.team_host_requested.connect(_on_team_host_requested)
	_menu.team_join_requested.connect(_on_team_join_requested)
	_menu.team_room_create_requested.connect(_on_team_room_create_requested)
	_menu.team_room_join_requested.connect(_on_team_room_join_requested)
	_menu.team_room_list_requested.connect(_on_team_room_list_requested)
	_menu.public_token_generate_requested.connect(_on_public_token_generate_requested)
	_menu.public_token_resume_requested.connect(_on_public_token_resume_requested)
	if not _menu.team_offline_requested.is_connected(_on_team_offline_requested):
		_menu.team_offline_requested.connect(_on_team_offline_requested)
	if not _menu.team_reconnect_requested.is_connected(_on_team_reconnect_requested):
		_menu.team_reconnect_requested.connect(_on_team_reconnect_requested)
	_menu.settings_requested.connect(_show_settings)
	add_child(_menu)

func _on_team_reconnect_requested() -> void:
	# 手动重连：读本地凭证连回上一场，弹重连遮罩，成功落回备战/结果，失败清凭证回菜单
	var rc := SaveManager.load_reconnect()
	var rc_token := str(rc.get("token", ""))
	var rc_address := str(rc.get("address", ""))
	if rc_token.is_empty() or rc_address.is_empty():
		return
	GameState.team_mode = true
	NetworkService.begin_resume_from_disk(rc_token, rc_address)

func _on_team_offline_requested() -> void:
	# 纯离线自测：断开任何联机会话，team_active 保持 false，进大厅走本地槽位。
	# 开始后 BattleScreen 的 `not team_active` 分支会本地算回放，无需服务器。
	NetworkService.disconnect_session()
	_show_team3v3_lobby()

func _show_settings() -> void:
	_clear()
	var settings := preload("res://scenes/menu/SettingsScreen.tscn").instantiate()
	settings.back_requested.connect(_show_menu)
	add_child(settings)

func _show_team3v3_lobby() -> void:
	_clear()
	var lobby := preload("res://scenes/menu/Team3v3Lobby.tscn").instantiate()
	lobby.start_requested.connect(_on_team3v3_start)
	lobby.back_requested.connect(_on_lobby_back)
	lobby.selftest_requested.connect(_show_selftest)
	add_child(lobby)

# 离线自测·单位测试模式(officetest):独立场景,不走备战/回合/存档,
# 返回时还原 team_mode,不在 GameState 留任何痕迹。
func _show_selftest() -> void:
	_clear()
	_selftest_prev_team_mode = GameState.team_mode
	GameState.team_mode = true
	# load() (not preload) so this optional officetest scene never becomes a
	# parse-time dependency of Main on a cold boot before its .import exists.
	var screen: Node = (load("res://officetest/OfficeTestScreen.tscn") as PackedScene).instantiate()
	screen.back_requested.connect(_on_selftest_back)
	add_child(screen)

func _on_selftest_back() -> void:
	GameState.team_mode = _selftest_prev_team_mode
	_show_team3v3_lobby()

func _on_lobby_back() -> void:
	NetworkService.disconnect_session()
	_show_menu()

func _show_prep() -> void:
	# 保底：对局已结束（最终局打完）就不再进备战，直接游戏结束界面。
	# 堵住任何"结束后又被导航回备战"的残留路径（配合服务器封顶/不再开回合）。
	if GameState.team_mode and GameState.final_battle_complete:
		_show_game_over()
		return
	_clear()
	_prep = preload("res://scenes/prep/PrepScreen.tscn").instantiate()
	_prep.battle_requested.connect(_on_battle_requested)
	add_child(_prep)
	SaveManager.save_run()

func _show_battle(battle_scene: PackedScene = null) -> void:
	_clear()
	var scene := battle_scene if battle_scene != null else preload("res://scenes/battle/BattleScreen.tscn")
	_battle = scene.instantiate()
	_battle.battle_finished.connect(_on_battle_finished)
	add_child(_battle)

func _show_game_over() -> void:
	# 对局结束：重连凭证作废，避免下次启动误恢复到已结束的房间
	SaveManager.clear_reconnect()
	_clear()
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.07)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	bg.z_index = -10

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(420, 0)
	panel.add_theme_constant_override("separation", 12)
	center.add_child(panel)

	var title := Label.new()
	title.text = _game_over_title()
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(0.96, 0.92, 0.78))
	panel.add_child(title)

	var body := Label.new()
	body.text = _game_over_body()
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(420, 90)
	body.add_theme_color_override("font_color", Color(0.86, 0.9, 0.9))
	panel.add_child(body)

	var menu_btn := Button.new()
	menu_btn.text = tr("gameover_back")
	menu_btn.custom_minimum_size = Vector2(180, 40)
	menu_btn.pressed.connect(_on_return_menu_requested)
	panel.add_child(menu_btn)

func _on_team_host_requested() -> void:
	# Debug-only local host. Production Android clients connect to the VPS.
	if NetworkService.team_host(NetworkService.DEFAULT_PORT):
		_show_team3v3_lobby()
	elif is_instance_valid(_menu) and _menu.has_method("show_connection_error"):
		_menu.show_connection_error(NetworkService.last_error)

func _on_team_join_requested(address: String = NetworkService.DEFAULT_HOST) -> void:
	# Client-side production path: connect to the dedicated ENet server.
	# 开始新游戏 = 放弃上一场：清本地重连凭证，并让服务器把旧座位交给 AI
	# （若旧房间还有其他玩家；没人就靠超时自清）。之后从此连不回旧局。
	var rc := SaveManager.load_reconnect()
	var abandon_token := str(rc.get("token", ""))
	SaveManager.clear_reconnect()
	if not NetworkService.team_join(address, NetworkService.DEFAULT_PORT):
		if is_instance_valid(_menu) and _menu.has_method("show_connection_error"):
			_menu.show_connection_error(NetworkService.last_error)
		return
	if is_instance_valid(_menu) and _menu.has_method("show_connecting"):
		_menu.show_connecting()
	# 记下要放弃的旧座位 token，连上后由 NetworkService 发 abandon
	NetworkService.pending_abandon_token = abandon_token
	if not NetworkService.session_changed.is_connected(_on_pending_join_session_changed):
		NetworkService.session_changed.connect(_on_pending_join_session_changed)

func _on_pending_join_session_changed() -> void:
	match NetworkService.state:
		NetworkService.SessionState.READY:
			NetworkService.session_changed.disconnect(_on_pending_join_session_changed)
			_show_team3v3_lobby()
		NetworkService.SessionState.FAILED, NetworkService.SessionState.OFFLINE:
			NetworkService.session_changed.disconnect(_on_pending_join_session_changed)
			if is_instance_valid(_menu) and _menu.has_method("show_connection_error"):
				_menu.show_connection_error(NetworkService.last_error if NetworkService.last_error != "" else "连接失败")

func _on_team_room_list_requested() -> void:
	_start_team_menu_action("list")

func _on_team_room_create_requested() -> void:
	_start_team_menu_action("create")

func _on_team_room_join_requested(room_id: int) -> void:
	_pending_team_room_id = room_id
	_start_team_menu_action("join")

func _on_public_token_generate_requested() -> void:
	_start_team_menu_action("token")

func _on_public_token_resume_requested(token_id: String) -> void:
	_pending_public_token = token_id
	_start_team_menu_action("resume_public")

func _start_team_menu_action(action: String) -> void:
	_pending_team_menu_action = action
	if NetworkService.team_active and NetworkService.state == NetworkService.SessionState.READY and NetworkService.team_local_slot < 0:
		_run_pending_team_menu_action()
		return
	if NetworkService.team_active and NetworkService.team_local_slot >= 0:
		NetworkService.disconnect_session()
	if not NetworkService.team_join(NetworkService.DEFAULT_HOST, NetworkService.DEFAULT_PORT):
		if is_instance_valid(_menu) and _menu.has_method("show_connection_error"):
			_menu.show_connection_error(NetworkService.last_error)
		return
	if is_instance_valid(_menu) and _menu.has_method("show_connecting"):
		_menu.show_connecting()
	if not NetworkService.session_changed.is_connected(_on_pending_team_menu_session_changed):
		NetworkService.session_changed.connect(_on_pending_team_menu_session_changed)

func _on_pending_team_menu_session_changed() -> void:
	match NetworkService.state:
		NetworkService.SessionState.READY:
			if NetworkService.session_changed.is_connected(_on_pending_team_menu_session_changed):
				NetworkService.session_changed.disconnect(_on_pending_team_menu_session_changed)
			_run_pending_team_menu_action()
		NetworkService.SessionState.FAILED, NetworkService.SessionState.OFFLINE:
			if NetworkService.session_changed.is_connected(_on_pending_team_menu_session_changed):
				NetworkService.session_changed.disconnect(_on_pending_team_menu_session_changed)
			if is_instance_valid(_menu) and _menu.has_method("show_connection_error"):
				_menu.show_connection_error(NetworkService.last_error if NetworkService.last_error != "" else "连接失败")

func _run_pending_team_menu_action() -> void:
	match _pending_team_menu_action:
		"list":
			NetworkService.team_request_room_list()
		"create":
			_wait_for_room_join()
			NetworkService.team_request_create_room()
		"join":
			_wait_for_room_join()
			NetworkService.team_request_join_room(_pending_team_room_id)
		"token":
			NetworkService.team_request_public_token()
		"resume_public":
			NetworkService.team_request_public_resume(_pending_public_token)

func _wait_for_room_join() -> void:
	if not NetworkService.team_lobby_changed.is_connected(_on_pending_room_joined):
		NetworkService.team_lobby_changed.connect(_on_pending_room_joined)

func _on_pending_room_joined() -> void:
	if NetworkService.team_local_slot < 0:
		return
	if NetworkService.team_lobby_changed.is_connected(_on_pending_room_joined):
		NetworkService.team_lobby_changed.disconnect(_on_pending_room_joined)
	_pending_team_menu_action = ""
	_show_team3v3_lobby()

func _on_team_room_list_received(rooms: Array) -> void:
	if is_instance_valid(_menu) and _menu.has_method("show_room_list"):
		_menu.show_room_list(rooms)

func _on_team_room_action_failed(reason: String) -> void:
	if NetworkService.team_lobby_changed.is_connected(_on_pending_room_joined):
		NetworkService.team_lobby_changed.disconnect(_on_pending_room_joined)
	if is_instance_valid(_menu) and _menu.has_method("show_room_error"):
		_menu.show_room_error(reason)

func _on_public_token_changed(token_id: String) -> void:
	if is_instance_valid(_menu) and _menu.has_method("show_public_token"):
		_menu.show_public_token(token_id)

func _on_team3v3_start() -> void:
	SaveManager.new_run()
	GameState.team_mode = true
	GameState.team_hp = GameState.START_FORMATION_HP
	GameState.enemy_team_hp = GameState.START_FORMATION_HP
	if NetworkService.shared_seed == 0:
		NetworkService.shared_seed = randi()
	NetworkService.team_begin_round()
	_show_prep()

func _on_team_battle_finished(result: Dictionary) -> void:
	if NetworkService.team_active and not NetworkService.is_host:
		await _finish_server_authoritative_team_battle(result)
		return
	var completed_round := GameState.round_index
	var kind := str(result.get("kind", "pve"))
	var player_wins := bool(result.get("player_wins", false))
	var surviving_enemies := int(result.get("enemy_alive", result.get("enemy_count", 1)))
	# PvP uses a canonical arrangement (team A = "player"). If I'm on team B,
	# the outcome is mirrored: their win is my loss, and the survivors that hurt
	# my team are team A's (the "player" side).
	# 同款视角反转也在 BattleUI._local_player_wins（战斗字幕/总结显示用），
	# 改这里的条件时必须同步那边。
	if kind == "pvp" and NetworkService.team_active and NetworkService.team_local_slot >= 3:
		player_wins = not player_wins
		surviving_enemies = int(result.get("player_alive", 0))
	# Host stamps BOTH teams' damage this round into the replay result so every
	# client can drive its own team HP and the rival team HP deterministically.
	var self_dmg := int(result.get("team_damage_self", -1))
	var rival_dmg := int(result.get("team_damage_rival", -1))
	if self_dmg >= 0:
		GameState.team_hp = maxi(0, GameState.team_hp - self_dmg)
		GameState.enemy_team_hp = maxi(0, GameState.enemy_team_hp - maxi(0, rival_dmg))
		# Formation Heal (法阵回春): host-authoritative regen, after damage, only if
		# still alive, capped at the starting HP.
		var heal_self := int(result.get("team_heal_self", 0))
		var heal_rival := int(result.get("team_heal_rival", 0))
		if GameState.team_hp > 0 and heal_self > 0:
			GameState.team_hp = mini(GameState.START_FORMATION_HP, GameState.team_hp + heal_self)
		if GameState.enemy_team_hp > 0 and heal_rival > 0:
			GameState.enemy_team_hp = mini(GameState.START_FORMATION_HP, GameState.enemy_team_hp + heal_rival)
	elif not player_wins:
		# Legacy fallback: only my team's HP, damage = surviving enemy count.
		GameState.team_hp = maxi(0, GameState.team_hp - maxi(1, surviving_enemies))
	# Economy: kill gold + base income, plus the local player's post-battle money
	# treasures (per-player gold, so applied locally is correct).
	GameState.gold += _team_local_kill_gold(result) + int(result.get("bonus_gold", 0)) + 5
	if GameState.owned_treasures.has("money_lucky_envelope"):
		GameState.gold += 1 + (randi() % 3)
	if TreasureService.has_linkage("link_money_magic"):
		GameState.gold += 5 + (randi() % 3)
		if randf() < 0.10:
			GameState.gold += 10
	var team_interest := EconomyService.base_interest(GameState.gold)
	if GameState.owned_treasures.has("money_compound"):
		team_interest += int(floor(float(GameState.gold) * 0.05))
	GameState.gold += team_interest
	_apply_post_battle_unit_outcomes(result)
	GameState.battle_history.append(result)
	if kind == "pve":
		GameState.pve_completed += 1
	elif kind == "boss":
		GameState.boss_completed += 1
	GameState.round_index = mini(GameState.round_index + 1, GameState.FINAL_ROUND)
	GameState.reset_shop_refreshes()
	GameState.clear_shop()
	GameState.clear_mercenaries()
	# (2) End the run the moment either team's formation HP reaches 0 (or round 21).
	var run_over := GameState.team_hp <= 0 or GameState.enemy_team_hp <= 0 or completed_round >= GameState.FINAL_ROUND
	if run_over:
		if completed_round >= GameState.FINAL_ROUND:
			GameState.final_battle_complete = true
		if GameState.team_hp <= 0 and GameState.enemy_team_hp <= 0:
			GameState.team_run_won = player_wins if kind == "pvp" else GameState.team_hp >= GameState.enemy_team_hp
		elif GameState.team_hp <= 0:
			GameState.team_run_won = false
		elif GameState.enemy_team_hp <= 0:
			GameState.team_run_won = true
		else:
			# Reached round 21 with both alive: higher remaining HP wins.
			GameState.team_run_won = GameState.team_hp >= GameState.enemy_team_hp
		SaveManager.save_run()
		_show_game_over()
		return
	NetworkService.team_begin_round()
	_start_treasure_for_completed_round(completed_round)
	_show_prep()

func _finish_server_authoritative_team_battle(result: Dictionary) -> void:
	if result.has("error"):
		print("[NET] team battle failed reason=%s" % str(result.get("error", "")))
		NetworkService.disconnect_session()
		_show_menu()
		return
	var completed_round := GameState.round_index
	var waited := 0.0
	while not _has_team_match_state(completed_round) and waited < NetworkService.REPLAY_TIMEOUT_SEC:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	if not _has_team_match_state(completed_round):
		# 正在重连：不要拆会话回菜单，恢复流程会接管导航（resume 后落回备战）
		if NetworkService.state == NetworkService.SessionState.RECONNECTING:
			return
		print("[NET] match_state timeout round=%d" % completed_round)
		NetworkService.disconnect_session()
		_show_menu()
		return
	var state_payload := NetworkService.latest_match_state.duplicate(true)
	_apply_team_match_state_payload(state_payload, result)
	print("[NET] client applied match_state round=%d next=%d gold=%d hp=%d" % [completed_round, GameState.round_index, GameState.gold, GameState.team_hp])
	if bool(state_payload.get("run_over", false)):
		SaveManager.save_run()
		_show_game_over()
		return
	NetworkService.team_begin_round()
	_show_prep()

func _has_team_match_state(completed_round: int) -> bool:
	return not NetworkService.latest_match_state.is_empty() and int(NetworkService.latest_match_state.get("completed_round", -1)) == completed_round and int(NetworkService.latest_match_state.get("protocol", -1)) == NetworkConfig.NETWORK_PROTOCOL_VERSION

func _apply_team_match_state_payload(state_payload: Dictionary, result: Dictionary = {}) -> void:
	if state_payload.is_empty():
		return
	GameState.team_hp = int(state_payload.get("team_hp", GameState.team_hp))
	GameState.enemy_team_hp = int(state_payload.get("enemy_team_hp", GameState.enemy_team_hp))
	GameState.gold = int(state_payload.get("gold", GameState.gold))
	GameState.pve_completed = int(state_payload.get("pve_completed", GameState.pve_completed))
	GameState.boss_completed = int(state_payload.get("boss_completed", GameState.boss_completed))
	GameState.final_battle_complete = bool(state_payload.get("final_battle_complete", GameState.final_battle_complete))
	GameState.team_run_won = bool(state_payload.get("team_run_won", GameState.team_run_won))
	if not result.is_empty():
		_apply_post_battle_unit_outcomes(result)
		GameState.battle_history.append(result)
	GameState.round_index = int(state_payload.get("round_index", GameState.round_index))
	GameState.pending_treasure = (state_payload.get("pending_treasure", {"active": false, "round": 0, "candidates": [], "refresh_index": 0}) as Dictionary).duplicate(true)
	GameState.reset_shop_refreshes()
	GameState.clear_shop()
	GameState.clear_mercenaries()
	SaveManager.save_run()

func _team_local_kill_gold(result: Dictionary) -> int:
	var slot := NetworkService.team_local_slot if NetworkService.team_active else 0
	if slot < 0:
		slot = 0
	var by_slot: Dictionary = result.get("kill_gold_by_slot", {})
	return int(by_slot.get(slot, by_slot.get(str(slot), 0)))

func _on_battle_requested() -> void:
	var loaded_battle_scene: PackedScene = null
	if _prep != null and _prep.has_method("take_loaded_battle_scene"):
		loaded_battle_scene = _prep.call("take_loaded_battle_scene") as PackedScene
	if GameState.tutorial_mode:
		if TutorialMode.begin_battle():
			_show_battle(loaded_battle_scene)
		return
	# 3v3 gates on its own per-round ready sync (team_round_start); board
	# collection still happens in the battle screen.
	_show_battle(loaded_battle_scene)

func _on_return_menu_requested() -> void:
	SaveManager.save_run()
	NetworkService.disconnect_session()
	_show_menu()

func _on_battle_finished(result: Dictionary = {}) -> void:
	if GameState.tutorial_mode:
		TutorialMode.after_battle(result)
		if TutorialMode.step == TutorialMode.Step.DONE:
			TutorialMode.finish()
			_show_game_over()
			return
		_show_prep()
		return
	if GameState.team_mode:
		_on_team_battle_finished(result)
		return

func _game_over_title() -> String:
	if GameState.team_mode:
		return tr("gameover_final_win") if GameState.team_run_won else tr("gameover_final_lost")
	if GameState.player_formation_hp <= 0:
		return tr("gameover_lost")
	if GameState.enemy_formation_hp <= 0:
		return tr("gameover_win")
	if GameState.final_battle_complete:
		var last := _last_battle_result()
		if bool(last.get("player_wins", false)):
			return tr("gameover_final_win")
		return tr("gameover_final_lost")
	return tr("gameover_lost")

func _game_over_body() -> String:
	if GameState.team_mode:
		var team_result := tr("gameover_result_win") if GameState.team_run_won else tr("gameover_result_lose")
		return tr("gameover_team_body") % [GameState.round_index, team_result, GameState.team_hp]
	var last := _last_battle_result()
	var result_text := tr("gameover_result_win") if bool(last.get("player_wins", false)) else tr("gameover_result_lose")
	return tr("gameover_body") % [
		GameState.round_index,
		result_text,
		GameState.player_formation_hp,
		GameState.enemy_formation_hp,
	]

func _last_battle_result() -> Dictionary:
	if GameState.battle_history.is_empty():
		return {}
	var last = GameState.battle_history.back()
	if typeof(last) == TYPE_DICTIONARY:
		return last
	return {}

func _on_network_match_state_received(state_payload: Dictionary) -> void:
	if _battle != null and is_instance_valid(_battle):
		return
	# 内嵌服务器会在本回合刚就绪时立刻把战后 match_state 发回，此刻玩家可能还在
	# 备战界面异步打包战斗（战斗场景尚未创建）。这时绝不能提前应用——否则
	# round_index 会在进战斗前就 +1，既跳了回合，又让备战的
	# _wait_for_team_match_state 等待条件永远错配、卡住进不去战斗。payload 已存在
	# NetworkService.latest_match_state 里，战斗播完后 _finish_server_authoritative_team_battle
	# 会统一应用。
	if _prep != null and is_instance_valid(_prep) and _prep.has_method("is_committing_to_battle") and bool(_prep.call("is_committing_to_battle")):
		return
	if GameState.team_mode:
		_apply_team_match_state_payload(state_payload)
		if _prep != null and is_instance_valid(_prep) and _prep.has_method("_refresh_all"):
			_prep.call_deferred("_refresh_all")

func _apply_post_battle_unit_outcomes(result: Dictionary) -> void:
	if not result.has("player_survivor_slots"):
		return
	var survivor_slots := {}
	for slot in result.get("player_survivor_slots", []):
		survivor_slots[int(slot)] = true
	for i in GameState.board_slots.size():
		var cell = GameState.board_slots[i]
		if cell == null or str(cell.get("def", {}).get("skill_id", "")) != "unique_king_growth":
			continue
		if survivor_slots.has(i):
			_grow_human_king(cell)
		else:
			GameState.board_slots[i] = null

func _grow_human_king(cell: Dictionary) -> void:
	var d: Dictionary = cell.get("def", {})
	var mul := 1.0 + float(d.get("post_battle_all_stat_growth", 0.20))
	for key in ["hp", "atk", "def"]:
		if d.has(key):
			d[key] = maxi(1, int(round(float(d[key]) * mul)))
	for key in ["attack_speed", "move_speed", "crit", "crit_dmg", "range"]:
		if d.has(key):
			d[key] = float(d[key]) * mul
	cell.def = d
	cell.king_growth_stacks = int(cell.get("king_growth_stacks", 0)) + 1

func _start_treasure_for_completed_round(completed_round: int) -> void:
	if bool(GameState.pending_treasure.get("active", false)):
		return
	if completed_round in GameState.claimed_treasure_rounds:
		return
	if not RoundService.is_treasure_round(completed_round) or not TreasureService.can_draw():
		return
	var candidates := TreasureService.roll_candidates(3)
	if candidates.is_empty():
		return
	GameState.pending_treasure = {
		"active": true,
		"round": completed_round,
		"candidates": candidates,
		"refresh_index": 0,
	}
