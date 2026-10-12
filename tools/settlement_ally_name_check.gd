extends Node

# 10.12 反馈第 2 条（中英切换）：
#   「英文语言模式下，最终结算面板里的法阵守护者名字未转换成英文。检查任何模式下对局的
#     结算面板及对战历史查看详情面板，法阵守护者名字要跟随中英文语言模式转换进行切换。」
#
# 战报里存的是守护者的**中文名**（FinalSettlementData 取 actor.name ⇒ 数据表的 name），
# 所以英文界面上一直冒中文。修法：显示侧按 id / 中文名 / 英文名反查 formation_allies，
# 换成本语言的名字。历史详情复用的就是同一个面板（MatchHistoryPanel.settlement_view_data
# → FinalSettlementPanel），所以两条路径用同一套判据。
#
# 四节：
#   A 数据面：法阵守护者表每条都有 id / name / name_en，且中英不同名
#   B 纯函数：_ally_display_name 对**表里每一条**的 id / 中文名 / 英文名 三种输入、
#     两种语言都正确；空串给空；表里没有的名字原样返回
#   C 真实现（实时结算面板）：把面板挂进树，读**真实 Label 文本** —— 每个守护者放到
#     红/蓝任一队，英文模式必须出现英文名且不出现中文名，中文模式反之
#   D 历史路径：用 MatchHistoryPanel.settlement_view_data() 造出面板数据，走同一个面板，
#     断言与 C 同口径（历史里已存的旧战报同样要翻）
#
# ★ 注意（本门禁第一版踩过的坑）：面板一支队伍只带**一个**法阵守护者。夹具里只放了
#   allies[0]，却回头对所有 allies 断言「名字要出现」⇒ 后 4 条必假红。夹具里放谁，
#   就只能断言谁。

const H := preload("res://tools/CheckHarness.gd")
const PanelScript := preload("res://scenes/menu/FinalSettlementPanel.gd")
const HistoryPanel := preload("res://scenes/menu/MatchHistoryPanel.gd")
const ALLY_TABLE := "formation_allies"

var h


func _ready() -> void:
	h = H.new("settlement_ally_name")
	var saved_locale: String = LocaleManager.get_locale()
	var allies := _allies()

	_section_table(allies)
	_section_helper(allies)
	for locale in ["zh", "en"]:
		await _section_live(allies, str(locale))
	await _section_history(allies)

	LocaleManager.set_locale(saved_locale)
	h.finish(get_tree())


func _allies() -> Array:
	var out: Array = []
	for raw in DataRegistry.get_table(ALLY_TABLE).get("allies", []):
		if typeof(raw) == TYPE_DICTIONARY:
			out.append(raw)
	return out


# --- A 数据面 ---------------------------------------------------------------

func _section_table(allies: Array) -> void:
	h.expect(not allies.is_empty(), "table_nonempty", "法阵守护者表应至少有一条")
	h.expect(allies.size() >= 2, "table_has_multiple",
		"法阵守护者表应至少 2 条（否则「跟着语言切换」无从区分）")
	for a in allies:
		var d: Dictionary = a
		var id := str(d.get("id", ""))
		var zh := str(d.get("name", ""))
		var en := str(d.get("name_en", ""))
		h.item()
		h.expect(not id.is_empty() and not zh.is_empty() and not en.is_empty(),
			"entry_fields", "守护者 %s 缺字段：id=%s zh=%s en=%s" % [id, id, zh, en])
		h.expect(zh != en, "entry_zh_ne_en",
			"守护者 %s 中英同名（%s）—— 同名则本门禁无法区分语言是否生效" % [id, zh])


# --- B 纯函数 ---------------------------------------------------------------

func _section_helper(allies: Array) -> void:
	var panel: Control = PanelScript.new()
	for locale in ["zh", "en"]:
		LocaleManager.set_locale(str(locale))
		var expect_zh: bool = str(locale) != "en"
		for a in allies:
			var d: Dictionary = a
			var id := str(d.get("id", ""))
			var zh := str(d.get("name", ""))
			var en := str(d.get("name_en", ""))
			var want: String = zh if expect_zh else en
			for pair in [[id, "id"], [zh, "中文名"], [en, "英文名"]]:
				var got: String = str(panel.call("_ally_display_name", str(pair[0])))
				h.item()
				h.expect(got == want, "helper_input_kind",
					"%s 语言下用%s（%s）查询应得 %s，实得 %s" % [locale, str(pair[1]), str(pair[0]), want, got])
		var blank: String = str(panel.call("_ally_display_name", ""))
		h.item()
		h.expect(blank == "", "helper_empty", "%s 语言下空串应给空串" % locale)
		var unknown: String = str(panel.call("_ally_display_name", "不存在的守护者"))
		h.item()
		h.expect(unknown == "不存在的守护者", "helper_unknown",
			"%s 语言下未知名字应原样返回" % locale)
	panel.free()


