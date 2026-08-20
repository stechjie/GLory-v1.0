# 第三方资源与代码总账

> 建立于 2026-08-20（README 工作单 A5）。
>
> **这份文件的用途是发布门禁，不是清单展示。** 一项资源出现在仓库里不等于拥有商业再分发权。
> 下表中任何标为「⛔ 未确认」的项目，在补齐来源与许可证之前**不得随发布包分发**。
>
> 记录口径：每项必须有 来源 / 作者 / 许可证 / 是否允许再分发 / 原始链接。
> 无法补齐的，要么替换，要么在打包时排除。

---

## 1. 结论摘要

| 状态 | 数量 | 说明 |
| --- | ---: | --- |
| ✅ 已确认可再分发 | 3 | 两个 Binbun CC0 包 + Knewave 字体（OFL） |
| ⛔ **未确认，且被运行时引用** | 3 | Binbun Vol 1 的两个子包 + Starter_Vfx |
| ⚠️ 未确认，但未被运行时引用 | 1 | Demo_GodotVFX（已在打包时排除） |
| ⬜ 尚未盘点 | — | `assets/` 下的模型、贴图、音频与 AI 生成内容 |

**当前最重要的一条：启动预热实际实例化的 8 个外部 VFX 场景里，有 5 个来自没有许可证的包。**
它们不是可有可无的参考素材，是战斗里真的会播的东西。

---

## 2. 外部 VFX 包

| 包 | 体积 | 许可证 | 可再分发 | 运行时引用 |
| --- | ---: | --- | --- | --- |
| `BinbunVFX_Vol2/BattleFX` | 170 KB | **CC0** — 包内 `license.txt` 原文：Battle FX is licensed under Creative Commons Zero (CC0)，明确写明可用于商业项目且无需署名 | ✅ 是 | `vfx_blank_slash.tscn` |
| `BinbunVFX_Vol2/ElementalMagicFX` | 135 KB | **CC0** — 包内 `license.txt` 同上表述 | ✅ 是 | `vfx_fire_area_01.tscn`、`vfx_fire_projectile_01.tscn` |
| `BinbunVFX`（Vol 1） | 551 KB | ⛔ **包内无任何许可证文件** | ⛔ 未确认 | `beam_vfx/base_beam_vfx.tscn`、`loot_effects/loot_vfx_mythic.tscn` |
| `reference_packages/Starter_Vfx` | 5.5 MB | ⛔ **包内无任何许可证文件** | ⛔ 未确认 | `vfx_air_explosion_01.tscn`、`vfx_muzzle_01.tscn`、`vfx_hit_impact_02.tscn` |
| `reference_packages/Demo_GodotVFX` | 276 KB | ⛔ 无许可证文件 | ⛔ 未确认 | 无（仅包内自引用）。已加入 `export_presets.cfg` 的 `exclude_filter` |

### 待办（按优先级）

1. **Binbun Vol 1 与 Starter_Vfx 必须在发布前解决。** 三条路径任选：
   补上原始下载页与许可证 → 若同为 CC0 则登记转绿；
   或替换为已确认的 Vol 2 等价效果；
   或改为工程内自制的程序化效果。
   在此之前这两个包**不能进发布包**，而排除它们会让 5 个战斗特效失效——所以不是简单加一条排除规则就完事。
2. Demo_GodotVFX 已排除出打包，但仍留在仓库供参考。若确认无用可整包移除（注意它在 `assets.manifest.json` 里有 46 条，需同步重新生成清单）。

---

## 3. 字体

| 资源 | 许可证 | 可再分发 | 备注 |
| --- | --- | --- | --- |
| `assets/fonts/Knewave-Regular.ttf` | **SIL Open Font License**，随包提供 `Knewave-OFL.txt` | ✅ 是 | OFL 要求保留许可证文本，已随字体一同保留 |

---

## 4. 代码

| 项目 | 用途 | 是否移植代码 |
| --- | --- | --- |
| [R055LE/horror-battler](https://github.com/R055LE/horror-battler) | 仅阅读其 `combat → event list → animator` 的分层思想 | **否。** 该仓库未提供 LICENSE，因此只保留链接与人工设计笔记，未复制任何代码、资源或数据 |
| [Lacaedemon/sparta](https://github.com/Lacaedemon/sparta)（MIT） | 参考其「模拟 / 回放 / 单位演员 / HUD」的边界划分 | **否。** BattlePresentationDirector D0-D6 全部按 README 与 Director 清单的条款自行编写，未逐行移植 |
| [Kelpekk/Juicee](https://github.com/Kelpekk/Juicee)（MIT） | 曾列为可选的手感插件 | **否。** D5 未引入该插件 |
| [Brackeys/vfx-in-godot](https://github.com/Brackeys/vfx-in-godot)（CC0） | 参数参考 | **否。** 未导入示例工程 |

**因此 D0-D6 与 B4/E3 没有产生任何新的署名义务。** 若将来确实逐行移植 MIT 代码，
必须在文件头保留原版权声明，并在本节登记来源 commit/tag 与改动文件。

---

## 5. 尚未盘点的部分

以下内容目前**没有**来源与许可记录，是本文件最大的缺口：

- `assets/models/`（393 个文件、约 1070 MiB）：单位、佣兵、Boss、PVE 怪、阵营援军的模型、骨骼、动画与贴图
- `assets/ui/`（490 个文件、约 224 MiB）：卡牌、图标、立绘、按钮
- `assets/audio/`（12 个文件、约 13 MiB）：BGM 与 UI 音效
- `assets/board/`：棋盘与战场背景
- 其中由 AI 生成的部分需单独标注生成工具与其服务条款

商店上架前，这一节必须逐项补齐 `path / 来源 / 作者 / 许可证 / 是否允许再分发 / 原始链接 / SHA-256`。
`assets.manifest.json` 已经提供了 path 与 SHA-256 两列，缺的是来源与许可两列。
