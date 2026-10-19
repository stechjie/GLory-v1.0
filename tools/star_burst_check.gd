extends Node

# 萝卜营地入口的「有升级石 / 能升 4★」两级提示。
#
# ## 这个门禁守过的两版口径
#
# 旧（10.11 第 8 条）：营地入口与三格石头在「存在升级石」时散发柔和星爆。
# 实现是 ui/components/StarBurst.gd，入口那颗调成冰蓝白、`radius_scale 1.3`。
#
# 新（10.18，Leno 推翻了上一版）：那 10 根星芒压在橙色徽章**上面**，看着像贴纸 /
# 镜头光斑，冷暖还打架。改成两级提示：
#   · 一级 = 队伍有任意一颗升级石（或 13 回合营地模式下还能免费抽一次）。
#     按钮**背后**一圈柔和暖同色呼吸光（ui/components/CampEntryGlow.gd）
#     + 右上角「石头图标 + 数量」小角标。
#   · 二级 = 真有一枚三星棋子现在就能升 4★。光转金、更亮，角标换成「4★」；
#     **从不满足变满足的那一刻**弹一下 + 一声提示音，之后安静呼吸。
#   · 营地面板里三格石头的星爆去掉，改成「有存货时图标与数字变亮」。
#
# 门禁名沿用 `star_burst` —— 守的是同一处提示，只是换了形态；改名会让历史记录断掉。
#
# ## 判据分两层（缺哪层都有盲区）
#
#   · **行为** —— 真例化备战界面、喂一份**真有石头**的服务端状态（以及一枚真能升
#     4★ 的棋子），断言光环与角标的 visible / 文案 / 颜色跟着等级走。
#     只断言「节点建出来了」证明不了它会不会亮 —— 那正是「定义 ≠ 已接线」的老坑。
#   · **结构** —— 光层必须是**纯 `_draw()`** 组件（不碰 `StyleBoxFlat.new()` /
#     `Button.new()`）：本仓有 procedural_ui_ratchet 棘轮，用 StyleBox 实现这层光会
#     把棘轮顶红（同 ui/components/SoftEdgeGlow.gd 的先例）。
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/star_burst_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const CampEntryGlowScript := preload("res://ui/components/CampEntryGlow.gd")

const CHECK_NAME := "star_burst"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_component_contract()
	_case_breathing()
	_case_pulse()
	_case_structure()
	await _case_entry_levels()
	_h.finish(get_tree())


func _case_component_contract() -> void:
	var glow: Control = CampEntryGlowScript.new()
	add_child(glow)
	glow.size = Vector2(132, 132)
	_h.expect(glow.mouse_filter == Control.MOUSE_FILTER_IGNORE, "glow_ignores_mouse",
		"光层必须不吃输入 —— 否则会挡掉它下面按钮的点击")
	# 不可见时不推进相位（挂着 = 零成本，除非真的亮着）。
	glow.visible = false
	var before := float(glow.get("_phase"))
	glow.call("_process", 0.5)
	_h.expect(is_equal_approx(float(glow.get("_phase")), before), "glow_idle_when_hidden",
		"光层不可见时不该推进呼吸相位（白跑 `_process`）")
	glow.visible = true
	glow.call("_process", 0.5)
	_h.expect(not is_equal_approx(float(glow.get("_phase")), before), "glow_advances_when_shown",
		"光层可见时应当推进呼吸相位")
	glow.queue_free()


# 「柔和呼吸」：亮度要随相位起伏，而且最暗也不归零（不是闪烁）。
func _case_breathing() -> void:
	var glow = CampEntryGlowScript.new()
	glow.set("_phase", PI * 0.5)
	var bright: float = glow.call("_breath")
	glow.set("_phase", 0.0)
	var mid: float = glow.call("_breath")
	glow.set("_phase", PI * 1.5)
	var dim: float = glow.call("_breath")
	_h.expect(bright > mid and mid > dim, "breath_varies",
		"呼吸亮度应随相位起伏，实测 亮 %.3f / 中 %.3f / 暗 %.3f" % [bright, mid, dim])
	_h.expect(dim > 0.0, "breath_never_zero",
		"呼吸最暗时也不该归零（要「柔和」，不是闪烁），实测 %.3f" % dim)
	_h.expect(float(glow.get("BREATH_PERIOD_SEC")) >= 3.0, "breath_is_slow",
		"呼吸必须是慢的（周期 ≥ 3 秒），实测 %s" % str(glow.get("BREATH_PERIOD_SEC")))
	glow.free()


