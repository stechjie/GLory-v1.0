extends Control

# 静态种族 logo。动态特效（光环/上升粒子/黑烟）已移除：
# 它们每帧 queue_redraw 重绘，在低端安卓机上是纯浪费。

const LOGO_PATHS := {
	"god": "res://assets/ui/race_logos/god.png",
	"human": "res://assets/ui/race_logos/human.png",
	"undead": "res://assets/ui/race_logos/undead.png",
	"dark": "res://assets/ui/race_logos/dark.png",
}

var _race := ""
var _logo: Texture2D


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()


func set_race(race: String) -> void:
	_race = race
	var logo_path := str(LOGO_PATHS.get(race, ""))
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
	draw_texture_rect(_logo, icon_rect, false)
