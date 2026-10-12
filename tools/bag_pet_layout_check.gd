extends Node

# 10.12 反馈第 1 条（背包-宠物页）：选择宠物出战时
#   ① 点击别的宠物 → 立绘异常往上覆盖
#   ② 点击「松鼠」→ 页面下沉、宠物名字被遮盖一半
#   ③ 点击「老虎」→ 整个宠物选择栏消失
#
# 根因（三处同一个）：详情文案长度不同 ⇒ 页面最小高度不同 ⇒ 排在页面末尾的宠物栏
# 被顶出屏幕；演示台（原 CenterContainer）又把立绘框 480×376 当成自己的最小尺寸，
# 空间被压小后立绘越界往上盖。
#
# 本门禁用**几何判据**，与渲染无关（headless 即可）：
#   A 每个宠物、每种窗口尺寸下，宠物栏都必须完整落在屏幕内（不被顶出去）
#   B 立绘必须完全落在演示台矩形内（不越界覆盖上方标题 / 下方宠物栏）
#   C 右侧档案面板的最小高度必须被地板值钉住（文案再长也不能撑高面板）
#   D 面板本身也必须完整落在屏幕内
# 尺寸覆盖三种：常见 16:9 / 较矮的 1024×600 / 更矮的 960×540 —— 矮屏是最容易复现
# 用户那三张实拍的场景。

const H := preload("res://tools/CheckHarness.gd")
const BAG := preload("res://scenes/menu/BagScreen.gd")
const PetService := preload("res://scripts/pets/PetService.gd")

const SIZES := [Vector2i(1280, 720), Vector2i(1024, 600), Vector2i(960, 540)]
const EPS := 0.5
# 面板地板值（与 BagScreen.PET_DETAIL_MIN_HEIGHT 同口径）。这里写字面量而不是读常量：
# 常量被改大时门禁要红 —— 读同一个常量会跟着一起漂。
const DETAIL_FLOOR := 200.0
# 面板最小高度的允许余量（边框 / 滚动条各留几像素）。
const DETAIL_SLACK := 32.0

var h


func _ready() -> void:
	h = H.new("bag_pet_layout")

	var pet_ids: Array[String] = []
	for raw in PetService.all_pets():
		pet_ids.append(str((raw as Dictionary).get("id", "")))
	h.expect(pet_ids.size() >= 2, "fixture_pets",
		"宠物数据表至少要有 2 只才能测出战切换，实际 %d" % pet_ids.size())

	for size in SIZES:
		await _check_size(size, pet_ids)
	h.finish(get_tree())


