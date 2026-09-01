# 资产清单（自动生成，勿手改）

生成者：`tools/asset_manifest_check.gd`　生成时间：2026-08-31T10:36:51　Godot：4.7-stable (official)

清单协议：`schema_version=2`　稳定库存指纹：`f029df50b2892028aad2796439eac0b12bac490de7f377d948ba2bbd28edecf8`

机读版本在 `assets.manifest.json`，A2 用它在新机器上校验资源恢复结果。

## 分类汇总

| 分类 | 文件数 | 体积 | 含义 |
| --- | ---: | ---: | --- |
| `runtime_required` | 918 | 2337.8 MiB | 正式运行会加载，必须进发布包 |
| `dynamic_dir` | 300 | 257.5 MiB | 代码运行时按目录拼路径，静态查不到引用，一律保留 |
| `editor_only` | 2 | 2.7 MiB | 只被 tools/ 或 scenes/debug/ 引用，不必进发布包 |
| `third_party` | 257 | 7.3 MiB | 外部参考包，发布前必须有许可证（C1/A5） |
| `import_meta` | 1036 | 1.1 MiB | Godot 导入元数据，由引擎生成 |
| `unreferenced` | 145 | 333.6 MiB | 任何静态引用都查不到，可评估删除 |

## 判定结果

- 被引用但不存在的文件：**3**
- 依赖查询失败的资源：**1**

### 缺失明细

- `res://effects/vfx3d/vfxv2/binbun_reference/assets/BinbunVFX_Vol2/BattleFX/effects/shield/vfx_blank_shield_02.tscn` ← res://effects/vfx3d/vfxv2/binbun_reference/assets/BinbunVFX_Vol2/BattleFX/battle_fx_scene_free.tscn
- `res://assets/models/arena/battle_scene.glb` ← res://scenes/battle/BattleUI.gd
- `res://shaders/battle_crystal_toon_before.gdshader` ← res://tools/crystal_toon_shot.gd

### 依赖查询失败明细

- `res://effects/vfx3d/vfxv2/binbun_reference/assets/BinbunVFX_Vol2/BattleFX/effects/shield/vfx_blank_shield_02.tscn`

## 未被引用的文件（可评估删除）

