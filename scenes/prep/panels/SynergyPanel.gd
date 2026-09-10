extends Control

# 备战界面左侧的**羁绊面板** —— D2 步骤 4′。
#
# 它显示当前棋盘的种族羁绊进度，另外还挂着两个宝物动作按钮
# （黄金祭坛、慷慨命运）—— 那两个按钮在视觉上属于左面板，
# 但它们的**执行**归宿主：一个改水晶血量、一个开奖并改金币，
# 都不是「显示羁绊」这个面板该伸手做的事。所以按钮在这里、动作发信号出去。
#
# 与 ShopPanel 同一套结构：依赖由 setup() 注入，动作用信号出去，
# 面板不认识 PrepScreen。

const PrepWidgets := preload("res://scenes/prep/PrepWidgets.gd")
const PrepShopRaceIcon = preload("res://scenes/prep/PrepShopRaceIcon.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")

signal altar_requested                       # 点了黄金祭坛
signal gamble_requested                      # 点了慷慨命运
signal treasure_detail_requested(id: String) # 长按宝物按钮看说明

var overlay: RefCounted


func setup(p_overlay: RefCounted) -> void:
	overlay = p_overlay


# --- 搬过来的成员 ---
var _left_panel: VBoxContainer
var _left_panel_signature := "unset"


# 原 _refresh_left_panel（PrepUI.gd）
func refresh() -> void:
	var sig_altar_hp := GameState.team_hp if GameState.team_mode else GameState.player_formation_hp
	var sig := JSON.stringify([
		SynergyService.count_races_from_board(),
		GameState.owned_treasures,
		GameState.golden_altar_uses,
		GameState.gamble_used,
		sig_altar_hp <= 10,
		LocaleManager.get_locale(),
	])
	if sig == _left_panel_signature:
		return
	_left_panel_signature = sig
	for child in _left_panel.get_children():
		child.queue_free()
	var title := Label.new()
	title.text = tr("ui_bond_treasure")
	title.add_theme_font_size_override("font_size", 16)
	_left_panel.add_child(title)

	_add_synergy_widgets()

	var sell_hint := Label.new()
	sell_hint.text = tr("ui_sell_hint")
	sell_hint.modulate = Color(0.9, 0.82, 0.55)
	_left_panel.add_child(sell_hint)

	# Owned-treasure logos now live next to the money bag (see _owned_treasure_box).
	if GameState.owned_treasures.has("money_golden_altar"):
		var altar := Button.new()
		# 显示实际到账金额。此前硬编码了 5，而 ALTAR_GOLD = 50 —— 玩家看到的和
		# 拿到的差了一个数量级。改成读常量，以后调数值不会再漏改这里。
		altar.text = tr("ui_altar") % [NetworkService.ALTAR_GOLD, GameState.golden_altar_uses]
		var altar_hp := GameState.team_hp if GameState.team_mode else GameState.player_formation_hp
		altar.disabled = altar_hp <= NetworkService.ALTAR_MIN_HP or GameState.golden_altar_uses >= NetworkService.ALTAR_MAX_USES_PER_ROUND
		altar.pressed.connect(func(): altar_requested.emit())
		_left_panel.add_child(altar)

	if GameState.owned_treasures.has("money_generous_fate"):
		var gamble := Button.new()
		gamble.text = tr("ui_gamble_used") if GameState.gamble_used else tr("ui_gamble")
		gamble.disabled = GameState.gamble_used
		gamble.pressed.connect(func(): gamble_requested.emit())
		overlay.attach_long_press(gamble, func(): treasure_detail_requested.emit("money_generous_fate"))
		_left_panel.add_child(gamble)



# 原 _add_current_synergy_widgets（PrepDetails.gd）
# ─── synergy widgets ──────────────────────────────────────────────────────────

