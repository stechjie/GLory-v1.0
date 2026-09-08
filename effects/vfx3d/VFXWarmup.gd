extends Node
class_name VFXWarmup

# 启动时的 shader 预热。
#
# 为什么要预热：VFX 的材质是运行时用 GDScript 里的 shader 源码建的，第一次被
# 光栅化时才编译成管线。实测装完第一次打第 1 回合，主线程被这件事堵了 6.2 秒
# （单帧 proc=6156ms + [NET] process freeze 6.2s），期间编译了 21 个
# SceneForwardMobileShaderRD + 6 个 ParticlesShaderRD。
#
# 为什么放在启动而不是大厅：
#   1. Godot 的 shader_cache + vulkan pipeline cache 跨启动有效（实测重启后
#      新编译 0 个），所以这笔成本一个安装周期只付一次，不该每局都付
#   2. 启动阶段还没连服务器，没有心跳可以超时 —— 这正是上次 warm_draw() 出事
#      的原因（对局中一帧实例化 14 个场景，冻结 28.3 秒，直接被判掉线）
#   3. 从引擎就绪到连上服务器实测有 44 秒（语言选择 / 教程 / 宠物 / 主菜单），
#      预热藏在这段里，玩家零感知
#
# Sharing the window with the player (added for V3 P0-04):
#
# The offline window is not idle time -- it is the language screen, the tutorial and
# the menu, i.e. exactly where the V3 review measured 40-105 ms main-thread frames.
# The review's own remedy was "pause the warmup on those screens", which cannot be
# done here: those screens *are* the window, and _process() aborts the moment the
# session leaves OFFLINE, so pausing there is cancelling (see above). Two things are
# done instead, neither of which shortens the window:
#
#   1. _should_yield_to_input() declines to *start* an item within INPUT_QUIET_MS of
#      a touch, with a starvation cap so continuous input cannot hold the queue off.
#   2. An item that overruns FRAME_BUDGET_MS buys extra settle frames before the
#      next one starts, so spikes do not stack up back to back.
#
# Per-item cost is now measured across _spawn_one() itself. It previously timed from
# the *end* of the spawn to the end of the settle frames, so the "slowest 54 ms"
# figure in the old logs was really FRAMES_PER_ITEM of wall clock and told you
# nothing about which item was expensive.
#
# 离屏视口必须和 BattleArena._battle_3d_viewport 逐项对齐（尤其 transparent_bg）：
# Vulkan 管线按 framebuffer 格式索引，格式不一致的话预热出来的管线在战斗里用不上。
# 真机 8 项验证版实测：预热窗口精确写入 7 个 SceneForwardMobileShaderRD，
# 第 1 回合的新编译量随之从 21 降到 13 —— 格式是对上的。

const PROCEDURAL_VFX := preload("res://effects/BossProceduralVFX3D.gd")

# 普攻组合。这几个不在数据表里（种族 × 近战/远程是代码推出来的），要手写。
const BASIC_ATTACKS := [
	"basic_attack_melee_god", "basic_attack_ranged_god",
	"basic_attack_melee_human", "basic_attack_ranged_human",
	"basic_attack_melee_dark", "basic_attack_ranged_dark",
	"basic_attack_melee_undead", "basic_attack_ranged_undead",
]

# 技能从数据表现场收集，不手写清单 —— 手写的话加一个新单位就漏热一个，
# 而漏掉的那个会在战斗中途现编译，正是要消除的东西。
#
# E3：分成两张表是为了排序，不是为了推迟。
#
# 说明一下为什么不能"推迟到备战/首战再热"（README E3 的字面写法）：本预热的
# 全部安全性建立在"此刻还没连服务器、没有心跳会超时"之上（见文件头那次 28.3 秒
# 冻结掉线）。_process() 第一件事就是一旦 state != OFFLINE 立刻 abort，所以
# 联机下推后的阶段根本不会执行 —— 推迟等于取消，shader 编译成本会原样回到
# 第一场战斗。
#
# 分阶段真正买到的是**顺序**：离线菜单窗口有限，玩家点得快就会提前 abort，
# 那时候应该先热到的是每回合每个单位都放的普攻，最后才是 Boss 与最终战援军。
const FIRST_BATTLE_TABLES := {
	"race_units": "units",
	"pve_monsters": "monsters",
}

