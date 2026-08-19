# 检查台：怎么跑、怎么读、怎么改

对应 README 的 **A1（可复现资产清单）** 与 **A3（让检查真正失败）**。

在此之前，`tools/` 下的检查场景一律以无参 `get_tree().quit()` 结束，退出码恒为 `0`。
断言失败、资源缺失、依赖查询失败全都只打印到日志里，CI 和人都会把它读成"通过"。
本文档描述改造后的约定。

## 1. 怎么跑

Godot 不在 PATH 上，用 console 版才能把日志打到 stdout：

```bash
"C:/Users/Leno/Desktop/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64_console.exe" --headless --path . tools/asset_manifest_check.tscn
```

**不要加 `--quit-after`。** 它会在脚本还没跑到 `finish()` 时强杀进程，退出码被强制成 `0` ——
那正是这次要消灭的假绿。历史上棋盘烟测就是靠它才"通过"的。

核心六个检查：

| 场景 | 覆盖什么 |
| --- | --- |
| `tools/asset_manifest_check.tscn` | 资产清单：引用图、缺失资源、sha256、分类（A1） |
| `tools/model_bounds_check.tscn` | 单位/佣兵模型能否加载、有没有可见网格 |
| `tools/skel_check.tscn` | 多动作 FBX 的骨架是否一致（能否走 Animation Library） |
| `tools/board_4x4_smoke.tscn` | 准备界面棋盘、拖拽、25→16 旧存档迁移 |
| `tools/board_readability_check.tscn` | E1-E：16格/三路双半场契约、样式预算、设置迁移、评审场景 |
| `tools/dep_scan.tscn` | assets/ 下 PNG 的引用情况 |
| `tools/determinism_check.tscn` | 回放确定性：14 个用例的种子矩阵、SHA-256、首差异定位（D3） |

改动过任何 `class_name` 脚本后，先跑一次编辑器导入重建全局类缓存，
否则会看到 `Parse Error: Could not find type "XXX"`：

```bash
"C:/Users/Leno/Desktop/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64_console.exe" --headless --path . --editor --quit-after 400
```

## 2. 退出码

| 码 | 含义 |
| --- | --- |
| `0` | PASS —— 检查了至少一个对象，且没有未被豁免的失败 |
| `1` | FAIL（有失败）或 SKIP（一个对象都没检查到） |

**SKIP 同样返回 1 是刻意的。** 检查集为空意味着"什么都没验证"，把它读成通过正是要消灭的那类假绿：
资源被移走、数据表没读到、过滤条件写错，都会表现为空集。

每次运行末尾有一行机器可读结果，CI 直接 grep 它：

```
CHECK_RESULT name=asset_manifest status=PASS checked=2639 failures=0 allowed=4 stale=0
```

## 3. 允许列表

已知且暂时不修的失败登记在 `tools/check_allowlist.json`。

- 每条**必须**带 `expires`（`YYYY-MM-DD`）。缺 `expires` 的条目不予豁免，并直接报 `allowlist_no_expiry`。
- 到期后条目自动失效，并额外产生一条 `allowlist_expired` 失败 —— **登记一次不会永远绿**。
- 不在列表里的失败一律硬失败。列表为空 = 全部硬失败。
- 某条本次没命中会打印 `STALE`，说明问题可能已修好，应当删除该条。

字段：`check`（检查名或 `*`）/ `code`（失败码或 `*`）/ `match`（消息子串，空=全匹配）/ `expires` / `why`（为什么豁免、归属哪个工作单）。

### 3.1 不该进允许列表的两类东西

允许列表是给「**真问题，但暂时不修**」用的，每条都要到期。有两类失败不属于这个范畴，
硬塞进去只会年年到期、年年续期，最后没人再认真看这份列表。

**归档与证据目录** —— `D3_prechange_backup_20260819/`、`D6_battle_presentation_cleanup_20260819/`
这类目录也在 `res://` 下，但里面是某次改动**当时**的旧副本。它们引用的是那一刻存在的文件：
D6 删掉 `BattlePresentationSlice.gd` 之后，D5/D6 的备份副本仍在引用它，清单就会报出一个
按定义永远修不好的 `missing_asset`。`asset_manifest_check.gd` 的 `SKIP_DIR_PATTERNS`
用通配符匹配目录名把它们排除在扫描之外（`*_prechange_backup_*`、`D?_*_20*` 等）。

