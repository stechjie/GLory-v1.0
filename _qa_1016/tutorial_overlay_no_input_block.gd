extends Node
# ============================================================================
# 2026-10-15 问题 2（第三轮）门禁：教学覆盖层**不许限制玩家操作**。
#
# 【反馈原文（两轮）】
#   ① 「此次修复增加的遮罩，你改动一下，不要增加玩家操作的限制，仅设为提醒和明亮度的
#      不同，但是其他操作都可以做的，就不会引发这么多问题」
#   ② 「新手教程要保持本次修复之前的样子，但是只是加了明的目标、步骤、箭头位置，
#      暗的其他位置」
#   ⇒ 合并成一句可验收的话：**教程的步骤 / 文案 / 顺序 / 箭头 / 「点哪儿算数」全都与
#      加遮罩之前逐字一致；覆盖层只是多了一层明暗，一个点击都不许吃。**
#
# 【被钉住的那个历史缺陷】
#   加遮罩那一版沿用了原版的一个「透明热点」`_hotspot`：Button，`modulate = Color(1,1,1,0)`，
#   `MOUSE_FILTER_STOP`。BOND_HINT / VIEW_TREASURE 时它盖在目标上（+10px），
#   FORMATION_HP / CARROT_HARVEST 时它铺满整屏。**alpha=0 不等于不拦输入** ——
#   它照样在命中测试里胜出：
#     * 那 4 步里点目标 = 点击被它吃掉（羁绊说明 / 宝藏面板根本不会打开）；
#     * 后 2 步里点屏幕任何地方都被它吃掉（商店、棋盘全点不动）。
#   气泡 `_bubble` 也一样：`PanelContainer` + 默认 `MOUSE_FILTER_STOP`，而且它的
#   `MarginContainer` / `VBoxContainer` 子节点同样是 STOP ⇒ 只改气泡那一层是半截修法。
#
# 【现在的做法（本门禁要钉的合同）】
#   * 覆盖层里**只有**「跳过教学」吃点击，其余一律 `MOUSE_FILTER_IGNORE`（含整棵子树）；
#   * 那 4 步改由 `TutorialMode._input()` **旁听**真实按下事件推进，受理范围与旧热区
#     **逐字相同**（目标矩形 `grow(10)` / 后两步任意处），但**绝不 `set_input_as_handled()`**
#     ⇒ 同一次点击照常落到下面那个真控件上。
#
# 【判据】
#   ① 覆盖层直接子节点恰好 4 个（遮罩/箭头/气泡/跳过），且除跳过外整棵子树都是 IGNORE；
#      「跳过教学」必须仍然吃点击（它是唯一该吃的那个）。
#   ② 真实命中测试：气泡中心 / 屏幕中心 / 各步目标中心，`gui_get_hovered_control()`
#      拾取到的**不能**是教程节点 —— 这一条正是 `_hotspot` / `_bubble` 那两处缺陷的照妖镜。
#   ③ 那 4 步：真实鼠标按下之后 ⑴ `step` 必须推进 ⑵ 这一下必须落到下面的真控件上
#      （在那上面挂 `gui_input` 计数，一次都没触发就是被吃掉了）。
#   ④ 反例：非「点一下继续」的步骤一律不受理；`FORMATION_HP` 上的「跳过教学」矩形不受理；
#      `BOND_HINT` 的目标之外不受理。
#
# 【为什么每个 tap 步都新建一个 PrepScreen】
#   真实点击会产生真实副作用（点宝藏图标真的会开宝藏面板、点羁绊栏真的会开羁绊说明）。
#   带着一个开着的面板去测下一步，命中测试量的就不是被放行的那一层了 —— 那会变成
#   「测到了别的东西」，结论不可信。所以每一步用一个干净的备战页。
#
# 【刻意不做的一条】
#   不在门禁里真的去点「跳过教学」：那一下会经 DialogService 弹一个模态确认框，
#   模态框会跟后面的命中测试打照面。改为直接问纯判据
#   `_tap_advance_accepts(跳过键中心)` 必须为 false（与真点等价，且无副作用）。
#
# 【跑法】
#   Godot_v4.7.2-stable_win64_console.exe --headless --path <工程根> \
#       _qa_1016/tutorial_overlay_no_input_block.tscn
#   退出码 0 = PASS，1 = FAIL。