const DEFERRED_TABLES := {
	"mercenaries": "mercenaries",
	"bosses": "bosses",
	"formation_allies": "allies",
}

const PHASE_MENU_MINIMAL := "menu_minimal"
const PHASE_FIRST_BATTLE := "first_battle"
const PHASE_DEFERRED := "deferred"

const PHASES := [PHASE_MENU_MINIMAL, PHASE_FIRST_BATTLE, PHASE_DEFERRED]

# 战斗里会播、但不是任何单位的 skill_id 的 effect_id。
# 来源：grep BattleVfx 里 _play_*_procedural("字面量") + BossProceduralVFX3D 的特例分支。
# 光靠数据表收集会全部漏掉这些 —— 比如 mirror_clone 这个技能在战斗里实际播的是
# mirror_slash（BattleVfx 做了重映射），按 skill_id 喂等于喂了个不存在的分支。
const EXTRA_EFFECTS := [
	"mirror_slash", "mirror_spawn",
	"apocalypse_complete", "apocalypse_interrupt",
	"blood_lifesteal", "overload_stack", "rage_milestone", "twin_timer",
	"lightning_strike", "lightning_ball", "meteor_strike",
]

# 纯数值/经济技能，没有任何 VFX 分支。喂进去只会 push_warning 并白占一帧。
const NO_VFX_SKILLS := ["post_battle_gold_by_star", "mirror_clone"]

# 每个特效播完等几帧再销毁。1 帧只保证提交，2 帧比较稳。
const FRAMES_PER_ITEM := 2
# 单帧预算。超了就直接让出，宁可多花几帧也不要在启动时造成可感知的顿挫。
const FRAME_BUDGET_MS := 12.0

# Cumulative buckets for per-item cost. An item over 50 ms is also counted in the
# 33 and 16.7 buckets -- what matters when reading the report is how far into the
# tail the worst items sit, not which single band they land in.
const SPIKE_WARN_MS := 16.7
const SPIKE_BAD_MS := 33.0
const SPIKE_SEVERE_MS := 50.0
# Ceiling on the backoff below. Without it a single pathological item could push
# the rest of the queue past the end of the offline window.
const MAX_BACKOFF_FRAMES := 8

# Do not start a new item within this long of the last input event.
#
# Note what this is NOT: pausing the warmup on the language / tutorial / shop
# screens. Those screens *are* the offline window this whole thing depends on (see
# the header), so pausing there would not defer the work, it would cancel it and
# hand the shader compilation back to the first battle. This only declines to start
# an item in the same handful of frames the player is actually touching.
const INPUT_QUIET_MS := 500.0
# Starvation guard. Someone drumming on the screen must not be able to hold the
# queue off indefinitely; after this long yielding, take one item anyway.
const INPUT_YIELD_MAX_MS := 3000.0
# How many of the slowest items the report names. Ten is enough to see a pattern
# without printing the whole queue into logcat.
const SLOWEST_REPORTED := 10

signal finished(report: Dictionary)

var _viewport: SubViewport
var _world_root: Node3D
var _queue: Array[String] = []
var _done := 0
var _total := 0
var _aborted := false
var _running := false

