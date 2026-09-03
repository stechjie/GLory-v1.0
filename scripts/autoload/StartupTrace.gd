extends Node

# Startup timeline instrumentation.
#
# Why this exists: every statement made about this game's startup so far has been a
# stopwatch estimate. `am start -W` reports when Android put a window on screen
# (~250 ms on the vivo), which is not when the player can do anything -- the
# language screen shows up seconds later. Without marks inside the process there is
# no way to say which segment is slow, so optimizing it is guesswork.
#
# What this deliberately does NOT claim: T0. Godot's clock starts at engine init, so
# the Android process start, the zygote fork and the dex/so loading before it are
# invisible from in here. Every line therefore carries base="engine_init", and
# bridging to the real process start is logcat's job -- tools/android_smoke.sh pairs
# these marks with the `Displayed` line that only the system server can emit.
#
# Output is one line per mark so it survives `adb logcat`:
#   GLORY_STARTUP {"mark":"t3_first_input_ready","ms":2140,"base":"engine_init",...}
#
# Reading the numbers:
#   t1_first_frame       the lightweight branded Bootstrap was presented.
#   t2_godot_main_ready  Main._ready() returned.
#   t3_first_input_ready a real control is on screen and can be pressed.
#   t4_first_action      the first meaningful action the player took completed.

const LOG_PREFIX := "GLORY_STARTUP"
const BUILD_LOG_PREFIX := "GLORY_BUILD"

# Written by tools/android_smoke.sh immediately before the export, so it travels
# inside the APK. Absent on desktop and in the editor -- that is the normal case,
# not an error, and build_info() says so rather than inventing values.
# Generated at export time by tools/android_smoke.sh and gitignored, so it is
# legitimately absent from every source tree. The trailing marker (which must sit on
# the same line as the literal) stops tools/asset_manifest_check from reporting a
# missing_asset that could never be fixed.
const BUILD_INFO_PATH := "res://build_info.json"  # asset-manifest-ignore

# The earliest instant any GDScript in this project can observe. StartupTrace is the
# first autoload, so Time.get_ticks_msec() here *is* the engine's own boot cost:
# everything before it is Godot starting up, loading the .pck, building the import
# and UID tables -- no game code has run yet.
#
# Added after the first real device run measured t3_first_input_ready at 8949 ms with
# data_registry_loaded already at 7972 ms, and DataRegistry's own parse taking 7.8 ms.
# That meant ~8 s was disappearing somewhere with no instrumentation at all, and the
# obvious suspects (duplicate data load, warmup ordering) were provably milliseconds.
# This mark splits that dark region into "engine boot" and "autoload construction",
# which is the difference between optimizing the right thing and guessing.
const T0_TRACE_READY := "t0_trace_ready"

const T1_FIRST_FRAME := "t1_first_frame"
const T2_MAIN_READY := "t2_godot_main_ready"
const T3_INPUT_READY := "t3_first_input_ready"
const T4_FIRST_ACTION := "t4_first_action_complete"

# The ordered spine of a startup. Marks outside this list are still recorded (phase
# detail, data loading), they just do not participate in the ordering assertion.
#
# Bootstrap is the project main scene, so its branded first frame must precede Main.
# If T2 arrives before T1 again, the startup path has regressed to loading the full
# interface before showing an acknowledgement frame.
const ORDERED_MARKS: PackedStringArray = [
	T0_TRACE_READY, T1_FIRST_FRAME, T2_MAIN_READY, T3_INPUT_READY, T4_FIRST_ACTION,
]

const TRACE_PATH := "user://startup_trace.jsonl"
# Rotated rather than grown without bound: the 20-launch cold/hot matrix appends 20
# runs to this file and nobody prunes it.
const TRACE_MAX_BYTES := 262144

# Substrings that disqualify a metadata key. Startup marks describe timing, and a
# release build's logcat is not the place for a session token or a room address.
const SENSITIVE_KEY_PARTS: PackedStringArray = [
	"token", "password", "secret", "address", "session", "credential", "auth",
]
const MAX_META_VALUE_LEN := 96

