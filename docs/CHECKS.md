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
| `tools/replay_identity_split_check.tscn` | 玩法回放身份与完整载荷的双 SHA 合同（见下节） |
| `tools/rate_limit_check.tscn` | RPC 限流服务的行为用例（D1 PR1，注入假时钟） |
| `tools/client_log_check.tscn` | 客户端日志服务的行为用例（D1 PR3，注入临时文件路径） |
| `tools/player_identity_check.tscn` | `player_id` 的签发与**不变性**（账号系统第 0 步，见 `docs/账号系统RFC.md`） |
| `tools/account_check.tscn` | 账号凭证存储与门面接线。核心判据：**access token 永不落盘** |
| `tools/carrot_economy_check.tscn` | 萝卜经济：等级表形状与单调性、采集公式、幂等、**客户端/服务端一致性**、升级石可达性、采集权责判据 |
| `tools/carrot_online_check.tscn` | 联机 3v3 的萝卜链路：服务端准入判据、回执写回 GameState、room_state 带不带萝卜、客机面板按钮可用性 |
| `tools/piece_uid_check.tscn` | 棋子 uid：铸造唯一、跨局不复用、存档往返与老档补发、快照携带与去重 —— 四星血统的前提 |
| `tools/four_star_values_check.tscn` | 四星技能数值：`star4` 覆写只在 4 星生效、不泄漏到低星，以及 §2 配平封顶表的机器可读版本 |

### 检查脚本自己写坏时会怎样（2026-09-08 实测）

**GDScript 解析错误会让 Godot 永远挂住** —— 不退出、不输出 `CHECK_RESULT`，
只在 stderr 打一行 `SCRIPT ERROR: Parse Error`。既不是 PASS 也不是 FAIL，是**没有结果**。

`tools/run_check.ps1` 已经覆盖这种情况（600 秒超时 → `verdict = timeout`、
`passed = $false`），所以走它跑不会假绿。**但手动直接调 Godot 时要自己带超时**，
否则就是干等。

一个具体的踩法：`AccountConfig.get_script_constant_map()` —— 那是非静态方法，
在类上直接调是解析错误。要读 preload 进来的脚本常量，直接
`AccountConfig.SOME_CONST` 就行。

### 需要外部依赖的检查，不进核心清单

`tools/account_live_check.tscn` 是**手动**验收：它要后端在跑、要真实的
`backend/.env` 凭据，所以刻意不列进上面那张表。让门禁依赖某人本机的配置
就是另一种假绿。

```bash
cd backend && .venv/Scripts/python -m uvicorn app.main:app --port 8099
```

它覆盖两次「启动」：第一次本地无凭证走 `/v1/auth/anonymous`，第二次有凭证走
`/v1/auth/refresh` 且 `player_id` 必须不变。第二条最要命 —— 走错分支（重复注册）
不报错，只会让玩家每次启动都变成新玩家，进度看起来就没了。

### 回放身份：两个 SHA，别混用（V2 收尾 G1，2026-09-03）

回放摘要现在给出**两个**互不替代的 SHA-256。判据分工是硬性的：

| 字段 | 覆盖什么 | 什么时候看它 |
| --- | --- | --- |
| `simulation_replay_sha256` | 顶层 `kind` / `frames` / `result` + **正向白名单**投影后的 roster | **玩法/模拟确定性** |
| `replay_payload_sha256` | 完整载荷：roster、`def`、`frame_events`、所有表现字段 | **传输 / 演出载荷完整性** |

- `replay_sha256` 保留为**完整载荷的兼容别名**，含义不变。
  baseline 每次都跨实现校验它确实等于 `replay_payload_sha256`
  （一边走本地 canonical 路径，一边走 `ReplayDigest.payload_sha256()`）。
- `final_state_sha256` / `frame_events_sha256` / `roster_sha256` / `repeat_replay_sha256` 一律保留。

白名单在 `ReplayDigest.SIMULATION_ROSTER_FIELDS`：
`uid / id / team / lane / max_hp / is_mercenary / is_formation_ally / star /
footprint_cells / owner_slot`。

**刻意不纳入**：roster 的整份 `def`（混着 model / material / animation /
`model_in_place_actions` 等表现配置）、`name` / `name_en`（本地化展示串，
改文案不该让玩法身份变化）、`frame_events`（演出事件流，属完整载荷）。

用正向白名单而不是「排除已知表现字段」的黑名单 ——
黑名单会随新字段静默失效，白名单加字段必须有人显式改 `ReplayDigest`。
**投影只能在 `ReplayDigest` 里做一份，禁止散落到各工具。**

#### 为什么要拆

2026-09-02 的根位移批次给 5 个单位加了 `model_in_place_actions`（纯表现配置）。
结果：`final_state_sha256` 三个回合逐字节相同，`replay_sha256` 却全变。
当时无法回答「模拟到底变没变」，只能把决定权交回给人。

拆完之后用真实设备数据复核（8-31 旧包 vs 当前包，rounds 1/5/21）：

```
round_01  simulation a25e9a09f3df… 一致 ✓   payload 5a4ba7b4 -> 9b9163a5 不同
          首差异 $.roster.player_L0_1.def.model_in_place_actions(extra in repeat)
round_05  simulation af21cbd3432c… 一致 ✓   payload 78b1442b -> 2fb9f679 不同
round_21  simulation fd58f3d36bc5… 一致 ✓   payload acbe79e5 -> e547545d 不同
```

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
且与 `scripts/qa/battle_presentation_baseline.gd` **共用** `scripts/qa/ReplayDigest.gd` 的规范化与哈希。
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

## 4.6 NetworkService 拆分（代码 D1，PR1 于 2026-08-20）

> 注意编号撞车：README 的 **代码 D1/D2/D3**（NetworkService 拆分 / PrepUI 拆分 / 回放哈希）
> 与 Checklist 的 **Director D0–D6** 同名。提交信息 `readme all D done` 指的是后者。
> 说"D1 做完了"之前先说清是哪一个。

### 先量耦合，再定顺序

动手前对 4264 行做了一次静态耦合分析（每个函数引用了哪些成员变量）：

```
函数 217 个，成员变量 71 个

被最多函数触碰的成员变量：
  50  state          37  is_host        36  _dedicated_server
  28  team_active    23  team_slot_states
```

按 README 的六个服务分组，各自的耦合度（own=本组变量，fns=触碰它们的函数数，
foreign=这些函数还额外碰了多少组外变量）：

| 候选服务 | own | fns | foreign |
| --- | ---: | ---: | ---: |
| RateLimit（不在 README 六个里） | 2 | 2 | **1** |
| ReplayTransfer | 2 | 4 | 12 |
| ClientLog（不在 README 六个里） | 4 | 5 | 18 |
| Room | 6 | 32 | 23 |
| Reconnect | 6 | 24 | 38 |
| Transport | 8 | 19 | 47 |
| DedicatedServer | 5 | **46** | **37** |

**这份数据推翻了两个原有假设：**

1. **DedicatedServerService 不是最容易的第一刀，而是最难的之一。** `_dedicated_server`
   不是某个模块的私有状态，而是散布在 36 个函数里的**模式开关**（全文件第三热的变量）。
   它的持久化部分实际上是 RoomService 的持久化（直接操作 `_rooms` / `_token_seat` /
   `_public_token_seat`），启动部分又要调 `team_host()`。
2. **README 的"六个平级服务"不完全成立。** `state` / `is_host` / `team_active` /
   `team_slot_states` / `team_ready` / `team_local_slot` / `last_error` 构成一个
   **会话核心**，几乎每个服务都要读，搬不走，只能留在门面上。

修正后的顺序（按实测耦合升序）：
`RateLimit → ReplayTransfer → ClientLog → Room → Reconnect → Transport → DedicatedServer`。

### PR1：RateLimit

`scripts/multiplayer/RateLimitService.gd`。依赖全部注入（`now` / `log` / `kick` 三个 Callable），
本类不认识 `NetworkService`、不碰 `multiplayer`、不读全局状态。
"是否启用"（原来的 `if not _dedicated_server`）留在门面上判断。

- `NetworkService` 4264 → 4223 行
- `_rate_ok` / `_rate_forget` 保留为门面薄包装，**内部 18 个调用点一个都没改**
- 门面 API 面不变：外部 475 处引用、33 个文件，一字未动（实测比对）
- **不用 `class_name`**：`make_server_zip.ps1` 会打包 `.godot/global_script_class_cache.cfg`，
  新增全局类若未先重建缓存就打包，服务器会在解析阶段直接挂

### 抽之前它是零覆盖的

`handshake` / `persist` / `reconnect` / `channel` / `adversarial` 五个探针里，
只有 `adversarial_client_node.gd:307` 一句**注释**提到 `_rate_ok`，没有任何用例真正驱动过限流。
也就是说那五个探针全绿，对"限流有没有被抽坏"零信息量 —— 拿它们当验收就是假绿。

所以新写了 `tools/rate_limit_check.tscn`（45 项），用**注入的假时钟**确定性地覆盖：
配额内放行 / 超限拒绝 / 窗口滚动重置 / strike 累计到阈值踢人且踢对 peer /
`count_strike=false` 不累计不踢人且软日志只记一行 / `forget()` 重置 /
peer 之间隔离 / action 之间隔离 / 未知 action 默认配额 20 / 时钟确实来自注入。

证伪测试：把 `allow()` 改成无条件 `return true`，检查报出 12 条失败并精确指出
"超出配额仍被放行""连续超限没有触发断开""软限流日志应只记 1 行，实际 0 行"。验证后探针已移除。

### PR2：ReplayTransfer

`scripts/multiplayer/ReplayTransferService.gd`：回放的存放（`team_replay` /
`team_replay_rival`）与 zstd 编解码（`pack` / `unpack`、防解压炸弹的长度头校验）。

**动手前先解决了属性转发这个坑。** 这两个是**公开变量**，外部 60 处直接引用，
而且既读又写（整体赋值 `= {}`、也有原地改）。GDScript 里若用"门面存一份、服务存一份"
就会出双份状态，症状是"偶尔看到上一局的回放"，极难查。

正确写法是 Godot 4 的属性访问器：

```gdscript
var team_replay: Dictionary:
	get:
		return _replay_transfer.team_replay
	set(value):
		_replay_transfer.team_replay = value
```

动手前用一次性探针实测过五件事，全部通过：整体赋值写进服务、读得回来、
**原地改共享同一份引用**（getter 返回的不是副本 —— 这是关键，返回副本就会静默丢改动）、
服务侧改动外部可见、清空生效。验完探针即删。

留在门面上的：`_rpc_team_replay`（`@rpc` 必须挂在 autoload 的 Node 上）、
`team_replay_received` 信号、`team_begin_round()`（回合生命周期），
以及 `_pack_replay` / `_unpack_replay` 两个薄包装 ——
`tools/adversarial_client_node.gd` 与 `tools/channel_check_node.gd` 共 7 处直接调用它们
（往返、空包、损坏包、解压炸弹、假长度头），这块**本来就有覆盖**，与限流不同。

`NetworkService` 4223 → 4215 行。

### PR3：ClientLog

`scripts/multiplayer/ClientLogService.gd`：客户端诊断日志的三件事 ——
调试构建下 print、进内存环形缓冲（重连后回传服务器进 journald）、落盘并按大小轮转。
专服不走这里（有 journald，不双写）。

- `_net_log()` 有 **115 个内部调用点**，保留为门面薄包装，一个都没改；外部零引用
- 专服开关按调用**逐次传入**（`write(message, _dedicated_server)`），不在服务里存镜像：
  `_dedicated_server` 在三处被写，存镜像迟早不同步
- 服务端接收侧的行数上限与单行截断长度改为直接引用 `ClientLogService.MAX_LINES` /
  `SEND_LINE_MAX_CHARS` —— 客户端发多少、服务端收多少必须同源
- `_client_send_pending_logs()` 留在门面（要 `.rpc_id()`），取增量的逻辑进服务

`NetworkService` 4215 → 4194 行。三刀合计 **4264 → 4194**。

**这块抽之前同样是零覆盖**，新写 `tools/client_log_check.tscn`（22 项），
落盘路径注入到临时文件，不污染正式的 `user://net_log.txt`。

重点覆盖**环形缓冲与已发游标的联动**：缓冲满时 `pop_front` 的同时，
已发游标必须跟着退一格，否则会把还没回传过的行当成已发的跳过去。
证伪测试把那一格回退删掉，检查立刻报出：

```
FAIL [cursor_not_rewound]   挤掉 3 行后游标应退到 77，实际 80
FAIL [eviction_lost_lines]  应恰好取到 3 行新内容，实际 0 行（游标错位会漏发或重发）
```

**取到 0 行** —— 也就是那 3 行新内容永远发不出去。在真实链路上的表现是
"重连后少了几行崩溃现场"，靠人工几乎不可能发现。验证后探针已移除。

### PR4：Room（进行中，分四步）

Room 比前三刀大一个量级：**37 个函数、约 1065 行，占整个文件的 25%**。
一次性搬完、只有函数级探针兜底风险不可控，因此分四步、每步跑完整回归。

勘测阶段的两个订正：

1. **`_resume_seat`（115 行，Room 里最大的单个函数）其实是重连逻辑**——按 token 找席位、
   失败发 `resume_failed`。它属于 ReconnectService（PR5），不属于 Room。原分组划混了。
2. **`_next_room_id` 是死变量**——房间号早已改成
   `_shard_index * SHARD_ID_STRIDE + randi_range(100000, 999999)`，那个自增计数器
   全仓只剩声明。已删除。

**4-1 状态搬迁（已完成）**：7 个状态变量（`rooms` / `peer_room` / `token_seat` /
`public_token_seat` / `peer_public_token` / `rooms_dirty` / `server_epoch`）进 RoomService，
门面保留**原来的下划线名**作为转发属性。这样 NetworkService 内部 60 多处引用、
以及 `adversarial_client` / `persist_check` / `reconnect_check` 三个探针的 **98 处直接访问**
（读 + 原地写）一处都不用改。

> 诚实记账：这一步让 NetworkService 从 **4194 涨到 4237 行** —— 7 个转发属性比
> 7 行声明长。它的价值是架构接缝，不是行数。

**4-2 持久化 + 房间创建（已完成）**：`new_room` / `snapshot_path` / `save_snapshot` /
`load_snapshot` 进服务，门面留薄包装。NetworkService **4237 → 4059 行**。

两处机制在动手前都用一次性探针验证过（验完即删）：

| 机制 | 用途 | 验证结果 |
| --- | --- | --- |
| 属性 `get`/`set` 转发 | 150+ 处 `_rooms` 等引用零改动 | 整体赋值、读回、**原地改共享同一份引用**、服务侧改动外部可见、清空，五项全过 |
| `const X := RoomService.X` 重新导出 | 常量搬进服务而调用点零改动 | 成立 |

只注入**行为**（`now` / `wall_now` / `log` / `shard_index`）。
`TEAM_SLOTS` / `ROOM_LOBBY` / `ROOM_RESULT` / `RESERVE_GRACE_SEC` 在门面内部有
43/24/11/5 处引用、外部也有引用，留在门面、按配置字典传入更省事。

**4-3 席位元数据 + token 生成（已完成）**：`room_for_peer` / `room_online_count` /
`room_live_token_count` / `move_seat_metadata` / `clear_seat_metadata` /
`release_seat_public_id` / `make_token` / `make_public_token` 进服务，
`SEAT_SLOT_MAPS` 与 `PUBLIC_TOKEN_*` 随实现搬走并重新导出。**4059 → 3987 行**。

**4-4 房间查询与阶段（已完成）**：`room_next_free_slot` / `room_player_count` /
`find_or_create_room` / `touch_room` / `set_room_state` / `public_room_list`
进服务。**3987 → 3951 行**。

### 哪些**故意**留在门面，以及为什么

剩下的 Room 相关函数不是"没搬完"，是**搬进服务会让设计更差**：

| 留下的 | 原因 |
| --- | --- |
| 5 个 `@rpc` 入口（`_rpc_team_create_room` 等，105 行） | RPC 必须挂在 autoload 的 Node 上，服务对象没有节点路径 |
| `_room_close` / `_room_remove_peer` / `_room_reserve_peer`（61 行） | 主体是 RPC 派发与大厅广播：`_rpc_team_room_closed.rpc_id()`、`_broadcast_room_lobby()`、`_maybe_promote_leader()` |
| `_process` / `_cleanup_rooms` / `_assign_peer_to_room` / `_on_peer_disconnected` / `_tick_*`（约 480 行） | 生命周期编排：读 `multiplayer` 连接状态、发广播、驱动看门狗 |
| `_resume_seat`（115 行） | 是重连逻辑，归 PR5 的 ReconnectService |

把这些搬进服务，服务就得为每次发包回调门面——那不是解耦，只是把同一份耦合
换个地方写，还多一层间接。**最终形态是：服务持有房间数据与纯操作，
门面持有网络编排。**这正是门面该有的样子。

### D1 累计

| 刀 | NetworkService |
| --- | --- |
| 起点 | 4264 |
| PR1 RateLimit | 4223 |
| PR2 ReplayTransfer | 4215 |
| PR3 ClientLog | 4194 |
| PR4-1 房间状态搬迁 | 4237（转发属性比声明长，见上） |
| PR4-2 持久化 + 房间创建 | 4059 |
| PR4-3 席位元数据 + token | 3987 |
| PR4-4 房间查询与阶段 | **3951** |

