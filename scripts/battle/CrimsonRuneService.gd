class_name CrimsonRuneService
extends RefCounted

# A rune belongs to one fighter and lasts for the current battle. The action
# sequence prevents a self buff plus its Crimson 4 Resonance from counting twice.
const MAX_STACKS := 9

static func begin_action(fighter: Dictionary, state: Dictionary) -> void:
	if str(fighter.get("def", {}).get("race", "")) != "crimson":
		return
	var action := int(state.get("crimson_rune_action_seq", 0)) + 1
	state.crimson_rune_action_seq = action
	fighter.crimson_rune_action = action


static func end_action(fighter: Dictionary) -> void:
	fighter.erase("crimson_rune_action")


static func note_self_effect(fighter: Dictionary, state: Dictionary) -> bool:
	if not bool(fighter.get("alive", false)) or str(fighter.get("def", {}).get("race", "")) != "crimson":
		return false
	var syn: Dictionary = fighter.get("owner_syn", state.get("player_syn", {}) if str(fighter.get("team", "")) == "player" else state.get("enemy_syn", {}))
	if not bool(syn.get("crimson_rune", false)):
		return false
	var action := int(fighter.get("crimson_rune_action", 0))
	if action > 0 and int(fighter.get("crimson_rune_last_award_action", -1)) == action:
		return false
	var stacks := stack_count(fighter)
	if stacks >= MAX_STACKS:
		return false
	fighter.crimson_rune_stacks = stacks + 1
	if action > 0:
		fighter.crimson_rune_last_award_action = action
	return true


static func stack_count(fighter: Dictionary) -> int:
	return clampi(int(fighter.get("crimson_rune_stacks", 0)), 0, MAX_STACKS)


static func crit_bonus(fighter: Dictionary) -> float:
	return 0.30 if stack_count(fighter) >= 3 else 0.0


static func attack_speed_multiplier(fighter: Dictionary) -> float:
	return 1.60 if stack_count(fighter) >= 6 else 1.0


static func crit_damage_bonus(fighter: Dictionary) -> float:
	return 0.90 if stack_count(fighter) >= 9 else 0.0
