extends RefCounted

# Presentation-only policy. Lower rank is more audible; it never touches simulation/RNG.
const MAIN_UNITS := ["god_king","god_arbiter","god_guard","dark_dragon","dark_fear","dark_suc","dark_scythe","dark_doom","undead_mother","undead_bomb","undead_parasite","human_swordsman","human_death_servant","skypierce","Icey","lattern","merc_taurus_charge","merc_aquarius_time","merc_sagittarius_rain","merc_pisces_bubble"]
const SECONDARY_UNITS := ["god_archangel","god_angel","god_priestess","god_priest","dark_mage","dark_queen","undead_titan","human_mage","human_cleric","human_archer","human_king","hunter","drumer","dancer","merc_capricorn_steel","merc_cancer_shell","merc_virgo_heal","merc_gemini_assassin","merc_aries_blood","merc_libra_judge","merc_scorpio_death","merc_leo_sun"]
const DETAIL_UNITS := ["god_aurora","dark_imp","undead_small","undead_poison","undead_fly","undead_spike","human_militia","human_merchant","crimson","armbreaker"]

static func unit_weight(id: String) -> int:
 if id.begins_with("boss_") or id in MAIN_UNITS:return 0
 if id in SECONDARY_UNITS:return 1
 return 2

static func describe(cue: String, context: Dictionary) -> Dictionary:
 var kind := str(context.get("kind", "skill"))
 var id := str(context.get("unit_id", ""))
 var tier := 2
 var family := "skill"
 var interval := 400
 var gain := 0.0
 if cue in ["battle_victory","battle_defeat","boss_appear","final_round_pvp_intro"]:
  tier=0;family="transition";interval=400
 elif cue=="human_king_death" or kind=="critical" or cue.contains("apocalypse") or cue.contains("meteor_caster"):
  tier=1;family="critical";interval=350
 elif kind=="binding":
  tier=4;family="detail";interval=1000;gain=-5.0
 elif kind=="basic" or cue.begins_with("melee_"):
  tier=3;family="impact";interval=150
 elif kind=="flight" or cue.begins_with("proj_"):
  tier=4;family="flight";interval=300;gain=-5.0
 elif cue.contains("reward") or cue=="monster_kill_reward":
  tier=4;family="loot";interval=800;gain=-6.0
 elif cue.begins_with("death_") or kind=="death":
  tier=4;family="death";interval=500;gain=-4.0
 elif cue=="lane_clear_accent":
  tier=1;family="clear";interval=700
 elif cue.contains("formation_hit"):
  tier=2;family="formation";interval=450
 elif unit_weight(id)>0:
  tier=3 if unit_weight(id)==1 else 4
  interval=750 if unit_weight(id)==1 else 1000
  gain=-2.0 if unit_weight(id)==1 else -4.0
 var star := clampi(int(context.get("star", 1)),1,4)
 var weight := unit_weight(id)*2+(4-star)
 if bool(context.get("off_focus",false)):weight+=2;gain-=3.0
 return {"tier":tier,"family":family,"interval":interval,"gain":gain,"weight":weight}