净减 **313 行**，新增四个服务共约 800 行（含从门面搬来的实现与新写的注释）。
门面对外 API 面全程不变：**475 处引用、33 个文件**，一处未改。

### PR5：ReconnectBackoff（只抽算法，不抽状态机）

勘测：触碰重连变量的 **24 个函数、509 行**里，绝大多数是**会话状态机编排** ——
`_begin_reconnect` 写 `state` / `last_error` / 发 `session_changed`、
`_tick_reconnect` 调发包、5 个 `@rpc` 入口必须挂 Node。与 PR4 剩余部分同理，
搬进服务只会变成"为每次状态变更回调门面"。

**另一处订正**：先前说 `_resume_seat`（115 行）归 PR5 —— 不对。它是**服务端**
按 token 恢复席位、操作房间数据、并发 RPC；而 `session_token` / `reconnect_address` /
退避重试那组是**客户端**侧。两件事，`_resume_seat` 留在门面。

真正抽出来的是**退避算法本身**：`scripts/multiplayer/ReconnectBackoff.gd`，
capped exponential backoff + full jitter，随机源可注入。

**抽出来之前它零测试覆盖**——`tools/` 下搜不到一处 backoff 用例。
而它写错的症状是「服务器刚恢复就被全服同步重试再打垮一次」：
服务器冻结时所有客户端同时判超时，若间隔固定，波峰完全叠加。
这类故障本地几乎复现不出来，只在真实事故里暴露。

`tools/reconnect_backoff_check.tscn`（20 项）覆盖：指数增长、上限封顶、
**尝试次数钳制**（`pow(2, 大数)` 溢出成 inf 会让重连彻底卡死）、
full jitter 区间、**"是 full jitter 而非 cap 附近小幅抖动"**、负 attempt 不炸、
超时截止、随机源确实来自注入。

证伪测试把 full jitter 改成"cap 的 0.9~1.0 抖动"，检查报出：

```
FAIL [jitter_not_full_low]     rand=0 应给出 0 等待，实际 14.400（说明不是 full jitter）
FAIL [jitter_span_too_narrow]  抖动跨度只有 1.600，不足 cap 的九成——全服重试仍会叠加
```

NetworkService **3951 → 3954 行**（多出的 3 行是服务实例与注释；这一刀的价值是
把一段零覆盖的关键算法变成有 20 项用例守着的独立单元，不是减行）。

### PR6：ConnectionHealth（只抽判定，不抽传输层）

勘测：触碰传输变量的 **20 个函数、669 行**里，**525 行是编排**。这符合预期 ——
传输层的本职就是操作 `multiplayer` 和 ENet peer，它没有多少"数据"可搬。
纯函数只有 1 个。

可抽的是三个 tick 函数（心跳超时 / 僵尸回收 / 空闲回收）共同的那一半：

```
遍历 peer 映射 → 按时间判定谁该处理 → 执行断开/回收
                 ↑ 纯的，抽走          ↑ 必须留门面
```

`scripts/multiplayer/ConnectionHealth.gd` 只做判定：`timed_out_peers` /
`partition_unjoined` / `should_warn_silence` / `should_log_rtt` / `should_send_ping`。

覆盖现状（抽出来的动机）：`adversarial_client` 只覆盖了空闲回收的**一个**用例，
**心跳超时与僵尸回收零覆盖**。阈值判错的后果都很实在 —— 判太松则掉线的人一直占座位，
判太紧则网络抖一下就踢正常玩家。

`tools/connection_health_check.tscn`（19 项）里最有价值的两组：

**① 阈值之间的相对关系。** 单看任何一个常量都发现不了的错误：

- 静默预警线必须严格早于超时线，否则预警永远不会触发
- 心跳间隔必须早于预警线，否则正常心跳就会触发预警
- 超时线必须大于心跳间隔的两倍，否则丢一个包就判掉线

**② `partition_unjoined` 的两组语义不能混。** 已进房间的 peer 只应从
`connected_at` 摘除（交给座位/心跳那套管），**绝不能断开**；混在一起写就会
把正在打的人踢下线。用例里专门放了"连了极久但都在房间里的 5 个 peer"，
断言它们一个都不被 drop。

证伪测试把预警线从 6s 改到 25s（超过 20s 的超时线）：

```
FAIL [warn_not_before_timeout] 静默预警线 25.0s 不早于超时线 20.0s —— 预警永远不会触发
```

NetworkService **3954 → 3958 行**。同 PR5，价值在于把零覆盖的判定变成有用例守着的纯单元。

未做：PR7 DedicatedServer。**建议不要做成服务对象** ——
`_dedicated_server` 是一个 bool，被 43 处引用、36 个函数读，全是
`if _dedicated_server:` 这样的分支判断。它是横切的**身份**，不是模块的私有状态；
搬进服务只会让 36 个分支的访问路径变长，耦合一点不降。
更值得做的是把它换成 `ServerRole` 枚举 —— 顺便修掉一个真实缺陷：
`enter_test_server_mode()`（工具进程内跑服务端逻辑、不开 socket）与真专服
**共用同一个 bool**，任何一处 `if _dedicated_server` 都分不清"我该发包吗"。
但换枚举要改 43 处、且部分语义需要重判（`!= CLIENT` 还是 `== DEDICATED`），
**这属于改行为而非搬运**，在没有双设备 QA 之前风险高于前六刀。
`_dedicated_server` 是散在 36 个函数里的模式开关而非模块状态，
PR7 更可能该做成门面上的 `ServerRole` 枚举，而不是服务对象。

## 4.8 PrepUI 拆分（代码 D2，第一步：2026-08-20）

### 先量结构，结果比 README 说的更严重

README 的 D2 说"把 `PrepUI.gd`（2461 行）拆成五个 Panel"。实测下来问题不在单个文件：

```
Control
 └─ PrepShared.gd            860 行   成员变量 110 个
     └─ PrepBoardModels.gd  1176 行
         └─ PrepUI.gd       2461 行   用到别层变量 81 个
             └─ PrepFlowController.gd   200 行
                 └─ PrepBoardController.gd  752 行
                     └─ PrepDetails.gd      769 行
                         └─ PrepScreen.gd   509 行
```

**6727 行、409 个函数、148 个成员变量，通过 7 层继承合成一个类。**
`PrepScreen` 实例化出来的对象带着全部这些成员，
`PrepUI` 一层就用到别层定义的 **81 个变量** —— 这是继承耦合的实证。

### 这一步只做了一件事：拆 `_build_rest`

`PrepUI.gd` 里最大的一簇是 `build_*`（8 个函数 1018 行），
其中 **`_build_rest` 一个函数就 638 行**，占 PrepUI 的 26%。

**不能靠肉眼切。** 对函数体做局部变量生存区间分析后发现：

```
全函数 638 行、56 个局部量，完全干净的切点只有 2 处（L310 和 L944）
```

每一个内部切点都至少被 `body`(L311→L885) 和 `center_host`(L327→L943) 跨越，
个别切点还被 `center` / `shop_card_area` 跨越。第一次按"看起来像分段"的位置切，
编译立刻报 `Identifier "left_drop" not declared` —— 数据分析救回来的。

最终切点取在「除 `body`/`center_host` 外没有其它局部量跨越」处（L441/514/672/756/872），
容器以参数传入，并逐一核对过这些参数在段内**只读、不重新赋值**。

| 段 | 行数 |
| --- | ---: |
| `_build_rest`（保留头部 + 5 次调用） | 142 |
| `_build_shop_button_and_purse` | 73 |
| `_build_shop_popup` | 158 |
| `_build_shop_hand_cards` | 84 |
| `_build_sell_zone_and_refresh` | 116 |
| `_build_merc_panels` | 74 |

### 安全网：节点树快照

PrepUI 的注释里明确记着**树顺序影响输入拾取**：

> 它默认 STOP 且树顺序在 board_frame 之后（拾取优先），把右列点击全吃了

也就是说，只要把两段的先后换一下，右列棋格就可能点不动，
而 `board_4x4_smoke` 未必抓得到（它测的是 `_can_drop_on_board` 的逻辑判定，不是真实拾取）。

所以新增 `tools/prep_tree_snapshot.tscn`：实例化 `PrepScreen` 后导出完整节点树 ——
路径、类名、在父节点中的次序，以及 `z_index` / `visible` / `mouse_filter`
这三个决定层叠与拾取的属性。位置尺寸**不记**：它们依赖窗口大小与布局时序，
在 headless 下不稳定，记了只会变成噪声。

拆分前后各抓一份：**303 个节点逐字节一致**。

> ### ⚠️ 2026-08-20 更正：这个工具的第一版是**假绿**，前四步的依据是错的
>
> 第一版 `prep_tree_snapshot` 只做三件事：导出节点树、断言「节点数 > 50」、
> 把文件写到 `user://`。**它从来没有比对过任何东西。**
> 输出里那个 `checked=305` 只是节点计数喂给 `_h.item()`，不是 305 条比对。
>
> 于是「拆分前后逐字节一致」这句话，**靠的是人去 diff 两个 `user://` 文件**，
> 而那一步很容易被省掉 —— 第八到十一步就确实被省掉了，
> 却仍然在结论里写着「节点树 305 节点不变」。
>
> 发现方式：故意把 `PrepWidgets.make_cell_caption()` 的 `z_index` 改成 11、
> `visible` 改成 `true`，工具照样 `status=PASS`。事后 diff 两份导出文件，
> **96 行差异**明明白白。
>
> **事实核对**：树本身确实没变 —— `prep_tree_before.txt`（D2 开工前）
> 与后续每一次导出逐字节相同。结论是对的，**依据是假的**。
> 这两件事必须分开说：结论碰巧成立，不能用来给一条不工作的检查背书。
>
> **已修**：改为与仓库里的 `tools/prep_tree_baseline.txt` 逐行比对，
> 报第一处差异的行号、期望值与实际值（和 `determinism_check` 要求给出
> 首个不同 tick 是同一个道理）。两条证伪：
>
> | 探针 | 结果 |
> | --- | --- |
> | `z_index` 10 → 11 | FAIL `tree_changed` 第 67 行起不同，共 24 行 |
> | 删掉基线文件 | FAIL `baseline_missing` |
>
> 第二条是刻意的：基线缺失若当成「首次运行，自动建基线」，
> 任何人删掉基线就能让这条检查永远绿 —— 那是同一个坑的另一种形状。
> 要重建必须显式跑 `-- --update`，工具会打印警告要求把差异写进本文档。
>
> 后文第八 / 九 / 十 / 十一步里凡写「节点树 305 节点不变」的地方，
> 请按本节理解：**那几次的检查没有真正比对**。
> 事后用修好的工具复核过，树确实未变。

### 剩余工作

这一步**没有**减少类的大小、也没有降低继承耦合 —— `_build_rest` 的 638 行还在
`PrepUI.gd` 里，只是变成了 6 个可读的函数。它的价值是把后续抽取的接缝先开出来。

真正的 D2（按 README：`ShopPanel` / `BoardHud` / `TreasureChoicePanel` /
`SynergyPanel` / `BattleStatsPanel` 用组合替代继承）还需要解决那 148 个成员变量的归属，
特别是 `PrepShared.gd` 里那 110 个 —— 它们是整条链共享的状态池，也是耦合的根。

### 第二步：先给商店补网，再谈抽取

`PrepShared` 的 110 个成员变量里：**15 个只被自己用**（可直接私有化），
**95 个跨层共用**。按功能聚类，最大的两簇是 board（16 个）和 shop（19 个）。

商店那簇正好对应 README 的 `ShopPanel`：**19 个成员变量、122 处引用、18 个函数 851 行**，
分布在 `PrepShared` / `PrepUI` / `PrepBoardController` / `PrepScreen` 四层。

**但抽它之前先查了覆盖，结果是零：**

| 已有检查 | 测的是什么 |
| --- | --- |
| `adversarial_client` | 服务端经济账本（`EconomyLedger.apply` 的 buy/refresh）—— 钱的权威裁决，**不是界面** |
| `board_4x4_smoke` | 棋盘/待命区拖拽，**一个商店调用都没有** |
| `prep_tree_snapshot` | 只证明"构建出来的节点树一致"，证明不了"点击还能用" |

把 19 个变量、644 行代码抽成 ShopPanel 却只有构建快照兜底，
正是这套流程一直在反对的做法。所以先补 `tools/prep_shop_check.tscn`（24 项），
驱动真实私有方法覆盖：节点构建产物、弹窗开关与幂等、售卖模式与覆盖层可见性、
出售区只接受棋盘/待命区、选卡状态、越界索引的购买理由、空商店刷新后清理选中态。

证伪测试两条都验过：
把出售区判定放宽到"任何字典"→ `FAIL [sell_accepts_shop]`；
去掉失效选中态的清理 → `FAIL [stale_selection_kept] 实际 0（会导致点购买时买到不存在的卡）`。

### 写这份用例时我自己造了个假绿，记在这里

第一版的"空商店刷新"用例有两处错：

1. **用 `resize()` 造出了 `null` 空位**。真实代码是
   `GameState.reset_run()` 里 `resize(N)` 之后逐个 `shop_offers[i] = {}`，
   永远不会有 null。于是 `_refresh_shop` 里 `.is_empty()` 打在 Nil 上报错 ——
   那是**测试造了个不可能的状态**，不是产品 bug。
2. **断言写成了 `expect(true, ...)`** —— 一个永远为真的断言。
   结果是：脚本报了 `SCRIPT ERROR`，检查却显示 `status=PASS`。

第 2 条尤其值得记：**"检查通过"和"日志干净"是两回事**，
回归时要同时看 `CHECK_RESULT` 和脚本错误数。本文档第 2 节说"退出码 0 不等于通过"，
这次是同一个陷阱换了个面孔出现在检查脚本自己身上。

### 第三步：商店簇真正搬家

19 个成员变量从 `PrepShared` 的共享池收进 `ShopPanel`，全仓 **133 处引用**
统一改成 `_shop.xxx`（`PrepShared` 19、`PrepUI` 86、`PrepBoardController` 17、`PrepScreen` 11）。

改名表是**单射**且带自检（两个变量映到同一个名字会静默合并，是最难查的一类错误）：

```
_shop_row / _shop_panel / _shop_open_button / _buy_shop_button / _shop_sell_overlay
_shop_side_controls / _refresh_shop_{button,icon,cost_label} / _shop_{buttons,portraits,
card_frames,card_labels,price_labels,race_icons,reason_labels} / _shop_picker_open /
_selected_shop / _shop_drag_sell_mode
        ↓
_shop.{row,panel,open_button,buy_button,sell_overlay,side_controls,
       refresh_button,refresh_icon,refresh_cost_label,buttons,portraits,
       card_frames,card_labels,price_labels,race_icons,reason_labels,
       picker_open,selected,drag_sell_mode}
```

**为什么做成内部类而不是独立文件。** 先按独立文件写了一版，编译报
`Could not find type "DragButton"` / `"SellDropPanel"` —— 这两个是 `PrepShared.gd`
自己的内部类。独立文件要用它们就得 `preload` PrepShared，而 PrepShared 又要
preload 它，循环依赖。退而用无类型 `Array` 的话，`_shop.buttons` 的静态类型会丢，
二十来处调用点全部退化成 Variant。做成内部类两头都保住。

另外 `var _shop: RefCounted = ...` 也不行 —— `_shop.buttons[i]` 的类型推不出来，
一片 `Cannot infer the type`。要用具体类型 `var _shop := ShopPanel.new()`。

`PrepShared` 的成员变量从 110 降到 **67**（除商店 19 个外，
这一步也让之前统计口径里的重复声明归并了）。

### 安全网当场生效了

改完跑回归，`prep_shop_check` 直接 **FAIL 6 项**：

```
FAIL [shop_node_missing] 商店节点 _shop_panel 没有被构建出来
FAIL [shop_button_count] 商店卡位应有 4 个，实际 <null>
```

排查后确认是**检查本身读的是旧名字**，不是产品坏了 —— 但这恰好证明了这张网是通的：
如果搬家真的漏了某个变量，报出来的会是同一种失败。更新检查改从 `_prep._shop` 读之后
恢复 24/24、脚本错误 0，并再次证伪（把 `_set_shop_sell_mode` 改成恒 false
→ `FAIL [sell_mode_not_set]`）。

节点树快照与第一步的基线**逐字节一致**（303 个节点），
`board_4x4_smoke` 62 项、`board_readability` 、`prep_initial_model_layout`、
`determinism` 111 项、`economy_settle` 全部通过。

### 这一步之后还剩什么

商店的**状态**归位了，但 `_build_shop_*` 三个构建函数、`_refresh_shop`、
`_on_shop_pressed` 等**行为**仍在 PrepUI/PrepBoardController 里，
只是通过 `_shop.` 访问自己的状态。要变成 README 说的真正 `ShopPanel` 组合节点
（一个自治的 `Control` 子类），还需要把这些函数也搬进去，并把它对
`GameState` / 教学模式 / 拖拽系统的依赖理清。

### 第四步：棋盘/待命区簇搬家

