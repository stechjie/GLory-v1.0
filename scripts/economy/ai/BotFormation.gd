extends RefCounted
## AI 站位（2026-11-07）。输入已经选好的上阵棋子，输出每个棋子放哪一格。
##
## 棋盘 4×4，下标 = 行 × 4 + 列，第 0 行离对手最近（BattleSimShared.board_cell_pos）。
## 佣兵不归这里管：战斗开始时它们自动填空格，后排、中间两列优先（free_board_cells）。
##
## 档位：
##   basic   近战 / 嘲讽进前两行（血厚的站中间），远程进后两行（攻击高的站中间）—— 11-07 前的做法
##   role    坦克前排中间，近战输出前排两侧，刺客后排两角，远程输出最后一排中间，辅助第三排中间
## flip_on_loss 的档位（普通以上）上一场 PvP 输了就左右翻转一次站位，换一种对位。
##
## 11-08 删了「counter 看上一场对手站位」和配套的对手阵容摘要：对战台量过没有可测的好处。
##
## 纯函数：同样的输入永远同样的站位（LiveBotEconomy.mirror 回写站位、真人收回座位时要一致）。

const Eval := preload("res://scripts/economy/ai/BotEval.gd")

const FRONT_SLOTS := [1, 2, 0, 3, 5, 6, 4, 7]      # 第 0、1 行，中间优先
const BACK_SLOTS := [13, 14, 12, 15, 9, 10, 8, 11]  # 第 3、2 行，中间优先
const SUPPORT_SLOTS := [9, 10, 13, 14, 8, 11, 12, 15]
const ASSASSIN_SLOTS := [12, 15, 8, 11, 13, 14, 9, 10]

const TANK_SKILLS := ["guardian_shield_taunt", "block_guard", "poison_reflect_armor_stack", "left_neighbor_sacrifice"]
const SUPPORT_SKILLS := ["lowest_ally_heal", "nearest_ally_bless", "nearby_ally_heal_buff", "every_fifth_group_heal",
	"random_ally_damage_reduction", "random_ally_buff", "team_random_stack"]
const ASSASSIN_SKILLS := ["blink_low_def_backline"]


static func role_of(definition: Dictionary) -> String:
	var skill := str(definition.get("skill_id", ""))
	if ASSASSIN_SKILLS.has(skill):
		return "assassin"
	if SUPPORT_SKILLS.has(skill):
		return "support"
	if float(definition.get("range", 1)) > 1.5:
		return "ranged"
	if TANK_SKILLS.has(skill):
		return "tank"
	var ehp := float(definition.get("hp", 1)) * (1.0 + float(definition.get("def", 0)) / 100.0)
	var dps := float(definition.get("atk", 1)) * float(definition.get("attack_speed", 1.0))
	return "tank" if ehp >= dps * 22.0 else "melee"


# units：上阵的 [{def, star, id}]。返回 [[unit, cell], ...]。
static func arrange(units: Array, mode: String, flip: bool = false) -> Array:
	var out: Array = _role(units) if mode == "role" else _basic(units)
	if flip:
		for pair in out:
			var cell := int(pair[1])
			pair[1] = cell - cell % GameConstants.BOARD_COLUMNS + (GameConstants.BOARD_COLUMNS - 1 - cell % GameConstants.BOARD_COLUMNS)
	return out


static func _basic(units: Array) -> Array:
	var front: Array = []
	var back: Array = []
	for u in units:
		var d: Dictionary = u.def
		if float(d.get("range", 1)) <= 1.5 or str(d.get("skill_id", "")) == "guardian_shield_taunt":
			front.append(u)
		else:
			back.append(u)
	front.sort_custom(func(a, b): return _stat(a, "hp") > _stat(b, "hp") or (_stat(a, "hp") == _stat(b, "hp") and str(a.id) < str(b.id)))
	back.sort_custom(func(a, b): return _stat(a, "atk") > _stat(b, "atk") or (_stat(a, "atk") == _stat(b, "atk") and str(a.id) < str(b.id)))
	var out: Array = []
	var used := {}
	_place_unique(out, used, front, FRONT_SLOTS)
	_place_unique(out, used, back, BACK_SLOTS)
	return out


static func _role(units: Array) -> Array:
	var groups := {"tank": [], "melee": [], "assassin": [], "ranged": [], "support": []}
	for u in units:
		(groups[role_of(u.def)] as Array).append(u)
	for key in groups:
		(groups[key] as Array).sort_custom(func(a, b):
			var pa := Eval.unit_power(a.def, int(a.star))
			var pb := Eval.unit_power(b.def, int(b.star))
			return pa > pb or (pa == pb and str(a.id) < str(b.id)))
	# 坦克按有效血量排（最肉的站中间），其余按估值排。
	(groups.tank as Array).sort_custom(func(a, b): return _ehp(a) > _ehp(b) or (_ehp(a) == _ehp(b) and str(a.id) < str(b.id)))
	var used := {}
	var out: Array = []
	var front_units: Array = (groups.tank as Array) + (groups.melee as Array)
	# 没有近战时前排空着会让远程直接挨打：拿最肉的远程顶上去。
	if front_units.is_empty() and not (groups.ranged as Array).is_empty():
		var ranged: Array = groups.ranged
		ranged.sort_custom(func(a, b): return _ehp(a) > _ehp(b) or (_ehp(a) == _ehp(b) and str(a.id) < str(b.id)))
		front_units.append(ranged.pop_front())
	_place_unique(out, used, front_units, FRONT_SLOTS)
	_place_unique(out, used, groups.assassin, ASSASSIN_SLOTS)
	_place_unique(out, used, groups.ranged, BACK_SLOTS)
	_place_unique(out, used, groups.support, SUPPORT_SLOTS)
	return out


static func _place_unique(out: Array, used: Dictionary, units: Array, order: Array) -> void:
	for u in units:
		var cell := -1
		for c in order:
			if not used.has(int(c)):
				cell = int(c)
				break
		if cell < 0:
			for c in GameConstants.CELL_COUNT:
				if not used.has(c):
					cell = c
					break
		if cell < 0:
			return
		used[cell] = true
		out.append([u, cell])


static func _stat(u: Dictionary, key: String) -> float:
	return float((u.def as Dictionary).get(key, 1)) * GameState.star_stat_multiplier(int(u.star), u.def)


static func _ehp(u: Dictionary) -> float:
	return _stat(u, "hp") * (1.0 + _stat(u, "def") / 100.0)
