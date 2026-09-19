-- 012: 系统邮件
--
-- 设计见 docs/邮件系统设计.md。配套 backend/app/mail.py。
--
-- 只有系统邮件：服务端发，玩家读、领附件、删。**没有玩家之间的邮件** —— 那是聊天的活。
--
-- ## 管理员怎么发
--
-- 延续公告那条：Supabase 后台直接操作，没有正式后台。但邮件会发钱，所以**只给函数入口**
-- （本文件末尾的 send_mail / send_mail_all / withdraw_mail），不要手写 insert ——
-- 函数会查好友码、强制填操作人、给出能看懂的报错。
--
-- ## 一封群发只存一行
--
-- 群发不按玩家复制。玩家打开邮箱时，账号服务器按「发给我的 + 我能收到的群发」现算；
-- 读过 / 领过 / 删过才在 mail_states 里落一行。全服几万人也只是一行邮件。
--
-- ## 🔴 邮件行不删
--
-- 撤回用 withdraw_mail（打标记），过期了留着。钱包流水的 mail_id 指着它 ——
-- 「这笔钻石是哪封邮件发的」要一直查得到，同 009 里「流水永不裁剪」那条。

create table mails (
  mail_id      bigint generated always as identity primary key,

  -- 收件人。null = 全服。
  player_id    uuid references players(player_id) on delete cascade,

  -- 全服邮件：发出之后才注册的新玩家能不能收到。
  --   false（默认）= 只给发送那一刻已经存在的玩家。补偿用 —— 事故之后才注册的人没受影响。
  --   true         = 过期之前注册的新玩家也能收到。活动礼包用。
  -- 对单人邮件没有意义，所以下面的约束不许单人邮件打开它（免得有人以为它有作用）。
  include_new_players boolean not null default false,
  constraint mail_new_players_only_for_broadcast
    check (player_id is null or not include_new_players),

  -- 中英文各一份，英文空着时客户端显示中文。同 008 公告。
  title_zh     text not null,
  body_zh      text not null default '',
  title_en     text,
  body_en      text,
  constraint mail_title_zh_length check (char_length(btrim(title_zh)) between 1 and 60),
  constraint mail_body_zh_length  check (char_length(body_zh) <= 2000),
  constraint mail_title_en_length check (title_en is null or char_length(title_en) <= 60),
  constraint mail_body_en_length  check (body_en is null or char_length(body_en) <= 2000),

  -- 附件。钻石进的是 **diamond_free**（赠送）—— 邮件发的钱不是玩家付的，
  -- 混进付费列就把退款口径弄脏了（009 的 grant_diamonds 同一条）。
  --
  -- 单封上限是**防手滑**：500 多打两个 0 就是 50000。真要发更多就分几封，
  -- 那样每一封都得有人再看一眼。
  diamond      bigint not null default 0,
  coin         bigint not null default 0,
  constraint mail_diamond_range check (diamond between 0 and 100000),
  constraint mail_coin_range    check (coin between 0 and 1000000),

  -- 内容 id（pet_cat / preset:avatar_101），不是商品 id —— 同 010 归属表。
  -- 这里只管格式。「是不是能发的东西」由账号服务器判：**只有商品目录里卖的才能发**
  -- （不在目录里的本来就人人免费，发了等于没发），不认识的整封不给玩家看，
  -- 原因写进下面的 problem 列。
  items        text[] not null default '{}',
  constraint mail_items_shape check (
    cardinality(items) <= 10
    and (cardinality(items) = 0
         or array_to_string(items, ',') ~ '^[a-z0-9_:]{1,64}(,[a-z0-9_:]{1,64})*$')
  ),

  -- 🔴 谁发的，不许空。同 wallet_ledger.actor：邮件会发钱，
  -- 「谁给这个号发了 10000 钻」必须查得到。
  actor        text not null,
  constraint mail_actor_length check (char_length(btrim(actor)) between 1 and 64),

  -- 内部备注（为什么发、对应哪次事故）。**玩家看不到。**
  note         text,
  constraint mail_note_length check (note is null or char_length(note) <= 200),

  created_at   timestamptz not null default now(),
  -- 过期之后玩家看不到，没领的附件也就没了。默认 30 天（docs/邮件系统设计.md 拍板）。
  expires_at   timestamptz not null default now() + interval '30 days',
  constraint mail_expires_after_created check (expires_at > created_at),

  -- 撤回。**不删行**，理由见文件头。
  withdrawn_at timestamptz,

  -- 账号服务器写：这封邮件为什么没发出去（附件里有不能发的东西）。
  -- 管理员在表格里看这一列。为空 = 正常。
  problem      text
);

