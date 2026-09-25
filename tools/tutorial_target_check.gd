extends Node

# V2 P1-10 gate: TutorialMode consumes a semantic provider contract and never
# reaches into PrepScreen's private fields. A fake provider proves the mapping;
# the live Prep adapter proves every required target is bound.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const TutorialScript := preload("res://scripts/tutorial/TutorialMode.gd")
const ProviderScript := preload("res://scripts/tutorial/TutorialTargetProvider.gd")
const PrepScript := preload("res://scenes/prep/PrepScreen.gd")

const CHECK_NAME := "tutorial_target"
const TUTORIAL_SOURCE := "res://scripts/tutorial/TutorialMode.gd"
const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"

const STEP_TARGETS := {
	TutorialScript.Step.BUY_3: ProviderScript.TARGET_BUY_UNIT,
	TutorialScript.Step.PLACE_3: ProviderScript.TARGET_PLACE_UNIT,
	TutorialScript.Step.START_PVE_1: ProviderScript.TARGET_START_BATTLE,
	TutorialScript.Step.UPGRADE_2: ProviderScript.TARGET_UPGRADE_UNIT,
	TutorialScript.Step.START_PVE_2: ProviderScript.TARGET_START_BATTLE,
	TutorialScript.Step.TAKE_TREASURE_1: ProviderScript.TARGET_TREASURE_CHOICE,
	TutorialScript.Step.UPGRADE_3: ProviderScript.TARGET_UPGRADE_UNIT,
	TutorialScript.Step.UPGRADE_OTHERS: ProviderScript.TARGET_UPGRADE_UNIT,
	TutorialScript.Step.BOND_HINT: ProviderScript.TARGET_BOND_ROW,
	TutorialScript.Step.VIEW_TREASURE: ProviderScript.TARGET_TREASURE_LOGO,
	# 9.25 萝卜 / 四星教学：营地关着时（默认状态）这几步都先指营地入口，
	# 收获萝卜那一步指萝卜数量。营地打开后的逐级目标见 _check_carrot_sub_targets()。
	TutorialScript.Step.CARROT_CAMP: ProviderScript.TARGET_CARROT_CAMP,
	TutorialScript.Step.HARVEST_UPGRADE: ProviderScript.TARGET_CARROT_CAMP,
	TutorialScript.Step.START_BOSS: ProviderScript.TARGET_START_BATTLE,
	TutorialScript.Step.TAKE_TREASURE_2: ProviderScript.TARGET_TREASURE_CHOICE,
	TutorialScript.Step.CARROT_HARVEST: ProviderScript.TARGET_CARROT_COUNTER,
	TutorialScript.Step.DRAW_STONE: ProviderScript.TARGET_CARROT_CAMP,
	TutorialScript.Step.FOUR_STAR: ProviderScript.TARGET_CARROT_CAMP,
	TutorialScript.Step.HIRE_MERC: ProviderScript.TARGET_HIRE_MERCENARY,
	TutorialScript.Step.FILL_7: ProviderScript.TARGET_FILL_SEVEN,
	TutorialScript.Step.FORMATION_HP: ProviderScript.TARGET_FORMATION_HP,
	TutorialScript.Step.START_PVP: ProviderScript.TARGET_START_BATTLE,
}

var _h: CheckHarness
var _feedback_seen := ""
var _close_action_seen := false
var _refresh_action_seen := false


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_source_has_no_prep_reflection()
	await _check_fake_provider_contract()
	await _check_live_prep_adapter()
	_h.finish(get_tree())


func _check_source_has_no_prep_reflection() -> void:
	var raw := FileAccess.get_file_as_string(TUTORIAL_SOURCE)
	if not _h.expect(not raw.is_empty(), "source_unreadable",
			"读不到 %s" % TUTORIAL_SOURCE):
		return
	var source := _strip_comments(raw)
	_h.expect(not source.contains("var _prep"), "prep_reference_restored",
		"TutorialMode 又开始持有 PrepScreen 实例")
	var reflected := RegEx.create_from_string(
		"_prep\\s*\\.\\s*(get|call|call_deferred|has_method)\\s*\\(")
	_h.expect(reflected.search(source) == null, "prep_reflection_restored",
		"TutorialMode 又用 _prep.get/call/has_method 读取私有实现")
	_h.expect(source.contains("TutorialTargetProvider"), "provider_contract_removed",
		"TutorialMode 不再依赖 TutorialTargetProvider 合同")