const CheckHarness := preload("res://_qa_1016/CheckHarness.gd")
const TutorialScript := preload("res://scripts/tutorial/TutorialMode.gd")
const PrepScript := preload("res://scenes/prep/PrepScreen.gd")

const CHECK_NAME := "tutorial_overlay_no_input_block"
const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"

const RESOLUTIONS: Array = [
	{"name": "1600x720", "size": Vector2i(1600, 720)},
	{"name": "1280x720", "size": Vector2i(1280, 720)},
	{"name": "iPhone 灵动岛在左 1748x804", "size": Vector2i(1748, 804), "insets": Vector4(114, 0, 0, 38)},
]

# 契约：覆盖层直接子节点只有这 6 个。**刻意写成门禁自己的字面量** —— 读实现里的
# 常量就成了同义反复（改常量两边一起动，永远对得上）。多一个就是要红：历史形状是
# 「又加回来一个吃点击的节点」（透明热点就是那一个）。
# 10.19 tutorial fix 起第 6 个是自由回合那只「加油！」文案 _cheer_label（IGNORE，
# 见 TutorialMode._ensure_overlay / _show_passive_dog）—— 它不吃点击，递归断言照旧覆盖它。
const EXPECT_OVERLAY_CHILDREN := 6

# 「点一下继续」必须**就是**这 4 步（枚举本身没有变过，这里直接静态引用是安全的）。
const TAP_STEPS := [
	TutorialScript.Step.BOND_HINT,
	TutorialScript.Step.VIEW_TREASURE,
	TutorialScript.Step.FORMATION_HP,
	TutorialScript.Step.CARROT_HARVEST,
]

# 非「点一下继续」的步骤（抽查几个代表：布阵 / 开战 / 升级 / 铺货 / Boss / 完成）。
# 这些步骤点哪儿都不该推进 —— 否则玩家随手一点就跳步。
const NON_TAP_STEPS := [
	TutorialScript.Step.PLACE_3,
	TutorialScript.Step.START_PVE_1,
	TutorialScript.Step.UPGRADE_2,
	TutorialScript.Step.FILL_7,
	TutorialScript.Step.START_BOSS,
	TutorialScript.Step.DONE,
]


var _h: CheckHarness
var _restore_size := Vector2i.ZERO
var _measured := 0
# 「真实点击有没有落到下面那个真控件上」的探针计数。
# 刻意用**具名方法**而不是匿名 lambda：`gui_input.connect(lambda)` / `is_connected(lambda)`
# 依赖 Callable 的 hash 稳定，换个写法就可能连接与断开对不上；具名方法的引用是稳定的。
var _probe_hits := 0
var _probe_target: Control = null


# ⚠ 本门禁**不得在编译期绑定** TutorialMode 这一轮新增的符号（`_input` /
# `is_tap_step()` / `_tap_advance_accepts()` / `confirm_tap_step()`）。第一版门禁里
# 有过一次教训：脚本引用了未修复构建上不存在的符号 ⇒ 整个脚本解析失败 ⇒ 场景没有脚本 ⇒
# 进程不退出，`timeout` 把"假挂"当成了结果。所以新增符号一律走 `has_method()` + `call()`，
# 让"没有这套东西"落成下面那些正常的失败码。
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
		"整个门禁只量到 %d 个对象，等于没验" % _measured)
	_h.finish(get_tree())


