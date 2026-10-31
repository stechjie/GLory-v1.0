extends Node
## Regression checks for ownership, replay event deduplication, death routing and
## cleanup. This does not modify player options, gameplay rules or reward data.
const HOST := preload("res://scenes/battle/BattleVfx.gd")
const ACTOR := preload("res://effects/runtime/presentation/UnitActor3D.gd")
const Harness := preload("res://tools/CheckHarness.gd")
var _h: RefCounted

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	_h = Harness.new("monster_death_feedback")
	NetworkService.team_active = false
	GameState.team_mode = true
	_check_kill_accounting()
	await _check_routes_and_cleanup()
	await _check_seek_clears_live_tails()
	await _check_clear_and_special_handoff()
	_h.finish(get_tree())

func _new_host():
	var host = HOST.new()
	host.name = "DeathFeedbackCheckHost"
	add_child(host)
	var arena := Control.new()
	arena.size = Vector2(1280, 720)
	host.add_child(arena)
	host._arena = arena
	var model_root := Node3D.new()
	host.add_child(model_root)
	host._battle_3d_root = model_root
	var effect_root := Node3D.new()
	model_root.add_child(effect_root)
	host._battle_3d_vfx_root = effect_root
	host._state = {"kind": "pve", "elapsed": 1.0, "player": [{"uid": "local", "id": "human_militia", "team": "player", "owner_slot": 0, "lane": 0, "alive": true}, {"uid": "ally", "id": "human_militia", "team": "player", "owner_slot": 1, "lane": 0, "alive": true}], "enemy": []}
	return host

func _victim(uid: String, unit_id: String = "pve_land_rock_beast", owner: int = 3) -> Dictionary:
	return {"uid": uid, "id": unit_id, "team": "enemy" if owner == 3 else "player", "owner_slot": owner, "lane": 0, "alive": false, "hp": 0, "star": 1, "is_mercenary": unit_id.begins_with("merc_"), "def": {"id": unit_id, "race": "human" if unit_id.begins_with("human_") else ""}}

func _check_kill_accounting() -> void:
	var host = _new_host()
	for uid in ["one", "two", "three", "four", "enemy_mirror_1", "enemy_parasite_1"]:
		host._state.enemy.append(_victim(uid))
	var own := _victim("own", "human_militia", 0)
	host._state.player.append(own)
	var formation := _victim("formation", "ally_abyss_beast")
	formation.is_formation_ally = true
	host._state.enemy.append(formation)
	host._record_personal_kill("one", "local", "battle:1:0", 1.0)
	_h.expect(host._kill_streak_count == 1, "first_kill", "First eligible personal death must count once")
	host._record_personal_kill("one", "local", "battle:1:0", 1.0)
	_h.expect(host._kill_streak_count == 1 and host._personal_kill_events.size() == 1, "duplicate_event", "Repeated replay death event must not add a kill")
	host._record_personal_kill("two", "local", "battle:2:0", 2.0)
	_h.expect(host._kill_streak_count == 2 and is_instance_valid(host._combat_feedback), "second_kill_ui", "Second personal kill inside the window must start the actual feedback UI")
	host._record_personal_kill("three", "local", "battle:3:0", 4.01)
	_h.expect(host._kill_streak_count == 1, "chain_timeout", "A gap longer than two replay seconds must reset the chain")
	var accepted: int = host._personal_kill_events.size()
	for rejected in [{"victim": "four", "killer": "ally", "key": "ally"}, {"victim": "enemy_mirror_1", "killer": "local", "key": "mirror"}, {"victim": "enemy_parasite_1", "killer": "local", "key": "parasite"}, {"victim": "own", "killer": "local", "key": "friendly"}, {"victim": "formation", "killer": "local", "key": "formation"}, {"victim": "four", "killer": "", "key": "unowned"}]:
		host._record_personal_kill(str(rejected.victim), str(rejected.killer), str(rejected.key), 4.2)
		_h.expect(host._personal_kill_events.size() == accepted, "ownership_filter_" + str(rejected.key), "Unowned/ally/friendly/clone/formation death must not grow personal Kills")
	# Same UID may legitimately die again after revival, with a new event key.
	host._record_personal_kill("one", "local", "battle:5:0", 5.0)
	_h.expect(host._kill_streak_count == 2 and host._personal_kill_events.size() == accepted + 1, "revival_new_event", "A new death event for a revived UID must remain eligible")
	# An older action track may report late; it cannot extend the newest suffix.
	host._record_personal_kill("four", "local", "battle:old:0", 1.5)
	_h.expect(host._kill_streak_count == 2, "out_of_order_tracks", "Late earlier death cannot inflate the current chain across its gap")
	host.cue_release_corpses()
	_h.expect(host._personal_kill_events.is_empty() and host._personal_kill_times.is_empty() and host._kill_streak_count == 0, "reset_chain", "Seek/scene-reset cleanup must clear all chain state")
	host.queue_free()

