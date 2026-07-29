# 状态信封 RFC（设计稿，未实现）

> 状态：**待审**。本文只定方案，不含代码。
> 审过之后再实现，实现时协议号 +1、客户端与服务端同发。
>
> 配套文档：`docs/联机审计与整改方案.md`（问题编号 A/B/C、R1–R7、发布门都在那边）

---

## 一、这份设计要解开什么

现在**房间的权威状态被拆成了七八个各自为政的 RPC**，每个都能独立地迟到、乱序、
互相覆盖。由此派生出的问题占了待办清单的一大块：

| 问题 | 现状 | 根因 |
|---|---|---|
| `B6` 回合号双份真相 | `_rpc_round_resync` + `team_begin_round` + `team_submit_board` 三处各自对齐 | 没有单一权威版本号 |
| `C17` `server_round_index` 可被倒退 | 三个入口已加"只升不降"止血 | 同上；`slot_states`/`ready` 仍是无条件覆盖 |
| `C5` resume 不完整 | 补了宝物，仍缺 streak/PVE/佣兵/祭坛/战后棋盘/终局 | 恢复快照没有统一定义 |
| `C7` 任意一人推进 RESULT | 已挡住 `ready=false`，仍是"一个人推全房" | 没有每座位确认 |
| `B15` 终局不可恢复 | `match_over` 直接拒绝 resume | 没有 terminal 快照 |
| `B8` 技术失败误离场 | 已分级止血 | leave 没有回执，凭证清得太早 |
| `C10` 协议校验太晚 | 只在提交棋盘时验 | 没有握手 |
| `C11` 数据表无哈希 | 无 | 同上 |

**八个问题，一个根因。** 这也是为什么它值得单独设计：不先定下来，后面每加一个功能
就会各造一套同步格式，最后重连、恢复、持久化互相打架。

### 非目标（明确不做）

- **不做增量（delta）。** 已确认。状态包本来就小（座位状态 + ready + 回合号 ≈ 一百多字节），
  而真正大的 replay 不是状态增量。delta 要配套版本历史、resync、应用失败回退，
  为省几十字节不值得。
- **不做 replay 分块。** 实测压缩后最坏 61.8 KB，低于常见阈值上沿。信封**预留** chunk 字段，
  实现可缓（见联机审计文档 B2）。
- **不做 replay 留存。** 已确认 replay 只是当前这场的演示素材，播完即弃，没有回看功能。
  所以缓存生命周期 = 本房当前战斗阶段，房间推进到下一个 PREP 就整个丢弃。
  **不需要** TTL / LRU / 磁盘 spill。
- **不做账号。** 暂不接 Nakama。身份仍是"一局一换的座位 token"。

---

## 二、不做 delta 带来的一个关键简化

值得单独说，因为它影响后面所有时序：

> **全量快照 + 序号 ⇒ 漏包自愈。**

客户端漏了 `seq=5`，之后收到 `seq=7` 的全量快照，**直接应用就是对的**——
不需要请求补 5、6，服务器也不需要保留历史版本。

这让 `resync_request` 从"补差机制"退化成"我怀疑自己不同步，请重发一份当前状态"，
实现上就是再广播一次全量。**服务器不保留任何状态历史。**

---

## 三、信封结构

所有下行**状态类**消息共用这个外壳。内容（payload）与外壳严格分开：
外壳只管传输、版本、顺序、恢复；payload 才管金币、棋盘、战斗。

```text
envelope = {
    protocol_version : int      # 握手已校验，这里是二次防线
    server_epoch     : int      # 服务器进程本次启动的标识
    room_id          : int      # 已含分片号（多进程已落地）
    state_seq        : int      # 该房间权威状态的版本号，每次变更 +1
    message_type     : String
    request_id       : String   # 关联某条上行请求；无关联时为空
    ack_required     : bool
    payload          : Variant  # Dictionary，或 replay 的 PackedByteArray
}
```

**刻意不放进信封的东西**（GPT 的建议里有，我认为放错层了）：

| 字段 | 为什么不放 |
|---|---|
| `round` / `phase` / `deadline_remaining_ms` | 这些是**游戏内容**，属于 payload。放信封里违反"外壳只管传输"这条自己的原则 |
| `base_state_seq` | 增量基准。不做 delta 就不需要 |
| `chunk_index` / `chunk_count` / `transfer_id` | 只有 bulk 传输才用得上。放进**每一条**消息会让一个几十字节的 ack 也背上四个 chunk 字段。做成**可选段**，只在 `battle_replay` 上出现 |
| `payload_hash` | 见下 |

