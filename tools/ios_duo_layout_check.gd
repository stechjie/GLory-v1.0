extends Control

# Offline contract/scene checks using explicit iOS geometry. This does not claim
# native IME, physical touch, rendered Duo poses, or a signed package acceptance.
const Geometry := preload("res://ui/services/SafeArea.gd")
const Chat := preload("res://ui/components/ChatInputBar.gd")
const Party := preload("res://scenes/menu/PartyLobby.gd")
const Shop := preload("res://scenes/prep/PrepShopCardButton.gd")
const Announcement := preload("res://scripts/autoload/AnnouncementService.gd")
var checked := 0
var failures: Array[String] = []
var counts := {"safe": 0, "editing": 0}

class ProfileProbe extends "res://scenes/menu/ProfileScreen.gd":
	func _load() -> void:
		pass  # Exercise production UI without querying any account.

class CarrotProbe extends "res://scenes/prep/PrepUI.gd":
	func _report_carrot_camp_state() -> void:
		pass  # Test the real close path without reporting tutorial progress.

class RecorderProbe extends "res://ui/components/VoiceRecordButton.gd":
	var releases := 0
	func _release(_point: Vector2) -> void:
		releases += 1
		_held = false  # A routing sentinel, never microphone/upload/transcription.

func expect(ok: bool, message: String) -> void:
	checked += 1
	if not ok:
		failures.append(message)
		push_error("IOS_DUO: " + message)

func settle(frames: int = 5) -> void:
	for index in frames:
		await get_tree().process_frame

func snapshot(safe: Rect2, keyboard: float = 0.0) -> Dictionary:
	var view := get_viewport_rect().size
	return {"view_size": view, "window_size": view, "safe_rect": safe, "keyboard_height": keyboard}

func _ready() -> void:
	print("IOS_DUO_USER_DIR ", OS.get_user_data_dir())
	expect(OS.get_user_data_dir().contains("GloryDuoLayoutQA-"), "isolated QA user data required")
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_geometry_checks()
	SafeArea.changed.connect(_on_safe_changed)
	SafeArea.editing_changed.connect(_on_editing_changed)
	var view := get_viewport_rect().size
	var current := snapshot(Rect2(Vector2.ZERO, view))
	SafeArea.set_test_ios_geometry(current)
	var before := int(counts.safe)
	current.window_size = view * 2.0
	current.safe_rect = Rect2(Vector2.ZERO, view * 2.0)
	SafeArea.set_test_ios_geometry(current)
	expect(counts.safe == before + 1, "pixel-size change notifies even with unchanged logical insets")
	before = int(counts.safe)
	var edit_before := int(counts.editing)
	current.keyboard_height = view.y
	SafeArea.set_test_ios_geometry(current)
	expect(counts.safe == before and counts.editing == edit_before + 1, "keyboard does not alter global game safe area")
	expect(SafeArea.rect().is_equal_approx(Rect2(Vector2.ZERO, view)), "keyboard leaves game geometry unchanged")
	SafeArea.set_test_ios_geometry(snapshot(Rect2(30, 20, view.x - 80, view.y - 55)))
	await _chat_checks()
	await _profile_checks()
	await _bootstrap_checks()
	await _party_checks()
	await _voice_checks()
	await _cancel_consumer_checks()
	SafeArea.set_test_ios_geometry(null)
	SafeArea.changed.disconnect(_on_safe_changed)
	SafeArea.editing_changed.disconnect(_on_editing_changed)
	preload("res://ui/services/MusicService.gd").shutdown()
	await settle(2)
	var report := {"scope": "Godot 4.7 offline iOS geometry strategy and production scene layout; no native device or IME claim", "checked": checked, "failures": failures}
	print("IOS_DUO_LAYOUT_RESULT ", JSON.stringify(report))
	get_tree().quit(0 if failures.is_empty() else 1)

func _on_safe_changed() -> void:
	counts.safe += 1

func _on_editing_changed() -> void:
	counts.editing += 1

