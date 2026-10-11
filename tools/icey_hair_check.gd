extends Node

# 10.12 反馈第 3 条（霜印使发色）：
#   「对局里霜印使的棋子模型和图片差距过大，最明显的是发色：图片是红衣白发，模型是红衣红发。
#     优化为：棋子模型改成白发，要和图片设计更贴切。」
#
# 根因：精修脚本 crimson_refine.py 里有一段 **只在 Icey 上生效**的整发重上色
# （`if unit == "Icey": ... recolour_hair(...)`，源于 2026-10-05「把 Icey 头发刷成族红」
# 的旧决定），霜印使（model Icey_refined.tscn → Icey_m0_albedo.png）的白发因此被刷红。
# 修法：删掉这段 Icey 专属重上色，霜印使回归**源贴图**（原始 crimson_race/Icey.glb 的
# baseColorTexture，本来就是白/银发）；材质侧 unify_min_saturation=0.5 保证低饱和的白色
# 发丝不被 race_hue 统一成红色。该改动只动 Icey 一支，其余 7 个赤律族单位不受影响。
#
# 判据分两段（缺一不可）：
#   A 接线：race_units.json 里霜印使指向精修模型；贴图能加载、且 ≤1024 预算
#   B 贴图本身：从**实际运行的 albedo 像素**统计 —— 泛白（低饱和·高亮度）像素占比要
#     高、正红像素占比要低。刷成红发的版本这一条必红（白区间被填成红）
#   C 材质守卫：Icey_m0.tres 的 unify_min_saturation 必须 ≥ 0.45 ——
#     低于它（发丝的白）hue pull = 0，不会被 race_hue 拉红；回归默认 0.18 会红
#
# ★ 只量「贴图尺寸 ≤1024」是不够的：那是资源预算，和发色无关（本门禁第一版正是如此，
#   被这轮补齐）。

const H := preload("res://tools/CheckHarness.gd")
const UNIT_ID := "Icey"
const MODEL_EXPECT := "res://assets/models/units/crimson_refined/Icey/Icey_refined.tscn"
const ALBEDO_PATH := "res://assets/models/units/crimson_refined/Icey/Icey_m0_albedo.png"
const MATERIAL_PATH := "res://assets/models/units/crimson_refined/Icey/Icey_m0.tres"
# 泛白发丝 vs 正红披风的判据（在 0..1 的 sRGB 空间量，见 race_body.gdshaderinc 的分类口径）
const PALE_SAT := 0.35
const PALE_VAL := 0.55
const PALE_MIN_FRAC := 0.60
const RED_MAX_FRAC := 0.25
const UNIFY_MIN := 0.45
const SAMPLE_STEP := 4

var h


func _ready() -> void:
	h = H.new("icey_hair")
	_section_wiring()
	_section_albedo()
	_section_material()
	h.finish(get_tree())


# --- A 接线 -----------------------------------------------------------------

func _section_wiring() -> void:
	var def := _unit_def()
	h.expect(not def.is_empty(), "unit_found", "race_units 里应有 id=%s 的霜印使" % UNIT_ID)
	h.expect(str(def.get("model", "")) == MODEL_EXPECT, "model_path",
		"霜印使应指向精修模型 %s，实为 %s" % [MODEL_EXPECT, str(def.get("model", ""))])
	var scene: Resource = load(MODEL_EXPECT)
	h.expect(scene is PackedScene, "scene_loads", "精修模型场景应能加载")
	var tex: Texture2D = load(ALBEDO_PATH) as Texture2D
	h.item()
	h.expect(tex != null, "albedo_loads", "霜印使 albedo 贴图应能加载")
	if tex == null:
		return
	h.item()
	h.expect(maxi(tex.get_width(), tex.get_height()) <= 1024, "albedo_budget",
		"albedo 应 ≤1024，实为 %dx%d" % [tex.get_width(), tex.get_height()])


# --- B 贴图本身 -------------------------------------------------------------

func _section_albedo() -> void:
	# 直读源 PNG（而不是 load() 出来的导入贴图）：导入贴图走的是 .godot/imported 里的
	# .ctex 缓存，改了源文件但没重导时它还是旧的 —— 那会把「源文件已被刷红」这种变异
	# 悄悄放过（本门禁第一版就踩了：变异 B 明明是红发，门禁仍读旧缓存报 PASS）。
	var img := Image.load_from_file(ALBEDO_PATH)
	if img == null:
		h.fail("albedo_load_from_file", "无法直接读取 albedo 源文件")
		return
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	var data := img.get_data()
	var w := img.get_width()
	var hh := img.get_height()
	var stride := w * 3
	var total := 0
	var pale := 0
	var red := 0
	var y := 0
	while y < hh:
		var x := 0
		while x < w:
			var o := y * stride + x * 3
			var r := float(data[o]) / 255.0
			var g := float(data[o + 1]) / 255.0
			var b := float(data[o + 2]) / 255.0
			var mx := maxf(r, maxf(g, b))
			var mn := minf(r, minf(g, b))
			var sat := 0.0 if mx <= 1e-6 else (mx - mn) / mx
			total += 1
			if sat < PALE_SAT and mx > PALE_VAL:
				pale += 1
			if sat > 0.5 and r > g + 0.1 and r > b + 0.1:
				red += 1
			x += SAMPLE_STEP
		y += SAMPLE_STEP
	h.expect(total > 0, "pixels_sampled", "应采到像素")
	var pale_frac := float(pale) / maxf(1.0, float(total))
	var red_frac := float(red) / maxf(1.0, float(total))
	h.note("霜印使 albedo：泛白 %.1f%% / 正红 %.1f%%（采样 %d）" % [pale_frac * 100.0, red_frac * 100.0, total])
	h.expect(pale_frac >= PALE_MIN_FRAC, "albedo_is_pale_hair",
		"泛白发丝应占多数（≥%.0f%%），实为 %.1f%% —— 贴图疑似被刷成红发" % [PALE_MIN_FRAC * 100.0, pale_frac * 100.0])
	h.expect(red_frac <= RED_MAX_FRAC, "albedo_not_red_hair",
		"正红像素应占少数（≤%.0f%%），实为 %.1f%% —— 贴图疑似整片红" % [RED_MAX_FRAC * 100.0, red_frac * 100.0])


# --- C 材质守卫 -------------------------------------------------------------

func _section_material() -> void:
	var mat: ShaderMaterial = load(MATERIAL_PATH) as ShaderMaterial
	if mat == null:
		h.fail("material_loads", "霜印使材质应能加载")
		return
	var unify := 0.0
	if mat.get_shader_parameter("unify_min_saturation") != null:
		unify = float(mat.get_shader_parameter("unify_min_saturation"))
	h.note("霜印使 unify_min_saturation = %.3f" % unify)
	h.expect(unify >= UNIFY_MIN, "pale_hair_guarded",
		"unify_min_saturation 应 ≥%.2f，低饱和的白发才不会被 race_hue 拉红；实为 %.3f" % [UNIFY_MIN, unify])
	if mat.get_shader_parameter("race_hue") != null:
		var race_hue := float(mat.get_shader_parameter("race_hue"))
		h.expect(race_hue > 0.9 or race_hue < 0.1, "race_hue_red",
			"赤律族 race_hue 应贴红（≈0.99 或 ≈0.0），实为 %.3f" % race_hue)


# --- 工具 -------------------------------------------------------------------

func _unit_def() -> Dictionary:
	for raw in DataRegistry.get_table("race_units").get("units", []):
		if typeof(raw) == TYPE_DICTIONARY and str((raw as Dictionary).get("id", "")) == UNIT_ID:
			return raw
	return {}
