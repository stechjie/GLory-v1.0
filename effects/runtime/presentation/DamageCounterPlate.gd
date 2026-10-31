extends Control
## Retained vector artwork for the cold-metal combo-counter silhouette.
## The arc, knife ends and engraved cells stay in this widget's existing bounds.
var accent := Color("829aff")

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)

func set_accent(value: Color) -> void:
	accent = value
	queue_redraw()

func _curve(out: Array[Vector2], a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> void:
	for i in range(1,17):
		out.append(a.bezier_interpolate(b,c,d,float(i)/16.0))

func _points(values: Array[Vector2], inset := Vector2.ONE) -> PackedVector2Array:
	var result := PackedVector2Array()
	for value: Vector2 in values:
		result.append(((value-Vector2.ONE*0.5)*inset+Vector2.ONE*0.5)*size)
	return result

func _draw() -> void:
	var factor := size.x/286.0
	var outline: Array[Vector2] = [Vector2(0.02,0.96)]
	_curve(outline,outline[-1],Vector2(0.18,0.86),Vector2(0.43,0.60),Vector2(0.32,0.33))
	_curve(outline,outline[-1],Vector2(0.27,0.25),Vector2(0.27,0.17),Vector2(0.35,0.05))
	_curve(outline,outline[-1],Vector2(0.35,0.19),Vector2(0.32,0.22),Vector2(0.46,0.25))
	outline.append(Vector2(0.98,0.20))
	outline.append(Vector2(0.90,0.40))
	_curve(outline,outline[-1],Vector2(0.86,0.54),Vector2(0.84,0.78),Vector2(0.87,0.94))
	outline.append(Vector2(0.91,0.98))
	var outer := _points(outline)
	var shadow := outer.duplicate()
	for i in range(shadow.size()):
		shadow[i] += Vector2(0.7,1.7)*factor
	draw_colored_polygon(shadow,Color(0.0,0.01,0.04,0.48))
	var rim_colors := PackedColorArray()
	var body_colors := PackedColorArray()
	for value: Vector2 in outline:
		var rim := Color("5364a4").lerp(Color("e0eaff"),maxf(0.0,1.0-value.y))
		rim.a = 0.85
		rim_colors.append(rim)
		var body := Color("040a1d").lerp(Color("10335c"),clampf(0.88-value.x,0.0,0.6))
		body.a = 0.94
		body_colors.append(body)
	draw_polygon(outer,rim_colors)
	draw_polygon(_points(outline,Vector2(0.986,0.956)),body_colors)
	# The top blade is a silver bevel, rather than a uniform wire outline.
	var bevel: Array[Vector2] = [Vector2(0.65,0.27),Vector2(0.98,0.20),Vector2(0.87,0.33)]
	draw_polygon(_points(bevel),PackedColorArray([Color(0.48,0.60,0.86,0.30),Color(0.93,0.98,1.0,0.94),Color(0.16,0.25,0.50,0.75)]))
	# Open silver arc, kept independent of the moving flare so it never flickers.
	var silver: Array[Vector2] = [Vector2(0.08,0.93)]
	_curve(silver,silver[-1],Vector2(0.26,0.84),Vector2(0.42,0.60),Vector2(0.33,0.35))
	_curve(silver,silver[-1],Vector2(0.29,0.24),Vector2(0.29,0.20),Vector2(0.34,0.12))
	draw_polyline(_points(silver),Color(0.58,0.76,1.0,0.78),1.0*factor,true)
	draw_line(Vector2(0.40,0.275)*size,Vector2(0.92,0.235)*size,Color(0.77,0.84,1.0,0.74),0.7*factor,true)
	draw_line(Vector2(0.16,0.935)*size,Vector2(0.74,0.935)*size,Color(0.41,0.40,0.78,0.80),0.8*factor,true)
	# Quiet violet engraved hexagons sit behind the figures, like cut metal cells.
	for center in [Vector2(0.32,0.36),Vector2(0.35,0.54),Vector2(0.31,0.70),Vector2(0.80,0.42),Vector2(0.77,0.62)]:
		var cell := PackedVector2Array()
		for i in range(7):
			var angle := PI/6.0+float(i)*TAU/6.0
			cell.append(center*size+Vector2(cos(angle),sin(angle))*6.0*factor)
		draw_polyline(cell,Color(0.59,0.30,0.82,0.45),0.8*factor,true)