照商店那一步的模式再做一次。**17 个成员变量**收进 `BoardPanel` 内部类，
全仓 **132 处引用**改成 `_board.xxx`：

| 文件 | 改名处数 |
| --- | ---: |
| `PrepUI.gd` | 68 |
| `PrepBoardController.gd` | 26 |
| `PrepShared.gd` | 17 |
| `PrepBoardModels.gd` | 11 |
| `tools/board_4x4_smoke_node.gd` | 10 |

同样是内部类：`BoardCellButton` / `BenchCellButton` / `RelationProgressOverlay`
也都是 `PrepShared.gd` 自己的内部类。

**踩到一个改名脚本才会犯的错**：`board_4x4_smoke` 里是
`prep.get("_board_buttons")` 这种**字符串字面量**取属性，
机械改名把它变成了 `prep.get("_board.buttons")` —— 而 `Object.get()` 收的是
**属性名不是路径**，这样写会**静默返回 null**，不报错。
改成先取 `_board` 再取字段的辅助函数才对。
这类"字符串里的标识符"是批量改名最容易漏的地方，因为编译器管不到。

验证：节点树 303 个节点与第一步基线**逐字节一致**；
`board_4x4_smoke` 62 项、`prep_shop_check` 24 项、`board_readability`、
`prep_initial_model_layout`、`determinism` 111 项全部通过，脚本错误 0。
证伪：把 `_board.drop_hover_index` 改成恒 -99 →
`FAIL [board_hover_index] 棋盘 hover 下标为 -99，期望 10`。

### D2 四步小结

| 步骤 | 内容 |
| --- | --- |
| 1 | 拆 `_build_rest`（638 行 → 142 行 + 5 个段函数），建立节点树快照安全网 |
| 2 | 补商店 UI 用例（24 项）—— 抽取之前它是零覆盖 |
| 3 | 商店簇 19 个变量 → `ShopPanel` 内部类，133 处引用改名 |
| 4 | 棋盘簇 17 个变量 → `BoardPanel` 内部类，132 处引用改名 |

`PrepShared` 的共享状态池：**110 → 50 个**（36 个进了两个内部类，
其余是统计口径里的重复声明归并）。全程节点树逐字节不变。

### 第五步：为什么不继续搬「行为」，以及真正该抽的是什么

下一步本来是把 `_build_shop_*` / `_refresh_shop` / `_on_shop_pressed` 也搬进 ShopPanel。
动手前先量了一遍这 18 个函数对宿主的依赖：

```
引用 _shop. 的函数：18 个，合计 851 行
完全不依赖宿主的：1 个 / 4 行
```

其余每一个都要用宿主的成员变量和/或函数，`_refresh_shop` 一个就要 6 个变量 + 7 个函数。
**搬进去等于给面板一个 owner 反向引用、处处回调宿主** —— 那不是解耦，
和 NetworkService 编排层得出的是同一个结论，这次有了 prep 侧的数字。

那真正能独立出来的是什么？换个统计口径：

```
不碰任何成员变量、且被 >=2 处调用的函数：86 个 / 1249 行
```

这些才是这条继承链里真正可以拿走的部分。第一个先拿战力格式化 ——
纯数值 + 语言分支，容易写错，而且**此前零覆盖**。

### 抽出来当场发现一个线上 bug：英文战力虚报 10 倍

`scenes/prep/PrepPowerFormat.gd` + `tools/prep_power_format_check.tscn`（26 项）。

原实现的英文分支套用了中文「亿」的阈值，却把单位标成 B：

```gdscript
if rounded >= 100000000: return "%.2fB" % (rounded / 100000000.0)
```

1B = 10 亿，不是 1 亿。把原实现放回去跑检查，报出来的是：

```
FAIL [en_yi_mislabeled_as_billion] format_power(100000000.0, is_en=true) 应为 100.00M，实际 1.00B
FAIL [en_real_billion_lost]        format_power(1000000000.0, is_en=true) 应为 1.00B，实际 10.00B
FAIL [en_m]                        format_power(1000000.0, is_en=true) 应为 1.00M，实际 1000.00K
```

也就是**英文界面上的战力数字一律虚报 10 倍**，而且 M 档整个不存在（1,000,000 显示成 "1000.00K"）。
中文分支一直是对的，所以只有英文玩家看得到。抽取时已修正：
1 亿 → `100.00M`，10 亿 → `1.00B`，并补了 M 档。

> 这是这次拆分里唯一一处**改变了用户可见行为**的地方。其余四步都是纯搬运，
> 由节点树快照逐字节保证。这一处是有意为之的修 bug，不是搬运的副作用。

顺带记一个不是 bug 的边角：`99,999,999 ÷ 10000 = 9999.9999`，`%.2f` 进位成
`10000.00万`。读起来像该显示 `1.00亿`，但它确实还没到阈值。用例里写了注释，
免得下次有人看到再查一遍。

### ⚠️ 一次真实事故：改名漏了 TutorialMode，进教学第一关就崩

D2 第 3/4 步把商店/棋盘成员收进内部类之后，用户实机跑出来的：

```
E _shop_entry_control: Invalid call. Nonexistent 'bool' constructor.
  TutorialMode.gd:551 -> _target_control() -> update_overlay() -> sync()
  -> attach() -> PrepScreen._ready() -> Main._show_prep()
```

`scripts/tutorial/TutorialMode.gd` 里有 **15 处** `_prep.get("_selected_shop")`
这类**字符串取属性**，改名时整个文件被漏掉了 —— 我当时的引用面分析只扫了
`scenes/prep/` 和 `tools/`。

**为什么所有检查都没拦住：**

| 环节 | 为什么没报 |
| --- | --- |
| 编译 | `Object.get()` 的参数是字符串，编译器不检查 |
| 运行时 | 取不到只**返回 null，不报错**，null 一路传到 `bool(null)` 才炸 |
| `board_4x4_smoke` 62 项 | 直接实例化 `PrepScreen`，走不到 `TutorialMode` 这条路 |
| `prep_tree_snapshot` 303 节点 | 只看构建出来的节点树，不看谁去引用它们 |

也就是说：**全绿 + 零脚本错误，但一进教学就崩**。
这正是本文档反复说的那件事的最锋利版本 —— 检查没覆盖到的地方，绿色什么也不证明。

**修复**：15 处改走 `_prep_shop_field()` / `_prep_board_field()` 两个辅助函数
（先取簇、再取字段）。

**补网**：新增 `tools/tutorial_target_check.tscn`（24 项）——
把 `TutorialMode.gd` 里所有 `_prep.get("X")` 与 `_prep_*_field("X")` 的 X 抠出来，
逐个断言 `PrepScreen`（或 `_shop` / `_board`）上真的有这个属性。
判据用 `get_property_list()` 而不是 `get() != null`：合法属性本身也可能是 null
（未构建的节点引用），用返回值区分不开。

扫描前会剥掉注释 —— 第一版没剥，把文档注释里"旧写法长这样"的示例当成了真实调用。

证伪：把任意一处改回 `_prep.get("_shop_picker_open")` →
`FAIL [missing_prep_member] …但 PrepScreen 上没有这个属性（会静默返回 null）`。

**教训写在这里**：批量改名时，引用面分析的范围必须是**全仓**，
不能只扫"看起来相关"的目录。字符串里的标识符编译器管不到，
唯一可靠的办法是有一条检查把"字符串名"和"真实属性"对起来。

### 第六步：战力公式

`scenes/prep/PrepPowerEstimate.gd` + `tools/prep_power_estimate_check.tscn`（22 项）。

公式本身：

```
单位战力 = hp × (1 + def/50) + (普攻DPS + 技能DPS) × 10
普攻DPS  = atk × 攻速 × (1 + 暴击率 × max(0, 暴伤 - 1))
技能DPS  = skill_damage/cd  或  atk × damage_atk_pct/cd  或  atk × skill_atk_pct/cd
```

备战界面三处都用它：玩家当前战力、下一波小怪估算、下一个 Boss 估算。
**写错不会崩、不会报错**，只会让玩家看到偏的数字并据此做错误的备战决策；
而且它同时算玩家侧和敌方侧 —— 末尾那个 `× 10` 决定了"坦度"与"输出"的相对价值，
一动所有单位的战力排序都会变。

用例都用**手算得出**的期望值，不是把当前输出抄下来当基准 ——
后者只能证明"没变过"，证明不了"算得对"。覆盖：

- 三种技能配法各自的公式，以及**它们之间的优先级**（`skill_damage` > `damage_atk_pct` > `skill_atk_pct`；顺序错了会让固定伤害的单位按百分比算，差一个量级）
- `skill_cd <= 0` 返回 0 而不是除零（GDScript 除零给 inf，会让整个战力变成 inf）
- 缺省冷却 8 秒
- 防御的两个字段名 `def` / `defense` 必须等价（数据表两种都出现过）
- 暴伤 < 1 时被 `maxf` 夹住，不能变成负加成
- 空定义为 0、缺 `attack_speed` 默认 1.0
- **单调性**：hp / def / atk / 攻速 / 暴击率任意一项变强，战力都不能变小 ——
  守的是"改公式时某一项被写成负相关"这种低级但致命的错误

22 项一次通过，说明抽出来的实现与原公式逐位一致。
证伪：把 `defense / 50.0` 改成 `/ 100.0` →
`FAIL [effective_hp_wrong] hp 1000 def 50 无输出：期望 2000.0000，实际 1500.0000`。

`PrepDetails` 净减 18 行，保留两个薄包装，三处调用点不用改。

### 第七步：宝物文案与联动依赖 —— 这次选择了「不抽」

下一簇本来是 `PrepDetails` 里的宝物文案（`_treasure_effect_text` 等，约 100 行 match）。
**看了之后决定不搬**：它们是**数据不是逻辑**，把一张查表从一个文件挪到另一个文件，
既不减耦合也不减风险，只是让 diff 变大。

这里真正的风险点是别的：这三个函数都是 `match` + 兜底 `return`，
少写一条不会崩、不会报错，玩家只会看到占位符 ——

```
"暂未写入详细说明。" / "Description not yet available." / "联动效果待说明。"
```

加宝物是**数据改动**，最容易忘的就是回头补文案，而没有任何机制会提醒。

所以这一步交付的是 `tools/prep_text_coverage_check.tscn`（93 项），
把**数据表**和**文案表**对起来：

- 25 件宝物 × 中英文案，任何一条落到占位符就失败
- 11 条联动的说明文案
- **联动的 `requires` 必须都是真实存在的宝物 id** —— 依赖写错的联动永远不会触发，
  而且同样毫无报错（`link_phoenix` 那两件依赖当初是靠人工核对才确认存在的）
- 四个种族的显示名不能落回原始 id

现状是齐的（25/25、11/11），这条检查是为了让它保持齐。

证伪：往 `treasures.json` 里塞一件没写文案的宝物、外加一条依赖不存在宝物的联动：

```
FAIL [treasure_text_missing_cn]   宝物 probe_new_treasure 缺中文说明（落到了占位符）
FAIL [treasure_text_missing_en]   宝物 probe_new_treasure 缺英文说明（落到了占位符）
FAIL [linkage_text_missing]       联动 probe_link 缺说明（落到了占位符）
FAIL [linkage_requires_unknown]   联动 probe_link 依赖的宝物 not_a_real_treasure 在 treasures 表里不存在
```

四类问题全部抓到。

> 这一步是个有用的对照：前六步的判断标准一直是"能不能真正减少耦合"。
> 到这里答案是"不能"，那就不搬 —— 改成补上这块真正缺的那道闸。
> **抽取不是目的，减少出错的可能才是。**

### 第八步：同一套算钱逻辑存了两份

`PrepBoardController._shop_unit_cost()` —— 商店卡片上显示的价格。
`EconomyLedger.unit_cost()` —— 服务端实际扣钱时用的价格。

两份**逐行完全一样**：

```
基础价 cost
  → × shop_cost_multiplier        （单位自带的折价系数）
  → × 0.6  若触发 link_clearance_sale 联动
    elif × 0.8  若持有 money_discount
每一步都 maxi(1, ceil(...))
```

注意中间那个 **elif** —— 联动折扣和折扣券是**互斥**的，不叠加。
如果哪天有人把它写成两个并列的 `if`，价格就会变成 ×0.48，凭空多出一档折扣。

**这种重复的危险之处不在于"代码难看"，在于它坏掉时完全无声。**
改了服务端忘了改客户端，结果就是卡片上写着 10 金、点下去扣了 12 金。
没有报错、没有警告、没有断言，玩家只会觉得"钱怎么不对"，
而这类问题在联机对局里通常要等到有人截图投诉才会被发现。

处理方式：**删掉客户端那份，改为委托服务端的权威实现。**
服务端是最终裁决方，以它为准；客户端只是显示，不该有自己的意见。

```gdscript
func _shop_unit_cost(unit_def: Dictionary) -> int:
    return EconomyLedger.unit_cost(unit_def, GameState.owned_treasures)
```

`EconomyLedger` 是全局 `class_name`（`scripts/multiplayer/EconomyLedger.gd`），
不需要 preload。10 行 → 2 行。

#### 新增检查 `tools/shop_price_parity_check.tscn`（106 项）

光删掉不够 —— 没有任何机制阻止以后有人又在客户端补一份"本地算价"。
所以这一步同时补了一条守门的检查，做两件事：

| 用例 | 守什么 |
| --- | --- |
| 32 个真实单位 × 3 种宝物持有状态 = 96 组比对 | 客户端报价 ≡ 服务端报价 |
| `shop_cost_multiplier` 0.5 → 5、0.55 → 6 | 倍率生效且向上取整 |
| clearance + money_discount 同时持有仍为 ×0.6 | **两档折扣互斥，不叠加**（写成 48 就是叠加了） |
| cost 1 打折后仍为 1、极低倍率仍为 1、缺字段默认 1 | 价格下限，不能白送或变成 0 |

第一条用的是数据表里的**真实单位**，不是构造的假数据 ——
`board_4x4_smoke` 曾经因为用假 unit id 而误判 `sanitize_board` 有 bug（见 4.5），
教训是：断言产品行为时用真数据，构造假数据只用来测边界规则。

#### 证伪（必做，否则不算数）

把客户端改回"自己算"，并故意把互斥的 elif 写成两个并列 if：

```
FAIL [price_mismatch] 单位 god_priest（持有 ["atk_fury_roster", "money_discount"]）：
                      客户端 10 vs 服务端 12 —— 显示价与实扣价不一致
FAIL [price_mismatch] 单位 god_guard（同上）：客户端 15 vs 服务端 18
...
```

抓到的正是"显示一个价、扣另一个价"这个症状本身。还原后 106 项全过。

#### 回归

`shop_price_parity` / `prep_text_coverage` / `prep_power_estimate` / `prep_power_format` /
`tutorial_target` / `prep_shop` / `prep_tree_snapshot` / `board_4x4_smoke` /
`adversarial_client` / `economy_settle` / `determinism` —— 11 项全过，零脚本错误。
其中 `adversarial_client` 与 `economy_settle` 本来就在测服务端定价，
它们没变色说明权威侧的行为一字未动。

### 第九步：服务端商店根本没有档位概念

上一步查定价重复时顺手搜了「服务端有没有第二份规则」，搜出两个命中，
其中一个不是重复 —— 是**两边规则不一样**。

| | 客户端 `_roll_shop_tier` | 服务端 `_server_roll_shop_offers` |
| --- | --- | --- |
| 做法 | 按回合摇档位，再在该档单位里选 | **全表均匀随机**，没有档位概念 |

单位表是 32 个：tier1 八个、tier2 十八个、tier3 六个。于是：

| 回合 | 客户端 t1/t2/t3 | 服务端（均匀） |
| --- | --- | --- |
| 1–4 | **80% / 20% / 0%** | 25% / 56% / **19%** |
| 5–9 | 50% / 50% / 0% | 25% / 56% / **19%** |
| 10–14 | 25% / 60% / 15% | 25% / 56% / 19% |
| 15+ | 15% / 60% / 25% | 25% / 56% / 19% |

**第一回合就有 19% 概率刷出三档单位，设计上那里应该是 0%。**
整条成长曲线在联机权威模式下会静默消失。

#### 为什么它到现在都没被发现

两个原因，第二个比第一个严重得多。

1. 账本还锁在 `economy_ledger_enabled` / `economy_ledger_authoritative` 两个
   **默认关闭**的开关后面，`request_economy` 全仓一个调用点都没有 ——
   这条路径今天不跑，所以是**潜伏**缺陷，不是线上事故。
2. 计划中用来验收开关能不能翻的「影子比对」，**结构上抓不到这个问题**。
   `_shadow_audit_economy()` 比的只有金币，而刷新价两边都走
   `EconomyService.shop_refresh_cost`，一分钱不差。
   代码注释里白纸黑字写着「影子期零差异是翻 authoritative 开关的唯一依据」——
   照这个依据走，会得到一个漂亮的零差异，然后翻开关，然后商店曲线没了。

> 这是这一步真正的收获：**不是"发现了一个 bug"，是"发现验收标准本身有盲区"**。
> 一个只比金币的对账机制，无法验收一个会改变商品内容的改动。

#### 改法

新建 `scripts/economy/ShopRoll.gd`，把档位曲线放进去，两边共用。

