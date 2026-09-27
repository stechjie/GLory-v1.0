extends Control

# 棋盘皮肤预览：在编辑器里打开本场景按 F6，点上面的按钮换皮肤（docs/棋盘皮肤.md）。
#
# 摆的是真的摆放界面（PrepScreen.tscn），看到的就是对局里的样子。
# 画面只看不点：盖了一层吃输入的遮罩 —— 在这里拖棋子会触发 SaveManager.save_run()，
# 把本机的对局存档写成这份假数据。
#
# 「生成预览图」把当前画面截一张写进 assets/skins/prep/<皮肤 id>/preview.png，
# 就是备战页和商城卡片上那张。写完切回编辑器让它导入（或跑一次 --import）才生效。

const PrepSkin := preload("res://scenes/prep/PrepSkin.gd")
const PREP_SCENE_PATH := "res://scenes/prep/PrepScreen.tscn"

# 棋盘上摆几个真棋子，看贴图和模型叠在一起的样子。
const UNIT_PLACEMENTS := [
	{"id": "human_swordsman", "zone": "board", "slot": 5},
	{"id": "dark_fear", "zone": "board", "slot": 6},
	{"id": "human_archer", "zone": "board", "slot": 9},
	{"id": "dark_queen", "zone": "board", "slot": 10},
	{"id": "human_archer", "zone": "bench", "slot": 1},
	{"id": "dark_fear", "zone": "bench", "slot": 3},
	{"id": "human_swordsman", "zone": "bench", "slot": 6},
]
const TEAM_PETS := {0: "pet_cat", 1: "pet_rabbit", 2: "pet_mushroom", 3: "pet_rabbit", 4: "pet_cat", 5: "pet_mushroom"}
# 预览图从 1600×720 的画面里截哪一块（16:9，棋盘、待命区、萝卜、商店按钮都在里面），再缩到多大。
const PREVIEW_CROP := Rect2i(200, 0, 1280, 720)
const PREVIEW_SIZE := Vector2i(640, 360)

var team_pets_box: CheckBox
var prep: Control
var _prep_host: Control
var _toolbar_layer: CanvasLayer
var _status: Label
var _building := false


func _ready() -> void:
	DataRegistry.ensure_loaded()
	_prep_host = Control.new()
	_prep_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_prep_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_prep_host)

	_toolbar_layer = CanvasLayer.new()
	_toolbar_layer.layer = 100
	add_child(_toolbar_layer)
	var blocker := Control.new()
	blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	_toolbar_layer.add_child(blocker)

	var bar := PanelContainer.new()
	bar.position = Vector2(8.0, 8.0)
	_toolbar_layer.add_child(bar)
	var rows := VBoxContainer.new()
	bar.add_child(rows)
	var buttons := HBoxContainer.new()
	rows.add_child(buttons)
	for entry in PrepSkin.catalog():
		var b := Button.new()
		b.text = "%s（%s）" % [str(entry.get("name", "")), str(entry.get("id", ""))]
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(show_skin.bind(str(entry.get("id", ""))))
		buttons.add_child(b)
	var shot := Button.new()
	shot.text = "生成预览图"
	shot.focus_mode = Control.FOCUS_NONE
	shot.pressed.connect(save_preview)
	buttons.add_child(shot)
	team_pets_box = CheckBox.new()
	team_pets_box.text = "萝卜旁摆 6 只宠物（组队局）"
	team_pets_box.focus_mode = Control.FOCUS_NONE
	team_pets_box.toggled.connect(func(_on: bool) -> void: _refresh_carrot())
	rows.add_child(team_pets_box)
	_status = Label.new()
	rows.add_child(_status)

	_stage_game_state()
	show_skin(PrepSkin.DEFAULT_ID)


func show_skin(skin_id: String) -> void:
	if _building:
		return
	_building = true
	PrepSkin.active_id = skin_id
	if prep != null:
		prep.queue_free()
		await get_tree().process_frame
	prep = (load(PREP_SCENE_PATH) as PackedScene).instantiate()
	# 不分帧构建时 startup_ready 在 add_child 里就发完了，所以先接信号再进树。
	var started := {"done": false}
	prep.startup_ready.connect(func() -> void: started.done = true, CONNECT_ONE_SHOT)
	_prep_host.add_child(prep)
	while not started.done:
		await get_tree().process_frame
	_refresh_carrot()
	_status.text = "当前：%s" % skin_id
	_building = false


# 截当前画面（藏掉上面这排按钮）写成当前皮肤的 preview.png。返回写到哪了，失败返回空串。
func save_preview() -> String:
	if prep == null or _building:
		return ""
	_toolbar_layer.visible = false
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	_toolbar_layer.visible = true
	var crop := PREVIEW_CROP.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	image = image.get_region(crop)
	image.resize(PREVIEW_SIZE.x, PREVIEW_SIZE.y, Image.INTERPOLATE_LANCZOS)
	var path := PrepSkin.SKIN_FILE % [PrepSkin.active_id, "preview"]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	if image.save_png(path) != OK:
		_status.text = "预览图没写成：%s" % path
		return ""
	_status.text = "已写 %s —— 切回编辑器让它导入" % path
	return path


# 组队局萝卜旁最多 6 只宠物（后排 3 只最容易被萝卜挡脸）。单人预览里借 NetworkService 的
# 组队字段摆一次，摆完立刻还原 —— 这几个字段只是转到会话对象上的普通属性，改它们不发信号。
func _refresh_carrot() -> void:
	if prep == null or not is_instance_valid(prep):
		return
	if not team_pets_box.button_pressed:
		prep.refresh_carrot_gathering()
		return
	var saved := [NetworkService.team_active, NetworkService.team_slot_states,
		NetworkService.team_local_slot, NetworkService.team_seat_pets]
	NetworkService.team_active = true
	NetworkService.team_slot_states = ["player", "player", "player", "player", "player", "player"]
	NetworkService.team_local_slot = 4
	NetworkService.team_seat_pets = TEAM_PETS.duplicate()
	prep.refresh_carrot_gathering()
	NetworkService.team_active = saved[0]
	NetworkService.team_slot_states = saved[1]
	NetworkService.team_local_slot = saved[2]
	NetworkService.team_seat_pets = saved[3]


func _stage_game_state() -> void:
	GameState.reset_run()
	# 第 3 回合：下一轮是打怪，不会弹 PVP 预警。采集回合等于当前回合，
	# 进摆放界面时就不会再发萝卜、也就不会触发存档。
	GameState.round_index = 3
	GameState.last_harvest_round = 3
	GameState.gold = 48
	GameState.carrots = 12
	var definitions := {}
	for unit in DataRegistry.get_table("race_units").get("units", []):
		definitions[str(unit.get("id", ""))] = unit
	for i in UNIT_PLACEMENTS.size():
		var placement: Dictionary = UNIT_PLACEMENTS[i]
		var unit_id := str(placement.id)
		if not definitions.has(unit_id):
			continue
		var cell := {"uid": "skin_review_%d" % i, "id": unit_id, "star": 1,
			"def": (definitions[unit_id] as Dictionary).duplicate(true)}
		if placement.zone == "board":
			GameState.board_slots[int(placement.slot)] = cell
		else:
			GameState.bench_slots[int(placement.slot)] = cell
