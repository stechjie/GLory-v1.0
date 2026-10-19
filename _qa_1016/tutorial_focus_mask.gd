extends Node
# ============================================================================
# 2026-10-15 问题 2 门禁：新手教学「聚焦遮罩」（除步骤/箭头/目标外一律压暗）。
#
# 【反馈原文】
#   「新手教学模式需要优化，当前为：新手教程步骤、箭头提示和目标过于不明显。
#     优化为：调整明亮度，使除步骤、箭头提示和目标外的地方变暗，方便新手玩家
#     更好看到操作指引。举例，如图里的"步骤1/22"，要保留亮度的就是步骤1/22、
#     红色箭头、民兵，其他区域变暗。」
#
# 【同日返工：从"4 块拼环形"换成"单块 + shader 开洞"】
#   第一版用 4 块 ColorRect（上/下/左/右）围出洞。玩家实测报「屏幕会闪，伴有线」：
#   相邻两块共用一条**同值的分数坐标边**，GPU 按各自 quad 独立栅格化 ⇒ 公共边在
#   像素级错开 1px 成一条亮线；而目标（商店木牌）本身在**逐帧漂移**
#   （实测 y ≈ −0.027 px/帧、x ≈ +0.003 px/帧）⇒ 那条缝被一秒扫过一两次 = 闪。
#   ⇒ 现在遮罩是**一整块**铺满 overlay 的 ColorRect，洞交给 fragment 逐片元判定，
#   内部不存在任何边界。本门禁随之换成下面这组判据。
#
# 【要钉住什么】
#   亮度承诺拆成四条独立的判据，任何一条被改坏都要红：
#     ① **目标不被压暗** —— shader 的 hold 洞（hole uniform 换算回像素）必须罩住
#        目标的可见部分。这是反馈里点的名（"民兵"要保持亮度）。
#     ② **其余全被压暗** —— hole_on 必须是 1（有目标时）／0（无目标时），
#        且洞不得大于「目标外扩 FOCUS_HOLE_PADDING」——否则就是"该暗的地方没暗透"。
#     ③ **结构上不可能有缝** —— 遮罩节点**只有 1 块**，且它的矩形恒等于整幅 overlay。
#        这条同时钉住「每帧几何零变化」：目标漂移不许带动遮罩边缘做亚像素游走
#        （那正是玩家实测报的「闪 + 线」的来源）。
#     ④ **步骤与箭头不被压暗** —— 遮罩必须是 _overlay 的第 1 个子节点，
#        index 小于箭头 / 气泡 / 跳过键 / 热点。这几样靠画序压在遮罩之上，
#        把遮罩挪到后面就等于把它们的亮度一起吃掉（这条最容易被顺手改坏）。
#
#   另外两条防"修好了 A 压坏了 B"的反向判据：
#     ⑤ 遮罩一律 MOUSE_FILTER_IGNORE —— 只负责变暗，不许吃点击
#        （透明热点、跳过键、商店、棋盘都还要能点）。门禁用真实鼠标事件探测。
#     ⑥ 顶层详情页打开时 overlay 整层隐藏，遮罩必须跟着消失，不能留在屏幕上
#        把整局游戏糊黑。
#
# 【本门禁量不到的东西】
#   `--headless` 不渲染，所以"洞在屏幕上到底落在哪个像素""边缘有没有 1px 亮线"
#   拿不到像素真值 —— 那部分由非 headless 的 `_qa_1016/mask_pixel_probe.tscn`
#   负责（逐像素对比"遮罩开/关"两帧，见该文件头部说明）。本门禁钉的是**契约**。
#
# 【跑法】
#   Godot_v4.7.2-stable_win64_console.exe --headless --path <工程根> \
#       _qa_1016/tutorial_focus_mask.tscn
#   退出码 0 = PASS，1 = FAIL。

const CheckHarness := preload("res://_qa_1016/CheckHarness.gd")
const TutorialScript := preload("res://scripts/tutorial/TutorialMode.gd")
const PrepScript := preload("res://scenes/prep/PrepScreen.gd")

const CHECK_NAME := "tutorial_focus_mask"
const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"

