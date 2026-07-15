extends "res://scenes/battle/BattleVfx.gd"

func _finish_simulation() -> void:
	if _return_emitted:
		return
	_finished = true
	var calculated := BattleSim.result_from_state(_state)
	if _uses_authoritative_online_result():
		if NetworkService.is_host:
			_result = calculated
			NetworkService.send_pvp_result(_result)
		elif not NetworkService.latest_pvp_result.is_empty():
			_result = NetworkService.latest_pvp_result.duplicate(true)
		else:
			_waiting_authoritative_result = true
			_pvp_result_request_elapsed = PVP_RESULT_REQUEST_INTERVAL_SEC
			_result = {}
			_state.log.append(tr("log_wait_authoritative"))
			NetworkService.request_pvp_result()
	else:
		_result = calculated
	_refresh_summary()
	if not _waiting_authoritative_result:
		_emit_finished()

func _on_pvp_result_received(result: Dictionary) -> void:
	if not _uses_authoritative_online_result() or _return_emitted:
		return
	_waiting_authoritative_result = false
	_pvp_result_request_elapsed = 0.0
	_result = result.duplicate(true)
	_finished = true
	_refresh_summary()
	_refresh_visuals()
	_emit_finished()

func _poll_authoritative_result(delta: float) -> void:
	if not NetworkService.latest_pvp_result.is_empty():
		_on_pvp_result_received(NetworkService.latest_pvp_result.duplicate(true))
		return
	_pvp_result_request_elapsed += delta
	if _pvp_result_request_elapsed >= PVP_RESULT_REQUEST_INTERVAL_SEC:
		_pvp_result_request_elapsed = 0.0
		NetworkService.request_pvp_result()
		_refresh_summary()

func _emit_finished() -> void:
	if _return_emitted:
		return
	if _uses_authoritative_online_result() and not NetworkService.is_host and _result.is_empty():
		if not _waiting_authoritative_result:
			_waiting_authoritative_result = true
			_state.log.append(tr("log_wait_authoritative"))
		_refresh_summary()
		return
	_return_emitted = true
	_stop_battle_music()
	_show_result_overlay()
	await get_tree().create_timer(RESULT_DISPLAY_SECONDS).timeout
	battle_finished.emit(_result if not _result.is_empty() else BattleSim.result_from_state(_state))

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
