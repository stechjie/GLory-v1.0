extends Node
const Harness = preload("res://tools/CheckHarness.gd")
const Format = preload("res://scripts/ui/UnitDetailFormat.gd")
class ArenaProbe:
	extends "res://scenes/battle/BattleArena.gd"
	func _ready() -> void:
		pass

func _ready() -> void:
	var h = Harness.new("bug0911")
	var saved_flags := ServerFlags._values.duplicate(true)
	var saved_round := GameState.round_index
	GameState.round_index = GameState.FINAL_ROUND
	var arena := ArenaProbe.new()
	var wrap := Control.new()
	arena._add_battle_3v3_dividers(wrap)
	h.expect(wrap.get_child_count() == 0, "final_dividers", "最终回合不创建分割线")
	wrap.free()
	arena.free()
	GameState.round_index = saved_round
	ServerFlags.get_bool("carrot_economy_enabled")
	ServerFlags._values["economy_ledger_enabled"] = false
	ServerFlags._values["economy_ledger_authoritative"] = false
	ServerFlags._values["carrot_economy_enabled"] = true
	h.expect(NetworkService._economy_action_enabled("shop_refresh"), "refresh_enabled", "仅萝卜账本开启时刷新仍可执行")
	var room: Dictionary = NetworkService._new_room()
	room["state"] = NetworkService.ROOM_PREP
	room["round_index"] = 2
	var prep: Dictionary = NetworkService._room_prep(room, 0)
	var previous := ""
	for i in 3:
		var receipt := NetworkService._room_apply_economy(room, 0, "shop_refresh", {"gold": 1000})
		h.expect(receipt.get("ok", false), "refresh_ok", "刷新受理")
		var result: Dictionary = receipt.get("result", {})
		var id := str(result.get("offer_id", ""))
		h.expect(not id.is_empty() and id != previous and not result.get("offers", []).is_empty(), "new_offer", "连续刷新生成新批次而非复用旧缓存")
		previous = id
	var a: Dictionary = NetworkService._room_team_stones(room, 0)
	a["sky"] = 2
	h.expect(NetworkService._build_economy_state(room, 1).get("team_upgrade_stones", {}).get("sky", 0) == 2, "ally_stones", "队友快照读取同一升级石仓库")
	h.expect(NetworkService._build_economy_state(room, 3).get("team_upgrade_stones", {}).get("sky", 0) == 0, "enemy_stones", "敌方仓库独立")
	for d in DataRegistry.get_table("race_units").get("units", []):
		if d.id == "dark_dragon":
			h.expect(Format.format_skill_detail(d).contains("8.0"), "dragon_cd", "黑洞显示8秒冷却")
		if d.id == "human_death_servant":
			h.expect(d.atk == 1, "servant_atk", "死侍基础攻击显示1")
			var stale: Dictionary = d.duplicate(true)
			stale["atk"] = 0
			h.expect(Format.format_unit_def(stale).contains("攻击：1 "), "stale_servant", "旧商品/存档攻击0时详情与战斗最低攻击1一致")
			h.expect(stale.atk == 0, "immutable_def", "格式化不修改输入快照")
			for star in range(1, GameConstants.MAX_STAR + 1):
				for base in [d, stale]:
					h.expect(UnitFactory.apply_star_stats(base, star).atk == 1, "fixed_atk", "死侍各星级实际基础攻击固定1")
					h.expect(Format.format_unit_def(base, star).contains("攻击：1 "), "fixed_atk_detail", "死侍各星级详情攻击固定1")
				var ordinary: Dictionary = {"id": "fixture", "atk": 10}
				h.expect(UnitFactory.apply_star_stats(ordinary, star).atk == int(round(10 * GameState.star_stat_multiplier(star, ordinary))), "normal_scaling", "其他棋子攻击仍随升星增长")

		if d.id == "human_merchant":
			h.expect(Format.format_skill_detail(d).contains("4星+40"), "merchant", "商人四星收入说明")
	_check_upgrade_shadow(h)
	ServerFlags._values = saved_flags
	if "--review" in OS.get_cmdline_user_args():
		var rect := TextureRect.new()
		rect.texture = load("res://assets/ui/room_v2/chat.png")
		var material := ShaderMaterial.new()
		material.shader = load("res://scenes/menu/chat_no_badge.gdshader")
		rect.material = material
		add_child(rect)
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://work/bug0911-01/chat-preview.png")
	h.finish(get_tree())

func _check_upgrade_shadow(h) -> void:
	var unit_id := ""
	for d in DataRegistry.get_table("race_units").get("units", []):
		if str(d.get("name", "")) == "毒灵":
			unit_id = str(d.id)
	h.expect(not unit_id.is_empty(), "poison_fixture", "找到截图中的毒灵")
	for authoritative in [false, true]:
		ServerFlags._values["economy_ledger_enabled"] = true
		ServerFlags._values["economy_ledger_authoritative"] = authoritative
		var room: Dictionary = NetworkService._new_room()
		room["state"] = NetworkService.ROOM_PREP
		room["round_index"] = 17
		var prep: Dictionary = NetworkService._room_prep(room, 0)
		prep.gold = 1295
		prep.roster["poison"] = {"unit_id": unit_id, "star": 1, "kind": "unit", "cost_basis": 20}
		var stones: Dictionary = NetworkService._room_team_stones(room, 0)
		stones.ren = 2
		var payload := {"uid": "poison", "unit_id": unit_id, "star": 3, "gold": 1295}
		var receipt: Dictionary = NetworkService._room_apply_economy(room, 0, "use_upgrade_stone", payload)
		if authoritative:
			h.expect(receipt.get("error") == "not_three_star" and prep.gold == 1295 and stones.ren == 2, "authority_reject", "权威模式拒绝伪报三星且不扣费")
			prep.roster.poison.star = 3
			receipt = NetworkService._room_apply_economy(room, 0, "use_upgrade_stone", payload)
		h.expect(receipt.get("ok", false) and prep.gold == 795 and stones.ren == 1 and prep.roster.poison.star == 4, "upgrade_once", "合法升级扣500金币和1颗石并登记四星")
		var retry: Dictionary = NetworkService._room_apply_economy(room, 0, "use_upgrade_stone", payload)
		h.expect(retry.get("error") == "already_four_star" and prep.gold == 795 and stones.ren == 1, "no_double_charge", "重复升级不会再次扣费")
		if not authoritative:
			payload.uid = "other"
			payload.star = 2
			retry = NetworkService._room_apply_economy(room, 0, "use_upgrade_stone", payload)
			h.expect(retry.get("error") == "not_three_star" and prep.gold == 795 and stones.ren == 1, "shadow_bad_star", "影子模式拒绝明确提交的非三星且回滚余额")