- `res://assets/audio/ui/start_game.mp3`
- `res://assets/fonts/Knewave-OFL.txt`
- `res://assets/models/allies/FormationAllyAnimated.gd.uid`
- `res://assets/models/allies/abyss_beast_animated/AbyssBeastAnimated.gd.uid`
- `res://assets/models/allies/abyss_beast_animated/abyss_beast_animated.tscn`
- `res://assets/models/battle_crystals/blue/Meshy_AI_Blue_Crystal_Spire_0717152101_texture_fbx/Meshy_AI_Blue_Crystal_Spire_0717152101_texture_3.png`
- `res://assets/models/battle_crystals/blue/Meshy_AI_Blue_Crystal_Spire_0717152101_texture_fbx/Meshy_AI_Blue_Crystal_Spire_0717152101_texture_4.png`
- `res://assets/models/battle_crystals/red/Meshy_AI_Crimson_Prism_0717152324_texture_fbx/Meshy_AI_Crimson_Prism_0717152324_texture_3.png`
- `res://assets/models/battle_crystals/red/Meshy_AI_Crimson_Prism_0717152324_texture_fbx/Meshy_AI_Crimson_Prism_0717152324_texture_4.png`
- `res://assets/models/bosses/boss_apocalypse_animated/bossapocalypseAnimated.gd.uid`
- `res://assets/models/bosses/boss_blood_demon_animated/bossblooddemonAnimated.gd.uid`
- `res://assets/models/bosses/boss_holy_priest_animated/bossholypriestAnimated.gd.uid`
- `res://assets/models/bosses/boss_meteor_caster_animated/bossmeteorcasterAnimated.gd.uid`
- `res://assets/models/bosses/boss_mirror_lord_animated/bossmirrorlordAnimated.gd.uid`
- `res://assets/models/bosses/boss_rage_beast_animated/bossragebeastAnimated.gd.uid`
- `res://assets/models/bosses/boss_soul_devourer_animated/BossSoulDevourerAnimated.gd.uid`
- `res://assets/models/bosses/boss_thunder_core_animated/bossthundercoreAnimated.gd.uid`
- `res://assets/models/bosses/boss_twin_gate_animated/BossTwinGateVariantAnimated.gd.uid`
- `res://assets/models/mercenaries/merc_aquarius_time_animated/mercaquariustimeAnimated.gd.uid`
- `res://assets/models/mercenaries/merc_aries_blood_animated/merc_aries_blood_attack.fbx`
- `res://assets/models/mercenaries/merc_aries_blood_animated/merc_aries_blood_idle.fbx`
- `res://assets/models/mercenaries/merc_aries_blood_animated/merc_aries_blood_walking.fbx`
- `res://assets/models/mercenaries/merc_aries_blood_animated/mercariesbloodAnimated.gd.uid`
- `res://assets/models/mercenaries/merc_cancer_shell_animated/MercCancerShellAnimated.gd.uid`
- `res://assets/models/mercenaries/merc_capricorn_steel_animated/merccapricornsteelAnimated.gd.uid`
- `res://assets/models/mercenaries/merc_gemini_assassin_animated/mercgeminiassassinAnimated.gd.uid`
- `res://assets/models/mercenaries/merc_leo_sun_animated/mercleosunAnimated.gd.uid`
- `res://assets/models/mercenaries/merc_libra_judge_animated/merclibrajudgeAnimated.gd.uid`
- `res://assets/models/mercenaries/merc_pisces_bubble_animated/MercPiscesBubbleAnimated.gd.uid`
- `res://assets/models/mercenaries/merc_sagittarius_rain_animated/mercsagittariusrainAnimated.gd.uid`
- `res://assets/models/mercenaries/merc_scorpio_death_animated/mercscorpiodeathAnimated.gd.uid`
- `res://assets/models/mercenaries/merc_taurus_charge_animated/merctauruschargeAnimated.gd.uid`
- `res://assets/models/mercenaries/merc_virgo_heal_animated/merc_virgo_heal_Idle.fbx`
- `res://assets/models/mercenaries/merc_virgo_heal_animated/merc_virgo_heal_Walking.fbx`
- `res://assets/models/mercenaries/merc_virgo_heal_animated/merc_virgo_heal_attack.fbx`
- `res://assets/models/mercenaries/merc_virgo_heal_animated/mercvirgohealAnimated.gd.uid`
- `res://assets/models/monsters/land/pve_land_ancient_tree_animated/PveLandAncientTreeAnimated.gd.uid`
- `res://assets/models/monsters/land/pve_land_lava_golem_animated/pvelandlavagolemAnimated.gd.uid`
- `res://assets/models/monsters/land/pve_land_mountain_giant_animated/pvelandmountaingiantAnimated.gd.uid`
- `res://assets/models/monsters/land/pve_land_rock_beast_animated/PvelandrockbeastAnimated.gd.uid`
- `res://assets/models/monsters/land/pve_land_vein_worm_animated/PvelandveinwormAnimated.gd.uid`
- `res://assets/models/monsters/land/pve_land_vine_guard_animated/PvelandvineguardAnimated.gd.uid`
- `res://assets/models/monsters/ren/pve_ren_poison_doctor_animated/pverenpoisondoctorAnimated.gd.uid`
- `res://assets/models/monsters/ren/pve_ren_puppet_master_animated/pve_ren_puppet_master_animated.tscn`
- `res://assets/models/monsters/ren/pve_ren_puppet_master_animated/pverenpuppetmasterAnimated.gd.uid`
- `res://assets/models/monsters/ren/pve_ren_shadow_thief_animated/pverenshadowthiefAnimated.gd.uid`
- `res://assets/models/monsters/ren/pve_ren_voodoo_witch_animated/pverenvoodoowitchAnimated.gd.uid`
- `res://assets/models/monsters/ren/pve_ren_wandering_swordsman_animated/pverenwanderingswordsmanAnimated.gd.uid`
- `res://assets/models/monsters/sky/pve_sky_cloud_eagle_animated/pve_sky_cloud_eagle_Animated.gd.uid`
- `res://assets/models/monsters/sky/pve_sky_dome_guard_animated/pve_sky_dome_guard_Animated.gd.uid`
- `res://assets/models/monsters/sky/pve_sky_hymn_spirit_animated/pve_sky_hymn_spirit_Animated.gd.uid`
- `res://assets/models/monsters/sky/pve_sky_star_butterfly_animated/pve_sky_star_butterfly_Animated.gd.uid`
- `res://assets/models/monsters/sky/pve_sky_thunder_spirit_animated/pve_sky_thunder_spirit_Animated.gd.uid`
- `res://assets/models/monsters/sky/pve_sky_wind_falcon_animated/pve_sky_wind_falcon_Animated.gd.uid`
- `res://assets/models/pets/pet_cat/PetCatAnimated.gd.uid`
- `res://assets/models/pets/pet_mushroom/PetMushroomAnimated.gd.uid`
- `res://assets/models/pets/pet_rabbit/PetRabbitAnimated.gd.uid`
- `res://assets/models/units/dark_doom_animated/DarkdoomAnimated.gd.uid`
- `res://assets/models/units/dark_doom_animated/dark_doom_attack.fbx`
- `res://assets/models/units/dark_doom_animated/dark_doom_attack_Baked_BaseColor.png`
- `res://assets/models/units/dark_doom_animated/dark_doom_attack_Baked_Emit.png`
- `res://assets/models/units/dark_doom_animated/dark_doom_attack_normal.png`
- `res://assets/models/units/dark_doom_animated/dark_doom_idle.fbx`
- `res://assets/models/units/dark_doom_animated/dark_doom_idle_Baked_BaseColor.png`
- `res://assets/models/units/dark_doom_animated/dark_doom_idle_Baked_Emit.png`
- `res://assets/models/units/dark_doom_animated/dark_doom_idle_normal.png`
- `res://assets/models/units/dark_doom_animated/dark_doom_run.fbx`
- `res://assets/models/units/dark_doom_animated/dark_doom_run_Image.png`
- `res://assets/models/units/dark_dragon.glb`
- `res://assets/models/units/dark_dragon_animated/DarkDragonAnimated.gd.uid`
- `res://assets/models/units/dark_fear.glb`
- `res://assets/models/units/dark_fear_animated/darkfearAnimated.gd.uid`
- `res://assets/models/units/dark_imp_motong/MotongAnimationTest.gd.uid`
- `res://assets/models/units/dark_mage_violet_necromancer/DarkMageVioletNecromancerAnimated.gd.uid`
- `res://assets/models/units/dark_queen_animated/DarkQueenAnimated.gd.uid`
- `res://assets/models/units/dark_scythe.glb`
- `res://assets/models/units/dark_scythe_animated/darkscytheAnimated.gd.uid`
- `res://assets/models/units/dark_suc_animated/DarkSucAnimated.gd.uid`
- `res://assets/models/units/god_angel_animated/GodangelAnimated.gd.uid`
- `res://assets/models/units/god_angel_animated/god_angel_skill_preview.gd.uid`
- `res://assets/models/units/god_angel_animated/god_angel_skill_preview.tscn`
- `res://assets/models/units/god_arbiter_animated/GodarbiterAnimated.gd.uid`
- `res://assets/models/units/god_arbiter_animated/god_arbiter_attackt.fbx`
- `res://assets/models/units/god_arbiter_animated/god_arbiter_skill_preview.gd.uid`
- `res://assets/models/units/god_arbiter_animated/god_arbiter_skill_preview.tscn`
- `res://assets/models/units/god_arbiter_animated/god_arbiter_weapon.fbx`
- `res://assets/models/units/god_archangel_animated/GodarchangelAnimated.gd.uid`
- `res://assets/models/units/god_archangel_animated/god_archangel_skill_preview.gd.uid`
- `res://assets/models/units/god_archangel_animated/god_archangel_skill_preview.tscn`
- `res://assets/models/units/god_aurora_animated/GodauroraAnimated.gd.uid`
- `res://assets/models/units/god_aurora_animated/god_aurora_skill_preview.gd.uid`
- `res://assets/models/units/god_aurora_animated/god_aurora_skill_preview.tscn`
- `res://assets/models/units/god_guard_crystalbound/GodGuardCrystalboundAnimationTest.gd.uid`
- `res://assets/models/units/god_guard_crystalbound/god_guard_crystalbound_attack.fbx`
- `res://assets/models/units/god_guard_crystalbound/god_guard_crystalbound_idle.fbx`
- `res://assets/models/units/god_guard_crystalbound/god_guard_crystalbound_run.fbx`
- `res://assets/models/units/god_guard_crystalbound/god_guard_skill_preview.gd.uid`
- `res://assets/models/units/god_guard_crystalbound/god_guard_skill_preview.tscn`
- `res://assets/models/units/god_king_animated/GodkingAnimated.gd.uid`
- `res://assets/models/units/god_king_animated/god_king_skill_preview.gd.uid`
- `res://assets/models/units/god_king_animated/god_king_skill_preview.tscn`
- `res://assets/models/units/god_priest_halo_animated/GodPriestHaloAnimated.gd.uid`
- `res://assets/models/units/god_priest_halo_animated/god_priest_skill_preview.gd.uid`
- `res://assets/models/units/god_priest_halo_animated/god_priest_skill_preview.tscn`
- `res://assets/models/units/god_priestess_animated/GodpriestessAnimated.gd.uid`
- `res://assets/models/units/god_priestess_animated/god_priestess_skill_preview.gd.uid`
- `res://assets/models/units/god_priestess_animated/god_priestess_skill_preview.tscn`
- `res://assets/models/units/human_archer.glb`
- `res://assets/models/units/human_archer_animated/human_archer_skill_preview.gd.uid`
- `res://assets/models/units/human_archer_animated/human_archer_skill_preview.tscn`
- `res://assets/models/units/human_archer_animated/humanarcherAnimated.gd.uid`
- `res://assets/models/units/human_cleric_animated/HumanclericAnimated.gd.uid`
- `res://assets/models/units/human_cleric_animated/human_cleric_skill_preview.gd.uid`
- `res://assets/models/units/human_cleric_animated/human_cleric_skill_preview.tscn`
- `res://assets/models/units/human_death_servant_animated/HumandeathservantAnimated.gd.uid`
- `res://assets/models/units/human_death_servant_animated/human_death_servant_skill_preview.gd.uid`
- `res://assets/models/units/human_death_servant_animated/human_death_servant_skill_preview.tscn`
- `res://assets/models/units/human_king_animated/HumanKingAnimated.gd.uid`
- `res://assets/models/units/human_king_animated/walk-relaxed-2loop-378986.fbx`
- `res://assets/models/units/human_king_skill_preview.gd.uid`
- `res://assets/models/units/human_king_skill_preview.tscn`
- `res://assets/models/units/human_mage_animated/HumanmageAnimated.gd.uid`
- `res://assets/models/units/human_mage_animated/human_mage_skill_preview.gd.uid`
- `res://assets/models/units/human_mage_animated/human_mage_skill_preview.tscn`
- `res://assets/models/units/human_merchant_green_cloak/HumanMerchantGreenCloakAnimated.gd.uid`
- `res://assets/models/units/human_merchant_green_cloak/human_merchant_skill_preview.gd.uid`
- `res://assets/models/units/human_merchant_green_cloak/human_merchant_skill_preview.tscn`
- `res://assets/models/units/human_militia_little_knight/HumanMilitiaLittleKnightAnimated.gd.uid`
- `res://assets/models/units/human_militia_little_knight/human_militia_skill_preview.gd.uid`
- `res://assets/models/units/human_militia_little_knight/human_militia_skill_preview.tscn`
- `res://assets/models/units/human_swordsman_animated/HumanswordsmanAnimated.gd.uid`
- `res://assets/models/units/human_swordsman_animated/human_swordsman_body_material.tres`
- `res://assets/models/units/human_swordsman_animated/human_swordsman_skill_preview.gd.uid`
- `res://assets/models/units/human_swordsman_animated/human_swordsman_skill_preview.tscn`
- `res://assets/models/units/undead_bomb_animated/UndeadbombAnimated.gd.uid`
- `res://assets/models/units/undead_fly_animated/UndeadflyAnimated.gd.uid`
- `res://assets/models/units/undead_mother_animated/UndeadmotherAnimated.gd.uid`
- `res://assets/models/units/undead_parasite_animated/UndeadparasiteAnimated.gd.uid`
- `res://assets/models/units/undead_poison_animated/UndeadpoisonAnimated.gd.uid`
- `res://assets/models/units/undead_small_animated/UndeadsmallAnimated.gd.uid`
- `res://assets/models/units/undead_spike_animated/UndeadspikeAnimated.gd.uid`
- `res://assets/models/units/undead_titan_animated/UndeadtitanAnimated.gd.uid`
- `res://assets/shaders/prep_money_bag_glow.gdshader.uid`
- `res://assets/shaders/prep_river_flow.gdshader.uid`
- `res://assets/shaders/prep_scroll_burn.gdshader.uid`

## 许可证

所有条目的 `license_id` 当前均为 `unknown`。A5/C1 必须为每个 `third_party` 与可发布资源补齐来源、作者、许可证与原始链接，并写入 `THIRD_PARTY_NOTICES.md`。
