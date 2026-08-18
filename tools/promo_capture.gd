extends SceneTree
# Promo footage recorder: runs one real battle and writes every rendered frame.
#
#   godot --path . --script tools/promo_capture.gd \
#         --write-movie <out>/frame.png --fixed-fps 60 --resolution 1080x1920 \
#         --quit-after <N> -- --out <out> --lineup dark_vs_god
#
# Use tools/promo_capture.ps1 rather than calling this directly - it computes
# --quit-after, cleans the output directory and keeps the PNGs away from the
# resource importer.
#
# This deliberately shares no code with tools/vfx_capture.gd. That one is a
# regression harness: grey void stage, capsule stand-ins, frozen animations,
# 12fps - every one of those chosen to keep a pixel diff meaningful. Promo
# footage needs the exact opposite (real arena, real models, animations running,
# 60fps), and that harness has a calibrated baseline that must not shift.
#
# Determinism: the replay is computed once up front from a fixed seed, and
# --fixed-fps pins every frame delta to 1/fps regardless of machine load. Same
# --seed + --lineup + --round reproduces the same footage frame for frame, so a
# clip that came out well can be re-shot at a higher resolution later.

const BATTLE_SCREEN_PATH := "res://scenes/battle/BattleScreen.tscn"
const PREP_SCREEN_PATH := "res://scenes/prep/PrepScreen.tscn"
const MAIN_MENU_PATH := "res://scenes/menu/MainMenu.tscn"

# Frames to let a non-battle screen build itself and settle before the footage
# is considered usable. Battle has an explicit ready flag to wait on; prep and
# menu do not, so this is a fixed lead-in that the encoder trims.
const SCREEN_WARMUP_FRAMES := 45
# The round the prep screen is staged at. 3 keeps the next round on the PvE
# schedule (pvp_rounds are 6/12/18/21), which avoids the PvP warning dialog
# popping over the board on the very first frames.
const PREP_ROUND := 3
const PREP_GOLD := 48

# Round 18 is a pvp round (see data/rounds/round_schedule.json: pvp_rounds =
# [6,12,18,21]). pvp means both sides field real units instead of PvE monsters,
# which is what the footage is meant to show off. 21 is excluded by default: it
# takes the final-round path with its own left/right layout and intro sequence.
const DEFAULT_ROUND := 18
const DEFAULT_SEED := 20260807
const DEFAULT_FPS := 60

# Hard ceiling so a malformed replay cannot spin forever writing PNGs to disk.
const MAX_SECONDS := 120.0
# Keep rolling after battle_finished so the result overlay lands in the footage.
const TAIL_FRAMES := 45

# Board cells to fill, in order. The board is 4x4 (GameConstants.BOARD_ROWS x
# BOARD_COLUMNS), index = row * 4 + col.
#
# NOTE: this assumes row 0 is the rank nearest the enemy, so melee fills first
# and the centre columns fill before the edges (a centred clump frames better
# than a spread line). If the first capture shows the ranged units in front,
# flip this to [13,14,12,15,9,10,8,11] - the sim decides engagement order from
# board position, so it changes the fight, not just the framing.
const FILL_ORDER: Array[int] = [1, 2, 0, 3, 5, 6, 4, 7]

# Curated matchups. Each side is three lanes (one per player seat in a 3v3);
# each lane is that seat's board, filled in FILL_ORDER.
#
# Picked for silhouette contrast and for skills that read at a glance. The
# tier-3 units carry the biggest effects: dark_dragon/black_hole is the largest
# in the library, god_king/global_divine_blast covers the whole field.
const LINEUPS := {
	# Default. Two visually opposite races, T3 anchors on both sides.
	"dark_vs_god": {
		"a": [
			["dark_suc", "dark_scythe", "dark_dragon", "dark_mage"],
			["dark_fear", "dark_queen", "dark_doom", "dark_imp"],
			["dark_suc", "dark_scythe", "dark_dragon", "dark_mage"],
		],
		"b": [
			["god_guard", "god_arbiter", "god_king", "god_priestess"],
			["god_aurora", "god_angel", "god_archangel", "god_priest"],
			["god_guard", "god_arbiter", "god_king", "god_priestess"],
		],
	},
	# Rot versus order. undead_bomb's death_poison_explosion is the payoff shot.
	"undead_vs_human": {
		"a": [
			["undead_spike", "undead_bomb", "undead_mother", "undead_poison"],
			["undead_titan", "undead_parasite", "undead_mother", "undead_fly"],
			["undead_spike", "undead_bomb", "undead_mother", "undead_poison"],
		],
		"b": [
			["human_swordsman", "human_archer", "human_king", "human_mage"],
			["human_militia", "human_swordsman", "human_king", "human_cleric"],
			["human_swordsman", "human_archer", "human_king", "human_mage"],
		],
	},
	# All four races on screen at once - the "32 units" establishing shot.
	"all_races": {
		"a": [
			["human_swordsman", "human_archer", "human_king", "human_mage"],
			["god_guard", "god_arbiter", "god_king", "god_priestess"],
			["human_militia", "god_aurora", "god_archangel", "human_cleric"],
		],
		"b": [
			["dark_suc", "dark_scythe", "dark_dragon", "dark_mage"],
			["undead_spike", "undead_bomb", "undead_mother", "undead_poison"],
			["dark_fear", "undead_titan", "dark_doom", "undead_fly"],
		],
	},
}

