extends RefCounted

# 棋子自己的成长（2026-10-07）：人王「活过一场」、老虎「每次升星」。
#
# 两种成长都记在**棋子格子**上，跟着那一枚棋子走（拖动、上下场、进待命区、合成、重连都带着）：
#   king_growth_stacks  人王活过的场数（层数）。封顶读 max_stacks：1~3 星 5 层、4 星 8 层。
#   king_mult           人王累计倍率：每活一场乘 (1 + 当时星级的成长率)，1~3 星 20%、4 星 30%。
#                       单独记这个数、不现算 (1+率)^层数：升四星之前长的那几层仍按 20% 算，
#                       不会被追溯成 30%（和以前「直接改 def」的结果一样）。老存档里人王的 def
#                       是已经乘过的、没有 king_mult（按 1.0 算），读进来不会重复乘。
#   tiger_stacks        老虎层数。出战宠物是老虎时，每发生一次升星（合成或升四星），当时手上
#                       （棋盘 + 待命区）**每一枚**一阶棋子 +1 层；之后才买的棋子从 0 层开始。
#                       合成出来的那一枚先继承被合掉的几枚里最高的层数，再吃这一次的 +1。
#
# 生命 / 攻击 / 防御 × king_mult × (1 + 老虎成长率 × tiger_stacks)，只这三项（同四星规格 §1：
# 攻速、暴伤直接乘 DPS，不跟着涨）。摆放界面详情（UnitDetailFormat）和战斗
# （BattleSimShared._fighter_from_cell，服务器与本机同一份）读的都是 stat_multiplier()。
#
# 信谁：备战经济还在影子期（客户端算钱，服务器本来就信客户端报的 1~3 星），层数也由客户端
# 按上面的规则算、随棋盘提交，服务器只截它自己核得了的上限：
#   - 结构上限（NetProtocol 收棋盘时，sanitize_into）：人王不超过封顶、不超过打完的回合数；
#     老虎只给一阶非佣兵；
#   - 账本上限（NetworkService 收棋盘时，clamp_tiger）：老虎层数不超过服务器账本数到的这个座位
#     的升星次数。客户端显示也按同一个次数截（联机时 GameState.tiger_starup_count 跟服务器那份），
#     所以摆放界面看到的就是实战用的数。
# ⚠️ 账本转权威（economy_ledger_authoritative）那天，层数要改成服务器按 uid 记在 roster 上。

const KING_SKILL := "unique_king_growth"
const KING_STACKS := "king_growth_stacks"
const KING_MULT := "king_mult"
const TIGER_STACKS := "tiger_stacks"
# 网络上来的老虎层数的结构上限，只防离谱数。真正的上限是服务器账本数到的升星次数。
const MAX_TIGER_STACKS := 100


static func _def(cell: Dictionary) -> Dictionary:
	var d: Variant = cell.get("def", {})
	return d if typeof(d) == TYPE_DICTIONARY else {}


static func is_king(cell: Dictionary) -> bool:
	return str(_def(cell).get("skill_id", "")) == KING_SKILL


# 老虎只加一阶、不是佣兵的棋子。阶级是购买阶级，升星不改它。
static func tiger_eligible(cell: Dictionary) -> bool:
	if bool(cell.get("is_mercenary", false)):
		return false
	var d := _def(cell)
	return int(d.get("tier", 0)) == 1 and not bool(d.get("is_mercenary", false))


static func tiger_stacks(cell: Dictionary) -> int:
	if not tiger_eligible(cell):
		return 0
	return clampi(int(cell.get(TIGER_STACKS, 0)), 0, MAX_TIGER_STACKS)


static func king_stacks(cell: Dictionary) -> int:
	return maxi(0, int(cell.get(KING_STACKS, 0))) if is_king(cell) else 0


static func king_mult(cell: Dictionary) -> float:
	if not is_king(cell):
		return 1.0
	var m := float(cell.get(KING_MULT, 1.0))
	return m if is_finite(m) and m >= 1.0 else 1.0


# 人王当前星级的封顶层数与每层成长率。两个字段都会被 star4 覆写，而格子上的 def 是没按星级
# 缩放的原表项 —— 一律经 UnitFactory.apply_star_stats 读（9.14 踩过：上限改了、倍率还读原表）。
static func king_cap(cell: Dictionary) -> int:
	return int(UnitFactory.apply_star_stats(_def(cell), int(cell.get("star", 1))).get("max_stacks", 0))


static func king_rate(cell: Dictionary) -> float:
	var effective := UnitFactory.apply_star_stats(_def(cell), int(cell.get("star", 1)))
	return maxf(0.0, float(effective.get("post_battle_all_stat_growth", 0.20)))


# 还能不能再长一层。cap ≤ 0 = 不封顶（数据表门禁 four_star_values_check 守着它不为 0）。
static func king_can_grow(cell: Dictionary) -> bool:
	if not is_king(cell):
		return false
	var cap := king_cap(cell)
	return cap <= 0 or king_stacks(cell) < cap


# 人王活过一场：层数 +1、倍率 ×(1 + 当前星级成长率)。到顶就不长。返回这次长没长。
static func grow_king(cell: Dictionary) -> bool:
	if not king_can_grow(cell):
		return false
	cell[KING_MULT] = king_mult(cell) * (1.0 + king_rate(cell))
	cell[KING_STACKS] = king_stacks(cell) + 1
	return true