var _marks: Dictionary = {}
var _order: Array[String] = []
var _duplicates: Array[String] = []
var _enabled := true
# Kept so tools/startup_trace_check.gd can assert against the line that was really
# emitted. Re-deriving it in the test would only prove the test can format JSON.
var _last_line := ""
var _build_info: Dictionary = {}


func _ready() -> void:
	# Same rule as scripts/autoload/PerfLog.gd: only an explicit flag counts as "this is a
	# server". A bare --headless is how every tools/ check runs, and those are
	# allowed to trace.
	#
	# Unlike PerfLog this goes quiet rather than freeing itself. Other autoloads call
	# StartupTrace.mark() during their own _ready(), and an autoload that has already
	# queue_free()d itself turns those into calls on a freed instance. There is no
	# _process() here, so staying resident costs one idle node.
	if "--server" in OS.get_cmdline_args() or "--dedicated-server" in OS.get_cmdline_args():
		_enabled = false
		return
	_rotate_trace_if_large()
	# Marked before anything else this autoload does, including reading build_info:
	# the value only means "engine boot cost" if nothing of ours has run yet.
	mark(T0_TRACE_READY, {"note": "engine boot; no game code has run before this"})
	# A trace nobody can attribute to a build is not evidence. V3 P0-01.3 asks for it.
	_load_build_info()
	if not RenderingServer.frame_post_draw.is_connected(_on_first_frame):
		RenderingServer.frame_post_draw.connect(_on_first_frame)


func _on_first_frame() -> void:
	if RenderingServer.frame_post_draw.is_connected(_on_first_frame):
		RenderingServer.frame_post_draw.disconnect(_on_first_frame)
	mark(T1_FIRST_FRAME)


# --- public API ---------------------------------------------------------------

# Records a named moment. The first call for a name wins; later ones are counted as
# duplicates and logged, but never overwrite the original timing -- a mark that can
# be moved by a later caller is not evidence of anything.
func mark(mark_name: String, meta: Dictionary = {}) -> void:
	if not _enabled or mark_name.is_empty():
		return
	if _marks.has(mark_name):
		_duplicates.append(mark_name)
		_emit({
			"mark": mark_name,
			"ms": _now_ms(),
			"base": "engine_init",
			"duplicate_of_ms": int(_marks[mark_name]),
			"meta": _sanitize(meta),
		})
		return
	var ms := _now_ms()
	_marks[mark_name] = ms
	_order.append(mark_name)
	_emit({
		"mark": mark_name,
		"ms": ms,
		"base": "engine_init",
		"since_previous_ms": _since_previous_ms(ms),
		"meta": _sanitize(meta),
	})


func mark_first_frame() -> void:
	mark(T1_FIRST_FRAME)


# Call this once the screen's controls are actually on screen and hittable, not when
# the scene was instantiated -- the gap between the two is the thing being measured.
func mark_input_ready(screen: String) -> void:
	mark(T3_INPUT_READY, {"screen": screen})


func mark_first_action(action: String, result: String) -> void:
	mark(T4_FIRST_ACTION, {"action": action, "result": result})


# For tests and for the QA overlay. Copies, so a caller cannot edit the record.
func timeline() -> Dictionary:
	return {
		"marks": _marks.duplicate(true),
		"order": _order.duplicate(),
		"duplicates": _duplicates.duplicate(),
	}


# The exact text of the most recent emitted line, as it reached stdout.
func last_line() -> String:
	return _last_line


# Build identity for this binary. Always has "available"; when false it also has
# "reason", and none of the identity fields are present -- callers must render the
# absence rather than substitute a zero or the current time, or a desktop run will
# read back as a build that never happened.
func build_info() -> Dictionary:
	return _build_info.duplicate(true)


# One-line summary for a QA overlay. Deliberately short: it sits over gameplay.
func build_info_label() -> String:
	if not bool(_build_info.get("available", false)):
		return "build ?  (%s)" % str(_build_info.get("reason", "unknown"))
	var commit := str(_build_info.get("git_commit_short", "?"))
	if int(_build_info.get("dirty_tracked_files", 0)) > 0:
		commit += "+dirty"
	return "%s  %s v%s  assets %s" % [
		commit,
		str(_build_info.get("package_id", "?")),
		str(_build_info.get("version_code", "?")),
		str(_build_info.get("asset_inventory_sha256", "?")).substr(0, 8),
	]


