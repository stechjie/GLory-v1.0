extends Control
# 卷轴商店棋子卡的卡框。
#
# 2026-11-15 起：框本体换成贴图（ui/shop_card/frame_t1~3.png，GPT 出图后按用户三轮意见定稿），代码只画贴图之外的东西。
#   稀有度一眼分开：T1 普通 = 灰石素框；T2 稀有 = 蓝框蓝铭牌 + 底角蓝水晶；T3 史诗 = 金框金铭牌 + 金冠小翅膀 + 底角金晶。
#   内窗底部一排阶数星（T1 一颗灰、T2 两颗蓝、T3 三颗金）。
#   铭牌「能量流动」：稀有 / 史诗挂 ui/shop_card/plate_energy.gdshader（稀有不扫光，只流光 + 星光；史诗再加扫光），普通卡静止。
#   呼吸光是框外一圈柔和光晕：T1 无、T2 慢、T3 快而亮。
#   右上角大金币（数字由 ShopPanel 叠在圈内）。种族徽章、近战/远程牌子、名字由 ShopPanel 叠上。
# 升星提示（star_up）：卡顶 12 点方向一团绿色柔光 + 一颗呼吸的大十字星 + 往上飘的小十字星，可冲出卡顶。
#   判据由 ShopPanel 用 PrepRules.first_merge_target 算，和真正买入时一致。
# 近战 / 远程的判据与战斗表现一致：数据表射程 range <= 1 为近战（BattleVfx 同一口径）。
# 坐标写在 200×200 卡面空间里，按实际尺寸等比缩放；装饰可以画到卡外（slot 不裁切）。
# 「减少动态」时全部静止。

const CARD := Vector2(200.0, 200.0)

const OUTLINE := Color("3a2418")       # 深棕描边，和头像 / 宝藏图标的描边同色系

# base = 主色，hi = 亮面（左上），lo = 暗面（右下），plate = 名字条，glow = 呼吸光
const TIER_STYLE := {
	1: {"base": Color("8e8679"), "hi": Color("c2b9a9"), "lo": Color("5e574d"), "plate": Color("4e4840"), "glow": Color("d8d0c0")},
	2: {"base": Color("5b7fae"), "hi": Color("98b8e0"), "lo": Color("365582"), "plate": Color("2f4a70"), "glow": Color("7fc4ff")},
	3: {"base": Color("d49a2e"), "hi": Color("fbd56a"), "lo": Color("9a6514"), "plate": Color("7a4f16"), "glow": Color("ffd56a")},
}
# 呼吸光晕：alpha = 最亮时最内层不透明度；layers × step = 宽度；speed = 弧度/秒；low = 最暗比例
const GLOW := {
	1: {"alpha": 0.0, "layers": 0, "step": 0.0, "speed": 0.0, "low": 1.0},
	2: {"alpha": 0.75, "layers": 6, "step": 2.6, "speed": 1.55, "low": 0.2},
	3: {"alpha": 1.0, "layers": 9, "step": 2.8, "speed": 3.0, "low": 0.1},
}
# 框贴图：1254 画布上卡框本体（不含溢出的金冠 / 水晶）占 (34, 33) 起 1185×1190，按这个映射到 200×200 卡面。
const FRAME_TEXTURES := {
	1: preload("res://ui/shop_card/frame_t1.png"),
	2: preload("res://ui/shop_card/frame_t2.png"),
	3: preload("res://ui/shop_card/frame_t3.png"),
}
const FRAME_SOURCE := 1254.0
const FRAME_BODY := Rect2(34.0, 33.0, 1185.0, 1190.0)
# 铭牌能量：遮罩与卡框贴图同一张画布；plate_rect 是铭牌在 UV 里的外接框（由遮罩量出）。
const PLATE_ENERGY_SHADER := preload("res://ui/shop_card/plate_energy.gdshader")
const PLATE_ENERGY := {
	2: {"mask": preload("res://ui/shop_card/plate_mask_t2.png"), "rect": Vector4(0.1212, 0.8325, 0.8700, 0.9330),
		"sweep_strength": 0.0, "sweep_color": Color(0.82, 0.94, 1.0),
		"flow_strength": 0.22, "flow_low": 0.58, "flow_color": Color(0.55, 0.84, 1.0),
		"spark_count": 5, "spark_strength": 0.75, "spark_size": 0.019, "spark_color": Color(0.87, 0.95, 1.0)},
	3: {"mask": preload("res://ui/shop_card/plate_mask_t3.png"), "rect": Vector4(0.1108, 0.8357, 0.8868, 0.9330),
		"sweep_strength": 0.55, "sweep_color": Color(1.0, 0.97, 0.82),
		"flow_strength": 0.32, "flow_low": 0.52, "flow_color": Color(1.0, 0.86, 0.45),
		"spark_count": 9, "spark_strength": 0.9, "spark_size": 0.022, "spark_color": Color(1.0, 0.97, 0.84)},
}
# 阶数星：内窗底部一排
const TIER_STAR_Y := 152.0
const TIER_STAR_R := 12.5
const TIER_STAR_GAP := 25.0
const TIER_STAR_COLORS := {
	1: [Color("d8d2c4"), Color("f2eee4")],
	2: [Color("7fc4ff"), Color("c4e6ff")],
	3: [Color("ffcf3a"), Color("ffe98a")],
}
const GOLD := Color("eab53a")
const GOLD_HI := Color("ffdc72")
const GOLD_LO := Color("b9821e")

