extends Node3D

# 羁绊跨档时，挂在**该族每一枚棋盘棋子**脚下的一次性特效（10.31）。
#
# 两档：
#   · major（中间档，如神3 / 暗2 / 灵4）：脚下一圈种族色光环往外扩 + 地面一闪 +
#     一小撮光点往上飘。约 0.55 秒。
#   · ultimate（最高档）：上面全部加量，再加一道从脚下拔起的种族色光柱。约 0.9 秒。
#
# 和升星迸发（PrepStarUpgradeBurst）刻意区分开：升星是「星星炸开」，冷白/金；
# 羁绊是「地面扩圈 + 往上照」，取种族色 —— 两件事同时发生时（合成出第 7 枚）一眼能分清。
#
# 尺度约定与 PrepStarUpgradeBurst 相同：CELL_SIZE / UNIT_HEIGHT 是「一格 / 一枚棋子」
# 的设计单位，挂上去时由 PrepBoardModels._prep_effect_scale() 按实测格距统一换算。
# 备战阶段不做顿帧、不震屏：会拖慢倒计时、挡住拖拽。

const CELL_SIZE := 0.6
const UNIT_HEIGHT := 0.32
const TEX_SIZE := 128
const GROUND_LIFT := 0.015
const RENDER_PRIORITY := 20
const SHADOW_COLOR := Color(0.04, 0.05, 0.08)
const SHADOW_ALPHA := 0.38

# 种族色 = 种族 logo（assets/ui/race_logos/*.png）**中间纹章**的颜色（Leno 10.31：
# 「每个种族 logo 都有不同颜色，用 logo 的颜色做特效」）。
# 取法：只取外圈铜框以内（半径 62%）、亮度 ≥0.45 的像素，按亮度排序取中段平均 ——
# 铜框五族共用，不能算进去；最亮那一截是高光，会把颜色洗白。
# 神族纹章本身就是象牙白，所以它的特效偏白是对的，不是取色失败。
# 换 logo 后照这个口径重取，左侧面板计数色也跟着走（SynergyPanel 读的是这张表）。
const RACE_COLORS := {
	"god": Color(0.87, 0.79, 0.67),
	"human": Color(0.21, 0.49, 0.83),
	"undead": Color(0.58, 0.76, 0.11),
	"dark": Color(0.50, 0.21, 0.88),
	"crimson": Color(0.92, 0.17, 0.15),
}

const PRESETS := {
	"major": {
		"duration": 0.55,
		"ring_from": 0.35, "ring_to": 1.25,   # 光环直径（格）
		"flash_size": 0.95, "flash_alpha": 0.55,
		"mote_count": 8, "mote_size": 0.05, "mote_rise": 1.5,
		"pillar": false,
	},
	"ultimate": {
		"duration": 0.90,
		"ring_from": 0.35, "ring_to": 1.7,
		"flash_size": 1.2, "flash_alpha": 0.8,
		"mote_count": 16, "mote_size": 0.065, "mote_rise": 2.6,
		"pillar": true,
		"pillar_width": 0.42,     # 格
		"pillar_height": 4.2,     # 棋子身高的倍数
	},
}

static var _ring_texture: ImageTexture
static var _disc_texture: ImageTexture
static var _beam_texture: ImageTexture

var _kind := "major"
var _color := Color.WHITE
var _elapsed := 0.0
var _playing := false
var _ring: MeshInstance3D
var _ring_shadow: MeshInstance3D
var _flash: MeshInstance3D
var _pillar: MeshInstance3D
var _motes: Array[MeshInstance3D] = []
var _mote_specs: Array[Dictionary] = []


static func race_color(race: String) -> Color:
	return RACE_COLORS.get(race, RACE_COLORS["human"])


func play(race: String, ultimate: bool) -> void:
	_kind = "ultimate" if ultimate else "major"
	_color = race_color(race)
	_elapsed = 0.0
	_playing = true
	_rebuild()
	_apply()


# 跳到任意时刻（截帧 / 门禁用，同 PrepStarUpgradeBurst.seek）。
func seek(t: float) -> void:
	if _ring == null:
		_rebuild()
	_elapsed = maxf(0.0, t)
	_apply()


func total_duration() -> float:
	return float((PRESETS[_kind] as Dictionary)["duration"])


func _process(delta: float) -> void:
	if not _playing:
		return
	_elapsed += delta
	_apply()
	if _elapsed >= total_duration():
		_playing = false
		queue_free()


