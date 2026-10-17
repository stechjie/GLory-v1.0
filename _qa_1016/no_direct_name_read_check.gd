extends Node
# ============================================================================
# 源码门禁：**不许直读数据表的 `name` 当显示名**（10.16 之后的防复发基建）
#
# 【为什么单独立一条】既有 `tools/prep_1008_check.gd` 的 `bug1_no_bare_chinese_literals`
#   只抓**中文字面量**；「直读 `name` 字段」是变量，扫描器看不见 —— 同一个坑因此
#   复发三次（10.08c 三处 → 10.16 七处）。这条专门盯它。
#
# 【判据】
#   一行同时满足以下才算 offender：
#     (1) 出现 `get("name"` 或 `["name"]`
#     (2) 不含任何「已经考虑过语言」的线索 —— 见 SAFE_PATTERN：
#           本地化包装 `tr(` / `_t(`、双语字段 `name_en` / `name_cn`、取法
#           `is_en(` / `localized_name` / `unit_name` / `display_name`、
#           贴图名 `.png` / `portrait` / `tname` / `catalog` / `ICON` / `LOGO` / `_DIR`、
#           玩家名 `player` / `seat` / `message` / `who` / `actor` / `sender` /
#           `account` / `nickname` / `owner` / `member`、
#           反射与节点查找 `property_info` / `method.get` / `method_` / `signal` / `parts[`、
#           日志与回放 `state.log` / `log_` / `roster` / `BattleSim` / `replay`
#     (3) 不是「写字段」形态 `"name": str(...)`（数据组装，另有 name_en 字段）
#     (4) 不是纯比较/排序（该行不含 `text` 而有 `<` `>` `==` `!=`）
#
#   ★★ SAFE_PATTERN 必须带**词边界**：`tr(` 是 `str(` 的子串 —— 写成裸子串会把
#      所有含 `str(` 的行都豁免掉，实测 offender 会从 17 条假降到 1 条（假绿）。
#      同理别用 `art` / `id` / `key` 这种短词。
#
# 【三段】
#   ① 判据自检：正样本（必须报）+ 反样本（必须放行）。**这一段是防止有人为了过门禁
#      把 SAFE 放宽** —— 规则一宽，自检立刻红。
#   ② 全量扫描：粗筛后的 offender 必须都在 ALLOW（合法直读，永久）或
#      KNOWN_DEBT（已知真漏点，带到期日）里。
#   ③ 防腐烂：ALLOW / KNOWN_DEBT 的每条都必须仍在源码里能找到，
#      否则报 stale（问题修好了就该把条目删掉）。
#
# 【跑法】
#   Godot_v4.7.2-stable_win64_console.exe --headless --path <工程根> \
#       _qa_1016/no_direct_name_read_check.tscn

const CheckHarness := preload("res://_qa_1016/CheckHarness.gd")

const CHECK_NAME := "no_direct_name_read"
const ROOTS := ["res://scenes", "res://ui", "res://scripts"]
const SKIP_DIRS := ["_qa_1016", "_qa_godpulse", "_qa_t3unique", "work", "addons", "backend", "tools", "debug"]
const MIN_FILES := 200

const READ_PATTERN := "get\\(\\s*\"name\"\\s*[,)]|\\[\\s*\"name\"\\s*\\]"
const WRITE_PATTERN := "\"name\"\\s*:\\s*str\\("
const CMP_PATTERN := "[<>]=?|==|!="
const SAFE_PATTERN := "(?<![A-Za-z0-9_])(?:tr|_t)\\(|name_en|name_cn|is_en\\(|localized_name|unit_name|display_name|\\.png|portrait|tname|catalog|ICON|LOGO|_DIR|player|seat|message|who|actor|sender|account|nickname|owner|member|property_info|method\\.get|method_|signal|parts\\[|state\\.log|log_|roster|BattleSim|replay"

