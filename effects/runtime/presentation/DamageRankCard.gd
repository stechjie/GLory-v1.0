extends Control
## 排行榜里的一块木牌：头像 + 头像框 + 名字（标题牌）+ 数字（数字牌）+ 奖励金币。
## 名次不再画角标（11-18 用户：1/2/3 数字和木牌不协调），名次靠上下位置和大小表达。
## 底板、数字字体、墨光、火、光晕全部沿用单人伤害计数那一套（DamageCounterPlate /
## damage_counter_*.gdshader），只是一块牌变成三块，由 DamageLeaderboard 排位和挪动。
## 火和光晕只给第一名（set_flame）：三块牌都烧太乱，光晕会互相压，低配机也扛不住。
## 坐标都是「设计像素」：木牌 FULL_W×88 的图，抽掉两段平直的木头后宽 PLATE_SIZE.x（见 ShortPlate），
## 左边多出 PAD_LEFT 给压在红宝石上的头像。
## 第二、三名由外面整块 scale 缩小，这里不用管。

const PLATE := preload("res://effects/runtime/presentation/DamageCounterPlate.gd")
const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")
const Fonts := preload("res://ui/fonts/UIFontFallback.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const AvatarCatalog := preload("res://scripts/account/AvatarCatalog.gd")
## 对局内金币统一用这张（四星升级、萝卜营地、棋子详情都是它）。运行时 load：战斗服务器包不带导入贴图。
const COIN_PATH := "res://assets/ui/unit_detail/icon_gold_stack.png"
const DISPLAY_FONT := preload("res://ui/fonts/LibreBaskerville-Variable.ttf")
const INK_SHADER := preload("res://shaders/damage_counter_ink.gdshader")
const FLAME_SHADER := preload("res://shaders/damage_counter_fire.gdshader")
const AURA_SHADER := preload("res://shaders/damage_counter_blast.gdshader")
const AURA_EXTENT := Vector2(344, 138)
const AURA_PLATE_ORIGIN := Vector2(8, 50)

## 原图的设计宽度（单人伤害木牌就是这么宽）。
const FULL_W := 286.0
## 11-18 用户：榜上的木牌太长、数字前面空一大截。原图在两处是横向一模一样的平直木头：
## 标题牌中段（x 0.30~0.70）和标题牌右边那截底板（x 0.76~0.88）。各抽掉一段再拼起来，
## 红宝石、叶子、卷边、标题牌的两头都不变形。下面是留下来的三段（原图比例）。
const SEGMENTS := [Vector2(0.0, 0.40), Vector2(0.505, 0.78), Vector2(0.87, 1.0)]
## 留下的比例 = 0.40 + 0.275 + 0.13 = 0.805。
const KEEP := 0.805
const PLATE_SIZE := Vector2(FULL_W * KEEP, 88)
## 头像中心对着图里那颗红宝石（约 x 0.06 / y 0.37），往左探出木牌一截。
const PAD_LEFT := 40.0
const AVATAR_BOX := 80.0
const AVATAR_CENTER := Vector2(PAD_LEFT + 6.0, 44.0)
const CARD_SIZE := Vector2(PAD_LEFT + FULL_W * KEEP, 96.0)
const TEAM_COLORS := [Color("f7937e"), Color("86bbf3")]

var slot := -1
var _plate: Control
var _name_label: Label
var _number: Label
var _depth: Label
var _ink: ShaderMaterial
var _fire: ColorRect
var _fire_material: ShaderMaterial
var _aura: ColorRect
var _aura_material: ShaderMaterial
var _portrait: TextureRect
var _frame: TextureRect
var _reward_box: Control
var _reward: Label
var _flash_tween: Tween
var _pop_tween: Tween
var _value_text := ""
var _flame_level := -1.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	size = CARD_SIZE
	custom_minimum_size = CARD_SIZE


func _ready() -> void:
	var plate_origin := Vector2(PAD_LEFT, 0)
	_aura = ColorRect.new()
	_aura.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_aura_material = ShaderMaterial.new()
	_aura_material.shader = AURA_SHADER
	_aura_material.set_shader_parameter("extent", AURA_EXTENT)
	_aura_material.set_shader_parameter("plate_origin", AURA_PLATE_ORIGIN)
	_aura_material.set_shader_parameter("px", 1.0)
	_aura.material = _aura_material
	# 光晕 / 火的 shader 按原图宽画，这里整块横向压成同一个比例。
	_aura.position = plate_origin - AURA_PLATE_ORIGIN * Vector2(KEEP, 1.0)
	_aura.size = AURA_EXTENT
	_aura.scale = Vector2(KEEP, 1.0)
	_aura.hide()
	add_child(_aura)

	_plate = ShortPlate.new()
	_plate.position = plate_origin
	_plate.size = PLATE_SIZE
	add_child(_plate)

	# 标题牌（原图 x 0.26~0.75，抽掉中段后约 78~182）放名字；原来写的是「Damage」。
	_name_label = _make_label(Color.WHITE)
	_name_label.position = plate_origin + Vector2(80, 2)
	_name_label.size = Vector2(_cut_x(0.73) - 80.0, 26)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name_label.clip_text = true
	_name_label.add_theme_font_size_override("font_size", 20)
	_name_label.add_theme_constant_override("outline_size", 6)
	var name_font := Fonts.bold_font()
	if name_font != null:
		_name_label.add_theme_font_override("font", name_font)

	# 数字牌：和单人计数同一套字（Baskerville 窄体、等宽数字）、同一个墨光 shader。
	var face := FontVariation.new()
	face.base_font = DISPLAY_FONT
	face.variation_opentype = {"wght": 500.0}
	face.variation_transform = Transform2D(Vector2(0.78, 0.0), Vector2(0.0, 1.0), Vector2.ZERO)
	face.opentype_features = {"lnum": 1, "tnum": 1}
	_depth = _make_label(Color("2a1608"))
	_number = _make_label(Color.WHITE)
	for label in [_depth, _number]:
		label.add_theme_font_override("font", face)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		label.clip_text = true
		label.add_theme_color_override("font_outline_color", Color("2a1608"))
		label.add_theme_constant_override("outline_size", 1 if label == _depth else 0)
		label.add_theme_font_size_override("font_size", 34)
	_number.position = plate_origin + Vector2(30, 26)
	_number.size = Vector2(_cut_x(0.91) - 30.0, 56)
	_number.pivot_offset = _number.size * 0.5
	_depth.position = _number.position + Vector2(0.7, 1.1)
	_depth.size = _number.size
	_depth.pivot_offset = _number.pivot_offset
	_ink = ShaderMaterial.new()
	_ink.shader = INK_SHADER
	_ink.set_shader_parameter("promotion", 0.0)
	_ink.set_shader_parameter("sweep", 1.0)
	_number.material = _ink

	_fire = ColorRect.new()
	_fire.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fire_material = ShaderMaterial.new()
	_fire_material.shader = FLAME_SHADER
	_fire.material = _fire_material
	_fire.position = plate_origin + Vector2(0, -10)
	_fire.size = Vector2(FULL_W, 112)
	_fire.scale = Vector2(KEEP, 1.0)
	_fire.hide()
	add_child(_fire)

	_build_avatar()
	_build_reward()
	_refresh_ink_metrics()


func _make_label(color: Color) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.focus_mode = Control.FOCUS_NONE
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0.09, 0.055, 0.02, 0.94))
	add_child(label)
	return label


