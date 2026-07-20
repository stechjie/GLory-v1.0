extends Node
class_name VFXPreviewRecorder

signal screenshot_saved(path: String)

var playback_speed := 1.0
var paused := false
var capture_directory := "user://vfx_captures"

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(capture_directory))

func set_playback_speed(speed: float) -> void:
	playback_speed = clampf(speed, 0.0, 4.0)
	paused = is_zero_approx(playback_speed)
	Engine.time_scale = playback_speed

func toggle_pause() -> bool:
	paused = not paused
	Engine.time_scale = 0.0 if paused else (playback_speed if playback_speed > 0.0 else 1.0)
	return paused

func step_frame() -> void:
	paused = true
	Engine.time_scale = 1.0
	await get_tree().process_frame
	Engine.time_scale = 0.0

func capture_now(viewport: Viewport, label := "vfx") -> String:
	if viewport == null:
		return ""
	await RenderingServer.frame_post_draw
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/%s_%s.png" % [capture_directory, label, stamp]
	var error := viewport.get_texture().get_image().save_png(path)
	if error == OK:
		screenshot_saved.emit(path)
		return path
	return ""

func capture_at_time(viewport: Viewport, seconds: float, label := "vfx_fixed") -> String:
	var previous_speed := Engine.time_scale
	Engine.time_scale = 1.0
	await get_tree().create_timer(maxf(seconds, 0.0), true, false, true).timeout
	Engine.time_scale = 0.0
	paused = true
	var path := await capture_now(viewport, label)
	if not paused:
		Engine.time_scale = previous_speed
	return path

func restore_normal_speed() -> void:
	paused = false
	playback_speed = 1.0
	Engine.time_scale = 1.0

func _exit_tree() -> void:
	Engine.time_scale = 1.0
