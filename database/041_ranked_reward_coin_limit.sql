-- 041: ranked victories pay 15..20 coins; 027 still capped receipts at 15.
-- A 16..20 coin receipt rolled back the entire report transaction, including
-- every player's score, wallet, XP and receipt. Keep all historical 3..15 rows.
-- Run before deploying the account backend; rerunning is safe.
-- This changes no balances and does not replay or fabricate missing reports.

begin;
alter table ranked_reward_receipts
  drop constraint if exists ranked_reward_receipts_coin_check;
alter table ranked_reward_receipts
  add constraint ranked_reward_receipts_coin_check check (coin between 3 and 20);
commit;
