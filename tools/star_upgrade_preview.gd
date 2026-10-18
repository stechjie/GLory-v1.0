extends Node

# 升星特效（scenes/prep/effects/PrepStarUpgradeBurst.gd）的**截帧预览**。
#
# 为什么需要它：参数表上的「0.12 → 0.26，0.35 秒，软边」说不清好不好看。先把
# 2★ / 3★ 的整段动作逐帧渲出来给 Leno 挑，定稿了再接进 PrepBoardController 的两个
# 合成函数 —— 比直接接进去再返工省事。同先例：tools/carrot_star_burst_capture.gd。
#
# ⚠️ **必须不带 --headless 运行**：headless 是 dummy 渲染后端，抓出来是空图。
#   "Godot_v4.7-stable_win64_console.exe" --path . res://tools/star_upgrade_preview.tscn
# 输出：reports/star_upgrade_preview/（reports/ 在 .gitignore 里，不会进版本库）
#
# ★ 相机**角度**与备战棋盘一致（PrepBoardModels.PREP_RIVER_CAMERA_*），只是沿同一条
#   视线拉近 —— 角度变了，贴地的环在屏幕上的椭圆度就变了，那预览就代表不了真实观感。
#   拉近是为了让一格填满画面；真实游戏里它只占 4×4 棋盘的十六分之一。
#
# ★ 取样用 effect.seek(t) 而不是等真实帧推进：帧率一抖，抓出来的时刻就对不上，
#   两档之间也没法比。seek 让同一个 t 每次都渲出同一张图。

const BurstFx := preload("res://scenes/prep/effects/PrepStarUpgradeBurst.gd")
const CELL_MARK_PATH := "res://assets/board/prep_2_5d/board_cell_mark.png"

const OUT_DIR := "res://reports/star_upgrade_preview"
const WINDOW := Vector2i(900, 900)
const SETTLE_FRAMES := 4

# 备战棋盘相机（PrepBoardModels）。位置这里会沿同一条视线重算，只有角度与 FOV 照抄。
const PREP_CAMERA_POSITION := Vector3(0.0, 3.8, 2.0)
const PREP_CAMERA_TARGET := Vector3(0.0, -0.07, -0.03)
const PREP_CAMERA_FOV := 44.0
# 沿视线拉近到这个距离（原距离约 4.37）。
# 星星最远散到约 1.6 格（≈0.96 世界半径），相机得退到这个距离才框得住整片。
const PREVIEW_DISTANCE := 2.4

# 每一档取几帧。8 帧 × 两档，拼成两张 4×2 的联络表，一眼能看完整段动作。
const FRAMES_PER_STAR := 8
const SHEET_COLS := 4
const SHEET_CELL := 300

# 备战棋子渲染高度（PrepBoardModels 里 FOUR_STAR_AURA.fit_to_actor 的第三参）。
# 放一根这么高的替身柱子，图上才看得出环和棋子的比例关系。
const UNIT_HEIGHT := 0.32
# 格子站位图的世界尺寸（PrepBoardModels.PREP_CELL_MARK_SIZE）。
const CELL_MARK_SIZE := 0.6

var _dir := ""
var _label: Label
var _stage: Node3D
var _shots := 0


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("star_upgrade_preview 需要真实渲染后端，请去掉 --headless")
		get_tree().quit(2)
		return
	_dir = ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(_dir)
	DisplayServer.window_set_size(WINDOW)
	_build_stage()
	await _settle(20)

	for star in [2, 3]:
		await _capture_star(star)

	print("STAR_UPGRADE_PREVIEW shots=%d dir=%s" % [_shots, _dir])
	get_tree().quit(0)


