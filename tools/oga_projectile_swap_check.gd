extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const CHECK_NAME := "oga_projectile_swap"
const CATALOG := preload("res://effects/vfx3d/units/OgaChessVFXCatalog.gd")
const COMPOSER_PATH := "res://effects/vfx3d/units/UnitSkillVFXComposer3D.gd"

# 9.24 订正 #2：神侍 ↔ 极光射手普攻投射物「只对换模型，飞行速度不变」。
#
# 为什么需要这条门禁 —— 上一版改错了地方，而且**没有任何既有门禁会红**：
#   玩家棋子（32 只）的远程普攻**不走** UnitSkillVFXComposer3D 里的
#   `BOLT_KIND_BY_UNIT` / `PROJECTILE_TEX_BY_UNIT` —— `_basic_attack` 一开头就查
#   `OGA_CHESS_CATALOG.projectile_for(uid)`，**命中即 return**。
#   9.24 第一版把「对换」写在那边 = 死代码：编译通过、批跑全绿、用户肉眼无变化
#   （用户报的就是「未对换完成」）。
#
# 所以这里把两件事钉成可执行断言：
#   ① 权威表是 OGA 目录 —— 用**源码先后顺序**断言 precedence，而不是靠注释里的口头约定；
#   ② 对换后的模型，以及「速度留在原主身上」这个用户口径。
#      ★ 只要有人把对换改回、改反、或顺手把 speed 一起换掉，这条就会红。
#
# 9.24 订正 #6：弓箭手普攻投射物 → 金属箭矢。同一个高危区（弓箭手也是玩家棋子），
#   再加 4 条断言：模型确实是金属箭、贴图分格能整切、**朝向仍是 45° 右上**、
#   且「只改形态」没有顺带改飞行速度 / 误伤命中特效。
const MODEL_AFTER_SWAP := {
	"god_priest": "res://assets/vfx/oga/projectiles/god_aurora_light_spear.png",
	"god_aurora": "res://assets/vfx/oga/projectiles/god_priest_star_lance.png",
}

# 用户口径：**只对换模型，飞行速度不变**。这两条速度必须留在原主身上。
const SPEED_UNCHANGED := {
	"god_priest": 5.6,
	"god_aurora": 10.5,
}

# --- #6 弓箭手金属箭 -----------------------------------------------------------
const ARCHER_METAL_ARROW := "res://assets/vfx/oga/projectiles/human_archer_metal_arrow.png"
const ARCHER_IMPACT := "res://assets/vfx/oga/impacts/human_archer_hit.png"
const ARCHER_SPEED := 11.5
const ARCHER_COLUMNS := 6
const ARCHER_ROWS := 1
# 贴图约定的前向轴：箭尖在画面**右上 45°**（0=朝右, 90=朝上）。
# 原图实测 44.0~46.3°，所以给 ±20° 的宽容带，够挡「换成朝右的箭」这类错误。
const ARCHER_FORWARD_TOL := 20.0

const REQUIRED_KEYS: Array[String] = [
	"path", "columns", "rows", "frame_count", "fps", "size", "speed",
	"impact_path", "impact_columns", "impact_rows", "impact_frames", "impact_fps", "impact_size",
]


func _ready() -> void:
	var h := CheckHarness.new(CHECK_NAME)
	_check_catalog_precedence(h)
	_check_swap(h)
	_check_speed_preserved(h)
	_check_archer_metal_arrow(h)
	_check_unique_paths(h)
	h.finish(get_tree())


