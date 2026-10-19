-- 037: Account levels and new-player race ownership.
-- Run after 031-036, before deploying the expanded shop catalogue.
create table if not exists player_progression (
  player_id uuid primary key references players(player_id) on delete cascade,
  xp integer not null default 0 check (xp >= 0),
  level smallint not null default 1 check (level between 1 and 20),
  updated_at timestamptz not null default now()
);
alter table player_progression enable row level security;

create table if not exists level_up_events (
  player_id uuid not null references players(player_id) on delete cascade,
  level smallint not null check (level between 2 and 20),
  match_uid text not null,
  seen_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (player_id, level)
);
alter table level_up_events enable row level security;

-- Existing accounts keep races that were playable before this change.
-- The grant is guarded: rerunning this migration must never gift races to
-- accounts that registered after the first deployment.
do $$
begin
  insert into one_time_grants (name) values ('037_progression_grandfather')
  on conflict (name) do nothing;
  if not found then
    return;
  end if;
  insert into player_entitlements (player_id, item_id, source)
select p.player_id, c.item_id, 'grant'
from players p
cross join unnest(array[
  'human', 'unit:human_militia', 'unit:human_merchant', 'unit:human_archer',
  'unit:human_swordsman', 'unit:human_mage', 'unit:human_cleric',
  'unit:human_death_servant', 'unit:human_king',
  'god', 'unit:god_priest', 'unit:god_priestess', 'unit:god_guard',
  'unit:god_aurora', 'unit:god_angel', 'unit:god_arbiter',
  'unit:god_archangel', 'unit:god_king',
  'dark', 'unit:dark_imp', 'unit:dark_mage', 'unit:dark_fear',
  'unit:dark_queen', 'unit:dark_scythe', 'unit:dark_suc',
  'unit:dark_doom', 'unit:dark_dragon',
  'undead', 'unit:undead_small', 'unit:undead_poison',
  'unit:undead_parasite', 'unit:undead_spike', 'unit:undead_fly',
  'unit:undead_bomb', 'unit:undead_titan', 'unit:undead_mother'
]) as c(item_id)
where p.deleted_at is null
on conflict (player_id, item_id) do nothing;

  -- Preserve old default four-race loadouts for pre-existing accounts.
  update players set selected_races = array['god','dark','undead','human']::text[]
  where selected_races is null and deleted_at is null;
end
$$;
alter table player_ranked add column if not exists breakthrough_ready boolean not null default false;
alter table player_ranked add column if not exists forest_unlocked boolean not null default false;
alter table player_ranked add column if not exists breakthrough_complete boolean not null default false;
update player_ranked set forest_unlocked = true where score >= 100;
update player_ranked set breakthrough_complete = true where score >= 300;

-- The existing season settlement resets score to zero. Preserve the permanent
-- floors there too, without rewriting the season archive and reward function.
create or replace function keep_ranked_stage_floor() returns trigger
language plpgsql as $$
begin
  new.forest_unlocked := new.forest_unlocked or old.forest_unlocked or new.score >= 100;
  new.breakthrough_complete := new.breakthrough_complete or old.breakthrough_complete
    or new.score >= 300;
  if new.breakthrough_complete then
    new.score := greatest(new.score, 300);
  elsif new.forest_unlocked then
    new.score := greatest(new.score, 100);
  end if;
  return new;
end
$$;
drop trigger if exists ranked_stage_floor on player_ranked;
create trigger ranked_stage_floor before update on player_ranked
for each row execute function keep_ranked_stage_floor();

