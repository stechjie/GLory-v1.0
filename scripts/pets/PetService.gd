class_name PetService
extends RefCounted
# 宠物纯逻辑（静态，仿 TreasureService/EconomyService）。
# 全程数据驱动：只认 effect 枚举字符串 + value，宠物数量随 pets.json 增减，无需改此文件。
# 现有效果枚举：
#   self_hp_pct   —— 己方棋子开局最大生命 ×(1+value)   （蘑菇）
#   self_atk_pct  —— 己方棋子开局攻击   ×(1+value)     （兔子）
#   interest_pct  —— 金币利息率 +value                  （猫）
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

# ---- 挂钩点助手：给定「出战宠物 id」，返回对应加成 ----

# 猫：利息率加成（叠加到基础 0.05 上）。
static func interest_rate_bonus(pet_id: String) -> float:
	var e := effect_of(pet_id)
	return float(e.get("value", 0.0)) if str(e.get("effect", "")) == "interest_pct" else 0.0

# 蘑菇：开局最大生命乘数（1.0 = 无加成）。
static func opening_hp_mult(pet_id: String) -> float:
	var e := effect_of(pet_id)
	return 1.0 + float(e.get("value", 0.0)) if str(e.get("effect", "")) == "self_hp_pct" else 1.0

# 鸭子：开局攻击乘数（1.0 = 无加成）。
static func opening_atk_mult(pet_id: String) -> float:
	var e := effect_of(pet_id)
	return 1.0 + float(e.get("value", 0.0)) if str(e.get("effect", "")) == "self_atk_pct" else 1.0
