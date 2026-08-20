extends Control

# 备战界面的**宝物面板** —— D2 步骤 4′。
#
# 两块内容：
#   * 三选一浮层（回合结束后弹出，带倒计时与刷新按钮）
#   * 已持有宝物的 logo 栏（钱袋旁边那一排）
#
# 面板负责「显示候选、显示说明文案、把点击变成信号」；
# 真正的领取由宿主执行 —— 它要走服务端授予流程（NetworkService.treasure_granted），
# 不是面板能自己决定的事。
#
# 那几段 effect_text / link_effect_text 是纯查表的文案函数，
# 由 tools/prep_text_coverage_check.tscn 守着「数据表里每件宝物都有文案」——
# 少写一条不会崩，只会显示占位符。

const PrepWidgets := preload("res://scenes/prep/PrepWidgets.gd")
const TREASURE_CARD_DIRECTORY := "res://assets/ui/treasure_cards"

signal pick_requested(tid: String)  # 玩家点了某个候选；领取流程归宿主（要走服务端授予）
signal claim_requested              # 该结算这一轮的宝物了
signal net_signals_needed           # 联机重摇前，请宿主确保 NetworkService 宝物信号已连
signal state_changed                # 需要整屏刷新

# ⚠️ 面板节点是**零尺寸**的逻辑宿主。浮层用 PRESET_FULL_RECT 锚定，
# 挂到零尺寸父节点上锚点会解算成 0 大小 —— 界面直接消失，且不报错。
# 所以顶层控件一律 host.add_child(...)，挂在 PrepScreen 下，位置与原来一致。
# （节点树基线因此只多面板节点本身这一个。）
var host: Control
var overlay: RefCounted
var hover_handler: Callable


func setup(p_host: Control, p_overlay: RefCounted, p_hover: Callable) -> void:
	host = p_host
	overlay = p_overlay
	hover_handler = p_hover


# --- 搬过来的成员 ---
var _treasure_overlay: ColorRect
var _treasure_timer_lbl: Label
var _treasure_choice_row: HBoxContainer
var _treasure_refresh_btn: Button
var _owned_treasure_box: GridContainer


# 原 _refresh_treasure_panel（PrepUI.gd）

func refresh() -> void:
	if _treasure_overlay == null:
		return
	var active := bool(GameState.pending_treasure.get("active", false))
	_treasure_overlay.visible = active
	if not active:
		return
	_treasure_timer_lbl.text = tr("ui_treasure_pick")
	for child in _treasure_choice_row.get_children():
		child.queue_free()
	var cands: Array = GameState.pending_treasure.get("candidates", [])
	for i in cands.size():
		var tid := str(cands[i])
		var t := TreasureService.treasure_by_id(tid)
		var tname := str(t.get("name", tid))
		var card := Button.new()
		# 三选一抽宝藏卡整体放大 30%（336×448 → 437×582）。
		card.custom_minimum_size = Vector2(437, 582)
		card.focus_mode = Control.FOCUS_NONE
		PrepWidgets.apply_empty_button_styles(card)
		PrepWidgets.configure_unframed_portrait_card(card, hover_handler)
		card.pressed.connect(func(): pick_requested.emit(tid))
		overlay.attach_long_press(card, show_detail.bind(tid))
		var tex := TextureRect.new()
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var _card_suffix := "_en" if LocaleManager.get_locale() == "en" else ""
		var _tex_path := "%s/%s%s.png" % [TREASURE_CARD_DIRECTORY, tname, _card_suffix]
		var _loaded_tex := PrepWidgets.cached_texture(_tex_path)
		if _loaded_tex == null:
			_loaded_tex = PrepWidgets.cached_texture("%s/%s.png" % [TREASURE_CARD_DIRECTORY, tname])
		tex.texture = _loaded_tex
		card.add_child(tex)
		# Safety net: if the card art is missing, never leave the card invisible —
		# show the treasure name so it stays selectable.
		if _loaded_tex == null:
			var fallback := Label.new()
			fallback.text = PrepWidgets.unit_name(t)
			fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
			fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			fallback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			fallback.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			fallback.add_theme_font_size_override("font_size", 28)
			fallback.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
			fallback.add_theme_constant_override("outline_size", 4)
			card.add_child(fallback)
		_treasure_choice_row.add_child(card)
	var cost := TreasureService.refresh_cost(int(GameState.pending_treasure.get("refresh_index", 0)), TreasureService.has_set("money"))
	_treasure_refresh_btn.text = tr("ui_treasure_refresh_free") if cost == 0 else tr("ui_treasure_refresh_cost") % cost
	_treasure_refresh_btn.disabled = GameState.gold < cost



