extends RefCounted

const DEV_DIRECTORY := "res://addons/glory_speech/bin/windows"
const MODEL := "ggml-base-q5_1.bin"
const TIMEOUT_MSEC := 90000
const MIN_SECONDS := 0.6
var cancelled := false
var _pid := -1

func cancel() -> void:
	cancelled = true
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)

func runtime_directory() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path(DEV_DIRECTORY)
	return OS.get_executable_path().get_base_dir().path_join("speech")

func recognize(owner: Node, wav: PackedByteArray) -> Dictionary:
	if cancelled:
		return {"ok": false, "error": "cancelled"}
	var runtime := runtime_directory()
	var executable := runtime.path_join("whisper-cli.exe")
	var model := runtime.path_join(MODEL)
	if not FileAccess.file_exists(executable) or not FileAccess.file_exists(model):
		return {"ok": false, "error": "windows_model_missing"}
	# Silence is not a speech prompt: avoid hallucinated text without launching a model.
	if not has_voice(wav):
		return {"ok": false, "error": "no_speech"}
	var job := "user://speech_%d" % Time.get_ticks_usec()
	var audio := job + ".wav"
	var output := job + ".txt"
	var file := FileAccess.open(audio, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "audio_file_failed"}
	file.store_buffer(wav)
	file.close()
	var args := PackedStringArray(["-m", model, "-f", ProjectSettings.globalize_path(audio),
		"-of", ProjectSettings.globalize_path(job), "-otxt", "-l", "auto", "-ng", "-np", "-nt",
		"-t", str(clampi(OS.get_processor_count() / 2, 1, 4)), "-bs", "1", "-bo", "1", "-sns"])
	if TranslationServer.get_locale().begins_with("zh"):
		args.append_array(PackedStringArray(["--prompt", "以下是简体中文的游戏聊天。"] ))
	# No shell and no console window. User speech is never interpolated into commands.
	_pid = OS.create_process(executable, args, false)
	var result := {"ok": false, "error": "recognition_failed"}
	if _pid > 0:
		var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
		while not cancelled and is_instance_valid(owner) and owner.is_inside_tree() \
				and OS.is_process_running(_pid) and Time.get_ticks_msec() < deadline:
			await owner.get_tree().create_timer(0.05).timeout
		if cancelled or not is_instance_valid(owner) or not owner.is_inside_tree():
			result.error = "cancelled"
		elif OS.is_process_running(_pid):
			result.error = "timeout"
		elif FileAccess.file_exists(output):
			var text := clean_text(FileAccess.get_file_as_string(output))
			result = {"ok": not text.is_empty(), "text": text, "error": "" if not text.is_empty() else "no_speech"}
		if OS.is_process_running(_pid):
			OS.kill(_pid)
	_pid = -1
	DirAccess.remove_absolute(ProjectSettings.globalize_path(audio))
	if FileAccess.file_exists(output):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(output))
	return result

static func clean_text(text: String) -> String:
	return text.trim_prefix("\ufeff").replace("\r", " ").replace("\n", " ").strip_edges()

static func has_voice(wav: PackedByteArray) -> bool:
	if wav.size() < 44 + int(16000 * MIN_SECONDS) * 2:
		return false
	var peak := 0
	var energy := 0.0
	var count := (wav.size() - 44) / 2
	for index in count:
		var sample := int(wav.decode_s16(44 + index * 2))
		peak = maxi(peak, absi(sample))
		energy += float(sample) * sample
	return peak > 160 and sqrt(energy / count) > 40.0
