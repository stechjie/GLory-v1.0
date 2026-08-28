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
	_check_offline_only_guard_survives()
	_check_input_is_observed_not_consumed()
	_check_budget_backoff(warmup)
	_check_input_yield_behaviour(warmup)

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


# The load-bearing invariant of the whole design: warm only while nothing is
# connected, because there is no heartbeat to time out then. Lose this guard and the
# 28.3 s mid-match freeze at the top of VFXWarmup.gd comes back.
func _check_offline_only_guard_survives() -> void:
	var source := _code_only(FileAccess.get_file_as_string("res://effects/vfx3d/VFXWarmup.gd"))
	if not _h.expect(not source.is_empty(), "source_read", "无法读取 VFXWarmup.gd 源码"):
		return
	var process_at := source.find("func _process(")
	if not _h.expect(process_at >= 0, "process_missing", "找不到 _process()"):
		return
	# Only the head of _process matters: the abort has to happen before any work.
	var head := source.substr(process_at, 400)
	_h.expect(head.contains("NetworkService.SessionState.OFFLINE"),
		"offline_guard_missing",
		"_process() 开头不再检查 SessionState.OFFLINE —— 预热会带着心跳跑进对局")
	_h.expect(head.contains("abort("),
		"offline_abort_missing", "_process() 开头没有 abort() —— 离线守卫没有出口")


# This node sits on the scene tree root, so _input() sees every event before the UI
# does. Consuming one here would swallow the player's taps -- which is the exact
# symptom ("clicked and nothing happened") the V3 list is trying to remove.
func _check_input_is_observed_not_consumed() -> void:
	var source := _code_only(FileAccess.get_file_as_string("res://effects/vfx3d/VFXWarmup.gd"))
	if source.is_empty():
		return
	_h.expect(source.contains("func _input(event: InputEvent) -> void:"),
		"input_hook_missing", "没有 _input() —— 输入让路无从判断最近是否有触摸")
	_h.expect(not source.contains("set_input_as_handled"),
		"input_consumed",
		"VFXWarmup 调用了 set_input_as_handled() —— 挂在 root 上会吞掉玩家的点击")
	# The starvation cap is asserted behaviourally instead of by name, in
	# _check_input_yield_behaviour().


# The budget used to be checked after the spawn had already happened, so it limited
# nothing. Assert the replacement actually converts overshoot into wait frames.
func _check_budget_backoff(warmup) -> void:
	_h.expect(warmup._backoff_frames_for(WarmupScript.FRAME_BUDGET_MS - 1.0) == 0,
		"backoff_on_cheap_item", "预算内的项目也被追加了等待帧")
	# Explicitly typed, not inferred: `warmup` is an untyped local (the script is
	# preloaded, not a global class), so := has nothing to infer from and the whole
	# check script fails to parse.
	var one_over: int = warmup._backoff_frames_for(WarmupScript.FRAME_BUDGET_MS * 2.0)
	_h.expect(one_over >= 1, "backoff_absent", "超预算一倍的项目没有追加等待帧")
	var huge: int = warmup._backoff_frames_for(WarmupScript.FRAME_BUDGET_MS * 1000.0)
	_h.expect(huge <= WarmupScript.MAX_BACKOFF_FRAMES,
		"backoff_unbounded",
		"退避帧数没有上限（%d > %d）—— 单个坏项目能把队列推出离线窗口"
			% [huge, WarmupScript.MAX_BACKOFF_FRAMES])


# Drives _should_yield_to_input() directly. Nothing else exercises it: an
# unattended launch never touches the screen, so a real run reports
# "yielded_frames 0" whether the logic works or is broken outright.
#
# The clock fields are set by hand rather than by faking input events, because what
# has to hold is the decision, not the plumbing that records the timestamp.
func _check_input_yield_behaviour(warmup) -> void:
	var now := Time.get_ticks_usec()

	# Nothing has been touched yet: never yield, or the queue would never start.
	warmup._last_input_us = 0
	warmup._yield_started_us = 0
	_h.expect(not warmup._should_yield_to_input(),
		"yield_without_input", "还没有任何输入就开始让路，预热永远起不来")

	# Touched just now: hold off.
	warmup._last_input_us = Time.get_ticks_usec()
	warmup._yield_started_us = 0
	_h.expect(warmup._should_yield_to_input(),
		"no_yield_after_input", "刚有输入却仍然启动新项 —— 输入让路没生效")

	# Quiet for longer than the window: resume.
	warmup._last_input_us = now - int((WarmupScript.INPUT_QUIET_MS + 50.0) * 1000.0)
	warmup._yield_started_us = 0
	_h.expect(not warmup._should_yield_to_input(),
		"yield_after_quiet", "安静超过 %.0f ms 之后仍在让路" % WarmupScript.INPUT_QUIET_MS)

	# Still being touched, but held off past the cap: take one item anyway. Without
	# this, someone drumming on the language screen pushes the whole queue past the
	# offline window, and the shader cost lands in the first battle instead.
	warmup._last_input_us = Time.get_ticks_usec()
	warmup._yield_started_us = now - int((WarmupScript.INPUT_YIELD_MAX_MS + 50.0) * 1000.0)
	_h.expect(not warmup._should_yield_to_input(),
		"starvation_cap_ineffective",
		"连续输入让路超过 %.0f ms 后仍不放行 —— 预热可被饿死" % WarmupScript.INPUT_YIELD_MAX_MS)

	warmup._last_input_us = 0
	warmup._yield_started_us = 0


# Source text with comments removed.
#
# Needed because these assertions cannot otherwise tell code from prose, and it cuts
# both ways: a comment saying "never call set_input_as_handled()" tripped the
# forbidden-call assertion, and — worse — a comment merely *mentioning*
# SessionState.OFFLINE would satisfy the guard-still-present assertion after the
# real guard had been deleted.
#
# Deliberately simple: cut each line at its first '#'. GDScript string literals may
# contain '#', so this can truncate a line early; that only ever removes text from
# the haystack, which cannot turn a real failure into a pass.
func _code_only(source: String) -> String:
	var out: PackedStringArray = []
	for raw_line in source.split("\n"):
		var line := str(raw_line)
		var hash_at := line.find("#")
		if hash_at >= 0:
			line = line.substr(0, hash_at)
		out.append(line)
	return "\n".join(out)


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