# 头像画法照抄战斗里教学那组头像（BattleArena._add_tutorial_team_portraits）：
# 圆形遮罩里铺头像，框压在头像上面（11.16 用户定的叠放顺序）。
func _build_avatar() -> void:
	var badge := Control.new()
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.position = AVATAR_CENTER - Vector2.ONE * AVATAR_BOX * 0.5
	badge.size = Vector2.ONE * AVATAR_BOX
	add_child(badge)
	var mask := Panel.new()
	mask.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var inset := AVATAR_BOX * 0.17
	mask.offset_left = inset
	mask.offset_top = inset
	mask.offset_right = -inset
	mask.offset_bottom = -inset
	var circle := StyleBoxFlat.new()
	circle.bg_color = Color("2a1608")
	circle.set_corner_radius_all(int(AVATAR_BOX))
	mask.add_theme_stylebox_override("panel", circle)
	badge.add_child(mask)
	_portrait = TextureRect.new()
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.add_child(_portrait)
	_frame = TextureRect.new()
	_frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_child(_frame)


# 奖励：一摞金币 + 「+150」，挂在木牌外侧、和数字同一高度，不加底框（11-18 用户：深色小签不协调；
# 压在木牌下沿的金边上又太挤）。
func _build_reward() -> void:
	_reward_box = Control.new()
	_reward_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reward_box.size = Vector2(96, 34)
	_reward_box.position = Vector2(PAD_LEFT + PLATE_SIZE.x + 2, 36)
	add_child(_reward_box)
	var coin := TextureRect.new()
	coin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	coin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	coin.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	coin.size = Vector2(34, 34)
	if ResourceLoader.exists(COIN_PATH):
		coin.texture = load(COIN_PATH) as Texture2D
	_reward = Label.new()
	_reward.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reward.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_reward.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_reward.position = Vector2(32, 1)
	_reward.size = Vector2(_reward_box.size.x - 32, 32)
	_reward.add_theme_font_size_override("font_size", 22)
	_reward.add_theme_color_override("font_color", Color("ffe08a"))
	_reward.add_theme_color_override("font_outline_color", Color("2a1406"))
	_reward.add_theme_constant_override("outline_size", 7)
	_reward.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.45))
	_reward.add_theme_constant_override("shadow_offset_y", 2)
	var bold := Fonts.bold_font()
	if bold != null:
		_reward.add_theme_font_override("font", bold)
	_reward_box.add_child(_reward)
	_reward_box.add_child(coin)


