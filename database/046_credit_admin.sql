-- 046: 信誉分与惩罚累加可以人工干预
--
-- 设计见 docs/排位系统设计.md 第四节（信誉分本体）、docs/运营后台设计.md 第四节。
-- 配套 backend/app/ranked.py、backend/app/admin.py、backend/app/routes/admin.py、
-- backend/admin_web/admin.js。
--
-- 001-045 一个字都不改 —— 编号只增不改，见 database/README.md。
--
--
-- ## 一 为什么要这个
--
-- 014 的惩罚是**全自动**的：跑路和没按准备各自按最近 7 天里的次数升档，扣多少分、
-- 禁多久都跟着次数涨。它算得对的时候很好用；算错的时候**谁都救不了** ——
-- 后台今天连信誉分都改不了，更不用说那个根本看不见的次数。
--
-- 最典型的算错是服务器自己出事：账号服务器或战斗服务器抖一下，一批人被判成
-- 「对局结束时人不在」。他们不只是白扣一次分 —— 那一次会**在 7 天窗口里一直待着**，
-- 接下来一周他正常跑路一次，就按第 2 档罚。玩家完全看不懂为什么变重了。
--
-- 所以这次开三个人工入口：信誉分本身、累加的次数、自动禁赛的到期时间。
--
--
-- ## 二 🔴 次数没有计数器列，所以「清空累加」= 把那几行标成已撤销
--
-- 014 特意没有存计数器（它的文件头算过账：有了计数器就要回答「什么时候清零」，
-- 而那个问题两种直觉答案都是错的）。次数是每次结算时在 credit_events 上现数出来的。
--
-- 所以人工减少次数只能作用在事件行上。做法和 016 封号、019 禁言一致：
-- **不删行，打 revoked_* 标记**，计数查询排掉已撤销的那些。
-- 删行的话，出了争议就再也查不到「他到底哪几次跑了、谁给撤的、为什么」。
--
-- 反过来，人工增加次数是**补写一行**，kind 照旧是 abandon / no_accept，只是 actor
-- 记上管理员。不另开一个 kind —— 新 kind 不会被计数查询数到，记了等于没记。
--
--
-- ## 三 撤销一笔 = 当作没发生过
--
-- 撤销同时做两件事：那一笔不再计入次数，**当时扣的分也退回去**。
-- 拆成两个按钮（「只退分」「只清次数」）看着更灵活，实际上是个陷阱：
-- 只退分的话那次跑路还在窗口里，他下次跑路仍然按更高一档罚 —— 而退了分的管理员
-- 会以为自己已经把事情办完了。两件事必须一起发生，所以只给一个动作。
--
-- 禁赛另算：banned_until 只是一个时间戳，看不出是哪一笔造成的，所以撤销时由后台
-- 显式问一句「要不要顺便解除禁赛」，不在这里猜。
--
--
-- ## 四 🔴 部署
--
--   ① Supabase SQL Editor 跑本文件 → ② deploy/update.sh。
--
-- 跑完**不用重启后端**：本文件只加可空列、放宽一条 check，不动任何函数
-- （和只建表的 035 一样，不是重建函数的 036 那种）。
--
-- 🔴 **顺序不能反，反了的后果比「后台用不了」大得多**：新代码的 window_count
-- 查 revoked_at，而它在**每一局排位结算的路上**（ranked._settle_credit）。旧库上
-- 那句话会报列不存在，整个结算事务回滚 —— 那一局所有人的积分、信誉分一起丢，
-- 战报也存不进。和 041 同一个形状。
--
-- 反过来先跑本文件、后上代码是安全的：旧代码不认识新列，它只往老列里写。
--
-- 🔴 **约束放宽这一类，启动自检的 prepare 抓不到**（语句本身完全合法，要到真 insert
-- 那一刻才被拒）—— 和 030、036、040 同一个形状。app/schema_check.py 里给它加了
-- 直接问系统表的探针，别删。
--
-- 幂等：加列用 if not exists、约束先 drop 再 add，手工跑两遍安全。
-- 🟢 不锁表：加可空列不重写表；约束重验要扫一遍 credit_events，但这张表只有排位
-- 结算在写，行数比钱包流水小一个数量级。


-- ── 一 撤销标记 ──────────────────────────────────────────────────────────────
alter table credit_events add column if not exists revoked_at  timestamptz;
alter table credit_events add column if not exists revoked_by  text;
alter table credit_events add column if not exists revoke_note text;

-- 撤销人必填，理由同 016 unban_player / 036 unmute_player 里的 p_actor：
-- 以后一定会有人问「这笔是谁给撤的」。
alter table credit_events drop constraint if exists credit_event_revoked_by;
alter table credit_events add constraint credit_event_revoked_by
  check (revoked_at is null or (revoked_by is not null and btrim(revoked_by) <> ''));

alter table credit_events drop constraint if exists credit_event_revoke_note_length;
alter table credit_events add constraint credit_event_revoke_note_length
  check (revoke_note is null or char_length(revoke_note) <= 500);

comment on column credit_events.revoked_at is
  '管理员撤销了这一笔：不再计入「最近 7 天第 N 次」，当时扣的分也已退回。不删行。';
comment on column credit_events.revoked_by is '撤销人（admin_users.name）。撤销时必填。';
comment on column credit_events.revoke_note is '撤销备注。玩家看不到。';


-- ── 二 管理员写的行：操作人与原因 ─────────────────────────────────────────────
--
-- 系统写的行这两列是空的（排位结算不需要「操作人」这个概念）。
alter table credit_events add column if not exists actor  text;
alter table credit_events add column if not exists reason text;

alter table credit_events drop constraint if exists credit_event_reason_length;
alter table credit_events add constraint credit_event_reason_length
  check (reason is null or char_length(btrim(reason)) between 1 and 200);

comment on column credit_events.actor is
  '管理员手动写的那些行记操作人（admin_users.name）；系统结算写的行是空的。';
comment on column credit_events.reason is '管理员填的原因。玩家看不到，只进后台记录。';


-- ── 三 放行 kind = 'admin' ───────────────────────────────────────────────────
--
-- 'admin' 是**纯改分**：管理员直接加减信誉分，不属于任何一种惩罚，所以它不该
-- 被「最近 7 天第 N 次」数到 —— 计数查询只数 abandon / no_accept，天然排除。
--
-- 🔴 反过来，管理员「补记一次跑路」写的不是这个 kind，而是 abandon 本身
-- （见文件头第二节）。那种行靠 actor 不为空来区分。
alter table credit_events drop constraint if exists credit_event_kind_known;
alter table credit_events add constraint credit_event_kind_known
  check (kind in ('abandon', 'no_accept', 'match', 'daily', 'admin'));

comment on column credit_events.kind is
  'abandon 跑路 / no_accept 没按准备 / match 正常打完 / daily 每天恢复 / admin 管理员改分。'
  '只有 abandon 与 no_accept 计入「最近 7 天第 N 次」。';

comment on table credit_events is
  '信誉分流水。只追加 ——「7 天内第 N 次」是在这张表上数出来的（排掉 revoked_at 不为空的行）';
