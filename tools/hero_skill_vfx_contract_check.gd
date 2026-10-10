extends SceneTree

# 黑龙（black_hole）/ 神王（global_divine_blast）/ 母灵（unique_death_execute）特效契约检查。
# Run with: Godot --headless --path . --script res://tools/hero_skill_vfx_contract_check.gd
#
# 只走生产入口：
#   · 先用固定 D0 阵容（FixedBattleFixture：a 队有神王，b 队有黑龙、母灵）在 PVP 回合跑
#     真实模拟，取模拟器真正写进回放的记录：黑龙被拉名单（第 12 列）、神王目标、
#     母灵 mother_execute 事件与魂火计数旁路（undead_mother_count_events）；
#   · 再把回放帧原样还原成快照，喂给 BattleVfx._refresh_battle_vfx（skill_ready 上升沿 /
#     _play_visual_events），断言生成的 VFXHeroSkill3D 读到的就是那份记录。
# 另外覆盖：被拉名单 = 真被眩晕的人、黑洞半径 = 数据 220 的战场映射、神王后续每跳的脉冲
# （施法同帧那一跳不重复）、裁决者仍是落雷、Boss 重击 / 无目标空翻、魂火计数回放与回退、
# 低画质截断与关键通道、表现层不碰 RngService、生命周期自清。
# 画面好不好看不在这里判 —— 那是 effects/preview/HeroSkillVFXPreview.tscn 的事。

const Harness := preload("res://tools/CheckHarness.gd")
const HERO_PATH := "res://effects/vfx3d/units/VFXHeroSkill3D.gd"
const ARC_PATH := "res://effects/vfx3d/VFXLightningArc.gd"
const PVP_ROUND := 6
const SEEDS := [20261010, 20261011, 20261012, 20261013, 20261014, 20261015, 20261016, 20261017, 20261018, 20261019, 20261020, 20261021]

var h := Harness.new("hero_skill_vfx_contract")
var _factory: Script


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	for service_name in ["NetworkService", "RealtimeService", "AnalyticsService", "ChatService", "AnnouncementService", "MailService"]:
		var service := root.get_node_or_null(service_name)
		if service != null:
			service.set_process(false)
	root.get_node("DataRegistry").call("load_all")
	_factory = load("res://scripts/units/UnitFactory.gd")
	var budget: Script = load("res://effects/vfx3d/core/VFXQualityBudget.gd")
	budget.set("tier", 1)
	_check_routes()
	var samples := _natural_samples()
	await _check_black_hole(samples)
	await _check_god_king(samples)
	await _check_mother(samples)
	await _check_variants()
	_check_badge()
	_check_replay_apply(samples)
	await _check_budget(budget)
	budget.set("tier", 1)
	h.finish(self)


# ── 1. 路由 ───────────────────────────────────────────────────────────────

func _check_routes() -> void:
	var unit_skills: Array = (load("res://effects/BossProceduralVFX3D.gd") as Script).get("UNIT_SKILLS")
	for effect in ["black_hole", "global_divine_blast", "global_divine_blast_pulse", "unique_death_execute"]:
		h.expect(effect in unit_skills, "routed_" + effect, "%s must route to UnitSkillVFXComposer3D (Boss fallback is grey)" % effect)
	var warm: Script = load("res://scripts/assets/BattleRenderWarmup.gd")
	h.expect(not "black_hole" in (warm.get("DIRECT_PACK_ROUTES") as Array), "warmup_full_composer", "black_hole must be warmed through the full composer, not the retired OGA card")


# ── 2. 真实模拟 → 记录 ────────────────────────────────────────────────────

