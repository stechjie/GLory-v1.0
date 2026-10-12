# OPS-02 处罚与案件 —— 第一轮：禁语音与禁排位（账号服务器）

2026-10-12 · 需求来源《GLORY_后台功能完善需求与AI实施任务书_20261011》OPS-02
· 核对结论见 [后台功能完善_核对结论_20261012.md](后台功能完善_核对结论_20261012.md)

本轮只做**账号服务器能独立验证的部分**：两个新处罚范围的存储、准入执法、后台接口。
案件（case）页面、资产收回、以及禁语音在**战斗服务器**那一半都没做，见最后一节。

---

## 一 关键判断：不新建「统一处罚表」

`database/019_world_chat.sql` 的 `player_mutes` **本来就是按可扩展设计的** ——
它已经有 `scope` 列，而且表自己的注释写着：

> scope 先只有 world；**以后要禁房间 / 局内聊天再加值**（那两条走战斗服务器，要另想怎么通知它）

任务书要的「统一处罚页」是**页面**统一，它还明说「历史封号及禁言可以关联展示，
不应为迁移而再次执行」。所以 `database/036_sanction_scopes.sql` 只放宽约束、
复用现成的「只追加、解除打标记」的形状。

新建一张表再搬旧数据，收益只有「整齐」，代价是动 016/019 两条已经在线上跑的路径
（封号还连着 403 与续期凭证寄存）。不值得。

**账号封禁（016 的 `player_bans`）不并进来**：它语义不同 —— 整号进不去、要强制下线、
要寄存续期凭证。`sanctions.SCOPES` 里**没有** `ban`，测试盯着这一点。

| scope | 限制什么 | 不限制什么 |
|---|---|---|
| `world` | 世界频道发言 | 私聊、语音、排位 |
| `voice` | 组队与局内**说话** | **收听照常** |
| `ranked` | 人工禁止排位准入 | 休闲、自建房 |

---

## 二 🔴 顺手修了一个还没发作的 bug

`unmute_player` 原本撤销的是「这个玩家**全部**生效中的禁言」，**不分 scope**。

今天只有 world 一种所以看不出来；一旦加了 voice / ranked，「解除世界频道禁言」
就会连带把禁语音也解了 —— 而且不会报错。任务书 §四.3 明确要求
「撤销其中一个不解除另一个」。

036 把它改成按 scope 撤销，默认值仍是 `'world'`，`admin.py` 那两处调用不用改、
行为也和今天一致（库里只有 world 行）。

相对的，`world_chat.py` 的 `_LIVE_MUTE` **已经写了** `scope = 'world'`，
不会被新 scope 污染 —— 那一条原作者做对了，没动。

---

## 三 禁语音：本轮做了一半

**已拍板（2026-10-12）**：禁语音是「禁止说话、**仍可收听**」。

| 这一半 | 状态 |
|---|---|
| 账号服务器发组队语音令牌时 `canPublish=false`、`canSubscribe=true` | ✅ 本轮 |
| 战斗服务器发局内语音令牌时同样处理 | ❌ 没做 |
| 对局**中途**被罚的人：LiveKit `UpdateParticipant` 当场撤发言权 | ❌ 没做 |
| 旧令牌重连不能恢复发言 | ❌ 没做 |

🔴 **最后两条是验收 S02 专门考的**，而且是整件事里最容易做漏的：
`LiveKitAuth.gd:18` 的 `JOIN_TTL_SEC = 600`，LiveKit **只在首次进房时**检查令牌。
所以光靠签发时不给发言权是不够的 —— 手上那张没过期的旧令牌还能再用 10 分钟。

好消息是调用通道现成：`LiveKitAdmin.gd:37` 的 `_post()` 是通用的，
而 `admin_token(can_delete=false)` 签的就是 `{"roomAdmin": true, "room": room}`，
**正是 `UpdateParticipant` 需要的授权，鉴权侧一行都不用动**。

---

## 四 禁排位：和信誉分自动禁赛分开判

`ranked.queue_gate` 现在是**四道闸**：时间窗口 → **人工禁排位** → 信誉分禁赛到期 → 信誉分阈值。

