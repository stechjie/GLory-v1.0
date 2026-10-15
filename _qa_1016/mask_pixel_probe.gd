extends Node
# ============================================================================
# 聚焦遮罩**像素级**探针（非 headless —— 必须真渲染才拿得到像素）。
#
# 【为什么不能做成 headless 门禁】
#   `--headless` 不绘制，`Engine.get_frames_drawn()` 也不动，拿不到任何像素真值。
#   所以"洞到底落在哪个像素、边缘有没有 1px 亮线"这件事只能靠这个探针。
#   契约层（节点数 / 矩形 / uniform / 画序）由 `tutorial_focus_mask.tscn` 那个
#   headless 门禁负责；两者互补，别把其中一个当成全部。
#
# 【它验什么】
#   ① 遮罩**真的在压暗**（不是画了个空的 ColorRect）；
#   ② 洞落在**预期像素**上（对照 target.grow(FOCUS_HOLE_PADDING) 换算出的窗口坐标）；
#   ③ 洞的上下边界是**一行到位**的硬边 —— 逐行打印"洞左 / 洞内 / 洞右"三条横带的
#      强差异像素数，洞外那一行必须是满值、洞内那一段必须掉到底；
#      任何"少压一行 / 多压一行"的中间值都会在这张表里露出来；
#   ④ 顺带存两张 3× 放大的裁剪图，用肉眼复核洞边缘有没有缝。
#
# 【手法与坑】
#   A = 正常（遮罩可见）；B = 把**遮罩节点本身** `visible = false`（无遮罩）。
#   A-B 有差 = 被压暗的像素；没差 = 洞里。
#   ⚠ 不能改成切 shader 的 hole_on：PrepScreen 每帧都在 `_process` 里调
#     `update_overlay()`，一让出帧 uniform 就被写回去了（第一版就是栽在这上面，
#     两组图的差异只剩水流动画的噪声）。而 `visible` 不在 `_update_focus_dim`
#     的改动范围内，能稳定保留。
#
# 【跑法】
#   Godot_v4.7.2-stable_win64_console.exe --path . --resolution 1600x800 \
#       _qa_1016/mask_pixel_probe.tscn
#   输出图落在 user://qa1016/（打印绝对路径），**不污染工程目录**。
# ============================================================================

const TutorialScript := preload("res://scripts/tutorial/TutorialMode.gd")

const OUT_DIR := "user://qa1016"
# 判定"这一像素被压暗了"的阈值（三通道绝对差之和）。
# 遮罩 alpha 0.66、颜色近黑 ⇒ 亮场景每通道差 0.3+；水流动画只有零点几，
# 取 0.12 能把两者干净分开。
const STRONG := 0.12

var _prep: Node


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	GameState.reset_run()
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	_prep = packed.instantiate()
	add_child(_prep)
	await _wait(12)
	TutorialMode.start()
	await _wait(4)
	TutorialMode.attach(_prep.tutorial_target_provider())
	await _wait(6)
	TutorialMode.step = TutorialScript.Step.BUY_3
	await _wait(24)
	for res in [Vector2i(1600, 800), Vector2i(1280, 720), Vector2i(1440, 720)]:
		get_window().size = res
		await _wait(24)
		await _verify(res)
	get_tree().quit(0)


