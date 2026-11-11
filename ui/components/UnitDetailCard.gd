extends PanelContainer

# 备战长按棋子的详情卡（11.11 羊皮纸风，照用户给的「神侍」概念图）。
#
# 从上到下：头像框 + 名字 / 星级 / 种族、元素小签 → 「属性」两列（每行底下一条浅色圆角底）
# → 「技能」图标 + 名字 + 冷却签 + 说明 → 「四星升级」内嵌框（查看四星按钮、升级石 / 金币行、
# 升级大按钮、提示）。
#
# 四星那一块只负责「长什么样」：按钮和文字都公开出来（four_star_*），
# 由 FourStarUpgradePanel 那套逻辑去填文字、开关按钮，这里不碰 GameState。
#
# 字体：标题用思源宋体粗（Noto Serif SC 900），正文用思源黑体中粗（Noto Sans SC 500/600），
# 只用在这张卡上，不改全局默认字体。

const Kit := preload("res://ui/theme/ParchmentKit.gd")
const CodexSkillArt := preload("res://ui/components/CodexSkillArt.gd")
const ART := "res://assets/ui/unit_detail/%s.png"
const SERIF_PATH := "res://ui/fonts/NotoSerifSC-VF.ttf"
const SANS_PATH := "res://ui/fonts/NotoSansSC-VF.ttf"

const INK := Color("4a2c14")
const INK_SOFT := Color("6b4526")
const STAT_ICON_TINT := Color(1, 1, 1, 0.95)
# 属性行底色：浅棕半透明，叠在羊皮纸上是一条淡淡的色带
const ROW_TINT := Color(0.55, 0.36, 0.16, 0.13)

# stat_icons.png 3x3，每格 256：生命 护甲 攻速 / 暴击 移速 攻击 / 魔抗 射程 暴伤
const STAT_CELL := {"hp": 0, "def": 1, "aspd": 2, "crit": 3, "move": 4, "atk": 5, "mres": 6, "range": 7, "crit_dmg": 8}
const LEFT_STATS := ["hp", "def", "aspd", "crit", "move"]
const RIGHT_STATS := ["atk", "mres", "range", "crit_dmg"]

signal close_requested

var four_star_box: PanelContainer
var four_star_preview: Button
var four_star_stone_icon: TextureRect
var four_star_stone_label: Label
var four_star_gold_label: Label
var four_star_action: Button
var four_star_hint: Label
var _action_stars: Array[TextureRect] = []

static var _fonts := {}


static func font(serif: bool, weight: int) -> FontVariation:
	var key := "%s%d" % ["serif" if serif else "sans", weight]
	if _fonts.has(key):
		return _fonts[key]
	var fv := FontVariation.new()
	fv.base_font = load(SERIF_PATH if serif else SANS_PATH)
	var ts := TextServerManager.get_primary_interface()
	fv.variation_opentype = {ts.name_to_tag("wght"): weight}
	_fonts[key] = fv
	return fv


static func art(piece: String) -> Texture2D:
	return load(ART % piece)


# 手绘升级石（天 / 地 / 人，没有元素用问号那颗）
static func stone_texture(element: String) -> Texture2D:
	return art("stone_%s" % (element if element in ["sky", "land", "ren"] else "unknown"))


static var _scaled := {}


# 九宫格用的缩小版贴图。StyleBoxTexture 的切边按「贴图像素」算、画出来也是这个尺寸，
# 原图 1000px 宽的按钮直接切会把端头压扁，所以先把贴图整体缩到显示尺寸（跟 ParchmentKit.tex 同一招）。
static func scaled(path: String, k: float) -> Texture2D:
	var key := "%s@%.3f" % [path, k]
	if _scaled.has(key):
		return _scaled[key]
	var image := (load(path) as Texture2D).get_image()
	if image.is_compressed():
		image.decompress()
	image.generate_mipmaps()
	var t := ImageTexture.create_from_image(image)
	t.set_size_override(Vector2i(roundi(image.get_width() * k), roundi(image.get_height() * k)))
	_scaled[key] = t
	return t


# margins 用原图像素写，k 是缩放
static func slice(path: String, k: float, margins: Vector4) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = scaled(path, k)
	sb.texture_margin_left = margins.x * k
	sb.texture_margin_top = margins.y * k
	sb.texture_margin_right = margins.z * k
	sb.texture_margin_bottom = margins.w * k
	return sb


