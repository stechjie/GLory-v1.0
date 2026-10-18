extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const LobbyScene := preload("res://scenes/menu/PartyLobby.tscn")
const EntryGuide := preload("res://scripts/tutorial/TutorialEntryGuide.gd")

var _h: CheckHarness
var _selected := 0
var _started := 0


func _ready() -> void:
	_h = CheckHarness.new("tutorial_entry")
	var lobby := LobbyScene.instantiate() as Control
	lobby.call("configure_tutorial_intro")
	lobby.connect("tutorial_mode_selected", func() -> void: _selected += 1)
	lobby.connect("tutorial_requested", func() -> void: _started += 1)
	add_child(lobby)
	await get_tree().process_frame
	var mode := lobby.call("tutorial_mode_target") as Button
	var action := lobby.call("tutorial_start_target") as Button
	_h.expect(mode != null and action != null, "targets_missing",
		"青苗和匹配 AI 的真实按钮必须可解析")
	_h.expect(not mode.disabled and action.disabled, "entry_order_wrong",
		"玩家必须先选青苗，才能匹配 AI")
	_h.expect(str(lobby.get("_preview")) == "tutorial" and
		str(lobby.get("_room").get("mode", "")) == "casual", "local_mode_wrong",
		"首局必须走本地休闲青苗房")
	var guide := EntryGuide.new() as Control
	guide.call("configure", mode, "lobby_mode")
	lobby.add_child(guide)
	await get_tree().process_frame
	_h.expect(guide.visible and guide.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"guide_blocks_input", "狗狗提示不得拦截玩家点击")
	var original_size := get_window().size
	for viewport_size in [Vector2i(1600, 900), Vector2i(1600, 720), Vector2i(1280, 720)]:
		get_window().size = viewport_size
		await get_tree().process_frame
		await get_tree().process_frame
		var bubble := guide.get("_bubble") as Control
		var dog := guide.get("_dog") as Control
		var target_rect := mode.get_global_rect()
		var bubble_rect := bubble.get_global_rect()
		var dog_rect := dog.get_global_rect()
		var target_area := maxf(1.0, target_rect.size.x * target_rect.size.y)
		var hidden := bubble_rect.intersection(target_rect).get_area() \
			+ dog_rect.intersection(target_rect).get_area()
		_h.expect(hidden / target_area <= 0.1, "entry_target_covered",
			"%s 青苗按钮被遮住 %.1f%%" % [str(viewport_size), hidden / target_area * 100.0])
		var bounds := Rect2(Vector2.ZERO, Vector2(viewport_size))
		_h.expect(bounds.encloses(bubble_rect) and bounds.encloses(dog_rect),
			"entry_guide_offscreen", "%s 狗狗或对白超出屏幕" % str(viewport_size))
	get_window().size = Vector2i(1748, 804)
	SafeArea.set_test_insets(Vector4(78, 0, 0, 0))
	await get_tree().process_frame
	await get_tree().process_frame
	var notch_safe := SafeArea.rect().grow(-20.0)
	_h.expect(notch_safe.encloses((guide.get("_bubble") as Control).get_global_rect())
		and notch_safe.encloses((guide.get("_dog") as Control).get_global_rect()),
		"entry_notch_overlap", "灵动岛安全区内应完整容纳狗狗和对白")
	SafeArea.set_test_insets(null)
	get_window().size = original_size
	action.pressed.emit()
	_h.expect(_started == 0, "start_before_seedling", "未选青苗时不能开局")
	mode.pressed.emit()
	await get_tree().process_frame
	_h.expect(_selected == 1 and not action.disabled, "seedling_not_selected",
		"点击青苗必须解锁匹配 AI")
	guide.call("configure", action, "lobby_start")
	await get_tree().process_frame
	var start_rect := action.get_global_rect()
	var start_hidden := (guide.get("_bubble") as Control).get_global_rect().intersection(start_rect).get_area() \
		+ (guide.get("_dog") as Control).get_global_rect().intersection(start_rect).get_area()
	_h.expect(start_hidden / maxf(1.0, start_rect.get_area()) <= 0.1,
		"start_target_covered", "匹配 AI 按钮被狗狗或对白遮挡")
	action.pressed.emit()
	_h.expect(_started == 1, "ai_start_missing", "匹配 AI 必须发出本地教学开始信号")
	lobby.queue_free()
	await get_tree().process_frame
	_h.finish(get_tree())