# 与 tutorial_overlay_layout_check 同一组口径：基准视口 1600×720，
# stretch=canvas_items + aspect=expand ⇒ 窄屏拿到**更窄/更高**的画布。
const RESOLUTIONS: Array = [
	{"name": "1600x720", "size": Vector2i(1600, 720)},
	{"name": "1280x720", "size": Vector2i(1280, 720)},
	{"name": "iPhone 灵动岛在左 1748x804", "size": Vector2i(1748, 804), "insets": Vector4(114, 0, 0, 38)},
]

const EPS := 1.5
const EPS_AREA := 4.0
# 契约：遮罩**只有一块**。**刻意写成门禁自己的字面量**，不去读 TutorialMode 的
# 常量 —— 读实现里的值就变成同义反复（改常量两边一起动，永远对得上）。
# 从 4 改成 1 是玩家实测报的「屏幕会闪，伴有线」的修法：单块 + shader 开洞，
# 内部没有公共边，缝在结构上不可能出现。
const EXPECT_DIM_COUNT := 1


var _h: CheckHarness
var _restore_size := Vector2i.ZERO
var _measured := 0


# ⚠ 本门禁**不得在编译期绑定** TutorialMode 的新符号（FOCUS_DIM_COUNT /
# FOCUS_HOLE_PADDING / _update_focus_dim）。第一版直接写 `TutorialScript.FOCUS_DIM_COUNT`，
# 结果在**未修复**的构建上整个脚本解析失败、场景没有脚本、进程不退出 —— 门禁挂住而不是
# 判红，正是"假绿"的反面：假挂。所以常量走 get_script_constant_map()、方法走 call()，
# 让"没有这套东西"落到 dim_node_count 这条正常失败上。
func _script_const(name: String, fallback: Variant) -> Variant:
	# 走 Variant + call()：直接写 `TutorialScript.get_script_constant_map()` 会被
	# 静态分析判成「不能在类上直接调非静态函数」而解析失败。
	var script_obj: Variant = TutorialScript
	if script_obj == null or not script_obj.has_method("get_script_constant_map"):
		return fallback
	var map: Variant = script_obj.call("get_script_constant_map")
	if not (map is Dictionary):
		return fallback
	return (map as Dictionary).get(name, fallback)


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_restore_size = get_window().size

	for entry in RESOLUTIONS:
		SafeArea.set_test_insets((entry as Dictionary).get("insets", Vector4.ZERO))
		await _check_resolution(entry as Dictionary)

	SafeArea.set_test_insets(null)
	get_window().size = _restore_size
	TutorialMode.finish()
	GameState.reset_run()
	await _settle(3)

	_h.expect(_measured >= 10, "too_few_measurements",
		"整个门禁只量到 %d 个目标，等于没验" % _measured)
	_h.finish(get_tree())


func _check_resolution(entry: Dictionary) -> void:
	var label := str(entry["name"])
	get_window().size = entry["size"] as Vector2i
	await _settle(4)

	TutorialMode.start()
	var prep := _new_prep()
	if prep == null:
		return
	await _settle(3)
	TutorialMode.attach(prep.tutorial_target_provider())
	await _settle(2)

	var overlay: Control = TutorialMode._overlay
	if not _h.expect(overlay != null and is_instance_valid(overlay),
			"overlay_missing", "%s：教程 overlay 没建起来" % label):
		prep.queue_free()
		await _settle(3)
		return

	var dims := _dim_nodes()
	var want_count := int(_script_const("FOCUS_DIM_COUNT", EXPECT_DIM_COUNT))
	_h.expect(want_count == EXPECT_DIM_COUNT, "dim_count_contract_changed",
		"%s：契约是 %d 块遮罩，TutorialMode 的 FOCUS_DIM_COUNT 却是 %d —— "
			% [label, EXPECT_DIM_COUNT, want_count]
		+ "改了数量要同步改本门禁的 EXPECT_DIM_COUNT 并说明理由")
	if not _h.expect(dims.size() == EXPECT_DIM_COUNT,
			"dim_node_count",
			"%s：聚焦遮罩应当是**一整块**（%d 块，节点名以 TutorialFocusDim 开头），"
				% [label, EXPECT_DIM_COUNT]
			+ "实际找到 %d 块 —— 修复前这里会是 0 块；"
				% dims.size()
			+ "如果又变成 4 块拼环形，先看本轮『屏幕会闪，伴有线』的记录"):
		prep.queue_free()
		await _settle(3)
		return
	await _check_draw_order(dims, overlay, label)
	await _check_color_and_input(dims, label)
	await _check_single_quad(dims, overlay, label)
	await _check_geometry_stable(dims, overlay, label)
	_check_optout_table(label)

	for step in _walkable_steps():
		TutorialMode.step = step
		TutorialMode.update_overlay()
		prep._refresh_carrot_counter()
		await _settle(1)
		# 再跑一帧，让 rect / overlay 尺寸都稳定下来
		TutorialMode.update_overlay()
		await _settle(1)
		await _check_step(dims, overlay, label, step)

	await _check_degenerate(dims, overlay, label)
	await _check_suppressed(overlay, label)

	prep.queue_free()
	await _settle(4)