跳过的目录会在日志里逐个列出：

```
[asset_manifest] 跳过的归档/证据目录 9 个：D3_battle_presentation_actors_20260819, ... , backups
```

**这一行必须看。** 悄悄少扫一个目录等于悄悄放宽判定 —— 如果哪天某个真实源码目录出现在这行里，
就是模式写得太宽。

**故意写出的不存在路径** —— 在需要抑制的**那一行**行尾加 `# asset-manifest-ignore`：

```gdscript
# 这条路径是**故意**不存在的夹具，用来验证同一坏资源只上报一次。
UnitVisualResolverScript.report_failure("human_militia", "res://missing_model.tscn", "check", "forced failure")  # asset-manifest-ignore

# 反向断言：这个路径必须**不**存在，因此不是资产引用。
_h.expect(not ResourceLoader.exists("res://effects/runtime/presentation/BattlePresentationSlice.gd"),  # asset-manifest-ignore
	"slice_file_left", "BattlePresentationSlice.gd 应在 D6 删除")
```

标记**只作用于所在行**，不是整个文件 —— 同一文件里其他未标记的坏路径照样硬失败。
这一点有专门的实测用例守着（见第 4 节表格）。忽略的行数也会打进日志。

## 4. 加新用例的纪律

沿用 `docs/联机审计与整改方案.md` 已定的规矩：

> 新增用例必须先让它**故意失败一次**，确认失败真的会被看见，再改成正确断言；
> 测试向量只能来自规范或独立实现，不能凭印象写。

这次改造本身按这条验证过，四项都实测通过：

| 验收测试 | 结果 |
| --- | --- |
| 移走 `assets/board/battle_toon_autochess_arena.png` | `status=FAIL` 且点名该路径与消费者 `BattleUI.gd`，退出码 1；恢复后 PASS、退出码 0 |
| 把一条允许列表改成已到期 | `allowlist_expired`，退出码 1 |
| 删掉一条允许列表的 `expires` | `allowlist_no_expiry`，退出码 1 |
| 把两张数据表清空造出空检查集 | `status=SKIP checked=0`，退出码 1 |

3.1 的两条抑制机制加入时同样先证伪过（这是重点：抑制误报最容易顺手把真问题一起抑制掉）：

| 验收测试 | 结果 |
| --- | --- |
| 归档目录排除后，再移走一个真资源 | 仍 `status=FAIL failures=1`，退出码 1 —— 排除的只是归档，检出能力没变 |
| 在**已有标记行的同一文件**里追加一条无标记的坏路径 | `FAIL [missing_asset] res://definitely_not_here_probe.tscn`，退出码 1 —— 证明标记是行级而非文件级 |

## 4.5 回放确定性（D3，2026-08-19）

`tools/determinism_check.tscn` 从"单 seed + 32 位哈希"升级为"种子矩阵 + SHA-256 + 首差异定位"。

**改造前为什么不够**（这些是该文件自己的注释承认的）：

- 用 32 位 `String.hash()` —— 碰撞概率对"证明两份回放逐位相同"来说太高
- 只哈希 `frames` + `result` —— **`frame_events` 和 `roster` 完全没进哈希**，演出事件流和出场名单变了也发现不了
- 单一 seed、单一回合、4 种单位
- 不一致时只说"哈希不等"，不指出差在哪
- 用 `assert()`，失败会中断脚本，后面的用例一个都不跑

**现在**：整份 replay（含 `frames` / `frame_events` / `roster` / `result`）走 SHA-256，
且与 `tools/battle_presentation_baseline.gd` **共用** `tools/ReplayDigest.gd` 的规范化与哈希。
两份实现会漂移，跨平台比对就失去意义 —— 所以抽成一处。

