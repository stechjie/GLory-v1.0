extends Control

# 慷慨命运的掷骰演出，约 2 秒出结果，不挡操作（不接收鼠标）。
#
#   0.00  骰子从 logo 处甩出，沿弧线飞向屏幕中央并放大
#   0.30  落地翻滚：每半圈换一面，弹两下，越滚越慢
#   1.70  停在结果那一面
#   2.00  发 revealed —— 宿主此刻才把金币改掉、刷新界面
#         赢：金光环 + 金色「+N」上浮 + 星光；输：红闪 + 红色「-N」下沉
#   2.90  发 finished，节点自己释放
#
# 结果在开演前就定了（宿主先开奖），骰子只负责演：face 由输赢挑，1-3 输、4-6 赢。
# 减弱动态效果时不翻滚不飞行，结果那一面直接淡入。
# 不用外部贴图：骰子、点数、光晕都是 _draw() 画的。
#
# 节点被提前移出树（切场景、开战）时也会补发 revealed，宿主那边的结算不会丢。

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const SfxService := preload("res://ui/services/SfxService.gd")

signal revealed
signal finished

const THROW_SEC := 0.30
const SETTLE_AT := 1.70
const REVEAL_AT := 2.00
const END_AT := 2.90
const DIE_SIZE := 112.0
const BODY := Color(1.0, 0.86, 0.42)
const BODY_SHADE := Color(0.86, 0.60, 0.16)
const EDGE := Color(0.42, 0.24, 0.04)
const PIP := Color(0.55, 0.04, 0.05)
const WIN_COLOR := Color(1.0, 0.84, 0.30)
const LOSE_COLOR := Color(1.0, 0.25, 0.22)
# 点数在单位格（-1..1）里的位置。
const PIPS := {
	1: [Vector2(0, 0)],
	2: [Vector2(-0.5, -0.5), Vector2(0.5, 0.5)],
	3: [Vector2(-0.5, -0.5), Vector2(0, 0), Vector2(0.5, 0.5)],
	4: [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(-0.5, 0.5), Vector2(0.5, 0.5)],
	5: [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0, 0), Vector2(-0.5, 0.5), Vector2(0.5, 0.5)],
	6: [Vector2(-0.5, -0.55), Vector2(0.5, -0.55), Vector2(-0.5, 0), Vector2(0.5, 0), Vector2(-0.5, 0.55), Vector2(0.5, 0.55)],
}

var _t := 0.0
var _from := Vector2.ZERO
var _stage := Vector2.ZERO
var _won := false
var _face := 6
var _shown_face := 1
var _delta_text := ""
var _reduced := false
var _revealed := false
var _rng := RandomNumberGenerator.new()
var _sparks: Array[Dictionary] = []


func _ready() -> void:
	set_process(false)
	tree_exiting.connect(_emit_reveal_once)


# from：骰子出手的屏幕位置（logo 中心，全局坐标）。gold_delta：结算后金币变化，正赢负输。
func play(from: Vector2, won: bool, gold_delta: int, options: Dictionary = {}) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var view := get_viewport_rect().size
	_stage = Vector2(view.x * 0.5, view.y * 0.45) - global_position
	_from = from - global_position
	_won = won
	_rng.randomize()
	_face = _rng.randi_range(4, 6) if won else _rng.randi_range(1, 3)
	_shown_face = _rng.randi_range(1, 6)
	_delta_text = ("+%d" % gold_delta) if gold_delta >= 0 else ("%d" % gold_delta)
	_reduced = bool(options.get("reduced_motion", Tokens.reduced_motion()))
	if bool(options.get("sound", true)):
		SfxService.play(SfxService.CUE_UI_POPUP)
	_t = 0.0
	set_process(true)
	queue_redraw()


func rolled_face() -> int:
	return _face


func _process(delta: float) -> void:
	_t += delta
	if not _revealed and _t >= REVEAL_AT:
		_emit_reveal_once()
		if not _reduced:
			_spawn_sparks()
		SfxService.play(SfxService.CUE_UI_CURRENCY_GAIN if _won else SfxService.CUE_UI_CURRENCY_SPEND)
	for s in _sparks:
		s["p"] = (s["p"] as Vector2) + (s["v"] as Vector2) * delta
		s["v"] = (s["v"] as Vector2) * 0.94 + Vector2(0, 260.0 if not _won else 40.0) * delta
	if _t >= END_AT:
		set_process(false)
		finished.emit()
		queue_free()
		return
	queue_redraw()


func _emit_reveal_once() -> void:
	if _revealed:
		return
	_revealed = true
	revealed.emit()


func _spawn_sparks() -> void:
	var color := WIN_COLOR if _won else LOSE_COLOR
	var count := 18 if _won else 10
	for i in count:
		var a := _rng.randf() * TAU
		var speed := _rng.randf_range(160.0, 360.0)
		_sparks.append({"p": _stage, "v": Vector2(cos(a), sin(a)) * speed - Vector2(0, 90.0 if _won else 0.0), "c": color, "r": _rng.randf_range(3.0, 6.0)})


