extends "res://scenes/battle/BattleRenderer.gd"

const RANGED_ATTACK_MIN_RANGE_PX := 135.0
const _SkillVFXConfig := preload("res://effects/SkillVFXConfig.gd")

var _vfx_prev_units: Dictionary = {}
var _vfx_seeded: bool = false
var _vfx_visual_event_index := 0

func _refresh_visuals() -> void:
	super._refresh_visuals()
	_refresh_battle_vfx(_state)

func _update_vfx_camera_shake() -> void:
	pass

func _refresh_battle_vfx(state_snapshot: Dictionary) -> void:
	_play_visual_events(state_snapshot)
	var current := _collect_vfx_units(state_snapshot)
	if not _vfx_seeded:
		_vfx_prev_units = current
		_vfx_seeded = true
		return

	var damage_events: Array[Dictionary] = []
	var death_events: Array[Dictionary] = []

	for id: String in current.keys():
		var now: Dictionary = current[id]
		var prev: Dictionary = _vfx_prev_units.get(id, {})
		if prev.is_empty():
			if _vfx_seeded and str(now.get("skill_id", "")) == "twin_revive":
				_spawn_boss_texture_variant(str(now.get("unit_id", "")), "revive", now.get("foot_pos", Vector2.ZERO))
			if _vfx_seeded and id.contains("_mirror_"):
				_spawn_boss_texture_variant("boss_mirror_lord", "split", now.get("foot_pos", Vector2.ZERO))
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
				"team": str(now.get("team", "")),
				"critical": critical,
			})
		elif hp_delta > 0:
			_spawn_vfx("HOLY_HEAL", now.get("head_pos", Vector2.ZERO))
		if shield_delta > 0:
			_spawn_vfx("HOLY_SHIELD", now.get("head_pos", Vector2.ZERO))
		if stack_delta > 0 and sid_now in ["rage_stack", "same_target_damage_stack"]:
			if sid_now == "rage_stack":
				_spawn_boss_texture_variant(str(now.get("unit_id", "")), "rage_stack", now.get("foot_pos", Vector2.ZERO))
			else:
				_spawn_vfx("GROWTH_AURA", now.get("foot_pos", Vector2.ZERO))
		if sid_now == "overload_counter" and stack_delta != 0:
			var overload_target := _nearest_enemy_target(now, damage_events, current)
			var overload_pos: Vector2 = overload_target.get("hit_pos", now.get("foot_pos", Vector2.ZERO))
			_play_boss_procedural("lightning_ball", now.get("cast_pos", now.get("foot_pos", Vector2.ZERO)), overload_pos)
		var prev_ratio := float(prev.get("hp", 0)) / float(maxi(1, int(prev.get("max_hp", 1))))
		var now_ratio := float(now.get("hp", 0)) / float(maxi(1, int(now.get("max_hp", 1))))
		if sid_now == "blood_rage" and prev_ratio > 0.35 and now_ratio <= 0.35:
			_spawn_boss_texture_variant(str(now.get("unit_id", "")), "blood_rage", now.get("foot_pos", Vector2.ZERO))
		if sid_now == "twin_revive" and not bool(prev.get("alive", true)) and bool(now.get("alive", false)):
			_spawn_boss_texture_variant(str(now.get("unit_id", "")), "revive", now.get("foot_pos", Vector2.ZERO))
		var prev_skill_ready := float(prev.get("skill_ready", 0.0))
		var now_skill_ready := float(now.get("skill_ready", 0.0))
		if now_skill_ready > prev_skill_ready + 0.1:
			_play_skill_cast_vfx(now, damage_events, current)
		if bool(prev.get("alive", true)) and not bool(now.get("alive", true)):
			death_events.append({"pos": now.get("foot_pos", Vector2.ZERO), "killer_team": _opposite_team(str(now.get("team", "")))})
			_spawn_vfx("DEATH_EXPLOSION", now.get("foot_pos", Vector2.ZERO))

	for id: String in _vfx_prev_units.keys():
		if current.has(id):
			continue
		var prev_missing: Dictionary = _vfx_prev_units[id]
		_spawn_vfx("DEATH_EXPLOSION", prev_missing.get("foot_pos", Vector2.ZERO))

	_play_ranged_projectiles(_collect_attack_events(current, true), damage_events, current)
	if not death_events.is_empty():
		for id: String in current.keys():
			var boss_now: Dictionary = current[id]
			if str(boss_now.get("skill_id", "")) == "soul_devour" and bool(boss_now.get("alive", false)):
				for death_event: Dictionary in death_events:
					_spawn_boss_texture_variant(str(boss_now.get("unit_id", "")), "devour", death_event.get("pos", boss_now.get("foot_pos", Vector2.ZERO)))
	_play_melee_slashes(_collect_attack_events(current, false), damage_events, current)
	_vfx_prev_units = current