func _add_synergy_widgets() -> void:
	var counts := SynergyService.count_races_from_board()
	var shown := false
	for race in ["god", "dark", "undead", "human"]:
		var count := int(counts.get(race, 0))
		if count <= 0:
			continue
		var max_threshold := race_max_threshold(race)
		if max_threshold <= 0:
			continue
		shown = true
		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(220, 58)
		row.add_theme_constant_override("separation", 12)
		_left_panel.add_child(row)

		var logo := Button.new()
		logo.custom_minimum_size = Vector2(54, 54)
		logo.focus_mode = Control.FOCUS_NONE
		logo.text = ""
		if PrepWidgets.is_en():
			logo.tooltip_text = "%s Bond %d/%d" % [race_name(race), count, max_threshold]
		else:
			logo.tooltip_text = "%s族羁绊 %d/%d" % [race_name(race), count, max_threshold]
		PrepWidgets.apply_empty_button_styles(logo)
		var effect_logo: Control = PrepShopRaceIcon.new()
		effect_logo.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		effect_logo.call("set_race", race)
		logo.add_child(effect_logo)
		logo.pressed.connect(overlay.show_text.bind(format_synergy_detail(race, count)))
		row.add_child(logo)

		var count_label := Label.new()
		count_label.text = "%d/%d" % [count, max_threshold]
		count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		count_label.add_theme_font_size_override("font_size", 18)
		count_label.add_theme_color_override("font_color", Color(0.94, 0.94, 0.90))
		count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(count_label)
	if not shown:
		var none := Label.new()
		none.text = "No units on board" if PrepWidgets.is_en() else "棋盘上没有普通棋子"
		none.modulate = Color(0.55, 0.55, 0.55)
		_left_panel.add_child(none)



# 原 _race_synergy_entries（PrepDetails.gd）

# ─── race synergy ─────────────────────────────────────────────────────────────

func _race_entries(race: String) -> Array:
	if PrepWidgets.is_en():
		return _race_entries_en(race)
	match race:
		"god":
			return [
				{"threshold": 1, "name": "神族特性·净化", "detail": "友方单位死亡时，随机一名存活友军清除所有负面状态。"},
				{"threshold": 3, "name": "神3·吸血", "detail": "神族单位造成伤害时回复实际伤害 20% 生命。"},
				{"threshold": 7, "name": "神7·无敌", "detail": "神族单位开战时无敌 1.5 秒。"},
			]
		"dark":
			return [
				{"threshold": 1, "name": "暗族特性·击杀叠层", "detail": "每 3 个敌人死亡，暗族单位获得 1 层 +6% 伤害。"},
				{"threshold": 2, "name": "暗2·负面强化", "detail": "暗族负面效果（减攻、减速、破甲）强度 +25%。"},
				{"threshold": 5, "name": "暗5·伤害", "detail": "暗族单位伤害 +25%。"},
				{"threshold": 7, "name": "暗7·负面延时", "detail": "暗族负面效果持续时间 +50%。"},
			]
		"undead":
			return [
				{"threshold": 1, "name": "灵族特性·亡者召唤", "detail": "累计 30 次死亡时，每个灵族单位以 40% 属性召唤一个随机死亡单位的复制体。"},
				{"threshold": 4, "name": "灵4·剧毒", "detail": "灵族中毒伤害翻倍。"},
				{"threshold": 7, "name": "灵7·降低阈值", "detail": "灵族触发阈值降低：鬼母每 4 次死亡触发（原 5）；召唤在 23 次死亡（原 30）。"},
			]
		"human":
			return [
				{"threshold": 1, "name": "人族特性·三连暴击", "detail": "人族单位每第 3 次攻击必定暴击。"},
				{"threshold": 2, "name": "人2·护盾", "detail": "开战时普通棋子获得等于 8% 最大生命的护盾。"},
				{"threshold": 7, "name": "人7·狂战士", "detail": "仅剩 1 个普通棋子时触发一次：最大生命 ×2、防御 ×2、攻击 ×2、攻速 ×2、暴击 +100%、暴击伤害 +50%，并回复 50% 生命。"},
			]
	return []



