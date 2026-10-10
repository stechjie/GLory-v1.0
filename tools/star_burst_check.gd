extends Node

# 10.11 第 8 条：萝卜营地「存在升级石」时的柔和星爆提醒。
#
# 需求原话：萝卜营地里**存在升级石**时，营地 UI 与对应的天 / 地 / 人升级石要
# 「散发柔和星爆（由内向外衰减发射星芒）」，可加极慢呼吸明暗，符合游戏风格。
#
# ## 判据分两层（缺哪层都有盲区）
#
#   · **行为** —— 真例化备战界面、真开营地、喂一份**真有石头**的服务端状态，
#     断言每一格石头以及营地入口按钮的星爆层 `visible` 与「这一格有没有存货」一致。
#     只断言「节点建出来了」证明不了它会不会亮 —— 那正是「定义 ≠ 已接线」的老坑。
#   · **结构** —— 星爆层必须是**纯 `_draw()`** 组件（不碰 `StyleBoxFlat.new()` /
#     `Button.new()`）：本仓有 procedural_ui_ratchet 棘轮，用 StyleBox 实现这层光会
#     把棘轮顶红（同 ui/components/SoftEdgeGlow.gd 的先例）。
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/star_burst_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const StarBurstScript := preload("res://ui/components/StarBurst.gd")

const CHECK_NAME := "star_burst"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_component_contract()
	_case_breathing()
	_case_structure()
	await _case_panel_visibility()
	_h.finish(get_tree())


func _case_component_contract() -> void:
	var burst: Control = StarBurstScript.new()
	add_child(burst)
	burst.size = Vector2(116, 150)
	_h.expect(burst.mouse_filter == Control.MOUSE_FILTER_IGNORE, "burst_ignores_mouse",
		"星爆层必须不吃输入 —— 否则会挡掉它下面按钮的点击")
	_h.expect(burst is Control, "burst_is_control", "星爆层应当是 Control")
	# 不可见时不推进相位（挂着 = 零成本，除非真的亮着）。
	burst.visible = false
	var before := float(burst.get("_phase"))
	burst.call("_process", 0.5)
	_h.expect(is_equal_approx(float(burst.get("_phase")), before), "burst_idle_when_hidden",
		"星爆不可见时不该推进呼吸相位（白跑 `_process`）")
	burst.visible = true
	burst.call("_process", 0.5)
	_h.expect(not is_equal_approx(float(burst.get("_phase")), before), "burst_advances_when_shown",
		"星爆可见时应当推进呼吸相位")
	burst.queue_free()


# 需求「可加极慢呼吸明暗」：亮度要随相位起伏，而且最暗也不归零（不是闪烁）。
func _case_breathing() -> void:
	var burst = StarBurstScript.new()
	burst.set("_phase", PI * 0.5)
	var bright: float = burst.call("_breath")
	burst.set("_phase", 0.0)
	var mid: float = burst.call("_breath")
	burst.set("_phase", PI * 1.5)
	var dim: float = burst.call("_breath")
	_h.expect(bright > mid and mid > dim, "breath_varies",
		"呼吸亮度应随相位起伏，实测 亮 %.3f / 中 %.3f / 暗 %.3f" % [bright, mid, dim])
	_h.expect(dim > 0.0, "breath_never_zero",
		"呼吸最暗时也不该归零（要「柔和但引人注目」，不是闪烁），实测 %.3f" % dim)
	_h.expect(is_equal_approx(float(burst.get("BREATH_PERIOD_SEC")), 5.0), "breath_is_slow",
		"呼吸必须是极慢的（周期 5 秒），实测 %s" % str(burst.get("BREATH_PERIOD_SEC")))
	burst.free()


