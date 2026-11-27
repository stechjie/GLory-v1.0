extends Node

const Harness := preload("res://tools/CheckHarness.gd")

class MainProbe extends "res://scenes/main/Main.gd":
	var entered := 0
	func _ready() -> void:
		pass
	func _on_match_ready() -> void:
		entered += 1
		ModalStack.pop(MATCH_QUEUE_MODAL_ID)

class QueueProbe extends "res://scenes/menu/MatchQueuePanel.gd":
	var response := {"code":200,"body":{"state":{"state":"ready"}}}
	var leave_calls := 0
	var accept_calls := 0
	var pause := false
	signal release
	func _ready() -> void:
		_build()
	func _request_leave(_party: bool) -> Dictionary:
		leave_calls += 1
		if pause:
			await release
		return response
	func _request_accept() -> Dictionary:
		accept_calls += 1
		if pause:
			await release
		return response
	func _request_match_state() -> Dictionary:
		if pause:
			await release
		return response

var h := Harness.new("match_queue_race_1027")

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	NetworkService.set_process(false)
	for locale in ["zh", "en"]:
		LocaleManager.set_locale(locale)
		_countdown_updates()
		_delayed_confirmations()
		for mode in ["casual", "casual_normal", "ranked", "ranked_normal"]:
			var main := MainProbe.new()
			add_child(main)
			main._show_match_queue(mode, true, true)
			await get_tree().process_frame
			var panel: Control = ModalStack.top().get("content")
			panel.call("_apply", {"state":"found","accepted":true,"accept_sec":30})
			h.expect(ModalStack.handle_back_request(), "back_consumed", "Back is consumed by the match modal")
			h.expect(ModalStack.has(main.MATCH_QUEUE_MODAL_ID), "esc_keeps_queue", "Esc must not orphan a confirmed match")
			if ModalStack.has(main.MATCH_QUEUE_MODAL_ID):
				RealtimeService.message_received.emit({"t":"match","state":"ready"})
				await get_tree().process_frame # Main enters after the WS dispatch has completed.
				h.expect(main.entered == 1, "ready_after_esc", "The same client still receives the ready transition")
			ModalStack.pop(main.MATCH_QUEUE_MODAL_ID)
			main.free()
			await get_tree().process_frame
	for locale in ["zh", "en"]:
		LocaleManager.set_locale(locale)
		await _cancel_cases()
		await _accept_race()
		await _accept_then_cancel()
		var unclear := _queue()
		unclear.response = {"code":200,"body":{"state":{"state":"found","accepted":true}}}
		var cancelled := [0]
		unclear.dismissed.connect(func() -> void: cancelled[0] += 1)
		await unclear._on_leave()
		h.expect(cancelled[0] == 0 and unclear._state == "found", "http_success_not_cancelled",
			"A 200 response still in the match is not a confirmed cancellation")
		unclear.free()
		var q := _queue()
		var counts := [0]
		q.match_ready.connect(func() -> void: counts[0] += 1)
		q._apply({"state":"ready"})
		q._apply({"state":"queued"})
		q._apply({"state":"found","accepted":false})
		q._apply({"state":"ready"})
		h.expect(q._state == "ready" and counts[0] == 1, "terminal_ready", "Late HTTP replies cannot undo ready or start a second connection")
		q.free()
	h.finish(get_tree())

func _countdown_updates() -> void:
	var q := _queue()
	q.configure("ranked")
	q._apply({"state": "queued"})
	q._queue_started_msec = Time.get_ticks_msec() - 7100
	q._process(0.0)
	var waiting := q._detail.text
	q._on_realtime_message({"t": "match", "state": "queued", "position": 1})
	h.expect(waiting.ends_with("\n8...") and q._detail.text == waiting, "queue_clock_no_flash",
		"Repeated queued snapshots must preserve elapsed wait time immediately")
	q.pause = true
	q.response = {"code": 200, "body": {"state": {"state": "queued"}}}
	q._poll()
	var seats := [{"team": 0, "seat": 0, "name": "P1", "accepted": false}]
	var found := {"t": "match", "state": "found", "match_uid": "A", "accept_sec": 6, "seats": seats}
	q._on_realtime_message(found)
	q.release.emit()
	h.expect(q._state == "found", "old_queue_poll_during_confirmation",
		"A delayed queued poll must not flash the panel back from match confirmation")
	var chip := q._roster.get_child(0).get_child(0)
	var before := q._title.text
	found.accept_sec = 28
	q._apply(found)
	h.expect(before.ends_with("6") and q._title.text == before, "confirmation_clock_no_rewind",
		"Older responses must not extend the same match's countdown")
	seats[0].accepted = true
	found.accept_sec = 2
	q._apply(found)
	h.expect(q._title.text.ends_with("2") and q._roster.get_child(0).get_child(0) == chip and
		chip.get_node("ConfirmTick").visible, "confirmation_updates_in_place",
		"A shorter deadline and confirmation mark must update without recreating portraits")
	found.match_uid = "B"
	found.accept_sec = 30
	q._apply(found)
	h.expect(q._title.text.ends_with("30"), "new_match_fresh_deadline",
		"A new match has its own full confirmation window")
	q.free()

