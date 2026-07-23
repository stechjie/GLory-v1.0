class_name FormationCrystal
extends Control

# 阵型血量水晶：按当前血量段显示一张图片（火队=红水晶、水队=蓝水晶，由队伍决定）。
# 满血 50，共 5 段：0-10 / 10-20 / 20-30 / 30-40 / 40-50，血越低图越暗/破。
# 用 set_bracket_textures([5 张贴图]) 指定这套图，用 set_hp_ratio(current/max) 驱动血量段。

const BRACKET_COUNT := 5

var hp_ratio := 1.0
var _bracket_textures: Array = []

func _ready() -> void:
	custom_minimum_size = Vector2(56, 56)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_bracket_textures(texs: Array) -> void:
	_bracket_textures = texs
	queue_redraw()

func set_hp_ratio(r: float) -> void:
	hp_ratio = clampf(r, 0.0, 1.0)
	queue_redraw()

func _bracket_index() -> int:
	# 5 段均分整条血量：0-10,10-20,...,40-50（等价于血量比例的五分之一区间）。
	return clampi(int(floor(hp_ratio * float(BRACKET_COUNT))), 0, BRACKET_COUNT - 1)

func _draw() -> void:
	if _bracket_textures.size() < BRACKET_COUNT:
		return
	var tex := _bracket_textures[_bracket_index()] as Texture2D
	if tex == null:
		return
	# 按控件尺寸等比居中显示（KEEP_ASPECT_CENTERED），避免非方形贴图被拉变形。
	var tex_size := Vector2(tex.get_width(), tex.get_height())
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return
	var scale := minf(size.x / tex_size.x, size.y / tex_size.y)
	var draw_size := tex_size * scale
	var pos := (size - draw_size) * 0.5
	draw_texture_rect(tex, Rect2(pos, draw_size), false)
