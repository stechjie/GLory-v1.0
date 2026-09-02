extends Node

# V2 P1-04 / P1-01：**包装模型动作合同矩阵**。
#
# V2 清单在 P1-01 和 P1-04 里两次写到「后续还必须增加包装模型动作合同矩阵」，
# 这份报告就是它：把每个单位的 idle / attack / run 实际播出的 clip 列出来，
# 并把「动作语义和 clip 语义打架」的挑出来。
#
# 这**不是门禁**（文件名不以 _check 结尾，run_check.ps1 -All 不会收它）。
# 判据只能是名字，机器读不出画面，所以它不该去卡红灯 —— 但它能把
# 「攻击时在跳舞」从「玩到才发现」变成「一条命令就列出来」。
#
# 起因：给 27 条待批准的根位移做分类时，发现超标 clip 叫
# dance-graceful / aerobic-dance / birdcage / stand-to-sit。逐个 dump 后确认
# 每个动作节点**只挂一条 clip**，所以不是选曲打分挑错，是资产映射本身把
# 跳舞片指给了 attack。
#
# **不重实现选曲逻辑。** 73 个 wrapper 的 `_action_aliases()` 有 7 种不同变体
# （有的 idle 认 "relax"，有的 attack 认 "bite"/"devour"，有的 run 认 "gallop"），
# 抄任何一份都会在别的单位上报错人。这里改成让 wrapper 自己 `play_xxx()`，
# 再从 AnimationPlayer 读回 `current_animation` —— 那是 ground truth，
# 和玩家真实看到的逐字一致。
#
# 判据刻意分两档，因为「名字里没有 attack」和「名字里写着 dance」不是一回事：
#   * 共享 clip（relax-378947 给几十个单位当 idle）只是命名不带别名，**正常**；
#   * 冲突 clip（dance / sit / birdcage 绑到 attack 或 run）才是要人去看的。
# 只报第二档，第一档留在全量矩阵里供查。

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "model_action_contract_report"
const OUT_PATH := "user://model_action_contract.md"

# clip 名里出现这些词，说明它演的是「静态/生活化」内容。
# 绑到 idle 无所谓（idle 本来就该是这种），绑到 attack 或 run 才是冲突。
const SEDENTARY_WORDS := [
	"dance", "sit", "birdcage", "relax", "talk", "pose", "cage", "sleep",
	"yawn", "clap", "salute", "wave", "think", "look", "breath",
]

# 反过来的赦免词：名字里带这些就明确是战斗/位移内容，不算冲突。
# 比 wrapper 的别名表宽，因为这里只用于「免罪」，宽一点只会漏报不会误报。
const ACTION_WORDS := {
	"attack": ["attack", "atk", "punch", "slash", "hit", "cast", "spell", "shoot",
		"gun", "bite", "devour", "blast", "kick", "swing", "stab", "claw"],
	"run": ["run", "walk", "move", "catwalk", "trot", "gallop", "sprint", "dash", "fly"],
}

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
			"length": length, "count": pool, "conflict": _is_conflict(clip, action),
		})
	root.queue_free()
	await get_tree().process_frame
	_seen_models[model_path] = true


# 冲突 = 一条明显在演「坐着/跳舞/闲聊」的 clip 被绑到了 attack 或 run。
# 反过来（战斗 clip 当 idle）不算：待机摆个攻击起手式是常见做法。
func _is_conflict(clip: String, action: String) -> bool:
	if not ACTION_WORDS.has(action) or clip.begins_with("<"):
		return false
	var lower := clip.to_lower()
	for word in ACTION_WORDS[action]:
		if lower.contains(str(word)):
			return false
	for word in SEDENTARY_WORDS:
		if lower.contains(str(word)):
			return true
	return false


func _write_report() -> void:
	var conflicts: Array[Dictionary] = []
	var by_clip := {}
	for row in _rows:
		if bool(row["conflict"]):
			conflicts.append(row)
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
	lines.append("**共享 clip 不是问题**：一条 idle 给几十个单位复用是正常做法。")
	lines.append("下面只列语义打架的。")
	lines.append("")

	lines.append("## 一、冲突：静态/生活化 clip 被绑到 attack 或 run（%d 条）" % conflicts.size())
	lines.append("")
	if conflicts.is_empty():
		lines.append("无。")
	else:
		lines.append("| # | 单位 | 类 | 动作 | 实际播的 clip | 时长 | 该节点可选 clip 数 |")
		lines.append("|---|---|---|---|---|---|---|")
		conflicts.sort_custom(func(a, b): return str(a["clip"]) + str(a["id"]) < str(b["clip"]) + str(b["id"]))
		var index := 0
		for row in conflicts:
			index += 1
			lines.append("| %d | `%s` | %s | **%s** | `%s` | %.2fs | %d |" % [
				index, str(row["id"]), str(row["kind"]), str(row["action"]),
				str(row["clip"]), float(row["length"]), int(row["count"])])
		lines.append("")
		lines.append("> **可选 clip 数为 1 时不是选曲挑错**（没有别的可选），")
		lines.append("> 而是资产映射本身把这条指给了这个动作。修法是换 FBX，不是改代码。")
	lines.append("")

	lines.append("## 二、clip × 动作 绑定表（按使用单位数排序）")
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
		var mark := " ⚠" if _is_conflict(str(entry["clip"]), str(entry["action"])) else ""
		lines.append("| `%s`%s | %s | %.2fs | %d |" % [
			str(entry["clip"]), mark, str(entry["action"]), float(entry["length"]), users.size()])
	lines.append("")

	lines.append("## 三、全量矩阵")
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
			var text := "`%s`" % str(row["clip"])
			if bool(row["conflict"]):
				text = "⚠ " + text
			cells.append(text)
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
	_h.note("扫描 %d 个模型、%d 条单位×动作、%d 条 clip×动作绑定；语义冲突 %d 条"
		% [_seen_models.size(), _rows.size(), by_clip.size(), conflicts.size()])


func _find(root: Node, type_name: String) -> Node:
	if root.get_class() == type_name:
		return root
	for child in root.get_children():
		var found := _find(child, type_name)
		if found != null:
			return found
	return null
