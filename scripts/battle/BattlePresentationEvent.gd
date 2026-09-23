class_name BattlePresentationEvent
extends RefCounted

# Pure-data contract shared by replay production and the future presentation
# director. This file must never load VFX resources, access the scene tree, or
# consume RngService. Presentation randomness is derived from event_key only.

const SCHEMA_VERSION := 1

const VISIBILITY_CRITICAL := "critical"
const VISIBILITY_IMPORTANT := "important"
const VISIBILITY_AMBIENT := "ambient"

const KNOWN_TYPES := {
	"attack_start": true,
	"projectile_spawn": true,
	"impact": true,
	"hit_number": true,
	"heal": true,
	"shield": true,
	"death": true,
	"skill_cast": true,
	"unit_skill_proc": true,
	"skill_shake": true,
	"mother_execute": true,
	"buff_apply": true,
	"summon": true,
	# 9.22：**只出声**的技能触发事件（四星刺灵/毒灵/飞灵/巨甲灵/魔童 + 佣兵审判剑士）。
	# 与 `unit_skill_proc` 分开是因为那一条还带着程序化特效的语义
	# （BattleVfx 会在派发完音效后调 `_play_unit_procedural`），而这几个 skill_id
	# 本来没有演出 —— 复用会把「加音效」做成「加特效」。
	#
	# 必须登记在这张表里：未登记的 type 会被 `_warn_unknown_type_once` 记一笔，
	# 而 `validate()` 会报 `unknown_type:`。这些事件**每只棋子的每次普攻**都会产生，
	# 不登记就是每局几十条 warning + 校验错误。
	"sfx_proc": true,
}

const CORE_FIELD_ORDER := [
	"schema_version",
	"event_key",
	"battle_id",
	"tick",
	"ordinal",
	"type",
	"source_uid",
	"target_uids",
	"skill_id",
	"amount",
	"is_crit",
	"is_lethal",
	"presentation_seed",
	"visibility_priority",
	"timing_hint",
]

static var _warned_unknown_types: Dictionary = {}


static func normalize(raw_event: Dictionary, battle_id: String, tick: int, ordinal: int) -> Dictionary:
	var event_type := str(raw_event.get("type", "")).strip_edges()
	var stable_battle_id := battle_id.strip_edges()
	if stable_battle_id.is_empty():
		stable_battle_id = "missing_battle"
	var event_key := "%s:%d:%d" % [stable_battle_id, tick, ordinal]
	var source_uid := str(raw_event.get("source_uid", raw_event.get("uid", "")))
	var target_uids := _target_uids(raw_event)
	var skill_id := _skill_id(raw_event, event_type)
	var is_crit := bool(raw_event.get("is_crit", raw_event.get("crit", false)))
	var is_lethal := bool(raw_event.get("is_lethal", false))

	if not is_known_type(event_type):
		_warn_unknown_type_once(event_type)

	# Insert core fields in one fixed order. Legacy/producer-specific fields are
	# appended alphabetically afterwards so existing BattleVfx readers keep working
	# while hashes remain stable across repeated captures.
	var normalized: Dictionary = {}
	normalized["schema_version"] = SCHEMA_VERSION
	normalized["event_key"] = event_key
	normalized["battle_id"] = stable_battle_id
	normalized["tick"] = tick
	normalized["ordinal"] = ordinal
	normalized["type"] = event_type
	normalized["source_uid"] = source_uid
	normalized["target_uids"] = target_uids
	normalized["skill_id"] = skill_id
	normalized["amount"] = int(raw_event.get("amount", 0))
	normalized["is_crit"] = is_crit
	normalized["is_lethal"] = is_lethal
	normalized["presentation_seed"] = _presentation_seed(event_key)
	normalized["visibility_priority"] = str(raw_event.get(
		"visibility_priority", _default_visibility(event_type, is_crit, is_lethal, raw_event)))
	normalized["timing_hint"] = _timing_hint(raw_event.get("timing_hint", {}))

	var extra_keys: Array = raw_event.keys()
	extra_keys.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
	for key_value in extra_keys:
		var key := str(key_value)
		if normalized.has(key):
			continue
		normalized[key] = _copy_value(raw_event[key_value])
	return normalized