# 合法直读：每一条都经人工确认，`why` 就是它的理由。
# 加条目之前先问：这里读的是**给玩家看的名字**吗？是 ⇒ 不是合法直读，去改代码。
const ALLOW := [
	{"file": "scenes/battle/BattleRenderer.gd", "contains": "str(f.get(\"name\", str(f.get(\"id\", \"?\"))))",
		"why": "_fighter_display_name 的**兜底**分支：上面已 canonical→unit_display_name→name_en"},
	{"file": "scenes/menu/CodexScreen.gd", "contains": "return str(entry.get(\"name\", \"\"))",
		"why": "_entry_name / _entry_sub_name 的兜底：前面先 name_key→tr(key)、再 name_en"},
	{"file": "scenes/menu/FinalSettlementPanel.gd", "contains": "var name := str(d.get(\"name\", \"\"))",
		"why": "按 key 匹配图鉴条目（比较用），不是显示"},
	{"file": "scenes/menu/FinalSettlementPanel.gd", "contains": "return str(entry.get(\"name\", \"\"))",
		"why": "_ally_display_name 的兜底：前面已 DataRegistry.unit_display_name"},
	{"file": "scenes/menu/FinalSettlementPanel.gd", "contains": "var name := str(entry.get(\"name\", \"\"))",
		"why": "_codex_name 的兜底：前面已按 _english() 取 name_en"},
	{"file": "scenes/menu/ShopScreen.gd", "contains": "str(item.get(key, item.get(\"name\", item.get(\"id\", \"\"))))",
		"why": "_item_name：key 在英文档下就是 \"name_en\""},
	{"file": "scenes/prep/PrepSkin.gd", "contains": "return str(item.get(\"name\", skin_id))",
		"why": "中文分支（上一行的英文分支取 name_en）"},
	{"file": "scenes/prep/PrepUI.gd", "contains": "_add_owned_treasure_logo(tid_str, str(t.get(\"name\", tid_str)),",
		"why": "这是**贴图名**参数（treasure_logos/ 下就是中文文件名），不是给玩家看的名；显示名走第四参 tooltip"},
	{"file": "scenes/prep/panels/TreasureChoicePanel.gd", "contains": "str(entry.get(\"name\", \"\")), str(entry.get(\"effect\", \"\"))",
		"why": "中文分支（上一行的英文分支配对取 name_en/effect_en）"},
	{"file": "scripts/autoload/AnalyticsService.gd", "contains": "\"name\": event[\"name\"]",
		"why": "埋点事件的字段名，不进 UI"},
	{"file": "scripts/autoload/DataRegistry.gd", "contains": "return str(display.get(\"name\", str(definition.get(\"id\", \"?\"))))",
		"why": "unit_display_name 本体 —— 它就是那个按 locale 取名的唯一入口"},
	{"file": "scripts/battle/BattleSimShared.gd", "contains": "else str(d.get(\"name\", d.get(\"id\", \"Unit\")))",
		"why": "_english_name_from_def 的兜底：正常路已在上面派生英文名"},
	{"file": "scripts/multiplayer/RoomChatLog.gd", "contains": "str(entry.get(\"name\", \"\")), body",
		"why": "房间聊天的玩家名（玩家自由文本）"},
	{"file": "scripts/pets/PetService.gd", "contains": "return str(pet_by_id(pet_id).get(\"name\", pet_id))",
		"why": "display_name 的兜底：先走 TranslationServer.translate(pet_name_<id>)，5 只宠物中英都登记在 LocaleManager"},
]

# 已知的真漏点（该改代码，不是给豁免）。带到期日 —— 到期自动变红，防止「登记一次永远绿」。
const KNOWN_DEBT := [
	{"file": "scenes/prep/CarrotCampPanel.gd", "contains": "var name := str(d.get(\"name\", d.get(\"id\", \"?\")))",
		"expires": "2026-11-15", "why": "V1 死代码（无 .tscn 引用，PrepUI.gd:23 只 preload V3）"},
	{"file": "scenes/prep/CarrotCampPanel.gd", "contains": "str(merc.get(\"name\", merc.get(\"id\", \"\"))), int(merc.get(\"carrot_cost\", -1))",
		"expires": "2026-11-15", "why": "V1 死代码，同上"},
	{"file": "scenes/prep/CarrotCampPanelV2.gd", "contains": "str(unit_def.get(\"name\", unit_def.get(\"id\", \"棋子\")))",
		"expires": "2026-11-15", "why": "V2 死代码（同上）"},
]

