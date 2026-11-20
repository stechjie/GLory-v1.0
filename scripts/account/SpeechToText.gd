extends RefCounted

# Android plugin methods are invisible to has_method(); see NativeBridge.gd.
const NativeBridge := preload("res://scripts/account/NativeBridge.gd")

var cancelled := false
var _windows: RefCounted

func cancel() -> void:
	cancelled = true
	if _windows != null:
		_windows.cancel()

func _native_bridge() -> Object:
	return Engine.get_singleton("GloryVoice") if Engine.has_singleton("GloryVoice") else null

# Recognize the captured audio, never start a second microphone session.
func recognize(owner: Node, wav: PackedByteArray) -> Dictionary:
	var bridge := _native_bridge()
	# Native mobile implementations and test bridges keep their existing contract.
	if OS.get_name() == "Windows" and (bridge == null or not NativeBridge.supports(bridge, "recognizeSpeechFile")):
		_windows = preload("res://scripts/account/WindowsSpeechToText.gd").new()
		if cancelled:
			_windows.cancel()
		return await _windows.recognize(owner, wav)
	if bridge == null:
		return {"ok": false, "error": "unavailable"}
	for method in ["recognizeSpeechFile", "getSpeechResult", "cancelSpeechRecognition"]:
		if not NativeBridge.supports(bridge, method):
			return {"ok": false, "error": "plugin_update_required"}
	var filename := "user://speech_%d.wav" % Time.get_ticks_usec()
	var file := FileAccess.open(filename, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "audio_file_failed"}
	file.store_buffer(wav)
	file.close()
	var native_path := ProjectSettings.globalize_path(filename)
	var locale := "en-US" if TranslationServer.get_locale().begins_with("en") else "zh-CN"
	var error := str(bridge.call("recognizeSpeechFile", native_path, locale))
	var result := {"ok": false, "error": error}
	var deadline := Time.get_ticks_msec() + 45000
	if error.is_empty():
		while not cancelled and is_instance_valid(owner) and owner.is_inside_tree() and Time.get_ticks_msec() < deadline:
			var status: Variant = JSON.parse_string(str(bridge.call("getSpeechResult")))
			if status is Dictionary and str(status.get("state", "")) == "done":
				var text := str(status.get("text", "")).strip_edges()
				result = {"ok": not text.is_empty(), "text": text, "error": str(status.get("error", "no_speech"))}
				break
			await owner.get_tree().create_timer(0.1).timeout
		if not bool(result.get("ok", false)) and str(result.get("error", "")).is_empty():
			result = {"ok": false, "error": "timeout"}
	bridge.call("cancelSpeechRecognition")
	DirAccess.remove_absolute(native_path)
	return result