# --- 贴图（整个进程各生成一次，白图，颜色走材质） -----------------------------

static func _ring_tex() -> ImageTexture:
	if _ring_texture == null:
		_ring_texture = _make_radial(func(r: float) -> float:
			# 细亮环 + 往里一层很淡的余晖
			var ring := pow(clampf(1.0 - absf(r - 0.82) / 0.13, 0.0, 1.0), 2.0)
			var inner := 0.18 * smoothstep(0.2, 0.8, r) * (1.0 - smoothstep(0.8, 0.95, r))
			return clampf(ring + inner, 0.0, 1.0))
	return _ring_texture


static func _disc_tex() -> ImageTexture:
	if _disc_texture == null:
		_disc_texture = _make_radial(func(r: float) -> float:
			return pow(clampf(1.0 - r, 0.0, 1.0), 2.2))
	return _disc_texture


static func _make_radial(alpha_at: Callable) -> ImageTexture:
	var image := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	var half := float(TEX_SIZE) * 0.5
	for y in TEX_SIZE:
		for x in TEX_SIZE:
			var nx := (float(x) + 0.5 - half) / half
			var ny := (float(y) + 0.5 - half) / half
			var a: float = alpha_at.call(sqrt(nx * nx + ny * ny))
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(image)


# 光柱：横向中间亮两边柔，纵向底部最亮、往上渐隐。
static func _beam_tex() -> ImageTexture:
	if _beam_texture != null:
		return _beam_texture
	var w := 64
	var h := 128
	var image := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		# y=0 是贴图顶端
		var v := float(y) / float(h - 1)
		var vertical := pow(v, 1.6) * (1.0 - smoothstep(0.93, 1.0, v) * 0.6)
		for x in w:
			var u := absf((float(x) + 0.5) / float(w) * 2.0 - 1.0)
			var core := pow(clampf(1.0 - u, 0.0, 1.0), 2.5)
			var hot := pow(clampf(1.0 - u / 0.25, 0.0, 1.0), 2.0) * 0.6
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf((core + hot) * vertical, 0.0, 1.0)))
	_beam_texture = ImageTexture.create_from_image(image)
	return _beam_texture


# --- 搭节点 -----------------------------------------------------------------

func _rebuild() -> void:
	for child in get_children():
		child.queue_free()
	_motes.clear()
	_mote_specs.clear()
	var preset: Dictionary = PRESETS[_kind]
	_flash = _make_ground_quad(_disc_tex(), true)
	# 光环底下垫一圈淡黑晕：灵族青绿压在草地上、神族象牙白压在雪地上都会糊掉，
	# 有这圈暗边，彩色环在任何底图上都分得出来。先建先画（同 priority 按建立顺序）。
	_ring_shadow = _make_ground_quad(_ring_tex(), false)
	_ring = _make_ground_quad(_ring_tex(), false)
	if bool(preset["pillar"]):
		_pillar = _make_quad(_beam_tex(), BaseMaterial3D.BILLBOARD_FIXED_Y, false)
	else:
		_pillar = null
	var count := int(preset["mote_count"])
	for i in count:
		# 固定种子：每次播出来一样，截图可比。
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("synergy_burst_%s_%d" % [_kind, i])
		var angle := TAU * float(i) / float(count) + rng.randf_range(-0.4, 0.4)
		_mote_specs.append({
			"dir": Vector3(cos(angle), 0.0, sin(angle)),
			"radius": CELL_SIZE * rng.randf_range(0.12, 0.38),
			"delay": rng.randf_range(0.0, 0.35),
			"rise": UNIT_HEIGHT * float(preset["mote_rise"]) * rng.randf_range(0.6, 1.0),
			"size": float(preset["mote_size"]) * rng.randf_range(0.7, 1.2),
		})
		_motes.append(_make_quad(_disc_tex(), BaseMaterial3D.BILLBOARD_ENABLED))


func _make_material(tex: Texture2D, billboard: int, additive: bool = true) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# 实拍（tools/synergy_activation_capture）踩到的两个坑：
	#   · 棋盘底图是一整块大的半透明面片，透明物按中心距离排序，它常常排在小光环之后画，
	#     把光环整个盖掉 —— 所以 render_priority 必须压过棋盘图层（站位图是 5）；
	#   · 草地底图本身很亮，神族金白 ADD 上去几乎不变色 —— 地面光环和光柱改用普通混合，
	#     颜色才「站得住」；光点和地面闪光仍用 ADD，保留发光感。
	mat.render_priority = RENDER_PRIORITY
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	mat.billboard_mode = billboard
	mat.albedo_texture = tex
	mat.albedo_color = _color
	mat.disable_receive_shadows = true
	return mat


