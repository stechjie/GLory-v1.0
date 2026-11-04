extends Node2D

# 备战棋盘「联动生物」的共用底座（11.04，从定稿的凤凰里抽出来）。
#
# 每条作用在棋子上的宝藏联动 = 棋盘上一只平面生物（凤凰 / 锦鲤 / …）。底座管所有生物共有的东西，
# 子类只管「长什么样、什么颜色」：
#   · 子类覆盖 _build_shape() 往 _tongues 里加形状（火舌 / 鱼身 / 鳍…，都是「脊线 + 宽度」）；
#   · 子类在 _init() 里改配色 col_* 和手感参数（cruise_speed / turn_rate / flap_hz / body_scale）；
#   · 需要的话覆盖 _draw_extra()（本体之上再画点东西）和 _draw_ignite()（掠过棋子时的特效）。
#
# 贴到棋盘：宿主把这张离屏画布贴在棋盘地面的面片上（PrepBoardModels._ensure_prep_creature_canvas），
# 透视交给 3D，棋子站在生物上面；面片材质把亮部提到 > 1，抵消备战 3D 的 Filmic 压暗。
# 画布坐标：像素；棋盘 UV → 像素用 uv_to_px()。
#
# 亮法（Leno 定稿的凤凰）：照赤律 4「共鸣」光球 —— 每个形状由暗到亮四层（暗边 → 主体 → 核心 → 白热），
# 外面垫两圈半透明柔光；胸口一团同样分层的光核 + 四道抖动的光丝。亮草地上加色会被洗白，全用普通混合。
#
# 动起来不僵（game-feel）：
#   · 漫游 = 转向追目标（方向有惯性、转弯有上限），走弧线；转弯时 _bank 带动造型侧倾 / 甩尾；
#   · 「扇动」（翅膀 / 尾鳍）一阵发力接一段滑行，节奏不等长，发力那半拍推一下速度；
#   · 掠过棋子（中档）：gather 放慢蓄力（_fold → +1）→ dash ease-in 冲刺（_fold → -1）→
#     到棋子时 _draw_ignite 弹出（overshoot）→ settle ease-out 收势；
#   · 登场（大档）：一圈特效炸开，生物从中间弹出、附件（翅膀 / 鳍）晚一拍展开；退场化成火星散掉。

signal piece_ignited(index: int)

# 可游动范围（棋盘图 UV）。宿主画布比这个大一圈，伸出去的部分不会被裁掉。
const AREA := Rect2(0.27, 0.22, 0.40, 0.58)
const SWOOP_EVERY := Vector2(4.0, 7.0)
const IGNITE_RADIUS := 0.45      # 格
const TONGUE_STEPS := 10

# --- 子类可改 ---------------------------------------------------------------
var creature_name := "PrepBoardCreature"
# 配色：暗边 / 主体 / 核心 / 白热 / 光丝 / 柔光晕（默认值 = 定稿凤凰的橙色版共鸣光）
var col_edge := Color(0.16, 0.05, 0.01)
var col_main := Color(0.90, 0.36, 0.03)
var col_hot := Color(1.0, 0.64, 0.16)
var col_white := Color(1.0, 0.94, 0.74)
var col_thread := Color(1.0, 0.78, 0.40)
var col_halo := Color(1.0, 0.48, 0.08)
var cruise_speed := 0.95         # 格 / 秒
var turn_rate := 1.9             # 弧度 / 秒
var flap_hz := 0.9
var body_scale := 0.6            # 造型相对「一格」的大小（只缩造型，速度和点燃特效按格算）
var core_offset := 0.22          # 光核在身体前方多远（× 造型尺寸）

# --- 状态 ------------------------------------------------------------------
var cell_px := 150.0
var _canvas_origin_uv := Vector2.ZERO
var _canvas_uv_size := Vector2.ONE
var _canvas_px := Vector2(900, 700)
var _pieces: Callable
var _rng := RandomNumberGenerator.new()

var _t := 0.0
var _pos := Vector2.ZERO
var _vel := Vector2.ZERO
var _heading := -PI * 0.5
var _bank := 0.0
var _target := Vector2.ZERO
var _flap_phase := 0.0
var _flap_amount := 1.0
var _flap_timer := 1.5
var _flapping := true
var _fold := 0.0                  # +1 蓄力（翅膀前收 / 身体弯成 C），-1 冲刺（后掠 / 绷直）

