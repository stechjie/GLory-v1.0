extends Node

# One-command snapshot for a "I tapped it and nothing happened" report.
#
# The V3 review asked for a fixed report shape (V3 P2-06) so that every such report
# arrives with the same evidence instead of a sentence and a screenshot. Two of the
# fields it lists come from services that do not exist yet -- there is no
# ModalStack (P0-07) and no AsyncActionController (P0-05). Those are reported as
# {"available": false, "reason": ...}. Filling them with zeros would be worse than
# leaving them out, because a zero reads like a measurement.
#
# One field is answered anyway, by measurement rather than by registry:
# `input_blockers`. The reason "nothing happened" is usually that some full-screen
# Control with MOUSE_FILTER_STOP is still in the tree and ate the tap. There are
# more than ten places in this project that create one (BattleRenderer, PrepUI x4,
# TutorialMode, Main's reconnect overlay, ...) and nothing tracks them, which is
# exactly V3's C-08. So this walks the live tree and reports what is actually
# consuming input right now. When ModalStack lands it can replace this; until then
# it is the only answer available, and it is a real one.
#
# Usage:
#   IssueReport.capture("start button did nothing")   # from code or the debugger
#   F12 in a debug build
#
# Privacy: node paths and enum names only. Never the server address, the session
# token, the public room code or any user directory -- a report gets pasted into
# chat, and those are the fields that must not travel with it.

const LOG_PREFIX := "GLORY_ISSUE"
const SCHEMA_VERSION := 1

# A frame this long is one the player felt. 33 ms is the V3 list's own threshold.
const SLOW_FRAME_MS := 33.0
const SLOW_FRAME_KEEP := 10

# A Control has to cover at least this share of the viewport before it counts as a
# blocker. A small STOP button is doing its job; a full-screen one is the suspect.
const BLOCKER_MIN_VIEWPORT_SHARE := 0.5
const BLOCKER_SCAN_MAX_NODES := 4000

const REPORT_PATH_PREFIX := "user://issue_report_"

# Capture once, unattended, N seconds in. Exists because the interactive trigger
# (F12) needs a human, and the runs that most need a baseline -- tools/android_smoke.sh
# cold launches, --quit-after regression boots -- have nobody at the keyboard.
#
# Deliberately a delay rather than a capture at shutdown: by the time an autoload's
# _exit_tree() runs the main scene is already gone, so the screen is unknown and the
# blocker scan sees 22 nodes instead of the live UI. Measured, not assumed.
const AUTO_CAPTURE_FLAG := "--issue-report-after"
const AUTO_CAPTURE_DEFAULT_SEC := 10.0

var _slow_frames: Array[Dictionary] = []
var _enabled := true
var _last_report: Dictionary = {}
# Two captures inside the same millisecond would otherwise land on the same
# filename and the second would overwrite the first -- which is easy to do, since
# the interesting case is someone tapping repeatedly because nothing happened.
var _capture_seq := 0
var _last_recorded_ms := 0.0


func _ready() -> void:
	# Same rule as tools/PerfLog.gd and StartupTrace: only an explicit flag means
	# "this is a server". A bare --headless is how every tools/ check runs.
	if "--server" in OS.get_cmdline_args() or "--dedicated-server" in OS.get_cmdline_args():
		_enabled = false
		set_process(false)
		return
	set_process(true)
	_schedule_auto_capture()


# --issue-report-after            capture at AUTO_CAPTURE_DEFAULT_SEC
# --issue-report-after=25         capture at 25 s
func _schedule_auto_capture() -> void:
	var delay := -1.0
	for raw_arg in OS.get_cmdline_args():
		var arg := str(raw_arg)
		if arg == AUTO_CAPTURE_FLAG:
			delay = AUTO_CAPTURE_DEFAULT_SEC
		elif arg.begins_with(AUTO_CAPTURE_FLAG + "="):
			delay = maxf(0.0, float(arg.substr(AUTO_CAPTURE_FLAG.length() + 1)))
	if delay < 0.0:
		return
	var timer := get_tree().create_timer(delay)
	timer.timeout.connect(func(): capture("auto_capture_after_%.0fs" % delay))


