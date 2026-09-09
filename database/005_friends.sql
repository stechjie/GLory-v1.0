-- 005: 交友系统（好友关系 / 拉黑 / 请求配额 / 在线状态）
--
-- 配套设计文档：docs/交友系统设计.md（每一条「为什么」都在那里）。
-- 001–004 一个字都不改 —— 编号只增不改，见 database/README.md。
--
-- 本文件建四张新表，全部是 🟢（加新表零风险）：
--   player_friendships    好友关系，**一段关系一行**
--   player_blocks         拉黑，有方向
--   friend_request_log    请求日志，**每日配额唯一的数据来源**
--   player_presence       在线状态与所在房间
--
-- 这套设计不碰 ENet、不碰 NetProtocol、不需要 ②↔③ 通道：
-- 房间号由客户端经 HTTPS 自报，② 侧关联。边界见设计文档第二节
-- （自报只能用于「说谎没有收益」的数据）。


-- ============================================================================
-- 好友关系
-- ============================================================================
--
-- **一段关系一行，不是两行。** 强制 low_id < high_id，物理上不可能出现两行。
--
-- 另一种做法是每段友谊存两行有向边（owner_id / other_id），查列表更快
-- —— 一次索引扫描，没有 or。但它有一个**能表示出来的坏状态**：两行不一致
-- = 单向好友。写漏一行不报错、不崩溃，表现是「他的列表里有我，我的列表里
-- 没他」，而且只在特定玩家身上出现。那正是 docs/账号系统RFC.md 第七节
-- 那条不变量要防的静默 bug。canonical 排序让这个状态**不可表示**。
--
-- 代价是查「我的好友」要 (low_id = $1 or high_id = $1)，走两个索引的 BitmapOr。
-- 好友上限 100、玩家几万的量级上不是问题。
--
-- **交叉请求顺带被解决**：A 加 B 的同时 B 加 A，第二个事务撞主键，
-- 应用层捕获后发现 requested_by 是对方 → 直接置 accepted。
-- ⚠️ 重试必须包在 **savepoint** 里 —— 理由同 backend/app/players.py 的好友码
-- 重试：PostgreSQL 里一条语句失败后整个事务进入 aborted 状态，不开 savepoint
-- 的话重试循环 100% 是摆设，而且第二次的报错与真实原因完全无关。
create table player_friendships (
  low_id       uuid not null references players(player_id) on delete cascade,
  high_id      uuid not null references players(player_id) on delete cascade,

  -- 谁发起的。pending 状态下用它区分「我发出的」和「我收到的」——
  -- canonical 排序抹掉了方向，这一列把方向加回来。
  requested_by uuid not null,

  status       text not null default 'pending',
  created_at   timestamptz not null default now(),
  accepted_at  timestamptz,

  primary key (low_id, high_id),

  -- 这条约束就是「一段关系一行」的全部实现。去掉它，坏状态立刻可表示。
  constraint friendship_ordered check (low_id < high_id),

  constraint friendship_requester_is_party check (requested_by in (low_id, high_id)),

  -- 刻意**没有 'rejected'**。已确认的产品决定是「拒绝 = 删掉这一行」，
  -- 靠每日配额和拉黑兜底。留 rejected 的话，误拒的人永远加不回来。
  -- 代价见下面 friend_request_log 那张表。
  constraint friendship_status_allowed check (status in ('pending', 'accepted')),

  -- accepted 必须有时间戳，pending 必须没有。两者对不上说明状态机写漏了一处。
  constraint friendship_accepted_at_matches_status check (
    (status = 'accepted') = (accepted_at is not null)
  )
);

-- 主键覆盖了 low_id 方向，另一个方向要单独建。
create index player_friendships_by_high on player_friendships (high_id);

alter table player_friendships enable row level security;

comment on table player_friendships is
  '好友关系。一段关系一行（low_id < high_id），单向不一致这个坏状态在结构上不可表示。';
comment on column player_friendships.requested_by is
  '发起方。canonical 排序抹掉了方向，靠这一列区分「我发出的」与「我收到的」请求。';


-- ============================================================================
-- 拉黑
-- ============================================================================
--
-- **有方向**（A 拉黑 B ≠ B 拉黑 A），所以塞不进上面那个 canonical 对，
-- 必须单独一张表。
--
-- docs/玩家资料系统设计.md 当初把拉黑推迟，理由是「今天没有任何互动方式，
-- 屏蔽一个只能看、不能互动的人没有意义。等聊天做了再说」。
-- **交友系统上线那一刻这条理由就失效了** —— 好友请求本身就是一条能反复
-- 戳人的通道。所以它进第一批，不等聊天。
--
-- 应用层义务（这里约束不了，写在这当提醒）：
--   拉黑时必须在**同一个事务**里删掉已有的好友关系。
--   只插 block 不删 friendship，会得到「已经拉黑了但还在好友列表里」。
create table player_blocks (
  blocker_id uuid not null references players(player_id) on delete cascade,
  blocked_id uuid not null references players(player_id) on delete cascade,
  created_at timestamptz not null default now(),

  primary key (blocker_id, blocked_id),
  constraint block_not_self check (blocker_id <> blocked_id)
);

-- 查询方向：「谁拉黑了我」—— 发请求前要查这个方向。
create index player_blocks_by_blocked on player_blocks (blocked_id);