# V3 P0-04：显式状态机。
#
# 以前只有 `_running` / `_aborted` 两个布尔，读报告的人能看出「没在跑」，
# 但看不出**为什么**没在跑 —— 是玩家在操作、是有 modal 挡着、还是内存告警了。
# 这三种"没在跑"的处理方式完全不同：第一种等一会儿就好，第三种要放缓存。
#
# RUNNING         正在起项
# IDLE_WINDOW     队列还有东西，但这一帧让给了输入（最近 500 ms 有输入）
# NON_INTERACTIVE 玩家碰不到的阶段（Bootstrap / 不可交互加载页），可以放开跑
# PAUSED          被 modal 或低内存挡住，且原因记在 _state_reason 里
# CANCELLED       abort() 过
# FINISHED        队列跑完
enum State { RUNNING, IDLE_WINDOW, NON_INTERACTIVE, PAUSED, CANCELLED, FINISHED }

var _state := State.NON_INTERACTIVE
var _state_reason := "not_started"
# 每个状态累计停留的帧数。报告里给出分布，才能回答
# 「预热没跑完是因为一直被挡着，还是因为它本来就慢」。
var _state_frames: Dictionary = {}
# 收到 NOTIFICATION_OS_MEMORY_WARNING 之后置位。只暂停 deferred 阶段，
# 不动 first_battle —— 那批是当前战斗要用的。
var _low_memory := false
var _t_start_us := 0
var _slowest_ms := 0.0
var _slowest_id := ""
var _label: Label
# E3: which phase each queued id belongs to, and how many of each finished.
var _phase_by_id: Dictionary = {}
var _phase_total: Dictionary = {}
var _phase_done: Dictionary = {}
var _phase_first_done_ms: Dictionary = {}
# Per-item spawn cost. This is the number that was missing: the old _slowest_ms
# timed from the end of _spawn_one() to the end of the settle frames, so it was
# measuring FRAMES_PER_ITEM of wall clock, not the main-thread work. The 40-105 ms
# frames the V3 review recorded happen *inside* _spawn_one().
var _item_costs: Array[Dictionary] = []
var _spike_counts: Dictionary = {"over_16_7ms": 0, "over_33ms": 0, "over_50ms": 0}
var _last_input_us := 0
var _yield_started_us := 0
var _yielded_frames := 0

func start() -> void:
	if _running:
		return
	# 设备侧基线要测的正是着色器编译和贴图读盘。预热挂在 root 上、跨场景存活，
	# 所以 Main._ready() 起的这一份会一直跑到测量中间去，把它自己的 GPU 占用和
	# 缺页算进被测数字里。见 scripts/autoload/DeviceHarness.gd。
	if DeviceHarness.harness_active():
		print("[WARMUP] 设备侧诊断已接管本次启动，跳过预热以免污染实机指标")
		return
	_running = true
	_queue = _collect_ids()
	_total = _queue.size()
	_done = 0
	_t_start_us = Time.get_ticks_usec()
	_build_viewport()
	_build_label()
	set_process(true)
	var scenes := 0
	for q in _queue:
		if q.begins_with("res://"):
			scenes += 1
	print("[WARMUP] 启动预热：%d 项（普攻 %d + 技能 %d + 外部场景 %d）"
		% [_total, BASIC_ATTACKS.size(), _total - BASIC_ATTACKS.size() - scenes, scenes])
	var phase_parts: Array[String] = []
	for phase_name in PHASES:
		phase_parts.append("%s %d" % [phase_name, int(_phase_total.get(phase_name, 0))])
	print("[WARMUP] 阶段顺序：%s（按需要得越早排越前；提前中止时丢的是最靠后的）"
		% " → ".join(phase_parts))
	print("[WARMUP] 清单：%s" % ", ".join(_queue))