# ① 权威表判据：`_basic_attack` 必须先查 OGA 目录并 return，才轮到 race bolt。
# 用源码文本顺序断言，因为这是「谁先谁后」的问题 —— 运行期两跳之外看不出来。
func _check_catalog_precedence(h: CheckHarness) -> void:
	if not FileAccess.file_exists(COMPOSER_PATH):
		h.fail("composer_missing", "找不到 %s" % COMPOSER_PATH)
		return
	var source := FileAccess.get_file_as_string(COMPOSER_PATH)
	var start := source.find("func _basic_attack")
	if start < 0:
		h.fail("basic_attack_missing", "_basic_attack 不在 %s 里（函数被改名或删掉了）" % COMPOSER_PATH)
		return
	var next := source.find("\nfunc ", start + 1)
	var body := source.substr(start, (next - start) if next > 0 else -1)

	var at_catalog := body.find("projectile_for(uid)")
	var at_race := body.find("VFX_RACE_BASIC_ATTACK")
	var at_bolt_tex := body.find("PROJECTILE_TEX_BY_UNIT")

	if not h.expect(at_catalog >= 0, "catalog_lookup_missing",
			"_basic_attack 里找不到 OGA_CHESS_CATALOG.projectile_for(uid)：玩家棋子的权威弹体表被摘掉了"):
		return
	h.expect(at_race >= 0, "race_bolt_missing",
		"_basic_attack 里找不到 VFX_RACE_BASIC_ATTACK 兜底：非玩家棋子会没有任何远程弹体")
	# 这是本条门禁的核心：目录查询必须排在 race bolt **之前**，
	# 否则 player chess 会被 race bolt 抢走（9.24 第一版的假设就是这么来的）。
	h.expect(at_race < 0 or at_catalog < at_race, "catalog_after_race_bolt",
		"OGA 目录查询排在了 VFX_RACE_BASIC_ATTACK 之后 —— 玩家棋子的普攻会被 race bolt 抢走，"
		+ "写在那两张表上的改动全部失效（这正是 9.24 #2 第一版的错误）")
	# PROJECTILE_TEX_BY_UNIT 是**构造 race bolt 参数的语句**，天然排在 _spawn 之前 ——
	# 要断言的是它排在 **OGA 目录查询之后**（否则玩家棋子会先被贴图表截走）。
	h.expect(at_bolt_tex < 0 or at_catalog < at_bolt_tex, "bolt_tex_before_catalog",
		"PROJECTILE_TEX_BY_UNIT 用在了 OGA 目录查询之前 —— 玩家棋子会被 race bolt 的贴图表截走，对换失效")


# ② 模型对换：神侍拿极光的枪、极光拿神侍的星矛。
func _check_swap(h: CheckHarness) -> void:
	var paths := {}
	for unit_id in MODEL_AFTER_SWAP.keys():
		var want := str(MODEL_AFTER_SWAP[unit_id])
		var spec: Dictionary = CATALOG.projectile_for(str(unit_id))
		if not h.expect(not spec.is_empty(), "spec_missing",
				"%s 在 OGA 目录里没有投射物 spec —— 对换前提不成立" % unit_id):
			continue
		var got := str(spec.get("path", ""))
		h.expect(got == want, "model_not_swapped",
			"%s 的模型是 %s，期望 %s（对换未生效或被改回）" % [unit_id, got, want])
		h.expect(ResourceLoader.exists(want), "model_resource_missing",
			"%s 期望的模型资源不存在：%s" % [unit_id, want])
		paths[str(unit_id)] = got
		for key in REQUIRED_KEYS:
			h.expect(spec.has(key), "missing_key",
				"%s 的 spec 缺 %s" % [unit_id, key])
	# 两只必须拿的是**对方**原来那张图 —— 否则就是「换了一半」。
	if paths.size() == 2:
		h.expect(paths["god_priest"] != paths["god_aurora"], "same_model",
			"神侍与极光射手拿到了同一张模型图，谈不上对换")


