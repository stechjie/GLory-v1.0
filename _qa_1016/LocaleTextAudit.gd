extends RefCounted
# 英文界面「中文巡检」——扫任意 Control 子树上的**可见文本**，报出仍含汉字的地方。
#
# 【为什么要它】10.16 第 2 条修的七处漏点，是同一个坑的第三次复发（prep_1008 的
#   `bug1_no_bare_chinese_literals` 只抓**中文字面量**，抓不到：
#     ① `str(def.get("name", ...))` 直读数据表中文字段（变量不是字面量）；
#     ② 把**贴图名**当显示名（treasure_logos/ 下本是中文文件名）。
#   这一层不检查「代码怎么写」，只检查**最终画面上有没有汉字** —— 所以新增任何
#   显示路径都逃不掉，无论它是走 helper、直读 name，还是把名字塞错了参数。
#
# 【★ 关键：中文不一定都是 bug】玩家自己产生的内容本来就该原样显示：
#   昵称、聊天正文、邮件/举报理由、好友备注、搜索框里手打的字……
#   判据分三道（顺序即优先级）：
#     ① 控件类型：LineEdit / TextEdit / CodeEdit 的 `text` 是玩家输入，**不扫**
#        （它们自己写的 placeholder / tooltip 照扫 —— 那是开发写的文案）。
#     ② 节点路径：路径里命中 PLAYER_TEXT_PATTERNS（chat/message/friend/mail/…）
#        的控件整条豁免。
#     ③ 内容剔除：把调用方给的 `player_strings`（当前账号昵称、聊天原文、好友名…）
#        从文本里**挖掉**，再看剩下的还有没有汉字。这条最要紧 ——
#        它让「`Shell Guard（甲壳守卫）` 里嵌了玩家昵称」这类行不会误报，
#        同时「同一行里另外有个漏掉的中文名」仍然会被抓出来。
#
# 用法：
#   const LocaleTextAudit := preload("res://_qa_1016/LocaleTextAudit.gd")
#   var hits := LocaleTextAudit.audit(get_tree().root, ["某个玩家昵称"])
#   # hits: [{"path": "...", "kind": "label", "text": "...", "visible": true}]

# CJK 汉字区间（只认汉字，不认全角标点 —— `：` `，` 是 Fullwidth Forms，不该报）。
const CJK_RANGES := [
	[0x4E00, 0x9FFF],   # CJK 统一表意文字
	[0x3400, 0x4DBF],   # 扩展 A
	[0xF900, 0xFAFF],   # 兼容表意文字
	[0x20000, 0x2A6DF], # 扩展 B（罕用，留着防漏）
]

# 承载「玩家自由文本」的节点/路径关键词（大小写不敏感的子串）。
# 每加一条都要能说出理由：这些都是玩家自己输入/服务端回传的原文。
const PLAYER_TEXT_PATTERNS := [
	"chat",          # 聊天频道正文
	"message", "msg",# 私聊 / 系统消息正文
	"nickname", "nick", "player_name", "playername", "display_name",  # 昵称
	"friend",        # 好友列表与备注
	"mail", "letter",# 邮件正文
	"report", "feedback",  # 举报 / 反馈理由
	"remark",        # 备注
	"input", "edit", "search",  # 输入框（玩家手打）
	"announce",      # 公告正文（运营写的中文也可能进英文环境，但那是内容不是 UI 文案）
]

# 编辑类控件的 `text` 是玩家输入 —— 不扫；它们的 placeholder / tooltip 照扫。
const EDITABLE_TYPES := ["LineEdit", "TextEdit", "CodeEdit"]


static func has_cjk(text: String) -> bool:
	for i in text.length():
		if _is_cjk(text.unicode_at(i)):
			return true
	return false


static func _is_cjk(code: int) -> bool:
	for r in CJK_RANGES:
		if code >= int(r[0]) and code <= int(r[1]):
			return true
	return false