### 关于 payload_hash：保留字段，但不要当安全措施

裸 hash 在**明文链路**上防不了篡改——中间人可以把数据和 hash 一起改。
它只防"实现 bug 导致的损坏"，而 ENet reliable 本身已经有 CRC。

所以：
- `battle_replay` 的包内已有 `[8B 原始长度][zstd]`，长度头兼任防解压炸弹门，够用
- 信封里**保留** `payload_hash` 字段但 v1 不填
- 真要防篡改必须是 **HMAC + 共享密钥**，那是 C14 加密之后的事

---

## 四、消息清单与迁移映射

### 下行（服务器 → 客户端）

| message_type | 取代现有 RPC | 说明 |
|---|---|---|
| `room_state` | `_rpc_team_lobby`<br>`_rpc_team_leader`<br>`_rpc_resume_state`<br>`_rpc_round_resync` | **房间权威全量快照**。四合一是这份设计的核心 |
| `battle_result` | `_rpc_receive_match_state` | 权威结算。`ack_required = true` |
| `battle_replay` | `_rpc_team_replay` | 演示素材。带 chunk 可选段（v1 不分块） |
| `receipt` | `_rpc_altar_result`<br>`_rpc_treasure_granted/denied/offer` | 上行请求的回执，按 `request_id` 幂等 |
| `error` | `_rpc_resume_failed`<br>`_rpc_team_action_failed`<br>`_rpc_team_room_closed` | **带分级**（见第八节） |

### 上行（客户端 → 服务器）

| message_type | 取代现有 RPC | 说明 |
|---|---|---|
| `client_hello` | 无（新增） | 握手，见第七节 |
| `intent` | `_rpc_team_set_ready`<br>`_rpc_team_submit_board`<br>`_rpc_altar_request`<br>`_rpc_treasure_choice/refresh`<br>`_rpc_team_leave` 等 | 玩家动作。**必带 `request_id`** |
| `ack` | 无（新增） | 确认已应用某个 `state_seq` 或 `battle_id` |
| `resync_request` | 无（新增） | "我怀疑不同步，请重发当前状态" |

### 不进信封的

- `_rpc_ping` / `_rpc_pong`：心跳，不承载状态，保持裸 RPC（也便于以后走 unreliable 通道）
- `_rpc_client_log`：排障回传，与状态无关

---

## 五、`room_state` 快照内容

这是解决 `C5` 的关键：**恢复用的和平时广播的是同一份东西**，
不再有"平时发一部分、重连发另一部分"的口径差。

```text
room_state.payload = {
    # --- 房间 ---
    phase              : String   # lobby / prep / battle / result / terminal
    round_id           : int      # 当前回合
    leader_slot        : int
    slot_states        : Array[6] # empty / player / dummy
    ready              : Array[6]
    suspended          : bool     # B11 已落地的概念

    # --- 本座位 ---
    my_slot            : int
    session_token      : String   # B14 已落地：短码恢复后也拿得到私有凭证

    # --- 队伍 ---
    team_hp            : int
    rival_team_hp      : int

    # --- 本座位的对局进度（C5 缺的那批）---
    gold               : int
    loss_streak        : int
    pve_completed      : int
    boss_completed     : int
    owned_treasures    : Array
    treasure_offer     : Dictionary   # 空 = 明确无待领取（客户端必须据此清 UI）
    altar_uses         : int
    gamble_used        : bool
    prep_mercs         : Array
    board_snapshot     : Dictionary   # 服务端规范化的战后棋盘
    last_battle_id     : String

    # --- 终局（phase == terminal 时有效）---
    run_outcome        : int          # TeamOutcome.TEAM_A / TEAM_B / DRAW
    terminal_summary   : Dictionary
}
```

**两条硬规则：**

1. **字段一律"有就是有、没有就是明确的空"**，不允许"缺字段 = 保持原值"。
   `treasure_offer` 为空必须清掉客户端旧候选——这正是修好的 C5 那半个洞。
2. **deadline 一律传 `remaining_ms`，不传绝对时刻。**
   服务端已改单调时钟（C20），而单调值跨进程重启就失效；
   客户端也没有和服务端对齐的时钟。

---

## 六、序号与 epoch