# ── 单个步骤的亮度承诺 ─────────────────────────────────────────────────────────

func _check_step(dims: Array, overlay: Control, label: String, step: int) -> void:
	var step_key := TutorialMode.step_key()
	var where := "%s · %s" % [label, step_key]

	# ① 这一步该不该压暗（反馈 2026-10-15 第二/第三轮：关商店 / 上阵布阵 / 选择宝藏 ×2 /
	#    补满七人 这几步整幅不压暗）。判据走 focus_mask_disabled()，与产品**同源**，
	#    门禁不另抄一份步骤名单 —— 否则产品改了名单门禁还绿着。
	#    ⚠ 这一条**必须排在下面「目标解析不出来就 return」之前**。实测 PLACE_3 的
	#    target 在本门禁环境里根本解析不出来（日志 `resolver_returned_no_control`：
	#    棋盘上没放棋子，`place_unit` 没有对应控件），若放在后面整条断言会被静默跳过，
	#    "这两步不压暗"的亮度承诺就没人验了。可见性只取决于 update_overlay()，与 target 无关。
	var dim := dims[0] as Control
	if _mask_disabled():
		_measured += 1
		_h.expect(not dim.visible, "mask_shown_on_optout_step",
			"%s：这一步按反馈要求**不该压暗**，遮罩却还在画（visible=true）—— "
				% where + "它要玩家做的动作正好落在被压暗的区域上（点商店外面 / 拖待命区）")
		return
	_h.expect(dim.visible, "mask_hidden_on_required_step",
		"%s：这一步应当压暗，遮罩却是隐藏的（visible=false）—— 亮度承诺塌了" % where)

	# ② 剩下的两条（洞 / 悬停）都要求"目标在屏幕上"，解析不出来时如实跳过
	var target := TutorialMode._target_control()
	if target == null or not is_instance_valid(target) or not target.is_visible_in_tree():
		return
	var target_rect := target.get_global_rect()
	if target_rect.size.x <= 0.0 or target_rect.size.y <= 0.0:
		return
	_measured += 1

	# ③ 目标不得被压暗：shader 的洞必须罩住目标
	await _check_hole(dims, overlay, where, target_rect)

	# ④ 真实鼠标悬停在目标上，拾取到的不能是遮罩
	var hovered := await _hover_at(target_rect.get_center())
	for dim2 in dims:
		_h.expect(hovered != dim2, "dim_eats_pointer",
			"%s：光标停在目标上，GUI 拾取到的却是遮罩 %s —— 遮罩吃了点击"
				% [where, str((dim2 as Node).name)])


