-- 031: 赤律族改成「商城集齐 8 个棋子解锁」，上线前已有的账号一次性补发
--
-- 配套 data/shop.json（8 个 kind=unit 棋子 + 一行 kind=race 的赤律族）、
-- backend/app/shop.py 的 grant_content（买到第 8 个时同一事务发种族）。
--
-- ## 为什么要补发
--
-- 赤律族上线时是免费的（不在 data/shop.json 里 = 人人可用）。它一进商城目录，
-- shop.requires_entitlement('crimson') 就变成 true，没有归属行的人：
--   - 存不进出战种族（loadout.save_races 回 race_not_owned）；
--   - 已经选了赤律族的，出战名片会把它去掉（loadout.build_loadout），
--     战斗服务器凑不够 4 族就整份换成默认 —— 不报错，玩家只会发现赤律族没了。
-- 那是对已经在用它的玩家的回收（shop.json 顶上 _free_by_omission 那一条）。
-- 拍板（2026-10-10）：老玩家不干涉，这次更新之后注册的新玩家才需要去商城买。
--
-- ## 🔴 部署顺序：先跑这个文件，再部署新的 data/shop.json
--
-- 反过来的话，中间那段时间里老玩家的赤律族会被名片去掉。
--
-- ## 🔴 只能生效一次
--
-- 「老玩家」= 这个文件**第一次**执行时已经存在的账号。之后再执行一遍（手滑、换库重放）
-- 绝不能把赤律族白送给之后注册的新玩家 —— 所以用 one_time_grants 记一笔，
-- 已经记过就整段跳过。全新建库时依次跑到这里，players 是空的，等于什么都不发，也是对的。

create table if not exists one_time_grants (
  name    text primary key,
  constraint one_time_grant_name_length check (char_length(name) between 1 and 64),
  ran_at  timestamptz not null default now(),
  -- 发了多少行，事后对账用。
  granted bigint not null default 0
);

alter table one_time_grants enable row level security;

comment on table one_time_grants is
  '一次性补发的执行记录。name 已存在 = 已经发过，迁移文件据此跳过，重跑不会多发。';

do $$
declare
  rows_granted bigint;
begin
  insert into one_time_grants (name) values ('031_crimson_grandfather')
  on conflict (name) do nothing;
  if not found then
    raise notice '031 已经执行过，跳过（再发一次会把赤律族送给之后注册的新玩家）';
    return;
  end if;

  -- 种族 + 8 个棋子一起发：商城面板按棋子数点亮 logo，只发种族的话老玩家会看到「0 / 8」。
  -- source = grant（手工发放），同 shop.SOURCES；order_id 留空，没有订单。
  insert into player_entitlements (player_id, item_id, source)
  select p.player_id, c.item_id, 'grant'
    from players p
    cross join unnest(array[
      'crimson',
      'unit:crimson', 'unit:dancer', 'unit:drumer', 'unit:hunter',
      'unit:armbreaker', 'unit:Icey', 'unit:skypierce', 'unit:lattern'
    ]) as c(item_id)
   where p.deleted_at is null
  on conflict (player_id, item_id) do nothing;
  get diagnostics rows_granted = row_count;

  update one_time_grants set granted = rows_granted where name = '031_crimson_grandfather';
  raise notice '031 赤律族补发完成：% 行', rows_granted;
end
$$;