func _make_quad(tex: Texture2D, billboard: int, additive: bool = true) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = QuadMesh.new()
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.material_override = _make_material(tex, billboard, additive)
	add_child(node)
	return node


# 平躺在地面上的面片（PlaneMesh 默认朝上），贴着棋子脚底。
func _make_ground_quad(tex: Texture2D, additive: bool) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE
	node.mesh = plane
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.material_override = _make_material(tex, BaseMaterial3D.BILLBOARD_DISABLED, additive)
	node.position = Vector3(0.0, GROUND_LIFT, 0.0)
	add_child(node)
	return node


func _set_alpha(node: MeshInstance3D, a: float, tint: Variant = null) -> void:
	var mat := node.material_override as StandardMaterial3D
	var c: Color = _color if tint == null else tint
	c.a = clampf(a, 0.0, 1.0)
	mat.albedo_color = c
	node.visible = a > 0.001


# --- 每帧 -------------------------------------------------------------------

func _apply() -> void:
	var preset: Dictionary = PRESETS[_kind]
	var duration := total_duration()
	var t := clampf(_elapsed / duration, 0.0, 1.0)

	# 光环：ease-out 往外扩（起步快、收尾慢），后半段淡出。
	var ring_t := clampf(t / 0.75, 0.0, 1.0)
	var grow := 1.0 - pow(1.0 - ring_t, 3.0)
	var diameter := lerpf(float(preset["ring_from"]), float(preset["ring_to"]), grow) * CELL_SIZE
	_ring.scale = Vector3(diameter, 1.0, diameter)
	var ring_alpha := smoothstep(0.0, 0.06, ring_t) * (1.0 - smoothstep(0.35, 1.0, ring_t))
	_set_alpha(_ring, ring_alpha)
	_ring_shadow.scale = Vector3(diameter * 1.07, 1.0, diameter * 1.07)
	_ring_shadow.position.y = GROUND_LIFT * 0.5
	_set_alpha(_ring_shadow, ring_alpha * SHADOW_ALPHA, SHADOW_COLOR)

	# 地面一闪：前 35% 时长内亮起又退掉。
	var flash_t := clampf(t / 0.35, 0.0, 1.0)
	var fsize := float(preset["flash_size"]) * CELL_SIZE * (0.8 + 0.2 * flash_t)
	_flash.scale = Vector3(fsize, 1.0, fsize)
	_set_alpha(_flash, float(preset["flash_alpha"]) * smoothstep(0.0, 0.12, flash_t) * (1.0 - flash_t))

	# 光柱：0.15 内从地面拔起到满高，之后变细、渐隐。
	if _pillar != null:
		var rise := 1.0 - pow(1.0 - clampf(t / 0.18, 0.0, 1.0), 2.0)
		var fade := 1.0 - smoothstep(0.35, 1.0, t)
		var height := UNIT_HEIGHT * float(preset["pillar_height"]) * maxf(rise, 0.001)
		var width := float(preset["pillar_width"]) * CELL_SIZE * lerpf(1.0, 0.45, smoothstep(0.3, 1.0, t))
		(_pillar.mesh as QuadMesh).size = Vector2(width, height)
		_pillar.position = Vector3(0.0, height * 0.5, 0.0)
		_set_alpha(_pillar, 0.9 * fade)

	# 光点：从脚边绕一点点往里收、往上飘。
	for i in _motes.size():
		var spec := _mote_specs[i]
		var delay := float(spec["delay"]) * duration
		var life := maxf(duration - delay, 0.001)
		var mt := (_elapsed - delay) / life
		var mote := _motes[i]
		if mt < 0.0 or mt > 1.0:
			mote.visible = false
			continue
		var up := 1.0 - pow(1.0 - mt, 1.8)
		var dir: Vector3 = spec["dir"]
		mote.position = dir * float(spec["radius"]) * (1.0 - 0.5 * up) + Vector3(0.0, float(spec["rise"]) * up, 0.0)
		(mote.mesh as QuadMesh).size = Vector2.ONE * float(spec["size"]) * (1.0 - 0.4 * mt)
		_set_alpha(mote, smoothstep(0.0, 0.1, mt) * (1.0 - smoothstep(0.5, 1.0, mt)))
