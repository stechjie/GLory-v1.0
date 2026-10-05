extends Node

# 战斗加载读条（`BattleScreen._make_battle_prepare_bar`）的布局合同。
#
# 2026-09-27 那版要求是「黑色卡片 + 两行文字提示，且不能压到顶部 HUD」。
# **2026-10-05 用户反馈第 5 条把这个界面改掉了**：去掉文字提示与黑色底色（去掉的是
# 「正在准备战斗特效 · 11/13」那行字和它背后那块黑卡），只保留蓝色进度条，并在
# 进度条填充的右端放一只**玩家当前出战的宠物**，跟着进度一起前进。
#
# 所以这里测新合同。旧合同（StageText / LoadingBackdrop 必须存在）已作废 ——
# 保留旧断言会让「按要求改对」变成红，这正是"门禁写死了旧设计"的典型。
#
# 核心判据是**宠物位置真的跟着 value 走**：只断言「宠物节点在」证明不了这条，
# 把 _set_prepare_progress() 里的定位那两行删掉，节点照样在、条照样走。

const H := preload("res://tools/CheckHarness.gd")
const PetService := preload("res://scripts/pets/PetService.gd")
const PetPreview := preload("res://scripts/pets/PetPreview.gd")

# 与 BattleScreen._make_battle_prepare_bar() 里的蓝色填充一致。
const FILL_BLUE := Color(0.20, 0.95, 0.92, 1.0)
const TEST_PET := "pet_cat"

# ---- 10.05 第 5 条返工补的「宠物必须完整」判据（见 _check_pet_geometry）----
# 逐条入口检查时用的正方形框；与生产尺寸无关，量的是**比例**。
const PET_CHECK_SIZE := Vector2(160, 160)
# 投影留白下限（占视口短边）。读条上的宠物在播 run，动画摆动会吃掉余量
# （实测 1.16 档最坏一帧只剩 1px），所以读条比静止的正面卡严。
const RUNNER_MIN_MARGIN := 0.08
const FRONT_MIN_MARGIN := 0.05
# 脚底允许的偏差（世界单位）。宠物站在地面上 ⇒ 最低那根骨头应在 y≈0。
const FOOT_TOLERANCE := 0.08

class Preview:
	extends "res://scenes/battle/BattleScreen.gd"
	func _ready() -> void:
		set_process(false)


func _ready() -> void:
	var h := H.new("battle_loading_layout")
	var saved_pet := PlayerProfile.active_pet
	PlayerProfile.active_pet = TEST_PET
	var screen := Preview.new()
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(screen)
	# 顶部一条 HUD：读条期间不能被加载界面压住（原合同里唯一还成立的一条）。
	var hud := Label.new()
	hud.text = "第 3 回合 · 战斗信息"
	hud.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	hud.add_theme_font_size_override("font_size", 24)
	screen.add_child(hud)

	var bar := screen._make_battle_prepare_bar()
	await get_tree().process_frame
	h.expect(bar.get_node_or_null("StageText") == null, "stage_text_removed",
		"读条上的文字提示应当已经去掉（10.05 第 5 条）")
	h.expect(bar.get_node_or_null("LoadingBackdrop") == null, "backdrop_removed",
		"读条背后的黑色卡片应当已经去掉（10.05 第 5 条）")
	var fill = bar.get_theme_stylebox("fill")
	h.expect(fill is StyleBoxFlat and (fill as StyleBoxFlat).bg_color.is_equal_approx(FILL_BLUE),
		"blue_bar_kept", "蓝色进度条必须保留")

	var pet := bar.get_node_or_null("PreparePet") as Control
	h.expect(ResourceLoader.exists(PetService.model_path(TEST_PET)), "pet_model_missing",
		"测试用的宠物模型不存在，这一组用例没有真的跑到")
	if pet == null:
		h.expect(false, "pet_missing",
			"带了宠物时，读条上应当出现当前出战宠物的模型（10.05 第 5 条）")
	else:
		_check_pet_follows(h, screen, bar, pet)
		# ★ 10.05 实测补的判据：宠物必须**真的在播跑动动作**。
		#   只测位置会漏掉一个真实的坏法 —— 宠物脚本里是
		#   `@onready var animation_player := $AnimationPlayer`，而 build_runner 返回的
		#   frame 还没被 add_child 进树，模型此时不在树里，直接 `play_run()` 会在
		#   模型内部炸 `Cannot call method 'play' on a null value`；
		#   而**位置判据照样全绿**（节点在、value 在动）。所以「动起来了」要单独断言。
		h.expect(_pet_action(pet) == "run", "pet_running",
			"读条宠物应当在播 run 动作，实际动作=%s" % _pet_action(pet))
		h.expect(not pet.get_global_rect().intersects(hud.get_global_rect()), "hud_overlap",
			"读条宠物不得压到顶部 HUD")

	# ★★ 10.05 第 5 条返工补的判据：**宠物在画面里必须完整**。
	#
	# 为什么必须单独补：上面那一组（节点在 / 跟着 value 走 / 在播 run）在
	# 「宠物被裁掉一半」时**全是绿的** —— 用户 10.05 的截图正是这种：读条上那只猫
	# 只剩斗篷和一块白，而节点一个不少、动作也在播。
	# **不含几何量的判据等于没断言**（第 2 条的教训同款）。
	#
	# 门禁跑在 headless 下拿不到渲染像素，所以用几何量：被动画驱动、被渲染出来的
	# 几何是**骨骼当前姿势**，不是 `MeshInstance3D.get_aabb()`（那是绑定姿势，
	# 基准还错半身，见 scripts/pets/PetPreview.gd 的 `normalize()` 说明）。
	# 把骨骼盒投到视口上量四周留白，等价于量「宠物离画面边还有多远」。
	#   实测对照（160px 框、run 周期最坏一帧）：
	#     runner@1.16 → 骨骼 4.2% ／ 渲染 0.6%（擦边）
	#     runner@1.40 → 骨骼 12.0% ／ 渲染 9.4%（有余量）
	#   即骨骼留白 ≈ 渲染留白 + 3%；阈值取 8%/5% 时渲染侧仍留正余量。
	for pet_id in _all_pet_ids():
		await _check_pet_geometry(h, pet_id)

	# 没带宠物时：只留进度条，不放「?」占位框（玩家会以为加载出错了）。
	PlayerProfile.active_pet = ""
	var bare := screen._make_battle_prepare_bar()
	await get_tree().process_frame
	h.expect(bare.get_node_or_null("PreparePet") == null, "no_pet_no_placeholder",
		"没带宠物时读条上不该出现占位框")
	bare.queue_free()
	await get_tree().process_frame

	bar.queue_free()
	await get_tree().process_frame
	h.expect(not is_instance_valid(bar), "bar_cleanup", "进度条与宠物必须一起消失")
	PlayerProfile.active_pet = saved_pet
	screen.queue_free()
	h.finish(get_tree())