# 「弹一下」必须是**一次性**的：起跳后随时间衰减回 0，不能变成常亮或持续闪。
func _case_pulse() -> void:
	var glow = CampEntryGlowScript.new()
	glow.visible = true
	glow.call("pulse")
	var peak := float(glow.get("_pulse"))
	_h.expect(peak > 0.0, "pulse_starts", "pulse() 之后弹跳量应 > 0，实测 %.3f" % peak)
	glow.call("_process", float(glow.get("PULSE_SEC")) * 0.5)
	var mid := float(glow.get("_pulse"))
	_h.expect(mid < peak and mid > 0.0, "pulse_decays",
		"弹跳量应随时间衰减，实测 起 %.3f -> 中 %.3f" % [peak, mid])
	glow.call("_process", float(glow.get("PULSE_SEC")) * 2.0)
	_h.expect(is_zero_approx(float(glow.get("_pulse"))), "pulse_ends",
		"弹跳必须归零（一次性，不是常亮），实测 %.3f" % float(glow.get("_pulse")))
	glow.free()


func _case_structure() -> void:
	var src := _strip_comments(FileAccess.get_file_as_string("res://ui/components/CampEntryGlow.gd"))
	if not _h.expect(not src.is_empty(), "glow_src", "读不到 CampEntryGlow.gd"):
		return
	_h.expect(src.contains("func _draw()"), "glow_draws", "光层必须自己 _draw()")
	_h.expect(not src.contains("StyleBoxFlat.new()"), "glow_no_stylebox",
		"光层不得用 StyleBoxFlat.new() —— 会被 procedural_ui_ratchet 顶红")
	_h.expect(not src.contains("Button.new()"), "glow_no_button", "光层不得建 Button")
	_h.expect(src.contains("func pulse()"), "glow_has_pulse",
		"光层必须提供 pulse() —— 二级提示「从不满足变满足那一刻弹一下」靠它")

	var prep := _strip_comments(FileAccess.get_file_as_string("res://scenes/prep/PrepUI.gd"))
	_h.expect(prep.contains("CampEntryGlowScript") and prep.contains("_carrot_entry_glow"),
		"entry_uses_glow", "营地入口按钮必须挂呼吸光层")
	# ★ 旧星爆必须真的摘掉，而不是留在那里和新光层叠着亮。
	_h.expect(not prep.contains("_carrot_button_burst"), "entry_old_burst_removed",
		"入口的旧星爆（_carrot_button_burst）必须摘掉 —— 10.18 Leno 推翻了那一版")
	# ★ 「背后」是这次改动的核心：子节点按树序绘制，排在徽章贴图后面就是压在图上，
	#   排到 0 号位才是背后。少这一行，改了等于没改。
	_h.expect(prep.contains("carrot_btn.move_child(carrot_glow, 0)"), "entry_glow_behind_badge",
		"光层必须 move_child 到 0 号位（徽章**背后**）—— 否则又变回「压在橙色徽章上面」")
	# ★ 光挂上去不够：Button 不是 Container，子 Control 不自己铺满 ⇒ size 停在 (0,0)，
	#   `_draw()` 里 peak<=1 直接 return。这一行是「真的会被画出来」的接线判据。
	_h.expect(prep.contains("carrot_glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)"),
		"entry_glow_sized",
		"光层必须显式铺满按钮（set_anchors_and_offsets_preset）—— 否则 size=(0,0)，一个像素都画不出来")
	# ★ 二级判据必须复用 GameState.four_star_check —— 和棋盘上那圈金色「可升」光环
	#   （PrepBoardModels._sync_four_star_actor state==1）同一口径。两处不同口径的话，
	#   棋盘亮了入口不亮（或反过来）才是最糟的提示。
	_h.expect(prep.contains("func _any_four_star_ready()"), "entry_level2_helper",
		"二级提示必须有独立判据函数 _any_four_star_ready()")
	_h.expect(prep.contains("GameState.four_star_check(cell).get(\"ok\"")
		or prep.contains("GameState.four_star_check(cell)"), "entry_level2_same_rule",
		"二级判据必须走 GameState.four_star_check —— 与棋盘金色光环同口径")
	_h.expect(prep.contains("_carrot_entry_glow.call(\"pulse\")"), "entry_pulse_wired",
		"「从不满足变满足」那一刻必须真的调 pulse() —— 只声明不调 = 屏幕上看不出来")
	_h.expect(prep.contains("SfxService.play("), "entry_cue_wired",
		"二级提示转亮那一刻必须出一声 —— Leno 口径「弹一下 + 一声提示音」")

	# 营地面板里三格石头的星爆去掉，改成「有存货时图标与数字变亮」。
	var camp := _strip_comments(FileAccess.get_file_as_string("res://scenes/prep/CarrotCampPanelV3.gd"))
	_h.expect(not camp.contains("StarBurstScript"), "camp_bursts_removed",
		"营地面板三格石头的星爆必须去掉（10.18 口径）")
	_h.expect(camp.contains("_stone_icons") and camp.contains("has_stock"),
		"camp_brightness_rule",
		"三格石头改成「有存货（has_stock）时图标与数字变亮」")


