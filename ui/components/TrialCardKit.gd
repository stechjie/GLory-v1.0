extends RefCounted

# 体验卡的图、名字、卡框颜色、剩余时间 —— 背包、购买弹窗、出售弹窗、到期提醒共用这一份
# （规则在 backend/app/trial.py，接口在 AccountManager 的「体验卡」一节）。
#
# 图案沿用各自的（2026-11-20 用户定）：种族 = 种族 logo，宠物 = 宠物形象，棋盘皮肤 = 那张皮肤自己的卷轴
# （shop_button.png，商城祈愿横幅上浮着的就是它）。同一目标的 1/3/7 天卡是同一张图，
# 所以靠卡框颜色（1 天铜、3 天银、7 天金）和右上角的天数角标区分。
#
# 只在界面里用：战斗服务器不加载这个文件，可以 load 贴图。

const Kit := preload("res://ui/theme/ParchmentKit.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const PetPreview := preload("res://scripts/pets/PetPreview.gd")
const PrepSkin := preload("res://scenes/prep/PrepSkin.gd")

const RACE_LOGO_PATH := "res://assets/ui/race_logos/%s.png"
const DAYS := [1, 3, 7]
# 与服务器 trial.PRICE / SELL_PRICE 一致（只用来显示；扣多少、给多少以服务器回执为准）。
const PRICE := {1: 100, 3: 200, 7: 300}
const DAY_TINT := {
	1: Color(0.93, 0.76, 0.60),   # 铜
	3: Color(0.86, 0.89, 0.93),   # 银
	7: Color(1.0, 0.86, 0.50),    # 金
}
const DAY_BADGE := {
	1: Color("9a5b2c"),
	3: Color("5f6b78"),
	7: Color("a8740f"),
}


static func english() -> bool:
	return TranslationServer.get_locale().begins_with("en")


static func t(zh: String, en: String) -> String:
	return en if english() else zh


static func kind_name(kind: String) -> String:
	match kind:
		"race":
			return t("种族", "Race")
		"pet":
			return t("宠物", "Pet")
		"prep_skin":
			return t("棋盘皮肤", "Board skin")
	return ""


static func target_name(kind: String, target: String) -> String:
	match kind:
		"race":
			var race_name: String = UnitDetailFormat.unit_race_name(target)
			return race_name if english() else "%s族" % race_name
		"pet":
			return PetService.display_name(target)
		"prep_skin":
			return PrepSkin.display_name(target)
	return target


static func days_text(days: int) -> String:
	return t("%d天" % days, "%dd" % days)


# 「暗族 · 3天体验卡」
static func card_title(kind: String, target: String, days: int) -> String:
	return t("%s · %d天体验卡", "%s · %d-day trial") % [target_name(kind, target), days]


# 卡面图。pet 是现画的立绘控件；种族 / 皮肤是贴图。拿不到图返回一个空控件（不报错）。
static func icon(kind: String, target: String, box: Vector2) -> Control:
	if kind == "pet":
		var art := PetPreview.build_illustration(target, box, false)
		_ignore_mouse(art)
		return art
	var path := ""
	if kind == "race":
		path = RACE_LOGO_PATH % target
	elif kind == "prep_skin":
		path = PrepSkin.path_for(target, "shop_button")
	var rect := TextureRect.new()
	rect.custom_minimum_size = box
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not path.is_empty() and ResourceLoader.exists(path):
		rect.texture = load(path) as Texture2D
	return rect


# 一张卡的格子：卡框按天数染色，右上角天数角标，右下角数量（>1 才显示）。
# card = 背包接口里的一项 {target, kind, days, count, owned}。
static func tile(card: Dictionary, size: Vector2) -> PanelContainer:
	var days := int(card.get("days", 1))
	var panel := PanelContainer.new()
	panel.custom_minimum_size = size
	panel.add_theme_stylebox_override("panel",
		Kit.box("slot", Vector4(10, 10, 10, 10), DAY_TINT.get(days, Color.WHITE)))
	var stage := Control.new()
	stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(stage)
	var art := icon(str(card.get("kind", "")), str(card.get("target", "")), size * 0.66)
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	art.offset_left = size.x * 0.08
	art.offset_right = -size.x * 0.08
	art.offset_top = size.y * 0.10
	art.offset_bottom = -size.y * 0.14
	stage.add_child(art)
	if bool(card.get("owned", false)):
		art.modulate = Color(0.55, 0.55, 0.55)
	stage.add_child(_corner_badge(days_text(days), DAY_BADGE.get(days, Kit.INK), true))
	var count := int(card.get("count", 1))
	if count > 1:
		stage.add_child(_corner_badge("×%d" % count, Kit.INK, false))
	return panel


static func _corner_badge(text: String, color: Color, top: bool) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", Color.WHITE if top else Kit.INK)
	label.add_theme_color_override("font_outline_color", color if top else Kit.INK_OUTLINE)
	label.add_theme_constant_override("outline_size", 6 if top else 4)
	label.set_anchors_preset(Control.PRESET_TOP_RIGHT if top else Control.PRESET_BOTTOM_RIGHT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	label.grow_vertical = Control.GROW_DIRECTION_END if top else Control.GROW_DIRECTION_BEGIN
	label.offset_right = -2
	label.offset_top = 0 if top else -22
	label.offset_bottom = 22 if top else 0
	return label


static func _ignore_mouse(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore_mouse(child)


# --- 时间 ---------------------------------------------------------------------

# 服务器的 ISO 时间（UTC，可能带小数秒和 Z）-> unix 秒。读不出来返回 0。
static func unix_of(iso: String) -> float:
	if iso.length() < 19:
		return 0.0
	return float(Time.get_unix_time_from_datetime_string(iso.substr(0, 19)))


# 服务器时间 - 本机时间。倒计时用它校正本机时钟（改了系统时间也不会显示错）。
static func clock_offset(server_now_iso: String) -> float:
	var server := unix_of(server_now_iso)
	return 0.0 if server <= 0.0 else server - Time.get_unix_time_from_system()


# 「剩 2天5小时」/「剩 3小时12分」/「即将到期」
static func time_left(expires_iso: String, offset := 0.0) -> String:
	var left := int(unix_of(expires_iso) - (Time.get_unix_time_from_system() + offset))
	if left <= 60:
		return t("即将到期", "Ending soon")
	var days := left / 86400
	var hours := (left % 86400) / 3600
	var minutes := (left % 3600) / 60
	if days > 0:
		return t("剩 %d天%d小时" % [days, hours], "%dd %dh left" % [days, hours])
	if hours > 0:
		return t("剩 %d小时%d分" % [hours, minutes], "%dh %dm left" % [hours, minutes])
	return t("剩 %d分钟" % minutes, "%dm left" % minutes)


# 背包接口 / 归属接口里的 trials -> {target: expires_iso}。两种形状都认：
#   归属接口：{"dark": "2026-…Z"}；背包接口：[{target, kind, expires_at}]。
static func trial_map(raw: Variant) -> Dictionary:
	var out := {}
	if raw is Dictionary:
		for key in raw:
			out[str(key)] = str(raw[key])
	elif raw is Array:
		for item in raw:
			if item is Dictionary:
				out[str(item.get("target", ""))] = str(item.get("expires_at", ""))
	return out