const OUTER_INSET := 3.0
const OUTER_RADIUS := 14.0
# 大金币压右上角（11.15 用户要求价格数字在圈里）
const COIN_CENTER := Vector2(186.0, 8.0)
const COIN_RADIUS := 27.0
const STAR_UP_CENTER := Vector2(100.0, 0.0)   # 12 点方向
const STAR_UP_COLOR := Color("6dff9a")
const STAR_UP_SPARKS := 14

var tier := 1
var ranged := false        # true = 远程，false = 近战（牌子由 ShopPanel 画；这里留着给刷新判定用）
var star_up := false       # 买下即升星
var animated := true:
	set(value):
		if animated == value:
			return
		animated = value
		_update_process()
		_configure_energy()
		_queue_dynamic_redraw()
var anim_time := 0.0:
	set(value):
		if anim_time == value:
			return
		anim_time = value
		_queue_dynamic_redraw()
var anim_phase := 0.0:
	set(value):
		if anim_phase == value:
			return
		anim_phase = value
		_configure_energy()
		_queue_dynamic_redraw()

# All layers use the same local card coordinates. Their own _draw callbacks
# supply the CanvasItem painter, so commands are retained on the correct RID.
# The static frame stays between the original behind-frame glow and front stars.
class AnimatedLayer extends Control:
	var card: Control
	var upgrade := false
	func _draw() -> void:
		if not is_instance_valid(card):
			return
		if upgrade:
			card.call("_paint_upgrade", self)
		else:
			card.call("_paint_glow", self)

var _glow_layer: Control
var _upgrade_layer: Control
var _energy_layer: ColorRect
var _energy_material: ShaderMaterial


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 600px 卡框贴图缩到 ~180px 显示，要用 mipmap，不然边缘起颗粒
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_glow_layer = _make_animated_layer("BreathingGlow", false)
	_glow_layer.show_behind_parent = true
	_energy_layer = ColorRect.new()
	_energy_layer.name = "PlateEnergy"
	_energy_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_energy_layer.focus_mode = Control.FOCUS_NONE
	_energy_material = ShaderMaterial.new()
	_energy_material.shader = PLATE_ENERGY_SHADER
	_energy_layer.material = _energy_material
	add_child(_energy_layer)
	_upgrade_layer = _make_animated_layer("StarUpgrade", true)
	# configure() 可能在进树之前就调过（商店先建卡、后刷新），那时能量层还没建，这里补一次
	_configure_energy()
	_layout_energy()
	resized.connect(_refresh_size)
	visibility_changed.connect(_refresh_visibility)
	_update_process()
	_queue_dynamic_redraw()