func _natural_samples() -> Dictionary:
	var fixture: Script = load("res://scripts/qa/FixedBattleFixture.gd")
	var simulator: Script = load("res://scripts/battle/BattleSimulator.gd")
	var out := {"pull": [], "pull_empty": 0, "king": [], "pulse": [], "execute": [], "replays": []}
	for seed_value in SEEDS:
		fixture.call("setup_match_state", PVP_ROUND, seed_value)
		var replay: Dictionary = simulator.call("compute_team_replay", 0, "hero-contract:%d" % seed_value)
		if seed_value == SEEDS[0]:
			fixture.call("setup_match_state", PVP_ROUND, seed_value)
			var repeat: Dictionary = simulator.call("compute_team_replay", 0, "hero-contract:%d" % seed_value)
			h.expect(JSON.stringify(repeat) == JSON.stringify(replay), "replay_repeatable", "Presentation records must keep the replay byte-identical across repeated runs")
		out.replays.append(replay)
		_scan(replay, out)
		if (out.replays as Array).size() >= 4 and not (out.execute as Array).is_empty() and not (out.pull as Array).is_empty():
			break
	h.expect(not (out.pull as Array).is_empty(), "natural_black_hole_record", "A natural battle must record who the black hole pulled (column 12)")
	h.expect(not (out.king as Array).is_empty(), "natural_god_king_cast", "A natural battle must contain a God King cast with recorded targets")
	h.expect(not (out.pulse as Array).is_empty(), "natural_god_king_pulses", "God King's later damage ticks must arrive as hit_number events")
	# 母灵要攒满 5 次本席位击杀，D0 阵容的自然战斗里不一定攒得到；处决本身由下面的
	# 模拟器直调覆盖（_mother_sim_sample），这里只要求计数旁路一定存在。
	var has_counts := false
	for replay: Dictionary in out.replays:
		has_counts = has_counts or not (replay.get("undead_mother_count_events", []) as Array).is_empty()
	h.expect(has_counts, "natural_mother_counts", "A natural battle with a Mother Wisp must carry undead_mother_count_events")
	return out


func _scan(replay: Dictionary, out: Dictionary) -> void:
	var roster: Dictionary = replay.get("roster", {})
	var frames: Array = replay.get("frames", [])
	var events: Array = replay.get("frame_events", [])
	var last := {}
	for tick in frames.size():
		for row: Array in frames[tick]:
			var uid := str(row[0])
			var unit_id := str((roster.get(uid, {}) as Dictionary).get("id", ""))
			var ready := float(row[6])
			var edge: bool = last.has(uid) and ready > float(last[uid]) + 0.1
			last[uid] = ready
			if not edge:
				continue
			if unit_id == "dark_dragon":
				if str(row[12]).is_empty():
					out.pull_empty = int(out.pull_empty) + 1
				else:
					(out.pull as Array).append({"replay": replay, "tick": tick, "uid": uid, "record": str(row[12])})
			elif unit_id == "god_king" and not str(row[12]).is_empty():
				(out.king as Array).append({"replay": replay, "tick": tick, "uid": uid, "record": str(row[12])})
		if tick < events.size():
			for value in events[tick]:
				if not value is Dictionary:
					continue
				var event: Dictionary = value
				if str(event.get("type", "")) == "mother_execute":
					(out.execute as Array).append({"replay": replay, "tick": tick, "event": event})
				elif str(event.get("type", "")) == "hit_number" and str(event.get("skill_id", "")) == "global_divine_blast" and str(event.get("kind", "dmg")) == "dmg":
					(out.pulse as Array).append({"replay": replay, "tick": tick, "event": event})


# ── 3. 黑龙 ───────────────────────────────────────────────────────────────

