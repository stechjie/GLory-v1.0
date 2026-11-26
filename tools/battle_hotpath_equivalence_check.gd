extends Node

# Frozen reference functions below come from ad76ec05fd564201c3b27eaa2d6f3fafbfe26b9f.
# Compare actual snapshot/scene results, not textual implementation patterns.
# Both reference and candidate use the same validity-first registry fix.
# This is a behavior gate and operation count, not a mobile energy benchmark.
const Harness := preload("res://tools/CheckHarness.gd")
const CurrentVfx := preload("res://scenes/battle/BattleVfx.gd")
const CurrentStatus := preload("res://scenes/battle/StatusVFXController.gd")

class CountingRegistry:
	extends "res://effects/runtime/presentation/UnitActorRegistry.gd"
	var actor_reads := 0
	func get_actor(uid: String) -> Node3D:
		actor_reads += 1
		return super.get_actor(uid)

class LegacyVfx:
	extends "res://scenes/battle/BattleVfx.gd"
	func _visual_id(f: Dictionary) -> String:
		return str(f.get("uid", "%s_%s" % [str(f.get("team", "")), str(f.get("id", ""))]))
	func _collect_vfx_units(state_snapshot: Dictionary) -> Dictionary:
		# 取"当前不是上一帧快照"的那个缓冲区来填。prev 恒指向另一个缓冲区，
		# 所以覆盖本缓冲区时绝不会动到 prev。
		var result: Dictionary = _vfx_snap_b if _vfx_snap_use_b else _vfx_snap_a
		_vfx_snap_use_b = not _vfx_snap_use_b
		_vfx_seen_ids.clear()
		for side in ["player", "enemy"]:
			for f in state_snapshot.get(side, []):
				if typeof(f) != TYPE_DICTIONARY:
					continue
				var id := _visual_id(f)
				var sim_pos := _visual_sim_pos_for_fighter(f)
				var base_pos := _sim_to_arena(sim_pos)
				var unit_node := _unit_node_for_id(id)
				var model_node: Node3D = _unit_actor_registry.get_actor(id)
				_vfx_seen_ids[id] = true
				# 取回该 id 的字典原地改写；首见才建一次，之后帧一直复用同一个字典对象。
				# 不用 result.get(id, {})——那个默认 {} 每次调用都会构造一个丢弃的空字典，
				# 等于每帧每单位又白分配一次。
				var u: Dictionary
				if result.has(id):
					u = result[id]
				else:
					u = {}
					result[id] = u
				u["id"] = id
				u["hp"] = int(f.get("hp", 0))
				u["max_hp"] = int(f.get("max_hp", 1))
				u["shield"] = int(f.get("shield", 0))
				u["alive"] = bool(f.get("alive", true))
				u["pos"] = base_pos
				u["sim_pos"] = sim_pos
				# 模拟里的真实坐标（sim_pos 是画面插值后的位置）。按模拟半径取目标时用它。
				u["raw_pos"] = _fighter_sim_pos(f)
				u["foot_pos"] = _unit_anchor_global_position(unit_node, "FootAnchor", base_pos)
				u["cast_pos"] = _unit_anchor_global_position(unit_node, "CastAnchor", base_pos)
				u["hit_pos"] = _unit_anchor_global_position(unit_node, "HitAnchor", base_pos)
				u["head_pos"] = _unit_anchor_global_position(unit_node, "HeadAnchor", base_pos)
				u["world_foot"] = _unit_vfx_position(id, "FootAnchor", sim_pos, 0.08)
				u["world_cast"] = _unit_vfx_position(id, "CastAnchor", sim_pos, 0.82)
				u["world_hit"] = _unit_vfx_position(id, "HitAnchor", sim_pos, 0.72)
				u["world_head"] = _unit_vfx_position(id, "HeadAnchor", sim_pos, 1.45)
				u["model_node"] = model_node
				u["team"] = str(f.get("team", ""))
				u["owner_slot"] = int(f.get("owner_slot", -1))
				u["attack_count"] = int(f.get("attack_count", 0))
				u["range_px"] = float(f.get("range_px", 0.0))
				u["skill_ready"] = float(f.get("skill_ready", 0.0))
				# 11.21 偷袭者吟唱：模拟器挂 skill_chant 状态（0.5 秒），状态随帧过回放边界。
				var chant_value: Variant = f.get("statuses", {})
				var chant_status: Variant = (chant_value as Dictionary).get("skill_chant", {}) if typeof(chant_value) == TYPE_DICTIONARY else {}
				u["skill_chant_sec"] = float((chant_status as Dictionary).get("remaining", 0.0)) if typeof(chant_status) == TYPE_DICTIONARY else 0.0
				u["skill_id"] = str(f.get("def", {}).get("skill_id", ""))
				# 种族只用于挑表现（赤律族的 unit_id 没有 god_/dark_ 这类前缀）。
				u["race"] = str(f.get("def", {}).get("race", ""))
				# 数据里的射程格数（1 = 近战）。range_px 在实时模拟与回放里口径不同
				# （32 vs 72），判近战/远程只能看这个。
				u["attack_range"] = float(f.get("def", {}).get("range", 1.0))
				# Replay rosters preserve the resolved def, but omit the opening-only
				# taunt fields. Taunt lasts while the guardian lives, independent of shield.
				u["taunt_active"] = bool(f.get("taunt_active", u["skill_id"] == "guardian_shield_taunt"))
				u["taunt_radius"] = float(f.get("taunt_radius", f.get("def", {}).get("taunt_radius", 0.0)))
				u["skill_every"] = int(f.get("def", {}).get("every", 0))
				u["unit_id"] = str(f.get("id", ""))
				# 母灵处决打到 Boss 时是「重击」而不是吸魂。判据与模拟器 _is_boss_fighter 一致：
				# Boss 数据表里没有 is_boss 字段，回合 Boss 只能靠 id 前缀认（11.12 以前这里只看字段，
				# 真实 Boss 永远被当成普通棋子）。
				u["is_boss"] = bool(f.get("def", {}).get("is_boss", false)) or str(f.get("id", "")).begins_with("boss_")
				u["skill_stacks"] = int(f.get("skill_stacks", 0))
				# 人王的持久成长层数，只给天剑定尺寸用。3v3 回放的 roster 不带这个字段，读到 0。
				u["king_stacks"] = int(f.get("king_growth_stacks", 0))
				u["phoenix_used"] = bool(f.get("phoenix_used", false))
				u["sim_uid"] = str(f.get("uid", ""))
				u["killer_uid"] = str(f.get("killer_uid", ""))
				u["mother_execute_kill"] = bool(f.get("mother_execute_kill", false))
				u["attack_target_uid"] = str(f.get("vfx_attack_target_uid", ""))
				u["skill_target_uid"] = str(f.get("vfx_skill_target_uid", ""))
				u["lane"] = int(f.get("lane", -1))
				u["blood_rage_active"] = bool(f.get("blood_rage_active", false))
				u["apocalypse_charging"] = f.has("apocalypse_due")
				u["apocalypse_due"] = float(f.get("apocalypse_due", -1.0))
				u["twin_group_id"] = str(f.get("twin_group_id", ""))
				u["twin_member_index"] = int(f.get("twin_member_index", -1))
		# 剪掉本帧没出现的（已离场/被移除）单位的陈旧字典，否则 diff 会把它们当成还在。
		if result.size() != _vfx_seen_ids.size():
			for id in result.keys():
				if not _vfx_seen_ids.has(id):
					result.erase(id)
		return result

	func _unit_vfx_position(id: String, anchor_name: String, sim_pos: Vector2, fallback_y: float) -> Vector3:
		var model_node: Node3D = _unit_actor_registry.get_actor(id)
		if model_node != null and is_instance_valid(model_node):
			var anchor := _unit_actor_registry.get_anchor(id, anchor_name)
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

