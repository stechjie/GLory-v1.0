-- 035: 服务控制（全局维护 / 关闭排位与休闲匹配）+ 入场登记
--
-- 配套：backend/app/service_control.py（状态读写与各道闸）、
-- backend/app/routes/service_status.py（GET /v1/service-status，客户端读）、
-- backend/app/routes/admin.py（后台「维护」页签）。
-- 需求来源：docs/后台功能完善_核对结论_20261012.md 的 OPS-05。
--
--
-- ## 一 为什么要两张表，而不是一张
--
-- `service_control` 是**管理员设的意图**（要不要维护、要不要关匹配）。
-- `match_entries` 是**服务器自己的账**（它放了谁进哪一局）。两件事，两张表。
--
--
-- ## 二 match_entries：为什么非要它不可
--
-- 维护打开时要「停止新准入、但别打断已经在打的人」。于是必须回答一个问题：
-- **这条连接上的人，是不是正在一局里？**
--
-- 🔴 现有的两个信号**都不能用**，它们都是客户端自报的：
--
--   · `admission.parse_intent` 的 RESUME —— 它自己的注释写着「来意是客户端自报的」。
--   · `player_presence.in_match` —— database/032 的注释写着「与 room_id 同一个
--     信任级别：谎报只能让自己的好友看到一个错的状态，**拿不到任何东西**」。
--
-- 注意 032 那句话在它自己的场景里是对的，但**换到这里就不成立了**：
-- 一旦拿它当维护准入的依据，谎报就从「没好处」变成「能绕过维护」。
-- 这是个人人可用的绕过口，不能这么做。
--
-- 账号服务器**自己**知道的权威事实只有一条：**每一张出战名片都是它签的**
-- （backend/app/loadout.py 的 issue_card，私钥在它自己机器上）。
-- 玩家要进战斗服务器就必须来领名片，所以「签过名片」= 它亲手放这个人进了那一局。
--
-- 那为什么不用 matchmaking 的分配登记（`assignment_for`）？
--   · 它只活 **300 秒**（ASSIGNMENT_TTL_SEC），而一局远不止 5 分钟 ——
--     开局 5 分钟后那份登记就没了，人还在打。
--   · 它在**内存**里，重启就空（验收 M05 要求「状态不被重启清空」）。
--   · 自建房的名片**不带** match_uid（routes/loadout.py 只在匹配分配存在时才填），
--     所以自建房玩家在它那里完全不存在。
-- 所以这里登记的是**每一次发名片**，不管有没有 match_uid。
--
-- 清理有两条路，缺一不可：
--   1. 战报到了就删（backend/app/battle_report.py）—— 正常结束走这条。
--   2. 定时扫掉超过 MATCH_ENTRY_MAX_AGE 的行（backend/app/maintenance.py）——
--      战报丢了 / 对局崩了 / 玩家领了名片就没去，走这条兜底。
--      🔴 没有第 2 条的话，这张表会变成「只增不减」，而且那些陈旧行会让
--      维护时**永远踢不掉**那些人。005 的 friend_request_log 就是这么一直涨到 09-11 的。
--
-- ⚠️ 它和 `match_records`（013/023，战绩历史）是两回事：那张表是**打完**才写的事后记录，
-- 这张表是**正在进行**的名册。别把战绩建在这张表上。
--
--
-- ## 三 🔴 部署顺序与「表不存在」的处理
--
-- 本文件只**新建表**，不改任何现有表 —— 所以跑完**不需要重启后端**
-- （没有任何缓存执行计划引用这两张新表；032 那条「必须重启」是因为它 alter 了现有表）。
--
-- 但顺序仍然是：① 在 Supabase SQL Editor 跑本文件 → ② deploy/update.sh。
--
-- 🔴 如果顺序反了（代码先上、表还没建），service_control.py 的处理是
-- **当成「这个功能还没部署」，放行一切**，而不是「读不到状态就拒绝新开局」。
-- 两者的区别很要紧：
--   · 表压根不存在 = 维护从来没被打开过 → 放行是正确答案；
--     按「读不到就拒绝」处理的话，一次部署顺序失误就等于全服停服
--     —— 034 漏跑那次已经演示过这个代价了。
--   · 表在、但这一次读失败（数据库抖动） = 真的不知道状态 → 那才按任务书
--     §七.2 末尾「无法确定准入状态时拒绝新开局」处理，详见 service_control.py。
--
-- 幂等：全部 if not exists，手工跑两遍安全。两张都是新表，🟢 不锁任何现有表。


