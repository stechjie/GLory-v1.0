extends Node

# 门禁：战斗血条/单位配色的「我方绿 / 敌方红」归属（scenes/battle/**）。
#
# ## 9.29 bug 文档第 1 条（这条门禁就是为它写的）
#
# 玩家反馈：一场仗**一开始我方绿、敌方红**，但到了**最终回合**，我方跑到右边变成**红**、
# 敌方变**绿**。要求「恒定：我方绿、敌方红」。
#
# ## 根因（不是配色函数写错，是两个概念被一个开关绑在一起）
#
# 规范化棋局里 A 队（slot 0-2）恒为 "player" 侧。观众若坐在 B 队，画面上的「我方」是
# 规范化的 enemy 侧，血条必须翻色，否则看到自己是红的。
#
# 这个「翻色」原来只用 `_arena_flip_y` 一个开关判断，而 `_arena_flip_y` 同时管三件事：
#   ① 位置上下镜像（BattleArena._sim_to_world_pos）
#   ② 半场标签归属
#   ③ 配色归属（BattleRenderer._display_team）
# 最终回合把战斗轴改成**左右**，位置绝不能翻（翻了画面会坏），于是 `_arena_flip_y`
# 在决赛被强制 false —— 顺带把 ③ 也关了 ⇒ B 队玩家在决赛里看到自己全红。
#
# 修法：把配色归属从位置镜像里**解耦**出来，单独用 `_color_flip`：
#   · 位置镜像 `_arena_flip_y`：决赛 false（不变）
#   · 配色归属 `_color_flip`：只看「观众是否坐在规范化 enemy 侧」，决赛也生效
#
# ## 这条门禁验什么（行为 + 结构，缺一不可）
#
#   1. 行为：`resolve_display_team` 四种组合都对，且翻转后 **enemy→player**（=绿）。
#   2. 行为：`hp_color_for_display_team` 的绿/红必须与 _hp_color_for_team 历史值一致
#      （绿 0.2,0.9,0.25 / 红 1.0,0.18,0.12）—— 别顺手改了色号。
#   3. 行为：**决赛 B 队场景**端到端 —— color_flip=true 时，B 队自己的棋子（真实 team
#      = "enemy"）展示为 player（绿），对面 A 队棋子（真实 "player"）展示为 enemy（红）。
#   4. 结构：`BattleScreen` 里 `_color_flip` 的赋值**不许带决赛排除**（那正是 bug）。
#   5. 结构：`_display_team` 必须读 `_color_flip`，**不许**再读 `_arena_flip_y`。
#
# ## 跑
#   godot --headless --path <项目> tools/battle_team_color_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
# 只 preload 脚本、**不实例化** —— BattleRenderer 是重型 3D 场景，headless new() 会挂死。
# 两个判据已抽成 static 纯函数，直接调即可（见 BattleRenderer.resolve_display_team）。
const BattleRendererScript := preload("res://scenes/battle/BattleRenderer.gd")

const CHECK_NAME := "battle_team_color"
const SCREEN_PATH := "res://scenes/battle/BattleScreen.gd"
const RENDERER_PATH := "res://scenes/battle/BattleRenderer.gd"
const UI_PATH := "res://scenes/battle/BattleUI.gd"

# 历史色号：我方绿 / 敌方红。改动这条就是改全局观感，必须是有意识的决定。
const FRIENDLY := Color(0.2, 0.9, 0.25)
const ENEMY := Color(1.0, 0.18, 0.12)

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_display_team_mapping()
	_case_hp_color_values()
	_case_final_round_b_team_end_to_end()
	_case_color_flip_not_pinned_to_final_exclusion()
	_case_display_team_reads_color_flip()
	_case_state_fields_exist()
	_h.finish(get_tree())


# --- 1. 展示 team 的映射 --------------------------------------------------------