func _process(_delta: float) -> void:
	if not _enabled:
		return
	# TIME_PROCESS is the previous frame's cost, which is what we want: the frame
	# the player's tap landed in has already gone by when they notice.
	var ms := float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
	if ms < SLOW_FRAME_MS:
		return
	# The monitor does not refresh every frame, so reading it on consecutive frames
	# returns the same value and one real stall gets recorded ten times -- which then
	# evicts every other slow frame from the buffer. Measured: a 64.8 ms warmup stall
	# filled all ten slots with identical entries. Only record a changed reading.
	if is_equal_approx(ms, _last_recorded_ms):
		return
	_last_recorded_ms = ms
	record_slow_frame(ms)


# Debug-only hotkey so the report is one keypress away rather than a thing you have
# to remember the API for. Observation only -- this never marks the event handled,
# because this node sits on the tree root and consuming input here would cause the
# very symptom the report exists to diagnose.
func _input(event: InputEvent) -> void:
	if not _enabled or not OS.is_debug_build():
		return
	if event is InputEventKey and (event as InputEventKey).pressed \
			and (event as InputEventKey).keycode == KEY_F12:
		capture("manual_f12")


# --- public API ---------------------------------------------------------------

func capture(reason: String) -> Dictionary:
	var report := {
		"schema_version": SCHEMA_VERSION,
		"reason": reason,
		"captured_at_ms": int(Time.get_ticks_msec()),
		"captured_utc": Time.get_datetime_string_from_system(true),
		"build": _build_section(),
		"startup": _startup_section(),
		"warmup": _warmup_section(),
		"screen": _screen_section(),
		"input_blockers": _input_blockers_section(),
		"slow_frames": _slow_frames.duplicate(true),
		"slow_frame_threshold_ms": SLOW_FRAME_MS,
		"network": _network_section(),
		"modal_stack": {
			"available": false,
			"reason": "ModalStack service does not exist yet (V3 P0-07)",
			"substitute": "see input_blockers, derived from the live scene tree",
		},
		"action_state": {
			"available": false,
			"reason": "AsyncActionController does not exist yet (V3 P0-05)",
		},
		"input_breadcrumbs": {
			"available": false,
			"reason": "InputBreadcrumb does not exist yet (V3 P0-05)",
		},
	}
	_last_report = report
	_emit(report)
	return report


func last_report() -> Dictionary:
	return _last_report.duplicate(true)


func slow_frames() -> Array:
	return _slow_frames.duplicate(true)


# Appends to the ring buffer. Public because _process() cannot be driven on demand:
# a headless check has no way to make a real frame take 40 ms, so the gate calls this
# directly. Same code path either way -- a test-only twin would let the real one rot.
func record_slow_frame(ms: float) -> void:
	_slow_frames.append({"ms": snappedf(ms, 0.1), "at_ms": int(Time.get_ticks_msec())})
	while _slow_frames.size() > SLOW_FRAME_KEEP:
		_slow_frames.remove_at(0)


# --- sections -----------------------------------------------------------------

func _build_section() -> Dictionary:
	# Reuses StartupTrace so a report and a startup log can never disagree about
	# which build they describe.
	if not is_instance_valid(StartupTrace):
		return {"available": false, "reason": "StartupTrace autoload missing"}
	return StartupTrace.build_info()


