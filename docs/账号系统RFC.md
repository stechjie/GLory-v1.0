# 账号系统 RFC

> 状态：**第 0 步（`player_id`）已实现并有门禁；其余为设计稿，未实现。**
>
> 本文取代 `docs/状态信封RFC.md` 里"暂不接 Nakama"那条记录（2026-09-07 起作废）。
>
> 配套文档：`docs/联机审计与整改方案.md`（`C14` `A12` `C15` 等编号在那边）、
> `docs/P1经济账本RFC.md`（局内经济已经服务端权威，账号层不重复做那部分）

---

## 一、为什么现在写这份文档

不是因为要开始做账号，而是因为**仓库里躺着一条已经作废的决定**。

`docs/状态信封RFC.md` 的非目标一节写着「不做账号。暂不接 Nakama」，
`docs/联机审计与整改方案.md` 的收尾也写着「`C14` 等 Nakama 账号层」。
这两句是当时对的，但选型今天改了。不改这两处，下一个读到它们的人（包括几个月后的
自己）会按错的前提往下做 —— 这次差点就发生了：一份完全没提 Nakama 的外部方案
被拿来讨论时，没有人第一时间想起仓库里写过 Nakama。

**这份文档的第一职责是让"最后一次成文的决定"是对的。**

第二职责是把`player_id` 那个改动的理由留下来。那段代码看起来只是多了一个字段，
但它挡住的是一类静默丢数据的 bug，注释里塞不下完整的理由。

---

## 二、选型：Supabase + FastAPI

**结论：用 Supabase（Auth + PostgreSQL）+ 自建 FastAPI 后端。不接 Nakama。**

### 推翻了什么

| 时间 | 决定 | 出处 |
|---|---|---|
| 之前 | 账号层用 Nakama，暂缓接入 | `状态信封RFC.md` 非目标、`联机审计与整改方案.md` |
| 2026-09-07 | 改为 Supabase + FastAPI | 本文 |

### 理由

| | Nakama | Supabase + FastAPI |
|---|---|---|
| 覆盖范围 | 账号 + 钱包 + 排行榜 + 匹配 + 存储，一整套 | Auth + Postgres，业务逻辑全部自己写 |
| 服务端逻辑语言 | Lua / Go / TS | Python（仓库里已有 Python 工具链） |
| 迁移成本 | 绑它自己的 storage schema | 普通 Postgres 表，`pg_dump` 就能搬 |
| 与本仓库的契合 | 它替你做决定 | 每一处逻辑都是自己的 |

决定性的一条是**契合**，不是功能多少。这个仓库的做法是每个决定都有理由、都进文档、
都有门禁断言（见 `docs/CHECKS.md`）。Nakama 的"按我的方式来"会持续跟这套做法打架，
而且局内经济已经在 `EconomyLedger` 里服务端权威地做完了 —— 换成 Nakama，
等于把这套逻辑用 Lua 再写一遍，收益是负的。

代价要认：**Supabase 路线要自己写的东西明显更多**（每个接口、每处反作弊、
每笔钱包事务）。接受这个代价。

### 这个选型不锁死什么

第四节的身份模型保证了：Supabase 只是"其中一个 Auth provider"。
将来换 Firebase、Auth0、Steam 或自建，改的是 `player_identities` 一张映射表，
金币 / 单位 / 宝物 / Rank / 战绩一张都不用重新 key。

---

## 三、四层边界

```
① Client            Godot：UI、输入、演出
                      ↓ 只经过 AccountManager 一个门面
② Game Backend      FastAPI：账号资料、钱包、商城、Rank、奖励
                      ↓
③ Battle Backend    Godot headless + ENet：3v3 实时战斗、胜负
                      ↓
④ Infrastructure    Supabase：Auth + PostgreSQL + Storage
```

三条硬规则：