# 原 _refresh_treasure_candidates（PrepFlowController.gd）

func _refresh_candidates() -> void:
	var cost := TreasureService.refresh_cost(int(GameState.pending_treasure.get("refresh_index", 0)), TreasureService.has_set("money"))
	if GameState.gold < cost:
		return
	GameState.gold -= cost
	# 联机局：钱仍在本地扣（金币还没有权威账本，见 A5/P1），但候选必须由服务端重摇——
	# 本地摇出来的东西不在服务端 offer 里，选的时候会被 not_offered 拒收。
	if NetworkService.team_active:
		# 联机重摇要先确保 NetworkService 的宝物信号已连上宿主 —— 那是宿主的事。
		net_signals_needed.emit()
		NetworkService.request_treasure_refresh()
		SaveManager.save_run()
		state_changed.emit()
		return
	GameState.pending_treasure.refresh_index = int(GameState.pending_treasure.get("refresh_index", 0)) + 1
	GameState.pending_treasure.candidates = TreasureService.roll_candidates(3)
	SaveManager.save_run()
	state_changed.emit()



# 原 _build_treasure_overlay（PrepUI.gd）

func build_overlay() -> void:
	# Treasure draw: full-screen modal overlay (dim background + 3 big cards,
	# forced pick) centered over the prep screen. z_index keeps it above the board.
	_treasure_overlay = ColorRect.new()
	_treasure_overlay.color = Color(0.0, 0.0, 0.0, 0.66)
	_treasure_overlay.visible = false
	_treasure_overlay.z_index = 60
	_treasure_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_treasure_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Added to the screen root (self) so the dim + cards cover the ENTIRE screen,
	# not just the center column.
	host.add_child(_treasure_overlay)
	var treasure_box := VBoxContainer.new()
	treasure_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	treasure_box.alignment = BoxContainer.ALIGNMENT_CENTER
	treasure_box.add_theme_constant_override("separation", 16)
	_treasure_overlay.add_child(treasure_box)
	_treasure_timer_lbl = Label.new()
	_treasure_timer_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_treasure_timer_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_treasure_timer_lbl.add_theme_font_size_override("font_size", 24)
	_treasure_timer_lbl.add_theme_color_override("font_color", Color(1.0, 0.92, 0.66))
	_treasure_timer_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_treasure_timer_lbl.add_theme_constant_override("outline_size", 3)
	treasure_box.add_child(_treasure_timer_lbl)
	_treasure_choice_row = HBoxContainer.new()
	_treasure_choice_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_treasure_choice_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_treasure_choice_row.add_theme_constant_override("separation", 28)
	treasure_box.add_child(_treasure_choice_row)
	var treasure_refresh_holder := HBoxContainer.new()
	treasure_refresh_holder.alignment = BoxContainer.ALIGNMENT_CENTER
	treasure_refresh_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	treasure_box.add_child(treasure_refresh_holder)
	_treasure_refresh_btn = Button.new()
	_treasure_refresh_btn.custom_minimum_size = Vector2(220, 46)
	_treasure_refresh_btn.focus_mode = Control.FOCUS_NONE
	PrepWidgets.apply_refresh_button_styles(_treasure_refresh_btn)
	_treasure_refresh_btn.pressed.connect(_refresh_candidates)
	treasure_refresh_holder.add_child(_treasure_refresh_btn)



