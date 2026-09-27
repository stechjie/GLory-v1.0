-- 019: 世界频道、禁言、举报
--
-- 设计见 docs/聊天系统设计.md（批次 E）。配套 backend/app/world_chat.py、reports.py、
-- routes/world.py、routes/reports.py，网页后台 docs/运营后台设计.md。
--
-- 001-018 一个字都不改 —— 编号只增不改，见 database/README.md。
--
--
-- ## 2026-09-27 拍板
--
--   · 世界频道**第一版只跑本地规则**（结构管控 + 联系方式 + 词表，backend/app/text_guard.py），
--     不接外部审核；靠举报 + 禁言 + 删单条兜底。一句违规的话会先被正在看的人看到，直到被删。
--   · 所有人都能说话（以后有等级制度再加门槛，判据在 world_chat.can_speak_in_world）。
--   · 打开世界频道先给最近 100 条，往上翻可以一直翻到 7 天前（库里只存 7 天）。
--
--
-- ## 部署顺序
--
--   Supabase SQL Editor 先跑本文件 → 再更新账号服务器 → 再出新包。
--   没跑本文件时：世界频道的接口回 503「世界频道暂时不可用」，举报回同样的话；
--   游戏其余部分不受影响（与 016 没跑时封号放行同一个思路）。


-- ============================================================================
-- 世界频道的消息
-- ============================================================================
--
-- 显示走账号服务器进程内的最近 100 条（world_chat.WorldChannel），往上翻才查这张表。
-- 保留 7 天：够往回翻、够处理举报（举报那一刻服务器另外把证据复制进 player_reports.evidence，
-- 这张表清掉了证据也还在）。定时清理在 backend/app/maintenance.py。
--
-- 🔴 昵称 / 头像 / 头像框**按发言那一刻存下来**，不在显示时去 players 现查：
-- 进程内那 100 条、往上翻查出来的、推送出去的，三处必须是同一个名字；
-- 举报时也要知道他当时用的是什么名字（改个名就能洗掉的话，举报就没用了）。

create table world_messages (
  message_id    bigint generated always as identity primary key,
  sender_id     uuid not null references players(player_id) on delete cascade,
  -- 客户端给每条消息生成的 uuid。网络重试同一条时靠它去重：第二次回第一次那条，不再推一次。
  client_msg_id uuid not null,
  constraint world_client_msg_unique unique (sender_id, client_msg_id),

  -- 与 backend/app/text_guard.py 的 WORLD_MAX、客户端 ChatService.WORLD_MAX_CHARS 一致。
  body          text not null,
  constraint world_body_length check (char_length(body) between 1 and 100),

  sender_name   text not null,
  constraint world_sender_name_length check (char_length(sender_name) between 1 and 64),
  sender_avatar text not null default '',
  sender_frame  text not null default '',

  created_at    timestamptz not null default now(),

  -- 运营删掉的：打标记、不删行（举报要看上下文）。玩家那边看不到，推送里也会让已经显示的那条消失。
  hidden_at     timestamptz,
  hidden_by     text,
  hidden_reason text,
  constraint world_hidden_pair check ((hidden_at is null) = (hidden_by is null)),
  constraint world_hidden_by_length check (hidden_by is null or char_length(btrim(hidden_by)) between 1 and 64),
  constraint world_hidden_reason_length check (hidden_reason is null or char_length(hidden_reason) <= 200)
);

-- 往上翻（message_id < 游标，没被删的，新到旧）。
create index world_messages_visible on world_messages (message_id desc) where hidden_at is null;
-- 某个人最近说了什么：举报时的证据、网页后台的玩家页。
create index world_messages_by_sender on world_messages (sender_id, message_id desc);
-- 7 天清理。
create index world_messages_created on world_messages (created_at);

alter table world_messages enable row level security;

comment on table  world_messages             is '世界频道消息。保留 7 天；运营删除打 hidden_* 标记。';
comment on column world_messages.sender_name is '发言那一刻的昵称（不随改名变）。';


-- ============================================================================
-- 禁言
-- ============================================================================
--
-- 与 016 的封号同一个形状：只追加，解除打 revoked_* 标记，不删行。
-- 和封号是两回事：被禁言的人照常能玩、能私聊，**只是不能在世界频道说话**。
-- scope 先只有 world；以后要禁房间 / 局内聊天再加值（那两条走战斗服务器，要另想怎么通知它）。
--
-- 管理员怎么用（网页后台调的也是这两个函数）：
--
--   select mute_player(p_friend_code => 'ABCD2345', p_duration => interval '1 day',
--                      p_reason => '世界频道刷屏', p_actor => 'arvin', p_note => '举报 #12');
--   select unmute_player(p_friend_code => 'ABCD2345', p_actor => 'arvin', p_note => '误判');

