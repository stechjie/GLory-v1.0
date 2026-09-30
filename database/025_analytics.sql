-- 025: 运营数据第一批（2026-09-30）：在线人数、每日活跃、内部账号标签
--
-- 配套 backend/app/analytics.py（记）、backend/app/analytics_report.py（算），
-- 后台「数据」页。口径与已知误差见 docs/运营数据.md。
--
-- 001–024 一个字都不改 —— 编号只增不改，见 database/README.md。
--
-- 三张新表 + 重定义 erase_player()（多删两张表），🟢。
--
-- ## 为什么现在就要有
--
-- 「每天谁来过」「每时每刻多少人在线」过去了就补不回来：players.last_seen_at 只有最后一次，
-- 连接表在进程内存里。这两张表从账号服务器更新那一刻开始记，之前的日子永远是空的。
--
-- ## 业务日 = 马来西亚时间（Asia/Kuala_Lumpur），同后台和七日登录
--
-- 存的时间一律 timestamptz；game_day 是账号服务器按马来西亚时间算好的日期。


-- ============================================================================
-- 在线人数：每 15 秒一行
-- ============================================================================
--
-- 数的是「此刻连着账号服务器的真人账号」（同一账号几台设备算一个）。游戏开着才连着：
-- 手机切后台引擎就停了、心跳停了，最多 95 秒后断开（app/realtime.py 的 IDLE_TIMEOUT_SEC）。
--
-- 🔴 **没有行 ≠ 0 人。** 账号服务器重启、数据库一时写不进，那 15 秒就没有这一行 ——
-- 报表按「有几行」算采集覆盖率，不把缺的补成 0。server_epoch 换了 = 中间重启过。

create table analytics_online_samples (
  sampled_at   timestamptz primary key,
  server_epoch uuid        not null,
  interval_sec smallint    not null,
  constraint online_sample_interval check (interval_sec between 1 and 600),
  -- 连着的真人账号数，**含**内部账号；内部账号另记一列，报表默认减掉。
  -- 按采样那一刻的标签算：之后才打的标签不回头改旧行。
  players      int not null,
  internal     int not null,
  connections  int not null,
  -- 在启动画面排队、还没放进来的（app/admission.py）。已经含在 players 里。
  queued       int not null,
  constraint online_sample_counts check (
    players >= 0 and internal between 0 and players and connections >= players and queued between 0 and players)
);

alter table analytics_online_samples enable row level security;

comment on table analytics_online_samples is
  '在线人数采样（15 秒一行）。没有行 = 没采到，不是 0 人；server_epoch 换了 = 账号服务器重启过。';


-- ============================================================================
-- 每日活跃：每人每天一行
-- ============================================================================
--
-- 「来过」= 那天游戏开着、连上过账号服务器。只续期令牌、收到邮件不算（那些不经过这条连接）。
-- 跨午夜一直开着的人，两天各一行。
--
-- online_seconds 是连着的时长，精度约 1 分钟：从连上算到最后一次心跳后 30 秒。
-- ⚠️ 电脑版最小化时心跳不停，时长会偏多；手机切后台就停，基本准。

create table analytics_player_days (
  game_day       date not null,
  player_id      uuid not null references players(player_id) on delete cascade,
  first_seen_at  timestamptz not null,
  last_seen_at   timestamptz not null,
  online_seconds int not null default 0,
  constraint player_day_seconds check (online_seconds between 0 and 86400),
  connects       int not null default 0,
  constraint player_day_connects check (connects >= 0),
  primary key (game_day, player_id)
);

-- 留存：按人找他哪几天来过。
create index analytics_player_days_by_player on analytics_player_days (player_id, game_day);

alter table analytics_player_days enable row level security;

comment on table analytics_player_days is
  '每人每天一行：那天连上过账号服务器（游戏开着）。日活、留存、人均时长的底表。注销时删。';


-- ============================================================================
-- 内部账号：员工、测试、压测号 —— 报表默认排除
-- ============================================================================
--
-- 在后台玩家页打。报表同时写明排除了几个，原始总数照样查得到。
-- 按「现在」的标签算：给一个号补打标签，他以前的日活、留存也一起排除（在线人数的旧行除外，见上）。

create table analytics_account_tags (
  player_id uuid primary key references players(player_id) on delete cascade,
  kind      text not null,
  constraint account_tag_kind check (kind in ('staff', 'qa', 'loadtest')),
  note      text,
  constraint account_tag_note_length check (note is null or char_length(note) <= 200),
  tagged_by text not null,
  tagged_at timestamptz not null default now()
);

alter table analytics_account_tags enable row level security;

comment on table analytics_account_tags is
  '内部账号（staff 员工 / qa 测试 / loadtest 压测），运营数据默认排除。谁打的、什么时候打的都在操作记录里。';


-- ============================================================================
-- 注销：每日活跃与标签算个人数据，删
-- ============================================================================
--
-- 019 的 erase_player() 原样照抄，只多两行 delete。
-- backend/tests/test_profile.py 读的是**最后一个**定义 erase_player 的迁移。
--
-- 代价：注销的人以前的日活从统计里消失（留存的名单里也不算他）。几个人的量，接受。

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

	-- 哪天来过、在线多久（025）；内部账号标签（025）。
	delete from analytics_player_days  where player_id = p_player;
	delete from analytics_account_tags where player_id = p_player;

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
	'注销：删资料与社交往来（含世界频道发言、每日活跃记录）、清展示字段、换好友码；账目、处罚与举报记录保留。已注销过返回 false。';