# 宠物中心必须贴在进度条填充的右端：0% 在最左、100% 在最右、中间单调。
func _check_pet_follows(h, screen, bar: ProgressBar, pet: Control) -> void:
	var width := bar.size.x
	h.expect(width > 400.0, "bar_width", "进度条宽度异常：%.1f" % width)
	var centers: Array[float] = []
	for percent in [0.0, 25.0, 50.0, 75.0, 100.0]:
		screen._set_prepare_progress(bar, percent)
		centers.append(pet.position.x + pet.size.x * 0.5)
	var monotonic := true
	for i in range(1, centers.size()):
		if centers[i] <= centers[i - 1]:
			monotonic = false
	h.expect(monotonic, "pet_not_following",
		"宠物没有跟着进度前进：%s" % str(centers))
	h.expect(absf(centers[0]) < 1.0, "pet_start",
		"0%% 时宠物中心应在进度条左端，实际 %.1f" % centers[0])
	h.expect(absf(centers[centers.size() - 1] - width) < 1.0, "pet_end",
		"100%% 时宠物中心应在进度条右端（%.1f），实际 %.1f" % [width, centers[centers.size() - 1]])
	# 中途必须落在两端之间，且大致成比例 —— 只测首尾的话「50% 卡在起点」也会全绿。
	var mid := centers[2]
	h.expect(mid > 1.0 and mid < width - 1.0, "pet_mid",
		"50%% 时宠物应落在中间，实际 %.1f（条宽 %.1f）" % [mid, width])
	h.expect(absf(mid - width * 0.5) < width * 0.05, "pet_mid_ratio",
		"50%% 时宠物中心应接近条中点，实际 %.1f（期望 %.1f）" % [mid, width * 0.5])


# 宠物模型当前播的动作名。直接读生产状态（`current_action`），
# 而不是自己去数 AnimationPlayer —— 后者只说明「有个播放器」，
# 说明不了「宠物切到跑动动作了」。
func _pet_action(frame: Node) -> String:
	var stack: Array[Node] = [frame]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current.has_method("play_run") and current.has_method("play_idle"):
			return str(current.get("current_action"))
		for child in current.get_children():
			stack.append(child)
	return ""


# 数据里所有**模型存在**的宠物。用数据驱动而不是写死三只：以后加宠物自动纳入，
# 「新宠物没被检查」这种漏网就不会发生。
func _all_pet_ids() -> Array:
	var out: Array = []
	for p in PetService.all_pets():
		var pet_id := str(p.get("id", ""))
		if pet_id.is_empty():
			continue
		var path := PetService.model_path(pet_id)
		if not path.is_empty() and ResourceLoader.exists(path):
			out.append(pet_id)
	return out