func _check_size(size: Vector2i, pet_ids: Array[String]) -> void:
	# 用固定尺寸的壳子把屏幕撑到目标大小：根视口在 headless 里不一定能被改尺寸。
	var shell := Control.new()
	shell.custom_minimum_size = Vector2(size)
	shell.size = Vector2(size)
	add_child(shell)

	var bag: Control = BAG.new()
	bag.set_meta("ui_capture_fixture", true)
	bag.set("_loading", false)
	bag.set("_owned_pets", pet_ids)
	bag.set("_active_pet", pet_ids[0])
	bag.set("_paid_content", {})
	bag.set("_sold_content", {})
	bag.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shell.add_child(bag)
	await _settle()

	var roster: Control = bag.get("_pet_roster")
	var stage: Control = bag.get("_pet_stage")
	var detail: Control = bag.get("_pet_detail")
	h.expect(roster != null and stage != null and detail != null, "nodes_present",
		"%s 屏幕下 BagScreen 的关键节点应存在" % str(size))
	if roster == null or stage == null or detail == null:
		shell.queue_free()
		return

	# 面板 = 滚动容器 → PanelContainer。
	var scroll: Node = detail.get_parent()
	var panel: Control = scroll.get_parent() if scroll != null else null

	for pet_id in pet_ids:
		bag.set("_selected_pet", pet_id)
		bag.call("_refresh_pet_selection")
		await _settle()
		var label := "%s@%s" % [pet_id, str(size)]

		# A 宠物栏完整落在屏幕内。
		h.item()
		if roster.visible:
			var rr := roster.get_global_rect()
			var sr := shell.get_global_rect()
			h.expect(rr.end.y <= sr.end.y + EPS and rr.position.y >= sr.position.y - EPS,
				"roster_inside_screen",
				"%s 宠物栏越出屏幕：roster=%s shell=%s" % [label, str(rr), str(sr)])
		else:
			h.fail("roster_hidden", "%s 多只宠物时宠物栏不应隐藏" % label)

		# B 演示台里**有且只有**当前选中宠物的那一张立绘。
		#   ★ 10.12 第 1 条返修追加：原来只量 get_child(0)，于是「每点一只宠物就往
		#   演示台**追加**一张立绘」的 bug 溜了过去 —— 新立绘铺满演示台盖住旧的，
		#   旧的只从边上露一点，而 child(0) 仍然在台内 ⇒ 门禁恒绿。现在把**数量**
		#   和**身份**都钉死。
		h.item()
		h.expect(stage.get_child_count() == 1, "stage_single_artwork",
			"%s 演示台应只剩 1 张立绘（当前选中的那只），实际 %d 张（旧的没清掉 ⇒ 重影）" % [
				label, stage.get_child_count()])
		if stage.get_child_count() > 0:
			var tr := stage.get_global_rect()
			for i in stage.get_child_count():
				var art_node := stage.get_child(i)
				if not (art_node is Control):
					continue
				var ar := (art_node as Control).get_global_rect()
				h.item()
				h.expect(ar.position.y >= tr.position.y - EPS and ar.end.y <= tr.end.y + EPS
						and ar.position.x >= tr.position.x - EPS and ar.end.x <= tr.end.x + EPS,
					"artwork_inside_stage",
					"%s 立绘越出演示台：art=%s stage=%s" % [label, str(ar), str(tr)])
			# 台上那张立绘必须**就是**当前选中的宠物（不是别的宠物遗留下来的）。
			var icon_path := str(PetService.pet_by_id(pet_id).get("icon", ""))
			if not icon_path.is_empty() and ResourceLoader.exists(icon_path):
				var shown := _artwork_texture_path(stage.get_child(0))
				h.item()
				h.expect(shown == icon_path, "artwork_matches_selection",
					"%s 演示台上的立绘应属于 %s（%s），实际是 %s" % [
						label, pet_id, icon_path,
						shown if not shown.is_empty() else "<无贴图>"])
		else:
			h.fail("artwork_missing", "%s 演示台里应有一张立绘" % label)

		# C 面板最小高度被地板值钉住（长文案不许再撑高面板）。
		if panel != null:
			h.item()
			h.expect(panel.get_combined_minimum_size().y <= DETAIL_FLOOR + DETAIL_SLACK,
				"panel_min_height_bounded",
				"%s 面板最小高度 %s 超过地板值 %s（文案把面板撑高了）" % [
					label, str(panel.get_combined_minimum_size()), str(DETAIL_FLOOR)])
			# D 面板完整落在屏幕内。
			h.item()
			var pr := panel.get_global_rect()
			var sr2 := shell.get_global_rect()
			h.expect(pr.end.y <= sr2.end.y + EPS, "panel_inside_screen",
				"%s 面板越出屏幕：panel=%s shell=%s" % [label, str(pr), str(sr2)])

	# E ★ 10.12 第 1 条返修：模拟玩家「来回点不同宠物」的真实操作序列。
	#   每一步之后演示台都必须只剩 1 张立绘 —— 这正是用户复测时看到重影的路径
	#   （上面 A~D 是按顺序各点一次，单看 child(0) 抓不到累积）。
	if pet_ids.size() >= 2:
		var seq: Array[String] = [pet_ids[0], pet_ids[1], pet_ids[0]]
		if pet_ids.size() >= 3:
			seq.append(pet_ids[2])
		seq.append(pet_ids[1])
		for seq_pet in seq:
			bag.set("_selected_pet", seq_pet)
			bag.call("_refresh_pet_selection")
			await _settle()
			h.item()
			h.expect(stage.get_child_count() == 1, "interleaved_single_artwork",
				"%s 来回点宠物（%s）后演示台残留 %d 张立绘" % [
					str(size), "->".join(seq), stage.get_child_count()])

	shell.queue_free()


# 演示台里那张立绘（PetPreview.build_illustration 返回的 frame）内部是一个
# TextureRect；拿它的贴图路径来判断「台上到底摆的是谁」。
func _artwork_texture_path(frame: Node) -> String:
	if frame == null:
		return ""
	var stack: Array[Node] = [frame]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is TextureRect:
			var tex := (cur as TextureRect).texture
			if tex != null:
				return tex.resource_path
		for child in cur.get_children():
			stack.append(child)
	return ""


# 容器布局要几帧才收敛（立绘是 3D 预览回退时还要等 SubViewport 建好）。
func _settle() -> void:
	for _i in 6:
		await get_tree().process_frame
