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
const SKILL_TABLES := {
	"race_units": "units",
	"mercenaries": "mercenaries",
	"bosses": "bosses",
	"formation_allies": "allies",
	"pve_monsters": "monsters",
}

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

signal finished(report: Dictionary)

var _viewport: SubViewport
var _world_root: Node3D
var _queue: Array[String] = []
var _done := 0
var _total := 0
var _aborted := false
var _running := false
var _t_start_us := 0
var _slowest_ms := 0.0
var _slowest_id := ""
var _label: Label

func start() -> void:
	if _running:
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
	print("[WARMUP] 清单：%s" % ", ".join(_queue))

# 普攻 + 数据表里出现过的全部 skill_id。去重后按原顺序排，普攻在前 ——
# 它们每回合每个单位都放，最该先热到。
func _collect_ids() -> Array[String]:
	var out: Array[String] = []
	for s in BASIC_ATTACKS:
		out.append(str(s))
	var seen := {}
	for s in out:
		seen[s] = true
	for table_name in SKILL_TABLES:
		var table: Variant = DataRegistry.get_table(str(table_name))
		if typeof(table) != TYPE_DICTIONARY:
			continue
		var rows: Variant = (table as Dictionary).get(str(SKILL_TABLES[table_name]), [])
		if typeof(rows) != TYPE_ARRAY:
			continue
		for row in rows:
			if typeof(row) != TYPE_DICTIONARY:
				continue
			var sid := str((row as Dictionary).get("skill_id", ""))
			if sid.is_empty() or sid == "none" or seen.has(sid) or NO_VFX_SKILLS.has(sid):
				continue
			seen[sid] = true
			out.append(sid)
	for e in EXTRA_EFFECTS:
		var eid := str(e)
		if not seen.has(eid):
			seen[eid] = true
			out.append(eid)
	# 外部 VFX 场景（binbun / starter）。以 res:// 开头，_spawn_one 据此分支。
	#
	# 为什么单列一段：大厅预载只把它们读进内存（Resource Ready），场景里的
	# GPUParticles3D 要真的被光栅化一次才编译 shader。实测第 1 回合
	# cold=3、编译 4 个 ParticlesShaderRD，就是这批漏掉的。
	# 按 skill_id 播只有少数技能会走到外部分支，热不全，所以直接实例化整个场景。
	for p in BattleAssetManifest.seed_independent_paths():
		var path := str(p)
		if not seen.has(path):
			seen[path] = true
			out.append(path)
	return out

func abort(reason: String) -> void:
	if not _running:
		return
	_aborted = true
	print("[WARMUP] 中止（%s）：完成 %d/%d" % [reason, _done, _total])
	_finish()

# 判读用。真正要看的不是这里的耗时，而是设备上
#   files/shader_cache/SceneForwardMobileShaderRD/ 的文件数按写入时间戳归因：
#   落在预热窗口内的就是预热的产出，之后第 1 回合的新增量应随之下降。
func warmup_report() -> Dictionary:
	return {
		"total": _total, "done": _done, "aborted": _aborted,
		"elapsed_ms": float(Time.get_ticks_usec() - _t_start_us) / 1000.0,
		"slowest_ms": _slowest_ms, "slowest_id": _slowest_id,
	}

func _build_viewport() -> void:
	# 逐项对齐 BattleArena._battle_3d_viewport。尺寸不进管线 key（视口是动态状态），
	# 所以这里开 64x64 就够；transparent_bg / msaa / 更新模式必须一致。
	_viewport = SubViewport.new()
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

func _build_label() -> void:
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
var _active_started_us := 0

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
		var ms := float(Time.get_ticks_usec() - _active_started_us) / 1000.0
		if ms > _slowest_ms:
			_slowest_ms = ms
			_slowest_id = _active.name
		if is_instance_valid(_active):
			_active.queue_free()
		_active = null
		_done += 1
		_update_label()
		return

	if _queue.is_empty():
		_finish()
		return

	var frame_start := Time.get_ticks_usec()
	var skill_id: String = _queue.pop_front()
	_spawn_one(skill_id)
	_wait_frames = FRAMES_PER_ITEM
	# 单帧预算只用于「本帧还要不要再喂一个」，这里一帧本来就只喂一个，
	# 留着是为了以后扩到 34 个模块时能一帧喂多个而不超预算。
	if float(Time.get_ticks_usec() - frame_start) / 1000.0 > FRAME_BUDGET_MS:
		return

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
	_active_started_us = Time.get_ticks_usec()

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
	_active_started_us = Time.get_ticks_usec()

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
