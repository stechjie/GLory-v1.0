extends SceneTree

# 赤律族（race = crimson）特效契约检查。
# Run with: Godot --headless --path . --script res://tools/crimson_vfx_contract_check.gd
#
# 只走生产入口，不直接调用特效模块：
#   · 数据 → 路由：race_units.json 里每个赤律单位的普攻 / 技能都进 UnitSkillVFXComposer3D，
#     不再落到 Boss composer 的兜底灰刀光或人族蓝弹；
#   · 普攻：BattleVfx.cue_play_basic_attack（Director 真正调用的那个入口）；
#   · 主动技：BattleVfx._refresh_battle_vfx 的 skill_ready 上升沿；
#   · 被动 / 事件：先用固定阵容跑一场真实模拟（BattleSimulator.compute_team_replay），
#     取出模拟器真正写进回放的事件，再原样喂给 BattleVfx._play_visual_events。
# 另外覆盖：飞行时长与伤害数字延时同源、四星多目标、霜印半径映射与无目标不画、
# 赤灯封印只画在真沉默的目标上、低画质截断与关键通道、生命周期清理、人族普攻不受影响。
# 画面好不好看不在这里判 —— 那是 effects/preview/CrimsonVFXPreview.tscn 与正式战斗截图的事。

const Harness := preload("res://tools/CheckHarness.gd")
const CATALOG_PATH := "res://effects/vfx3d/units/CrimsonVFXCatalog.gd"
const ATTACK_PATH := "res://effects/vfx3d/units/VFXCrimsonAttack3D.gd"
const SKILL_PATH := "res://effects/vfx3d/units/VFXCrimsonSkill3D.gd"
const RACE_ATTACK_PATH := "res://effects/vfx3d/modules/VFXRaceBasicAttack3D.gd"
# 自然战斗取事件用的固定阵容（team b 三条线各 4 个）。与正式截图工具同一份。
const CRIMSON_LINEUP := [
	["crimson", "hunter", "armbreaker", "lattern"],
	["dancer", "drumer", "skypierce", "Icey"],
	["crimson", "drumer", "hunter", "skypierce"],
]
# team b 只在 PVP 回合上场（round_schedule.json: pvp_rounds = 6/12/18/21）；1 回合是 PVE。
const PVP_ROUND := 6

var h := Harness.new("crimson_vfx_contract")
var _catalog: Script
var _factory: Script
var _defs: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	for service_name in ["NetworkService", "RealtimeService", "AnalyticsService", "ChatService", "AnnouncementService", "MailService"]:
		var service := root.get_node_or_null(service_name)
		if service != null:
			service.set_process(false)
	root.get_node("DataRegistry").call("load_all")
	_catalog = load(CATALOG_PATH)
	_factory = load("res://scripts/units/UnitFactory.gd")
	var budget: Script = load("res://effects/vfx3d/core/VFXQualityBudget.gd")
	budget.set("tier", 1)
	_check_data_routes()
	await _check_basic_attacks()
	await _check_active_skills()
	await _check_natural_events()
	await _check_budget_and_critical(budget)
	budget.set("tier", 1)
	h.finish(self)


# ── 1. 数据 → 路由 ────────────────────────────────────────────────────────

