extends Node

const WindowsSpeech := preload("res://scripts/account/WindowsSpeechToText.gd")
const Speech := preload("res://scripts/account/SpeechToText.gd")
var checked := 0
var failures := 0

func expect(ok: bool, message: String) -> void:
	checked += 1
	if not ok:
		failures += 1
		push_error(message)

func _ready() -> void:
	var silence := PackedFloat32Array()
	silence.resize(16000)
	var silent_wav := VoiceClipService.build_wav(silence, 16000)
	expect(not WindowsSpeech.has_voice(silent_wav), "Silence must not launch recognition")
	expect(not WindowsSpeech.has_voice(PackedByteArray()), "Empty audio rejected")
	expect(WindowsSpeech.clean_text("\ufeffHello\r\nworld\n") == "Hello  world", "Transcript cleaned without timestamps")
	var cancelled := WindowsSpeech.new()
	cancelled.cancel()
	var result: Dictionary = await cancelled.recognize(self, silent_wav)
	expect(result.get("error") == "cancelled", "Pre-cancelled job must not launch")
	if OS.get_name() == "Windows":
		for locale in ["zh", "en"]:
			var sample := "res://build/whisper-setup/%s.wav" % locale
			if not FileAccess.file_exists(sample):
				push_error("Generate the local TTS fixtures before running the recognition integration check: " + sample)
				get_tree().quit(1)
				return
			TranslationServer.set_locale(locale)
			var audio := FileAccess.get_file_as_bytes(sample)
			expect(WindowsSpeech.has_voice(audio), "Speech passes activity gate")
			var before := Time.get_ticks_msec()
			result = await Speech.new().recognize(self, audio)
			print("WINDOWS_SPEECH ", locale, " elapsed_ms=", Time.get_ticks_msec() - before, " result=", result)
			expect(bool(result.get("ok", false)), "Real local recognition succeeds: " + locale)
			var text := str(result.get("text", "")).to_lower()
			expect(text.contains("游戏") or text.contains("遊戲") if locale == "zh" else text.contains("together"), "Recognized expected speech: " + locale)
			var job := WindowsSpeech.new()
			_cancel_job.call_deferred(job)
			result = await job.recognize(self, audio)
			expect(result.get("error") == "cancelled" and job._pid == -1, "Active process cancelled and reaped")
		var active := false
		for filename in DirAccess.get_files_at("user://"):
			active = active or filename.begins_with("speech_")
		expect(not active, "No temporary recordings or transcripts remain")
	print("WINDOWS_SPEECH_CHECK checked=", checked, " failures=", failures)
	get_tree().quit(1 if failures else 0)

func _cancel_job(job: RefCounted) -> void:
	await get_tree().create_timer(0.1).timeout
	job.cancel()
