class_name FormationAllyService
extends RefCounted

static func ally_id_for_hp(hp: int) -> String:
	if hp <= 10: return "ally_flame_claw"
	if hp <= 20: return "ally_soul_chain"
	if hp <= 30: return "ally_abyss_beast"
	if hp <= 40: return "ally_hell_inferno"
	return "ally_eternal_night"