var _mode := "wander"
var _mode_t := 0.0
var _next_swoop := 3.0
var _swoop_index := -1
var _swoop_pos := Vector2.ZERO
var _last_swoop_index := -1

var _embers: Array[Dictionary] = []
var _flares: Array[Dictionary] = []

var _scale := 0.0
var _unfold := 0.0
var _appear_t := -1.0
var _leaving := false
var _leave_t := 0.0
var _strength := 1.0

var _fx_layer: Node2D
# 本帧要画的形状：每条 {spine: Array[Vector2], width: float, highlight: bool}
var _tongues: Array[Dictionary] = []


func setup(canvas_origin_uv: Vector2, canvas_uv_size: Vector2, canvas_px: Vector2, cell: float, pieces: Callable, seed_value: int = 7) -> void:
	name = creature_name
	_canvas_origin_uv = canvas_origin_uv
	_canvas_uv_size = canvas_uv_size
	_canvas_px = canvas_px
	cell_px = cell
	_pieces = pieces
	_rng.seed = seed_value
	_fx_layer = Node2D.new()
	_fx_layer.name = "Fx"
	_fx_layer.draw.connect(_draw_fx)
	add_child(_fx_layer)
	_pos = uv_to_px(AREA.get_center())
	_vel = Vector2.from_angle(_heading) * cell_px * 0.2
	_target = _random_point()


func uv_to_px(uv: Vector2) -> Vector2:
	return (uv - _canvas_origin_uv) / _canvas_uv_size * _canvas_px


# 联动刚成立（大档）
func appear_with_rebirth() -> void:
	_pos = uv_to_px(AREA.get_center())
	_vel = Vector2.from_angle(_heading) * cell_px * 0.05
	_appear_t = 0.0
	_scale = 0.0
	_unfold = 0.0
	_add_flare(_pos, 2.0, true)
	_burst_embers(_pos, 30, 1.4)


# 进备战页时联动早已成立：淡入
func appear_quiet() -> void:
	_appear_t = 99.0
	_scale = 1.0
	_unfold = 1.0
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.6).set_ease(Tween.EASE_OUT)


func dismiss() -> void:
	if _leaving:
		return
	_leaving = true
	_leave_t = 0.0
	_burst_embers(_pos, 36, 1.3)


func set_strength(v: float) -> void:
	_strength = v


# --- 子类覆盖点 ---------------------------------------------------------------

# 往 _tongues 里加形状。s = 当前造型尺寸（像素）。
func _build_shape(_s: float) -> void:
	pass


# 本体画完之后再画的东西（默认：胸口光核 + 光丝）
func _draw_extra(s: float, beat: float) -> void:
	_draw_core(s, beat)


# 掠过棋子 / 登场时地面上的那一下（默认：一圈朝外窜的火舌）
func _draw_ignite(f: Dictionary) -> void:
	_draw_flame_ring(f)


# --- 每帧 -------------------------------------------------------------------

func _process(delta: float) -> void:
	delta = minf(delta, 0.05)
	_t += delta
	_update_appear(delta)
	_update_flight(delta)
	_update_particles(delta)
	_tongues.clear()
	if _scale > 0.001:
		_build_shape(cell_px * _scale * body_scale)
	queue_redraw()
	_fx_layer.queue_redraw()
	if _leaving:
		_leave_t += delta
		if _leave_t > 1.4:
			queue_free()


func _update_appear(delta: float) -> void:
	if _leaving:
		_scale = maxf(0.0, 1.0 - _ease_in(clampf(_leave_t / 0.4, 0.0, 1.0)))
		return
	if _appear_t < 0.0 or _appear_t > 5.0:
		return
	_appear_t += delta
	# 特效先炸 0.15 秒，本体弹出（过冲），附件晚一拍再展开 —— 分两拍，才像「破出来」
	_scale = _ease_out_back(clampf((_appear_t - 0.15) / 0.45, 0.0, 1.0)) if _appear_t > 0.15 else 0.0
	_unfold = _ease_out_back(clampf((_appear_t - 0.35) / 0.55, 0.0, 1.0)) if _appear_t > 0.35 else 0.0