class LegacyStatus:
	extends "res://scenes/battle/StatusVFXController.gd"
	func update_from_fighter(fighter: Dictionary) -> void:
		_sync_divine_pulse(fighter)
		var shield_now := int(fighter.get("shield", 0))
		_note_shield_transition(shield_now)
		# BREAK 期间必须保持可见，否则 shield 归零的同一帧精灵就被隐藏，
		# 破盾演出一帧都放不出来 —— 那等于没做。
		_set_effect_visible("shield", shield_now > 0 or _shield_phase == ShieldPhase.BREAK)
		var statuses: Dictionary = fighter.get("statuses", {})
		# Iterate the fixed definitions without allocating per-fighter dictionaries,
		# key arrays or an unused remaining-duration map on every rendered frame.
		for kind in EFFECTS:
			if kind == "shield":
				continue
			var status: Dictionary = statuses.get(kind, {})
			# Blood Pact's nonlethal self-bleed is stored separately so an enemy bleed
			# can remain lethal and keep its own attribution. Both share one icon.
			if kind == "bleed" and float(status.get("remaining", 0.0)) <= 0.0:
				status = statuses.get("bleed_nonlethal", {})
			_set_effect_visible(kind, float(status.get("remaining", 0.0)) > 0.0)
		# Poison remains one gameplay status with two independently timed stacks.
		# Reuse its existing texture for a second head icon only while both are live.
		_set_effect_visible("poison_2", _legacy_active_poison_layers(statuses) >= 2)
	static func _legacy_active_poison_layers(statuses: Dictionary) -> int:
		var poison: Dictionary = statuses.get("poison", {})
		if poison.has("stacks"):
			var active := 0
			for raw_stack in poison.get("stacks", []):
				if typeof(raw_stack) == TYPE_DICTIONARY and float((raw_stack as Dictionary).get("remaining", 0.0)) > 0.0:
					active += 1
			return mini(active, 2)
		return 1 if float(poison.get("remaining", 0.0)) > 0.0 else 0