func _check_data_routes() -> void:
	var parsed: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/units/race_units.json"))
	for definition: Dictionary in parsed.get("units", []):
		if str(definition.get("race", "")) == "crimson":
			_defs[str(definition.get("id", ""))] = definition
	var ids: Array = _defs.keys()
	ids.sort()
	var catalog_ids: Array = (_catalog.get("UNIT_IDS") as Array).duplicate()
	catalog_ids.sort()
	h.expect(ids == catalog_ids, "catalog_units_match_data", "CrimsonVFXCatalog.UNIT_IDS must list exactly the race=crimson units in race_units.json (data %s, catalog %s)" % [str(ids), str(catalog_ids)])
	var route_script: Script = load("res://effects/BossProceduralVFX3D.gd")
	var unit_skills: Array = route_script.get("UNIT_SKILLS")
	var skill_effects: Array = _catalog.call("all_skill_effects")
	for effect_id: String in _catalog.get("BASIC_EFFECTS"):
		h.expect(effect_id in unit_skills, "basic_routed_" + effect_id, "%s must route to UnitSkillVFXComposer3D, not the Boss fallback" % effect_id)
	var kinds: Dictionary = {}
	for unit_id: String in _defs:
		var definition: Dictionary = _defs[unit_id]
		var skill_id := str(definition.get("skill_id", ""))
		h.expect(skill_id in skill_effects, "skill_catalogued_" + unit_id, "%s skill %s has no crimson presentation entry" % [unit_id, skill_id])
		h.expect(skill_id in unit_skills, "skill_routed_" + unit_id, "%s skill %s would fall into BossSkillVFXComposer3D's grey fallback" % [unit_id, skill_id])
		if float(definition.get("range", 1)) > 1.0:
			var projectile: Dictionary = _catalog.call("projectile_for", unit_id)
			var kind := str(projectile.get("kind", ""))
			h.expect((_catalog.get("PROJECTILES") as Dictionary).has(unit_id), "projectile_authored_" + unit_id, "Ranged %s must have its own projectile, not the default" % unit_id)
			h.expect(not kinds.has(kind), "projectile_distinct_" + unit_id, "%s shares projectile '%s' with %s" % [unit_id, kind, str(kinds.get(kind, ""))])
			kinds[kind] = unit_id


# ── 2. 普攻（Director 的 cue 入口）──────────────────────────────────────────

func _check_basic_attacks() -> void:
	var setup := _battle()
	var battle: Control = setup.battle
	var composer: Node = setup.composer
	var enemy := _fighter("enemy_target", _unit_def("human_swordsman", 1), "enemy", Vector2(720.0, 270.0))
	var players: Array = []
	var x := 260.0
	for unit_id: String in _defs:
		players.append(_fighter("p_" + unit_id, _unit_def(unit_id, 1), "player", Vector2(x, 250.0)))
		x += 24.0
	players.append(_fighter("p_human_archer", _unit_def("human_archer", 1), "player", Vector2(300.0, 330.0)))
	var state := {"player": players, "enemy": [enemy], "visual_events": []}
	_seed(battle, state)
	# 记录每次 cue 期间真正进树的节点（含当帧就 queue_free 的空节点 —— 它们也占并发预算）。
	var entered: Array = []
	composer.child_entered_tree.connect(func(node: Node) -> void:
		var script: Variant = node.get_script()
		entered.append((script as Script).resource_path if script is Script else node.get_class()))
	for unit_id: String in _defs:
		var uid := "p_" + unit_id
		var ranged := float((_defs[unit_id] as Dictionary).get("range", 1)) > 1.0
		var before := _scripts_under(composer, ATTACK_PATH).size()
		var race_before := _scripts_under(composer, RACE_ATTACK_PATH).size()
		entered.clear()
		battle.call("cue_play_basic_attack", uid, "enemy_target", ranged)
		var spawned := _scripts_under(composer, ATTACK_PATH)
		var melee_kind := str(_catalog.call("melee_kind_for", unit_id))
		h.expect(_scripts_under(composer, RACE_ATTACK_PATH).size() == race_before, "no_generic_bolt_" + unit_id, "%s must not fall back to the generic race bolt/slash" % unit_id)
		if not ranged and melee_kind.is_empty():
			# 赤卫：与其它玩家近战棋子同规则，只有模型动作 + 伤害数字。
			h.expect(spawned.size() == before and not ATTACK_PATH in entered, "melee_plain_" + unit_id, "%s has no signature weapon and must not spawn even an empty crimson attack node" % unit_id)
			continue
		if not h.expect(spawned.size() == before + 1, "attack_spawned_" + unit_id, "%s basic attack must spawn exactly one VFXCrimsonAttack3D" % unit_id):
			continue
		var debug: Dictionary = (spawned[spawned.size() - 1] as Node).call("get_debug_state")
		if ranged:
			var expected_kind := str((_catalog.call("projectile_for", unit_id) as Dictionary).get("kind", ""))
			h.expect(str(debug.get("kind", "")) == expected_kind and str(debug.get("mode", "")) == "ranged", "projectile_kind_" + unit_id, "%s fired '%s' instead of '%s'" % [unit_id, str(debug.get("kind", "")), expected_kind])
			var cue_flight := float(battle.call("cue_ranged_flight_time", uid, "enemy_target"))
			h.expect(absf(float(debug.get("flight_time", -1.0)) - cue_flight) < 0.002, "flight_parity_" + unit_id, "Projectile flight %.3fs must equal the damage-number delay %.3fs" % [float(debug.get("flight_time", -1.0)), cue_flight])
		else:
			h.expect(str(debug.get("kind", "")) == melee_kind, "melee_kind_" + unit_id, "%s melee must draw '%s'" % [unit_id, melee_kind])
	# 被动表现的命中延时按数据射程分近战/远程：回放里 range_px = range×72，近战也是 72，
	# 拿像素阈值判会把破甲者/战鼓使当成远程，表现晚到 0.3s 以上。
	for f: Dictionary in players:
		f["range_px"] = float((f.def as Dictionary).get("range", 1)) * 72.0
	battle.call("_refresh_battle_vfx", state)
	var windup := float((load("res://effects/runtime/presentation/adapters/LegacyBattleVfxAdapter.gd") as Script).get("WINDUP_SEC"))
	h.expect(is_equal_approx(float(battle.call("_crimson_hit_delay", "p_armbreaker", "enemy_target")), 0.10), "hit_delay_melee_replay", "A melee hit must resolve on the swing (0.10s) even with replay-scaled range_px")
	var ranged_expected := windup + float(battle.call("cue_ranged_flight_time", "p_hunter", "enemy_target"))
	h.expect(absf(float(battle.call("_crimson_hit_delay", "p_hunter", "enemy_target")) - ranged_expected) < 0.002, "hit_delay_ranged_replay", "A ranged hit must resolve after windup + projectile flight")
	# 人族普攻不受赤律接线影响。
	var crimson_before := _scripts_under(composer, ATTACK_PATH).size()
	battle.call("cue_play_basic_attack", "p_human_archer", "enemy_target", true)
	h.expect(_scripts_under(composer, ATTACK_PATH).size() == crimson_before, "human_route_unchanged", "A human ranged attack must not reach the crimson attack module")
	# 生命周期：所有普攻节点在最长飞行 + 收尾内自行释放。
	await create_timer(1.6).timeout
	h.expect(_scripts_under(composer, ATTACK_PATH).is_empty(), "attack_lifecycle", "Crimson attack nodes must free themselves after impact")
	battle.queue_free()
	await process_frame