# 宠物预览的几何合同（见 _ready 里的说明）：
#   ① 脚底落地：最低那根骨头在世界空间的 y 必须 ≈ 0；
#      —— 这一条卡的是 `PetPreview.normalize()` 的基准。改坏前它拿**绑定姿势包围盒的
#      底**当脚底（盒子以原点为中心、基准错半身），宠物被整体抬高半身 ⇒ 头顶出画。
#   ② 整只在画面内：骨骼盒投到相机上，四边都要留够余量。
#      —— 这一条卡的是取景（正交尺寸）。改坏成 1.16 时最坏一帧只剩 4.2%。
#   ③ 高度归一：`normalize()` 的后置条件 —— 归一化之后宠物的**实际高度**必须约等于
#      `TARGET_HEIGHT`。这一条卡的是**归一化的时机**：`normalize()` 在模型进树前跑时
#      量到的兜底包围盒高度是 1.0，算出 scale 0.95（真实需要 0.60），宠物会偏大 1.6 倍；
#      而它脚底仍在 y=0、投影也还勉强在框内 ⇒ ①②都会放它过去。
func _check_pet_geometry(h, pet_id: String) -> void:
	for kind in ["runner", "front"]:
		var frame: Control
		if kind == "runner":
			frame = PetPreview.build_runner(pet_id, PET_CHECK_SIZE)
		else:
			frame = PetPreview.build(pet_id, PET_CHECK_SIZE)
		if frame == null:
			h.expect(false, "pet_frame_%s_%s" % [pet_id, kind],
				"%s 的 %s 预览为空（模型缺失？）" % [pet_id, kind])
			continue
		add_child(frame)
		await get_tree().process_frame
		await get_tree().process_frame
		var model := _find_model3d(frame)
		var camera := _find_camera(frame)
		var viewport := _find_viewport(frame)
		if model == null or camera == null or viewport == null:
			h.expect(false, "pet_nodes_%s_%s" % [pet_id, kind],
				"%s 的 %s 预览缺件：model=%s camera=%s viewport=%s" % [pet_id, kind,
					str(model != null), str(camera != null), str(viewport != null)])
		else:
			var bones := _world_bone_box(model)
			h.expect(absf(bones.position.y) <= FOOT_TOLERANCE,
				"pet_feet_%s_%s" % [pet_id, kind],
				"%s 的 %s 预览脚底应落在 y=0（地面），实际 %.3f" % [
					pet_id, kind, bones.position.y])
			var vsize := Vector2(viewport.size)
			var shortest := minf(vsize.x, vsize.y)
			var margin := _worst_projected_margin(camera, bones, vsize)
			var need := RUNNER_MIN_MARGIN if kind == "runner" else FRONT_MIN_MARGIN
			h.expect(margin >= need * shortest,
				"pet_fits_%s_%s" % [pet_id, kind],
				"%s 的 %s 预览露边：最小投影留白 %.1fpx（视口 %.0fpx，要求 ≥ %.1fpx）" % [
					pet_id, kind, margin, shortest, need * shortest])
			# ③ 归一化的后置条件：实际高度 = 网格盒高 × 模型缩放。
			#    网格盒的**高度**可信（实测与骨骼一致），基准才是错的（见 normalize 说明）。
			var world_height := PetPreview.aabb_of(model).size.y * model.scale.y
			var want := PetPreview.TARGET_HEIGHT
			h.expect(absf(world_height - want) <= want * 0.05,
				"pet_height_%s_%s" % [pet_id, kind],
				"%s 的 %s 预览归一化后高度应 ≈ %.2f，实际 %.3f（缩放 %.3f）" % [
					pet_id, kind, want, world_height, model.scale.y])
		frame.queue_free()
		await get_tree().process_frame


# 模型当前姿势下、所有骨骼原点在**世界空间**的包围盒（含 FBX Armature 的 100× 缩放）。
# 用骨骼而不是 `MeshInstance3D.get_aabb()`：后者是绑定姿势且基准错半身。
func _world_bone_box(root: Node3D) -> AABB:
	var found := false
	var out := AABB()
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		for child in current.get_children():
			stack.append(child)
		if not (current is Skeleton3D):
			continue
		var skeleton := current as Skeleton3D
		for i in skeleton.get_bone_count():
			var p: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(i).origin
			if found:
				out = out.expand(p)
			else:
				out = AABB(p, Vector3.ZERO)
				found = true
	return out if found else AABB()


# 把包围盒 8 个角投到相机上，返回四边里最小的那个留白（px）。负数＝已经出画。
func _worst_projected_margin(camera: Camera3D, bounds: AABB, vsize: Vector2) -> float:
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for i in 8:
		var corner := bounds.position + Vector3(
			bounds.size.x if (i & 1) else 0.0,
			bounds.size.y if (i & 2) else 0.0,
			bounds.size.z if (i & 4) else 0.0)
		var sp := camera.unproject_position(corner)
		lo = lo.min(sp)
		hi = hi.max(sp)
	return minf(minf(lo.x, lo.y), minf(vsize.x - hi.x, vsize.y - hi.y))


func _find_camera(root: Node) -> Camera3D:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is Camera3D:
			return current as Camera3D
		for child in current.get_children():
			stack.append(child)
	return null


func _find_viewport(root: Node) -> SubViewport:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is SubViewport:
			return current as SubViewport
		for child in current.get_children():
			stack.append(child)
	return null


func _find_model3d(root: Node) -> Node3D:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is Node3D and current.has_method("play_run") and current.has_method("play_idle"):
			return current as Node3D
		for child in current.get_children():
			stack.append(child)
	return null
