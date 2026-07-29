class_name TeamOutcome
extends RefCounted

# 3v3 胜负判定的唯一实现（C16）。
#
# 此前同一套规则有三份独立实现：服务端结算 `_room_build_match_states`、
# 战斗界面 `BattleUI._local_player_wins`、以及 `Main._on_team_battle_finished`
# 的本地 fallback。它们不只是代码重复 —— 规则本身已经分叉：
#   * 服务端第 21 回合按「最终战胜负」决定整局；
#   * 本地 fallback 落进 else 分支，按「剩余水晶生命」决定；
#   * 双杀两边都用 `hp_a >= hp_b`，0 >= 0 恒真 → **固定判 A 队胜**。
# 最后一条直接违反「两队玩家平等待遇」。
#
# 已确认的产品规则（2026-07-28 定稿）：
#   1. **第 21 回合恒为最终战**：两队棋子同场对打，加上按水晶血量召唤的友军和
#      双方的佣兵。没有 pve/boss 形态。打完有一方赢就**直接赢下整局**，
#      水晶血量不参与；只有双方同时全灭才是平局。
#   2. **第 21 回合之前**：对局只在某队水晶归零时结束，归零方判负、另一方胜。
#      那一轮的战斗胜负本身不决定整局，**唯一依据是水晶血量**。
#   3. **两队水晶同时归零 = 平局**（PVE/Boss 各打各的怪时可能发生；
#      中途 PVP 同场对打只有输方掉血，不会同时归零）。
#   4. 任何情况下都不得用「相等就判 A 队」这类回退 —— 那正是旧实现的队伍偏置。
#
# 命名刻意只用 team_a / team_b / viewer_team：
# 「玩家 / 敌方」这类相对视角命名正是队伍偏置的来源。

enum { TEAM_A = 0, TEAM_B = 1, DRAW = 2 }

# --- 单场战斗 ---------------------------------------------------------------

# 服务端视角：手里有两队各自的 replay 结果。
# replay 是**规范化棋局**——A 队恒为 "player" 方，所以 `res_a.player_wins` 就是
# A 队视角。PVP 双方同场对战，一方赢即另一方输；PVE/Boss 各打各的怪，胜负独立。
static func team_wins_battle(res_a: Dictionary, res_b: Dictionary, kind: String, team: int) -> bool:
	if team == TEAM_A:
		return bool(res_a.get("player_wins", false))
	if kind == "pvp":
		return not bool(res_a.get("player_wins", false))
	return bool(res_b.get("player_wins", false))

# 客户端视角：只有自己那一份 replay。
# PVP 时它仍是规范化的 A 视角，B 队要反转；PVE/Boss 时它就是本队自己那场，直接用。
static func viewer_wins_battle(result: Dictionary, kind: String, viewer_team: int) -> bool:
	var wins := bool(result.get("player_wins", false))
	if kind == "pvp" and viewer_team == TEAM_B:
		return not wins
	return wins

# --- 整局归属 ---------------------------------------------------------------

# ctx:
#   completed_round : int   刚打完的回合
#   final_round     : int   GameState.FINAL_ROUND
#   hp_a / hp_b     : int   结算后两队水晶生命
#   kind            : String  "pvp" / "pve" / "boss"
#   battle_a_wins   : bool  本场 A 队是否获胜（A 视角，即 res_a.player_wins）
#   battle_is_draw  : bool  本场是否真正打平（res_a.is_draw：双方全灭或超时战力相等）
#
# 返回 TEAM_A / TEAM_B / DRAW。
static func run_outcome(ctx: Dictionary) -> int:
	var completed_round := int(ctx.get("completed_round", 0))
	var final_round := int(ctx.get("final_round", 0))

	# 规则 1：第 21 回合恒为最终战，按那一战的结果判整局，水晶血量不参与。
	#
	# 这里**刻意不检查 kind**。第 21 回合按定义就是最终战，没有 pve/boss 形态；
	# 而 kind 的字面值取决于从哪里读：`RoundService.schedule_kind_for_round(21)`
	# 给的是 "final"，但 `prepare_team_state` 内部会立刻把它改写成 "pvp" 再存进
	# state/replay。依赖任何一个字面值，都会在下次有人改写法时静默走错分支。
	#
	# `battle_a_wins` 在真平局时是模拟器的偏 A 回退值（双方全灭 -> player_wins=true，
	# 超时战力相等 -> 用恒相等的 formation_hp 破平），所以必须先看 is_draw，
	# 否则"双方同时全灭"会被静默转成"A 队胜"。
	if final_round > 0 and completed_round >= final_round:
		if bool(ctx.get("battle_is_draw", false)):
			return DRAW
		return TEAM_A if bool(ctx.get("battle_a_wins", false)) else TEAM_B

	# 规则 2：第 21 回合之前，唯一依据是水晶血量 —— 归零方判负。
	# 那一轮的战斗胜负不参与（打赢一场不等于赢下整局）。
	var hp_a := int(ctx.get("hp_a", 0))
	var hp_b := int(ctx.get("hp_b", 0))
	var a_dead := hp_a <= 0
	var b_dead := hp_b <= 0
	if a_dead and b_dead:
		# 规则 3：同时归零 = 平局。PVE/Boss 两队各打各的怪、各自掉血时可能发生；
		# 中途 PVP 同场对打只有输方掉血，走不到这里。
		# 旧实现在这里用 `hp_a >= hp_b`（0 >= 0 恒真）判 A 胜，是纯粹的队伍偏置。
		return DRAW
	if a_dead:
		return TEAM_B
	if b_dead:
		return TEAM_A
	# 两队水晶都还在却判定对局结束：调用方的 run_over 判定有问题。
	# 不猜胜者 —— 猜错就是又一条隐性偏置。
	return DRAW

# 把 A/B 绝对归属换算成「某一队视角下赢了没」。DRAW 时两队都不算赢。
static func team_won_run(outcome: int, team: int) -> bool:
	return outcome == team

static func is_draw(outcome: int) -> bool:
	return outcome == DRAW