func _add_actor(host, fighter: Dictionary) -> Node3D:
	var actor = ACTOR.new()
	actor.configure_contract(0.98, "melee")
	actor.set_meta("base_yaw", 180.0)
	actor.set_meta("unit_id", str(fighter.id))
	host._battle_3d_root.add_child(actor)
	var model := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.3, 0.7, 0.3)
	model.mesh = box
	model.position.y = 0.35
	actor.attach_model(model)
	host._battle_3d_models[str(fighter.uid)] = actor
	host._unit_actor_registry.register_actor(str(fighter.uid), actor)
	return actor

func _check_routes_and_cleanup() -> void:
	var host = _new_host()
	var monster := _victim("monster")
	var mercenary := _victim("mercenary", "merc_libra_judge")
	var own := _victim("own_piece", "human_militia", 0)
	var sentinel := _victim("sentinel")
	sentinel.alive = true
	sentinel.hp = 100
	host._state.enemy = [monster, mercenary, sentinel]
	host._state.player.append(own)
	_h.expect(host._uses_monster_death_feedback("monster"), "monster_route", "PvE enemy must use the dust/embers route")
	_h.expect(not host._uses_monster_death_feedback("own_piece") and host._death_tier("own_piece") == "own", "own_route", "Own piece must keep a subdued own-side death tier")
	_h.expect(not host._uses_monster_death_feedback("mercenary") and host._is_mercenary_death("mercenary"), "mercenary_route", "Mercenary must use the separate star residue route")
	_h.expect(not host._is_local_lane_clear("monster"), "clear_waits_for_living", "A living local-lane enemy must block lane-clear")
	var models: Array[Node3D] = []
	var events: Array = []
	for fighter in [monster, mercenary, own]:
		models.append(_add_actor(host, fighter))
		events.append({"type": "death", "source_uid": str(fighter.uid)})
	var gold := int(GameState.gold)
	host.cue_claim_corpses(events)
	_h.expect(host._cue_corpses.size() == 3, "claims_held", "All three actors must remain owned while their death cues are queued")
	for fighter in [monster, mercenary, own]:
		_h.expect(host.cue_play_death(str(fighter.uid), 0.35, "local", "route:" + str(fighter.uid), 10.0), "cue_accepted_" + str(fighter.uid), "Real production death entry must accept each held actor")
	await _wait(0.42)
	_h.expect(not host._battle_3d_vfx_root.find_children("MonsterDeathDust", "GPUParticles3D", true, false).is_empty(), "dust_spawned", "Real monster body contact must spawn the dust emitter")
	_h.expect(not host._battle_3d_vfx_root.find_children("MonsterDeathEmbers", "GPUParticles3D", true, false).is_empty(), "embers_spawned", "Real monster body contact must spawn the fine ember emitter")
	_h.expect(not host._battle_3d_vfx_root.find_children("MercenaryDeathStars", "GPUParticles3D", true, false).is_empty(), "stars_spawned", "Mercenary contact must spawn its separate star emitter")
	_h.expect(host._battle_3d_vfx_root.find_children("DeathShards*", "GPUParticles3D", true, false).is_empty(), "no_legacy_stones", "New routes must not create the retired large colored stone emitters")
	await _wait(1.30)
	_h.expect(host._active_death_actors.is_empty() and host._cue_corpses.is_empty(), "corpses_cleaned", "All completed deaths must leave the active/queued dictionaries")
	for actor in models:
		_h.expect(not is_instance_valid(actor), "actor_freed", "Completed actor must be freed, not just hidden")
	_h.expect(host._battle_3d_vfx_root.get_child_count() == 0, "tails_cleaned", "All death particle roots must clean themselves after their tail")
	_h.expect(int(GameState.gold) == gold, "gold_unchanged", "Presentation must not mutate player gold")
	host.cue_release_corpses()
	host.queue_free()
	await get_tree().process_frame

func _check_seek_clears_live_tails() -> void:
	var host = _new_host()
	var monster := _victim("seek_monster")
	var mercenary := _victim("seek_mercenary", "merc_libra_judge")
	var sentinel := _victim("seek_sentinel")
	sentinel.alive = true
	sentinel.hp = 100
	host._state.enemy = [monster, mercenary, sentinel]
	var models: Array[Node3D] = []
	for fighter in [monster, mercenary]:
		models.append(_add_actor(host, fighter))
		host.cue_claim_corpses([{"type": "death", "source_uid": str(fighter.uid)}])
		host.cue_play_death(str(fighter.uid), 0.35, "local", "seek:" + str(fighter.uid), 20.0)
	await _wait(0.42)
	_h.expect(not host._battle_3d_vfx_root.find_children("MonsterDeathDust", "GPUParticles3D", true, false).is_empty()
		and not host._battle_3d_vfx_root.find_children("MercenaryDeathStars", "GPUParticles3D", true, false).is_empty(),
		"seek_precondition_live_tails", "Seek check must begin after actual dust and stars have spawned")
	_h.expect(not host._death_tail_blocks.is_empty(), "tail_registry_populated", "Active death tails must be tracked for seek cancellation")
	host.cue_release_corpses()
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(host._battle_3d_vfx_root.get_child_count() == 0 and host._death_tail_blocks.is_empty(), "seek_tails_removed", "Seek must remove already-spawned death tails immediately")
	_h.expect(host._active_death_actors.is_empty() and host._cue_corpses.is_empty(), "seek_bodies_released", "Seek must release active and queued bodies")
	for actor in models:
		_h.expect(not is_instance_valid(actor), "seek_actor_freed", "Seek must free bodies that were already animating")
	await _wait(0.55)
	_h.expect(host._battle_3d_vfx_root.get_child_count() == 0 and not host._lane_clear_presented, "seek_no_late_callbacks", "Cancelled death callbacks must not recreate tails or celebrations")
	host.queue_free()
	await get_tree().process_frame

