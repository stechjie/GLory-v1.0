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

# 左面板的字直接压在棋盘底图上，而底图随棋盘皮肤换（冰雪是大片白雪）——
# 一律带深色描边，不然浅色底上的白字看不见（2026-09-26 冰雪样片发现的）。
const TEXT_OUTLINE_SIZE := 5
const TEXT_OUTLINE_COLOR := Color(0.05, 0.08, 0.12, 0.9)


func setup(p_overlay: RefCounted) -> void:
	overlay = p_overlay


func _outlined(label: Label) -> Label:
	label.add_theme_constant_override("outline_size", TEXT_OUTLINE_SIZE)
	label.add_theme_color_override("font_outline_color", TEXT_OUTLINE_COLOR)
	return label


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
	altar_logo = null
	gamble_logo = null
	var title := _outlined(Label.new())
	title.text = tr("ui_bond_treasure")
	title.add_theme_font_size_override("font_size", 16)
	_left_panel.add_child(title)

	_add_synergy_widgets()

	var sell_hint := _outlined(Label.new())
	sell_hint.text = tr("ui_sell_hint")
	sell_hint.modulate = Color(0.9, 0.82, 0.55)
	_left_panel.add_child(sell_hint)

	# Owned-treasure logos now live next to the money bag (see _owned_treasure_box).
	# 10.18：两个金钱宝藏从「文字按钮上下堆」改成一行「左 logo（点它触发）+ 右侧名称与说明」。
	# 只有拿到宝藏才出现；用完 / 血量不够时 logo 变灰、点不动。
	if GameState.owned_treasures.has("money_golden_altar"):
		# 显示实际到账金额。此前硬编码了 5，而 ALTAR_GOLD = 50 —— 玩家看到的和
		# 拿到的差了一个数量级。改成读常量，以后调数值不会再漏改这里。
		var hp_cost := 0 if TreasureService.has_linkage("link_hu_pai_master") else TreasureService.golden_altar_hp_cost()
		var altar_hp := GameState.team_hp if GameState.team_mode else GameState.player_formation_hp
		var altar_ready := altar_hp > NetworkService.ALTAR_MIN_HP and GameState.golden_altar_uses < NetworkService.ALTAR_MAX_USES_PER_ROUND
		altar_logo = _add_money_action(ALTAR_LOGO_PATH, tr("ui_altar_name"),
			tr("ui_altar_desc") % [hp_cost, NetworkService.ALTAR_GOLD, GameState.golden_altar_uses],
			altar_ready, func(): altar_requested.emit(), "money_golden_altar")

	if GameState.owned_treasures.has("money_generous_fate"):
		var loss_pct := 50 if TreasureService.has_linkage("link_fraud_fate") else 80
		var desc := tr("ui_gamble_desc_used") if GameState.gamble_used else tr("ui_gamble_desc") % loss_pct
		gamble_logo = _add_money_action(GAMBLE_LOGO_PATH, tr("ui_gamble_name"), desc,
			not GameState.gamble_used, func(): gamble_requested.emit(), "money_generous_fate")


# 金钱宝藏动作行。返回 logo 按钮，宿主拿它的位置做骰子 / 金币特效的起点。
# 原版图标仍在资源包中；不存在的“无框”路径会使 TextureButton 变成透明空白。
const ALTAR_LOGO_PATH := "res://assets/ui/treasure_logos/黄金祭坛.png"
# 骰子 logo 还没出图，先用慷慨命运原图占位；出图后只换这一个路径。
const GAMBLE_LOGO_PATH := "res://assets/ui/treasure_logos/慷慨命运.png"
const MONEY_LOGO_SIZE := Vector2(40, 40)
const MONEY_DISABLED_TINT := Color(0.42, 0.42, 0.42, 0.85)
var altar_logo: TextureButton
var gamble_logo: TextureButton

