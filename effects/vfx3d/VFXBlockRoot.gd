extends Node3D
class_name VFXBlockRoot

# 命名避开 QUALITY：部分子类（VFXDebrisBurst3D 等）已经自己声明了同名常量，
# 父类再占用这个名字会撞 "member already exists in parent class"。
const QUALITY_BUDGET := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")

# ── World scale calibration ───────────────────────────────────────────
# Every VFX in this project was authored against an assumed ~1.7 world-unit tall
# unit (the old hardcoded anchors said Head=1.55 / Body=0.85).  Units actually
# render ~0.98 units tall - measured off rendered silhouettes, not mesh AABBs,
# which lie badly for these skinned rigs - so effects came out ~1.7x oversized.
#
# SIZE scales the artwork itself; OFFSET scales the local nudges composers add on
# top of a unit anchor (+0.34 up the chest, +0.30 toward camera, ...).  Offsets
# need the harder squeeze because the anchor they start from is now already at
# chest height instead of at the feet.
# Toward the battle camera, which sits at (0, 7.4, 7) looking at the origin.
# This is the view axis, so moving a layer along it changes only its depth - it
# does NOT slide on screen. Pushing along +Z instead (what this used to do)
# drags effects visibly downward under a 45-degree camera.
const CAMERA_DIR := Vector3(0.0, 0.727, 0.687)

static func vfx_toward_camera(distance: float) -> Vector3:
	return CAMERA_DIR * distance

const VFX_SIZE_SCALE := 0.60
const VFX_OFFSET_SCALE := 0.60

static func vfx_size(value: float) -> float:
	return value * VFX_SIZE_SCALE

static func vfx_size2(value: Vector2) -> Vector2:
	return value * VFX_SIZE_SCALE

static func vfx_offset(value: Vector3) -> Vector3:
	return value * VFX_OFFSET_SCALE

var _tweens: Array[Tween] = []
var _finished := false
var vfx_alpha := 1.0
var vfx_brightness := 1.0

# ── 同屏名额 ───────────────────────────────────────────────────────────
# 3D 这条路以前完全没有上限（VFXManager 的池和 EFFECT_CAPS 只管 2D 老路径），
# 一个 AoE 回合能一次生成几十组节点，所以生成前要过闸门：超限直接不生成，保帧率。
#
# 11.12：名额按「这是什么特效」分开算，不再全场共用一个数。
#
# 原来只有 _active_blocks 一个计数，凡是继承本类的节点都算进去 —— 挂在棋子身上的常驻
# 状态、特效内部的子块、强制生成的招牌演出 —— 普攻的弹道还和技能抢同一份。实测三路 Boss
# 战（每路 7 个棋子）里，中画质 56%~63% 的棋子特效层、41%~76% 的 Boss 技能层被拦掉，
# 玩家看到的就是「技能有时候被吃掉」。现在：
#
#   LIGHT  高频小特效：普攻弹道 / 刀光、每挨一下的小闪光。画面满了先省它们。
#          调用方用 begin_budget_class(LIGHT) / end_budget_class() 把生成包起来。
#   SKILL  技能（默认）：有自己的名额，普攻再多也挤不掉。
#   force  招牌演出（Boss 技能、母灵的书、死亡）和常驻状态：不占名额、不受限。
#
# 只有「过了闸门的块」才占名额。直接 new 出来的常驻块、特效内部的子块只进 _active_blocks
# （诊断用的总数），不再吃掉技能的位置。上限数字没有变（VFXQualityBudget），变的是谁占谁的。
enum BudgetClass { NONE, LIGHT, SKILL }

static var _active_blocks := 0
static var _cap_denials := 0
static var _gated_light := 0
static var _gated_skill := 0
static var _class_stack: Array[int] = []
# 一次 play 里同步生成的各层共用一个放行结果，见 begin_effect()。
static var _effect_depth := 0
static var _effect_decided := false
static var _effect_admitted := false

# 这个块占的是哪一类名额；NONE = 没过闸门（强制 / 常驻 / 子块），不占。
var _budget_class: int = BudgetClass.NONE

static func active_block_count() -> int:
	return _active_blocks

static func cap_denial_count() -> int:
	return _cap_denials

# 某一类现在占着几个名额（门禁和排查用）。
static func gated_block_count(budget_class: int) -> int:
	return _gated_light if budget_class == BudgetClass.LIGHT else _gated_skill

static func begin_budget_class(budget_class: int) -> void:
	_class_stack.append(budget_class)

static func end_budget_class() -> void:
	_class_stack.pop_back()

static func current_budget_class() -> int:
	return BudgetClass.SKILL if _class_stack.is_empty() else _class_stack[-1]

# 一招通常由好几层组成。名额在第一层那里决定一次，同一次调用里后面的层跟着它：
# 要么整招画，要么整招不画，不再出现「有预警圈没有爆炸」这种半截特效。
static func begin_effect() -> void:
	if _effect_depth == 0:
		_effect_decided = false
	_effect_depth += 1

static func end_effect() -> void:
	_effect_depth = maxi(0, _effect_depth - 1)

# 当前这一类还有没有名额（不看 begin_effect 的整招结果）。
static func can_spawn_block() -> bool:
	return _has_room(current_budget_class())