# 当前帧骰子的位置 / 缩放 / 转角 / 翻面挤压，以及该显示哪一面。
func _die_pose() -> Dictionary:
	if _reduced:
		var a := clampf(_t / 0.35, 0.0, 1.0)
		return {"pos": _stage, "scale": 1.0, "rot": 0.0, "squash": 1.0, "face": _face, "alpha": a}
	if _t < THROW_SEC:
		var u := _t / THROW_SEC
		var pos := _from.lerp(_stage, u) + Vector2(0, -160.0 * sin(u * PI))
		return {"pos": pos, "scale": lerpf(0.35, 1.0, u), "rot": u * TAU * 1.5, "squash": 1.0, "face": _shown_face, "alpha": 1.0}
	if _t < SETTLE_AT:
		# 翻滚段：转速按 (1-u)^2 衰减，弹跳振幅也衰减。
		var u := (_t - THROW_SEC) / (SETTLE_AT - THROW_SEC)
		var spin := (1.0 - pow(1.0 - u, 3.0)) * 7.0          # 总共翻约 7 个半圈
		var flip := fmod(spin, 1.0)
		var squash := absf(cos(flip * PI))                    # 翻面时横向压扁，假装是立体翻转
		var faces_passed := int(floor(spin))
		var face := ((_shown_face - 1 + faces_passed * 3) % 6) + 1
		if u > 0.92:
			face = _face
		var bounce := absf(sin(u * PI * 3.0)) * 70.0 * (1.0 - u)
		var rot := sin(u * PI * 5.0) * 0.5 * (1.0 - u)
		return {"pos": _stage + Vector2(0, -bounce), "scale": 1.0, "rot": rot, "squash": maxf(0.12, squash), "face": face, "alpha": 1.0}
	# 定格：落定那一下小回弹。
	var k := clampf((_t - SETTLE_AT) / 0.25, 0.0, 1.0)
	var pulse := 1.0 + 0.12 * sin(k * PI)
	var fade := 1.0 - smoothstep(END_AT - 0.35, END_AT, _t)
	return {"pos": _stage, "scale": pulse, "rot": 0.0, "squash": 1.0, "face": _face, "alpha": fade}


func _draw() -> void:
	var pose := _die_pose()
	var alpha: float = pose["alpha"]
	var pos: Vector2 = pose["pos"]
	# 结果光：赢是一圈扩散金环，输是一下红色闪底。
	if _t >= REVEAL_AT:
		var k := clampf((_t - REVEAL_AT) / 0.6, 0.0, 1.0)
		var color := WIN_COLOR if _won else LOSE_COLOR
		if _won:
			draw_arc(_stage, DIE_SIZE * (0.7 + 1.2 * k), 0.0, TAU, 48, Color(color, 0.8 * (1.0 - k)), 10.0 * (1.0 - k) + 2.0)
		draw_circle(_stage, DIE_SIZE * 1.1, Color(color, 0.35 * (1.0 - k) * alpha))
	# 骰子本体
	draw_set_transform(pos, float(pose["rot"]), Vector2(float(pose["squash"]), 1.0) * float(pose["scale"]))
	var half := DIE_SIZE * 0.5
	var rect := Rect2(Vector2(-half, -half), Vector2(DIE_SIZE, DIE_SIZE))
	var body := StyleBoxFlat.new()
	body.bg_color = Color(BODY, alpha)
	body.border_color = Color(EDGE, alpha)
	body.set_border_width_all(5)
	body.set_corner_radius_all(int(DIE_SIZE * 0.2))
	body.shadow_color = Color(0, 0, 0, 0.35 * alpha)
	body.shadow_size = 8
	body.shadow_offset = Vector2(0, 6)
	draw_style_box(body, rect)
	# 下半一层暗金，做出体积
	var shade := StyleBoxFlat.new()
	shade.bg_color = Color(BODY_SHADE, 0.45 * alpha)
	shade.set_corner_radius_all(int(DIE_SIZE * 0.18))
	draw_style_box(shade, Rect2(Vector2(-half + 6, 4), Vector2(DIE_SIZE - 12, half - 10)))
	# 左上高光
	draw_circle(Vector2(-half * 0.45, -half * 0.5), DIE_SIZE * 0.12, Color(1, 1, 0.92, 0.55 * alpha))
	var face: int = pose["face"]
	for p in PIPS.get(face, []):
		var at: Vector2 = (p as Vector2) * half * 0.62
		draw_circle(at, DIE_SIZE * 0.085, Color(PIP, alpha))
		draw_circle(at + Vector2(-2, -2), DIE_SIZE * 0.03, Color(1, 0.55, 0.5, 0.5 * alpha))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 火花
	for s in _sparks:
		var life := clampf(1.0 - (_t - REVEAL_AT) / (END_AT - REVEAL_AT), 0.0, 1.0)
		draw_circle(s["p"], float(s["r"]) * life, Color(s["c"] as Color, life))
	# 金币变化
	if _t >= REVEAL_AT:
		var k := clampf((_t - REVEAL_AT) / (END_AT - REVEAL_AT), 0.0, 1.0)
		var font := get_theme_default_font()
		var size := 46
		var text := _delta_text
		var label := tr("ui_gamble_win") if _won else tr("ui_gamble_lose")
		var drift := Vector2(0, (-60.0 if _won else 50.0) * k)
		var color := WIN_COLOR if _won else LOSE_COLOR
		var fade := 1.0 - smoothstep(0.7, 1.0, k)
		var at := _stage + Vector2(0, DIE_SIZE * 0.95) + drift
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, size).x
		draw_string_outline(font, at - Vector2(w * 0.5, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 8, Color(0.08, 0.05, 0.02, fade))
		draw_string(font, at - Vector2(w * 0.5, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(color, fade))
		var lw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, 26).x
		var lat := _stage - Vector2(lw * 0.5, DIE_SIZE * 0.85) + drift * 0.4
		draw_string_outline(font, lat, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, 6, Color(0.08, 0.05, 0.02, fade))
		draw_string(font, lat, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, Color(1, 1, 1, fade))
