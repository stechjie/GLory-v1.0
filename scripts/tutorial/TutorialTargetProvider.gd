extends RefCounted

# Stable contract between TutorialMode and the current preparation-screen UI.
# TutorialMode asks for semantic targets; the Prep adapter owns private fields.

const TARGET_BUY_UNIT := "buy_unit"
const GloryToastScript := preload("res://ui/components/GloryToast.gd")
const TARGET_PLACE_UNIT := "place_unit"
const TARGET_UPGRADE_UNIT := "upgrade_unit"
const TARGET_START_BATTLE := "start_battle"
const TARGET_FORMATION_HP := "formation_hp"
const TARGET_TREASURE_CHOICE := "treasure_choice"
const TARGET_HIRE_MERCENARY := "hire_mercenary"
const TARGET_FILL_SEVEN := "fill_seven"
const TARGET_BOND_ROW := "bond_row"
const TARGET_TREASURE_LOGO := "treasure_logo"

const ACTION_CLOSE_MERCENARY := "close_mercenary"
const ACTION_REFRESH_VIEW := "refresh_view"

const REQUIRED_TARGETS := [
	TARGET_BUY_UNIT,
	TARGET_PLACE_UNIT,
	TARGET_UPGRADE_UNIT,
	TARGET_START_BATTLE,
	TARGET_FORMATION_HP,
	TARGET_TREASURE_CHOICE,
	TARGET_HIRE_MERCENARY,
	TARGET_FILL_SEVEN,
	TARGET_BOND_ROW,
	TARGET_TREASURE_LOGO,
]

var _provider_name := "unbound"
var _overlay_host: Control
var _target_resolvers: Dictionary = {}
var _actions: Dictionary = {}
var _feedback: Callable
var _keep_clear: Callable
var _last_request: Dictionary = {}
var _last_missing: Dictionary = {}
var _reported_missing: Dictionary = {}


func _init(provider_name: String = "unbound", overlay_host: Control = null) -> void:
	_provider_name = provider_name
	_overlay_host = overlay_host


static func required_target_ids() -> Array:
	return REQUIRED_TARGETS.duplicate()


func provider_name() -> String:
	return _provider_name


func overlay_host() -> Control:
	if _overlay_host == null or not is_instance_valid(_overlay_host):
		return null
	return _overlay_host


func bind_target(target_id: String, resolver: Callable) -> void:
	if target_id.is_empty() or not resolver.is_valid():
		return
	_target_resolvers[target_id] = resolver


func bind_action(action_id: String, action: Callable) -> void:
	if action_id.is_empty() or not action.is_valid():
		return
	_actions[action_id] = action


func bind_feedback(feedback: Callable) -> void:
	_feedback = feedback


# 教程气泡不得压住的区域：主按钮、待命区、宝藏刷新等（V2 P1-09）。
#
# 这是一条**可选**合同：没绑就返回空数组，REQUIRED_TARGETS 一条没动，
# 所以既有的 tutorial_target 门禁不受影响。之所以走 provider 而不是让
# TutorialMode 直接伸手到 PrepScreen 的私有字段拿控件，是因为 P1-10 刚把
# 那种耦合拆掉，不能从这里再接回去。
func bind_keep_clear(resolver: Callable) -> void:
	if not resolver.is_valid():
		return
	_keep_clear = resolver


func keep_clear_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	if not _keep_clear.is_valid():
		return out
	var raw = _keep_clear.call()
	if not (raw is Array):
		return out
	for value in (raw as Array):
		if value is Rect2 and (value as Rect2).size.x > 0.0 and (value as Rect2).size.y > 0.0:
			out.append(value as Rect2)
	return out


func has_target(target_id: String) -> bool:
	if not _target_resolvers.has(target_id):
		return false
	var resolver: Callable = _target_resolvers[target_id]
	return resolver.is_valid()


func bound_target_ids() -> Array[String]:
	var ids: Array[String] = []
	for target_id in _target_resolvers.keys():
		ids.append(str(target_id))
	ids.sort()
	return ids


func resolve_target(target_id: String, step_key: String, feedback_text: String = "") -> Control:
	_last_request = {
		"step": step_key,
		"target": target_id,
		"provider": _provider_name,
	}
	if not _target_resolvers.has(target_id):
		return _record_missing(step_key, target_id, "unbound_target", feedback_text)
	var resolver: Callable = _target_resolvers[target_id]
	if not resolver.is_valid():
		return _record_missing(step_key, target_id, "invalid_resolver", feedback_text)
	var resolved: Variant = resolver.call()
	if not (resolved is Control) or not is_instance_valid(resolved):
		return _record_missing(step_key, target_id, "resolver_returned_no_control", feedback_text)
	return resolved as Control


func request_action(action_id: String) -> bool:
	if not _actions.has(action_id):
		push_warning("Tutorial provider action missing action=%s provider=%s" % [
			action_id, _provider_name])
		return false
	var action: Callable = _actions[action_id]
	if not action.is_valid():
		push_warning("Tutorial provider action invalid action=%s provider=%s" % [
			action_id, _provider_name])
		return false
	action.call()
	return true


func show_feedback(text: String) -> bool:
	# V3 P1-04：_feedback 没绑定时**回落到全局 toast**，而不是静默失效。
	#
	# 唯一的生产绑定是 PrepUI.gd 的 bind_feedback(show_message)，所以此前
	# 在备战页之外这个函数一律 return false，什么都不显示 ——
	# TutorialMode.gd 里 begin_battle() 被拒绝时走的 follow_arrow_hint()
	# 就是一条会在别处触发的路径，玩家那时看到的是「点了没反应」。
	if text.is_empty():
		return false
	if _feedback.is_valid():
		_feedback.call(text)
		return true
	return GloryToastScript.show_text(text)


func release() -> void:
	_overlay_host = null
	_target_resolvers.clear()
	_actions.clear()
	_feedback = Callable()


func last_request_snapshot() -> Dictionary:
	return _last_request.duplicate(true)


func last_missing_snapshot() -> Dictionary:
	return _last_missing.duplicate(true)


func _record_missing(
	step_key: String,
	target_id: String,
	reason: String,
	feedback_text: String
) -> Control:
	_last_missing = {
		"step": step_key,
		"target": target_id,
		"provider": _provider_name,
		"reason": reason,
	}
	var report_key := "%s|%s|%s" % [step_key, target_id, reason]
	if not _reported_missing.has(report_key):
		_reported_missing[report_key] = true
		push_warning(
			"Tutorial target missing step=%s target=%s provider=%s reason=%s" % [
				step_key, target_id, _provider_name, reason])
		show_feedback(feedback_text)
	return null