# 普攻 + 数据表里出现过的全部 skill_id，按阶段排序后拉平成一条队列。
# 普攻永远在最前 —— 它们每回合每个单位都放，最该先热到。
#
# 阶段划分只影响顺序与提前中止时的取舍，不影响总量：三个阶段的并集与分阶段
# 之前完全一致（有 tools/vfx_warmup_check 守着这一点）。
func _collect_ids() -> Array[String]:
	_phase_by_id.clear()
	_phase_total.clear()
	_phase_done.clear()
	_phase_first_done_ms.clear()
	var out: Array[String] = []
	var seen := {}

	# 阶段 1：普攻。8 项，最快热完，也是玩家一定会看到的。
	for s_value in BASIC_ATTACKS:
		_append_phase_id(out, seen, str(s_value), PHASE_MENU_MINIMAL)

	# 阶段 2：第一场战斗真的会出现的东西 —— 可购买棋子与 PVE 小怪的技能。
	for table_name in FIRST_BATTLE_TABLES:
		for sid in _skill_ids_of(str(table_name), str(FIRST_BATTLE_TABLES[table_name])):
			_append_phase_id(out, seen, sid, PHASE_FIRST_BATTLE)

	# 阶段 3：更晚才出现的。Boss 在第 5 回合、佣兵要买、阵营援军只在最终战。
	for table_name in DEFERRED_TABLES:
		for sid in _skill_ids_of(str(table_name), str(DEFERRED_TABLES[table_name])):
			_append_phase_id(out, seen, sid, PHASE_DEFERRED)
	for e in EXTRA_EFFECTS:
		_append_phase_id(out, seen, str(e), PHASE_DEFERRED)
	# 外部 VFX 场景（binbun / starter）。以 res:// 开头，_spawn_one 据此分支。
	#
	# 为什么单列一段：大厅预载只把它们读进内存（Resource Ready），场景里的
	# GPUParticles3D 要真的被光栅化一次才编译 shader。实测第 1 回合
	# cold=3、编译 4 个 ParticlesShaderRD，就是这批漏掉的。
	# 按 skill_id 播只有少数技能会走到外部分支，热不全，所以直接实例化整个场景。
	for p_value in BattleAssetManifest.seed_independent_paths():
		_append_phase_id(out, seen, str(p_value), PHASE_DEFERRED)
	return out


func _skill_ids_of(table_name: String, rows_key: String) -> Array[String]:
	var out: Array[String] = []
	var table: Variant = DataRegistry.get_table(table_name)
	if typeof(table) != TYPE_DICTIONARY:
		return out
	var rows: Variant = (table as Dictionary).get(rows_key, [])
	if typeof(rows) != TYPE_ARRAY:
		return out
	for row in rows:
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var sid := str((row as Dictionary).get("skill_id", ""))
		if sid.is_empty() or sid == "none" or NO_VFX_SKILLS.has(sid):
			continue
		out.append(sid)
	return out


func _append_phase_id(out: Array[String], seen: Dictionary, id_value: String, phase: String) -> void:
	if id_value.is_empty() or seen.has(id_value):
		return
	seen[id_value] = true
	out.append(id_value)
	_phase_by_id[id_value] = phase
	_phase_total[phase] = int(_phase_total.get(phase, 0)) + 1


func phase_totals() -> Dictionary:
	return _phase_total.duplicate(true)


func phase_of(id_value: String) -> String:
	return str(_phase_by_id.get(id_value, ""))


func abort(reason: String) -> void:
	if not _running:
		return
	_aborted = true
	var lost: Dictionary = {}
	for pending in _queue:
		var phase := str(_phase_by_id.get(str(pending), "?"))
		lost[phase] = int(lost.get(phase, 0)) + 1
	print("[WARMUP] 中止（%s）：完成 %d/%d，未热到 %s" % [reason, _done, _total, str(lost)])
	_finish()