-- ── 服务控制（单行表）──────────────────────────────────────────────────────
create table if not exists service_control (
  -- 单行表的惯用写法：主键恒为 true，插不进第二行。
  only_row boolean primary key default true,
  constraint service_control_single_row check (only_row),

  -- 每次写 +1。后台改配置时带上自己读到的版本号，对不上回 409 让它刷新
  -- （任务书 §二.4：不能以禁用按钮替代服务端并发控制）。
  version bigint not null default 1,

  -- 两个开关**分别存**。解除维护绝不能顺带把之前关掉的匹配打开（任务书 §七.2）。
  maintenance_enabled boolean not null default false,
  -- 注意默认值相反：匹配平时是**开着**的。
  matchmaking_enabled boolean not null default true,

  -- 给玩家看的话。中英分开；空 = 客户端用自己的兜底文案。
  maintenance_notice_zh text not null default '',
  maintenance_notice_en text not null default '',
  matchmaking_notice_zh text not null default '',
  matchmaking_notice_en text not null default '',

  -- 预计恢复时间。**只是说明**，到点不会自动开服（任务书 §七.2）。
  expected_back_at timestamptz,

  -- 审计用。谁、为什么、什么时候改的。
  change_reason text not null default '',
  actor         text not null default '',
  changed_at    timestamptz not null default now(),

  constraint service_control_notice_len check (
    char_length(maintenance_notice_zh) <= 500 and
    char_length(maintenance_notice_en) <= 500 and
    char_length(matchmaking_notice_zh) <= 500 and
    char_length(matchmaking_notice_en) <= 500),
  constraint service_control_reason_len check (char_length(change_reason) <= 500),
  constraint service_control_actor_len  check (char_length(actor) <= 64)
);

-- 建好就放进去那唯一一行，省得代码里到处判「没有行怎么办」。
insert into service_control (only_row) values (true) on conflict do nothing;

alter table service_control enable row level security;
revoke all on service_control from anon, authenticated;

comment on table service_control is
  '全局服务开关（维护 / 关闭排位与休闲匹配）。单行表，写入用 version 做乐观并发。';
comment on column service_control.maintenance_enabled is
  '维护中：拒绝新的游戏准入与新发名片。已在对局中的人不受影响（判据见 match_entries）。';
comment on column service_control.matchmaking_enabled is
  '匹配开关。false = 排位与休闲**一起**关（2026-10-12 用户拍板）。自建房与教学不受影响。';
comment on column service_control.expected_back_at is
  '预计恢复时间，仅用于展示。到点不自动开服。';


-- ── 入场登记：服务器自己的「谁在打哪一局」名册 ──────────────────────────────
create table if not exists match_entries (
  -- 一个人同时只可能在一局里，所以 player_id 就是主键，发新名片直接覆盖。
  player_id uuid primary key references players(player_id) on delete cascade,

  -- 匹配出来的对局有会合键；自建房是空串（routes/loadout.py 只在有分配时才填）。
  -- 空串也要登记 —— 自建房玩家同样在打，同样不该被维护踢掉。
  match_uid text not null default '',

  -- 签发名片的时刻。超过 MATCH_ENTRY_MAX_AGE 就当这局已经结束（兜底清理）。
  entered_at timestamptz not null default now(),

  constraint match_entries_uid_len check (char_length(match_uid) <= 40)
);

-- 战报到了要按 match_uid 批量删（一局六个人）。空串不进索引：自建房没有 uid，
-- 它们只会被按时间的兜底清理扫走，不会有人按 uid 查。
create index if not exists match_entries_match_uid_idx
  on match_entries (match_uid) where match_uid <> '';

-- 兜底清理按时间扫。
create index if not exists match_entries_entered_at_idx on match_entries (entered_at);

alter table match_entries enable row level security;
revoke all on match_entries from anon, authenticated;

comment on table match_entries is
  '服务器自己签发名片的记录 = 「它亲手放了谁进哪一局」。维护时判断谁在对局中只认这张表，'
  '不认客户端自报的 admission intent 或 player_presence.in_match。'
  '战报到达时按 match_uid 删；陈旧行由定时清理兜底。不承载任何战绩数据。';