func _check_fake_provider_contract() -> void:
	GameState.reset_run()
	var host := Control.new()
	host.name = "FakeTutorialHost"
	host.size = Vector2(1280, 720)
	add_child(host)

	var fake: ProviderScript = ProviderScript.new("FakeProvider", host)
	for target_id in ProviderScript.required_target_ids():
		var target := Button.new()
		target.name = str(target_id)
		target.position = Vector2(320, 240)
		target.size = Vector2(160, 72)
		host.add_child(target)
		fake.bind_target(str(target_id), _return_control.bind(target))
	fake.bind_feedback(_capture_feedback)
	fake.bind_action(ProviderScript.ACTION_CLOSE_MERCENARY, _capture_close_action)
	fake.bind_action(ProviderScript.ACTION_REFRESH_VIEW, _capture_refresh_action)

	var tutorial: TutorialScript = TutorialScript.new()
	add_child(tutorial)
	tutorial.start()
	tutorial.attach(fake)
	await get_tree().process_frame

	_h.expect(STEP_TARGETS.size() == TutorialScript.Step.DONE,
		"step_target_map_incomplete",
		"DONE 前有 %d 个步骤，但 fake provider 映射只有 %d 项" % [
			TutorialScript.Step.DONE, STEP_TARGETS.size()])
	for step_value in STEP_TARGETS.keys():
		tutorial.step = int(step_value)
		tutorial.update_overlay()
		var request := fake.last_request_snapshot()
		_h.item()
		_h.expect(str(request.get("target", "")) == str(STEP_TARGETS[step_value]),
			"wrong_step_target",
			"步骤 %s 请求了 %s，期望 %s" % [
				str(TutorialScript.Step.keys()[int(step_value)]),
				str(request.get("target", "")), str(STEP_TARGETS[step_value])])
		_h.expect(str(request.get("provider", "")) == "FakeProvider",
			"provider_name_missing", "目标请求没有记录 provider")

	_check_carrot_sub_targets(tutorial, fake)

	_h.expect(fake.request_action(ProviderScript.ACTION_CLOSE_MERCENARY),
		"close_action_unbound", "关闭佣兵动作没有绑定")
	_h.expect(fake.request_action(ProviderScript.ACTION_REFRESH_VIEW),
		"refresh_action_unbound", "刷新动作没有绑定")
	_h.expect(_close_action_seen, "close_action_not_called", "关闭佣兵动作没有执行")
	_h.expect(_refresh_action_seen, "refresh_action_not_called", "刷新动作没有执行")

	var missing: ProviderScript = ProviderScript.new("MissingFake", host)
	missing.bind_feedback(_capture_feedback)
	_feedback_seen = ""
	var unresolved := missing.resolve_target(
		ProviderScript.TARGET_BUY_UNIT, "BUY_3", "recoverable feedback")
	var diagnostic := missing.last_missing_snapshot()
	_h.expect(unresolved == null, "missing_target_returned_control",
		"未绑定目标却返回了控件")
	_h.expect(str(diagnostic.get("step", "")) == "BUY_3",
		"missing_step_not_reported", "缺目标诊断没有 step")
	_h.expect(str(diagnostic.get("target", "")) == ProviderScript.TARGET_BUY_UNIT,
		"missing_target_not_reported", "缺目标诊断没有 target")
	_h.expect(str(diagnostic.get("provider", "")) == "MissingFake",
		"missing_provider_not_reported", "缺目标诊断没有 provider")
	_h.expect(not str(diagnostic.get("reason", "")).is_empty(),
		"missing_reason_not_reported", "缺目标诊断没有 reason")
	_h.expect(_feedback_seen == "recoverable feedback",
		"missing_target_has_no_player_feedback", "缺目标时没有给玩家可恢复反馈")

	tutorial.finish()
	tutorial.queue_free()
	host.queue_free()
	await get_tree().process_frame


