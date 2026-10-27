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
		return response

var h := Harness.new("match_queue_race_1027")

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	NetworkService.set_process(false)
	for locale in ["zh", "en"]:
		LocaleManager.set_locale(locale)
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
