extends Resource
class_name VFXRecipe3D

@export var recipe_id := "new_recipe"
@export var display_name := "New VFX Recipe"
@export var description := ""
@export var tracks: Array[VFXTimelineTrack3D] = []

func total_duration() -> float:
	var result := 0.0
	for track in tracks:
		if track != null:
			result = maxf(result, track.start_time + track.duration / maxf(track.time_scale, 0.01))
	return result

func phases() -> PackedStringArray:
	var result := PackedStringArray()
	for track in tracks:
		if track != null and not result.has(track.phase):
			result.append(track.phase)
	return result

static func from_json(json_text: String) -> VFXRecipe3D:
	var parsed = JSON.parse_string(json_text)
	if not parsed is Dictionary:
		return null
	var recipe := VFXRecipe3D.new()
	recipe.recipe_id = str(parsed.get("recipe_id", "json_recipe"))
	recipe.display_name = str(parsed.get("display_name", recipe.recipe_id))
	recipe.description = str(parsed.get("description", ""))
	for raw_track in parsed.get("tracks", []):
		if not raw_track is Dictionary:
			continue
		var track := VFXTimelineTrack3D.new()
		track.track_id = str(raw_track.get("track_id", "layer"))
		track.phase = str(raw_track.get("phase", "Impact"))
		track.start_time = float(raw_track.get("start_time", 0.0))
		track.duration = maxf(float(raw_track.get("duration", 0.5)), 0.01)
		track.fade_in = maxf(float(raw_track.get("fade_in", 0.06)), 0.0)
		track.fade_out = maxf(float(raw_track.get("fade_out", 0.16)), 0.0)
		track.time_scale = maxf(float(raw_track.get("time_scale", 1.0)), 0.05)
		track.loop = bool(raw_track.get("loop", false))
		track.trigger_once = bool(raw_track.get("trigger_once", true))
		var script_path := str(raw_track.get("module_script", ""))
		if ResourceLoader.exists(script_path):
			track.module_script = load(script_path) as Script
		recipe.tracks.append(track)
	return recipe