### `server_epoch`

服务器进程每次启动生成一次，整个进程生命周期不变。

**它解决的是"跨重启的迟到包"**：服务器重启后 `state_seq` 从 0 重新计，
如果客户端手里还留着重启前的 `seq=42`，没有 epoch 就会把新的 `seq=3` 当成倒退丢掉，
从此永远不同步。

取值建议：启动时的墙钟秒（`_wall_now()`），**不用单调时钟**——单调值每次重启都从 0 开始，
两次重启会撞。

### `state_seq`

**每个房间一个**，房间创建时为 0，每次权威状态变更 +1。

不做全局序号，因为房间之间互不相干，全局序号只会让每个房间的号跳得很难读。

### 客户端应用规则

```text
收到 room_state：
  if envelope.server_epoch != my_epoch:
      # 服务器重启过，或这是第一份状态
      接受，my_epoch = envelope.server_epoch，my_seq = envelope.state_seq
  elif envelope.state_seq <= my_seq:
      丢弃（迟到包）
  else:
      接受并整份替换，my_seq = envelope.state_seq
```

注意 `else` 分支**不检查是否连续**——因为是全量快照，跳号直接应用就对了。
这就是第二节说的"漏包自愈"。

**这条规则一上，`C17` 的三处止血补丁全部可以删掉**，`server_round_index`
这份平行真相也随之消失（`round_id` 只存在于 `room_state` 里）。

---

## 七、握手（解决 C10 / C11）

用 Godot 的 `SceneMultiplayer.set_auth_callback`。

### 关键实现约束（会踩的坑，先写下来）

- `set_auth_callback` **必须在给 `multiplayer.multiplayer_peer` 赋值之前**配置，
  否则先连上来的 peer 绕过认证
- 必须设 `auth_timeout`，否则半开的认证连接会一直挂着（这本身就是 `A13` 的连接槽面）
- 认证中的 peer 要有**数量上限**和**payload 字节上限**
- 失败路径必须显式清理，不能只靠超时

### `client_hello` 内容

```text
{
    protocol_version        : int
    client_build_id         : String   # 兼容性元数据，**不是身份认证**
    data_manifest_sha256    : String   # 数据表指纹
    sim_manifest_sha256     : String   # 战斗模拟版本指纹
    session_token           : String   # 可空；重连时带
    last_server_epoch       : int      # 可空
    last_state_seq          : int      # 可空
}
```

### 服务端校验顺序

```text
1. protocol_version 不匹配        → error(terminal, "protocol_mismatch")
2. data_manifest 不匹配           → error(terminal, "data_mismatch")
3. sim_manifest 不匹配            → error(terminal, "sim_mismatch")
4. 以上都过 → complete_auth
```

### ⚠️ manifest 必须校验实际部署文件

构建期生成的 manifest 编进包里，但**服务器监听前必须对实际部署目录重算一遍并比对**。
只信包内常量的话，覆盖解压残留、部署目录损坏、坏 JSON 被当成空字典——全都发现不了。
校验失败 **fail closed**（拒绝启动），不是打个警告继续跑。

---

## 八、失败分级（解决 B8 / B13）

现在代码里的 `RESUME_RETRYABLE_REASONS` 已经是这个思路的雏形，这里把它形式化到所有错误。

```text
error.payload = {
    class  : "terminal" | "retryable" | "transport"
    code   : String
    detail : String   # 可选，给日志用，不进 UI
}
```

| 分级 | 含义 | 客户端行为 | 例子 |
|---|---|---|---|
| `terminal` | 凭证确实失效了 | 清 token、回主菜单 | `token_unknown` `room_gone` `protocol_mismatch` `data_mismatch` |
| `retryable` | 这一刻接不上，但凭证仍有效 | **保留 token**，退避重试 | `seat_busy` `server_busy` |
| `transport` | 传输层失败，状态没问题 | 保留 token，进可恢复状态，继续补 | `replay_unpack_failed` `replay_timeout` |

**一条铁律**：只有 `terminal` 才允许清凭证。

这直接修掉 `B8`——现在 `disconnect_session()` 会在 replay 超时这种 `transport`
失败上清 token，把一个能自愈的问题升级成永久离场。

---

## 九、ACK 与幂等

只有三个地方需要 ACK。**不要给所有消息都加**，那会把心跳都拖慢。

### ① 明确退出（B8 / R1）

