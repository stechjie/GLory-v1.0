# 第三方许可缺口（README A5 / 工作包 C-01）

> 由 `tools/license_inventory.py` 生成于 2026-08-31T09:09:34Z，可随时重跑。
> 机器可读版：`reports/third_party_license_inventory.json`。
>
> **这是缺口清单，不是授权证明。** 只有 `proven` 一档代表有据可查，
> 而且每一条都必须指到本仓库内的一个文件和行号。没有第四档。

## 0. 一句话结论

**正式战斗里真的会播、但许可证未确认的外部 VFX 有 5 个。**
在补齐来源之前这些不能随发布包分发；而直接排除它们会让对应特效失效。

- `starter_explosion` → **Starter_Vfx**（`unknown`，声明于 `effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd:9`）
- `starter_hit_02` → **Starter_Vfx**（`unknown`，声明于 `effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd:7`）
- `starter_muzzle` → **Starter_Vfx**（`unknown`，声明于 `effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd:12`）
- `beam` → **BinbunVFX Vol 1**（`unknown`，声明于 `effects/vfx3d/vfxv2/VFXBinbunReference3D.gd:8,50,87`）
- `loot` → **BinbunVFX Vol 1**（`unknown`，声明于 `effects/vfx3d/vfxv2/VFXBinbunReference3D.gd:10,104`）

## 1. 总账

| 结论 | 文件数 | 字节 | 含义 |
| --- | ---: | ---: | --- |
| `proven` | 65 | 206,148 | An evidence file in this repo says so; path and line numbers cited. |
| `awaiting_user_records` | 2382 | 3,075,127,268 | Procured, commissioned or AI-generated. Only the user can supply the receipt, the commission agreement, or the generator's terms of service. |
| `unknown` | 211 | 7,472,852 | No evidence in the tree and no basis to classify. |
| **合计** | **2658** | **3,082,806,268** | 与 `assets.manifest.json` 逐条对齐 |

## 2. 必须先说清楚的口径

- assets.manifest.json carries a `license_id` field on every one of its 2658 entries and every single one is "unknown" — the column was created and never filled. This report is the sidecar that fills it; it does not write back into the manifest.
- Do NOT read `class: third_party` (257 entries) as the number of files needing licence clearance. All 257 sit under effects/vfx3d/vfxv2/. The manifest's classifier answers 'is this an imported reference package', not 'is the licence clean'. The 2546.9 MiB of assets/models is classed runtime_required/import_meta and is entirely uncleared.
- `proven` requires a citable file in this repository. Three such files exist. Nothing was promoted on plausibility.
- COVERAGE: assets.manifest.json indexes only assets/ and effects/, so that is exactly what this ledger covers. Project source under scenes/, scripts/, ui/ and data/ is NOT enumerated here — for an *asset* licence ledger that is the right scope, but do not read '2658 entries' as 'every file in the repo'. Third-party code provenance lives in THIRD_PARTY_NOTICES.md section 4.

## 3. 分组

