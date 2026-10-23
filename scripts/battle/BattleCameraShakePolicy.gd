extends RefCounted
## Presentation-only rule: successful skill damage from a Boss, or from the
## viewer's own four-star unique unit. Future skills use the same rule.
var _seen: Dictionary = {}

func reset() -> void:
	_seen.clear()

static func is_candidate(event: Dictionary) -> bool:
	var kind := str(event.get("type", ""))
	if kind == "sfx_proc":
		return str(event.get("skill_id", "")) == "blood_rage"
	if int(event.get("amount", 0)) <= 0:
		return false
	return kind == "skill_damage" or (kind == "hit_number"
		and str(event.get("kind", "dmg")) == "dmg" and bool(event.get("skill", false))
		and not bool(event.get("treasure", false)))

func accepts(event: Dictionary, source: Dictionary, local_owned: bool) -> bool:
	if not is_candidate(event):
		return false
	var definition: Dictionary = source.get("def", {})
	var boss := bool(definition.get("is_boss", false))
	var skill := str(event.get("skill_id", ""))
	var rage := str(event.get("type", "")) == "sfx_proc" and boss
	if not rage:
		if skill != str(definition.get("skill_id", "")):
			return false
		if str(event.get("type", "")) == "sfx_proc":
			return false
		if not boss and not (local_owned and int(source.get("star", 1)) == 4
			and bool(definition.get("unique_on_board", false))):
			return false
	var group := "rage" if rage else str(event.get("shake_group", str(event.get("time", 0.0))))
	var key := "%s|%s|%s" % [str(event.get("source_uid", "")), skill, group]
	if _seen.has(key):
		return false
	_seen[key] = true
	return true
