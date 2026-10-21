extends Node

# ============================================================================
# 2026-10-20 门禁：教程 5 项修复的「接线」契约（10.19 反馈第 1/3/4/5 条）。
#
# 为什么单独一条：
#   * 第 1 条的版面行为由 tutorial_overlay_layout_check 量；
#   * 第 2 条的数值契约由 tutorial_pvp_script_check 量；
#   * 这里钉的是**接线**：引导链有没有真的串到「等级奖励 → 成长之路 → 返回 → 备战」、
#     结算界面有没有真的隐藏查看详情、种族页锁输入有没有真的接上。
#   这些错法不会崩，只会「流程又跳步了」，必须靠源码契约钉住。
#
# 【写法铁律】只读源码 / 只查方法是否存在，不实例化界面（避免账号数据依赖）；
#   任何一条被改回去都要红，并且报错信息直接说「玩家会看到什么」。
#
# 【跑法】
#   Godot_v4.7.2-stable_win64_console.exe --headless --path <工程根> \
#       res://tools/tutorial_guide_chain_check.tscn
# ============================================================================

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "tutorial_guide_chain"
const MAIN_SRC := "res://scenes/main/Main.gd"
const PROFILE_SRC := "res://scenes/menu/ProfileScreen.gd"
const PROGRESSION_SRC := "res://scenes/menu/ProgressionPanel.gd"
const PET_SRC := "res://scenes/menu/PetScreen.gd"
const GAMEOVER_SRC := "res://scenes/menu/GameOverScreen.gd"
const ARENA_SRC := "res://scenes/battle/BattleArena.gd"
const TUTORIAL_SRC := "res://scripts/tutorial/TutorialMode.gd"
const GUIDE_SRC := "res://scripts/tutorial/TutorialEntryGuide.gd"
const SHADER_SRC := "res://shaders/tutorial_focus_mask.gdshader"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_run()
	_h.expect(_h.checked_count() >= 24, "too_few_assertions",
		"整个门禁只量到 %d 条断言，等于没验" % _h.checked_count())
	_h.finish(get_tree())