# 判读用。真正要看的不是这里的耗时，而是设备上
#   files/shader_cache/SceneForwardMobileShaderRD/ 的文件数按写入时间戳归因：
#   落在预热窗口内的就是预热的产出，之后第 1 回合的新增量应随之下降。
func warmup_report() -> Dictionary:
	return {
		"total": _total, "done": _done, "aborted": _aborted,
		"elapsed_ms": float(Time.get_ticks_usec() - _t_start_us) / 1000.0,
		# Spawn cost, not settle time -- see _item_costs.
		"slowest_ms": _slowest_ms, "slowest_id": _slowest_id,
		"slowest_items": _slowest_items(),
		"spike_counts": _spike_counts.duplicate(true),
		"yielded_frames": _yielded_frames,
		"phase_total": _phase_total.duplicate(true),
		"phase_done": _phase_done.duplicate(true),
		"phase_first_done_ms": _phase_first_done_ms.duplicate(true),
	}

func _build_viewport() -> void:
	# 逐项对齐 BattleArena._battle_3d_viewport。尺寸不进管线 key（视口是动态状态），
	# 所以这里开 64x64 就够；transparent_bg / msaa / 更新模式必须一致。
	_viewport = SubViewport.new()
	# Offscreen rendering alone does not isolate the world. Without this,
	# warmup effects at the origin are visible through the preparation camera.
	_viewport.own_world_3d = true
	_viewport.name = "VFXWarmupViewport"
	_viewport.size = Vector2i(64, 64)
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	add_child(_viewport)

	_world_root = Node3D.new()
	_world_root.name = "WarmupWorld"
	_viewport.add_child(_world_root)

	var cam := Camera3D.new()
	cam.current = true
	cam.position = Vector3(0.0, 0.6, 3.0)
	# 先入树再 look_at：look_at 要读全局变换，节点不在树里会直接报
	# "Node not inside tree"，相机就保持默认朝向了。
	_viewport.add_child(cam)
	cam.look_at(Vector3(0.0, 0.3, 0.0), Vector3.UP)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55.0, 35.0, 0.0)
	_viewport.add_child(light)

# E3: this is a developer readout. It used to be built unconditionally, so a
# release build drew "预热 96/96 最慢 54 ms (…)" over the language-select screen —
# exactly the "不得在语言页暴露开发文字" the README calls out.
func _build_label() -> void:
	if not OS.is_debug_build():
		return
	var layer := CanvasLayer.new()
	layer.name = "VFXWarmupHUD"
	layer.layer = 128
	add_child(layer)
	_label = Label.new()
	_label.add_theme_color_override("font_color", Color(0.55, 0.85, 1.0, 0.85))
	_label.add_theme_font_size_override("font_size", 14)
	_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_label.offset_left = 12.0
	_label.offset_top = -34.0
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_label)

var _wait_frames := 0
var _active: Node = null
var _active_id := ""


# Observation only. This node lives on the scene tree root, so consuming an event
# here would eat the player's taps before any UI sees them -- never call
# set_input_as_handled() from this function.
#
# Plain mouse motion is deliberately not counted: a cursor drifting across a menu
# is not a frame anyone is waiting on, and treating it as input would keep the
# warmup yielding for the entire desktop session.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton or event is InputEventScreenTouch \
			or event is InputEventScreenDrag or event is InputEventKey:
		_last_input_us = Time.get_ticks_usec()


func _should_yield_to_input() -> bool:
	if _last_input_us == 0:
		return false
	var now := Time.get_ticks_usec()
	if float(now - _last_input_us) / 1000.0 >= INPUT_QUIET_MS:
		_yield_started_us = 0
		return false
	if _yield_started_us == 0:
		_yield_started_us = now
		return true
	if float(now - _yield_started_us) / 1000.0 >= INPUT_YIELD_MAX_MS:
		# Held off long enough. Take one item so continuous input cannot starve the
		# queue past the end of the offline window.
		_yield_started_us = 0
		return false
	return true


# Frames of extra settle for an item that overran the budget, one per budget's
# worth of overshoot.
func _backoff_frames_for(spawn_ms: float) -> int:
	if spawn_ms <= FRAME_BUDGET_MS:
		return 0
	var over := (spawn_ms - FRAME_BUDGET_MS) / FRAME_BUDGET_MS
	return clampi(int(ceil(over)), 1, MAX_BACKOFF_FRAMES)


