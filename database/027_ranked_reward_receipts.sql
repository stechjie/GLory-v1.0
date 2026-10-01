-- The ranked reward display reads the exact amount committed for this player and match.
-- Written in the same transaction as match_records, ranked score and wallet_ledger.
create table ranked_reward_receipts (
  match_uid text not null references match_records(match_uid) on delete cascade,
  player_id uuid not null references players(player_id) on delete cascade,
  result text not null check (result in ('win', 'lose', 'draw')),
  coin int not null check (coin between 3 and 15),
  score_before int not null check (score_before >= 0),
  score_after int not null check (score_after >= 0),
  coin_balance_after bigint not null check (coin_balance_after >= 0),
  created_at timestamptz not null default now(),
  primary key (match_uid, player_id)
);

create index ranked_reward_receipts_by_player
  on ranked_reward_receipts (player_id, created_at desc);

alter table ranked_reward_receipts enable row level security;
