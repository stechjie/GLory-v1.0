-- Seven cumulative daily claims. The account service calculates the game day in
-- Asia/Kuala_Lumpur; both constraints are a final guard against duplicate grants.
create table if not exists seven_day_login_claims (
  player_id uuid not null references players(player_id) on delete cascade,
  day smallint not null check (day between 1 and 7),
  game_day date not null,
  reward_type text not null,
  reward_amount int not null default 0,
  claimed_at timestamptz not null default now(),
  primary key (player_id, day),
  unique (player_id, game_day)
);

alter table seven_day_login_claims enable row level security;
comment on table seven_day_login_claims is
  'Seven cumulative login claims; account server locks players row and grants reward in the same transaction.';
