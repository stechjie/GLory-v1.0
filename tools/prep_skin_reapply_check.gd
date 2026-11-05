extends Node

# 10.12 反馈第 7 条（棋盘皮肤在排位/组队里没生效）：
#   「在备战-棋盘皮肤界面选择了冰雪皮肤，但进行排位3v3对局，里面的皮肤切换为了普通
#     青草地皮肤。请你进行测试是否有这种情况，如果有请进行修复。」
#
# 根因：摆放界面的皮肤图是在 _build 那一刻按 PrepSkin.path() **定死**的（满屏 2D 垫底
# + 3D 各贴图层 + 萝卜 + 萤火虫色 + 河面波光），而"用哪张皮肤"是登录后**异步**从账号
# 服务器拉的（Bootstrap._fetch_loadout → PlayerProfile.refresh_prep_skin）。冷启动后
# 立刻排/进一场对局时，摆放界面常常在皮肤回来之前就建好了 —— 那一整局都是默认青草地，
# 正是测试员报的现象（3v3/排位只是"开局更快、更容易撞上"）。
#
# 修法：PrepScreen 监听 PlayerProfile.prep_skin_changed，皮肤晚到时调用
# PrepUI.reapply_prep_skin() 把已经建好的棋盘图**换过来**；没拉到过时进对局再补拉一次。
#
# 判据（这一条是"晚到"，所以要真把面板挂进树、真发信号、再读真节点上的图）：
#   A 默认皮肤建好 → 2D 垫底 / 3D 底图 / 河流 / 待命区都是默认那张
#   B 皮肤晚到（active_id 改冰雪 + 发 prep_skin_changed）→ 上面几层**全部**换成冰雪
#   C 再换回默认 → 全部换回去（不是只会变一次的单向补丁）
#   D 皮肤设置项也跟着走：冰雪 river_glow=false → 河面波光层隐藏；萤火虫色 = 冰雪白
#   G 河面整体位置也跟着走：river_drop 把画得偏高的河面挪到和草地同一条水线
#   F 河面波光的**图**也跟着走（10.31 补）：默认用那张照草地河道画的高光图；自带河面图的
#     皮肤改用它自己那张当波光源。只换显隐不换图的话，樱花会顶着草地那条青蓝流光
#     （实测就是这样，玩家反馈"河流怪怪的"）。
#   E 接线本身：PrepScreen 必须真连了信号（连不上时 B 会红——由 B 覆盖）

const H := preload("res://tools/CheckHarness.gd")
const PrepSkinC := preload("res://scenes/prep/PrepSkin.gd")
const PREP := preload("res://scenes/prep/PrepScreen.tscn")
const PrepBoardC := preload("res://scenes/prep/PrepBoardModels.gd")
const ICE := "prep_skin_ice"
const SELF_GLOW := "prep_skin_sakura"   # 自带河面图、且没关波光的皮肤
const DEFAULT := "prep_skin_default"
const ICE_FIREFLY := Color(0.86, 0.95, 1.0)

var h
var _firefly_default := Color.WHITE


func _ready() -> void:
	h = H.new("prep_skin_reapply")
	var saved: String = PrepSkinC.active_id
	var saved_loaded: bool = PrepSkinC.loaded
	PrepSkinC.active_id = DEFAULT

	var prep: Control = PREP.instantiate()
	add_child(prep)
	await _settle(prep, 14)

	_section_build(prep)
	await _section_arrive(prep)
	await _section_self_glow(prep)
	await _section_revert(prep)

	# 收尾：断开信号依赖、还原静态状态
	prep.queue_free()
	await _settle(null, 3)
	PrepSkinC.active_id = saved
	PrepSkinC.loaded = saved_loaded
	h.finish(get_tree())


func _section_build(prep: Control) -> void:
	h.expect(_path_of_slot(prep, "PrepFullscreenBackground") == _def("board"),
		"build_bg2d_default", "默认皮肤下满屏 2D 垫底应是默认棋盘图")
	# 11.05 起草地底图只走满屏 2D 背景（贴 3D 地面会被斜相机压扁、树比例跑掉），3D 里不该再有这层。
	h.expect(prep.find_child("PrepBaseLayer", true, false) == null,
		"build_no_base3d", "草地底图不应再贴在 3D 地面上（只用 2D 满屏背景）")
	h.expect(_plane_path(prep, "PrepRiverBottomLayer") == _def("river"),
		"build_river_default", "默认皮肤下河流应是默认图")
	h.expect(_plane_path(prep, "PrepStandbyBgLayer") == _def("bench"),
		"build_bench_default", "默认皮肤下待命区应是默认图")
	_firefly_default = _firefly_color(prep)
	h.expect(_color_close(_firefly_default, PrepSkinC.FIREFLY_DEFAULT), "build_firefly_default",
		"默认皮肤萤火虫应是金色，实为 %s" % str(_firefly_default))