var _h: CheckHarness
var _re_read: RegEx
var _re_safe: RegEx
var _re_write: RegEx
var _re_cmp: RegEx


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_re_read = RegEx.create_from_string(READ_PATTERN)
	_re_safe = RegEx.create_from_string(SAFE_PATTERN)
	_re_write = RegEx.create_from_string(WRITE_PATTERN)
	_re_cmp = RegEx.create_from_string(CMP_PATTERN)
	if _re_read == null or _re_safe == null:
		_h.fail("regex_compile_failed", "判据正则编译失败 —— 后面的扫描全不可信")
	else:
		_selftest_rules()
		_scan_all()
		_check_rot()
	LocaleManager.set_locale("zh")
	_h.finish(get_tree())


# ---- ① 判据自检 --------------------------------------------------------------

func _selftest_rules() -> void:
	# 正样本：这些都是**真漏点**的写法，判据必须咬住
	_h.expect(_is_offender("var t := str(def.get(\"name\", \"\"))"), "rule_miss_plain",
		"判据漏掉了最普通的直读 `var t := str(def.get(\"name\", \"\"))`")
	_h.expect(_is_offender("label.text = str(unit.get(\"name\"))"), "rule_miss_label",
		"判据漏掉了 Label 赋值形态")
	_h.expect(_is_offender("return \"%s\" % str(entry.get(\"name\", fallback))"), "rule_miss_format",
		"判据漏掉了格式化形态")
	_h.expect(_is_offender("button.text = \"%s\" % str(merc.get(\"name\", \"\"))"), "rule_miss_button_text",
		"判据漏掉了 Button.text 形态")
	# ★ 划清边界：本门禁只看 `get("name")` 直读。「把显示名塞进贴图名参数」那种错
	#   （10.16 返工那次）在这一层**看不见** —— 它由 locale_guard_check 的
	#   「贴图名 ↔ treasure_logos/ 文件一致」+ 调用点源码断言负责。
	_h.note("本门禁只覆盖 `get(\"name\")` 直读；贴图名参数塞显示名由 locale_guard_check 覆盖")
	# 反样本：这些是**合法**写法，判据不能报
	_h.expect(not _is_offender("var t := str(d.get(\"name_en\", \"\"))"), "rule_false_name_en",
		"判据误报了 name_en")
	_h.expect(not _is_offender("return str(entry.get(\"name\", \"\")) if is_en() else other"), "rule_false_is_en",
		"判据误报了带 is_en() 分支的写法")
	_h.expect(not _is_offender("state.log.append(\"x\" % str(u.get(\"name\", \"?\")))"), "rule_false_log",
		"判据误报了战斗日志（烘进回放，按 locale 取名会让回放依赖当时语言）")
	_h.expect(not _is_offender("var tname := str(t.get(\"name\", tid))"), "rule_false_art",
		"判据误报了贴图名（treasure_logos/ 下是中文文件名）")
	_h.expect(not _is_offender("return str(entry.get(\"name_en\", entry.get(\"name\", \"\")))"), "rule_false_bilingual_fallback",
		"判据误报了「英文优先、中文兜底」的写法")
	# 正样本（会落进 offender 面，靠 ALLOW 登记放行）：`key` 变量已经在外面按语言选过。
	# 判据看不见变量的值，所以这类只能靠白名单 —— 白名单里 ShopScreen 那条就是它。
	_h.expect(_is_offender("return str(item.get(key, item.get(\"name\", \"\")))"), "rule_miss_key_short_circuit",
		"判据没咬住「key 变量替语言」的写法（它不含 name_en 线索，本就会进 offender 面）")
	# ★ 词边界回归：`tr(` 不能把 `str(` 当自己人
	_h.expect(_is_offender("var s := str(thing.get(\"name\", \"\"))"), "rule_word_boundary_tr_vs_str",
		"SAFE_PATTERN 少了词边界：`tr(` 匹配到了 `str(` —— offender 会被整片吃掉（假绿）")
	_h.expect(not _is_offender("var s := tr(\"ui_key\") + str(x.get(\"name_en\", \"\"))"), "rule_word_boundary_false",
		"真 tr( 反而没被认出来")


# ---- ② 全量扫描 --------------------------------------------------------------