func _check_black_hole(samples: Dictionary) -> void:
	if (samples.pull as Array).is_empty():
		return
	var sample: Dictionary = samples.pull[0]
	var replay: Dictionary = sample.replay
	var tick := int(sample.tick)
	var record := str(sample.record)
	var uids := record.split(",")
	var frame: Array = replay.frames[tick]
	var prev: Array = replay.frames[tick - 1]
	var dragon_pos := Vector2.ZERO
	for row: Array in prev:
		if str(row[0]) == str(sample.uid):
			dragon_pos = Vector2(float(row[1]), float(row[2]))
	var all_stunned := true
	var all_enemy := true
	var all_moved := true
	for uid in uids:
		var now_row := _row(frame, uid)
		var before_row := _row(prev, uid)
		if now_row.is_empty() or before_row.is_empty():
			all_stunned = false
			continue
		all_stunned = all_stunned and (now_row[9] as Dictionary).has("stun")
		all_enemy = all_enemy and str((replay.roster.get(uid, {}) as Dictionary).get("team", "")) != str((replay.roster.get(str(sample.uid), {}) as Dictionary).get("team", ""))
		var before_pos := Vector2(float(before_row[1]), float(before_row[2]))
		var now_pos := Vector2(float(now_row[1]), float(now_row[2]))
		all_moved = all_moved and now_pos.distance_to(dragon_pos) < before_pos.distance_to(dragon_pos) - 1.0
	h.expect(all_enemy and all_stunned, "pull_record_is_stunned_enemies", "Every recorded pulled uid must be an enemy that now carries stun (%s)" % record)
	h.expect(all_moved, "pull_record_moved_inward", "Every recorded uid must actually have been dragged toward the dragon")
	# 第 12 列里没有记录的敌人不该被拉：本帧新挂眩晕、又在 220 内的敌人都必须在名单里。
	var missing := 0
	for row: Array in frame:
		var uid := str(row[0])
		if uid in uids or not bool(row[4]):
			continue
		var before_row := _row(prev, uid)
		if before_row.is_empty() or (before_row[9] as Dictionary).has("stun"):
			continue
		if (row[9] as Dictionary).has("stun") and Vector2(float(before_row[1]), float(before_row[2])).distance_to(dragon_pos) <= 220.0 and str((replay.roster.get(uid, {}) as Dictionary).get("team", "")) != str((replay.roster.get(str(sample.uid), {}) as Dictionary).get("team", "")):
			missing += 1
	h.expect(missing == 0, "pull_record_complete", "No newly stunned enemy within 220 may be missing from the pull record")

	var result := await _feed_cast(replay, tick)
	var debug: Dictionary = result.get("debug", {})
	h.expect(str(debug.get("skill", "")) == "black_hole", "black_hole_hero_module", "Black hole must reach VFXHeroSkill3D (got %s)" % str(debug))
	h.expect(int(debug.get("pulled", -1)) == mini(uids.size(), 6) and int(debug.get("locks", -1)) == int(debug.get("pulled", -2)), "black_hole_draws_record", "Drag smears / locks must be drawn for exactly the recorded pulls (%d vs %s)" % [uids.size(), str(debug)])
	h.expect(debug.has("hole_at"), "black_hole_volumetric_core", "Black hole must build the 3D singularity above the dragon")
	h.expect((debug.get("radius", Vector2.ZERO) as Vector2).is_equal_approx(result.get("radius_220", Vector2.ONE)), "black_hole_radius_220", "Vortex radius must be BattleVfx's sim→world mapping of 220 (%s vs %s)" % [str(debug.get("radius")), str(result.get("radius_220"))])
	var stun_left := 0.0
	for uid in uids:
		var row := _row(frame, uid)
		if not row.is_empty():
			stun_left = maxf(stun_left, float(((row[9] as Dictionary).get("stun", {}) as Dictionary).get("remaining", 0.0)))
	h.expect(absf(float(debug.get("stun", -1.0)) - stun_left) < 0.01, "black_hole_lock_is_stun", "Gravity lock must last the real stun remaining (%.2f vs %.2f)" % [float(debug.get("stun", -1.0)), stun_left])
	h.expect(float(debug.get("end_time", 0.0)) >= stun_left, "black_hole_lifetime_covers_stun", "Effect must stay until the stun ends")
	h.expect(bool(result.get("rng_untouched", false)), "black_hole_no_rng", "VFX must not consume RngService")
	# 没拉到人 → 记录被清空 → 只画漩涡，不拿旧名单乱画。
	var empty := await _feed_cast(replay, tick, {"vfx_skill_target_uid": ""})
	var empty_debug: Dictionary = empty.get("debug", {})
	h.expect(bool(empty.get("spawned", false)) and int(empty_debug.get("pulled", -1)) == 0, "black_hole_empty_record_no_guess", "An empty pull record must still draw the vortex but no invented drag targets (%s)" % str(empty_debug))


