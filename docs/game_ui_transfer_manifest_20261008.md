# Beta 0.04 游戏 UI 移植文件清单

工程根：`C:/Users/Leno/Desktop/Beta 0.04`。以下均为相对路径。

## 修改（11）

- `.gitignore`
- `data/avatars.json`
- `effects/runtime/presentation/adapters/LegacyBattleVfxAdapter.gd`
- `scenes/battle/BattleVfx.gd`
- `scenes/main/Main.gd`
- `scenes/menu/AvatarPickerPanel.gd`
- `scenes/menu/SettingsScreen.gd`
- `scripts/account/AvatarCatalog.gd`
- `scripts/battle/DamageService.gd`
- `tools/battle_presentation_event_check.gd`
- `tools/make_avatar_thumbs.py`

## 创建（131）

- `scenes/menu/GameOverScreen.gd`
- `scenes/menu/GameOverScreen.gd.uid`
- `assets/ui/game_over/victory.png`
- `assets/ui/game_over/defeat.png`
- `assets/ui/avatars/thumb/avatar_001.png`
- `assets/ui/avatars/thumb/avatar_002.png`
- `assets/ui/avatars/thumb/avatar_003.png`
- `assets/ui/avatars/thumb/avatar_004.png`
- `assets/ui/avatars/thumb/avatar_005.png`
- `assets/ui/avatars/thumb/avatar_006.png`
- `assets/ui/avatars/thumb/avatar_007.png`
- `assets/ui/avatars/thumb/avatar_008.png`
- `assets/ui/avatars/thumb/avatar_009.png`
- `assets/ui/avatars/thumb/avatar_010.png`
- `assets/ui/avatars/thumb/avatar_011.png`
- `assets/ui/avatars/thumb/avatar_012.png`
- `assets/ui/avatars/thumb/avatar_013.png`
- `assets/ui/avatars/thumb/avatar_014.png`
- `assets/ui/avatars/thumb/avatar_015.png`
- `assets/ui/avatars/thumb/avatar_016.png`
- `assets/ui/avatars/thumb/avatar_017.png`
- `assets/ui/avatars/thumb/avatar_018.png`
- `assets/ui/avatars/thumb/avatar_019.png`
- `assets/ui/avatars/thumb/avatar_020.png`
- `assets/ui/avatars/thumb/avatar_021.png`
- `assets/ui/avatars/thumb/avatar_022.png`
- `assets/ui/avatars/thumb/avatar_023.png`
- `assets/ui/avatars/thumb/avatar_024.png`
- `assets/ui/avatars/thumb/avatar_025.png`
- `assets/ui/avatars/thumb/avatar_026.png`
- `assets/ui/avatars/thumb/avatar_027.png`
- `assets/ui/avatars/thumb/avatar_028.png`
- `assets/ui/avatars/thumb/avatar_029.png`
- `assets/ui/avatars/thumb/avatar_030.png`
- `assets/ui/avatars/thumb/avatar_031.png`
- `assets/ui/avatars/thumb/avatar_032.png`
- `assets/ui/avatars/thumb/avatar_033.png`
- `assets/ui/avatars/thumb/avatar_034.png`
- `assets/ui/avatars/thumb/avatar_035.png`
- `assets/ui/avatars/thumb/avatar_036.png`
- `assets/ui/avatars/thumb/avatar_037.png`
- `assets/ui/avatars/thumb/avatar_038.png`
- `assets/ui/avatars/thumb/avatar_039.png`
- `assets/ui/avatars/thumb/avatar_040.png`
- `assets/ui/avatars/thumb/avatar_041.png`
- `assets/ui/avatars/thumb/avatar_042.png`
- `assets/ui/avatars/thumb/avatar_043.png`
- `assets/ui/avatars/thumb/avatar_044.png`
- `assets/ui/avatars/thumb/avatar_045.png`
- `assets/ui/avatars/thumb/avatar_046.png`
- `assets/ui/avatars/thumb/avatar_047.png`
- `assets/ui/avatars/thumb/avatar_048.png`
- `assets/ui/avatars/thumb/avatar_049.png`
- `assets/ui/avatars/thumb/avatar_050.png`
- `assets/ui/avatars/thumb/avatar_051.png`
- `assets/ui/avatars/thumb/avatar_052.png`
- `assets/ui/avatars/thumb/avatar_001.png.import`
- `assets/ui/avatars/thumb/avatar_002.png.import`
- `assets/ui/avatars/thumb/avatar_003.png.import`
- `assets/ui/avatars/thumb/avatar_004.png.import`
- `assets/ui/avatars/thumb/avatar_005.png.import`
- `assets/ui/avatars/thumb/avatar_006.png.import`
- `assets/ui/avatars/thumb/avatar_007.png.import`
- `assets/ui/avatars/thumb/avatar_008.png.import`
- `assets/ui/avatars/thumb/avatar_009.png.import`
- `assets/ui/avatars/thumb/avatar_010.png.import`
- `assets/ui/avatars/thumb/avatar_011.png.import`
- `assets/ui/avatars/thumb/avatar_012.png.import`
- `assets/ui/avatars/thumb/avatar_013.png.import`
- `assets/ui/avatars/thumb/avatar_014.png.import`
- `assets/ui/avatars/thumb/avatar_015.png.import`
- `assets/ui/avatars/thumb/avatar_016.png.import`
- `assets/ui/avatars/thumb/avatar_017.png.import`
- `assets/ui/avatars/thumb/avatar_018.png.import`
- `assets/ui/avatars/thumb/avatar_019.png.import`
- `assets/ui/avatars/thumb/avatar_020.png.import`
- `assets/ui/avatars/thumb/avatar_021.png.import`
- `assets/ui/avatars/thumb/avatar_022.png.import`
- `assets/ui/avatars/thumb/avatar_023.png.import`
- `assets/ui/avatars/thumb/avatar_024.png.import`
- `assets/ui/avatars/thumb/avatar_025.png.import`
- `assets/ui/avatars/thumb/avatar_026.png.import`
- `assets/ui/avatars/thumb/avatar_027.png.import`
- `assets/ui/avatars/thumb/avatar_028.png.import`
- `assets/ui/avatars/thumb/avatar_029.png.import`
- `assets/ui/avatars/thumb/avatar_030.png.import`
- `assets/ui/avatars/thumb/avatar_031.png.import`
- `assets/ui/avatars/thumb/avatar_032.png.import`
- `assets/ui/avatars/thumb/avatar_033.png.import`
- `assets/ui/avatars/thumb/avatar_034.png.import`
- `assets/ui/avatars/thumb/avatar_035.png.import`
- `assets/ui/avatars/thumb/avatar_036.png.import`
- `assets/ui/avatars/thumb/avatar_037.png.import`
- `assets/ui/avatars/thumb/avatar_038.png.import`
- `assets/ui/avatars/thumb/avatar_039.png.import`
- `assets/ui/avatars/thumb/avatar_040.png.import`
- `assets/ui/avatars/thumb/avatar_041.png.import`
- `assets/ui/avatars/thumb/avatar_042.png.import`
- `assets/ui/avatars/thumb/avatar_043.png.import`
- `assets/ui/avatars/thumb/avatar_044.png.import`
- `assets/ui/avatars/thumb/avatar_045.png.import`
- `assets/ui/avatars/thumb/avatar_046.png.import`
- `assets/ui/avatars/thumb/avatar_047.png.import`
- `assets/ui/avatars/thumb/avatar_048.png.import`
- `assets/ui/avatars/thumb/avatar_049.png.import`
- `assets/ui/avatars/thumb/avatar_050.png.import`
- `assets/ui/avatars/thumb/avatar_051.png.import`
- `assets/ui/avatars/thumb/avatar_052.png.import`
- `assets/ui/game_over/defeat.png.import`
- `assets/ui/game_over/victory.png.import`
- `prechange_backups/.gdignore`
- `prechange_backups/20261008_ui_transfer/.gitignore`
- `prechange_backups/20261008_ui_transfer/data/avatars.json`
- `prechange_backups/20261008_ui_transfer/effects/runtime/presentation/adapters/LegacyBattleVfxAdapter.gd`
- `prechange_backups/20261008_ui_transfer/effects/runtime/presentation/adapters/LegacyBattleVfxAdapter.gd.uid`
- `prechange_backups/20261008_ui_transfer/scenes/battle/BattleVfx.gd`
- `prechange_backups/20261008_ui_transfer/scenes/battle/BattleVfx.gd.uid`
- `prechange_backups/20261008_ui_transfer/scenes/main/Main.gd`
- `prechange_backups/20261008_ui_transfer/scenes/main/Main.gd.uid`
- `prechange_backups/20261008_ui_transfer/scenes/menu/AvatarPickerPanel.gd`
- `prechange_backups/20261008_ui_transfer/scenes/menu/AvatarPickerPanel.gd.uid`
- `prechange_backups/20261008_ui_transfer/scenes/menu/SettingsScreen.gd`
- `prechange_backups/20261008_ui_transfer/scenes/menu/SettingsScreen.gd.uid`
- `prechange_backups/20261008_ui_transfer/scripts/account/AvatarCatalog.gd`
- `prechange_backups/20261008_ui_transfer/scripts/account/AvatarCatalog.gd.uid`
- `prechange_backups/20261008_ui_transfer/scripts/battle/DamageService.gd`
- `prechange_backups/20261008_ui_transfer/scripts/battle/DamageService.gd.uid`
- `prechange_backups/20261008_ui_transfer/tools/battle_presentation_event_check.gd`
- `prechange_backups/20261008_ui_transfer/tools/battle_presentation_event_check.gd.uid`
- `prechange_backups/20261008_ui_transfer/tools/make_avatar_thumbs.py`
- `docs/game_ui_transfer_manifest_20261008.md`