1. **Godot 永远不直连数据库，也不直连 Supabase。** 客户端只认识
   `AccountManager` 这一个门面。仓库里 `NetworkService` / `PlayerProfile` 已经是
   这个模式，`AccountManager` 照着延续，不要新发明一套。
   > 违反的代价很具体：换后端时要改的是几十个 `.gd` 文件，而不是一个。
2. **金币 / 钻石 / 抽卡 / 商城 / 解锁 / Rank / 奖励只能由 ② 修改。**
   客户端和 RLS 都不是权威。RLS 只当第二道保险（挡"玩家 A 读到玩家 B 的私人数据"），
   **不要把升级价格、抽卡概率、赢一局加多少分写进 RLS policy** —— 那是游戏逻辑，
   写进去以后既难改也搬不走。
3. **③ 不因为有了账号而改变职责。** 实时战斗继续走自己的 ENet 服务器。
   Supabase Realtime 最多用于在线状态、好友、通知，**不碰战斗同步**。

### ② 与 ③ 之间的信任链（本文最欠缺的一节，落地前必须补完）

四层图容易让人以为 ② 和 ③ 是并列的两个盒子就完事了，实际最难的是它们之间：

- 客户端拿到 Auth 签发的 JWT 后，怎么在 ENet 握手时把身份交给 ③？
- ③ 凭什么验证这个 JWT —— 自己持公钥验签，还是回问 ②？
- 打完了，③ 把权威结算写回 ② 用什么凭证？
  **必须是服务端之间的 secret，绝不能复用客户端的 token。**

这三个问题现在都没有答案，**并且它们直接依赖 `C14`**（见第六节）。
在 `C14` 落地前不要开始写 ② ↔ ③ 的接口。

---

## 四、身份模型

### `player_id` 是游戏内部唯一的身份

```
player_identities
player_id                          provider    provider_user_id
---------------------------------------------------------------
52c7027a-...                       supabase    a91d3f...   ← 匿名登录也走这行
52c7027a-...                       google      109238...
```

> **2026-09-08 修订：白名单里没有 `local`。** 上一版这里列了一行
> `local ← 设备首次读档时签发`，那是"自建设备登录"的设想。定下用 Supabase
> 匿名登录之后它不成立了，而且**不能**成立：匿名设备登录里 device_id 的地位
> 等同于密码，把它明文存进 `provider_user_id` 就是把密码明文入库 ——
> 一次泄库所有匿名账号全部沦陷，而且它还会出现在客户端日志与崩溃报告里。
> 见 `database/003_player_identities.sql` 里同一处说明。

```
players / player_wallet / player_units / player_inventory
player_mercenaries / player_treasures / player_rank / match_players
      └── 全部只有 player_id 一个外键
```

**任何游戏表里都不允许出现 `supabase_user_id` / `google_user_id` / `steam_user_id`。**
身份系统和游戏数据系统分开，这是整套设计里唯一不可逆的部分。

### 本机签发的 `player_id` 直接成为账号的 `player_id`

这解决了通常很烦的一个问题：**先玩后注册的进度认领**。

设备第一次读档时就签发 `player_id`（第七节，已实现）。首次登录时客户端把它
**报给** `/v1/auth/anonymous`，服务端直接拿它当 `players.player_id`。
于是本地存档与服务器账号从第一天起就是同一个 id，不存在"两个 player_id"的歧义，
也不需要任何"迁移"。

实测确认过：`tools/account_live_check.tscn` 断言服务器返回的 `player_id`
与 `PlayerProfile.player_id` 相等。

它**不是身份凭证** —— 能不能登录完全由 Supabase 的 auth_uid 决定。
如果那个 id 已被占用（同一份存档被复制到两台设备是现实的），服务端回 409，
客户端调 `PlayerProfile.reissue_player_id()` 重签一个，而不是接管别人的账号。

玩家之后要绑邮箱时，Supabase 的匿名用户可**原地升级**成正式账号且 auth uid 不变，
所以 `player_identities` 连新增一行都不用，进度天然延续。