func _init() -> void:
	custom_minimum_size = Vector2(528, 0)
	var sb := slice(Kit.DIR + "panel.png", 0.4, Vector4(146, 162, 148, 145))
	sb.content_margin_left = 40
	sb.content_margin_top = 28
	sb.content_margin_right = 40
	sb.content_margin_bottom = 20
	add_theme_stylebox_override("panel", sb)


var compact := false
# 佣兵：没有种族 / 元素 logo（换成「佣兵」小签）、技能不放图标，头像在 mercenary_portraits
var mercenary := false


static func is_mercenary_cell(cell: Dictionary) -> bool:
	var d: Dictionary = cell.get("def", {})
	return bool(cell.get("is_mercenary", false)) or bool(d.get("is_mercenary", false)) \
		or str(d.get("id", cell.get("id", ""))).begins_with("merc_")


# cell 跟棋盘格子一样：{"def": {...}, "star": n, ...}
# compact = 商店选卡时用的横版：左边头部 + 技能，右边属性，没有四星那块（还没买，不能升）。
# 横版只有约 300 高，摆在商店卷轴上方，不挡下面选棋子。
#
# upgrade_panel：长按棋盘 / 待命棋子时传进来的 FourStarUpgradePanel（真的升级逻辑），
# 直接放进「四星升级」框里；不传就画一份静态示意（预览截图用）。
# 它是外面持有、反复复用的节点，重建前先摘下来，别跟着旧内容一起被释放。
var _upgrade_panel: Control


func setup(cell: Dictionary, p_compact := false, upgrade_panel: Control = null) -> void:
	compact = p_compact
	mercenary = is_mercenary_cell(cell)
	if _upgrade_panel != null and is_instance_valid(_upgrade_panel) and _upgrade_panel.get_parent() != null:
		_upgrade_panel.get_parent().remove_child(_upgrade_panel)
	_upgrade_panel = upgrade_panel
	if upgrade_panel != null and upgrade_panel.get_parent() != null:
		upgrade_panel.get_parent().remove_child(upgrade_panel)
	for c in get_children():
		remove_child(c)
		c.queue_free()
	four_star_box = null
	four_star_action = null
	var d: Dictionary = cell.get("def", {})
	var star := int(cell.get("star", 1))
	var g := UnitDetailFormat.grown_def(d, star, cell)
	# 横版底边留宽一点：技能说明两行时第二行会贴到金框
	var panel_sb := get_theme_stylebox("panel") as StyleBoxTexture
	if panel_sb != null:
		panel_sb.content_margin_bottom = 32 if compact else 20
	if compact:
		custom_minimum_size = Vector2(0, 0)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 30)
		add_child(row)
		var left := VBoxContainer.new()
		left.add_theme_constant_override("separation", 4)
		left.custom_minimum_size.x = 400
		row.add_child(left)
		left.add_child(_header(d, star))
		left.add_child(_section_title(_t("技能", "Skill")))
		left.add_child(_skill(d, star))
		var right := VBoxContainer.new()
		right.add_theme_constant_override("separation", 6)
		right.custom_minimum_size.x = 400
		row.add_child(right)
		right.add_child(_section_title(_t("属性", "Stats")))
		right.add_child(_stats(g))
		return
	custom_minimum_size = Vector2(528, 0)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	add_child(col)
	col.add_child(_header(d, star))
	col.add_child(_section_title(_t("属性", "Stats")))
	col.add_child(_stats(g))
	col.add_child(_section_title(_t("技能", "Skill")))
	col.add_child(_skill(d, star))
	col.add_child(_four_star(d))


# ---------- 头部 ----------