# 反馈（2026-10-15 第二 / 第三轮，共 5 张真机截图）明令这些步骤**整幅不压暗**，因为它们
# 要玩家做的动作正好落在被压暗的区域上：① BUY_3 的「关闭商店」子阶段要点的就是商店
# **外面**；② PLACE_3 要从**待命区**把棋子拖到棋盘；③ TAKE_TREASURE_1 / TAKE_TREASURE_2
# （步骤 6/22、15/22）的宝藏三选一本身就是一整块全屏面板，压暗只会糊掉要读的卡面；
# ④ FILL_7（步骤 20/22）与 PLACE_3 同理。
# 真值表直接喂参数验，不去伪造 GameState 的棋盘/商店（那会变成同义反复）。
func _check_optout_table(label: String) -> void:
	if not TutorialMode.has_method("focus_mask_disabled_for"):
		_h.fail("no_mask_optout_api",
			"%s：TutorialMode 上没有 focus_mask_disabled_for() —— "
				% label + "「这两步不压暗」的契约不存在")
		return
	var fn := Callable(TutorialMode, "focus_mask_disabled_for")
	var rows := [
		[TutorialScript.Step.PLACE_3, false, true, "上阵布阵"],
		[TutorialScript.Step.PLACE_3, true, true, "上阵布阵（商店恰好开着也一样）"],
		[TutorialScript.Step.BUY_3, true, true, "购买棋子 · 关商店子阶段"],
		[TutorialScript.Step.BUY_3, false, false, "购买棋子 · 正常买（要压暗）"],
		# 2026-10-15 第三轮补：步骤 6/22、15/22、20/22
		[TutorialScript.Step.TAKE_TREASURE_1, false, true, "选择宝藏（步骤 6/22）"],
		[TutorialScript.Step.TAKE_TREASURE_2, false, true, "再选宝藏（步骤 15/22）"],
		[TutorialScript.Step.FILL_7, false, true, "补满七人（步骤 20/22）"],
		[TutorialScript.Step.FILL_7, true, true, "补满七人（商店恰好开着也一样）"],
		[TutorialScript.Step.START_PVE_1, false, false, "首场战斗（要压暗）"],
		[TutorialScript.Step.BOND_HINT, false, false, "羁绊提示（要压暗）"],
		# 边界钉子：第 10/22「查看宝藏」**仍要压暗**（反馈只点名 6/15/20），
		# 防的是「顺手把 TAKE_TREASURE_ 前缀整个放过」这类过度放开。
		[TutorialScript.Step.VIEW_TREASURE, false, false, "查看宝藏（仍要压暗）"],
		[TutorialScript.Step.START_PVP, false, false, "PVP（要压暗）"],
	]
	for row in rows:
		var got := bool(fn.call(row[0], row[1]))
		_h.expect(got == bool(row[2]), "mask_optout_table",
			"%s：%s 的遮罩开关应为 %s，实际 %s" % [label, row[3], str(row[2]), str(got)])


# 编译期安全：新符号一律走 has_method + Callable，绝不写成 `TutorialMode.focus_mask_disabled()` ——
# 未修复的构建会整个脚本解析失败 → 场景没有脚本 → 进程不退出（"假挂"而不是判红）。
func _mask_disabled() -> bool:
	if not TutorialMode.has_method("focus_mask_disabled"):
		return false
	return bool(Callable(TutorialMode, "focus_mask_disabled").call())


# 洞由 shader 的 hole / hole_on 两个 uniform 描述（单位是 overlay 尺寸的 0..1）。
# 换算回像素后：必须罩住目标可见部分，且不得大于「目标 + FOCUS_HOLE_PADDING」。
func _check_hole(dims: Array, overlay: Control, where: String, target_rect: Rect2) -> void:
	var dim := dims[0] as Control
	var full := overlay.size
	var ov_origin := overlay.get_global_rect().position
	var on := _hole_on(dim)
	if not _h.expect(on, "hole_missing",
			"%s：遮罩的 hole_on 是 0（整幅压暗）—— 目标 %s 会被一起压暗"
				% [where, str(target_rect)]):
		return
	var hole := _hole_px(dim, full)
	if not _h.expect(hole.size.x > 0.0 and hole.size.y > 0.0, "hole_degenerate",
			"%s：hole_on=1 但洞的尺寸是 %s —— uniform 没写全" % [where, str(hole.size)]):
		return

	var pad := float(_script_const("FOCUS_HOLE_PADDING", 0.0))
	# 目标换算到 overlay 本地坐标（overlay 是 FULL_RECT，实际 origin 就是 0，
	# 但不假设 —— 少一个"换个宿主就量错"的坑）。
	var local_target := Rect2(target_rect.position - ov_origin, target_rect.size)

	# 洞不得超过「目标 + 外扩」：否则该暗的地方没暗透
	var want := local_target.grow(pad)
	_h.expect(hole.size.x <= want.size.x + EPS and hole.size.y <= want.size.y + EPS,
		"hole_too_big",
		"%s：洞口 %s 比「目标 + %0.0fpx」(%s) 还大 —— 除了目标以外还有地方没被压暗"
			% [where, str(hole.size), pad, str(want.size)])
	_h.expect(hole.size.x + EPS >= local_target.size.x
			and hole.size.y + EPS >= local_target.size.y,
		"hole_too_small",
		"%s：洞口 %s 比目标 %s 还小 —— 目标会被遮罩切掉一块"
			% [where, str(hole.size), str(local_target.size)])
	# 洞必须罩住目标（不是偏到别处）。
	# ⚠ 只比「目标落在 overlay 里的那部分」：有些目标（顶栏那一排）y 是负的，
	# 露在画布外的那半本来就没有遮罩可言，拿整个目标去比会永远红。
	var visible_target := local_target.intersection(Rect2(Vector2.ZERO, full))
	if visible_target.size.x > 0.0 and visible_target.size.y > 0.0:
		var covers := hole.position.x <= visible_target.position.x + EPS \
			and hole.position.y <= visible_target.position.y + EPS \
			and hole.end.x >= visible_target.end.x - EPS \
			and hole.end.y >= visible_target.end.y - EPS
		_h.expect(covers, "hole_misplaced",
			"%s：洞口 %s 没罩住目标可见部分 %s —— 打亮的不是该打亮的东西"
				% [where, str(hole), str(visible_target)])