func _update_flight(delta: float) -> void:
	_mode_t += delta
	var speed_target := cruise_speed
	var fold_target := 0.0
	match _mode:
		"wander":
			if _pos.distance_to(_target) < cell_px * 0.5:
				_target = _random_point()
			_next_swoop -= delta
			if _next_swoop <= 0.0 and _pick_swoop():
				_mode = "gather"
				_mode_t = 0.0
		"gather":
			speed_target = cruise_speed * 0.45
			fold_target = 1.0
			_target = _swoop_pos
			_flapping = true
			if _mode_t > 0.5:
				_mode = "dash"
				_mode_t = 0.0
		"dash":
			var k := clampf(_mode_t / 0.5, 0.0, 1.0)
			speed_target = lerpf(cruise_speed, cruise_speed * 3.2, _ease_in(k))
			fold_target = -1.0
			_target = _swoop_pos
			_flapping = false
			if _pos.distance_to(_swoop_pos) < cell_px * IGNITE_RADIUS:
				_ignite(_swoop_index, _swoop_pos)
				_mode = "settle"
				_mode_t = 0.0
				_target = _pos + _vel.normalized() * cell_px * 1.2
			elif _mode_t > 2.5:
				_mode = "settle"
				_mode_t = 0.0
		"settle":
			var k := clampf(_mode_t / 0.9, 0.0, 1.0)
			speed_target = lerpf(cruise_speed * 2.6, cruise_speed, _ease_out(k))
			fold_target = -1.0 + _ease_out_back(k)
			_flapping = true
			if _mode_t > 1.0:
				_mode = "wander"
				_target = _random_point()
				_next_swoop = _rng.randf_range(SWOOP_EVERY.x, SWOOP_EVERY.y)
	if _appear_t >= 0.0 and _appear_t < 0.9:
		speed_target *= 0.2

	if _mode == "wander":
		_flap_timer -= delta
		if _flap_timer <= 0.0:
			_flapping = not _flapping
			_flap_timer = _rng.randf_range(1.6, 2.6) if _flapping else _rng.randf_range(1.2, 2.0)
	_flap_amount = move_toward(_flap_amount, 1.0 if _flapping else 0.0, delta * 2.0)
	var hz := flap_hz * (1.6 if _mode == "gather" else 1.0)
	_flap_phase += delta * TAU * hz * lerpf(0.3, 1.0, _flap_amount)
	var power := maxf(0.0, sin(_flap_phase)) * _flap_amount
	speed_target += cruise_speed * 0.35 * power
	_fold = lerpf(_fold, fold_target, 1.0 - exp(-delta * 6.0))

	var to_target := _target - _pos
	var cur := _vel.angle() if _vel.length() > 0.01 else _heading
	var diff := wrapf(to_target.angle() - cur, -PI, PI)
	# 冲刺时转向能力 ×3：冲刺速度是巡航的 3.2 倍，按巡航的转向上限，转弯半径有 1.5 格多，
	# 目标在侧面时会绕着棋子兜圈、永远进不了点燃半径（门禁抓到冰链 9 秒一次没点燃）。
	var tr := turn_rate * (3.0 if _mode == "dash" else 1.0)
	var turn := clampf(diff, -tr * delta, tr * delta)
	var speed := lerpf(_vel.length(), speed_target * cell_px, 1.0 - exp(-delta * 2.5))
	_vel = Vector2.from_angle(cur + turn) * speed
	_pos += _vel * delta
	_pos = _pos.clamp(uv_to_px(AREA.position), uv_to_px(AREA.end))
	_heading = lerp_angle(_heading, _vel.angle(), 1.0 - exp(-delta * 8.0))
	var bank_target := clampf(turn / (tr * delta + 0.0001), -1.0, 1.0)
	_bank = lerpf(_bank, bank_target, 1.0 - exp(-delta * 4.0))


func _update_particles(delta: float) -> void:
	var speed_k := clampf(_vel.length() / (cruise_speed * cell_px), 0.3, 3.0)
	if not _leaving and _rng.randf() < 18.0 * speed_k * _scale * delta:
		var back := -Vector2.from_angle(_heading)
		var at := _pos + back * cell_px * _rng.randf_range(0.5, 1.4) * _scale \
			+ back.orthogonal() * cell_px * _rng.randf_range(-0.35, 0.35) * _scale
		var drift := Vector2.from_angle(_rng.randf() * TAU) * cell_px * _rng.randf_range(0.05, 0.2)
		_spawn_ember(at, drift - _vel * 0.1, _rng.randf_range(0.5, 1.0))
	for i in range(_embers.size() - 1, -1, -1):
		var e: Dictionary = _embers[i]
		e["age"] = float(e["age"]) + delta
		if float(e["age"]) >= float(e["life"]):
			_embers.remove_at(i)
			continue
		e["vel"] = (e["vel"] as Vector2) * (1.0 - delta * 1.6)
		e["pos"] = (e["pos"] as Vector2) + (e["vel"] as Vector2) * delta
	for i in range(_flares.size() - 1, -1, -1):
		var f: Dictionary = _flares[i]
		f["age"] = float(f["age"]) + delta
		if float(f["age"]) >= float(f["life"]):
			_flares.remove_at(i)