func _geometry_checks() -> void:
	var pixels := Vector2(1200, 900)
	var view := Vector2(1600, 1200)
	var mapped := Geometry.map_ios_safe_area(Rect2(-20, 9.4, 700.9, 850.1), pixels, view)
	var inset: Vector4 = mapped.insets
	expect(bool(mapped.valid), "partially outside native rectangle remains valid")
	expect(is_equal_approx(inset.x, 0.0) and is_equal_approx(inset.y, 10.0 * 4.0 / 3.0), "clip negative origin and round top inward")
	expect(inset.z > view.x / 3.0, "iOS accepts an inset larger than one third")
	expect(is_equal_approx((view.x - inset.z) * 0.75, 680.0), "right edge rounds inward in physical pixels")
	mapped = Geometry.map_ios_safe_area(Rect2(40, 50, 0, 0), pixels, view)
	inset = mapped.insets
	expect(bool(mapped.valid) and not (mapped.rect as Rect2).has_area(), "valid empty area stays empty")
	expect(not bool(Geometry.map_ios_safe_area(Rect2(0, 0, 100, 100), Vector2.ZERO, view).valid), "zero native bounds is unready")
	expect(not bool(Geometry.map_ios_safe_area(Rect2(NAN, 0, 100, 100), pixels, view).valid), "nonfinite native geometry rejected")
	var available := Geometry.ios_editing_rect(Rect2(20, 30, 1100, 800), Vector2(1200, 900), 300)
	expect(available.is_equal_approx(Rect2(20, 30, 1100, 570)), "keyboard intersects lower edge without double safe-area deduction")
	expect(not Geometry.ios_editing_rect(Rect2(20, 30, 1100, 800), Vector2(1200, 900), 900).has_area(), "fully covered editor stays empty")

func _chat_checks() -> void:
	var chat := Chat.new()
	add_child(chat)
	await settle()
	var field: LineEdit = chat._input
	field.text = "Duo-draft-keep-123"
	field.caret_column = 7
	field.select(4, 9)
	var field_id := field.get_instance_id()
	var view := get_viewport_rect().size
	for safe in [Rect2(80, 25, view.x - 170, view.y - 60), Rect2(24, 30, view.x * 0.55, view.y - 70), Rect2(45, 16, view.x - 90, view.y - 40)]:
		SafeArea.set_test_ios_geometry(snapshot(safe, view.y * 0.45))
		await settle()
		expect(field.get_instance_id() == field_id and field.text == "Duo-draft-keep-123", "chat resize retains field and draft")
		expect(field.has_focus() and field.get_selection_from_column() == 4 and field.get_selection_to_column() == 9, "chat resize retains focus and selection")
		expect(SafeArea.editing_rect(chat).grow(0.001).encloses(chat.get_global_rect()), "chat remains inside editing region")
		var visible := chat._ios_scroll.get_global_rect()
		expect(visible.grow(0.001).encloses(field.get_global_rect()), "focused chat field is reachable above keyboard")
	chat.queue_free()
	await settle()

func _profile_checks() -> void:
	var profile := ProfileProbe.new()
	add_child(profile)
	profile.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	profile._select_profile_tab(true)
	await settle()
	var field: LineEdit = profile._name_edit
	field.grab_focus()
	field.text = "Duo-profile-keep"
	field.caret_column = 6
	var field_id := field.get_instance_id()
	var view := get_viewport_rect().size
	SafeArea.set_test_ios_geometry(snapshot(Rect2(32, 20, view.x * 0.55, view.y - 40), view.y * 0.5))
	await settle(8)
	expect(field.get_instance_id() == field_id and field.text == "Duo-profile-keep" and field.has_focus(), "profile resize retains editor and draft")
	expect(profile._ios_scroll.get_global_rect().is_equal_approx(SafeArea.editing_rect(profile)), "profile scroll frame follows editor region")
	expect(profile._ios_scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_AUTO, "narrow profile can reach fixed-width columns")
	expect(profile._ios_scroll.get_global_rect().grow(0.001).encloses(field.get_global_rect()), "profile focused field revealed after resize")
	profile.queue_free()
	await settle()

func _bootstrap_checks() -> void:
	var boot := load("res://scenes/bootstrap/Bootstrap.tscn").instantiate() as Control
	boot.auto_start = false
	boot.auto_transition = false
	boot.entry_gate = false
	add_child(boot)
	boot.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await settle()
	expect(boot.get_node_or_null("%Title") != null and boot.get_node_or_null("%Progress") != null, "bootstrap scroll preserves scene ownership")
	var choice_id: int = boot._choice_panel.get_instance_id()
	var view := get_viewport_rect().size
	SafeArea.set_test_ios_geometry(snapshot(Rect2(28, 24, view.x - 70, view.y - 60)))
	await settle()
	expect(boot._choice_panel.get_instance_id() == choice_id, "bootstrap resize keeps login choice instance")
	expect((boot.get_node("SafeMargin") as Control).get_global_rect().is_equal_approx(SafeArea.rect()), "bootstrap content tracks safe area")
	boot.queue_free()
	await settle()

