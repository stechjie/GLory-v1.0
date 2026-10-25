extends RefCounted

# User-approved 2026-10-25 review. Variants rotate without consuming combat RNG.
const VARIANTS := {
  "proj_thorn": ["res://assets/audio/sfx/approved_20261025/lance_A.wav", "res://assets/audio/sfx/approved_20261025/lance_B.wav", "res://assets/audio/sfx/approved_20261025/lance_C.wav"],
  "melee_metal": [
    "res://assets/audio/sfx/approved_20261025/metal_A.wav",
    "res://assets/audio/sfx/approved_20261025/metal_B.wav",
    "res://assets/audio/sfx/approved_20261025/metal_C.wav"
  ],
  "melee_heavy": [
    "res://assets/audio/sfx/approved_20261025/metal_heavy_A.wav",
    "res://assets/audio/sfx/approved_20261025/metal_heavy_B.wav",
    "res://assets/audio/sfx/approved_20261025/metal_heavy_C.wav"
  ],
  "melee_unarmed": [
    "res://assets/audio/sfx/approved_20261025/punch_A.wav",
    "res://assets/audio/sfx/approved_20261025/punch_B.wav",
    "res://assets/audio/sfx/approved_20261025/punch_C.wav"
  ],
  "melee_claw": [
    "res://assets/audio/sfx/approved_20261025/claw_A.wav",
    "res://assets/audio/sfx/approved_20261025/claw_B.wav",
    "res://assets/audio/sfx/approved_20261025/claw_C.wav"
  ],
  "melee_claw_heavy": [
    "res://assets/audio/sfx/approved_20261025/claw_heavy_A.wav",
    "res://assets/audio/sfx/approved_20261025/claw_heavy_B.wav",
    "res://assets/audio/sfx/approved_20261025/claw_heavy_C.wav"
  ],
  "melee_nonmetal": [
    "res://assets/audio/sfx/approved_20261025/wood_A.wav",
    "res://assets/audio/sfx/approved_20261025/wood_B.wav",
    "res://assets/audio/sfx/approved_20261025/wood_C.wav"
  ],
  "melee_shell": [
    "res://assets/audio/sfx/approved_20261025/shell_A.wav",
    "res://assets/audio/sfx/approved_20261025/shell_B.wav",
    "res://assets/audio/sfx/approved_20261025/shell_C.wav"
  ],
  "melee_spirit": [
    "res://assets/audio/sfx/approved_20261025/spirit_A.wav",
    "res://assets/audio/sfx/approved_20261025/spirit_B.wav",
    "res://assets/audio/sfx/approved_20261025/spirit_C.wav"
  ],
  "proj_arrow": [
    "res://assets/audio/sfx/approved_20261025/arrow_A.wav",
    "res://assets/audio/sfx/approved_20261025/arrow_B.wav",
    "res://assets/audio/sfx/approved_20261025/arrow_C.wav"
  ],
  "proj_javelin": [
    "res://assets/audio/sfx/approved_20261025/javelin_A.wav",
    "res://assets/audio/sfx/approved_20261025/javelin_B.wav",
    "res://assets/audio/sfx/approved_20261025/javelin_C.wav"
  ],
  "proj_bone": [
    "res://assets/audio/sfx/approved_20261025/needle_A.wav",
    "res://assets/audio/sfx/approved_20261025/needle_B.wav",
    "res://assets/audio/sfx/approved_20261025/needle_C.wav"
  ],
  "proj_orb": [
    "res://assets/audio/sfx/approved_20261025/orb_A.wav",
    "res://assets/audio/sfx/approved_20261025/orb_B.wav",
    "res://assets/audio/sfx/approved_20261025/orb_C.wav"
  ],
  "proj_dark_orb": [
    "res://assets/audio/sfx/approved_20261025/orb_dark_A.wav",
    "res://assets/audio/sfx/approved_20261025/orb_dark_B.wav",
    "res://assets/audio/sfx/approved_20261025/orb_dark_C.wav"
  ],
  "proj_holy": [
    "res://assets/audio/sfx/approved_20261025/orb_holy_A.wav",
    "res://assets/audio/sfx/approved_20261025/orb_holy_B.wav",
    "res://assets/audio/sfx/approved_20261025/orb_holy_C.wav"
  ],
  "proj_light_lance": [
    "res://assets/audio/sfx/approved_20261025/lance_A.wav",
    "res://assets/audio/sfx/approved_20261025/lance_B.wav",
    "res://assets/audio/sfx/approved_20261025/lance_C.wav"
  ],
  "proj_wing": [
    "res://assets/audio/sfx/approved_20261025/feather_A.wav",
    "res://assets/audio/sfx/approved_20261025/feather_B.wav",
    "res://assets/audio/sfx/approved_20261025/feather_C.wav"
  ],
  "proj_disc": [
    "res://assets/audio/sfx/approved_20261025/petal_A.wav",
    "res://assets/audio/sfx/approved_20261025/petal_B.wav",
    "res://assets/audio/sfx/approved_20261025/petal_C.wav"
  ],
  "proj_frost": [
    "res://assets/audio/sfx/approved_20261025/frost_A.wav",
    "res://assets/audio/sfx/approved_20261025/frost_B.wav",
    "res://assets/audio/sfx/approved_20261025/frost_C.wav"
  ],
  "proj_ember": [
    "res://assets/audio/sfx/approved_20261025/ember_A.wav",
    "res://assets/audio/sfx/approved_20261025/ember_B.wav",
    "res://assets/audio/sfx/approved_20261025/ember_C.wav"
  ],
  "proj_thunder": [
    "res://assets/audio/sfx/approved_20261025/thunder_A.wav",
    "res://assets/audio/sfx/approved_20261025/thunder_B.wav",
    "res://assets/audio/sfx/approved_20261025/thunder_C.wav"
  ],
  "proj_divine_blade": [
    "res://assets/audio/sfx/approved_20261025/divine_A.wav",
    "res://assets/audio/sfx/approved_20261025/divine_B.wav",
    "res://assets/audio/sfx/approved_20261025/divine_C.wav"
  ],
  "star4_dancer_skill": [
    "res://assets/audio/sfx/approved_20261025/dancer_skill_A.wav",
    "res://assets/audio/sfx/approved_20261025/dancer_skill_B.wav",
    "res://assets/audio/sfx/approved_20261025/dancer_skill_C.wav"
  ],
  "star4_hunter_skill": [
    "res://assets/audio/sfx/approved_20261025/hunter_skill_A.wav",
    "res://assets/audio/sfx/approved_20261025/hunter_skill_B.wav",
    "res://assets/audio/sfx/approved_20261025/hunter_skill_C.wav"
  ],
  "star4_icey_skill": [
    "res://assets/audio/sfx/approved_20261025/icey_skill_A.wav",
    "res://assets/audio/sfx/approved_20261025/icey_skill_B.wav",
    "res://assets/audio/sfx/approved_20261025/icey_skill_C.wav"
  ],
  "star4_queen_skill": [
    "res://assets/audio/sfx/approved_20261025/queen_skill_A.wav",
    "res://assets/audio/sfx/approved_20261025/queen_skill_B.wav",
    "res://assets/audio/sfx/approved_20261025/queen_skill_C.wav"
  ],
  "star4_skypierce_skill": [
    "res://assets/audio/sfx/approved_20261025/skypierce_skill_A.wav",
    "res://assets/audio/sfx/approved_20261025/skypierce_skill_B.wav",
    "res://assets/audio/sfx/approved_20261025/skypierce_skill_C.wav"
  ],
  "star4_default": [
    "res://assets/audio/sfx/approved_20261025/merge4_A.wav",
    "res://assets/audio/sfx/approved_20261025/merge4_B.wav",
    "res://assets/audio/sfx/approved_20261025/merge4_C.wav"
  ]
}

