extends "res://scenes/battle/BattleRenderer.gd"

const RANGED_ATTACK_MIN_RANGE_PX := 135.0
const _SkillVFXConfig := preload("res://effects/SkillVFXConfig.gd")

var _vfx_prev_units: Dictionary = {}
var _vfx_seeded: bool = false
var _vfx_visual_event_index := 0
var _persistent_unit_vfx: Dictionary = {}

func _refresh_visuals() -> void:
	super._refresh_visuals()
	_refresh_battle_vfx(_state)

func _update_vfx_camera_shake() -> void:
	pass

func _refresh_battle_vfx(state_snapshot: Dictionary) -> void:
	var current := _collect_vfx_units(state_snapshot)
	_sync_persistent_unit_vfx(current)
	_play_visual_events(state_snapshot,current)
	if not _vfx_seeded:
		_play_opening_unit_vfx(current)
		_vfx_prev_units = current
		_vfx_seeded = true
		return

	var damage_events: Array[Dictionary] = []
	var death_events: Array[Dictionary] = []
	var apocalypse_ended: Array[Dictionary] = []

	for id: String in current.keys():
		var now: Dictionary = current[id]
		var prev: Dictionary = _vfx_prev_units.get(id, {})
		if prev.is_empty():
			if _vfx_seeded and str(now.get("skill_id", "")) == "twin_revive":
				_play_boss_procedural("twin_revive", now.get("world_foot", Vector3.ZERO), now.get("world_foot", Vector3.ZERO))
			if _vfx_seeded and id.contains("_mirror_"):
				_play_boss_procedural("mirror_spawn", now.get("world_foot", Vector3.ZERO), now.get("world_foot", Vector3.ZERO))
			continue
		var hp_delta := int(now.get("hp", 0)) - int(prev.get("hp", 0))
		var shield_delta := int(now.get("shield", 0)) - int(prev.get("shield", 0))
		var stack_delta := int(now.get("skill_stacks", 0)) - int(prev.get("skill_stacks", 0))
		var sid_now := str(now.get("skill_id", ""))
		if hp_delta < 0:
			var critical := -hp_delta >= maxi(35, int(round(float(maxi(1, int(now.get("max_hp", 1)))) * 0.24)))
			damage_events.append({
				"id": id,
				"pos": now.get("hit_pos", Vector2.ZERO),
				"hit_pos": now.get("hit_pos", Vector2.ZERO),
				"head_pos": now.get("head_pos", Vector2.ZERO),
				"foot_pos": now.get("foot_pos", Vector2.ZERO),
				"world_hit": now.get("world_hit", Vector3.ZERO),
				"world_head": now.get("world_head", Vector3.ZERO),
				"world_foot": now.get("world_foot", Vector3.ZERO),
				"model_node": now.get("model_node"),
				"team": str(now.get("team", "")),
				"lane": int(now.get("lane", -1)),
				"critical": critical,
			})
		elif hp_delta > 0:
			if sid_now == "blood_rage" and bool(now.get("blood_rage_active", false)):
				var blood_source := _nearest_enemy_target(now, damage_events, current)
				_play_boss_procedural("blood_lifesteal", now.get("world_foot", Vector3.ZERO), blood_source.get("world_hit", now.get("world_foot", Vector3.ZERO)), _boss_target_context(blood_source))
			else:
				# Healing is rendered by the 3D unit composer. Do not layer the
				# legacy 2D HOLY_HEAL ring on top of it.
				pass
		if shield_delta > 0:
			_spawn_vfx("HOLY_SHIELD", now.get("head_pos", Vector2.ZERO))
		if stack_delta > 0 and sid_now in ["rage_stack", "same_target_damage_stack"]:
			if sid_now == "rage_stack":
				var rage_stacks := int(now.get("skill_stacks", 0))
				var rage_target := _nearest_enemy_target(now, damage_events, current)
				if rage_stacks > 0 and rage_stacks % 5 == 0:
					_play_boss_procedural("rage_milestone", now.get("world_foot", Vector3.ZERO), rage_target.get("world_foot", now.get("world_foot", Vector3.ZERO)), _boss_target_context(rage_target, {"stacks": rage_stacks}))
				else:
					_play_boss_procedural("rage_stack", now.get("world_foot", Vector3.ZERO), now.get("world_foot", Vector3.ZERO), {"stacks": rage_stacks})
			else:
				_spawn_vfx("GROWTH_AURA", now.get("foot_pos", Vector2.ZERO))
				var linked_uid := str(now.get("linked_target_uid", ""))
				var linked_target:Dictionary = current.get(linked_uid, now) if not linked_uid.is_empty() else now
				_play_unit_procedural("same_target_damage_stack", now.get("world_foot", Vector3.ZERO), linked_target.get("world_hit", linked_target.get("world_foot", now.get("world_foot", Vector3.ZERO))), _unit_target_context(now, linked_target))
		if stack_delta > 0 and sid_now == "poison_reflect_armor_stack":
			_play_unit_procedural("poison_reflect_armor_stack", now.get("world_foot", Vector3.ZERO), now.get("world_foot", Vector3.ZERO), _unit_target_context(now, now))
		if sid_now == "overload_counter" and stack_delta > 0:
			_play_boss_procedural("overload_stack", now.get("world_cast", Vector3.ZERO), now.get("world_foot", Vector3.ZERO))
		elif sid_now == "overload_counter" and stack_delta < 0:
			var overload_target := _nearest_enemy_target(now, damage_events, current)
			var overload_world: Vector3 = overload_target.get("world_foot", now.get("world_foot", Vector3.ZERO))
			_play_boss_procedural("overload_counter", now.get("world_cast", Vector3.ZERO), overload_world, _boss_target_context(overload_target))
		var prev_ratio := float(prev.get("hp", 0)) / float(maxi(1, int(prev.get("max_hp", 1))))
		var now_ratio := float(now.get("hp", 0)) / float(maxi(1, int(now.get("max_hp", 1))))
		if sid_now == "blood_rage" and prev_ratio > 0.35 and now_ratio <= 0.35:
			_play_boss_procedural("blood_rage", now.get("world_foot", Vector3.ZERO), now.get("world_foot", Vector3.ZERO))
		if sid_now == "twin_revive" and not bool(prev.get("alive", true)) and bool(now.get("alive", false)):
			_play_boss_procedural("twin_revive", now.get("world_foot", Vector3.ZERO), now.get("world_foot", Vector3.ZERO))
		var prev_apocalypse := bool(prev.get("apocalypse_charging", false))
		var now_apocalypse := bool(now.get("apocalypse_charging", false))
		if sid_now == "apocalypse_charge" and not prev_apocalypse and now_apocalypse:
			_play_boss_procedural("apocalypse_charge", now.get("world_foot", Vector3.ZERO), now.get("world_foot", Vector3.ZERO))
		elif sid_now == "apocalypse_charge" and prev_apocalypse and not now_apocalypse:
			var apocalypse_result := now.duplicate(true)
			apocalypse_result["charge_completed"] = float(state_snapshot.get("elapsed", 0.0)) + 0.05 >= float(prev.get("apocalypse_due", INF))
			apocalypse_ended.append(apocalypse_result)
		var prev_skill_ready := float(prev.get("skill_ready", 0.0))
		var now_skill_ready := float(now.get("skill_ready", 0.0))
		if now_skill_ready > prev_skill_ready + 0.1:
			_play_skill_cast_vfx(now, prev, damage_events, current)
		if bool(prev.get("alive", true)) and not bool(now.get("alive", true)):
			death_events.append({"pos": now.get("foot_pos", Vector2.ZERO), "world_foot": now.get("world_foot", Vector3.ZERO), "world_hit": now.get("world_hit", Vector3.ZERO), "killer_team": _opposite_team(str(now.get("team", ""))), "killer_uid": str(now.get("killer_uid", "")), "mother_execute_kill": bool(now.get("mother_execute_kill", false)), "model_node": now.get("model_node"), "victim_id": id})
			if sid_now == "twin_revive":
				var partner := _living_twin_partner(now, current)
				if not partner.is_empty():
					_play_boss_procedural("twin_timer", now.get("world_foot", Vector3.ZERO), partner.get("world_foot", now.get("world_foot", Vector3.ZERO)), _boss_target_context(partner))
			_spawn_vfx("DEATH_EXPLOSION", now.get("foot_pos", Vector2.ZERO))
			if sid_now == "death_poison_explosion":
				_play_unit_procedural("death_poison_explosion", now.get("world_foot", Vector3.ZERO), now.get("world_foot", Vector3.ZERO), _unit_target_context(now, now))

	for id: String in _vfx_prev_units.keys():
		if current.has(id):
			continue
		var prev_missing: Dictionary = _vfx_prev_units[id]
		_spawn_vfx("DEATH_EXPLOSION", prev_missing.get("foot_pos", Vector2.ZERO))
		if bool(prev_missing.get("mother_execute_kill", false)):
			death_events.append({"pos": prev_missing.get("foot_pos", Vector2.ZERO), "world_foot": prev_missing.get("world_foot", Vector3.ZERO), "world_hit": prev_missing.get("world_hit", Vector3.ZERO), "killer_uid": str(prev_missing.get("killer_uid", "")), "mother_execute_kill": true, "model_node": prev_missing.get("model_node"), "victim_id": id})

	_play_ranged_projectiles(_collect_attack_events(current, true), damage_events, current)
	for apocalypse: Dictionary in apocalypse_ended:
		var affected := _boss_damage_events_for_lane(apocalypse, damage_events)
		if not bool(apocalypse.get("charge_completed", false)):
			_play_boss_procedural("apocalypse_interrupt", apocalypse.get("world_foot", Vector3.ZERO), apocalypse.get("world_foot", Vector3.ZERO))
		elif not affected.is_empty():
			var impact_positions: Array = []
			for event: Dictionary in affected:
				impact_positions.append(event.get("world_foot", Vector3.ZERO))
			_play_boss_procedural("apocalypse_complete", apocalypse.get("world_foot", Vector3.ZERO), impact_positions[0], {"targets": impact_positions})
	if not death_events.is_empty():
		for id: String in current.keys():
			var boss_now: Dictionary = current[id]
			if str(boss_now.get("skill_id", "")) == "soul_devour" and bool(boss_now.get("alive", false)):
				for death_event: Dictionary in death_events:
					if str(death_event.get("killer_uid", "")) == str(boss_now.get("sim_uid", "")):
						_play_boss_procedural("soul_devour", boss_now.get("world_foot", Vector3.ZERO), death_event.get("world_hit", boss_now.get("world_foot", Vector3.ZERO)))
		for death_event: Dictionary in death_events:
			if not bool(death_event.get("mother_execute_kill", false)):
				continue
			var mother := _vfx_unit_by_sim_uid(current, str(death_event.get("killer_uid", "")))
			if mother.is_empty():
				mother = _vfx_unit_by_sim_uid(_vfx_prev_units, str(death_event.get("killer_uid", "")))
			if mother.is_empty():
				continue
			var victim := {"world_foot": death_event.get("world_foot", Vector3.ZERO), "model_node": death_event.get("model_node")}
			_play_unit_procedural("unique_death_execute", mother.get("world_head", mother.get("world_cast", Vector3.ZERO)), victim.get("world_foot", Vector3.ZERO), _unit_target_context(mother, victim))
	_play_melee_slashes(_collect_attack_events(current, false), damage_events, current)
	_vfx_prev_units = current

