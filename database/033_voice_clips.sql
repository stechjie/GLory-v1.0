-- 033: 语音消息（docs/聊天系统设计.md「语音消息」，2026-10-11）
--
-- 配套实现：backend/app/voice_clips.py（上传、配额、清理）、backend/app/routes/voice_clips.py、
-- backend/app/chat.py 的 VOICE_KIND、backend/app/world.py、客户端 scripts/autoload/VoiceClipService.gd。
-- 001–032 一个字都不改 —— 编号只增不改，见 database/README.md。
--
-- ## 这张表存的是「文件」，不是「消息」
--
-- 用户 2026-10-11 定：**凡是能打字的地方都能发语音**（私聊、世界频道、房间与对局内），上限 30 秒。
-- 三个渠道的消息走三条完全不同的路：
--
--   私聊     chat_messages，kind='voice'            （落库）
--   世界频道  world_messages，kind='voice'           （落库）
--   房间/对局 战斗服务器转发，和局内文字同一条路        （**不落库**）
--
-- 所以「消息」没有统一的落脚点，但**音频文件有**：三条路都先把音频传到账号服务器，
-- 拿到一个编号，之后传来传去的只是这个编号加秒数。本表就是那个编号的户口。
--
-- 🔴 **举报锚定在这张表上，不是锚定在消息上。** 对局里的语音不落库，如果证据挂在消息上，
-- 那对局里就永远举报不了。挂在文件上之后，拿着编号就能查出是谁、什么时候、从哪个渠道传的 ——
-- 三个渠道一视同仁。这也是 scope 这一列存在的唯一理由。
--
-- ## 文件与行是多对一
--
-- 文件按内容哈希命名（<sha256>.ogg，与公告图片同一套，Caddy 直接发），所以**同一段音频
-- 被两个人发就是同一个文件**。但行各自一份：举报要知道是谁传的。
-- 直接后果：**删行不能顺手删文件** —— 还有别的行指着它。清理时先删行，
-- 再删「已经没有任何行引用」的文件（backend/app/voice_clips.py 的 sweep）。
--
-- ## 保留期按渠道分，被举报的不清理
--
-- 私聊 30 天（与 chat.py 的 ENDED_RETENTION_DAYS 一致）、世界频道与对局 7 天
-- （与 019 世界频道的 7 天清理一致）。被举报的那条 hold_until 往后推，
-- 清理时跳过 —— 否则「举报了，处理的人去听，文件已经被定时任务删了」。

create table voice_clips (
  clip_id     uuid primary key,

  -- 文件名 <sha256>.ogg，落在 GLORY_MEDIA_DIR（Caddy 的 /media/*）。
  -- 不带路径：路径是部署细节，换目录不该要改数据。
  media_name  text not null,
  constraint voice_media_name_shape check (media_name ~ '^[0-9a-f]{64}\.ogg$'),

  uploader_id uuid not null references players(player_id) on delete cascade,

  -- 转码之后的真实时长，服务端量出来的，不信客户端报的。
  -- 上限 30 秒与 backend/app/voice_clips.py 的 MAX_SECONDS、
  -- 客户端 VoiceClipService.MAX_SECONDS 一致（tools/voice_clip_check 钉着）。
  seconds     numeric(4, 1) not null,
  constraint voice_seconds_range check (seconds > 0 and seconds <= 30),

  bytes       int not null check (bytes > 0),

  -- 从哪个渠道传的。只为举报与保留期服务，不参与投递。
  scope       text not null,
  constraint voice_scope_allowed check (scope in ('private', 'world', 'match')),

  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,

  -- 被举报：推到这个时间之前都不清理。null = 没被举报过。
  hold_until  timestamptz
);

-- 配额：某人最近 24 小时传了几条（backend/app/voice_clips.py 的 _quota_used）。
create index voice_clips_by_uploader on voice_clips (uploader_id, created_at desc);
-- 清理任务按它扫。
create index voice_clips_expiry on voice_clips (expires_at);
-- 删行之后判断「这个文件还有没有人引用」。
create index voice_clips_by_media on voice_clips (media_name);

alter table voice_clips enable row level security;

comment on table voice_clips is
  '语音消息的音频文件登记。消息本身在 chat_messages / world_messages / 战斗服务器转发里，这里只管文件与举报锚点。';
comment on column voice_clips.scope is
  '上传时声明的渠道：private=好友私聊，world=世界频道，match=房间与对局内（不落库，只有这张表留得下证据）。';
comment on column voice_clips.hold_until is
  '被举报后推迟清理到这个时间；null 表示没被举报过。清理任务必须跳过 hold_until 还没到的行。';

-- --------------------------------------------------------------------------
-- 私聊：第四种消息类型
--
-- 020 定下的规矩：新类型「只能靠先发迁移、再加客户端来引入」。030 漏掉这条 check
-- 导致组队邀请 HTTP 500，这次一起写。drop + add 带 if[not] exists 的理由同 030：
-- 这个文件要人手工在 Supabase 里跑，贴两遍不能报错。
-- --------------------------------------------------------------------------

alter table chat_messages
  drop constraint if exists chat_message_kind_allowed;

alter table chat_messages
  add constraint chat_message_kind_allowed
    check (kind in ('text', 'room_invite', 'party_invite', 'voice'));

comment on column chat_messages.kind is
  '消息类型：text=普通文本，room_invite=房间邀请，party_invite=组队邀请，voice=语音消息（payload 带 clip_id 与 seconds）。';

-- --------------------------------------------------------------------------
-- 世界频道：加类型与 payload
--
-- 019 那张表只存文本，而且 body 限 1–100 字。语音消息没有玩家写的文本，
-- **直接发会撞 world_body_length** —— 所以约束要按类型分开。
--
-- 语音的 body 不是空串：服务端往里写一句「[语音 12″]」（见 routes/world.py）。
-- 理由是**旧客户端**：不认 kind='voice' 的包会把 body 当文字画出来，写了这句
-- 它至少看得见「这是一段语音」，空串只会给它一个空气泡。私聊那边同理
-- （007 的 chat_body_length 本来就要求 1 字以上）。
--
-- 限到 32 字是为了挡死「语音 + 一段自由文字」这种半吊子形态：真要做是另一次迁移。
-- 客户端传的 body 在路由里一律丢掉，所以这条只是多一道门。
-- --------------------------------------------------------------------------

alter table world_messages
  add column if not exists kind text not null default 'text';

alter table world_messages
  add column if not exists payload jsonb;

alter table world_messages
  drop constraint if exists world_kind_allowed;

alter table world_messages
  add constraint world_kind_allowed check (kind in ('text', 'voice'));

alter table world_messages
  drop constraint if exists world_body_length;

alter table world_messages
  add constraint world_body_length check (
    (kind = 'text' and char_length(body) between 1 and 100)
    or (kind = 'voice' and char_length(body) between 1 and 32)
  );

comment on column world_messages.kind is
  '消息类型：text=普通文本，voice=语音消息（body 是服务端写的「[语音 N″]」占位，payload 带 clip_id 与 seconds）。';
comment on column world_messages.payload is
  '类型相关的机器可读数据。text 为 null；voice 为 {"clip_id": <uuid>, "seconds": <number>}。';