func _build_stage() -> void:
	_stage = Node3D.new()
	add_child(_stage)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	# 偏暗的草地色：真实棋盘底图是暖绿草地，纯黑背景会让加色混合的环假亮一档。
	env.background_color = Color(0.09, 0.13, 0.08)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.62, 0.52)
	env.ambient_light_energy = 0.6
	env_node.environment = env
	_stage.add_child(env_node)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-55.0, -30.0, 0.0)
	key.light_energy = 0.8
	key.shadow_enabled = false
	_stage.add_child(key)

	# 地面：一大块草地色 quad，让环有东西可以压着。
	var ground := MeshInstance3D.new()
	var ground_quad := QuadMesh.new()
	ground_quad.size = Vector2(3.0, 3.0)
	ground.mesh = ground_quad
	ground.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.22, 0.30, 0.17)
	ground_mat.roughness = 1.0
	ground.material_override = ground_mat
	_stage.add_child(ground)

	# 真·格子站位图：环的峰值半径 0.20 就是照它的圈定的，必须同屏可见才验得了。
	var mark := MeshInstance3D.new()
	var mark_quad := QuadMesh.new()
	mark_quad.size = Vector2.ONE * CELL_MARK_SIZE
	mark.mesh = mark_quad
	mark.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	mark.position = Vector3(0.0, 0.005, 0.0)
	var mark_mat := StandardMaterial3D.new()
	mark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mark_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mark_mat.albedo_texture = load(CELL_MARK_PATH)
	mark.material_override = mark_mat
	_stage.add_child(mark)

	# 替身棋子：0.32 高的柱子。不用真模型 —— 这里要看的是环与光尘，
	# 真模型的 idle 动作反而会让两档之间的对比图不可比。
	var stand_in := MeshInstance3D.new()
	var body := CapsuleMesh.new()
	body.height = UNIT_HEIGHT
	body.radius = UNIT_HEIGHT * 0.22
	stand_in.mesh = body
	stand_in.position = Vector3(0.0, UNIT_HEIGHT * 0.5, 0.0)
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.46, 0.42, 0.38)
	stand_in.material_override = body_mat
	_stage.add_child(stand_in)

	var camera := Camera3D.new()
	camera.fov = PREP_CAMERA_FOV
	# 同角度、不同距离：方向取自备战相机，位置沿这条方向重新放。
	var dir := (PREP_CAMERA_TARGET - PREP_CAMERA_POSITION).normalized()
	camera.look_at_from_position(PREP_CAMERA_TARGET - dir * PREVIEW_DISTANCE,
		PREP_CAMERA_TARGET, Vector3.UP)
	camera.current = true
	_stage.add_child(camera)

	# 每张图自带说明，免得看图的时候还要对文件名。
	var layer := CanvasLayer.new()
	add_child(layer)
	_label = Label.new()
	_label.position = Vector2(18, 14)
	_label.add_theme_font_size_override("font_size", 22)
	_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_label.add_theme_constant_override("outline_size", 5)
	layer.add_child(_label)


func _capture_star(star: int) -> void:
	var fx: Node3D = BurstFx.new()
	# 预览自己按 seek 取样，别让 _process 也在后台推进。
	fx.set_process(false)
	_stage.add_child(fx)
	fx.call("play", star)
	fx.set_process(false)
	var duration: float = fx.call("total_duration")
	var frames: Array[Image] = []
	for i in FRAMES_PER_STAR:
		var t := duration * float(i) / float(FRAMES_PER_STAR - 1)
		fx.call("seek", t)
		_label.text = "%d★  t = %.3fs / %.3fs" % [star, t, duration]
		await _settle()
		var image := get_viewport().get_texture().get_image()
		var name := "%dstar_%02d_t%.3f" % [star, i, t]
		image.save_png("%s/%s.png" % [_dir, name])
		_shots += 1
		frames.append(image)
	_save_sheet(frames, "%dstar_sheet" % star)
	fx.queue_free()


# 联络表：8 帧拼成 4×2 一张图。挑方案的人要看的是「整段动作长什么样」，
# 一张张翻会丢掉节奏感。
func _save_sheet(frames: Array[Image], out_name: String) -> void:
	if frames.is_empty():
		return
	var rows := int(ceil(float(frames.size()) / float(SHEET_COLS)))
	var sheet := Image.create(SHEET_COLS * SHEET_CELL, rows * SHEET_CELL, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.05, 0.06, 0.05))
	for i in frames.size():
		var cell := frames[i].duplicate() as Image
		# 视口抓下来的图不一定是 RGBA8，blit_rect 要求两边格式一致（不转会直接报错）。
		cell.convert(Image.FORMAT_RGBA8)
		cell.resize(SHEET_CELL, SHEET_CELL, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(cell, Rect2i(Vector2i.ZERO, cell.get_size()),
			Vector2i((i % SHEET_COLS) * SHEET_CELL, (i / SHEET_COLS) * SHEET_CELL))
	sheet.save_png("%s/%s.png" % [_dir, out_name])
	_shots += 1


func _settle(frames: int = SETTLE_FRAMES) -> void:
	for i in frames:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
