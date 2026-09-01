extends Node

# V2 P1-04 第 2 条 +「统一战场轮廓」的门禁。
#
# 先说实测把 V2 原文修正掉的两点，免得将来有人照原文改坏：
#
# 1. **不存在"资源中预烘焙的粗黑边"。** 角色贴图是 4096x4096 的 UV 图集
#    （如 human_king_texture.png），黑的是未使用的 UV 空间，不是画进去的描边。
#    描边本来就已经是 shader：shaders/character_outline.gdshader，以 next_pass
#    反向外扩（VERTEX += NORMAL * outline_width）实现。所以"改用统一 shader
#    outline"这件事本身早就做了。
#
# 2. **墨色和宽度不能统一成一个值。** 实测颜色是按种族有意分的（人族暖黑、
#    暗族紫黑、亡灵紫、神族蓝灰，每个 Boss 一套），宽度是按类别调过的
#    （怪物 0.010-0.017、Boss 0.018-0.022、单位 0.022-0.034、佣兵全 0.026）。
#    Boss 那一档明显已经手工补偿过它 2.0 的 model_visual_scale —— 再在 shader
#    里做缩放归一化就会补偿两次，把 Boss 的墨线削得过细。
#
# 3. **4 个援军 + abyss_beast 没有描边，不是漏做，是必要的省略。**
#    我一开始把它判成漂移，给它们补上了描边 —— 静态渲染当场证明是错的：
#    模型整个变成一团黑（near_black_ratio 从 0.003-0.335 跳到 0.99+），
#    而且从 0.028 一路试到 0.001 每个宽度都一样。参照组（human_king / human_archer /
#    古树长者）加了描边是 0.13-0.23。也就是说这几个网格根本吃不下反向外扩壳
#    （多半是法线或绕序反了），壳会盖住模型本体而不是围在外面。补描边要先修网格。
#    已撤销，并在下面登记为有依据的豁免。
#
# 所以真正的缺口只剩两处，也是这个门禁守的东西：
#   * merc_virgo_heal 和圣裁者的武器漏了描边（已补，静态渲染验证 image_failures=0）
#   * human_swordsman 一个单位的两个材质用了两种墨色（已收敛到人族墨色）

const CheckHarness := preload("res://tools/CheckHarness.gd")
const CHECK_NAME := "character_outline"

const OUTLINE_SHADER := "res://shaders/character_outline.gdshader"
const MODELS_ROOT := "res://assets/models"

# 战场上会出现的角色目录。pets 不在其中：实测没有任何活代码或数据表引用
# assets/models/pets/*，只有 2026-08-20 的旧备份 bundle 里还留着文件名。
const BATTLEFIELD_DIRS := ["units", "mercenaries", "monsters", "bosses", "allies"]

# 每一类的宽度合理区间。区间是从实测分布来的，留了余量；
# 它守的是"没有离谱值"，不是"必须等于某个数"——按类别微调是允许的。
const WIDTH_BANDS := {
	"units": [0.018, 0.038],
	"mercenaries": [0.022, 0.030],
	"monsters": [0.008, 0.020],
	"bosses": [0.014, 0.026],
}

# 有依据的豁免：目录标记 -> 为什么这个材质没有描边。
#
# 每一条都是实测结论，不是"先放过去"。谁想给这里的材质补描边，请先读 reason ——
# 我已经补过一次并且被静态渲染打回来了。
const OUTLINE_EXEMPT := {
	"formation_ally_1_animated":
		"内嵌近白 StandardMaterial3D，目录里连贴图都没有；补它要美术资源，"
		+ "已由 model_material_integrity_check 以 white_material_suspect 盯着",
	"formation_ally_2_animated":
		"网格吃不下反向外扩壳：加描边后 near_black_ratio 0.003->0.99，0.028 到 0.001 全一样",
	"formation_ally_3_animated":
		"同 formation_ally_2：外扩壳会盖住模型本体而不是围在外面",
	"formation_ally_4_animated":
		"同 formation_ally_2：实测 0.335->0.994，参照组只有 0.13-0.23",
	"formation_ally_5_animated":
		"同 formation_ally_2：外扩壳会盖住模型本体",
	"abyss_beast_animated":
		"同 formation_ally_2：加描边后整体变黑并触发 mostly_black 粗筛",
}

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_shader_is_lightweight()
	var materials := _collect_materials()
	if not _h.expect(materials.size() >= 60, "too_few_materials",
		"只扫到 %d 个角色材质，目录结构可能变了" % materials.size()):
		_h.finish(get_tree())
		return
	_check_every_character_has_outline(materials)
	_check_width_bands(materials)
	_check_one_ink_per_unit(materials)
	_h.finish(get_tree())


# 项目里所有战场角色材质：[{path, category, text}]
func _collect_materials() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for category in BATTLEFIELD_DIRS:
		_collect_into(out, "%s/%s" % [MODELS_ROOT, category], category)
	return out