## 移动与删除

- 无。

## 未覆盖的现有文件

- 真实游戏中已有的 40 张种族原画和 12 张佣兵原画均与源工程 SHA-256 一致，未复制或改动。
.gitignore 的新规则会让其中原本被忽略的 32 张种族原画和 12 张佣兵原画显示为 Git 未跟踪文件；它们不是此次新建的文件。
- `scenes/menu/PetDrawReveal.gd` 及原有探针 UID 副文件保持原状。
- `prechange_backups/20261008_ui_transfer` 中的 11 份原文件备份可用于恢复；8 个 `.gd.uid` 由首次 Godot 导入自动生成。

## 验证

- Godot 4.7 资源导入成功。
- `settings_locale_live_check`: 4/4。
- `battle_presentation_event_check`: 16120/16120。
- `responsive_layout_check`: 114/114。
- `profile_check`: 344/344。
- `main_screen_scenes_check`: 64/64。
- `cold_parse_chain_check`: 354/354。
- 后端头像校验模块接受 52/52 个头像 ID。
- Git diff whitespace check 通过。

## Godot 临时缓存

`.godot/` 下的导入缓存由 Godot 4.7 自动更新，属于引擎管理的临时文件；上面逐项列出了工程资源旁新建的 54 个 `.png.import` 文件。
