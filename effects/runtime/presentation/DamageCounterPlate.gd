extends Control
## 战斗左侧伤害计数的底板（保留式绘制，只在尺寸 / accent 变化时重画）。
## 2026-11-15：原来是仿冷金属刀形的深蓝板，和全游戏的羊皮纸 / 金边美术不是一路。
## 现在用一张 GPT 出的图（ui/battle_hud/damage_plaque.png）：深胡桃木牌 + 金边卷花 + 左端红宝石 + 两角叶子，
## 上面压一块小标题牌。底色保持偏深：数字的扫光和光晕是叠加混合，底太亮就看不见了。
## 图里两块内面的位置（比例）：标题牌 x 0.26~0.75 / y 0.04~0.31，数字牌 x 0.07~0.93 / y 0.36~0.82；
## BattleCombatFeedback._layout() 里两个 Label 按这个对齐。
## 贴图运行时 load()：战斗服务器包不带导入过的贴图，不能 preload。
const PLAQUE_PATH := "res://ui/battle_hud/damage_plaque.png"
const NUMBER_FACE := Rect2(0.07, 0.36, 0.86, 0.46)

var accent := Color("ffd24a")
static var _plaque: Texture2D
static var _plaque_tried := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	resized.connect(queue_redraw)

func set_accent(value: Color) -> void:
	if accent == value:
		return
	accent = value
	queue_redraw()

static func plaque_texture() -> Texture2D:
	if not _plaque_tried:
		_plaque_tried = true
		if ResourceLoader.exists(PLAQUE_PATH):
			_plaque = load(PLAQUE_PATH) as Texture2D
	return _plaque

func _draw() -> void:
	var factor := size.x / 286.0
	var texture := plaque_texture()
	if texture != null:
		draw_texture_rect(texture, Rect2(Vector2.ZERO, size), false)
	else:
		# 没有贴图（无头 / 服务器环境）时的兜底：一块深棕牌
		draw_rect(Rect2(size * Vector2(0.03, 0.34), size * Vector2(0.94, 0.52)), Color("4a2a16"))
	# 数字下面一道跟伤害档位走的细线（档位变了底板上也看得出来）
	var y := (NUMBER_FACE.position.y + NUMBER_FACE.size.y * 0.95) * size.y
	var x0 := (NUMBER_FACE.position.x + NUMBER_FACE.size.x * 0.16) * size.x
	var x1 := (NUMBER_FACE.position.x + NUMBER_FACE.size.x * 0.90) * size.x
	draw_line(Vector2(x0, y), Vector2(x1, y), Color(accent.r, accent.g, accent.b, 0.55), 1.4 * factor, true)