# --- 掠过 / 点燃 --------------------------------------------------------------

func _pick_swoop() -> bool:
	if not _pieces.is_valid():
		return false
	var list: Array = _pieces.call()
	if list.is_empty():
		return false
	var best := -1
	var best_score := -1e9
	for item in list:
		var d := item as Dictionary
		var idx := int(d.get("index", -1))
		var p := uv_to_px(d.get("pos", Vector2.ZERO))
		# 挑离得远、不是上一次那枚的：冲刺路线才会横穿棋盘
		var score := _pos.distance_to(p) / cell_px + _rng.randf() * 0.6 - (3.0 if idx == _last_swoop_index else 0.0)
		if score > best_score:
			best_score = score
			best = idx
			_swoop_pos = p
	_swoop_index = best
	_last_swoop_index = best
	return best >= 0


func _ignite(index: int, at: Vector2) -> void:
	_add_flare(at, 1.0, false)
	_burst_embers(at, 12, 0.9)
	piece_ignited.emit(index)


func _add_flare(at: Vector2, size: float, rebirth: bool) -> void:
	_flares.append({"pos": at, "age": 0.0, "life": 1.3 if rebirth else 0.95, "size": size,
		"rebirth": rebirth, "seed": _rng.randf() * TAU})


func _burst_embers(at: Vector2, count: int, power: float) -> void:
	for i in count:
		var v := Vector2.from_angle(_rng.randf() * TAU) * cell_px * _rng.randf_range(0.4, 1.3) * power
		_spawn_ember(at, v, _rng.randf_range(0.45, 0.9))


func _spawn_ember(at: Vector2, vel: Vector2, life: float) -> void:
	if _embers.size() >= 120:
		return
	_embers.append({"pos": at, "vel": vel, "age": 0.0, "life": life, "size": _rng.randf_range(0.025, 0.05)})


# --- 造型工具 ---------------------------------------------------------------

# 一条形状的脊线：从 root 沿 dir 出发，越往尖越卷（curl，弧度），并按 phase 自己摆动。
# s_curve > 0 时先往一边弯再往另一边弯（S 形）。返回画布坐标的点列。
func _spine(root: Vector2, dir: Vector2, length: float, curl: float, phase: float, s_curve: float = 0.0) -> Array[Vector2]:
	var pts: Array[Vector2] = []
	var p := root
	var d := dir.normalized()
	# 摆动 + 伸缩：两组不同频率的正弦叠加，每条相位不同 —— 像在烧 / 在游，不像在抖
	var sway := 0.22 * sin(_t * 3.1 + phase) + 0.10 * sin(_t * 5.3 + phase * 1.7)
	var stretch := 1.0 + 0.10 * sin(_t * 4.2 + phase * 2.3)
	var seg := length * stretch / float(TONGUE_STEPS)
	for i in TONGUE_STEPS + 1:
		pts.append(p)
		var k := float(i) / float(TONGUE_STEPS)
		var bend := curl * pow(k, 1.4) + sway * k + s_curve * sin(k * PI * 1.6)
		p += d.rotated(bend) * seg
	return pts


func _add_tongue(spine: Array[Vector2], width: float, highlight: bool) -> void:
	_tongues.append({"spine": spine, "width": width, "highlight": highlight})


# 局部坐标（x 朝前 = 头，y 朝右）→ 画布坐标
func _w(local: Vector2) -> Vector2:
	return _pos + local.rotated(_heading)


func _wd(local_dir: Vector2) -> Vector2:
	return local_dir.rotated(_heading)


# --- 绘制 -------------------------------------------------------------------

