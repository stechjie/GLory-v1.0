# OPS-05 维护与关闭匹配 —— 第一轮（账号服务器）

2026-10-12 · 需求来源《GLORY_后台功能完善需求与AI实施任务书_20261011》OPS-05
· 核对结论见 [后台功能完善_核对结论_20261012.md](后台功能完善_核对结论_20261012.md)

**本轮只做账号服务器，不含客户端与战斗服务器。** 交付的能力是：

> 维护 = 停止新准入；关闭匹配 = 排位与休闲一起不能开新局。
> 两者都**不打断已经在打的对局**。

---

## 一 本轮做了什么 / 没做什么

| 任务书要求 | 本轮 |
|---|---|
| 维护时拒绝新准入 | ✅ WS 握手 + 发名片两道闸 |
| 已开局正常打完并结算 | ✅ 判据是服务器自己的发牌记录，见第三节 |
| 关闭排位与休闲匹配 | ✅ 排队 / 确认 / 组队开局三道闸 |
| 两个开关分别存，解除维护不顺带开匹配 | ✅ 两列分开，测试盯着 |
| 维护优先级高于关闭匹配 | ✅ |
| 开关有版本号、冲突回 409 | ✅ 乐观并发，不靠禁用按钮 |
| 状态变更即时生效 | ✅ 单进程单实例 + 写完作废缓存 |
| 开、关、失败均记审计 | ✅ 进 `admin_audit` |
| 后台有确认与影响说明 | ✅ 开启维护时弹出当前在线 / 对局中人数 |
| 客户端能读状态 | ✅ `GET /v1/service-status`（不要登录） |
| 维护时踢掉大厅玩家 | ✅ 2026-10-12 用户拍板要踢；只踢不在对局中的人 |
| **不可穿透的游戏内弹窗** | ❌ 要改客户端，下一轮 |
| **战斗服务器侧** | ❌ 下一轮 |
| **WebSocket 主动推送状态变更** | ❌ 下一轮。本轮客户端靠 `/v1/service-status` 自己问 |
| **统一开局边界（`match_uid` 已开始）** | ❌ 见第三节：真要它需要新的跨服务基建 |

---

## 二 改了哪些文件

**新增**

| 文件 | 作用 |
|---|---|
| `database/035_service_control.sql` | `service_control`（单行开关表）+ `match_entries`（入场名册） |
| `backend/app/service_control.py` | 状态读写、两道闸的纯函数、入场登记、踢人 |
| `backend/app/routes/service_status.py` | `GET /v1/service-status` |
| `backend/tests/test_service_control_stdlib.py` | 29 条，不需要数据库 |

**改动**

| 文件 | 改了什么 |
|---|---|
| `backend/app/routes/ws.py` | 握手时挡新准入（放过在对局中的人） |
| `backend/app/routes/loadout.py` | 发名片挡新准入 + **签发时登记入场** |
| `backend/app/routes/matchmaking.py` | `_service_gate()`，用在 `POST /queue` 与 `POST /accept` |
| `backend/app/routes/party.py` | `POST /start` 同一道闸 |
| `backend/app/battle_report.py` | 战报到达时按 `match_uid` 清名册 |
| `backend/app/maintenance.py` | 定时清理加一项：陈旧入场登记 |
| `backend/app/admin.py` | `service_control_state()` / `set_service_control()` |
| `backend/app/routes/admin.py` | `GET`/`PUT /admin/api/service-control` |
| `backend/app/schema_check.py` | 035 两条 prepare，漏跑会在启动时喊出来 |
| `backend/app/main.py` | 挂载 `/v1/service-status` |
| `backend/admin_web/admin.js` | 新增「维护」页签 |
| `backend/tests/test_matchmaking.py` | 替身池补 `fetchrow`/`fetch`；+9 条闸的用例 |

---

## 三 🔴 最要紧的一个设计判断：「谁还在打」只认服务器自己的账

维护要「停新准入、不打断存量局」，就必须回答：**这条连接上的人是不是正在一局里？**

现有的两个信号**都不能用**，它们都是客户端自报的：

- `admission.parse_intent` 的 `RESUME` —— 它自己的注释写着「来意是客户端自报的」
- `player_presence.in_match` —— `database/032` 的注释写着「谎报只能让自己的好友看到一个错的状态，**拿不到任何东西**」

032 那句话在它自己的场景里成立，但**换到这里就不成立了**：一旦拿它当维护准入依据，谎报就从「没好处」变成「能绕过维护」。那是人人可用的绕过口。

账号服务器自己知道的权威事实只有一条：**每一张出战名片都是它签的**（`loadout.issue_card`，私钥在它机器上）。玩家要进战斗服务器就必须来领名片。所以本轮在签发那一刻记一笔 `match_entries`，战报到了就删，陈旧行定时清。

为什么不用 matchmaking 现成的分配登记（`assignment_for`）：

- 它只活 **300 秒**（`ASSIGNMENT_TTL_SEC`），一局远不止 5 分钟
- 它在**内存**里，重启就空（验收 M05 要求状态不被重启清空）
- **自建房的名片不带 `match_uid`**，那些玩家在它那里根本不存在

### 这个判据的已知边界

它判的是「服务器放这个人进过一局，且时间还在 `MATCH_ENTRY_MAX_AGE_SEC`（45 分钟）内」，**不是**「这一局此刻真的还在打」。所以：

