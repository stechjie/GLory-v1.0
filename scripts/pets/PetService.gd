class_name PetService
extends RefCounted
# 宠物纯逻辑（静态，仿 TreasureService/EconomyService）。
# 全程数据驱动：只认 effect 枚举字符串 + value，宠物数量随 pets.json 增减，无需改此文件。
# 现有效果枚举：
#   self_hp_pct   —— 己方棋子开局最大生命 ×(1+value)   （蘑菇）
#   self_atk_pct  —— 己方棋子开局攻击   ×(1+value)     （兔子）
#   interest_pct  —— 金币利息率 +value                  （猫）
#   carrot_harvest_capacity_pct —— 萝卜采集和营地容量 +value（松鼠）
#   tier1_upgrade_growth —— 每次升星，一阶棋子成长 +value  （老虎）
#   first_buy_copy —— 每回合买的第一个棋子有几率免费多一张 1 星（猴子）。
#                     value = 起始成功率，value_per_pvp_round = 每打完一个 PvP 回合加多少，value_max = 封顶
# 新增效果类型时：在此加一个对应查询助手 + 在其挂钩点接入即可，宠物本身不用碰代码。

static func all_pets() -> Array:
	return DataRegistry.get_table("pets").get("pets", [])

static func starter_ids() -> Array:
	return DataRegistry.get_table("pets").get("starter_ids", [])

static func is_starter(pet_id: String) -> bool:
	return pet_id in starter_ids()

static func pet_by_id(pet_id: String) -> Dictionary:
	if pet_id.is_empty():
		return {}
	for p in all_pets():
		if str((p as Dictionary).get("id", "")) == pet_id:
			return p
	return {}

# 单一效果查询：返回 {"effect": String, "value": float}，无宠物/无效果时 effect 为空。
static func effect_of(pet_id: String) -> Dictionary:
	var p := pet_by_id(pet_id)
	if p.is_empty():
		return {"effect": "", "value": 0.0}
	return {"effect": str(p.get("effect", "")), "value": float(p.get("value", 0.0))}

# ---- 模型助手（主菜单草地 / 宠物界面展示用）----

static func model_path(pet_id: String) -> String:
	return str(pet_by_id(pet_id).get("model", ""))

static func model_scale(pet_id: String) -> float:
	return float(pet_by_id(pet_id).get("model_scale", 1.0))

static func model_y(pet_id: String) -> float:
	return float(pet_by_id(pet_id).get("model_y", 0.0))

# ---- 显示助手（UI 用，走本地化）----

static func display_name(pet_id: String) -> String:
	if pet_id.is_empty():
		return TranslationServer.translate("pet_none")
	var key := "pet_name_" + pet_id
	var t := TranslationServer.translate(key)
	# 未登记本地化名时回落到数据表里的原始名。
	if t == key:
		return str(pet_by_id(pet_id).get("name", pet_id))
	return t

static func effect_text(pet_id: String) -> String:
	if LocaleManager.get_locale() == "zh":
		var approved := FinalStatusCatalog.pet_summary_cn(pet_id)
		if not approved.is_empty():
			return approved
	var e := effect_of(pet_id)
	var effect := str(e.get("effect", ""))
	if effect.is_empty():
		return ""
	var pct := int(round(float(e.get("value", 0.0)) * 100.0))
	var key := "pet_effect_" + effect
	var fmt := TranslationServer.translate(key)
	if fmt == key or not fmt.contains("%d"):
		return fmt
	return fmt % pct

static func skill_detail_text(pet_id: String) -> String:
	if LocaleManager.get_locale() == "zh":
		var approved := FinalStatusCatalog.pet_detail_cn(pet_id)
		if not approved.is_empty():
			return approved
	var key := "pet_skill_detail_" + pet_id
	var detail := TranslationServer.translate(key)
	return "" if detail == key else detail

# ---- 挂钩点助手：给定「出战宠物 id」，返回对应加成 ----

# 猫：利息率加成（叠加到基础 0.05 上）。
static func interest_rate_bonus(pet_id: String) -> float:
	var e := effect_of(pet_id)
	return float(e.get("value", 0.0)) if str(e.get("effect", "")) == "interest_pct" else 0.0

# 松鼠：萝卜采集和容量加成。
static func carrot_bonus_rate(pet_id: String) -> float:
	var e := effect_of(pet_id)
	return float(e.get("value", 0.0)) if str(e.get("effect", "")) == "carrot_harvest_capacity_pct" else 0.0

# 老虎：每次升星带给一阶棋子的成长率。
static func tier1_growth_rate(pet_id: String) -> float:
	var e := effect_of(pet_id)
	return float(e.get("value", 0.0)) if str(e.get("effect", "")) == "tier1_upgrade_growth" else 0.0

# 猴子：每回合买的第一个棋子有几率免费多复制一张（1 星）。这里只答「这只宠物有没有这个效果」，
# 成功率见下面的 first_buy_copy_rate。规则与挂钩点见 EconomyLedger._pet_first_buy_copy
# （服务器账本）、PrepBoardController._plan_pet_first_buy_copy（客户端）、BotPlayer._pet_first_buy_copy（AI 托管）。
static func copies_first_buy(pet_id: String) -> bool:
	return str(effect_of(pet_id).get("effect", "")) == "first_buy_copy"

# 猴子：这一回合「第一个买的棋子」复制成功的概率（0..1；不是猴子返回 0）。
#
# 用户 11-26 定：起始 25%，每打完一个 PvP 回合 +25%，最高 100%。
#   21 回合赛程（PvP 在 6 / 12 / 18）：1–6 回合 25%，7–12 回合 50%，13–18 回合 75%，19 回合起 100%。
#   13 回合赛程（PvP 在 6 / 11）：    1–6 回合 25%，7–11 回合 50%，12–13 回合 75%（到不了 100%）。
# 三个数都在 pets.json（value / value_per_pvp_round / value_max）；「打完几个 PvP 回合」按赛程表数
# （RoundService.pvp_rounds_before），以后改 PvP 回合，这里自动跟着。
#
# 🔴 这只是**概率**。掷骰一回合只掷一次、而且只由一方掷：联机由战斗服务器掷好随 room_state 下发
# （NetworkService._room_pet_copy_ok_round），单机由本机掷（PrepBoardController._pet_copy_roll_ok）。
# 客户端和服务器各掷各的话，两边账本会对不上（影子比对日志多出差异）。
static func first_buy_copy_rate(pet_id: String, round_index: int, final_round: int = 21) -> float:
	var pet := pet_by_id(pet_id)
	if str(pet.get("effect", "")) != "first_buy_copy":
		return 0.0
	var passed := RoundService.pvp_rounds_before(round_index, final_round)
	var rate := float(pet.get("value", 0.0)) + float(pet.get("value_per_pvp_round", 0.0)) * float(passed)
	return clampf(rate, 0.0, clampf(float(pet.get("value_max", 1.0)), 0.0, 1.0))

# 蘑菇：开局最大生命乘数（1.0 = 无加成）。
static func opening_hp_mult(pet_id: String) -> float:
	var e := effect_of(pet_id)
	return 1.0 + float(e.get("value", 0.0)) if str(e.get("effect", "")) == "self_hp_pct" else 1.0

# 鸭子：开局攻击乘数（1.0 = 无加成）。
static func opening_atk_mult(pet_id: String) -> float:
	var e := effect_of(pet_id)
	return 1.0 + float(e.get("value", 0.0)) if str(e.get("effect", "")) == "self_atk_pct" else 1.0