static func _has_room(budget_class: int) -> bool:
	if budget_class == BudgetClass.LIGHT:
		return _gated_light < QUALITY_BUDGET.max_simultaneous_effects_for(QUALITY_BUDGET.PRIORITY_AMBIENT)
	return _gated_skill < QUALITY_BUDGET.max_simultaneous_effects_for(QUALITY_BUDGET.PRIORITY_IMPORTANT)

static func _admit(budget_class: int) -> bool:
	if _effect_depth > 0 and _effect_decided:
		return _effect_admitted
	var admitted := _has_room(budget_class)
	if _effect_depth > 0:
		_effect_decided = true
		_effect_admitted = admitted
	return admitted

# 统一的生成入口：没名额返回 null。调用方要么直接判空，
# 要么依赖已有的 is_instance_valid() 守卫（对 null 返回 false）。
#
# force=true 不过闸门：留给玩家必须读到的招牌演出和常驻状态。名额是用来省廉价高频特效的，
# 不是省招牌演出的。
static func spawn_block(script: Script, parent: Node, force := false) -> Node3D:
	if parent == null or not is_instance_valid(parent):
		return null
	var budget_class: int = BudgetClass.NONE
	if not force:
		budget_class = current_budget_class()
		if not _admit(budget_class):
			_cap_denials += 1
			return null
	var block := script.new() as Node3D
	if block == null:
		return null
	var gated := block as VFXBlockRoot
	if gated != null:
		gated._budget_class = budget_class
	parent.add_child(block)
	return block

# 贴图统一走 VFXManager 的缓存：裸 load() 在特效释放、引用归零后就被卸载，
# 下次同一个技能又要重新读盘，战斗中是可感的顿挫。
#
# 这里用字符串查节点而不是直接写 VFXManager，是因为 autoload 作为标识符要在
# 解析期就能解析到。用 --script 跑工具脚本（截帧 harness）时 autoload 还没注册，
# 直接引用会让整个模块编译失败，`script.new()` 退化成一个裸 Node3D，
# 症状是运行时报 "Nonexistent function 'play_layer'"。
func vfx_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if is_inside_tree():
		var manager := get_tree().root.get_node_or_null("VFXManager")
		if manager != null and manager.has_method("get_texture"):
			return manager.call("get_texture", path) as Texture2D
	return load(path) as Texture2D

func _enter_tree() -> void:
	_active_blocks += 1
	if _budget_class == BudgetClass.LIGHT:
		_gated_light += 1
	elif _budget_class == BudgetClass.SKILL:
		_gated_skill += 1

func _exit_tree() -> void:
	_active_blocks = maxi(0, _active_blocks - 1)
	if _budget_class == BudgetClass.LIGHT:
		_gated_light = maxi(0, _gated_light - 1)
	elif _budget_class == BudgetClass.SKILL:
		_gated_skill = maxi(0, _gated_skill - 1)

# Timer awaits can outlive a VFX node when a scene changes or a pooled block is
# released. Capture the SceneTree before creating the timer so a detached node
# never calls get_tree().create_timer() through a stale coroutine.
func wait_for(seconds: float, process_always := true, ignore_time_scale := false) -> bool:
	if not is_inside_tree() or is_queued_for_deletion():
		return false
	var tree := get_tree()
	if tree == null:
		return false
	var timer := tree.create_timer(maxf(seconds, 0.0), process_always, false, ignore_time_scale)
	await timer.timeout
	return is_inside_tree() and not is_queued_for_deletion()

func begin() -> void:
	_finished = false
	visible = true

# queue_free() 一个根节点会在那一帧末释放整棵子树，所以要知道子树到底多大。
static func _count_descendants(node: Node) -> int:
	var n := 0
	for child in node.get_children():
		n += 1 + _count_descendants(child)
	return n

func track_tween(tween: Tween) -> Tween:
	if tween != null:
		_tweens.append(tween)
	return tween

func set_vfx_alpha(value: float) -> void:
	vfx_alpha = clampf(value, 0.0, 1.0)
	visible = vfx_alpha > 0.001

func set_vfx_brightness(value: float) -> void:
	vfx_brightness = maxf(value, 0.0)

func stop_vfx(immediate := false) -> void:
	if immediate:
		finish()
	else:
		var tween := track_tween(create_tween())
		tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_method(set_vfx_alpha, vfx_alpha, 0.0, 0.12)
		tween.tween_callback(finish)

func finish(delay := 0.0) -> void:
	if _finished:
		return
	_finished = true
	# 埋点：实测有单帧 6043 ms 的冻结，期间节点数在**下降**、贴图完全不动 ——
	# 特征指向销毁而不是创建。但那一帧里也可能有别的事，所以这里直接量
	# 「kill 掉几个 Tween、释放多少子节点、花了多久」，把推测变成读数。
	# 只在明显偏慢时打印，正常帧不刷屏。调试完连同 PerfLog 一起删。
	var t0 := Time.get_ticks_usec()
	var tween_count := _tweens.size()
	for tween in _tweens:
		if tween != null and tween.is_valid():
			tween.kill()
	_tweens.clear()
	var kill_us := Time.get_ticks_usec() - t0
	var child_total := _count_descendants(self)
	if kill_us > 20000 or child_total > 120:
		print("[VFXFREE] %s  killTween=%.0fms(%d个)  子节点=%d" % [
			get_script().resource_path.get_file(), kill_us / 1000.0, tween_count, child_total])
	if delay <= 0.0:
		queue_free()
	else:
		if not await wait_for(delay):
			return
		if is_instance_valid(self):
			queue_free()
