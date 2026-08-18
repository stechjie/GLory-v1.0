# 资产清单（自动生成，勿手改）

生成者：`tools/asset_manifest_check.gd`　生成时间：2026-08-18T10:39:55　Godot：4.7-stable (official)

机读版本在 `assets.manifest.json`，A2 用它在新机器上校验资源恢复结果。

## 分类汇总

| 分类 | 文件数 | 体积 | 含义 |
| --- | ---: | ---: | --- |
| `runtime_required` | 850 | 2455.1 MiB | 正式运行会加载，必须进发布包 |
| `dynamic_dir` | 306 | 258.9 MiB | 代码运行时按目录拼路径，静态查不到引用，一律保留 |
| `editor_only` | 1 | 2.4 MiB | 只被 tools/ 或 scenes/debug/ 引用，不必进发布包 |
| `third_party` | 260 | 7.3 MiB | 外部参考包，发布前必须有许可证（C1/A5） |
| `import_meta` | 1023 | 1.1 MiB | Godot 导入元数据，由引擎生成 |
| `unreferenced` | 61 | 266.0 MiB | 任何静态引用都查不到，可评估删除 |

## 判定结果

- 被引用但不存在的文件：**5**
- 依赖查询失败的资源：**1**

### 缺失明细

- `res://effects/vfx3d/vfxv2/binbun_reference/assets/BinbunVFX_Vol2/BattleFX/effects/shield/vfx_blank_shield_02.tscn` ← res://effects/vfx3d/vfxv2/binbun_reference/assets/BinbunVFX_Vol2/BattleFX/battle_fx_scene_free.tscn
- `res://assets/models/arena/battle_scene.glb` ← res://scenes/battle/BattleUI.gd
- `res://assets/models/prep/river_arena/Meshy_AI_Verdant_River_Arena_0621085900_texture.fbx` ← res://scenes/prep/PrepBoardModels.gd
- `res://assets/models/prep/river_arena/prep_river_arena_material.tres` ← res://scenes/prep/PrepBoardModels.gd
- `res://shaders/battle_crystal_toon_before.gdshader` ← res://tools/crystal_toon_shot.gd

### 依赖查询失败明细

- `res://effects/vfx3d/vfxv2/binbun_reference/assets/BinbunVFX_Vol2/BattleFX/effects/shield/vfx_blank_shield_02.tscn`

## 未被引用的文件（可评估删除）

