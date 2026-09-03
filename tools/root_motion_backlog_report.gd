extends Node

# V2 P1-04 / F2：把「还没登记原地化的 27 条 attack/idle」摊开成一份可判断的清单。
#
# 这**不是门禁**（文件名不以 _check 结尾，run_check.ps1 -All 不会收它）。
# 它的唯一职责是产出 Leno 逐项批准所需要的事实，因为 MD 0.7 规定 attack/idle
# 不许批量登记 —— 有些位移是故意的（扑击、飘浮），登记了反而毁掉表现。
#
# model_root_motion_inventory 只报一个 span，那不足以判断。真正决定性的是
# **末帧有没有回到原点**：
#
#   * 冲出去又收回来（end 小、span 大）  -> 扑击/后仰，多半是故意的，登记会毁打击感
#   * 一路走不回来（end 接近 span）      -> 净漂移，身体最后就留在圆盘外，该登记
#
# 量法与 inventory / lock 两条门禁逐字一致（只看无父骨骼的 POSITION_3D 轨道、
# 相对第一帧、只算水平面），三份数字才可比。
#
# **判据只有位移数字，与 clip 名称无关。**
# 2026-09-03 用户确认：通用动作库的 clip 名（dance / birdcage / aerobic 之类）
# 被用在攻击或奔跑上是设计选择，不是错误。所以这份清单不看名字，
# 只回答「播放时身体有没有留在圆盘外」，并且**最终仍需 Leno 逐条批准**
# 才能改数据 —— 有些位移是故意的（扑击、飘浮），登记了反而毁掉表现。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const UnitActor3D := preload("res://effects/runtime/presentation/UnitActor3D.gd")

const CHECK_NAME := "root_motion_backlog_report"
const SHADOW_RADIUS := 0.26
const OUT_PATH := "user://root_motion_backlog.md"

# end/span 低于这个比例就算「收得回来」。0.35 是留给收势不彻底的余量：
# 扑出去 1.0 收回到 0.35 以内，玩家看不出人圈分离。
const RETURN_RATIO := 0.35

const TABLES := [
	{"kind": "unit", "path": "res://data/units/race_units.json", "key": "units"},
	{"kind": "merc", "path": "res://data/mercenary/mercenaries.json", "key": "mercenaries"},
	{"kind": "monster", "path": "res://data/pve/pve_monsters.json", "key": "monsters"},
	{"kind": "boss", "path": "res://data/boss/bosses.json", "key": "bosses"},
	{"kind": "ally", "path": "res://data/formation/formation_allies.json", "key": "allies"},
]

var _h: CheckHarness
var _rows: Array[Dictionary] = []


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	for table in TABLES:
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(table.path)))
		if not (parsed is Dictionary):
			continue
		for item in (parsed as Dictionary).get(str(table.key), []):
			await _scan(item as Dictionary, str(table.kind))

	_rows.sort_custom(func(a, b): return float(a["span"]) > float(b["span"]))
	_h.item()
	_h.expect(_rows.size() >= 20, "backlog_scan_vacuous",
		"只扫出 %d 条未登记动作，测量链多半断了（预期 27 上下）" % _rows.size())
	_write_report()
	_h.finish(get_tree())


func _scan(definition: Dictionary, kind: String) -> void:
	var model_path := str(definition.get("model", ""))
	if model_path.is_empty():
		return
	var packed := load(model_path) as PackedScene
	if packed == null:
		return
	var root := packed.instantiate() as Node3D
	if root == null:
		return
	var unit_id := str(definition.get("id", ""))
	var configured := _configured_actions(definition)
	var actor := UnitActor3D.new()
	actor.set_meta("unit_id", unit_id)
	actor.set_meta("resolved_visual", definition)
	actor.attach_model(root)
	add_child(actor)
	await get_tree().process_frame

	var model_root := root.get_node_or_null("ModelRoot")
	if model_root != null:
		for child in model_root.get_children():
			var action := _action_of(str(child.name))
			# run 已经全部登记完，这份清单只服务待批准的 attack/idle。
			if action.is_empty() or action == "run" or configured.has(action):
				continue
			var measured := _measure(child as Node, action)
			if measured.is_empty() or float(measured["span"]) <= SHADOW_RADIUS:
				continue
			measured["id"] = unit_id
			measured["kind"] = kind
			measured["action"] = action
			_rows.append(measured)
	actor.queue_free()
	await get_tree().process_frame