func _make_animated_layer(layer_name: String, upgrade: bool) -> Control:
	var layer := AnimatedLayer.new()
	layer.name = layer_name
	layer.card = self
	layer.upgrade = upgrade
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.focus_mode = Control.FOCUS_NONE
	add_child(layer)
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return layer


# 一次设齐卡面状态（商店每次刷新调用）。
func configure(p_tier: int, p_ranged: bool, p_star_up: bool) -> void:
	var wanted_tier := clampi(p_tier, 1, 3)
	var static_changed := tier != wanted_tier or ranged != p_ranged
	var glow_changed := tier != wanted_tier
	var effects_changed := glow_changed or star_up != p_star_up
	tier = wanted_tier
	ranged = p_ranged
	star_up = p_star_up
	_update_process()
	if glow_changed:
		_configure_energy()
	if static_changed:
		queue_redraw()
	if glow_changed and is_instance_valid(_glow_layer):
		_glow_layer.queue_redraw()
	if effects_changed:
		_queue_dynamic_redraw()


# 数据表射程格数 > 1 为远程。
static func is_ranged(unit_def: Dictionary) -> bool:
	return float(unit_def.get("range", 1.0)) > 1.0


func _refresh_size() -> void:
	queue_redraw()
	_layout_energy()
	if is_instance_valid(_glow_layer):
		_glow_layer.queue_redraw()
	_queue_dynamic_redraw()


func _refresh_visibility() -> void:
	_update_process()
	if is_visible_in_tree():
		_queue_dynamic_redraw()


func _update_process() -> void:
	set_process(animated and is_visible_in_tree() and (tier >= 2 or star_up))
	if is_instance_valid(_glow_layer):
		_glow_layer.visible = tier >= 2
	if is_instance_valid(_upgrade_layer):
		_upgrade_layer.visible = star_up
	if is_instance_valid(_energy_layer):
		_energy_layer.visible = tier >= 2


# 能量层盖住整张卡框贴图（含溢出部分），UV 与贴图一致。
func _layout_energy() -> void:
	if not is_instance_valid(_energy_layer):
		return
	var s := card_scale()
	var r := _frame_rect()
	_energy_layer.position = (size - CARD * s) * 0.5 + r.position * s
	_energy_layer.size = r.size * s


func _configure_energy() -> void:
	if not is_instance_valid(_energy_material) or not PLATE_ENERGY.has(tier):
		return
	var e: Dictionary = PLATE_ENERGY[tier]
	_energy_material.set_shader_parameter("plate_mask", e["mask"])
	_energy_material.set_shader_parameter("plate_rect", e["rect"])
	_energy_material.set_shader_parameter("phase", fmod(anim_phase * 0.37, 1.0))
	for key in ["sweep_color", "flow_strength", "flow_low", "flow_color", "spark_color", "spark_size"]:
		_energy_material.set_shader_parameter(key, e[key])
	# 减少动态：画面静止，只留流光纹理，不扫光、不飘星
	_energy_material.set_shader_parameter("speed", 1.0 if animated else 0.0)
	_energy_material.set_shader_parameter("sweep_strength", e["sweep_strength"] if animated else 0.0)
	_energy_material.set_shader_parameter("spark_count", int(e["spark_count"]) if animated else 0)
	_energy_material.set_shader_parameter("spark_strength", e["spark_strength"])


# 卡框贴图在 200×200 卡面坐标里的位置（本体对齐卡面，溢出的装饰在外面）。
func _frame_rect() -> Rect2:
	var k := Vector2(CARD.x / FRAME_BODY.size.x, CARD.y / FRAME_BODY.size.y)
	return Rect2(-FRAME_BODY.position * k, Vector2(FRAME_SOURCE, FRAME_SOURCE) * k)


func _queue_dynamic_redraw() -> void:
	# Breathing scales every glow command's alpha by the same value. Retain its
	# geometry too; a Canvas uniform preserves per-command blending and phase.
	if is_instance_valid(_glow_layer):
		var gl: Dictionary = GLOW[tier]
		var pulse := 1.0
		if animated and float(gl["speed"]) > 0.0:
			var w01 := 0.5 + 0.5 * sin(anim_time * float(gl["speed"]) + anim_phase)
			pulse = lerpf(float(gl["low"]), 1.0, w01 * w01)
		_glow_layer.self_modulate.a = pulse
	if is_instance_valid(_upgrade_layer) and _upgrade_layer.is_visible_in_tree():
		_upgrade_layer.queue_redraw()


