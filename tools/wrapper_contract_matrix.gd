extends Node

# Work package C-05: read-only contract matrix for the animated wrapper models.
#
# Purpose is to support the GLOBAL animation-activity work (V2 P1-01 / V3 P2-02),
# not to study Round 20. Round 20 is only the current worst-case stress sample;
# the optimisation has to hold for every wrapper in the project, so somebody needs
# a per-wrapper contract table before deciding what "pause the hidden branch" may
# and may not assume.
#
# READ ONLY. Nothing here modifies a wrapper, a model, a material, an import
# setting or any gameplay wiring. It loads scenes, measures them, frees them.
#
# Two passes, because neither alone is sufficient:
#   * static  — parses the wrapper .tscn and its sibling .gd. This is the only way
#               to see the proxy animation library, whether those animations are
#               trackless, and how attack->idle is wired.
#   * runtime — instantiates the wrapper. This is the only way to see INSIDE the
#               FBX: internal AnimationPlayers, Skeleton3D and bone counts, and
#               whether anything other than meshes (particles, audio, scripts)
#               lives in a branch that hidden-subtree pausing would silently stop.
#
# Output: reports/animated_wrapper_contracts.csv + .json
#
# Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/wrapper_contract_matrix.tscn

const MODEL_ROOT := "res://assets/models"
const OUT_CSV := "res://reports/animated_wrapper_contracts.csv"   # asset-manifest-ignore
const OUT_JSON := "res://reports/animated_wrapper_contracts.json" # asset-manifest-ignore

const COLUMNS: PackedStringArray = [
	"wrapper", "unit", "category", "script", "shared_script", "action_binding", "architecture",
	"proxy_player", "proxy_animations", "proxy_animation_names", "proxy_trackless",
	"action_scene_keys", "action_scene_count", "foreign_action_refs",
	"has_process", "process_polls_current_animation", "process_polls_is_playing",
	"attack_to_idle", "repeat_attack_restarts",
	"animation_players_total", "internal_players", "skeletons", "bones", "mesh_instances",
	"particles", "audio_players", "scripted_child_nodes",
	"internal_players_idle_only", "anomalies",
]

var _rows: Array[Dictionary] = []
var _errors: Array[String] = []


func _ready() -> void:
	var wrappers := _find_wrappers(MODEL_ROOT)
	wrappers.sort()
	print("[wrapper_matrix] 找到 %d 个包装场景" % wrappers.size())

	for path in wrappers:
		var row := _static_pass(path)
		await _runtime_pass(path, row)
		_rows.append(row)
		if _rows.size() % 10 == 0:
			print("[wrapper_matrix]   ... %d/%d" % [_rows.size(), wrappers.size()])

	_write_outputs()
	_print_summary()
	get_tree().quit(0)


# --- discovery -----------------------------------------------------------------