func _scan_all() -> void:
	var files: Array[String] = []
	for root in ROOTS:
		_scan_dir(root, files)
	_h.item(files.size())
	_h.expect(files.size() >= MIN_FILES, "scanned_too_few_files",
		"只扫到 %d 个 .gd（应 >= %d）—— 目录结构变了或扫描被静默跳过，后面的「没 offender」不可信"
		% [files.size(), MIN_FILES])

	var unlisted: Array[String] = []
	var debt_hits := 0
	for path in files:
		var rel := path.replace("res://", "")
		var src := FileAccess.get_file_as_string(path)
		var line_no := 0
		for line in src.split("\n"):
			line_no += 1
			var code := line
			var hash_at := code.find("#")
			if hash_at >= 0:
				code = code.substr(0, hash_at)
			if not _is_offender(code):
				continue
			var trimmed := line.strip_edges()
			if _matches(ALLOW, rel, trimmed):
				continue
			if _matches_debt(rel, trimmed):
				debt_hits += 1
				continue
			unlisted.append("%s:%d  %s" % [rel, line_no, trimmed])
	_h.expect(unlisted.is_empty(), "unlisted_direct_name_read",
		"%d 处直读 name 既不在合法清单也不在技术债里 —— 新增的显示名必须走 PrepWidgets.unit_name / localized_name：\n%s"
		% [unlisted.size(), "\n".join(unlisted.slice(0, 12))])
	_h.note("技术债命中 %d 条（都在 %s 到期）" % [debt_hits, "2026-11-15"])


# ---- ③ 防腐烂 ----------------------------------------------------------------

func _check_rot() -> void:
	var stale: Array[String] = []
	for entry in ALLOW:
		if _file_state(str(entry["file"]), str(entry["contains"])) == 2:
			stale.append("ALLOW %s | %s" % [str(entry["file"]), str(entry["contains"])])
	_h.expect(stale.is_empty(), "allow_entry_stale",
		"%d 条合法清单在源码里找不到了（问题已改掉就该删条目）：\n%s" % [stale.size(), "\n".join(stale)])

	var today := Time.get_date_string_from_system()
	var expired: Array[String] = []
	var debt_stale: Array[String] = []
	for entry in KNOWN_DEBT:
		if _file_state(str(entry["file"]), str(entry["contains"])) == 2:
			debt_stale.append(str(entry["contains"]))
		if str(entry["expires"]) < today:
			expired.append("%s（到期 %s）" % [str(entry["file"]), str(entry["expires"])])
	_h.expect(debt_stale.is_empty(), "debt_stale",
		"技术债条目所指的那一行在源码里变了（不是文件不存在，是真变了）—— 该把条目删掉或改写：%s" % ", ".join(debt_stale))
	_h.expect(expired.is_empty(), "debt_expired",
		"技术债已到期，请处理而不是延期：%s" % ", ".join(expired))


# ---- 判据与小工具 ------------------------------------------------------------

func _is_offender(code: String) -> bool:
	if _re_read.search(code) == null:
		return false
	if _re_safe.search(code) != null:
		return false
	if _re_write.search(code) != null:
		return false
	if not code.contains("text") and _re_cmp.search(code) != null:
		return false
	return true


func _matches(entries: Array, rel: String, line: String) -> bool:
	for entry in entries:
		if str(entry["file"]) == rel and line.contains(str(entry["contains"])):
			return true
	return false


func _matches_debt(rel: String, line: String) -> bool:
	return _matches(KNOWN_DEBT, rel, line)


# 三态：0 = 这棵树里没有这个文件（不算 stale —— codex 是包体树、v1.0 是全量树，
# 两棵树的文件集合本来就不同）；1 = 有且含该片段；2 = 有但不含（真腐烂，该删条目）。
func _file_state(rel: String, needle: String) -> int:
	if not FileAccess.file_exists("res://" + rel):
		return 0
	return 1 if FileAccess.get_file_as_string("res://" + rel).contains(needle) else 2


func _scan_dir(path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full := path + "/" + name
		if dir.current_is_dir():
			if not SKIP_DIRS.has(name):
				_scan_dir(full, out)
		elif name.ends_with(".gd"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