# ── 4. 神王 ───────────────────────────────────────────────────────────────

func _check_god_king(samples: Dictionary) -> void:
	if not (samples.king as Array).is_empty():
		var sample: Dictionary = samples.king[0]
		var result := await _feed_cast(sample.replay, int(sample.tick))
		var debug: Dictionary = result.get("debug", {})
		var count := str(sample.record).split(",").size()
		h.expect(str(debug.get("skill", "")) == "global_divine_blast", "god_king_hero_module", "God King must reach VFXHeroSkill3D, not vertical lightning (got %s)" % str(debug))
		h.expect(int(debug.get("orbs", -1)) == mini(count, 6) and int(debug.get("linger", -1)) == int(debug.get("orbs", -2)), "god_king_orb_per_target", "One energy orb + lingering motes per recorded target (%d vs %s)" % [count, str(debug)])
		h.expect(int(debug.get("clusters", 0)) >= 4, "god_king_orbiting_clusters", "The halo must be orbiting energy clusters, not a flat sigil (%s)" % str(debug))
		h.expect(int(result.get("arcs", -1)) == 0, "god_king_no_lightning", "God King must not spawn VFXLightningArc any more")
		h.expect(bool(result.get("rng_untouched", false)), "god_king_no_rng", "VFX must not consume RngService")
	# 后续每跳伤害 → 一个小脉冲；与施法同帧的第一跳不重复画。
	var later: Dictionary = {}
	for sample: Dictionary in samples.pulse:
		var replay: Dictionary = sample.replay
		var src := str((sample.event as Dictionary).get("source_uid", ""))
		if not _is_cast_tick(replay, int(sample.tick), src):
			later = sample
			break
	if h.expect(not later.is_empty(), "god_king_later_tick_found", "Need a damage tick after the cast frame"):
		var pulse := await _feed_events(later.replay, int(later.tick), [later.event])
		h.expect(int(pulse.get("count", 0)) == 1 and str((pulse.get("debug", {}) as Dictionary).get("skill", "")) == "global_divine_blast_pulse", "god_king_pulse_on_tick", "A later God King damage tick must draw exactly one pulse (got %s)" % str(pulse))
	for sample: Dictionary in samples.pulse:
		var src := str((sample.event as Dictionary).get("source_uid", ""))
		if _is_cast_tick(sample.replay, int(sample.tick), src):
			var same := await _feed_events(sample.replay, int(sample.tick), [sample.event], true)
			h.expect(int(same.get("pulses", -1)) == 0, "god_king_first_tick_no_pulse", "The cast-frame tick is drawn by the orb impact; no extra pulse (got %s)" % str(same))
			break
	# 裁决者仍是单体落雷（与神王脱钩后不受影响）。
	var setup := _battle()
	var route: Node3D = setup.route
	route.call("play", "judgement_strike", Vector3.ZERO, Vector3(1, 0, 0), {})
	h.expect(_scripts_under(setup.composer, ARC_PATH).size() == 1 and _scripts_under(setup.composer, HERO_PATH).is_empty(), "judgement_still_lightning", "judgement_strike must keep its single lightning arc")
	(setup.battle as Node).queue_free()
	await process_frame


# ── 5. 母灵 ───────────────────────────────────────────────────────────────