# ── 3. 主动技（skill_ready 上升沿）────────────────────────────────────────

func _check_active_skills() -> void:
	# 赤舞者四星：记录是「队友,自己」两个 uid，两处都要画。
	var dancer_def := _unit_def("dancer", 4)
	var result := await _cast("dancer", dancer_def, {"vfx_skill_target_uid": "p_ally,p_caster"}, [])
	var debug: Dictionary = result.get("debug", {})
	h.expect(str(debug.get("skill", "")) == "random_ally_buff" and int(debug.get("targets", 0)) == 2, "dancer_star4_two_targets", "Four-star dancer must draw both recorded recipients (got %s)" % str(debug))
	# 音符挂到增益结束：时长来自数据 buff_duration，不是写死的表现长度。
	h.expect(is_equal_approx(float(debug.get("duration", -1.0)), float(dancer_def.get("buff_duration", -2.0))) and int(debug.get("notes", 0)) >= 2 * 2, "dancer_notes_last_buff", "Buff notes must last the real buff_duration on every recipient (got %s)" % str(debug))
	h.expect(float(debug.get("end_time", 0.0)) >= float(dancer_def.get("buff_duration", 3.0)), "dancer_notes_lifetime", "The effect must stay alive until the buff ends")
	result = await _cast("dancer", _unit_def("dancer", 1), {"vfx_skill_target_uid": "p_ally"}, [])
	h.expect(int((result.get("debug", {}) as Dictionary).get("targets", 0)) == 1, "dancer_single_target", "Legacy single-uid record must still draw one recipient")
	result = await _cast("dancer", _unit_def("dancer", 1), {"vfx_skill_target_uid": ""}, [])
	h.expect(int((result.get("debug", {}) as Dictionary).get("targets", -1)) == 0, "dancer_no_guess", "No record must not be replaced by a guessed nearest enemy")

	# 霜印使：中心 = 记录目标；半径 = 数据 aoe_radius 经战场映射；冰刺只长在真带 ice_vulnerable 的范围内敌人脚下。
	var icey_def := _unit_def("Icey", 1)
	var enemies := [
		{"uid": "e_center", "pos": Vector2(700.0, 260.0), "statuses": {"ice_vulnerable": {"remaining": 3.0}}},
		{"uid": "e_near", "pos": Vector2(760.0, 290.0), "statuses": {"ice_vulnerable": {"remaining": 3.0}}},
		{"uid": "e_near_immune", "pos": Vector2(650.0, 300.0), "statuses": {}},
		{"uid": "e_far", "pos": Vector2(700.0, 470.0), "statuses": {"ice_vulnerable": {"remaining": 3.0}}},
	]
	result = await _cast("Icey", icey_def, {"vfx_skill_target_uid": "e_center"}, enemies)
	debug = result.get("debug", {})
	var battle_radius: Vector2 = result.get("expected_radius", Vector2.ZERO)
	h.expect(str(debug.get("skill", "")) == "frost_status", "frost_routed", "Icey must reach VFXCrimsonSkill3D")
	h.expect((debug.get("world_radius", Vector2.ZERO) as Vector2).is_equal_approx(battle_radius) and battle_radius.x > 0.0, "frost_radius_mapped", "Seal radius %s must equal BattleVfx's sim→world mapping %s of aoe_radius" % [str(debug.get("world_radius", Vector2.ZERO)), str(battle_radius)])
	var center_foot: Vector3 = result.get("foot_e_center", Vector3.INF)
	var center: Vector3 = debug.get("center", Vector3.ZERO)
	h.expect(Vector2(center.x, center.z).is_equal_approx(Vector2(center_foot.x, center_foot.z)), "frost_center_on_record", "Seal must center on the recorded target's feet")
	h.expect(int(debug.get("targets", -1)) == 2, "frost_affected_only", "Ice must form on exactly the 2 enemies inside the radius AND ice_vulnerable (got %s)" % str(debug.get("targets", -1)))
	result = await _cast("Icey", icey_def, {"vfx_skill_target_uid": ""}, enemies)
	h.expect(not bool(result.get("spawned", true)), "frost_no_target_no_seal", "Without a recorded target the seal must not be drawn under someone else")

	# 赤灯使：三个记录目标，其中一个免控（没有 silence 状态）→ 3 道光线、2 枚封印。
	var lantern_def := _unit_def("lattern", 1)
	var silenced := [
		{"uid": "e1", "pos": Vector2(690.0, 230.0), "statuses": {"silence": {"remaining": 1.5}}},
		{"uid": "e2", "pos": Vector2(730.0, 280.0), "statuses": {}},
		{"uid": "e3", "pos": Vector2(700.0, 330.0), "statuses": {"silence": {"remaining": 1.5}}},
	]
	result = await _cast("lattern", lantern_def, {"vfx_skill_target_uid": "e1,e2,e3"}, silenced)
	debug = result.get("debug", {})
	h.expect(int(debug.get("targets", 0)) == 3 and int(debug.get("silenced_flashes", -1)) == 2, "lantern_seals_only_silenced", "The strong silence flash must appear only on targets that actually carry silence (got %s)" % str(debug))


