extends AudioStreamPlayer

# A root-owned player receives lifecycle events even while its scene is paused.
signal application_suspended
signal application_resumed

var _audio_probe_remaining := 0
var _audio_probe_delay := 0.0

func _ready() -> void:
	if OS.has_feature("ios"):
		_audio_probe_remaining = 6

func _process(delta: float) -> void:
	if _audio_probe_remaining <= 0:
		return
	_audio_probe_delay -= delta
	if _audio_probe_delay > 0.0:
		return
	_audio_probe_delay = 1.0
	_audio_probe_remaining -= 1
	var voice := VoiceService.status()
	NetworkService._net_log("audio probe mix_age=%.3f position=%.3f playing=%s paused=%s gain=%.2f master_db=%.1f muted=%s peak=%.1f category=%s route=%s error=%s" % [
		AudioServer.get_time_since_last_mix(), get_playback_position(), str(playing), str(stream_paused), volume_linear,
		AudioServer.get_bus_volume_db(0), str(AudioServer.is_bus_mute(0)), AudioServer.get_bus_peak_volume_left_db(0, 0),
		str(voice.get("audio_mode", "")), str(voice.get("output", "")), str(voice.get("audio_session_error", ""))])

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		application_suspended.emit()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		if OS.has_feature("ios"):
			_audio_probe_remaining = 6
			_audio_probe_delay = 0.0
		# Resume after Godot has restarted its platform audio driver.
		application_resumed.emit.call_deferred()