-- 「发给我的」走它。
create index mails_by_player on mails (player_id, mail_id desc) where player_id is not null;
-- 「全服的」走它。
create index mails_broadcast on mails (mail_id desc) where player_id is null;

alter table mails enable row level security;

comment on table  mails                     is '系统邮件。一封群发只存一行。撤回打标记，不删行。';
comment on column mails.player_id           is '收件人。null = 全服。';
comment on column mails.include_new_players is '全服邮件：发出之后才注册的玩家能不能收到。false = 只给当时已有的玩家（补偿），true = 过期前注册的也给（活动礼包）。';
comment on column mails.diamond             is '附件钻石，领取时进 diamond_free。单封上限 100000，防手滑。';
comment on column mails.items               is '附件内容 id。只有商品目录里卖的才能发；不认识的整封不给玩家看，见 problem。';
comment on column mails.actor               is '发件的操作人，不许为空。';
comment on column mails.note                is '内部备注，玩家看不到。';
comment on column mails.problem             is '账号服务器写：这封为什么没发出去。为空 = 正常。';


-- ============================================================================
-- 每个玩家对每封邮件的状态
-- ============================================================================
--
-- 读过 / 领过 / 删过才有行。没有行 = 没读、没领、没删。
--
-- 🔴 **「领过」只能在这里记一次** —— 领取的事务先锁这一行再发东西
-- （backend/app/mail.py 的 claim）。两台手机同时点、弱网重试，都只到账一次。

create table mail_states (
  player_id  uuid   not null references players(player_id) on delete cascade,
  mail_id    bigint not null references mails(mail_id) on delete cascade,
  read_at    timestamptz,
  claimed_at timestamptz,
  -- 玩家删的。只是他自己看不到，邮件和领取记录都还在。
  deleted_at timestamptz,
  primary key (player_id, mail_id)
);

-- 注销账号时单人邮件跟着删，级联要按 mail_id 找状态行。
create index mail_states_by_mail on mail_states (mail_id);

alter table mail_states enable row level security;

comment on table mail_states is '玩家对邮件的已读 / 已领 / 已删。没有行 = 都没有。领取只记一次。';


-- ============================================================================
-- 流水记上是哪封邮件发的
-- ============================================================================
--
-- source 记 'mail'（backend/app/shop.py 的 SOURCES），这一列记具体哪封。
-- 一键领取会在同一时刻写好几笔，只靠时间对不上是哪封。

alter table wallet_ledger add column mail_id bigint references mails(mail_id);

-- 注销账号删单人邮件时，外键要检查流水里有没有指着它的行。
create index wallet_ledger_by_mail on wallet_ledger (mail_id) where mail_id is not null;

comment on column wallet_ledger.mail_id is '邮件附件发的钱：是哪封邮件。其他来源为空。';


-- ============================================================================
-- 管理员入口
-- ============================================================================
--
-- 用具名参数调用，不用记顺序：
--
--   select send_mail(
--     p_friend_code => 'ABCD2345',
--     p_title_zh    => '9/20 掉单补偿',
--     p_body_zh     => '抱歉，这是补给你的钻石。',
--     p_actor       => 'arvin',
--     p_diamond     => 500);
--
--   select send_mail_all(
--     p_title_zh            => '开服礼包',
--     p_body_zh             => '感谢参加测试！',
--     p_actor               => 'arvin',
--     p_diamond             => 100,
--     p_include_new_players => true,
--     p_days                => 14);
--
--   select withdraw_mail(12);
--
-- 手册：docs/邮件系统设计.md 第三节。

