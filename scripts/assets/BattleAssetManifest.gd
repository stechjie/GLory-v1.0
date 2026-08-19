class_name BattleAssetManifest
extends RefCounted

# 算「本局 / 本轮要哪些资源」的清单。只算路径，不负责加载。
#
# 分两段是因为 shared_seed 到达有先后：
#   seed 无关：外部 VFX、竞技场、商店池全部候选 —— 进大厅立刻能算
#   seed 相关：整局怪物 / Boss 名单 —— 服务器下发 seed 之后才算得出
#
# 怪物 / Boss 只依赖 shared_seed + 回合号（BattleSimShared._round_pick_index），
# 所以 seed 一到，整局名单就是确定的，可以提前几轮加载。

const LOOKAHEAD_ROUNDS := 3

# --- seed 无关：进大厅就能开始加载 ---------------------------------------------

# 正式战斗真正会用到的外部 VFX。
# 注册表里有 17 个，但实测只有这 8 类出现在正式战斗调用点上
# （BossSkillVFXComposer3D / UnitSkillVFXComposer3D）；
# 其余 9 个只被 VFXStageComposerV2 用，而那条路只有 ModelBattlePreview（debug）走。
const BATTLE_EXTERNAL_VFX := [
	"area", "beam", "slash", "projectile", "loot",          # VFXBinbunReference3D
	"starter_explosion", "starter_muzzle", "starter_hit_02", # VFXV2ExternalReference3D
]

static func seed_independent_paths() -> Array[String]:
	var out: Array[String] = []
	var binbun: Dictionary = VFXBinbunReference3D.SCENES
	var starter: Dictionary = VFXV2ExternalReference3D.SCENES
	for kind in BATTLE_EXTERNAL_VFX:
		for table in [binbun, starter]:
			var p := str(table.get(kind, ""))
			if not p.is_empty() and not out.has(p):
				out.append(p)
	return out

# 商店能刷出来的全部单位模型。玩家买什么开局不知道，但**候选池是固定的**，
# 所以整池预加载就不会在落子那一刻现加载（实测那一下冻结 3.3 秒）。
static func shop_pool_paths() -> Array[String]:
	var out: Array[String] = []
	for table_name in ["race_units", "mercenaries"]:
		var t: Dictionary = DataRegistry.get_table(table_name)
		var key := "units" if table_name == "race_units" else "mercenaries"
		for def in t.get(key, []):
			_append_model_paths(def as Dictionary, out)
	return out

# --- seed 相关：服务器下发 seed 之后 -------------------------------------------

static func has_seed() -> bool:
	return NetworkService.shared_seed != 0

# 从 from_round 起 count 个回合的敌方模型。PVP / final 回合返回空
# （对手棋盘取决于他买了什么，开局无法预知）。
static func rounds_enemy_paths(from_round: int, count: int) -> Dictionary:
	var out: Dictionary = {}
	for n in range(from_round, from_round + count):
		var paths := BattleSimShared.round_enemy_model_paths(n)
		if not paths.is_empty():
			out[n] = paths
	return out

# --- 本场 replay 的确切阵容（读条兜底用）---------------------------------------

# 服务器已经把整场算完发过来了，roster 就是确切的出场名单，不用猜。
static func replay_paths(replay: Dictionary) -> Array[String]:
	var out: Array[String] = []
	if typeof(replay) != TYPE_DICTIONARY:
		return out
	for uid in replay.get("roster", {}):
		var r: Dictionary = replay["roster"][uid]
		_append_model_paths(r.get("def", {}), out)
	return out

static func replay_texture_paths(replay: Dictionary) -> Array:
	var out: Array = []
	if typeof(replay) != TYPE_DICTIONARY:
		return out
	for uid in replay.get("roster", {}):
		var r: Dictionary = replay["roster"][uid]
		for cfg in SkillVFXConfig.get_textures(str(r.get("id", ""))):
			out.append(str(cfg.get("path", "")))
	return out

static func _append_model_paths(def: Dictionary, out: Array[String]) -> void:
	for key in ["model", "model_idle_animation"]:
		var p := str(def.get(key, ""))
		if not p.is_empty() and not out.has(p):
			out.append(p)
	var variants_value = def.get("model_by_element", {})
	if typeof(variants_value) == TYPE_DICTIONARY:
		for value in (variants_value as Dictionary).values():
			var variant_path := str(value)
			if not variant_path.is_empty() and not out.has(variant_path):
				out.append(variant_path)