关键设计：**随机数不在模块里摇**。调用方各自提供 `[0,1)` 的值 ——
客户端用 `RandomNumberGenerator`，服务端必须用 `Crypto`
（`randf()` 的种子来自系统时间、可预测，而商店内容是钱能买到的东西；
同文件里赌博那段已经因为同样的理由用了 `Crypto`）。
模块只负责「一个骰子点数 + 回合号 → 档位」这条**规则**。

用 `preload` 而不是 `class_name`：新增全局类要等编辑器重扫才进类缓存，
而服务端包是直接打包仓库里那份缓存文件的（见 4.6）。

顺带修掉一个 off-by-one：`_room_begin_next_prep()` 摇的是**下一轮**的商店，
但它位于 `room.round_index` 自增**之前**。直接传 `room.round_index` 会让
整条曲线慢一轮（第 5 回合拿到第 4 回合的分布）。改成先算出 `next_round`，
摇商店和自增共用同一个值。

#### 新增检查 `tools/shop_roll_parity_check.tscn`（6476 项）

抽出规则之后有个容易犯的错：只测 `ShopRoll` 本身。
那只能证明「规则没写错」，证明不了「服务端真的在用它」——
而这次坏的恰恰是后者。所以检查分四层：

| 层 | 断言 | 能抓到什么 |
| --- | --- | --- |
| 曲线边界（23 点） | roll=0.799→t1、0.80→t2 … 逐点钉死 | `<` 写成 `<=` 之类的偏移 |
| 服务端硬断言 | 回合 1/4/5/9 采样 8000 次，三档**必须为 0** | 均匀随机（会给出 ~19%），零抽样风险 |
| 服务端分布 | 回合 1/5/10/15/21 各档占比 ±5 个百分点 | 曲线被改动 |
| **接线** | 走完整 `_room_apply_economy` → `_economy_ctx` 路径 | **回合号有没有真的传进去** |

期望值那张表是曲线的**独立副本**，故意不从 `ShopRoll` 读 ——
否则改了曲线检查跟着一起改，等于没测。

最后一层是这条检查里最有价值的部分。它用 `_new_room()` + `_room_apply_economy()`
真跑房间：`round_index=1` 断言摇不出三档，`round_index=21` 断言摇得出；
再单独跑 `_room_begin_next_prep()` 从第 9 轮进第 10 轮，断言能摇出三档
（用旧回合号则恒为 0）。

#### 证伪（三次，每条断言单独验）

```
探针 A：服务端改回全表均匀随机
  FAIL [server_tier3_too_early] 回合 1 服务端刷出了 1468 个三档单位 —— 曲线在这一段应为 0%
  FAIL [server_share_off]       回合 1 tier1 占比 24.7%，期望 80%
  FAIL [server_share_off]       回合 1 tier3 占比 18.8%，期望 0%

探针 B：_economy_ctx 硬编码回合 1（回合号不传）
  FAIL [wiring_round_not_passed] 房间 round_index=21，1200 个商品里一个三档都没有

探针 C：_room_begin_next_prep 用自增前的旧回合号
  FAIL [next_prep_round_off_by_one] 从第 9 轮进入第 10 轮，800 个商品里一个三档都没有
```

实测到的 18.8% 与从数据表算出来的 6/32 = 18.75% 对得上。

#### 我自己在这条检查里写错的一处

第一版给房间塞了 999999 金币就开始连刷 300 次，结果两条接线断言都红：
`not_enough_gold`。原因是刷新价**翻倍**递增（10 → 20 → 40 …），
17 次就上百万。这不是产品的问题，是用例的问题 ——
这条用例测的是摇出来的东西，不是价格阶梯，所以改成每次迭代复位金币与次数。

记在这里是因为它和 4.5 那次同类：**检查红了先分清是产品坏了还是用例写错了**，
上次差点因此去"修"一个没坏的 `sanitize_board`。

#### 回归

16 项全过、零脚本错误：新增两条 + `prep_shop` / `prep_text_coverage` /
`prep_power_estimate` / `prep_power_format` / `tutorial_target` /
`prep_tree_snapshot`(305 节点不变) / `board_4x4_smoke` / `adversarial_client` /
`economy_settle` / `determinism` / `rate_limit` / `reconnect_backoff` /
`connection_health` / `client_log`。

`adversarial_client` 里的 `shop_offers_filled`、`server_rolls_shop`
本来就在跑服务端刷新路径，它们没变色说明这次改动没动坏那条链路。

### 第十步：服务端账本的合成规则是错的

第九步搜「服务端有没有第二份规则」时有两个命中，这是第二个。
这次三条规则里**错了两条**，而且方向都是对玩家有利的那一侧。

单一真相应当是：

```
GameState.STAR_UPGRADE_COPIES = {1: 2, 2: 3}   1星→2星 要 2 个，2星→3星 要 3 个
GameState.MAX_UNIT_STAR       = 3              三星封顶
```

服务端账本 `EconomyLedger` 里写的是：

```gdscript
const STAR_UPGRADE_COPIES := 2   # 两个同名同星合成一个高一星
```

一个**平坦的 2**，而且完全没有星级上限。

#### 这不是读代码读出来的，是先写检查跑出来的

规则类的问题最容易「看着像对的」，所以这次顺序反过来：
**先写 `merge_rule_parity_check`，在修之前跑，红了才算数。**

```
FAIL [merge_correct_count_rejected] 2 星升级要 3 个（客户端规则），服务端却拒了：bad_merge_count
FAIL [merge_short_count_accepted]   2 星升级只给了 2 个（要 3 个），服务端却放行了 —— 玩家能白捡一个单位
```

两个方向同时坏：

| | 客户端 | 服务端账本 |
| --- | --- | --- |
| 3 个二星升三星 | 合法 | **拒收**（`bad_merge_count`）—— 正常玩法做不了 |
| 2 个二星升三星 | 非法 | **放行** —— 白捡一个二星 |
| 3 个三星再合 | 非法（`star < MAX_UNIT_STAR`） | **放行，产出四星** |

#### 我自己在这条检查里写的第二个假绿

星级封顶那条用例第一版是绿的，但**它绿得没有道理**：满星那次合成确实被拒了，
拒它的是旧账本「必须正好 2 个」的份数检查（我给了 3 个），根本不是封顶。
份数一修好，这条就会变红 —— 也就是说它当时什么也没守住。

改成同时断言**拒绝的理由**必须是 `star_capped`。
后面证伪时探针 B（拿掉封顶）抓到了「3 个 3 星合成了 4 星」，
正是原来那版漏掉的情况。

> 这是这份文档里第二次记「只断言失败、不断言失败原因」的坑
> （第一次是 4.5 的 `_h.expect(true, ...)`）。
> **一条断言必须能说清它是被谁挡下的，否则换个原因挡下它就静默失效了。**

#### 改法：规则表移到 GameConstants

`EconomyLedger` 头部有一条明确的设计约束：

> 纯函数、零全局。不读 `GameState`、不读 `TreasureService.has_set()`……
> 服务端一个进程要同时跑几百个房间，任何全局状态都会串房间。

所以不能像第八步那样直接委托。规则表改放 `scripts/core/GameConstants.gd` ——
纯常量脚本，没有任何可变状态，不涉及房间状态，与那条约束不冲突
（那条防的是 `GameState`/`TreasureService` 这类带房间状态的单例）。

* `GameConstants.STAR_UPGRADE_COPIES` + `copies_to_upgrade()` = 唯一定义
* `GameState.STAR_UPGRADE_COPIES` / `MAX_UNIT_STAR` 改为**再导出**，
  `copies_to_upgrade()` 改为委托 —— 客户端 6 处调用点一个都不用动
* `EconomyLedger._merge()` 改为按目标星级取份数，并补上满星拒收

份数检查必须**挪到读出 `first` 之后**：份数是由目标单位的星级决定的，
判之前得先知道要合的是几星。顺带补一条空数组直接拒 ——
否则下面 `first` 取不到东西。

`copies_to_upgrade()` 对表外星级返回 3（保守取大）。
返回小值意味着「更容易升星」，而这是漏配时最不该发生的方向。

#### 证伪（三次，每条规则单独验）

```
A 份数改回写死的 2      FAIL merge_correct_count_rejected / merge_short_count_accepted
B 拿掉星级封顶          FAIL star_cap_not_enforced（3 个 3 星合成了 4 星）
                        FAIL star_cap_wrong_reason（理由是 bad_merge_count，不是 star_capped）
C cost_basis 改成取最大  FAIL cost_basis_not_summed（应为 14，实际 7）
```

C 那条守的是退款：出售退的是「这一坨总共花了多少」的一半，
`cost_basis` 加错了就是退款金额错，而且不会有任何报错。

#### 回归

18 项全过、零脚本错误。`GameState` 与 `GameConstants` 是核心文件，
所以这次把战斗侧也带上跑了：`determinism`(111) /
`battle_presentation_event`(9787) / `persist_check` / `channel_check` /
`handshake_check` / `reconnect_check` 全绿。

`adversarial_client` 里那四条合成断言（`merge_ok` / `merge_star2` /
`merge_cost_basis_summed` / `merge_self_denied`）用的都是一星单位、2 个 uid，
新规则下依然合法，所以没变色 —— 这次改动只收紧了二星以上和满星那两段。

### 第十一步：小灵的全额退款 —— 两个 ×0.5 撞在一起

第十步收尾时顺着 `ECONOMY_ACTIONS` 往下查出售退款，撞上这一步。
和前三步不同：**这条今天是活的**，不在任何开关后面。

#### 现象

`undead_small`（小灵）在商店卖 5 金，卖掉退 5 金 —— **全额退款**。
带上折扣宝物买入，就变成净赚。

| 买入方式 | 买入价 | 1星退款 | 净利 | 合成 2 星后 |
| --- | ---: | ---: | ---: | ---: |
| 无宝物 | 5 | 5 | ±0（可零成本换阵容）| ±0 |
| `money_discount` ×0.8 | 4 | 5 | **+1** | **+2** |
| `clearance` 联动 ×0.6 | 3 | 5 | **+2** | **+4** |

#### 成因：两个不相干的 0.5

```
商店价  = cost × shop_cost_multiplier   小灵：10 × 0.5 = 5
1星退款 = cost × 星级 × 0.5             小灵：10 ×  1  × 0.5 = 5
```

退款读的是**打折前的 `cost`（10）**，购买读的是**打折后的值（5）**。
当乘数恰好是 `0.5` 时，「退一半」的 ×0.5 与乘数的 ×0.5 互相抵消，
两个式子变成同一个 —— 退款必然等于售价。

**全表只有小灵带这个字段**，所以只有它中招。纯粹是数据凑巧把洞放到最大。

#### 这条不是新写出来的，是文档定义就漏了

`docs/金币系统.md` 里两张表用的不是同一个 cost：

| 表 | 用的是 |
| --- | --- |
| 购买价格 | `ceil(cost × shop_cost_multiplier)` ← 算了乘数 |
| 出售返还 | `floor(基础cost × 星级 × 0.5)` ← **没算乘数** |

而且第 313 行的示例表白纸黑字写着 `cost 10 → 1星 → 退 5`。
**照文档实现就会得到这个洞。**

更早之前 `docs/P1经济账本RFC.md` 第 4.1 节已经把这件事完整整理过，
归在「⛔ 需要你拍板」下面，数字与本次实测完全一致。
服务端账本当时**修了**（改按 `cost_basis` 退），**客户端没有一起改** ——
而账本锁在默认关闭的开关后面，所以线上跑的一直是有洞的那份。

> 这一步的教训与第九步同类：`docs/联机审计与整改方案.md` 里写着
> 「套利洞已实测关闭」，对抗台的 `no_arbitrage_profit` 也是绿的 ——
> **但那只覆盖服务端**。一条只测了一半系统的断言，读起来和测全了一模一样。

#### 先写检查，红了再改

`tools/sell_refund_check.tscn` 断言的是**性质**，不绑定公式：

| 断言 | 内容 |
| --- | --- |
| `sell_for_profit` | 退款 > 实付 —— 硬失败 |
| `sell_free_reroll` | 退款 == 实付 —— 硬失败（可零成本反复换阵容）|
| `refund_mismatch` | 客户端退款 != 服务端账本退款 —— 分叉登记 |

第一版我把「无套利」和「退款率恰好 50%」写成了同一条断言，
于是 `god_priest` 实付 16 退 10（**亏 6**）也被报成失败。
亏本卖出不是漏洞，只是退款率偏高。拆成两条之后数字才说的是它真正的意思。

#### 改了两处，作用完全不同

**1. 代码（堵洞）** —— `EconomyLedger` 新增 `base_unit_cost()`：
`cost` 经过 `shop_cost_multiplier`，但**不含**玩家身上的折扣宝物。
`unit_cost()` 与客户端 `_sell_refund_for_cell()` 都读它。

没有在退款那里重抄一遍乘数逻辑 —— **「同一套算钱逻辑存两份」正是这个洞的成因**。

**2. 数据（定价）** —— 删掉 `undead_small` 的 `shop_cost_multiplier: 0.5`，
售价由 5 变为 **10**，正好是普通棋子（20）的一半。
删除后数据表里**已无任何棋子带乘数**，`cost` 与售价在全表恒等。

顺带修掉两处一直存在的不一致（都是因为它们读原始 `cost`）：

| 位置 | 之前 | 现在 |
| --- | --- | --- |
| 图鉴 `CodexScreen.gd:322` | 显示 10，商店实际卖 5 | 显示 10 = 售价 |
| PVE 敌方预算 `BattleSimShared.gd:435` | 按 10 记账，实际值 5 | 按 10 记账 = 售价 |

#### 证伪 —— 两个探针分清了「谁在堵洞」

```
A 把乘数加回数据表（代码改动保留）
  → PASS。代码那一改**单独**就足以堵住洞。

B 乘数加回 + 退款改回读打折前的 cost
  → FAIL [sell_free_reroll] undead_small 1星：花 5 退 5
    FAIL [sell_for_profit]  undead_small 1星（money_discount）：花 4 退 5 净赚 1
```

探针 A 是这一步最有价值的一次验证：它证明**堵洞的是代码，不是数据**。
数据那一改是独立的定价决策，即使将来又加带乘数的棋子，洞也不会回来。

#### 没做的部分，明确登记

客户端退款仍**不看**玩家的折扣宝物，也不按凑齐该星级实际用掉的份数，
所以与服务端账本对不上 **64/96 组**，退款率最高一组 83%
（clearance 下花 12 退 10）。

**这不是漏洞** —— 288 种组合全部亏本卖出。它是数值口径问题。
要严格对齐需要给客户端棋子记 `cost_basis`，那会改存档格式、
并让三星退款翻倍（30→60 / 45→90 / 75→150），属于 RFC 4.1 待拍板的数值改动。

按 `refund_mismatch` 登记进 `tools/check_allowlist.json`，到期日 `2026-09-30`。
⚠️ **在它落地之前不能翻 `economy_ledger_authoritative`** ——
一翻，64 组退款金额会当场变化。

#### 回归

17 项全过、零脚本错误。数据改动会影响 PVE 敌方阵容，所以带上了战斗侧：
`determinism`(111) / `battle_presentation_event`(9787) / `pve_round_monster_probe` /
`persist_check` / `adversarial_client` / `economy_settle` 全绿。

### 仍未做

7 层继承本身还在，6727 行仍然合成一个类。剩下那 85 个纯 helper（约 1100 行）
可以照这一步继续抽，尤其是 `PrepDetails` 里的文本/战力估算那一簇。
而 README 说的自治组合节点（`Control` 子类）**在当前结构下做不出来** ——
上面的依赖统计已经说明，行为层离不开宿主。要做只能先把宿主拆薄，
那是比这五步加起来更大的改动。

### 一个反复踩到的 GDScript 坑

服务实例声明为 `var _x: RefCounted`，于是 `var y := _x.some_method()` 会报
`Cannot infer the type of "y" variable`。而**解析失败会让 headless 进程静默挂死**
（实测 exit=124 超时），不是干脆报错退出。调用抽出去的服务方法时，
返回值一律显式标类型：`var lines: PackedStringArray = _client_log.take_pending_lines()`。

## 4.7 ⚠️ 备份目录里的重复 class_name 会毒化类缓存

**这是 PR2 期间撞出来的既有地雷，不是被谁改坏的，但后果很重。**

`D3~D6_prechange_backup_20260819/` 四个备份目录里有 10 个带 `class_name` 的 `.gd`，
与活代码重名（`BattlePresentationDirector` 5 份、`LegacyBattleVfxAdapter` 3 份，
还有 `BattleSimulator` / `DamageService` / `VFXQualityBudget`）。

重建类缓存时，全局类名可能被绑到**备份里的旧版本**上。实测抓到的状态：

```
"DamageService"    -> res://D4_prechange_backup_20260819/scripts/battle/DamageService.gd
"BattleSimulator"  -> res://D4_prechange_backup_20260819/scripts/battle/BattleSimulator.gd
"VFXQualityBudget" -> res://D5_prechange_backup_20260819/effects/vfx3d/core/VFXQualityBudget.gd
```

于是 D4 新增的 `DamageService.emit_attack_start()` 在活代码里"找不到"，整个战斗栈报错：

