extends Node2D

# 棋盘联动生物（凤凰 / 锦鲤 …）的单独预览：草绿底 + 几个圆点当棋子，拍浴火登场 → 巡航 → 冲刺点燃。
# 只看凤凰本体的造型和动作，不起整个备战界面（快）。透视、棋子遮挡要看真棋盘用 prep_phoenix_capture。
# WARN: 必须不带 --headless：
#   "Godot_v4.7-stable_win64_console.exe" --path . res://tools/phoenix_preview.tscn
# 输出 reports/phoenix_preview/p_XX_<毫秒>.png + sheet.png

# 默认看凤凰；`-- --creature koi` 之类换别的生物（键 = creatures/ 下 Prep<Name>2D.gd 的小写名）
const CREATURES := {
	"phoenix": "res://scenes/prep/effects/creatures/PrepPhoenix2D.gd",
	"koi": "res://scenes/prep/effects/creatures/PrepKoi2D.gd",
	"snake": "res://scenes/prep/effects/creatures/PrepSnake2D.gd",
	"bats": "res://scenes/prep/effects/creatures/PrepBats2D.gd",
	"icechain": "res://scenes/prep/effects/creatures/PrepIceChain2D.gd",
	"scorpion": "res://scenes/prep/effects/creatures/PrepScorpion2D.gd",
	"crab": "res://scenes/prep/effects/creatures/PrepCrab2D.gd",
}
const OUT_DIR := "res://reports/phoenix_preview"
const SIZE := Vector2i(900, 720)
const SHOTS := 24
const EVERY_SEC := 0.28
const PIECES := [Vector2(0.36, 0.36), Vector2(0.58, 0.36), Vector2(0.36, 0.66), Vector2(0.58, 0.66)]

var _canvas_uv := Rect2(0.20, 0.14, 0.54, 0.74)


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("phoenix_preview 需要真实渲染后端")
		get_tree().quit(2)
		return
	var dir := ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + f)
	DisplayServer.window_set_size(SIZE)
	get_window().size = SIZE
	RenderingServer.set_default_clear_color(Color(0.62, 0.78, 0.24))
	queue_redraw()
	var key := "phoenix"
	var args := OS.get_cmdline_user_args()
	var at := args.find("--creature")
	if at >= 0 and at + 1 < args.size():
		key = args[at + 1]
	var bird: Node2D = (load(CREATURES.get(key, CREATURES["phoenix"])) as Script).new()
	add_child(bird)
	bird.call("setup", _canvas_uv.position, _canvas_uv.size, Vector2(SIZE), 150.0, _pieces, 11)
	bird.set("_next_swoop", 2.2)
	await get_tree().create_timer(0.3).timeout
	bird.call("appear_with_rebirth")
	var frames: Array[Image] = []
	var ms := 0
	for i in SHOTS:
		await get_tree().create_timer(EVERY_SEC).timeout
		ms += int(EVERY_SEC * 1000.0)
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/p_%02d_%05d.png" % [dir, i, ms])
		frames.append(img)
	var cols := 6
	var cell := Vector2i(300, 240)
	var sheet := Image.create(cell.x * cols, cell.y * ceili(float(frames.size()) / cols), false, Image.FORMAT_RGBA8)
	for i in frames.size():
		var im := frames[i].duplicate() as Image
		im.convert(Image.FORMAT_RGBA8)
		im.resize(cell.x, cell.y, Image.INTERPOLATE_BILINEAR)
		sheet.blit_rect(im, Rect2i(Vector2i.ZERO, cell), Vector2i((i % cols) * cell.x, (i / cols) * cell.y))
	sheet.save_png(dir + "/sheet.png")
	print("PHOENIX_PREVIEW dir=%s" % dir)
	get_tree().quit(0)


func _pieces() -> Array:
	var out: Array = []
	for i in PIECES.size():
		out.append({"index": i, "pos": PIECES[i]})
	return out


func _draw() -> void:
	for p in PIECES:
		var px: Vector2 = (p - _canvas_uv.position) / _canvas_uv.size * Vector2(SIZE)
		draw_circle(px, 22.0, Color(0.15, 0.2, 0.35))