# ── 每个分辨率 ─────────────────────────────────────────────────────────────────

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
			"overlay_missing", "%s：教程 overlay 没建起来 —— 覆盖层这条合同无从谈起" % label):
		prep.queue_free()
		await _settle(3)
		return

	# ① 结构：覆盖层里只有跳过键吃点击
	await _check_overlay_children(overlay, label)
	# ② 命中测试：覆盖层盖住的地方不许拾取到教程节点
	await _check_hover_paths(overlay, label)
	# ④(c) 纯判据反例
	_check_predicate_counter_cases(label)

	prep.queue_free()
	await _settle(4)

	# ③ 那 4 步：每一步一个干净的备战页（真实点击会开真面板）
	for step in TAP_STEPS:
		await _check_tap_step(entry, step)
	# ④(d) 真实点击反例：非 tap 步任意处都不推进
	await _check_realtime_counter_case(entry)


# ── ① 覆盖层结构 ───────────────────────────────────────────────────────────────

func _check_overlay_children(overlay: Control, label: String) -> void:
	var children := overlay.get_children()
	_h.expect(children.size() == EXPECT_OVERLAY_CHILDREN, "overlay_child_count",
		"%s：覆盖层直接子节点有 %d 个，契约是 %d 个（遮罩 / 金光 / 狗狗 / 气泡 / 跳过键 / 加油文案）—— "
			% [label, children.size(), EXPECT_OVERLAY_CHILDREN]
		+ "多出来的那一个多半又在吃点击（历史形状：透明热点 `_hotspot`，Button + STOP，"
		+ "alpha=0 也照样在命中测试里胜出）")
	_h.expect(overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE, "overlay_blocks_input",
		"%s：覆盖层根节点 mouse_filter=%d（应为 IGNORE）—— 整层都会吃点击"
			% [label, overlay.mouse_filter])
	_h.expect(children.has(TutorialMode._light) and children.has(TutorialMode._guide)
		and children.has(TutorialMode._bubble) and children.has(TutorialMode._skip_btn)
		and children.has(TutorialMode._cheer_label),
		"overlay_children_wrong", "%s：覆盖层缺少金光、狗狗、气泡、跳过键或加油文案" % label)

	var skip: Control = TutorialMode._skip_btn
	if skip == null or not is_instance_valid(skip):
		_h.fail("skip_button_missing", "%s：覆盖层里找不到「跳过教学」按钮" % label)
		return
	for child in children:
		var ctl := child as Control
		if ctl == null:
			continue
		if ctl == skip:
			_h.expect(ctl.mouse_filter != Control.MOUSE_FILTER_IGNORE,
				"skip_button_not_clickable",
				"%s：「跳过教学」是覆盖层里**唯一**该吃点击的节点，它却是 IGNORE —— 玩家点不到跳过"
					% label)
			continue
		_assert_subtree_ignores_mouse(ctl, label, str(ctl.name))


# 递归钉住。**必须递归**：Container 的 `mouse_filter` 默认是 STOP（不是 PASS），
# 只把气泡那一个 PanelContainer 设成 IGNORE 的话，它下面那层 MarginContainer 照样把
# 落在气泡矩形里的点击吃掉 —— 真机表现就是"气泡底下的按钮点不动"。
func _assert_subtree_ignores_mouse(node: Node, label: String, path: String) -> void:
	var ctl := node as Control
	if ctl != null:
		_measured += 1
		_h.expect(ctl.mouse_filter == Control.MOUSE_FILTER_IGNORE, "overlay_child_blocks_input",
			"%s：覆盖层节点 %s 的 mouse_filter=%d（应为 IGNORE）—— 它会吃掉落在自己矩形里的点击，"
				% [label, path, ctl.mouse_filter]
			+ "玩家在那一片就操作不了（Container 一级的默认值就是 STOP）")
	for child in node.get_children():
		_assert_subtree_ignores_mouse(child, label, "%s/%s" % [path, str(child.name)])


# ── ② 命中测试 ─────────────────────────────────────────────────────────────────