func _case_structure() -> void:
	var src := _strip_comments(FileAccess.get_file_as_string("res://ui/components/StarBurst.gd"))
	if not _h.expect(not src.is_empty(), "starburst_src", "读不到 StarBurst.gd"):
		return
	_h.expect(src.contains("func _draw()"), "starburst_draws", "星爆必须自己 _draw()")
	_h.expect(not src.contains("StyleBoxFlat.new()"), "starburst_no_stylebox",
		"星爆不得用 StyleBoxFlat.new() —— 会被 procedural_ui_ratchet 顶红")
	_h.expect(not src.contains("Button.new()"), "starburst_no_button", "星爆不得建 Button")
	# 星芒起点：既要有 `ray_start`（= 半径 × inner_ratio），又要真的被用来起画。
	# 用户 10.11 最终口径是「从图标中心向外散发」⇒ 入口按钮**不传** inner（= 0.0，圆心起画），
	# 所以这里只钉「起点这条通道接上了」；具体取值由下面的行为层 _assert_drawable 量真实例。
	_h.expect(src.contains("var ray_start := radius * clampf(inner_ratio"), "starburst_inner_ratio",
		"星爆必须有 ray_start（= 半径 × inner_ratio）作为星芒起点")
	_h.expect(src.contains("lerpf(ray_start, length, "), "starburst_rays_from_ray_start",
		"星芒必须从 ray_start 起画到 length —— 起点没接进 lerpf 的话 inner_ratio 就是个死旋钮")
	# 「明暗交替」的落点：短芒增益必须真的乘进 alpha。只声明不乘 = 白写（本轮踩过的
	# 「定义 ≠ 已接线」）。
	_h.expect(src.contains("var ray_gain := 1.0 if is_long else short_ray_alpha"),
		"starburst_ray_gain", "短芒必须有独立亮度增益（明暗交替的开关）")
	_h.expect(src.contains("* ray_gain"), "starburst_ray_gain_applied",
		"短芒增益必须真乘进 ray.a —— 否则「明暗交替」只是声明，屏幕上看不出来")
	# 三格石头与营地入口按钮都要真的引用它（否则「定义 ≠ 已接线」）。
	var camp := _strip_comments(FileAccess.get_file_as_string("res://scenes/prep/CarrotCampPanelV3.gd"))
	_h.expect(camp.contains("StarBurstScript") and camp.contains("_stone_bursts"),
		"camp_uses_starburst", "萝卜营地必须给每格石头挂星爆层")
	_h.expect(camp.contains("burst.visible = count > 0"), "camp_visibility_rule",
		"每格星爆的开关必须是「这一格有存货」（count > 0）")
	var prep := _strip_comments(FileAccess.get_file_as_string("res://scenes/prep/PrepUI.gd"))
	_h.expect(prep.contains("StarBurstScript") and prep.contains("_carrot_button_burst"),
		"entry_uses_starburst", "营地入口按钮必须挂星爆层")
	_h.expect(prep.contains("stone_total > 0"), "entry_visibility_rule",
		"入口星爆的开关必须是「队伍里任意一颗升级石」（stone_total > 0）")
	# ★ 光挂上去不够：Button 不是 Container，子 Control 不自己铺满 ⇒ size 停在 (0,0)，
	#   `_draw()` 里 radius<=1 直接 return。这一行是「真的会被画出来」的接线判据。
	_h.expect(prep.contains("carrot_burst.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)"),
		"entry_burst_sized",
		"入口星爆必须显式铺满按钮（set_anchors_and_offsets_preset）—— 否则 size=(0,0)，一个像素都画不出来")
	# 入口按钮的最终风格（10.11 用户口径）全部只在**调用方**传参 —— 组件默认值保持第一版，
	# 石头格才不会被连带改掉。这两条钉住「调用方真的传了」。
	_h.expect(prep.contains("carrot_burst.short_ray_alpha = "), "entry_alternating_wired",
		"入口星爆必须显式设 short_ray_alpha（明暗交替星爆）")
	_h.expect(prep.contains("carrot_burst.ray_width_scale = "), "entry_ray_width_wired",
		"入口星爆必须显式设 ray_width_scale（半径放大后要加粗）")


# 结构断言**必须先剥注释**：注释里提到某个 token 会让肯定式 `contains` 变假绿、
# 否定式 `not contains` 变假红（本轮就在 StarBurst.gd 的说明注释上踩到 ——
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


