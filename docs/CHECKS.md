# 检查台：怎么跑、怎么读、怎么改

对应 README 的 **A1（可复现资产清单）** 与 **A3（让检查真正失败）**。

在此之前，`tools/` 下的检查场景一律以无参 `get_tree().quit()` 结束，退出码恒为 `0`。
断言失败、资源缺失、依赖查询失败全都只打印到日志里，CI 和人都会把它读成"通过"。
本文档描述改造后的约定。

## 1. 怎么跑

Godot 不在 PATH 上，用 console 版才能把日志打到 stdout：

```bash
"C:/Users/Leno/Desktop/godot/Godot_v4.7-stable_win64_console.exe" --headless --path . tools/asset_manifest_check.tscn
```

**不要加 `--quit-after`。** 它会在脚本还没跑到 `finish()` 时强杀进程，退出码被强制成 `0` ——
那正是这次要消灭的假绿。历史上棋盘烟测就是靠它才"通过"的。

全部五个检查：

| 场景 | 覆盖什么 |
| --- | --- |
| `tools/asset_manifest_check.tscn` | 资产清单：引用图、缺失资源、sha256、分类（A1） |
| `tools/model_bounds_check.tscn` | 单位/佣兵模型能否加载、有没有可见网格 |
| `tools/skel_check.tscn` | 多动作 FBX 的骨架是否一致（能否走 Animation Library） |
| `tools/board_4x4_smoke.tscn` | 准备界面棋盘、拖拽、25→16 旧存档迁移 |
| `tools/dep_scan.tscn` | assets/ 下 PNG 的引用情况 |

改动过任何 `class_name` 脚本后，先跑一次编辑器导入重建全局类缓存，
否则会看到 `Parse Error: Could not find type "XXX"`：

```bash
"C:/Users/Leno/Desktop/godot/Godot_v4.7-stable_win64_console.exe" --headless --path . --editor --quit-after 400
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
CHECK_RESULT name=asset_manifest status=PASS checked=2507 failures=0 allowed=6 stale=0
```

## 3. 允许列表

已知且暂时不修的失败登记在 `tools/check_allowlist.json`。

- 每条**必须**带 `expires`（`YYYY-MM-DD`）。缺 `expires` 的条目不予豁免，并直接报 `allowlist_no_expiry`。
- 到期后条目自动失效，并额外产生一条 `allowlist_expired` 失败 —— **登记一次不会永远绿**。
- 不在列表里的失败一律硬失败。列表为空 = 全部硬失败。
- 某条本次没命中会打印 `STALE`，说明问题可能已修好，应当删除该条。

字段：`check`（检查名或 `*`）/ `code`（失败码或 `*`）/ `match`（消息子串，空=全匹配）/ `expires` / `why`（为什么豁免、归属哪个工作单）。

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

## 5. 本机基线（2026-08-18）

Windows 10 / Godot 4.7.stable / `assets/` 2205 个文件。

| 检查 | checked | failures | allowed | 说明 |
| --- | ---: | ---: | ---: | --- |
| `asset_manifest` | 2505 | 0 | 4 | 盘点 2501 个文件、2990.8 MiB；解析出 1188 条引用 |
| `model_bounds` | 44 | 0 | 0 | **broken=0、span=0 的模型 0 个** |
| `skel_check` | 3 | 0 | 3 | 只有 3 个单位有 ≥2 个可比动作，且 3 个全不一致 |
| `board_4x4_smoke` | 62 | 0 | 0 | 含 25→16 迁移与"未知 id 必须被丢弃"两组用例 |
| `dep_scan` | 722 | 0 | 1 | — |

**README 里「35 个 broken scene」在本机复现不出来。** README 的审计是在 macOS 上、
带一个外层 `../assets/` 叠加包做的（其 Godot 路径为 `/Volumes/repository/...`），
本机没有那个外层目录，数据表引用的 45 个模型路径**全部存在**。
后续任何"修复了多少个坏场景"的说法都必须以本表为基线，不能沿用 README 的数字。

`skel_check` 的覆盖率是真实短板：44 个模型里只有 3 个进入了骨架比对，
其余单位的 `ACTION_SCENES` 不足 2 个动作。这属于 E2 范围，A3 不处理。

## 6. 已登记的 7 条豁免

登记于 2026-08-18，来自本机首次运行的真实结果。

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

## 7. 产出物

| 文件 | 用途 |
| --- | --- |
| `assets.manifest.json` | 机读清单。每条含 `path / type / size / sha256 / required_by / class / license_id`。**A2 用它在新机器上校验资源恢复结果** |
| `docs/ASSET_MANIFEST.md` | 人读汇总：分类计数、缺失明细、未引用文件清单 |
| `user://asset_manifest_hash_cache.json` | sha256 增量缓存（按 path+size+mtime）。首次全量 35.2 秒，命中缓存后 2.4 秒 |

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