# 造一场「施法者 + 友军 + 指定敌人」的快照，种子帧后把 skill_ready 抬高制造上升沿。
func _cast(unit_id: String, definition: Dictionary, caster_extra: Dictionary, enemies: Array) -> Dictionary:
	var setup := _battle()
	var battle: Control = setup.battle
	var composer: Node = setup.composer
	var caster := _fighter("p_caster", definition, "player", Vector2(320.0, 260.0))
	var ally := _fighter("p_ally", _unit_def("crimson", 1), "player", Vector2(380.0, 300.0))
	var enemy_fighters: Array = []
	for spec: Dictionary in enemies:
		var f := _fighter(str(spec.uid), _unit_def("human_swordsman", 1), "enemy", spec.pos)
		f["statuses"] = spec.get("statuses", {})
		enemy_fighters.append(f)
	if enemy_fighters.is_empty():
		enemy_fighters.append(_fighter("e_idle", _unit_def("human_swordsman", 1), "enemy", Vector2(720.0, 260.0)))
	var state := {"player": [caster, ally], "enemy": enemy_fighters, "visual_events": []}
	_seed(battle, state)
	var before := _scripts_under(composer, SKILL_PATH).size()
	caster["skill_ready"] = 3.0
	caster.merge(caster_extra, true)
	battle.call("_refresh_battle_vfx", state)
	var spawned := _scripts_under(composer, SKILL_PATH)
	var out := {"spawned": spawned.size() > before}
	if spawned.size() > before:
		out["debug"] = (spawned[spawned.size() - 1] as Node).call("get_debug_state")
	out["expected_radius"] = battle.call("_guardian_taunt_world_radius", float(definition.get("aoe_radius", 144.0)))
	var units: Dictionary = battle.get("_vfx_prev_units")
	for id: String in units:
		out["foot_" + id] = (units[id] as Dictionary).get("world_foot", Vector3.ZERO)
	battle.queue_free()
	await process_frame
	return out


