-- 002: 玩家自愿填写的展示资料
--
-- 用途已确认：**社交展示** —— 让交流时的对方能了解一点。不是年龄门禁，
-- 不是用户画像。玩家不填是完全正常的状态，所以每一列都可空。
--
-- 为什么不并进 players：
--   1. players 每个请求都读，这几个字段一个月读一次；
--   2. 大部分玩家不会填，空列不该放在热表里；
--   3. 玩家要求删除个人资料时，删这一行即可 ——
--      players 上挂着所有游戏表的外键，动不得。

create table player_bio (
  player_id   uuid primary key references players(player_id) on delete cascade,

  gender      text,

  -- 只存月日，**不存年份**，这是刻意的。
  --
  -- 用途是展示生日与星座，月日已经足够。存了年份就等于知道谁是未成年人，
  -- 随之而来的是防沉迷（中国）、GDPR-K（欧盟 16 岁以下需监护人同意）、
  -- COPPA（美国 13 岁以下）的一整套义务，以及 Google Play / App Store
  -- 年龄分级问卷里必须对应声明。同样的社交价值，零法律负担。
  --
  -- 将来若真要做年龄门禁，那是另一张表、另一套流程与告知，
  -- **不要在这里加 birth_year**。
  birth_month smallint,
  birth_day   smallint,

  -- ISO 3166-1 alpha-2，例如 MY / CN / SG。这是玩家**自报**的国家地区。
  -- 匹配用的服务器区域是另一回事，属于对局系统，不该存在玩家资料里。
  region      text,

  updated_at  timestamptz not null default now(),

  constraint gender_allowed check (
    gender is null or gender in ('male', 'female', 'other', 'undisclosed')
  ),

  constraint birth_month_range check (birth_month is null or birth_month between 1 and 12),
  constraint birth_day_range   check (birth_day   is null or birth_day   between 1 and 31),

  -- 月日要么都填要么都不填，避免"三月，几号不知道"这种半截数据。
  constraint birth_pair check ((birth_month is null) = (birth_day is null)),

  -- 按月份卡实际天数，挡住 2/31 这类。2 月给 29 —— 闰日生日是真实存在的。
  constraint birth_day_in_month check (
    birth_month is null or birth_day is null
    or birth_day <= (array[31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31])[birth_month]
  ),

  constraint region_format check (region is null or region ~ '^[A-Z]{2}$')
);

-- 同 001：开 RLS、零 policy，一切经 FastAPI。
--
-- 注意这张表的性质与 players 不同：它**天生要给别人看**。等做社交系统时，
-- 这里会是第一批需要"哪些字段对好友可见、哪些对陌生人可见"的字段，
-- 到时候按字段加可见性列与对应 policy，不要一次性全开。
alter table player_bio enable row level security;

comment on table  player_bio             is '玩家自愿填写的展示资料。全部可空，不填是正常状态。';
comment on column player_bio.birth_month is '生日月份。刻意不存年份，见本文件注释。';
comment on column player_bio.region      is '玩家自报的国家地区（ISO 3166-1 alpha-2）。非匹配区域。';