# 原 _build_treasure_logos_panel（PrepUI.gd）
func build_logos_panel() -> void:
	# Active treasure/linkage logos, pinned to the bottom-left corner of the screen.
	# Grows up-right so it can hold 8-9 icons (owned treasures + active linkages).
	# 宝藏 logo：只保留图标，不再加左下灰色底框。
	var tp_w := 303.0
	var tp_h := 161.0
	var treasure_panel := Control.new()
	treasure_panel.name = "TreasurePanel"
	treasure_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	treasure_panel.anchor_left = 0.0
	treasure_panel.anchor_top = 1.0
	treasure_panel.anchor_right = 0.0
	treasure_panel.anchor_bottom = 1.0
	treasure_panel.offset_left = 6
	treasure_panel.offset_right = 6 + tp_w
	treasure_panel.offset_top = -10 - tp_h
	treasure_panel.offset_bottom = -10
	treasure_panel.z_index = -5            # 河流(z-19)之上、石框(z0)之下：石框画在灰框上面，不被挡
	host.add_child(treasure_panel)
	# 宝藏 grid 左对齐（4 列 × 2 行横排，66px）。
	_owned_treasure_box = GridContainer.new()
	_owned_treasure_box.columns = 4
	_owned_treasure_box.anchor_left = 0.0
	_owned_treasure_box.anchor_top = 0.0
	_owned_treasure_box.anchor_right = 0.0
	_owned_treasure_box.anchor_bottom = 0.0
	_owned_treasure_box.offset_left = 0
	_owned_treasure_box.offset_top = 0
	_owned_treasure_box.grow_horizontal = Control.GROW_DIRECTION_END
	_owned_treasure_box.grow_vertical = Control.GROW_DIRECTION_END
	_owned_treasure_box.add_theme_constant_override("h_separation", 5)
	_owned_treasure_box.add_theme_constant_override("v_separation", 5)
	treasure_panel.add_child(_owned_treasure_box)



# 原 _show_treasure_detail（PrepShared.gd）

func show_detail(tid: String) -> void:
	pass



# 原 _treasure_category_name（PrepDetails.gd）

func category_name(category: String) -> String:
	if PrepWidgets.is_en():
		match category:
			"defense": return "Defense"
			"control": return "Control"
			"attack":  return "Attack"
			"money":   return "Money"
			"element": return "Element"
		return category
	match category:
		"defense": return "防御"
		"control": return "控制"
		"attack":  return "攻击"
		"money":   return "金钱"
		"element": return "元素"
	return category



# 原 _treasure_set_status（PrepDetails.gd）
func set_status(category: String) -> String:
	if category.is_empty() or not TreasureService.has_set(category):
		return ""
	var names: Array[String] = []
	for tid in GameState.owned_treasures:
		var t := TreasureService.treasure_by_id(str(tid))
		if str(t.get("category", "")) == category:
			names.append(PrepWidgets.localized_name(t))
	if PrepWidgets.is_en():
		return "Set: %s\nSet Bonus: %s" % [" + ".join(names), set_effect_text(category)]
	return "套装：%s\n套装效果：%s" % [" + ".join(names), set_effect_text(category)]



# 原 _treasure_linkage_status（PrepDetails.gd）
func linkage_status(tid: String) -> Array[String]:
	var lines: Array[String] = []
	var links: Array = DataRegistry.get_table("treasures").get("linkages", [])
	for link in links:
		var d: Dictionary = link
		var requires: Array = d.get("requires", [])
		if not requires.has(tid):
			continue
		var link_id := str(d.get("id", ""))
		if not TreasureService.has_linkage(link_id):
			continue
		var names: Array[String] = []
		for req in requires:
			var req_id := str(req)
			var req_t := TreasureService.treasure_by_id(req_id)
			names.append(PrepWidgets.localized_name(req_t))
		if PrepWidgets.is_en():
			lines.append("Synergy: %s\nSynergy Effect: %s" % [" + ".join(names), link_effect_text(link_id)])
		else:
			lines.append("联动：%s\n联动效果：%s" % [" + ".join(names), link_effect_text(link_id)])
	return lines