func _vfx_hit_stop_active() -> bool:
	# VFXManager is an autoload: reference it directly. The old has_node/get_node
	# pair resolved a node path twice every frame from _process.
	return VFXManager.is_hitstop_active()

func _collect_vfx_units(state_snapshot: Dictionary) -> Dictionary:
	var result := {}
	for side in ["player", "enemy"]:
		for f in state_snapshot.get(side, []):
			if typeof(f) != TYPE_DICTIONARY:
				continue
			var id := _visual_id(f)
			var sim_pos := _visual_sim_pos_for_fighter(f)
			var base_pos := _sim_to_arena(sim_pos)
			var unit_node := _unit_node_for_id(id)
			var model_node: Node3D = _battle_3d_models.get(id)
			result[id] = {
				"id": id,
				"hp": int(f.get("hp", 0)),
				"max_hp": int(f.get("max_hp", 1)),
				"shield": int(f.get("shield", 0)),
				"alive": bool(f.get("alive", true)),
				"pos": base_pos,
				"sim_pos": sim_pos,
				"foot_pos": _unit_anchor_global_position(unit_node, "FootAnchor", base_pos),
				"cast_pos": _unit_anchor_global_position(unit_node, "CastAnchor", base_pos),
				"hit_pos": _unit_anchor_global_position(unit_node, "HitAnchor", base_pos),
				"head_pos": _unit_anchor_global_position(unit_node, "HeadAnchor", base_pos),
				"world_foot": _unit_vfx_position(id, "FeetAnchor", sim_pos, 0.08),
				"world_cast": _unit_vfx_position(id, "BodyAnchor", sim_pos, 0.82),
				"world_hit": _unit_vfx_position(id, "BodyAnchor", sim_pos, 0.72),
				"world_head": _unit_vfx_position(id, "HeadAnchor", sim_pos, 1.45),
				"model_node": model_node,
				"team": str(f.get("team", "")),
				"attack_count": int(f.get("attack_count", 0)),
				"range_px": float(f.get("range_px", 0.0)),
				"skill_ready": float(f.get("skill_ready", 0.0)),
				"skill_id": str(f.get("def", {}).get("skill_id", "")),
				"skill_every": int(f.get("def", {}).get("every", 0)),
				"unit_id": str(f.get("id", "")),
				"skill_stacks": int(f.get("skill_stacks", 0)),
				"sim_uid": str(f.get("uid", "")),
				"killer_uid": str(f.get("killer_uid", "")),
				"mother_execute_kill": bool(f.get("mother_execute_kill", false)),
				"attack_target_uid": str(f.get("vfx_attack_target_uid", "")),
				"skill_target_uid": str(f.get("vfx_skill_target_uid", "")),
				"lane": int(f.get("lane", -1)),
				"blood_rage_active": bool(f.get("blood_rage_active", false)),
				"apocalypse_charging": f.has("apocalypse_due"),
				"apocalypse_due": float(f.get("apocalypse_due", -1.0)),
				"twin_group_id": str(f.get("twin_group_id", "")),
				"twin_member_index": int(f.get("twin_member_index", -1)),
			}
	return result