# 结构上不可能有缝：遮罩只有一块，且矩形恒等于整幅 overlay（见文件头说明）。
func _check_single_quad(dims: Array, overlay: Control, label: String) -> void:
	var dim := dims[0] as Control
	var a := dim.get_global_rect()
	var b := overlay.get_global_rect()
	if not _h.expect(absf(a.position.x - b.position.x) <= EPS
			and absf(a.position.y - b.position.y) <= EPS
			and absf(a.size.x - b.size.x) <= EPS
			and absf(a.size.y - b.size.y) <= EPS,
			"mask_not_full_overlay",
			"%s：遮罩矩形 %s ≠ 整幅 overlay %s —— 遮罩不是「一块铺满」的话，"
				% [label, str(a), str(b)]
			+ "内部就会有边界，玩家报的那条 1px 亮线会回来"):
		return
	# 必须挂着 ShaderMaterial（洞靠它抠），且三个 uniform 都真的写得进去。
	var mat := dim.material as ShaderMaterial
	if not _h.expect(mat != null and mat.shader != null, "mask_shader_missing",
			"%s：遮罩没有 ShaderMaterial —— 洞没法抠，整幅会一团黑" % label):
		return
	for name in ["dim_color", "hole", "hole_on"]:
		_h.expect(mat.get_shader_parameter(name) != null, "mask_uniform_missing",
			"%s：遮罩 shader 上没有 uniform `%s` —— 契约对不上" % [label, name])


# 目标在漂移（实测 y ≈ −0.027 px/帧），遮罩的**几何**必须一动不动：
# 它恒等于整幅 overlay，每帧只改 uniform。这条防的正是"边缘跟着目标做亚像素游走"
# 那种闪烁（玩家反馈的「闪」）。
func _check_geometry_stable(dims: Array, overlay: Control, label: String) -> void:
	var dim := dims[0] as Control
	var before := dim.get_global_rect()
	for i in 6:
		TutorialMode.update_overlay()
		await _settle(1)
	var after := dim.get_global_rect()
	_h.expect(before.position.is_equal_approx(after.position)
			and before.size.is_equal_approx(after.size),
		"mask_geometry_moved",
		"%s：连跑 6 帧后遮罩矩形从 %s 变成 %s —— 遮罩几何不该随目标漂移而变"
			% [label, str(before), str(after)])