var h = Harness.new("battle_hotpath_equivalence")
var _old
var _new
var _common: Node
var _actor: Node3D
var _vfx_root: Node3D
var _state: Dictionary
var _snapshot_cases := 0

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var team_mode_before: bool = GameState.team_mode
	var round_before: int = GameState.round_index
	GameState.team_mode = false
	GameState.round_index = 1
	_check_uid_semantics()
	_check_snapshot_lifecycle()
	_check_status_sequence()
	GameState.team_mode = team_mode_before
	GameState.round_index = round_before
	print("HOTPATH_EQUIVALENCE snapshots=%d" % _snapshot_cases)
	h.finish(get_tree())

func _check_uid_semantics() -> void:
	var current = CurrentVfx.new()
	var cases: Array = [
		{}, {"team": "player", "id": "human_swordsman"},
		{"uid": "player_1", "team": "ignored", "id": "ignored"},
		{"uid": ""}, {"uid": null}, {"uid": 17}, {"uid": 0.5},
		{"uid": StringName("named_uid")}, {"team": null, "id": 42},
	]
	for i in cases.size():
		var f: Dictionary = cases[i]
		var expected := str(f.get("uid", "%s_%s" % [str(f.get("team", "")), str(f.get("id", ""))]))
		h.expect(current._visual_id(f) == expected, "uid_%d" % i, "UID fallback must preserve present-key and conversion semantics")
	current.free()

func _make_actor(offset: Vector3) -> Node3D:
	var actor := Node3D.new()
	_common.add_child(actor)
	actor.position = offset
	actor.rotation.y = 0.31
	actor.scale = Vector3(1.2, 0.9, 1.1)
	for name in ["ActorRoot", "FootAnchor", "HeadAnchor", "CastAnchor", "HitAnchor", "Shadow"]:
		var anchor := Node3D.new()
		anchor.name = name
		actor.add_child(anchor)
		anchor.position = Vector3(float(actor.get_child_count()) * 0.1, float(actor.get_child_count()) * 0.2, -0.3)
	return actor

func _register_actor(actor: Node3D) -> void:
	for screen in [_old, _new]:
		h.expect(screen._unit_actor_registry.register_actor("fighter_a", actor), "register_actor", "Fixture must satisfy the actual actor contract")

func _compare_snapshot(label: String) -> Array:
	var before := _state.duplicate(true)
	var old_snapshot: Dictionary = _old._collect_vfx_units(_state)
	var new_snapshot: Dictionary = _new._collect_vfx_units(_state)
	h.expect(old_snapshot == new_snapshot, "snapshot_" + label, label + ": every collected field must match the frozen implementation")
	h.expect(_state == before, "state_" + label, label + ": collection must not mutate gameplay dictionaries")
	_snapshot_cases += 1
	return [old_snapshot, new_snapshot]