func _case_panel_visibility() -> void:
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "prep_scene_load", "PrepScreen.tscn 无法加载"):
		return
	var was_active := NetworkService.team_active
	var was_host := NetworkService.is_host
	GameState.reset_run()
	NetworkService.team_active = true
	NetworkService.is_host = false
	var screen: Node = packed.instantiate()
	add_child(screen)
	await get_tree().process_frame

	var panel = screen.get("_carrot_panel")
	if not _h.expect(panel != null and is_instance_valid(panel), "panel_missing", "没有萝卜营地面板"):
		_teardown(screen, was_active, was_host)
		return
	screen.call("_toggle_carrot_camp")
	await get_tree().process_frame
	# 切到「升级石」页：左侧石头栏只在 `_current_page == 1` 时可见。不切过去，
	# 它的布局就不会真跑，下面那条「尺寸必须 > 1」会量到 0 —— 那是假红，不是缺陷。
	panel.call("_show_page", 1)
	await get_tree().process_frame

	# ① 全 0：一格都不该亮。
	_apply_stones({"sky": 0, "land": 0, "ren": 0})
	_refresh(screen, panel)
	await get_tree().process_frame
	_assert_bursts(panel, screen, {"sky": false, "land": false, "ren": false}, false, "zero")

	# ② 天 1 / 地 0 / 人 2：亮的恰好是「有存货」的那两格 + 入口按钮。
	_apply_stones({"sky": 1, "land": 0, "ren": 2})
	_refresh(screen, panel)
	await get_tree().process_frame
	_assert_bursts(panel, screen, {"sky": true, "land": false, "ren": true}, true, "mixed")

	# ③ 回到全 0：必须重新灭掉（不能只亮不灭）。
	_apply_stones({"sky": 0, "land": 0, "ren": 0})
	_refresh(screen, panel)
	await get_tree().process_frame
	_assert_bursts(panel, screen, {"sky": false, "land": false, "ren": false}, false, "cleared")

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


func _refresh(screen: Node, panel) -> void:
	if panel != null and is_instance_valid(panel):
		panel.call("refresh")
	if screen != null and is_instance_valid(screen):
		screen.call("_refresh_carrot_counter")


func _assert_bursts(panel, screen, want: Dictionary, want_entry: bool, tag: String) -> void:
	var bursts: Dictionary = panel.get("_stone_bursts")
	_h.expect(bursts.size() == 3, "bursts_%s_count" % tag,
		"应有 3 格星爆层（天 / 地 / 人），实测 %d" % bursts.size())
	for stone_type in ["sky", "land", "ren"]:
		var burst = bursts.get(stone_type)
		var visible := burst != null and is_instance_valid(burst) and bool(burst.visible)
		_h.expect(visible == bool(want[stone_type]), "burst_%s_%s" % [tag, stone_type],
			"%s 格星爆可见性应为 %s，实测 %s" % [stone_type, str(want[stone_type]), str(visible)])
		if visible:
			# 石头格：用户 10.11 明确「只让你改萝卜营地这个 UI，没让你改天 / 地 / 人升级石」
			# ⇒ 这里反过来钉住它们**保持第一版参数**，只验证「真的画得出来」。
			_assert_drawable(burst, "burst_%s_%s_size" % [tag, stone_type], "%s 格" % stone_type, false)
	var entry = screen.get("_carrot_button_burst")
	var entry_visible := entry != null and is_instance_valid(entry) and bool(entry.visible)
	_h.expect(entry_visible == want_entry, "burst_%s_entry" % tag,
		"营地入口按钮星爆可见性应为 %s，实测 %s" % [str(want_entry), str(entry_visible)])
	if entry_visible:
		_assert_drawable(entry, "burst_%s_entry_size" % tag, "营地入口按钮", true)
		_assert_entry_style(entry, tag)