# 返回 {span, end, length, clip}；span=相对首帧最大水平位移，end=末帧水平位移。
func _measure(action_root: Node, action: String) -> Dictionary:
	var player := _find(action_root, "AnimationPlayer") as AnimationPlayer
	var skeleton := _find(action_root, "Skeleton3D") as Skeleton3D
	if player == null or skeleton == null:
		return {}
	var chosen := _best_animation_name(player, action)
	if chosen.is_empty():
		return {}
	var animation := player.get_animation(chosen)
	if animation == null:
		return {}
	var roots := {}
	for bone_index in skeleton.get_bone_count():
		if skeleton.get_bone_parent(bone_index) < 0:
			roots[str(skeleton.get_bone_name(bone_index))] = true
	var span := 0.0
	var end := 0.0
	for track_index in animation.get_track_count():
		if animation.track_get_type(track_index) != Animation.TYPE_POSITION_3D:
			continue
		var bone_name := str(animation.track_get_path(track_index)).get_slice(":", 1)
		var keys := animation.track_get_key_count(track_index)
		if not roots.has(bone_name) or keys <= 0:
			continue
		var first := animation.track_get_key_value(track_index, 0) as Vector3
		var origin := Vector2(first.x, first.z)
		for key_index in keys:
			var value := animation.track_get_key_value(track_index, key_index) as Vector3
			span = maxf(span, origin.distance_to(Vector2(value.x, value.z)))
		var last := animation.track_get_key_value(track_index, keys - 1) as Vector3
		end = maxf(end, origin.distance_to(Vector2(last.x, last.z)))
	return {"span": span, "end": end, "length": animation.length, "clip": chosen}


func _write_report() -> void:
	var lines: Array[String] = []
	lines.append("# 待批准：attack/idle 根位移分类清单")
	lines.append("")
	lines.append("由 tools/root_motion_backlog_report.tscn 生成。圆盘半径 **%.2f**。" % SHADOW_RADIUS)
	lines.append("")
	lines.append("- **span** = 相对首帧的最大水平位移（身体最远飘到哪）")
	lines.append("- **end** = 末帧的水平位移（收势后回没回到原点）")
	lines.append("- **建议** = 机器初判，**最终由 Leno 定**；登记后该动作会被原地化，")
	lines.append("  扑击类一旦登记就会失去前冲的打击感。")
	lines.append("")
	lines.append("| # | 单位 | 类 | 动作 | span | end | end/span | 时长 | clip | 建议 |")
	lines.append("|---|---|---|---|---|---|---|---|---|---|")
	var index := 0
	var suggest_register := 0
	for row in _rows:
		index += 1
		var span := float(row["span"])
		var end := float(row["end"])
		var ratio := (end / span) if span > 0.0 else 0.0
		var verdict := ""
		if ratio <= RETURN_RATIO:
			verdict = "保留（收得回来，像扑击）"
		else:
			verdict = "**建议登记**（净漂移 %.2f）" % end
			suggest_register += 1
		lines.append("| %d | `%s` | %s | %s | %.3f | %.3f | %.2f | %.2fs | `%s` | %s |" % [
			index, str(row["id"]), str(row["kind"]), str(row["action"]),
			span, end, ratio, float(row["length"]), str(row["clip"]), verdict])
	lines.append("")
	lines.append("合计 **%d** 条：建议登记 **%d**，建议保留 **%d**。" % [
		_rows.size(), suggest_register, _rows.size() - suggest_register])
	lines.append("")
	lines.append("批准哪几条之后，把动作名加进对应数据表的 model_in_place_actions，")
	lines.append("并把 model_root_motion_inventory_check.gd 的 MAX_UNREGISTERED 相应调低。")
	var text := ""
	for line in lines:
		text += line + "\n"
	var file := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
	_h.note("清单已写到 %s（%d 条）" % [ProjectSettings.globalize_path(OUT_PATH), _rows.size()])


func _configured_actions(definition: Dictionary) -> Array:
	var raw: Variant = definition.get("model_in_place_actions", [])
	var out: Array = []
	if raw is Array:
		for value in (raw as Array):
			out.append(str(value).strip_edges().to_lower())
	return out


func _action_of(node_name: String) -> String:
	var lower := node_name.to_lower()
	for action in ["idle", "attack", "run"]:
		if lower.begins_with(action):
			return action
	return ""


func _best_animation_name(player: AnimationPlayer, action: String) -> String:
	var best_name := ""
	var best_score := -999999.0
	for name in player.get_animation_list():
		var text := String(name)
		var lower := text.to_lower()
		var animation := player.get_animation(text)
		var score: float = animation.length if animation != null else 0.0
		if lower.contains("reset"):
			score -= 10000.0
		for alias in _action_aliases(action):
			if lower.contains(alias):
				score += 1000.0
		if score > best_score:
			best_score = score
			best_name = text
	return best_name


func _action_aliases(action: String) -> Array[String]:
	match action:
		"idle":
			return ["idle", "idel", "stand", "breath"]
		"attack":
			return ["attack", "punch", "slash", "hit", "cast"]
		"run":
			return ["run", "walk", "move", "catwalk"]
		_:
			return []


func _find(root: Node, type_name: String) -> Node:
	if root.get_class() == type_name:
		return root
	for child in root.get_children():
		var found := _find(child, type_name)
		if found != null:
			return found
	return null