# --- C 真实现 ---------------------------------------------------------------

func _section_live(allies: Array, locale: String) -> void:
	LocaleManager.set_locale(locale)
	var expect_zh: bool = locale != "en"
	for side in [0, 1]:
		# 红队（side 0）把整张表都过一遍；蓝队（side 1）再用第一条验证另一支队伍的接线。
		var picks: Array = allies if side == 0 else [allies[0]]
		for a in picks:
			var d: Dictionary = a
			var zh := str(d.get("name", ""))
			var en := str(d.get("name_en", ""))
			var shown: String = en if not expect_zh else zh
			var hidden: String = zh if not expect_zh else en
			var panel: Control = PanelScript.new()
			panel.data = _fixture_data(zh, side)
			var holder := Control.new()
			holder.custom_minimum_size = Vector2(1280, 720)
			holder.size = Vector2(1280, 720)
			add_child(holder)
			holder.add_child(panel)
			await _settle()
			var texts := _label_texts(panel)
			h.item()
			h.expect(_contains(texts, shown), "live_shows_locale_name",
				"side=%d %s：面板应出现「%s」" % [side, locale, shown])
			h.item()
			h.expect(not _contains(texts, hidden), "live_hides_other_locale_name",
				"side=%d %s：面板不该出现另一语言的「%s」" % [side, locale, hidden])
			holder.queue_free()


# --- D 历史路径 -------------------------------------------------------------

func _section_history(allies: Array) -> void:
	for a in allies:
		var first: Dictionary = a
		var zh := str(first.get("name", ""))
		var en := str(first.get("name_en", ""))
		var item := {
			"my_slot": 0,
			"seats": [],
			"settlement": {"kind": "final", "allies": [zh, ""], "seats": [], "stats": []},
		}
		h.expect(HistoryPanel.has_settlement_details(item), "history_accepts_fixture",
			"历史夹具应被判定为「有结算详情」（否则 D 节根本没测到面板）")
		var data: Dictionary = HistoryPanel.settlement_view_data(item)
		for locale in ["zh", "en"]:
			LocaleManager.set_locale(str(locale))
			var panel: Control = PanelScript.new()
			panel.data = data
			var holder := Control.new()
			holder.custom_minimum_size = Vector2(1280, 720)
			holder.size = Vector2(1280, 720)
			add_child(holder)
			holder.add_child(panel)
			await _settle()
			var texts := _label_texts(panel)
			var shown: String = en if str(locale) == "en" else zh
			h.item()
			h.expect(_contains(texts, shown), "history_shows_locale_name",
				"历史详情 %s：应出现「%s」" % [locale, shown])
			holder.queue_free()


# --- 工具 -------------------------------------------------------------------

func _fixture_data(guardian_zh: String, side: int) -> Dictionary:
	var guardians: Array = ["", ""]
	guardians[side] = guardian_zh
	var seats: Array = []
	for slot in 6:
		seats.append({
			"slot": slot, "name": "P%d" % slot, "is_local": slot == 0,
			"board": [], "mercenaries": [], "treasures": [], "stones": {},
			"total_gold": 0,
		})
	return {
		"outcome": 2, "local_team": 0, "allies": guardians,
		"seats": seats, "stats": [], "can_return_room": false,
	}


func _label_texts(root: Node) -> Array:
	var out: Array = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		for child in cur.get_children():
			stack.append(child)
		if cur is Label:
			out.append((cur as Label).text)
	return out


func _contains(texts: Array, needle: String) -> bool:
	if needle.is_empty():
		return false
	for t in texts:
		if str(t).contains(needle):
			return true
	return false


func _settle() -> void:
	for _i in 4:
		await get_tree().process_frame
