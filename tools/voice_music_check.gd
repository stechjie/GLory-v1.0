extends Node
const Harness = preload("res://tools/CheckHarness.gd")
const Music = preload("res://ui/services/MusicService.gd")
const VoiceChecks = preload("res://tools/voice_check.gd")

class FocusAudioBridge extends VoiceChecks.FakeIOSBridge:
	var focus_prepared := 0
	func prepareAudioResume() -> bool:
		focus_prepared += 1
		return true

func _ready() -> void:
	var h = Harness.new("voice_music")
	var fake = FocusAudioBridge.new()
	VoiceService.set_process(false)
	VoiceService._bridge = fake
	VoiceService._notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	h.expect(fake.focus_prepared == 1, "focus_prepares_ios_output", "iOS audio session is ready during FOCUS_IN, before Godot starts output")
	VoiceService._joined = true
	fake.joined = true
	Music._ensure_player()
	var pending_player := Music._player
	Music._ensure_player()
	h.expect(Music._player == pending_player, "one_pending_music_player", "同帧切换页面只保留一个播放器")
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
	Music._path = "test://loop"
	player.stream_paused = false
	player.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	h.expect(player.stream_paused, "background_pauses_music", "后台暂停 BGM")
	Music._sync()
	h.expect(player.stream_paused, "background_sync_stays_paused", "后台同步不能重启 BGM")
	player.stop()
	player.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	await get_tree().process_frame
	h.expect(player.playing and not player.stream_paused and player.stream == tone, "foreground_restores_music", "前台恢复丢失的播放器")
	player.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	var previous_music_enabled := PlayerProfile.music_enabled
	PlayerProfile.music_enabled = false
	player.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	await get_tree().process_frame
	h.expect(player.stream_paused, "foreground_respects_music_off", "回前台不覆盖用户关闭音乐的设置")
	PlayerProfile.music_enabled = previous_music_enabled
	player.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	Music.stop()
	player.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	await get_tree().process_frame
	h.expect(not player.playing, "foreground_respects_stop", "主动停止的音乐不恢复")
	Music.shutdown()
	h.finish(get_tree())
