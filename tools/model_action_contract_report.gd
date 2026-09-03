extends Node

# V2 P1-04 / P1-01：**包装模型动作合同矩阵**。
#
# V2 清单在 P1-01 和 P1-04 里两次写到「后续还必须增加包装模型动作合同矩阵」，
# 这份报告就是它：把每个单位的 idle / attack / run 实际播出的 clip 如实列出来。
#
# 这**不是门禁**（文件名不以 _check 结尾，run_check.ps1 -All 不会收它）。
#
# ## 只记录事实，不按名称判定对错
#
# 2026-09-03 更正：本报告的第一版按 clip 名字里的词（dance / sit / birdcage …）
# 判定「静态动作被绑到 attack 或 run」是冲突，并把 16 条列成缺陷。
# **用户确认那批舞蹈动作用于攻击/奔跑是设计选择，不是错误。**
#
# 名字判不了对错，原因很直接：
#   * clip 名来自通用动作库，和它在本作里承担的演出职责没有必然关系；
#   * 时长、候选数、英文词义同样说明不了「这个动作放在这里对不对」——
#     那是美术和策划的判断，不是字符串匹配能替代的。
#
# 所以本报告只回答一个可证伪的问题：**每个单位的每个动作，实际播的是哪条 clip。**
# 判断某个动作是否需要 `model_in_place_actions`，只看**播放时角色主体是否
# 不合理地离开自己的圆盘**（那是 battle_actor_body_on_disc 与
# root_motion_backlog_report 的职责，判据是位移数字），与动作名称无关。
#
# ## 取值方式：让 wrapper 自己播，读回它选中的那条
#
# **不重实现选曲逻辑。** 73 个 wrapper 的 `_action_aliases()` 有 7 种不同变体
# （有的 idle 认 "relax"，有的 attack 认 "bite"/"devour"，有的 run 认 "gallop"），
# 抄任何一份都会在别的单位上报错人。这里改成让 wrapper 自己 `play_xxx()`，
# 再从 AnimationPlayer 读回 `current_animation` —— 那是 ground truth，
# 和玩家真实看到的逐字一致。

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "model_action_contract_report"
const OUT_PATH := "user://model_action_contract.md"

const ACTION_METHODS := {"idle": "play_idle", "attack": "play_attack", "run": "play_run"}
const ACTIONS := ["idle", "attack", "run"]
# clip 名里可能含 "|"（Godot 导入 FBX 会命名成 Armature|mixamo_com），
# 所以做字典键时不能用 "|" 当分隔符。换行符不会出现在 clip 名或动作名里。
const KEY_SEP := "\n"

const TABLES := [
	{"kind": "unit", "path": "res://data/units/race_units.json", "key": "units"},
	{"kind": "merc", "path": "res://data/mercenary/mercenaries.json", "key": "mercenaries"},
	{"kind": "monster", "path": "res://data/pve/pve_monsters.json", "key": "monsters"},
	{"kind": "boss", "path": "res://data/boss/bosses.json", "key": "bosses"},
	{"kind": "ally", "path": "res://data/formation/formation_allies.json", "key": "allies"},
]

var _h: CheckHarness
var _rows: Array[Dictionary] = []
var _seen_models := {}


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	for table in TABLES:
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(table.path)))
		if not (parsed is Dictionary):
			continue
		for item in (parsed as Dictionary).get(str(table.key), []):
			await _scan(item as Dictionary, str(table.kind))
	_h.item()
	_h.expect(_rows.size() >= 100, "matrix_vacuous",
		"只扫出 %d 条单位×动作，测量链多半断了" % _rows.size())
	_h.item()
	var resolved := 0
	for row in _rows:
		if not str(row["clip"]).begins_with("<"):
			resolved += 1
	_h.expect(resolved >= _rows.size() * 0.8, "playback_readback_broken",
		("只有 %d/%d 条读回了正在播的 clip —— play_xxx() 之后 current_animation "
			+ "是空的，说明读取链断了，报告内容不可信") % [resolved, _rows.size()])
	_write_report()
	_h.finish(get_tree())


func _scan(definition: Dictionary, kind: String) -> void:
	var model_path := str(definition.get("model", ""))
	var unit_id := str(definition.get("id", ""))
	if model_path.is_empty() or unit_id.is_empty():
		return
	var packed := load(model_path) as PackedScene
	if packed == null:
		return
	var root := packed.instantiate() as Node3D
	if root == null:
		return
	add_child(root)
	await get_tree().process_frame

	var nodes_value: Variant = root.get("action_nodes")
	var nodes: Dictionary = nodes_value if nodes_value is Dictionary else {}
	for action in ACTIONS:
		var clip := "<缺动作节点>"
		var length := 0.0
		var pool := 0
		var action_root := nodes.get(action) as Node
		if action_root != null:
			# 让 wrapper 自己选：这才是玩家真实看到的那条。
			root.call(str(ACTION_METHODS[action]))
			await get_tree().process_frame
			var player := _find(action_root, "AnimationPlayer") as AnimationPlayer
			if player == null:
				clip = "<没有 AnimationPlayer>"
			else:
				pool = player.get_animation_list().size()
				var playing := str(player.current_animation)
				if playing.is_empty():
					clip = "<未在播放>"
				else:
					clip = playing
					var animation := player.get_animation(playing)
					length = animation.length if animation != null else 0.0
		_rows.append({
			"id": unit_id, "kind": kind, "action": action, "clip": clip,
			"length": length, "count": pool,
		})
	root.queue_free()
	await get_tree().process_frame
	_seen_models[model_path] = true