func _note_item_cost(item_id: String, ms: float) -> void:
	_item_costs.append({
		"id": item_id,
		"phase": str(_phase_by_id.get(item_id, "")),
		"ms": snappedf(ms, 0.1),
	})
	if ms > _slowest_ms:
		_slowest_ms = ms
		_slowest_id = item_id
	# Cumulative on purpose -- see the bucket constants.
	if ms > SPIKE_WARN_MS:
		_spike_counts["over_16_7ms"] = int(_spike_counts["over_16_7ms"]) + 1
	if ms > SPIKE_BAD_MS:
		_spike_counts["over_33ms"] = int(_spike_counts["over_33ms"]) + 1
	if ms > SPIKE_SEVERE_MS:
		_spike_counts["over_50ms"] = int(_spike_counts["over_50ms"]) + 1


# The worst offenders, most expensive first. This is what makes the report
# actionable: "96 items took 3548 ms" says nothing about which ones to attack.
func _slowest_items() -> Array:
	var sorted := _item_costs.duplicate(true)
	sorted.sort_custom(func(a, b): return float(a["ms"]) > float(b["ms"]))
	return sorted.slice(0, mini(SLOWEST_REPORTED, sorted.size()))

func _process(_delta: float) -> void:
	if not _running:
		return
	# 一旦联网就停手：预热的全部安全性依赖于「此刻没有心跳要维持」。
	if NetworkService.state != NetworkService.SessionState.OFFLINE:
		abort("已连接服务器")
		return

	if _active != null:
		_wait_frames -= 1
		if _wait_frames > 0:
			return
		if is_instance_valid(_active):
			_active.queue_free()
		_active = null
		_done += 1
		_note_phase_progress()
		_update_label()
		return

	if _queue.is_empty():
		_finish()
		return

	# V3 P0-04：modal 在栈上就暂停。
	#
	# 输入让路（下面那段）只看"最近有没有点过"，挡不住这种情况：玩家打开了宝藏
	# 三选一，盯着三张卡想了五秒没动手 —— 输入静默期早就过了，预热照跑，
	# 而那正是他要做决定的时刻。有 modal 就是有人在等玩家，让开。
	if ModalStack.depth() > 0:
		_enter_state(State.PAUSED, "modal_open:%s" % ModalStack.top_id())
		return

	# V3 P0-04：低内存时停掉 deferred。
	# first_battle 那批是当前战斗要用的，停了会让战斗现场掉帧，得不偿失。
	if _low_memory and _next_phase_is_deferred():
		_enter_state(State.PAUSED, "low_memory")
		return

	# Yield the frame rather than the window: this defers one item by a few frames,
	# it does not stop the queue. See INPUT_QUIET_MS.
	if _should_yield_to_input():
		_yielded_frames += 1
		_enter_state(State.IDLE_WINDOW, "recent_input")
		return

	_enter_state(State.RUNNING, "")

	var skill_id: String = _queue.pop_front()
	_active_id = skill_id
	var spawn_started := Time.get_ticks_usec()
	_spawn_one(skill_id)
	var spawn_ms := float(Time.get_ticks_usec() - spawn_started) / 1000.0
	_note_item_cost(skill_id, spawn_ms)
	# The old budget check sat *after* _spawn_one() and only did `return`, which is
	# what the frame did anyway -- so it never limited anything. Cost is now paid
	# forward instead: an item that overran the budget buys extra settle frames, so
	# the next one does not land in the same stretch the player already felt.
	_wait_frames = FRAMES_PER_ITEM + _backoff_frames_for(spawn_ms)

func _spawn_one(item: String) -> void:
	if item.begins_with("res://"):
		_spawn_scene(item)
		return
	_spawn_skill(item)