# 路径命中玩家文本关键词 ⇒ 整条豁免。
static func is_player_text_path(path: String) -> bool:
	var low := path.to_lower()
	for pattern in PLAYER_TEXT_PATTERNS:
		if low.contains(pattern):
			return true
	return false


# 把已知的玩家文本挖掉，再看剩下有没有汉字。
static func residual_has_cjk(text: String, player_strings: Array) -> bool:
	var residual := text
	for raw in player_strings:
		var sample := str(raw).strip_edges()
		if not sample.is_empty():
			residual = residual.replace(sample, "")
	return has_cjk(residual)


# 扫一棵子树。`player_strings` 由调用方提供（昵称、聊天原文……），可留空。
static func audit(root: Node, player_strings: Array = []) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	_walk(root, out, player_strings, "")
	return out


static func _walk(node: Node, out: Array[Dictionary], player_strings: Array, path: String) -> void:
	if node == null:
		return
	var here := path + "/" + String(node.name)
	var visible := false
	if node is CanvasItem:
		visible = (node as CanvasItem).is_visible_in_tree()
	for probe in _text_probes(node):
		var text := str(probe["text"])
		if text.is_empty() or not has_cjk(text):
			continue
		if is_player_text_path(here):
			continue
		if not residual_has_cjk(text, player_strings):
			continue
		out.append({
			"path": here,
			"kind": str(probe["kind"]),
			"text": text,
			"visible": visible,
		})
	for child in node.get_children():
		_walk(child, out, player_strings, here)


# 一个节点上所有「开发者写的、本该随语言切换」的文本。
# 编辑类控件只取 placeholder / tooltip，不取 text。
static func _text_probes(node: Node) -> Array[Dictionary]:
	var probes: Array[Dictionary] = []
	var editable := false
	for t in EDITABLE_TYPES:
		if node.is_class(t):
			editable = true
			break
	if node is Label:
		probes.append({"kind": "label", "text": (node as Label).text})
	elif node is RichTextLabel:
		probes.append({"kind": "rich", "text": (node as RichTextLabel).text})
	elif node is BaseButton:
		probes.append({"kind": "button", "text": (node as BaseButton).text})
		if not editable:
			probes.append({"kind": "button_tooltip", "text": (node as BaseButton).tooltip_text})
	if node is LineEdit:
		probes.append({"kind": "placeholder", "text": (node as LineEdit).placeholder_text})
	elif node is TextEdit:
		probes.append({"kind": "placeholder", "text": (node as TextEdit).placeholder_text})
	if node is Control and not (node is BaseButton):
		probes.append({"kind": "tooltip", "text": (node as Control).tooltip_text})
	if node is PopupMenu:
		var menu := node as PopupMenu
		for i in menu.item_count:
			probes.append({"kind": "menu_item", "text": menu.get_item_text(i)})
	if node is TabBar:
		var bar := node as TabBar
		for i in bar.tab_count:
			probes.append({"kind": "tab", "text": bar.get_tab_title(i)})
	if node is TabContainer:
		var tabs := node as TabContainer
		for i in tabs.get_tab_count():
			probes.append({"kind": "tab", "text": tabs.get_tab_title(i)})
	# 窗口标题栏**不算**游戏内文案：主窗口标题就是 ProjectSettings 的 config/name
	# （两棵树靠它隔离：测试服 / Glory Beta 0.04），扫它只会天天误报。
	# 子窗口（AcceptDialog 等）的标题才是开发写的 UI 文案，照扫。
	if node is Window and not editable and node.get_parent() != null:
		probes.append({"kind": "window_title", "text": (node as Window).title})
	return probes


# 报告成一行行可读文本（门禁与实时巡检共用一个格式）。
static func format_hits(hits: Array) -> String:
	var lines: Array[String] = []
	for h in hits:
		lines.append("%s [%s]%s %s" % [
			str(h.get("path", "?")),
			str(h.get("kind", "?")),
			"" if bool(h.get("visible", true)) else " (hidden)",
			str(h.get("text", "")).replace("\n", "\\n"),
		])
	return "\n".join(lines)
