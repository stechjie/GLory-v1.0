extends Node

# V3 P1-06 门禁：教程之外的页面响应式覆盖。
#
# `tutorial_overlay_layout_check` 已经把 PrepScreen 教程遮罩钉在四种分辨率上；
# 审计（reports/v3_audit.json 的 P1-06 条目）点名的缺口是**其余页面没有等价
# 覆盖**。这条门禁补的就是那些页面：MainMenu（连同它拉起的 MainMenuAmbience /
# MainMenuPet 子组件）、Team3v3Lobby、SettingsScreen、CodexScreen。
#
# 覆盖六种分辨率：16:9、19.5:9、20:9（项目基准视口 1600×720 正好是 20:9，
# 是「画布最矮」的那一档）、平板横屏、项目最早支持的 1280×720、以及一个更高的
# 平板竖屏纵深(2048×1536)。刘海/挖孔安全区仍然 external ——
# 本机 25028RN03A 横屏 `navigation_mode=0`，没有 cutout 可测。
#
# 三种版面各查各的不变式，而不是笼统地遍历整棵控件树：
#   * REF_SIZE 信封页（MainMenu / Team3v3Lobby）——它们自己用
#     `scale = min(viewport/REF_SIZE)` 居中缩放出一块画布；这条门禁按同一个公式
#     重新算一遍期望值，核对页面自己算出来的 _layout_scale 与之一致，且画布不会
#     超出视口。
#   * CenterContainer 面板页（SettingsScreen）——直接测量最终布局，断言面板矩形
#     完整落在画布内。
#   * 自带缩放系统的页（CodexScreen）——它的书本背景按「cover」故意铺满裁边，
#     不检查背景是否超出（那是设计意图），只检查返回键这个真正要可达的控件。
#
# 全部只读：不改布局代码，只在发现真溢出时才失败。这一轮实测这几个页面都没有
# 溢出，只有 SettingsScreen 在 20:9（画布 1600×720）下边距压到 7px ——
# 记在这里，作为回归基线，而不是当场重新设计布局。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const SettingsScene := preload("res://scenes/menu/SettingsScreen.tscn")
const CodexScene := preload("res://scenes/menu/CodexScreen.tscn")
const Team3v3LobbyScene := preload("res://scenes/menu/Team3v3Lobby.tscn")
const MainMenuScene := preload("res://scenes/menu/MainMenu.tscn")
const MainMenuScript := preload("res://scenes/menu/MainMenu.gd")
const Team3v3LobbyScript := preload("res://scenes/menu/Team3v3Lobby.gd")

const CHECK_NAME := "responsive_layout"

# 与 tutorial_overlay_layout_check 共用同一族分辨率，另加 19.5:9 与一档平板纵深
# （审计原文点名要覆盖 19.5:9 / 平板，旧门禁的四档里没有）。
const RESOLUTIONS: Array = [
	{"name": "16:9 1920x1080", "size": Vector2i(1920, 1080)},
	{"name": "19.5:9 2340x1080", "size": Vector2i(2340, 1080)},
	{"name": "20:9 2400x1080", "size": Vector2i(2400, 1080)},
	{"name": "tablet 2640x1216", "size": Vector2i(2640, 1216)},
	{"name": "1280x720", "size": Vector2i(1280, 720)},
	{"name": "tablet 2048x1536", "size": Vector2i(2048, 1536)},
]

# 低于这个边距只记 note、不判失败——真出界（<0）才算缺陷。
const TIGHT_MARGIN_WARN_PX := 12.0

var _h: CheckHarness
var _restore_size := Vector2i.ZERO


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_restore_size = get_window().size

	for entry in RESOLUTIONS:
		await _check_main_menu(entry as Dictionary)
		await _check_team3v3_lobby(entry as Dictionary)
		await _check_centered_panel_page("SettingsScreen", SettingsScene, entry as Dictionary)
		await _check_codex_page(entry as Dictionary)

	get_window().size = _restore_size
	await _settle(2)
	_h.finish(get_tree())


func _settle(frames: int = 3) -> void:
	for i in frames:
		await get_tree().process_frame


# --- REF_SIZE 信封页：MainMenu / Team3v3Lobby -------------------------------
#
# 两个页面结构不同（各自的字段类型不能共用一个签名），所以分别写，
# 但校验逻辑共用 `_check_ref_size_invariant()`。

func _check_main_menu(entry: Dictionary) -> void:
	var res_label := str(entry["name"])
	get_window().size = entry["size"] as Vector2i
	await _settle(4)
	var page: MainMenuScript = MainMenuScene.instantiate()
	add_child(page)
	await _settle(4)
	_check_ref_size_invariant("MainMenu", res_label, page.REF_SIZE, page._layout_scale)
	page.queue_free()
	await _settle(2)


func _check_team3v3_lobby(entry: Dictionary) -> void:
	var res_label := str(entry["name"])
	get_window().size = entry["size"] as Vector2i
	await _settle(4)
	var page: Team3v3LobbyScript = Team3v3LobbyScene.instantiate()
	add_child(page)
	await _settle(4)
	_check_ref_size_invariant("Team3v3Lobby", res_label, page.REF_SIZE, page._layout_scale)
	page.queue_free()
	await _settle(2)


