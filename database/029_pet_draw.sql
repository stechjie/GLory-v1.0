-- 029: Diamond pet draw, per-player pity, and idempotent receipts.
-- The wallet row lock serializes every draw for the same player.
create table pet_draw_progress (
  player_id uuid primary key references players(player_id) on delete cascade,
  misses smallint not null default 0 check (misses between 0 and 9)
);
alter table pet_draw_progress enable row level security;

create table pet_draws (
  draw_id uuid primary key,
  player_id uuid not null references players(player_id) on delete cascade,
  client_draw_id uuid not null,
  pet_id text,
  coin_reward integer not null default 0 check (coin_reward in (0, 100)),
  price_snapshot integer not null check (price_snapshot = 75),
  misses_after smallint not null check (misses_after between 0 and 9),
  created_at timestamptz not null default now(),
  unique (player_id, client_draw_id),
  check ((pet_id is null and coin_reward = 100) or
         (pet_id is not null and coin_reward = 0))
);
create index pet_draws_by_player on pet_draws (player_id, created_at desc);
alter table pet_draws enable row level security;