# ★ 只验 `visible` 会漏掉「挂上了、也 visible，但 size 还是 (0,0)」—— 本仓的
#   「存在 ≠ 被正确赋值」老坑：**Button 不是 Container**，挂上去的子 Control 尺寸不会
#   自己跟上来，于是 StarBurst._draw() 里 `radius <= 1.0` 直接 return，屏幕上什么都看不到。
#   10.11 实测踩到：营地入口那颗星爆从头到尾一个像素都没画过，而 visible 一直是真的。
func _assert_drawable(node, key: String, what: String, poke_out: bool) -> void:
	var sz: Vector2 = node.size
	_h.expect(sz.x > 1.0 and sz.y > 1.0, key,
		"%s星爆 visible=true 但 size=%s —— _draw() 会因 radius<=1 直接 return，画不出东西" % [what, str(sz)])
	var scale := float(node.get("radius_scale"))
	var inner := float(node.get("inner_ratio"))
	if poke_out:
		# 入口按钮：控件方框**就是整枚徽章**（132×132 里那枚 512² 图标，实测不透明像素
		# 半径 ≈ 65 / 66px）⇒ 系数 ≤1 时星芒末端正好停在图标边缘，看着只是「压在图标上」。
		# 必须 > 1 才射得到外面；同时要有上限 —— 用户口径是「向外一点」，> 2 会变成一大团
		# 光糊住旁边两枚佣兵按钮。
		_h.expect(scale > 1.15 and scale < 2.0, "%s_scale" % key,
			"%s星爆 radius_scale=%s —— 应 > 1.15（探出图标）且 < 2.0（只是「外面一点」，别糊住邻居）" % [what, str(scale)])
		# 「从图标中心向外散发」⇒ 起点就在圆心（inner_ratio = 0）。传 > 0 会变成
		# 「从图标边缘起画」，那是上一版口径、已被用户推翻。
		_h.expect(inner <= 0.05, "%s_inner" % key,
			"%s星爆 inner_ratio=%s —— 用户 10.11 口径是「从图标中心向外散发」，应为 0" % [what, str(inner)])
	else:
		# 石头格：用户 10.11 明确「只改萝卜营地入口，天 / 地 / 人三格不动」⇒ 反过来钉住
		# 它们仍是第一版参数。谁手滑把这里也放大 / 改成从边缘起画，这两条立刻红。
		_h.expect(is_equal_approx(scale, 1.0), "%s_scale" % key,
			"%s星爆 radius_scale=%s —— 石头格必须保持第一版 1.0（用户口径：三格不动）" % [what, str(scale)])
		_h.expect(inner <= 0.05, "%s_inner" % key,
			"%s星爆 inner_ratio=%s —— 石头格必须保持第一版 0.0（从圆心起画）" % [what, str(inner)])


# 入口按钮「显眼」三件套 —— 量**真实例上的值**，不是 grep 源码。
# 值写错（比如把 0.4 写成 4.0、颜色又写回暖金）源码里 token 一个不少，只有量值才抓得住。
func _assert_entry_style(entry, tag: String) -> void:
	# ① 明暗交替：短芒必须被压暗（< 1），但不能压到看不见（> 0.15）。
	var short_a := float(entry.get("short_ray_alpha"))
	_h.expect(short_a < 1.0 and short_a > 0.15, "entry_%s_alternating" % tag,
		"入口星爆 short_ray_alpha=%s —— 须 < 1（长芒亮 / 短芒暗 = 明暗交替）且 > 0.15（别压没）" % str(short_a))
	# ② 芒宽：半径放大后细芒会显脏，必须加粗。
	var width := float(entry.get("ray_width_scale"))
	_h.expect(width > 1.0, "entry_%s_ray_width" % tag,
		"入口星爆 ray_width_scale=%s ≤ 1 —— 半径放大后细芒会显脏，必须加粗" % str(width))
	# ③ 非黄色：用户 10.11 明确「不要黄色，不够显眼」。黄系的特征是 R/G 高、B 低，
	#    所以判据是「蓝通道显著高于红通道」（冰蓝白），而不是「R 不等于 1.0」这种弱否定。
	var col: Color = entry.get("burst_color")
	_h.expect(col.b > col.r + 0.15, "entry_%s_not_yellow" % tag,
		"入口星爆颜色 %s 偏黄 —— 用户 10.11 明确「不要黄色，不够显眼」，应改偏冷的蓝白" % str(col))


func _teardown(screen: Node, was_active: bool, was_host: bool) -> void:
	NetworkService.team_active = was_active
	NetworkService.is_host = was_host
	if screen != null and is_instance_valid(screen):
		screen.queue_free()