# 直接实例化外部 VFX 场景并入树，让它自己播一帧。
func _spawn_scene(path: String) -> void:
	var holder := Node3D.new()
	holder.name = "WarmScene_%s" % path.get_file().get_basename()
	_world_root.add_child(holder)
	var ps := ResourceLoader.load(path) as PackedScene
	if ps != null:
		var inst := ps.instantiate()
		if inst is Node3D:
			(inst as Node3D).position = Vector3.ZERO
		holder.add_child(inst)
	_active = holder

func _spawn_skill(skill_id: String) -> void:
	# 整项挂在一个容器下，销毁时连锚点一起回收 —— 锚点单独 add_child 到
	# _world_root 的话会一直堆着，88 项下来就是上百个游离节点。
	var holder := Node3D.new()
	holder.name = "Warm_%s" % skill_id
	_world_root.add_child(holder)

	var origin := Vector3(-0.6, 0.3, 0.0)
	var target := Vector3(0.6, 0.3, 0.0)
	# 有些分支会读 target_node / origin_node 去挂锚点，给真实节点免得报空。
	var origin_node := Node3D.new()
	origin_node.position = origin
	holder.add_child(origin_node)
	var target_node := Node3D.new()
	target_node.position = target
	holder.add_child(target_node)

	# 走 BossProceduralVFX3D.play()：它就是战斗里 BattleVfx._play_boss_procedural /
	# _play_unit_procedural 唯一的落点，内部按 UNIT_SKILLS 分派到单位 composer
	# 还是 Boss composer。直接调某一个 composer 会漏掉另一半技能。
	var vfx := PROCEDURAL_VFX.new()
	vfx.name = "ProceduralVFX"
	holder.add_child(vfx)

	var context := {
		"origin_node": origin_node,
		"target_node": target_node,
		"source_unit_id": "warmup",
		"target_unit_id": "warmup_target",
		"targets": [target],
		"heal_target": origin,
		"status_duration": 1.0,
	}
	vfx.play(skill_id, origin, target, context)
	_active = holder

# Records which phase the item that just finished belonged to, and stamps the
# moment each phase completed so an early abort can be attributed.
func _note_phase_progress() -> void:
	if _active_id.is_empty():
		return
	var phase := str(_phase_by_id.get(_active_id, ""))
	_active_id = ""
	if phase.is_empty():
		return
	_phase_done[phase] = int(_phase_done.get(phase, 0)) + 1
	if int(_phase_done[phase]) >= int(_phase_total.get(phase, 0)) and not _phase_first_done_ms.has(phase):
		var ms := float(Time.get_ticks_usec() - _t_start_us) / 1000.0
		_phase_first_done_ms[phase] = ms
		print("[WARMUP] 阶段完成：%s %d 项，累计 %.0f ms" % [phase, int(_phase_total.get(phase, 0)), ms])
		StartupTrace.mark("warmup_phase_%s" % phase, {
			"items": int(_phase_total.get(phase, 0)),
			"since_warmup_start_ms": snappedf(ms, 0.1),
		})


func _update_label() -> void:
	if _label == null or not is_instance_valid(_label):
		return
	_label.text = "预热 %d/%d   最慢 %.0f ms (%s)" % [_done, _total, _slowest_ms, _slowest_id]

