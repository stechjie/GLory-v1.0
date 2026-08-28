extends Node

# Static game data, read from JSON once per process.
#
# It used to be read twice: this autoload's _ready() called load_all(), and then
# Main._ready() called it again a moment later. Both are synchronous, so the second
# pass re-read and re-parsed all eight files on the way to the first frame for no
# effect other than the delay.
#
# So there are now two entry points with different jobs:
#   ensure_loaded()  idempotent. Callers who just need the data present.
#   load_all()       forced re-read, always. tools/ checks and the debug scenes use
#                    it to pick up edits without restarting, which is why it did not
#                    simply become idempotent.

enum State { UNINITIALIZED, LOADING, READY, FAILED }

const DATA_FILES := {
	"rounds": "res://data/rounds/round_schedule.json",
	"race_units": "res://data/units/race_units.json",
	"pve_monsters": "res://data/pve/pve_monsters.json",
	"bosses": "res://data/boss/bosses.json",
	"mercenaries": "res://data/mercenary/mercenaries.json",
	"treasures": "res://data/treasure/treasures.json",
	"formation_allies": "res://data/formation/formation_allies.json",
	"pets": "res://data/pets/pets.json",
}

signal ready_changed(state: int)

var data := {}
var state: int = State.UNINITIALIZED
# Paths that were missing or unparseable on the last load. A caller that needs to
# know whether it is running on complete data can read this instead of guessing
# from an empty table.
var failed_files: Array[String] = []
# Counts actual disk reads. tools/data_registry_check.gd asserts this stays at 1
# across repeated ensure_loaded() calls -- the whole point of the split.
var _file_reads := 0

func _ready() -> void:
	ensure_loaded()

# Loads once. Repeat calls are free and do not touch the disk.
func ensure_loaded() -> void:
	if state == State.READY or state == State.LOADING:
		return
	load_all()

# Always re-reads. Used by tools/ checks and the debug preview scenes.
func load_all() -> void:
	state = State.LOADING
	var started_us := Time.get_ticks_usec()
	data.clear()
	failed_files.clear()
	for key in DATA_FILES.keys():
		data[key] = _load_json(DATA_FILES[key])
	state = State.FAILED if not failed_files.is_empty() else State.READY

	var elapsed_ms := float(Time.get_ticks_usec() - started_us) / 1000.0
	# File names only, never contents: this line goes to a release logcat.
	StartupTrace.mark("data_registry_loaded", {
		"files": DATA_FILES.size(),
		"reads": _file_reads,
		"elapsed_ms": snappedf(elapsed_ms, 0.1),
		"failed": failed_files.size(),
	})
	ready_changed.emit(state)

func get_table(key: String) -> Variant:
	return data.get(key, {})

func is_ready() -> bool:
	return state == State.READY

func _load_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		failed_files.append(path)
		push_warning("Missing data file: %s" % path)
		return {}
	_file_reads += 1
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed == null:
		failed_files.append(path)
		push_error("Invalid JSON: %s" % path)
		return {}
	return parsed
