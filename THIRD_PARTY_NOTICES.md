# 第三方资源与代码总账

> 建立于 2026-08-20（README 工作单 A5）。**2026-08-31 按实测复核并补齐盘点**（工作包 C-01）。
>
> **这份文件的用途是发布门禁，不是清单展示。** 一项资源出现在仓库里不等于拥有商业再分发权。
> 下表中任何标为「⛔ 未确认」的项目，在补齐来源与许可证之前**不得随发布包分发**。
>
> 记录口径：每项必须有 来源 / 作者 / 许可证 / 是否允许再分发 / 原始链接。
> 无法补齐的，要么替换，要么在打包时排除。
>
> **机器可读版**：`reports/third_party_license_inventory.json`（由 `tools/license_inventory.py` 生成，可重跑）。
> **缺口清单**：`docs/THIRD_PARTY_LICENSE_GAPS.md`。
> 本文件与那两份冲突时，以生成的那两份为准——它们是从 `assets.manifest.json` 逐条算出来的。

---

## 0. 2026-08-31 复核改了什么

正文 2026-08-20 版的**许可结论一条都没有改动**。改的是三处事实与一处空白：

| 位置 | 原文 | 复核后 |
|---|---|---|
| §2 `Demo_GodotVFX` | 运行时引用「无（仅包内自引用）」 | **不准确。** 它被 `VFXV2ExternalReference3D.gd:15-16` 以 `demo_orb_03/04` 具名引用，且两个 recipe 用到 `external_orb`。但那条路只有 `VFXStageComposerV2` → `ModelBattlePreview`（debug）会走，**正式战斗不经过**——所以「不进发布包」的处置结论仍然正确 |
| §2 缺一行 | 表里没有 `BinbunVFX_Vol2/shared` | **补上。** 14 个文件 / 1.4 MiB，**自己没有 license.txt**，被两个 CC0 子包共同引用 |
| §2 体积列 | 目录体积 | 换成 `assets.manifest.json` 的逐条统计（含 `.import` 边车），与原来的目录体积口径不同 |
| §1 / §5 | `assets/` 一律「尚未盘点」 | **补上真实分组数据**，见下 |

`BinbunVFX`(Vol 1) 与 `Starter_Vfx` 的运行时引用，原文列的三个 Starter 场景
（`vfx_air_explosion_01` / `vfx_muzzle_01` / `vfx_hit_impact_02`）**逐个核对无误**；
补充了两个包各自还有若干只走 debug 路径的入口。

---

## 1. 结论摘要

全仓 **2658 个受管资源 / 2940.0 MiB**（口径＝`assets.manifest.json`，覆盖 `assets/` 与 `effects/` 两个根）。

| 状态 | 文件数 | 体积 | 说明 |
| --- | ---: | ---: | --- |
| ✅ **已证明可再分发** | 65 | 0.2 MiB | 两个 Binbun Vol 2 子包（CC0）+ Knewave 字体（OFL）。每条都指到本仓库内的一个文件和行号 |
| ⛔ **未确认，且正式战斗会播** | 151 | 5.6 MiB | Binbun Vol 1 + Starter_Vfx |
| ⚠️ 未确认，但正式战斗不播 | 60 | 1.5 MiB | Binbun Vol 2 的 `shared/`；Demo_GodotVFX（已在打包时排除） |
| 🧾 **待用户提供采购/委托记录或 AI 生成工具条款** | 2382 | 2932.7 MiB | `assets/` 下的模型、贴图、UI、音频，加上工程自有源码的作者确认 |

**当前最重要的一条没变：正式战斗里真的会播、但许可证未确认的外部 VFX 有 5 个。**

| kind | 来自 | 具体场景（要替换的就是这 5 个文件） | 声明位置 |
|---|---|---|---|
| `beam` | Vol 1 | `BinbunVFX/beam_vfx/effects/base/base_beam_vfx.tscn` | `VFXBinbunReference3D.gd:8` |
| `loot` | Vol 1 | `BinbunVFX/loot_effects/effects/floating/loot_vfx_mythic.tscn` | 同上 `:10` |
| `starter_explosion` | Starter_Vfx | `Starter_Vfx/scenes/explosion/vfx_air_explosion_01.tscn` | `VFXV2ExternalReference3D.gd:9` |
| `starter_hit_02` | Starter_Vfx | `Starter_Vfx/scenes/hit_impact/vfx_hit_impact_02.tscn` | 同上 `:7` |
| `starter_muzzle` | Starter_Vfx | `Starter_Vfx/scenes/muzzle/vfx_muzzle_01.tscn` | 同上 `:12` |

