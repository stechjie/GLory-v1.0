-- 010: 商城归属与订单
--
-- 配套 009_wallet.sql（钱）与 data/shop.json（目录）。
-- 设计见 docs/商城系统设计.md 第四、六节。

-- ============================================================================
-- 归属
-- ============================================================================
--
-- 🔴 **存的是「内容 id」，不是「商品 id」。**
--
--     shop_pet_cat   ← 商品 id，只出现在 shop_orders 里
--     pet_cat        ← 内容 id，存这里
--
-- 游戏问的是「他有没有这只猫」，不是「他买过哪个礼包」。分开之后，同一只宠物
-- 可以在不同活动里以不同价格、不同包装上架，都指向同一个内容 id。
--
-- **不在 data/shop.json 里的内容一律免费**，不需要在这张表里有行。
-- 现有那 20 张头像与 frame_default 就是这样 —— 它们上线时是免费的，
-- 不能因为做了商城就变成付费（那是对已经在用它的玩家的回收）。
-- 判定逻辑的唯一实现在 backend/app/shop.py 的 requires_entitlement()。

create table player_entitlements (
  player_id  uuid not null references players(player_id) on delete cascade,

  item_id    text not null,
  -- 任何会被写进库的字符串都要有上限，同 players.player_name 那条
  -- （docs/联机审计与整改方案.md 的 A12）。这个值来自服务端目录而不是客户端，
  -- 但上限是最后一道，不看来源。
  constraint entitlement_item_length check (char_length(item_id) between 1 and 64),

  granted_at timestamptz not null default now(),
  source     text not null,   -- shop / iap / grant / starter_pick
  constraint entitlement_source_length check (char_length(source) between 1 and 32),

  order_id   uuid,

  -- 退款收回。**不删行** —— 删了就查不出「他买过又被退了」，
  -- 而那正是客服最常问的一件事。
  --
  -- ⚠️ 退款之后又重新买：**把这一列置回 null，不是插新行**（主键挡着）。
  -- 实现见 backend/app/shop.py 的 _grant()。
  revoked_at timestamptz,

  primary key (player_id, item_id)
);

-- 主键 (player_id, item_id) 已经覆盖了「列出某人拥有的全部」，不另建索引。

alter table player_entitlements enable row level security;

comment on table  player_entitlements            is '非消耗品归属。存内容 id（pet_cat），不存商品 id（shop_pet_cat）。';
comment on column player_entitlements.item_id    is '内容 id。不在 data/shop.json 里的内容一律免费，不需要有行。';
comment on column player_entitlements.revoked_at is '退款收回的时刻。重新购买时置回 null，不插新行。';


-- ============================================================================
-- 订单
-- ============================================================================

create table shop_orders (
  order_id        uuid primary key,
  player_id       uuid not null references players(player_id) on delete cascade,

  -- 幂等键。客户端给每次购买生成一个 uuid，弱网下重试时带同一个 ——
  -- 服务端靠它认出「这笔已经处理过了」，重放原回执而不是再扣一次钱。
  -- 与 chat_messages.client_msg_id 是同一套做法（database/007_chat.sql）。
  client_order_id uuid not null,

  item_id         text not null,   -- **商品** id（shop_pet_cat），不是内容 id
  constraint order_item_length check (char_length(item_id) between 1 and 64),

  currency        text not null,
  constraint order_currency check (currency in ('diamond', 'coin')),

  -- 🔴 **下单时的价格，绝不 join 目录去取。**
  -- 搞活动降价那天，历史订单的金额会集体变化，对账直接废。
  price_snapshot  bigint not null,
  constraint order_price_non_negative check (price_snapshot >= 0),

  -- ok / refunded。**没有 rejected。**
  --
  -- 拒绝（余额不足、已拥有、商品不存在）一律不落库，理由有两条：
  --   1. 拒绝是幂等的 —— 同样的输入永远得到同样的拒绝，不需要记下来重放；
  --   2. 落了库就会被重放。「余额不足 → 去充值 → 用同一个 client_order_id 重试」
  --      会被重放成失败，而玩家看到的是「我明明有钱了」。
  -- 代价是订单表里看不到失败尝试，那些在日志里。
  status          text not null,
  constraint order_status check (status in ('ok', 'refunded')),

  source          text not null,   -- shop / iap / grant / starter_pick
  constraint order_source_length check (char_length(source) between 1 and 32),

  -- 渠道订单号 / Google Play 的 purchase token。第一版恒为空，充值时才填。
  external_id     text,
  constraint order_external_length check (external_id is null or char_length(external_id) between 1 and 256),

  created_at      timestamptz not null default now(),
  settled_at      timestamptz,

  constraint shop_order_client_unique unique (player_id, client_order_id)
);

-- 🔴 充值去重靠它：**Google 的 RTDN 会重复推同一笔**，而且顺序不保证。
-- 第一版没有 external_id，所以这个索引现在是空的 —— 它在这里是为了
-- 接充值时不用动一张已经有真实数据的表。
create unique index shop_orders_external
  on shop_orders (source, external_id) where external_id is not null;

-- 客服 / 对账查一个玩家的订单。
create index shop_orders_by_player on shop_orders (player_id, created_at desc);

alter table shop_orders enable row level security;

comment on table  shop_orders                 is '商城订单。幂等键是 (player_id, client_order_id)。拒绝不落库。';
comment on column shop_orders.price_snapshot  is '下单时的价格。绝不 join 目录 —— 改价不能让历史订单的金额跟着变。';
comment on column shop_orders.external_id     is '渠道订单号 / purchase token。第一版恒空，充值时才填；唯一索引用于 RTDN 去重。';
