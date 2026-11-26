extends SceneTree

# 11.26 死侍开场誓约特效检查。
# Run with: Godot --headless --path . --script res://tools/death_servant_vfx_check.gd
#
# 走生产入口 BattleVfx._refresh_battle_vfx 的播种帧（_play_opening_unit_vfx）：
#   · 绑到人 + 两个友军吃到光环 → 脚下大法阵、身上盾环、每个友军一组徽记、被绑者血誓印记；
#   · 没绑到人（死侍站最后一排）→ 法阵和盾环照播，但没有血誓印记；
#   · 敌方棋子、别的棋盘（owner_slot 不同）的友军不亮徽记。
# 只判「生成了哪些层」，好不好看要进游戏看。

const Harness := preload("res://tools/CheckHarness.gd")

var h := Harness.new("death_servant_vfx")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	for service_name in ["NetworkService", "RealtimeService", "AnalyticsService", "ChatService", "AnnouncementService", "MailService"]:
		var service := root.get_node_or_null(service_name)
		if service != null:
			service.set_process(false)
	root.get_node("DataRegistry").call("load_all")
	var budget: Script = load("res://effects/vfx3d/core/VFXQualityBudget.gd")
	budget.set("tier", 1)

	var bound := _battle()
	_seed(bound.battle, _state(true))
	# 各层带 0.1~0.6 秒的错开延迟，延迟结束才命名；等到全部亮起、最早的还没消失再数。
	await create_timer(0.8).timeout
	var counts := _layer_counts(bound.route)
	h.expect(int(counts.get("ServantOath_Field", 0)) == 1, "oath_field", "死侍脚下铺一片誓约法阵（实际 %s）" % str(counts))
	h.expect(int(counts.get("ServantOath_Crown", 0)) == 1, "oath_crown", "死侍身上一圈盾环")
	h.expect(int(counts.get("ServantOath_AllyMark", 0)) == 2 and int(counts.get("ServantOath_AllyShield", 0)) == 2,
		"oath_allies", "只有吃到光环的 2 个同棋盘友军亮徽记（实际 %s）" % str(counts))
	h.expect(int(counts.get("ServantOath_BoundSeal", 0)) == 1, "oath_bound_seal", "被绑者身上有血誓印记")
	bound.battle.queue_free()
	await process_frame

	var unbound := _battle()
	_seed(unbound.battle, _state(false))
	await create_timer(0.8).timeout
	counts = _layer_counts(unbound.route)
	h.expect(int(counts.get("ServantOath_Field", 0)) == 1 and int(counts.get("ServantOath_Crown", 0)) == 1,
		"oath_without_bind", "没绑到人时法阵和盾环照播（实际 %s）" % str(counts))
	h.expect(int(counts.get("ServantOath_BoundSeal", 0)) == 0, "no_seal_without_bind", "没绑到人就没有血誓印记")
	unbound.battle.queue_free()
	await process_frame
	h.finish(self)


func _fighter(uid: String, unit_id: String, team: String, pos: Vector2, owner_slot: int, statuses: Dictionary, skill_id := "") -> Dictionary:
	return {"uid": uid, "id": unit_id, "name": unit_id, "team": team, "lane": 0, "star": 1, "max_hp": 1000, "hp": 1000,
		"alive": true, "pos": pos, "attack_count": 0, "skill_ready": 0.0, "shield": 0, "skill_stacks": 0,
		"owner_slot": owner_slot, "statuses": statuses, "def": {"id": unit_id, "skill_id": skill_id, "race": "human", "range": 1},
		"range_px": 72.0, "vfx_attack_target_uid": "", "vfx_skill_target_uid": ""}


func _state(bind: bool) -> Dictionary:
	var aura := {"defense_flat_up": {"remaining": 5.0, "amount": 10}, "mres_flat_up": {"remaining": 5.0, "amount": 10}}
	var servant := _fighter("p_servant", "human_death_servant", "player", Vector2(300, 260), 0, {}, "left_neighbor_sacrifice")
	if bind:
		servant["vfx_skill_target_uid"] = "p_back"
	var state := {"player": [
			servant,
			_fighter("p_back", "human_archer", "player", Vector2(228, 260), 0, aura.duplicate(true)),
			_fighter("p_side", "human_mage", "player", Vector2(300, 332), 0, aura.duplicate(true)),
			# 没吃到光环的同棋盘友军、别的棋盘上带同样状态的队友：都不该亮。
			_fighter("p_far", "human_militia", "player", Vector2(120, 100), 0, {}),
			_fighter("p_other_board", "human_cleric", "player", Vector2(300, 188), 1, aura.duplicate(true)),
		], "enemy": [
			_fighter("e_one", "dark_imp", "enemy", Vector2(700, 260), 3, aura.duplicate(true)),
		], "visual_events": [], "elapsed": 0.0}
	return state


func _battle() -> Dictionary:
	var battle: Control = (load("res://scenes/battle/BattleVfx.gd") as Script).new()
	root.add_child(battle)
	var arena := Control.new()
	arena.size = Vector2(1000.0, 520.0)
	battle.add_child(arena)
	battle.set("_arena", arena)
	var route: Node3D = (load("res://effects/BossProceduralVFX3D.gd") as Script).new()
	battle.add_child(route)
	battle.set("_battle_3d_vfx_root", route)
	return {"battle": battle, "route": route}


func _seed(battle: Control, state: Dictionary) -> void:
	battle.set("_state", state)
	battle.call("_refresh_battle_vfx", state)


func _layer_counts(node: Node, out: Dictionary = {}) -> Dictionary:
	for child in node.get_children():
		var layer_name := str(child.name)
		if layer_name.begins_with("ServantOath_"):
			# 同名节点 Godot 会自动加数字后缀（ServantOath_AllyMark2），按前缀归并。
			for key in ["ServantOath_Field", "ServantOath_Crown", "ServantOath_AllyMark", "ServantOath_AllyShield", "ServantOath_BoundSeal"]:
				if layer_name.begins_with(key):
					out[key] = int(out.get(key, 0)) + 1
					break
		_layer_counts(child, out)
	return out