`ReplayDigest.gd` 提供 `json_safe` / `canonical_json` / `sha256_text` / `sha256_variant` /
`sha256_file` / `first_difference`。**改动它会让 Director 的四个冻结哈希漂移**，
所以改完必须重跑 baseline 验证那四个值一字不变（本次抽取即如此验证，两个 round 的
`hashes.json` 逐字节一致）。

### 覆盖是断言出来的，不是声称的

每个用例都要用 `expect` 断言它那一维真的出现在 roster/帧里，另外**所有**用例都断言
"我摆的阵容真的出现在 player 队 roster 里"。这两条不是形式主义，它们当场抓到了两个真问题：

| 抓到的问题 | 表现 |
| --- | --- |
| 四种族只覆盖了两种 | round 3 是 PVE 回合、对手是怪物而非 b 方，改 b 方阵容对结果毫无影响 —— 四个"不同种族"用例里两对哈希**完全相同** |
| 复活用例根本没触发复活 | phoenix 要求**我方**阵亡，而 PVE/Boss 回合里 3 星阵容全胜不掉人，死的全是怪物、怪物没有宝物 |

第二条因此把死亡按阵营拆成 `death_player` / `death_enemy`。实测全矩阵只有
`pvp_round_06` 与 `final_round_21` 出现 `death_player`，复活用例只能放在 PVP 回合。

### 当前矩阵（14 个用例，约 15 秒）

四种族各一（哈希互不相同）、PVP 回合、Boss 回合 ×4（5/10/15/20）、最终战、佣兵、宝物、复活、打断。

覆盖汇总实测：`boss×4  death×14  death_enemy×14  death_player×3  formation_ally×1  interrupt×5  mercenary×1  revive×1`

### 证伪测试

按纪律先让它失败一次：临时把 `sync_2` 的 `frames[3][0][3]`（帧 3、单位 0 的 hp）改成 999999，
检查报出

```
FAIL [sync_not_repeatable] race_human：同步两次结果不同，首差异 $.frames[3][0][3](2160 != 999999)
```

路径与两侧的值都精确 —— 满足 README D3「给出首个不同的 tick、事件和字段，
不允许只输出总哈希不一致」。验证后探针已移除。

> 注入探针那次曾用 latin1 写文件把中文注释写坏，结果**脚本解析失败、进程静默挂死 10 分钟**。
> 这正是 `docs/联机审计与整改方案.md` 记过的假绿类型之一。给检查场景加超时保护是有必要的。

### 仍未覆盖，不得写成通过

**跨平台（桌面 vs Android ARM64）。** README D3 要求"生成桌面与 Android 的 digest 逐项比较"，
Android 按当前决定暂停，只完成了桌面侧。检查运行时会显式打印这一行提醒。

## 5. 本机基线（2026-08-19）

Windows / Godot 4.7.stable / 两个盘点根目录合计 2643 个文件。2026-08-19 的
A2 冷克隆恢复与首次完整导入也使用同一份稳定库存指纹
`5dabb3f546ee6ec0dd8491441ab32872afda3c4e2da46360e752e75e91fc508e`。

| 检查 | checked | failures | allowed | 说明 |
| --- | ---: | ---: | ---: | --- |
| `asset_manifest` | 2647 | 0 | 4 | 盘点 2643 个文件、3115.5 MiB；3 个已知缺失和 1 个依赖查询失败均有精确、限期豁免 |
| `asset_delivery` | 2643 | 0 | 0 | 冷恢复并首次完整导入后：missing/size/hash/extras 均为 0 |
| `model_bounds` | 44 | 0 | 0 | **broken=0、span=0 的模型 0 个** |
| `skel_check` | 68 | 0 | 7 | 61 个单位骨骼一致；7 个已知不一致均归属 E2，并有精确、限期豁免 |
| `board_4x4_smoke` | 62 | 0 | 0 | 含 25→16 迁移与"未知 id 必须被丢弃"两组用例 |
| `board_readability` | 5 组 | 0 | 0 | 16个准备格、6个战术区域、40点射程、真实目标标记、profile v2→v3 迁移全部通过 |
| `dep_scan` | 726 | 0 | 1 | 新纳入 4 张 Godot 从战场水晶 FBX 提取的贴图；已由 A2 manifest 管理 |
| `determinism` | 111 | 0 | 0 | D3 的 14 个用例矩阵，约 15 秒；跨平台未覆盖 |