func _unit_vfx_position(id: String, anchor_name: String, sim_pos: Vector2, fallback_y: float) -> Vector3:
	var model_node: Node3D = _battle_3d_models.get(id)
	if model_node != null and is_instance_valid(model_node):
		var anchor := model_node.get_node_or_null(anchor_name)
		if anchor is Node3D:
			var anchor_global := (anchor as Node3D).global_position
			if _battle_3d_vfx_root != null and is_instance_valid(_battle_3d_vfx_root):
				return _battle_3d_vfx_root.to_local(anchor_global)
			return anchor_global
		var model_global := model_node.global_position
		if _battle_3d_vfx_root != null and is_instance_valid(_battle_3d_vfx_root):
			model_global = _battle_3d_vfx_root.to_local(model_global)
		model_global.y += fallback_y
		return model_global
	var fallback := _sim_to_world_pos(sim_pos)
	fallback.y = fallback_y
	return fallback

func _fighter_sim_pos(f: Dictionary) -> Vector2:
	var raw = f.get("pos", Vector2.ZERO)
	if raw is Vector2:
		return raw
	if typeof(raw) == TYPE_DICTIONARY:
		return Vector2(float(raw.get("x", 0.0)), float(raw.get("y", 0.0)))
	return Vector2.ZERO

func _collect_attack_events(current: Dictionary, ranged: bool) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	for id: String in current.keys():
		var now: Dictionary = current[id]
		var prev: Dictionary = _vfx_prev_units.get(id, {})
		if prev.is_empty() or not bool(now.get("alive", true)):
			continue
		if int(now.get("attack_count", 0)) <= int(prev.get("attack_count", 0)):
			continue
		var is_ranged := float(now.get("range_px", 0.0)) >= RANGED_ATTACK_MIN_RANGE_PX
		if is_ranged != ranged:
			continue
		events.append({
			"id": id,
			"pos": now.get("cast_pos", Vector2.ZERO),
			"world_cast": now.get("world_cast", Vector3.ZERO),
			"team": str(now.get("team", "")),
			"unit_id": str(now.get("unit_id", "")),
			"skill_id": str(now.get("skill_id", "")),
			"attack_count": int(now.get("attack_count", 0)),
			"skill_every": int(now.get("skill_every", 0)),
			"target_uid": str(now.get("attack_target_uid", "")),
		})
	return events

func _play_ranged_projectiles(attacks: Array[Dictionary], damage_events: Array[Dictionary], current: Dictionary) -> void:
	for attack: Dictionary in attacks:
		var target := _nearest_enemy_target(attack, damage_events, current)
		if target.is_empty():
			target = _floor_target_for(attack)
		var race:=_visual_race_from_unit_id(str(attack.get("unit_id","")))
		if str(attack.get("unit_id", "")) == "human_king":
			_play_attack_unit_procedural(attack,target,current)
			continue
		_play_race_basic_attack(attack,target,"ranged",race,current)
		_play_attack_unit_procedural(attack,target,current)

func _play_melee_slashes(attacks: Array[Dictionary], damage_events: Array[Dictionary], current: Dictionary) -> void:
	for attack: Dictionary in attacks:
		var target := _nearest_enemy_target(attack, damage_events, current)
		if target.is_empty():
			target = _floor_target_for(attack)
		var race:=_visual_race_from_unit_id(str(attack.get("unit_id","")))
		if str(attack.get("unit_id", "")) == "human_king":
			_play_attack_unit_procedural(attack,target,current)
			continue
		if str(attack.get("skill_id", "")) == "mirror_clone" or str(attack.get("id", "")).contains("_mirror_"):
			_play_boss_procedural("mirror_slash", attack.get("world_cast", Vector3.ZERO), target.get("world_foot", Vector3.ZERO), _boss_target_context(target))
			continue
		if not race.is_empty():
			_play_race_basic_attack(attack,target,"melee",race,current)
			_play_attack_unit_procedural(attack,target,current)
			continue
		_play_race_basic_attack(attack,target,"melee",race,current)
		_play_attack_unit_procedural(attack,target,current)

func _race_from_unit_id(unit_id:String)->String:
	for race in ["god","human","dark","undead"]:
		if unit_id.begins_with(race+"_"):
			return race
	return ""