func _write_report() -> void:
	var by_clip := {}
	for row in _rows:
		var key := str(row["clip"]) + KEY_SEP + str(row["action"])
		if not by_clip.has(key):
			by_clip[key] = {"clip": str(row["clip"]), "action": str(row["action"]),
				"length": float(row["length"]), "users": []}
		((by_clip[key] as Dictionary)["users"] as Array).append(str(row["id"]))

	var lines: Array[String] = []
	lines.append("# 包装模型动作合同矩阵")
	lines.append("")
	lines.append("由 tools/model_action_contract_report.tscn 生成。")
	lines.append("扫描 %d 个模型、%d 条「单位 × 动作」、%d 条不同的「clip × 动作」绑定。"
		% [_seen_models.size(), _rows.size(), by_clip.size()])
	lines.append("")
	lines.append("clip 是**让 wrapper 自己 `play_xxx()` 之后从 `current_animation` 读回来的**，")
	lines.append("不是重算的 —— 73 个 wrapper 的别名表有 7 种变体，重算必然报错人。")
	lines.append("")
	lines.append("> **本报告只记录事实，不判定动作对错。**")
	lines.append("> clip 名来自通用动作库，与它在本作里承担的演出职责没有必然关系；")
	lines.append("> 名字、时长、候选数都说明不了「这个动作放在这里对不对」。")
	lines.append("> 某个动作是否需要 `model_in_place_actions`，只看播放时角色主体是否")
	lines.append("> 不合理地离开自己的圆盘 —— 判据是位移数字，见")
	lines.append("> `battle_actor_body_on_disc_check` 与 `root_motion_backlog_report`。")
	lines.append("")

	lines.append("## 一、clip × 动作 绑定表（按使用单位数排序）")
	lines.append("")
	lines.append("| clip | 绑到 | 时长 | 单位数 |")
	lines.append("|---|---|---|---|")
	var keys := by_clip.keys()
	keys.sort_custom(func(a, b):
		return ((by_clip[a] as Dictionary)["users"] as Array).size() \
			> ((by_clip[b] as Dictionary)["users"] as Array).size())
	for key in keys:
		var entry := by_clip[key] as Dictionary
		var users := entry["users"] as Array
		lines.append("| `%s` | %s | %.2fs | %d |" % [
			str(entry["clip"]), str(entry["action"]), float(entry["length"]), users.size()])
	lines.append("")

	lines.append("## 二、全量矩阵")
	lines.append("")
	lines.append("括号内是该动作节点里可选的 clip 数。为 1 表示该节点只挂了这一条，")
	lines.append("没有别的候选 —— 这是资产映射的事实，不构成对错判断。")
	lines.append("")
	lines.append("| 单位 | 类 | idle | attack | run |")
	lines.append("|---|---|---|---|---|")
	var by_unit := {}
	var order: Array[String] = []
	for row in _rows:
		var unit_id := str(row["id"])
		if not by_unit.has(unit_id):
			by_unit[unit_id] = {"kind": str(row["kind"])}
			order.append(unit_id)
		(by_unit[unit_id] as Dictionary)[str(row["action"])] = row
	for unit_id in order:
		var entry := by_unit[unit_id] as Dictionary
		var cells: Array[String] = []
		for action in ACTIONS:
			var row_value: Variant = entry.get(action)
			if row_value == null:
				cells.append("—")
				continue
			var row := row_value as Dictionary
			cells.append("`%s` (%d)" % [str(row["clip"]), int(row["count"])])
		lines.append("| `%s` | %s | %s | %s | %s |" % [
			unit_id, str(entry.get("kind", "")), cells[0], cells[1], cells[2]])

	var text := ""
	for line in lines:
		text += line + "\n"
	var file := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
	_h.note("矩阵已写到 %s" % ProjectSettings.globalize_path(OUT_PATH))
	_h.note("扫描 %d 个模型、%d 条单位×动作、%d 条 clip×动作绑定"
		% [_seen_models.size(), _rows.size(), by_clip.size()])


func _find(root: Node, type_name: String) -> Node:
	if root.get_class() == type_name:
		return root
	for child in root.get_children():
		var found := _find(child, type_name)
		if found != null:
			return found
	return null
