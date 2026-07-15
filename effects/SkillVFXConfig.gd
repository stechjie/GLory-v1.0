extends RefCounted
class_name SkillVFXConfig

# 返回 Array[Dictionary]，每项: {path, offset, delay, scale, duration}
static func get_textures(unit_id: String) -> Array[Dictionary]:
	var b := "res://assets/vfx/skills/"
	match unit_id:
		# ── 神族 ──────────────────────────────────────────
		"god_priest":
			return _tex(b + "god_priest/", [
				"god_priest_holy_ring.png",
				"god_priest_soft_spark.png",
			], 0.65)
		"god_priestess":
			return _tex(b + "god_priestess/", [
				"god_priestess_decree.png",
				"god_priestess_decree_mark.png",
			], 0.65)
		"god_guard":
			return _tex(b + "god_guard/", [
				"god_guard_crystal_panel.png",
				"god_guard_taunt_rune.png",
			], 0.55)
		"god_aurora":
			return _tex(b + "god_aurora/", [
				"god_aurora_arrow_trail.png",
				"god_aurora_true_hit.png",
			], 0.40)
		"god_angel":
			return _tex(b + "god_angel/", [
				"god_angel_immunity_feathers.png",
				"god_angel_shelter_wing.png",
			], 0.65)
		"god_arbiter":
			return _tex(b + "god_arbiter/", [
				"god_arbiter_verdict_slash.png",
				"god_arbiter_armor_plate.png",
			], 0.42)
		"god_archangel":
			return _tex(b + "god_archangel/", [
				"god_archangel_covenant_sigla.png",
				"god_archangel_mercy_ribbon.png",
			], 0.70)
		"god_king":
			return _tex(b + "god_king/", [
				"god_king_judgement_line.png",
				"god_king_royal_impact.png",
			], 0.50)
		# ── 暗族 ──────────────────────────────────────────
		"dark_imp":
			return _tex(b + "dark_imp/", [
				"motong_curse_crack_ring.png",
				"motong_curse_mark.png",
			], 0.45)
		"dark_mage":
			return _tex(b + "dark_mage/", [
				"dark_mage_magic_bolt.png",
				"dark_mage_silence_mark.png",
			], 0.42)
		"dark_fear":
			return _tex(b + "dark_fear/", [
				"dark_fear_ghost_face.png",
				"dark_fear_backstep_arrow.png",
			], 0.50)
		"dark_queen":
			return _tex(b + "dark_queen/", [
				"dark_queen_pain_heart_spike.png",
				"dark_queen_stun_stars.png",
			], 0.45)
		"dark_scythe":
			return _tex(b + "dark_scythe/", [
				"dark_scythe_crescent_slash.png",
				"dark_scythe_shadow_blink.png",
			], 0.38)
		# ── 亡灵 ──────────────────────────────────────────
		"undead_poison":
			return _tex(b + "undead_poison/", [
				"undead_poison_miasma_cone.png",
				"undead_poison_spore_orb.png",
				"undead_poison_puddle.png",
			], 0.55)
		"undead_parasite":
			return _tex(b + "undead_parasite/", [
				"undead_parasite_cute_pod.png",
				"undead_parasite_cute_thread.png",
				"undead_parasite_cute_mark.png",
			], 0.50)
		"undead_spike":
			return _tex(b + "undead_spike/", [
				"undead_spike_bone_dart.png",
				"undead_spike_armor_break.png",
				"undead_spike_stack_pin.png",
			], 0.42)
		"undead_fly":
			return _tex(b + "undead_fly/", [
				"undead_fly_poison_feather.png",
				"undead_fly_evasion_spark.png",
				"undead_fly_dodge_afterimage.png",
			], 0.45)
		"undead_bomb":
			return _tex(b + "undead_bomb/", [
				"undead_bomb_core_pop.png",
				"undead_bomb_poison_ring.png",
				"undead_bomb_soul_fragment.png",
			], 0.48)
		"undead_titan":
			return _tex(b + "undead_titan/", [
				"undead_titan_reflect_spike.png",
				"undead_titan_armor_plate.png",
				"undead_titan_stack_badge.png",
			], 0.50)
		"undead_mother":
			return _tex(b + "undead_mother/", [
				"undead_mother_dark_orb.png",
				"undead_mother_dark_book.png",
				"undead_mother_death_mark.png",
			], 0.60)
		# ── 人族 ──────────────────────────────────────────
		"human_militia":
			return _tex(b + "human_militia/", [
				"human_militia_shield_bash.png",
				"human_militia_impact_ring.png",
				"human_militia_charge_dust_start.png",
			], 0.40)
		"human_merchant":
			return _tex(b + "human_merchant/", [
				"human_merchant_contract_slip.png",
				"human_merchant_coin_spark.png",
				"human_merchant_coin_trail.png",
			], 0.55)
		"human_archer":
			return _tex(b + "human_archer/", [
				"human_archer_arrow_trail.png",
				"human_archer_charge_wind.png",
				"human_archer_pierce_flash.png",
				"human_archer_star_crack.png",
				"human_archer_leaf_spark.png",
			], 0.40)
		"human_swordsman":
			return _tex(b + "human_swordsman/", [
				"human_swordsman_slash_a.png",
				"human_swordsman_slash_b.png",
				"human_swordsman_arc_180.png",
				"human_swordsman_blade_charge.png",
				"human_swordsman_stun_ring.png",
			], 0.42)
		"human_mage":
			return _tex(b + "human_mage/", [
				"human_mage_element_orb.png",
				"human_mage_element_burst.png",
				"human_mage_element_trail.png",
				"human_mage_element_residue.png",
			], 0.50)
		"human_cleric":
			return _tex(b + "human_cleric/", [
				"human_cleric_life_mark.png",
				"human_cleric_heal_ribbon.png",
				"human_cleric_prayer_wisp.png",
				"cleric_final_contact.png",
			], 0.60)
		"human_death_servant":
			return _tex(b + "human_death_servant/", [
				"human_death_servant_guard_sigils.png",
				"human_death_servant_blood_chain.png",
				"human_death_servant_oath_crack.png",
				"human_death_servant_sacrifice_burst.png",
			], 0.55)
		"human_king":
			return _tex(b + "human_king/", [
				"human_king_heaven_sword.png",
				"human_king_light_column.png",
				"human_king_royal_impact.png",
				"king_final_contact.png",
			], 0.55)
	return []

