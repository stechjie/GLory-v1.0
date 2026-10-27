-- 040: 充值（真钱买钻石）
--
-- 设计见 docs/充值系统设计.md 第三节。配套 backend/app/iap.py、data/iap_products.json。
-- 001-039 一个字都不改 —— 编号只增不改，见 database/README.md。
--
-- 🔴 **必须在更新账号服务器之前跑。** 新代码读钱包时就要 diamond_debt 这一列，
-- 漏跑的话商城、抽宠物、邮件领取、七日登录、升级奖励**全部 500**
-- （启动自检会在 journalctl 里打 SCHEMA 不一致）。跑完要重启账号服务器（DDL 之后旧连接的查询计划会报错）。
--
-- 写法带 if exists / if not exists，手工执行两遍也安全。


-- ============================================================================
-- 一、欠账
-- ============================================================================
--
-- 退款时钻石已经花掉、扣不回来的那部分记在这里（docs/充值系统设计.md 第七节）。
-- 不能把余额扣成负数：009 的 wallet_non_negative 是钱包的最后一道，不为退款放开它。

alter table player_wallets
  add column if not exists diamond_debt bigint not null default 0;

alter table player_wallets drop constraint if exists wallet_debt_non_negative;
alter table player_wallets
  add constraint wallet_debt_non_negative check (diamond_debt >= 0);

-- 🔴 有欠账时付费、赠送两列一定是 0。
--
-- 只在两列都扣光之后才记欠账，而任何钻石入账都先还欠账（backend/app/shop.py 的 settle_debt），
-- 所以这条一直成立。约束是那段代码写错时的兜底：宁可让那笔写失败回滚，
-- 也不能出现「欠着 300 又有 500 余额」—— 那时游戏里显示的数和他真正能花的对不上。
alter table player_wallets drop constraint if exists wallet_debt_exclusive;
alter table player_wallets
  add constraint wallet_debt_exclusive
  check (diamond_debt = 0 or (diamond_paid = 0 and diamond_free = 0));

comment on column player_wallets.diamond_debt is
  '欠账：退款时扣不回来的钻石。有欠账时付费、赠送两列一定是 0；任何钻石入账先还它。';

-- 流水的 currency 与钱包列名一一对应（009），多了一列就要放行一个名字。
alter table wallet_ledger drop constraint if exists wallet_ledger_currency;
alter table wallet_ledger
  add constraint wallet_ledger_currency
  check (currency in ('diamond_paid', 'diamond_free', 'coin', 'diamond_debt'));


-- ============================================================================
-- 二、真钱订单
-- ============================================================================
--
-- **不复用 shop_orders。** 商城订单是「花钻石买东西」：状态只有 ok / refunded，明文规定拒绝不落库。
-- 真钱订单要先存一张「待付款」的单（Steam 要服务器先下单；Google / Apple 要把订单号塞进付款请求），
-- 还要记平台、环境、真钱币种。