### `player_id` 不是什么

- 不是 `SessionContext.session_token` —— 那是一局一换的重连凭证，不是身份
- 不是 `public_token_id` —— 那是给玩家看的短码
- 不是任何一家 Auth 的用户 id

---

## 五、账号态 vs 设备态

现在 `user://profile.json` 把两类东西混在一起。接账号前必须切开，否则会出现
"在手机上关了震动，PC 上也跟着关了"这种明显错误的同步。

| 跟人走（账号态，将来上云） | 跟设备走（设备态，永远只在本机） |
|---|---|
| `owned_pets` | `screen_shake_enabled` |
| `active_pet` | `flash_effects_enabled` |
| `codex_seen` | `hit_stop_enabled` |
| `needs_starter_pick` | `reduced_motion_enabled` |
| （将来）金币、单位、宝物、Rank | `ui_sound_enabled` |
| | `haptics_enabled` |
| | `board_readability_enabled` |

`player_id` 两边都不属于：它是**这台设备上的身份凭证**，物理上留在本地，
逻辑上是账号的锚点。

> 判据：**换一台性能不同的手机，这个值应不应该跟过去？** 不该跟过去的就是设备态。
> 演出开关全部属于"不该跟过去" —— 玩家在低端机上关掉的东西，
> 不该在高端机上还是关着。

拆分动作本身不在第 0 步里，留到真正接账号时做。**现在先把判据定下来**，
免得那时候逐个字段重新争论。

---

## 六、边界：账号层可以并行开工，但只在 HTTPS 那条链路上

> **本节 2026-09-07 重写。** 上一版把顺序写成"账号层整个排在 `C14` 之后"，
> 那是按一个人串行做写的，不准确 —— 被 `C14` 卡住的只有 ②↔③ 那一段。
> 现在联机栈的阻断项（`A12` / `C11` / 客户端打包 / 真人 3v3 / `C14`）
> 由另一位同事并行推进，账号层可以同时开工。

### 先看清楚：这里有两条链路，安全状况完全不同

```
① Godot ──── HTTPS ────→ ② FastAPI ──→ ④ Supabase     TLS + 服务端身份齐全
① Godot ──── ENet ─────→ ③ 战斗服务器                  明文，客户端验不了对端（C14）
```

**账号系统的绝大部分工作在第一条链路上。那条链路今天就是安全的。**
`C14` 说的是第二条链路 —— 它卡住的不是"账号"，而是"账号身份进入战斗链路"。

### 🟢 可以现在做（全在 ①↔② ，与联机栈零交集）

| 项 | 备注 |
|---|---|
| 建 `glory-dev` Supabase 项目 | Region Singapore；`Automatically expose new tables` 关掉 |
| `/database/NNN_*.sql` | 字段从 `SaveSchema` / `PlayerProfile` / `EconomyLedger` **反推**，不要凭空设计 |
| FastAPI 骨架 | 结构、配置、health、JWT 验签中间件 |
| 注册 / 登录 | Supabase Auth → `player_identities` 映射到第 0 步签发的 `player_id` |
| ~~`AccountManager.gd`~~ | ✅ 已完成，见 `scripts/autoload/AccountManager.gd` |
| 账号态 / 设备态拆分 | 见第五节 |
| ~~本地进度认领~~ | ✅ 已完成 —— 客户端报上 `player_id`，服务端直接采用 |

这一整块做完就是一个完整可用的账号系统：能注册、能登录、能存云端资料、能换设备。
**全程不碰 ENet。**

### 🔴 碰到这三件事就停，等 `C14`

1. **把 JWT 或任何账号凭证通过 ENet 发给 ③。**
   今天发等于明文广播账号凭证。泄漏一个座位 token 只是毁一局，泄漏 JWT 是丢账号。
2. **让 ③ 读写持久化货币。**
   `EconomyLedger` 管的是**局内**经济（备战期买卖合成），纯函数、零全局，很干净。
   跨局的钱只能由 ② 改。