static func _tex(folder: String, names: Array, dur: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var delay := 0.0
	for name in names:
		var role := _role_for_name(name)
		var cfg := {
			"path":     folder + name,
			"role":     role,
			"offset":   _offset_for_name(name, role),
			"delay":    delay,
			"scale":    _scale_for_name(name, role),
			"duration": _duration_for_name(name, role, dur),
			"alpha":    _alpha_for_role(role),
			"glow":     true,
			"particles": _particles_for_name(name, role),
			"spin":     _spin_for_name(name, role),
			"flatten":  role == "foot",
			"drift":    _drift_for_name(name, role),
		}
		result.append(cfg)
		delay += 0.07
	return result

static func _role_for_name(name: String) -> String:
	var n := name.to_lower()
	if n.contains("trail") or n.contains("bolt") or n.contains("dart") or n.contains("feather") or n.contains("heart_spike") or n.contains("ribbon") or n.contains("thread") or n.contains("line"):
		return "projectile"
	if n.contains("life_mark") or n.contains("residue") or n.contains("puddle") or n.contains("ring") or n.contains("rift") or n.contains("crack"):
		return "foot"
	if n.contains("mark") or n.contains("stars") or n.contains("armor_break") or n.contains("armor_plate") or n.contains("stack") or n.contains("badge") or n.contains("pin") or n.contains("sigla") or n.contains("book"):
		return "head"
	if n.contains("dark_orb") or n.contains("spore_orb") or n.contains("hit") or n.contains("burst") or n.contains("impact") or n.contains("flash") or n.contains("spark") or n.contains("slash") or n.contains("sword") or n.contains("column") or n.contains("flame") or n.contains("pop"):
		return "hit"
	return "cast"

static func _scale_for_name(name: String, role: String) -> float:
	var n := name.to_lower()
	if n == "undead_spike_bone_dart.png":
		return 0.14
	if n.begins_with("undead_spike_"):
		return 0.24
	if n.contains("sword") or n.contains("column"):
		return 0.62
	if role == "projectile":
		return 0.42
	if role == "foot":
		return 0.62
	if role == "head":
		return 0.42
	if role == "hit":
		return 0.54
	return 0.50

static func _duration_for_name(name: String, role: String, fallback: float) -> float:
	var n := name.to_lower()
	if n.contains("residue"):
		return 2.5
	if n.contains("curse"):
		return 4.0
	if n.contains("silence"):
		return 1.2
	if n.contains("stun") or n.contains("stars"):
		return 1.0
	if n.contains("ghost_face") or n.contains("backstep"):
		return 1.5
	if n.contains("stack") or n.contains("pin") or n.contains("badge"):
		return 5.0
	if role == "foot":
		return maxf(fallback, 1.2)
	if role == "head":
		return maxf(fallback, 0.9)
	return fallback

static func _alpha_for_role(role: String) -> float:
	if role == "foot":
		return 0.82
	if role == "projectile":
		return 0.95
	return 1.0

static func _particles_for_name(name: String, role: String) -> int:
	var n := name.to_lower()
	if role == "projectile":
		return 0
	if n.contains("spark") or n.contains("fragment") or n.contains("spore") or n.contains("burst") or n.contains("impact") or n.contains("hit") or n.contains("pop"):
		return 8
	if role == "hit":
		return 5
	if role == "head":
		return 3
	return 0

static func _spin_for_name(name: String, role: String) -> float:
	var n := name.to_lower()
	if n.contains("stars") or n.contains("ring") or n.contains("sigla") or n.contains("book"):
		return 0.35
	if role == "hit":
		return 0.08
	return 0.0

static func _offset_for_name(name: String, role: String) -> Vector2:
	var n := name.to_lower()
	if n.contains("sword"):
		return Vector2(0.0, -56.0)
	if n.contains("column"):
		return Vector2(0.0, -24.0)
	if role == "foot":
		return Vector2(0.0, 8.0)
	return Vector2.ZERO

static func _drift_for_name(name: String, role: String) -> Vector2:
	var n := name.to_lower()
	if n.contains("sword"):
		return Vector2(0.0, 48.0)
	if n.contains("column"):
		return Vector2(0.0, -8.0)
	if role == "head":
		return Vector2(0.0, -10.0)
	if role == "hit":
		return Vector2(0.0, -4.0)
	return Vector2.ZERO