> ⚠️ **本表上半部分的数字已经对不上当前工作树。** 2026-08-19 D3 落地时实测：
> `asset_manifest` checked=2505（表里写 2647）、`skel_check` checked=3 且有 4 条 STALE
> 豁免（表里写 68 / 7 条）、`model_bounds` checked=75（表里写 44）。
>
> 其中 `skel_check` 是**真实的覆盖退化**：`_collect_units()` 靠"找到带 `ACTION_SCENES`
> 脚本常量的 .gd"来收集单位，而多数 wrapper 已重构为共用
> `assets/models/UnitActionModel.gd`，全仓只剩 3 个单位还是老写法
> （`AbyssBeastAnimated.gd` / `DarkdoomAnimated.gd` / `GodarbiterAnimated.gd`）。
> 也就是 75 个模型里只有 3 个进了骨架比对。这一退化是被允许列表的 STALE 机制发现的。
>
> 数字未在此更新，是因为它与第 7 节那条待办（清单指纹重新冻结）是同一件事，
> 需要先确认文件数变化全部有意，再一次性重冻并同步本表。

**README 里「35 个 broken scene」在本机复现不出来。** README 的审计是在 macOS 上、
带一个外层 `../assets/` 叠加包做的（其 Godot 路径为 `/Volumes/repository/...`），
本机没有那个外层目录，数据表引用的 45 个模型路径**全部存在**。
后续任何"修复了多少个坏场景"的说法都必须以本表为基线，不能沿用 README 的数字。

相较 2026-08-18 的 2501 条旧清单，资源侧补入 68 个动作脚本及对应 68 个 `.uid`，
并移除 2 个旧 `UnitActionModel` 文件，净增 134 条。旧清单因此不再代表当前工程，本次已重新生成。

`skel_check` 现在覆盖 68 个具有 ≥2 个可比动作的单位：61 个一致，7 个不一致。
这 7 个问题需要 Blender 重导出或 retarget，属于 E2；A3 只负责保证它们被准确报告、
未知问题继续硬失败，不能以静默跳过制造假绿。

## 6. 已登记的 11 条豁免

前 7 条登记于 2026-08-18，来自本机首次运行的真实结果；后 4 条登记于
2026-08-19，是扩大 `ACTION_SCENES` 覆盖后首次暴露的 rest pose 不一致。

首批登记的 9 条里有 2 条当天就修掉并删除了（见第 8 节），
删除前先跑了一次确认它们被自动标为 `STALE` —— 这条链路是允许列表不会烂掉的保证。

| 失败 | 到期 | 归属 |
| --- | --- | --- |
| `assets/models/arena/battle_scene.glb` 缺失 | 2026-09-30 | E1。死分支，`BATTLE_USE_3D_ARENA` 为 false |
| `battle_crystal_toon_before.gdshader` 缺失 | 2026-09-30 | A5。只被调试工具引用 |
| Binbun `vfx_blank_shield_02.tscn` 缺失 + 依赖查询失败 | 2026-09-30 | A5/C1。第三方包内部损坏 |
| `god_arbiter_animated` 骨骼数 83 vs 118 | 2026-09-30 | E2 |
| `dark_doom_animated` 骨骼数 65 vs 83 | 2026-09-30 | E2 |
| `abyss_beast_animated` rest pose 不同 | 2026-09-30 | E2 |
| `human_king_animated` rest pose 不同 | 2026-09-30 | E2 |
| `human_cleric_animated` rest pose 不同 | 2026-09-30 | E2 |
| `human_archer_animated` rest pose 不同 | 2026-09-30 | E2 |
| `dark_suc_animated` rest pose 不同 | 2026-09-30 | E2 |

## 7. 产出物