create table player_mutes (
  mute_id     bigint generated always as identity primary key,
  player_id   uuid not null references players(player_id) on delete cascade,
  scope       text not null default 'world',
  constraint mute_scope check (scope in ('world')),

  created_at  timestamptz not null default now(),
  -- null = 永久。不用魔法年份（同 016）。
  ends_at     timestamptz,
  constraint mute_ends_after_start check (ends_at is null or ends_at > created_at),

  -- 给玩家看的原因：他在世界频道发言时看到的就是这一句。
  reason      text not null,
  constraint mute_reason_length check (char_length(btrim(reason)) between 1 and 200),
  -- 内部备注，玩家看不到。
  note        text,
  constraint mute_note_length check (note is null or char_length(note) <= 500),
  actor       text not null,
  constraint mute_actor_length check (char_length(btrim(actor)) between 1 and 64),

  revoked_at  timestamptz,
  revoked_by  text,
  revoke_note text,
  constraint mute_revoke_pair check ((revoked_at is null) = (revoked_by is null)),
  constraint mute_revoked_by_length check (revoked_by is null or char_length(btrim(revoked_by)) between 1 and 64),
  constraint mute_revoke_note_length check (revoke_note is null or char_length(revoke_note) <= 500)
);

create index player_mutes_live on player_mutes (player_id) where revoked_at is null;

alter table player_mutes enable row level security;

comment on table  player_mutes        is '禁言记录（先只有世界频道）。只追加；解除打 revoked_* 标记。';
comment on column player_mutes.reason is '给玩家看的原因。';
comment on column player_mutes.note   is '内部备注，玩家看不到。';


create function mute_player(
	p_friend_code text,
	p_duration    interval,
	p_reason      text,
	p_actor       text,
	p_note        text default null
) returns bigint
language plpgsql
as $$
declare
	v_player uuid;
	v_id     bigint;
begin
	if p_actor is null or btrim(p_actor) = '' then
		raise exception '必须填操作人（p_actor）：以后要查「这个号是谁禁言的」';
	end if;
	if p_reason is null or btrim(p_reason) = '' then
		raise exception '必须填原因（p_reason）：被禁言的玩家会看到这一句';
	end if;
	if p_duration is not null and p_duration <= interval '0' then
		raise exception '禁言时长必须是正的（永久填 null），现在是 %', p_duration;
	end if;
	select player_id into v_player from players where friend_code = upper(btrim(p_friend_code));
	if v_player is null then
		raise exception '没有这个好友码：%', p_friend_code;
	end if;

	insert into player_mutes (player_id, ends_at, reason, note, actor)
	values (v_player,
	        case when p_duration is null then null else now() + p_duration end,
	        btrim(p_reason), p_note, btrim(p_actor))
	returning mute_id into v_id;
	return v_id;
end;
$$;

comment on function mute_player(text, interval, text, text, text) is
	'禁言（世界频道，按好友码）。p_duration 为 null = 永久。原因玩家看得到，备注看不到。操作人必填。';


-- 解除：把这个玩家现在生效的禁言全部撤销（理由同 016 的 unban_player「全部」）。返回撤销了几条。
create function unmute_player(
	p_friend_code text,
	p_actor       text,
	p_note        text default null
) returns int
language plpgsql
as $$
declare
	v_player uuid;
	v_count  int;
begin
	if p_actor is null or btrim(p_actor) = '' then
		raise exception '必须填操作人（p_actor）';
	end if;
	select player_id into v_player from players where friend_code = upper(btrim(p_friend_code));
	if v_player is null then
		raise exception '没有这个好友码：%', p_friend_code;
	end if;

	update player_mutes
	   set revoked_at = now(), revoked_by = btrim(p_actor), revoke_note = p_note
	 where player_id = v_player and revoked_at is null and (ends_at is null or ends_at > now());
	get diagnostics v_count = row_count;
	if v_count = 0 then
		raise exception '这个玩家现在没有被禁言：%', p_friend_code;
	end if;
	return v_count;
end;
$$;

comment on function unmute_player(text, text, text) is
	'解除禁言（按好友码）：撤销他现在生效的全部禁言。不删行。操作人必填。';


-- ============================================================================
-- 举报
-- ============================================================================
--
-- 🔴 **证据由服务器在举报那一刻复制进 evidence**，不收客户端上传的记录（那可以伪造）：
--   · 世界频道：被举报的那一条 + 他最近 20 条世界频道发言（含已被删的）
--   · 私聊：举报人与他最近 50 条私聊（服务器本来就存着）
--   · 资料：他当时的昵称、签名、头像
--   · 房间 / 局内：服务器不存那两条频道的消息（docs/聊天系统设计.md 第八节第 5 条），只有资料快照
-- 世界频道的消息 7 天后会被清掉，证据在这里另存一份，不跟着清。
--
-- 同一个人对同一个人、同一种场合，**在处理之前只算一条**（下面的唯一索引）：
-- 刷举报不会把队列刷满，也不会给被举报的人多算。