func _add_money_action(logo_path: String, title: String, desc: String, enabled: bool, on_press: Callable, detail_id: String) -> TextureButton:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(220, MONEY_LOGO_SIZE.y)
	row.add_theme_constant_override("separation", 8)
	_left_panel.add_child(row)
	var logo := TextureButton.new()
	logo.texture_normal = PrepWidgets.cached_texture(logo_path)
	logo.ignore_texture_size = true
	logo.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	logo.custom_minimum_size = MONEY_LOGO_SIZE
	logo.focus_mode = Control.FOCUS_NONE
	logo.disabled = not enabled
	logo.modulate = Color.WHITE if enabled else MONEY_DISABLED_TINT
	logo.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if enabled else Control.CURSOR_ARROW
	logo.tooltip_text = title
	logo.pressed.connect(on_press)
	overlay.attach_long_press(logo, func(): treasure_detail_requested.emit(detail_id))
	row.add_child(logo)
	var text_box := VBoxContainer.new()
	text_box.alignment = BoxContainer.ALIGNMENT_CENTER
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.add_theme_constant_override("separation", 0)
	row.add_child(text_box)
	var name_label := _outlined(Label.new())
	name_label.text = title
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.42) if enabled else Color(0.7, 0.7, 0.7))
	text_box.add_child(name_label)
	var desc_label := _outlined(Label.new())
	desc_label.text = desc
	# 单行：左栏高度很紧（4 行羁绊 + 两行宝藏要塞进 720 高），换行会压到下面的宝藏栏。
	desc_label.add_theme_font_size_override("font_size", 12)
	desc_label.add_theme_color_override("font_color", Color(0.94, 0.94, 0.90) if enabled else Color(0.62, 0.62, 0.62))
	text_box.add_child(desc_label)
	return logo



# 原 _add_current_synergy_widgets（PrepDetails.gd）
# ─── synergy widgets ──────────────────────────────────────────────────────────

func _add_synergy_widgets() -> void:
	_race_widgets.clear()
	var counts := SynergyService.count_races_from_board()
	var shown := false
	var grid := GridContainer.new()
	grid.name = "SynergyGrid"
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	_left_panel.add_child(grid)
	for race in ["god", "dark", "undead", "human", "crimson"]:
		var count := int(counts.get(race, 0))
		if count <= 0:
			continue
		var max_threshold := race_max_threshold(race)
		if max_threshold <= 0:
			continue
		shown = true
		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(106, 54)
		row.add_theme_constant_override("separation", 4)
		grid.add_child(row)

		var logo := Button.new()
		logo.custom_minimum_size = Vector2(48, 48)
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

		var count_label := _outlined(Label.new())
		count_label.text = "%d/%d" % [count, max_threshold]
		count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		count_label.add_theme_font_size_override("font_size", 18)
		count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_apply_tier_style(count_label, race, count)
		row.add_child(count_label)
		_race_widgets[race] = {"logo": effect_logo, "label": count_label, "count": count}
	if not shown:
		var none := _outlined(Label.new())
		none.text = "No units on board" if PrepWidgets.is_en() else "棋盘上没有普通棋子"
		none.modulate = Color(0.55, 0.55, 0.55)
		_left_panel.add_child(none)



# ─── 10.31 羁绊档位的面板反馈 ────────────────────────────────────────────────
#
# 计数文字按「生效到哪一档」上色：
#   · 只有第 1 档「特性」（棋盘上有这一族就自动有）：常色偏灰 —— 它谈不上「凑出来了」；
#   · 中间档生效：种族色；
#   · 最高档生效：种族色提亮 + 加粗描边。
# 这样不点开详情也能一眼看出「神 3/7」到底生效到哪一档。

# race -> {logo, label, count}。每次 _add_synergy_widgets 重建时重填（旧节点已 queue_free）。
var _race_widgets: Dictionary = {}

const TIER_IDLE_COLOR := Color(0.80, 0.80, 0.76)
const PulseColors := preload("res://scenes/prep/effects/PrepSynergyActivateBurst.gd")


func _apply_tier_style(label: Label, race: String, count: int) -> void:
	var thresholds: Array = SynergyService.RACE_THRESHOLDS.get(race, [])
	var color := TIER_IDLE_COLOR
	if thresholds.size() >= 2 and count >= int(thresholds[thresholds.size() - 1]):
		color = PulseColors.race_color(race).lerp(Color.WHITE, 0.25)
		label.add_theme_constant_override("outline_size", TEXT_OUTLINE_SIZE + 3)
	elif thresholds.size() >= 2 and count >= int(thresholds[1]):
		# 提亮一点：人族蓝 / 暗族紫原色压在深色描边上偏暗，18px 字不好认。
		color = PulseColors.race_color(race).lerp(Color.WHITE, 0.2)
	label.add_theme_color_override("font_color", color)
	label.set_meta("tier_color", color)