# 直接驱动模拟器的计数函数：4 次击杀只涨计数，第 5 次归零并发 mother_execute。
func _mother_sim_sample() -> Dictionary:
	var treasures: Script = load("res://scripts/battle/BattleSimTreasures.gd")
	var mother := _fighter("p_mother", _unit_def("undead_mother", 1), "player", Vector2(300.0, 260.0))
	var killer := _fighter("p_killer", _unit_def("human_swordsman", 1), "player", Vector2(340.0, 260.0))
	var victims: Array = []
	for i in 8:
		var v := _fighter("e_%d" % i, _unit_def("human_swordsman", 1), "enemy", Vector2(700.0, 200.0 + 20.0 * i))
		v["killer_uid"] = "p_killer"
		victims.append(v)
	var state := {"player": [mother, killer], "enemy": victims, "visual_events": [], "player_syn": {}, "enemy_syn": {}, "elapsed": 1.0}
	treasures.call("stamp_mother_counters", state)
	h.expect(int(mother.get("vfx_mother_count", -1)) == 0 and int(mother.get("vfx_mother_threshold", -1)) == int(mother.def.get("death_threshold", 5)), "mother_stamp_opening", "Opening stamp must write 0 / threshold (%s/%s)" % [str(mother.get("vfx_mother_count")), str(mother.get("vfx_mother_threshold"))])
	var counts: Array = []
	for i in 5:
		(victims[i] as Dictionary)["alive"] = false
		treasures.call("_credit_mother_kill", state, victims[i])
		counts.append(int(mother.get("vfx_mother_count", -1)))
	h.expect(counts == [1, 2, 3, 4, 0], "mother_counter_sequence", "Kill counter must read 1,2,3,4 then reset on the trigger (got %s)" % str(counts))
	var event: Dictionary = {}
	for value in state.visual_events:
		if value is Dictionary and str((value as Dictionary).get("type", "")) == "mother_execute":
			event = value
	h.expect(not event.is_empty(), "mother_execute_event", "The 5th kill must emit mother_execute")
	return {"state": state, "event": event}


func _check_mother(samples: Dictionary) -> void:
	var direct := _mother_sim_sample()
	if (samples.execute as Array).is_empty():
		if (direct.event as Dictionary).is_empty():
			return
		var setup := _battle()
		var battle: Control = setup.battle
		var state: Dictionary = direct.state
		state.visual_events = []
		_seed(battle, state)
		(state.visual_events as Array).append((direct.event as Dictionary).duplicate(true))
		battle.call("_refresh_battle_vfx", state)
		var books := _scripts_under(setup.composer, HERO_PATH)
		if h.expect(books.size() == 1, "mother_book_spawned", "mother_execute must draw exactly one book (got %d)" % books.size()):
			var debug: Dictionary = (books[0] as Node).call("get_debug_state")
			h.expect(int(debug.get("pages", 0)) >= 3, "mother_book_flips", "The book must flip at least 3 pages")
			if not str((direct.event as Dictionary).get("target_uid", "")).is_empty():
				h.expect(bool(debug.get("victim", false)) and int(debug.get("wisps", 0)) >= 1, "mother_soul_drawn", "With a target the soul must be drawn back into the book (%s)" % str(debug))
				h.expect(bool(debug.get("wave", false)) and float(debug.get("wave_hit", 9.0)) < float(debug.get("end_time", 0.0)), "mother_wave_takes_target", "The open book must fire a light wave that reaches the target before the book closes (%s)" % str(debug))
		battle.queue_free()
		await process_frame
		_check_mother_counts(samples)
		return
	var sample: Dictionary = samples.execute[0]
	var event: Dictionary = sample.event
	var result := await _feed_events(sample.replay, int(sample.tick), [event])
	var debug: Dictionary = result.get("debug", {})
	var has_target := not str(event.get("target_uid", "")).is_empty()
	h.expect(int(result.get("count", 0)) == 1 and str(debug.get("skill", "")) == "unique_death_execute", "mother_book_spawned", "mother_execute must draw exactly one book (got %s)" % str(result))
	h.expect(int(debug.get("pages", 0)) >= 3, "mother_book_flips", "The book must flip at least 3 pages")
	if has_target:
		h.expect(bool(debug.get("victim", false)) and int(debug.get("wisps", 0)) >= 1, "mother_soul_drawn", "With a target the soul must be drawn back into the book (%s)" % str(debug))
	_check_mother_counts(samples, sample)