（路径相对各自的包根：Vol 1 在 `effects/vfx3d/vfxv2/binbun_reference/assets/`，
Starter_Vfx 在 `effects/vfx3d/vfxv2/reference_packages/`。全路径见机器可读版。）

这个 5 与 2026-08-20 版从预热清单数出来的 5 **数值一致但推导路径不同**——
本次是从 `scripts/assets/BattleAssetManifest.gd` 的 `BATTLE_EXTERNAL_VFX` 解析的。
两条独立路径得到同一个数。

> **一个必须先说清楚的口径**：`assets.manifest.json` 的 `class: third_party` 是 257 条，
> 很容易被读成「只有 257 个文件需要许可清理」。**不能这样读。** 这 257 条全部在
> `effects/vfx3d/vfxv2/` 下；manifest 的分类器判的是「是不是外来参考包」，不是
> 「许可是否清白」。体量真正的大头 `assets/models`（2546.9 MiB）被分类成
> `runtime_required` / `import_meta`，**完全未清**。

---

## 2. 外部 VFX 包

体积口径为 `assets.manifest.json` 的逐条统计（含 `.import` 边车），与 2026-08-20 版的目录体积不同。

| 包 | 文件 | 体积 | 许可证 | 可再分发 | 正式战斗会播 | 仅 debug 路径 |
| --- | ---: | ---: | --- | --- | --- | --- |
| `BinbunVFX_Vol2/BattleFX` | 35 | 0.1 MiB | **CC0** — 包内 `license.txt` 第 1 行：Battle FX is licensed under Creative Commons Zero (CC0)，明确写明可用于商业项目且无需署名 | ✅ 是 | `slash` | — |
| `BinbunVFX_Vol2/ElementalMagicFX` | 27 | 0.1 MiB | **CC0** — 包内 `license.txt` 第 1 行同上表述 | ✅ 是 | `area`、`projectile` | — |
| `BinbunVFX_Vol2/shared` | 14 | 1.4 MiB | ⛔ **自己没有 license.txt** | ⛔ 未确认 | — | 被上面两个 CC0 子包引用 |
| `BinbunVFX`（Vol 1） | 71 | 0.4 MiB | ⛔ **包内无任何许可证文件** | ⛔ 未确认 | **`beam`、`loot`** | `portal` |
| `reference_packages/Starter_Vfx` | 80 | 5.2 MiB | ⛔ **包内无任何许可证文件** | ⛔ 未确认 | **`starter_explosion`、`starter_hit_02`、`starter_muzzle`** | `starter_fire`、`starter_hit_01`、`starter_loot_01`、`starter_loot_02`、`starter_smoke_01`、`starter_smoke_02` |
| `reference_packages/Demo_GodotVFX` | 46 | 0.2 MiB | ⛔ 无许可证文件 | ⛔ 未确认 | — | `demo_orb_03`、`demo_orb_04`。已在 `export_presets` 的 `exclude_filter` 里（`*/Demo_GodotVFX/*`） |

### 「仅 debug 路径」是什么意思

`scripts/assets/BattleAssetManifest.gd:19-21` 写明：注册表里有 17 个外部 VFX，
但只有 8 类出现在正式战斗调用点（`BossSkillVFXComposer3D` / `UnitSkillVFXComposer3D`）；
其余 9 个只被 `VFXStageComposerV2` 使用，而那条路只有 `ModelBattlePreview`（debug 预览）会走。

所以 `demo_orb_03/04` 虽然被 `VFXV2ExternalReference3D.gd:15-16` 具名引用、
也出现在 `fireball_standard_v2.tres` 和 `portal_arrival_v2.tres` 的 `external_orb` 阶段里，
**正式战斗不会触发它**。核对过两份真机 `device_logcat.log`：
`External VFX reference failed to load` 出现 **0 次**，与该判断一致。

> 顺带记下失效方式：`VFXV2ExternalReference3D.play_external()` 在场景加载不到时
> 走 `push_error` 并 return，表现是**特效不播 + 日志一条 ERROR**，不会崩。
> 所以「排除某个包」的后果是静默丢特效，不是崩溃——这也是下面待办第 1 条
> 「不是简单加一条排除规则就完事」的原因。

### 待办（按优先级）

1. **Binbun Vol 1 与 Starter_Vfx 必须在发布前解决。** 三条路径任选：
   补上原始下载页与许可证 → 若同为 CC0 则登记转绿；
   或替换为已确认的 Vol 2 等价效果；
   或改为工程内自制的程序化效果。
   在此之前这两个包**不能进发布包**，而排除它们会让 5 个战斗特效失效——所以不是简单加一条排除规则就完事。