func _visual_race_from_unit_id(unit_id:String)->String:
	var race:=_race_from_unit_id(unit_id)
	if not race.is_empty():
		return race
	var key:=unit_id.to_lower()
	if key.contains("dark") or key.contains("shadow") or key.contains("demon"):
		return "dark"
	if key.contains("undead") or key.contains("wisp") or key.contains("poison") or key.contains("death"):
		return "undead"
	if key.contains("god") or key.contains("angel") or key.contains("divine"):
		return "god"
	# Mercenaries and unclassified neutral units use the restrained human
	# projectile/strike palette instead of the legacy 2D hit effects.
	return "human"

func _play_race_basic_attack(attack:Dictionary,target:Dictionary,mode:String,race:String,current:Dictionary)->void:
	var origin:Vector3=attack.get("world_cast",Vector3.ZERO)
	var target_world:Vector3=target.get("world_hit",target.get("world_foot",Vector3.ZERO))
	var source:Dictionary=current.get(str(attack.get("id","")),{})
	_play_unit_procedural("basic_attack_%s_%s"%[mode,race],origin,target_world,_unit_target_context(source,target))

func _nearest_enemy_damage_event(attack: Dictionary, damage_events: Array[Dictionary]) -> Dictionary:
	var best: Dictionary = {}
	var best_dist := INF
	var attack_team := str(attack.get("team", ""))
	var attack_pos: Vector2 = attack.get("pos", Vector2.ZERO)
	for event: Dictionary in damage_events:
		if str(event.get("team", "")) == attack_team:
			continue
		var target_pos: Vector2 = event.get("pos", Vector2.ZERO)
		var dist := attack_pos.distance_squared_to(target_pos)
		if dist < best_dist:
			best_dist = dist
			best = event
	return best

func _nearest_enemy_target(source: Dictionary, damage_events: Array[Dictionary], current: Dictionary) -> Dictionary:
	for target_key in ["target_uid", "skill_target_uid", "attack_target_uid"]:
		var exact_uid := str(source.get(target_key, ""))
		if exact_uid.is_empty() or not current.has(exact_uid):
			continue
		var exact: Dictionary = current[exact_uid]
		if str(exact.get("team", "")) != str(source.get("team", "")):
			return exact
	var damaged := _nearest_enemy_damage_event(source, damage_events)
	if not damaged.is_empty():
		return damaged
	var best: Dictionary = {}
	var best_dist := INF
	var source_team := str(source.get("team", ""))
	var source_pos: Vector2 = source.get("pos", Vector2.ZERO)
	for id: String in current.keys():
		var target: Dictionary = current[id]
		if not bool(target.get("alive", true)) or str(target.get("team", "")) == source_team:
			continue
		var target_pos: Vector2 = target.get("hit_pos", target.get("pos", Vector2.ZERO))
		var dist := source_pos.distance_squared_to(target_pos)
		if dist < best_dist:
			best_dist = dist
			best = {
				"id": id,
				"pos": target_pos,
				"hit_pos": target.get("hit_pos", target_pos),
				"head_pos": target.get("head_pos", target_pos),
				"foot_pos": target.get("foot_pos", target_pos),
				"world_hit": target.get("world_hit", Vector3.ZERO),
				"world_head": target.get("world_head", Vector3.ZERO),
				"world_foot": target.get("world_foot", Vector3.ZERO),
				"model_node": target.get("model_node"),
				"team": str(target.get("team", "")),
			}
	return best

func _floor_target_for(source: Dictionary) -> Dictionary:
	var from_pos: Vector2 = source.get("pos", Vector2.ZERO)
	var dir := -1.0 if str(source.get("team", "")) == "player" else 1.0
	var floor_pos := from_pos + Vector2(0.0, 150.0 * dir)
	return {
		"id": "",
		"pos": floor_pos,
		"hit_pos": floor_pos,
		"head_pos": floor_pos,
		"foot_pos": floor_pos,
		"team": _opposite_team(str(source.get("team", ""))),
	}

func _play_skill_cast_vfx(unit: Dictionary, previous: Dictionary, damage_events: Array[Dictionary], current: Dictionary) -> void:
	var sid := str(unit.get("skill_id", ""))
	var uid := str(unit.get("unit_id", ""))
	var texture_pos: Vector2 = unit.get("cast_pos", Vector2.ZERO)
	var should_play_texture := true
	var procedural_played := false
	_play_race_unit_skill_procedural(sid, unit, previous, damage_events, current)
	match sid:
		"apocalypse_charge", "element_meteor", "mirror_clone", "holy_purify", "overload_counter", "twin_revive", "blood_rage", "soul_devour", "rage_stack":
			should_play_texture = false
			if sid == "element_meteor":
				var meteor_target := _nearest_enemy_target(unit, damage_events, current)
				var meteor_world: Vector3 = meteor_target.get("world_foot", unit.get("world_foot", Vector3.ZERO))
				_play_boss_procedural("element_meteor", unit.get("world_cast", Vector3.ZERO), meteor_world, _boss_target_context(meteor_target))
				procedural_played = true
			elif sid == "holy_purify":
				var ally_positions: Array = []
				for ally_id: String in current.keys():
					var ally: Dictionary = current[ally_id]
					if bool(ally.get("alive", false)) and str(ally.get("team", "")) == str(unit.get("team", "")):
						ally_positions.append(ally.get("world_foot", unit.get("world_foot", Vector3.ZERO)))
				_play_boss_procedural("holy_purify", unit.get("world_foot", Vector3.ZERO), unit.get("world_foot", Vector3.ZERO), {"targets": ally_positions})
				procedural_played = true
		"random_attribute_bolt", "silence_bolt":
			should_play_texture = false
			var target_bolt := _nearest_enemy_target(unit, damage_events, current)
			if target_bolt.is_empty():
				target_bolt = _floor_target_for(unit)
			texture_pos = target_bolt.get("hit_pos", target_bolt.get("pos", texture_pos))
			var target_node := _unit_anchor_node_for_id(str(target_bolt.get("id", "")), "HitAnchor")
			_spawn_skill_textures_for_role(uid, "cast", unit.get("cast_pos", Vector2.ZERO))
			_spawn_skill_textures_for_role(uid, "hit", texture_pos)
			should_play_texture = false
		"bubble_dream", "balance_judge", "gold_charge", "twin_strike", "arrow_rain", "blood_rampage", "steel_order", "time_slow", "death_hunt":
			should_play_texture = false
		"king_aura":
			# Visual-only procedural aura; never spawn the obsolete legacy PNG layer.
			should_play_texture = false
		"judgement_strike":
			should_play_texture = false
			var target_judgement := _nearest_enemy_target(unit, damage_events, current)
			if not target_judgement.is_empty():
				_spawn_skill_roles_at_target(uid, unit, target_judgement, true)
		"global_divine_blast":
			should_play_texture = false
			for event: Dictionary in _enemy_damage_events(unit, damage_events):
				_spawn_skill_roles_at_target(uid, unit, event)
		"fear", "stun", "front_cone_stun", "blink_low_def_backline":
			should_play_texture = false
			var target_control := _nearest_enemy_target(unit, damage_events, current)
			if not target_control.is_empty():
				if sid == "front_cone_stun":
					# The swordsman uses only the two authored, compact slash masks
					# at the confirmed hit target; no caster/ground fallback layers.
					_spawn_skill_textures_for_role(uid, "hit", target_control.get("hit_pos", target_control.get("pos", texture_pos)))
				else:
					_spawn_skill_roles_at_target(uid, unit, target_control)
				if sid == "blink_low_def_backline":
					_spawn_skill_textures_for_role(uid, "hit", target_control.get("hit_pos", target_control.get("pos", Vector2.ZERO)))
		"black_hole":
			should_play_texture = false
		"lowest_ally_heal", "nearby_ally_heal_buff", "holy_song", "holy_purify":
			should_play_texture = false
			# The 3D composer owns the heal presentation; the legacy 2D
			# HOLY_HEAL effect is intentionally disabled.
		"random_ally_damage_reduction", "shell_guard", "apocalypse_charge":
			should_play_texture = false
			if not uid.begins_with("merc_"):
				_spawn_vfx("HOLY_SHIELD", unit.get("head_pos", Vector2.ZERO))
		"shared_hp_link":
			should_play_texture = false
		_:
			pass
	# 叠加贴图特效（与程序效果同时显示）
	if should_play_texture:
		_play_skill_texture_vfx(unit, texture_pos)
	elif procedural_played:
		# The procedural sample owns its full staged animation; do not place a static Boss PNG on top.
		pass