```
Parse Error: Static function "emit_attack_start()" not found in base "DamageService"
Invalid call. Nonexistent function 'compute_team_replay' in base 'GDScript'
```

**症状有多隐蔽**：`battle_presentation_director_check` 并没有崩，只是从 **82 项掉到 15 项**
——大部分断言根本没跑到，而摘要行仍然是 `status=PASS`。`reconnect_check` 则直接 exit=1。
如果只看"退出码 0"就放行，等于用一份跑了 15 项的检查冒充跑了 82 项。

**修法**：给四个备份目录各加一个 `.gdignore`。Godot 会整个跳过该目录，
文件仍留在 git 里作为证据，但不参与导入、不注册 class_name。修后重建缓存，
三个类名都指回活代码，全部检查恢复正常。

**这颗地雷会打到服务器包**：`make_server_zip.ps1` 把
`.godot/global_script_class_cache.cfg` 一起打包。如果在缓存被毒化的状态下打包，
服务器会在解析阶段直接挂。这也是新增服务一律**不用 `class_name`、只用 `preload`** 的原因。

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

> **⚠️ 以下三段是 2026-08-19 的历史记录，其中的操作建议已作废。**
> 自 2026-09-03（V2 收尾 G2）起 `asset_manifest_check` **默认只读**，
> 普通运行不会改写任何基准，不需要再 `git checkout --` 还原。
> 保留原文是因为它记录了当时的实测数字与那个结构漏洞的成因。

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

> **✅ 结论更正（2026-09-03，V2 收尾 G2）：上面这个漏洞已修。**
> 上面的历史测量与描述保留，但「尚未修」和「跑完请用 `git checkout --` 还原」
> 两句已经作废 —— 现在普通运行根本不会改写基准。详见下节。

### 资产清单：默认只读，更新基准要显式（V2 收尾 G2，2026-09-03）

实测发现的症状比上面记的更具体：字母序上 `asset_delivery_check` 排在
`asset_manifest_check` **前面**，所以任何资产改动都会让**第一次**全量红、
**第二次**绿 —— delivery 比对的是改动前的清单，紧随其后的 manifest 把清单
重新生成，下一次就一致了。

**自愈的假红会训练人「再跑一遍就好」，长期比假绿还危险** ——
假绿至少没人看见，自愈的红是被看见之后学会忽略。

新合同分三层：

| 层 | 行为 |
| --- | --- |
| `asset_manifest_check` 默认 | **只读**。照常扫引用/缺失/依赖失败，打印候选 inventory SHA 与条目数，**一个字节都不写** |
| `--update-manifest` | 唯一允许写基准的路径。写之前仍走 `failure_count() == 0` 守卫；打印「将更新哪些文件、旧/新 inventory SHA、条目数」 |
| `run_check.ps1` | 套件前后取两份基准的 SHA-256。**普通运行若改写了它们，整套判失败并点名文件**（`baseline_rewritten=true`，独立于 `failed`） |

显式入口（会显示 `git diff --stat`，**不自动提交** —— 移动基准是决定，不是副作用）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/update_asset_manifest.ps1
```

`asset_delivery_check` 不需要改：普通套件不再改写 `assets.manifest.json`，
它读到的永远是进入本次套件时已有的受信任清单，顺序依赖自然消失。
（它本来就支持 `--manifest=` 指定别的清单，那条路保留。）

#### 验证证据

- 连跑两次普通 `-All`：verdict 相同，两份基准 SHA 均不变
- 可恢复夹具（给 `flare_star.png` 追加 1 字节）后连跑两次
  `-Name asset_delivery,asset_manifest`：**两次 `asset_delivery` 都 FAIL**，
  `baseline_rewritten=false`，不自愈
- 变异（强制 `asset_manifest_check` 每次都写）：普通运行 `failed=0` 但
  `baseline_rewritten=true`、退出码 1、点名两个文件 —— 守卫是独立判决路径
- 缺失夹具（把被引用的资产挪走）下跑显式更新：打印 `manifest_untrusted=true`，
  拒绝覆盖，两份基准 SHA 逐字未变

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

## 9. D2 重做：从「拆不动」到真的拆

第十一步之后重新对着 README 的 D2 验收清单逐条核对，结论是**没完成**：
10 个检查点里 2 条完成、1 条部分、7 条没做，而且继承链总行数是**涨的**
（6727 → 6853，因为加了大量说明注释）。

更要紧的是，我之前给出的「做不出来」的判断是**测错了**。

### 前提修正：耦合远比我说的薄

第五步我写过「行为层离不开宿主，README 说的自治组合节点在当前结构下做不出来」。
那个结论来自只数**调用次数**、不分类。重新按类别量一遍：

| 面板 | 函数 | 代码行 | 读写宿主成员 | 调用宿主函数 |
| --- | ---: | ---: | ---: | ---: |
| ShopPanel | 18 | 595 | 14 | 20 |
| BoardHud | 12 | 150 | 11 | 13 |
| TreasurePanel | 15 | 334 | 5 | 13 |
| SynergyPanel | 5 | 142 | 3 | 4 |
| StatsPanel | 6 | 115 | 2 | 10 |

把这些依赖拆开看：

* **跨面板共享的成员只有 5 个** —— `_shop` / `_board` / `_selected_board` /
  `_selected_bench` / `_owned_treasure_box`。其余全是面板自己的。
* **被 ≥2 个面板调用的宿主函数只有 7 个，而且 7 个全都不碰成员变量。**
  它们不是「面板依赖宿主」，只是「大家都要用的工具恰好放在宿主身上」。
* 只被 1 个面板用的 42 个函数里，28 个也不碰成员 —— 跟着面板一起搬即可。

> 教训与第九步同类：**统计口径决定结论**。
> 数「调用了多少次宿主」得到「拆不动」；
> 数「这些调用分别是什么性质」得到「大部分根本不是耦合」。

### 前三步

| 步 | 内容 | 继承链行数 |
| --- | --- | ---: |
| — | 起点 | 6853 |
| 1 | `PrepWidgets.gd` 通用 UI 工具箱（13 个函数，69 个调用点） | 6677 |
| 2 | `PrepRules.gd` 规则查询（11 个函数，33 个调用点） | 6552 |
| 3 | `PrepDetailOverlay.gd` 详情浮层组件（有状态） | 6470 |

`PrepWidgets` / `PrepRules` 是纯静态工具；`PrepDetailOverlay` 是第一个
**自带状态的组件** —— 它持有弹窗节点、文本节点，以及「等待松手」的关闭时序。

### ⚠️ 第一步查出：`prep_tree_snapshot` 是我造的假绿

详见第 4 节「安全网：节点树快照」下的更正块。要点：
第一版**从不比对**，`checked=305` 只是节点计数；
第八到十一步「节点树无变化」这句话工具一次都没验证过。
已改为对着 `tools/prep_tree_baseline.txt` 逐行比对并报首处差异。

### ⚠️ 第二步险些造成事故：`has_method` 会把删除变成静默失效

`_can_drop_on_board` 搬进 `PrepRules` 后，`PrepShared` 的内部类里还留着：

```gdscript
screen.has_method("_can_drop_on_board") and screen._can_drop_on_board(...)
```

方法没了 → `has_method` 返回 **false** → **拖放静默全部失效**，编译期零报错。
`board_4x4_smoke` 抓到了（SCRIPT ERROR + exit 124）。
已改成内部类直调 `PrepRules` —— 它本来就不需要问宿主。

### 新增检查 `dynamic_call`（221 项）

同一个坑踩了两次（上一次是 TutorialMode 漏改导致进教学关崩溃），值得一条守门的。

规则：凡按名字调用的方法（`.call("x")` / `has_method("x")` / `Callable(self,"x")`），
那个名字必须在全仓有定义；另加一个**棘轮**——接收者无法静态确定的调用数
当前 213，只许降不许升。

**它当场查出一个真实的悬空调用**：`human_mage_skill_preview.gd` 守的是
`set_action`，而 `UnitActionModel` 的 API 是 `play_idle/play_attack/play_run` ——
这个方法**全仓从不存在**，技能预览里那两处动画从来没播过。已修。

写这条检查时我自己造了两个误报，都记进注释了：

| 误报 | 原因 |
| --- | --- |
| `play_idle` 等被判「不存在」 | 扫描根目录漏了 `res://assets`，模型包装脚本就在那 |
| `play_` 被判「不存在」 | `node.call("play_" + action)` 是拼接，只能拿到前缀 |

棘轮随后又立了一功：我写 `prep_detail_overlay_check` 时用了 15 处
`ov.call("show_text", ...)`，棘轮从 213 涨到 230 当场报警。
正确做法不是调高上限，是**改成静态调用**（用 preload 常量做类型标注），
改完回到 213。检查工具自己也不该制造编译器管不到的调用。

### 新增检查 `prep_detail_overlay`（18 项）

抽出组件之前，详情浮层**一条检查都没有**。而它失效的方式全是静默的：

| 断言 | 抓什么 |
| --- | --- |
| `overlay_not_bound` | 忘了 `bind()` → 所有 `show_*` 直接 return，长按没反应 |
| `gold_flag_not_reset` | 标志没复位 → 金币一变就把详情内容覆盖成利息文本 |
| `long_press_no_motion` | 漏连 `gui_input` → 拖拽不取消长按，拖着拖着弹出说明框 |

三条证伪各自独立命中。

### 顺带更正一个我一直说错的事实

我多次说「全文件纯 CRLF」。实测全仓 272 个 `.gd`：
**纯 CRLF 153 个、纯 LF 116 个、混合 3 个**（`assets/` 下基本是 LF）。
「纯 CRLF」只对我动过的 `scenes` / `scripts` / `tools` / `docs` 成立，不是仓库整体。

### 步骤 3′：ShopPanel 成为真正的自治面板

原计划的步骤 3 是「给功能容器命名 + 挂面板脚本，节点树零变动」。
查到商店的实际结构后这个方案不成立：**商店的控件分在两处根** ——
顶层的 `ShopSideControls`（15 个节点）与主布局深处的 `SellDropPanel`（50 个节点），
没有任何单一容器能同时拥有它们。

> ⚠️ 我当时换了方案却**没有说**，还继续用「第三步」这个编号汇报（实际做的是详情浮层）。
> 换方案要先讲清楚，不能换完了接着用同一个编号 —— 这跟 D2 本身被悄悄换掉是同一个毛病。

拆成两个小步做，因为一次同时动 565 行代码和 19 个字段，出问题时分不清是搬错了还是改错了。

#### 3′a — 状态换家（节点树 +1）

`ShopPanel` 从 `PrepShared` 的内部类变成 `scenes/prep/panels/ShopPanel.gd`（`extends Control`），
在 `_build()` 末尾 `add_child` 进树。**行为一行不动。**

先要解决一个障碍：面板的字段里有 `panel: SellDropPanel` 和 `buttons: Array[DragButton]`，
而这两个类是 `PrepShared` 的内部类，独立成文件就引用不到；
退成基类又会丢掉静态检查（`btn.drag_payload` 直接编译不过）。
所以先把它们也抽成独立文件（`PrepDragButton.gd` / `PrepSellDropPanel.gd`）——
两个类零反向依赖，只认识 `Control`。

验证过一个不确定性：`class BoardCellButton: extends DragButton` 里，
**用 preload 常量当基类是可行的**。

节点加在 `_build()` **末尾**而不是开头：加在前面会把所有兄弟节点的次序整体后移，
而树顺序影响输入拾取。重建基线前用集合比对验过：

```
新增 1 行: /PrepScreen/ShopPanel [Control] z=0 vis=true mouse=2
缺失 0 行
去掉新增节点后，其余 303 个节点的顺序与属性与旧基线完全一致 ✓
```

顺手把这个能力做进了 `prep_tree_snapshot`：之前逐行比对在中间插一个节点会报
「302 行不同」，噪声淹没信息。现在**集合比对**回答「多了谁少了谁」，
**共有序列比对**回答「谁挪了位置」，两者分开报。基线用 `-- --update` 显式重建（304 节点）。

#### 3′b — 行为搬家 + 信号

14 个函数（565 行）、18 个常量、6 个成员搬进面板。
面板**不认识 PrepScreen**，需要的只有三样，由 `setup()` 注入：

| 注入项 | 为什么 |
| --- | --- |
| `host` | 少数控件仍要挂在宿主节点下（这一步刻意不动节点树） |
| `overlay` | 详情浮层组件，四个面板共用 |
| `hover_handler` | 立绘卡片悬停动画，宿主与其它面板共用同一份 |

所有会改变游戏状态的操作改为**信号**：

```gdscript
signal card_selected(index)       # 选中一张卡
signal buy_requested(index)       # 请求买入（找空位/扣钱/合成归宿主）
signal detail_requested(index)    # 长按看详情
signal picker_toggled(is_open)    # 商店开合（关别的弹窗、调待命格输入）
signal refresh_requested          # 请求刷新（燃烧特效与扣钱归宿主）
signal message_requested(text)    # 「钱不够」「待命区满」
signal state_changed              # 需要整屏刷新
```

划分原则：**面板管「看」与「选」，宿主管「交易」。**
买入要动金币、待命区和联机同步；刷新要扣钱并放燃烧特效；
关别的弹窗要碰别的面板 —— 这些都不该由商店伸手去做。

#### 我在这一步踩的两个坑

**① 搬走的是抽象桩，不是真实现**

`PrepShared` 里有 6 个 `func _refresh_shop(): pass` 这样的桩。
我的抽取脚本按继承链顺序取第一个匹配，于是搬走了 3 行的桩，
88 行的真实现还留在 `PrepUI`。改成：收集**所有**定义、取行数最多的作为实现、
其余（桩）一并删除。

**② `setup()` 的调用位置错了**

第一版把 `setup()` 和 `add_child()` 一起放在 `_build()` 末尾，
但 `build_*` 在中间就跑了 —— 构建期 `overlay` 与 `host` 都是 null，
表现是「长按详情静默失效」外加几条 `Cannot call method on a null value`。
拆开：`setup` 放开头（它不需要在树里），`add_child` 仍在末尾（保住节点次序）。

顺带发现一处统计疏漏：我用「函数体里是否出现」来判断常量是否只被商店用，
漏掉了 `PrepDetails` 里的 `PrepShopRaceIcon`（在一个不属于商店簇的函数里）。
补回 `PrepUI` 的 preload —— 两个文件各自声明依赖、指向同一个脚本，不是重复逻辑。

> 定位手段也记一笔：Godot 只报最外层的 "Could not resolve class"，
> 中间哪一层坏了看不出来。写了个临时探针逐个 `ResourceLoader.load` 继承链上的脚本，
> 第一个 `FAILED` 的就是元凶。用完即删。

#### 证伪暴露了一个检查缺口

探针 A（把 `card_selected.connect(...)` 注释掉）跑下来 **24 项照样全绿**。

信号没接上的后果是静默的：面板照常 emit，没人听，动作就是不发生 ——
不报错、不崩、界面看着正常。**只测「面板方法能调」证明不了「接线通了」。**

补了两条用例，分管两层：

| 断言 | 管什么 |
| --- | --- |
| `signal_not_connected` | 7 个信号都必须有接收者 |
| `board_selection_not_cleared` | 断言**实际效果**：选商店卡必须清掉棋盘/待命的选中 |

探针 C（处理函数只清棋盘、漏清待命）只违反第二条，证明两层各管各的。
`prep_shop` 从 24 项增至 34 项。

#### 数字

| | 起点 | 现在 |
| --- | ---: | ---: |
| 继承链总行数 | 6853 | **5788** |
| `PrepShared` 顶层成员 | 124 | **85** |
| `dynamic_call` 棘轮 | 213 | **204** |
| `ShopPanel.gd` | —— | 765 行 |

回归 16 项全绿、零脚本错误。

### 步骤 4′：其余四个面板

顺序按耦合从低到高：羁绊 → 战力统计 → 宝物 → 棋盘。
每个面板一步，每步跑一遍完整回归。

| 面板 | 行数 | 对外信号 |
| --- | ---: | --- |
| `SynergyPanel` | 258 | `altar_requested` / `gamble_requested` / `treasure_detail_requested` |
| `BattleStatsPanel` | 290 | **零** |
| `TreasureChoicePanel` | 395 | `pick_requested` / `claim_requested` / `net_signals_needed` / `state_changed` |
| `BoardHud` | 209 | `visuals_dirty` / `state_changed` |

`BattleStatsPanel` 一条信号都没有，是个有用的对照：
**需要信号的是「会改状态的动作」，纯显示不需要。**
它只读 `GameState` 与战报历史，算完排版显示，一个字节的状态都不改。

#### 为此写了一个可复用的搬运器

四个面板用同一套流程，所以把它写成了 `movepanel.js` + 每个面板一份 JSON 配置。
踩过的坑都固化进了搬运器：

| 坑 | 固化的规则 |
| --- | --- |
| `PrepShared` 里有抽象桩 | 收集**所有**定义，按「函数体是否只有 pass」判桩 |
| 多行常量（字典字面量） | 按括号配平消费到 `}` |
| `const X: T = ...` 带类型标注 | 匹配 `^const\s+NAME\b` 而不是 `const NAME ` |
| Callable 形式（不带括号）的函数名 | 改名时用 `(?![\w])` 而不是 `(?=\s*\()` |

