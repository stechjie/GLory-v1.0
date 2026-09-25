-- 016: 封号
--
-- 设计见 docs/运营后台设计.md 第二节。配套 backend/app/bans.py。
--
-- 001-015 一个字都不改 —— 编号只增不改，见 database/README.md。
--
--
-- ## 封号只动账号服务器
--
-- 被封的人：登录 / 续期被拒（403，不是 401 —— 见下），手上还没过期的令牌调任何接口也被拒，
-- 在线的实时连接 10 秒内被断开，匹配队列里的位置被摘掉，**拿不到新的出战名片**。
--
-- 战斗服务器不用改：名片 60 秒过期、一张只能用一次、没有名片坐不进任何房间
-- （backend/app/loadout.py 的 CARD_TTL_SEC、NetworkService._accept_seat_card）。
-- 拿不到新名片，最多 60 秒后他就进不了任何新对局。**正在打的那一局照常打完** ——
-- 其他五个人的对局不该因为一个人被封而作废。
--
--
-- ## 🔴 被封回 403，不回 401
--
-- 旧版客户端续期收到 401 会清掉本机凭证、自动注册一个新的匿名号
-- （scripts/autoload/AccountManager.gd 的启动流程）—— 回 401 等于替他换了个号。
-- 403 只会显示登录失败，本机凭证留着，解封之后还是原来那个号。
--
--
-- ## 这张表只追加
--
-- 解封是在原行上打「撤销」标记（revoked_*），不删行。以后要答得出
-- 「这个号被封过几次、谁封的、谁解的、为什么」。
--
--
-- ## 管理员怎么用
--
--   select ban_player(
--     p_friend_code => 'ABCD2345',
--     p_duration    => interval '7 days',     -- null = 永久
--     p_reason      => '使用外挂',              -- 玩家会看到这一句
--     p_actor       => 'arvin',
--     p_note        => '举报截图在群里 9/24');   -- 内部备注，玩家看不到
--
--   select unban_player(p_friend_code => 'ABCD2345', p_actor => 'arvin', p_note => '误封');
--
-- 网页后台（docs/运营后台设计.md）调的也是这两个函数。

create table player_bans (
  ban_id      bigint generated always as identity primary key,
  player_id   uuid not null references players(player_id) on delete cascade,

  created_at  timestamptz not null default now(),
  -- null = 永久。**不用魔法年份**（9999-12-31 之类）：那种值迟早被当成真日期显示给玩家。
  ends_at     timestamptz,
  constraint ban_ends_after_start check (ends_at is null or ends_at > created_at),

  -- 给玩家看的原因。被封的人在登录画面上看到的就是这一句。
  reason      text not null,
  constraint ban_reason_length check (char_length(btrim(reason)) between 1 and 200),

  -- 内部备注（证据在哪、对应哪条举报）。**玩家看不到。**
  note        text,
  constraint ban_note_length check (note is null or char_length(note) <= 500),

  -- 🔴 谁封的，不许空。同 wallet_ledger.actor。
  actor       text not null,
  constraint ban_actor_length check (char_length(btrim(actor)) between 1 and 64),

  -- 解封：打标记，不删行。三列要么都空、要么 revoked_at 与 revoked_by 都有。
  revoked_at  timestamptz,
  revoked_by  text,
  revoke_note text,
  constraint ban_revoke_pair check ((revoked_at is null) = (revoked_by is null)),
  constraint ban_revoked_by_length check (revoked_by is null or char_length(btrim(revoked_by)) between 1 and 64),
  constraint ban_revoke_note_length check (revoke_note is null or char_length(revoke_note) <= 500)
);

-- 每个请求都要问一次「这个人现在有没有被封」，走它。
create index player_bans_live on player_bans (player_id) where revoked_at is null;

alter table player_bans enable row level security;

comment on table  player_bans         is '封号记录。只追加；解封打 revoked_* 标记，不删行。';
comment on column player_bans.ends_at is '解封时间。null = 永久。';
comment on column player_bans.reason  is '给玩家看的原因。';
comment on column player_bans.note    is '内部备注，玩家看不到。';