func _delayed_confirmations() -> void:
	var q := _queue()
	var seats := [{"team": 0, "seat": 0, "me": true, "accepted": false},
		{"team": 0, "seat": 1, "name": "P2", "accepted": false}]
	var found := {"state": "found", "match_uid": "A", "seats": seats, "accept_sec": 12}
	q._apply(found)
	q.pause = true
	var response := found.duplicate(true)
	response.accepted = true
	response.seats[0].accepted = true
	q.response = {"code": 200, "body": {"state": response}}
	q._on_accept()
	seats[1].accepted = true
	q._apply(found)
	q.release.emit()
	q._apply({"state": "found", "match_uid": "A", "seats": []})
	var row := q._roster.get_child(0)
	h.expect(q._accepted and q._accept_btn.disabled and q._roster.visible and
		row.get_child(0).get_node("ConfirmTick").visible and row.get_child(1).get_node("ConfirmTick").visible,
		"late_or_sparse_accept_preserves_marks", "Same-match snapshots can only add confirmations")
	q._apply({"state": "found", "match_uid": "B"})
	h.expect(not q._accepted and not q._roster.visible, "new_table_clears_roster",
		"A new match starts with its own confirmations even if its first snapshot lacks seats")
	q.free()
	for destination in ["queued", "found"]:
		for reply in ["found", "ready"]:
			q = _queue()
			q._apply({"state": "found", "match_uid": "A"})
			q.pause = true
			q.response = {"code": 200, "body": {"state": {"state": reply, "match_uid": "A", "accepted": true}}}
			q._on_accept()
			q._apply({"state": destination, "match_uid": "B", "accept_sec": 29})
			q.release.emit()
			h.expect(q._state == destination and not q._accepted and not q._leave_btn.disabled,
				"old_table_accept_after_" + destination + "_" + reply,
				"An old acceptance response cannot re-open or start a dissolved table")
			q.free()
	q = _queue()
	q._apply({"state": "found", "match_uid": "A"})
	q.pause = true
	q.response = {"code": 200, "body": {"state": {"state": "ready", "match_uid": "A"}}}
	q._on_accept()
	q._apply({"state": "found", "match_uid": "A", "accept_sec": 1})
	q.release.emit()
	h.expect(q._state == "ready", "current_assignment_wins",
		"The final allocation for the current match still enters after intermediate updates")
	q.free()

func _queue() -> QueueProbe:
	var q := QueueProbe.new()
	add_child(q)
	q._apply({"state":"found","accepted":false})
	return q

func _cancel_cases() -> void:
	for grouped in [false, true]:
		var q := _queue()
		q._party_queue = grouped
		if grouped:
			q._apply({"state":"queued"})
		var counts := [0,0]
		q.dismissed.connect(func() -> void: counts[0] += 1)
		q.match_ready.connect(func() -> void: counts[1] += 1)
		await q._on_leave()
		h.expect(counts == [0,1], "late_cancel_enters", "Cancellation that loses to ready must enter, not abandon the client")
		q.free()
		q = _queue()
		q._party_queue = grouped
		if grouped:
			q._apply({"state":"queued"})
		q.response = {"code":200,"body":{"state":{"state":"room","queued":false} if grouped else {"state":"idle"}}}
		counts = [0,0]
		q.dismissed.connect(func() -> void: counts[0] += 1)
		q.match_ready.connect(func() -> void: counts[1] += 1)
		await q._on_leave()
		q._apply({"state":"ready"})
		h.expect(counts == [1,0], "confirmed_cancel_closes", "A confirmed cancellation closes once and ignores late notifications")
		q.free()
		q = _queue()
		q.response = {"code":0,"error":"test offline"}
		counts = [0]
		q.dismissed.connect(func() -> void: counts[0] += 1)
		await q._on_leave()
		h.expect(counts[0] == 0 and q._state == "found" and not q._leave_btn.disabled,
			"failed_cancel_stays", "A failed cancel keeps the match listener and retry action")
		q.free()

func _accept_race() -> void:
	var q := _queue()
	q.pause = true
	q.response = {"code":200,"body":{"state":{"state":"found","accepted":true}}}
	var counts := [0,0]
	q.dismissed.connect(func() -> void: counts[0] += 1)
	q.match_ready.connect(func() -> void: counts[1] += 1)
	q._on_accept()
	h.expect(q._leave_btn.disabled, "accept_blocks_decline", "Accept and decline cannot be sent concurrently")
	await q._on_leave()
	h.expect(q.leave_calls == 0, "no_concurrent_cancel", "Clicking decline during acceptance sends no cancellation")
	q._apply({"state":"ready"})
	q.release.emit()
	await get_tree().process_frame
	h.expect(q._state == "ready" and counts == [0,1], "push_beats_old_accept", "Old accept reply cannot undo a ready push")
	q.free()

func _accept_then_cancel() -> void:
	for committed in [false, true]:
		var q := _queue()
		var counts := [0,0]
		q.dismissed.connect(func() -> void: counts[0] += 1)
		q.match_ready.connect(func() -> void: counts[1] += 1)
		q.response = {"code":200,"body":{"state":{"state":"found","accepted":true}}}
		await q._on_accept()
		h.expect(q._accepted and q._accept_btn.disabled and not q._leave_btn.disabled,
			"accepted_waiting", "After accepting, the caller waits while the server still permits cancellation")
		q.response = {"code":200,"body":{"state":{"state":"ready" if committed else "idle"}}}
		await q._on_leave()
		h.expect(counts == ([0,1] if committed else [1,0]), "accept_then_cancel_order",
			"Accept then cancel enters only when confirmation has already committed; otherwise it cancels")
		q.free()
