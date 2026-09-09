-- 006: 房间访问记录（「最近一起玩过」）
--
-- 配套设计文档：docs/交友系统设计.md 第二节（批次 3）。
-- 001–005 一个字都不改 —— 编号只增不改，见 database/README.md。
--
-- 只加一张新表，🟢。
--
--
-- ## 为什么需要它：客户端不知道队友是谁
--
-- NetworkService 里**没有任何 player_name / friend_code**（RFC 第六节 🔴 第 3 条：
-- NetProtocol 不加账号身份字段）。所以「我和谁玩了」不能由客户端上报 ——
-- 它压根不知道。
--
-- 但客户端知道**自己在哪个房间**（NetworkService.team_room_id）。
-- 于是 ② 把「同一时间报了同一个房间号」的人关联起来，就得到了同局名单。
-- 这条路径完全绕开了那条红线。
--
--
-- ## 🔴 双向要求就是防伪造的全部机制
--
-- 「最近同玩」是自报数据里**唯一有真实滥用面**的一条：谎报房间号可以把自己
-- 塞进陌生人的「最近同玩」列表 = 一个定向骚扰入口。
--
-- 对策不是校验，是**结构**：关联要求两边都有一条记录、且时间窗重叠。
-- 要伪造就必须真的进那个房间 —— 而那时你本来就是队友了。
--
-- 这条一旦被改成单边匹配，滥用面立刻回来，而且**不会报错**。
--
--
-- ## 记的是「进出」，不是每次心跳
--
-- 心跳每 60 秒一次，逐条记录等于每个在线玩家每分钟一行。
-- 这里只在**房间号真的变了**时记一行（backend/app/presence.py 的 heartbeat），
-- 一局对战只产生一行。
create table player_room_visits (
  id         bigint generated always as identity primary key,
  player_id  uuid   not null references players(player_id) on delete cascade,

  -- 客户端自报。谎报的唯一后果见上面那节。
  room_id    bigint not null,

  entered_at timestamptz not null default now(),
  -- null = 还在里面。查询时用 coalesce(left_at, now()) 当作右端点。
  left_at    timestamptz,

  constraint room_visit_room_id_positive check (room_id > 0),
  constraint room_visit_time_ordered check (left_at is null or left_at >= entered_at)
);

-- 关联查询：给定我的一段访问，找同房间、时间窗重叠的其他人。
create index player_room_visits_by_room on player_room_visits (room_id, entered_at desc);

-- 「我最近去过哪些房间」，以及关房时找到自己那条未闭合的记录。
create index player_room_visits_by_player on player_room_visits (player_id, entered_at desc);

alter table player_room_visits enable row level security;

comment on table player_room_visits is
  '房间访问记录。「最近一起玩过」靠它做同房关联 —— 客户端不知道队友是谁，只知道自己在哪个房间。保留 7 天。';
comment on column player_room_visits.left_at is
  'null = 还在房间里。客户端崩溃时不会有人来闭合它，所以查询一律 coalesce(left_at, now())，不要假设它非空。';

-- 保留 7 天，之后没有用途（「最近」本来就只看最近）。这是一张只增的表，
-- 必须有人定期清理：
--   delete from player_room_visits where entered_at < now() - interval '7 days';
