-- 036: 处罚范围扩到「禁语音」「禁排位」（OPS-02 的基础）
--
-- 配套：backend/app/sanctions.py、backend/app/routes/admin.py、
-- backend/app/ranked.py 的 queue_gate、backend/app/party_voice.py。
-- 需求来源：docs/后台功能完善_核对结论_20261012.md 的 OPS-02。
--
--
-- ## 一 为什么不新建一张「统一处罚表」
--
-- 019 的 `player_mutes` **本来就是按可扩展设计的**：它已经有 scope 列，
-- 而且那张表自己的注释写着「scope 先只有 world；**以后要禁房间 / 局内聊天再加值**」。
-- 任务书要的「统一处罚页」是**页面**统一，不是非得存储统一 ——
-- 它还明说「历史封号及禁言可以关联展示，不应为迁移而再次执行」。
--
-- 所以这里只放宽约束、复用现成的表与「只追加、解除打标记」的形状。
-- 新建一张表再把旧数据搬过去，收益只有「整齐」，代价是动了 016/019 两条
-- 已经在线上跑着的路径（封号还连着 403 与续期凭证寄存）。不值得。
--
-- 账号封禁（016 的 `player_bans`）**不并进来**：它的语义不一样 ——
-- 整个账号进不去、要强制下线、要寄存续期凭证。那是另一类东西。
--
--
-- ## 二 🔴 这次顺手修一个还没发作的 bug
--
-- `unmute_player` 现在撤销的是「这个玩家**全部**生效中的禁言」，不分 scope。
-- 今天只有 world 一种，所以看不出问题；一旦加了 voice / ranked，
-- 「解除世界频道禁言」就会连带把禁语音也解了。
--
-- 任务书 §四.3 明确要求「撤销其中一个不解除另一个」，所以这次把它改成按 scope 撤销。
-- 默认值仍是 'world'，`admin.py` 那两处 5 参 / 3 参调用**不用改**，行为也和今天一致
-- （今天库里只有 world 行）。
--
-- 相对的，`world_chat.py` 的 `_LIVE_MUTE` 已经写了 `scope = 'world'`，
-- 不会被新 scope 污染 —— 那一条原作者做对了，不用动。
--
--
-- ## 三 🔴 部署
--
-- ① Supabase SQL Editor 跑本文件 → ② deploy/update.sh。
--
-- **跑完需要重启后端。** 本文件 `drop function` 再 `create`，旧连接上缓存的
-- 执行计划会指向已经不存在的函数，报 `cache lookup failed for function`。
-- （这点和 032 一样，和只建新表的 035 不一样。）
--
-- 🔴 **check 约束放宽这一类，启动自检的 prepare 抓不到**（语句本身合法，
-- 要到真 insert 才被拒）—— 和 030 同一个形状。所以 app/schema_check.py 里
-- 给它加了一条直接问系统表的探针，别删。
--
-- 幂等：约束先 drop 再 add、函数先 drop 再 create，手工跑两遍安全。
-- 🟢 不锁表（player_mutes 行数很少，而且 drop/add constraint 只扫这张表）。


-- ── 一 放宽 scope ───────────────────────────────────────────────────────────
alter table player_mutes drop constraint if exists mute_scope;
alter table player_mutes add constraint mute_scope
  check (scope in ('world', 'voice', 'ranked'));

comment on column player_mutes.scope is
  'world = 世界频道禁言；voice = 禁止语音发言（仍可收听）；ranked = 人工禁止排位。'
  '三者互不影响：撤销一个不解除另外两个。账号封禁不在这张表里（见 016 player_bans）。';

comment on table player_mutes is
  '处罚记录（世界频道禁言 / 禁语音 / 禁排位）。只追加；解除打 revoked_* 标记，不删行。';


-- ── 二 下处罚：加 p_scope ────────────────────────────────────────────────────
--
-- 六参带默认值，所以现有的 5 参调用照常命中，不用改 admin.py。
drop function if exists mute_player(text, interval, text, text, text);
drop function if exists mute_player(text, interval, text, text, text, text);

create function mute_player(
	p_friend_code text,
	p_duration    interval,
	p_reason      text,
	p_actor       text,
	p_note        text default null,
	p_scope       text default 'world'
) returns bigint
language plpgsql
as $$
declare
	v_player uuid;
	v_id     bigint;
begin
	if p_actor is null or btrim(p_actor) = '' then
		raise exception '必须填操作人（p_actor）：以后要查「这个号是谁处罚的」';
	end if;
	if p_reason is null or btrim(p_reason) = '' then
		raise exception '必须填原因（p_reason）：被处罚的玩家会看到这一句';
	end if;
	if p_duration is not null and p_duration <= interval '0' then
		raise exception '处罚时长必须是正的（永久填 null），现在是 %', p_duration;
	end if;
	-- 在这里也挡一道：约束会挡，但错误信息是 Postgres 的，看不出哪里错了。
	if p_scope is null or p_scope not in ('world', 'voice', 'ranked') then
		raise exception '不认识的处罚范围：%（只能是 world / voice / ranked）', p_scope;
	end if;
	select player_id into v_player from players where friend_code = upper(btrim(p_friend_code));
	if v_player is null then
		raise exception '没有这个好友码：%', p_friend_code;
	end if;

	insert into player_mutes (player_id, scope, ends_at, reason, note, actor)
	values (v_player, p_scope,
	        case when p_duration is null then null else now() + p_duration end,
	        btrim(p_reason), p_note, btrim(p_actor))
	returning mute_id into v_id;
	return v_id;
end;
$$;

comment on function mute_player(text, interval, text, text, text, text) is
	'下处罚（按好友码）。p_scope：world 世界频道禁言 / voice 禁语音 / ranked 禁排位，默认 world。'
	'p_duration 为 null = 永久。原因玩家看得到，备注看不到。操作人必填。';


-- ── 三 解除：🔴 只解这一个 scope ──────────────────────────────────────────────
drop function if exists unmute_player(text, text, text);
drop function if exists unmute_player(text, text, text, text);

create function unmute_player(
	p_friend_code text,
	p_actor       text,
	p_note        text default null,
	p_scope       text default 'world'
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
	if p_scope is null or p_scope not in ('world', 'voice', 'ranked') then
		raise exception '不认识的处罚范围：%（只能是 world / voice / ranked）', p_scope;
	end if;
	select player_id into v_player from players where friend_code = upper(btrim(p_friend_code));
	if v_player is null then
		raise exception '没有这个好友码：%', p_friend_code;
	end if;

	-- 🔴 **带上 scope**。不带的话解除世界频道禁言会连带把禁语音、禁排位一起解了
	-- （任务书 §四.3：撤销其中一个不解除另一个）。
	-- 同一 scope 下有多条生效时全部撤销 —— 这一条沿用 016 unban_player 的口径。
	update player_mutes
	   set revoked_at = now(), revoked_by = btrim(p_actor), revoke_note = p_note
	 where player_id = v_player and scope = p_scope
	   and revoked_at is null and (ends_at is null or ends_at > now());
	get diagnostics v_count = row_count;
	if v_count = 0 then
		raise exception '这个玩家现在没有生效中的 % 处罚：%', p_scope, p_friend_code;
	end if;
	return v_count;
end;
$$;

comment on function unmute_player(text, text, text, text) is
	'解除处罚（按好友码 + 范围）：撤销他该范围内生效的全部记录。不删行。'
	'**只解这一个范围**，不碰其它范围的处罚。操作人必填。';