| 组 | 结论 | 文件 | 体积 | 正式战斗会播 | 证据 | 缺哪些字段 |
| --- | --- | ---: | ---: | :---: | --- | --- |
| assets/models — 单位 / 佣兵 / Boss / PVE 怪 / 阵营援军 | `awaiting_user_records` | 1279 | 2546.9 MiB | — | — | source、author、license、redistributable、source_url |
| assets/ui — 卡牌 / 图标 / 立绘 / 按钮 | `awaiting_user_records` | 482 | 222.0 MiB | — | — | source、author、license、redistributable、source_url |
| assets/vfx + assets/vfx_textures — 特效贴图 | `awaiting_user_records` | 554 | 128.2 MiB | — | — | source、author、license、redistributable、source_url |
| assets/board — 棋盘与战场背景 | `awaiting_user_records` | 28 | 22.3 MiB | — | — | source、author、license、redistributable、source_url |
| assets/audio — BGM 与 UI 音效 | `awaiting_user_records` | 12 | 13.3 MiB | — | — | source、author、license、redistributable、source_url |
| Starter_Vfx | `unknown` | 80 | 5.2 MiB | ✅ | — | license、author、source_url、redistributable |
| BinbunVFX Vol 2 / shared | `unknown` | 14 | 1.4 MiB | — | — | license、source_url |
| BinbunVFX Vol 1 | `unknown` | 71 | 0.4 MiB | ✅ | — | license、author、source_url、redistributable |
| Demo_GodotVFX | `unknown` | 46 | 0.2 MiB | — | — | license、author、source_url、redistributable |
| BinbunVFX Vol 2 / BattleFX | `proven` | 35 | 0.1 MiB | ✅ | `effects/vfx3d/vfxv2/binbun_reference/assets/BinbunVFX_Vol2/BattleFX/license.txt`:1 | — |
| BinbunVFX Vol 2 / ElementalMagicFX | `proven` | 27 | 0.1 MiB | ✅ | `effects/vfx3d/vfxv2/binbun_reference/assets/BinbunVFX_Vol2/ElementalMagicFX/license.txt`:1 | — |
| Knewave 字体 | `proven` | 3 | 0.0 MiB | — | `assets/fonts/Knewave-OFL.txt`:3,10 | — |
| effects/vfx3d/vfxv2 的工程自有胶水层（registry / cache / recipes） | `awaiting_user_records` | 21 | 0.0 MiB | — | — | author |
| assets/shaders — 三个 Prep 着色器 | `awaiting_user_records` | 6 | 0.0 MiB | — | — | author |

## 4. 逐组说明

### assets/models — 单位 / 佣兵 / Boss / PVE 怪 / 阵营援军

- 结论：**`awaiting_user_records`**
- 缺失字段：source、author、license、redistributable、source_url
- The single largest block in the repo. Nothing in the tree records where these came from — purchased, commissioned, or AI-generated.
- AI-generated portions need the generating tool named plus its terms of service, not just a statement that the project made them.

### assets/ui — 卡牌 / 图标 / 立绘 / 按钮

- 结论：**`awaiting_user_records`**
- 缺失字段：source、author、license、redistributable、source_url

### assets/vfx + assets/vfx_textures — 特效贴图

- 结论：**`awaiting_user_records`**
- 缺失字段：source、author、license、redistributable、source_url
- These ship through git (see the `!/assets/vfx/` exception in .gitignore) and are sampled by roughly 1080 references in effects/, so excluding them is not an option.

### assets/board — 棋盘与战场背景

- 结论：**`awaiting_user_records`**
- 缺失字段：source、author、license、redistributable、source_url

### assets/audio — BGM 与 UI 音效

- 结论：**`awaiting_user_records`**
- 缺失字段：source、author、license、redistributable、source_url
- Music and sound effects carry their own rights, separate from art. Six mp3 files; one stock-library receipt would settle all six at once.

### Starter_Vfx