create table player_reports (
  report_id    bigint generated always as identity primary key,
  reporter_id  uuid not null references players(player_id) on delete cascade,
  target_id    uuid not null references players(player_id) on delete cascade,
  constraint report_not_self check (reporter_id <> target_id),

  -- 在哪儿看到的：world 世界频道 / profile 资料页 / dm 私聊 / match 房间或对局里
  context      text not null,
  constraint report_context check (context in ('world', 'profile', 'dm', 'match')),
  -- abuse 辱骂骚扰 / ads 广告引流 / cheat 外挂作弊 / name 不当昵称头像签名 / other 其他
  reason       text not null,
  constraint report_reason check (reason in ('abuse', 'ads', 'cheat', 'name', 'other')),
  -- 举报人自己写的补充（可空）。只给管理员看。
  detail       text,
  constraint report_detail_length check (detail is null or char_length(detail) <= 200),
  -- 被举报的那条世界频道消息。**不加外键**：那张表 7 天就清，证据在 evidence 里。
  message_id   bigint,

  evidence     jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now(),

  -- open 待处理 / resolved 已处理（封号、禁言、删消息之类）/ dismissed 不成立
  status       text not null default 'open',
  constraint report_status check (status in ('open', 'resolved', 'dismissed')),
  handled_by   text,
  handled_at   timestamptz,
  handled_note text,
  constraint report_handled_pair check ((status = 'open') = (handled_by is null)),
  constraint report_handled_note_length check (handled_note is null or char_length(handled_note) <= 500)
);

create unique index player_reports_open_once on player_reports (reporter_id, target_id, context)
  where status = 'open';
create index player_reports_queue on player_reports (report_id) where status = 'open';
create index player_reports_by_target on player_reports (target_id, report_id desc);

alter table player_reports enable row level security;

comment on table  player_reports          is '玩家举报。证据由服务器在举报那一刻复制；同一人对同一人同一场合，处理前只算一条。';
comment on column player_reports.evidence is '服务器快照：被举报消息、他最近的发言、资料。不收客户端上传的记录。';


-- ============================================================================
-- 注销：世界频道的发言算个人数据，删；禁言、举报记录算处罚记录，留（同封号）
-- ============================================================================
--
-- 017 的 erase_player() 原样照抄，只多一行 `delete from world_messages`。
-- backend/tests/test_profile.py 读的是**最后一个**定义 erase_player 的迁移。

create or replace function erase_player(p_player uuid) returns boolean
language plpgsql
as $$
declare
	v_code text;
	v_tries int := 0;
begin
	-- 锁住这一行：两次并发注销只有一次真的执行。
	perform 1 from players where player_id = p_player and deleted_at is null for update;
	if not found then
		return false;
	end if;

	-- 资料与登录方式。
	delete from player_bio          where player_id = p_player;
	delete from player_identities   where player_id = p_player;

	-- 社交往来。
	delete from player_friendships  where low_id = p_player or high_id = p_player;
	delete from player_blocks       where blocker_id = p_player or blocked_id = p_player;
	delete from friend_request_log  where requester_id = p_player or target_id = p_player;
	delete from player_presence     where player_id = p_player;
	delete from player_room_visits  where player_id = p_player;
	-- 私聊：他参与的每一段会话连同双方的消息。
	delete from chat_messages       where low_id = p_player or high_id = p_player;
	delete from chat_read_state     where player_id = p_player;
	delete from chat_conversations  where low_id = p_player or high_id = p_player;
	-- 世界频道的发言（019）。被举报过的，证据已经复制在 player_reports.evidence 里。
	delete from world_messages      where sender_id = p_player;

	-- 被封期间寄存的续期凭证（016）。
	delete from ban_refresh_handoff where player_id = p_player;

	-- 好友码换成一个没人知道的新码。撞了就再来（同 004 回填那段）。
	loop
		v_code := glory_new_friend_code();
		exit when not exists (select 1 from players where friend_code = v_code);
		v_tries := v_tries + 1;
		if v_tries > 100 then
			raise exception '好友码连续冲突 100 次，检查 glory_new_friend_code()';
		end if;
	end loop;

	update players
	   set player_name     = '已注销玩家',
	       avatar          = 'preset:avatar_001',
	       avatar_frame    = 'preset:frame_default',
	       showcase_pet    = null,
	       selected_races  = null,
	       name_changed_at = null,
	       friend_code     = v_code,
	       deleted_at      = now()
	 where player_id = p_player;
	return true;
end;
$$;

comment on function erase_player(uuid) is
	'注销：删资料与社交往来（含世界频道发言）、清展示字段、换好友码；账目、处罚与举报记录保留。已注销过返回 false。';
