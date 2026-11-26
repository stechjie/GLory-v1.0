extends Node
# Explicit QA-only entry for the separately packaged Simulator app.
# Production project.godot never points to this scene.
const CONTROL := "user://ios_perf_control.json"
const RECEIPT := "user://ios_perf_entry.json"
const SCENES := {
	"cpu": "res://scripts/qa/battle_hotpath_benchmark.tscn",
	"battle": "res://scripts/qa/battle_presentation_baseline.tscn",
}
var _poll := 0.0
var _claimed := false

func _ready() -> void:
	# Offline fixtures use service data, but must not initiate service traffic.
	for service in [AccountManager, NetworkService, RealtimeService, AnalyticsService,
			ChatService, AnnouncementService, MailService, VoiceService, VoiceClipService]:
		service.process_mode = Node.PROCESS_MODE_DISABLED
	DeviceHarness.set("_active", true)
	_claim()

func _process(delta: float) -> void:
	if _claimed:
		return
	_poll += delta
	if _poll >= 0.25:
		_poll = 0.0
		_claim()

func _claim() -> void:
	if not FileAccess.file_exists(CONTROL):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONTROL))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CONTROL))
	if not parsed is Dictionary:
		_write({"passed": false, "error": "invalid_control"})
		return
	var mode := str(parsed.get("mode", ""))
	if not SCENES.has(mode):
		_write({"passed": false, "error": "unknown_mode", "mode": mode})
		return
	var args := PackedStringArray()
	for value in parsed.get("tool_args", []):
		args.append(str(value))
	DeviceHarness.tool_args = args
	_claimed = true
	_write({"qa_only": true, "mode": mode, "tool_args": args, "os": OS.get_name(),
		"adapter": RenderingServer.get_video_adapter_name(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"window": str(DisplayServer.window_get_size()),
		"viewport": str(get_viewport().get_visible_rect().size),
		"engine": Engine.get_version_info(), "debug_build": OS.is_debug_build(),
		"quality_tier": VFXManager.get_quality_tier(), "network": "offline service processing disabled"})
	call_deferred("_open", str(SCENES[mode]))

func _open(path: String) -> void:
	var error := get_tree().change_scene_to_file(path)
	if error != OK:
		_write({"passed": false, "error": "scene_load_failed", "path": path, "code": error})
		get_tree().quit(1)

func _write(data: Dictionary) -> void:
	var f := FileAccess.open(RECEIPT, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data, "\t"))
		f.close()