func _find_wrappers(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			out.append_array(_find_wrappers(full))
		elif name.ends_with("_animated.tscn"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	return out


# --- static pass ---------------------------------------------------------------

func _static_pass(path: String) -> Dictionary:
	var scene_text := FileAccess.get_file_as_string(path)
	var dir := path.get_base_dir()
	var unit := path.get_file().replace("_animated.tscn", "")
	var row := {
		"wrapper": path,
		"unit": unit,
		"category": _category_of(path),
		"script": "",
		"shared_script": false,
		"action_binding": "",
		"proxy_player": scene_text.contains("type=\"AnimationPlayer\""),
		"proxy_animations": 0,
		"proxy_animation_names": "",
		"proxy_trackless": true,
		"action_scene_keys": "",
		"action_scene_count": 0,
		"foreign_action_refs": "",
		"has_process": false,
		"process_polls_current_animation": false,
		"process_polls_is_playing": false,
		"attack_to_idle": "",
		"repeat_attack_restarts": "",
		"architecture": "",
		"animation_players_total": -1,
		"internal_players": -1,
		"skeletons": -1,
		"bones": -1,
		"mesh_instances": -1,
		"particles": -1,
		"audio_players": -1,
		"scripted_child_nodes": -1,
		"internal_players_idle_only": -1,
		"anomalies": [],
	}

	# Animation names come from the AnimationLibrary's _data keys, which is what
	# play("idle") actually looks up. An earlier version scraped `resource_name =`
	# instead and reported the two baked-model wrappers as having animations called
	# "Material_001" and "Mesh1_0" — those are material and mesh resource names,
	# not animations. Both wrappers do have real `idle` and `attack` keys.
	#
	# An Animation sub-resource with no tracks/N/ lines is a pure timing shell that
	# drives the real FBX players rather than animating anything itself.
	var anim_names: Array[String] = []
	var lib := RegEx.create_from_string("_data = \\{([\\s\\S]*?)\\n\\}").search(scene_text)
	if lib != null:
		for m in RegEx.create_from_string("&\"([^\"]+)\"\\s*:").search_all(lib.get_string(1)):
			anim_names.append(m.get_string(1))
	row["proxy_animations"] = anim_names.size()
	anim_names.sort()
	row["proxy_animation_names"] = ";".join(anim_names)
	row["proxy_trackless"] = not scene_text.contains("tracks/0/type")

	# Read the script straight out of the scene's ext_resource. An earlier version
	# scanned the wrapper's own directory instead and reported seven wrappers as
	# "no script", which was wrong: five formation_ally_* share
	# allies/FormationAllyAnimated.gd and the two twin_gate variants share
	# boss_twin_gate_animated/BossTwinGateVariantAnimated.gd, both one level up.
	# The .tscn is the authoritative binding; the directory never was.
	var script_path := _script_of_scene(scene_text)
	if script_path.is_empty():
		row["anomalies"].append("no_script_binding")
		return row
	row["script"] = script_path
	row["shared_script"] = script_path.get_base_dir() != dir
	if not FileAccess.file_exists(script_path):
		row["anomalies"].append("script_missing_on_disk")
		return row

	var src := FileAccess.get_file_as_string(script_path)
	var keys: Array[String] = []
	var refs: Array[String] = []

	# Two ways a wrapper names its action FBXs, both mainstream:
	#   const ACTION_SCENES := { "idle": "res://...", ... }   (71 wrappers)
	#   @export var idle_scene_path, set per instance in the .tscn  (7 wrappers)
	# Reading only the first form is what made the seven @export wrappers look
	# contract-less in the first version of this matrix.
	var block := RegEx.create_from_string(
		"const ACTION_SCENES\\s*:=\\s*\\{([\\s\\S]*?)\\n\\}").search(src)
	if block != null:
		for m in RegEx.create_from_string(
				"\"([a-z_]+)\"\\s*:\\s*\"(res://[^\"]+)\"").search_all(block.get_string(1)):
			keys.append(m.get_string(1))
			refs.append(m.get_string(2))
		row["action_binding"] = "const_dict"
	else:
		# Not anchored with ^: Godot's RegEx is PCRE2 without multiline by default,
		# so ^ would only ever match the very start of the file.
		for m in RegEx.create_from_string(
				"\\n([a-z_]+)_scene_path = \"(res://[^\"]+)\"").search_all(scene_text):
			keys.append(m.get_string(1))
			refs.append(m.get_string(2))
		if not keys.is_empty():
			row["action_binding"] = "exported_per_instance"
	keys.sort()
	row["action_scene_keys"] = ";".join(keys)
	row["action_scene_count"] = refs.size()
	# No ACTION_SCENES and no exported paths is not a defect by itself: the baked
	# architecture has its model in the wrapper scene and nothing to lazy-load.
	# Flagging it as an anomaly was measuring one architecture with the other
	# architecture's ruler.
	row["baked"] = refs.is_empty()

	# A wrapper pointing at another unit's FBX is either deliberate rig sharing or
	# a copy-paste that nobody noticed. Reporting it is the point; deciding which
	# it is needs an art call, not a script.
	var foreign: Array[String] = []
	for r in refs:
		if not r.contains(unit):
			foreign.append(r.get_file())
	if not foreign.is_empty():
		row["foreign_action_refs"] = ";".join(foreign)
		row["anomalies"].append("foreign_action_fbx")

	row["has_process"] = src.contains("func _process(")
	row["process_polls_current_animation"] = src.contains("animation_player.current_animation")
	row["process_polls_is_playing"] = src.contains("is_playing()")

	if src.contains("current_action == \"attack\" and not animation_player.is_playing()"):
		row["attack_to_idle"] = "process_poll"
	elif src.contains("animation_finished"):
		row["attack_to_idle"] = "animation_finished_signal"
	else:
		row["attack_to_idle"] = "none_found"
		row["anomalies"].append("no_attack_to_idle_path")

	if src.contains("_activate_action(\"attack\", true)"):
		row["repeat_attack_restarts"] = "yes"
	elif bool(row.get("baked", false)) and src.contains("func play_attack"):
		# play("attack") on the one baked player restarts by definition — there is
		# no branch to re-activate, so the const_dict idiom simply does not apply.
		row["repeat_attack_restarts"] = "yes_by_replay"
	elif src.contains("func play_attack"):
		row["repeat_attack_restarts"] = "unclear"
		row["anomalies"].append("attack_restart_unclear")
	else:
		row["repeat_attack_restarts"] = "no_play_attack"
		row["anomalies"].append("no_play_attack")

	# Whatever the architecture, the two names the battle actually calls must exist.
	for required in ["idle", "attack"]:
		if not anim_names.has(required):
			row["anomalies"].append("missing_animation_" + required)

	return row


func _script_of_scene(scene_text: String) -> String:
	var m := RegEx.create_from_string(
		"\\[ext_resource type=\"Script\" path=\"(res://[^\"]+\\.gd)\"").search(scene_text)
	return "" if m == null else m.get_string(1)


func _category_of(path: String) -> String:
	for part in ["allies", "bosses", "mercenaries", "monsters", "units", "pve", "factions"]:
		if path.contains("/%s/" % part):
			return part
	return "other"


# --- runtime pass ---------------------------------------------------------------

func _runtime_pass(path: String, row: Dictionary) -> void:
	var packed := load(path) as PackedScene
	if packed == null:
		_errors.append("load_failed: %s" % path)
		row["anomalies"].append("scene_load_failed")
		return

	# Full load: this is what a battle actually instantiates.
	var full := await _measure(packed, false)
	if full.is_empty():
		row["anomalies"].append("instantiate_failed")
		return
	# Two architectures, and the arithmetic differs:
	#   proxy_plus_lazy_fbx  — a trackless proxy AnimationPlayer on the wrapper
	#                          drives players loaded from FBX at _ready(). The
	#                          proxy is not a per-unit cost, so subtract it.
	#   baked_single_scene   — the model lives in the wrapper scene and its one
	#                          AnimationPlayer is the real one. Subtracting here
	#                          reported these as "0 players", which read as broken
	#                          when they are simply built differently.
	row["architecture"] = ("proxy_plus_lazy_fbx" if not str(row["action_binding"]).is_empty()
		else "baked_single_scene")
	row["animation_players_total"] = int(full["players"])
	row["internal_players"] = (maxi(0, int(full["players"]) - 1)
		if row["architecture"] == "proxy_plus_lazy_fbx" else int(full["players"]))
	row["skeletons"] = int(full["skeletons"])
	row["bones"] = int(full["bones"])
	row["mesh_instances"] = int(full["meshes"])
	row["particles"] = int(full["particles"])
	row["audio_players"] = int(full["audio"])
	row["scripted_child_nodes"] = int(full["scripted"])

	# load_idle_only is the meta the wrapper honours to load one action instead of
	# three; the delta is what a lazy-load strategy would actually save.
	var idle := await _measure(packed, true)
	row["internal_players_idle_only"] = (maxi(0, int(idle.get("players", 0)) - 1)
		if row["architecture"] == "proxy_plus_lazy_fbx" else int(idle.get("players", -1)))

	if int(full["particles"]) > 0 or int(full["audio"]) > 0:
		# Pausing an AnimationPlayer does not stop a particle emitter or a sound.
		row["anomalies"].append("non_animation_nodes_in_actions")
	if int(row["internal_players"]) == 0:
		row["anomalies"].append("no_animation_player")


func _measure(packed: PackedScene, idle_only: bool) -> Dictionary:
	var node := packed.instantiate() as Node3D
	if node == null:
		return {}
	if idle_only:
		node.set_meta("load_idle_only", true)
	add_child(node)
	await get_tree().process_frame

	var counts := {"players": 0, "skeletons": 0, "bones": 0, "meshes": 0,
		"particles": 0, "audio": 0, "scripted": 0}
	_count(node, counts, node)

	remove_child(node)
	node.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	return counts


func _count(node: Node, counts: Dictionary, root: Node) -> void:
	if node is AnimationPlayer:
		counts["players"] = int(counts["players"]) + 1
	elif node is Skeleton3D:
		counts["skeletons"] = int(counts["skeletons"]) + 1
		counts["bones"] = int(counts["bones"]) + (node as Skeleton3D).get_bone_count()
	elif node is MeshInstance3D:
		counts["meshes"] = int(counts["meshes"]) + 1
	elif node is GPUParticles3D or node is CPUParticles3D:
		counts["particles"] = int(counts["particles"]) + 1
	elif node is AudioStreamPlayer3D or node is AudioStreamPlayer:
		counts["audio"] = int(counts["audio"]) + 1
	if node != root and node.get_script() != null:
		counts["scripted"] = int(counts["scripted"]) + 1
	for child in node.get_children():
		_count(child, counts, root)


# --- output ---------------------------------------------------------------------

func _write_outputs() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://reports"))

	var csv := FileAccess.open(OUT_CSV, FileAccess.WRITE)
	if csv != null:
		csv.store_line(",".join(COLUMNS))
		for row in _rows:
			var cells: Array[String] = []
			for col in COLUMNS:
				var v: Variant = row.get(col, "")
				if v is Array:
					v = ";".join(PackedStringArray(v))
				cells.append(_csv_cell(str(v)))
			csv.store_line(",".join(cells))
		csv.close()

	var json := FileAccess.open(OUT_JSON, FileAccess.WRITE)
	if json != null:
		json.store_string(JSON.stringify({
			"generated_by": "tools/wrapper_contract_matrix.gd",
			"read_only": true,
			"wrappers": _rows.size(),
			"errors": _errors,
			"rows": _rows,
		}, "  "))
		json.close()


func _csv_cell(value: String) -> String:
	if value.contains(",") or value.contains("\"") or value.contains("\n"):
		return "\"%s\"" % value.replace("\"", "\"\"")
	return value


func _print_summary() -> void:
	var players := 0
	var bones := 0
	var by_anomaly := {}
	var trackless := 0
	var polling := 0
	var max_row := {}
	for row in _rows:
		players += maxi(0, int(row["internal_players"]))
		bones += maxi(0, int(row["bones"]))
		if bool(row["proxy_trackless"]):
			trackless += 1
		if bool(row["process_polls_current_animation"]):
			polling += 1
		for a in row["anomalies"]:
			by_anomaly[a] = int(by_anomaly.get(a, 0)) + 1
		if max_row.is_empty() or int(row["bones"]) > int(max_row.get("bones", -1)):
			max_row = row

	print("")
	print("WRAPPER_MATRIX wrappers=%d internal_players=%d bones=%d"
		% [_rows.size(), players, bones])
	print("  无轨道代理动画: %d/%d   _process 轮询 current_animation: %d/%d"
		% [trackless, _rows.size(), polling, _rows.size()])
	if not max_row.is_empty():
		print("  骨骼最多: %s (%d 骨 / %d 骨架 / %d 内部播放器)"
			% [str(max_row["unit"]), int(max_row["bones"]),
				int(max_row["skeletons"]), int(max_row["internal_players"])])
	print("  异常:")
	var keys := by_anomaly.keys()
	keys.sort()
	for k in keys:
		print("    %-32s %d" % [str(k), int(by_anomaly[k])])
	if not _errors.is_empty():
		print("  错误 %d 条: %s" % [_errors.size(), ", ".join(_errors)])
	print("  -> %s" % OUT_CSV)
	print("  -> %s" % OUT_JSON)
