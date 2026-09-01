extends Node

# V2 P1-04 第 1、3、5 条的门禁。
#
# 先记实测把 V2 原文修正掉的地方：
#
# * 第 1 条说"不复用 64/128 图标"。实测立绘是 330x330（32 张单位）、256x256
#   （12 张佣兵）、512/1024（38 张图鉴），没有 64/128 的图标被复用。真正的缺口是
#   **44 张低于 384**。V2 对这一档的原话是"直接警告"而不是失败，所以这里
#   <384 记 NOTE、<192 才判 FAIL（后者才是真把图标接上来了）。
#
# * "优先使用 512/1024 战斗半身图"在这个仓里**没有可切换的来源**：图鉴那 38 张
#   512/1024 是按怪物/Boss 的中文 name 命名的，与 32 个单位 id、12 个佣兵 id
#   零重合。要满足这条得先出图，不是改代码能解决的。
#
# * 第 3 条（脚底基准/目标高度/朝向/队伍色底座/双线性各向异性 mipmap）与第 5 条
#   （fallback 按 unit_id/reason 聚合）实测**都已经实现了**。所以这个门禁不是
#   去补功能，而是把它们钉住 —— 在此之前没有任何东西拦着谁把 mipmap 关掉、
#   把卡框从地面上抬起来，或者把聚合改成每帧刷一行。
#
# 另记一条容易误判的：单位立绘全是满幅方图、零透明像素。单看会以为公告板会渲染成
# 一个方块，但 fallback 是"底座 + 立绘 + 中空石框"三层叠出来的，框把边缘盖住了，
# 整体读作战场上立着一张卡。这是有意的造型，不是 bug。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const FallbackScript := preload("res://effects/runtime/presentation/UnitPortraitFallback3D.gd")
const VisualResolver := preload("res://effects/runtime/presentation/UnitVisualResolver.gd")
const CHECK_NAME := "portrait_fallback_quality"

# V2 第 1 条的两条线：低于 WARN 只警告，低于 FAIL 才判失败。
const PORTRAIT_WARN_PX := 384
const PORTRAIT_FAIL_PX := 192

const PROBE_HEIGHT := 1.24
const PROBE_PORTRAIT := "res://assets/ui/unit_portraits/human_king.png"
const PROBE_FRAME := "res://assets/ui/shop/card_frame_common.png"

# 故意不存在的路径，用来驱动 report_failure 的聚合逻辑。
# 带 asset-manifest-ignore：这是探针，不是真引用；不加标记
# asset_manifest_check 会把它当成缺失资源报 missing_asset。
const PROBE_MISSING_PATH := "res://probe_absent_model.tscn"  # asset-manifest-ignore

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_portrait_resolutions()
	_check_fallback_presentation()
	_check_failure_aggregation()
	_h.finish(get_tree())


# --- 第 1 条：报告实际尺寸，低于 384 警告 -----------------------------------

func _check_portrait_resolutions() -> void:
	var entries := VisualResolver.all_combat_entries()
	if not _h.expect(entries.size() >= 50, "registry_too_small",
		"只解析到 %d 个战斗条目" % entries.size()):
		return

	var sized := 0
	var under_warn: Array[String] = []
	var missing := 0
	var smallest := 99999
	var smallest_id := ""
	for entry in entries:
		var def_dict: Dictionary = entry
		var path := str(def_dict.get("portrait", ""))
		var unit_id := str(def_dict.get("id", "?"))
		if path.is_empty() or not VisualResolver.resource_exists(path):
			# 缺图交给 asset_manifest_check 判，这里只计数，不重复背责任。
			missing += 1
			continue
		var texture := load(path) as Texture2D
		if texture == null:
			missing += 1
			continue
		sized += 1
		var short_side := mini(texture.get_width(), texture.get_height())
		if short_side < smallest:
			smallest = short_side
			smallest_id = unit_id
		# V2 的失败线：真把 64/128 的图标接上来了才算错。
		_h.expect(short_side >= PORTRAIT_FAIL_PX,
			"portrait_is_an_icon",
			"%s 的立绘只有 %dpx（%s）—— 低于 %dpx 说明接的是图标而不是半身图"
				% [unit_id, short_side, path, PORTRAIT_FAIL_PX])
		if short_side < PORTRAIT_WARN_PX:
			under_warn.append("%s(%dpx)" % [unit_id, short_side])

	_h.item()
	_h.note("量到 %d 张立绘，缺图 %d 张（缺图由 asset_manifest_check 负责）" % [sized, missing])
	_h.note("最小的一张：%s %dpx" % [smallest_id, smallest])
	if under_warn.is_empty():
		_h.note("全部达到 %dpx 以上" % PORTRAIT_WARN_PX)
	else:
		# V2 原话是"低于 384 直接警告"——警告，不是失败。
		_h.note("警告：%d 张低于 %dpx，在 1046px 的卡框里会被放大：%s"
			% [under_warn.size(), PORTRAIT_WARN_PX, ", ".join(under_warn.slice(0, 12))])