- 结论：**`unknown`**
- 运行时入口 `starter_explosion` → .../reference_packages/Starter_Vfx/scenes/explosion/vfx_air_explosion_01.tscn（正式战斗，声明于 `effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd:9`）
- 运行时入口 `starter_fire` → .../reference_packages/Starter_Vfx/scenes/fire/vfx_fire_01.tscn（**仅 debug 路径**，声明于 `effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd:8`）
- 运行时入口 `starter_hit_01` → .../reference_packages/Starter_Vfx/scenes/hit_impact/vfx_hit_impact_01.tscn（**仅 debug 路径**，声明于 `effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd:6`）
- 运行时入口 `starter_hit_02` → .../reference_packages/Starter_Vfx/scenes/hit_impact/vfx_hit_impact_02.tscn（正式战斗，声明于 `effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd:7`）
- 运行时入口 `starter_loot_01` → .../reference_packages/Starter_Vfx/scenes/loot/vfx_loot_environment_01.tscn（**仅 debug 路径**，声明于 `effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd:13`）
- 运行时入口 `starter_loot_02` → .../reference_packages/Starter_Vfx/scenes/loot/vfx_loot_environment_02.tscn（**仅 debug 路径**，声明于 `effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd:14`）
- 运行时入口 `starter_muzzle` → .../reference_packages/Starter_Vfx/scenes/muzzle/vfx_muzzle_01.tscn（正式战斗，声明于 `effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd:12`）
- 运行时入口 `starter_smoke_01` → .../reference_packages/Starter_Vfx/scenes/movement/vfx_ground_smoke_01.tscn（**仅 debug 路径**，声明于 `effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd:10`）
- 运行时入口 `starter_smoke_02` → .../reference_packages/Starter_Vfx/scenes/movement/vfx_ground_smoke_02.tscn（**仅 debug 路径**，声明于 `effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd:11`）
- 缺失字段：license、author、source_url、redistributable
- No licence file anywhere in the package.

### BinbunVFX Vol 2 / shared

- 结论：**`unknown`**
- 缺失字段：license、source_url
- Vol 2 ships its licence per sub-package; `shared/` carries no licence.txt of its own.
- Its only consumers are the two CC0 sub-packages above, so it is the single most likely candidate in this table to become `proven` — but 'probably covered' is not evidence, so it stays unknown until the Vol 2 download page is checked.

### BinbunVFX Vol 1

- 结论：**`unknown`**
- 运行时入口 `beam` → .../binbun_reference/assets/BinbunVFX/beam_vfx/effects/base/base_beam_vfx.tscn（正式战斗，声明于 `effects/vfx3d/vfxv2/VFXBinbunReference3D.gd:8,50,87`）
- 运行时入口 `loot` → .../binbun_reference/assets/BinbunVFX/loot_effects/effects/floating/loot_vfx_mythic.tscn（正式战斗，声明于 `effects/vfx3d/vfxv2/VFXBinbunReference3D.gd:10,104`）
- 运行时入口 `portal` → .../binbun_reference/assets/BinbunVFX/portal_vfx/effects/simple/simple_portal_vfx.tscn（**仅 debug 路径**，声明于 `effects/vfx3d/vfxv2/VFXBinbunReference3D.gd:9,96`）
- 缺失字段：license、author、source_url、redistributable
- No licence file anywhere in the package.

### Demo_GodotVFX

- 结论：**`unknown`**
- 运行时入口 `demo_orb_03` → .../reference_packages/Demo_GodotVFX/GodotVFX/effects/magic_orb_flash/magic_orb_flash_vfx_03.tscn（**仅 debug 路径**，声明于 `effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd:15`）
- 运行时入口 `demo_orb_04` → .../reference_packages/Demo_GodotVFX/GodotVFX/effects/magic_orb_flash/magic_orb_flash_vfx_04.tscn（**仅 debug 路径**，声明于 `effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd:16`）
- **已被导出预设 exclude_filter 排除，不进 APK。**
- 缺失字段：license、author、source_url、redistributable
- No licence file anywhere in the package.

### BinbunVFX Vol 2 / BattleFX

- 结论：**`proven`**
- 许可证：**Creative Commons Zero v1.0 Universal**（CC0-1.0）；商用 允许；署名 不要求
- 作者：Binbun3D (bun3d.com)
- 来源：https://creativecommons.org/publicdomain/zero/1.0/
- 证据：`effects/vfx3d/vfxv2/binbun_reference/assets/BinbunVFX_Vol2/BattleFX/license.txt` 第 1 行（匹配 'Creative Commons Zero'）
- 运行时入口 `slash` → .../binbun_reference/assets/BinbunVFX_Vol2/BattleFX/effects/slash/vfx_blank_slash.tscn（正式战斗，声明于 `effects/vfx3d/vfxv2/VFXBinbunReference3D.gd:11,77`）