func _startup_section() -> Dictionary:
	if not is_instance_valid(StartupTrace):
		return {"available": false, "reason": "StartupTrace autoload missing"}
	var timeline: Dictionary = StartupTrace.timeline()
	var marks: Dictionary = timeline.get("marks", {})
	var out := {}
	for key in [StartupTrace.T1_FIRST_FRAME, StartupTrace.T2_MAIN_READY,
			StartupTrace.T3_INPUT_READY, StartupTrace.T4_FIRST_ACTION]:
		out[str(key)] = int(marks.get(key, -1))
	out["base"] = "engine_init"
	out["duplicate_marks"] = timeline.get("duplicates", []).size()
	return out


# Derived from the startup marks rather than from VFXWarmup itself: the warmup node
# frees itself when it finishes, so by the time anyone files a report it is usually
# gone and only its marks remain.
func _warmup_section() -> Dictionary:
	if not is_instance_valid(StartupTrace):
		return {"available": false, "reason": "StartupTrace autoload missing"}
	var marks: Dictionary = StartupTrace.timeline().get("marks", {})
	var phases := {}
	var last_phase := "none"
	for key in marks.keys():
		var name_value := str(key)
		if not name_value.begins_with("warmup_"):
			continue
		phases[name_value] = int(marks[key])
		last_phase = name_value
	return {
		"finished": marks.has("warmup_finished"),
		"last_phase_reached": last_phase,
		"phase_marks_ms": phases,
	}


# There is no screen router in this project (V3 P0-09 would add one), so the current
# screen is inferred from the tree. Labelled as derived so nobody reads it as a
# declared state.
func _screen_section() -> Dictionary:
	var tree := get_tree()
	if tree == null:
		return {"available": false, "reason": "no SceneTree"}
	var current := tree.current_scene
	if current == null:
		return {"available": false, "reason": "no current_scene"}
	var children: Array[String] = []
	for child in current.get_children():
		if child is CanvasItem and not (child as CanvasItem).visible:
			continue
		children.append("%s:%s" % [child.name, child.get_class()])
	return {
		"source": "derived_from_scene_tree (no screen router exists)",
		"current_scene": current.name,
		"current_scene_class": current.get_class(),
		"visible_children": children,
		"root_child_count": tree.root.get_child_count(),
	}


# The answer to "why did my tap do nothing". Walks the tree for visible Controls
# that both consume input and cover most of the viewport.
func _input_blockers_section() -> Dictionary:
	var tree := get_tree()
	if tree == null:
		return {"available": false, "reason": "no SceneTree"}
	var viewport_size := Vector2(tree.root.get_visible_rect().size)
	var viewport_area := maxf(viewport_size.x * viewport_size.y, 1.0)
	var found: Array[Dictionary] = []
	var scanned := [0]
	_scan_for_blockers(tree.root, viewport_area, found, scanned)
	var suspects: Array[Dictionary] = []
	for entry in found:
		if bool(entry.get("suspect", false)):
			suspects.append(entry)
	return {
		"source": "derived_from_scene_tree (no ModalStack exists)",
		"viewport": "%dx%d" % [int(viewport_size.x), int(viewport_size.y)],
		"nodes_scanned": scanned[0],
		"scan_truncated": scanned[0] >= BLOCKER_SCAN_MAX_NODES,
		"count": found.size(),
		# Read this one first. `count` includes the ordinary full-screen backgrounds
		# every screen has -- Control and ColorRect both default to MOUSE_FILTER_STOP,
		# so a healthy language screen already reports two. Only `suspects` are the
		# ones that can explain a swallowed tap.
		"suspect_count": suspects.size(),
		"suspects": suspects,
		"blockers": found,
	}