var _out_dir := ""
var _lineup := "dark_vs_god"
var _round := DEFAULT_ROUND
var _seed := DEFAULT_SEED
var _fps := DEFAULT_FPS
var _merc_count := 0
var _star := 3
var _locale := "en"
var _setup_done := false
# What to record: "battle" (a full fight), "prep" (the board/shop screen) or
# "menu" (the main menu). Prep and menu have no natural end, so they run until
# the runner's --quit-after ceiling.
var _scene := "battle"
# Vertical reframing. BattleArena's camera (BATTLE_CAMERA_SIZE 7.2, looking at
# the origin from 0,7.4,7.0) is tuned for 16:9; in a 9:16 frame the fight sits
# in the upper half with dead ground below. These pan/zoom the promo camera
# only - the game's own constants are untouched. 0 means "leave as the game has
# it", so the defaults reproduce the stock framing exactly.
var _camera_size := 0.0
var _pan_x := 0.0
# Along the camera's view axis: negative pulls the framing toward the near edge.
var _pan_z := 0.0
var _camera_applied := false

# Autoloads have to be reached through the tree. A script run with --script
# replaces the main loop before the autoload names are registered as global
# identifiers, so writing `GameState.foo` here is a compile error even though
# the singletons themselves are alive - the same reason tools/vfx_capture.gd
# goes through root.get_node("VFXManager"). Classes declared with class_name
# (GameConstants, NetProtocol) are unaffected and can be used normally.
var _game_state: Node = null
var _data: Node = null
var _network: Node = null
# NetProtocol is a class_name and would normally be usable directly, but naming
# it here would pull it into THIS script's compile, and its own body references
# the autoloads - so it fails for the reason above, one level removed. Loading it
# at runtime defers its compile until the singletons are registered.
var _net_protocol: GDScript = null
# GameState's consts are not reachable via Object.get(); pull the whole map once
# rather than duplicating the numbers here where they could drift.
var _gs_const: Dictionary = {}

var _screen: Node = null
var _frame := 0
# Frame at which the board finished building and the fight actually starts.
# Everything before it is the model-loading progress bar and must be trimmed;
# the encoder reads this out of manifest.json.
var _start_frame := -1
var _finished_frame := -1
var _replay_frames := 0
var _viewport_size := Vector2i.ZERO

func _initialize() -> void:
	_parse_arguments()
	if not LINEUPS.has(_lineup):
		push_error("Unknown lineup '%s'. Available: %s" % [_lineup, ", ".join(LINEUPS.keys())])
		quit(1)