func _draw() -> void:
	if _tongues.is_empty():
		return
	# 整体身下一大团柔光（普通混合 —— 亮草地上加色会被洗白），发力那半拍亮一点，像心跳
	var s := cell_px * _scale * body_scale
	var beat := 0.85 + 0.15 * maxf(0.0, sin(_flap_phase)) * _flap_amount
	var glow_a := 0.50 * beat * _strength * (1.0 if PresentationSettings.flash_allowed() else 0.6)
	_soft_glow(self, _pos, s * 1.6, Color(col_halo, glow_a * 0.55))
	_soft_glow(self, _pos + Vector2.from_angle(_heading) * s * 0.25, s * 0.7, Color(col_hot, glow_a))
	_draw_tongues_layered(self, _tongues, cell_px * 0.035 * _scale * body_scale)
	_draw_extra(s, beat)


# 光核（照共鸣光球）：一团由暗到白热的光 + 四道往外抖动的光丝。
# 光丝的角度、弯曲、亮度都按时间慢慢变，不是每帧随机。
func _draw_core(s: float, beat: float) -> void:
	var c := _pos + Vector2.from_angle(_heading) * s * core_offset
	var a := _strength
	for i in 4:
		var ang := _heading + float(i) * PI * 0.5 + 0.45 + sin(_t * 0.9 + float(i) * 2.2) * 0.22
		var flick := 0.60 + 0.40 * sin(_t * 12.0 + float(i) * 2.0)
		var pts := PackedVector2Array()
		var steps := 8
		for k in steps + 1:
			var t := float(k) / float(steps)
			var r := s * lerpf(0.10, 0.62, t)
			var crooked := sin(t * 6.0 + float(i) * 3.2 - _t * 5.0) * 0.12 * t
			pts.append(c + Vector2.from_angle(ang + crooked) * r)
		draw_polyline(pts, Color(col_thread, 0.55 * flick * a), maxf(1.5, s * 0.035), true)
		draw_polyline(pts.slice(0, 5), Color(col_white, 0.75 * flick * a), maxf(1.0, s * 0.016), true)
	var core := s * 0.17 * (0.92 + 0.10 * beat)
	draw_circle(c, core * 1.25, Color(col_edge, 0.35 * a))   # 外圈淡：硬黑圈和游戏柔光不搭
	draw_circle(c, core, Color(col_main, a))
	draw_circle(c, core * 0.72, Color(col_hot, a))
	draw_circle(c, core * 0.42, Color(col_white, a))


# 11.04 美术统一（Leno：「参考我现在游戏的美术，做到美术统一」）：
# 游戏里的草地、胡萝卜、石头、树、升四星掉的碎片都是**低多边形切面**——每个面一个颜色，
# 朝光（左上）的面亮、背光的面暗；贴地的装饰（分路细藤、棋子脚下的圈）半透明、不描黑边。
# 第一版是平滑条带 + 对称的「暗边→主体→亮芯」条纹 + 黑粗描边，像霓虹灯管 / 贴纸贴在草地上。
# 现在每条形状沿中线劈成两半：朝左上的一半亮、另一半暗；每一小段亮度再按哈希轻微浮动成切面；
# 中线留一道细亮棱；外缘只留很淡的同色系深边。整只生物攒成一个三角数组一次提交（顺序 = 前后）。
const LIGHT_TO_SOURCE := Vector2(-0.55, -0.83)   # 光从左上来（画布坐标，y 向下）
const FACET_JITTER := 0.10


func _draw_tongues_layered(layer: CanvasItem, tongues: Array[Dictionary], pad: float) -> void:
	var rid := layer.get_canvas_item()
	# 一圈很淡的柔光托底（游戏里贴地的光都是柔的，不是一圈亮边）
	var hp := PackedVector2Array()
	var hi := PackedInt32Array()
	for tongue in tongues:
		_append_tongue(hp, hi, tongue["spine"], float(tongue["width"]) * 1.7 + pad, 1.0)
	_submit_rid(rid, hp, hi, Color(col_halo, 0.18 * _strength))
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var ridge: Array = []
	var t_i := 0
	for tongue in tongues:
		_append_faceted(pts, cols, idx, tongue["spine"], float(tongue["width"]), t_i, bool(tongue["highlight"]), ridge)
		t_i += 1
	if not idx.is_empty():
		RenderingServer.canvas_item_add_triangle_array(rid, idx, pts, cols)
	# 中线细亮棱（切面的折线），只画在大形状的前七成
	for r in ridge:
		layer.draw_polyline(r[0], Color(col_white, 0.55 * _strength), r[1], true)


