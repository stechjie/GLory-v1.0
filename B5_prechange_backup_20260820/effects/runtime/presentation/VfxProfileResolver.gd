class_name VfxProfileResolver
extends RefCounted

# Picks the presentation profile for an event (checklist section 4.2:
# "type + skill_id + race + quality_tier"). It reads only immutable event fields
# and never touches simulation state.
#
# A missing profile is not an error the player should ever see: the resolver hands
# back a deliberately cheap built-in fallback and aggregates one warning per
# type/profile pair, exactly as 4.2 requires.

const ProfileScript := preload("res://effects/runtime/presentation/BattleCueProfile.gd")
const PROFILE_DIR := "res://data/vfx/battle_cues/"

const KNOWN_PROFILE_IDS := [
	"basic_melee",
	"basic_ranged",
	"crit",
	"heal",
	"death",
]

var _profiles: Dictionary = {}
var _fallback: Resource = null
var _missing_warned: Dictionary = {}
var _missing_rows: Array[Dictionary] = []
var _resolved_counts: Dictionary = {}


func _init() -> void:
	_fallback = _build_fallback()


# Returns how many profiles loaded. A caller that gets 0 must treat it as a
# failure, not as "nothing to do" (README A3: an empty check set is not a pass).
func load_profiles() -> int:
	_profiles.clear()
	for profile_id in KNOWN_PROFILE_IDS:
		var path := "%s%s.tres" % [PROFILE_DIR, profile_id]
		if not ResourceLoader.exists(path):
			_report_missing("<load>", profile_id, "profile resource not found: %s" % path)
			continue
		var resource := ResourceLoader.load(path)
		if resource == null or resource.get_script() != ProfileScript:
			_report_missing("<load>", profile_id, "profile resource failed to load: %s" % path)
			continue
		var profile: Resource = resource
		if str(profile.get("id")) != profile_id:
			_report_missing("<load>", profile_id, "profile id mismatch: file says '%s'" % str(profile.get("id")))
		_profiles[profile_id] = profile
	return _profiles.size()


func has_profile(profile_id: String) -> bool:
	return _profiles.has(profile_id)


func profile_ids() -> Array:
	var out: Array = _profiles.keys()
	out.sort()
	return out


# The id this event would like, before checking whether it actually exists.
func wanted_profile_id(event: Dictionary) -> String:
	var event_type := str(event.get("type", ""))
	match event_type:
		"death":
			return "death"
		"heal":
			return "heal"
		"impact":
			return "crit" if bool(event.get("is_crit", false)) else _basic_id(event)
		"attack_start", "projectile_spawn":
			return _basic_id(event)
		"hit_number":
			if str(event.get("kind", "")) == "heal":
				return "heal"
			return "crit" if bool(event.get("is_crit", false)) else _basic_id(event)
	return ""


func resolve(event: Dictionary) -> Resource:
	var wanted := wanted_profile_id(event)
	if wanted.is_empty():
		# Types with no profile yet (skill_shake, unit_skill_proc, ...) are still
		# legitimate; they simply run on the cheap fallback until D6 migrates them.
		return _fallback
	# Race-qualified profiles do not exist yet, but resolving them first is the
	# documented extension point for per-race art (checklist 4.2).
	var race := str(event.get("race", ""))
	if not race.is_empty():
		var race_id := "%s_%s" % [wanted, race]
		if _profiles.has(race_id):
			return _count(_profiles[race_id])
	if _profiles.has(wanted):
		return _count(_profiles[wanted])
	var fallback_id := ""
	var probe: Variant = _profiles.get(wanted)
	if probe != null and probe is Resource:
		fallback_id = str((probe as Resource).get("fallback_profile"))
	if not fallback_id.is_empty() and _profiles.has(fallback_id):
		_report_missing(str(event.get("type", "")), wanted, "using declared fallback '%s'" % fallback_id)
		return _count(_profiles[fallback_id])
	_report_missing(str(event.get("type", "")), wanted, "no profile and no fallback; using built-in cheap cue")
	return _count(_fallback)


# Timing and budget fields with the current quality tier folded in.
func resolve_fields(event: Dictionary) -> Dictionary:
	return resolve(event).resolved_for_tier(tier_name())


static func tier_name() -> String:
	match VFXQualityBudget.tier:
		VFXQualityBudget.Tier.LOW:
			return "LOW"
		VFXQualityBudget.Tier.HIGH:
			return "HIGH"
	return "MEDIUM"


func missing_rows() -> Array[Dictionary]:
	return _missing_rows.duplicate(true)


func resolved_counts() -> Dictionary:
	return _resolved_counts.duplicate(true)


func reset_reports() -> void:
	_missing_warned.clear()
	_missing_rows.clear()
	_resolved_counts.clear()


func _basic_id(event: Dictionary) -> String:
	var skill_id := str(event.get("skill_id", ""))
	if skill_id == "basic_ranged":
		return "basic_ranged"
	if skill_id == "basic_melee":
		return "basic_melee"
	return ""


func _count(profile: Resource) -> Resource:
	var profile_id := str(profile.get("id"))
	var key := profile_id if not profile_id.is_empty() else "<fallback>"
	_resolved_counts[key] = int(_resolved_counts.get(key, 0)) + 1
	return profile


# One warning per type/profile pair, not per cue: a missing profile in a long
# battle would otherwise print thousands of identical lines.
func _report_missing(event_type: String, profile_id: String, detail: String) -> void:
	var key := "%s|%s" % [event_type, profile_id]
	if _missing_warned.has(key):
		return
	_missing_warned[key] = true
	_missing_rows.append({
		"event_type": event_type,
		"profile_id": profile_id,
		"detail": detail,
	})
	if OS.is_debug_build():
		push_warning("[VFX_PROFILE] %s / %s: %s" % [event_type, profile_id, detail])


# Deliberately the cheapest thing that still reads as a cue: no scene, no camera,
# short timings, ambient priority so the budget may merge it away first.
func _build_fallback() -> Resource:
	var profile: Resource = ProfileScript.new()
	profile.id = "fallback_minimal"
	profile.event_types = PackedStringArray()
	profile.priority = "ambient"
	profile.anchors = {"source": "CastAnchor", "target": "HitAnchor"}
	profile.windup_ms = 40
	profile.impact_ms = 40
	profile.recovery_ms = 40
	profile.camera_mode = "none"
	profile.audio_cue = ""
	profile.vfx_scene = ""
	profile.max_concurrent = 4
	profile.quality_overrides = {}
	profile.fallback_profile = ""
	return profile