# 遮罩必须画在箭头 / 气泡 / 跳过键之下。
#
# ⚠ 画序的真正判据是 **(z_index, 子节点 index)** 这个二元组，不是单看 index：
#   z_index 默认 z_as_relative，遮罩与这三者的 z 都是 0 ⇒ 才轮到 index 说话。
#   只钉 index 会有个洞：谁把遮罩的 z_index 改成 999，index 依然是最小，
#   但绘制上它会盖住气泡（玩家看到步骤条被压暗）—— 所以两条都要钉。
#
# （2026-10-15 第三轮：这里的第 4 项原本是「点击热点」`_hotspot`。反馈明令遮罩/覆盖层
#   不得限制玩家操作，那个透明 Button 已整个删掉，覆盖层里只剩它、箭头、气泡、跳过键。
#   覆盖层「一颗点击都不吃」这件事改由 `_qa_1016/tutorial_overlay_no_input_block` 专钉。）
func _check_draw_order(dims: Array, overlay: Control, label: String) -> void:
	var dim_max := -1
	for dim in dims:
		dim_max = maxi(dim_max, (dim as Node).get_index())
	var above := {
		"金色光辉": TutorialMode._light,
		"狗狗": TutorialMode._guide,
		"气泡": TutorialMode._bubble,
		"跳过按钮": TutorialMode._skip_btn,
	}
	for what in above:
		var node: Node = above[what]
		if node == null or not is_instance_valid(node):
			_h.fail("chrome_missing", "%s：%s 不存在，画序判据无法执行" % [label, what])
			continue
		var ctl := node as CanvasItem
		var dim_z := 0
		for dim in dims:
			dim_z = maxi(dim_z, (dim as CanvasItem).z_index)
		if ctl != null:
			_h.expect(dim_z <= ctl.z_index, "dim_z_above_chrome",
				"%s：遮罩 z_index=%d > %s 的 z_index=%d —— "
					% [label, dim_z, what, ctl.z_index]
				+ "z 比较靠后就会盖在它上面，它会被压暗（index 判据查不出这种情况）")
		_h.expect(node.get_index() > dim_max, "dim_above_chrome",
			"%s：%s（index=%d）被排在了遮罩（最大 index=%d）之前 —— "
				% [label, what, node.get_index(), dim_max]
			+ "它会被压暗，而反馈明确要求它保持亮度")
	# 遮罩必须是第 1 个子节点：这是"靠层级保亮度"的前提
	_h.expect(dim_max == 0, "dim_not_first_child",
		"%s：遮罩的 index 是 %d（应为 0）—— 它前面还有别的节点，画序契约变了"
			% [label, dim_max])
	_h.expect(overlay.get_child_count() > 0, "overlay_empty", "%s：overlay 没有子节点" % label)


func _check_color_and_input(dims: Array, label: String) -> void:
	for i in dims.size():
		var dim := dims[i] as ColorRect
		if dim == null:
			_h.fail("dim_not_color_rect", "%s：遮罩[%d] 不是 ColorRect" % [label, i])
			continue
		_h.expect(dim.mouse_filter == Control.MOUSE_FILTER_IGNORE, "dim_not_ignore",
			"%s：遮罩[%d] 的 mouse_filter 是 %d（应为 IGNORE）—— 遮罩会吃点击"
				% [label, i, dim.mouse_filter])
		var v = _uniform(dim, "dim_color")
		if not (v is Color):
			_h.fail("dim_color_missing",
				"%s：遮罩[%d] 的 dim_color uniform 读不到（%s）" % [label, i, str(v)])
			continue
		var c := v as Color
		var dimness := maxf(c.r, maxf(c.g, c.b))
		_h.expect(c.a >= 0.4, "dim_too_transparent",
			"%s：遮罩[%d] 的 alpha 只有 %.2f —— 压不下去，等于没做" % [label, i, c.a])
		_h.expect(dimness <= 0.2, "dim_not_dark",
			"%s：遮罩[%d] 的颜色 %s 不够暗（max 通道 %.2f）" % [label, i, str(c), dimness])


# 目标解析不出来时应当整幅压暗（不能凭空亮一块）。
#
# ⚠ 不能 await：PrepScreen 每帧都在 `_process` 里调 `TutorialMode.update_overlay()`，
# 一让出帧它就会按当前目标把洞重算回来，这一条就永远量不到。
# GDScript 是同步的，调用后立刻读 uniform 即可。
func _check_degenerate(dims: Array, overlay: Control, label: String) -> void:
	if not TutorialMode.has_method("_update_focus_dim"):
		_h.fail("no_focus_dim_api",
			"%s：TutorialMode 上没有 _update_focus_dim()，整条聚焦遮罩都不存在" % label)
		return
	TutorialMode.call("_update_focus_dim", Rect2())
	var dim := dims[0] as Control
	_h.expect(not _hole_on(dim), "degenerate_not_full",
		"%s：目标为空时 hole_on 还是 1（洞 %s）—— "
			% [label, str(_hole_px(dim, overlay.size))]
		+ "要么漏了没压暗，要么在屏幕中央凭空亮了一块")


