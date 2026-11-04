-- 043: 邀请码。一个被邀请人一辈子一行。
--
-- 设计 2026-11-03 和用户逐条拍板；配套 backend/app/invites.py。
--
-- ## 码本身不在这里
--
-- 用的是 players.friend_code（004）。玩家不用记两个码，也不用再造一张码表。
--
-- 🔴 **存 player_id，不存好友码。** 017 注销时会把好友码换成一个没人知道的新码，
--    存码的话关系会在注销那一刻静默断掉，而且没人会发现。好友码只是输入，
--    填码时当场解析成 player_id（同 send_mail）。
--
-- ## 规则（数字都在 .env，见 backend/app/config.py 的 invite_*）
--
--   · 注册后 7 天内能填，一辈子一次，不能填自己
--   · 被邀请人**达到或超过** 5 级时发奖：被邀请人 50 钻、邀请人 100 钻，走邮件进赠送列
--   · 邀请人最多拿 20 份。🔴 **上限算的是「发了奖的」，不是「绑定了的」**：
--     算绑定的话，别人开小号填你的码就能把你的名额烧光，你真朋友反而填不进来。
--
-- 填码窗口与上限**刻意不写进 check 约束**：它们由 .env 控制，写进约束就等于
-- 「改个天数要跑迁移」—— 而要调这些数，通常是上线后发现被刷、急着收紧的时候。
--
-- 可重复执行（if not exists）。🔴 必须在更新账号服务器之前跑。

create table if not exists player_invites (
  -- 被邀请人。**主键 = 一辈子只能被邀请一次**。
  invitee       uuid primary key references players(player_id) on delete cascade,

  inviter       uuid not null references players(player_id) on delete cascade,
  constraint invite_not_self check (inviter <> invitee),

  bound_at      timestamptz not null default now(),

  -- 达标发奖的时刻。null = 绑定了、还没达标。
  rewarded_at   timestamptz,

  -- 奖励走邮件（012），这里指回那两封。
  -- 「这笔钻石是哪个邀请发的」要一直查得到 —— 同 009「流水永不裁剪」。
  -- 邮件行永不删除（012 文件头），所以这两个外键是稳的；真有人手滑删邮件，外键会拦下来。
  invitee_mail  bigint references mails(mail_id),
  inviter_mail  bigint references mails(mail_id),

  -- 邀请人没拿到钱的原因。拿到了就是 null。
  --   capped  = 他已经拿满上限
  --   deleted = 发奖那一刻他已经注销
  -- 🔴 客服最常被问的就是「我邀请了人怎么没钻石」。没有这一列只能靠猜。
  inviter_skipped text,
  constraint invite_skipped_values check (
    inviter_skipped is null or inviter_skipped in ('capped', 'deleted')),

  -- 发奖与被邀请人那封邮件同生同灭。
  -- 邀请人那封**可以没有**（上限用完 / 已注销都是正常情况，不是错误）——
  -- 被邀请人照样该拿他那一份。
  constraint invite_rewarded_has_mail check (
    (rewarded_at is null) = (invitee_mail is null)),

  -- 没发奖就不会有邀请人那封，也不会有跳过原因。
  constraint invite_inviter_side_after_reward check (
    rewarded_at is not null or (inviter_mail is null and inviter_skipped is null)),

  -- 发奖之后，邀请人那边**恰好一样**：要么有邮件，要么有跳过原因。
  constraint invite_inviter_paid_xor_skipped check (
    rewarded_at is null or ((inviter_mail is null) <> (inviter_skipped is null)))
);

-- 算上限（count … where inviter = $1 and rewarded_at is not null）与客服查「他邀请了谁」。
create index if not exists player_invites_by_inviter on player_invites (inviter);

alter table player_invites enable row level security;

comment on table player_invites is
  '邀请关系。被邀请人一辈子一行；达到等级门槛时在同一事务里发两封邮件。码用的是 players.friend_code。';
comment on column player_invites.inviter_skipped is
  '邀请人没拿到奖的原因：capped（已拿满上限）/ deleted（已注销）。拿到了就是 null。';