func _process(delta: float) -> void:
	# Hidden cards retain their phase without scheduling invisible draw callbacks.
	if not is_visible_in_tree():
		return
	anim_time += delta


func card_scale() -> float:
	return minf(size.x / CARD.x, size.y / CARD.y)


func _begin_card_paint(painter: CanvasItem) -> bool:
	var s := card_scale()
	if s <= 0.0:
		return false
	painter.draw_set_transform((size - CARD * s) * 0.5, 0.0, Vector2(s, s))
	return true


func _draw() -> void:
	_paint_static(self)


func _paint_glow(painter: CanvasItem) -> void:
	if not _begin_card_paint(painter):
		return
	var st: Dictionary = TIER_STYLE[tier]
	var full := Rect2(Vector2.ZERO, CARD)
	var gl: Dictionary = GLOW[tier]
	var glow_col: Color = st["glow"]
	var layers := int(gl["layers"])
	for i in layers:
		var g := 1.0 + float(i) * float(gl["step"])
		var fall := 1.0 - float(i) / float(layers)
		_outline(painter, _rounded(full.grow(g - OUTER_INSET), OUTER_RADIUS + g), Color(glow_col.r, glow_col.g, glow_col.b, float(gl["alpha"]) * fall * fall * 0.45), 3.2)
	painter.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _paint_static(painter: CanvasItem) -> void:
	if not _begin_card_paint(painter):
		return
	# 1. 框贴图（本体对齐卡面，金冠 / 水晶溢出到外面）
	painter.draw_texture_rect(FRAME_TEXTURES[tier], _frame_rect(), false)

	# 2. 阶数星：内窗底部一排
	var cols: Array = TIER_STAR_COLORS[tier]
	var x0 := CARD.x * 0.5 - TIER_STAR_GAP * float(tier - 1) * 0.5
	for i in tier:
		_star(painter, Vector2(x0 + TIER_STAR_GAP * float(i), TIER_STAR_Y), TIER_STAR_R, cols[0], cols[1])

	# 3. 右上大金币（数字由外面叠在圈内）：深棕描边 + 暗金底 + 亮金面（光从左上）+ 内圈细线
	painter.draw_circle(COIN_CENTER, COIN_RADIUS + 3.0, OUTLINE)
	painter.draw_circle(COIN_CENTER, COIN_RADIUS, GOLD_LO)
	painter.draw_circle(COIN_CENTER + Vector2(-1.6, -1.6), COIN_RADIUS - 2.4, GOLD)
	painter.draw_arc(COIN_CENTER, COIN_RADIUS * 0.78, 0.0, TAU, 32, GOLD_LO, 1.6, true)
	painter.draw_arc(COIN_CENTER, COIN_RADIUS - 6.0, PI * 1.05, PI * 1.55, 12, GOLD_HI, 2.6, true)
	painter.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _paint_upgrade(painter: CanvasItem) -> void:
	if not star_up or not _begin_card_paint(painter):
		return
	_draw_star_up(painter, anim_time if animated else 0.0)
	painter.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# 圆角矩形轮廓点（顺时针，左上角起）。直边额外细分 subdiv 段，外 / 内两条点数一致，供框带逐段连接。
func _rounded(r: Rect2, radius: float, subdiv: int = 1) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var rad := maxf(0.5, minf(radius, minf(r.size.x, r.size.y) * 0.5))
	var centres := [
		r.position + Vector2(rad, rad),
		Vector2(r.end.x - rad, r.position.y + rad),
		r.end - Vector2(rad, rad),
		Vector2(r.position.x + rad, r.end.y - rad),
	]
	var starts := [PI, PI * 1.5, 0.0, PI * 0.5]
	var arc_steps := 4
	for ci in 4:
		var c: Vector2 = centres[ci]
		var a0: float = starts[ci]
		for k in arc_steps + 1:
			var a := a0 + PI * 0.5 * float(k) / float(arc_steps)
			pts.append(c + Vector2(cos(a), sin(a)) * rad)
		var nc: Vector2 = centres[(ci + 1) % 4]
		var na: float = starts[(ci + 1) % 4]
		var end_pt := nc + Vector2(cos(na), sin(na)) * rad
		var start_pt: Vector2 = pts[pts.size() - 1]
		for k in range(1, subdiv):
			pts.append(start_pt.lerp(end_pt, float(k) / float(subdiv)))
	return pts


