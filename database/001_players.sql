-- 001: 账号本体
--
-- player_id 由**客户端**在设备首次读档时签发（scripts/save/SaveSchema.gd 的
-- new_player_id），不是 Supabase Auth 的 id。各家 Auth 通过 002 的
-- player_identities 映射到它。这样换登录方式、甚至换掉整个后端，
-- 游戏数据表一张都不用重新 key。设计理由见 docs/账号系统RFC.md 第四节。

create table players (
  player_id    uuid        primary key,
  player_name  text        not null default 'Player',
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),

  -- 任何来自客户端的字符串都要有上限。参见 docs/联机审计与整改方案.md 的 A12：
  -- 超长字符串可用来制造常驻内存压力，对抗台有 untrusted_string_caps 用例。
  -- 昵称是新开的客户端输入入口，从第一天就带上限。
  constraint player_name_length check (char_length(player_name) between 1 and 24)
);

-- 显示名**不唯一**。区分同名玩家靠 player_id 前 4 位，例如 "Leno #52c7"。
-- 那只是显示用的区分符，不是身份 —— 身份永远是完整的 player_id，
-- 所以短 ID 不单独存列（存了就会有"两处不一致"的问题）。

-- 开 RLS 但**刻意不建任何 policy**。
--
-- 按 docs/账号系统RFC.md 第三节：Godot 永远不直连 Supabase，一切经过 FastAPI，
-- 而 FastAPI 用 secret key —— secret key 本来就绕过 RLS。
-- 于是「开 RLS + 零 policy」= 通过 Data API 谁都读不到这张表，FastAPI 照常读写。
--
-- 以后某个字段真需要客户端直读（例如好友要看别人昵称），
-- 再为**那个场景**单独加一条 policy，而不是一开始就开着口子。
alter table players enable row level security;

comment on table  players              is '账号本体。一行 = 一个玩家。';
comment on column players.player_id    is '客户端签发的 UUIDv4，见 SaveSchema.new_player_id。非 Supabase Auth id。';
comment on column players.player_name  is '显示名。不唯一，默认 Player，玩家可改。';
comment on column players.last_seen_at is '最近一次活跃。不允许为空 —— "建了但从没登录过"不是真实状态。';
