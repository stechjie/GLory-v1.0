extends Node

# 10.11 第 8 条：把「萝卜营地 + 天 / 地 / 人升级石」的柔和星爆**真渲染**出来存图。
#
# 为什么需要它：tools/star_burst_check 验的是合同（可见性规则、纯 _draw()、呼吸不归零），
# 回答不了「亮起来到底好不好看、会不会挡字、三格颜色分不分得清」。同 announcement_ui_capture 的理由。
#
# ⚠️ **必须不带 --headless 运行**：headless 是 dummy 渲染后端，抓出来是空图。
#   Godot_v4.7.2-stable_win64_console.exe --path . res://tools/carrot_star_burst_capture.tscn
# 输出：E:/Users/WINDOWS/Desktop/其他/work/_qa_1011/carrot_burst_shots/*.png
#
# ★ 裁剪坐标要过换算：`Control.get_global_rect()` 给的是**画布坐标**，而截图是**窗口像素**；
#   `stretch_mode=canvas_items` + `expand` 下两者差一个比例因子（本仓老坑）。
#   这里用 img_size / viewport_visible_rect 现算，别硬编码。

const StarBurstScript := preload("res://ui/components/StarBurst.gd")
const PrepScene := preload("res://scenes/prep/PrepScreen.tscn")

const OUT_DIR := "E:/Users/WINDOWS/Desktop/其他/work/_qa_1011/carrot_burst_shots"
const FALLBACK_DIR := "res://reports/carrot_star_burst"
const WINDOW := Vector2i(1600, 900)
const SETTLE_FRAMES := 30

# 三格石头各自的颜色（与 CarrotCampPanelV3._stone_burst_color 一致）+ 营地入口最终配色。
const SKY := Color(0.55, 0.85, 1.0)
const LAND := Color(0.58, 1.0, 0.62)
const REN := Color(1.0, 0.52, 0.5)
# 入口按钮最终版（用户 10.11 口径：明暗交替 / 从图标中心向外 / 不要黄色）。这三个数
# 必须与 PrepUI.gd 的 carrot_burst.* 一致，否则截图就代表不了真实产品。
const ENTRY_COLOR := Color(0.62, 0.86, 1.0)
const ENTRY_SCALE := 1.3
const ENTRY_SHORT_ALPHA := 0.4
const ENTRY_WIDTH := 1.5
# 上一版（已被用户推翻）—— 只用于「对比图」里当反例，别拿去接产品。
const OLD_COLOR := Color(1.0, 0.95, 0.74)
const OLD_SCALE := 2.2

var _dir := ""
var _shots := 0


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("carrot_star_burst_capture 需要真实渲染后端，请去掉 --headless")
		get_tree().quit(2)
		return
	_dir = OUT_DIR
	if DirAccess.make_dir_recursive_absolute(_dir) != OK:
		_dir = ProjectSettings.globalize_path(FALLBACK_DIR)
		DirAccess.make_dir_recursive_absolute(_dir)
	DisplayServer.window_set_size(WINDOW)
	await _settle()

	await _shot_burst_showcase()
	await _shot_breath_phases()
	await _shot_prep_camp()

	print("CARROT_STAR_BURST_CAPTURE shots=%d dir=%s" % [_shots, _dir])
	get_tree().quit(0)