# 宿主在羁绊跨档 / 掉档时调。kind："minor" / "major" / "ultimate" / "drop"。
#
# 调用时面板刚被 refresh() 整个重建过，新节点还没排版（size 为 0），
# 所以先等一帧再设 pivot —— 否则缩放绕左上角，图标会往右下甩。
func pulse_race(race: String, kind: String) -> void:
	if not is_inside_tree():
		return
	var widgets: Dictionary = _race_widgets.get(race, {})
	if widgets.is_empty():
		return
	await get_tree().process_frame
	# 等的这一帧里面板可能又重建了：先判有效再转型（对已释放对象 as 会报 SCRIPT ERROR）。
	if not is_instance_valid(widgets.get("logo")):
		return
	var logo := widgets.get("logo") as Control
	var label: Label = widgets.get("label") as Label if is_instance_valid(widgets.get("label")) else null
	logo.pivot_offset = logo.size * 0.5
	if kind == "drop":
		# 掉档：图标迅速褪成灰再恢复，不弹。
		logo.modulate = Color(0.45, 0.45, 0.45, 1.0)
		var dt := logo.create_tween()
		dt.tween_property(logo, "modulate", Color.WHITE, 0.40).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		return
	# 弹一下：先压扁再 TRANS_BACK 过冲回弹。档位越高越大。
	var amount := {"minor": 0.18, "major": 0.30, "ultimate": 0.45}.get(kind, 0.18) as float
	logo.scale = Vector2(1.0 + amount, 1.0 - amount * 0.6)
	var tween := logo.create_tween()
	tween.tween_property(logo, "scale", Vector2.ONE, 0.32 if kind == "minor" else 0.42) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if kind == "minor" or label == null or not is_instance_valid(label):
		return
	# 计数文字闪一下：先亮成近白的种族色，再回到这一档的常驻色。
	var rest: Color = label.get_meta("tier_color", TIER_IDLE_COLOR)
	var flash := PulseColors.race_color(race).lerp(Color.WHITE, 0.6)
	label.pivot_offset = label.size * 0.5
	label.scale = Vector2.ONE * (1.25 if kind == "major" else 1.4)
	var lt := label.create_tween()
	lt.tween_property(label, "scale", Vector2.ONE, 0.36).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# tween 绑在 label 自己身上，label 被释放时 tween 一起停，回调里不会碰到已释放节点。
	lt.parallel().tween_method(_set_label_color.bind(label), flash, rest, 0.6 if kind == "major" else 0.9)


func _set_label_color(c: Color, label: Label) -> void:
	label.add_theme_color_override("font_color", c)


# 档位显示名（如「神7·神佑」）。终极档弹字用，口径与详情弹窗一致：
# 中文优先取 FinalStatusCatalog 的定稿名，没有再退回本文件的条目表。
static func tier_display_name(race: String, threshold: int) -> String:
	var entries := _race_entries_en(race) if PrepWidgets.is_en() else _race_entries(race)
	for item in entries:
		if int(item.get("threshold", 0)) != threshold:
			continue
		var approved := FinalStatusCatalog.synergy_cn(race, threshold) if not PrepWidgets.is_en() else {}
		return str(approved.get("name_cn", item.get("name", "")))
	return ""


# 原 _race_synergy_entries（PrepDetails.gd）

# ─── race synergy ─────────────────────────────────────────────────────────────