func _check_snapshot_lifecycle() -> void:
	_common = Node.new()
	add_child(_common)
	_old = LegacyVfx.new()
	_new = CurrentVfx.new()
	_common.add_child(_old)
	_common.add_child(_new)
	var arena := Control.new()
	_common.add_child(arena)
	arena.size = Vector2(1600, 900)
	_vfx_root = Node3D.new()
	_common.add_child(_vfx_root)
	_vfx_root.position = Vector3(2, -0.5, 1.5)
	_vfx_root.rotation.y = -0.2
	_vfx_root.scale = Vector3(0.8, 1.1, 1.3)
	var plate := Control.new()
	_common.add_child(plate)
	plate.position = Vector2(50, 120)
	for name in ["FootAnchor", "CastAnchor", "HitAnchor", "HeadAnchor"]:
		var anchor = Node2D.new() if name == "FootAnchor" else Control.new()
		anchor.name = name
		plate.add_child(anchor)
		anchor.position = Vector2(11, 23)
		if anchor is Control:
			anchor.size = Vector2(16, 12)
	for screen in [_old, _new]:
		screen._arena = arena
		screen._battle_3d_vfx_root = _vfx_root
		screen._unit_nodes["fighter_a"] = plate
		screen._unit_actor_registry = CountingRegistry.new()
	_actor = _make_actor(Vector3(3, 1, -2))
	_register_actor(_actor)
	var fighter := {"uid": "fighter_a", "id": "human_swordsman", "team": "player", "pos": Vector2(250, 500),
		"hp": 83, "max_hp": 100, "shield": 21, "alive": true, "owner_slot": 0,
		"def": {"skill_id": "guardian_shield_taunt", "race": "human", "range": 2, "taunt_radius": 77, "every": 4},
		"statuses": {"skill_chant": {"remaining": 0.4}}, "skill_stacks": 3,
		"vfx_attack_target_uid": "fighter_b", "vfx_skill_target_uid": "fighter_b", "lane": 0}
	_state = {"player": [fighter], "enemy": []}
	for screen in [_old, _new]:
		screen._state = _state
		screen._unit_actor_registry.actor_reads = 0
	var first := _compare_snapshot("actor_and_anchors")
	var old_reads: int = _old._unit_actor_registry.actor_reads
	var new_reads: int = _new._unit_actor_registry.actor_reads
	h.expect(old_reads == 9 and new_reads == 1, "registry_reads", "Four anchors must reuse the frame-local actor (9 original reads, 1 current read)")
	print("HOTPATH_OPERATIONS actor_reads_original=%d actor_reads_current=%d" % [old_reads, new_reads])
	var frozen: Dictionary = first[1].duplicate(true)
	fighter.hp = 52
	fighter.statuses.skill_chant.remaining = 0.0
	fighter.def.race = "crimson"
	_actor.position += Vector3(1, 0.2, -0.4)
	(_actor.get_node("HeadAnchor") as Node3D).position += Vector3(0.1, 0.3, 0.2)
	_compare_snapshot("animated_and_changed_fields")
	h.expect(first[1] == frozen, "double_buffer", "Alternating collection must preserve the preceding frame snapshot")
	var hit: Node = _actor.get_node("HitAnchor")
	hit.name = "RetiredHitAnchor"
	_compare_snapshot("missing_anchor")
	var new_hit := Node3D.new()
	new_hit.name = "HitAnchor"
	_actor.add_child(new_hit)
	new_hit.position = Vector3(-0.7, 1.6, 0.4)
	_compare_snapshot("replaced_anchor")
	for name in ["FeetAnchor", "BodyAnchor", "MissingAnchor"]:
		var expected: Vector3 = _old._unit_vfx_position("fighter_a", name, fighter.pos, 0.72)
		h.expect(_new._unit_vfx_position("fighter_a", name, fighter.pos, 0.72) == expected,
			"anchor_alias_" + name, "Helper aliases and missing-anchor fallback must preserve the prior positions")
	var replacement := _make_actor(Vector3(-3, 2, 1))
	_register_actor(replacement)
	_actor.free()
	_actor = replacement
	_compare_snapshot("same_uid_replacement")
	for screen in [_old, _new]:
		screen._battle_3d_vfx_root = null
	_compare_snapshot("global_coordinates_without_vfx_root")
	for screen in [_old, _new]:
		screen._battle_3d_vfx_root = _vfx_root
		# Exercise ordinary ownership cleanup as well as the stale-free path below.
		h.expect(screen._unit_actor_registry.unregister_if_holds("fighter_a", _actor),
			"unregister_before_free", "Only the actor currently owned by this uid may be unregistered")
	_actor.free()
	_compare_snapshot("unregistered_actor_fallback")
	_actor = _make_actor(Vector3(2, 1, 3))
	_register_actor(_actor)
	_actor.free()
	_compare_snapshot("freed_actor_without_unregister")
	for screen in [_old, _new]:
		h.expect(screen._unit_actor_registry.size() == 0,
			"stale_actor_pruned", "A freed actor must return null and leave no stale registry entry")
	_state.player.append({"id": "no_uid", "team": "player", "pos": Vector2(180, 450)})
	_state.enemy.append({"uid": "fighter_b", "id": "boss_probe", "team": "enemy", "pos": Vector2(300, 200), "alive": false, "statuses": null})
	_state.enemy.append(42)
	_compare_snapshot("missing_fields_dead_and_malformed_entries")
	_state.player = [_state.player[1]]
	_state.enemy.clear()
	_compare_snapshot("removed_units_buffer_a")
	_compare_snapshot("removed_units_buffer_b")
	_common.free()