create table if not exists iap_orders (
  -- 服务器生成。Google 的 obfuscatedProfileId、Apple 的 appAccountToken 都填它。
  order_id        uuid primary key,

  -- Steam 的 orderid 必须是 64 位整数，用它。
  order_no        bigint generated always as identity,
  constraint iap_order_no_unique unique (order_no),

  player_id       uuid not null references players(player_id) on delete cascade,

  -- 幂等键。弱网下重试建单带同一个，拿回同一张单（同 shop_orders.client_order_id）。
  client_order_id uuid not null,
  constraint iap_order_client_unique unique (player_id, client_order_id),

  platform        text not null,
  constraint iap_order_platform check (platform in ('google', 'apple', 'steam')),

  -- diamond_pack_N，也是三家后台的商品编号。
  product_id      text not null,
  constraint iap_order_product_length check (char_length(product_id) between 1 and 64),

  -- pending → credited / cancelled；credited → refunded。
  status          text not null default 'pending',
  constraint iap_order_status check (status in ('pending', 'credited', 'cancelled', 'refunded')),

  -- sandbox = 测试单（许可测试员、TestFlight、Apple 审核员、Steam 沙盒）。待付款时可能还不知道，留空。
  environment     text,
  constraint iap_order_environment check (environment is null or environment in ('production', 'sandbox')),

  -- 去重键：Google = 付款凭证的 sha256（凭证本身太长且长度不定）、Apple = transactionId、Steam = transid。
  external_id     text,
  constraint iap_order_external_length check (external_id is null or char_length(external_id) between 1 and 128),

  -- Google 的原始付款凭证。退款通知只带它，服务器补消耗也要它。
  purchase_token  text,
  constraint iap_order_token_length check (purchase_token is null or char_length(purchase_token) <= 4096),

  -- Steam 单子付款的那个 Steam 账号。
  steam_id        text,
  constraint iap_order_steam_id check (steam_id is null or steam_id ~ '^[0-9]{1,20}$'),

  -- 入账时实际给了多少（快照）。退款按它扣，绝不按目录重算 —— 改了档位，历史订单不能跟着变。
  diamond_paid    bigint not null default 0,
  diamond_free    bigint not null default 0,
  constraint iap_order_diamonds check (diamond_paid >= 0 and diamond_free >= 0),

  -- 这一单是不是首充双倍。
  first_bonus     boolean not null default false,

  -- 平台告诉我们的价格，最小货币单位（sen / cent）。只作参考，结算以平台报表为准。
  price_amount    bigint,
  price_currency  text,
  constraint iap_order_price check (
    (price_amount is null and price_currency is null)
    or (price_amount >= 0 and price_currency ~ '^[A-Z]{3}$')),

  -- 取消、退款的原因（test_daily_limit / steam_declined / 平台给的退款原因 …）。
  note            text,
  constraint iap_order_note_length check (note is null or char_length(note) <= 200),

  created_at      timestamptz not null default now(),
  credited_at     timestamptz,
  -- Google 消耗成功的时间。Apple 由客户端 finish、Steam 的扣款就是核实那一步，这两家恒空。
  consumed_at     timestamptz,
  refunded_at     timestamptz,

  -- 入过账的单，环境、去重键、入账时间都必须有 —— 少一样，退款和对账就找不到它。
  constraint iap_order_credited_complete check (
    status not in ('credited', 'refunded')
    or (environment is not null and external_id is not null and credited_at is not null)),
  constraint iap_order_refunded_complete check (status <> 'refunded' or refunded_at is not null)
);

-- 🔴 去重靠它：同一张付款凭证不能入两张单；Google 的实时通知会重复推同一笔。
create unique index if not exists iap_orders_external
  on iap_orders (platform, external_id) where external_id is not null;

-- 客服 / 运营后台查一个玩家的单。
create index if not exists iap_orders_by_player on iap_orders (player_id, created_at desc);

-- 定时对账扫待付款的单（第 2 步）。
create index if not exists iap_orders_pending on iap_orders (platform, created_at) where status = 'pending';

alter table iap_orders enable row level security;

comment on table  iap_orders              is '真钱订单。幂等键 (player_id, client_order_id)；去重键 (platform, external_id)。永不裁剪。';
comment on column iap_orders.external_id  is 'Google = 付款凭证 sha256、Apple = transactionId、Steam = transid。';
comment on column iap_orders.diamond_paid is '入账时进付费列的钻石。退款按它扣。';
comment on column iap_orders.diamond_free is '入账时进赠送列的钻石（加送 / 首充那份 / 测试单的全部）。退款按它扣。';


-- ============================================================================
-- 三、首充资格
-- ============================================================================
--
-- 每档第一次买双倍，按账号算、全平台共用。入账时 insert … on conflict do nothing，
-- **插进去了 = 这一单双倍**；和钱包行锁在同一个事务里，两笔同档的单同时到也只有一笔拿得到。
-- 测试单不插（不占资格）。退款不删（不恢复资格）。

create table if not exists iap_first_bonus (
  player_id  uuid not null references players(player_id) on delete cascade,
  product_id text not null,
  constraint iap_first_bonus_product_length check (char_length(product_id) between 1 and 64),
  order_id   uuid not null references iap_orders(order_id),
  granted_at timestamptz not null default now(),
  primary key (player_id, product_id)
);

alter table iap_first_bonus enable row level security;

comment on table iap_first_bonus is '首充资格已用掉的档位。一行 = 这个号这一档不再双倍。退款不删。';


-- ============================================================================
-- 四、删掉 010 给充值留的预留
-- ============================================================================
--
-- 010 在 shop_orders 上预留了 external_id 和唯一索引，打算充值时往商城订单里塞。
-- 现在另开了 iap_orders，这两样永远用不上，留着就是地雷（下一个人会以为充值去重在那里）。
-- 线上这一列全是空值，删它不影响任何数据。

drop index if exists shop_orders_external;
alter table shop_orders drop column if exists external_id;