3. **往 `NetProtocol` 加任何带账号身份的字段。**
   一加就进了联机栈的车道，还会顶掉协议号。

这三条的共同点：**全部是 ② 与 ③ 之间的信任链** —— 也就是第三节末尾那三个
"现在没有答案"的问题。`C14` 落地前不要动。

### `C14` 现状（`docs/联机审计与整改方案.md`）

> 传输明文、无服务端身份认证与链路完整性保护 —— 客户端不能验证服务器身份，
> 中间人仍可读改包。⬜ 待做

> **注意：这把原来的顺序倒过来了。** 审计文档原文是"`C14` 等账号层"，
> 前提是 Nakama 自带 TLS 终结的连接 —— 接了它，`C14` 大半自动没了。
> 现在不接 Nakama，实时战斗继续走自己的 Godot headless + ENet，
> 链路安全重新变成我们自己的问题，于是依赖方向反过来：**`C14` 是 ②↔③ 的前置**。
> 审计文档对应处已同步。

### 并行分工与交接点

| 轨道 | 内容 |
|---|---|
| **联机栈**（同事） | `A12` 短码服务端签发、`C11` 数据表哈希、客户端打包、真人 3v3（第一份 L2 证据）、`C14` |
| **账号层** | 上面 🟢 那张表 |

三个必须对齐的点：

1. **`PROFILE_VERSION` 已升到 4**（第七节）。动存档路径的人要知道。
2. **`C14` 的优先级变了** —— 从"等账号层"变成"账号层等它"。
3. **第一个客户端包必须包含 `AccountManager`**，否则那个包验证不了账号路径，
   等于白打一次。打包时间点要提前约。

### 仍然成立的一条

联机栈那 28 个"部分完成"目前**全部只有 L1 证据**（同进程函数探针）。
在拿到 L2 之前，它们只是"源码层面修好了"。这不阻塞 🟢 那张表，
但意味着 ②↔③ 接缝**必须**等真人对局验过 —— 否则那里出问题时，
你要同时怀疑新后端、旧联机栈和接缝三处，而 L1 证据一处都帮不上忙。

---

## 七、第 0 步：已实现

改动范围只有三处，**不联网、不注册、不登录、没有任何一张表**。玩家侧零可见变化。

| 位置 | 做了什么 |
|---|---|
| `SaveSchema` | `PROFILE_VERSION` 3 → 4；新增 `new_player_id()` / `is_valid_player_id()` / `_ensure_player_id()` |
| `PlayerProfile` | 新增 `player_id` 字段；读档三条路径各自保证它存在；`save_profile()` 落盘；坏档先备份到 `user://profile.corrupt.json` |
| `tools/player_identity_check.tscn` | 门禁，709 条断言 |

### 不变量

> **没有合法 id 就签发一次；已经有了就绝对不许再签。**

违反了不会报错、不会崩溃、日志里什么都没有。接上账号之后它的表现是
**玩家每次冷启动都变成新玩家**。这类 bug 靠人工测试发现不了（本机跑一次
永远是"有 id、能进游戏"），只能靠断言挡在上线之前 —— 这就是它值得单开一个
检查场景的原因。

### 三个容易写错的地方

1. **`_ensure_player_id` 不能放进 `if from < 4` 版本分支里。**
   版本号已经是最新、但档案里缺 id 或 id 被写坏的情况同样要补发。
   放进版本分支就会漏掉这种档案，而漏掉就是每次启动重签。

2. **落盘条件不能只看版本号。**
   `PlayerProfile.load_profile()` 结尾原本是"版本比当前低就重存"。
   加了 `player_id` 之后必须再判一次 `盘上的 id != 内存里的 id` ——
   否则上面那种档案签了新 id 却不落盘，下次启动又签一个。