# 一条形状的切面三角：左右两半各一组，亮度 = 该半边外法线朝光的程度 + 每段哈希浮动。
func _append_faceted(pts: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array,
		spine: Array[Vector2], width: float, salt: int, highlight: bool, ridge: Array) -> void:
	var n := spine.size()
	if n < 3 or width <= 0.0:
		return
	var lefts: Array[Vector2] = []
	var rights: Array[Vector2] = []
	var normals: Array[Vector2] = []
	for i in n:
		var k := float(i) / float(n - 1)
		var tangent := (spine[mini(i + 1, n - 1)] - spine[maxi(i - 1, 0)]).normalized()
		var normal := Vector2(-tangent.y, tangent.x)
		var w := width * _profile(k) * 0.5
		lefts.append(spine[i] + normal * w)
		rights.append(spine[i] - normal * w)
		normals.append(normal)
	# 亮面往白热色提一点：只有切面会变成哑光折纸，Leno 要的「亮」就没了
	var lit := col_hot.lerp(col_white, 0.35)
	var shade := col_main.darkened(0.25)
	var a := _strength
	for i in n - 1:
		var jit := (fposmod(sin(float(i * 37 + salt * 101) * 12.9898) * 43758.5453, 1.0) - 0.5) * 2.0 * FACET_JITTER
		var nrm := (normals[i] + normals[i + 1]).normalized()
		for side: float in [1.0, -1.0]:
			var b := clampf(nrm.dot(LIGHT_TO_SOURCE) * side * 0.5 + 0.5 + jit, 0.0, 1.0)
			var c := shade.lerp(lit, b)
			c.a = a
			var e0: Vector2 = lefts[i] if side > 0.0 else rights[i]
			var e1: Vector2 = lefts[i + 1] if side > 0.0 else rights[i + 1]
			var base := pts.size()
			pts.append_array(PackedVector2Array([spine[i], e0, e1, spine[i + 1]]))
			cols.append_array(PackedColorArray([c, c, c, c]))
			idx.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	# 外缘：很淡的同色系深边（亮草地上保证轮廓可读，但不像贴纸的黑边）
	var edge := col_edge
	edge.a = 0.55 * a
	for i in n - 1:
		for side: float in [1.0, -1.0]:
			var e0: Vector2 = lefts[i] if side > 0.0 else rights[i]
			var e1: Vector2 = lefts[i + 1] if side > 0.0 else rights[i + 1]
			var o0 := e0 + normals[i] * side * 1.2
			var o1 := e1 + normals[i + 1] * side * 1.2
			var base := pts.size()
			pts.append_array(PackedVector2Array([e0, o0, o1, e1]))
			cols.append_array(PackedColorArray([edge, edge, edge, edge]))
			idx.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	if highlight and width > 6.0:
		var r := PackedVector2Array()
		for i in int(float(n) * 0.7):
			r.append(spine[i])
		if r.size() >= 2:
			ridge.append([r, maxf(1.0, width * 0.05)])


static func _submit_rid(rid: RID, points: PackedVector2Array, indices: PackedInt32Array, color: Color) -> void:
	if indices.is_empty():
		return
	var colors := PackedColorArray()
	colors.resize(points.size())
	colors.fill(color)
	RenderingServer.canvas_item_add_triangle_array(rid, indices, points, colors)


# 形状外形：根部圆、三成处最鼓、往尖收成三角（比第一版饱满，第一版像细叶子）
static func _profile(k: float) -> float:
	if k < 0.3:
		return sin(k / 0.3 * PI * 0.5) * 0.75 + 0.25
	return pow((1.0 - k) / 0.7, 0.95)


static func _append_tongue(points: PackedVector2Array, indices: PackedInt32Array, spine: Array[Vector2], width: float, length_k: float) -> void:
	# length_k 只能截短，不能超过脊线本身（> 1 会越界）
	var n := mini(int(round(float(spine.size() - 1) * length_k)) + 1, spine.size())
	if n < 3:
		return
	var base := points.size()
	for i in n:
		var k := float(i) / float(n - 1)
		var a := spine[maxi(i - 1, 0)]
		var b := spine[mini(i + 1, n - 1)]
		var tangent := (b - a).normalized()
		var normal := Vector2(-tangent.y, tangent.x)
		var w := width * _profile(k) * 0.5
		points.append(spine[i] + normal * w)
		points.append(spine[i] - normal * w)
	for i in n - 1:
		var l0 := base + i * 2
		indices.append_array([l0, l0 + 2, l0 + 3, l0, l0 + 3, l0 + 1])