# The whole setup runs on the first processed frame, NOT in _initialize().
#
# _initialize() fires before the autoload nodes have had their _ready() called,
# and LocaleManager registers the translation tables in its _ready(). Building
# the battle any earlier means TranslationServer.translate() hands back the key
# itself, and the battle log formats it with `%` against a string that has no
# placeholders - which spams "String formatting error" and leaves every unit
# label wrong. Waiting one frame is the whole fix.
func _setup() -> void:
	_game_state = root.get_node_or_null("GameState")
	_data = root.get_node_or_null("DataRegistry")
	_network = root.get_node_or_null("NetworkService")
	var locale_mgr := root.get_node_or_null("LocaleManager")
	if _game_state == null or _data == null or _network == null or locale_mgr == null:
		push_error("Autoloads missing - run with --path pointing at the project root.")
		quit(1)
		return
	# LocaleManager defaults to zh. Promo footage is aimed at the international
	# platforms, so every on-screen string has to come out English.
	locale_mgr.call("set_locale", _locale)
	_gs_const = _game_state.get_script().get_script_constant_map()
	_net_protocol = load("res://scripts/multiplayer/NetProtocol.gd") as GDScript
	if _net_protocol == null:
		push_error("Failed to load NetProtocol.gd")
		quit(1)
		return
	_data.call("load_all")
	match _scene:
		"menu":
			_setup_menu()
			return
		"prep":
			_setup_prep()
			return
	_setup_match_state()
	var replay := _compute_replay()
	if replay.is_empty():
		push_error("Replay came back empty - the matchup produced no fight.")
		quit(1)
		return
	_replay_frames = (replay.get("frames", []) as Array).size()
	print("promo_capture: lineup=%s round=%d seed=%d replay_frames=%d (~%.1fs of combat)" % [
		_lineup, _round, _seed, _replay_frames, _replay_frames * 0.1])
	# BattleScreen._ready() takes the prepared-replay path when this package is
	# waiting for it (see BattleScreen.gd:30), which skips all the netcode and
	# plays the replay straight away.
	_game_state.call("set_pending_battle_package", {
		"mode": "team_replay",
		"round_index": _round,
		"replay": replay,
	})
	_screen = _instantiate(BATTLE_SCREEN_PATH)
	if _screen == null:
		return
	_screen.battle_finished.connect(_on_battle_finished)
	root.add_child(_screen)

func _setup_menu() -> void:
	_screen = _instantiate(MAIN_MENU_PATH)
	if _screen != null:
		root.add_child(_screen)
		print("promo_capture: recording the main menu")

# Stages a mid-run prep screen: a board with pieces on it, gold in the bank and
# a shop to look at. PrepScreen rolls its own shop when GameState.shop_offers is
# empty, so only the run state has to be set up here.
func _setup_prep() -> void:
	_game_state.call("reset_run")
	# Single-player prep, not 3v3: team mode makes the screen wait on lobby and
	# round-start traffic that will never arrive in a capture.
	_game_state.set("team_mode", false)
	_game_state.set("round_index", PREP_ROUND)
	_game_state.set("gold", PREP_GOLD)
	# A battle lane is 4 pieces, which fills only the front row and leaves the
	# board looking half-empty on a screen whose whole point is the board. Merge
	# two lanes so both rows are populated, up to the 7-piece cap.
	var config: Dictionary = LINEUPS[_lineup]
	var lanes: Array = config["a"]
	var wide_board: Array = (lanes[0] as Array) + (lanes[1] as Array)
	_game_state.set("board_slots", _board_from_ids(wide_board))
	_game_state.set("mercenary_slots", _merc_slots())
	_screen = _instantiate(PREP_SCREEN_PATH)
	if _screen != null:
		root.add_child(_screen)
		print("promo_capture: recording the prep screen (round %d, %d gold)" % [
			PREP_ROUND, PREP_GOLD])

func _instantiate(path: String) -> Node:
	var packed := load(path) as PackedScene
	if packed == null:
		push_error("Failed to load %s" % path)
		quit(1)
		return null
	return packed.instantiate()

# Total frames the runner should allow for, used to size --quit-after.
func total_frames() -> int:
	return int(MAX_SECONDS * _fps)

func _process(_delta: float) -> bool:
	_frame += 1
	if not _setup_done:
		_setup_done = true
		_setup()
		return false
	if _screen == null or not is_instance_valid(_screen):
		return true
	# Prep and menu never finish on their own - they run to the ceiling, with a
	# fixed lead-in trimmed instead of a readiness flag to wait on.
	if _scene != "battle":
		if _start_frame < 0 and _frame >= SCREEN_WARMUP_FRAMES:
			_start_frame = _frame
			_write_manifest()
		if _frame >= total_frames():
			_write_manifest()
			return true
		return false
	# Models are built a few per frame with the board hidden; the fight only
	# starts once that finishes (BattleScreen.gd:273).
	if _start_frame < 0 and bool(_screen.get("_battle_setup_ready")):
		_start_frame = _frame
		_apply_camera_framing()
		_record_viewport_size()
		print("  battle starts at frame %d (3D viewport %dx%d)" % [
			_start_frame, _viewport_size.x, _viewport_size.y])
		# Write it now, not only on the way out. Godot's --quit-after kills the
		# process without running _process to completion, so a capture that hits
		# the ceiling would otherwise leave no manifest at all - and the encoder
		# then keeps the model-loading lead-in in the clip.
		_write_manifest()
	if _finished_frame >= 0 and _frame >= _finished_frame + TAIL_FRAMES:
		_write_manifest()
		return true
	if _frame >= total_frames():
		push_warning("Hit the %.0fs ceiling before the battle finished." % MAX_SECONDS)
		_write_manifest()
		return true
	return false

