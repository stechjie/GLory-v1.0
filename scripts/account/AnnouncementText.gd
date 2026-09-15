extends RefCounted

# 公告文案的纯函数（docs/公告系统设计.md）：挑语言、正文 BBCode 白名单、时间显示、跳转白名单。
# 全部 static，公告界面、登录弹窗、顶部横条、门禁共用一份 —— 同一条规则写两遍迟早分叉。
#
# 不用 class_name：同 AccountConfig.gd 顶部那条（新全局类没重建缓存就打包，服务器会在解析阶段挂）。

# 正文里放行的标签。其它方括号一律转义成文字显示：
#   [img]                按路径加载游戏包里的任意资源
#   [url=任意地址]       能跳任意外链 —— 哪天有后台权限的账号被盗，就是给全服发钓鱼链接
#   [font_size] [table]  能把版面撑坏
const ALLOWED_TAGS := ["b", "i", "u", "color", "url"]

# 正文链接只许跳这些游戏内页面：[url=glory://prep]去备战[/url]。
# 与 Main._on_announcement_navigate 一一对应（tools/announcement_check 钉着）。
const LINK_SCHEME := "glory://"
const ROUTES := ["prep", "codex", "friends", "profile"]

const MONTHS_EN := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

# 一个标签最多往后看多远。白名单里最长的是 [url=glory://friends] 与 [color=#RRGGBB]。
const TAG_SCAN_CHARS := 64


# 英文没写就用中文，中文没写就用英文 —— 玩家永远不会看到空白。
static func pick_text(item: Dictionary, field: String, english: bool) -> String:
	var zh := str(item.get(field + "_zh", "")).strip_edges()
	var en := str(item.get(field + "_en", "")).strip_edges()
	if english and not en.is_empty():
		return en
	return en if zh.is_empty() else zh


static func kind_label(kind: String, english: bool) -> String:
	match kind:
		"event":
			return "Event" if english else "活动"
		"update":
			return "Update" if english else "更新"
		"urgent":
			return "Urgent" if english else "紧急"
		_:
			return "Notice" if english else "系统"


# 列表里一行的文字。按钮不解析 BBCode，方括号原样显示。
static func row_text(item: Dictionary, english: bool) -> String:
	var kind := kind_label(str(item.get("kind", "")), english)
	var tag := ("[%s] " % kind) if english else ("【%s】" % kind)
	var prefix := ""
	# 先判类型再取值：Godot 4 里 "true" == true 不是 false，是运行时报错。
	var preview: Variant = item.get("preview", false)
	if preview is bool and preview:
		prefix = "(Preview) " if english else "（预览）"
	return prefix + tag + pick_text(item, "title", english)


# 管理员写的正文 -> 可以直接交给 RichTextLabel 的 BBCode。白名单外的方括号转义成 [lb]。
static func sanitize_bbcode(text: String) -> String:
	var tag_re := RegEx.create_from_string("^\\[(/?)([a-z]+)(=[^\\[\\]]*)?\\]")
	var parts := PackedStringArray()
	var plain_start := 0
	var i := 0
	var n := text.length()
	while i < n:
		if text[i] != "[":
			i += 1
			continue
		parts.append(text.substr(plain_start, i - plain_start))
		var m := tag_re.search(text.substr(i, TAG_SCAN_CHARS))
		if m != null and _tag_allowed(m.get_string(1) == "/", m.get_string(2), m.get_string(3)):
			parts.append(m.get_string(0))
			i += m.get_string(0).length()
		else:
			parts.append("[lb]")
			i += 1
		plain_start = i
	parts.append(text.substr(plain_start))
	return "".join(parts)


# value 带着前面的「=」，没有值时是空串。
static func _tag_allowed(closing: bool, tag: String, value: String) -> bool:
	if not (tag in ALLOWED_TAGS):
		return false
	if closing:
		return value.is_empty()
	match tag:
		"color":
			return RegEx.create_from_string("^=#[0-9A-Fa-f]{6}$").search(value) != null
		"url":
			return value.begins_with("=") and not link_route(value.substr(1)).is_empty()
		_:
			return value.is_empty()


# 弹窗里只放两三行预览，不解析 BBCode：去掉白名单标签，别的方括号原样留着。
static func plain_text(text: String) -> String:
	var tag_re := RegEx.create_from_string("\\[/?(b|i|u|color|url)(=[^\\[\\]]*)?\\]")
	return tag_re.sub(text, "", true).strip_edges()


# glory://prep -> "prep"。不在白名单里返回空串。
static func link_route(target: String) -> String:
	if not target.begins_with(LINK_SCHEME):
		return ""
	var route := target.substr(LINK_SCHEME.length())
	return route if route in ROUTES else ""


# 服务器给的是 Unix 秒（UTC）。按手机的时区显示 —— 显示用手机时区没问题，
# 「该不该显示」是服务器按服务器的钟判的，与这里无关。
# bias_minutes：Time.get_time_zone_from_system() 的 bias（UTC+8 是 480）。
static func time_text(starts_at: int, ends_at: Variant, bias_minutes: int, english: bool) -> String:
	var start := clock_text(starts_at, bias_minutes, english)
	if not (ends_at is int or ends_at is float) or int(ends_at) <= 0:
		return ("Posted " + start) if english else (start + " 发布")
	return "%s – %s" % [start, clock_text(int(ends_at), bias_minutes, english)]


static func clock_text(unix: int, bias_minutes: int, english: bool) -> String:
	var d := Time.get_datetime_dict_from_unix_time(unix + bias_minutes * 60)
	var month := int(d["month"])
	if english:
		return "%s %d %02d:%02d" % [MONTHS_EN[month - 1], int(d["day"]), int(d["hour"]), int(d["minute"])]
	return "%d月%d日 %02d:%02d" % [month, int(d["day"]), int(d["hour"]), int(d["minute"])]