func _check_live_prep_adapter() -> void:
	GameState.reset_run()
	if not GameState.bench_slots.is_empty():
		GameState.bench_slots[0] = {
			"id": "human_militia",
			"star": 1,
			"def": {"id": "human_militia"},
		}
	var packed := load(PREP_SCENE) as PackedScene
	if not _h.expect(packed != null, "prep_scene_load_failed",
			"%s 加载不出来" % PREP_SCENE):
		return
	var prep: PrepScript = packed.instantiate() as PrepScript
	add_child(prep)
	await get_tree().process_frame
	await get_tree().process_frame
	var provider: ProviderScript = prep.tutorial_target_provider()
	_h.expect(provider != null, "prep_provider_missing",
		"PrepScreen 没有组合运行时 TutorialTargetProvider")
	if provider != null:
		_h.expect(provider.overlay_host() == prep, "wrong_overlay_host",
			"Prep provider 的 overlay host 不是 PrepScreen")
		_h.expect(provider.provider_name() == "PrepScreen", "wrong_provider_name",
			"Prep provider 没有稳定名称")
		for target_id in ProviderScript.required_target_ids():
			_h.item()
			_h.expect(provider.has_target(str(target_id)), "runtime_target_unbound",
				"Prep provider 没有绑定语义目标 %s" % str(target_id))
			var target := provider.resolve_target(
				str(target_id), "CHECK_%s" % str(target_id), "")
			_h.expect(target != null, "runtime_target_unresolved",
				"Prep provider 的语义目标 %s 在实屏上解析不到 Control" % str(target_id))
	prep.queue_free()
	await get_tree().process_frame


# 营地打开之后，一个步骤里按「营地开合 / 当前页签 / 是否已完成」依次换目标。
# 直接写 TutorialMode 的界面状态字段：走 record_carrot_camp_state() 会触发 sync()
# 把步骤往前推，这里只验「状态 -> 目标」的映射。
func _check_carrot_sub_targets(tutorial: TutorialScript, fake: ProviderScript) -> void:
	var saved_level := GameState.harvest_tech_level
	var cases := [
		[TutorialScript.Step.HARVEST_UPGRADE, true, TutorialScript.CAMP_PAGE_STONE, 0, ProviderScript.TARGET_CARROT_CAMP_TAB],
		[TutorialScript.Step.HARVEST_UPGRADE, true, TutorialScript.CAMP_PAGE_CAMP, 0, ProviderScript.TARGET_HARVEST_UPGRADE],
		[TutorialScript.Step.HARVEST_UPGRADE, true, TutorialScript.CAMP_PAGE_CAMP, 1, ProviderScript.TARGET_CARROT_CLOSE],
		[TutorialScript.Step.DRAW_STONE, true, TutorialScript.CAMP_PAGE_CAMP, 1, ProviderScript.TARGET_CARROT_STONE_TAB],
		[TutorialScript.Step.DRAW_STONE, true, TutorialScript.CAMP_PAGE_STONE, 1, ProviderScript.TARGET_STONE_DRAW],
		[TutorialScript.Step.FOUR_STAR, true, TutorialScript.CAMP_PAGE_CAMP, 1, ProviderScript.TARGET_CARROT_STONE_TAB],
		[TutorialScript.Step.FOUR_STAR, true, TutorialScript.CAMP_PAGE_STONE, 1, ProviderScript.TARGET_FOUR_STAR_ROW],
	]
	for c in cases:
		tutorial.step = int(c[0])
		tutorial._camp_open = bool(c[1])
		tutorial._camp_page = int(c[2])
		GameState.harvest_tech_level = int(c[3])
		tutorial.update_overlay()
		var request := fake.last_request_snapshot()
		_h.item()
		_h.expect(str(request.get("target", "")) == str(c[4]), "wrong_carrot_sub_target",
			"步骤 %s（营地开=%s 页=%d 采集=%d）请求了 %s，期望 %s" % [
				str(TutorialScript.Step.keys()[int(c[0])]), str(c[1]), int(c[2]), int(c[3]),
				str(request.get("target", "")), str(c[4])])
	tutorial._camp_open = false
	tutorial._camp_page = TutorialScript.CAMP_PAGE_CAMP
	GameState.harvest_tech_level = saved_level


func _return_control(control: Control) -> Control:
	return control


func _capture_feedback(text: String) -> void:
	_feedback_seen = text


func _capture_close_action() -> void:
	_close_action_seen = true


func _capture_refresh_action() -> void:
	_refresh_action_seen = true


func _strip_comments(text: String) -> String:
	var out: Array[String] = []
	for line in text.split("\n"):
		var hash_at := line.find("#")
		out.append(line if hash_at < 0 else line.substr(0, hash_at))
	return "\n".join(out)