# ── 4. 真实模拟事件 → BattleVfx._play_visual_events ───────────────────────

func _check_natural_events() -> void:
	var fixture: Script = load("res://scripts/qa/FixedBattleFixture.gd")
	var simulator: Script = load("res://scripts/battle/BattleSimulator.gd")
	fixture.set("lineup_b_override", CRIMSON_LINEUP)
	var found := {}
	var replay: Dictionary = {}
	var first_events := {}
	for seed_value in [20261009, 20261010, 20261011]:
		fixture.call("setup_match_state", PVP_ROUND, seed_value)
		replay = simulator.call("compute_team_replay", 0, "crimson-contract:%d" % seed_value)
		if seed_value == 20261009:
			fixture.call("setup_match_state", PVP_ROUND, seed_value)
			var repeat: Dictionary = simulator.call("compute_team_replay", 0, "crimson-contract:%d" % seed_value)
			h.expect(JSON.stringify(repeat) == JSON.stringify(replay), "replay_repeatable", "Adding presentation events must keep the crimson replay byte-identical across repeated runs")
		_scan_events(replay, found, first_events)
		if found.size() >= 4:
			break
	fixture.set("lineup_b_override", [])
	for kind in ["block_guard", "stacking_def_break", "current_hp_strike", "line_pierce"]:
		h.expect(found.has(kind), "natural_" + kind, "A natural crimson battle must produce %s presentation events" % kind)
	# 战鼓使的鼓点不再补表现事件（头顶音符徽章已表达层数；鼓声在普攻音波里）。
	h.expect(not found.has("team_random_stack"), "drum_no_extra_event", "Drum stacks must not add presentation events any more")
	_check_active_edges(replay)
	for kind: String in first_events:
		var sample: Dictionary = first_events[kind]
		await _feed_event(kind, sample.replay, int(sample.tick), sample.events)


func _scan_events(replay: Dictionary, found: Dictionary, first_events: Dictionary) -> void:
	var frame_events: Array = replay.get("frame_events", [])
	for tick in frame_events.size():
		var bucket: Array = frame_events[tick]
		var groups: Dictionary = {}
		for value in bucket:
			if not value is Dictionary:
				continue
			var event: Dictionary = value
			var kind := ""
			var type := str(event.get("type", ""))
			var skill_id := str(event.get("skill_id", ""))
			if type == "unit_skill_proc" and skill_id in ["block_guard", "stacking_def_break", "team_random_stack"]:
				kind = skill_id
			elif type == "impact" and skill_id == "line_pierce":
				kind = "line_pierce"
			elif type == "hit_number" and skill_id == "current_hp_strike" and str(event.get("kind", "dmg")) == "dmg":
				kind = "current_hp_strike"
			if kind.is_empty():
				continue
			found[kind] = int(found.get(kind, 0)) + 1
			# 同一 tick 里按「技能 + 出手者」分组：BattleVfx 也是按出手者把一击的几条事件归成一次表现。
			var group_key := "%s|%s" % [kind, str(event.get("source_uid", ""))]
			if not groups.has(group_key):
				groups[group_key] = []
			(groups[group_key] as Array).append(event)
		for group_key: String in groups:
			var kind := group_key.get_slice("|", 0)
			var events: Array = groups[group_key]
			if kind != "line_pierce":
				events = [events[0]]
			# 穿透：优先挑一次贯穿了 2 个以上目标的那一发。
			var better: bool = kind == "line_pierce" and first_events.has(kind) and events.size() > (first_events[kind].events as Array).size()
			if not first_events.has(kind) or better:
				first_events[kind] = {"replay": replay, "tick": tick, "events": events}


