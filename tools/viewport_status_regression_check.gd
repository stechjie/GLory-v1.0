extends Node

const Harness = preload("res://tools/CheckHarness.gd")
const Warmup = preload("res://effects/vfx3d/VFXWarmup.gd")
const Prep = preload("res://scenes/prep/PrepBoardModels.gd")
const Arena = preload("res://scenes/battle/BattleArena.gd")
const Status = preload("res://scenes/battle/StatusVFXController.gd")
const Diagnostics = preload("res://scripts/autoload/PerfLog.gd")

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var h = Harness.new("viewport_status_regression")
	var original_tier: int = VFXManager.get_quality_tier()
	VFXManager.set_quality_tier(VFXQualityBudget.Tier.HIGH)
	var warm = Warmup.new()
	add_child(warm)
	warm._build_viewport()
	var prep = Prep.new()
	add_child(prep)
	prep._setup_prep_river_background()
	var arena = Arena.new()
	add_child(arena)
	var wrap := Control.new()
	arena.add_child(wrap)
	arena._setup_battle_3d_view(wrap)
	var views: Array[SubViewport] = [warm._viewport, prep._prep_river_viewport, arena._battle_3d_viewport]
	h.expect(views[0].msaa_3d == Viewport.MSAA_DISABLED, "warmup_aa_cost", "offscreen warmup must remain single-sample")
	for view in [views[1], views[2]]:
		h.expect(view.msaa_3d == Viewport.MSAA_2X, "high_aa_missing", "high quality prep/battle geometry must use 2x MSAA")
		h.expect(is_equal_approx(view.scaling_3d_scale, 1.0), "aa_changed_resolution", "edge antialiasing must preserve render scale")
	h.expect(is_equal_approx(prep.get_node("PrepRiverArenaLayer/PrepRiverRefreshTimer").wait_time, 1.0 / 30.0),
		"aa_changed_refresh_rate", "preparation must retain its 30 Hz render budget")
	_check_low_medium_aa(h)
	VFXManager.set_quality_tier(original_tier)
	for i in views.size():
		h.expect(views[i].find_world_3d() != get_viewport().find_world_3d(), "parent_world", "viewport must not share the parent world")
		for j in range(i):
			h.expect(views[i].find_world_3d() != views[j].find_world_3d(), "shared_world", "warmup, prep and battle must be isolated")
	# A newly spawned warmup mesh must belong only to the offscreen scenario.
	var probe := MeshInstance3D.new()
	probe.mesh = SphereMesh.new()
	warm._world_root.add_child(probe)
	h.expect(probe.get_world_3d() == views[0].find_world_3d(), "probe_world", "probe belongs to warmup")
	h.expect(probe.get_world_3d() != views[1].find_world_3d(), "probe_leak", "probe cannot render on prep board")
	h.expect(not Diagnostics.diagnostics_enabled([], false), "normal_diagnostics", "ordinary play must not scan the scene tree")
	h.expect(Diagnostics.diagnostics_enabled(["--perf-log"], false), "opt_in", "device diagnostics remain available")
	h.expect(Diagnostics.diagnostics_enabled([], true), "headless", "headless checks retain diagnostics")
	h.expect(not Diagnostics.diagnostics_enabled(["--server", "--perf-log"], true), "server", "server diagnostics stay disabled")
	var host := Node3D.new()
	add_child(host)
	var status = Status.new()
	host.add_child(status)
	status.process_mode = Node.PROCESS_MODE_DISABLED
	var fighter := {"shield": 100, "statuses": {"poison": {"remaining": 5.0}}}
	status.update_from_fighter(fighter)
	var sprite = status._sprites["shield"]
	for i in 100:
		status.update_from_fighter(fighter)
	h.expect(status._sprites.size() == 2 and status._active_kinds.size() == 2, "duplicate_status", "repeated snapshots must reuse sprites")
	status._process(0.4)
	h.expect(status._shield_phase == Status.ShieldPhase.STEADY, "steady", "unchanged snapshots must not restart shield animation")
	fighter.shield = 80
	status.update_from_fighter(fighter)
	if VFXQualityBudget.tier != VFXQualityBudget.Tier.LOW:
		h.expect(status._shield_phase == Status.ShieldPhase.ABSORB, "absorb", "damage still triggers shield feedback")
	fighter.shield = 0
	fighter.statuses.poison.remaining = 0.0
	status.update_from_fighter(fighter)
	h.expect(sprite.visible and status._shield_phase == Status.ShieldPhase.BREAK, "break", "break effect must finish before hiding")
	status._process(0.4)
	h.expect(status._active_kinds.is_empty() and not status.is_processing(), "idle", "expired effects release per-frame processing")
	for n in [warm, prep, arena, host]:
		if n == prep:
			# The base model fixture does not attach PrepScreen's panel instances.
			for panel in [prep._shop, prep._synergy, prep._stats, prep._treasure, prep._board_hud]:
				panel.free()
		n.queue_free()
	await get_tree().process_frame
	h.finish(get_tree())

func _check_low_medium_aa(h: RefCounted) -> void:
	for tier in [VFXQualityBudget.Tier.LOW, VFXQualityBudget.Tier.MEDIUM]:
		VFXManager.set_quality_tier(tier)
		var prep = Prep.new()
		add_child(prep)
		prep._setup_prep_river_background()
		var arena = Arena.new()
		add_child(arena)
		var wrap := Control.new()
		arena.add_child(wrap)
		arena._setup_battle_3d_view(wrap)
		for view in [prep._prep_river_viewport, arena._battle_3d_viewport]:
			h.expect(view.msaa_3d == Viewport.MSAA_DISABLED, "mobile_aa_cost_increased",
				"low/medium must retain single-sample prep/battle rendering (tier=%d)" % tier)
		for panel in [prep._shop, prep._synergy, prep._stats, prep._treasure, prep._board_hud]:
			panel.free()
		prep.queue_free()
		arena.queue_free()
