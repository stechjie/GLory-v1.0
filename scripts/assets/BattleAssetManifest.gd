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
const OGA_CHESS := preload("res://effects/vfx3d/units/OgaChessVFXCatalog.gd")
const OGA_SKILLS := preload("res://effects/vfx3d/units/OgaSkillVFXCatalog.gd")
const DOOM_LINK := preload("res://effects/vfx3d/units/VFXDoomBloodLink3D.gd")

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
	# The roster includes units summoned later, not just the first visible frame.
	for uid in replay.get("roster", {}):
		var r: Dictionary = replay["roster"][uid]
		for path in fighter_texture_paths(str(r.get("id", "")), r.get("def", {})):
			_append_texture_path(str(path), out)
	return out

# Keep the direct Battle entry and PrepScreen resource stage on the same list.
# These catalogs are the actual playback routes, including projectile impacts
# and delayed nested skill layers. Loading only SkillVFXConfig leaves OGA cold.
static func fighter_texture_paths(unit_id: String, unit_def: Dictionary = {}) -> Array:
	var out: Array = []
	if unit_id.is_empty():
		return out
	for cfg in SkillVFXConfig.get_textures(unit_id):
		_append_texture_path(str(cfg.get("path", "")), out)
	_append_texture_spec(OGA_CHESS.projectile_for(unit_id), out)
	_append_texture_spec(OGA_CHESS.melee_for(unit_id, str(unit_def.get("race", ""))), out)
	var skill := str(unit_def.get("skill_id", ""))
	_append_texture_spec(OGA_CHESS.formal_skill_for(skill), out)
	_append_texture_spec(OGA_SKILLS.skill_for(skill), out)
	_append_texture_spec(OGA_SKILLS.melee_for(skill), out)
	if skill == "random_attribute_bolt":
		# This fighter may choose any of these elements during the fixed replay.
		for element in ["fire", "ice", "thunder", "poison", "arcane"]:
			_append_texture_spec(OGA_SKILLS.projectile_for_element(element), out)
	elif skill == "silence_bolt":
		_append_texture_spec(OGA_SKILLS.projectile_for_element("silence"), out)
	elif skill == "shared_hp_link":
		# The current route is Doom's authored chain, not the retired OGA link.
		for path in [DOOM_LINK.CHAIN_TEXTURE, DOOM_LINK.KNOT_TEXTURE, DOOM_LINK.TEAR_TEXTURE]:
			_append_texture_path(path, out)
	return out

static func _append_texture_spec(value: Variant, out: Array) -> void:
	if value is Dictionary:
		for child in value.values():
			_append_texture_spec(child, out)
	elif value is Array:
		for child in value:
			_append_texture_spec(child, out)
	elif value is String and value.begins_with("res://"):
		_append_texture_path(value, out)

static func _append_texture_path(path: String, out: Array) -> void:
	if not path.is_empty() and not out.has(path):
		out.append(path)

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