func _check_mother_counts(samples: Dictionary, sample: Dictionary = {}) -> void:
	# 魂火计数：开场一定有阈值；（自然战斗里有处决时）归零发生在 mother_execute 的同一 tick。
	var replay: Dictionary = sample.get("replay", samples.replays[0])
	var counts: Array = replay.get("undead_mother_count_events", [])
	var event: Dictionary = sample.get("event", {})
	var mother_uid := str(event.get("source_uid", ""))
	if mother_uid.is_empty():
		for uid in replay.roster:
			if str((replay.roster[uid] as Dictionary).get("id", "")) == "undead_mother":
				mother_uid = uid
	var definition: Dictionary = (replay.roster.get(mother_uid, {}) as Dictionary).get("def", {})
	var threshold_ok := false
	var reset_on_execute := false
	var prev_count := -1
	for entry: Array in counts:
		if str(entry[1]) != mother_uid:
			continue
		if int(entry[0]) == 0:
			threshold_ok = int(entry[3]) >= 1 and int(entry[3]) <= int(definition.get("death_threshold", 5))
		if int(entry[2]) == 0 and prev_count > 0 and int(entry[0]) == int(sample.get("tick", -1)):
			reset_on_execute = true
		prev_count = int(entry[2])
	h.expect(threshold_ok, "mother_threshold_from_tick0", "The first replay frame must carry the mother's kill threshold (events %s)" % str(counts.slice(0, 4)))
	if not event.is_empty():
		h.expect(reset_on_execute, "mother_count_resets_on_execute", "The counter must drop to 0 on the very tick the book fires")


func _check_variants() -> void:
	# Boss = 重击（不吸魂）；没有目标 = 空翻熄灭。直接构造 mother_execute 事件，走同一入口。
	var setup := _battle()
	var battle: Control = setup.battle
	var mother := _fighter("p_mother", _unit_def("undead_mother", 1), "player", Vector2(300.0, 260.0))
	var boss_def := _unit_def("human_swordsman", 1)
	boss_def["is_boss"] = true
	var boss := _fighter("e_boss", boss_def, "enemy", Vector2(700.0, 260.0))
	var state := {"player": [mother], "enemy": [boss], "visual_events": []}
	_seed(battle, state)
	(state.visual_events as Array).append({"type": "mother_execute", "source_uid": "p_mother", "target_uid": "e_boss", "time": 1.0})
	(state.visual_events as Array).append({"type": "mother_execute", "source_uid": "p_mother", "target_uid": "", "time": 1.0})
	battle.call("_refresh_battle_vfx", state)
	var books := _scripts_under(setup.composer, HERO_PATH)
	if h.expect(books.size() == 2, "mother_variants_spawned", "Boss hit and empty flip must each draw a book (got %d)" % books.size()):
		var heavy: Dictionary = (books[0] as Node).call("get_debug_state")
		var empty: Dictionary = (books[1] as Node).call("get_debug_state")
		h.expect(bool(heavy.get("heavy", false)) and bool(heavy.get("heavy_hit", false)) and int(heavy.get("wisps", 0)) == 1, "mother_boss_heavy", "A boss target must get the heavy strike (%s)" % str(heavy))
		h.expect(bool(empty.get("empty", false)) and not bool(empty.get("victim", true)), "mother_empty_flip", "No target must flip empty and fizzle (%s)" % str(empty))
	await create_timer(2.3).timeout
	h.expect(_scripts_under(setup.composer, HERO_PATH).is_empty(), "mother_lifecycle", "Books must free themselves")
	battle.queue_free()
	await process_frame


