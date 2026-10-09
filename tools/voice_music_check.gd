extends Node
const Harness = preload("res://tools/CheckHarness.gd")
const Music = preload("res://ui/services/MusicService.gd")
const VoiceChecks = preload("res://tools/voice_check.gd")
const Tokens = preload("res://ui/theme/GloryTokens.gd")

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
		[VoiceService.Mode.TALK, true, "connected", 1.0 / 6.0],
		[VoiceService.Mode.TALK, true, "reconnecting", 1.0],
		[VoiceService.Mode.TALK, true, "connected", 1.0 / 6.0],
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

	# 10.10 反馈第 4 条：设置页的「语音音量」（0 ~ 1）乘在每个远端队员的轨道音量上。
	#
	# 这条是**行为**判据，不是「代码里有这个字符串」：真的把设置改成 0.4，看桥接收到多少。
	var saved_volume := PlayerProfile.voice_volume
	PlayerProfile.voice_volume = 0.4
	VoiceService._applied_volumes.clear()
	VoiceService._apply_volumes()
	h.expect(is_equal_approx(float(fake.volumes.get("teammate-one", -1.0)), 0.4)
			and is_equal_approx(float(fake.volumes.get("teammate-two", -1.0)), 0.4),
		"voice_volume_setting_applies", "语音音量要乘在每个队友的轨道音量上；实际 %s" % str(fake.volumes))
	# 调到 0 = 全体安静，但**不能**顺手往屏蔽表里塞人（那是两件事：屏蔽会跨局跟着人走）。
	PlayerProfile.voice_volume = 0.0
	VoiceService._applied_volumes.clear()
	VoiceService._apply_volumes()
	h.expect(float(fake.volumes.get("teammate-one", -1.0)) == 0.0 and VoiceService._muted_keys.is_empty(),
		"voice_volume_zero_is_not_mute", "语音音量调到 0 不能让屏蔽表里多出人来")
	# 关扬声器仍然是 0：硬开关赢过连续量。
	PlayerProfile.voice_volume = 0.5
	VoiceService.speaker_enabled = false
	VoiceService._applied_volumes.clear()
	VoiceService._apply_volumes()
	h.expect(float(fake.volumes.get("teammate-one", -1.0)) == 0.0, "voice_volume_never_overrides_speaker",
		"关了扬声器就是 0，语音音量再大也盖不过去")
	VoiceService.speaker_enabled = true
	PlayerProfile.voice_volume = saved_volume
	VoiceService._applied_volumes.clear()
	VoiceService._apply_volumes()

	# 结构判据：那条滑块真的接上了设置页，且文案有中英两份（否则英文版下会显示裸 key）。
	var settings_src := FileAccess.get_file_as_string("res://scenes/menu/SettingsScreen.gd")
	h.expect(settings_src.contains("HSlider") and settings_src.contains("set_voice_volume")
			and settings_src.contains("settings_voice_volume"),
		"voice_volume_slider_wired", "设置页要有语音音量滑块，且接到 PlayerProfile.set_voice_volume")
	var locale_src := FileAccess.get_file_as_string("res://scripts/autoload/LocaleManager.gd")
	h.expect(locale_src.count("\"settings_voice_volume\"") == 2, "voice_volume_translated",
		"settings_voice_volume 要在中英两份文案表里各出现一次；实际 %d 处" % locale_src.count("\"settings_voice_volume\""))
	# 排队房（PartyVoice）走的是另一条音量通道，同一条设置也必须在那里生效。
	var party_src := FileAccess.get_file_as_string("res://scenes/menu/PartyVoice.gd")
	h.expect(party_src.contains("Presentation.voice_volume()"), "voice_volume_applies_in_party",
		"排位 / 休闲组队房的语音音量也要走这一条设置（PartyVoice 是另一条通道）")

	# ★ 真例化整页 + 真改滑块值。只 grep 源码会留下「代码齐全、点了没用」的假绿：
	#   信号没 connect、value 设错、标签不刷新 —— 源码里那几个字符串同样都在。
	#   操作方式与玩家一致（改 Range.value 就会发 value_changed），不 emit() 顶替。
	var ScreenScene := load("res://scenes/menu/SettingsScreen.tscn")
	var screen = ScreenScene.instantiate()
	add_child(screen)
	await get_tree().process_frame
	var slider = screen.get("_voice_slider")
	h.expect(slider is HSlider, "voice_volume_slider_exists", "设置页要真的有一个语音音量滑块")
	if slider is HSlider:
		h.expect(slider.min_value == 0.0 and slider.max_value == 1.0 and is_equal_approx(slider.step, 0.05),
			"voice_volume_slider_range", "滑块要是 0~1、步进 0.05；实际 min=%s max=%s step=%s"
			% [slider.min_value, slider.max_value, slider.step])
		h.expect(slider.custom_minimum_size.y >= Tokens.TOUCH_MIN, "voice_volume_slider_touch_min",
			"滑块触控高度不得低于 TOUCH_MIN(%s)；实际 %.1f" % [Tokens.TOUCH_MIN, slider.custom_minimum_size.y])
		var before := float(PlayerProfile.voice_volume)
		var target := 0.35 if not is_equal_approx(before, 0.35) else 0.55
		slider.value = target
		await get_tree().process_frame
		h.expect(is_equal_approx(float(PlayerProfile.voice_volume), target), "voice_volume_slider_drives_profile",
			"拖动滑块要真的写进玩家档案；期望 %.2f 实际 %.2f" % [target, PlayerProfile.voice_volume])
		var voice_label = screen.get("_voice_label")
		h.expect(voice_label is Label and (voice_label as Label).text.contains("%d%%" % roundi(target * 100.0)),
			"voice_volume_label_follows", "滑块旁的标签要跟着显示当前百分比；实际 %s"
			% ((voice_label as Label).text if voice_label is Label else "<无标签>"))
		PlayerProfile.set_voice_volume(before)
	screen.queue_free()
	await get_tree().process_frame

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