func _play_boss_procedural(effect_id: String, origin_value: Variant, target_value: Variant, context: Dictionary = {}) -> Node3D:
	if _battle_3d_vfx_root == null or not is_instance_valid(_battle_3d_vfx_root):
		return null
	if not _battle_3d_vfx_root.has_method("play"):
		return null
	var world_context := context.duplicate(false)
	if world_context.has("targets"):
		var world_targets: Array = []
		for value in world_context["targets"]:
			world_targets.append(_boss_world_position(value))
		world_context["targets"] = world_targets
	return _battle_3d_vfx_root.call("play", effect_id, _boss_world_position(origin_value), _boss_world_position(target_value), world_context)

func _play_unit_procedural(effect_id:String,origin:Vector3,target:Vector3,context:Dictionary={})->Node3D:
	return _play_boss_procedural(effect_id,origin,target,context)

func _sync_persistent_unit_vfx(current:Dictionary)->void:
	for id:String in _persistent_unit_vfx.keys().duplicate():
		var unit:Dictionary=current.get(id,{})
		var record:Dictionary=_persistent_unit_vfx.get(id,{})
		var node:Variant=record.get("node")
		var uid:=str(unit.get("skill_target_uid",""))
		var active:=not unit.is_empty() and bool(unit.get("alive",false)) and str(unit.get("skill_id",""))=="shared_hp_link" and not uid.is_empty()
		if active and uid==str(record.get("target_uid","")):
			continue
		if is_instance_valid(node) and node is Node3D and node.has_method("release_link"):
			node.release_link()
		_persistent_unit_vfx.erase(id)