func _status_state(controller) -> Dictionary:
	var sprites := {}
	for kind in controller._sprites:
		var sprite: Sprite3D = controller._sprites[kind]
		sprites[kind] = {"visible": sprite.visible, "texture": sprite.texture, "parent": str(sprite.get_parent().name)}
	return {"active": controller._active_kinds.duplicate(), "slots": controller._slot_x.duplicate(),
		"shield": controller._shield_amount, "phase": controller._shield_phase,
		"elapsed": controller._shield_phase_elapsed, "pending": controller._shield_hide_pending,
		"processing": controller.is_processing(), "sprites": sprites}

func _check_status_sequence() -> void:
	var old_host := Node3D.new()
	var new_host := Node3D.new()
	add_child(old_host)
	add_child(new_host)
	var old_status := LegacyStatus.new()
	var new_status = CurrentStatus.new()
	old_host.add_child(old_status)
	new_host.add_child(new_status)
	old_status.process_mode = Node.PROCESS_MODE_DISABLED
	new_status.process_mode = Node.PROCESS_MODE_DISABLED
	var frames: Array = [
		{}, {"shield": 0, "statuses": {}},
		{"shield": 100, "statuses": {"poison": {"remaining": 5.0}}},
		{"shield": 100, "statuses": {"poison": {"remaining": 5.0}}},
		{"shield": 80, "statuses": {"poison": {"stacks": [{"remaining": 4.0}, {"remaining": 3.0}]} }},
		{"shield": 120, "statuses": {"bleed": {"remaining": 0.0}, "bleed_nonlethal": {"remaining": 2.0}, "stun": {"remaining": 1.0}}},
		{"shield": 0, "statuses": {"poison": {"stacks": [{"remaining": 0.0}, {"remaining": 3.0}, 42]}}},
		{"shield": 0, "statuses": {}}, {},
	]
	for i in frames.size():
		var before: Dictionary = frames[i].duplicate(true)
		old_status.update_from_fighter(frames[i])
		new_status.update_from_fighter(frames[i])
		h.expect(_status_state(old_status) == _status_state(new_status), "status_update_%d" % i,
			"Active icon order, shield phase, textures and processing must match")
		h.expect(frames[i] == before, "status_input_%d" % i, "Status presentation must leave the input unchanged")
		for delta in [0.016, 0.4]:
			old_status._process(delta)
			new_status._process(delta)
			h.expect(_status_state(old_status) == _status_state(new_status), "status_phase_%d_%s" % [i, delta],
				"Shield apply/steady/absorb/break and icon lifetime must retain their exact progression")
	old_host.free()
	new_host.free()