# 覆盖层盖住的两个典型位置：气泡中心、屏幕中心。
# 命中测试会**跳过** IGNORE 控件，所以修复后这两个点上拾取到的必然是游戏自己的控件；
# 而修复前 / 半截修法下拾取到的会是热点或气泡（及其容器子节点）。
func _check_hover_paths(overlay: Control, label: String) -> void:
	TutorialMode.step = TutorialScript.Step.BOND_HINT
	TutorialMode.update_overlay()
	await _settle(1)

	var bubble: Control = TutorialMode._bubble
	if bubble != null and is_instance_valid(bubble):
		var bubble_rect := bubble.get_global_rect()
		if bubble_rect.size.x > 0.0 and bubble_rect.size.y > 0.0:
			_measured += 1
			var hit := await _hover_at(bubble_rect.get_center())
			_assert_not_tutorial(hit, overlay, label, "气泡中心")

	var canvas := get_viewport().get_visible_rect().size
	_measured += 1
	var centre := await _hover_at(canvas * 0.5)
	_assert_not_tutorial(centre, overlay, label, "屏幕中心")

	var skip: Control = TutorialMode._skip_btn
	if skip != null and is_instance_valid(skip):
		_measured += 1
		var skip_hit := await _hover_at(skip.get_global_rect().get_center())
		var ok := skip_hit == skip or (skip_hit != null and skip.is_ancestor_of(skip_hit))
		_h.expect(ok, "skip_button_not_hoverable",
			"%s：「跳过教学」按钮中心拾取到的是 %s —— 它必须仍然可点（覆盖层里唯一该吃点击的节点）"
				% [label, str(skip_hit.get_path()) if skip_hit != null else "<空>"])


func _assert_not_tutorial(hit: Control, overlay: Control, label: String, where: String) -> void:
	if hit == null:
		# 拾取到空不算"被遮住"，但也不该当成通过：这一点上没有任何可接收输入的控件，
		# 说明这条判据量了个寂寞。
		_h.fail("hover_nothing",
			"%s：%s 处悬停拾取到空 —— 那里没有任何可接收输入的控件，本条判据量不到东西" % [label, where])
		return
	var is_tutorial := hit == overlay or (overlay != null and is_instance_valid(overlay)
		and overlay.is_ancestor_of(hit))
	_h.expect(not is_tutorial, "overlay_in_hit_path",
		"%s：%s 处 GUI 拾取到的是教程节点 %s —— 覆盖层挡在玩家的操作路径上了。"
			% [label, where, str(hit.get_path())]
		+ "覆盖层里除「跳过教学」外所有节点都必须是 MOUSE_FILTER_IGNORE（含整棵子树）")


# ── ③ 那 4 步：真实点击既推进、又落到真控件 ──────────────────────────────────────