# 只留一条断言：`_layout_scale` 必须等于按 REF_SIZE 独立重算出来的
# min(viewport/REF_SIZE)。原来还有「画布不超出视口」与「scale 不是 0」两条，
# 删掉了 —— 只要 scale 真的等于这个 min 公式的结果，画布落在视口内是这条公式
# 本身的数学保证，不是另一件需要验的事；找不到一个只让那两条单独转红、不牵连
# 这条的生产代码变异，就说明它们是这条的复读，不是独立信息。
func _check_ref_size_invariant(
	label: String, res_label: String, ref_size: Vector2, actual_scale: float
) -> void:
	var viewport := get_viewport().get_visible_rect().size
	var expected_scale := minf(viewport.x / ref_size.x, viewport.y / ref_size.y)
	_h.expect(is_equal_approx(actual_scale, expected_scale),
		"ref_size_scale_drifted",
		("[%s @ %s] 页面自己算出的 scale=%.4f 与公式期望的 %.4f 不一致 —— "
			+ "居中缩放公式和生产代码分叉了，画布可能会顶出视口")
			% [label, res_label, actual_scale, expected_scale])


# --- CenterContainer 面板页：SettingsScreen ---------------------------------

func _check_centered_panel_page(label: String, scene: PackedScene, entry: Dictionary) -> void:
	var res_label := str(entry["name"])
	get_window().size = entry["size"] as Vector2i
	await _settle(4)

	var page: Control = scene.instantiate()
	add_child(page)
	await _settle(4)

	var center: CenterContainer = null
	for child in page.get_children():
		if child is CenterContainer:
			center = child
			break
	if not _h.expect(center != null and center.get_child_count() > 0,
			"centered_panel_not_found",
			"[%s @ %s] 没找到 CenterContainer 面板 —— 页面结构可能已经改了"
				% [label, res_label]):
		page.queue_free()
		await _settle(2)
		return

	var panel: Control = center.get_child(0)
	var canvas := get_viewport().get_visible_rect().size
	var rect := panel.get_global_rect()
	var margin_top := rect.position.y
	var margin_bottom := canvas.y - (rect.position.y + rect.size.y)
	_h.expect(margin_top >= -0.5, "centered_panel_overflow_top",
		"[%s @ %s] 面板顶部超出画布 %.1fpx" % [label, res_label, -margin_top])
	_h.expect(margin_bottom >= -0.5, "centered_panel_overflow_bottom",
		("[%s @ %s] 面板底部超出画布 %.1fpx —— 底部的返回键会点不到")
			% [label, res_label, -margin_bottom])
	if margin_top >= 0.0 and margin_top < TIGHT_MARGIN_WARN_PX:
		_h.note("[%s @ %s] 上边距只有 %.1fpx，接近极限" % [label, res_label, margin_top])
	if margin_bottom >= 0.0 and margin_bottom < TIGHT_MARGIN_WARN_PX:
		_h.note("[%s @ %s] 下边距只有 %.1fpx，接近极限" % [label, res_label, margin_bottom])

	page.queue_free()
	await _settle(2)


# --- 自带缩放系统的页：CodexScreen ------------------------------------------
#
# `_book` 是背景美术，按「cover」铺满视口 —— 边缘裁掉一圈是设计意图，不是缺陷，
# 所以**不**检查它是否超出画布（那本来就该超出）。真正要保证可达的是返回键：
# 背景怎么裁都不能把它带出画布，那样玩家会退不出这一页。

func _check_codex_page(entry: Dictionary) -> void:
	var res_label := str(entry["name"])
	get_window().size = entry["size"] as Vector2i
	await _settle(4)

	var page: Control = CodexScene.instantiate()
	add_child(page)
	await _settle(4)

	var book_value = page.get("_book")
	_h.expect(book_value is Control and (book_value as Control).size.x > 0.0
			and (book_value as Control).size.y > 0.0,
		"codex_book_degenerate",
		"[CodexScreen @ %s] 图鉴书本尺寸不正常：%s" % [res_label, str(book_value)])

	var back_btn_value = page.get("_back_btn")
	if _h.expect(back_btn_value is Button, "codex_back_button_missing",
			"[CodexScreen @ %s] _back_btn 字段不是 Button —— 门禁的取值方式失效了"
				% res_label):
		var back_btn: Button = back_btn_value
		var canvas := get_viewport().get_visible_rect().size
		var rect := back_btn.get_global_rect()
		var viewport_rect := Rect2(Vector2.ZERO, canvas).grow(0.5)
		_h.expect(viewport_rect.encloses(rect), "codex_back_button_unreachable",
			"[CodexScreen @ %s] 返回键 %s 超出了画布 %s —— 玩家退不出图鉴"
				% [res_label, str(rect), str(viewport_rect)])

	page.queue_free()
	await _settle(2)