func _vfx_hit_stop_active() -> bool:
	return has_node("/root/VFXManager") and get_node("/root/VFXManager").is_hitstop_active()

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
			result[id] = {
				"id": id,
				"hp": int(f.get("hp", 0)),
				"max_hp": int(f.get("max_hp", 1)),
				"shield": int(f.get("shield", 0)),
				"alive": bool(f.get("alive", true)),
				"pos": base_pos,
				"foot_pos": _unit_anchor_global_position(unit_node, "FootAnchor", base_pos),
				"cast_pos": _unit_anchor_global_position(unit_node, "CastAnchor", base_pos),
				"hit_pos": _unit_anchor_global_position(unit_node, "HitAnchor", base_pos),
				"head_pos": _unit_anchor_global_position(unit_node, "HeadAnchor", base_pos),
				"team": str(f.get("team", "")),
				"attack_count": int(f.get("attack_count", 0)),
				"range_px": float(f.get("range_px", 0.0)),
				"skill_ready": float(f.get("skill_ready", 0.0)),
				"skill_id": str(f.get("def", {}).get("skill_id", "")),
				"skill_every": int(f.get("def", {}).get("every", 0)),
				"unit_id": str(f.get("id", "")),
				"skill_stacks": int(f.get("skill_stacks", 0)),
			}
	return result

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
			"team": str(now.get("team", "")),
			"unit_id": str(now.get("unit_id", "")),
			"skill_id": str(now.get("skill_id", "")),
			"attack_count": int(now.get("attack_count", 0)),
			"skill_every": int(now.get("skill_every", 0)),
		})
	return events

func _play_ranged_projectiles(attacks: Array[Dictionary], damage_events: Array[Dictionary], current: Dictionary) -> void:
	for attack: Dictionary in attacks:
		var target := _nearest_enemy_target(attack, damage_events, current)
		if target.is_empty():
			target = _floor_target_for(attack)
		var vfx_id := "PROJECTILE_MAGIC" if str(attack.get("unit_id", "")).contains("mage") else "PROJECTILE_ARROW"
		var target_node := _unit_anchor_node_for_id(str(target.get("id", "")), "HitAnchor")
		if _attack_skill_vfx_ready(attack):
			_spawn_skill_projectile_or_default(str(attack.get("unit_id", "")), vfx_id, attack.get("pos", Vector2.ZERO), target_node, target.get("pos", Vector2.ZERO))
		else:
			var config := {"impact_id": "HIT_RANGED"}
			_apply_projectile_race_color(str(attack.get("unit_id", "")), config)
			_spawn_projectile(vfx_id, attack.get("pos", Vector2.ZERO), target_node, target.get("pos", Vector2.ZERO), config)

func _play_melee_slashes(attacks: Array[Dictionary], damage_events: Array[Dictionary], current: Dictionary) -> void:
	for attack: Dictionary in attacks:
		var target := _nearest_enemy_target(attack, damage_events, current)
		if target.is_empty():
			target = _floor_target_for(attack)
		var from_pos: Vector2 = attack.get("pos", Vector2.ZERO)
		var target_pos: Vector2 = target.get("hit_pos", target.get("pos", Vector2.ZERO))
		if str(attack.get("skill_id", "")) == "unique_king_growth":
			_spawn_skill_textures_for_role(str(attack.get("unit_id", "")), "hit", target_pos)
			continue
		var angle := (target_pos - from_pos).angle()
		_spawn_vfx("HIT_MELEE", target_pos, {"angle": angle})
		_play_attack_skill_texture(attack, target, true)

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