# 原 _treasure_set_effect_text（PrepDetails.gd）
func set_effect_text(category: String) -> String:
	if PrepWidgets.is_en():
		match category:
			"defense": return "4 Defense: Normal units gain HP/DEF +30% and Dodge +15% at battle start."
			"control": return "4 Control: Each debuff application randomly triggers one of: slow / ATK down / silence / stun / poison / disarm / bleed."
			"attack":  return "4 Attack: Normal units prioritize the lowest-HP enemy."
			"money":   return "4 Money: Shop refresh and treasure refresh are free."
			"element": return "4 Element: Normal units' attacks have a 20% chance to trigger an AoE (radius 180) elemental burst dealing 10% max HP true damage."
		return ""
	match category:
		"defense": return "4防御：普通棋子开战 HP/DEF +30%，闪避 +15%。"
		"control": return "4控制：每次触发负面效果，随机再触发减速/减攻/沉默/眩晕/中毒/缴械/失血之一。"
		"attack":  return "4攻击：普通棋子优先攻击当前低血敌人。"
		"money":   return "4金钱：商店刷新和宝藏刷新免费。"
		"element": return "4元素：普通棋子攻击 20% 概率触发 180 范围元素爆发，对范围敌人造成最大生命 10% 真实伤害。"
	return ""



# 原 _treasure_effect_text（PrepDetails.gd）
func effect_text(tid: String) -> String:
	if PrepWidgets.is_en():
		return effect_text_en(tid)
	match tid:
		"def_iron_wall":        return "开战时我方普通棋子 DEF +10。"
		"def_life_monument":    return "开战时我方普通棋子最大生命 +20%，当前生命同步提高；胡牌手激活后改为 +40%。"
		"def_formation_heal":   return "每次战后我方法阵 HP +1，不超过初始上限；胡牌手激活后改为 +2。"
		"def_soul_counter":     return "我方普通棋子死亡时，对击杀者造成其最大生命 35% 真实伤害。"
		"def_lifesteal_emblem": return "我方普通棋子造成伤害后，回复实际伤害 20% 的生命。"
		"def_phantom_step":     return "开战时我方普通棋子闪避 +20%。"
		"ctrl_shockwave":       return "我方普通棋子攻击时触发，对当前目标眩晕 1 秒，冷却 5 秒；胡牌手激活后眩晕 2 秒。"
		"ctrl_corrosive_needle":return "我方普通棋子每第 4 次攻击使目标失血，冷却 5 秒。"
		"ctrl_interrupt_chain": return "我方普通棋子攻击时 25% 概率缴械目标（1 秒内无法普攻），冷却 5 秒。"
		"ctrl_time_compress":   return "我方普通棋子技能冷却缩短 25%，首次与后续冷却均乘以 0.75。"
		"ctrl_binding_weight":  return "我方普通棋子攻击时使目标移动 -25%、攻速 -20%，持续 2 秒，冷却 5 秒。"
		"atk_blood_pact":       return "开战时我方普通棋子 ATK x1.25，但自身永久失血；胡牌手激活后改为 ATK x1.50。"
		"atk_fury_roster":      return "普通棋子上限从 7 提高到 8。"
		"atk_burst_core":       return "开战时我方普通棋子暴击率 +25%。"
		"atk_wail_resonance":   return "击杀敌人时，对死亡目标周围 180 范围敌人造成其最大生命 15% 真实伤害。"
		"atk_frenzy_assault":   return "攻击同一目标时自身攻速 x1.15，可叠；换目标重置。"
		"money_compound":       return "单件战后利息额外 +5% 当前金币。与雷霆加速联动后造成伤害有概率获得金币。"
		"money_generous_fate":  return "准备阶段每回合可手动参与 1 次赌博：50% 概率胜利使当前金币翻倍；50% 概率失败并损失当前金币的 80%。与幻影步伐联动后变为 60% 翻倍、40% 损失当前金币 50%。"
		"money_discount":       return "棋子商店价格 -20%；与狂怒阵容联动后变为 -40%。"
		"money_golden_altar":   return "准备阶段出现黄金祭坛按钮：-1 法阵 HP，+50 金，每回合最多 3 次，HP <=10 不可用。"
		"money_lucky_envelope": return "战后随机 +10~30 金；与时空压缩联动后额外随机 +50~70 金，10% 概率额外 +100 金。"
		"elem_flame_shatter":   return "攻击有 25% 概率额外造成 40% ATK 真实伤害；与吸血纹章联动后提高到 100%。"
		"elem_frost_blade":     return "攻击有 25% 概率使目标移动/攻速 -35%，持续 1.5 秒；与打断锁链联动后目标受伤 +15%。"
		"elem_thunder_haste":   return "攻击有 25% 概率使自身攻速 +60%，持续 3 秒，重复触发只刷新时间；与复利之道联动后造成伤害 10% 概率 +10 金。"
		"elem_toxic_spread":    return "攻击有 25% 概率使目标中毒；与爆裂核心联动后，造成伤害时中毒目标有 50% 概率提前结算剩余毒伤。"
	return "暂未写入详细说明。"