# 原 _race_synergy_entries_en（PrepDetails.gd）
func _race_entries_en(race: String) -> Array:
	match race:
		"god":
			return [
				{"threshold": 1, "name": "God Trait: Cleanse", "detail": "When a friendly unit dies, one random surviving ally removes all debuffs."},
				{"threshold": 3, "name": "God 3: Lifesteal", "detail": "God units restore 20% of actual damage dealt as HP."},
				{"threshold": 7, "name": "God 7: Invincible", "detail": "God units become invincible for 1.5s at battle start."},
			]
		"dark":
			return [
				{"threshold": 1, "name": "Dark Trait: Kill Stack", "detail": "Every 3 enemy deaths, Dark units gain 1 stack of +6% damage."},
				{"threshold": 2, "name": "Dark 2: Debuff Power", "detail": "Dark debuffs (ATK down, slow, DEF down) are 25% stronger."},
				{"threshold": 5, "name": "Dark 5: Damage", "detail": "Dark units deal +25% damage."},
				{"threshold": 7, "name": "Dark 7: Debuff Duration", "detail": "Dark debuffs last 50% longer."},
			]
		"undead":
			return [
				{"threshold": 1, "name": "Undead Trait: Death Summon", "detail": "At 30 total deaths, each of your Undead units summons a clone of a random dead unit at 40% stats."},
				{"threshold": 4, "name": "Undead 4: Poison", "detail": "Undead poison deals double damage."},
				{"threshold": 7, "name": "Undead 7: Lower Thresholds", "detail": "Undead trigger thresholds reduced: Matron triggers every 4 deaths (was 5); summon at 23 deaths (was 30)."},
			]
		"human":
			return [
				{"threshold": 1, "name": "Human Trait: Triple Crit", "detail": "Every 3rd attack from a Human unit is a guaranteed critical hit."},
				{"threshold": 2, "name": "Human 2: Shield", "detail": "At battle start, normal units gain a shield equal to 8% max HP."},
				{"threshold": 7, "name": "Human 7: Berserker", "detail": "Triggers once when only 1 normal unit remains: max HP ×2, DEF ×2, ATK ×2, AS ×2, Crit +100%, CritDmg +50%, and restore 50% HP."},
			]
	return []



# 原 _format_synergy_detail（PrepDetails.gd）
func format_synergy_detail(race: String, count: int) -> String:
	var lines: Array[String] = []
	var max_threshold := race_max_threshold(race)
	if PrepWidgets.is_en():
		lines.append("[b]%s Bond[/b]" % race_name(race))
		lines.append("On board: %d/%d" % [count, max_threshold])
	else:
		lines.append("[b]%s族羁绊[/b]" % race_name(race))
		lines.append("当前数量：%d/%d" % [count, max_threshold])
	for item in _race_entries(race):
		var threshold := int(item.get("threshold", 0))
		var active := count >= threshold
		var status := ""
		if active:
			status = "Active" if PrepWidgets.is_en() else "已解锁"
		else:
			var missing := maxi(0, threshold - count)
			status = ("Locked · Need %d more" % missing if PrepWidgets.is_en()
				else "未解锁 · 还差 %d 人" % missing)
		lines.append("")
		lines.append("[color=#%s][b]%s[/b][/color]" % [
			Tokens.GOLD.to_html(false), status])
		lines.append("[color=#%s][b]%s[/b]\n%s[/color]" % [
			Tokens.TEXT_PRIMARY.to_html(false) if active else Tokens.TEXT_SECONDARY.to_html(false),
			str(item.get("name", "")),
			str(item.get("detail", "")),
		])
	return "\n".join(lines)



# 原 _race_synergy_max_threshold（PrepDetails.gd）
func race_max_threshold(race: String) -> int:
	var max_threshold := 0
	# use zh entries for threshold values (same in both locales)
	var en_backup := PrepWidgets.is_en()
	# temporarily query zh entries for thresholds
	var entries: Array
	match race:
		"god":    entries = [{"threshold":1},{"threshold":3},{"threshold":7}]
		"dark":   entries = [{"threshold":1},{"threshold":2},{"threshold":5},{"threshold":7}]
		"undead": entries = [{"threshold":1},{"threshold":4},{"threshold":7}]
		"human":  entries = [{"threshold":1},{"threshold":2},{"threshold":7}]
		_:        entries = []
	for item in entries:
		max_threshold = maxi(max_threshold, int(item.get("threshold", 0)))
	return max_threshold



# 原 _race_name（PrepDetails.gd）
# ─── race names ───────────────────────────────────────────────────────────────

func race_name(race: String) -> String:
	if PrepWidgets.is_en():
		match race:
			"god":    return "God"
			"dark":   return "Dark"
			"undead": return "Undead"
			"human":  return "Human"
		return race
	match race:
		"god":    return "神"
		"dark":   return "暗"
		"undead": return "灵"
		"human":  return "人"
	return race
