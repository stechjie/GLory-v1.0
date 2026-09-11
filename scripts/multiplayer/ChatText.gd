extends RefCounted

# 房间 / 局内自由文字的校验与规范化（`docs/聊天系统设计.md` 批次 D）。
#
# **客户端和战斗服务器（③）用的是同一份代码**：客户端发之前先过一遍（给玩家即时的
# 原因），③ 转发之前再过一遍（权威）。改包的客户端只能绕过前一道。
#
# 规则照私聊那一套（`backend/app/text_guard.py` 的 `clean_chat_message`），只做结构层：
#   零宽 / 不可见字符、双向覆写、Zalgo（连续组合符）、控制字符 —— 防显示破坏，与内容无关
#   换行与制表压成空格、ZWJ 去掉（组合 emoji 退化成几个单独的 emoji，意思还在）
#   连续空白压成一个、去首尾空白、长度上限
#
# **不做内容审核。** 2026-09-11 已定：外部审核（阿里云）先不接；房间 / 局内按设计文档
# 第四节是 fail-open（审核不可用时放行）。以后接上审核，插在 ③ 转发之前那一行，
# 调用点不变。
#
# ⚠️ 与 Python 版的差别：GDScript 没有 unicodedata 的「字符类别」，这里按码位区间挡
# 最常见的几类（C0 / C1 控制符、零宽、双向覆写、组合符堆叠）。Unicode 的 Cf / Cn 类别
# 没法逐一覆盖 —— 这是结构层，漏一个的后果是显示怪，不是安全问题。
#
# 不用 `class_name`：理由同 ChatPhrases.gd（打包服务器时的全局类缓存问题）。

# 单条上限。**比私聊（200）短得多，是刻意的**：大厅聊天框只有 4 行（430×210），
# 局内是飘在棋盘右下角的 3 条消息。40 字加上昵称大约两行 —— 更长的话属于私聊。
const MAX_CHARS := 40

# 进校验之前的原始长度上限。来路是网络，任何没有上界的东西都会被人拿去打内存 ——
# 同 NetProtocol.gd 顶部那条「任何容器都必须在常数级步数内被拒」。
# 给规范化留余量（空白会被压缩），但不给一个几 MB 的串逐字符扫描的机会。
const MAX_RAW_CHARS := MAX_CHARS * 4

const _ZWJ := 0x200D


# 规范化后的文本；不合法返回空串（原因用 problem() 取）。
static func clean(raw: String) -> String:
	return str(_run(raw).get("text", ""))


# 不合法的原因（给玩家看的一句话）；合法返回空串。
static func problem(raw: String) -> String:
	return str(_run(raw).get("problem", ""))


static func _run(raw: String) -> Dictionary:
	# 先判原始长度，再逐字符扫 —— 反过来的话，一个几 MB 的串会先被完整扫一遍。
	if raw.length() > MAX_RAW_CHARS:
		return {"problem": "消息最多 %d 个字" % MAX_CHARS}
	var out := ""
	var pending_space := false
	var combining_run := 0
	for i in raw.length():
		var code := raw.unicode_at(i)
		if _is_space(code):
			pending_space = true
			combining_run = 0
			continue
		if code == _ZWJ:
			# 组合 emoji 的胶水：去掉，「一家三口」退化成三个单独的人。
			continue
		if _is_invisible(code):
			return {"problem": "不能包含不可见字符"}
		if _is_bidi(code):
			return {"problem": "不能包含改变文字方向的控制符"}
		if _is_control(code):
			return {"problem": "不能包含控制字符"}
		if _is_combining(code):
			combining_run += 1
			if combining_run >= 3:
				return {"problem": "不能包含连续的组合符号"}
		else:
			combining_run = 0
		if pending_space and not out.is_empty():
			out += " "
		pending_space = false
		out += char(code)
	if out.is_empty():
		return {"problem": "消息不能为空"}
	if out.length() > MAX_CHARS:
		return {"problem": "消息最多 %d 个字" % MAX_CHARS}
	return {"text": out}


# 换行、制表、回车与各种「看着像空格」的字符都当空格：粘贴多行文字是常事，
# 整条拒掉只会让玩家对着「不能包含控制字符」发呆。
static func _is_space(code: int) -> bool:
	return code == 0x20 or code == 0x09 or code == 0x0A or code == 0x0D \
		or code == 0x00A0 or code == 0x1680 or (code >= 0x2000 and code <= 0x200A) \
		or code == 0x202F or code == 0x205F or code == 0x3000


# 零宽与不可见字符（ZWJ 已在前面单独处理）。与 text_guard._INVISIBLE 同一组码位。
# 它们能让一句话看起来和别人的一模一样，也能把一条「空消息」塞进聊天框。
static func _is_invisible(code: int) -> bool:
	return (code >= 0x200B and code <= 0x200F) or (code >= 0x2060 and code <= 0x2064) \
		or code == 0xFEFF or code == 0x00AD or code == 0x180E


# 双向覆写。能让 "gnitaehc" 显示成 "cheating"，也能让一行字盖到隔壁那行。
static func _is_bidi(code: int) -> bool:
	return (code >= 0x202A and code <= 0x202E) or (code >= 0x2066 and code <= 0x2069)


# C0 / C1 控制符（空白类已经在 _is_space 里先处理掉了）。
static func _is_control(code: int) -> bool:
	return code < 0x20 or (code >= 0x7F and code <= 0x9F)


# 组合用变音符号。正常文字最多叠两个（例如越南语），三个以上是在糊屏幕。
static func _is_combining(code: int) -> bool:
	return (code >= 0x0300 and code <= 0x036F) or (code >= 0x1AB0 and code <= 0x1AFF) \
		or (code >= 0x20D0 and code <= 0x20F0)