func _collect_into(out: Array[Dictionary], dir_path: String, category: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := "%s/%s" % [dir_path, entry]
		if dir.current_is_dir():
			if not entry.begins_with("."):
				_collect_into(out, full, category)
		elif entry.ends_with(".tres"):
			var text := FileAccess.get_file_as_string(full)
			if not text.is_empty():
				out.append({"path": full, "category": category, "text": text})
		entry = dir.get_next()
	dir.list_dir_end()


# 第 2 条的"移动端只用单次采样/轻量描边"：反向外扩本来就是最省的做法 ——
# 一次额外绘制、unshaded、不采样任何贴图。这里把它钉住，防止有人改成多次采样。
func _check_shader_is_lightweight() -> void:
	var src := FileAccess.get_file_as_string(OUTLINE_SHADER)
	if not _h.expect(not src.is_empty(), "outline_shader_missing",
		"读不到 %s —— 统一 shader 描边的载体没了" % OUTLINE_SHADER):
		return
	_h.expect(src.contains("unshaded"),
		"outline_not_unshaded",
		"描边 shader 不再是 unshaded —— 会跟着光照走，等于多一份计算")
	_h.expect(src.contains("cull_front"),
		"outline_not_inverted_hull",
		"描边 shader 不再 cull_front —— 反向外扩的做法被换掉了")
	_h.expect(not src.contains("texture("),
		"outline_samples_texture",
		"描边 shader 里出现了 texture() 采样 —— V2 要求移动端只用单次采样/轻量描边")
	# 多次采样的典型写法：在 fragment 里循环取邻域。
	_h.expect(not src.contains("for ("),
		"outline_has_loop",
		"描边 shader 里出现了循环 —— 多重采样描边在移动端太贵")


func _check_every_character_has_outline(materials: Array) -> void:
	var missing: Array[String] = []
	var exempt_seen := {}
	for item in materials:
		var entry: Dictionary = item
		var path := str(entry["path"])
		var has_outline := str(entry["text"]).contains(OUTLINE_SHADER)
		var exemption := _exemption_for(path)
		if not exemption.is_empty():
			exempt_seen[exemption] = true
			# 豁免的材质**不该**带描边：带了就说明有人又补了一次，
			# 而实测证明那会让模型变成一团黑。这条比"漏了描边"更要紧。
			_h.expect(not has_outline,
				"exempt_material_got_outline",
				"%s 被登记为不能加描边，却带上了 character_outline。原因：%s"
					% [path.replace(MODELS_ROOT + "/", ""), exemption])
			continue
		if not has_outline:
			missing.append(path.replace(MODELS_ROOT + "/", ""))
	_h.expect(missing.is_empty(),
		"character_without_outline",
		"这些战场角色材质没有描边，站在有描边的单位旁边会显得没有轮廓：\n  %s"
			% "\n  ".join(missing))
	_h.note("扫描 %d 个角色材质：非豁免的全部带 character_outline，命中 %d 条豁免"
		% [materials.size(), exempt_seen.size()])


func _check_width_bands(materials: Array) -> void:
	for item in materials:
		var entry: Dictionary = item
		var text := str(entry["text"])
		if not text.contains(OUTLINE_SHADER):
			continue
		var width := _parse_float(text, "shader_parameter/outline_width = ")
		var category := str(entry["category"])
		var band: Array = WIDTH_BANDS.get(category, [0.005, 0.05])
		var short := str(entry["path"]).replace(MODELS_ROOT + "/", "")
		if not _h.expect(width > 0.0, "outline_width_missing",
			"%s 引用了描边 shader 却没写 outline_width" % short):
			continue
		_h.expect(width >= float(band[0]) and width <= float(band[1]),
			"outline_width_out_of_band",
			"%s 的描边宽度 %.4f 不在 %s 档的 %.3f-%.3f —— 墨线粗细会和同类单位对不上"
				% [short, width, category, float(band[0]), float(band[1])])


# 同一个单位的多个材质（本体/武器/分部件）必须用同一种墨色，
# 否则同一个角色身上会出现两种轮廓色。human_swordsman 就踩过这个。
func _check_one_ink_per_unit(materials: Array) -> void:
	var by_dir := {}
	for item in materials:
		var entry: Dictionary = item
		var text := str(entry["text"])
		if not text.contains(OUTLINE_SHADER):
			continue
		var color := _parse_line(text, "shader_parameter/outline_color = ")
		if color.is_empty():
			continue
		var dir_path := str(entry["path"]).get_base_dir()
		if not by_dir.has(dir_path):
			by_dir[dir_path] = {}
		(by_dir[dir_path] as Dictionary)[color] = true
	for dir_path in by_dir:
		var colors: Dictionary = by_dir[dir_path]
		_h.expect(colors.size() <= 1,
			"unit_has_two_ink_colors",
			"%s 下的材质用了 %d 种描边色：%s —— 同一个角色身上不该出现两种轮廓色"
				% [str(dir_path).replace(MODELS_ROOT + "/", ""), colors.size(),
					", ".join(PackedStringArray(colors.keys()))])


# 返回这个材质的豁免理由；没有登记就返回空串。
func _exemption_for(path: String) -> String:
	for marker in OUTLINE_EXEMPT:
		if path.contains(str(marker)):
			return str(OUTLINE_EXEMPT[marker])
	return ""


func _parse_float(text: String, key: String) -> float:
	var line := _parse_line(text, key)
	return line.to_float() if not line.is_empty() else -1.0


func _parse_line(text: String, key: String) -> String:
	var at := text.find(key)
	if at < 0:
		return ""
	var rest := text.substr(at + key.length())
	var end := rest.find("\n")
	if end >= 0:
		rest = rest.substr(0, end)
	return rest.strip_edges()