func _check_tap_step(entry: Dictionary, step: int) -> void:
	var label := str(entry["name"])
	var prep := await _fresh_prep_at(entry)
	if prep == null:
		return
	TutorialMode.step = step
	TutorialMode.update_overlay()
	prep._refresh_carrot_counter()
	await _settle(1)
	TutorialMode.update_overlay()
	await _settle(1)

	var overlay: Control = TutorialMode._overlay
	if overlay == null or not is_instance_valid(overlay):
		_h.fail("overlay_missing", "%s：%s 步的教程 overlay 不见了" % [label, str(TutorialMode.step_key())])
		await _drop_prep(prep)
		return
	var step_key := str(TutorialMode.step_key())

	# 取样点必须**逐字跟着产品判据走**：
	#   产品判据（`_tap_advance_accepts()`）= `target == null or not target.is_inside_tree()`
	#   ⇒ 任意处受理；否则 = 目标矩形 `grow(TAP_TARGET_PAD)` 之内。
	#   ⇒ 这里也就**不能**再加 `size > 0` / `is_visible_in_tree()` 这类产品没写的条件。
	# 实测（本门禁第一版就栽在这）：VIEW_TREASURE 在没有宝藏时目标控件是**存在但零尺寸**的
	# （`_treasure._owned_treasure_box` 这个 GridContainer 还没挂子节点，
	#   rect = P(6,549) S(0,0)）；加了 `size > 0` 就会退回"点屏幕中心"，
	# 而产品在屏幕中心本来就不受理 ⇒ 测出**假红**。
	var target := TutorialMode._target_control()
	var usable := target != null and is_instance_valid(target) and target.is_inside_tree()
	var target_rect := target.get_global_rect() if usable else Rect2()
	var click_pos := target_rect.get_center() if usable else overlay.get_global_rect().get_center()
	var where := "%s · %s · %s" % [label, step_key,
		"目标矩形中心" if usable else "屏幕中心(目标解析不出来⇒任意处受理)"]
	if usable and (target_rect.size.x <= 0.0 or target_rect.size.y <= 0.0):
		_h.note("%s · %s：目标控件存在但**零尺寸**（本门禁不伪造这一步的前置状态，"
			% [label, step_key] + "例如 VIEW_TREASURE 需要先有宝藏）—— 受理范围随之退化成"
			+ "「它的原点外扩 10px」那一小块，与旧版透明热区的行为完全一致")

	# (a) 命中测试：这一点上拾取到的不能是教程节点
	_measured += 1
	var hit := await _hover_at(click_pos)
	if hit == null:
		_h.note("%s：%s 处悬停拾取不到任何控件（该点是纯展示区），命中这一条跳过；"
			% [label, where] + "「点击能推进」与「点击落到真控件」两条仍照常执行")
	else:
		_h.expect(not _is_tutorial_node(hit), "overlay_in_hit_path",
			"%s：%s 处 GUI 拾取到的是教程节点 %s —— 覆盖层挡在玩家的操作路径上了"
				% [where, click_pos, str(hit.get_path())])

	# (b) 真实按下：既推进步骤，也要落到下面那个真控件上
	#     ⚠ `set_overlay_suppressed(false)` 必须紧贴在 `_click()` 之前、中间不 await：
	#      PrepScreen 每帧都会按当前界面状态重设它，让出一帧就可能被顶回去，教程层一隐藏
	#      `_input()` 就整段早退，这一条会变成"假红"。
	TutorialMode.set_overlay_suppressed(false)
	_probe_hits = 0
	_probe_target = hit
	var connected := hit != null and is_instance_valid(hit) and not hit.gui_input.is_connected(_on_probe_gui_input)
	if connected:
		hit.gui_input.connect(_on_probe_gui_input)
	_click(click_pos)
	if connected and is_instance_valid(hit) and hit.gui_input.is_connected(_on_probe_gui_input):
		hit.gui_input.disconnect(_on_probe_gui_input)
	_probe_target = null
	await _settle(2)

	var after := int(TutorialMode.step)
	_h.expect(after != step, "tap_click_did_not_advance",
		"%s：在 %s 真实按下之后 step 没有推进（仍停在 %s）—— 「点一下继续」失效了"
			% [where, click_pos, step_key])
	_h.expect(str(TutorialMode.step_key()) != step_key, "tap_step_key_unchanged",
		"%s：step 的显示代号还是 %s，说明推进没落地" % [where, step_key])
	if connected:
		_h.expect(_probe_hits > 0, "click_did_not_reach_widget",
			"%s：这一次按下**没有**落到下面的真控件 %s 上（gui_input 一次都没触发）—— "
				% [where, str(hit.get_path())]
			+ "覆盖层把点击吃掉了，玩家的操作被限制")

	await _drop_prep(prep)


func _on_probe_gui_input(event: InputEvent) -> void:
	if _probe_target == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
			return
		_probe_hits += 1
	elif event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
		_probe_hits += 1


func _is_tutorial_node(node: Control) -> bool:
	var overlay: Control = TutorialMode._overlay
	if node == null or overlay == null or not is_instance_valid(overlay):
		return false
	return node == overlay or overlay.is_ancestor_of(node)


# ── ④ 反例 ─────────────────────────────────────────────────────────────────────

