extends Node
const H = preload("res://tools/CheckHarness.gd")
const Sfx = preload("res://ui/services/SfxService.gd")
const UI = preload("res://scenes/battle/BattleUI.gd")
const Vfx = preload("res://scenes/battle/BattleVfx.gd")
const Profile = preload("res://scenes/menu/ProfileScreen.gd")
const Shop = preload("res://scenes/menu/ShopScreen.gd")
const Lobby = preload("res://scenes/menu/Team3v3Lobby.gd")
func _ready() -> void:
	var h = H.new("bug0918")
	var profile := Profile.new()
	var now := int(Time.get_unix_time_from_datetime_string("2026-09-18T12:00:00"))
	h.expect(profile._rename_hint("", now) == "现在可改名", "first", "首次可改名")
	h.expect(profile._rename_hint("2026-09-18T20:00:00.000000+08:00", now) == "现在可改名", "due", "精确到期含时区和微秒")
	h.expect(profile._rename_hint("2026-09-19T12:00:00Z", now) == "下次可改名：2026-09-19", "future", "未到期显示日期")
	profile.free()
	var shop := Shop.new()
	shop._owned = {"owned_fixture": true}
	var row := HBoxContainer.new()
	add_child(row)
	var owned := shop._card({"grants": "owned_fixture", "name": "已拥有样本", "price": 99999999})
	var poor := shop._card({"grants": "poor_fixture", "name": "余额不足样本", "price": 99999999})
	row.add_child(owned)
	row.add_child(poor)
	await get_tree().process_frame
	await get_tree().process_frame
	var owned_button := owned.get_child(0).get_child(3) as Button
	var poor_button := poor.get_child(0).get_child(3) as Button
	h.expect(is_equal_approx(owned_button.global_position.y, poor_button.global_position.y), "alignment", "不同购买状态按钮实际布局对齐")
	shop.free()
	var vfx := Vfx.new()
	NetworkService.team_active = true
	NetworkService.team_local_slot = 4
	vfx._state = {"player": [{"uid": "enemy", "id": "human_king", "owner_slot": 0}], "enemy": [{"uid": "self", "id": "human_king", "owner_slot": 4}, {"uid": "ally", "id": "human_king", "owner_slot": 5}]}
	h.expect(vfx._is_local_owned_unit("self"), "self_b_side", "B队本人归属正确")
	h.expect(not vfx._is_local_owned_unit("enemy") and not vfx._is_local_owned_unit("ally"), "others", "敌方及队友不触发")
	vfx._maybe_play_human_king_death_sfx("enemy")
	vfx._maybe_play_human_king_death_sfx("ally")
	h.expect(vfx._human_king_death_sfx_uids.is_empty(), "death_filter", "实际阵亡入口排除其他玩家")
	vfx.free()
	NetworkService.team_active = false
	var lobby := Lobby.new()
	lobby._slot_states = ["player", "empty", "empty", "empty", "empty", "empty"]
	h.expect(lobby._start_hint_text().contains("至少一个占位"), "empty_side", "空侧提示")
	lobby._slot_states[3] = "player"
	lobby._slot_ready = [true, false, false, false, false, false]
	h.expect(lobby._start_hint_text().contains("未准备"), "unready", "未准备提示")
	lobby._slot_ready[3] = true
	h.expect(lobby._start_hint_text() == "可以开始", "ready", "准备完成提示")
	lobby.free()
	var intro := AudioStreamPlayer.new()
	var other := AudioStreamPlayer.new()
	var stream := AudioStreamWAV.new()
	stream.data = PackedByteArray()
	stream.data.resize(44100)
	intro.stream = stream
	other.stream = stream
	intro.set_meta("sfx_cue", Sfx.CUE_BOSS_APPEAR)
	other.set_meta("sfx_cue", "other")
	add_child(intro)
	add_child(other)
	Sfx._voices.append(intro)
	Sfx._voices.append(other)
	intro.play()
	other.play()
	var ui := UI.new()
	ui._stop_battle_music()
	h.expect(not intro.playing and other.playing, "stop_intro_only", "结算停止登场音，不截断其他音效")
	Sfx._voices.erase(intro)
	Sfx._voices.erase(other)
	# 缩短测试音源，验证结束后到期的登场计时器不会重启战斗音乐。
	var intro_path: String = Sfx.CUES[Sfx.CUE_BOSS_APPEAR]
	var previous: Variant = Sfx._streams.get(intro_path)
	var short_stream := AudioStreamWAV.new()
	var samples := PackedByteArray()
	samples.resize(4410)
	short_stream.data = samples
	short_stream.mix_rate = 44100
	Sfx._streams[intro_path] = short_stream
	add_child(ui)
	ui._state = {"kind": "boss"}
	ui._boss_intro_played = true
	ui._boss_intro_pending = true
	ui._resolve_pending_battle_music()
	ui._stop_battle_music()
	await get_tree().create_timer(0.2).timeout
	h.expect(not ui._boss_intro_pending, "no_delayed_restart", "结算后旧登场计时器不重启音乐流程")
	if previous == null:
		Sfx._streams.erase(intro_path)
	else:
		Sfx._streams[intro_path] = previous
	ui.free()
	if "--review" in OS.get_cmdline_user_args():
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://work/bug0918/shop.png")
	h.finish(get_tree())