func _header(d: Dictionary, star: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	# 头像：深色圆角底 + 头像裁成圆角，金框盖在上面
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(132, 124) if compact else Vector2(150, 140)
	row.add_child(holder)
	var clip := Panel.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color("1f2a3a")
	bg.set_corner_radius_all(14)
	clip.add_theme_stylebox_override("panel", bg)
	clip.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	clip.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	clip.offset_left = 7
	clip.offset_top = 7
	clip.offset_right = -7
	clip.offset_bottom = -7
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(clip)
	var portrait_path := "res://assets/ui/%s/%s.png" % [
		"mercenary_portraits" if mercenary else "unit_portraits", str(d.get("id", ""))]
	if ResourceLoader.exists(portrait_path):
		var p := TextureRect.new()
		p.texture = load(portrait_path)
		p.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		p.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		p.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip.add_child(p)
	var frame := TextureRect.new()
	frame.texture = art("portrait_frame")
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_SCALE
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(frame)

	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 4)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)
	var name_label := _label(UnitDetailFormat.localized_name(d), 32 if compact else 36, true, 900)
	info.add_child(name_label)
	var stars := HBoxContainer.new()
	stars.add_theme_constant_override("separation", 2)
	for i in clampi(star, 1, 4):
		stars.add_child(_icon(art("star_on"), 28))
	info.add_child(stars)
	# 种族 / 元素：直接放整个圆形 logo，大一点（11.11 用户：不要椭圆小签）
	var logos := HBoxContainer.new()
	logos.add_theme_constant_override("separation", 10)
	var race := str(d.get("race", ""))
	var element := str(d.get("element", ""))
	var race_logo := "res://assets/ui/race_logos/%s.png" % race
	var elem_logo := "res://assets/ui/codex_portraits/elem_%s.png" % element
	var side := 56.0 if compact else 58.0
	if ResourceLoader.exists(race_logo):
		var r := _icon(load(race_logo), side)
		r.tooltip_text = UnitDetailFormat.unit_race_name(race)
		logos.add_child(r)
	if ResourceLoader.exists(elem_logo):
		var e := _icon(load(elem_logo), side)
		e.tooltip_text = UnitDetailFormat.unit_element_name(element)
		logos.add_child(e)
	if mercenary:
		var tag := _chip(null, _t("佣兵", "Mercenary"))
		tag.custom_minimum_size = Vector2(100, 34)
		tag.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		logos.add_child(tag)
	info.add_child(logos)
	# 右上角关闭键（商店横版不要：买下 / 取消选中它自己就收起）
	if not compact:
		var close := Kit.close_button(func() -> void: close_requested.emit(), 44.0)
		close.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		row.add_child(close)
	return row


func _chip(icon: Texture2D, text: String) -> Control:
	var chip := PanelContainer.new()
	# 药丸形：只切左右两端
	var sb := slice(ART % "chip", 34.0 / 140.0, Vector4(72, 0, 72, 0))
	sb.content_margin_left = 16
	sb.content_margin_right = 18
	sb.content_margin_top = 3
	sb.content_margin_bottom = 4
	chip.add_theme_stylebox_override("panel", sb)
	chip.custom_minimum_size = Vector2(118, 34)
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_theme_constant_override("separation", 6)
	chip.add_child(h)
	if icon != null:
		var ic := _icon(icon, 22)
		h.add_child(ic)
	var l := _label(text, 16, false, 600)
	h.add_child(l)
	return chip


# ---------- 分节标题：左右各一条叶子花边，中间标题 ----------

func _section_title(text: String) -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	var left := _ornament(false)
	var right := _ornament(true)
	row.add_child(left)
	row.add_child(_label(text, 22, true, 900))
	row.add_child(right)
	return row


func _ornament(mirror: bool) -> TextureRect:
	var r := TextureRect.new()
	r.texture = art("section_ornament")
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.custom_minimum_size = Vector2(150, 20)
	r.flip_h = mirror
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


# ---------- 属性：两列，每行一条浅色底 ----------

func _stats(g: Dictionary) -> Control:
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 26)
	for keys in [LEFT_STATS, RIGHT_STATS]:
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 4)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for key in keys:
			v.add_child(_stat_row(key, g))
		cols.add_child(v)
	return cols


func _stat_row(key: String, g: Dictionary) -> Control:
	var row := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = ROW_TINT
	sb.set_corner_radius_all(12)
	sb.content_margin_left = 12
	sb.content_margin_right = 14
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	row.add_theme_stylebox_override("panel", sb)
	row.custom_minimum_size.y = 25
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	row.add_child(h)
	var at := AtlasTexture.new()
	at.atlas = art("stat_icons")
	var cell := int(STAT_CELL[key])
	at.region = Rect2((cell % 3) * 256, (cell / 3) * 256, 256, 256)
	var ic := _icon(at, 22)
	ic.modulate = STAT_ICON_TINT
	h.add_child(ic)
	var name_label := _label(_stat_name(key), 16, false, 500)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(name_label)
	var value := _label(_stat_value(key, g), 16, false, 600)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(value)
	return row