create function send_mail(
	p_friend_code text,
	p_title_zh    text,
	p_body_zh     text,
	p_actor       text,
	p_diamond     bigint  default 0,
	p_coin        bigint  default 0,
	p_items       text[]  default '{}',
	p_days        integer default 30,
	p_note        text    default null,
	p_title_en    text    default null,
	p_body_en     text    default null
) returns bigint
language plpgsql
as $$
declare
	v_player uuid;
	v_id     bigint;
begin
	if p_actor is null or btrim(p_actor) = '' then
		raise exception '必须填操作人（p_actor）：以后要查「谁给这个号发了东西」';
	end if;
	if p_days is null or p_days < 1 or p_days > 365 then
		raise exception '有效天数要在 1 到 365 之间，现在是 %', p_days;
	end if;
	-- 好友码是玩家互相抄的东西，前后空格、小写都很常见。
	select player_id into v_player from players where friend_code = upper(btrim(p_friend_code));
	if v_player is null then
		raise exception '没有这个好友码：%（在游戏里的资料页能看到）', p_friend_code;
	end if;

	insert into mails
		(player_id, title_zh, body_zh, title_en, body_en,
		 diamond, coin, items, actor, note, expires_at)
	values
		(v_player, p_title_zh, coalesce(p_body_zh, ''), p_title_en, p_body_en,
		 coalesce(p_diamond, 0), coalesce(p_coin, 0), coalesce(p_items, '{}'),
		 btrim(p_actor), p_note, now() + make_interval(days => p_days))
	returning mail_id into v_id;
	return v_id;
end;
$$;

comment on function send_mail(text, text, text, text, bigint, bigint, text[], integer, text, text, text) is
	'给一个玩家（按好友码）发系统邮件。返回邮件编号。操作人必填。';


create function send_mail_all(
	p_title_zh            text,
	p_body_zh             text,
	p_actor               text,
	p_include_new_players boolean default false,
	p_diamond             bigint  default 0,
	p_coin                bigint  default 0,
	p_items               text[]  default '{}',
	p_days                integer default 30,
	p_note                text    default null,
	p_title_en            text    default null,
	p_body_en             text    default null
) returns bigint
language plpgsql
as $$
declare
	v_id bigint;
begin
	if p_actor is null or btrim(p_actor) = '' then
		raise exception '必须填操作人（p_actor）：全服邮件尤其要查得到是谁发的';
	end if;
	if p_days is null or p_days < 1 or p_days > 365 then
		raise exception '有效天数要在 1 到 365 之间，现在是 %', p_days;
	end if;

	insert into mails
		(player_id, include_new_players, title_zh, body_zh, title_en, body_en,
		 diamond, coin, items, actor, note, expires_at)
	values
		(null, coalesce(p_include_new_players, false), p_title_zh, coalesce(p_body_zh, ''),
		 p_title_en, p_body_en,
		 coalesce(p_diamond, 0), coalesce(p_coin, 0), coalesce(p_items, '{}'),
		 btrim(p_actor), p_note, now() + make_interval(days => p_days))
	returning mail_id into v_id;
	return v_id;
end;
$$;

comment on function send_mail_all(text, text, text, boolean, bigint, bigint, text[], integer, text, text, text) is
	'发全服邮件（只存一行）。p_include_new_players 决定之后注册的玩家能不能收到。操作人必填。';


-- 撤回：没领的人就看不到了。**已经领走的收不回来** —— 那要走退款流程（有据可查），
-- 不是偷偷改余额。
create function withdraw_mail(p_mail bigint) returns void
language plpgsql
as $$
begin
	update mails set withdrawn_at = now() where mail_id = p_mail and withdrawn_at is null;
	if not found then
		raise exception '没有这封邮件，或者它已经撤回过了：%', p_mail;
	end if;
end;
$$;

comment on function withdraw_mail(bigint) is
	'撤回一封邮件。没领的人看不到了；已领走的收不回来。不删行。';