alter table player_blocks enable row level security;

comment on table player_blocks is
  '拉黑。有方向，与好友关系是两张表。拉黑必须与「删好友」在同一事务里完成。';


-- ============================================================================
-- 请求日志 —— 这是「拒绝就删记录」这个决定的直接代价
-- ============================================================================
--
-- 已确认：拒绝好友请求 = 删掉 player_friendships 那一行。
-- 于是那张表里**不再留有任何历史**，「每天最多发几个请求」就没有可数的东西。
-- 所以必须单开这张日志表。
--
-- 漏掉它的后果很具体：配额代码看起来是写了的（select count(*) ...），
-- 但永远数出 0，任何人都能无限重发请求 —— 而这不会报错。
--
-- ⚠️ **配额判在数据库上，不能用 backend/app/rate_limit.py。**
-- 那是进程内滑动窗口，重启即清零、多 worker 各算各的（它自己的注释写着）。
-- 它仍要挂着，但它防的是刷接口，不是业务配额。这与改名冷却判在
-- players.name_changed_at 上是同一条教训（004）。
--
-- 保留期 **30 天**，之后没有用途。这是一张只增的表，必须有人定期清理：
--   delete from friend_request_log where created_at < now() - interval '30 days';
create table friend_request_log (
  id           bigint generated always as identity primary key,
  requester_id uuid not null references players(player_id) on delete cascade,
  target_id    uuid not null references players(player_id) on delete cascade,
  created_at   timestamptz not null default now(),

  constraint request_log_not_self check (requester_id <> target_id)
);

-- 配额查询：某人最近 24 小时发了几个。
create index friend_request_log_by_requester
  on friend_request_log (requester_id, created_at desc);

-- 清理查询走这个。
create index friend_request_log_by_created on friend_request_log (created_at);

alter table friend_request_log enable row level security;

comment on table friend_request_log is
  '好友请求日志。**每日配额唯一的数据来源** —— 因为拒绝会删掉 player_friendships 的行。保留 30 天。';


-- ============================================================================
-- 在线状态
-- ============================================================================
--
-- **为什么不加在 players 上**：presence 是高频写（每个在线玩家每 60 秒一次），
-- 而 players 是每个请求都读。写在同一行，每次心跳都会让那一行失效。
-- 这与 002 当初分出 player_bio 是同一条理由。
--
-- **没有「在线」布尔字段。** 在线与否由 last_seen_at 加 TTL 推出来，
-- 不存一个会说谎的值 —— 客户端崩溃时不会发「我下线了」，
-- 任何「下线时发个包」的方案都挡不住进程被杀。
-- 代价是「刚下线」最多显示成在线 2.5 分钟，接受它。
--
-- **room_id 是客户端自报的。** 谎报的后果只是让好友进错房间，而房间号本来
-- 就是任何人知道号就能进（NetworkService.team_request_join_room）——
-- 没有新增攻击面。⚠️ 这条边界只对「说谎没收益」的数据成立：
-- 战绩、排行、奖励一律不能建在自报数据上，见设计文档第二节。
create table player_presence (
  player_id    uuid primary key references players(player_id) on delete cascade,

  last_seen_at timestamptz not null default now(),

  -- null = 在线但不在任何房间（主菜单等）。
  room_id      bigint,

  -- 可见性用**文本枚举而不是 bool**，理由同 004：现在只有两态，bool 更省事，
  -- 但放宽一条 check 约束是 🟢，而 bool -> enum 是 README 代价表里 🔴 的
  -- 「改一列的含义」。多写几个字换掉一次数据迁移。
  --
  -- 已确认：在线状态**只对好友可见**，没有 'public' 档。
  -- 留着枚举是为了以后要加时不用写迁移。
  presence_visibility text not null default 'friends',

  -- 「在不在线」和「在哪个房间」泄漏的东西不是一回事 —— 后者是行为轨迹，
  -- 所以单独一个开关。
  room_visibility     text not null default 'friends',

  constraint presence_visibility_allowed check (presence_visibility in ('friends', 'nobody')),
  constraint room_visibility_allowed     check (room_visibility     in ('friends', 'nobody')),

  -- 自报值的基本 sanity。房间号由 shard * SHARD_ID_STRIDE + 六位随机组成
  -- （scripts/multiplayer/NetworkConfig.gd），恒为正。
  constraint presence_room_id_positive check (room_id is null or room_id > 0)
);

-- 「我的好友里谁在线」：where player_id = any($1) 走主键，够用。
-- 刻意**不**给 last_seen_at 建索引 —— 没有「列出全服在线玩家」这种查询，
-- 而每次心跳都要维护的索引是纯成本。
alter table player_presence enable row level security;

comment on table player_presence is
  '在线状态与所在房间。高频写，刻意与 players 分表。在线与否由 last_seen_at + TTL 推出，不存布尔值。';
comment on column player_presence.room_id is
  '客户端自报的当前房间号，null = 不在房间。谎报只能让好友进错房间（房间号本就公开可进），不可作为任何有价值判断的依据。';
comment on column player_presence.presence_visibility is
  '在线状态可见性。已确认只对好友可见；枚举而非 bool，是为了以后加档位时不用写迁移。';