# ── 1. 星爆本体：四种颜色并排（看清「由内向外衰减的星芒 + 核光」） ──────────────────
func _shot_burst_showcase() -> void:
	var canvas := _stage()
	# 前三个 = 石头格（第一版参数，用户口径「三格不动」）；后两个 = 入口按钮的
	# 「上一版 vs 最终版」，一眼看出用户到底要什么。
	var specs := [
		{"label": "天 sky（石头·第一版）", "color": SKY, "scale": 1.0, "short": 1.0, "w": 1.0},
		{"label": "地 land（石头·第一版）", "color": LAND, "scale": 1.0, "short": 1.0, "w": 1.0},
		{"label": "人 ren（石头·第一版）", "color": REN, "scale": 1.0, "short": 1.0, "w": 1.0},
		{"label": "入口·旧（暖金 2.2 无交替）", "color": OLD_COLOR, "scale": OLD_SCALE, "short": 1.0, "w": 1.0},
		{"label": "入口·新（冰蓝 1.3 明暗交替）", "color": ENTRY_COLOR, "scale": ENTRY_SCALE,
			"short": ENTRY_SHORT_ALPHA, "w": ENTRY_WIDTH},
	]
	for i in specs.size():
		var spec: Dictionary = specs[i]
		_stamp_burst(canvas, Vector2(84.0 + 300.0 * float(i), 280.0), Vector2(240, 240),
			spec["color"], str(spec["label"]), PI * 0.5,
			float(spec["scale"]), float(spec["short"]), float(spec["w"]))
	await _settle()
	await _shot("01_burst_colors")
	canvas.queue_free()


# ── 2. 呼吸明暗：同一个星爆在 亮 / 中 / 暗 三个相位（周期 5 秒，最暗不归零） ──────────
func _shot_breath_phases() -> void:
	var canvas := _stage()
	var phases := [{"p": PI * 0.5, "t": "最亮 phase=π/2"}, {"p": 0.0, "t": "中间 phase=0"}, {"p": PI * 1.5, "t": "最暗 phase=3π/2"}]
	for i in phases.size():
		var item: Dictionary = phases[i]
		# 用入口按钮**最终参数**跑三相位：这样「明暗交替（长芒亮/短芒暗）」和
		# 「极慢呼吸」是同屏可见的，一眼能看出不是闪烁。
		_stamp_burst(canvas, Vector2(150.0 + 420.0 * float(i), 280.0), Vector2(260, 260),
			ENTRY_COLOR, str(item["t"]), float(item["p"]),
			ENTRY_SCALE, ENTRY_SHORT_ALPHA, ENTRY_WIDTH)
	await _settle()
	await _shot("02_breath_phases")
	canvas.queue_free()


# ── 3. 实战：备战界面上的入口按钮 + 打开营地后的天地人石头栏 ────────────────────────
func _shot_prep_camp() -> void:
	# 同 tools/star_burst_check：置组队态 + reset，让「萝卜营地」入口可见。
	var was_active := NetworkService.team_active
	var was_host := NetworkService.is_host
	GameState.reset_run()
	NetworkService.team_active = true
	NetworkService.is_host = false

	var screen: Node = PrepScene.instantiate()
	add_child(screen)
	await _settle()

	# 天 2 / 地 1 / 人 0：亮的恰好是「有存货」的那两格 + 入口按钮（0 那格不亮，好对比）。
	_apply_stones({"sky": 2, "land": 1, "ren": 0})
	_refresh(screen)

	# ① 营地关着：只有入口按钮在散发星爆。
	await _settle()
	await _shot("03_prep_camp_closed")
	await _zoom("03_prep_camp_closed", "04_entry_button_zoom",
		(screen.get("_carrot_button") as Control), 12)

	# ② 打开营地并切到「升级石」页：左侧石头栏的三格一起亮。
	screen.call("_toggle_carrot_camp")
	await _settle()
	var panel = screen.get("_carrot_panel")
	if panel != null and is_instance_valid(panel):
		panel.call("_show_page", 1)
		panel.call("refresh")
	await _settle()
	await _shot("05_prep_camp_stone_tab")
	if panel != null and is_instance_valid(panel):
		await _zoom("05_prep_camp_stone_tab", "06_stone_rail_zoom",
			(panel.get("_stone_rail") as Control), 12)

	# ③ 全部清零：星爆必须一起灭掉（证明不是「只亮不灭」）。
	_apply_stones({"sky": 0, "land": 0, "ren": 0})
	_refresh(screen)
	await _settle()
	await _shot("07_prep_camp_zero_stones")

	screen.queue_free()
	await _settle()
	NetworkService.team_active = was_active
	NetworkService.is_host = was_host


