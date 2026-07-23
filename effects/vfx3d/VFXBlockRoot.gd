extends Node3D
class_name VFXBlockRoot

# 命名避开 QUALITY：部分子类（VFXDebrisBurst3D 等）已经自己声明了同名常量，
# 父类再占用这个名字会撞 "member already exists in parent class"。
const QUALITY_BUDGET := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")

var _tweens: Array[Tween] = []
var _finished := false
var vfx_alpha := 1.0
var vfx_brightness := 1.0

# 同屏 VFX 块的并发计数。3D 这条路以前完全没有上限（VFXManager 的池和
# EFFECT_CAPS 只管 2D 老路径），一个 AoE 回合能一次生成几十组节点。
static var _active_blocks := 0

static func active_block_count() -> int:
	return _active_blocks

# 生成前的闸门。超限直接不生成——密集回合里少一两个命中闪光玩家看不出来，
# 但帧率保得住。这和 VFXManager 对 2D 特效的做法是同一个策略。
static func can_spawn_block() -> bool:
	return _active_blocks < QUALITY_BUDGET.max_simultaneous_effects()

# 统一的生成入口：超限返回 null。调用方要么直接判空，
# 要么依赖已有的 is_instance_valid() 守卫（对 null 返回 false）。
static func spawn_block(script: Script, parent: Node) -> Node3D:
	if not can_spawn_block() or parent == null or not is_instance_valid(parent):
		return null
	var block := script.new() as Node3D
	if block == null:
		return null
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

func _exit_tree() -> void:
	_active_blocks = maxi(0, _active_blocks - 1)

func begin() -> void:
	_finished = false
	visible = true

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
	for tween in _tweens:
		if tween != null and tween.is_valid():
			tween.kill()
	_tweens.clear()
	if delay <= 0.0:
		queue_free()
	else:
		await get_tree().create_timer(delay).timeout
		if is_instance_valid(self):
			queue_free()
