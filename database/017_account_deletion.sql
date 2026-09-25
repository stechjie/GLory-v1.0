-- 017: 注销账号 = 删资料、留账目
--
-- 设计见 docs/运营后台设计.md 第三节。配套 backend/app/profile.py 的 delete_player()。
--
-- 001-016 一个字都不改 —— 编号只增不改，见 database/README.md。
--
--
-- ## 为什么不再 `delete from players`
--
-- 以前注销只发一句 `delete from players`，靠外键 on delete cascade 把二十多张表一起删掉。
-- 那样删得最干净，但连**账目**也一起没了：钻石流水、订单、邮件领取、对局、封号记录。
--
--   · 接了充值之后，Google / Apple 在他注销后发来退款通知，我们查不到他当初买了什么；
--   · 被封的人注销一下，封号记录就没了；
--   · 「流水永不删除」（009）被注销一键绕过。
--
-- 2026-09-24 拍板：**删资料、留账目。** Google Play 与 App Store 都允许为财务、
-- 防作弊保留这类记录。
--
--
-- ## 删什么、留什么
--
-- 删（能认出这个人、或者是他和别人的社交往来）：
--   资料（player_bio）、登录方式（player_identities —— 删了就再也登不回这个号）、
--   好友 / 拉黑 / 好友请求 / 在线状态、最近同房、私聊、被封期间寄存的续期凭证；
--   players 这一行上的昵称、头像、头像框、展示宠物、出战种族清回默认，
--   **好友码换成一个新的随机码** —— 别人手上记着的旧码从此查不到任何人。
--
-- 留（账目与游戏记录，只剩一串编号，看不出是谁）：
--   钱包与流水、订单与归属、邮件与领取记录、对局座位、排位分 / 信誉分 / 赛季归档、封号记录。
--
-- backend/tests/test_profile.py 钉着：**每一张引用 players 的表都必须在这两边之一**。
-- 以后加新表，要先想清楚它属于哪一边。
--
--
-- ## 为什么好友码是换掉、而不是在每个查询里加 `deleted_at is null`
--
-- 查好友码的地方有好几处（资料页、加好友、私聊、名片…）。每处都加一个条件，
-- 漏一处就是一个「已注销的人还能被加好友」；而且这些查询都会依赖本文件的新列 ——
-- 部署时账号服务器先上、017 没跑，资料页和加好友就全挂了。
-- 换一个没人知道的码，一处都不用改。

alter table players add column deleted_at timestamptz;

comment on column players.deleted_at is '注销时刻。非空 = 这一行只剩编号与账目，资料已删。';


-- 注销。返回是否真的删到了（已经注销过的返回 false）。一个事务：要么全删，要么都不删。
create function erase_player(p_player uuid) returns boolean
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
	-- 私聊：他参与的每一段会话连同双方的消息。消息表按会话外键本来也会跟着删，
	-- 这里写明，免得以后有人改了那个外键、消息悄悄留下来。
	delete from chat_messages       where low_id = p_player or high_id = p_player;
	delete from chat_read_state     where player_id = p_player;
	delete from chat_conversations  where low_id = p_player or high_id = p_player;

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
	'注销：删资料与社交往来、清展示字段、换好友码；账目与游戏记录保留。已注销过返回 false。';