- 领了名片却没进去的人，会被当成「在对局中」最多 45 分钟 —— 维护时他不会被踢。**这是有意选的方向**：判错成「他在打」只是维护慢一点生效，判错成「他在大厅」会把正在打的人踢出去，后者违反 P0。
- 真正的「统一开局边界」（任务书 §七.3.1 要的、以战斗服务确认 `match_uid` 已开始为准）**需要战斗服务器向账号服务器报告开局**，这套东西目前不存在 —— 战报是**结算时**才到、而且由客户端转交。下一轮做客户端弹窗时才真正需要它，**建议复用补丁服务已有的 desired/status 桥**（`patch_service.BattleBridge`）。

---

## 四 三种「读不到状态」，处理方式完全不同

| 情况 | 怎么办 | 为什么 |
|---|---|---|
| 035 没跑（表不存在） | **放行一切** | 表没建 = 维护从来没开过。按「拒绝」处理的话，一次部署顺序失误 = 全服停服 —— 034 漏跑那次已经演示过代价 |
| 读库失败、缓存还新鲜（60 秒内） | 按缓存判 | 抖一下不该改变准入结论 |
| 读库失败且没有可用缓存 | **拒绝新准入** | 任务书 §七.2：无法确定准入状态时拒绝新开局，不能假装正常 |

后台「维护」页签会把这三种分开显示，不会让人对着一个「正常」的界面纳闷为什么开关不生效。

---

## 五 🔴 部署顺序

1. **先**在 Supabase SQL Editor 跑 `database/035_service_control.sql`
2. **再** `deploy/update.sh`

本文件只**新建表**、不改任何现有表，所以**跑完不需要重启后端**（没有缓存执行计划引用新表；`032` 那条「必须重启」是因为它 `alter` 了现有表）。

顺序反了也不会停服 —— 见第四节第一行，代码会把「表不存在」当成「功能没部署」而放行。但那时候后台按开关是**不生效**的，页签上会写明。

部署后自检一眼：

```bash
journalctl -u glory-backend | grep SCHEMA | tail -5
```

看到 `SCHEMA ok` 就对了；出现 `service_control._READ_STATE 对不上当前表结构` 就是 035 没跑。

---

## 六 测试结果（实际跑出来的）

命令：`backend/.venv/Scripts/python.exe -m pytest tests/<文件> -q`，在 `backend/` 下。

🔴 **必须单文件跑。** 全套 pytest 在一个进程里跑是**既有的红**（`tests/*_stdlib.py` 污染 `sys.modules`），和本轮无关。

| 文件 | 结果 |
|---|---|
| `test_service_control_stdlib.py` | **29 passed**（新增） |
| `test_matchmaking.py` | **46 passed**（基线 37 + 新增 9） |
| `test_loadout.py` | 38 passed |
| `test_ws.py` | 22 passed |
| `test_admission.py` | 24 passed |
| `test_admin.py` | 17 passed, 12 skipped（跳过的要真数据库） |
| `test_party_room_stdlib.py` | 27 passed |
| `test_party_matchmaker_stdlib.py` | 11 passed |
| `test_party_invite_behavior.py` | 4 passed |
| `test_party_match_selection_stdlib.py` | 6 passed |
| `test_health.py` | 3 passed |
| `test_battle_report.py` | ⚠️ 5 failed, 44 passed —— **基线就是这 5 条，逐条对比完全相同，与本轮无关** |

### 变异测试（验证断言不是假绿）

每条都确认「改坏 → 转红，还原 → 转绿」：

| 把什么改坏 | 结果 |
|---|---|
| `unknown` 时放行新准入（去掉 fail-closed） | 5 红 |
| `players_in_match()` 读失败回空集合而不是 `None` | 1 红 |
| `allows_matchmaking` 不再受维护影响 | 1 红 |
| 排队不再过闸 | 3 红 |
| 确认不再过闸 | 1 红 |
| 维护时连对局中的人也挡（破坏 P0） | 1 红 |
| 发名片不再登记入场 | 1 红 |

`backend/admin_web/admin.js` 用浏览器引擎实测解析通过（本机没装 Node）。

---

## 七 还没做的手工验收

任务书第十一节 M01–M08 里，本轮能覆盖的只有服务端部分，下面这些**必须等客户端那一轮**，现在不能当作通过：

- M01 大厅弹窗不可穿透、确认后按要求退出
- M03 开关切换与确认、领名片、入场同时发生时的开局边界
- M05 维护中断线重连与**服务重启**后状态不丢（开关状态在数据库里，但没实测过重启）
- M07 WebSocket 断开 / 回前台 / 重复通知只显示一份弹窗
- M08 `/status.json` 过期、同步失败、账号服务停机

另外**生产上还没演练过**。第一次用它维护之前，建议先在测试环境走一遍：开维护 → 看谁被踢、谁没被踢 → 关维护 → 确认匹配开关没被顺带打开。

---

## 八 仍待运营拍板（影响下一轮）

- 个人排位禁赛是否允许当前局打完
- 自建非匹配房、本地教学是否纳入「关闭匹配」（本轮**不纳入**）
- 客户端自退出在安卓 / Windows / iOS 的行为，要实机