func _check_active_edges(replay: Dictionary) -> void:
	var roster: Dictionary = replay.get("roster", {})
	var frames: Array = replay.get("frames", [])
	var edges := {}
	var last := {}
	for frame: Array in frames:
		for row: Array in frame:
			var uid := str(row[0])
			var unit_id := str((roster.get(uid, {}) as Dictionary).get("id", ""))
			if not unit_id in ["dancer", "Icey", "lattern"]:
				continue
			var ready := float(row[6])
			if last.has(uid) and ready > float(last[uid]) + 0.1:
				edges[unit_id] = int(edges.get(unit_id, 0)) + 1
			last[uid] = ready
	for unit_id in ["dancer", "Icey", "lattern"]:
		h.expect(int(edges.get(unit_id, 0)) > 0, "natural_cast_edge_" + unit_id, "%s must produce skill_ready rising edges in a natural battle" % unit_id)


func _feed_event(kind: String, replay: Dictionary, tick: int, events: Array) -> void:
	var setup := _battle()
	var battle: Control = setup.battle
	var composer: Node = setup.composer
	var state := _state_from_replay(replay, tick)
	if kind == "line_pierce" and events.size() < 2:
		# 自然战斗里这一发只穿了 1 个：按真实事件的形状再补一个被贯穿目标，
		# 验「同一发的多条 impact 归成一条贯穿线」。
		var source_team := ""
		var hit_uid := str((events[0] as Dictionary).get("target_uids", [""])[0])
		for side in ["player", "enemy"]:
			for f: Dictionary in state[side]:
				if str(f.uid) == str((events[0] as Dictionary).get("source_uid", "")):
					source_team = str(f.team)
		for side in ["player", "enemy"]:
			for f: Dictionary in state[side]:
				if events.size() < 2 and str(f.team) != source_team and bool(f.alive) and str(f.uid) != hit_uid:
					var extra: Dictionary = (events[0] as Dictionary).duplicate(true)
					extra["target_uids"] = [str(f.uid)]
					extra["target_uid"] = str(f.uid)
					extra["ordinal"] = int(extra.get("ordinal", 0)) + 1
					extra["event_key"] = str(extra.get("event_key", "")) + ":b"
					events = events + [extra]
	_seed(battle, state)
	var before := _scripts_under(composer, SKILL_PATH).size()
	(state.visual_events as Array).append_array(events.duplicate(true))
	battle.call("_refresh_battle_vfx", state)
	var spawned := _scripts_under(composer, SKILL_PATH)
	if not h.expect(spawned.size() == before + 1, "event_spawn_" + kind, "One real %s event group must draw exactly one crimson effect (got %d)" % [kind, spawned.size() - before]):
		battle.queue_free()
		await process_frame
		return
	var debug: Dictionary = (spawned[spawned.size() - 1] as Node).call("get_debug_state")
	var event: Dictionary = events[0]
	var source_uid := str(event.get("source_uid", ""))
	var target_uids: Array = event.get("target_uids", [])
	var target_uid := str(target_uids[0]) if not target_uids.is_empty() else str(event.get("target_uid", ""))
	h.expect(str(debug.get("skill", "")) == kind, "event_skill_" + kind, "Event %s reached skill '%s'" % [kind, str(debug.get("skill", ""))])
	match kind:
		"block_guard":
			# source = 格挡者，target = 被挡的攻击者；延时 = 攻击者那一击的命中时刻。
			var expected := float(battle.call("_crimson_hit_delay", target_uid, source_uid))
			h.expect(absf(float(debug.get("delay", -1.0)) - expected) < 0.002, "block_delay_on_hit", "Block wall must appear when the blocked hit lands (%.3f vs %.3f)" % [float(debug.get("delay", -1.0)), expected])
		"stacking_def_break":
			h.expect(int(debug.get("stacks", -1)) == int(event.get("stacks", -2)), "def_break_stacks", "Crack size must follow the simulator's accumulated break stacks")
		"current_hp_strike":
			h.expect(not bool(debug.get("execute", true)), "hunter_single_no_execute", "One damage line in a hit is not an execute")
		"line_pierce":
			h.expect(events.size() >= 2 and int(debug.get("targets", -1)) == mini(events.size(), 6), "pierce_targets_in_group", "Pierce must chain every target the bolt actually passed (%d vs %d)" % [int(debug.get("targets", -1)), events.size()])
	if kind == "current_hp_strike":
		# 四星斩杀：同一击第二条 current_hp_strike 数字 → 额外的血刺。
		var doubled: Array = [events[0].duplicate(true), events[0].duplicate(true)]
		(doubled[1] as Dictionary)["ordinal"] = int((doubled[0] as Dictionary).get("ordinal", 0)) + 1
		var count := _scripts_under(composer, SKILL_PATH).size()
		(state.visual_events as Array).append_array(doubled)
		battle.call("_refresh_battle_vfx", state)
		var after := _scripts_under(composer, SKILL_PATH)
		if h.expect(after.size() == count + 1, "hunter_execute_grouped", "Two strike lines of one hit must group into ONE effect"):
			h.expect(bool((after[after.size() - 1] as Node).call("get_debug_state").get("execute", false)), "hunter_execute_flag", "Grouped double strike must draw the execute spike")
	# 认不得的 uid（旧回放 / 已离场）：静默跳过，不报错不乱画。
	var stray := (events[0] as Dictionary).duplicate(true)
	stray["source_uid"] = "missing_uid"
	stray["target_uid"] = "missing_uid"
	stray["target_uids"] = ["missing_uid"]
	var count_before := _scripts_under(composer, SKILL_PATH).size()
	(state.visual_events as Array).append(stray)
	battle.call("_refresh_battle_vfx", state)
	h.expect(_scripts_under(composer, SKILL_PATH).size() == count_before, "unknown_uid_skipped_" + kind, "An event naming unknown units must draw nothing")
	await create_timer(2.2).timeout
	h.expect(_scripts_under(composer, SKILL_PATH).is_empty(), "skill_lifecycle_" + kind, "Crimson skill effects must free themselves")
	battle.queue_free()
	await process_frame