func has_mark(mark_name: String) -> bool:
	return _marks.has(mark_name)


func ms_of(mark_name: String) -> int:
	return int(_marks.get(mark_name, -1))


# True when the ordered spine appeared in the right sequence. Marks that never
# happened are ignored: a run that stopped at t2 is incomplete, not out of order.
func ordering_is_sane() -> bool:
	var last := -1
	for name_value in ORDERED_MARKS:
		var mark_name := str(name_value)
		if not _marks.has(mark_name):
			continue
		var ms := int(_marks[mark_name])
		if ms < last:
			return false
		last = ms
	return true


# --- internals ----------------------------------------------------------------

func _load_build_info() -> void:
	_build_info = {"available": false, "reason": "not_generated"}
	if not FileAccess.file_exists(BUILD_INFO_PATH):
		# Desktop and editor runs simply have no build: say so, do not guess.
		_build_info["reason"] = "absent_desktop_or_editor_build"
		_emit_build_line()
		return
	var text := FileAccess.get_file_as_string(BUILD_INFO_PATH)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		_build_info["reason"] = "unparseable"
		_emit_build_line()
		return
	_build_info = (parsed as Dictionary).duplicate(true)
	# GDScript's JSON parses every number as float, so version_code 5 comes back as
	# 5.0 and the identity line reads "v5.0" while every other report says "5".
	# These are counts and ids, never fractional.
	for key in ["schema_version", "dirty_tracked_files", "version_code"]:
		if _build_info.has(key):
			_build_info[key] = int(_build_info[key])
	_build_info["available"] = true
	_emit_build_line()


func _emit_build_line() -> void:
	# Same one-line JSON shape as the marks, so tools/android_smoke.sh can pull it
	# out of logcat the same way. Sanitised for the same reason.
	var payload := _sanitize(_build_info)
	var line := "%s %s" % [BUILD_LOG_PREFIX, JSON.stringify(payload)]
	_last_line = line
	print(line)
	if OS.is_debug_build():
		_append_trace(line)


func _now_ms() -> int:
	return int(Time.get_ticks_msec())


func _since_previous_ms(ms: int) -> int:
	if _order.size() < 2:
		return 0
	var previous := str(_order[_order.size() - 2])
	return ms - int(_marks.get(previous, ms))


func _emit(payload: Dictionary) -> void:
	var line := "%s %s" % [LOG_PREFIX, JSON.stringify(payload)]
	_last_line = line
	print(line)
	if OS.is_debug_build():
		_append_trace(line)


func _append_trace(line: String) -> void:
	var file := FileAccess.open(TRACE_PATH, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(TRACE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	file.store_line(line)
	file.close()


func _rotate_trace_if_large() -> void:
	if not OS.is_debug_build():
		return
	if not FileAccess.file_exists(TRACE_PATH):
		return
	var file := FileAccess.open(TRACE_PATH, FileAccess.READ)
	if file == null:
		return
	var size := file.get_length()
	file.close()
	if size <= TRACE_MAX_BYTES:
		return
	var truncated := FileAccess.open(TRACE_PATH, FileAccess.WRITE)
	if truncated != null:
		truncated.close()


# Drops keys that could carry identity or network detail, and clips long values.
# Applied in every build, not just release: a mark is a timing record, and letting
# debug builds log more only guarantees the two behave differently under test.
func _sanitize(meta: Dictionary) -> Dictionary:
	var out := {}
	for key in meta.keys():
		var key_name := str(key).to_lower()
		if _is_sensitive_key(key_name):
			out[str(key)] = "<redacted>"
			continue
		var value: Variant = meta[key]
		if typeof(value) == TYPE_STRING:
			var text := str(value)
			if text.length() > MAX_META_VALUE_LEN:
				text = text.substr(0, MAX_META_VALUE_LEN) + "…"
			out[str(key)] = text
		else:
			out[str(key)] = value
	return out


func _is_sensitive_key(key_name: String) -> bool:
	for part in SENSITIVE_KEY_PARTS:
		if key_name.contains(str(part)):
			return true
	return false
