-- 026: 运营数据第二批（2026-09-30）：游戏上报的事件
--
-- 配套 backend/app/client_events.py（收）、routes/events.py（POST /v1/events）、
-- 客户端 scripts/autoload/AnalyticsService.gd。事件清单与口径见 docs/运营数据.md 第六节。
--
-- 001–025 一个字都不改。一张新表 + 重定义 erase_player()（多删这一张），🟢。
--
-- ## 🔴 这是客户端说的，不是服务器说的
--
-- 教学走到哪、战斗播没播完、报了什么错 —— 只有客户端知道，所以只能听它的。
-- 回合结果（round_result）的数是战斗服务器算好发给客户端、客户端原样转来的，
-- 可信度仍然只算「客户端」：改过的客户端能乱报。**不拿这张表发奖励、判排位、做处罚。**
--
-- ## 一条事件只记一次
--
-- 编号（event_id）客户端生成、重发时不变；主键 (player_id, event_id)。
-- 同一个编号再来一次就是重发，不算第二条。


create table analytics_client_events (
  player_id   uuid not null references players(player_id) on delete cascade,
  event_id    uuid not null,
  name        text not null,
  constraint client_event_name check (name ~ '^[a-z_]{1,40}$'),
  -- 发生时刻：客户端的钟按「发送那一刻」对齐到服务器的钟（改手机时间改不了日期），见 client_events.py。
  occurred_at timestamptz not null,
  received_at timestamptz not null default now(),
  -- 客户端这次启动的编号 / 这次安装的编号（随机数，卸载重装就换；不是设备标识）。
  session_id  uuid,
  install_id  uuid,
  -- 包的版本号（build_info.json 的 version_code，编辑器里跑是 0）。
  build       int,
  props       jsonb not null default '{}'::jsonb,
  constraint client_event_props_size check (octet_length(props::text) <= 4096),
  primary key (player_id, event_id)
);

-- 后台按事件名 + 时间段统计（教学漏斗、回合、报错）。
create index analytics_client_events_by_name on analytics_client_events (name, occurred_at);
-- 按人看时间线。
create index analytics_client_events_by_player on analytics_client_events (player_id, occurred_at);

alter table analytics_client_events enable row level security;

comment on table analytics_client_events is
  '游戏上报的事件（教学步骤、对局、战斗播放、报错、帧率）。客户端说的，只做统计，不做判定。注销时删。';


-- ============================================================================
-- 注销：上报的事件算个人数据，删
-- ============================================================================
--
-- 025 的 erase_player() 原样照抄，只多一行 delete。
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

	-- 哪天来过、在线多久（025）；内部账号标签（025）；游戏上报的事件（026）。
	delete from analytics_player_days   where player_id = p_player;
	delete from analytics_account_tags  where player_id = p_player;
	delete from analytics_client_events where player_id = p_player;

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
	'注销：删资料与社交往来（含世界频道发言、每日活跃、上报事件）、清展示字段、换好友码；账目、处罚与举报记录保留。已注销过返回 false。';