# ── 工具 ────────────────────────────────────────────────────────────────────────
func _stage() -> Control:
	var bg := ColorRect.new()
	bg.color = Color(0.055, 0.075, 0.058)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	return bg


func _stamp_burst(parent: Control, pos: Vector2, size: Vector2, color: Color,
		caption: String, phase: float,
		scale: float = 1.0, short_alpha: float = 1.0, width_scale: float = 1.0) -> void:
	var burst: Control = StarBurstScript.new()
	burst.setup(color, scale)
	# 「明暗交替」在组件里是默认关闭的旋钮，这里照产品里那样显式打开。
	burst.short_ray_alpha = short_alpha
	burst.ray_width_scale = width_scale
	burst.position = pos
	burst.size = size
	# 相位写死，截图才是确定的（否则每次抓到哪一相位全看运气）。
	burst.set("_phase", phase)
	parent.add_child(burst)
	var label := Label.new()
	label.text = caption
	label.position = pos + Vector2(-30.0, size.y + 8.0)
	label.size = Vector2(size.x + 60.0, 30.0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", color.lightened(0.25))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)


func _apply_stones(stones: Dictionary) -> void:
	NetworkService._apply_carrot_state({
		"carrot_authoritative": true,
		"carrots": 260,
		"harvest_tech_level": 1,
		"merc_carrots_spent_total": 0,
		"last_harvest_round": GameState.round_index,
		"last_harvest_gain": 0,
		"stone_draw_used_round": -1,
		"team_upgrade_stones": stones.duplicate(),
	})


func _refresh(screen: Node) -> void:
	var panel = screen.get("_carrot_panel")
	if panel != null and is_instance_valid(panel):
		panel.call("refresh")
	screen.call("_refresh_carrot_counter")


func _settle(frames: int = SETTLE_FRAMES) -> void:
	for _i in frames:
		await get_tree().process_frame


func _shot(shot_name: String) -> void:
	await _settle(4)
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [_dir, shot_name]
	var err := image.save_png(path)
	if err == OK:
		_shots += 1
		print("  saved %s (%dx%d)" % [path, image.get_width(), image.get_height()])
	else:
		push_error("保存失败 %s: %d" % [path, err])


# 把最近一张图按控件矩形裁出来放大 2×（坐标要过 画布→窗口 的换算）。
func _zoom(from_name: String, to_name: String, node: Control, pad: int) -> void:
	if node == null or not is_instance_valid(node):
		push_warning("_zoom 跳过 %s：控件不存在" % to_name)
		return
	var image := Image.load_from_file("%s/%s.png" % [_dir, from_name])
	if image == null:
		push_warning("_zoom 跳过 %s：读不到 %s.png" % [to_name, from_name])
		return
	var canvas := get_viewport().get_visible_rect().size
	var factor := Vector2(float(image.get_width()) / canvas.x, float(image.get_height()) / canvas.y)
	var rect := node.get_global_rect()
	var x0 := int(round(rect.position.x * factor.x)) - pad
	var y0 := int(round(rect.position.y * factor.y)) - pad
	var x1 := int(round(rect.end.x * factor.x)) + pad
	var y1 := int(round(rect.end.y * factor.y)) + pad
	var clip := Rect2i(x0, y0, x1 - x0, y1 - y0).intersection(
		Rect2i(0, 0, image.get_width(), image.get_height()))
	if clip.size.x <= 0 or clip.size.y <= 0:
		push_warning("_zoom 跳过 %s：裁剪区为空 %s" % [to_name, str(clip)])
		return
	var crop := image.get_region(clip)
	crop.resize(clip.size.x * 2, clip.size.y * 2, Image.INTERPOLATE_NEAREST)
	var err := crop.save_png("%s/%s.png" % [_dir, to_name])
	if err == OK:
		_shots += 1
		print("  saved %s (%dx%d, 2x from %s)" % [to_name, crop.get_width(), crop.get_height(), from_name])
	else:
		push_error("裁剪保存失败 %s: %d" % [to_name, err])
