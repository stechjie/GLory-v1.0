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
| `tools/rate_limit_check.tscn` | RPC 限流服务的行为用例（D1 PR1，注入假时钟） |
| `tools/client_log_check.tscn` | 客户端日志服务的行为用例（D1 PR3，注入临时文件路径） |

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