func _play_race_unit_skill_procedural(sid:String,unit:Dictionary,previous:Dictionary,damage_events:Array[Dictionary],current:Dictionary)->void:
	const ACTIVE_UNIT_SKILLS := [
		"lowest_ally_heal", "nearest_ally_bless", "nearby_ally_heal_buff",
		"random_attribute_bolt", "judgement_strike", "random_ally_damage_reduction",
		"global_divine_blast", "silence_bolt", "fear", "stun", "black_hole",
		"blink_low_def_backline", "shared_hp_link", "front_cone_stun",
		"bubble_dream", "shell_guard", "balance_judge", "gold_charge", "holy_song",
		"twin_strike", "king_aura", "arrow_rain", "blood_rampage", "steel_order",
		"time_slow", "death_hunt",
		# PVE 怪物与阵型盟友的主动技（都带 skill_cd，走 skill_ready 这条路）。
		# 这批以前不在名单里，所以施法时连 composer 都不会被调用到。
		"chain_lightning", "dive_backline", "heal_allies", "holy_shield_burst",
		"wind_bleed", "slow_aura", "stun_impact", "entangle", "burrow_ambush",
		"lava_burst", "nature_heal", "earth_slam", "backstab", "curse",
		"counter_slash", "burn_claw", "soul_chain", "devour_bite",
		"hell_burst", "eternal_night",
	]
	if not sid in ACTIVE_UNIT_SKILLS:
		return
	var origin:Vector3=unit.get("world_cast",unit.get("world_foot",Vector3.ZERO))
	if sid=="blink_low_def_backline":
		origin=previous.get("world_cast",previous.get("world_foot",origin))
	var exact:=_exact_skill_target(unit,current)
	var target:=exact
	if target.is_empty() and sid not in ["nearby_ally_heal_buff","global_divine_blast","black_hole"]:
		target=_nearest_enemy_target(unit,damage_events,current)
	var target_world:Vector3=target.get("world_hit",target.get("world_foot",unit.get("world_foot",Vector3.ZERO)))
	var context:=_unit_target_context(unit,target)
	if sid=="black_hole" and str(unit.get("unit_id",""))!="dark_dragon":
		return
	if sid=="shared_hp_link":
		var now_uid:=str(unit.get("skill_target_uid",""))
		if now_uid.is_empty() or now_uid==str(previous.get("skill_target_uid","")):
			return
		var old_link:Dictionary=_persistent_unit_vfx.get(str(unit.get("id","")),{})
		var old_node:Variant=old_link.get("node")
		if is_instance_valid(old_node) and old_node is Node3D and old_node.has_method("release_link"):
			old_node.release_link()
		context["persistent"]=true
	if sid=="nearby_ally_heal_buff":
		context["targets"]=_living_team_world_positions(unit,current)
		target_world=unit.get("world_foot",Vector3.ZERO)
	elif sid=="global_divine_blast":
		var enemy_targets:Array=[]
		for event in _enemy_damage_events(unit,damage_events):enemy_targets.append(event.get("world_foot",Vector3.ZERO))
		if enemy_targets.is_empty():
			for candidate_id:String in current.keys():
				var candidate:Dictionary=current[candidate_id]
				if bool(candidate.get("alive",false)) and str(candidate.get("team",""))!=str(unit.get("team","")):
					enemy_targets.append(candidate.get("world_foot",Vector3.ZERO))
		context["targets"]=enemy_targets
	elif sid=="black_hole":
		target_world=unit.get("world_foot",Vector3.ZERO)
	elif sid=="bubble_dream":
		var heal_target:=_lowest_living_team_target(unit,current)
		context["heal_target"]=heal_target.get("world_foot",unit.get("world_foot",Vector3.ZERO))
	elif sid=="holy_song":
		context["targets"]=_living_team_world_positions(unit,current)
		target_world=unit.get("world_foot",Vector3.ZERO)
	elif sid=="king_aura":
		context["targets"]=_living_team_world_positions(unit,current)
		target_world=unit.get("world_foot",Vector3.ZERO)
	elif sid=="arrow_rain":
		var rain_targets:=_enemy_damage_events(unit,damage_events)
		var rain_positions:Array=[]
		for event:Dictionary in rain_targets:rain_positions.append(event.get("world_foot",Vector3.ZERO))
		context["targets"]=rain_positions
		target_world=unit.get("world_foot",Vector3.ZERO)
	elif sid=="steel_order":
		context["targets"]=_nearest_living_team_positions(unit,current,3)
		target_world=unit.get("world_foot",Vector3.ZERO)
	elif sid=="time_slow":
		context["targets"]=_living_enemy_world_positions(unit,current)
		target_world=unit.get("world_foot",Vector3.ZERO)
	# PVE 怪物与阵型盟友里的群体技，目标集合的取法和上面同类技能一致。
	elif sid in ["heal_allies","nature_heal"]:
		context["targets"]=_living_team_world_positions(unit,current)
		target_world=unit.get("world_foot",Vector3.ZERO)
	elif sid=="holy_shield_burst":
		target_world=unit.get("world_foot",Vector3.ZERO)
	elif sid in ["slow_aura","eternal_night"]:
		context["targets"]=_living_enemy_world_positions(unit,current)
		target_world=unit.get("world_foot",Vector3.ZERO)
	elif sid in ["chain_lightning","hell_burst"]:
		var struck:Array=[]
		for event:Dictionary in _enemy_damage_events(unit,damage_events):
			struck.append(event.get("world_foot",Vector3.ZERO))
		context["targets"]=struck
	var spawned:=_play_unit_procedural(sid,origin,target_world,context)
	if sid=="shared_hp_link" and spawned!=null:
		_persistent_unit_vfx[str(unit.get("id",""))]={"node":spawned,"target_uid":str(unit.get("skill_target_uid",""))}

func _exact_skill_target(unit:Dictionary,current:Dictionary)->Dictionary:
	var uid:=str(unit.get("skill_target_uid",""))
	if not uid.is_empty() and current.has(uid):
		return current[uid]
	return {}

func _living_team_world_positions(unit:Dictionary,current:Dictionary)->Array:
	var result:Array=[]
	for id:String in current.keys():
		var candidate:Dictionary=current[id]
		if bool(candidate.get("alive",false)) and str(candidate.get("team",""))==str(unit.get("team","")):
			result.append(candidate.get("world_foot",Vector3.ZERO))
	return result

func _living_enemy_world_positions(unit:Dictionary,current:Dictionary)->Array:
	var result:Array=[]
	for id:String in current.keys():
		var candidate:Dictionary=current[id]
		if bool(candidate.get("alive",false)) and str(candidate.get("team",""))!=str(unit.get("team","")):
			result.append(candidate.get("world_foot",Vector3.ZERO))
	return result

func _lowest_living_team_target(unit:Dictionary,current:Dictionary)->Dictionary:
	var best:Dictionary={};var best_ratio:=INF
	for id:String in current.keys():
		var candidate:Dictionary=current[id]
		if not bool(candidate.get("alive",false)) or str(candidate.get("team",""))!=str(unit.get("team","")):continue
		var ratio:=float(candidate.get("hp",0))/float(maxi(1,int(candidate.get("max_hp",1))))
		if ratio<best_ratio:best_ratio=ratio;best=candidate
	return best

func _nearest_living_team_positions(unit:Dictionary,current:Dictionary,count:int)->Array:
	var candidates:Array=[];var source:Vector3=unit.get("world_foot",Vector3.ZERO)
	for id:String in current.keys():
		var candidate:Dictionary=current[id]
		if bool(candidate.get("alive",false)) and str(candidate.get("team",""))==str(unit.get("team","")):
			candidates.append({"distance":source.distance_squared_to(candidate.get("world_foot",source)),"position":candidate.get("world_foot",source)})
	candidates.sort_custom(func(a:Dictionary,b:Dictionary)->bool:return float(a["distance"])<float(b["distance"]))
	var result:Array=[]
	for entry in candidates.slice(0,mini(count,candidates.size())):result.append(entry["position"])
	return result

func _unit_target_context(source:Dictionary,target:Dictionary,extra:Dictionary={})->Dictionary:
	var context:=extra.duplicate(false)
	context["source_unit_id"] = str(source.get("unit_id", source.get("id", "")))
	context["target_unit_id"] = str(target.get("unit_id", target.get("id", "")))
	if source.has("stun_sec"):
		context["status_duration"] = float(source.get("stun_sec",1.18))
	var source_node=source.get("model_node")
	if is_instance_valid(source_node) and source_node is Node3D:
		var cast_anchor:Variant=source_node.get_node_or_null("CastAnchor")
		context["origin_node"]=cast_anchor if cast_anchor is Node3D else source_node
	var target_node=target.get("model_node")
	if is_instance_valid(target_node) and target_node is Node3D:
		var hit_anchor:Variant=target_node.get_node_or_null("HitAnchor")
		context["target_node"]=hit_anchor if hit_anchor is Node3D else target_node
	return context