| 文件 | 用途 |
| --- | --- |
| `assets.manifest.json` | 机读清单。每条含 `path / type / size / sha256 / required_by / class / license_id`。**A2 用它在新机器上校验资源恢复结果** |
| `docs/ASSET_MANIFEST.md` | 人读汇总：分类计数、缺失明细、未引用文件清单 |
| `user://asset_manifest_hash_cache.json` | sha256 增量缓存（按 path+size+mtime）。首次全量 35.2 秒，命中缓存后 2.4 秒 |

### ⚠️ 待办：清单指纹重新冻结（2026-08-19 起未决）

**跑 `asset_manifest_check` 会重写 `assets.manifest.json` 和 `docs/ASSET_MANIFEST.md`。**
在下面这件事定案之前，跑完请用 `git checkout -- assets.manifest.json docs/ASSET_MANIFEST.md`
还原，不要顺手把新指纹提交上去。

已提交的清单是 `file_count=2643`、`inventory_sha256=5dabb3f5…`（2026-08-19 04:33 生成），
但当前工作树只有 2501 个文件。拿已提交的清单跑 A2 的交付校验会失败：

```
ASSET_DELIVERY_RESULT status=FAIL entries=2643 missing=144 size_mismatch=215
FAIL 大小不匹配：.../formation_ally_4_animated/attack.fbx expected=37035932 actual=2195132
```

差异对得上 E2-2B 的 FBX 瘦身（ally4/ally5 从 233 MB 降到 19.7 MB）——**瘦身做了，清单没重新生成**。
142 个文件的消失是否全部有意尚未逐条确认，确认后才重新冻结指纹并同步 README 里引用的值。

**顺带暴露的 A2 结构漏洞**：`asset_manifest_check` 重写清单，而 `asset_delivery_check` 读的就是
这个文件。按「先跑 manifest、再跑 delivery」的顺序，delivery 永远是拿刚生成的清单校验刚扫过的树，
**结构上不可能失败**。交付校验必须以受信任的、不在同一次运行里被重写的清单为基准
（例如显式传 `--manifest=` 指向 git 中的版本）。这条属于 A2，尚未修。

`class` 的取值与含义：

| 值 | 含义 |
| --- | --- |
| `runtime_required` | 正式运行会加载，必须进发布包 |
| `editor_only` | 只被 `tools/` 或 `scenes/debug/` 引用，不必进发布包 |
| `dynamic_dir` | 代码运行时按目录拼路径，静态查不到引用，一律保留 |
| `third_party` | 外部参考包，发布前必须有许可证（C1/A5） |
| `backup` | 备份副本，不应进运行仓库（A5） |
| `import_meta` | Godot 导入元数据 |
| `unreferenced` | 任何静态引用都查不到，可评估删除 |

所有条目的 `license_id` 当前均为 `unknown`，留给 A5/C1 补齐。

## 8. 已随本次清理掉的死代码

`scenes/prep/PrepBoardModels.gd` 里 3D 河流场地（river arena）的残留。该方案早已被
「贴在平躺 quad 上的 2D 分层棋盘」取代（见同文件 `_add_prep_art_layers()` 上方注释），
但留下了指向已不存在目录 `assets/models/prep/river_arena/` 的常量和函数：

| 删除项 | 为什么是死的 |
| --- | --- |
| `PREP_RIVER_ARENA_PATH` | 全仓无使用点 |
| `PREP_RIVER_MATERIAL_PATH` | 只被下面这个函数用 |
| `_apply_prep_river_material()` | 全仓无调用点（含 `PrepUI` 这条继承链） |
| `_has_prep_river_background()` | 全仓无调用点 |
| `_prep_river_background_ready` | 唯一读者是上面那个函数，删后成为只写变量 |

注意：这段**不是**运行时失败。`_apply_prep_river_material()` 里那句
`ResourceLoader.load()` 因为函数没人调用而从不执行，所以玩家看不到任何警告。
它的价值在于：A1 的清单把"引用了不存在的资源"暴露出来，顺藤摸瓜才发现整块是死的。

回归：`board_4x4_smoke` 会实例化 `PrepScreen`（→ `PrepUI` → `PrepBoardModels`），
删除后该检查 62 项仍全过、无脚本错误。