# ③ 速度留在原主：这是用户明确口径，换模型不许顺带改飞行速度。
func _check_speed_preserved(h: CheckHarness) -> void:
	for unit_id in SPEED_UNCHANGED.keys():
		var spec: Dictionary = CATALOG.projectile_for(str(unit_id))
		if spec.is_empty():
			h.fail("spec_missing_for_speed", "%s 没有 spec，无法校验飞行速度" % unit_id)
			continue
		var got := float(spec.get("speed", -1.0))
		h.expect(is_equal_approx(got, float(SPEED_UNCHANGED[unit_id])), "speed_changed",
			"%s 的飞行速度是 %.2f，期望 %.2f —— 用户口径是「只对换模型，飞行速度不变」"
			% [unit_id, got, float(SPEED_UNCHANGED[unit_id])])


# ④ 弓箭手金属箭（9.24 #6）：只许改「形态」，不许顺带改速度、也不许误伤命中特效。
func _check_archer_metal_arrow(h: CheckHarness) -> void:
	var spec: Dictionary = CATALOG.projectile_for("human_archer")
	if not h.expect(not spec.is_empty(), "archer_spec_missing",
			"human_archer 在 OGA 目录里没有 spec —— #6 金属箭的前提不成立"):
		return
	var got_path := str(spec.get("path", ""))
	h.expect(got_path == ARCHER_METAL_ARROW, "archer_not_metal_arrow",
		"弓箭手普攻弹体是 %s，期望 %s（被改回风之箭 / 换图失效）"
		% [got_path, ARCHER_METAL_ARROW])
	h.expect(ResourceLoader.exists(ARCHER_METAL_ARROW), "archer_texture_missing",
		"金属箭贴图不存在或未导入：%s（新增 PNG 必须跑一次 --import 重导）" % ARCHER_METAL_ARROW)
	h.expect(int(spec.get("columns", 0)) == ARCHER_COLUMNS and int(spec.get("rows", 0)) == ARCHER_ROWS,
		"archer_grid_mismatch",
		"弓箭手 spec 的分格是 %dx%d，期望 %dx%d" % [
			int(spec.get("columns", 0)), int(spec.get("rows", 0)), ARCHER_COLUMNS, ARCHER_ROWS])
	# 速度不变：这条需求只要求改「投射物形态」。
	h.expect(is_equal_approx(float(spec.get("speed", -1.0)), ARCHER_SPEED), "archer_speed_changed",
		"弓箭手飞行速度是 %.2f，期望 %.2f —— 只改形态，不该顺带改手感"
		% [float(spec.get("speed", -1.0)), ARCHER_SPEED])
	# 命中特效不许被误伤：这正是最终没走程序化弹体的原因（那条路会把命中
	# 换成通用 _spawn_linear_hit，退化成非专属爆）。
	h.expect(str(spec.get("impact_path", "")) == ARCHER_IMPACT
			and int(spec.get("impact_frames", 0)) == 16, "archer_impact_degraded",
		"弓箭手命中特效被换成了 %s（%d 帧），期望 %s 的 16 帧专属爆 —— 改弹体不该误伤命中"
		% [str(spec.get("impact_path", "")), int(spec.get("impact_frames", 0)), ARCHER_IMPACT])
	_check_archer_sheet(h)


