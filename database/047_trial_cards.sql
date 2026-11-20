-- 047: 体验卡（种族 / 宠物 / 棋盘皮肤的限时体验，见 backend/app/trial.py）。
--
-- 来源：宠物祈愿、樱花祈愿没抽中时三选一（只给游戏币 / 只给一张卡 / 两样都给）；
--       商城「棋子」页用游戏币买种族体验卡（每个账号、每个种族、每周 1/3/7 天各一次）。
-- 卡先放进背包，玩家点「使用」才开始计时；同一目标再用一张，时长往后叠。
-- 背包里没用的卡永不过期；可以出售（1/3/7 天 = 100/200/300 游戏币）。
--
-- 🔴 体验**不进 player_entitlements**。那张表是「永久拥有」，集齐解锁种族、抽奖的「已拥有」、
-- 邮件领取都只认它 —— 体验卡要是写进去，用一张种族卡就能永久拿到种族。
-- 「能不能用」= 永久拥有 ∪ 正在体验，只在出战校验那几处合起来看（trial.read_usable）。
--
-- 可重复执行（if not exists / drop constraint if exists）。
-- 🔴 必须在更新账号服务器之前跑：新代码一抽奖就写 pet_draws / skin_draws 的新列，
-- 漏跑的话祈愿、宠物抽取会 500。

-- 背包里的卡：同一目标、同样天数叠成一行。数量用完就删行（不留 0 行）。
create table if not exists player_trial_cards (
  player_id uuid not null references players(player_id) on delete cascade,
  target text not null check (char_length(target) between 1 and 64),
  days smallint not null check (days in (1, 3, 7)),
  count integer not null check (count > 0),
  updated_at timestamptz not null default now(),
  primary key (player_id, target, days)
);
alter table player_trial_cards enable row level security;

-- 正在生效（或已经到期）的体验。到期不删行：到期提醒要靠它，再用一张卡时原地续上。
create table if not exists player_trials (
  player_id uuid not null references players(player_id) on delete cascade,
  target text not null check (char_length(target) between 1 and 64),
  expires_at timestamptz not null,
  -- 到期提醒弹过没有。null = 还没提醒（或还没到期）；再用一张卡续上时置回 null。
  notified_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (player_id, target)
);
create index if not exists player_trials_expiring on player_trials (player_id, expires_at);
alter table player_trials enable row level security;

-- 每周购买限制：每个账号、每个种族、每周 1/3/7 天各一次。week_start = 北京时间那一周的周一。
create table if not exists trial_race_purchases (
  player_id uuid not null references players(player_id) on delete cascade,
  race text not null check (char_length(race) between 1 and 32),
  days smallint not null check (days in (1, 3, 7)),
  week_start date not null,
  op_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (player_id, race, days, week_start)
);
alter table trial_race_purchases enable row level security;

-- 体验卡流水：获得 / 购买 / 使用 / 出售都记一行。客服查「这张卡哪来的、哪去了」靠它，永不裁剪。
-- client_op_id 是购买、使用、出售的防重复键（断网重发用同一个，原样回上次结果）；抽奖发的卡没有它，记 draw_id。
create table if not exists trial_card_ops (
  op_id uuid primary key,
  player_id uuid not null references players(player_id) on delete cascade,
  client_op_id uuid,
  kind text not null check (kind in ('pet_draw', 'skin_draw', 'buy', 'use', 'sell', 'grant')),
  target text not null check (char_length(target) between 1 and 64),
  days smallint not null check (days in (1, 3, 7)),
  -- 卡数量的变化（获得为正，使用 / 出售为负）
  count_delta integer not null check (count_delta <> 0),
  coin_delta integer not null default 0,
  draw_id uuid,
  -- 使用之后的到期时间（只有 use 有）
  expires_after timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists trial_card_ops_client
  on trial_card_ops (player_id, client_op_id) where client_op_id is not null;
create index if not exists trial_card_ops_by_player on trial_card_ops (player_id, created_at desc);
alter table trial_card_ops enable row level security;

-- 宠物抽取：没抽中时可能只给卡、不给游戏币。
alter table pet_draws add column if not exists trial_target text;
alter table pet_draws add column if not exists trial_days smallint;
alter table pet_draws drop constraint if exists pet_draws_check;
alter table pet_draws drop constraint if exists pet_draws_outcome;
alter table pet_draws add constraint pet_draws_outcome check (
  (trial_target is null) = (trial_days is null)
  and (trial_days is null or trial_days in (1, 3, 7))
  and ((pet_id is not null and coin_reward = 0 and trial_target is null)
    or (pet_id is null and (coin_reward = 100 or trial_target is not null))));

-- 樱花祈愿：没出碎片时可能只给卡、不给游戏币。
alter table skin_draws add column if not exists trial_target text;
alter table skin_draws add column if not exists trial_days smallint;
alter table skin_draws drop constraint if exists skin_draws_check;
alter table skin_draws drop constraint if exists skin_draws_outcome;
alter table skin_draws add constraint skin_draws_outcome check (
  (trial_target is null) = (trial_days is null)
  and (trial_days is null or trial_days in (1, 3, 7))
  and ((shards_gained > 0 and coin_reward = 0 and trial_target is null)
    or (shards_gained = 0 and (coin_reward > 0 or trial_target is not null))));
