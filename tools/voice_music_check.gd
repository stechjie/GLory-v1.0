extends Node
const Harness = preload("res://tools/CheckHarness.gd")
const Music = preload("res://ui/services/MusicService.gd")
const VoiceChecks = preload("res://tools/voice_check.gd")

func _ready() -> void:
	var h = Harness.new("voice_music")
	var fake = VoiceChecks.FakeIOSBridge.new()
	VoiceService.set_process(false)
	VoiceService._bridge = fake
	VoiceService._joined = true
	fake.joined = true
	Music._ensure_player()
	await get_tree().process_frame
	var player: AudioStreamPlayer = Music._player
	var tone := AudioStreamWAV.new()
	tone.format = AudioStreamWAV.FORMAT_16_BITS
	tone.mix_rate = 8000
	tone.loop_mode = AudioStreamWAV.LOOP_FORWARD
	tone.loop_end = 8000
	var data := PackedByteArray()
	data.resize(16000)
	tone.data = data
	player.stream = tone
	player.play()
	var master_db := AudioServer.get_bus_volume_db(0)
	for sample in [
		[VoiceService.Mode.LISTEN, false, "connected", 1.0],
		[VoiceService.Mode.TALK, false, "connected", 1.0],
		[VoiceService.Mode.TALK, true, "connected", 0.5],
		[VoiceService.Mode.TALK, true, "reconnecting", 1.0],
		[VoiceService.Mode.TALK, true, "connected", 0.5],
		[VoiceService.Mode.LISTEN, true, "connected", 1.0],
		[VoiceService.Mode.OFF, false, "disconnected", 1.0],
	]:
		VoiceService.mode = sample[0]
		fake.mic_on = sample[1]
		fake.state = sample[2]
		VoiceService._status_at_msec = -100000
		Music._sync_voice_volume()
		h.expect(is_equal_approx(player.volume_linear, sample[3]), "music_gain", str(sample))
		h.expect(player.playing and not player.stream_paused and player.stream == tone, "music_continues", str(sample))
		h.expect(AudioServer.get_bus_volume_db(0) == master_db, "master_unchanged", "队友语音和音效不降音量")
	VoiceService.mode = VoiceService.Mode.TALK
	fake.state = "connected"
	fake.mic_on = true
	fake.participants = ["teammate-one", "teammate-two"]
	VoiceService._status_at_msec = -100000
	VoiceService._muted_keys.clear()
	VoiceService._applied_volumes.clear()
	VoiceService._apply_volumes()
	Music._sync_voice_volume()
	h.expect(fake.volumes.get("teammate-one") == 1.0 and fake.volumes.get("teammate-two") == 1.0, "duplex_keeps_all_peers", "开麦不静音任何队友")
	player.stream_paused = true
	Music._sync_voice_volume()
	h.expect(player.stream_paused, "music_setting_preserved", "开麦不恢复用户已暂停的音乐")
	VoiceService._leave()
	Music._sync_voice_volume()
	h.expect(is_equal_approx(player.volume_linear, 1.0), "leave_restores_music", "离开恢复音乐")
	Music.shutdown()
	h.finish(get_tree())