3. **随机源必须是 `Crypto`，不能用 `randi()` 或 `RngService`。**
   `RngService` 是给回放确定性用的，同一个种子在两台设备上产生同一串数，
   拿它签 id 会直接撞号。

### 跑门禁

```bash
Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/player_identity_check.tscn
```

### 一个副产物

原来"全新档案"和"坏档"两条路径是逐字段抄的两份默认值，这次合并成
`_reset_to_defaults()`。两份各改各的迟早会漂。

另外坏档路径原来**只重置内存、不落盘**。现在必须落盘（新签的 id 不写回去就等于没签），
所以覆盖前先把原始字节另存到 `user://profile.corrupt.json` ——
不能让"存档打不开"变成"存档没了"。

---

## 八、非目标（明确不做）

> **2026-09-07 修订。** 上一版这里写着"不做注册/登录/联网""不建任何数据库表" ——
> 那两条的作用域是**第 0 步**，第 0 步已经做完了。它们现在与第六节的 🟢 表直接冲突，
> 因此删掉并重写。真正的边界一律以第六节的 🟢/🔴 为准。

- **不碰 🔴 三条。** JWT 不上 ENet、③ 不读写持久化货币、`NetProtocol` 不加账号字段。
  这是本文档最硬的一条，理由见第六节。
- **不动 `SessionContext.session_token`。** 那是重连凭证，与账号是两回事，
  接了账号之后它仍然存在、仍然一局一换。
- **不凭空设计表结构。** 字段一律从 `SaveSchema` / `PlayerProfile` / `EconomyLedger`
  的实际字段反推。外部方案给的示例 schema（`level` / `exp` 之类）与本游戏对不上，
  不要照抄。
- **不用 Supabase Realtime 做战斗同步。** 在线状态、好友、通知可以，战斗不行。
- **不在 Dashboard 上手点表结构。** SQL 一律进 `/database/NNN_*.sql` 并入 git
  （理由同 `docs/CHECKS.md` 那套：手点出来的状态没人能复现）。
- **不把游戏规则写进 RLS policy。** 升级价格、抽卡概率、赢一局加多少分属于 ②。
  RLS 只挡"玩家 A 读到玩家 B 的私人数据"。

---

## 九、待拍板（落地前必须有答案）

| # | 问题 | 为什么现在还不能定 |
|---|---|---|
| 9.1 | ③ 怎么验 JWT：自持公钥验签，还是回问 ②？ | 取决于 `C14` 用什么方案 |
| 9.2 | ③ → ② 的结算用什么服务端凭证、怎么轮换？ | 同上 |
| 9.3 | 首个 Auth provider 是邮箱密码还是设备匿名登录？ | 影响"先玩后注册"的体验路径 |
| 9.4 | `glory-dev` / `glory-prod` 两个项目怎么隔离数据与密钥？ | 等真正建项目时定 |
| 9.5 | 账号态字段上云时，本地与云端冲突以谁为准？ | 需要先有一版真实字段清单 |
| 9.6 | `player_profiles` 之外的表要不要一次性设计完？ | 倾向不要，按功能分批 |

---

## 附：密钥纪律

| 东西 | Godot / APK | GitHub | FastAPI 服务器 |
|---|---|---|---|
| Project URL | ✅ | ✅ | ✅ |
| Publishable key（`sb_publishable_…`） | ✅ | ⚠️ 可以但没必要 | ✅ |
| Secret key（`sb_secret_…`） | ❌ | ❌ | ✅ |
| 数据库密码 | ❌ | ❌ | ✅ |

Secret key 能绕过 RLS，只能待在 ② 里。仓库已有先例：`export_presets.cfg`
（含 keystore 密码）和 `upload ssh code.txt` 都在 `.gitignore` 里，
Supabase 的密钥按同样规格处理。

> 具体的 key 命名（`sb_publishable_` / `sb_secret_`）是较新的改动，
> 真正建项目时以当时的官方文档为准，不要照抄本文。