# 五角星：亮黄平涂 + 左半亮面 + 深棕描边。
func _star(painter: CanvasItem, c: Vector2, r: float, fill: Color = Color("ffcf3a"), lit: Color = Color("ffe98a")) -> void:
	var pts := PackedVector2Array()
	for i in 10:
		var ang := -PI * 0.5 + float(i) * PI / 5.0
		var rr := r if i % 2 == 0 else r * 0.46
		pts.append(c + Vector2(cos(ang), sin(ang)) * rr)
	_fill(painter, pts, fill)
	var left := PackedVector2Array([c])
	for i in range(5, 11):
		left.append(pts[i % 10])
	_fill(painter, left, lit)
	_outline(painter, pts, OUTLINE, 1.6)


# 升星：12 点方向的绿色柔光 + 呼吸的大十字星 + 往上飘的小十字星（棋盘特效同款十字闪光），可冲出卡顶。
func _draw_star_up(painter: CanvasItem, t: float) -> void:
	var c := STAR_UP_CENTER
	var col := STAR_UP_COLOR
	var breath := (0.6 + 0.4 * sin(t * 3.0)) if animated else 0.85
	for i in 12:
		var k := float(i) / 11.0
		painter.draw_circle(c, lerpf(70.0, 8.0, k) * (0.85 + 0.15 * breath), Color(col.r, col.g, col.b, (0.03 + 0.09 * k) * breath))
	_cross_star(painter, c + Vector2(0, -8), 28.0 * (0.8 + 0.25 * breath), Color(1, 1, 1, 0.95), col, breath)
	if not animated:
		return
	for i in STAR_UP_SPARKS:
		var seed := float(i) * 2.399
		var period := 1.2 + fmod(seed * 0.7, 1.0)
		var u := fmod(t / period + fmod(seed, 1.0), 1.0)
		var spread := fmod(seed * 37.0, 110.0) - 55.0
		var x := c.x + spread * (0.2 + 0.8 * u) + sin(t * 2.4 + seed * 4.0) * 4.0
		var y := c.y + 6.0 - u * (95.0 + fmod(seed * 11.0, 40.0))
		var fade := sin(u * PI)
		var size_k := 5.0 + fmod(seed * 5.0, 6.0)
		_cross_star(painter, Vector2(x, y), size_k * (0.7 + 0.3 * sin(t * 7.0 + seed * 5.0)), Color(1, 1, 1, 0.9 * fade), col, fade)


# 柔和十字星：四个细长尖角 + 中心亮点 + 外圈同色柔光。
func _cross_star(painter: CanvasItem, c: Vector2, r: float, core: Color, halo: Color, a: float) -> void:
	painter.draw_circle(c, r * 0.55, Color(halo.r, halo.g, halo.b, 0.25 * a))
	var w := r * 0.16
	for d in [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)]:
		var n := Vector2(-d.y, d.x)
		painter.draw_colored_polygon(PackedVector2Array([c + n * w, c + d * r, c - n * w]), Color(halo.r, halo.g, halo.b, 0.85 * a))
		painter.draw_colored_polygon(PackedVector2Array([c + n * w * 0.5, c + d * r * 0.7, c - n * w * 0.5]), core)
	painter.draw_circle(c, w * 1.2, core)


func _fill(painter: CanvasItem, pts: PackedVector2Array, col: Color) -> void:
	painter.draw_colored_polygon(pts, col)


func _outline(painter: CanvasItem, pts: PackedVector2Array, col: Color, width: float) -> void:
	var closed := pts.duplicate()
	closed.append(pts[0])
	painter.draw_polyline(closed, col, width, true)