# 生命 / 攻击 / 防御的成长总倍率。
#   tiger_rate：这枚棋子**主人**的老虎成长率（PetService.tier1_growth_rate；不是老虎就是 0）。
#   tiger_cap ：老虎层数上限 = 这个座位的升星次数；< 0 不截（战斗用的格子服务器已经截过）。
static func stat_multiplier(cell: Dictionary, tiger_rate: float, tiger_cap: int = -1) -> float:
	var stacks := tiger_stacks(cell)
	if tiger_cap >= 0:
		stacks = mini(stacks, tiger_cap)
	return king_mult(cell) * (1.0 + maxf(0.0, tiger_rate) * float(stacks))


# 把倍率乘到一份**已经按星级缩放过**的 def 上（只 hp / atk / def 三项）。
static func apply_to_def(d: Dictionary, mult: float) -> void:
	d["hp"] = maxi(1, int(round(float(d.get("hp", 1)) * mult)))
	d["atk"] = maxi(1, int(round(float(d.get("atk", 1)) * mult)))
	d["def"] = maxi(0, int(round(float(d.get("def", 0)) * mult)))


# 发生了一次升星（合成或升四星）：手上每一枚一阶棋子老虎 +1 层。
# owned = 棋盘 + 待命区。出战宠物是不是老虎由调用方判（GameState.record_tiger_starup）。
static func add_tiger_stack(owned: Array) -> void:
	for cell in owned:
		if typeof(cell) == TYPE_DICTIONARY and tiger_eligible(cell):
			(cell as Dictionary)[TIGER_STACKS] = mini(tiger_stacks(cell) + 1, MAX_TIGER_STACKS)


# 合成：留下的那一枚（keeper）继承被合掉的几枚的成长。要在 keeper 升星、记老虎 +1 **之前**调。
#   - 老虎：取几枚里最高的层数（2026-10-07 定）；
#   - 人王：取成长最多的那一份，层数和倍率一起带走。只带倍率不带层数，就能把长满的人王和新买的
#     合在一起、从 0 层再长一轮 —— 绕过封顶。老存档的成长是乘在 def 上的，所以「最多」按
#     生命 × 倍率比，def 也一起带走（新局里同星人王的 def 都一样，带不带没区别）。
static func inherit_on_merge(keeper: Dictionary, merged: Array) -> void:
	var tiger := tiger_stacks(keeper)
	var best: Dictionary = {}
	var best_score := -1.0
	for raw in [keeper] + merged:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var cell: Dictionary = raw
		tiger = maxi(tiger, tiger_stacks(cell))
		if not is_king(cell):
			continue
		var score := float(_def(cell).get("hp", 0)) * king_mult(cell)
		if score > best_score:
			best_score = score
			best = cell
	if tiger > 0 and tiger_eligible(keeper):
		keeper[TIGER_STACKS] = tiger
	if best.is_empty() or is_same(best, keeper):
		return
	keeper["def"] = _def(best).duplicate(true)
	keeper[KING_STACKS] = king_stacks(best)
	keeper[KING_MULT] = king_mult(best)


# --- 联网：随棋盘提交、服务器截上限 ---------------------------------------------

# 随棋盘一起提交的成长字段（NetProtocol._minimal_slots）。只带非零的。
static func wire_fields(cell: Dictionary) -> Dictionary:
	var out := {}
	var tiger := tiger_stacks(cell)
	if tiger > 0:
		out[TIGER_STACKS] = tiger
	var king := king_stacks(cell)
	if king > 0:
		out[KING_STACKS] = king
		out[KING_MULT] = king_mult(cell)
	return out


# 收棋盘：把网络上来的成长字段截到结构上限，写进 clean（已经换成可信 def 的格子）。
#   - 老虎层数：只给一阶非佣兵，0 ~ MAX_TIGER_STACKS（账本上限由 clamp_tiger 再截）；
#   - 人王层数：≤ 本星级封顶，且 ≤ max_battles（已经打完的回合数；< 0 = 不截）；
#   - 人王倍率：1 ~ (1 + 本星级成长率)^层数 —— 成长率随星级只升不降，任何合法的历史都不会超过它。
static func sanitize_into(clean: Dictionary, raw: Dictionary, max_battles: int = -1) -> void:
	clean.erase(TIGER_STACKS)
	clean.erase(KING_STACKS)
	clean.erase(KING_MULT)
	var tiger := _wire_int(raw.get(TIGER_STACKS, 0))
	if tiger > 0 and tiger_eligible(clean):
		clean[TIGER_STACKS] = mini(tiger, MAX_TIGER_STACKS)
	if not is_king(clean):
		return
	var king := _wire_int(raw.get(KING_STACKS, 0))
	var cap := king_cap(clean)
	if cap > 0:
		king = mini(king, cap)
	if max_battles >= 0:
		king = mini(king, max_battles)
	if king <= 0:
		return
	clean[KING_STACKS] = king
	clean[KING_MULT] = clampf(_wire_float(raw.get(KING_MULT, 1.0)), 1.0, pow(1.0 + king_rate(clean), king))


# 账本上限：老虎层数不超过服务器账本数到的这个座位的升星次数。
static func clamp_tiger(cell: Dictionary, starups: int) -> void:
	var tiger := mini(tiger_stacks(cell), maxi(0, starups))
	if tiger > 0:
		cell[TIGER_STACKS] = tiger
	else:
		cell.erase(TIGER_STACKS)


static func _wire_int(value: Variant) -> int:
	if typeof(value) == TYPE_INT:
		return clampi(int(value), 0, 1000000)
	if typeof(value) == TYPE_FLOAT and is_finite(float(value)):
		return int(clampf(float(value), 0.0, 1000000.0))
	return 0


static func _wire_float(value: Variant) -> float:
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return 1.0
	var f := float(value)
	return f if is_finite(f) else 1.0
