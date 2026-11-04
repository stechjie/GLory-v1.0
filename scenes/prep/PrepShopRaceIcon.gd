extends Control

# 静态种族 logo。动态特效（光环/上升粒子/黑烟）已移除：
# 它们每帧 queue_redraw 重绘，在低端安卓机上是纯浪费。

const LOGO_PATHS := {
	"god": "res://assets/ui/race_logos/god.png",
	"human": "res://assets/ui/race_logos/human.png",
	"undead": "res://assets/ui/race_logos/undead.png",
	"dark": "res://assets/ui/race_logos/dark.png",
	"crimson": "res://assets/ui/race_logos/crimson.png",
}

# 只画符号、不要圆章底和金圈（商店卡用，11.04）。glyph/ 下的图是从同名 logo 抠出的中间符号。
const GLYPH_DIR := "res://assets/ui/race_logos/glyph/"

var glyph_only := false
var _race := ""
var _logo: Texture2D


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()


func set_race(race: String) -> void:
	_race = race
	var logo_path := str(LOGO_PATHS.get(race, ""))
	if glyph_only and not logo_path.is_empty() and ResourceLoader.exists(GLYPH_DIR + race + ".png"):
		logo_path = GLYPH_DIR + race + ".png"
	var loaded: Resource = load(logo_path) if not logo_path.is_empty() else null
	_logo = loaded as Texture2D
	visible = _logo != null
	queue_redraw()


func _draw() -> void:
	if _logo == null:
		return
	var icon_side := maxf(0.0, minf(size.x, size.y))
	var icon_rect := Rect2(
		(size - Vector2(icon_side, icon_side)) * 0.5,
		Vector2(icon_side, icon_side)
	)
	if glyph_only:
		# 符号直接压在头像上：先画一圈柔和暗影托底，保证在亮色头像上也看得清。
		var shadow := Color(0.0, 0.0, 0.0, 0.42)
		var o := icon_side * 0.03
		for off in [Vector2(o, o), Vector2(-o, o), Vector2(o, -o), Vector2(-o, -o), Vector2(0, o * 1.6)]:
			draw_texture_rect(_logo, Rect2(icon_rect.position + off, icon_rect.size), false, shadow)
	draw_texture_rect(_logo, icon_rect, false)