func _scan_for_blockers(node: Node, viewport_area: float,
		found: Array[Dictionary], scanned: Array) -> void:
	if scanned[0] >= BLOCKER_SCAN_MAX_NODES:
		return
	scanned[0] = int(scanned[0]) + 1
	if node is Control:
		var control := node as Control
		var is_scene_root := control == get_tree().current_scene
		if control.visible and control.is_visible_in_tree() \
				and control.mouse_filter == Control.MOUSE_FILTER_STOP \
				and not is_scene_root:
			var rect := control.get_global_rect()
			var share := (rect.size.x * rect.size.y) / viewport_area
			if share >= BLOCKER_MIN_VIEWPORT_SHARE:
				# A blocker the player cannot see is the worst kind: the screen looks
				# interactive and every tap is swallowed.
				var invisible := control.modulate.a <= 0.02
				var in_layer := _canvas_layer_of(control)
				# What separates a suspect from ordinary furniture: it sits on a
				# CanvasLayer above the screen, or it hangs off the root outside the
				# current scene, or it is transparent yet still eating input. A plain
				# opaque background inside the active screen is just a background.
				var outside_scene := not _is_inside_current_scene(control)
				found.append({
					"path": str(control.get_path()),
					"class": control.get_class(),
					"script": _script_path_of(control),
					"rect": "%dx%d@%d,%d" % [
						int(rect.size.x), int(rect.size.y),
						int(rect.position.x), int(rect.position.y)],
					"viewport_share": snappedf(share, 0.01),
					"self_modulate_alpha": snappedf(control.self_modulate.a, 0.01),
					"modulate_alpha": snappedf(control.modulate.a, 0.01),
					"invisible_but_blocking": invisible,
					"canvas_layer": in_layer,
					"outside_current_scene": outside_scene,
					"suspect": invisible or outside_scene or in_layer != -9999,
				})
	for child in node.get_children():
		_scan_for_blockers(child, viewport_area, found, scanned)


# The CanvasLayer this control draws on, or -9999 when it is in the ordinary scene
# layer. Overlays are put on a CanvasLayer precisely so they sit above the screen,
# which is also what makes a stale one able to swallow every tap.
func _canvas_layer_of(node: Node) -> int:
	var walker := node.get_parent()
	while walker != null:
		if walker is CanvasLayer:
			return (walker as CanvasLayer).layer
		walker = walker.get_parent()
	return -9999


func _is_inside_current_scene(node: Node) -> bool:
	var current := get_tree().current_scene
	if current == null:
		return false
	return current.is_ancestor_of(node)


func _script_path_of(node: Node) -> String:
	var script_ref: Variant = node.get_script()
	if script_ref == null:
		return ""
	return str((script_ref as Script).resource_path)


# State only. The address, port, seat token and public room code are deliberately
# absent: a report is meant to be pasted into a chat window.
func _network_section() -> Dictionary:
	if not is_instance_valid(NetworkService):
		return {"available": false, "reason": "NetworkService autoload missing"}
	var names := ["OFFLINE", "JOINING", "READY", "FAILED", "RECONNECTING"]
	var index := int(NetworkService.state)
	var state_name := "UNKNOWN(%d)" % index
	if index >= 0 and index < names.size():
		state_name = str(names[index])
	return {"state": state_name}


# --- output -------------------------------------------------------------------

func _emit(report: Dictionary) -> void:
	# The full report is far too big for logcat, so the line is a summary and the
	# detail goes to a file. The line alone still says whether input was blocked.
	var blockers: Dictionary = report.get("input_blockers", {})
	var summary := {
		"reason": str(report.get("reason", "")),
		"screen": str((report.get("screen", {}) as Dictionary).get("current_scene", "?")),
		"input_blockers": int(blockers.get("count", -1)),
		"input_blocker_suspects": int(blockers.get("suspect_count", -1)),
		"slow_frames_kept": (report.get("slow_frames", []) as Array).size(),
		"network": str((report.get("network", {}) as Dictionary).get("state", "?")),
		"file": _write_report(report),
	}
	print("%s %s" % [LOG_PREFIX, JSON.stringify(summary)])


func _write_report(report: Dictionary) -> String:
	_capture_seq += 1
	var path := "%s%d_%d.json" % [REPORT_PATH_PREFIX, int(Time.get_ticks_msec()), _capture_seq]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	return path