# 原 _treasure_effect_text_en（PrepDetails.gd）
func effect_text_en(tid: String) -> String:
	match tid:
		"def_iron_wall":        return "At battle start, friendly normal units gain DEF +10."
		"def_life_monument":    return "At battle start, friendly normal units gain max HP +20% (current HP increases too). With Hu Pai Master: +40%."
		"def_formation_heal":   return "After each battle, restore 1 Formation HP (up to the starting cap). With Hu Pai Master: +2."
		"def_soul_counter":     return "When a friendly normal unit dies, deal 35% of the killer's max HP as true damage."
		"def_lifesteal_emblem": return "Friendly normal units restore 20% of actual damage dealt as HP."
		"def_phantom_step":     return "At battle start, friendly normal units gain Dodge +20%."
		"ctrl_shockwave":       return "On attack, stun the current target for 1s (CD 5s). With Hu Pai Master: stun 2s."
		"ctrl_corrosive_needle":return "Every 4th attack causes the target to bleed (CD 5s)."
		"ctrl_interrupt_chain": return "25% chance to disarm the target on attack (cannot use normal attacks for 1s; CD 5s)."
		"ctrl_time_compress":   return "Friendly normal units' skill cooldowns are reduced by 25% (multiplied by 0.75)."
		"ctrl_binding_weight":  return "On attack, reduce target movement by 25% and AS by 20% for 2s (CD 5s)."
		"atk_blood_pact":       return "At battle start, friendly normal units gain ATK ×1.25 but permanently bleed. With Hu Pai Master: ATK ×1.50."
		"atk_fury_roster":      return "Normal unit board limit increased from 7 to 8."
		"atk_burst_core":       return "At battle start, friendly normal units gain Crit +25%."
		"atk_wail_resonance":   return "On kill, deal 15% of the target's max HP as true damage to all enemies within radius 180."
		"atk_frenzy_assault":   return "Attacking the same target stacks own AS ×1.15 (stackable); resets on target switch."
		"money_compound":       return "After battle, gain bonus interest equal to +5% of current gold. Synergy with Thunder Haste: chance to earn 1G on damage."
		"money_generous_fate":  return "Once per prep phase, gamble: 50% chance to double current gold; 50% chance to lose 80% of current gold. Synergy with Phantom Step: becomes 60%/40% with 50% loss."
		"money_discount":       return "Shop unit prices -20%. Synergy with Fury Roster: -40%."
		"money_golden_altar":   return "Adds a Golden Altar button during prep: spend 1 Formation HP to gain +50G (max 3 times per round; unavailable at HP ≤10)."
		"money_lucky_envelope": return "After battle, gain a random +10~30G. Synergy with Time Compress: +50~70G extra, with 10% chance of +100G."
		"elem_flame_shatter":   return "25% chance on attack to deal extra 40% ATK true damage. Synergy with Lifesteal Emblem: increases to 100%."
		"elem_frost_blade":     return "25% chance on attack to reduce target movement and AS by 35% for 1.5s. Synergy with Interrupt Chain: target takes +15% damage."
		"elem_thunder_haste":   return "25% chance on attack to grant own AS +60% for 3s (refreshes on re-trigger). Synergy with Compound Interest: 10% chance to gain +10G on damage."
		"elem_toxic_spread":    return "25% chance on attack to poison the target. Synergy with Burst Core: 50% chance to instantly resolve remaining poison damage."
	return "Description not yet available."