-- ============================================================================
-- 被封期间的续期凭证寄存
-- ============================================================================
--
-- 🔴 **没有这张表，旧版客户端被封之后会自动换一个新号。**
--
-- 续期时账号服务器先把玩家手上的 refresh token 交给 Supabase，Supabase 当场换一张新的、
-- 旧的作废 —— 之后我们才知道这个人被封了，回 403，新的那张就没交到玩家手上。
-- 玩家下次还拿旧的来：Supabase 把「已经用过的旧凭证」当成被盗，整条会话作废，回 400；
-- 账号服务器照常转成 401；旧版客户端收到 401 清掉凭证、注册新匿名号。
-- 封号自动失效，而且解封之后原来那个号也登不回去了。
--
-- 所以被封时把 Supabase 换出来的新凭证存在这里，按旧凭证的哈希找：
--   还封着 → 直接 403，**不再碰 Supabase**（旧凭证不会被当成重放）；
--   解封了 → 用存着的那张去续，玩家拿到新凭证，回到原来的号。
--
-- 存的是凭证本身（Supabase 自己的 auth.refresh_tokens 在同一个库里也是这样存的）。
-- 玩家一续期成功，存着的这张就在 Supabase 那边作废了。
--
-- ⚠️ **不定期清理。** 永久封号的人一年后拿旧凭证回来，行被清掉的话就又走回
-- 「Supabase 判重放 → 401 → 自动换新号」。一个被封的人最多几行，不值得冒这个险。
create table ban_refresh_handoff (
  -- 玩家手上那张 refresh token 的 SHA-256（hex）。不存原文：它只用来找行。
  token_hash text primary key,
  constraint handoff_hash_shape check (token_hash ~ '^[0-9a-f]{64}$'),
  player_id  uuid not null references players(player_id) on delete cascade,
  -- Supabase 换出来、还没交到玩家手上的那张。
  next_token text not null,
  constraint handoff_token_length check (char_length(next_token) between 1 and 4096),
  updated_at timestamptz not null default now()
);

alter table ban_refresh_handoff enable row level security;

comment on table ban_refresh_handoff is
	'被封期间续期换出来的新凭证。旧版客户端拿旧凭证来时用它，避免 Supabase 判重放、客户端自动换新号。';


-- 封一个玩家（按好友码）。返回封号记录编号。
create function ban_player(
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
		raise exception '必须填操作人（p_actor）：以后要查「这个号是谁封的」';
	end if;
	if p_reason is null or btrim(p_reason) = '' then
		raise exception '必须填原因（p_reason）：被封的玩家会看到这一句';
	end if;
	if p_duration is not null and p_duration <= interval '0' then
		raise exception '封号时长必须是正的（永久封号填 null），现在是 %', p_duration;
	end if;
	-- 好友码是玩家互相抄的东西，前后空格、小写都很常见（同 012 的 send_mail）。
	select player_id into v_player from players where friend_code = upper(btrim(p_friend_code));
	if v_player is null then
		raise exception '没有这个好友码：%（在游戏里的资料页能看到）', p_friend_code;
	end if;

	insert into player_bans (player_id, ends_at, reason, note, actor)
	values (v_player,
	        case when p_duration is null then null else now() + p_duration end,
	        btrim(p_reason), p_note, btrim(p_actor))
	returning ban_id into v_id;
	return v_id;
end;
$$;

comment on function ban_player(text, interval, text, text, text) is
	'封号（按好友码）。p_duration 为 null = 永久。原因玩家看得到，备注看不到。操作人必填。';


-- 解封：把这个玩家**现在生效的**封号全部撤销。返回撤销了几条。
--
-- 为什么是「全部」：管理员说「解封」的意思是「让他能玩了」。只撤一条、另一条还在的话，
-- 玩家照样进不来，而管理员以为已经解了。要撤某一条具体的，网页后台里按记录撤。
create function unban_player(
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
		raise exception '必须填操作人（p_actor）：以后要查「这个号是谁解封的」';
	end if;
	select player_id into v_player from players where friend_code = upper(btrim(p_friend_code));
	if v_player is null then
		raise exception '没有这个好友码：%', p_friend_code;
	end if;

	update player_bans
	   set revoked_at = now(), revoked_by = btrim(p_actor), revoke_note = p_note
	 where player_id = v_player and revoked_at is null and (ends_at is null or ends_at > now());
	get diagnostics v_count = row_count;
	if v_count = 0 then
		raise exception '这个玩家现在没有被封：%', p_friend_code;
	end if;
	return v_count;
end;
$$;

comment on function unban_player(text, text, text) is
	'解封（按好友码）：撤销他现在生效的全部封号。不删行。操作人必填。';