2. **补 Binbun Vol 2 的下载页**，确认 `shared/` 是否随 BattleFX / ElementalMagicFX 一同 CC0。
   它的两个消费者都是 CC0，所以这是全表最有可能转绿的一组——但「大概率覆盖」不是证据，
   在拿到下载页之前保持未确认。
3. Demo_GodotVFX 已排除出打包，但仍留在仓库供参考。若确认无用可整包移除（注意它在
   `assets.manifest.json` 里有 46 条，需同步重新生成清单）。移除前先确认
   `VFXV2ExternalReference3D.SCENES` 里那两条 debug 入口要不要一起删。

---

## 3. 字体

| 资源 | 许可证 | 可再分发 | 备注 |
| --- | --- | --- | --- |
| `assets/fonts/Knewave-Regular.ttf` | **SIL Open Font License 1.1** — 随包提供 `Knewave-OFL.txt`（第 3、10 行） | ✅ 是 | 作者 Tyler Finck。OFL 要求保留许可证文本，已随字体一同保留，且不在任何 `exclude_filter` 内 |

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

## 5. `assets/` 盘点结果（2026-08-31 补齐）

**本节 2026-08-20 版写的是「以下内容目前没有来源与许可记录，是本文件最大的缺口」。**
缺口仍在——但现在它有了精确的边界、体量和缺失字段清单，不再是一句「尚未盘点」。

| 组 | 文件 | 体积 | 结论 | 缺哪些字段 |
| --- | ---: | ---: | --- | --- |
| `assets/models` — 单位 / 佣兵 / Boss / PVE 怪 / 阵营援军 | 1279 | 2546.9 MiB | 待用户提供记录 | source / author / license / redistributable / source_url |
| `assets/ui` — 卡牌 / 图标 / 立绘 / 按钮 | 482 | 222.0 MiB | 待用户提供记录 | 同上 |
| `assets/vfx` + `assets/vfx_textures` — 特效贴图 | 554 | 128.2 MiB | 待用户提供记录 | 同上 |
| `assets/board` — 棋盘与战场背景 | 28 | 22.3 MiB | 待用户提供记录 | 同上 |
| `assets/audio` — BGM 与 UI 音效 | 12 | 13.3 MiB | 待用户提供记录 | 同上 |
| `assets/shaders` — 三个 Prep 着色器 | 6 | < 0.1 MiB | 待作者确认 | author |
| `effects/vfx3d/vfxv2` 工程自有胶水层 | 21 | < 0.1 MiB | 待作者确认 | author |

**「待用户提供记录」不是「有问题」，也不是「已授权」。** 它的意思是：
这些资源是采购、委托或 AI 生成的，仓库里没有、也不可能有能证明权利的文件——
只有你能提供收据、委托合同或生成工具的服务条款。**其中由 AI 生成的部分需单独标注生成工具与其服务条款。**

### 按「一张凭证能关掉多少」排序的行动清单

1. **Binbun Vol 1 与 Starter_Vfx 的下载页** —— 唯一有发布阻塞性的一条，5 个正式战斗特效卡在这里
2. **`assets/models` 与 `assets/ui` 的采购或委托记录** —— 2768.9 MiB，占包体绝大部分
3. **`assets/audio` 六个 mp3 的音乐库购买凭证** —— 一张收据关掉整组
4. **Binbun Vol 2 的下载页** —— 确认 `shared/` 是否同为 CC0
5. **一行确认** —— `assets/shaders` 与 vfxv2 胶水层是否全部自有创作

`assets.manifest.json` 已经提供了 `path` 与 `sha256` 两列，且**每条都已经有 `license_id` 字段**——
但 2658 条**全部是 `"unknown"`**，字段建好从没填过。
本次盘点的结论按 `path` 对齐地放在 `reports/third_party_license_inventory.json` 里，
何时并回 manifest 的 `license_id` 由资源交付合同的负责人决定，本次没有写回。

---

## 6. 覆盖范围的边界

`assets.manifest.json` 只索引 `assets/` 和 `effects/` 两个根，所以本文件覆盖的
**就是这两个根**。`scenes/`、`scripts/`、`ui/`、`data/` 下的工程源码不在其中——
对一份**资产**许可总账来说这是正确的范围，但不要把「2658 条」读成「仓库里每个文件」。
第三方**代码**的溯源见 §4。

商店上架前，§5 那七组必须逐项补齐 `path / 来源 / 作者 / 许可证 / 是否允许再分发 / 原始链接 / SHA-256`。