func _check_clear_and_special_handoff() -> void:
	# One normal last death reserves the finale before the landing callback.
	var host = _new_host()
	var last := _victim("last_monster")
	host._state.enemy = [last]
	_add_actor(host, last)
	host.cue_claim_corpses([{"type": "death", "source_uid": str(last.uid)}])
	host.cue_play_death(str(last.uid), 0.35, "local", "clear:last", 30.0)
	_h.expect(host._lane_clear_played and host._lane_clear_pending_uid == str(last.uid) and not host._lane_clear_presented,
		"clear_reserved_before_landing", "Last death must reserve one finale without presenting before landing")
	await _wait(0.49)
	_h.expect(host._lane_clear_presented and host._battle_3d_vfx_root.find_children("LaneClearThinGoldRing", "MeshInstance3D", true, false).size() == 1,
		"normal_clear_presented_once", "The real last-body landing must present exactly one clear ring")
	host._spawn_lane_clear_feedback(null)
	host._spawn_lane_clear_feedback(null)
	_h.expect(host._battle_3d_vfx_root.find_children("LaneClearThinGoldRing", "MeshInstance3D", true, false).size() == 1,
		"clear_duplicate_ignored", "Repeated completion/delivery must not create extra clear rings")
	_h.expect(bool(host._combat_feedback.get("_clear_shown")), "clear_caption_once", "The actual clear caption must have accepted the first presentation")
	host.cue_release_corpses()
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(host._battle_3d_vfx_root.get_child_count() == 0 and not host._lane_clear_presented
		and host._lane_clear_pending_uid.is_empty() and not bool(host._combat_feedback.get("_clear_shown")),
		"clear_seek_resets_all", "Seek must cancel the active gold ring and reset reservation/caption state")
	host.queue_free()
	await get_tree().process_frame
	# Phoenix release returns before normal tier selection. Its final callback
	# must still discover and celebrate the actual last enemy exactly once.
	host = _new_host()
	var phoenix := _victim("enemy_last_phoenix_1", "human_militia")
	phoenix.phoenix_used = true
	host._state.enemy = [phoenix]
	_add_actor(host, phoenix)
	host.cue_claim_corpses([{"type": "death", "source_uid": str(phoenix.uid)}])
	_h.expect(host.cue_play_death(str(phoenix.uid), 0.35, "local", "clear:phoenix", 40.0), "phoenix_cue_accepted", "Real phoenix special death must be accepted")
	await _wait(0.43)
	_h.expect(host._lane_clear_presented and host._battle_3d_vfx_root.find_children("LaneClearThinGoldRing", "MeshInstance3D", true, false).size() == 1,
		"phoenix_final_clear", "A final phoenix special release must hand off to one clear presentation")
	host._spawn_lane_clear_feedback(null)
	_h.expect(host._battle_3d_vfx_root.find_children("LaneClearThinGoldRing", "MeshInstance3D", true, false).size() == 1,
		"phoenix_clear_no_duplicate", "Later special completion must not repeat the phoenix clear")
	host.cue_release_corpses()
	host.queue_free()
	await get_tree().process_frame
	# A late mother-execution event interrupts an already-reserved finale tween.
	# Exercise the real interruption path instead of manufacturing its flags.
	host = _new_host()
	last = _victim("late_execute_last")
	host._state.enemy = [last]
	_add_actor(host, last)
	host.cue_claim_corpses([{"type": "death", "source_uid": str(last.uid)}])
	host.cue_play_death(str(last.uid), 0.35, "local", "clear:late_execute", 50.0)
	_h.expect(host._lane_clear_pending_uid == str(last.uid), "late_execute_reserved", "The normal death must reserve its finale before interruption")
	await _wait(0.06)
	host._mark_mother_execute_victim(str(last.uid))
	await _wait(1.50)
	_h.expect(host._lane_clear_presented and host._battle_3d_vfx_root.find_children("LaneClearThinGoldRing", "MeshInstance3D", true, false).size() == 1,
		"late_execute_transfers_clear", "Replacing the reserved tween with mother execution must preserve its single clear")
	_h.expect(host._active_death_actors.is_empty(), "late_execute_body_finished", "The replacement special body must finish and release its actor")
	host._spawn_lane_clear_feedback(null)
	_h.expect(host._battle_3d_vfx_root.find_children("LaneClearThinGoldRing", "MeshInstance3D", true, false).size() == 1,
		"late_execute_no_duplicate", "The transferred reserved clear must remain one-shot")
	host.cue_release_corpses()
	host.queue_free()
	await get_tree().process_frame

func _wait(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