- `res://assets/audio/ui/start_game.mp3`
- `res://assets/fonts/Knewave-OFL.txt`
- `res://assets/models/UnitActionModel.gd.uid`
- `res://assets/models/allies/FormationAllyAnimated.gd.uid`
- `res://assets/models/allies/abyss_beast_animated/AbyssBeastAnimated.gd.uid`
- `res://assets/models/allies/abyss_beast_animated/abyss_beast_animated.tscn`
- `res://assets/models/bosses/boss_twin_gate_animated/BossTwinGateVariantAnimated.gd.uid`
- `res://assets/models/mercenaries/merc_aries_blood_animated/merc_aries_blood_attack.fbx`
- `res://assets/models/mercenaries/merc_aries_blood_animated/merc_aries_blood_idle.fbx`
- `res://assets/models/mercenaries/merc_aries_blood_animated/merc_aries_blood_walking.fbx`
- `res://assets/models/monsters/ren/pve_ren_puppet_master_animated/pve_ren_puppet_master_animated.tscn`
- `res://assets/models/units/dark_doom_animated/DarkdoomAnimated.gd.uid`
- `res://assets/models/units/dark_dragon.glb`
- `res://assets/models/units/dark_fear.glb`
- `res://assets/models/units/dark_imp_motong/MotongAnimationTest.gd.uid`
- `res://assets/models/units/dark_scythe.glb`
- `res://assets/models/units/god_angel_animated/god_angel_skill_preview.gd.uid`
- `res://assets/models/units/god_angel_animated/god_angel_skill_preview.tscn`
- `res://assets/models/units/god_arbiter_animated/GodarbiterAnimated.gd.uid`
- `res://assets/models/units/god_arbiter_animated/god_arbiter_attackt.fbx`
- `res://assets/models/units/god_arbiter_animated/god_arbiter_skill_preview.gd.uid`
- `res://assets/models/units/god_arbiter_animated/god_arbiter_skill_preview.tscn`
- `res://assets/models/units/god_arbiter_animated/god_arbiter_weapon.fbx`
- `res://assets/models/units/god_archangel_animated/god_archangel_skill_preview.gd.uid`
- `res://assets/models/units/god_archangel_animated/god_archangel_skill_preview.tscn`
- `res://assets/models/units/god_aurora_animated/god_aurora_skill_preview.gd.uid`
- `res://assets/models/units/god_aurora_animated/god_aurora_skill_preview.tscn`
- `res://assets/models/units/god_guard_crystalbound/GodGuardCrystalboundAnimationTest.gd.uid`
- `res://assets/models/units/god_guard_crystalbound/god_guard_crystalbound_attack.fbx`
- `res://assets/models/units/god_guard_crystalbound/god_guard_crystalbound_idle.fbx`
- `res://assets/models/units/god_guard_crystalbound/god_guard_crystalbound_run.fbx`
- `res://assets/models/units/god_guard_crystalbound/god_guard_skill_preview.gd.uid`
- `res://assets/models/units/god_guard_crystalbound/god_guard_skill_preview.tscn`
- `res://assets/models/units/god_king_animated/god_king_skill_preview.gd.uid`
- `res://assets/models/units/god_king_animated/god_king_skill_preview.tscn`
- `res://assets/models/units/god_priest_halo_animated/god_priest_skill_preview.gd.uid`
- `res://assets/models/units/god_priest_halo_animated/god_priest_skill_preview.tscn`
- `res://assets/models/units/god_priestess_animated/god_priestess_skill_preview.gd.uid`
- `res://assets/models/units/god_priestess_animated/god_priestess_skill_preview.tscn`
- `res://assets/models/units/human_archer.glb`
- `res://assets/models/units/human_archer_animated/human_archer_skill_preview.gd.uid`
- `res://assets/models/units/human_archer_animated/human_archer_skill_preview.tscn`
- `res://assets/models/units/human_cleric_animated/human_cleric_skill_preview.gd.uid`
- `res://assets/models/units/human_cleric_animated/human_cleric_skill_preview.tscn`
- `res://assets/models/units/human_death_servant_animated/human_death_servant_skill_preview.gd.uid`
- `res://assets/models/units/human_death_servant_animated/human_death_servant_skill_preview.tscn`
- `res://assets/models/units/human_king_animated/walk-relaxed-2loop-378986.fbx`
- `res://assets/models/units/human_king_skill_preview.gd.uid`
- `res://assets/models/units/human_king_skill_preview.tscn`
- `res://assets/models/units/human_mage_animated/human_mage_skill_preview.gd.uid`
- `res://assets/models/units/human_mage_animated/human_mage_skill_preview.tscn`
- `res://assets/models/units/human_merchant_green_cloak/human_merchant_skill_preview.gd.uid`
- `res://assets/models/units/human_merchant_green_cloak/human_merchant_skill_preview.tscn`
- `res://assets/models/units/human_militia_little_knight/human_militia_skill_preview.gd.uid`
- `res://assets/models/units/human_militia_little_knight/human_militia_skill_preview.tscn`
- `res://assets/models/units/human_swordsman_animated/human_swordsman_body_material.tres`
- `res://assets/models/units/human_swordsman_animated/human_swordsman_skill_preview.gd.uid`
- `res://assets/models/units/human_swordsman_animated/human_swordsman_skill_preview.tscn`
- `res://assets/shaders/prep_money_bag_glow.gdshader.uid`
- `res://assets/shaders/prep_river_flow.gdshader.uid`
- `res://assets/shaders/prep_scroll_burn.gdshader.uid`

## 许可证

所有条目的 `license_id` 当前均为 `unknown`。A5/C1 必须为每个 `third_party` 与可发布资源补齐来源、作者、许可证与原始链接，并写入 `THIRD_PARTY_NOTICES.md`。