func _section_arrive(prep: Control) -> void:
	PrepSkinC.active_id = ICE
	PlayerProfile.prep_skin_changed.emit()
	await _settle(prep, 6)
	h.expect(_path_of_slot(prep, "PrepFullscreenBackground") == _own(ICE, "board"),
		"arrive_bg2d_ice", "皮肤晚到后 2D 垫底应换成冰雪棋盘图（原来一直是青草地 ⇒ 本反馈）")
	h.expect(_plane_path(prep, "PrepRiverBottomLayer") == _own(ICE, "river"),
		"arrive_river_ice", "皮肤晚到后河流应换成冰雪图")
	h.expect(_plane_path(prep, "PrepStandbyBgLayer") == _own(ICE, "bench"),
		"arrive_bench_ice", "皮肤晚到后待命区应换成冰雪图")
	var carrot := prep.find_child("CarrotGeneratedSprite", true, false)
	var carrot_path := ""
	if carrot is Sprite3D and (carrot as Sprite3D).texture != null:
		carrot_path = (carrot as Sprite3D).texture.resource_path
	h.expect(carrot_path == _own(ICE, "carrot"),
		"arrive_carrot_ice", "皮肤晚到后萝卜应换成冰雪图，实为 %s" % carrot_path)
	var ice_firefly := _firefly_color(prep)
	h.expect(_color_close(ice_firefly, ICE_FIREFLY), "arrive_firefly_ice",
		"冰雪皮肤的萤火虫应是白色 %s，实为 %s" % [str(ICE_FIREFLY), str(ice_firefly)])
	h.expect(not _color_close(ice_firefly, _firefly_default), "arrive_firefly_changed",
		"皮肤晚到后萤火虫色应跟着换（不再是默认金）")
	# 冰雪 river_glow=false：那层照草地河道画的波光要隐藏
	var flow := prep.find_child("PrepRiverFlowBottom", true, false)
	if is_instance_valid(flow):
		h.expect(not (flow as Node3D).visible, "arrive_river_glow_off",
			"冰雪 river_glow=false，河面流动波光层应隐藏")


# F：自带河面图的皮肤，波光源要换成它自己那张（不是照草地河道画的那张）。
func _section_self_glow(prep: Control) -> void:
	if not PrepSkinC.has_skin(SELF_GLOW):
		return   # 这个包里没有这张皮肤的图（旧包）：没什么可查的
	PrepSkinC.active_id = SELF_GLOW
	PlayerProfile.prep_skin_changed.emit()
	await _settle(prep, 6)
	var flow := prep.find_child("PrepRiverFlowBottom", true, false)
	if not is_instance_valid(flow):
		return
	h.expect((flow as Node3D).visible, "self_glow_visible",
		"%s 没关 river_glow，波光层应显示" % SELF_GLOW)
	h.expect(_glow_path(prep) == _own(SELF_GLOW, "river"), "self_glow_uses_skin_river",
		"波光源应是皮肤自己的河面图，实为 %s" % _glow_path(prep))
	h.expect(_glow_cut(prep) > 0.0, "self_glow_cut_on",
		"用皮肤河面图当波光源时要切亮度（整条河都很亮，不切就是整条在滚）")
	# G（11.01 补）：河面画得比默认高的皮肤要整体往下游挪，底图和波光**两层用同一个偏移**。
	# 只换图不挪位置的话，水面会漫过待命区台子（玩家反馈「河流跑出上面的位置」）；
	# 只挪一层的话，波光会和水面错开。
	var want := PrepBoardC.PREP_BOARD_GROUND_CENTER.z + PrepSkinC.river_drop() * PrepBoardC.PREP_BOARD_GROUND_SIZE.y
	h.expect(PrepSkinC.river_drop() > 0.0, "self_glow_skin_drops_river",
		"%s 的河面比默认画得高，应当配了 river_drop" % SELF_GLOW)
	h.expect(is_equal_approx(_layer_z(prep, "PrepRiverBottomLayer"), want), "arrive_river_dropped",
		"皮肤晚到后河面底图应挪到 z=%.3f，实为 %.3f" % [want, _layer_z(prep, "PrepRiverBottomLayer")])
	h.expect(is_equal_approx(_layer_z(prep, "PrepRiverFlowBottom"), want), "arrive_glow_dropped",
		"波光层要和河面底图同一个 z，实为 %.3f" % _layer_z(prep, "PrepRiverFlowBottom"))