func _refresh_ink_metrics() -> void:
	var font_size := _number.get_theme_font_size("font_size")
	var font := _number.get_theme_font("font")
	var baseline := (_number.size.y - font.get_height(font_size)) * 0.5 + font.get_ascent(font_size)
	var scan := Vector2(-_number.size.x * 0.10, _number.size.x * 1.12)
	_ink.set_shader_parameter("extent", _number.size)
	_ink.set_shader_parameter("ink_y", Vector2(baseline - float(font_size) * 0.66, baseline))
	_ink.set_shader_parameter("scan_range", scan)
	_fire_material.set_shader_parameter("focus_y",
		(_number.position.y + baseline - float(font_size) * 0.33 - _fire.position.y) / _fire.size.y)
	_fire_material.set_shader_parameter("sweep_range",
		(scan + Vector2.ONE * (_number.position.x - _fire.position.x)) / (_fire.size.x * _fire.scale.x))


## 换人（同一块牌换给另一个座位）时调用；同一个人重复调用不重画头像。
func set_player(new_slot: int, display_name: String, avatar: String, frame: String, team: int) -> void:
	_name_label.text = display_name
	_name_label.add_theme_color_override("font_color", TEAM_COLORS[clampi(team, 0, 1)])
	if new_slot == slot:
		return
	slot = new_slot
	AvatarCatalog.set_avatar_texture(_portrait, AvatarCatalog.texture_for(avatar))
	AvatarCatalog.set_frame_texture(_frame, AvatarCatalog.frame_texture_for(frame))


func set_reward(reward_gold: int) -> void:
	_reward.text = "+%d" % reward_gold
	_reward_box.visible = reward_gold > 0


## 只改标题牌上的字（「你 · 第 5 名」那块小牌用）。
func set_caption(text: String, color: Color, font_size := 20) -> void:
	_name_label.text = text
	_name_label.add_theme_font_size_override("font_size", font_size)
	_name_label.add_theme_color_override("font_color", color)