# Without this Godot reports "1 ObjectDB instance was leaked at exit" on stderr.
# Harmless in itself, but it is noise on every single capture, and PowerShell
# turns native stderr into terminating errors whenever the caller redirects the
# stream - so the leak warning alone can fail an otherwise good run.
func _finalize() -> void:
	if _screen != null and is_instance_valid(_screen):
		root.remove_child(_screen)
		_screen.free()
		_screen = null

func _on_battle_finished(result: Dictionary) -> void:
	_finished_frame = _frame
	print("  battle finished at frame %d: %s" % [_frame, str(result.get("reason", "?"))])

# The 3D battle renders into a SubViewport whose size is set to 960x540 at
# construction (BattleArena.gd:549), but its SubViewportContainer has
# stretch = true, so at runtime the viewport is resized to the container - i.e.
# it follows the window. Recorded here rather than assumed, because if it ever
# comes back 960x540 the footage is a 540p upscale and the whole capture is
# worth re-shooting.
# Applied once, after the board is built. Safe to set and forget: the battle's
# camera-shake hook (_update_vfx_camera_shake) is an empty stub, so nothing
# writes to the camera transform per frame and these values stick.
func _apply_camera_framing() -> void:
	if _camera_applied:
		return
	_camera_applied = true
	if is_zero_approx(_camera_size) and is_zero_approx(_pan_x) and is_zero_approx(_pan_z):
		return
	var camera = _screen.get("_battle_3d_camera")
	if not (camera is Camera3D):
		push_warning("No battle camera to reframe.")
		return
	var cam := camera as Camera3D
	if _camera_size > 0.0:
		cam.size = _camera_size
	if not (is_zero_approx(_pan_x) and is_zero_approx(_pan_z)):
		# Move the eye and the look-at target by the same delta, which pans the
		# view without changing the angle - the arena is a 3D model in this same
		# world, so it pans with the units and nothing goes out of register.
		var delta := Vector3(_pan_x, 0.0, _pan_z)
		cam.look_at_from_position(cam.position + delta, delta, Vector3.UP)
	print("  camera reframed: size=%.2f pan=(%.2f, %.2f)" % [cam.size, _pan_x, _pan_z])

func _record_viewport_size() -> void:
	var viewport = _screen.get("_battle_3d_viewport")
	if viewport is SubViewport:
		_viewport_size = (viewport as SubViewport).size
		if _viewport_size.y <= 540:
			push_warning("3D viewport is only %dx%d - footage will be an upscale." % [
				_viewport_size.x, _viewport_size.y])

# Build the 3v3 match state the simulator reads. Mirrors what the netcode leaves
# behind after every board has been submitted, which is the same shape
# tools/battle_perf_check_node.gd sets up - the difference is that this fills the
# two teams with DIFFERENT boards so the matchup is the curated one.
func _setup_match_state() -> void:
	var start_hp: int = _gs_const.get("START_FORMATION_HP", 50)
	_game_state.call("reset_run")
	_game_state.set("team_mode", true)
	_game_state.set("round_index", _round)
	_game_state.set("team_hp", start_hp)
	_game_state.set("enemy_team_hp", start_hp)

	_network.set("team_active", true)
	_network.set("team_local_slot", 0)
	_network.set("shared_seed", _seed)
	# All six seats must read as occupied: an empty rival slot spawns nothing at
	# all in its lane (BattleSimShared._team_slot_is_opponent), which would leave
	# a third of the field bare.
	_network.set("team_slot_states", ["player", "player", "player", "player", "player", "player"])

	var config: Dictionary = LINEUPS[_lineup]
	var lanes_a: Array = config["a"]
	var lanes_b: Array = config["b"]
	# Team A's board is also the local player's. Set it before building the
	# submissions: NetProtocol.team_board_submission reads treasures, synergy
	# flags and the active pet off the live GameState, so the boards have to be
	# assembled against a GameState that already looks like team A's seat.
	_game_state.set("board_slots", _board_from_ids(lanes_a[0]))
	_game_state.set("mercenary_slots", _merc_slots())

	var boards: Dictionary = {}
	# Slots 0-2 are team red, 3-5 team blue (GameConstants.team_of_slot).
	for lane in 3:
		boards[lane] = _submission_for(lanes_a[lane])
		boards[lane + 3] = _submission_for(lanes_b[lane])
	_network.set("team_boards", boards)