# --- 第 3 条：脚底基准、目标高度、朝向、队伍色底座、过滤与 mipmap ------------

func _check_fallback_presentation() -> void:
	var fallback: Node3D = FallbackScript.new()
	add_child(fallback)
	var ok: bool = fallback.configure(PROBE_PORTRAIT, PROBE_FRAME, Color(0.2, 0.5, 0.9), PROBE_HEIGHT)
	if not _h.expect(ok, "fallback_configure_failed",
		"fallback 用 %s 配置失败" % PROBE_PORTRAIT):
		fallback.queue_free()
		return

	var frame := fallback.get_node_or_null("Frame") as Sprite3D
	var portrait := fallback.get_node_or_null("Portrait") as Sprite3D
	var plate := fallback.get_node_or_null("TeamPlate") as Sprite3D
	for pair in [["Frame", frame], ["Portrait", portrait], ["TeamPlate", plate]]:
		_h.expect((pair[1] as Node) != null, "fallback_layer_missing",
			"fallback 缺少 %s 层" % str(pair[0]))
	if frame == null or portrait == null or plate == null:
		fallback.queue_free()
		return

	# 脚底基准：卡框是这张卡的外轮廓，它的下边缘必须落在地面上。
	# V2 验收原话："不贴地漂浮"。
	var frame_span := _vertical_span(frame)
	_h.expect(absf(frame_span.x) < PROBE_HEIGHT * 0.03,
		"fallback_not_grounded",
		"卡框下边缘在 y=%.4f，不在地面上（高度 %.2f）—— 会读成浮空"
			% [frame_span.x, PROBE_HEIGHT])

	# 目标高度：卡框整体高度必须就是请求的高度，不能自己缩放。
	_h.expect(absf((frame_span.y - frame_span.x) - PROBE_HEIGHT) < PROBE_HEIGHT * 0.03,
		"fallback_wrong_height",
		"卡框实际高 %.4f，请求的是 %.2f" % [frame_span.y - frame_span.x, PROBE_HEIGHT])

	# 立绘和底座必须落在卡框里面，否则会从框外露出来。
	for pair in [["Portrait", portrait], ["TeamPlate", plate]]:
		var span := _vertical_span(pair[1] as Sprite3D)
		_h.expect(span.x >= frame_span.x - 0.001 and span.y <= frame_span.y + 0.001,
			"fallback_layer_outside_frame",
			"%s 的跨度 [%.3f, %.3f] 超出卡框 [%.3f, %.3f]"
				% [str(pair[0]), span.x, span.y, frame_span.x, frame_span.y])

	# 朝向：三层都必须是公告板，否则从侧面看会变成一条线。
	# 过滤策略：必须是各向异性 + mipmap，不然远处会闪烁、近处会糊。
	for pair in [["Frame", frame], ["Portrait", portrait], ["TeamPlate", plate]]:
		var sprite := pair[1] as Sprite3D
		_h.expect(sprite.billboard == BaseMaterial3D.BILLBOARD_ENABLED,
			"fallback_not_billboard",
			"%s 不是公告板，侧视会塌成一条线" % str(pair[0]))
		_h.expect(sprite.texture_filter == BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC,
			"fallback_filter_downgraded",
			"%s 的过滤是 %d，不是 LINEAR_WITH_MIPMAPS_ANISOTROPIC —— V2 第 3 条要求统一双线性/各向异性/mipmap"
				% [str(pair[0]), sprite.texture_filter])
		_h.expect(sprite.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
			"fallback_casts_shadow",
			"%s 在投影 —— 一张公告板的影子会是一条黑带" % str(pair[0]))
	fallback.queue_free()

	# 队伍色底座：两个不同队伍色必须产出不同的底座。
	#
	# **逐个色标比对**，不是只看其中一个。第一版只采 colors[1]，变异测试当场证明
	# 它不够：底座渐变是 [dark, center, dark] 三段，把 dark 那两段写死成常量、
	# 只留 center 跟队伍色走，断言照样通过。每一段都由队伍色派生，就该每一段都验。
	var a := _plate_colors_for(Color(0.2, 0.5, 0.9))
	var b := _plate_colors_for(Color(0.9, 0.3, 0.2))
	if not _h.expect(a.size() > 0 and a.size() == b.size(),
		"team_plate_gradient_missing",
		"底座渐变取不到色标（%d vs %d）" % [a.size(), b.size()]):
		return
	for i in range(a.size()):
		_h.expect(not a[i].is_equal_approx(b[i]),
			"team_plate_ignores_team_color",
			"底座渐变第 %d 段在两个队伍色下都是 %s —— 这一段没有跟着队伍色走"
				% [i, str(a[i])])