# 前景：火星 + 地面特效。
# 火星画成柔和的十字星点（游戏场景里漂的萤火虫 / 升星的星星都是这种），不是硬边圆点。
func _draw_fx() -> void:
	for e in _embers:
		var k := float(e["age"]) / float(e["life"])
		var r := cell_px * float(e["size"]) * (1.0 - 0.5 * k)
		var col := col_white if k < 0.3 else (col_hot if k < 0.6 else col_main)
		var a := (1.0 - k * k) * _strength
		_twinkle(_fx_layer, e["pos"], r, Color(col, a), float(e["age"]) * 3.0)
	for f in _flares:
		_draw_ignite(f)


# 柔和十字星点：软光晕 + 两道细芒 + 白芯
func _twinkle(layer: CanvasItem, at: Vector2, r: float, color: Color, rot: float) -> void:
	if r <= 0.3 or color.a <= 0.01:
		return
	_soft_glow(layer, at, r * 2.4, Color(color, color.a * 0.45))
	for i in 2:
		var d := Vector2.from_angle(rot + PI * 0.5 * float(i)) * r * 1.6
		layer.draw_line(at - d, at + d, Color(color, color.a * 0.85), maxf(1.0, r * 0.22), true)
	layer.draw_circle(at, r * 0.35, Color(col_white, color.a))


# 默认的地面特效：一圈朝外窜的火舌，长度先弹出过冲再回落（overshoot），然后收掉。棋子站在圈中间。
func _draw_flame_ring(f: Dictionary) -> void:
	var age := float(f["age"])
	var k := age / float(f["life"])
	var size := float(f["size"]) * cell_px
	var pop := _ease_out_back(clampf(age / 0.22, 0.0, 1.0))
	var fade := 1.0 - smoothstep(0.45, 1.0, k)
	var at: Vector2 = f["pos"]
	var r := size * lerpf(0.15, 0.42, _ease_out(clampf(k / 0.6, 0.0, 1.0)))
	var count := 14 if bool(f["rebirth"]) else 10
	var saved: Array[Dictionary] = _tongues.duplicate()
	_tongues.clear()
	for i in count:
		var a := TAU * float(i) / float(count) + float(f["seed"])
		var dir := Vector2.from_angle(a)
		var length := size * (0.42 + 0.16 * sin(float(f["seed"]) * 3.0 + float(i) * 2.3)) * pop * fade
		if length < 2.0:
			continue
		_add_tongue(_spine(at + dir * r, dir, length, (0.5 if i % 2 == 0 else -0.5), float(i)), size * 0.16 * fade, true)
	_draw_tongues_layered(_fx_layer, _tongues, cell_px * 0.025)
	_tongues = saved


static var _glow_tex: GradientTexture2D


static func _soft_glow(layer: CanvasItem, at: Vector2, r: float, color: Color) -> void:
	if r <= 0.5 or color.a <= 0.003:
		return
	if _glow_tex == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.4, 1.0])
		g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.45), Color(1, 1, 1, 0)])
		_glow_tex = GradientTexture2D.new()
		_glow_tex.gradient = g
		_glow_tex.fill = GradientTexture2D.FILL_RADIAL
		_glow_tex.fill_from = Vector2(0.5, 0.5)
		_glow_tex.fill_to = Vector2(1.0, 0.5)
		_glow_tex.width = 64
		_glow_tex.height = 64
	layer.draw_texture_rect(_glow_tex, Rect2(at - Vector2(r, r), Vector2(r, r) * 2.0), false, color)


func _random_point() -> Vector2:
	return uv_to_px(Vector2(_rng.randf_range(AREA.position.x + 0.04, AREA.end.x - 0.04),
		_rng.randf_range(AREA.position.y + 0.05, AREA.end.y - 0.05)))


static func _ease_out(x: float) -> float:
	return 1.0 - pow(1.0 - x, 3.0)


static func _ease_in(x: float) -> float:
	return x * x * x


static func _ease_out_back(x: float) -> float:
	var c := x - 1.0
	return 1.0 + 2.70158 * c * c * c + 1.70158 * c * c
