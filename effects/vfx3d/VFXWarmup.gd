extends Node
class_name VFXWarmup

# 启动时的 shader 预热（最小验证版）。
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
# ⚠️ 未验证的前提：Vulkan 管线按 framebuffer 格式索引。这里的离屏视口必须和
#    BattleArena._battle_3d_viewport 逐项对齐（尤其 transparent_bg），否则预热
#    出来的管线在战斗里用不上，等于白做。这个最小版本就是用来验证这一点的 ——
#    判读方式见 warmup_report()。

const UNIT_SKILL_COMPOSER := preload("res://effects/vfx3d/units/UnitSkillVFXComposer3D.gd")

# 最小验证版只热 8 个普攻组合。选它们的理由：
#   - 一定会在第 1 回合出现（每个单位每次攻击都放）
#   - 走的是和战斗完全相同的入口 UnitSkillVFXComposer3D.play_skill()，
#     直接 new 模块会绕过 composer 的分支，热到的可能不是同一个材质
const WARM_SKILLS := [
	"basic_attack_melee_god", "basic_attack_ranged_god",
	"basic_attack_melee_human", "basic_attack_ranged_human",
	"basic_attack_melee_dark", "basic_attack_ranged_dark",
	"basic_attack_melee_undead", "basic_attack_ranged_undead",
]

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
	_queue = []
	for s in WARM_SKILLS:
		_queue.append(str(s))
	_total = _queue.size()
	_done = 0
	_t_start_us = Time.get_ticks_usec()
	_build_viewport()
	_build_label()
	set_process(true)
	print("[WARMUP] 启动预热：%d 项" % _total)

func abort(reason: String) -> void:
	if not _running:
		return
	_aborted = true
	print("[WARMUP] 中止（%s）：完成 %d/%d" % [reason, _done, _total])
	_finish()

# 判读用。最小验证版看的不是这里的耗时，而是设备上
#   files/shader_cache/SceneForwardMobileShaderRD/ 的文件数：
#   走到主菜单时应从基线 7 涨到 12 左右 = 格式对上了；还是 7 = 白做。
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

func _spawn_one(skill_id: String) -> void:
	var composer := UNIT_SKILL_COMPOSER.new()
	composer.name = "Warm_%s" % skill_id
	_world_root.add_child(composer)
	var origin := Vector3(-0.6, 0.3, 0.0)
	var target := Vector3(0.6, 0.3, 0.0)
	# 有些分支会读 target_node / origin_node 去挂锚点，给它们真实节点免得报空。
	var origin_node := Node3D.new()
	origin_node.position = origin
	_world_root.add_child(origin_node)
	var target_node := Node3D.new()
	target_node.position = target
	_world_root.add_child(target_node)
	composer.set_meta("warm_anchors", [origin_node, target_node])
	var context := {
		"origin_node": origin_node,
		"target_node": target_node,
		"source_unit_id": "warmup",
		"target_unit_id": "warmup_target",
		"targets": [target],
		"heal_target": origin,
	}
	composer.play_skill(skill_id, origin, target, context)
	_active = composer
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