> 判桩那条是被逼出来的：`_show_treasure_detail` 的真实现只有 2 行、桩也是 2 行，
> 最初「按行数取最大」会把桩搬走、把真实现删掉，**而且编译期未必报错**。

#### 途中修掉的四个真问题

**① `@export var` 逃过了正则**

`cell_size` / `board_cell_rest_line` 是编辑器可调参数。
搬进面板会丢掉 inspector 里的配置 —— 改成留在原处、`setup()` 时把当前值传进来。

**② 宝物浮层被重挂到零尺寸面板下**

面板节点是零尺寸的逻辑宿主，而浮层用 `PRESET_FULL_RECT` 锚定 ——
挂到零尺寸父节点上，锚点解算成 **0 大小，界面直接消失且不报错**。
节点树检查抓到了（多出 4 个节点而不是 1 个）。
规则：面板里的**顶层**控件一律 `host.add_child(...)`。

**③ 格子按钮的 `has_method` 又要静默失效**

`BoardCellButton` 通过 `screen.has_method("_set_board_drop_hover")` 调用，
方法一搬走 `has_method` 返回 false → **拖放高亮永远不亮，不报错**。
给按钮一个指向面板的引用，改成静态调用。

**④ 父类看不见子类方法**

`_connect_treasure_signals` 定义在 `PrepFlowController`（PrepUI 的**子类**），
而面板接线在 `PrepUI._build()` 里。那条连接挪到最派生的 `PrepScreen`。

#### 三条检查各自立功

| 检查 | 抓到什么 |
| --- | --- |
| `tutorial_target` | 5 处 `_prep.get("...")` 漏改（`_left_panel` / `_owned_treasure_box` / `_treasure_choice_row` / `_board` / `_selected_bench`）|
| `dynamic_call` | 11 处指向已搬走方法的按名调用（格子按钮 6 + smoke 工具 5）|
| `prep_tree_snapshot` | 每次确认差异正好是「多一个面板节点」|

为了让面板能保住静态类型，还先把四个内部类搬成了独立文件：
`PrepDragButton` / `PrepSellDropPanel` / `PrepBoardCellButton` /
`PrepBenchCellButton` / `PrepRelationProgressOverlay`。
验证过一个不确定性：**用 preload 常量当内部类的基类是可行的**
（`class BoardCellButton: extends DragButton`）。

---

### 步骤 5′：每个面板一个场景

五个面板各建一个 `.tscn`，宿主改为 `Scene.instantiate()` 而不是 `Script.new()` ——
这才是 Godot 里「组合节点」的标准形态。

保留两个常量各司其职：`XxxScript` 用于类型标注（保住静态检查），
`XxxScene` 用于实例化。

#### 新增检查 `panel_scene`（43 项）

**它不实例化 `PrepScreen`。** 逐个 load 五个面板场景、单独放进树、断言能立起来。

这正是「自治组合节点」与「继承链上的一层」的分界：
继承链上的一层没法单独加载 —— 要碰商店就得把整个 6853 行的类拉起来。

| 断言 | 抓什么 |
| --- | --- |
| 裸状态进树不崩 | 面板在 `_ready` 里偷偷依赖宿主 |
| 根节点是 Control 且挂了脚本 | `.tscn` 与脚本脱钩 |
| 对外信号齐全 | 信号被删/改名 → 宿主 connect 连不上，动作静默不发生 |
| 纯显示面板**零信号** | 顺手加了没人接的信号 |

依赖注入的东西（`host` / `overlay` / `hover_handler`）在这里一律不给 ——
**面板必须能在裸状态下安全存在。**

#### 写这条时我造了一个误报

第一版判「自定义信号」的办法是：从 `get_signal_list()` 里减去一份**引擎信号白名单**。
名单漏了一个 Control 信号，`BattleStatsPanel` 当场误报。

改成**读脚本源码里的 `signal` 声明** —— 维护引擎白名单注定会漏，读源码是确定的。

三条证伪：删一条信号 → `signal_missing`；场景不挂脚本 → `script_missing`；
纯显示面板加信号 → `unexpected_signal`。

---

### 步骤 6′：删掉一整层

#### 28 个死转发

`PrepDetails` 里 15 个函数是 2–3 行的转发（`return UnitDetailFormat.xxx(...)`），
五个面板抽走后**全部零调用点**；`PrepShared` 里还有 13 个配对的抽象桩。一起删。

> 这批死代码不是本来就有的，是**面板抽取的副产品** ——
> 面板现在直接调 `UnitDetailFormat` / `PrepPowerFormat` / `PrepPowerEstimate`，
> 中间那层转发就没人走了。抽完不回头清一遍，它们会一直挂在那里看着像还在用。

#### `PrepDetails` 整层删除

从 769 行缩到只剩 6 个函数（三个「点某处 → 弹详情」+ 三个文案格式化），
并进 `PrepBoardController`，文件删除。**继承链 7 层 → 6 层。**

#### 26 个抽象桩

`PrepShared` 原本有 44 个只写 `pass` 的桩 ——
它们是给内部类与基类代码「按名字调用子类方法」用的占位。
五个面板 + 四个内部类搬走之后，26 个已经没有任何调用点。

做法是**先全删、让编译器点名**：删掉 44 个，编译器报出 18 个仍被调用的，补回。

> 剩下的 18 个本身就是**继承链还没拆干净的量度**。
> 每少一个，就说明又有一块行为不再需要「父类声明、子类实现」这种绕法。
> 这个数字比行数更能说明问题：行数会因为注释增减而波动，桩的数量不会。

`PrepShared` 从 860 → **352 行**，内部类 9 个 → **2 个**（只剩两个调试覆盖层）。

---

### D2 最终账

| | 起点 | 现在 |
| --- | ---: | ---: |
| 继承链 | 6853 行 / **7 层** | 4524 行 / **6 层** |
| `PrepShared` | 860 行 / 124 成员 / 9 内部类 | 352 行 / 67 成员 / **2 内部类** |
| 抽象桩 | 44 | **18** |
| 独立面板 | 0 | **5 个场景**，1917 行，16 条信号 |
| 独立组件 / 模块 | 0 | **8 个**，796 行 |
| `dynamic_call` 棘轮 | 213 | **189** |

本轮新增检查 12 条：`prep_tree_snapshot`（改造为真比对）/ `prep_shop` /
`prep_text_coverage` / `prep_power_format` / `prep_power_estimate` /
`tutorial_target` / `shop_price_parity` / `shop_roll_parity` /
`merge_rule_parity` / `sell_refund` / `dynamic_call` / `prep_detail_overlay` /
`panel_scene`。

18 项回归全绿（含战斗与联机侧），零脚本错误。

### README D2 验收对照（全部达成）

| 验收点 | 状态 |
| --- | --- |
| `ShopPanel` | ✅ 独立场景，7 条信号 |
| `BoardHud` | ✅ 独立场景，2 条信号 |
| `TreasureChoicePanel` | ✅ 独立场景，4 条信号 |
| `SynergyPanel` | ✅ 独立场景，3 条信号 |
| `BattleStatsPanel` | ✅ 独立场景，纯显示（零信号是断言，不是遗漏）|
| 用明确的输入事件与 `PrepFlowController` 通信 | ✅ 共 16 条信号 |
| `PrepDetails` 最小加载测试 | ✅ 多条检查实例化 `PrepScreen.tscn` |
| 从继承链移除纯 UI helper、优先组合节点 | ✅ 移出 2329 行，7 层减到 6 层 |
| 商店/拖拽/宝物/详情/战力推荐可独立场景加载 | ✅ `panel_scene` 43 项 |
| 4×4 smoke 失败非零 + 断言覆盖 | ✅ 62 项 |

### 仍未做（D2 之外）

* 继承链还剩 6 层、4524 行。`PrepUI`(1614) 与 `PrepBoardModels`(1176) 仍是两个大块；
  前者是布局构建、后者是 3D 模型层，都不属于 README D2 的范围。
* `PrepShared` 里还有 18 个抽象桩 —— 见步骤 6′，那是继承链未拆净的直接量度。
* 面板的可见控件仍挂在宿主节点下（`host.add_child`），面板节点本身是零尺寸的逻辑宿主。
  让面板真正拥有自己的子树需要重排布局锚点，是独立的一步，风险与收益都要单独评估。

---

## 2026-08-31：隐藏动作动画活动门禁

`battle_animation_activity` 用一个包含 idle / attack / run 三个动作分支的包装模型，按
idle → attack → run → idle 走正式 `BattleRenderer._play_model_action_method()` 路径。每次切换都断言：

- 当前动作元数据正确；
- 当前可见分支的内部 `AnimationPlayer` 正在播放；
- 完全隐藏分支的内部 `AnimationPlayer` 已暂停；
- 包装场景的代理播放器仍保持原合同；
- 隐藏播放数为 0。

命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_check.ps1 battle_animation_activity
```

当前结果为 29/29 PASS。反向变异验证中临时移除
`_pause_hidden_model_animation_players(action_node)`，同一门禁变为 12 项失败且进程退出码为 1；恢复调用后重新全绿。

真机证据位于
`C:\Users\Leno\Documents\Glory prep screen\android_qa_20260831_hidden_animation`：Round 20
战斗就绪后的 46/46 个皮肤采样均为 `hidden_play=0`，平均 FPS 从 13.96 提升到 16.20；
回合 1/5/20/21 的六项 digest 均与桌面逐字段一致，设备日志 0 Godot ERROR。

---

## 2026-09-01：输入压力与 Modal 生命周期门禁

`input_stress` 与 `modal_lifecycle` 分别负责两层不同的合同：前者检查输入如何到达控件、
一次物理点击是否只处理一次、所有拒绝是否有 reason；后者实例化真实 MainMenu / PrepScreen，
检查页面与弹窗重复进入退出后有没有节点、信号、Timer、Tween 或透明 STOP 层残留。

本轮修复了两条由门禁直接复现的生产缺陷：

- `ModalStack` 不再保存 owner 的 Object 引用，只保存 `owner_id`；owner 被释放后按实例 id
  自动关闭模态，避免给强类型 Object 赋失效引用时抛错、中断 `_process()`。
- `DialogService` 监听 `ModalStack.modal_closed`；backdrop、Back、owner 释放和 `close_all`
  都会清掉 `_pending`，返回 `dismissed`，且与 confirmed/cancelled 路径互斥、只结算一次。

命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_check.ps1 -Name input_stress,modal_lifecycle,ui_component,prep_battle_loading,issue_report
```

未污染的直接回归结果：`input_stress` 410/410、`modal_lifecycle` 235/235、
`ui_component` 95/95、`prep_battle_loading` 50/50、`issue_report` 47/47，合计 837 项断言、
0 failure、0 stale、0 运行中源文件修改。完整套件仍只有既有 Flame Claw 源资产阻塞：
三个动作槽复用同一个无内部动画、无贴图的 FBX，导致 `model_material_integrity` 对三个
动作分支各报 1 项白模失败；该美术阻塞与本轮 UI 服务修复无关。

## 2026-09-03：返回键全页面矩阵与手动重连（V3 P0-05 / P0-09）

### `tutorial_checkpoint` 162 → 169：Esc 与返回路由

两个缺口，都是「代码看着对、行为不对」那一类：

- 桌面 Esc 完全没接。`ui_cancel` 在整个仓里只出现在两处注释中，实际只有 Android 的
  `NOTIFICATION_WM_GO_BACK_REQUEST` 走返回逻辑。现在 `Main._unhandled_input()` 判
  `ui_cancel` 之后直接调 `_on_back_requested()` —— 只接输入、不复制逻辑。
- 返回键只覆盖了备战页。11 个顶层页面里，设置 / 宠物 / 图鉴 / 组队大厅 / 自测这 5 个都
  有 `back_requested` 接好的返回路由，但那**只有页面自己的返回按钮**会发。Android Back
  落到第 2 级只问 `PrepScreen`，其余页面直接掉到「再按一次退出」—— 玩家在设置页按返回
  会看到退出提示。

阶梯现在是：Modal → 页内面板 → 页面出口 → 二次确认退出 → 系统退出。

矩阵断言断的是**不变式**而不是页面名单：凡是接了 `back_requested` 的 `_show_*`，同一个
函数体里必须登记 `_page_back_route`。点名单的写法在加新页面时会静默漏掉，而漏掉正是这条
缺陷本身的成因。另配一条守卫，页面数掉到 5 以下就叫 —— 否则「没有缺路由的页面」在空集
上恒真，断言会变成摆设。

### 新增 `main_team_manual_reconnect_action`（35 项）

主菜单「游戏重连」此前是 `Main` 里唯一没走 `AsyncActionController` 的联网动作。三个后果：

1. 按下到 `NetworkService` 报 `RECONNECTING` 之间没有任何反馈
2. 连点会重复调 `begin_resume_from_disk()`，而它每次都 `reset()` 传输
3. 凭证不全时直接 `return` —— 而按钮的显隐判据是 `load_reconnect().is_empty()`，
   一条 token/address 为空、只剩 port 的记录会让按钮**可见但点了没反应**

第 3 条现在按「先受理再失败」处理：`fail(RECONNECT_NO_CREDENTIAL, retryable=false)` +
可见文案，玩家看得到原因，breadcrumb 里也留得下痕迹，而不是一片空白。

**门禁直接复现的生产缺陷**：`begin_resume_from_disk()` 第一行是 `reset()`，而 `reset()`
结尾自己会 `session_changed.emit()` —— 那一刻 `state` 还是 `OFFLINE`。所以监听方先收到
一次 `OFFLINE`、再收到 `RECONNECTING`。把 `OFFLINE` 一律当失败的话，动作在派发的同一帧
就被这声噪声结算掉：实测连点 100 次派发了 100 次，去重完全失效。判据改成「在途过才算
掉线」—— 只有观察到 `RECONNECTING`/`JOINING`/`READY` 之后的 `OFFLINE` 才是结果。

这条门禁会写真实的重连凭证文件，所以开头把主文件与 `.bak`/`.tmp` 三个变体整份快照成
字节、结尾逐字还原，并断言字节一致（只存主文件的话，`_read_with_fallback()` 会从残留的
兜底文件里把测试用的 token 读回来）。

夹具里有个值得记的坑：结算之后 `AsyncActionController` 会把动作放回 `idle`，所以断言
终态不能直接取状态序列的 `back()` —— 那样写取决于断言前隔了几帧，会时红时绿。取最后一个
**非 idle** 的状态才稳定。

命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_check.ps1 -Name tutorial_checkpoint,main_team_manual_reconnect_action,main_team_short_code_resume_action,modal_lifecycle
```

### `tutorial_checkpoint` 169 → 180：确认型步骤的断点延迟落盘（V3 P0-08）

V2 实测缺陷：按下「继续」或点热点推进之后强杀 app，回来还在按之前那一步。

根因是 `_on_continue_pressed()` 与 `_on_hotspot_pressed()` 推进了 `step` 却从不落盘 ——
断点要等玩家在备战页再做点什么触发 `sync()` 才跟上，而那两步之后玩家做的第一件事就是
开战，中间隔着整场战斗。

**先失败门禁**（对着修复前的代码跑出来的原文，落后幅度与 V2 记录一致）：

```
FAIL [checkpoint_lags_behind_step] 这些步骤推进后断点没有立刻跟上（强杀会退回上一步）：
["START_PVE_1(步号盘上=2 实际=3)", "START_PVE_2(步号盘上=4 实际=5)",
 "BOND_HINT(步号盘上=8 实际=9)", "VIEW_TREASURE(盘上=8)", "FORMATION_HP(盘上=8)",
 "START_BOSS(盘上=8)", "FORMATION_HP(步号盘上=15 实际=16)", "START_PVP(盘上=14)"]