# 同理不能 await：PrepScreen 每帧都用**详情页状态**重设 suppressed，
# 让出帧就会把它顶回来。与 tutorial_overlay_layout_check 同一写法。
func _check_suppressed(overlay: Control, label: String) -> void:
	TutorialMode.update_overlay()
	TutorialMode.set_overlay_suppressed(true)
	_h.expect(not overlay.visible, "dim_survives_suppress",
		"%s：顶层详情页打开时教程整层应当隐藏，遮罩却还留在屏幕上" % label)
	TutorialMode.set_overlay_suppressed(false)
	_h.expect(overlay.visible, "overlay_not_restored",
		"%s：关掉详情后教程层没有恢复" % label)


# ── 辅助 ───────────────────────────────────────────────────────────────────────

func _dim_nodes() -> Array:
	var out: Array = []
	var overlay: Control = TutorialMode._overlay
	if overlay == null or not is_instance_valid(overlay):
		return out
	for child in overlay.get_children():
		if child is ColorRect and str(child.name).begins_with("TutorialFocusDim"):
			out.append(child)
	return out


func _uniform(node: Control, name: String) -> Variant:
	if node == null or not is_instance_valid(node):
		return null
	var mat := node.material as ShaderMaterial
	if mat == null:
		return null
	return mat.get_shader_parameter(name)


func _hole_on(dim: Control) -> bool:
	var v = _uniform(dim, "hole_on")
	return v is float and float(v) > 0.5


# hole uniform（0..1）→ overlay 本地像素
func _hole_px(dim: Control, full: Vector2) -> Rect2:
	var v = _uniform(dim, "hole")
	if not (v is Vector4):
		return Rect2()
	var u := v as Vector4
	return Rect2(Vector2(u.x * full.x, u.y * full.y), Vector2(u.z * full.x, u.w * full.y))


func _hover_at(global_pos: Vector2) -> Control:
	var vp := get_viewport()
	var m := InputEventMouseMotion.new()
	m.position = global_pos
	m.global_position = global_pos
	vp.push_input(m)
	await _settle(2)
	return vp.gui_get_hovered_control()


func _walkable_steps() -> Array:
	var out: Array = []
	for step in [
		TutorialScript.Step.BUY_3, TutorialScript.Step.PLACE_3,
		TutorialScript.Step.START_PVE_1, TutorialScript.Step.UPGRADE_2,
		TutorialScript.Step.START_PVE_2, TutorialScript.Step.TAKE_TREASURE_1,
		TutorialScript.Step.UPGRADE_3, TutorialScript.Step.UPGRADE_OTHERS,
		TutorialScript.Step.BOND_HINT, TutorialScript.Step.VIEW_TREASURE,
		TutorialScript.Step.CARROT_CAMP,
		TutorialScript.Step.START_BOSS, TutorialScript.Step.TAKE_TREASURE_2,
		TutorialScript.Step.CARROT_HARVEST,
		TutorialScript.Step.HIRE_MERC, TutorialScript.Step.FILL_7,
		TutorialScript.Step.FORMATION_HP, TutorialScript.Step.START_PVP,
	]:
		out.append(step)
	return out


func _overlap(a: Rect2, b: Rect2) -> float:
	var hit := a.intersection(b)
	if hit.size.x <= 0.0 or hit.size.y <= 0.0:
		return 0.0
	return hit.size.x * hit.size.y


func _new_prep() -> PrepScript:
	var packed := load(PREP_SCENE) as PackedScene
	if not _h.expect(packed != null, "prep_scene_load_failed", "%s 加载不出来" % PREP_SCENE):
		return null
	var prep: PrepScript = packed.instantiate() as PrepScript
	if not _h.expect(prep != null, "prep_wrong_type", "实例化出来的不是 PrepScreen"):
		return null
	add_child(prep)
	return prep


func _settle(frames: int = 2) -> void:
	for i in frames:
		await get_tree().process_frame