# 纯判据（无副作用）：受理范围这条合同必须"恰好是那 4 步"。
func _check_predicate_counter_cases(label: String) -> void:
	if not _h.expect(TutorialMode.has_method("is_tap_step")
			and TutorialMode.has_method("_tap_advance_accepts"),
			"tap_api_missing",
			"%s：TutorialMode 上没有 is_tap_step() / _tap_advance_accepts() —— "
				% label + "「受理范围」这条合同不存在，下面两条反例量不到东西"):
		return

	for step in NON_TAP_STEPS:
		TutorialMode.step = step
		_measured += 1
		_h.expect(not bool(TutorialMode.call("is_tap_step")), "nontap_step_is_tap",
			"%s：%s 不是「点一下继续」的步骤，却被判成受理 —— 玩家随手一点就会跳步"
				% [label, str(TutorialMode.step_key())])
	for step in TAP_STEPS:
		TutorialMode.step = step
		_measured += 1
		_h.expect(bool(TutorialMode.call("is_tap_step")), "tap_step_not_tap",
			"%s：%s 是「点一下继续」的步骤，判据却是 false —— 玩家会卡在这一步出不去"
				% [label, str(TutorialMode.step_key())])

	# 「跳过教学」那一小块永远不算受理：那一下是去开跳过确认框的。
	TutorialMode.step = TutorialScript.Step.FORMATION_HP
	TutorialMode.update_overlay()
	var skip: Control = TutorialMode._skip_btn
	if skip != null and is_instance_valid(skip):
		_measured += 1
		_h.expect(not _accepts(skip.get_global_rect().get_center()), "skip_rect_accepts_tap",
			"%s：点在「跳过教学」按钮上也算推进教学步骤 —— 那一下是去开跳过确认框的，"
				% label + "顺手再推一格会让两个弹窗叠在一起")

	# BOND_HINT：目标（羁绊栏）矩形之外不许受理。
	TutorialMode.step = TutorialScript.Step.BOND_HINT
	TutorialMode.update_overlay()
	var target := TutorialMode._target_control()
	if target != null and is_instance_valid(target) and target.is_inside_tree() \
			and target.get_global_rect().size.x > 0.0:
		var outside := _point_outside(target.get_global_rect().grow(20.0), skip)
		if outside == Vector2.INF:
			_h.note("%s：找不到「羁绊栏外 + 跳过键外」的取样点，BOND_HINT 的外侧反例跳过" % label)
		else:
			_measured += 1
			_h.expect(not _accepts(outside), "outside_target_accepts_tap",
				"%s：BOND_HINT 这一步点在 %s（目标矩形之外）也算受理 —— 受理范围被放大了，"
					% [label, outside] + "玩家随手一点就会跳步")


# 真实点击反例：非 tap 步（PLACE_3）在屏幕中心按下去，step 不许动。
func _check_realtime_counter_case(entry: Dictionary) -> void:
	var label := "%s · PLACE_3" % str(entry["name"])
	var prep := await _fresh_prep_at(entry)
	if prep == null:
		return
	TutorialMode.step = TutorialScript.Step.PLACE_3
	TutorialMode.update_overlay()
	await _settle(2)

	var overlay: Control = TutorialMode._overlay
	var canvas := get_viewport().get_visible_rect().size
	var pos := overlay.get_global_rect().get_center() if overlay != null and is_instance_valid(overlay) \
		else canvas * 0.5
	var before := int(TutorialMode.step)
	TutorialMode.set_overlay_suppressed(false)
	_click(pos)
	await _settle(2)

	_measured += 1
	_h.expect(int(TutorialMode.step) == before, "nontap_step_advanced_on_click",
		"%s：非「点一下继续」的步骤也在真实点击下推进了（%s → %s）—— "
			% [label, str(TutorialScript.Step.keys()[before]), str(TutorialMode.step_key())]
		+ "玩家在布阵时随手点一下棋盘就会跳步")

	await _drop_prep(prep)


