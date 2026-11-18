extends Node3D
## 清场「火」皮肤扫光的视觉预览（只读，不写游戏数据）。
## 搭一块和战斗同角度的草地 + 中路几个替身棋子，播一次 VFXLaneClearBurst3D 的火扫光，
## 按固定帧号截 6 张拼成一排。用法：
##   godot --path . --fixed-fps 30 --resolution 1600x720 --rendering-method mobile \
##     res://tools/lane_sweep_fire_preview.tscn -- --out=<绝对路径.png> [--kind=fire]
const LaneBurst := preload("res://effects/vfx3d/modules/VFXLaneClearBurst3D.gd")
const CAMERA_POS := Vector3(0.0, 7.4, 7.0)
const CAMERA_SIZE := 7.2
const LANE := Rect2(-2.4, -5.0, 4.8, 10.0)
# 第几帧截（30 fps）：起步、扫到 1/3、过半、快到头、到头、收尾
const SHOTS := [4, 8, 12, 16, 20, 26]

var _frame := 0
var _shots: Array[Image] = []
var _out := ""
var _kind := "fire"
var _block: Node3D


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.substr(6)
		elif arg.begins_with("--kind="):
			_kind = arg.substr(7)
	if _out.is_empty():
		push_error("lane_sweep_fire_preview requires --out")
		get_tree().quit(2)
		return
	_build_stage()
	LaneBurst.warm_skin_textures(_kind)
	_block = LaneBurst.new()
	add_child(_block)


func _build_stage() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.2, 0.3, 0.18)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.7, 0.7)
	add_child(env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, 35, 0)
	add_child(light)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = CAMERA_SIZE
	cam.look_at_from_position(CAMERA_POS, Vector3.ZERO, Vector3.UP)
	cam.current = true
	add_child(cam)
	_ground(Vector2(22.0, 12.4), Vector3.ZERO, Color(0.38, 0.58, 0.30))
	# 三条路之间的分隔线
	for x in [-2.4, 2.4]:
		_ground(Vector2(0.08, 10.0), Vector3(x, 0.005, 0.0), Color(0.30, 0.46, 0.24))
	# 替身棋子：0.3 宽 0.7 高（单位实测 0.28–0.93 高）
	for pos in [Vector3(-1.0, 0, 2.6), Vector3(0.6, 0, 3.4), Vector3(1.4, 0, 1.8), Vector3(-0.4, 0, -3.6)]:
		var body := MeshInstance3D.new()
		var cap := CapsuleMesh.new()
		cap.radius = 0.16
		cap.height = 0.7
		body.mesh = cap
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.55, 0.45, 0.75) if pos.z > 0 else Color(0.75, 0.35, 0.3)
		body.material_override = m
		body.position = pos + Vector3(0, 0.35, 0)
		add_child(body)


func _ground(size: Vector2, pos: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = size
	mi.mesh = plane
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	mi.material_override = m
	mi.position = pos
	add_child(mi)


func _process(_delta: float) -> void:
	_frame += 1
	if _frame == 2:
		_block.call("play_clear", Vector3(0.4, 0.0, -3.8), LANE, [], {
			"from": Vector3(0.0, 0.0, LANE.end.y), "to": Vector3(0.0, 0.0, LANE.position.y), "kind": _kind})
	var shot_index := SHOTS.find(_frame - 2)
	if shot_index >= 0:
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		# 只要中路：屏幕中间一条
		var w := img.get_width()
		var h := img.get_height()
		var crop := img.get_region(Rect2i(int(w * 0.34), 0, int(w * 0.32), h))
		_shots.append(crop)
		if _shots.size() == SHOTS.size():
			_save_sheet()


func _save_sheet() -> void:
	var cw := _shots[0].get_width()
	var ch := _shots[0].get_height()
	var sheet := Image.create(cw * _shots.size() + 4 * (_shots.size() - 1), ch, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.1, 0.1, 0.1))
	for i in _shots.size():
		var s := _shots[i]
		s.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(s, Rect2i(0, 0, cw, ch), Vector2i(i * (cw + 4), 0))
	sheet.save_png(_out)
	print("LANE_SWEEP_PREVIEW_OK ", _out)
	get_tree().quit(0)