func _section_revert(prep: Control) -> void:
	PrepSkinC.active_id = DEFAULT
	PlayerProfile.prep_skin_changed.emit()
	await _settle(prep, 6)
	h.expect(_path_of_slot(prep, "PrepFullscreenBackground") == _def("board"),
		"revert_bg2d_default", "换回默认后 2D 垫底应回到默认棋盘图")
	var flow := prep.find_child("PrepRiverFlowBottom", true, false)
	if is_instance_valid(flow):
		h.expect((flow as Node3D).visible, "revert_river_glow_on",
			"换回草地后河面流动波光应重新显示（草地 river_glow=true）")
		h.expect(_glow_path(prep) == PrepBoardC.PREP_RIVER_BOTTOM_EF_PATH, "revert_glow_default_ef",
			"换回草地后波光源应回到那张专门画的高光图，实为 %s" % _glow_path(prep))
		h.expect(is_equal_approx(_glow_cut(prep), 0.0), "revert_glow_cut_off",
			"草地那张高光图是黑底，整张都该出，不许切亮度")
		# 草地没有 river_drop：换回来时河面要挪回原位（不是只会往下挪的单向补丁）
		h.expect(is_equal_approx(_layer_z(prep, "PrepRiverBottomLayer"), PrepBoardC.PREP_BOARD_GROUND_CENTER.z),
			"revert_river_z", "换回草地后河面应回到原位，实为 %.3f" % _layer_z(prep, "PrepRiverBottomLayer"))


# --- 工具 -------------------------------------------------------------------

func _def(slot: String) -> String:
	return str(PrepSkinC.SLOTS.get(slot, ""))


func _own(skin_id: String, slot: String) -> String:
	return PrepSkinC.SKIN_FILE % [skin_id, slot]


func _path_of_slot(prep: Control, node_name: String) -> String:
	var node := prep.find_child(node_name, true, false)
	if node is TextureRect and (node as TextureRect).texture != null:
		return (node as TextureRect).texture.resource_path
	return ""


func _plane_path(prep: Control, node_name: String) -> String:
	var node := prep.find_child(node_name, true, false)
	if node is MeshInstance3D:
		var mat := (node as MeshInstance3D).material_override
		if mat is StandardMaterial3D and (mat as StandardMaterial3D).albedo_texture != null:
			return (mat as StandardMaterial3D).albedo_texture.resource_path
	return ""


# 波光层当前用的是哪张图 / 切了多少亮度
func _layer_z(prep: Control, node_name: String) -> float:
	var node := prep.find_child(node_name, true, false)
	return (node as Node3D).position.z if node is Node3D else NAN


func _glow_material(prep: Control) -> ShaderMaterial:
	var node := prep.find_child("PrepRiverFlowBottom", true, false)
	if node is MeshInstance3D and (node as MeshInstance3D).material_override is ShaderMaterial:
		return (node as MeshInstance3D).material_override as ShaderMaterial
	return null


func _glow_path(prep: Control) -> String:
	var mat := _glow_material(prep)
	if mat == null:
		return ""
	var tex: Variant = mat.get_shader_parameter("river_tex")
	return (tex as Texture2D).resource_path if tex is Texture2D else ""


func _glow_cut(prep: Control) -> float:
	var mat := _glow_material(prep)
	if mat == null:
		return -1.0
	return float(mat.get_shader_parameter("highlight_cut"))


func _firefly_color(prep: Control) -> Color:
	var node := prep.find_child("PrepFireflies", true, false)
	if node is CPUParticles3D:
		var ramp := (node as CPUParticles3D).color_ramp
		if ramp != null and ramp.colors.size() >= 2:
			return ramp.colors[1]
	return Color.WHITE


func _color_close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.02 and absf(a.g - b.g) < 0.02 and absf(a.b - b.b) < 0.02


func _settle(prep: Control, frames: int) -> void:
	for _i in frames:
		await get_tree().process_frame