const BASIC_CUES := {
  "god_priest": "proj_light_lance",
  "god_priestess": "proj_disc",
  "god_guard": "melee_metal",
  "god_aurora": "proj_light_lance",
  "god_angel": "proj_wing",
  "god_arbiter": "melee_metal",
  "god_archangel": "proj_holy",
  "god_king": "melee_metal",
  "dark_imp": "melee_claw",
  "dark_mage": "proj_dark_orb",
  "dark_fear": "melee_claw",
  "dark_queen": "proj_thorn",
  "dark_scythe": "melee_metal",
  "dark_suc": "proj_light_lance",
  "dark_doom": "melee_heavy",
  "dark_dragon": "melee_claw_heavy",
  "undead_small": "melee_spirit",
  "undead_poison": "melee_claw",
  "undead_parasite": "melee_spirit",
  "undead_spike": "proj_bone",
  "undead_fly": "melee_claw",
  "undead_bomb": "melee_spirit",
  "undead_titan": "melee_shell",
  "undead_mother": "proj_light_lance",
  "human_militia": "melee_nonmetal",
  "human_merchant": "melee_unarmed",
  "human_archer": "proj_arrow",
  "human_swordsman": "melee_metal",
  "human_mage": "",
  "human_cleric": "proj_orb",
  "human_death_servant": "melee_metal",
  "human_king": "proj_divine_blade",
  "crimson": "melee_metal",
  "dancer": "proj_disc",
  "drumer": "melee_nonmetal",
  "hunter": "proj_arrow",
  "armbreaker": "melee_heavy",
  "Icey": "proj_frost",
  "skypierce": "proj_javelin",
  "lattern": "proj_ember",
  "merc_pisces_bubble": "proj_orb",
  "merc_cancer_shell": "melee_shell",
  "merc_libra_judge": "melee_metal",
  "merc_taurus_charge": "melee_heavy",
  "merc_virgo_heal": "proj_holy",
  "merc_gemini_assassin": "melee_metal",
  "merc_leo_sun": "melee_claw_heavy",
  "merc_sagittarius_rain": "proj_arrow",
  "merc_aries_blood": "melee_heavy",
  "merc_capricorn_steel": "melee_heavy",
  "merc_aquarius_time": "proj_orb",
  "merc_scorpio_death": "melee_metal",
  "boss_meteor_caster": "proj_orb",
  "boss_thunder_core": "proj_thunder",
  "boss_mirror_lord": "melee_spirit",
  "boss_holy_priest": "proj_holy",
  "boss_rage_beast": "melee_claw_heavy",
  "boss_blood_demon": "melee_metal",
  "boss_soul_devourer": "melee_spirit",
  "boss_twin_gate": "melee_metal",
  "boss_apocalypse": "proj_light_lance",
  "pve_sky_cloud_eagle": "melee_claw",
  "pve_sky_thunder_spirit": "proj_thunder",
  "pve_sky_star_butterfly": "proj_holy",
  "pve_sky_dome_guard": "melee_metal",
  "pve_sky_wind_falcon": "proj_arrow",
  "pve_sky_hymn_spirit": "proj_holy",
  "pve_land_rock_beast": "melee_shell",
  "pve_land_vine_guard": "melee_nonmetal",
  "pve_land_vein_worm": "melee_shell",
  "pve_land_lava_golem": "melee_shell",
  "pve_land_ancient_tree": "proj_holy",
  "pve_land_mountain_giant": "melee_shell",
  "pve_ren_shadow_thief": "melee_metal",
  "pve_ren_voodoo_witch": "proj_orb",
  "pve_ren_wandering_swordsman": "melee_metal",
  "pve_ren_poison_doctor": "proj_bone"
}