static func _race_entries(race: String) -> Array:
	if PrepWidgets.is_en():
		return _race_entries_en(race)
	match race:
		"god":
			return [
				{"threshold": 1, "name": "神族特性·净化", "detail": "友方单位死亡时，随机一名存活友军清除所有负面状态。"},
				{"threshold": 3, "name": "神3·吸血", "detail": "神族单位造成伤害时回复实际伤害 20% 生命。"},
				{"threshold": 7, "name": "神7·神佑", "detail": "开战 1 秒后起，每 5 秒全队无敌 1 秒（只免普攻与技能伤害，中毒/流血照常受伤）。"},
			]
		"dark":
			return [
				{"threshold": 1, "name": "暗族特性·击杀叠层", "detail": "每 3 个敌人死亡，暗族单位获得 1 层 +6% 伤害。"},
				{"threshold": 2, "name": "暗2·负面强化", "detail": "暗族单位施加的所有负面效果数值强度 +30%；无数值的控制效果持续时间 +30%。"},
				{"threshold": 5, "name": "暗5·伤害", "detail": "暗族单位伤害 +25%。"},
				{"threshold": 7, "name": "暗7·蚀魂", "detail": "暗族单位每次普攻使目标攻击/防御/攻速 -3%，自身攻击/防御/攻速 +3%（各最多 15 层）。"},
			]
		"undead":
			return [
				{"threshold": 1, "name": "灵族特性·双毒", "detail": "灵族施加的中毒最多叠加2层，分别计时和造成伤害；两层时目标头顶显示两枚毒标记。"},
				{"threshold": 2, "name": "灵2·剧毒抑疗", "detail": "目标中毒期间，其治疗与吸血获得的生命减少 30%。"},
				{"threshold": 4, "name": "灵4·剧毒", "detail": "灵族中毒伤害翻倍。"},
				{"threshold": 7, "name": "灵7·噬毒", "detail": "灵族单位攻击已中毒的敌人时，每次回复自身 15% 最大生命。"},
			]
		"human":
			return [
				{"threshold": 1, "name": "人族特性·三连暴击", "detail": "人族单位每第 3 次攻击必定暴击。"},
				{"threshold": 2, "name": "人2·护盾", "detail": "开战时普通棋子获得等于 8% 最大生命的护盾。"},
				{"threshold": 7, "name": "人7·哀兵", "detail": "己方每阵亡 1 个棋子，存活棋子获得 1 层：最大生命/攻击/防御/攻速 +20%、暴击 +20%、暴击伤害 +10%，并回复 20% 生命（可无限叠加）。"},
			]
		"crimson":
			return [
				{"threshold": 1, "name": "赤律特性·战律符文", "detail": "赤律棋子每次给自身施加增益或减益时获得1层战律符文（每次行动最多1层，整场最多9层）。3层：暴击率+30%；6层：再加攻速+60%；9层：再加暴击伤害+90%。赤律4共鸣与赤律7赤潮也可叠加符文。"},
				{"threshold": 2, "name": "赤律2·绵延", "detail": "赤律族施加的增益和减益持续时间 +20%；沉默、冰霜等控制额外增加最多 0.5 秒。"},
				{"threshold": 4, "name": "赤律4·共鸣", "detail": "每次成功施加增益、减益或控制，施加者获得一层共鸣：攻击和攻速 +5%，持续 4 秒，最多 10 层；新增层数刷新持续时间。"},
				{"threshold": 7, "name": "赤律7·赤潮", "detail": "开战第 2 秒起每 5 秒，赤律族全体技能剩余冷却 -1 秒、清除负面状态、回复 6% 最大生命，并永久获得 1 层攻击和攻速 +10%、暴击率 +10 个百分点，整场最多 5 层。"},
			]
	return []