func _plate_colors_for(team_color: Color) -> PackedColorArray:
	var fallback: Node3D = FallbackScript.new()
	add_child(fallback)
	fallback.configure(PROBE_PORTRAIT, PROBE_FRAME, team_color, PROBE_HEIGHT)
	var plate := fallback.get_node_or_null("TeamPlate") as Sprite3D
	var out := PackedColorArray()
	if plate != null and plate.texture is GradientTexture2D:
		var gradient := (plate.texture as GradientTexture2D).gradient
		if gradient != null:
			out = gradient.colors
	fallback.queue_free()
	return out


# Sprite3D 默认居中，所以纵向跨度是 position.y +- 半高。
func _vertical_span(sprite: Sprite3D) -> Vector2:
	if sprite == null or sprite.texture == null:
		return Vector2.ZERO
	var world_height := sprite.pixel_size * float(sprite.texture.get_height()) * sprite.scale.y
	var half := world_height * 0.5
	if not sprite.centered:
		return Vector2(sprite.position.y, sprite.position.y + world_height)
	return Vector2(sprite.position.y - half, sprite.position.y + half)


# --- 第 5 条：fallback 按 unit_id / reason 聚合 -------------------------------

func _check_failure_aggregation() -> void:
	VisualResolver.reset_failure_report()
	_h.expect(VisualResolver.failure_rows().is_empty(),
		"reset_does_not_clear", "reset_failure_report() 之后仍有残留行")

	# 同一个 (unit_id, path, consumer, reason) 报 5 次只能留 1 行。
	# 这是"聚合"的核心：fallback 每帧都可能被问一次，不去重就会刷爆记录。
	for _i in range(5):
		VisualResolver.report_failure("probe_unit", PROBE_MISSING_PATH, "battle", "model scene unavailable")
	_h.expect(VisualResolver.failure_rows().size() == 1,
		"failure_not_aggregated",
		"同一条失败报了 5 次，留下了 %d 行 —— 没有按 unit_id/reason 聚合"
			% VisualResolver.failure_rows().size())

	# 不同的 unit_id 或不同的 reason 必须各自成行，否则聚合过头、丢掉信息。
	VisualResolver.report_failure("probe_unit_2", PROBE_MISSING_PATH, "battle", "model scene unavailable")
	VisualResolver.report_failure("probe_unit", PROBE_MISSING_PATH, "battle", "portrait unavailable")
	var rows := VisualResolver.failure_rows()
	_h.expect(rows.size() == 3,
		"failure_over_aggregated",
		"两个不同 unit_id 加一个不同 reason 应得 3 行，实际 %d 行" % rows.size())

	# 每一行都必须带得走 unit_id 和 reason —— 设备记录要按这两个字段分组。
	for row_value in rows:
		var row: Dictionary = row_value
		for field in ["unit_id", "reason", "resource_path", "consumer"]:
			_h.expect(row.has(field) and not str(row[field]).is_empty(),
				"failure_row_missing_field",
				"失败行缺少 %s：%s" % [field, str(row)])

	VisualResolver.reset_failure_report()
	_h.note("聚合验证完成并已清空探针数据")