func _wait(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _verify(res: Vector2i) -> void:
	print("========== window=%s ==========" % res)
	var dim: ColorRect = TutorialMode._focus_dim[0]
	var mat := dim.material as ShaderMaterial
	TutorialMode.update_overlay()
	await _wait(2)
	var a := get_viewport().get_texture().get_image()

	dim.visible = false
	await _wait(3)
	var b := get_viewport().get_texture().get_image()
	dim.visible = true
	await _wait(2)

	var canvas: Vector2 = get_viewport().get_visible_rect().size
	var scale := Vector2(res) / canvas
	var target: Control = TutorialMode._target_control()
	var trect := target.get_global_rect() if target != null else Rect2()
	var pad := float(_script_const("FOCUS_HOLE_PADDING", 0.0))
	var want_canvas := trect.grow(pad).intersection(Rect2(Vector2.ZERO, canvas))
	var want := Rect2(want_canvas.position * scale, want_canvas.size * scale)
	print("canvas=%s scale=%.4f hole_on=%s" % [str(canvas), scale.x,
		str(mat.get_shader_parameter("hole_on"))])
	print("hole uniform=%s" % str(mat.get_shader_parameter("hole")))
	print("expected hole (window px) = %s" % _r(want))

	var w := a.get_width()
	var hgt := a.get_height()
	# 洞左右各留 12px 作为"洞外"参照带，于是洞内带一定会吃到这 24 个被压暗的列 ——
	# 这就是下面表里"洞内"那列的下限（≈24），不是噪声。
	var left_x := maxi(0, int(want.position.x) - 12)
	var right_x := mini(w - 1, int(want.end.x) + 12)
	var total := [0, 0, 0]
	for y in hgt:
		for x in w:
			if not _strong(a, b, x, y):
				continue
			if x <= left_x:
				total[0] += 1
			elif x >= right_x:
				total[2] += 1
			else:
				total[1] += 1
	print("strong-diff pixels: 洞左带=%d (宽%d) 洞内带=%d (宽%d) 洞右带=%d (宽%d)" % [
		total[0], left_x + 1, total[1], right_x - left_x - 1, total[2], w - right_x])
	print("-- 逐行：洞左 / 洞内 / 洞右 三条带的强差异像素数（洞外应满值，洞内应掉到底）--")
	var y0 := maxi(0, int(want.position.y) - 6)
	var y1 := mini(hgt - 1, int(want.end.y) + 6)
	for y in range(y0, y1 + 1):
		var c := [0, 0, 0]
		for x in w:
			if not _strong(a, b, x, y):
				continue
			if x <= left_x:
				c[0] += 1
			elif x >= right_x:
				c[2] += 1
			else:
				c[1] += 1
		var mark := ""
		if y == int(want.position.y):
			mark = "  <== 期望洞顶"
		elif y == int(want.end.y):
			mark = "  <== 期望洞底"
		print("   y=%4d  L=%4d  M=%4d  R=%4d%s" % [y, c[0], c[1], c[2], mark])

	print("full frame -> %s" % _save(a, "full_%dx%d.png" % [res.x, res.y]))
	# 洞顶 / 洞底各裁一条 320px 宽（贴着洞的左边界，含洞内与洞外两侧）的横带，
	# 上下各含 8px 邻域，3× 最近邻放大后肉眼看缝。为什么不用整宽：
	# 1600×3=4800 宽的图在查看器里会被缩回去，1px 的缝正好被抹掉。
	var bx := clampi(int(want.position.x) - 70, 0, maxi(0, w - 320))
	var top_band := Rect2i(bx, maxi(0, int(want.position.y) - 8), 320, 17)
	var bot_band := Rect2i(bx, maxi(0, int(want.end.y) - 8), 320, 17)
	print("hole-top band 3x -> %s" % _save(_crop3x(a, top_band), "top_%dx%d.png" % [res.x, res.y]))
	print("hole-bottom band 3x -> %s" % _save(_crop3x(a, bot_band), "bottom_%dx%d.png" % [res.x, res.y]))


func _save(img: Image, name: String) -> String:
	var path := OUT_DIR.path_join(name)
	var err := img.save_png(path)
	return "%s (err=%d)" % [ProjectSettings.globalize_path(path), err]


func _crop3x(img: Image, region: Rect2i) -> Image:
	var clip := region.intersection(Rect2i(0, 0, img.get_width(), img.get_height()))
	var out := img.get_region(clip)
	out.resize(clip.size.x * 3, clip.size.y * 3, Image.INTERPOLATE_NEAREST)
	return out


func _strong(a: Image, b: Image, x: int, y: int) -> bool:
	var ca := a.get_pixel(x, y)
	var cb := b.get_pixel(x, y)
	return absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) > STRONG


func _script_const(name: String, fallback: Variant) -> Variant:
	var script_obj: Variant = TutorialScript
	if script_obj == null or not script_obj.has_method("get_script_constant_map"):
		return fallback
	var map: Variant = script_obj.call("get_script_constant_map")
	if not (map is Dictionary):
		return fallback
	return (map as Dictionary).get(name, fallback)


func _r(r: Rect2) -> String:
	return "(%.2f,%.2f %.2fx%.2f)" % [r.position.x, r.position.y, r.size.x, r.size.y]
