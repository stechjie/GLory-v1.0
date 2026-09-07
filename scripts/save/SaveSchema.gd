class_name SaveSchema
extends RefCounted

# Version history:
#   1 - original run save; account profile had no version field at all
#   2 - profile gains codex_seen; pet_duck renamed to pet_rabbit
#   3 - profile gains the persistent BoardReadabilityLayer visibility setting
#   4 - profile gains persisted locale and an explicit onboarding lifecycle
const VERSION := 2

# Account-level profile (user://profile.json) is versioned separately from the run
# save: it survives across runs and is the only place collection progress lives.
const PROFILE_VERSION := 4

# Pets renamed after the art came in. Old profiles still hold the old id, so it is
# rewritten on load rather than orphaning a pet the player already owns.
const PET_ID_RENAMES := {
	"pet_duck": "pet_rabbit",
}

# Applies every migration needed to bring a profile payload up to PROFILE_VERSION.
# Safe to call on an already-current payload.
static func migrate_profile(payload: Dictionary) -> Dictionary:
	var out := payload.duplicate(true)
	var from := int(out.get("version", 1))
	if from >= PROFILE_VERSION:
		out["version"] = PROFILE_VERSION
		return out

	if from < 2:
		out["owned_pets"] = _rename_ids(out.get("owned_pets", []))
		out["active_pet"] = _rename_id(str(out.get("active_pet", "")))
		if not out.has("codex_seen"):
			out["codex_seen"] = []
	if from < 3 and not out.has("board_readability_enabled"):
		out["board_readability_enabled"] = true
	if from < 4:
		# Never guess that an old account completed onboarding from gold, pets or run
		# state. Those are not proof. Legacy accounts keep the old behaviour (show
		# language, then resume/start tutorial) once, and become explicit thereafter.
		if not out.has("locale"):
			out["locale"] = "zh"
		if not out.has("language_selected"):
			out["language_selected"] = false
		if not out.has("onboarding_version"):
			out["onboarding_version"] = 1
		if not out.has("onboarding_status"):
			out["onboarding_status"] = "legacy_unknown"

	out["version"] = PROFILE_VERSION
	return out

static func _rename_id(id: String) -> String:
	return str(PET_ID_RENAMES.get(id, id))

static func _rename_ids(ids: Array) -> Array:
	var out: Array = []
	for raw in ids:
		var id := _rename_id(str(raw))
		if not id.is_empty() and not out.has(id):
			out.append(id)
	return out
