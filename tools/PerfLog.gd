extends Node
# Temporary diagnostic autoload. Prints engine-side counters to stdout, which
# lands in `adb logcat -s godot`, so the numbers can be collected without the
# editor's Monitors panel and without anyone reading a screen.
#
# Engine bookkeeping is used on purpose: on this Unisoc/Mali device the OS-level
# graphics accounting (dumpsys meminfo "Graphics:") is stuck at a constant and
# cannot be trusted, while Godot counts what it allocated itself.
#
# Remove this file and its autoload entry once the memory question is settled.

const SAMPLE_INTERVAL := 0.5
# A step this large between samples is an event (a unit spawning, a scene
# loading), not drift -- worth its own line so it can be found in the log.
const JUMP_MB := 24.0

var _accum := 0.0
var _last_video_mb := 0.0
var _last_static_mb := 0.0

func _ready() -> void:
	print("[PERFLOG] started interval=%.1fs" % SAMPLE_INTERVAL)

func _process(delta: float) -> void:
	_accum += delta
	if _accum < SAMPLE_INTERVAL:
		return
	_accum = 0.0
	var video_mb := _mb(Performance.RENDER_VIDEO_MEM_USED)
	var texture_mb := _mb(Performance.RENDER_TEXTURE_MEM_USED)
	var buffer_mb := _mb(Performance.RENDER_BUFFER_MEM_USED)
	var static_mb := _mb(Performance.MEMORY_STATIC)
	print("[PERFLOG] fps=%d proc=%.1fms video=%.1f tex=%.1f buf=%.1f static=%.1f obj=%d res=%d node=%d orphan=%d draw=%d" % [
		Engine.get_frames_per_second(),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		video_mb, texture_mb, buffer_mb, static_mb,
		int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
	])
	if absf(video_mb - _last_video_mb) >= JUMP_MB:
		print("[PERFLOG] !! VIDEO JUMP %+.1f MB -> %.1f (tex=%.1f)" % [
			video_mb - _last_video_mb, video_mb, texture_mb])
	if absf(static_mb - _last_static_mb) >= JUMP_MB:
		print("[PERFLOG] !! STATIC JUMP %+.1f MB -> %.1f" % [
			static_mb - _last_static_mb, static_mb])
	_last_video_mb = video_mb
	_last_static_mb = static_mb

func _mb(monitor: int) -> float:
	return float(Performance.get_monitor(monitor)) / 1048576.0