func _party_checks() -> void:
	var party := Party.new()
	party.configure_preview("host")
	add_child(party)
	party.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await settle()
	var canvas_id: int = party._canvas.get_instance_id()
	var room_before: Dictionary = party._room.duplicate(true)
	var view := get_viewport_rect().size
	SafeArea.set_test_ios_geometry(snapshot(Rect2(70, 20, view.x - 140, view.y - 50)))
	await settle()
	expect(party._canvas.get_instance_id() == canvas_id and party._room == room_before, "party resize retains room and canvas")
	expect(SafeArea.rect().grow(0.001).encloses(party._canvas.get_global_rect()), "party canvas stays in native safe region")
	party.queue_free()
	await settle()

func _voice_checks() -> void:
	var recorder := RecorderProbe.new()
	add_child(recorder)
	await settle()
	recorder._held = true
	recorder._ios_touch_index = 3
	recorder._show_actions()
	VoiceClipService._samples = PackedFloat32Array([0.1, 0.2])
	var touch := InputEventScreenTouch.new()
	touch.index = 8
	touch.canceled = true
	recorder._input(touch)
	expect(recorder._held and recorder.releases == 0, "another finger cannot end owned voice gesture")
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = false
	recorder._input(mouse)
	recorder._on_up()
	expect(recorder._held and recorder.releases == 0, "emulated mouse and button_up cannot submit touch recording")
	touch.index = 3
	recorder._input(touch)
	expect(not recorder._held and recorder._cancelled and recorder.releases == 0, "canceled owner touch never reaches send path")
	expect(VoiceClipService._samples.is_empty() and not recorder._overlay.visible, "system cancel clears samples and recording overlay")
	recorder._held = true
	recorder._ios_touch_index = 3
	touch.canceled = false
	recorder._input(touch)
	recorder._on_up()
	expect(recorder.releases == 1 and not recorder._held, "normal owner release is dispatched exactly once")
	recorder._held = true
	recorder._ios_touch_index = 4
	VoiceClipService._samples = PackedFloat32Array([0.3])
	var view := get_viewport_rect().size
	SafeArea.set_test_ios_geometry(snapshot(Rect2(18, 20, view.x - 50, view.y - 40)))
	expect(not recorder._held and recorder.releases == 1 and VoiceClipService._samples.is_empty(), "geometry change cancels held recording without sending")
	recorder.queue_free()
	await settle()

func _cancel_consumer_checks() -> void:
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = false
	mouse.canceled = true
	mouse.position = Vector2(8, 8)
	# Detached production controllers avoid account requests / starting a game.
	var carrot := CarrotProbe.new()
	# PrepShared pre-instantiates these nodes before _enter_tree; own them for cleanup.
	for panel in [carrot._shop, carrot._synergy, carrot._stats, carrot._treasure, carrot._board_hud]:
		carrot.add_child(panel)
	carrot._carrot_panel = Control.new()
	carrot._carrot_dimmer = ColorRect.new()
	add_child(carrot._carrot_panel)
	add_child(carrot._carrot_dimmer)
	carrot._on_carrot_dimmer_input(mouse)
	expect(carrot._carrot_panel.visible and carrot._carrot_dimmer.visible, "canceled mouse keeps carrot panel open")
	mouse.canceled = false
	carrot._on_carrot_dimmer_input(mouse)
	expect(not carrot._carrot_panel.visible and not carrot._carrot_dimmer.visible, "normal mouse release still closes carrot panel")
	carrot._carrot_panel.free()
	carrot._carrot_dimmer.free()
	carrot.free()

	var announcement := Announcement.new()
	announcement.seen_file = ""
	announcement._banner = CanvasLayer.new()
	add_child(announcement._banner)
	mouse.canceled = true
	announcement._on_banner_input(mouse)
	var touch := InputEventScreenTouch.new()
	touch.canceled = true
	announcement._on_banner_input(touch)
	await settle(2)
	expect(announcement.has_banner(), "canceled mouse and touch keep announcement banner open")
	mouse.canceled = false
	announcement._on_banner_input(mouse)
	await settle(2)
	expect(not announcement.has_banner(), "normal release still closes announcement banner")
	announcement.free()

	var shop := Shop.new()
	shop.size = Vector2(100, 100)
	var taps := {"count": 0}
	shop.pressed.connect(func() -> void: taps.count += 1)
	add_child(shop)
	shop._start_tap(mouse.position, -1)
	mouse.canceled = true
	shop._input(mouse)
	await settle(2)
	expect(not shop._tap_active and taps.count == 0, "canceled mouse cleans shop tap without emitting purchase click")
	shop._start_tap(mouse.position, -1)
	mouse.canceled = false
	shop._input(mouse)
	await settle(2)
	expect(not shop._tap_active and taps.count == 1, "normal shop tap still emits exactly one click")
	shop.queue_free()
	await settle(2)
