-- 007: 好友私聊（docs/聊天系统设计.md 批次 C）
--
-- 配套设计文档：docs/聊天系统设计.md 第三节（每一条「为什么」都在那里）。
-- 001–006 一个字都不改 —— 编号只增不改，见 database/README.md。
--
-- 本文件建三张新表，全部是 🟢（加新表零风险）：
--   chat_conversations  私聊会话，**一对玩家一行**（canonical 对，同 player_friendships）
--   chat_messages       消息。游标是 bigserial
--   chat_read_state     已读游标，每人每会话一行
--
-- 不碰 ENet、不碰 NetProtocol、不需要 ②↔③ 通道：私聊全程在 ② 里，
-- 发送走 HTTPS，推送走 ② 的 WebSocket（批次 B）。
--
--
-- ## 存多少、存多久（2026-09-11 拍板）
--
-- **只存能显示的那部分。** 玩家只能看到、也只能举报自己看得到的消息，
-- 所以不显示的消息没有保留的理由：
--
--   仍是好友      每对只留最近 200 条（backend/app/chat.py 的 KEEP_PER_CONVERSATION），
--                 不按时间删。第 201 条写入时，**同一个事务里**删掉最老的。
--   不再是好友    会话从双方界面消失；记录从最后一条消息算起再留 30 天，然后整段删。
--                 这 30 天只防一件事：骂完立刻删好友的人，记录不能跟着好友关系一起没了。
--                 举报是另一个系统，以后接；到时它能在这 30 天里取到这段记录。
--   被拉黑后发的  **不落库**。发送方照样显示「已发送」，但谁都看不到、也没人能举报，
--                 存了只会被人拿来灌库。
--
-- 于是容量有**结构性**上界：一个号最多 100 个好友（friends.MAX_FRIENDS）× 200 条，
-- 与他发多少、发多快无关。每分钟 30 条的限流只防刷屏，不负责总量。
--
-- ⚠️ **会话刻意不外键到 player_friendships。** 外键 + on delete cascade 能让
-- 「删好友 = 删记录」在结构上成立，但那正是上面「再留 30 天」要防的事。
-- 过期清理由 backend/app/maintenance.py 定时做。


-- ============================================================================
-- 会话
-- ============================================================================
--
-- **一对玩家一行，不是每人一行。** 理由同 005 的 player_friendships：
-- 每人一行能表示出「A 的会话里有 5 条、B 的会话里有 3 条」这个坏状态。
-- 写漏一行不报错，表现是「他看到的和我看到的不一样」。canonical 对让它不可表示。
--
-- 应用层义务：所有 (low_id, high_id) 一律经 backend/app/friends.py 的 _pair() 排序。
create table chat_conversations (
  low_id          uuid not null references players(player_id) on delete cascade,
  high_id         uuid not null references players(player_id) on delete cascade,

  -- 最后一条消息。未读 = last_message_id > 我的 last_read_id（见 chat_read_state）。
  --
  -- 刻意**不**外键到 chat_messages：两张表互相外键时插入顺序会打结，
  -- 而这一列只用来比大小 —— 它指向的那条就算被裁剪掉，比较照样成立。
  last_message_id bigint,

  -- 最后一条消息的时间。会话列表按它排序；「不再是好友后再留 30 天」也按它算。
  updated_at      timestamptz not null default now(),

  primary key (low_id, high_id),

  -- 这条约束就是「一对一行」的全部实现。去掉它，坏状态立刻可表示。
  constraint chat_conversation_ordered check (low_id < high_id)
);

-- 主键覆盖了 low_id 方向，另一个方向要单独建。
create index chat_conversations_by_high on chat_conversations (high_id);

-- 过期清理按时间扫。
create index chat_conversations_by_updated on chat_conversations (updated_at);

alter table chat_conversations enable row level security;

comment on table chat_conversations is
  '私聊会话。一对玩家一行（low_id < high_id）。不外键到好友关系：删好友后记录再留 30 天。';