# 原 _treasure_link_effect_text（PrepDetails.gd）
func link_effect_text(link_id: String) -> String:
	if PrepWidgets.is_en():
		match link_id:
			"link_phoenix":           return "Friendly normal units revive at full HP with invulnerability for 3s after dying, then die for real."
			"link_money_magic":       return "After battle, gain an extra random +50~70G, with a 10% chance of +100G."
			"link_blood_covenant":    return "Flame Shatter true damage increases from 40% ATK to 100% ATK."
			"link_paralysis_shackles":return "On successful disarm, also apply ice effect; ice-affected targets take +15% damage."
			"link_oppression_counter":return "When a friendly normal unit is hit, apply ATK -20% to the attacker for 2s; also stacks Frenzy Assault AS logic on them."
			"link_fraud_fate":        return "Generous Fate becomes: 60% chance to double gold, 40% chance to lose 50% of gold."
			"link_iron_maiden":       return "When a friendly normal unit is hit, inflict bleed and armor break on the attacker (CD 5s)."
			"link_toxic_burst":       return "On dealing damage, 50% chance to instantly resolve remaining poison on poisoned targets."
			"link_rich_path":         return "10% chance to gain +10G on dealing damage."
			"link_clearance_sale":    return "Auto-activates when Fury Roster + Discount Token are both owned: shop prices -40%."
			"link_hu_pai_master":     return "Activates when Life Monument + Formation Heal + Shockwave + Blood Pact + Fury Roster are all owned: doubles the positive values of the first four treasures, and Fury Roster's unit cap gains +1 more (7 -> 9); cooldowns, chances, and costs unchanged."
		return "Synergy description not yet available."
	match link_id:
		"link_phoenix":           return "我方普通棋子死亡后满血复活并获得无敌，持续 3 秒，之后强制真死。"
		"link_money_magic":       return "战后额外随机 +50~70 金，10% 概率额外 +100 金。"
		"link_blood_covenant":    return "炎焰碎裂触发时，真实伤害从 ATK 40% 提高到 ATK 100%。"
		"link_paralysis_shackles":return "缴械成功后额外触发冰效果，被冰影响目标受伤 +15%。"
		"link_oppression_counter":return "我方普通棋子被攻击时，对攻击者施加减攻 20%，持续 2 秒；攻击者也会被叠加狂暴进攻攻速逻辑。"
		"link_fraud_fate":        return "慷慨命运变为每回合手动赌博 1 次：60% 金币翻倍，40% 损失当前金币 50%。"
		"link_iron_maiden":       return "我方普通棋子受击时反施失血和破甲，冷却 5 秒。"
		"link_toxic_burst":       return "造成伤害时，中毒目标有 50% 概率提前结算剩余毒伤。"
		"link_rich_path":         return "造成伤害后 10% 概率 +10 金。"
		"link_clearance_sale":    return "狂怒阵容与折扣令牌同时拥有时自动激活，棋子商店价格 -40%。"
		"link_hu_pai_master":     return "生命丰碑、法阵回春、震荡余波、血契之刃、狂怒阵容同时拥有时激活：前四件宝藏的正面数值翻倍，狂怒阵容棋子上限再 +1（7→9）；冷却、概率、次数和负面代价不变。"
	return "联动效果待说明。"

