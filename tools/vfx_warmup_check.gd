extends Node

# E3 gate for the startup shader warmup.
#
# The warmup is split into phases, but the split may only reorder work — never
# drop it. It also must not draw its developer readout in a release build.
#
# Why phases only reorder: the whole safety argument for warming at startup is
# that nothing is connected yet, so there is no heartbeat to time out (see the
# 28.3 s freeze recorded at the top of VFXWarmup.gd). _process() aborts the moment
# the session leaves OFFLINE, so a phase deferred past the menu would simply never
# run in an online match. What phasing buys is ordering: an early abort should
# lose the items the player meets last, not the ones every unit uses every round.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const WarmupScript := preload("res://effects/vfx3d/VFXWarmup.gd")
const CHECK_NAME := "vfx_warmup"

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	DataRegistry.load_all()
	var warmup = WarmupScript.new()
	add_child(warmup)
	var queue: Array = warmup._collect_ids()
	var totals: Dictionary = warmup.phase_totals()

	_check_no_work_lost(warmup, queue, totals)
	_check_phase_order(warmup, queue)
	_check_phase_membership(warmup)
	_check_release_build_has_no_readout()

	_h.note("queue=%d phases=%s" % [queue.size(), str(totals)])
	warmup.queue_free()
	_h.finish(get_tree())


# The union of the phases must be exactly the queue, with nothing duplicated and
# nothing unassigned. A dropped id is a shader that compiles mid-battle instead.
func _check_no_work_lost(warmup, queue: Array, totals: Dictionary) -> void:
	_h.expect(not queue.is_empty(), "queue_empty", "预热队列为空 —— 空集合不算通过")
	var summed := 0
	for phase in totals.keys():
		summed += int(totals[phase])
	_h.expect(summed == queue.size(),
		"phase_sum", "各阶段之和 %d 与队列长度 %d 不一致" % [summed, queue.size()])

	var seen := {}
	for item_value in queue:
		var item := str(item_value)
		_h.expect(not seen.has(item), "duplicate_item", "队列里出现重复项：%s" % item)
		seen[item] = true
		_h.expect(not warmup.phase_of(item).is_empty(),
			"item_unassigned", "%s 没有被分配到任何阶段" % item)

	# Every declared phase must actually exist in the queue: an empty phase means
	# the table it reads from was renamed and the ids silently vanished.
	for phase in WarmupScript.PHASES:
		_h.expect(int(totals.get(phase, 0)) > 0,
			"phase_empty", "阶段 %s 一项都没有 —— 多半是数据表键名改了" % str(phase))


# The queue must be laid out phase by phase, or an early abort would not lose the
# last phase first, which is the entire point of the split.
func _check_phase_order(warmup, queue: Array) -> void:
	var order := {}
	for i in WarmupScript.PHASES.size():
		order[str(WarmupScript.PHASES[i])] = i
	var highest_seen := -1
	var regressed := false
	for item_value in queue:
		var rank := int(order.get(warmup.phase_of(str(item_value)), 99))
		if rank < highest_seen:
			regressed = true
			break
		highest_seen = maxi(highest_seen, rank)
	_h.expect(not regressed, "phase_interleaved", "队列没有按阶段分段排列，提前中止时会丢错东西")


func _check_phase_membership(warmup) -> void:
	# Basic attacks are what every unit does every round, so they warm first.
	for attack_value in WarmupScript.BASIC_ATTACKS:
		_h.expect(warmup.phase_of(str(attack_value)) == WarmupScript.PHASE_MENU_MINIMAL,
			"basic_attack_phase", "普攻 %s 不在最优先阶段" % str(attack_value))

	# A round-1 PVE monster skill must not warm after a boss skill the player
	# cannot meet before round 5. This is the ordering bug the split fixed: the
	# old flat table put pve_monsters last, behind mercenaries and bosses.
	var monster_skill := _first_skill_of("pve_monsters", "monsters")
	var boss_skill := _first_skill_of("bosses", "bosses")
	if not monster_skill.is_empty() and not boss_skill.is_empty():
		_h.expect(warmup.phase_of(monster_skill) == WarmupScript.PHASE_FIRST_BATTLE,
			"monster_phase", "PVE 小怪技能 %s 应在 first_battle 阶段" % monster_skill)
		_h.expect(warmup.phase_of(boss_skill) == WarmupScript.PHASE_DEFERRED,
			"boss_phase", "Boss 技能 %s 应在 deferred 阶段" % boss_skill)

	# External VFX scenes are the heaviest items and the latest needed.
	var scene_items := 0
	for path in BattleAssetManifest.seed_independent_paths():
		scene_items += 1
		_h.expect(warmup.phase_of(str(path)) == WarmupScript.PHASE_DEFERRED,
			"scene_phase", "外部场景 %s 应在 deferred 阶段" % str(path))
	_h.expect(scene_items > 0, "scene_missing", "外部 VFX 场景一个都没进队列")


# The progress readout is a developer tool. Drawing it in a release build puts
# "预热 96/96 最慢 54 ms" over the language-select screen, which README E3
# explicitly forbids.
func _check_release_build_has_no_readout() -> void:
	var source := FileAccess.get_file_as_string("res://effects/vfx3d/VFXWarmup.gd")
	_h.expect(not source.is_empty(), "source_read", "无法读取 VFXWarmup.gd 源码")
	var guard_at := source.find("func _build_label() -> void:")
	_h.expect(guard_at >= 0, "build_label_missing", "找不到 _build_label()")
	if guard_at < 0:
		return
	var body := source.substr(guard_at, 200)
	_h.expect(body.contains("OS.is_debug_build()"),
		"readout_ungated", "_build_label() 必须以 OS.is_debug_build() 守卫，否则正式版会在语言页画开发文字")


func _first_skill_of(table_name: String, rows_key: String) -> String:
	var table: Variant = DataRegistry.get_table(table_name)
	if typeof(table) != TYPE_DICTIONARY:
		return ""
	for row in (table as Dictionary).get(rows_key, []):
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var sid := str((row as Dictionary).get("skill_id", ""))
		if not sid.is_empty() and sid != "none" and not WarmupScript.NO_VFX_SKILLS.has(sid):
			return sid
	return ""
