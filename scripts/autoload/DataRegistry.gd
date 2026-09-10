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
var _canonical_unit_defs: Dictionary = {}

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
	_rebuild_unit_index()
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

# Network shop payloads and old saves contain a snapshot of the whole unit row.
# Gameplay still keys units by `id`, but that snapshot also used to make display
# names stale forever after a rename. Keep one local source of truth for the two
# presentation-only fields; callers must not replace the whole def with this row,
# because a live def may contain four-star overrides or king growth.
func canonical_unit_def(unit_id: String) -> Dictionary:
	var found: Variant = _canonical_unit_defs.get(unit_id, {})
	return found as Dictionary if typeof(found) == TYPE_DICTIONARY else {}

func _rebuild_unit_index() -> void:
	_canonical_unit_defs.clear()
	for table_and_rows in [["race_units", "units"], ["mercenaries", "mercenaries"]]:
		for raw in get_table(str(table_and_rows[0])).get(str(table_and_rows[1]), []):
			if typeof(raw) != TYPE_DICTIONARY:
				continue
			var unit_id := str((raw as Dictionary).get("id", ""))
			if not unit_id.is_empty():
				_canonical_unit_defs[unit_id] = raw

func canonicalize_unit_display_names(definition: Dictionary) -> void:
	var canonical := canonical_unit_def(str(definition.get("id", "")))
	if canonical.is_empty():
		return
	for key in ["name", "name_en"]:
		if canonical.has(key):
			definition[key] = canonical[key]

func unit_display_name(definition: Dictionary, english: bool) -> String:
	var canonical := canonical_unit_def(str(definition.get("id", "")))
	var display := canonical if not canonical.is_empty() else definition
	if english:
		var name_en := str(display.get("name_en", ""))
		if not name_en.is_empty():
			return name_en
	return str(display.get("name", str(definition.get("id", "?"))))

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