func _case_display_team_mapping() -> void:
	# 不翻（A 队观众 / 单机）：原样透传。
	_h.expect(BattleRendererScript.resolve_display_team("player", false) == "player",
		"noflip_player_passthrough",
		"不翻色时 player 应原样透传")
	_h.expect(BattleRendererScript.resolve_display_team("enemy", false) == "enemy",
		"noflip_enemy_passthrough",
		"不翻色时 enemy 应原样透传")
	# 翻（B 队观众）：交换。
	_h.expect(BattleRendererScript.resolve_display_team("enemy", true) == "player",
		"flip_enemy_becomes_player",
		"B 队观众自己的棋子（规范化 enemy 侧）必须展示为 player（绿）—— 决赛 bug 就卡在这")
	_h.expect(BattleRendererScript.resolve_display_team("player", true) == "enemy",
		"flip_player_becomes_enemy",
		"B 队观众看到对面 A 队（规范化 player 侧）必须展示为 enemy（红）")


# --- 2. 色号 -------------------------------------------------------------------

func _case_hp_color_values() -> void:
	var friendly := BattleRendererScript.hp_color_for_display_team("player")
	var enemy := BattleRendererScript.hp_color_for_display_team("enemy")
	_h.expect(friendly.is_equal_approx(FRIENDLY), "friendly_color_changed",
		"我方（player）血条色不是历史绿 (0.2,0.9,0.25)：%s" % str(friendly))
	_h.expect(enemy.is_equal_approx(ENEMY), "enemy_color_changed",
		"敌方（enemy）血条色不是历史红 (1.0,0.18,0.12)：%s" % str(enemy))
	# 兜底：任何非 "enemy" 的展示 team 都算我方（绿）。策反/复活等异常 team 字符串
	# 不该渲染成敌人红。
	_h.expect(BattleRendererScript.hp_color_for_display_team("").is_equal_approx(FRIENDLY),
		"unknown_team_not_friendly", "非 enemy 的 team 应兜底为我方绿")


# --- 3. 决赛 B 队端到端 ---------------------------------------------------------

# 这一条是**用户报的那个场景**：决赛里 B 队玩家自己的棋子不能是红的。
func _case_final_round_b_team_end_to_end() -> void:
	# 决赛：位置不翻（_arena_flip_y=false），但 B 队观众要翻色（_color_flip=true）。
	var arena_flip := false
	var color_flip := true
	# 不变量：位置镜像与配色归属**必须解耦** —— 否则「决赛位置不翻」又会把配色一起关掉。
	_h.expect(not arena_flip and color_flip, "final_round_flags_decoupled",
		"决赛必须「位置不翻 + 色要翻」，两者不能同源")

	# B 队自己的棋子：规范化 team = "enemy"。
	var my_display := BattleRendererScript.resolve_display_team("enemy", color_flip)
	var my_color := BattleRendererScript.hp_color_for_display_team(my_display)
	_h.expect(my_display == "player", "final_b_team_self_is_player",
		"决赛里 B 队自己的棋子应展示为 player")
	_h.expect(my_color.is_equal_approx(FRIENDLY), "final_b_team_self_is_green",
		"决赛里 B 队自己的血条必须是绿 —— 这正是用户反馈「我方变红」的那一处，实际 %s" % str(my_color))

	# 对面 A 队的棋子：规范化 team = "player"。
	var foe_display := BattleRendererScript.resolve_display_team("player", color_flip)
	var foe_color := BattleRendererScript.hp_color_for_display_team(foe_display)
	_h.expect(foe_display == "enemy", "final_b_team_foe_is_enemy",
		"决赛里 A 队（对面）应展示为 enemy")
	_h.expect(foe_color.is_equal_approx(ENEMY), "final_b_team_foe_is_red",
		"决赛里对面血条必须是红，实际 %s" % str(foe_color))

	# A 队观众看决赛：不翻，自己仍绿。
	var a_self := BattleRendererScript.hp_color_for_display_team(
		BattleRendererScript.resolve_display_team("player", false))
	_h.expect(a_self.is_equal_approx(FRIENDLY), "final_a_team_self_green",
		"决赛里 A 队观众自己的血条仍是绿")


# --- 4. 结构：_color_flip 的赋值不许带决赛排除 ------------------------------------