func _state_from_replay(replay: Dictionary, tick: int) -> Dictionary:
	var roster: Dictionary = replay.get("roster", {})
	var frame: Array = (replay.get("frames", []) as Array)[tick]
	var state := {"player": [], "enemy": [], "visual_events": []}
	for row: Array in frame:
		var uid := str(row[0])
		var r: Dictionary = roster.get(uid, {})
		var definition: Dictionary = r.get("def", {})
		var f := {"uid": uid, "id": str(r.get("id", "")), "name": str(r.get("name", "")), "team": str(r.get("team", "")),
			"lane": int(r.get("lane", 0)), "star": int(r.get("star", 1)), "max_hp": int(r.get("max_hp", 1)),
			"pos": Vector2(float(row[1]), float(row[2])), "hp": int(row[3]), "alive": bool(row[4]),
			"attack_count": int(row[5]), "skill_ready": float(row[6]), "shield": int(row[7]), "skill_stacks": int(row[8]),
			"statuses": row[9], "def": definition,
			# 与 BattleScreen 回放同一口径：range × ATTACK_RANGE_SCALE。
			"range_px": float(definition.get("range", 1)) * 72.0,
			"vfx_attack_target_uid": str(row[11]), "vfx_skill_target_uid": str(row[12])}
		(state[f.team] as Array).append(f)
	return state


# ── 5. 低画质截断与关键通道 ───────────────────────────────────────────────

