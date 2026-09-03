extends Node

# V3 P2-01 门禁：截图回归的**判定**部分。
#
# 抓图（`startup_ui_capture.gd`）需要真实渲染后端，不能带 --headless——
# headless 是 dummy 后端，抓出来是空图（同 ui_gallery_capture.gd 的既有约束）。
# 判定不需要渲染，只需要读两份已经存在的 PNG 逐像素比对，所以拆成两个文件：
# 抓图单独跑（人工触发，产出证据），判定进 headless 套件（每次跑跑得动）。
#
# 流程：
#   1. godot --path . res://tools/startup_ui_capture.tscn         # 产出 CURRENT_DIR
#   2. godot --headless --path . res://tools/startup_ui_regression_check.tscn
#
# 第 2 步只在 CURRENT_DIR 存在时才判定；不存在就跳过并说明原因，不冒充「已验证」。
# 这不是自愈：CURRENT_DIR 从不由这条门禁自己写，是第 1 步（需要人工/CI 显式跑一次
# 真实渲染）产出的证据，判定端只读不写。
#
# 基准图更新（BASELINE_DIR 的内容）永远由 --update-baseline 显式触发 + 人工审查，
# 这条门禁不碰 BASELINE_DIR 的写入路径——同 asset_manifest 的合同。
#
# 动态区域用 mask：每张截图各自的动态区域坐标写在 MASKS 里，比对时跳过那些矩形。
# 呼吸 logo、加载层转圈动效这类每次渲染相位都不同的区域，不遮罩的话同一份代码
# 跑两次都会被判成「变了」，门禁会变成学不会自己稳定的噪声源。

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "startup_ui_regression"
const BASELINE_DIR := "res://data/qa/startup_ui_baseline"
const CURRENT_DIR := "res://reports/startup_ui_current"

# 单像素通道差的容差（0-255）。全 0 会被抗锯齿/浮点渲染噪声打成假红——
# 同一份代码连续渲染两次，边缘像素也可能有 ±1~2 的抖动。
const CHANNEL_TOLERANCE := 6
# 允许有差异的像素占比上限（扣掉 mask 区域之后）。
const DIFF_PIXEL_RATIO_MAX := 0.005

# 每张截图各自的动态区域（呼吸 logo、转圈动效之类）。矩形坐标对应
# startup_ui_capture.gd 里固定的 1600×900 视口，换分辨率要跟着换算。
const MASKS := {
	"bootstrap_ready": [Rect2i(700, 250, 200, 200)],  # logo 呼吸区
	"bootstrap_failed": [],
	"main_menu": [],
	"battle_loading_pending": [Rect2i(700, 380, 200, 140)],  # 转圈/进度条动效区
	"battle_loading_failed": [],
}

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)

	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(CURRENT_DIR)):
		_h.note(("%s 不存在——还没跑过 startup_ui_capture.gd（需要真实渲染后端，"
			+ "这条门禁不能替它跑）。判定跳过，不冒充已验证。") % CURRENT_DIR)
		_h.finish(get_tree())
		return

	for shot_name in MASKS.keys():
		_check_one(shot_name)

	_check_masks_are_not_the_whole_image()
	_h.finish(get_tree())


func _check_one(shot_name: String) -> void:
	var baseline_path := "%s/%s.png" % [BASELINE_DIR, shot_name]
	var current_path := "%s/%s.png" % [CURRENT_DIR, shot_name]

	if not FileAccess.file_exists(baseline_path):
		_h.expect(false, "baseline_missing",
			"%s 没有基准图——跑一次 --update-baseline 并人工审查后提交" % shot_name)
		return
	if not FileAccess.file_exists(current_path):
		_h.expect(false, "current_missing",
			"%s 的 current 截图不存在（capture 阶段可能失败了）" % shot_name)
		return

	var baseline := Image.load_from_file(ProjectSettings.globalize_path(baseline_path))
	var current := Image.load_from_file(ProjectSettings.globalize_path(current_path))
	if not _h.expect(baseline != null and current != null, "image_load_failed",
			"%s 的基准图或 current 图读不出来" % shot_name):
		return
	if not _h.expect(baseline.get_size() == current.get_size(), "size_mismatch",
			"%s 尺寸不一致：基准 %s，current %s —— 换分辨率要连基准一起更新"
				% [shot_name, str(baseline.get_size()), str(current.get_size())]):
		return

	var result := diff_images(baseline, current, MASKS.get(shot_name, []))
	var ratio := float(result.diff_pixels) / maxf(1.0, float(result.total_pixels))
	_h.expect(ratio <= DIFF_PIXEL_RATIO_MAX, "screenshot_regressed",
		("%s 与基准图差异 %.3f%%（%d/%d 像素，已扣除 %d 个遮罩像素），"
			+ "超过 %.3f%% 的容差 —— 这不是渲染抖动，页面真的变了")
			% [shot_name, ratio * 100.0, result.diff_pixels, result.total_pixels,
				result.masked_pixels, DIFF_PIXEL_RATIO_MAX * 100.0])


# mask 覆盖不能大到把整张图都盖住——那样再离谱的回归也测不出来。
# 用「已声明的遮罩面积 / 整图面积」卡一个上限，逼着遮罩只圈动态区域本身。
func _check_masks_are_not_the_whole_image() -> void:
	for shot_name in MASKS.keys():
		var rects: Array = MASKS[shot_name]
		if rects.is_empty():
			continue
		var masked_area := 0
		for rect_value in rects:
			var rect: Rect2i = rect_value
			masked_area += rect.size.x * rect.size.y
		var total_area := 1600 * 900
		var ratio := float(masked_area) / float(total_area)
		_h.expect(ratio < 0.25, "mask_too_large",
			"%s 的遮罩占了整图 %.1f%% —— 遮罩应该只圈动态区域，不是绕过比对"
				% [shot_name, ratio * 100.0])


# 逐像素比对，跳过 mask 矩形覆盖的像素。返回 {diff_pixels, masked_pixels, total_pixels}。
# 独立成一个纯函数：不依赖磁盘上的图，方便反向变异直接构造 Image 调它。
func diff_images(baseline: Image, current: Image, masks: Array) -> Dictionary:
	var size := baseline.get_size()
	var total := size.x * size.y
	var diff := 0
	var masked := 0
	for y in size.y:
		for x in size.x:
			if _in_any_mask(x, y, masks):
				masked += 1
				continue
			var a := baseline.get_pixel(x, y)
			var b := current.get_pixel(x, y)
			if _channel_diff(a, b) > CHANNEL_TOLERANCE:
				diff += 1
	return {"diff_pixels": diff, "masked_pixels": masked, "total_pixels": total}


func _in_any_mask(x: int, y: int, masks: Array) -> bool:
	for rect_value in masks:
		var rect: Rect2i = rect_value
		if rect.has_point(Vector2i(x, y)):
			return true
	return false


func _channel_diff(a: Color, b: Color) -> int:
	var da := absi(int(a.r * 255.0) - int(b.r * 255.0))
	var dg := absi(int(a.g * 255.0) - int(b.g * 255.0))
	var db := absi(int(a.b * 255.0) - int(b.b * 255.0))
	return maxi(da, maxi(dg, db))