# ④b 贴图本身：能整切、且朝向仍是 45° 右上。
# 朝向这条是真正的坑 —— flipbook 用 set_uv_rotation(_screen_facing(...)) 把贴图转向目标，
# 前提是**贴图自身朝 45° 右上**。换成一张「朝右」的箭，飞行时整支箭会歪 45°。
func _check_archer_sheet(h: CheckHarness) -> void:
	# 走正规资源加载（而不是 Image.load_from_file）—— 后者在 res:// 上会告警
	# "this will not work on export"，而且**绕过 .import**，就查不出「换图没重导」。
	var tex := load(ARCHER_METAL_ARROW) as Texture2D
	if not h.expect(tex != null, "archer_sheet_unloadable",
			"金属箭贴图加载不到（新增 PNG 没跑 --import 重导？）：%s" % ARCHER_METAL_ARROW):
		return
	var img := tex.get_image()
	if not h.expect(img != null, "archer_sheet_no_image",
			"金属箭贴图取不到像素：%s" % ARCHER_METAL_ARROW):
		return
	var w := img.get_width()
	var hgt := img.get_height()
	var cell_w := w / ARCHER_COLUMNS
	var cell_h := int(floor(float(hgt) / float(ARCHER_ROWS)))
	h.expect(w % ARCHER_COLUMNS == 0, "archer_sheet_not_sliceable",
		"贴图宽 %d 不能被 %d 列整除，帧会被切歪" % [w, ARCHER_COLUMNS])
	h.expect(hgt % ARCHER_ROWS == 0, "archer_sheet_not_sliceable_rows",
		"贴图高 %d 不能被 %d 行整除" % [hgt, ARCHER_ROWS])
	# 朝向用 alpha 加权的**主成分轴**量。
	# ★ 不要用「离重心最远的实心像素」当箭尖：箭镞质量大，会把重心整体拉向前方，
	#   于是最远点恒落在**箭尾**，判据会反向误报（第一版就是这么写错的，实测报 -136.5°）。
	#   主轴对 180° 反向不敏感，但我们要分辨的是 45° / 0°(朝右) / 90°(朝上) 三类
	#   朝向约定错误，正合适。
	var sx := 0.0
	var sy := 0.0
	var sw := 0.0
	for y in hgt:
		for x in cell_w:
			var a := img.get_pixel(x, y).a
			if a < 0.35:
				continue
			sx += float(x) * a
			sy += float(y) * a
			sw += a
	if not h.expect(sw > 0.0, "archer_sheet_empty",
			"金属箭第 1 帧没有 alpha>=0.35 的像素（贴图空白或整体太透明）"):
		return
	var mx := sx / sw
	var my := sy / sw
	var vxx := 0.0
	var vyy := 0.0
	var vxy := 0.0
	for y in hgt:
		for x in cell_w:
			var a := img.get_pixel(x, y).a
			if a < 0.35:
				continue
			var dx := float(x) - mx
			var dy := float(y) - my
			vxx += a * dx * dx
			vyy += a * dy * dy
			vxy += a * dx * dy
	# 协方差矩阵的主特征向量方向
	var theta := 0.5 * atan2(2.0 * vxy, vxx - vyy)
	# 图像 y 轴向下，取负换成「0=朝右, 90=朝上」的数学角；主轴上 180° 是同一根轴。
	var axis_deg := fposmod(rad_to_deg(-theta), 180.0)
	var delta := absf(axis_deg - 45.0)
	if delta > 90.0:
		delta = absf(delta - 180.0)
	h.expect(delta <= ARCHER_FORWARD_TOL, "archer_sheet_orientation",
		"金属箭主轴 %.1f°（0=朝右, 90=朝上；约定 45° 右上，容差 %.0f°）—— " % [
			axis_deg, ARCHER_FORWARD_TOL]
		+ "换图后箭会指错方向（看着像斜着飞）")
	h.item(1)
	h.note("archer metal arrow: %dx%d grid=%dx%d cell=%dx%d axis=%.1f deg solid_mass=%.0f"
		% [w, hgt, ARCHER_COLUMNS, ARCHER_ROWS, cell_w, cell_h, axis_deg, sw])


# ⑤ 对换不能把路径唯一性搞坏（oga_vfx_preview_check 也查这条，这里独立复核一次）。
func _check_unique_paths(h: CheckHarness) -> void:
	var seen := {}
	for unit_id in CATALOG.RANGED_UNIT_ORDER:
		var spec: Dictionary = CATALOG.projectile_for(str(unit_id))
		var path := str(spec.get("path", ""))
		if path.is_empty():
			continue
		h.expect(not seen.has(path), "duplicate_path",
			"%s 与 %s 共用同一张投射物图：%s" % [seen.get(path, "?"), unit_id, path])
		seen[path] = unit_id
	h.item(1)
	h.note("ranged=%d unique_projectile_paths=%d" % [CATALOG.RANGED_UNIT_ORDER.size(), seen.size()])
