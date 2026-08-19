class_name BattleCueProfile
extends Resource

# One presentation profile for a family of cues (checklist section 6).
#
# A profile decides how long a cue takes, which anchors it reads, how many may run
# at once and how it degrades on a low tier. It never decides damage, targeting or
# who dies — those are settled in the simulation long before a profile is read.

# Stable id, matching the .tres file name.
@export var id: String = ""

# Event types this profile serves, e.g. ["attack_start", "impact"].
@export var event_types: PackedStringArray = PackedStringArray()

# critical / important / ambient. Only used to merge and degrade, never to reorder.
@export var priority: String = "important"

# Anchor names the cue reads, as {"source": "CastAnchor", "target": "HitAnchor"}.
# Must stay inside the D3 six-node contract.
@export var anchors: Dictionary = {}

@export var windup_ms: int = 0
@export var impact_ms: int = 0
@export var recovery_ms: int = 0

# Local camera treatment only. Never touches Engine.time_scale (checklist 0.3).
@export var camera_mode: String = "none"

@export var audio_cue: String = ""

# Optional scene. Empty means "reuse whatever the legacy adapter already draws",
# which is the D5 default: this stage adds scheduling and budget, not new art.
@export var vfx_scene: String = ""

@export var max_concurrent: int = 8

# Per-tier overrides, e.g. {"LOW": {"max_concurrent": 3, "camera_mode": "none"}}.
@export var quality_overrides: Dictionary = {}

# Profile id used when this one cannot run. Empty means "degrade in place".
@export var fallback_profile: String = ""


func total_ms() -> int:
	return maxi(0, windup_ms) + maxi(0, impact_ms) + maxi(0, recovery_ms)


func anchor_for(role: String) -> String:
	return str(anchors.get(role, ""))


# Returns this profile's fields with the tier overrides applied. Overrides may only
# make a cue cheaper; a profile can never buy itself more budget on a lower tier.
func resolved_for_tier(tier_name: String) -> Dictionary:
	var out := {
		"id": id,
		"priority": priority,
		"anchors": anchors.duplicate(true),
		"windup_ms": windup_ms,
		"impact_ms": impact_ms,
		"recovery_ms": recovery_ms,
		"camera_mode": camera_mode,
		"audio_cue": audio_cue,
		"vfx_scene": vfx_scene,
		"max_concurrent": max_concurrent,
	}
	var override_value = quality_overrides.get(tier_name, {})
	if typeof(override_value) != TYPE_DICTIONARY:
		return out
	var overrides: Dictionary = override_value
	for key_value in overrides.keys():
		var key := str(key_value)
		if not out.has(key):
			continue
		if key == "max_concurrent":
			out[key] = mini(int(out[key]), int(overrides[key_value]))
		else:
			out[key] = overrides[key_value]
	return out
