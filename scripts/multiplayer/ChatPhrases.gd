extends RefCounted

# 房间 / 局内快捷短语表（`docs/聊天系统设计.md` 批次 A）。
#
# **网络上只传 phrase_id 这个整数，永远不传文本。** 这是批次 A 便宜的全部原因：
#
#   - 内容审核归零 —— 这张表自己审一次，管终身
#   - 不碰 `docs/账号系统RFC.md` 第六节 🔴 第 3 条 —— 载荷里只有座位号和一个 int
#   - 载荷上界天然存在 —— 符合 `NetProtocol.gd` 顶部那条「任何容器都必须在常数级
#     步数内被拒」
#
# 不用 `class_name`：`make_server_zip.ps1` 会把 `.godot/global_script_class_cache.cfg`
# 一起打包，新增的全局类如果没先重建缓存就打包，服务器会在解析阶段直接挂
# （见 `docs/CHECKS.md`）。用 `preload` 就没有这个问题 —— 同 `RateLimitService.gd`。

# --- 🔴 改这张表之前必须读完这一段 -------------------------------------------
#
# **id 一旦发布就不能重排、不能复用、不能改含义。**
#
# 客户端发的是 id。旧客户端发 7 号、新表的 7 号换成了另一句话，收到的人看到的
# 就是另一句 —— **不报错、不崩溃，只是说错话**，而且只在版本混用时出现。
# 这与 `NetProtocol.SNAPSHOT_VERSION` 那条教训同源（「同一个 key 换了含义就静默算错」）。
#
# 所以：
#   - 加新句子：**只在末尾追加新 id**
#   - 删句子：**把那个 id 从表里删掉就行，后面的绝不往前挪**（id 会出现空洞，这是对的）
#   - 改错别字：可以，那不改变含义
#
# --- 选词原则（同样重要）-----------------------------------------------------
#
# **全部中性或正面，宁可少几句。**
#
# 快捷短语真正的滥用方式是**反讽** —— 靠时机，不靠文本。「打得真好啊」在队友
# 送掉一局之后连发五次，文本本身挑不出毛病，举报时也无法判定。
# 能减少的办法只有一个：不收录那些**除了阴阳怪气没别的用途**的句子。
# 「厉害了」「真棒啊」「就这？」一律不进表。
#
# 完全杜绝做不到（「打得好！」照样能用来嘲讽），但那已经是最低成本的那一档。

const PHRASES := {
	# --- 问候 ---
	1: {"zh": "你好！", "en": "Hi!", "group": "greet"},
	2: {"zh": "一起加油！", "en": "Let's go!", "group": "greet"},
	3: {"zh": "谢谢！", "en": "Thanks!", "group": "greet"},
	4: {"zh": "打得好！", "en": "Nice one!", "group": "greet"},
	# --- 状态 ---
	5: {"zh": "我准备好了", "en": "I'm ready", "group": "status"},
	6: {"zh": "稍等一下", "en": "One moment", "group": "status"},
	7: {"zh": "我这边有点难", "en": "Struggling here", "group": "status"},
	8: {"zh": "交给我", "en": "I've got this", "group": "status"},
	# --- 收尾 ---
	9: {"zh": "可惜", "en": "So close", "group": "closing"},
	10: {"zh": "稳住", "en": "Stay steady", "group": "closing"},
	11: {"zh": "抱歉", "en": "Sorry", "group": "closing"},
	12: {"zh": "再来一局？", "en": "One more?", "group": "closing"},
}

# 分组顺序 = UI 上的显示顺序。表里的 id 顺序不保证与它一致，所以显式写出来。
const GROUP_ORDER := ["greet", "status", "closing"]

const GROUP_TITLES := {
	"greet": {"zh": "问候", "en": "Greet"},
	"status": {"zh": "状态", "en": "Status"},
	"closing": {"zh": "收尾", "en": "Closing"},
}


static func is_valid_id(phrase_id: int) -> bool:
	"""协议层唯一的合法性判据。

	服务端与客户端**都要调它** —— 服务端调是因为来路是网络，
	客户端调是因为收到的广播同样来自网络（专服会转发，但转发的是它校验过的 id；
	本地房主模式下那一跳的校验就是这里）。
	"""
	return PHRASES.has(phrase_id)


static func text(phrase_id: int) -> String:
	"""按当前语言取文本。**id 不合法时返回空串，不返回占位符。**

	返回「未知短语」这类占位符会让一个协议错误在界面上变成一条看似正常的消息，
	于是没人会去查。空串让调用方必须显式处理，而调用方一律是「不显示」。
	"""
	if not PHRASES.has(phrase_id):
		return ""
	var entry: Dictionary = PHRASES[phrase_id]
	return str(entry.get("en" if _is_en() else "zh", ""))


static func group_title(group: String) -> String:
	if not GROUP_TITLES.has(group):
		return ""
	var entry: Dictionary = GROUP_TITLES[group]
	return str(entry.get("en" if _is_en() else "zh", ""))


static func ids_in_group(group: String) -> Array:
	"""该组的 id，按 id 升序 —— 顺序必须稳定，否则每次打开面板按钮会跳位。"""
	var out: Array = []
	for phrase_id in PHRASES.keys():
		if str((PHRASES[phrase_id] as Dictionary).get("group", "")) == group:
			out.append(int(phrase_id))
	out.sort()
	return out


static func _is_en() -> bool:
	return TranslationServer.get_locale().begins_with("en")