func _check_badge() -> void:
	var badge: Control = (load("res://scenes/battle/MotherSoulBadge.gd") as Script).new()
	root.add_child(badge)
	h.expect(not badge.visible, "badge_hidden_without_threshold", "Badge must stay hidden before a threshold is known")
	badge.call("set_counter", 0, 5)
	h.expect(badge.visible and badge.call("get_counter") == Vector2i(0, 5), "badge_threshold", "Badge must show 5 empty flames")
	badge.call("set_counter", 3, 5)
	h.expect(badge.call("get_counter") == Vector2i(3, 5), "badge_count", "Badge must light 3 flames")
	badge.call("set_counter", 9, 4)
	h.expect(badge.call("get_counter") == Vector2i(4, 4), "badge_clamped", "Count must clamp to the threshold")
	badge.queue_free()


func _check_replay_apply(samples: Dictionary) -> void:
	# BattleScreen 的回放旁路：向前播放逐条生效，回退时从头重放。
	if (samples.replays as Array).is_empty():
		return
	var replay: Dictionary = samples.replays[0]
	var counts: Array = replay.get("undead_mother_count_events", [])
	if not h.expect(counts.size() >= 2, "mother_count_events_present", "Replay must carry undead_mother_count_events"):
		return
	var screen: Object = (load("res://scenes/battle/BattleScreen.gd") as Script).new()
	var by_uid := {}
	for uid in replay.roster:
		by_uid[uid] = {"uid": uid}
	screen.set("_replay", replay)
	screen.set("_replay_by_uid", by_uid)
	var probe: Array = counts[counts.size() - 1]
	screen.call("_apply_mother_count_events", int(probe[0]))
	var f: Dictionary = by_uid[str(probe[1])]
	h.expect(int(f.get("vfx_mother_count", -1)) == int(probe[2]) and int(f.get("vfx_mother_threshold", -1)) == int(probe[3]), "replay_apply_forward", "Forward playback must land on the latest count")
	var first: Array = counts[0]
	screen.call("_apply_mother_count_events", int(first[0]))
	var g: Dictionary = by_uid[str(first[1])]
	h.expect(int(g.get("vfx_mother_count", -1)) == int(first[2]), "replay_apply_rewind", "Seeking backwards must rebuild the count from the start")
	if screen is Node:
		(screen as Node).free()


# ── 6. 低画质与关键通道 ───────────────────────────────────────────────────

func _check_budget(budget: Script) -> void:
	budget.set("tier", 0)
	var setup := _battle()
	var route: Node3D = setup.route
	var many: Array = []
	for i in 9:
		many.append(Vector3(float(i) * 0.3, 0.0, 0.0))
	route.call("play", "global_divine_blast", Vector3.ZERO, Vector3.ZERO, {"targets": many})
	var spawned := _scripts_under(setup.composer, HERO_PATH)
	if h.expect(spawned.size() == 1, "low_tier_spawned", "God King must still play on low quality"):
		h.expect(int((spawned[0] as Node).call("get_debug_state").get("orbs", 99)) <= 4, "low_tier_caps_orbs", "Low quality must cap orbs at the AoE target budget")
	# 把并发上限占满：关键技能（黑洞 / 神威 / 书）仍要出；脉冲可以被丢。
	var cap := int(budget.call("max_simultaneous_effects_for", "important")) + 4
	for i in cap:
		route.call("play", "global_divine_blast_pulse", Vector3.ZERO, Vector3.ZERO, {})
	var before := _scripts_under(setup.composer, HERO_PATH).size()
	route.call("play", "black_hole", Vector3.ZERO, Vector3.ZERO, {"targets": [Vector3.ONE]})
	route.call("play", "unique_death_execute", Vector3.ZERO, Vector3.ZERO, {"has_victim": false})
	h.expect(_scripts_under(setup.composer, HERO_PATH).size() == before + 2, "critical_bypasses_cap", "Black hole and the book must bypass the concurrency cap")
	(setup.battle as Node).queue_free()
	await process_frame


# ── 工具 ─────────────────────────────────────────────────────────────────

