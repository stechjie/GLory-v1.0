-- 042: 钻石抽棋盘皮肤碎片（第一个是樱花，见 backend/app/skin_draw.py、docs/樱花祈愿.md）。
--
-- 每抽 100 钻石，出 1～3 片碎片或 200～300 游戏币；集满 10 片同一事务里发皮肤归属。
-- 第 10 抽碎片不够就直接补满，所以一张皮肤最多花 1000 钻石。
--
-- 碎片不进 player_entitlements：那张表只管「有 / 没有」（主键 player_id + item_id，
-- 见 docs/商城系统设计.md 第十三节「归属表只管非消耗品」），碎片是数量。
--
-- 钱包行锁（shop._lock_wallet）把同一个玩家的抽取串行化，再查 client_draw_id 防重复扣费。
-- 可重复执行（if not exists）。🔴 必须在更新账号服务器之前跑：新代码一抽就写这两张表。

create table if not exists skin_draw_progress (
  player_id uuid not null references players(player_id) on delete cascade,
  skin_id text not null check (skin_id ~ '^prep_skin_[a-z0-9_]{1,54}$'),
  shards smallint not null default 0 check (shards between 0 and 10),
  draws smallint not null default 0 check (draws between 0 and 10),
  updated_at timestamptz not null default now(),
  primary key (player_id, skin_id)
);
alter table skin_draw_progress enable row level security;

create table if not exists skin_draws (
  draw_id uuid primary key,
  player_id uuid not null references players(player_id) on delete cascade,
  client_draw_id uuid not null,
  skin_id text not null,
  shards_gained smallint not null check (shards_gained between 0 and 10),
  coin_reward integer not null check (coin_reward = 0 or coin_reward between 200 and 300),
  price_snapshot integer not null check (price_snapshot > 0),
  shards_after smallint not null check (shards_after between 0 and 10),
  draws_after smallint not null check (draws_after between 1 and 10),
  unlocked boolean not null default false,
  created_at timestamptz not null default now(),
  unique (player_id, client_draw_id),
  -- 一抽要么出碎片、要么给游戏币，不会两样都有或都没有
  check ((shards_gained > 0 and coin_reward = 0) or (shards_gained = 0 and coin_reward > 0))
);
create index if not exists skin_draws_by_player on skin_draws (player_id, created_at desc);
alter table skin_draws enable row level security;