# 结构断言**必须先剥注释**：注释里提到某个 token 会让肯定式 `contains` 变假绿、
# 否定式 `not contains` 变假红（10.11 就在 StarBurst.gd 的说明注释上踩到 ——
# 注释写着「不得用 StyleBoxFlat.new()」，结果 `not src.contains("StyleBoxFlat.new()")`
# 被自己的注释判成了红）。同先例：tools/room_invite_check.gd 的 _has_live_code。
func _strip_comments(source: String) -> String:
	var out: PackedStringArray = []
	for raw in source.split("\n"):
		var line := str(raw)
		var hash_at := line.find("#")
		if hash_at >= 0:
			line = line.substr(0, hash_at)
		out.append(line)
	return "\n".join(out)


func _case_entry_levels() -> void:
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "prep_scene_load", "PrepScreen.tscn 无法加载"):
		return
	var was_active := NetworkService.team_active
	var was_host := NetworkService.is_host
	GameState.reset_run()
	NetworkService.team_active = true
	NetworkService.is_host = true
	var screen: Node = packed.instantiate()
	add_child(screen)
	await get_tree().process_frame

	# ① 没有石头、也没有能升 4★ 的棋子 ⇒ 零级：光与角标都不该出现。
	_apply_stones({"sky": 0, "land": 0, "ren": 0})
	screen.call("_refresh_carrot_counter")
	await get_tree().process_frame
	_assert_level(screen, 0, "zero")
	_assert_hidden(screen, "zero")

	# ② 天 1 / 人 2 ⇒ 一级：暖同色呼吸光 + 角标显示总数 3，石头图标在。
	_apply_stones({"sky": 1, "land": 0, "ren": 2})
	screen.call("_refresh_carrot_counter")
	await get_tree().process_frame
	_assert_level(screen, 1, "stones")
	var glow = screen.get("_carrot_entry_glow")
	_assert_drawable(glow, "level1")
	var warm: Color = glow.get("glow_color")
	# 「同色系」= 跟暖橙徽章一路；上一版那颗冰蓝白（B 远高于 R）正是被推翻的那个。
	_h.expect(warm.r > warm.b + 0.15, "level1_warm",
		"一级光色 %s 偏冷 —— 10.18 口径是「同色系柔和光」，不是上一版的冰蓝白" % str(warm))
	var level1_alpha := float(glow.get("base_alpha"))
	_assert_badge(screen, "3", true, "level1")

	# ③ 放一枚真能升 4★ 的三星棋子 ⇒ 二级：光转金且更亮，角标变「4★」、图标让位，
	#    并且从一级跨到二级的那一刻弹了一下。
	GameState.gold = 2000
	GameState.board_slots[0] = {
		"uid": "star_burst_check_unit",
		"star": GameState.MAX_MERGE_STAR,
		"def": {"id": "star_burst_check_unit", "element": "sky", "tier": 1},
	}
	screen.call("_refresh_carrot_counter")
	await get_tree().process_frame
	_assert_level(screen, 2, "ready")
	var gold_color: Color = glow.get("glow_color")
	_h.expect(float(glow.get("base_alpha")) > level1_alpha, "level2_brighter",
		"二级必须比一级更亮，实测 一级 %.2f / 二级 %.2f" % [level1_alpha, float(glow.get("base_alpha"))])
	_h.expect(gold_color.r > 0.85 and gold_color.g > 0.75 and gold_color.b < gold_color.g - 0.2,
		"level2_gold", "二级光色应转金，实测 %s" % str(gold_color))
	_h.expect(float(glow.get("_pulse")) > 0.0, "level2_pulsed",
		"从一级跨到二级的那一刻必须弹一下，实测 _pulse=%.3f" % float(glow.get("_pulse")))
	_assert_badge(screen, "4★", false, "level2")

	# ④ 收掉棋子与石头 ⇒ 必须重新回到零级（不能只亮不灭）。
	GameState.board_slots[0] = null
	_apply_stones({"sky": 0, "land": 0, "ren": 0})
	screen.call("_refresh_carrot_counter")
	await get_tree().process_frame
	_assert_level(screen, 0, "cleared")
	_assert_hidden(screen, "cleared")

	_teardown(screen, was_active, was_host)


