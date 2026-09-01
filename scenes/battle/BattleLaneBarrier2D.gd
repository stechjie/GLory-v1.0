extends Node2D
class_name BattleLaneBarrier2D

signal release_finished

const LOOP_TEXTURE := preload("res://assets/vfx/battlefield/lane_barrier_lowpoly_loop.png")
const RELEASE_TEXTURE := preload("res://assets/vfx/battlefield/lane_barrier_lowpoly_release.png")
const CELL_SIZE := Vector2(128.0, 512.0)
const COLUMNS := 4
const LOOP_FRAME_COUNT := 16
const RELEASE_FRAME_COUNT := 8
const RELEASE_FPS := 18.0

# --- V2 P1-02：晶柱只作为边界提示，不当画面主体 --------------------------------
#
# 问题（2026-08-29 固定 seed round 1 中段截图实测）：这两根晶柱此前**从不设置
# modulate**，也就是全亮度全不透明，于是成了画面里最亮、对比最强的物体，比角色还抢眼。
#
# 做法：常态压淡，只在**开场**和**车道清空**这两个真正需要被看见的时刻亮起来。
# 玩家需要知道边界在哪，但只需要知道一次。
#
# **V2 原文那条"高度缩到 45%-60%"是错的，已被用户实看否决。**
# 第一版照做后用户的原话：「你把那个晶体缩短了，看不出那种隔开的感觉，不能弄短」。
# 高度是"隔开"这件事的载体 —— 一根矮柱子不再是分隔线，只是个装饰。V2 把"太抢眼"
# 误诊成了"太高"，真正的病因是没有 modulate。高度已恢复铺满，
# BattleArena 那侧有 tools/battle_lane_barrier_check 的反向断言盯着，防止再缩一次。
#
# 常态 alpha 因此从最初的 0.22 提到 0.45：0.22 是在"同时缩短高度"的前提下定的，
# 恢复全高之后那个值太淡，用户实看后定为 0.45。这也就超出了 V2 写的 0.15-0.30 区间 ——
# 那个区间随被否决的前提一起失效了。
#
# 刻意没做 V2 原文的"横向移到角色活动区外"：实测晶柱本来就落在三条车道的间隙里
# （单位 x≈194-266 / 464-536 / 734-806），横向并不压角色。
const STEADY_ALPHA := 0.45
const EMPHASIS_ALPHA := 0.85
const EMPHASIS_HOLD_SEC := 0.4
const EMPHASIS_FADE_SEC := 0.45
# 低画质档：更淡、更窄。保持"低画质更克制"的相对关系，跟着常态一起上调。
const LOW_QUALITY_ALPHA := 0.30
const LOW_QUALITY_WIDTH_SCALE := 0.55

var _sprite: Sprite2D
var _atlas: AtlasTexture
var _frame := 0
var _elapsed := 0.0
var _frame_count := LOOP_FRAME_COUNT
var _fps := RELEASE_FPS
var _released := false
var _low_quality := false
var _fade_tween: Tween


func _ready() -> void:
	_sprite = Sprite2D.new()
	_sprite.name = "BarrierSprite"
	_sprite.centered = true
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(_sprite)
	_atlas = AtlasTexture.new()
	_sprite.texture = _atlas
	play_loop()


func play_loop(_start_frame := 0) -> void:
	_released = false
	_frame_count = LOOP_FRAME_COUNT
	_frame = 0
	_elapsed = 0.0
	visible = true
	if _atlas != null:
		_atlas.atlas = LOOP_TEXTURE
		_apply_frame()
	# 开场亮一下再淡下去：玩家需要知道边界在哪，但只需要知道一次。
	_begin_emphasis_then_settle()
	# The low-poly obstacle is a rigid object. Keep it completely still until
	# the lane-clear event starts the one-shot release animation.
	set_process(false)


func play_release() -> void:
	if _released:
		return
	_released = true
	_frame_count = RELEASE_FRAME_COUNT
	_fps = RELEASE_FPS
	_frame = 0
	_elapsed = 0.0
	if _atlas != null:
		_atlas.atlas = RELEASE_TEXTURE
		_apply_frame()
	# 车道清空是一次性事件，本来就该被看见 —— 消失动画期间恢复到强调亮度。
	_kill_fade_tween()
	modulate.a = _emphasis_alpha()
	set_process(true)


# 低画质档退化成细线提示。命名与调用方式沿用 BattleArena 里既有的
# _board_readability_layer.set_low_quality()，不另发明一套。
func set_low_quality(enabled: bool) -> void:
	_low_quality = enabled
	if _sprite != null:
		_sprite.scale.x = LOW_QUALITY_WIDTH_SCALE if enabled else 1.0
	if not _released:
		_kill_fade_tween()
		modulate.a = _steady_alpha()


func steady_alpha() -> float:
	return _steady_alpha()


func _steady_alpha() -> float:
	return LOW_QUALITY_ALPHA if _low_quality else STEADY_ALPHA


func _emphasis_alpha() -> float:
	return EMPHASIS_ALPHA


func _kill_fade_tween() -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = null


func _begin_emphasis_then_settle() -> void:
	_kill_fade_tween()
	modulate.a = _emphasis_alpha()
	if not is_inside_tree():
		# 还没入树就没法起 tween。直接落到常态，别把强调亮度留在画面上。
		modulate.a = _steady_alpha()
		return
	_fade_tween = create_tween()
	_fade_tween.tween_interval(EMPHASIS_HOLD_SEC)
	_fade_tween.tween_property(self, "modulate:a", _steady_alpha(), EMPHASIS_FADE_SEC)


func is_released() -> bool:
	return _released


func _process(delta: float) -> void:
	_elapsed += delta
	var wanted := int(floor(_elapsed * _fps))
	if wanted >= _frame_count:
		visible = false
		set_process(false)
		release_finished.emit()
		return
	if wanted == _frame:
		return
	_frame = wanted
	_apply_frame()


func _apply_frame() -> void:
	if _atlas == null:
		return
	var column := _frame % COLUMNS
	var row := int(_frame / COLUMNS)
	_atlas.region = Rect2(Vector2(column, row) * CELL_SIZE, CELL_SIZE)
