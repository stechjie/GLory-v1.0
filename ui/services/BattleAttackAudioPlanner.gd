extends RefCounted

# Read the entire recorded tick before choosing an attack sound. No RNG/state
# changes: random procs and piercing use their actual recorded result.
const SfxService := preload("res://ui/services/SfxService.gd")
const OFFENSIVE_PROCS := ["attack_interrupt", "curse_attack", "poison_attack", "defense_down_attack", "stacking_def_break", "current_hp_strike", "line_pierce", "team_random_stack", "balance_judge"]
var _counts: Dictionary = {}
var _previous_ready: Dictionary = {}

func prepare_tick(raw: Array, roster: Dictionary, frame: Array = []) -> Array:
	var events: Array = raw.duplicate()
	var attacks: Dictionary = {}
	var bow_casts: Dictionary = {}
	# Cooldown telemetry also records fully shielded Arrow Rain casts, which may
	# have no damage-number event. Reading it never modifies replay or fighters.
	for entry in frame:
		if not entry is Array or entry.size() <= 6:
			continue
		var uid := str(entry[0])
		var fighter: Dictionary = roster.get(uid, {})
		if str(fighter.get("def", {}).get("id", "")) != "merc_sagittarius_rain":
			continue
		var ready := float(entry[6])
		if ready > float(_previous_ready.get(uid, 0.0)) + 0.1:
			bow_casts[uid] = true
		_previous_ready[uid] = ready
	for index in events.size():
		if not events[index] is Dictionary:
			continue
		var event: Dictionary = events[index]
		var uid := str(event.get("source_uid", ""))
		if str(event.get("type", "")) != "attack_start":
			continue
		_counts[uid] = int(_counts.get(uid, 0)) + 1
		var fighter: Dictionary = roster.get(uid, {})
		var definition: Dictionary = fighter.get("def", {})
		var unit_id := str(definition.get("id", ""))
		var ranged := str(event.get("skill_id", "")) == "basic_ranged"
		attacks[uid] = {"cue": SfxService.basic_attack_cue_for(unit_id, ranged), "skill": false,
			"ranged": ranged, "unit_id": unit_id, "count": int(_counts[uid]),
			"target_uid": str(event.get("target_uid", "")), "cast_replacement": false, "reactions": []}
	# Defensive procs belong to the incoming impact, never to the defender's
	# unrelated outgoing attack. Preserve them as separate, correctly owned sounds.
	for index in events.size():
		if not events[index] is Dictionary:
			continue
		var event: Dictionary = events[index]
		var sid := str(event.get("skill_id", ""))
		if not sid in ["block_guard", "poison_reflect_armor_stack"] or not str(event.get("type", "")) in ["unit_skill_proc", "sfx_proc"]:
			continue
		var defender := str(event.get("source_uid", ""))
		var attacker := str(event.get("target_uid", ""))
		if not attacks.has(attacker) or int(roster.get(defender, {}).get("star", 1)) != 4:
			continue
		attacks[attacker].reactions.append({"cue": SfxService.proc_skill_cue_for(sid), "source_uid": defender, "target_uid": attacker})
		events[index] = event.duplicate()
		events[index]["_attack_audio_managed"] = true
	# First match actual offensive procs. Defender block/reflection do not replace
	# the defender's unrelated outgoing attack.
	for index in events.size():
		if not events[index] is Dictionary:
			continue
		var event: Dictionary = events[index]
		var uid := str(event.get("source_uid", ""))
		if not attacks.has(uid):
			continue
		var sid := str(event.get("skill_id", ""))
		var kind := str(event.get("type", ""))
		var fighter: Dictionary = roster.get(uid, {})
		var cue := SfxService.merc_proc_cue_for(sid)
		if cue.is_empty() and int(fighter.get("star", 1)) == 4:
			cue = SfxService.proc_skill_cue_for(sid)
		var confirmed := kind in ["unit_skill_proc", "sfx_proc"] or kind == "hit_number" and sid == "current_hp_strike" and str(event.get("kind", "dmg")) == "dmg" or kind == "impact" and sid == "line_pierce"
		if not sid in OFFENSIVE_PROCS or cue.is_empty() or not confirmed:
			continue
		var plan: Dictionary = attacks[uid]
		plan.cue = cue
		plan.skill = true
		events[index] = event.duplicate()
		events[index]["_attack_audio_managed"] = true
	for uid: String in attacks:
		var plan: Dictionary = attacks[uid]
		var fighter: Dictionary = roster.get(uid, {})
		var definition: Dictionary = fighter.get("def", {})
		var sid := str(definition.get("skill_id", ""))
		var count := int(plan.count)
		var every := maxi(1, int(definition.get("every", 4 if sid == "every_fourth_combo" else 5)))
		var triggered := sid in ["true_damage_attack", "same_target_damage_stack"] or sid in ["every_fourth_combo", "every_fifth_group_heal"] and count % every == 0
		# The combo cannot follow a killing primary hit (same condition as simulator).
		if sid == "every_fourth_combo":
			for event: Dictionary in raw:
				if str(event.get("source_uid", "")) == uid and str(event.get("skill_id", "")) in ["basic_melee", "basic_ranged"] and str(event.get("type", "")) == "hit_number" and bool(event.get("is_lethal", false)):
					triggered = false
		if triggered and int(fighter.get("star", 1)) == 4:
			var cue := SfxService.attack_skill_cue_for(str(plan.unit_id))
			if not cue.is_empty():
				plan.cue = cue
				plan.skill = true
		# Ranged skill attacks suppress the ordinary flight sound entirely.
		plan.stage = "impact" if bool(plan.skill) or not bool(plan.ranged) else "projectile_spawn"
		# Arrow Rain is an independent cast whose existing sound is a drawn bow.
		# A basic shot sharing that cast must not add a second flight sound.
		if str(plan.unit_id) == "merc_sagittarius_rain":
			if bow_casts.has(uid):
				plan.cue = ""
				plan.cast_replacement = true
			for event: Dictionary in raw:
				if str(event.get("source_uid", "")) == uid and str(event.get("skill_id", "")) == "arrow_rain" and str(event.get("type", "")) in ["hit_number", "skill_cast", "skill_shake"]:
					plan.cue = ""
					plan.cast_replacement = true
		# The approved archer skill asset is a drawn bow, not an impact.
		if bool(plan.skill) and str(plan.unit_id) == "human_archer":
			plan.stage = "attack_start"
		plan.high_value = false
		for event: Dictionary in raw:
			if str(event.get("source_uid", "")) == uid and str(event.get("skill_id", "")) in ["basic_melee", "basic_ranged"]:
				if bool(event.get("is_crit", false)) or bool(event.get("is_lethal", false)):
					plan.high_value = true
		for index in events.size():
			if not events[index] is Dictionary:
				continue
			var event: Dictionary = events[index]
			if str(event.get("source_uid", "")) != uid or not str(event.get("type", "")) in ["attack_start", "projectile_spawn", "impact"] or not str(event.get("skill_id", "")) in ["basic_melee", "basic_ranged"]:
				continue
			events[index] = event.duplicate()
			events[index]["_attack_audio"] = plan.duplicate(true)
	return events