func _stat_name(key: String) -> String:
	var names := {"hp": ["生命", "HP"], "def": ["护甲", "Armor"], "aspd": ["攻速", "Atk Spd"],
		"crit": ["暴击", "Crit"], "move": ["移速", "Move"], "atk": ["攻击", "Attack"],
		"mres": ["魔抗", "M.Res"], "range": ["射程", "Range"], "crit_dmg": ["暴伤", "Crit Dmg"]}
	return _t(names[key][0], names[key][1])


func _stat_value(key: String, g: Dictionary) -> String:
	match key:
		"hp": return str(roundi(float(g.get("hp", 0))))
		"atk": return str(roundi(float(g.get("atk", 0))))
		"def": return str(roundi(float(g.get("def", 0))))
		"mres": return str(roundi(float(g.get("mres", 0))))
		"range": return _num(float(g.get("range", 1)), 1)
		# 攻速 / 移速是小数属性，整数也留一位（1 → 1.0），跟 0.95 / 3.2 对齐
		"aspd": return _num(float(g.get("attack_speed", 1.0)), 2, true)
		"move": return _num(float(g.get("move_speed", 0.0)), 1, true)
		"crit": return UnitDetailFormat.pct(float(g.get("crit", 0.0)))
		"crit_dmg": return UnitDetailFormat.pct(float(g.get("crit_dmg", 1.5)))
	return "-"


# 4.0 → "4"，0.95 → "0.95"，3.20 → "3.2"
static func _num(v: float, decimals := 2, keep_one := false) -> String:
	if is_equal_approx(v, roundf(v)):
		return "%.1f" % v if keep_one else str(roundi(v))
	return String.num(v, decimals)


# ---------- 技能 ----------

