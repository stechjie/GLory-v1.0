class_name BattlePresentationSlice
extends RefCounted

# C4 vertical slice for D4.
#
# Exactly the unit ids listed here have their basic-attack presentation driven by
# BattlePresentationDirector cues. Every other unit keeps the legacy snapshot-diff
# path inside BattleVfx untouched.
#
# Both sides read this one list: LegacyBattleVfxAdapter uses it to decide whether
# to play a cue, and BattleVfx uses it to decide whether to skip its diff branch.
# Because there is a single source of truth, a unit can never be played twice nor
# dropped by both paths — which is the whole reason the migration has to be atomic
# per visual rather than "add events now, delete diff branches in D6".
#
# The routing rule is: the unit named by the event's source_uid decides. For
# attack_start / projectile_spawn / impact / hit_number that is the attacker; for
# death it is the unit that dies.
#
# D5 widens this list as profiles land; D6 deletes this file once coverage is
# complete and the legacy diff branches are removed for good.

const MIGRATED_UNIT_IDS := {
	"human_militia": true,
	"human_archer": true,
	"pve_sky_thunder_spirit": true,
}


# D5 widened the slice from the three C4 units to everything, which is the state
# D6 then makes permanent by deleting this file and the gated diff branches.
# Flip back to false to return to the C4 slice for a bisect.
const MIGRATE_ALL := true


static func is_migrated(unit_id: String) -> bool:
	if unit_id.is_empty():
		return false
	return MIGRATE_ALL or MIGRATED_UNIT_IDS.has(unit_id)


static func migrated_ids() -> Array:
	var out: Array = MIGRATED_UNIT_IDS.keys()
	out.sort()
	return out