```text
客户端 → intent(type="leave", request_id=R)
        本地写入 pending_leave(R)，该状态下禁止自动 resume
服务端 → receipt(request_id=R, ok)
        撤销 token，保留 leave tombstone 一段时间
客户端 → 收到 receipt 才清 token
```

**技术失败绝不发 leave。** 现在 `disconnect_session()` 是发了 leave 就立刻关 peer——
包可能根本没送到，也可能送到了但立刻撤了 token。两种都错。

服务端保留 tombstone 是为了：ACK 丢了、客户端重试同一个 `request_id` 时，
能拿回**同一个 receipt**，而不是被当成新请求。

### ② 结算确认（C7 / B15 / R6）

```text
服务端 → battle_result(ack_required=true, battle_id=B)
客户端 → 播完/跳过后 ack(battle_id=B)
服务端 → 所有"仍有恢复资格的真人席位"都 ACK 了，才推进下一轮
```

- **AI 席位和空席由服务器自己代过**，不伪造客户端 ACK
- 必须有超时：某个真人一直不 ACK，等多久？→ **见第十二节未决问题 3**
- 这修掉 `C7`（一个人推全房）和 `B15`（终局没有确认边界）

### ③ 交易回执（R3）

`treasure_choice` / `treasure_refresh` / `altar` 都带 `request_id`：

```text
handler 顺序（**不能变**）：
  1. 认证 sender / slot
  2. 限制输入长度，生成 canonical fingerprint
  3. 先查 receipt / tombstone   ← 关键
  4. 同 request_id 同内容  → 重放原 receipt
     同 request_id 异内容  → 拒绝并记录
  5. 只有新请求才继续检查 phase / round / 余额并执行
```

**第 3 步必须在第 5 步之前。** 反过来的话，"成功了但 ACK 丢了"的重试会被新的 revision
判成 stale 而拒绝，玩家再也拿不回那个 receipt。

---

## 十、重连时序

```text
客户端 → client_hello(..., session_token, last_server_epoch, last_state_seq)

服务端判定：
  ├ 版本/数据表不匹配        → error(terminal, ...)
  ├ token 无效               → error(terminal, "token_unknown")
  ├ 座位被**活着的** peer 占  → error(retryable, "seat_busy")
  ├ 座位被**半死的** peer 占  → 顶掉旧 peer，继续（已落地，B13）
  └ 通过 → complete_auth，然后按服务器**当前阶段**决定发什么：

     phase == lobby / prep
         → room_state（全量）。不补任何旧 replay
     phase == battle / result（仍在本轮有效回放边界内）
         → room_state + battle_result + A/B 两份 replay
     phase == terminal
         → room_state（含 run_outcome + terminal_summary），不补 replay
```

**三条规则：**

1. **永远发全量 `room_state`**，无论 `last_state_seq` 是多少。不做 delta 就没有"补差"。
2. **不播放跨阶段的旧 replay。** 服务器已经进下一个 PREP 了就直接恢复摆放界面——
   replay 是即时素材，过期即无意义。
3. 收到 `battle_result` 可以先缓存，但**两份 replay 都验完之前不导航到 PREP、不发 ack**。

---

## 十一、分阶段实施

一次全改风险太大。建议四步，每步都能单独验证：

| 阶段 | 内容 | 解开 |
|---|---|---|
| **E1** | 握手（protocol + manifest）；`error` 分级 | `C10` `C11` `B8` 一半 |
| **E2** | `room_state` 全量快照 + `server_epoch` + `state_seq` + 拒收倒退 | `B6` `C17` `C5` |
| **E3** | ACK：leave receipt + result ack | `B8` 另一半、`C7` `B15` |
| **E4** | `request_id` 幂等回执（交易类） | `R3`，为 P1 账本铺路 |

**E2 是最大的一步**——四个 RPC 合一，客户端应用状态的路径要整个改。
建议 E1 和 E2 之间留一次完整回归。

chunk 相关字段在 E1 就写进信封定义（避免以后再升协议），但实现留到"实测证明需要"为止。

---

## 十二、未决问题（需要你定）

### 1. ~~要不要 `match_epoch`？~~ ✅ 已确认：**要留**

产品确认：6 人自定义房打完一局后**回到大厅，可以再开一局**（大家按准备 → host 按开始）。
也就是同一个房间会打多局，第一局的迟到包必须在第二局里被丢掉，
光靠 `room_id` 区分不了。**`match_epoch` 保留。**

