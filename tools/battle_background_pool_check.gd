extends SceneTree

const Catalog := preload("res://scripts/assets/BattleBackgroundCatalog.gd")
const Harness := preload("res://tools/CheckHarness.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await process_frame
	var h := Harness.new("battle_background_pool")
	for service_name in ["NetworkService", "RealtimeService", "AnalyticsService", "AccountManager"]:
		root.get_node(service_name).process_mode = Node.PROCESS_MODE_DISABLED
	for final_round in [13, 21]:
		var seen_grass := {}
		var seen_snow := {}
		for room in range(1, 33):
			var key := "room:%d" % room
			for round_index in range(1, final_round):
				for kind in ["pve", "boss", "pvp"]:
					var chosen := Catalog.path_for(kind, round_index, final_round, key)
					var pool: Array = Catalog.SNOW if kind == "pvp" else Catalog.GRASS
					h.expect(chosen in pool, "wrong_biome", "%s round %d returned %s" % [kind, round_index, chosen])
					h.expect(chosen == Catalog.path_for(kind, round_index, final_round, key), "unstable_choice", "Same round changed background")
					if kind == "pvp": seen_snow[chosen] = true
					else: seen_grass[chosen] = true
			for kind in ["pvp", "pve", "boss", "final"]:
				h.expect(Catalog.path_for(kind, final_round, final_round, key) == Catalog.FINAL, "final_changed", "Final background must remain fixed")
			h.expect(Catalog.path_for("final", 1, final_round, key) == Catalog.FINAL, "final_kind_changed", "Explicit final must remain fixed")
		h.expect(seen_grass.size() == 4 and seen_snow.size() == 4, "variant_unreachable", "All eight variants must be reachable")
		var round_choices := {}
		for r in range(1, final_round):
			round_choices[Catalog.path_for("pve", r, final_round, "room:123456")] = true
		h.expect(round_choices.size() > 1, "whole_run_locked", "Theme must vary by round, not only by match")
	seed(998877)
	var expected := randi()
	seed(998877)
	Catalog.path_for("pvp", 4, 21, "room:123456")
	h.expect(randi() == expected, "game_rng_consumed", "Background choice must not consume gameplay RNG")
	for path in Catalog.GRASS + Catalog.SNOW + [Catalog.FINAL]:
		var texture := load(path) as Texture2D
		h.expect(texture != null, "texture_missing", path)
		if texture != null:
			h.expect(texture.get_size() == Vector2(1672, 941), "texture_size", path)
	# Exercise the actual arena wiring, including early build before replay arrival.
	var game = root.get_node("GameState")
	var net = root.get_node("NetworkService")
	var arena = load("res://scenes/battle/BattleArena.gd").new()
	game.round_index = 1
	game.FINAL_ROUND = 21
	arena.set("_kind", "pvp")
	net.team_room_id = 123456
	net.spectate_room_id = 0
	net.shared_seed = 0
	var first: String = arena.call("_battlefield_base_path")
	h.expect(first in Catalog.SNOW, "arena_pvp", "Arena must choose snow for PVP")
	net.shared_seed = 998877
	h.expect(arena.call("_battlefield_base_path") == first, "late_seed_changed", "Late battle seed must not change backdrop")
	net.team_room_id = 0
	net.spectate_room_id = 123456
	h.expect(arena.call("_battlefield_base_path") == first, "spectator_mismatch", "Spectator must match room players")
	net.spectate_room_id = 0
	net.team_room_id = 123456
	arena.set("_kind", "boss")
	h.expect(arena.call("_battlefield_base_path") in Catalog.GRASS, "arena_boss", "Boss must use grass")
	for final_round in [13, 21]:
		game.FINAL_ROUND = final_round
		game.round_index = final_round
		arena.set("_kind", "pvp")
		h.expect(arena.call("_battlefield_base_path") == Catalog.FINAL, "arena_final", "Final round must override replay kind=pvp")
	arena.free()
	h.finish(self)