🔴 人工禁排位（`GATE_SANCTIONED` = `ranked_sanction`）和信誉分自动禁赛
（`GATE_BANNED` = `credit_banned`）**必须是两个码**：一个是系统按跑路行为自动算的、
有自己的到期时间，一个是运营手动下的。合成一个的话玩家看到的原因会说错，
后台也分不清该撤哪一个（任务书 §一）。

休闲不受影响（任务书 §四.2「默认不限制休闲」），测试盯着。

---

## 五 改了哪些文件

**新增**

| 文件 | 作用 |
|---|---|
| `database/036_sanction_scopes.sql` | 放宽 scope；`mute_player` / `unmute_player` 带 scope |
| `backend/app/sanctions.py` | 三个范围的常量、查询、`clean_scope` |
| `backend/tests/test_sanctions_stdlib.py` | 20 条，不需要数据库 |
| `docs/运营后台_OPS02_处罚范围.md` | 本文 |

**改动**

| 文件 | 改了什么 |
|---|---|
| `backend/app/ranked.py` | `GATE_SANCTIONED` + `queue_gate` 第二道闸 |
| `backend/app/routes/matchmaking.py` | 新原因码的玩家文案 |
| `backend/app/party_voice.py` | `issue(..., can_publish=True)` |
| `backend/app/routes/party.py` | 发语音令牌前查禁语音 |
| `backend/app/admin.py` | `mute` / `unmute` 带 scope，审计记 scope |
| `backend/app/routes/admin.py` | `MuteBody.scope` / `ScopedNoteBody` |
| `backend/app/schema_check.py` | 036 两条探针 + 一条 prepare |
| `backend/tests/test_ranked.py` | 替身补 `fetchval`；+3 条新闸的用例 |

---

## 六 🔴 部署

1. **先**在 Supabase SQL Editor 跑 `database/036_sanction_scopes.sql`
2. **再** `deploy/update.sh`
3. 🔴 **跑完要重启后端** —— 036 `drop function` 再 `create`，旧连接上缓存的执行计划
   会指向不存在的函数，报 `cache lookup failed for function`。
   （这点和只建新表的 035 不一样。）

部署后自检：

```bash
journalctl -u glory-backend | grep SCHEMA | tail -5
```

🔴 **036 是「放宽 check 约束」那一类，启动自检的 `prepare` 抓不到**
（语句完全合法，要到真 insert 才被拒）—— 和 030 同一个形状。
所以 `schema_check.py` 里给它加了两条直接问系统表的探针，**别删**：

- `036 player_mutes.scope 放行 voice / ranked`
- `036 unmute_player 带 scope 参数`

---

## 七 测试结果（实际跑出来的）

单文件跑（全套同进程是既有的红）：

| 文件 | 结果 |
|---|---|
| `test_sanctions_stdlib.py` | **20 passed**（新增） |
| `test_ranked.py` | **59 passed**（56 + 新增 3） |
| `test_matchmaking.py` / `test_loadout.py` / `test_ws.py` | 47 / 38 / 22 passed |
| `test_admin.py` / `test_bans.py` / `test_party_voice_stdlib.py` | 17 / 15 / 2 passed |
| `test_service_control_stdlib.py` | 49 passed |

变异验证（改坏 → 转红 → 还原转绿）：

| 把什么改坏 | 结果 |
|---|---|
| `unmute_player` 不带 scope（解一个连带解全部） | 1 红 |
| 禁语音把收听也禁了（`canSubscribe` 跟着关） | 1 红 |
| `_LIVE_SANCTION` 不按 scope 过滤 | 1 红 |
| 人工禁排位连休闲也挡 | 1 红 |

---

## 八 本轮没做

- **案件（case）**：把多条处罚归到一个案件号下、统一处罚页、关联举报与证据快照
- **资产收回**（OPS-03）—— 它要引用案件号
- **禁语音的战斗服务器那一半**（见第三节）：局内令牌、`UpdateParticipant`、旧令牌重连
- **后台页面**：现在只有接口，`admin.js` 还没有「处罚 / 案件」页签
- **玩家侧提示**：被禁语音的人在游戏里看不到「为什么不能说话」，只是麦克风没反应