**再开一局的重置规则（已确认）**：**全部刷新，等同于重新开一把新游戏** ——
金币、宝物、棋盘、板凳、佣兵、水晶血量、连败、祭坛次数、赌博状态全部回到初始，
`round_id` 回到 1，`match_epoch` +1。座位与 `join_seq` 保留（人还是那批人）。

> ⚠️ **这个功能现在不存在**：当前代码在 `run_over` 之后直接
> `_room_close(room, "match_over")` 把房间回收了，所有人被踢回主菜单。
> 「回大厅再开一局」是一个待实现的功能，不属于信封 RFC 的范围，
> 但信封必须**预留** `match_epoch` 以免到时候再升一次协议。

另有一个**完全不存在**的功能被这次讨论带出来：**3 人组队匹配陌生玩家**。
它和已决定的"取消公开房间列表"直接相关 —— 列表原本就是匹配系统的拙劣替代品。
产品已确认**先不做**，但要记住：现在 6 人自定义开房这条路是通的，
3 人组队匹配那条路是断的。

### 2. `state_seq` 溢出与持久化

单局最多 21 回合，每回合状态变更撑死几十次——`state_seq` 不可能溢出。
但如果以后做 `B5` 房间持久化，重启后 `state_seq` 从哪开始？

**建议**：持久化时连 `state_seq` 一起存，重启后接着数，同时**换新的 `server_epoch`**。
这样两条防线都在。

**问**：认可这个做法吗？

### 3. ~~result ACK 的超时策略~~ ✅ 已确认

**按"在线真人都 ACK 了"推进，掉线的不等。**
掉线者重连时靠 `room_state` 全量快照追上 —— 这和现有的"座位宽限 + AI 代打"
逻辑一致：掉线的人不该拖住在线的人。

AI 席位与空席由服务器自己代过，不伪造客户端 ACK。

> 顺带记录一条**被否决的相邻提案**：「摆放界面挂机 3 分钟强制开始」。
> 产品确认**先不做**。
> 现状是 `PREP_TIMEOUT_SEC = 30 分钟 → 直接关闭房间`（一个人挂机，六个人的对局就没了），
> 这确实该改，但不在信封范围内，另行排期。
> 真要做的话还得先定：强制开始时没准备的那个人用什么棋盘（当前摆的 / 服务端
> 缓存的 `last_board` / 空棋盘判负）。

### 4. ~~data_manifest 要不要 v1 就上？~~ ✅ 已确认

**E1 只校验 `protocol_version`。** 数据表指纹等打包流程完善之后再加
（它需要一条构建期生成 manifest 的流程，现在的打包脚本没有这一步）。

`client_hello` 里**保留** `data_manifest_sha256` / `sim_manifest_sha256` 字段，
E1 阶段允许为空、不参与校验 —— 这样以后加的时候不用再升一次协议。

### 5. `state_seq` 跨重启（**唯一还开着的**）

服务器重启后房间从存档恢复，`state_seq` 从几开始？

- 从 0 开始 → 客户端手里还留着重启前的 42，会把新的 3 当成迟到包丢掉，**从此永不同步**
- 接着数 → 要把它一起存进存档

**建议**：存进去接着数，**同时**换一个新的 `server_epoch`。两条防线，
任何一条对上都能识别出"服务器重启过了"。

**但这条只在做了 `B5` 房间持久化之后才有意义。** `B5` 做不做还没定，
所以这条可以挂着 —— **不阻塞 E1–E4 的实现**。

---

## 十三、这份设计**不解决**什么

避免审的时候误判覆盖范围：

- **不解决作弊。** 信封管的是传输和顺序。金币、单位、星级的权威化仍然要等 P1 备战账本（`A5` `A10` `C18`）
- **不解决单线程阻塞。** `B4` 是战斗模拟占着主循环，和同步协议无关
- **不解决重启丢房间。** `B5` 持久化是另一件事，信封只是给它提供了 `server_epoch` 和 `state_seq` 这两个必要字段
- **不解决加密。** `C14` 独立。信封里的 `payload_hash` 在明文链路上防不了篡改
- **不提供 L2 证据。** 实现完之后仍然需要独立进程 + 真实 ENet 的黑盒测试才能标 ✅

---

*本文档随实现推进更新。每完成一个阶段（E1–E4），在第十一节标注实际观测与偏差。*