func _play_opening_unit_vfx(current:Dictionary)->void:
	for id:String in current.keys():
		var unit:Dictionary=current[id]
		if not bool(unit.get("alive",false)):continue
		var sid:=str(unit.get("skill_id",""))
		if sid=="guardian_shield_taunt":
			_play_unit_procedural(sid,unit.get("world_foot",Vector3.ZERO),unit.get("world_foot",Vector3.ZERO),_unit_target_context(unit,unit))
		elif sid=="left_neighbor_sacrifice":
			var target:=_exact_skill_target(unit,current)
			if not target.is_empty():
				_play_unit_procedural(sid,unit.get("world_foot",Vector3.ZERO),target.get("world_foot",Vector3.ZERO),_unit_target_context(unit,target))

func _boss_world_position(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	if value is Vector2:
		# Legacy fallback only. Formal Boss effects now pass model/world anchors.
		return _sim_to_world_pos(value)
	return Vector3.ZERO

func _boss_target_context(target: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var context := extra.duplicate(false)
	var model_node = target.get("model_node")
	if is_instance_valid(model_node) and model_node is Node3D:
		var hit_anchor:Variant=model_node.get_node_or_null("HitAnchor")
		context["target_node"] = hit_anchor if hit_anchor is Node3D else model_node
	return context

func _living_twin_partner(unit: Dictionary, current: Dictionary) -> Dictionary:
	var group_id := str(unit.get("twin_group_id", ""))
	var member_index := int(unit.get("twin_member_index", -1))
	if group_id.is_empty() or member_index < 0:
		return {}
	for id: String in current.keys():
		var candidate: Dictionary = current[id]
		if bool(candidate.get("alive", false)) and str(candidate.get("team", "")) == str(unit.get("team", "")) and str(candidate.get("twin_group_id", "")) == group_id and int(candidate.get("twin_member_index", -1)) != member_index:
			return candidate
	return {}

func _boss_damage_events_for_lane(unit: Dictionary, damage_events: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var team := str(unit.get("team", ""))
	var lane := int(unit.get("lane", -1))
	for event: Dictionary in damage_events:
		if str(event.get("team", "")) == team:
			continue
		if lane >= 0 and int(event.get("lane", -1)) >= 0 and int(event.get("lane", -1)) != lane:
			continue
		result.append(event)
	return result

func _play_skill_texture_vfx(unit: Dictionary, pos: Vector2) -> void:
	var uid := str(unit.get("unit_id", ""))
	_spawn_skill_texture_for_unit_id(uid, pos)

func _spawn_skill_texture_for_unit_id(uid: String, pos: Vector2) -> void:
	if uid.is_empty():
		return
	var tex_configs := SkillVFXConfig.get_textures(uid)
	if tex_configs.is_empty():
		return
	_spawn_vfx("SKILL_TEXTURE", pos, {"textures": tex_configs})

func _spawn_boss_texture_variant(uid: String, variant: String, pos: Vector2) -> void:
	var configs := SkillVFXConfig.get_textures(uid)
	var selected: Array[Dictionary] = []
	for cfg: Dictionary in configs:
		if str(cfg.get("path", "")).to_lower().contains(variant.to_lower()):
			selected.append(cfg)
	if not selected.is_empty():
		_spawn_vfx("SKILL_TEXTURE", pos, {"textures": selected})

func _spawn_skill_hit_texture_for_unit_id(uid: String, pos: Vector2) -> void:
	var tex_configs := _textures_for_role(uid, "hit")
	if tex_configs.is_empty():
		return
	_spawn_vfx("SKILL_TEXTURE", pos, {"textures": tex_configs})

func _spawn_skill_textures_for_role(uid: String, role: String, pos: Vector2) -> void:
	var tex_configs := _textures_for_role(uid, role)
	if tex_configs.is_empty():
		return
	_spawn_vfx("SKILL_TEXTURE", pos, {"textures": tex_configs})

func _spawn_skill_projectile_or_default(uid: String, vfx_id: String, start_pos: Vector2, target_node: Node, target_pos: Vector2) -> void:
	var tex_configs := _textures_for_role(uid, "projectile")
	var config := {"impact_id": ""}
	if not tex_configs.is_empty():
		config["texture_path"] = str(tex_configs[0].get("path", ""))
		config["texture_scale"] = float(tex_configs[0].get("scale", 0.5))
	config["impact_textures"] = _textures_for_role(uid, "hit")
	config["head_textures"] = _textures_for_role(uid, "head")
	config["foot_textures"] = _textures_for_role(uid, "foot")
	_apply_projectile_race_color(uid, config)
	_spawn_projectile(vfx_id, start_pos, target_node, target_pos, config)

func _apply_projectile_race_color(uid: String, config: Dictionary) -> void:
	if uid.begins_with("human_"):
		config["color"] = Color(0.24, 0.68, 1.0, 1.0)
	elif uid.begins_with("undead_") or uid.begins_with("spirit_"):
		config["color"] = Color(0.24, 0.95, 0.30, 1.0)
	elif uid.begins_with("dark_"):
		config["color"] = Color(0.035, 0.025, 0.055, 1.0)

func _textures_for_role(uid: String, role: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for tex: Dictionary in SkillVFXConfig.get_textures(uid):
		if str(tex.get("role", "")) == role:
			result.append(tex)
	return result

func _spawn_skill_roles_at_target(uid: String, unit: Dictionary, target: Dictionary, head_on_caster := false) -> void:
	var hit_pos: Vector2 = target.get("hit_pos", target.get("pos", Vector2.ZERO))
	_spawn_skill_textures_for_role(uid, "cast", unit.get("cast_pos", Vector2.ZERO))
	_spawn_skill_textures_for_role(uid, "hit", hit_pos)
	_spawn_skill_textures_for_role(uid, "foot", target.get("foot_pos", hit_pos))
	var head_pos: Vector2 = unit.get("head_pos", hit_pos) if head_on_caster else target.get("head_pos", hit_pos)
	_spawn_skill_textures_for_role(uid, "head", head_pos)

func _enemy_damage_events(unit: Dictionary, damage_events: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var team := str(unit.get("team", ""))
	for event: Dictionary in damage_events:
		if str(event.get("team", "")) != team:
			result.append(event)
	return result

func _play_attack_skill_texture(attack: Dictionary, target: Dictionary, spawn_projectile := false) -> void:
	if not _attack_skill_vfx_ready(attack):
		return
	var uid := str(attack.get("unit_id", ""))
	var target_pos: Vector2 = target.get("hit_pos", target.get("pos", Vector2.ZERO))
	if spawn_projectile and not _textures_for_role(uid, "projectile").is_empty():
		var target_node := _unit_anchor_node_for_id(str(target.get("id", "")), "HitAnchor")
		_spawn_skill_projectile_or_default(uid, "PROJECTILE_MAGIC", attack.get("pos", Vector2.ZERO), target_node, target_pos)
		return
	_spawn_skill_hit_texture_for_unit_id(uid, target_pos)
	_spawn_skill_textures_for_role(uid, "head", target.get("head_pos", target_pos))
	_spawn_skill_textures_for_role(uid, "foot", target.get("foot_pos", target_pos))

func _attack_skill_vfx_ready(attack: Dictionary) -> bool:
	var sid := str(attack.get("skill_id", ""))
	if str(attack.get("unit_id", attack.get("source_id", ""))) == "human_king":
		return true
	if sid == "every_fourth_combo":
		var every := maxi(1, int(attack.get("skill_every", 4)))
		return int(attack.get("attack_count", 0)) % every == 0
	if sid == "same_target_damage_stack":
		return int(attack.get("attack_count", 0)) % 2 == 0
	if sid == "every_fifth_group_heal":
		var every_heal:=maxi(1,int(attack.get("skill_every",5)))
		return int(attack.get("attack_count",0))%every_heal==0
	return sid in ["true_damage_attack", "curse_attack", "poison_attack", "defense_down_attack"]

func _play_attack_unit_procedural(attack:Dictionary,target:Dictionary,current:Dictionary)->void:
	if not _attack_skill_vfx_ready(attack):return
	var sid:=str(attack.get("skill_id",""))
	var origin:Vector3=attack.get("world_cast",Vector3.ZERO)
	var target_world:Vector3=target.get("world_hit",target.get("world_foot",Vector3.ZERO))
	var source:Dictionary=current.get(str(attack.get("id","")),{})
	var context:=_unit_target_context(source,target)
	if sid=="every_fifth_group_heal":
		context["targets"]=_living_team_world_positions(source,current)
		target_world=origin
	# Human King's actual attack uses the target-bound vertical heaven sword.
	# This is visual-only and leaves damage, timing and target selection untouched.
	if str(attack.get("unit_id", attack.get("source_id", ""))) == "human_king":
		_play_unit_procedural("unique_king_growth", origin, target_world, context)
		return
	_play_unit_procedural(sid,origin,target_world,context)

func _play_visual_events(state_snapshot: Dictionary,current:Dictionary) -> void:
	var events: Array = state_snapshot.get("visual_events", [])
	if _vfx_visual_event_index > events.size():
		_vfx_visual_event_index = events.size()
	while _vfx_visual_event_index < events.size():
		var event = events[_vfx_visual_event_index]
		_vfx_visual_event_index += 1
		if typeof(event) != TYPE_DICTIONARY:
			continue
		if str(event.get("type", "")) == "skill_shake":
			_screen_shake(float(event.get("strength", 6.5)), float(event.get("duration", 0.2)))
		elif str(event.get("type",""))=="mother_execute":
			var mother:=_vfx_unit_by_sim_uid(current,str(event.get("source_uid","")))
			var victim:=_vfx_unit_by_sim_uid(current,str(event.get("target_uid","")))
			# A lethal execute is replayed from death_events below, where the
			# victim's cached position is still available. This branch handles the
			# non-lethal Boss-percent-damage variant only.
			if not mother.is_empty() and not victim.is_empty() and bool(victim.get("alive", true)):
				_play_unit_procedural("unique_death_execute",mother.get("world_head",mother.get("world_cast",Vector3.ZERO)),victim.get("world_foot",Vector3.ZERO),_unit_target_context(mother,victim))
		elif str(event.get("type", "")) == "unit_skill_proc":
			var source := _vfx_unit_by_sim_uid(current, str(event.get("source_uid", "")))
			var target := _vfx_unit_by_sim_uid(current, str(event.get("target_uid", "")))
			var skill_id := str(event.get("skill_id", ""))
			if not skill_id.is_empty() and not source.is_empty() and not target.is_empty():
				_play_unit_procedural(skill_id, source.get("world_cast", Vector3.ZERO), target.get("world_hit", target.get("world_foot", Vector3.ZERO)), _unit_target_context(source, target))

func _vfx_unit_by_sim_uid(current:Dictionary,sim_uid:String)->Dictionary:
	for id:String in current.keys():
		var unit:Dictionary=current[id]
		if str(unit.get("sim_uid",""))==sim_uid:return unit
	return {}

func _spawn_vfx(vfx_id: String, pos: Vector2, config: Dictionary = {}) -> void:
	VFXManager.spawn_vfx(vfx_id, pos, config)

func _spawn_projectile(vfx_id: String, start_pos: Vector2, target_node: Node, target_pos: Vector2, config: Dictionary = {}) -> void:
	config["target_position"] = target_pos
	VFXManager.spawn_projectile_vfx(vfx_id, start_pos, target_node, config)

func _hitstop(duration: float) -> void:
	VFXManager.play_hitstop(duration)

func _screen_shake(strength: float, duration: float) -> void:
	VFXManager.play_screen_shake(strength, duration)

func _unit_node_for_id(id: String) -> Node:
	if _unit_nodes.has(id):
		return _unit_nodes[id]
	return null

func _unit_anchor_node_for_id(id: String, anchor_name: String) -> Node:
	var unit_node := _unit_node_for_id(id)
	if unit_node == null or not is_instance_valid(unit_node):
		return null
	return unit_node.get_node_or_null(anchor_name)

func _unit_anchor_global_position(unit_node: Node, anchor_name: String, fallback: Vector2) -> Vector2:
	if unit_node == null or not is_instance_valid(unit_node):
		return fallback
	var anchor := unit_node.get_node_or_null(anchor_name)
	if anchor is Node2D:
		return (anchor as Node2D).global_position
	if anchor is Control:
		var c := anchor as Control
		return c.global_position + c.size * 0.5
	return fallback

func _opposite_team(team: String) -> String:
	return "enemy" if team == "player" else "player"