func _is_cast_tick(replay: Dictionary, tick: int, uid: String) -> bool:
	if tick <= 0:
		return false
	var now := _row(replay.frames[tick], uid)
	var before := _row(replay.frames[tick - 1], uid)
	return not now.is_empty() and not before.is_empty() and float(now[6]) > float(before[6]) + 0.1


func _row(frame: Array, uid: String) -> Array:
	for row: Array in frame:
		if str(row[0]) == uid:
			return row
	return []


# 还原 tick-1 帧做基线，再刷新到 tick 帧，制造真实的 skill_ready 上升沿。
func _feed_cast(replay: Dictionary, tick: int, override: Dictionary = {}) -> Dictionary:
	var setup := _battle()
	var battle: Control = setup.battle
	var prev_state := _state_from_replay(replay, tick - 1)
	_seed(battle, prev_state)
	var state := _state_from_replay(replay, tick)
	if not override.is_empty():
		for side in ["player", "enemy"]:
			for f: Dictionary in state[side]:
				var unit_id := str(f.id)
				if unit_id in ["dark_dragon", "god_king"]:
					f.merge(override, true)
	_copy_into(prev_state, state)
	var rng: RandomNumberGenerator = root.get_node("RngService").get("rng")
	var rng_before: int = rng.state
	var before := _scripts_under(setup.composer, HERO_PATH).size()
	battle.call("_refresh_battle_vfx", prev_state)
	var spawned := _scripts_under(setup.composer, HERO_PATH)
	var out := {"spawned": spawned.size() > before, "rng_untouched": rng.state == rng_before}
	if spawned.size() > before:
		out["debug"] = (spawned[spawned.size() - 1] as Node).call("get_debug_state")
	out["radius_220"] = battle.call("_guardian_taunt_world_radius", 220.0)
	out["arcs"] = _scripts_under(setup.composer, ARC_PATH).size()
	battle.queue_free()
	await process_frame
	return out


func _feed_events(replay: Dictionary, tick: int, events: Array, with_cast: bool = false) -> Dictionary:
	var setup := _battle()
	var battle: Control = setup.battle
	var state := _state_from_replay(replay, tick - 1 if with_cast else tick)
	_seed(battle, state)
	if with_cast:
		_copy_into(state, _state_from_replay(replay, tick))
	var before := _scripts_under(setup.composer, HERO_PATH).size()
	(state.visual_events as Array).append_array(events.duplicate(true))
	battle.call("_refresh_battle_vfx", state)
	var spawned := _scripts_under(setup.composer, HERO_PATH)
	var out := {"count": spawned.size() - before, "pulses": 0}
	for node in spawned.slice(before):
		var debug: Dictionary = (node as Node).call("get_debug_state")
		out["debug"] = debug
		if str(debug.get("skill", "")) == "global_divine_blast_pulse":
			out["pulses"] = int(out["pulses"]) + 1
	battle.queue_free()
	await process_frame
	return out


# 原地把 next 的每个单位字段写进 prev 的同一字典（BattleVfx 按 id 复用单位字典）。
func _copy_into(prev_state: Dictionary, next_state: Dictionary) -> void:
	var by_uid := {}
	for side in ["player", "enemy"]:
		for f: Dictionary in next_state[side]:
			by_uid[str(f.uid)] = f
	for side in ["player", "enemy"]:
		for f: Dictionary in prev_state[side]:
			if by_uid.has(str(f.uid)):
				f.merge(by_uid[str(f.uid)], true)


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
			"statuses": row[9], "def": definition, "range_px": float(definition.get("range", 1)) * 72.0,
			"vfx_attack_target_uid": str(row[11]), "vfx_skill_target_uid": str(row[12])}
		(state[f.team] as Array).append(f)
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
	_collect(node, path, out)
	return out


func _collect(node: Node, path: String, out: Array) -> void:
	for child in node.get_children():
		var script: Variant = child.get_script()
		if script is Script and (script as Script).resource_path == path and not child.is_queued_for_deletion():
			out.append(child)
		_collect(child, path, out)
