extends Control

# Exercise gestures without opening a microphone, uploading audio, or sending messages.
const RecordButton := preload("res://ui/components/VoiceRecordButton.gd")
var failures := 0
var checked := 0

class FakeSpeechBridge extends RefCounted:
	var filename := ""
	var cleaned := false
	func recognizeSpeechFile(file: String, _locale: String) -> String:
		filename = file
		return ""
	func getSpeechResult() -> String:
		return '{"state":"done","text":"Hello 你好","error":""}'
	func cancelSpeechRecognition() -> void:
		cleaned = true

class TestRecognition extends "res://scripts/account/SpeechToText.gd":
	var fake := FakeSpeechBridge.new()
	func _native_bridge() -> Object:
		return fake

func expect(ok: bool, message: String) -> void:
	checked += 1
	if not ok:
		failures += 1
		push_error(message)

func _ready() -> void:
	var speech := TestRecognition.new()
	var result: Dictionary = await speech.recognize(self, VoiceClipService.build_wav(PackedFloat32Array([0.1]), 16000))
	expect(bool(result.get("ok", false)), "Successful native result must not become a timeout")
	expect(result.get("text", "") == "Hello 你好", "Native text preserved")
	expect(speech.fake.cleaned and not FileAccess.file_exists(speech.fake.filename), "Native job and temporary audio cleaned")
	for locale in ["zh", "en"]:
		TranslationServer.set_locale(locale)
		var recorder := RecordButton.create(VoiceClipService.SCOPE_WORLD)
		recorder.position = Vector2(1200, 640)
		add_child(recorder)
		recorder._held = true
		recorder._show_actions()
		await get_tree().process_frame
		await get_tree().process_frame
		expect(recorder._button.icon != null and recorder._button.text.is_empty(), "Microphone must stay an icon")
		expect(not recorder._hint.visible, "No hint beside microphone")
		expect(recorder._cancel_action.text.contains("Cancel" if locale == "en" else "取消"), "Localized cancel")
		expect(recorder._text_action.text.contains("To Text" if locale == "en" else "转文字"), "Localized transcription")
		expect(recorder._actions.get_global_rect().end.y < recorder._button.get_global_rect().position.y, "Actions above microphone")
		var origin: Vector2 = recorder._gesture_origin
		var left := origin + Vector2(-240, -180)
		var right := origin + Vector2(240, -180)
		expect(not recorder._cancel_action.get_global_rect().has_point(left), "Cancel probe outside chip")
		expect(not recorder._text_action.get_global_rect().has_point(right), "Transcription probe outside chip")
		expect(recorder._gesture_choice(left) == "cancel", "Left direction cancels without hitting chip")
		expect(recorder._gesture_choice(right) == "text", "Right direction converts without hitting chip")
		expect(recorder._gesture_choice(origin + Vector2(120, 0)) == "text", "Horizontal slide selects conversion")
		expect(recorder._gesture_choice(origin + Vector2(-120, 0)) == "cancel", "Horizontal slide selects cancel")
		expect(recorder._gesture_choice(origin + Vector2(12, -8)) == "send", "Small movement still sends")
		recorder._highlight_action(left)
		expect(recorder._selected_action == "cancel", "Cancel direction highlighted")
		recorder._highlight_action(origin)
		expect(recorder._selected_action == "send", "Returning restores send")
		recorder._highlight_action(right)
		expect(recorder._selected_action == "text", "Transcription direction highlighted")
		expect(recorder._cancel_action.rotation < 0 and recorder._text_action.rotation > 0, "Rounded chips angle outward")
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("user://record-actions-%s.png" % locale)
		VoiceClipService._samples = PackedFloat32Array([0.1, 0.2])
		recorder._release(left)
		expect(VoiceClipService._samples.is_empty(), "Cancel clears captured audio even at time limit")
		expect(not recorder._overlay.visible and not recorder._held, "Cancel hides controls")
		recorder._held = true
		recorder._show_actions()
		recorder._notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
		expect(not recorder._held and not recorder._overlay.visible, "Backgrounding cancels gesture")
		var state := {"clips": 0, "errors": 0}
		recorder.clip_ready.connect(func(_clip: Dictionary) -> void: state.clips += 1)
		recorder.failed.connect(func(_error: String) -> void: state.errors += 1)
		recorder._held = true
		recorder._show_actions()
		VoiceClipService._samples.resize(16000)
		await recorder._release(right)
		expect(state.clips == 0, "Transcription never sends voice")
		expect(state.errors == 1 and not recorder._busy, "No-speech recognition ends cleanly without sending")
		recorder.queue_free()
		await get_tree().process_frame
	print("VOICE_RECORD_ACTIONS checked=", checked, " failures=", failures)
	get_tree().quit(1 if failures else 0)
