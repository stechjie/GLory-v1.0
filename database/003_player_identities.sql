-- 003: 登录方式 → 玩家的映射
--
-- 整套账号设计的关键。游戏内部永远只认 player_id；某家 Auth 换掉、或者以后加
-- Google / Apple / Steam，改的只是这张表，金币 / 单位 / 宝物 / Rank / 战绩
-- 一张都不用动。设计理由见 docs/账号系统RFC.md 第四节。

create table player_identities (
  provider         text not null,
  provider_user_id text not null,
  player_id        uuid not null references players(player_id) on delete cascade,
  linked_at        timestamptz not null default now(),

  -- 主键就是查询方向：拿着某家 Auth 的 id 来问「这是谁」。
  -- 同时强制了最要命的那条唯一性：**一个外部账号绝不可能映射到两个 player_id**。
  -- 没有这条约束，一次登录可能解析出两个玩家。
  primary key (provider, provider_user_id),

  -- 匿名登录走 'supabase'（Supabase Auth 的匿名用户），不是单独的 provider。
  -- 匿名用户之后原地升级成邮箱账号时 auth uid 不变，所以那一步连新增一行都不用。
  --
  -- 刻意**不含 'local'**：device_id 不是凭证。把设备 id 明文存进
  -- provider_user_id 等于把密码明文入库，一次泄库所有匿名账号全部沦陷，
  -- 而且它还会出现在客户端日志与崩溃报告里。
  -- 将来若真要做自己的设备密钥登录，那是新的迁移文件，且必须另存密钥哈希。
  constraint provider_allowed check (
    provider in ('supabase', 'google', 'apple', 'steam')
  ),

  -- 同 001 的昵称：任何来自客户端的字符串都要有上限。
  constraint provider_user_id_length check (
    char_length(provider_user_id) between 1 and 255
  )
);

-- 另一个查询方向：「这个玩家绑了哪些登录方式」—— 设置页要显示。
-- 主键是 (provider, provider_user_id)，帮不上这个方向，所以单独建索引。
create index player_identities_by_player on player_identities (player_id);

-- 同一个玩家、同一个 provider **允许多行**，刻意不加 unique(player_id, provider)。
-- 以后要支持一个玩家绑两个 Google 账号、或做账号合并的过渡状态时都用得上。
-- 现在堵死，将来解开要写数据迁移。

-- 同 001 / 002：开 RLS、零 policy，一切经 FastAPI。
-- 这张表尤其不该对客户端可见 —— 它是「谁是谁」的全部答案。
alter table player_identities enable row level security;

comment on table player_identities is
  '登录方式 → player_id 的映射。**只存映射，绝不存密码、token 或任何凭证** —— 凭证是 Supabase 的职责。';
comment on column player_identities.provider_user_id is
  '该 provider 侧的用户 id（如 Supabase 的 auth uid）。不是凭证，不能用来登录。';
