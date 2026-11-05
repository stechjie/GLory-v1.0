extends Control
## 商店刷新按钮中间的图案：空心金框 btn_refresh_blank.png 中间这一块，按棋盘皮肤换。
##
## 图案跟刷新特效（PrepSkin.refresh_fx）是同一套 kind：
##   fire  = 青草地（默认）火焰    frost = 冰雪 雪花
##   petal = 樱花 樱花             wisp  = 夜荧光 月牙 + 萤火
##
## 11.05 重做：第一版在这里每帧用 draw_colored_polygon 画形状 —— 多边形没有抗锯齿、
## 轮廓点太少、又套了随机切面明暗和深色描边，按钮大小下又碎又糙（用户：「做得那么差」）。
## 现在形状由 tools/gen_refresh_emblems.py 用光滑曲线 + 柔和渐变、4 倍超采样烘成 PNG
## （同樱花瓣贴图 PrepPetalTexture 的思路），这里只负责摆放和动：
##   待机：呼吸缩放；雪花慢转、樱花轻摆、火焰从底部一伸一缩地跳、月牙轻浮 + 三颗萤火绕飘闪烁。
##   点刷新：kick() 先往回拧一下再转一圈回弹（预备 + 过冲）。
## 皮肤晚到 / 换皮肤：PrepUI.reapply_prep_skin 会调 sync()。
## 图用运行时 load()：战斗服务器包不带导入过的贴图。

const PrepSkin := preload("res://scenes/prep/PrepSkin.gd")
const EMBLEM_PATH := "res://assets/ui/buttons/refresh_emblem_%s.png"
const FIREFLY_PATH := "res://assets/ui/buttons/refresh_firefly.png"
const EMBLEM_FRACTION := 0.62              # 图案边长 / 按钮边长（金框内圈约 0.81）

# 萤火：[相对按钮中心的位置（占按钮边长）, 大小（占按钮边长）, 相位]
const FIREFLIES := [
	[Vector2(0.11, -0.19), 0.19, 0.0],      # 都落在月牙缺口里（不压在月亮身上）
	[Vector2(0.22, -0.04), 0.14, 2.1],
	[Vector2(0.03, -0.09), 0.11, 4.2],
]

static var _textures := {}

var kind := "fire"
var _t := 0.0
var _spin := 0.0                           # kick 时的额外转角（弧度）
var _pop := 1.0                            # kick 时的额外缩放
var _kick_tween: Tween = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	sync()


## 按当前皮肤选图案。
func sync() -> void:
	set_kind(PrepSkin.refresh_fx())


func set_kind(new_kind: String) -> void:
	kind = new_kind if new_kind in PrepSkin.REFRESH_FX_KINDS else "fire"
	queue_redraw()


## 点刷新时的反馈：往回拧 18°、缩一点（预备），再转满一圈带过冲落回。
func kick() -> void:
	if _kick_tween != null and _kick_tween.is_valid():
		_kick_tween.kill()
	_spin = 0.0
	_pop = 1.0
	_kick_tween = create_tween()
	_kick_tween.tween_method(_set_spin, 0.0, deg_to_rad(-18.0), 0.07) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_kick_tween.parallel().tween_method(_set_pop, 1.0, 0.86, 0.07)
	_kick_tween.tween_method(_set_spin, deg_to_rad(-18.0), TAU, 0.42) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_kick_tween.parallel().tween_method(_set_pop, 0.86, 1.0, 0.42) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_kick_tween.tween_callback(func(): _spin = 0.0)


func _set_spin(v: float) -> void:
	_spin = v


func _set_pop(v: float) -> void:
	_pop = v


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_t += delta
	queue_redraw()


static func _tex(path: String) -> Texture2D:
	if not _textures.has(path):
		_textures[path] = load(path) as Texture2D
	return _textures[path]


func _draw() -> void:
	var side := minf(size.x, size.y)
	if side <= 1.0:
		return
	var tex := _tex(EMBLEM_PATH % kind)
	if tex == null:
		return
	var center := size * 0.5
	var edge := side * EMBLEM_FRACTION
	# 呼吸：缩放 ±3%，0.5 Hz
	var breathe := 1.0 + 0.03 * sin(_t * TAU * 0.5)
	var rot := _spin
	var stretch := Vector2.ONE
	var offset := Vector2.ZERO
	match kind:
		"frost":
			rot += _t * 0.35                            # 雪花慢慢自转
		"petal":
			rot += 0.10 * sin(_t * TAU * 0.35)          # 樱花左右轻摆
		"wisp":
			offset.y = sin(_t * TAU * 0.3) * side * 0.012   # 月牙轻浮
		_:
			# 火焰从底部跳：竖向伸缩、横向反向一点点（体积守恒的挤压拉伸），两个频率叠出不规律感
			var f := 0.035 * sin(_t * TAU * 1.7) + 0.02 * sin(_t * TAU * 2.9 + 1.3)
			stretch = Vector2(1.0 - f * 0.5, 1.0 + f)
			offset.y = -f * edge * 0.42                 # 底部基本不动、只有火尖在跳
	draw_set_transform(center + offset, rot, stretch * breathe * _pop)
	draw_texture_rect(tex, Rect2(-Vector2(edge, edge) * 0.5, Vector2(edge, edge)), false)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if kind == "wisp":
		_draw_fireflies(center + offset, side)


# 三颗萤火在月牙缺口里绕小圈慢飘，按相位一亮一暗（不随机抖）。点刷新转圈时它们不跟着转。
func _draw_fireflies(center: Vector2, side: float) -> void:
	var tex := _tex(FIREFLY_PATH)
	if tex == null:
		return
	for f in FIREFLIES:
		var ph := float(f[2])
		var pos := center + (f[0] as Vector2) * side \
			+ Vector2(sin(_t * 1.3 + ph), cos(_t * 1.1 + ph)) * side * 0.025
		var pulse := 0.5 + 0.5 * sin(_t * TAU * 0.6 + ph)
		var s := side * float(f[1]) * (0.85 + 0.25 * pulse) * _pop
		draw_texture_rect(tex, Rect2(pos - Vector2(s, s) * 0.5, Vector2(s, s)), false,
			Color(1, 1, 1, 0.55 + 0.45 * pulse))