-- ============================================================================
-- 消息
-- ============================================================================
--
-- 🔴 **游标必须是 bigserial，不能用时间戳。**
-- 增量拉取（「给我 message_id > X 的」）的正确性全押在游标单调上。
-- 时间戳会撞（同毫秒两条）、会因为时钟回拨倒退。事后改是 🔴：所有客户端的
-- 本地游标全部作废，而症状是「偶尔丢一条」或「偶尔重复一条」，几乎不可能复现。
--
-- 刻意**没有 deleted_at**：2026-09-11 已定不做「清空聊天记录」。
-- 以后真要做，加一列是 🟢（database/README 代价表），而且那一列只能表示
-- 「对双方都删了」—— 只删自己这边要另存每人一个水位线，见设计文档第三节。
create table chat_messages (
  message_id    bigserial primary key,
  low_id        uuid not null,
  high_id       uuid not null,
  sender_id     uuid not null references players(player_id) on delete cascade,
  body          text not null,

  -- 客户端给每条消息生成的 uuid。手机超时后重发同一条时，服务端靠它认出
  -- 「这条已经收过了」—— 否则弱网下会出现「我发了一次，对方收到两条」。
  client_msg_id uuid not null,

  created_at    timestamptz not null default now(),

  -- 会话没了消息跟着没（过期清理、玩家删号都走这条）。
  constraint chat_message_conversation
    foreign key (low_id, high_id)
    references chat_conversations (low_id, high_id) on delete cascade,

  constraint chat_sender_is_party check (sender_id in (low_id, high_id)),

  -- 与 backend/app/text_guard.py 的 CHAT_MAX 一致。那边是第一道，这里是最后一道；
  -- 两边对不上会表现为「客户端说可以、后端 500」。
  constraint chat_body_length check (char_length(body) between 1 and 200),

  constraint chat_client_msg_unique unique (sender_id, client_msg_id)
);

-- 拉历史（某会话最近 N 条）与裁剪（删掉第 200 条之前的）都走它。
-- 也覆盖了上面那条组合外键的反查。
create index chat_messages_by_conv on chat_messages (low_id, high_id, message_id desc);

alter table chat_messages enable row level security;

comment on table chat_messages is
  '私聊消息。游标 message_id 单调（bigserial）。仍是好友时每对只留最近 200 条；被拉黑后发的不落库。';
comment on column chat_messages.client_msg_id is
  '客户端生成的消息 uuid。同一发送者重发同一条时靠它去重，避免弱网下对方收到两条。';


-- ============================================================================
-- 已读游标
-- ============================================================================
--
-- 🔴 **未读 = 会话的 last_message_id > last_read_id，绝不存 unread_count。**
-- 可变计数器在任何一次并发、重发、乱序下都会漂，而且不报错 ——
-- 只表现为「红点消不掉」或「有新消息不亮」。
-- 同 player_presence 没有「离线」字段：不存会说谎的状态，存能推出真相的事实。
--
-- 应用层义务：更新一律 greatest(旧值, 新值)。同一账号两台设备都在线时，
-- 滞后的那台会把游标从 100 退回 50，表现为「看过的消息又变成未读」。
-- 单调之后，两台设备读同一个服务端游标，天然一致。
create table chat_read_state (
  player_id    uuid not null references players(player_id) on delete cascade,
  low_id       uuid not null,
  high_id      uuid not null,
  last_read_id bigint not null default 0,

  primary key (player_id, low_id, high_id),

  constraint chat_read_state_conversation
    foreign key (low_id, high_id)
    references chat_conversations (low_id, high_id) on delete cascade,

  constraint chat_reader_is_party check (player_id in (low_id, high_id))
);

-- 主键以 player_id 打头，会话被清理时的级联删除要按 (low_id, high_id) 反查。
create index chat_read_state_by_conv on chat_read_state (low_id, high_id);

alter table chat_read_state enable row level security;

comment on table chat_read_state is
  '私聊已读游标。只存游标不存计数；更新必须用 greatest() 保持单调。';