func _check_budget_and_critical(budget: Script) -> void:
	budget.set("tier", 0)
	var setup := _battle()
	var battle: Control = setup.battle
	var composer: Node = setup.composer
	var caster := _fighter("p_lantern", _unit_def("lattern", 1), "player", Vector2(320.0, 260.0))
	var dancer := _fighter("p_dancer", _unit_def("dancer", 1), "player", Vector2(300.0, 320.0))
	var enemy_list: Array = []
	var uids := PackedStringArray()
	for i in 6:
		var uid := "e%d" % i
		var f := _fighter(uid, _unit_def("human_swordsman", 1), "enemy", Vector2(680.0 + 20.0 * float(i), 200.0 + 30.0 * float(i)))
		f["statuses"] = {"silence": {"remaining": 1.5}}
		enemy_list.append(f)
		uids.append(uid)
	var state := {"player": [caster, dancer], "enemy": enemy_list, "visual_events": []}
	_seed(battle, state)
	# 把全局并发上限占满（LOW 档 normal 优先级 ≈ 14），再让两种技能同时施放。
	var block_root: Script = load("res://effects/vfx3d/VFXBlockRoot.gd")
	var fillers: Array = []
	var filler_parent := Node3D.new()
	root.add_child(filler_parent)
	while bool(block_root.call("can_spawn_block")):
		var filler: Node = block_root.call("spawn_block", block_root, filler_parent)
		if filler == null:
			break
		fillers.append(filler)
	var before := _scripts_under(composer, SKILL_PATH).size()
	caster["skill_ready"] = 3.0
	caster["vfx_skill_target_uid"] = ",".join(uids)
	dancer["skill_ready"] = 3.0
	dancer["vfx_skill_target_uid"] = "p_lantern"
	battle.call("_refresh_battle_vfx", state)
	var spawned := _scripts_under(composer, SKILL_PATH)
	var skills: Array = []
	var lantern_debug: Dictionary = {}
	for node: Node in spawned.slice(before):
		var debug: Dictionary = node.call("get_debug_state")
		skills.append(str(debug.get("skill", "")))
		if str(debug.get("skill", "")) == "aoe_silence":
			lantern_debug = debug
	h.expect("aoe_silence" in skills, "lantern_critical_under_saturation", "Mass silence is a control cue and must survive a saturated effect budget")
	h.expect(not "random_ally_buff" in skills, "normal_cue_respects_cap", "An ordinary buff cue must obey the saturated budget")
	h.expect(int(lantern_debug.get("targets", 99)) <= 4, "low_tier_target_cap", "LOW tier must draw at most 4 of 6 silence targets (got %s)" % str(lantern_debug.get("targets", "?")))
	for filler: Node in fillers:
		filler.queue_free()
	filler_parent.queue_free()
	battle.queue_free()
	await process_frame
	await process_frame
	h.expect(_scripts_under(root, SKILL_PATH).is_empty() and _scripts_under(root, ATTACK_PATH).is_empty(), "owner_cleanup", "Freeing the battle must leave no crimson nodes behind")


# ── 工具 ──────────────────────────────────────────────────────────────────

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
	return {"battle": battle, "route": route, "composer": route.get_node("UnitSkillVFXComposer3D")}


func _seed(battle: Control, state: Dictionary) -> void:
	battle.set("_state", state)
	battle.call("_refresh_battle_vfx", state)
	battle.call("_refresh_battle_vfx", state)


func _unit_def(unit_id: String, star: int) -> Dictionary:
	var parsed: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/units/race_units.json"))
	for definition: Dictionary in parsed.get("units", []):
		if str(definition.get("id", "")) == unit_id:
			return _factory.call("apply_star_stats", definition, star)
	return {"id": unit_id}


func _fighter(uid: String, definition: Dictionary, team: String, pos: Vector2) -> Dictionary:
	return {"uid": uid, "id": str(definition.get("id", "")), "name": str(definition.get("name", "")), "team": team, "lane": 0,
		"hp": 1000, "max_hp": 1000, "shield": 0, "alive": true, "pos": pos, "def": definition, "statuses": {},
		"range_px": 32.0 + maxf(0.0, float(definition.get("range", 1)) - 1.0) * 72.0, "skill_ready": 0.0,
		"attack_count": 0, "star": int(definition.get("star", 1)), "vfx_attack_target_uid": "", "vfx_skill_target_uid": ""}


func _scripts_under(node: Node, path: String) -> Array:
	var out: Array = []
	_collect_scripts(node, path, out)
	return out


func _collect_scripts(node: Node, path: String, out: Array) -> void:
	if node == null or not is_instance_valid(node) or node.is_queued_for_deletion():
		return
	var script: Variant = node.get_script()
	if script is Script and (script as Script).resource_path == path:
		out.append(node)
	for child in node.get_children():
		_collect_scripts(child, path, out)