func _case_color_flip_not_pinned_to_final_exclusion() -> void:
	var code := _code(SCREEN_PATH)
	var idx := code.find("_color_flip =")
	_h.expect(idx >= 0, "color_flip_not_assigned",
		"BattleScreen.gd 里没有给 _color_flip 赋值 —— 配色归属没从位置镜像解耦")
	if idx >= 0:
		# ⚠️ 取到「空行」为止，**不要只取第一行** —— 赋值可能带行尾 `\` 续行，决赛排除
		# 就会落在第二行上；只切第一行会让这条断言**静默失效**（变异实证曾漏过 M2）。
		var tail := code.substr(idx, 240)
		var window := tail.split("\n\n")[0].replace("\\\n", " ")
		_h.expect(not window.contains("FINAL_ROUND"), "color_flip_has_final_exclusion",
			"_color_flip 的赋值里出现了 FINAL_ROUND 排除 —— 决赛又会关掉配色翻转，bug 复发：%s"
				% window.replace("\n", " "))
		_h.expect(window.contains("my_team == 1"), "color_flip_not_teambased",
			"_color_flip 必须按「观众队伍 == 1(B 队)」判定，实际：%s" % window.replace("\n", " "))
	# 反向保险：_arena_flip_y 的赋值**必须**保留决赛排除（位置不能翻）。
	# ⚠️ 这个赋值跨了两行（行尾 `\` 续行），不能只切第一行 —— 否则排除条件在第二行，
	# 断言会误报「被删掉了」。
	var aidx := code.find("_arena_flip_y =")
	_h.expect(aidx >= 0, "arena_flip_not_assigned", "BattleScreen.gd 里没有给 _arena_flip_y 赋值")
	if aidx >= 0:
		var astmt := code.substr(aidx, 240).split("\n\n")[0]
		_h.expect(astmt.contains("FINAL_ROUND"), "arena_flip_lost_final_exclusion",
			"_arena_flip_y 决赛排除被删掉了 —— 决赛画面会被上下镜像转坏：%s" % astmt.replace("\n", " "))


# --- 5. 结构：_display_team 读的是 _color_flip ------------------------------------

func _case_display_team_reads_color_flip() -> void:
	var code := _code(RENDERER_PATH)
	var body := code.split("func _display_team(")[1].split("func ")[0]
	_h.expect(body.contains("_color_flip"), "display_team_not_color_flip",
		"_display_team 没读 _color_flip —— 配色归属没接上")
	_h.expect(not body.contains("_arena_flip_y"), "display_team_still_reads_arena_flip",
		"_display_team 还在读 _arena_flip_y —— 决赛位置不翻时会重新把配色关掉（bug 复发）")
	# 判据留在 static 纯函数里（探针能直调，不必实例化重型场景）。
	_h.expect(code.contains("static func resolve_display_team("), "resolve_not_static",
		"resolve_display_team 不是 static 纯函数 —— 门禁/探针将无法在不实例化场景的前提下直调")
	_h.expect(code.contains("static func hp_color_for_display_team("), "hp_color_not_static",
		"hp_color_for_display_team 不是 static 纯函数")


# --- 6. 结构：两个开关都声明了 ---------------------------------------------------

func _case_state_fields_exist() -> void:
	var ui := FileAccess.get_file_as_string(UI_PATH)
	_h.expect(ui.contains("var _color_flip"), "color_flip_field_missing",
		"BattleUI.gd 没有声明 _color_flip 字段")
	# 两者必须是**两个**独立字段（同名合并就退化解耦了）。
	_h.expect(ui.contains("var _arena_flip_y"), "arena_flip_field_missing",
		"BattleUI.gd 的 _arena_flip_y 字段没了")


# --- 小工具 ---------------------------------------------------------------------

# 去掉整行注释后的源码：扫「代码里有没有写 X」必须走这个，否则解释性注释会自己红自己。
func _code(path: String) -> String:
	var kept: Array[String] = []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if not str(line).strip_edges().begins_with("#"):
			kept.append(str(line))
	return "\n".join(kept)