# 原 _race_synergy_entries_en（PrepDetails.gd）
static func _race_entries_en(race: String) -> Array:
	match race:
		"god":
			return [
				{"threshold": 1, "name": "God Trait: Cleanse", "detail": "When a friendly unit dies, one random surviving ally removes all debuffs."},
				{"threshold": 3, "name": "God 3: Lifesteal", "detail": "God units restore 20% of actual damage dealt as HP."},
				{"threshold": 7, "name": "God 7: Divine Pulse", "detail": "From 1s into battle, every 5s your whole team is invincible for 1s (blocks attacks and skills; poison/bleed still hurt)."},
			]
		"dark":
			return [
				{"threshold": 1, "name": "Dark Trait: Kill Stack", "detail": "Every 3 enemy deaths, Dark units gain 1 stack of +6% damage."},
				{"threshold": 2, "name": "Dark 2: Debuff Power", "detail": "All debuffs applied by Dark units are 30% stronger; controls without a numeric strength last 30% longer."},
				{"threshold": 5, "name": "Dark 5: Damage", "detail": "Dark units deal +25% damage."},
				{"threshold": 7, "name": "Dark 7: Soul Sap", "detail": "Each Dark basic attack reduces the target’s ATK/DEF/AS by 3% and raises the attacker’s by 3% (up to 15 stacks each)."},
			]
		"undead":
			return [
				{"threshold": 1, "name": "Undead Trait: Double Poison", "detail": "Poison applied by Undead units stacks twice. Each stack ticks and expires separately; two poison marks appear above the target at two stacks."},
				{"threshold": 2, "name": "Undead 2: Venom Suppression", "detail": "While poisoned, the target receives 30% less HP from healing and lifesteal."},
				{"threshold": 4, "name": "Undead 4: Poison", "detail": "Undead poison deals double damage."},
				{"threshold": 7, "name": "Undead 7: Venom Feast", "detail": "When Undead units hit a poisoned enemy, they restore 15% of their max HP per hit."},
			]
		"human":
			return [
				{"threshold": 1, "name": "Human Trait: Triple Crit", "detail": "Every 3rd attack from a Human unit is a guaranteed critical hit."},
				{"threshold": 2, "name": "Human 2: Shield", "detail": "At battle start, normal units gain a shield equal to 8% max HP."},
				{"threshold": 7, "name": "Human 7: Vengeance", "detail": "Each time one of your units dies, survivors gain a stack: max HP/ATK/DEF/AS +20%, Crit +20%, CritDmg +10%, and heal 20% HP (no stack limit)."},
			]
		"crimson":
			return [
				{"threshold": 1, "name": "Crimson Trait: Battle Runes", "detail": "When a Crimson unit applies a buff or debuff to itself, it gains one rune (at most one per action and nine per battle). At 3 runes: +30 percentage points Crit; at 6: another +60% Attack Speed; at 9: another +90 percentage points Crit Damage. Crimson 4 Resonance and Crimson 7 Red Tide also grant runes."},
				{"threshold": 2, "name": "Crimson 2: Lingering Effects", "detail": "Crimson buffs and debuffs last 20% longer. Control effects gain at most 0.5 additional seconds."},
				{"threshold": 4, "name": "Crimson 4: Resonance", "detail": "Applying a buff, debuff, or control grants the caster +5% ATK and attack speed for 4s, up to 10 stacks. New stacks refresh the duration."},
				{"threshold": 7, "name": "Crimson 7: Red Tide", "detail": "From 2s into battle, every 5s Crimson units reduce remaining skill cooldown by 1s, cleanse debuffs, heal 6% max HP, and permanently gain one stack of +10% ATK, +10% attack speed, and +10 percentage points crit chance, up to 5 stacks per battle."},
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
		var approved := FinalStatusCatalog.synergy_cn(race, threshold) if not PrepWidgets.is_en() else {}
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
			str(approved.get("name_cn", item.get("name", ""))),
			str(approved.get("detail_cn", item.get("detail", ""))),
		])
	return "\n".join(lines)



# ─── 羁绊**效果**列表（10.01 第 12 条）─────────────────────────────────────
#
# 与 format_synergy_detail 的区别：那条是**战场上**的达成状态（当前数量 N/7、
# 已解锁 / 未解锁 · 还差 N 人），这里是选族前的**效果预览**，只列效果本身。
# 用户明确要求「去除已解锁、未解锁、还差几人这种说明」。
#
# 返回**纯文本**（不是 BBCode）：弹窗正文是 Label，不吃标记；全文同一字号
# 同一颜色，也就满足了「字体和颜色深浅要一致」。
static func format_synergy_effects(race: String) -> String:
	var blocks: Array[String] = []
	for item in _race_entries(race):
		var approved := FinalStatusCatalog.synergy_cn(race, int(item.get("threshold", 0))) if not PrepWidgets.is_en() else {}
		blocks.append("%s\n%s" % [str(approved.get("name_cn", item.get("name", ""))), str(approved.get("detail_cn", item.get("detail", "")))])
	return "\n\n".join(blocks)


# 弹窗标题：与 format_synergy_detail 的抬头同一口径（神族羁绊 / God Bond）。
static func format_synergy_title(race: String) -> String:
	if PrepWidgets.is_en():
		return "%s Bond" % race_name(race)
	return "%s族羁绊" % race_name(race)


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
		"undead": entries = [{"threshold":1},{"threshold":2},{"threshold":4},{"threshold":7}]
		"human":  entries = [{"threshold":1},{"threshold":2},{"threshold":7}]
		"crimson": entries = [{"threshold":1},{"threshold":2},{"threshold":4},{"threshold":7}]
		_:        entries = []
	for item in entries:
		max_threshold = maxi(max_threshold, int(item.get("threshold", 0)))
	return max_threshold



# 原 _race_name（PrepDetails.gd）
# ─── race names ───────────────────────────────────────────────────────────────

static func race_name(race: String) -> String:
	if PrepWidgets.is_en():
		match race:
			"god":    return "God"
			"dark":   return "Dark"
			"undead": return "Undead"
			"human":  return "Human"
			"crimson": return "Crimson"
		return race
	match race:
		"god":    return "神"
		"dark":   return "暗"
		"undead": return "灵"
		"human":  return "人"
		"crimson": return "赤律"
	return race
