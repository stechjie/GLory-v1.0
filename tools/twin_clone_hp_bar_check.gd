extends Node

# 11.28 镜像刺客（用户定）：生命 2750（试过 2580，改回）、开场 5 秒首发；分身生命 = 放技能那一刻本体当前生命的 30%。
# 分身的血条不是满格，而是按本体最大生命画（回放名单多一个可选键 hp_bar_max，只供显示）。

const Renderer := preload("res://scenes/battle/BattleRenderer.gd")
const Harness := preload("res://tools/CheckHarness.gd")


func _ready() -> void:
	var h := Harness.new("twin_clone_hp_bar")
	DataRegistry.load_all()
	var d: Dictionary = {}
	for merc: Dictionary in DataRegistry.get_table("mercenaries").get("mercenaries", []):
		if str(merc.get("id", "")) == "merc_gemini_assassin":
			d = merc.duplicate(true)
	h.expect(not d.is_empty(), "merc_data", "找不到镜像刺客数据")
	var caster: Dictionary = BattleSimShared._fighter_from_def(d, 0, "player", 0, 1, 1, true, false)
	caster.uid = "gemini"
	h.expect(int(caster.max_hp) == 2750 and is_equal_approx(float(d.get("first_cast_sec", 0.0)), 5.0), "merc_values",
		"镜像刺客应为生命 2750、开场 5 秒首发，实际 %d / %s" % [int(caster.max_hp), str(d.get("first_cast_sec", ""))])
	caster.hp = 800  # 11.28：分身按放技能那一刻本体的**当前**生命算，800 × 30% = 240
	var state := {"player": [caster], "enemy": [], "elapsed": 5.0}
	BattleSimSkills._skill_twin_strike(caster, state, d)
	h.expect(state.player.size() == 2, "clone_spawned", "应召出 1 个分身")
	var clone: Dictionary = state.player[1]
	var body_max := int(caster.max_hp)
	var clone_hp := 240
	h.expect(int(clone.hp) == clone_hp and int(clone.max_hp) == clone_hp, "clone_hp_from_current",
		"本体剩 800 时分身生命应为 240：hp %d / max %d" % [int(clone.hp), int(clone.max_hp)])
	# 满血时放：2750 × 30% = 825。
	caster.hp = body_max
	BattleSimSkills._skill_twin_strike(caster, state, d)
	h.expect(int((state.player[2] as Dictionary).hp) == 825, "clone_hp_full_body", "本体满血时分身生命应为 825，实际 %d" % int((state.player[2] as Dictionary).hp))
	h.expect(int(clone.get("hp_bar_max", 0)) == body_max and not caster.has("hp_bar_max"), "clone_bar_max",
		"分身的血条满格值 = 本体最大生命 %d，实际 %d；本体不带这个键" % [body_max, int(clone.get("hp_bar_max", 0))])

	# 回放名单：只有分身带 hp_bar_max。
	var roster := {}
	BattleSimulator._replay_capture_roster(state, roster)
	h.expect(int((roster[str(clone.uid)] as Dictionary).get("hp_bar_max", 0)) == body_max
		and not (roster["gemini"] as Dictionary).has("hp_bar_max"), "roster_key", "回放名单里只有分身带 hp_bar_max")

	# 血条：分身满血时只画三成；没有这个键的棋子照旧画满。
	var host := Control.new()
	add_child(host)
	Renderer._add_health_bar(host, clone, "player")
	var hp := host.get_node("HpFill") as ColorRect
	var bg := host.get_node("HpBg") as ColorRect
	Renderer._sync_health_segments(hp, clone)
	var full_width := hp.size.x
	h.expect(is_equal_approx(hp.scale.x, float(clone_hp) / float(body_max)), "bar_thirty_pct",
		"分身满血时血条应为 %.2f，实际 %.2f" % [float(clone_hp) / float(body_max), hp.scale.x])
	# 斩杀线仍按真实最大生命：hp_max_width 对应「真实满血」的宽度 = 当前这三成的宽度。
	h.expect(is_equal_approx(float(bg.get_meta("hp_max_width", 0.0)), full_width * hp.scale.x), "execute_line_real_max",
		"斩杀线的满血宽度应等于分身真实满血的宽度")
	Renderer._sync_health_segments(hp, {"hp": clone_hp, "max_hp": clone_hp, "shield": 0})
	h.expect(is_equal_approx(hp.scale.x, 1.0), "plain_unit_full", "不带 hp_bar_max 的棋子满血仍画满")
	h.finish(get_tree())