func _skill(d: Dictionary, star: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", Kit.box("slot", Vector4(5, 5, 5, 5)))
	frame.custom_minimum_size = Vector2(82, 82)
	frame.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	if not mercenary:
		row.add_child(frame)
	var tex: Texture2D = null if mercenary else CodexSkillArt.for_entry({"id": str(d.get("id", ""))})
	if tex != null:
		var ic := TextureRect.new()
		ic.texture = tex
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(ic)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(col)
	var parts := _skill_parts(d, star)
	var title := HBoxContainer.new()
	title.add_theme_constant_override("separation", 12)
	title.add_child(_label(parts[0], 22, true, 900))
	if not str(parts[1]).is_empty():
		var cd := _chip(null, parts[1])
		cd.custom_minimum_size = Vector2(100, 28)
		cd.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		(cd.get_child(0).get_child(0) as Label).add_theme_font_size_override("font_size", 14)
		title.add_child(cd)
	col.add_child(title)
	var desc := _label(parts[2], 15, false, 500)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size.x = 320
	col.add_child(desc)
	return row


# [技能名, "冷却 N 秒", 说明]。说明从总表那句里去掉「技能名（冷却x秒）：」前缀。
func _skill_parts(d: Dictionary, star: int) -> Array:
	var id := str(d.get("id", ""))
	var row: Dictionary = {}
	var table = DataRegistry.get_table("final_status")
	if table is Dictionary:
		row = table.get("units", {}).get(id, {})
	var sd := d.duplicate()
	sd["star"] = star
	var full := UnitDetailFormat.format_skill_detail(sd)
	var name := str(row.get("skill_name_en" if UnitDetailFormat.is_en() else "skill_name_cn", ""))
	var body := full
	var cut := full.find("：")
	if cut < 0:
		cut = full.find(": ")
	if cut >= 0 and cut < 24:
		if name.is_empty():
			name = full.substr(0, cut).split("（")[0].split(" (")[0]
		body = full.substr(cut + (1 if full[cut] == "：" else 2))
	if name.is_empty():
		name = _t("技能", "Skill")
	var cd := ""
	if d.has("skill_cd"):
		var v := float(d.get("skill_cd", 0.0))
		var n := str(int(v)) if is_equal_approx(v, roundf(v)) else String.num(v, 1)
		cd = _t("冷却 %s 秒" % n, "CD %ss" % n)
	return [name, cd, body]


# ---------- 四星升级内嵌框 ----------

func _four_star(d: Dictionary) -> Control:
	four_star_box = PanelContainer.new()
	var sb := slice(ART % "inset_panel", 0.4, Vector4(64, 64, 64, 64))
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 8
	sb.content_margin_bottom = 6
	four_star_box.add_theme_stylebox_override("panel", sb)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	four_star_box.add_child(col)
	col.add_child(_section_title(_t("四星升级", "4-Star Upgrade")))
	if _upgrade_panel != null:
		_upgrade_panel.show()
		col.add_child(_upgrade_panel)
		return four_star_box

	# 查看四星属性与技能（卷轴按钮）
	four_star_preview = Button.new()
	four_star_preview.custom_minimum_size = Vector2(232, 34)
	four_star_preview.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_style_texture_button(four_star_preview, "scroll_button", Vector4(80, 0, 80, 0), 34.0 / 150.0)
	var ph := HBoxContainer.new()
	ph.alignment = BoxContainer.ALIGNMENT_CENTER
	ph.add_theme_constant_override("separation", 8)
	ph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ph.add_child(_icon(art("icon_scroll"), 22))
	ph.add_child(_label(_t("查看四星属性与技能", "View 4-star stats & skill"), 16, false, 600))
	four_star_preview.add_child(ph)
	col.add_child(four_star_preview)

	# 升级石 | 金币需求
	var res := HBoxContainer.new()
	res.alignment = BoxContainer.ALIGNMENT_CENTER
	res.add_theme_constant_override("separation", 8)
	four_star_stone_icon = _icon(null, 30)
	var element := str(d.get("element", ""))
	four_star_stone_icon.texture = stone_texture(element)
	res.add_child(four_star_stone_icon)
	four_star_stone_label = _label(_t("队伍共享升级石", "Team upgrade stone"), 15, false, 500)
	res.add_child(four_star_stone_label)
	var bar := _label("|", 15, false, 400)
	bar.modulate.a = 0.45
	bar.custom_minimum_size.x = 24
	bar.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	res.add_child(bar)
	res.add_child(_icon(art("icon_gold_stack"), 24))
	four_star_gold_label = _label(_t("金币需求  —", "Gold needed  —"), 15, false, 500)
	res.add_child(four_star_gold_label)
	col.add_child(res)

	# 升级至 ★★★★
	four_star_action = Button.new()
	four_star_action.custom_minimum_size = Vector2(240, 42)
	four_star_action.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var ah := HBoxContainer.new()
	ah.alignment = BoxContainer.ALIGNMENT_CENTER
	ah.add_theme_constant_override("separation", 2)
	ah.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ah.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var al := _label(_t("升级至", "Upgrade to"), 19, true, 900)
	al.name = "Text"
	ah.add_child(al)
	var gap := Control.new()
	gap.custom_minimum_size.x = 8
	ah.add_child(gap)
	_action_stars.clear()
	for i in 4:
		var s := _icon(art("star_on"), 22)
		_action_stars.append(s)
		ah.add_child(s)
	four_star_action.add_child(ah)
	col.add_child(four_star_action)

	four_star_hint = _label("", 15, false, 500)
	four_star_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(four_star_hint)
	set_upgrade_ready(false)
	return four_star_box


# 升级按钮两种底图：可升级用金色那张（文字 / 星星正常色），不可升级换灰色那张、星星压暗。
func set_upgrade_ready(ready: bool) -> void:
	if four_star_action == null:
		return
	_style_texture_button(four_star_action, "upgrade_button_on" if ready else "upgrade_button_off",
		Vector4(115, 0, 115, 0), 42.0 / 190.0)
	four_star_action.disabled = not ready
	for s in _action_stars:
		s.modulate = Color.WHITE if ready else Color(0.32, 0.25, 0.18, 0.95)
	var text := four_star_action.find_child("Text", true, false) as Label
	if text != null:
		text.add_theme_color_override("font_color", Color("4a2608") if ready else Color("5c4a3a"))


func _style_texture_button(b: Button, piece: String, margins: Vector4, k: float) -> void:
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for state in ["normal", "hover", "pressed", "disabled"]:
		var sb := slice(ART % piece, k, margins)
		if state == "hover":
			sb.modulate_color = Color(1.06, 1.05, 1.0)
		elif state == "pressed":
			sb.modulate_color = Color(0.9, 0.87, 0.8)
		b.add_theme_stylebox_override(state, sb)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


# ---------- 小工具 ----------

func _label(text: String, size: int, serif: bool, weight: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font(serif, weight))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", INK)
	l.add_theme_constant_override("outline_size", 0)
	l.add_theme_constant_override("shadow_outline_size", 0)
	l.add_theme_color_override("font_shadow_color", Color.TRANSPARENT)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _icon(tex: Texture2D, side: float) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.custom_minimum_size = Vector2(side, side)
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _t(zh: String, en: String) -> String:
	return en if UnitDetailFormat.is_en() else zh