# ── 辅助 ───────────────────────────────────────────────────────────────────────

func _accepts(canvas_pos: Vector2) -> bool:
	if not TutorialMode.has_method("_tap_advance_accepts"):
		return false
	return bool(TutorialMode.call("_tap_advance_accepts", canvas_pos))


# 每一步一个干净的备战页：真实点击会开真面板（宝藏 / 羁绊说明），带着开着的面板去测下一步，
# 量的就不是被放行的那一层了。
func _fresh_prep_at(entry: Dictionary) -> PrepScript:
	TutorialMode.finish()
	GameState.reset_run()
	await _settle(2)
	TutorialMode.start()
	var prep := _new_prep()
	if prep == null:
		return null
	await _settle(3)
	TutorialMode.attach(prep.tutorial_target_provider())
	await _settle(2)
	return prep


func _drop_prep(prep: PrepScript) -> void:
	if prep == null or not is_instance_valid(prep):
		return
	prep.queue_free()
	await _settle(4)


func _new_prep() -> PrepScript:
	var packed := load(PREP_SCENE) as PackedScene
	if not _h.expect(packed != null, "prep_scene_load_failed", "%s 加载不出来" % PREP_SCENE):
		return null
	var prep: PrepScript = packed.instantiate() as PrepScript
	if not _h.expect(prep != null, "prep_wrong_type", "实例化出来的不是 PrepScreen"):
		return null
	add_child(prep)
	return prep


# 在给出的禁区之外挑一个取样点（画布坐标）。找不到返回 Vector2.INF。
func _point_outside(avoid: Rect2, skip: Control) -> Vector2:
	var canvas := get_viewport().get_visible_rect().size
	var skip_rect := Rect2()
	if skip != null and is_instance_valid(skip):
		skip_rect = skip.get_global_rect().grow(4.0)
	var candidates := [
		canvas * Vector2(0.5, 0.92),
		canvas * Vector2(0.92, 0.5),
		canvas * Vector2(0.5, 0.08),
		canvas * Vector2(0.08, 0.5),
		canvas * Vector2(0.85, 0.85),
		canvas * Vector2(0.15, 0.85),
		canvas * Vector2(0.85, 0.15),
		canvas * Vector2(0.15, 0.15),
	]
	for p in candidates:
		if avoid.has_point(p) or skip_rect.has_point(p):
			continue
		return p
	return Vector2.INF


# 真实鼠标按下 + 抬起。**不 await**：中间让出帧的话 PrepScreen 有可能把
# `_overlay_suppressed` 顶回去，教程层一隐藏 `_input()` 就整段早退，测不出真东西。
func _click(canvas_pos: Vector2) -> void:
	var win := _canvas_to_window(canvas_pos)
	var vp := get_viewport()
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = win
	down.global_position = win
	vp.push_input(down)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = win
	up.global_position = win
	vp.push_input(up)


func _hover_at(canvas_pos: Vector2) -> Control:
	var win := _canvas_to_window(canvas_pos)
	var vp := get_viewport()
	var m := InputEventMouseMotion.new()
	m.position = win
	m.global_position = win
	vp.push_input(m)
	await _settle(2)
	return vp.gui_get_hovered_control()


# `push_input()` 收的是**窗口坐标**，而 `Control.get_global_rect()` 与
# `TutorialMode._input()` 里的 `event.position` 都是**画布坐标**。
# 基准 1600×720 时两者 1:1，其它分辨率（stretch=canvas_items + aspect=expand）必须换算。
func _canvas_to_window(pos: Vector2) -> Vector2:
	var vp := get_viewport()
	var canvas := vp.get_visible_rect().size
	var win := Vector2(vp.size)
	if canvas.x <= 0.0 or canvas.y <= 0.0:
		return pos
	return Vector2(pos.x * win.x / canvas.x, pos.y * win.y / canvas.y)


func _settle(frames: int = 2) -> void:
	for i in frames:
		await get_tree().process_frame