func _run() -> void:
	var main := _read(MAIN_SRC)
	var profile := _read(PROFILE_SRC)
	var progression := _read(PROGRESSION_SRC)
	var pet := _read(PET_SRC)
	var gameover := _read(GAMEOVER_SRC)
	var arena := _read(ARENA_SRC)
	var tutorial := _read(TUTORIAL_SRC)
	var guide := _read(GUIDE_SRC)
	var shader := _read(SHADER_SRC)

	for pair in [[MAIN_SRC, main], [PROFILE_SRC, profile], [PROGRESSION_SRC, progression],
			[PET_SRC, pet], [GAMEOVER_SRC, gameover], [ARENA_SRC, arena], [TUTORIAL_SRC, tutorial],
			[GUIDE_SRC, guide], [SHADER_SRC, shader]]:
		_h.expect(not str(pair[1]).is_empty(), "source_unreadable",
			"读不到 %s —— 本门禁等于没跑" % str(pair[0]))

	# ---- 第 4 条：头像 → 等级奖励 → 成长之路 → 返回 → 备战 ----
	var reward_body := _func_body(main, "_show_tutorial_level_reward")
	_h.expect(reward_body.find("tutorial_level_tab_target") >= 0, "reward_tab_target_missing",
		"_show_tutorial_level_reward 没把引导挂到「等级奖励」页签 —— 玩家主页上没有任何高亮")
	_h.expect(reward_body.find("unseen_levels") < 0, "unseen_judge_back",
		"_show_tutorial_level_reward 又用回了 unseen_levels —— 已 Lv2 的回归账号会再次直接跳备战")
	_h.expect(reward_body.find("tutorial_progression_opened") >= 0, "progression_signal_missing",
		"_show_tutorial_level_reward 没接 ProfileScreen.tutorial_progression_opened —— 成长之路里的「返回」不会被高亮")
	var opened_body := _func_body(main, "_on_tutorial_progression_opened")
	_h.expect(opened_body.find("tutorial_back_target") >= 0, "progression_back_target_missing",
		"打开成长之路后没有指向面板的「返回」键")
	_h.expect(opened_body.find("progression_back") >= 0, "progression_back_phase_missing",
		"成长之路阶段没有用 progression_back 文案")
	# 10.20 新增：已获得的奖励（人族全套棋子 / 神侍）也要一起打亮。
	_h.expect(opened_body.find("tutorial_reward_target") >= 0, "progression_reward_target_missing",
		"成长之路只高亮了「返回」—— 已获得的奖励那一排仍是暗的")
	_h.expect(opened_body.find("set_second_focus") >= 0, "progression_second_hole_missing",
		"没有把奖励区交给第二个遮罩洞（第二个洞不接，奖励区就不会亮）")
	_h.expect(progression.find("func tutorial_reward_target") >= 0, "panel_reward_target_missing",
		"ProgressionPanel 缺 tutorial_reward_target()")
	_h.expect(guide.find("func set_second_focus") >= 0, "guide_second_focus_missing",
		"TutorialEntryGuide 缺 set_second_focus() —— 第二个洞无人设置")
	_h.expect(shader.find("uniform vec4 hole2") >= 0 and shader.find("hole2_on") >= 0,
		"shader_second_hole_missing",
		"聚焦遮罩没有第二个洞（hole2/hole2_on）—— 奖励与返回无法同时高亮")
	var dismissed_body := _func_body(main, "_on_tutorial_progression_dismissed")
	_h.expect(dismissed_body.find("set_tutorial_followup_step(\"prep\")") >= 0, "progression_dismiss_not_prep",
		"点「返回」后没有把引导推进到「点击备战」—— 流程会断在成长之路")
	_h.expect(profile.find("func tutorial_level_tab_target") >= 0, "profile_target_missing",
		"ProfileScreen 缺 tutorial_level_tab_target()")
	_h.expect(profile.find("tutorial_progression_opened.emit(panel)") >= 0, "profile_signal_not_emitted",
		"ProfileScreen._open_progression 没发出 tutorial_progression_opened")
	_h.expect(progression.find("func tutorial_back_target") >= 0, "panel_target_missing",
		"ProgressionPanel 缺 tutorial_back_target()")

	# ---- 第 5 条：种族页锁输入 + 返回即结束引导 ----
	var race_body := _func_body(main, "_on_tutorial_races_opened")
	_h.expect(race_body.find("tutorial_lock_page_input") >= 0, "race_lock_missing",
		"种族页没有锁输入 —— 教学模式下其他按钮又能点了")
	_h.expect(race_body.find("tutorial_back_target") >= 0, "race_back_target_missing",
		"种族页的引导目标不是「返回」键")
	var pet_back_body := _func_body(main, "_on_pet_back")
	_h.expect(pet_back_body.find("set_tutorial_followup_step(\"\")") >= 0, "pet_back_not_clearing",
		"种族页点返回没有清掉引导进度 —— 「点休闲」的提示和高亮还会再弹")
	_h.expect(pet.find("func tutorial_lock_page_input") >= 0, "pet_lock_missing",
		"PetScreen 缺 tutorial_lock_page_input()")
	_h.expect(pet.find("tutorial_lock_page_input(true)") < 0, "pet_self_locking",
		"PetScreen 自己就把锁打开了 —— 必须由教程引导（Main）来开，普通玩法不能锁")
	_h.expect(pet.find("btn != _back_btn") >= 0, "pet_lock_covers_back",
		"锁输入连「返回」键一起关了 —— 玩家会被卡死在这一页")
	var menu_body := _func_body(main, "_show_menu")
	_h.expect(menu_body.find("followup_casual") < 0, "casual_guide_still_attached",
		"_show_menu 还在挂 followup_casual 引导 —— 返回大厅又会弹「点休闲」提示")

	# ---- 第 3 条：教学结算隐藏查看详情 ----
	_h.expect(gameover.find("show_details and not tutorial_result") >= 0, "details_not_hidden",
		"教学结算还在出「查看详情」—— 会继续挤占返回主菜单并压住正文")
	_h.expect(gameover.find("0.24 if compact else 0.43") >= 0, "compact_heading_missing",
		"教学结算的标题区没有上移 —— 会被引导气泡和按钮盖住")
	_h.expect(gameover.find("0.47 if compact else 0.69") >= 0, "compact_body_missing",
		"教学结算的正文区没有上移 —— 「最终胜利及下面」仍被遮挡")

	# ---- 第 2 条：水晶分母 + 第 11 回合不强制胜 ----
	var ratio_body := _func_body(arena, "_crystal_hp_ratio")
	_h.expect(ratio_body.find("TUTORIAL_HP") >= 0, "crystal_denominator",
		"水晶比例分母没改 TUTORIAL_HP —— 教学扣 1 点仍会演成归零")
	var coerce_body := _func_body(tutorial, "coerce_victory")
	_h.expect(coerce_body.find("SCRIPTED_LOSS_ROUNDS") >= 0, "round11_coerce_guard_missing",
		"coerce_victory 没有第 11 回合的跳过 —— 脚本败仍会被改写成胜利")
	var after_body := _func_body(tutorial, "after_battle")
	_h.expect(after_body.find("_apply_scripted_team_damage") >= 0, "team_damage_not_applied",
		"after_battle 没有应用法阵伤害 —— HUD 会一直是 10/10")

	# ---- 第 1 条：跳过按钮进避让区 ----
	var bubble_body := _func_body(tutorial, "_bubble_position")
	_h.expect(bubble_body.find("SKIP_BUBBLE_CLEAR_PAD") >= 0, "skip_clear_missing",
		"气泡避让区没加「跳过教学」按钮 —— 文本框会继续压住它")


# ---------------------------------------------------------------- 工具

func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


# 取一个函数体的源码（从 `func name(` 到下一个顶层 `func `）。
func _func_body(src: String, name: String) -> String:
	var start := src.find("func %s(" % name)
	if start < 0:
		return ""
	var end := src.find("\nfunc ", start + 8)
	if end < 0:
		end = src.length()
	return src.substr(start, end - start)