func _play_skill_cast_vfx(unit: Dictionary, damage_events: Array[Dictionary], current: Dictionary) -> void:
	var sid := str(unit.get("skill_id", ""))
	var uid := str(unit.get("unit_id", ""))
	var texture_pos: Vector2 = unit.get("cast_pos", Vector2.ZERO)
	var should_play_texture := true
	var procedural_played := false
	match sid:
		"apocalypse_charge", "element_meteor", "mirror_clone", "holy_purify", "overload_counter", "twin_revive", "blood_rage", "soul_devour", "rage_stack":
			# Boss VFX are driven by the skill cast snapshot. The texture config supplies staged delays,
			# scale pulses, rotation and drift so the effect reads as an event, not a static sticker.
			should_play_texture = false
			if sid == "element_meteor":
				var meteor_target := _nearest_enemy_target(unit, damage_events, current)
				var meteor_pos: Vector2 = meteor_target.get("hit_pos", meteor_target.get("pos", texture_pos))
				_play_boss_procedural("meteor_strike", texture_pos, meteor_pos)
				procedural_played = true
			elif sid == "overload_counter":
				var lightning_target := _nearest_enemy_target(unit, damage_events, current)
				if not lightning_target.is_empty():
					var lightning_pos: Vector2 = lightning_target.get("hit_pos", lightning_target.get("pos", texture_pos))
					_play_boss_procedural("lightning_ball", texture_pos, lightning_pos)
					procedural_played = true
			elif sid == "apocalypse_charge":
				_spawn_boss_texture_variant(uid, "chargeup", unit.get("foot_pos", texture_pos))
				_spawn_boss_texture_variant(uid, "shield", unit.get("foot_pos", texture_pos))
				var apocalypse_target := _nearest_enemy_target(unit, damage_events, current)
				_spawn_boss_texture_variant(uid, "blast", apocalypse_target.get("hit_pos", texture_pos))
			else:
				_spawn_skill_texture_for_unit_id(uid, unit.get("foot_pos", texture_pos))
		"random_attribute_bolt", "silence_bolt":
			should_play_texture = false
			var target_bolt := _nearest_enemy_target(unit, damage_events, current)
			if target_bolt.is_empty():
				target_bolt = _floor_target_for(unit)
			texture_pos = target_bolt.get("hit_pos", target_bolt.get("pos", texture_pos))
			var target_node := _unit_anchor_node_for_id(str(target_bolt.get("id", "")), "HitAnchor")
			_spawn_skill_textures_for_role(uid, "cast", unit.get("cast_pos", Vector2.ZERO))
			_spawn_skill_projectile_or_default(uid, "PROJECTILE_MAGIC", unit.get("cast_pos", Vector2.ZERO), target_node, texture_pos)
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
				_spawn_skill_roles_at_target(uid, unit, target_control)
				if sid == "blink_low_def_backline":
					_spawn_vfx("TELEPORT_SLASH", target_control.get("hit_pos", target_control.get("pos", Vector2.ZERO)))
				elif sid == "fear":
					_spawn_vfx("FEAR_SKULL", target_control.get("head_pos", target_control.get("pos", Vector2.ZERO)))
				elif sid == "stun" or sid == "front_cone_stun":
					_spawn_vfx("STUN_RING", target_control.get("foot_pos", target_control.get("pos", Vector2.ZERO)))
		"black_hole":
			_spawn_vfx("BLACK_HOLE", unit.get("foot_pos", Vector2.ZERO))
			_spawn_vfx("DARK_EXPLOSION", unit.get("foot_pos", Vector2.ZERO))
		"lowest_ally_heal", "nearby_ally_heal_buff", "holy_song", "holy_purify":
			_spawn_vfx("HOLY_HEAL", unit.get("head_pos", Vector2.ZERO))
		"random_ally_damage_reduction", "shell_guard", "apocalypse_charge":
			_spawn_vfx("HOLY_SHIELD", unit.get("head_pos", Vector2.ZERO))
		"shared_hp_link":
			_spawn_vfx("SOUL_CHAIN", unit.get("cast_pos", Vector2.ZERO))
		_:
			if sid.contains("poison"):
				_spawn_vfx("POISON_CLOUD", unit.get("foot_pos", Vector2.ZERO))
	# 叠加贴图特效（与程序效果同时显示）
	if should_play_texture:
		_play_skill_texture_vfx(unit, texture_pos)
	elif procedural_played:
		# The procedural sample owns its full staged animation; do not place a static Boss PNG on top.
		pass

func _play_boss_procedural(effect_id: String, origin_2d: Vector2, target_2d: Vector2) -> void:
	if _battle_3d_vfx_root == null or not is_instance_valid(_battle_3d_vfx_root):
		return
	if not _battle_3d_vfx_root.has_method("play"):
		return
	_battle_3d_vfx_root.call("play", effect_id, _sim_to_world_pos(origin_2d), _sim_to_world_pos(target_2d))

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
	var config := {"impact_id": "HIT_RANGED"}
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
	if sid == "every_fourth_combo":
		var every := maxi(1, int(attack.get("skill_every", 4)))
		return int(attack.get("attack_count", 0)) % every == 0
	if sid == "same_target_damage_stack":
		return int(attack.get("attack_count", 0)) % 2 == 0
	return sid in ["true_damage_attack", "defense_down_attack"]

func _play_visual_events(state_snapshot: Dictionary) -> void:
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

func _spawn_vfx(vfx_id: String, pos: Vector2, config: Dictionary = {}) -> void:
	if has_node("/root/VFXManager"):
		get_node("/root/VFXManager").spawn_vfx(vfx_id, pos, config)

func _spawn_projectile(vfx_id: String, start_pos: Vector2, target_node: Node, target_pos: Vector2, config: Dictionary = {}) -> void:
	if has_node("/root/VFXManager"):
		config["target_position"] = target_pos
		get_node("/root/VFXManager").spawn_projectile_vfx(vfx_id, start_pos, target_node, config)

func _hitstop(duration: float) -> void:
	if has_node("/root/VFXManager"):
		get_node("/root/VFXManager").play_hitstop(duration)

func _screen_shake(strength: float, duration: float) -> void:
	if has_node("/root/VFXManager"):
		get_node("/root/VFXManager").play_screen_shake(strength, duration)

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