func _submission_for(unit_ids: Array) -> Dictionary:
	return _net_protocol.call("team_board_submission", _board_from_ids(unit_ids), _merc_slots())

func _board_from_ids(unit_ids: Array) -> Array:
	var board: Array = []
	board.resize(GameConstants.CELL_COUNT)
	var defs := _unit_defs()
	var unit_cap: int = _gs_const.get("MAX_NORMAL_UNITS", GameConstants.NORMAL_UNIT_CAP)
	var placed := 0
	for id in unit_ids:
		if placed >= FILL_ORDER.size() or placed >= unit_cap:
			break
		var key := str(id)
		if not defs.has(key):
			push_warning("Unknown unit id '%s' - skipped." % key)
			continue
		board[FILL_ORDER[placed]] = {
			"id": key,
			"star": _star,
			"def": (defs[key] as Dictionary).duplicate(true),
		}
		placed += 1
	return board

func _merc_slots() -> Array:
	var merc_cap: int = _gs_const.get("MERCENARY_SLOTS", 8)
	var slots: Array = []
	slots.resize(merc_cap)
	if _merc_count <= 0:
		return slots
	var table: Dictionary = _data.call("get_table", "mercenaries")
	var mercs: Array = table.get("mercenaries", [])
	for i in mini(_merc_count, merc_cap):
		if i >= mercs.size():
			break
		var mdef: Dictionary = (mercs[i] as Dictionary).duplicate(true)
		slots[i] = {"id": mdef.get("id", "merc"), "star": 1, "def": mdef}
	return slots

func _unit_defs() -> Dictionary:
	var defs: Dictionary = {}
	var table: Dictionary = _data.call("get_table", "race_units")
	for entry in table.get("units", []):
		if typeof(entry) == TYPE_DICTIONARY:
			defs[str((entry as Dictionary).get("id", ""))] = entry
	return defs

# Team 0's replay - the one a player on the red side would watch.
func _compute_replay() -> Dictionary:
	var sim := load("res://scripts/battle/BattleSimulator.gd")
	return sim.compute_team_replay(0)

func _write_manifest() -> void:
	if _out_dir.is_empty():
		return
	var manifest := {
		"scene": _scene,
		"lineup": _lineup,
		"round": _round,
		"seed": _seed,
		"fps": _fps,
		"star": _star,
		"locale": _locale,
		"mercenaries": _merc_count,
		# Frames before this one are the model-building progress bar, not combat.
		# Movie Maker numbers files from frame00000000.png, so the file index of
		# frame N is N-1.
		"start_frame": maxi(0, _start_frame - 1),
		"finished_frame": maxi(0, _finished_frame - 1),
		"total_frames": _frame,
		"replay_frames": _replay_frames,
		"viewport_3d": [_viewport_size.x, _viewport_size.y],
	}
	var path := _out_dir.path_join("manifest.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Could not write manifest to %s" % path)
		return
	file.store_string(JSON.stringify(manifest, "  "))
	file.close()
	print("promo_capture: wrote %s" % path)

func _parse_arguments() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var key := str(args[i])
		var value := str(args[i + 1]) if i + 1 < args.size() else ""
		match key:
			"--out": _out_dir = value
			"--lineup": _lineup = value
			"--round": _round = int(value)
			"--seed": _seed = int(value)
			"--fps": _fps = int(value)
			"--mercs": _merc_count = int(value)
			"--locale": _locale = value
			"--camera-size": _camera_size = float(value)
			"--pan-x": _pan_x = float(value)
			"--pan-z": _pan_z = float(value)
			"--scene": _scene = value
			"--star": _star = clampi(int(value), 1, GameConstants.MAX_STAR)
			_:
				push_warning("Unknown argument '%s'" % key)
				i += 1
				continue
		i += 2