func set_damage(value: int, accent: Color, animate: bool) -> void:
	var text := "× " + group_digits(maxi(0, value))
	var changed := text != _value_text
	_value_text = text
	_ink.set_shader_parameter("accent", accent)
	_plate.call("set_accent", accent)
	_number.text = text
	_depth.text = _number.text
	# 位数多了就缩字，保证完整数字留在数字牌里（与单人计数同一规则）。
	var font := _number.get_theme_font("font")
	var font_size := 34
	var width := font.get_string_size(_number.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	if width > _number.size.x:
		font_size = maxi(18, floori(float(font_size) * _number.size.x / width))
	if _number.get_theme_font_size("font_size") != font_size:
		_number.add_theme_font_size_override("font_size", font_size)
		_depth.add_theme_font_size_override("font_size", font_size)
		_refresh_ink_metrics()
	if changed and animate and _motion_allowed():
		if _pop_tween != null:
			_pop_tween.kill()
		_number.scale = Vector2.ONE * 1.008
		_depth.scale = _number.scale
		_pop_tween = create_tween().set_parallel(true)
		_pop_tween.tween_property(_number, "scale", Vector2.ONE, 0.12)
		_pop_tween.tween_property(_depth, "scale", Vector2.ONE, 0.12)


static func group_digits(value: int) -> String:
	var digits := str(value)
	var grouped := ""
	for index in range(digits.length()):
		if index > 0 and (digits.length() - index) % 3 == 0:
			grouped += ","
		grouped += digits[index]
	return grouped


## level 0 = 不烧（不是第一名，或第一名还没到第一档）。promoted = 刚升档 / 刚接过第一名，
## 播一次和单人计数一样的冲击 + 扫光。
func set_flame(level: float, tier: float, accent: Color, promoted: bool) -> void:
	var burning := level > 0.0
	_fire.visible = burning
	_aura.visible = burning
	if not burning:
		_flame_level = 0.0
		return
	var motion := _motion_allowed()
	_aura_material.set_shader_parameter("level", level)
	_aura_material.set_shader_parameter("accent", accent)
	_aura_material.set_shader_parameter("motion", 1.0 if motion else 0.0)
	_aura_material.set_shader_parameter("simple", 0.0 if Presentation.flash_allowed() else 1.0)
	_aura_material.set_shader_parameter("lite", 1.0 if Presentation._low_tier() else 0.0)
	_fire_material.set_shader_parameter("tier", tier)
	_fire_material.set_shader_parameter("flame_color", accent)
	_fire_material.set_shader_parameter("motion", 1.0 if motion else 0.0)
	_fire_material.set_shader_parameter("simple", 0.0 if Presentation.flash_allowed() else 1.0)
	if promoted and motion and Presentation.flash_allowed():
		_aura_material.set_shader_parameter("punch", 0.0)
		_aura_material.set_shader_parameter("punch_power", level / 6.0)
		_fire_material.set_shader_parameter("promotion", 1.0)
		_fire_material.set_shader_parameter("sweep", 0.0)
		var tween := create_tween().set_parallel(true)
		tween.tween_property(_aura_material, "shader_parameter/punch", 1.0, 0.55)
		tween.tween_property(_fire_material, "shader_parameter/promotion", 0.0, 0.48) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.tween_property(_fire_material, "shader_parameter/sweep", 1.0, 0.35) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	else:
		_aura_material.set_shader_parameter("punch", 1.0)
		_fire_material.set_shader_parameter("promotion", 0.0)
		_fire_material.set_shader_parameter("sweep", 1.0)
	_flame_level = level


## 超车：整块牌亮一下（modulate 提亮再回落），不抖、不震屏。
func flash_overtake() -> void:
	if not _motion_allowed() or not Presentation.flash_allowed():
		return
	if _flash_tween != null:
		_flash_tween.kill()
	modulate = Color(1.55, 1.42, 1.15, 1.0)
	_flash_tween = create_tween()
	_flash_tween.tween_property(self, "modulate", Color.WHITE, 0.5) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _motion_allowed() -> bool:
	return not Presentation._toggle("reduced_motion") and not Tokens.reduced_motion()


## 原图比例 x（0~1）在抽掉两段之后的设计像素位置。落在被抽掉的段里就贴到下一段开头。
static func _cut_x(fraction: float) -> float:
	var x := 0.0
	for seg: Vector2 in SEGMENTS:
		if fraction <= seg.x:
			return x
		if fraction <= seg.y:
			return x + (fraction - seg.x) * FULL_W
		x += (seg.y - seg.x) * FULL_W
	return x


## 抽短的伤害木牌：把原图按 SEGMENTS 三段拼起来画；没贴图时退回一块深棕牌。
## 数字下面那道跟档位变色的细线和 DamageCounterPlate 一样。
class ShortPlate extends Control:
	var accent := Color("ffd24a")

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	func set_accent(value: Color) -> void:
		if accent == value:
			return
		accent = value
		queue_redraw()

	func _draw() -> void:
		var texture: Texture2D = PLATE.plaque_texture()
		if texture == null:
			draw_rect(Rect2(size * Vector2(0.03, 0.34), size * Vector2(0.94, 0.52)), Color("4a2a16"))
		else:
			var tex_size := texture.get_size()
			var x := 0.0
			for seg: Vector2 in SEGMENTS:
				var w := (seg.y - seg.x) * FULL_W
				# 段与段之间多画半个像素，避免拼缝。
				draw_texture_rect_region(texture, Rect2(x, 0, w + 0.5, size.y),
					Rect2(seg.x * tex_size.x, 0, (seg.y - seg.x) * tex_size.x, tex_size.y))
				x += w
		var face: Rect2 = PLATE.NUMBER_FACE
		var y := (face.position.y + face.size.y * 0.95) * size.y
		draw_line(Vector2(size.x * 0.17, y), Vector2(size.x * 0.86, y), Color(accent.r, accent.g, accent.b, 0.55), 1.4, true)