static func validate(event: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if int(event.get("schema_version", 0)) != SCHEMA_VERSION:
		errors.append("schema_version")
	if str(event.get("battle_id", "")).is_empty():
		errors.append("battle_id")
	if int(event.get("tick", -1)) < 0:
		errors.append("tick")
	if int(event.get("ordinal", -1)) < 0:
		errors.append("ordinal")
	var event_type := str(event.get("type", ""))
	if not is_known_type(event_type):
		errors.append("unknown_type:%s" % event_type)
	if str(event.get("source_uid", "")).is_empty():
		errors.append("source_uid")
	if not (event.get("target_uids", []) is Array):
		errors.append("target_uids")
	if not _valid_priority(str(event.get("visibility_priority", ""))):
		errors.append("visibility_priority")
	if not _valid_timing_hint(event.get("timing_hint", {})):
		errors.append("timing_hint")
	var expected_key := "%s:%d:%d" % [
		str(event.get("battle_id", "")), int(event.get("tick", -1)), int(event.get("ordinal", -1))]
	if str(event.get("event_key", "")) != expected_key:
		errors.append("event_key")
	if int(event.get("presentation_seed", -1)) != _presentation_seed(expected_key):
		errors.append("presentation_seed")
	return errors


static func is_known_type(event_type: String) -> bool:
	return KNOWN_TYPES.has(event_type)


static func core_field_order() -> Array:
	return CORE_FIELD_ORDER.duplicate()


static func unknown_warning_count() -> int:
	return _warned_unknown_types.size()


static func clear_unknown_warning_cache() -> void:
	_warned_unknown_types.clear()


static func _target_uids(raw_event: Dictionary) -> Array:
	var out: Array = []
	var raw_targets: Variant = raw_event.get("target_uids", [])
	if raw_targets is Array:
		for uid_value in raw_targets:
			var uid := str(uid_value)
			if not uid.is_empty() and not out.has(uid):
				out.append(uid)
	var legacy_target := str(raw_event.get("target_uid", ""))
	if not legacy_target.is_empty() and not out.has(legacy_target):
		out.append(legacy_target)
	return out


static func _skill_id(raw_event: Dictionary, event_type: String) -> String:
	var explicit := str(raw_event.get("skill_id", ""))
	if not explicit.is_empty():
		return explicit
	if event_type == "hit_number":
		if str(raw_event.get("kind", "")) == "heal":
			return "heal"
		if bool(raw_event.get("skill", false)):
			return "unknown_skill"
		return "basic_melee"
	if event_type == "mother_execute":
		return "mother_execute"
	return event_type


static func _default_visibility(event_type: String, is_crit: bool, is_lethal: bool, raw_event: Dictionary) -> String:
	if event_type == "mother_execute" or event_type == "death" or is_lethal:
		return VISIBILITY_CRITICAL
	# Checklist section 3: the basic-attack chain is important, and a crit impact is
	# critical. Added in D5 — D4 introduced these types while this function still
	# had no rule for them, so they fell through to ambient and were wrongly
	# exposed to ambient merging and to being dropped during DRAINING.
	if event_type == "impact":
		return VISIBILITY_CRITICAL if is_crit else VISIBILITY_IMPORTANT
	if event_type == "attack_start" or event_type == "projectile_spawn":
		return VISIBILITY_IMPORTANT
	if event_type == "skill_shake" or event_type == "unit_skill_proc" or event_type == "skill_cast":
		return VISIBILITY_IMPORTANT
	# 9.22：`sfx_proc` 与 `unit_skill_proc` 同级。它本身只驱动音效，但归到 ambient
	# 会被 DRAINING 阶段的合并/丢弃规则吃掉 —— 那是给「不重要的画面」准备的通道，
	# 不该拿它决定「这一声技能音还响不响」。
	if event_type == "sfx_proc":
		return VISIBILITY_IMPORTANT
	if event_type == "heal" or event_type == "shield" or str(raw_event.get("kind", "")) == "heal" or is_crit:
		return VISIBILITY_IMPORTANT
	return VISIBILITY_AMBIENT


static func _timing_hint(raw_hint: Variant) -> Dictionary:
	var hint: Dictionary = raw_hint if raw_hint is Dictionary else {}
	return {
		"windup_ms": maxi(0, int(hint.get("windup_ms", 0))),
		"impact_ms": maxi(0, int(hint.get("impact_ms", 0))),
		"recovery_ms": maxi(0, int(hint.get("recovery_ms", 0))),
	}


static func _valid_timing_hint(value: Variant) -> bool:
	if not (value is Dictionary):
		return false
	var hint: Dictionary = value
	for key in ["windup_ms", "impact_ms", "recovery_ms"]:
		if not hint.has(key) or int(hint.get(key, -1)) < 0:
			return false
	return true


static func _valid_priority(value: String) -> bool:
	return value == VISIBILITY_CRITICAL or value == VISIBILITY_IMPORTANT or value == VISIBILITY_AMBIENT


static func _presentation_seed(event_key: String) -> int:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(event_key.to_utf8_buffer())
	var digest := context.finish()
	if digest.size() < 4:
		return 1
	var seed := (int(digest[0]) << 24) | (int(digest[1]) << 16) | (int(digest[2]) << 8) | int(digest[3])
	return seed & 0x7fffffff


static func _warn_unknown_type_once(event_type: String) -> void:
	var label := event_type if not event_type.is_empty() else "<empty>"
	if _warned_unknown_types.has(label):
		return
	_warned_unknown_types[label] = true
	push_warning("BattlePresentationEvent: unknown event type '%s'; preserved for replay but Director must drop it safely." % label)


static func _copy_value(value: Variant) -> Variant:
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	if value is Array:
		return (value as Array).duplicate(true)
	return value
