extends Node

const DATA_FILES := {
	"rounds": "res://data/rounds/round_schedule.json",
	"race_units": "res://data/units/race_units.json",
	"pve_monsters": "res://data/pve/pve_monsters.json",
	"bosses": "res://data/boss/bosses.json",
	"mercenaries": "res://data/mercenary/mercenaries.json",
	"treasures": "res://data/treasure/treasures.json",
	"formation_allies": "res://data/formation/formation_allies.json",
}

var data := {}

func _ready() -> void:
	load_all()

func load_all() -> void:
	data.clear()
	for key in DATA_FILES.keys():
		data[key] = _load_json(DATA_FILES[key])

func get_table(key: String) -> Variant:
	return data.get(key, {})

func _load_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_warning("Missing data file: %s" % path)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed == null:
		push_error("Invalid JSON: %s" % path)
		return {}
	return parsed
