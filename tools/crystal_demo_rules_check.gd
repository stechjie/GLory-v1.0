extends Node

# 结算水晶演出的决策表校验：_crystal_demo_losing_team 决定这一局演不演、演哪一队的
# 水晶。PvP 的答案必须是绝对队伍（六个客户端一致），PvE 只有我方被打穿才演。

const BattleArenaScript := preload("res://scenes/battle/BattleResult.gd")

var arena: Control

func _ready() -> void:
	arena = BattleArenaScript.new()
	var ok := true
	# 名称, kind, player_wins, player_alive, enemy_alive, round_index, 本地槽位, 期望
	var cases := [
		["PvP 红队赢 -> 打蓝晶", "pvp", true, 3, 0, 5, 0, GameConstants.TEAM_BLUE],
		["PvP 红队赢 / 蓝队玩家视角也一样", "pvp", true, 3, 0, 5, 4, GameConstants.TEAM_BLUE],
		["PvP 蓝队赢 -> 打红晶", "pvp", false, 0, 3, 5, 0, GameConstants.TEAM_RED],
		["PvP 蓝队赢 / 蓝队玩家视角也一样", "pvp", false, 0, 3, 5, 5, GameConstants.TEAM_RED],
		["PvE 我方赢 -> 不演", "pve", true, 3, 0, 5, 0, -1],
		["PvE 我方全灭 / 红队玩家", "pve", false, 0, 5, 5, 1, GameConstants.TEAM_RED],
		["PvE 我方全灭 / 蓝队玩家", "pve", false, 0, 5, 5, 4, GameConstants.TEAM_BLUE],
		["Boss 我方全灭 / 蓝队玩家", "boss", false, 0, 2, 12, 3, GameConstants.TEAM_BLUE],
		["第 21 回合 -> 不演", "pvp", true, 3, 0, GameState.FINAL_ROUND, 0, -1],
		["同归于尽 -> 不演", "pvp", true, 0, 0, 5, 0, -1],
	]
	for case in cases:
		var label := str(case[0])
		GameState.round_index = int(case[5])
		NetworkService.team_local_slot = int(case[6])
		var result := {
			"kind": str(case[1]),
			"player_wins": bool(case[2]),
			"player_alive": int(case[3]),
			"enemy_alive": int(case[4]),
		}
		var got: int = arena._crystal_demo_losing_team(result)
		var want := int(case[7])
		var pass_case := got == want
		ok = ok and pass_case
		print("%s  %s  got=%s want=%s" % [
			"PASS" if pass_case else "FAIL", label, _team_name(got), _team_name(want)])
	print("CRYSTAL_RULES: %s" % ("ALL PASS" if ok else "FAILED"))
	arena.free()
	get_tree().quit(0 if ok else 1)

func _team_name(team: int) -> String:
	match team:
		GameConstants.TEAM_RED: return "红队"
		GameConstants.TEAM_BLUE: return "蓝队"
	return "不演出"