```

盘上停在第 8 步，玩家已经走到 9/10/11/12 —— 这就是「落后 2～3 步」。

逐点补 `save_checkpoint()` 治不住：`step` 有 19 处直接赋值，下次加步骤照样会漏。改成
单一 mutator `_advance_to()`（赋值 + 同步步号 + 落盘），并由门禁断言除 `start()` /
`restore_checkpoint()` / mutator 自身之外**不得直接赋值 `step`**。18 处运行时赋值全部
改道，两处白名单保留原样。

顺带修一处排序：`_begin_fill_step()` 原本排在 `step = Step.FILL_7` 之后，而 `_advance_to()`
会立刻落盘 —— 晚一步就会把 `_fill_started=false` 记进 FILL_7 的断点，恢复时子状态机对不上。
同时把 `_fill_started` 纳入落盘节流签名：`BUY` 相位与 `bought=0` 在「还没开始」和「刚开始」
两种状态下取值相同，只看那两个会漏掉这次转变。

新增的三条行为断言里有一条**写错过一次**，值得记：最初写的是「每次推进后盘上的
棋子/宝藏/佣兵/金币要等于实时状态」。那不是不变式 —— 断点是推进那一刻的快照，之后玩家
还会继续买、继续摆，几帧后再比必然不等。改成真正的不变式：教程里宝藏、佣兵、累计采购
只增不减，断点里这三个数一旦回退就说明写进去的是过期快照。另配一条守卫，样本太少就叫。

另加一条：教程全程主存档必须一个字节都不动（`_write_now()` 第一行就是
`if GameState.tutorial_mode: return`，而主存档参与 replay / final-state SHA）。

### `bootstrap` 41 → 57：启动看门狗 3 / 8 / 15 秒（V3 P0-10）

迁移前 Bootstrap **完全没有看门狗**：线程载入卡住的话，玩家看到的是一张无限呼吸的启动
画面 —— 没有升级提示、没有解释、没有出路。

三级：3 秒说明仍在哪一步、8 秒补一句为什么慢、15 秒摆出重试/退出。三级都**不碰载入本身**：
15 秒之后仍然不进 `Phase.FAILED`，线程载入继续跑，随时可能完成，那时 `_finish_loading()`
会照常切场景，玩家自己就走出去了。主线程强杀只会把一次「慢」变成一次「坏」，而且丢掉
本来能自己恢复的那条路。

计时由**进度**驱动而不只是阶段：进度在动就重置。慢不等于坏 —— 冷启动第一次解压资源本来
就慢，那种情况下弹「启动失败」比不弹更糟。

两个实现细节各踩了一次：

- `_reset_watchdog()` 最初没有把当前进度记成基线，于是复位后的第一次 tick 被自己造出来的
  进度差吃掉，三个门槛整体晚一秒。重置的含义是「基线就是现在」，不是「基线未知」。
- `_set_phase()` 里的复位最初放在开头，那时 `_progress.value` 还是上一阶段的值，同样会
  吃掉一次 tick。挪到末尾。

**一条断言写成了装饰品，值得记**：最初只有一条 `watchdog_text_ignores_phase`，比的是
「两个阶段卡住后 `_detail.text` 是否相同」。把 `_phase_noun()` 写死之后它照样通过 ——
因为 EXPLAIN 的文案是「阶段名词 + 解释」两行，解释还在变就把名词的写死盖过去了。
拆成三条（NOTICE 只用名词 / EXPLAIN 只比第二行 / STUCK 比错误面板），每条都做出了能让
它单独转红的变异才算数。**做不出单独转红的变异，就说明这条断言是上一条的复读。**

九条断言逐条反向变异全部转红，`Bootstrap.gd` 按字节还原：

```
watchdog_fires_too_early / watchdog_explain_missed / watchdog_killed_on_main_thread
watchdog_fakes_progress / watchdog_ignores_progress / watchdog_not_reset_on_phase_change
watchdog_notice_text_ignores_phase / watchdog_explain_text_ignores_phase
watchdog_stuck_text_ignores_phase
```

### `ui_component` 95 → 105、`async_action` 174 → 178：六态覆盖、忙碌态、最小触控（V3 P1-01 / P1-02）

三个实测缺口：

- **CheckButton 五个状态的底板全是 Godot 默认外观**（原来只设了字色）。深色界面里按下去
  会闪一块浅灰。
- **TabBar / TabContainer 完全没进主题**。设置页与图鉴用得到，不覆盖就会露出一整条浅色标签栏。
- **LineEdit 只有 normal / focus**。Godot 的输入框没有 `disabled`，只有 `read_only` ——
  名字不同、语义相同，缺了它玩家看不出「这一格现在不能改」。

覆盖表 `REQUIRED_STYLEBOX_COVERAGE` 写在 `GloryTheme`（生产侧），门禁只负责逐条核对 ——
表放门禁里会变成一份会漂移的副本。核对用 `has_stylebox()` 而不是 `get_stylebox()!=null`：
后者在缺失时回落到默认，断言永远通不了红。

**忙碌态与禁用态分开**。`GloryBusyButton.show_pending()` 原来只置 `disabled=true`，于是
「你点到了、正在做」和「这个按钮现在不能点」长得一模一样 —— 玩家读成后者就会去别处点，
或者反复点这一个。现在同时切到 `GloryBusy` 变体（青色，和加载层同一套语义），结算后还回
原变体。还原这一步必须两条路径各自成立：`show_terminal()` 和 `reset_idle()`，因为取消
那条路径上根本没有 terminal。

**最小触控尺寸量的是主题作用之后的控件，不是 token 常量**。`TOUCH_MIN` 一直写着 48，而
实测按钮只有 44、输入框和 CheckButton 只有 47 —— 常量看着对，手指点不中，是这条要求最
常见的失败方式。`BUTTON_PAD_V` 按**最矮**的那类（`FONT_BODY` 的 LineEdit / CheckButton）
校准成 11；按按钮校准就会把输入框卡在 47。换字号后任何一类矮下去，门禁转红。

八条断言逐条反向变异全部转红，两个主题文件与 `GloryBusyButton.gd` 均按字节还原。
其中 `idle_variation_not_restored` 第一版是装饰品 —— 断言点在 `show_terminal()` 之后，
而那里已经还原过一次，做不出能让它单独转红的变异。补了「pending 直接回 IDLE」的取消路径
之后才立得住。**做不出单独转红的变异，就说明这条断言是别处的复读。**

### `prep_battle_loading` 50 → 60：等待到 2 秒解释、8 秒给出路（V3 P1-05）

迁移前加载层完全没有时间维度：卡在「等待服务器」上无论多久，画面都是同一句话加一个转圈的
菱形。玩家唯一能做的判断是「它是不是死了」，而那个判断没有依据。

两级：2 秒解释为什么慢，8 秒给出路。都不改进度条 —— 用等待时间伪造完成度是清单明令禁止的，
而且玩家一旦发现进度条会自己爬，之后就再也不信它。计时按**进度**复位：进度在动就不算慢。

**不可取消时不造一个按不动的取消键**。那比没有更糟：玩家会去点，点不动，然后认定程序坏了。
改为把「为什么走不掉」摆到明面上（清单原文：不可取消时显示原因）。可取消的路径则确实在
8 秒后露出取消键 —— 两条路径各有一条断言，否则「不造假取消键」可以靠「永远不给取消键」通过。

兜底文案指向真实阶段（「仍在『等待服务器』，比平时久一些」），不是写死一句「请稍候」。

七条断言逐条反向变异全部转红，`GloryLoadingOverlay.gd` 按字节还原。

### `tutorial_text_leak` 21632 → 21773：无效点击要说明原因（V3 P1-10）

原来无论在哪一步，无效点击都只回一句「先完成箭头指示的操作」。那句话有两个问题：
它没说要做什么，而且**箭头指的地方可能正被商店盖住** —— 玩家照着看，看到的是商店，
于是在商店里反复找。

现在说清两件事：商店开着就先让它关掉，然后复述这一步的目标。目标直接取
`current_text()` 的首行，不另建一张会漂移的文案表 —— 那张表还会成为第二处可能泄漏
enum key 的地方。采购类步骤（`BUY_3` / `UPGRADE_*` / `FILL_7` 的 BUY 相位）不提示关商店：
那正是要点的地方。

「每一步都回同一句话」也是失败：断言要求至少 5 种不同说法，否则只是换了个说法的
「再试一次」。

三条断言逐条反向变异全部转红，`TutorialMode.gd` 按字节还原。

（FILL_7 的「商店遮住待命区」在 V2 P1-07 已由 `CLOSE_SHOP` 子阶段处理：
「买齐了。先关掉商店，才能把棋子拖上棋盘。」本次补的是其余步骤。）

### `ui_component` 105 → 116：降低动态效果进设置页、状态不再只靠颜色（V3 P1-09）

`GloryTokens.reduced_motion()` 原来只认命令行 `--reduced-motion` 与项目设置 —— 真机上玩家
没有任何办法打开它。现在它成为第四个无障碍开关，走 `PlayerProfile` 落盘，并**单向写进**
`ProjectSettings`：`GloryTokens` 是 `static` 的、拿不到 autoload，让 profile 写那一处，
读侧就只有一个入口，不会出现「设置页开了、动画还在跑」。命令行仍然优先，真机上不改代码
就能验。两处 `REDUCED_MOTION_SETTING` 字面量由门禁核对一致 —— 抄的东西要有人核对。

**设置页的「当前选中」原来只用 `modulate` 表示**。色觉障碍、强光下的手机屏幕、以及任何
截图转灰度的场合，这些界面都读不出自己选的是哪一项 —— 而语言和画质恰好都是「选错了要
重新找回来」的设置。加了文字标记（`✓` 前缀 / `开`·`关` 后缀），颜色照常保留：两条通道并存，
不是用一条换另一条。

「标记不能越拼越长」这条断言指的是**画质**按钮而不是语言按钮：语言那两个每次传的是字面量
（`"中文"`），重刷多少次都不会累加；画质按钮传的是 `btn.text` —— 读自己再拼一次，那才是
真正会越拼越长的地方。第一版指着语言按钮，做不出能让它转红的变异。**断言要指着能坏的那一处。**

九条断言逐条反向变异全部转红，`PlayerProfile.gd` 与 `SettingsScreen.gd` 均按字节还原。

## 2026-09-03：程序化 UI 棘轮（V3 P1-08）

新增 `procedural_ui_ratchet`（7 项）。盯的是业务代码里 `StyleBoxFlat.new()` 与
`Button.new()` 的**数量**，基线 `data/qa/procedural_ui_baseline.json`。

分批迁移最常见的失败方式不是「没迁」，是**边迁边加** —— 这一批减了 3 处，另一个页面又
新写了 4 处，总数看着在动，观感一致性没有任何改善。所以三条一起断言：

- **总数只能下降。**
- **单文件也只能下降。** 总数持平但从 A 文件搬到 B 文件同样红 —— 那不是迁移，是换地方藏。
- **降下来之后必须显式收紧基线。** 不收紧的话，「只能下降」会退化成「不能高于最初那个
  很松的数」，之后随便加回去都不会红。

`--update-baseline` 是唯一的写入路径，普通运行**只读**（同 `asset_manifest` 的合同：
自愈更新基线等于让棘轮自己松开）。`ui/theme/` 不计 —— 那正是这些调用**应该**在的地方；
把它算进来会逼着迁移把 StyleBox 从主题里也删掉，方向正好是反的。`scenes/debug/` 不进包，
也不计。计数**跳过注释**：注释里提到 `Button.new()` 是常事，算进去会逼人去改注释而不是改代码。

首批迁移 `scenes/menu/MainMenu.gd`：5 处 `StyleBoxFlat.new()` → 0。做法是把那五处逐个
`set_*` 的东西抬进 `GloryTokens.flat_box(bg, edge, border_width, radius)`，配色抬成具名
token（`PARCHMENT` / `INK_PANEL` 等），**逐值透传、观感不变**。业务目录总数
`StyleBoxFlat.new()` 26 → 21，`Button.new()` 45（本批未动）。

四条断言逐条反向变异全部转红（`baseline_not_tightened` 是迁移当场自己红的）。

## 2026-09-03：响应式覆盖扩到教程之外的页面（V3 P1-06）

`tutorial_overlay_layout` 只覆盖 PrepScreen 的教程遮罩。审计（`reports/v3_audit.json`
的 P1-06 条目）点名的缺口是**其余页面没有等价覆盖**。新增 `responsive_layout`（48 项），
覆盖 MainMenu（连同它拉起的 MainMenuAmbience / MainMenuPet 子组件）、Team3v3Lobby、
SettingsScreen、CodexScreen，六种分辨率：16:9、19.5:9、20:9（项目基准视口 1600×720
正好是 20:9，是画布最矮的一档）、平板横屏、1280×720、平板竖深。刘海/挖孔安全区仍然
external —— 本机 25028RN03A 横屏 `navigation_mode=0`，没有 cutout 可测。

**三种版面各查各的不变式**，不是笼统遍历整棵控件树：

- REF_SIZE 信封页（MainMenu / Team3v3Lobby）：核对页面自己算出的 `_layout_scale`
  与按 `min(viewport/REF_SIZE)` 独立重算的期望值一致。原来还有「画布不超出视口」
  与「scale 不是 0」两条，**删掉了**——只要 scale 真的等于这个公式的结果，画布落在
  视口内是公式本身的数学保证，不是另一件需要验的事；找不到一个只让那两条单独转红、
  不牵连 scale 一致性的生产代码变异，就说明它们是复读，不是独立信息。
- CenterContainer 面板页（SettingsScreen）：直接测量面板矩形是否完整落在画布内。
- 自带缩放系统的页（CodexScreen）：`_book` 背景按「cover」故意铺满裁边，**不检查
  背景是否超出视口**（那是设计意图，裁边越裁越宽本来就该超出）；只检查返回键这个
  真正要可达的控件。

`Rect2.grow()` 的方向踩了一次坑：容差要加在**视口**这一边而不是画布那一边——
`grow()` 往外扩，扩画布只会让判据更严（要求画布比视口还小一圈），扩视口才是
「放宽 0.5px」该有的方向。写反了会让所有正常页面都假红。

实测六个页面在全部六档分辨率下都**没有溢出**；`SettingsScreen` 在 20:9
（画布收到最矮的 1600×720）下边距只有 7px，记为回归基线（不是当场重新设计布局—
没有实际点击不到的按钮，只是余量小，未来再加一个开关就会真的溢出）。

六条断言逐条反向变异全部转红，涉及的三个生产文件（MainMenu / SettingsScreen /
CodexScreen）均按字节还原。

## 2026-09-03：Release 包会崩溃的调试入口（V3 P1-07）

审计（`reports/v3_audit.json` P1-07）原先标「完成」，只欠「Release 导出回归」。
做这一步验证时发现的不是一个显示层面的小问题，是一个**真的会崩溃**的缺陷：

`Team3v3Lobby` 的「自测开始」按钮此前只按 `not _online()` 显隐，没有查
`OS.is_debug_build()`。这颗按钮打开的是 `officetest/OfficeTestScreen.tscn` ——
而 `officetest/*` 在 `export_presets.cfg` 的 `exclude_filter` 里，**根本不进
Android/Windows 的 Release 包**。Release 玩家离线时能看见并点这颗按钮，点下去
`Main._show_selftest()` 里 `load(...)` 拿到 `null`，对 `null` 调 `.instantiate()`
直接崩溃。同一个文件里 F3 排布调试网格也只按在线状态无关的按键触发，桌面
Release 版有真实键盘，同样能被玩家意外唤出。

修法三处：

1. `_selftest_btn.visible` 的两处赋值（初始化 + 状态刷新）都加
   `OS.is_debug_build() and`。
2. F3 处理函数入口先判 `OS.is_debug_build()`，不满足直接 return。
3. `Main._show_selftest()` 补防御性判空：`load()` 结果为 `null` 时退回大厅，
   不再无条件对它调 `.instantiate()` —— 这是纵深防御，即便以后又长出第二个
   能触发它的入口，也不会重演同一次崩溃。

新增门禁 `release_debug_ui`（8 项）。headless 跑的是 debug 模板，
`OS.is_debug_build()` 在测试进程里恒为 `true`，没有办法在同一个进程里让它变
`false` 来验证「Release 下这颗按钮真的不显示」——能验的是**源码合同**：显隐
赋值那一行有没有把 `OS.is_debug_build()` 当作显式的与运算项。这条合同验证的是
「代码写没写这道判断」，不是「Release 二进制运行时真的隐藏了它」；后者需要一次
真实的 Release 导出加人工确认可见性，那部分标 external，留给用户回来看一眼。

对着修复前的原始代码跑出的**先失败证据**：

```
FAIL [selftest_button_visible_in_release] ...["_build: _selftest_btn.visible = not _online()", ...]
FAIL [f3_overlay_not_gated] F3 排布调试网格没有在处理按键之前先判 OS.is_debug_build()
FAIL [show_selftest_no_null_guard] _show_selftest() 直接对 load() 的结果调 instantiate()，没有判空
```

六条断言逐条反向变异全部转红，`Team3v3Lobby.gd`（纯 LF）与 `export_presets.cfg`
均按字节还原；`Main.gd`（混合行尾）用「读 HEAD 字节 + 行级正则匹配」脚本改动，
新增行一律 LF，`git diff --check` 干净。

外部依赖（写进最终交接表，不代自动绿）：Windows Desktop / Android 的 Release
导出需要用户实际打开一次，肉眼确认「自测开始」按钮确实不见了。

## 2026-09-03：真实页面循环的生命周期泄漏（V3 P2-04）

`modal_lifecycle` 已经覆盖「热身 + 20 轮」的漂移检测，但它驱动的是**独立实例化**
的 MainMenu / PrepScreen 各自开关一次 Dialog/Modal 再销毁 —— 不是真的经过
`Main._show_menu()` → 信号 → `Main._show_xxx()` → `_on_back_requested()` 这条
玩家实际会走的页面切换路径。审计（`reports/v3_audit.json` P2-04）点名的缺口正是
这个：**真实页面循环（非仅 modal）**。新增 `page_lifecycle`（74 项）补上它。

走法只用 `Main` 自己的公开入口，不额外造测试专用接缝：`_show_menu()` 建出的
`MainMenu` 会把 `settings_requested` / `codex_requested` / `prep_requested` /
`team_offline_requested` 接到 `Main` 对应的 `_show_xxx()`，每个子页面的
`back_requested` 已经接到 `_page_back_route`（V3 P0-09）—— 于是调用
`main._on_back_requested()` 就等价于玩家按了一次 Android Back / 桌面 Esc。
另加一步 `_show_room_overlay()`（P0-07 迁移后唯一从 MainMenu 直接推到
ModalStack 的层），让循环里真的有模态可开可关，覆盖设置 / 图鉴 / 宠物 /
组队大厅(离线) / 房间面板五个真实页面，20 轮。PrepScreen/BattleScreen 需要
真实对局状态，风险和铺垫都更大，留给 `tutorial_checkpoint` /
`prep_battle_loading` 这些已经在跑它们的门禁去覆盖。

**一条断言写错过一次**：`cycle_left_invisible_stop` 最初判的是「不可见 STOP
控件数量必须是 0」。这在 MainMenu 的稳定态下天然为假 —— 重连按钮、地址输入框
都是「仅在满足某条件时才显示」的合法设计，默认隐藏但 `mouse_filter=STOP`，
每次全新建出 MainMenu 都会有这两个。改成跟基线比**增量**：真正的泄漏信号是
这个数字比基线还往上涨，不是它非零。

**`cycle_left_modal_open` 的反向变异也踩了一次坑，值得记**：第一次直接把
`ModalStack.handle_back_request()` 改成 `return false`，结果测试进程在几轮
之内自己退出了（exit=0，看着像通过）——因为返回键阶梯在「没有模态可关、没有
页面路由」时会继续走到二次确认退出，连续几次 Back 落空之后触发了
`get_tree().quit()`，把整个测试进程杀掉，而不是让某条断言转红。换成让
`close_top()` 假装成功但不真的弹栈，进程倒是活到了终点，可断言依然不红——
再查才发现 `ModalStack._process()` 有一层独立的兜底：`owner` 节点被释放时
自动 `pop()`（不经过 `close_top()`）。而本轮循环下一步就是切到设置页，
`Main._clear()` 会把持有房间面板的 MainMenu 一并释放，安全网正好抢先把泄漏
清理掉，断言测的其实是这层兜底而不是 `close_top()` 本身。真正独立证明这条
断言的做法是直接改 `pop()`（两条路径共用的最终落点）。

五条断言逐条反向变异全部转红，涉及的两个生产文件（`ModalStack.gd` 纯 LF、
不需要按字节还原技巧）与门禁自身脚本均可正常还原。

## 2026-09-03：帧时间固定字段与阈值判定（V3 P2-02）

`scripts/qa/battle_presentation_baseline.gd`（D0 基线，真实渲染一整场战斗，一轮几十秒
到几分钟）已经在产出 `average_fps` / `one_percent_low_fps` / `p95_frame_time_ms` /
`max_frame_time_ms`，但缺清单要求的另外几个固定字段，而且**从来没有阈值判定**——
`_finish_all()` 里的 `passed` 只看审计失败和轮数是否齐，不看帧时间。

补的字段：`p99_frame_time_ms`、`frames_over_16_7ms` / `_33ms` / `_50ms` / `_100ms`
四档计数、`memory_delta_mb`（采样窗口首尾两帧的 video/texture/static 内存差 ——
问的是「这一场打完有没有净增长」，跟已有的 `peak_*` 问的「打到一半冲多高」是两件事）。

新增 `battle_frame_time`（11 项）做**判定**，跟产出报告的脚本分开：判定吃的是普通
`Dictionary`，不用真的渲染一遍就能反向变异，也不会让「这条门禁能不能转红」依赖一次
GPU 才能复现。判据：

- 单帧硬顶（`max_frame_time_ms > 100`）独立于均值判断——「平均 120 FPS 但出现
  105ms 帧仍判失败」，两者不能互相抵消。
- 持续卡顿的软预算（`frames_over_50ms` 占比 > 2%）——最坏一帧正常、均值也正常，
  但三分钟里三分钟都在 40ms 帧的「整场发闷」，同样要抓。
- 报告缺字段直接判不合规，不是「查不到就当过」。
- **`judge_performance()` 的函数签名本身不接受 round 参数**——源码层面钉死
  「不能按 Round 20 特判」，不是靠人记着不写。

⚠️ **阈值是本次新加的默认值，不是既有产品决策的回收**：仓库里没有任何地方明确写过
`AVG_FPS_MIN`/`ONE_PCT_LOW_FPS_MIN`/`MAX_FRAME_TIME_MS_HARD` 这三个数字，是按「移动端
3v3 自走棋，允许偶发卡顿但不能整场糊」的常见口径估的（30 FPS / 20 FPS / 100ms）。
写进最终交接报告，等产品/主美回来确认或改。

用两份**真实历史采样**（2026-08-20 A4 设备/桌面双跑，不是编出来的数字）验证判定
本身有意义：`A4_device_battle_20260820/desktop/round_01`（健康局，143 FPS）应该通过；
`A4_device_battle_20260820/cold_cache/device/round_20`（均 8.93 FPS、1% low 6.84、
P95 帧时 138ms，早就是已知的性能缺口）必须判失败——门禁如果对着这份数据还给通过，
阈值就是形同虚设。同时这份旧采样天然没有新加的固定字段，顺手验证了「缺字段判不合规」
这条不是纸上谈兵。

**反向变异过程中的两个坑**：

1. `_check_uniform_thresholds_no_round_special_case()` 里判「函数签名不接受 round
   参数」，第一版直接 `src.find("func judge_performance(")` —— 而这条检查**自己的
   源码**里就写着这个字面量（这行注释、这行代码本身），不锚定到真正的函数定义
   会先匹配到自己。改成按行扫描、只认 `begins_with("func judge_performance(")`
   的整行。
2. 修复过程中用一次性 Python heredoc 写文件时，转义字符 `\n` 被环境吃成了真实换行
   （已知坑，见 `windows-escaping-traps` 记忆）——教训是这类字符串拼接改用 Edit 工具
   或独立 `.py` 文件，不要经过 shell heredoc。

十一条断言逐条反向变异全部转红（含用真实数据验证的两条），涉及的两个生产文件均
按字节还原。

## 2026-09-03：启动与页面截图回归（V3 P2-01）

四个新门禁族里唯一此前**零实现**的一个。拆成两个文件，理由是抓图需要真实渲染
后端——`headless` 是 dummy 后端，抓出来是空图（同 `ui_gallery_capture.gd` 的既有
约束）；判定只需要读两份已存在的 PNG 逐像素比对，不需要渲染，可以进 headless
套件天天跑：

- `startup_ui_capture.gd`（不带 `--headless` 手动跑）：产出 splash/Bootstrap 正常态、
  Bootstrap 失败态、主菜单、战斗加载等待态、战斗加载失败态五张截图，1600×900、
  zh、一档画质。清单要求的完整矩阵（16:9/19.5:9/20:9/平板 × zh/en × 三档画质）
  留给下一批照这套写法批量加，这批先把机制立起来。
- `startup_ui_regression_check.gd`（headless，进套件）：只读两个目录的 PNG 比对，
  不碰基准图的写入路径——`--update-baseline` 是唯一的写入口，同 `asset_manifest`
  的合同。

**实测撞到一个真的会让门禁变噪声源的问题**：主菜单有环境动画（水面、粒子、宠物
待机），同一份代码连续渲染两次，仅这一页就有 0.575%（8281/1,440,000）像素差异
——超过原定 0.5% 容差。诊断发现差异散布在大半张图上（bbox 覆盖 (284,22) 到
(1362,898)），不是一小块能遮罩掉的区域，说明问题不是某个孤立的动效精灵，而是
背景多处细碎的持续动画。改法不是加大容差或画一块大遮罩（那样会削弱这条门禁本身
的敏感度，也会撞上下面这条"遮罩不能盖住大半张图"的守卫），而是在抓图前把
`Engine.time_scale` 冻成 0——所有按 delta 推进的动画停在同一帧，两次抓图逐像素
一致，改完差异归零。这比逐个动效系统接入去改动更省事，也不需要碰任何生产代码。

判据：

- 单像素通道容差 6（0-255）——同一份代码渲染两次仍可能有 ±1~2 的抗锯齿抖动，
  容差为 0 会把这种正常抖动打成假红。
- 差异像素占比上限 0.5%（扣除遮罩像素之后）。
- 遮罩矩形本身不能盖住整图的 25% 以上——遮罩应该只圈动态区域，不能变成绕过
  比对的手段。
- 尺寸不一致直接判失败——换分辨率要连基准图一起显式更新，不能悄悄通过。

四条断言用**真实截图文件**反向变异（不是合成数据）——图像比对这类逻辑，合成
数据容易漏掉真实文件格式/通道数的坑：真的往 current 图上画一块红色矩形验证
`screenshot_regressed`；挪走基准图验证 `baseline_missing`；把某张图的遮罩撑到
盖住大半张图验证 `mask_too_large`；把 current 图缩放成不同尺寸验证
`size_mismatch`。全部转红，涉及的 PNG 与门禁脚本均已还原。

外部依赖（写进最终交接表）：完整的 viewport/locale/quality 矩阵、语言选择页、
教程确认页，以及刘海/挖孔设备下的截图，留给下一批与真机确认。

## 2026-09-07：按钮触摸反馈（V3 P1-04 步骤 1–8）

新增 `ui_feedback`（39 项），`ui_component` 116 → 134，`responsive_layout`
48 → 54，`export_presets` 6（新增一条正向断言）。全量 87 → 88 条检查。

清单 P1-04 有四条要求，第 1 条（六态可区分、最小触控）2026-09-03 已完成。
这一批做的是剩下三条，外加验收原文那句「无业务按钮使用 Godot 默认主题」。

### 裁决：并进 `PresentationSettings`，不另起一套

`ui_sound_allowed()` = 玩家开关 **且** Master 总线未静音。备战页那颗静音
按钮静的就是 Master，而此前没有任何 UI 音效会去查它——玩家按了静音，还得
再去设置页关一次。加这一条把「静音按钮只管 BGM」变成「静音就是静音」。

**「跟随系统静音」做不到**：Godot 4 没有可移植的 OS 静音查询 API，能查的只有
游戏自己的总线。按该文件对「低电量降级」的既有写法如实写在注释里，不假装做到。

`haptics_allowed(device_supported := ...)` 的默认参数**不是可变的测试开关**，
生产调用一律不传。没有它，「关掉开关就不震」这半条在桌面门禁上恒真——平台
判断会先返回 false，断言永远绿，等于没测。有了它，门禁才能在 Windows 上跑
手机那条分支。

触觉**刻意不并进 reduced motion**：那个开关压的是屏幕上的运动，震动不是屏幕
运动。想关震动的人未必想让所有过场动画也变静。

### 一次点击只发一次：靠锚点，不靠事后去重

确认反馈只接 `AsyncActionController.action_resolved`。`_resolve()` 只在
「找得到这个 request_id」且「状态属于 ACTIVE_STATES」时才发信号，其余路径
记面包屑后返回 false——所以一个 request_id 最多产生一次 `action_resolved`，
这是结构上的保证，不是一个 bool 标志位。

反例就在仓里：`PrepScreen._input()` 用 if/elif 同时处理 `InputEventMouseButton`
与 `InputEventScreenTouch`，两条路之间没有去重。今天无害（关面板是幂等的），
但只要把播音挂进去，Android 上一次触摸就会响两次——而**在 Windows 开发机上
完全看不出来**，桌面只有鼠标那一路会来。这种「桌面正常、真机翻倍」的不对称
正是它必须机械化成规则而不能靠人 review 的原因，所以有两条源码合同：
`Input.vibrate_handheld(` 全仓只能有一个调用点；任何 `_input` / `_unhandled_input`
/ `_gui_input` / `_shortcut_input` 的**函数体**里都不许出现 `UiFeedback`。

### 音频管线：搭好但静音

新增 `default_bus_layout.tres`，只有 Master 和 SFX 两条。**刻意没有 Music**：
四处 BGM 代码都写着 `bus = "Music" if get_bus_index("Music") >= 0 else "Master"`，
那个分支今天永远走 false；加一条 Music 会让这四处**同时**改走一条从没调过
音量的总线——在一个标题写着「按钮反馈」的提交里偷偷改掉线上 BGM 的路由。
门禁反过来钉住「不许有 Music 总线」，别让谁顺手补上。

`project.godot` 里**没有** `[audio]` 段是对的，不是漏了：
`audio/buses/default_bus_layout` 的引擎默认值就是 `res://default_bus_layout.tres`，
Godot 重写 project.godot 时会把停留在默认值的设置删掉。第一版显式写了那一行，
跑一次就被抹掉了。

`CONFIRM_SFX_PATH` 是空串，今天完全静音——仓里一个 UI 音效素材都没有，音频
许可仍是未闭环 blocker。**没有断言「stream 是 null」**：那条断言会在有人做对
事情、把文件放进来的那天转红。填一个真实文件即可生效，零门禁改动。

### toast / shake / 拒绝原因

`GloryToast` 是仓里唯一的 toast 实现，照抄 `Main._show_back_exit_hint()` 那套
真机验过的写法（自带 CanvasLayer、实心底板不靠描边、计时器挂在层自己身上）。
迁移了两处旧机制，函数名都保留所以调用点没动；`MainMenu` 的两个状态标签
**不迁**——那是常驻状态，换成 1.3 秒的 toast 是把信息弄丢。

shake 抖 `rotation` 不抖 `position`：Container 每次重排都会重写子控件的
position/size（`fit_child_in_rect`），却从不碰 rotation/pivot_offset。
两条容易写错的地方各有断言钉着：**还原到存下来的原值而不是归零**；
**重入时取回存下来的原值**，不能拿抖到一半的当前值当原值。

**toast 与 shake 是两条独立通道，不能互相顶替**：抖动是吸引注意力的，原因
文字是可达性通道，关掉屏震或开了 reduced motion 的玩家照样要看得见原因。

### 禁用态可以问原因

实现前先实测了机制：禁用的 `BaseButton` **仍然派发 `gui_input`**（连发按下
+抬起，`gui_input` 收到 2 次、`pressed` 收到 0 次）。C++ 侧
`Control::_call_gui_input` 先发信号再调虚函数，而 `BaseButton::gui_input`
在 disabled 时提前返回。挂 `gui_input` 既收得到点击又绝不触发业务。

**必须先 `has_meta`**：Godot 4.7 里 `get_meta(key, default)` 取不到 key 时
仍然会打引擎 ERROR，而 `run_check.ps1` 把这类 ERROR 直接算失败。带默认值也
救不了。

长按刻意不做：验收原文是「点击**或**长按」，只做点击就满足。

### 顺带修掉的四个真缺陷

1. **买不起一声不吭**。同一个「金币不够」，走商店面板有提示，走拖拽购买 /
   雇佣佣兵 / 刷新商店则静默 return——而静默 return 的上面两行就是会提示的
   `toast_unique_limit`。六处全部补上同一个文案 key，并配一条**穷举规则**：
   `PrepBoardController` 里每一处 `if GameState.gold <` 块内没有
   `show_message`/`reject` 就红。
2. **教学反馈出了备战页静默失效**。`TutorialTargetProvider.show_feedback()`
   的唯一生产绑定在 `PrepUI` 里，所以别处一律 `return false`、什么都不显示。
3. **设置页溢出**。加两行开关之后 19.5:9 / 20:9 / 平板三档面板底部溢出
   92–110px，返回键点不到。`responsive_layout` 的注释里早就记着
   「20:9 下边距只剩 7px」——那是预告。改成 ScrollContainer，门禁判据同步从
   「面板必须装得下」改成「返回键必须可达」。
4. **触控尺寸**。设置页三个控件写死 46 / 46 / 40，都低于 `TOUCH_MIN=48`。

### 变异证据里踩的坑（都写在断言旁边）

- **文案断言的「`tr(key) != key`」写法证明不了任何事**：TranslationServer
  查不到会回落到 fallback locale（en），只删 zh 那一条照样全绿，而中文玩家
  看到的是英文。改成断言两个语言返回不同字符串。
- **数 toast 层数不能按名字**：重名兄弟会被 Godot 改成 `@GloryToastLayer@2`，
  前缀是 `@`，精确相等和 `begins_with` 都数不到第二层。按层号数。
- **变异不能把脚本弄崩**：把 layer 直接置 null 那一版导致运行期报错、检查
  中途夭折（`checked` 从 22 掉到 14 却仍然打印 PASS），那证明不了断言能转红。
  变异脚本因此加了一道保险：变异后 `checked` 必须仍等于基线。
- **注释也会造假红**：扫 `Input.vibrate_handheld(` 的规则第一版没去注释，被
  `PresentationSettings` 里一句说明性注释判成违规。和「整文件 contains 被
  自己写的注释满足」是同一个坑，方向反过来。规则改成扫去掉注释之后的代码。
- **删掉了一条装饰性断言**：`feedback_toggles_not_restored` 做不出独立变异
  （被 `ui_sound_ignores_toggle` 支配），还原照做，断言删掉。

### 仍然 external

- **确认音素材**：管线就绪但静音，等素材与 `third-party-license-ledger` 闭环。
- **VIBRATE 权限真的进了 APK**：只证明了受 git 跟踪的模板请求了它；
  live 的 `export_presets.cfg` 不进 git，在一台从没同步过它的机器上导出就是
  没有，CI 也看不见。
- **12 ms 震动在真机上感不感觉得到**、**240 fps 录屏测反馈时延**：需要设备。