func _finish() -> void:
	_running = false
	set_process(false)
	var report := warmup_report()
	print("[WARMUP] 结束：完成 %d/%d 耗时 %.0f ms 最慢单项 %.0f ms (%s) 中止=%s"
		% [report["done"], report["total"], report["elapsed_ms"],
			report["slowest_ms"], report["slowest_id"], str(report["aborted"])])
	print("[WARMUP] 单项耗时分级：>16.7ms %d / >33ms %d / >50ms %d；因输入让路 %d 帧"
		% [int(_spike_counts["over_16_7ms"]), int(_spike_counts["over_33ms"]),
			int(_spike_counts["over_50ms"]), _yielded_frames])
	for entry in _slowest_items():
		print("[WARMUP]   慢项 %.1f ms  %s  (%s)"
			% [float(entry["ms"]), str(entry["id"]), str(entry["phase"])])
	StartupTrace.mark("warmup_finished", {
		"done": int(report["done"]),
		"total": int(report["total"]),
		"aborted": bool(report["aborted"]),
		"elapsed_ms": snappedf(float(report["elapsed_ms"]), 0.1),
		"slowest_ms": snappedf(float(report["slowest_ms"]), 0.1),
		"over_16_7ms": int(_spike_counts["over_16_7ms"]),
		"over_33ms": int(_spike_counts["over_33ms"]),
		"over_50ms": int(_spike_counts["over_50ms"]),
		"yielded_frames": _yielded_frames,
	})
	if _label != null and is_instance_valid(_label):
		_label.text = "预热完成 %d/%d  %.0f ms" % [_done, _total, report["elapsed_ms"]]
		var tw := create_tween()
		tw.tween_interval(2.5)
		tw.tween_property(_label, "modulate:a", 0.0, 0.6)
		tw.tween_callback(func():
			if is_instance_valid(_label):
				_label.get_parent().queue_free())
	if _viewport != null and is_instance_valid(_viewport):
		_viewport.queue_free()
	finished.emit(report)


# --- V3 P0-04：状态机与低内存 -------------------------------------------------

# 记录状态转移。同状态重复进入只累计帧数，不刷屏日志 ——
# 被 modal 挡住几百帧是正常的，每帧打一行会把 logcat 冲垮。
func _enter_state(next_state: int, reason: String) -> void:
	var key: String = State.keys()[next_state]
	_state_frames[key] = int(_state_frames.get(key, 0)) + 1
	if _state == next_state and _state_reason == reason:
		return
	_state = next_state
	_state_reason = reason
	if next_state == State.PAUSED:
		print("[WARMUP] 暂停：%s（完成 %d/%d）" % [reason, _done, _total])


# 队列头那一项是不是 deferred 阶段。低内存只停 deferred，
# 所以得看**下一项**属于哪一阶段，而不是看整体进度。
func _next_phase_is_deferred() -> bool:
	if _queue.is_empty():
		return false
	return str(_phase_by_id.get(str(_queue[0]), "")) == PHASE_DEFERRED


# Android 在内存吃紧时会先发这个通知，再决定要不要杀进程。
# 收到之后停掉 deferred 预热并放掉预览缓存，是"别让系统选择杀我们"的最便宜做法。
#
# 刻意**不**清当前战斗必需的资源：那会把一次内存告警变成一次可见的战斗卡顿，
# 而系统很可能根本不会来杀我们。
func _notification(what: int) -> void:
	if what != NOTIFICATION_OS_MEMORY_WARNING:
		return
	_low_memory = true
	print("[WARMUP] 收到系统低内存告警：暂停 deferred 预热并释放预览缓存")
	_release_preview_cache()


# 只释放预热自己造出来的东西。战斗现场的资源不归这里管。
func _release_preview_cache() -> void:
	if _active != null and is_instance_valid(_active):
		_active.queue_free()
		_active = null
		_active_id = ""
	var dropped := 0
	for index in range(_queue.size() - 1, -1, -1):
		if str(_phase_by_id.get(str(_queue[index]), "")) == PHASE_DEFERRED:
			_queue.remove_at(index)
			dropped += 1
	if dropped > 0:
		_total -= dropped
		print("[WARMUP] 低内存：丢弃 %d 项 deferred 预热（first_battle 不动）" % dropped)


# 供门禁与 IssueReport 读。状态名而不是数字：报告要给人看。
func state_name() -> String:
	var names: Array = State.keys()
	return str(names[_state])


func state_reason() -> String:
	return _state_reason


func low_memory() -> bool:
	return _low_memory
