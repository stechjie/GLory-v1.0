# database/ —— 数据库结构的唯一真相

这里的 SQL 文件是 Glory 数据库结构的**唯一来源**。不在 Supabase Dashboard 上手点表。

理由和 `docs/CHECKS.md` 那套一样：手点出来的状态没人能复现。有了这些文件，
新建一个 Supabase 项目、换到 AWS RDS、或者在本机起一个 PostgreSQL，
都是把 001 → 002 → 003 依次跑一遍就还原出来。

## 规则

**编号只增不改。老文件永远不动。**

别的机器已经按老文件建过表了，回头改它会让两边对不上 —— 而且不报错，只是结构悄悄不一致。
要改结构就加新文件：

```
001_players.sql            ← 建好之后再也不动
002_player_bio.sql
003_player_identities.sql
...
012_add_players_avatar.sql ← 想给 players 加一列？加这个，不是回去改 001
```

这跟本地存档的做法是同一个概念，只是换了个地方：

| | 本地存档 | 数据库 |
|---|---|---|
| 版本号 | `SaveSchema.PROFILE_VERSION` | 文件编号 001 / 002 / … |
| 升级方式 | `migrate_profile()` 里加一段 | 加一个新 .sql 文件 |
| 老数据 | 读档时就地迁移 | 跑新文件时 `alter table` |

## 代价表（决定要不要"以后再说"时看这个）

| 操作 | 难度 |
|---|---|
| 加一张新表 | 🟢 零风险 |
| 加一列（可空或带默认值） | 🟢 PostgreSQL 里瞬时完成，不锁表 |
| 给已有列加 `not null` | 🟡 要先给老数据回填 |
| 改一列的**含义** | 🔴 要写数据迁移脚本 |
| 改主键 / 改外键指向谁 | 🔴🔴 要动所有表 |

最后一行就是 `player_id` 必须在第一天定死的全部理由（见 `docs/账号系统RFC.md` 第四节）。

## 内容 id 会改名，数据库要跟着改

数据表里的 id 不是永恒的。`SaveSchema.PET_ID_RENAMES` 里就留着一次：
`pet_duck` → `pet_rabbit`（美术做完后改的名）。

本地存档靠读档时改写来处理。**数据库里存的 id 同样要改**，否则玩家会拥有一个
数据表里已经不存在的东西。那也是一个新编号文件，例如 `0XX_rename_pet_ids.sql`。

这件事直接关联 `docs/联机审计与整改方案.md` 的 `C11`（数据表哈希校验）——
两边表对不上时，现在**没有任何机制能发现**。

## 怎么跑

Supabase Dashboard → SQL Editor，按编号顺序逐个执行。
以后接了 Supabase CLI 再改成 `supabase db push`。

## 当前清单

| 文件 | 内容 |
|---|---|
| `001_players.sql` | 账号本体。`player_id` / 显示名 / 时间戳 |
| `002_player_bio.sql` | 玩家自愿填写的展示资料。性别 / 生日月日 / 地区 |
| `003_player_identities.sql` | 登录方式 → `player_id` 的映射。**不存任何凭证** |
| `004_profile_display.sql` | 玩家资料的展示字段。头像 / 头像框 / **好友码** / 改名冷却 / 签名 / 三个可见性开关 |
| `005_friends.sql` | 交友系统。好友关系 / 拉黑 / 请求日志 / 在线状态 |
| `006_room_visits.sql` | 房间访问记录。「最近一起玩过」的同房关联 |
| `007_chat.sql` | 好友私聊。会话 / 消息 / 已读游标。仍是好友时每对只存最近 200 条；删好友后再留 30 天 |
| `008_announcements.sql` | 公告。**管理员在 Supabase 后台直接改行**（这一张是例外，见文件头）；账号服务器只写 problem 列。撤下不删 |
| `009_wallet.sql` | 账号钱包与流水。钻石**分付费 / 赠送两列**、黄金一列；流水只追加。附 `grant_diamonds()`，手工发放的唯一入口 |
| `010_shop.sql` | 商城归属与订单。归属存**内容 id**不存商品 id；订单幂等键 `(player_id, client_order_id)`；`external_id` 唯一索引留给充值去重 |
| `011_loadout.sql` | 出战种族搬到账号服务器（`players.selected_races`）。出战名片要给它盖章，账号服务器得先知道它。只管格式，「必须几个」归战斗服务器 |

## 一条硬规则

**所有表一律 `enable row level security` 且默认零 policy。**

Godot 不直连 Supabase，一切经过 FastAPI（用 secret key，绕过 RLS）。
零 policy 意味着通过 Data API 谁都读不到。需要客户端直读时，
为那个具体场景单独加 policy —— 不要一开始就开口子。

配套：建项目时 `Automatically expose new tables` 必须关掉。