### BinbunVFX Vol 2 / ElementalMagicFX

- 结论：**`proven`**
- 许可证：**Creative Commons Zero v1.0 Universal**（CC0-1.0）；商用 允许；署名 不要求
- 作者：Binbun3D (bun3d.com)
- 来源：https://creativecommons.org/publicdomain/zero/1.0/
- 证据：`effects/vfx3d/vfxv2/binbun_reference/assets/BinbunVFX_Vol2/ElementalMagicFX/license.txt` 第 1 行（匹配 'Creative Commons Zero'）
- 运行时入口 `area` → .../binbun_reference/assets/BinbunVFX_Vol2/ElementalMagicFX/effects/area/vfx_fire_area_01.tscn（正式战斗，声明于 `effects/vfx3d/vfxv2/VFXBinbunReference3D.gd:7,102`）
- 运行时入口 `projectile` → .../binbun_reference/assets/BinbunVFX_Vol2/ElementalMagicFX/effects/projectile/vfx_fire_projectile_01.tscn（正式战斗，声明于 `effects/vfx3d/vfxv2/VFXBinbunReference3D.gd:6,73`）

### Knewave 字体

- 结论：**`proven`**
- 许可证：**SIL Open Font License 1.1**（OFL-1.1）；商用 允许；署名 要求
- 作者：Tyler Finck <hello@sursly.com>
- 来源：http://scripts.sil.org/OFL
- 证据：`assets/fonts/Knewave-OFL.txt` 第 3、10 行（匹配 'SIL Open Font License'）
- OFL requires the licence text to travel with the font; Knewave-OFL.txt sits alongside the .ttf and is not caught by any exclude_filter.

### effects/vfx3d/vfxv2 的工程自有胶水层（registry / cache / recipes）

- 结论：**`awaiting_user_records`**
- 缺失字段：author
- Everything under assets/ or effects/ that the group rules above did not claim. In practice this is the wrapper layer the project wrote *around* the third-party VFX packages: the two SCENES tables, VFXExternalCache, VFXStageComposerV2 and the eight recipe .tres files.
- Almost certainly written in this project, but authorship is asserted, not evidenced — same caveat as assets/shaders.
- Third-party *code* provenance is tracked separately in THIRD_PARTY_NOTICES.md section 4, which records four consulted repositories and states that no code was ported.

### assets/shaders — 三个 Prep 着色器

- 结论：**`awaiting_user_records`**
- 缺失字段：author
- Looks project-authored, but a file sitting in the repo is not proof of authorship. One line of confirmation from the user closes this group.

## 5. 要用户提供什么

按能一次关掉最多缺口排序：

1. **Binbun Vol 1 与 Starter_Vfx 的下载页与许可证。** 这两个包里有 5 个特效在正式
   战斗里真的会播。三条路任选：补证据（若同为 CC0 即转 `proven`）、换成已确认的
   Vol 2 等价效果、或改为工程内自制程序化效果。
2. **`assets/models` 与 `assets/ui` 的采购/委托记录。** 这两组占了包体的绝大部分。
   AI 生成的部分要单独说明生成工具及其服务条款。
3. **`assets/audio` 六个 mp3 的音乐库购买凭证。** 一张收据能一次关掉整组。
4. **Binbun Vol 2 的下载页**，用来确认 `shared/` 是否随 BattleFX / ElementalMagicFX
   一同 CC0。这组最有可能转绿，但「大概率覆盖」不是证据。
5. **一行确认**：`assets/shaders` 与工程源码是否全部为自有创作。

## 6. 这份报告不做的事

- 不猜许可证，不因为「看起来像免费素材」就转 `proven`
- 不写回 `assets.manifest.json` 的 `license_id`（该文件属 Codex）
- 不修改 `THIRD_PARTY_NOTICES.md`（按交接要求，需用户批准后才补）
- 不移动、删除或排除任何资产