func _apply_stones(stones: Dictionary) -> void:
	NetworkService._apply_carrot_state({
		"carrot_authoritative": true,
		"carrots": 0,
		"harvest_tech_level": 0,
		"merc_carrots_spent_total": 0,
		"last_harvest_round": GameState.round_index,
		"last_harvest_gain": 0,
		"stone_draw_used_round": -1,
		"team_upgrade_stones": stones.duplicate(),
	})


func _assert_level(screen: Node, want: int, tag: String) -> void:
	var level := int(screen.get("_carrot_entry_level"))
	_h.expect(level == want, "level_%s" % tag,
		"入口提示等级应为 %d，实测 %d" % [want, level])


func _assert_hidden(screen: Node, tag: String) -> void:
	for field in ["_carrot_entry_glow", "_carrot_entry_badge"]:
		var node = screen.get(field)
		var shown := node != null and is_instance_valid(node) and bool(node.visible)
		_h.expect(not shown, "hidden_%s_%s" % [tag, field.substr(14)],
			"零级时 %s 不该可见" % field)


# ★ 只验 `visible` 会漏掉「挂上了、也 visible，但 size 还是 (0,0)」—— 本仓的
#   「存在 ≠ 被正确赋值」老坑：**Button 不是 Container**，挂上去的子 Control 尺寸不会
#   自己跟上来，于是 _draw() 里 peak<=1 直接 return，屏幕上什么都看不到。
#   10.11 实测踩到：营地入口那层光从头到尾一个像素都没画过，而 visible 一直是真的。
func _assert_drawable(node, tag: String) -> void:
	var shown := node != null and is_instance_valid(node) and bool(node.visible)
	if not _h.expect(shown, "%s_glow_visible" % tag, "该亮的时候光层必须可见"):
		return
	var sz: Vector2 = node.size
	_h.expect(sz.x > 1.0 and sz.y > 1.0, "%s_glow_size" % tag,
		"光层 visible=true 但 size=%s —— _draw() 会因 peak<=1 直接 return，画不出东西" % str(sz))


func _assert_badge(screen: Node, want_text: String, want_icon: bool, tag: String) -> void:
	var badge = screen.get("_carrot_entry_badge")
	_h.expect(badge != null and is_instance_valid(badge) and bool(badge.visible),
		"%s_badge_visible" % tag, "有提示时右上角角标必须可见")
	var label = screen.get("_carrot_entry_badge_label")
	var text := str(label.text) if label != null and is_instance_valid(label) else ""
	_h.expect(text == want_text, "%s_badge_text" % tag,
		"角标文案应为 %s，实测 %s" % [want_text, text])
	var icon = screen.get("_carrot_entry_badge_icon")
	var icon_shown := icon != null and is_instance_valid(icon) and bool(icon.visible)
	_h.expect(icon_shown == want_icon, "%s_badge_icon" % tag,
		"角标石头图标可见性应为 %s，实测 %s" % [str(want_icon), str(icon_shown)])


func _teardown(screen: Node, was_active: bool, was_host: bool) -> void:
	NetworkService.team_active = was_active
	NetworkService.is_host = was_host
	if screen != null and is_instance_valid(screen):
		screen.queue_free()
