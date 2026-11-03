-- 044: 兑换码
--
-- 设计 2026-11-03 和用户逐条拍板；配套 backend/app/redeem.py。
--
-- 和邀请码（043）共用的只有「奖励走邮件」。其余是两回事：
-- 邀请码是每人一个的永久身份；兑换码是运营造的、**会泄漏、会被爆破**的东西。
--
-- 🔴 这是全系统唯一一个「猜对了就给钱」的接口。限流在账号服务器（按账号，不按 IP）。
--
-- ## 一张表装两种码，区别只在 max_uses
--
--   通用码  GLORY2026   人取的名字，全服都能填，一人一次
--   单次码  12 位随机    max_uses = 1，批量生成（KOL / 补偿 / 线下活动）
--
-- ## 管理员怎么建
--
-- 建码会发钱，所以和发钻石同一条规矩：**网页后台提交、另一个管理员批准**（018）。
-- 批准时后台调的就是本文件末尾这几个函数。紧急时在 Supabase 里直接调也行（同 send_mail），
-- 但**不要手写 insert** —— 函数会规范化码、强制填操作人、给出能看懂的报错。
--
--   select create_redeem_code(
--     p_code     => 'GLORY2026',
--     p_max_uses => 5000,
--     p_actor    => 'arvin',
--     p_diamond  => 100,
--     p_days     => 14);
--
--   select create_redeem_batch(p_count => 200, p_actor => 'arvin', p_diamond => 50);
--
--   select withdraw_redeem_code('GLORY2026');          -- 一个码止血
--   select withdraw_redeem_campaign('batch_20261103_…'); -- 一整批止血
--
-- **撤回只要一个人。** 开闸要两个人，关闸一个人就够 —— 止血必须立刻做。
--
-- ## 🔴 码行不删
--
-- 泄漏了用 withdrawn_at 止血。claims 指着它，「这笔钻石是哪个码发的」要一直查得到
-- （同 012 邮件行不删）。
--
-- 可重复执行。🔴 必须在更新账号服务器之前跑。


-- ============================================================================
-- 单次码的生成
-- ============================================================================
--
-- 字母表与好友码（004）相同，排掉 0 O 1 I L —— 单次码是玩家从图片、直播里抄的。
--
-- 和好友码有一处刻意不同：**拒绝采样**。好友码是公开的查找键，004 那边说过
-- 「256 mod 31 的偏置无关紧要」；单次码是**秘密**，猜中就拿钱，所以把偏置消掉：
-- 只收 0–247（= 31 × 8）的字节，248–255 丢掉重取。
--
-- 31 ^ 12 ≈ 7.9 × 10^17。按账号限流下，爆破单次码在算术上不可能。
create or replace function glory_new_redeem_code() returns text
language plpgsql
volatile
as $$
declare
	alphabet constant text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
	n        constant int  := 31;
	raw      bytea;
	pos      int := 16;
	b        int;
	out_code text := '';
begin
	while char_length(out_code) < 12 loop
		if pos >= 16 then
			-- gen_random_uuid 是密码学随机；不用 random()（理由见 004）。
			raw := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
			pos := 0;
		end if;
		b := get_byte(raw, pos);
		pos := pos + 1;
		if b < 248 then
			out_code := out_code || substr(alphabet, 1 + (b % n), 1);
		end if;
	end loop;
	return out_code;
end;
$$;

comment on function glory_new_redeem_code() is
	'生成 12 位单次兑换码。字母表同好友码；拒绝采样消掉取模偏置（它是秘密，好友码不是）。';


-- 玩家抄码时常见的空格、连字符、小写都去掉。
-- 🔴 与 backend/app/redeem.py 的 normalize() 必须一致（tests/test_redeem_pg.py 钉着）。
create or replace function glory_normalize_redeem_code(p_code text) returns text
language sql
immutable
as $$
	select upper(regexp_replace(coalesce(p_code, ''), '[[:space:]-]', '', 'g'));
$$;


-- ============================================================================
-- 码
-- ============================================================================

create table if not exists redeem_codes (
  code_id    bigint generated always as identity primary key,

  -- 存的一律是规范化后的形态（glory_normalize_redeem_code）。
  --
  -- 字母表比好友码宽：放行 A-Z0-9 全 36 个。运营要能取 GLORY2026 这种名字，
  -- 窄字母表连 0 和 1 都打不出来。代价是通用码可能出现 0 / O 混淆 ——
  -- 由取名的人自己避开。**我们生成的单次码仍然用窄字母表**，不会混。
  code       text not null,
  constraint redeem_code_format check (code ~ '^[A-Z0-9]{4,24}$'),
  constraint redeem_code_unique unique (code),

  -- 活动分组。同一个 campaign 下一个号只能领一个 ——
  -- 运营发了 5 个码，玩家不该全填一遍。null = 不分组。
  -- 批量码一定有（create_redeem_batch 没给就用批次号）。
  campaign   text,
  constraint redeem_campaign_length check (
    campaign is null or char_length(btrim(campaign)) between 1 and 32),

  -- 🔴 **必填，不许无限。** 一个泄漏的无限码 = 全服白拿，而唯一的刹车是人工撤回 ——
  --    从泄漏到有人发现通常是几小时。必须填 = 自动刹车：要发给全服就填 100000，
  --    但建码的人必须想一下这个数。
  max_uses   integer not null,
  constraint redeem_max_uses_range check (max_uses between 1 and 1000000),

  -- 已领次数。冗余（claims 能数出来），但「先数再写」在并发下会超发。
  -- 领取走 update … where used_count < max_uses returning，一条语句定胜负。
  -- 下面的约束是最后一道：就算哪天有人写错了领取逻辑，也超发不了。
  used_count integer not null default 0,
  constraint redeem_used_count_range check (
    used_count >= 0 and used_count <= max_uses),

  -- 奖励口径完全照邮件（012）：钻石进 diamond_free（赠送列），
  -- 不进付费列 —— 混进去就把退款口径弄脏了。
  -- 上限是防手滑：500 多打两个 0 就是 50000。
  diamond    bigint not null default 0,
  coin       bigint not null default 0,
  items      text[] not null default '{}',
  constraint redeem_diamond_range check (diamond between 0 and 100000),
  constraint redeem_coin_range    check (coin between 0 and 1000000),
  constraint redeem_items_shape check (
    cardinality(items) <= 10
    and (cardinality(items) = 0
         or array_to_string(items, ',') ~ '^[a-z0-9_:]{1,64}(,[a-z0-9_:]{1,64})*$')),
  -- 什么都不发的码一定是填错了。
  constraint redeem_gives_something check (
    diamond > 0 or coin > 0 or cardinality(items) > 0),

  starts_at  timestamptz not null default now(),
  expires_at timestamptz not null,
  constraint redeem_expires_after_start check (expires_at > starts_at),

  -- 🔴 泄漏之后的止血手段。不要 delete。
  withdrawn_at timestamptz,

  -- 🔴 谁建的，不许空。同 mails.actor 与 wallet_ledger.actor：
  --    「谁建了这个发 10000 钻的码」必须查得到。后台批准时记「申请人/批准人」。
  actor      text not null,
  constraint redeem_actor_length check (char_length(btrim(actor)) between 1 and 64),

  -- 内部备注（为什么建、哪个活动）。**玩家看不到。**
  note       text,
  constraint redeem_note_length check (note is null or char_length(note) <= 200),

  created_at timestamptz not null default now()
);

-- 后台按活动列出、整批撤回。
create index if not exists redeem_codes_by_campaign on redeem_codes (campaign) where campaign is not null;

alter table redeem_codes enable row level security;

comment on table redeem_codes is
  '兑换码。通用码与单次码同一张表，区别只在 max_uses。撤回打标记，不删行。';
comment on column redeem_codes.max_uses is
  '总共能被领多少次。必填、不许无限：泄漏的码要有自动刹车。单次码是 1。';


-- ============================================================================
-- 谁领过哪个码
-- ============================================================================

create table if not exists redeem_claims (
  -- 不加 on delete cascade：码行不删。真有人手滑 delete 一个被领过的码，
  -- 外键会直接拦下来 —— 这正是要的。
  code_id    bigint not null references redeem_codes(code_id),
  player_id  uuid   not null references players(player_id) on delete cascade,

  -- redeem_codes.campaign 的副本，由下面的触发器填，**应用层不写**。
  -- 为什么要抄：「同一活动只能领一个」要靠唯一索引才能在并发下守住，
  -- 而唯一索引只能建在一张表的列上。
  campaign   text,

  -- 发奖那封邮件。建邮件、写这一行、扣 used_count 在同一个事务里。
  mail_id    bigint not null references mails(mail_id),

  claimed_at timestamptz not null default now(),

  -- 同一个码，一个号只能领一次。
  primary key (code_id, player_id)
);

-- 同一个活动，一个号只能领一个码。
-- 🔴 必须是唯一索引，不能是应用层「先查再插」：
--    两个请求同时进来，都查到「没领过」，就都领了。
create unique index if not exists redeem_claims_campaign_once
  on redeem_claims (campaign, player_id) where campaign is not null;

-- 客服查「这个号领过哪些码」。
create index if not exists redeem_claims_by_player on redeem_claims (player_id);

alter table redeem_claims enable row level security;

comment on table redeem_claims is
  '兑换记录。(码, 玩家) 唯一；同一 campaign 一人一条。campaign 是触发器从 redeem_codes 抄来的。';


-- 副本由数据库自己抄，应用层传什么都被覆盖 —— 抄错的副本比没有副本更糟。
-- 插入和改行都重抄：有人直接 update 这一列也改不歪。
create or replace function redeem_claims_copy_campaign() returns trigger
language plpgsql
as $$
begin
	new.campaign := null;
	select campaign into new.campaign from redeem_codes where code_id = new.code_id;
	return new;
end;
$$;

drop trigger if exists redeem_claims_copy_campaign on redeem_claims;
create trigger redeem_claims_copy_campaign
	before insert or update on redeem_claims
	for each row execute function redeem_claims_copy_campaign();


-- 码的 campaign 建了就不许改。不然：码 A 被领过（副本记着 nov），运营把 A 改成 dec，
-- 领过 A 的人就能再领一个 dec 的码 —— 互斥被一次 update 绕过。建错了就撤回、重建。
create or replace function redeem_codes_campaign_frozen() returns trigger
language plpgsql
as $$
begin
	if new.campaign is distinct from old.campaign then
		raise exception '兑换码的 campaign 建了就不能改（码 %）：撤回它，重建一个', old.code;
	end if;
	return new;
end;
$$;

drop trigger if exists redeem_codes_campaign_frozen on redeem_codes;
create trigger redeem_codes_campaign_frozen
	before update on redeem_codes
	for each row execute function redeem_codes_campaign_frozen();


-- ============================================================================
-- 管理员入口
-- ============================================================================

-- 建一个码（通用码，或者自己取名的单次码）。返回 code_id。
create or replace function create_redeem_code(
	p_code      text,
	p_max_uses  integer,
	p_actor     text,
	p_diamond   bigint      default 0,
	p_coin      bigint      default 0,
	p_items     text[]      default '{}',
	p_days      integer     default 30,
	p_campaign  text        default null,
	p_starts_at timestamptz default null,
	p_note      text        default null
) returns bigint
language plpgsql
as $$
declare
	v_code  text := glory_normalize_redeem_code(p_code);
	v_start timestamptz := coalesce(p_starts_at, now());
	v_id    bigint;
begin
	if p_actor is null or btrim(p_actor) = '' then
		raise exception '必须填操作人（p_actor）：以后要查「谁建了这个码」';
	end if;
	if p_days is null or p_days < 1 or p_days > 365 then
		raise exception '有效天数要在 1 到 365 之间，现在是 %', p_days;
	end if;
	if v_code !~ '^[A-Z0-9]{4,24}$' then
		raise exception '兑换码只能是 4 到 24 位字母和数字（空格、连字符会自动去掉）：%', p_code;
	end if;
	if p_max_uses is null or p_max_uses < 1 or p_max_uses > 1000000 then
		raise exception '总次数（p_max_uses）必填，1 到 1000000 之间，现在是 %：不许无限，泄漏的码要有自动刹车', p_max_uses;
	end if;
	if exists (select 1 from redeem_codes where code = v_code) then
		raise exception '这个兑换码已经有了：%（撤回过的也不能重用，换一个名字）', v_code;
	end if;

	insert into redeem_codes
		(code, campaign, max_uses, diamond, coin, items, starts_at, expires_at, actor, note)
	values
		(v_code, nullif(btrim(p_campaign), ''), p_max_uses,
		 coalesce(p_diamond, 0), coalesce(p_coin, 0), coalesce(p_items, '{}'),
		 v_start, v_start + make_interval(days => p_days), btrim(p_actor), p_note)
	returning code_id into v_id;
	return v_id;
end;
$$;

comment on function create_redeem_code(text, integer, text, bigint, bigint, text[], integer, text, timestamptz, text) is
	'建一个兑换码。返回 code_id。操作人必填；码自动转大写、去空格和连字符。';


-- 批量生成单次码（每个 max_uses = 1）。返回这一批的码，给运营导出。
--
-- 🔴 **整批强制同一个 campaign**：没给就用批次号。不然运营给 KOL 生成 1000 个码，
--    观众在评论区贴码，一个人能把他抢到的码全填一遍 —— 每个都是单次的，每个都合法。
create or replace function create_redeem_batch(
	p_count     integer,
	p_actor     text,
	p_diamond   bigint      default 0,
	p_coin      bigint      default 0,
	p_items     text[]      default '{}',
	p_days      integer     default 30,
	p_campaign  text        default null,
	p_starts_at timestamptz default null,
	p_note      text        default null
) returns text[]
language plpgsql
as $$
declare
	v_campaign text := nullif(btrim(p_campaign), '');
	v_start    timestamptz := coalesce(p_starts_at, now());
	v_codes    text[] := '{}';
	v_code     text;
	v_tries    int;
	i          int;
begin
	if p_actor is null or btrim(p_actor) = '' then
		raise exception '必须填操作人（p_actor）：以后要查「谁建了这批码」';
	end if;
	if p_count is null or p_count < 1 or p_count > 5000 then
		raise exception '一批要在 1 到 5000 个之间，现在是 %（再多就分几批，每批都有人再看一眼）', p_count;
	end if;
	if p_days is null or p_days < 1 or p_days > 365 then
		raise exception '有效天数要在 1 到 365 之间，现在是 %', p_days;
	end if;
	if v_campaign is null then
		v_campaign := 'batch_' || to_char(now() at time zone 'Asia/Kuala_Lumpur', 'YYYYMMDD_HH24MISS')
			|| '_' || substr(md5(gen_random_uuid()::text), 1, 4);
	end if;

	for i in 1..p_count loop
		v_tries := 0;
		loop
			v_code := glory_new_redeem_code();
			exit when not exists (select 1 from redeem_codes where code = v_code);
			v_tries := v_tries + 1;
			if v_tries > 100 then
				raise exception '兑换码连续冲突 100 次，检查 glory_new_redeem_code()';
			end if;
		end loop;
		insert into redeem_codes
			(code, campaign, max_uses, diamond, coin, items, starts_at, expires_at, actor, note)
		values
			(v_code, v_campaign, 1,
			 coalesce(p_diamond, 0), coalesce(p_coin, 0), coalesce(p_items, '{}'),
			 v_start, v_start + make_interval(days => p_days), btrim(p_actor), p_note);
		v_codes := v_codes || v_code;
	end loop;
	return v_codes;
end;
$$;

comment on function create_redeem_batch(integer, text, bigint, bigint, text[], integer, text, timestamptz, text) is
	'批量生成单次兑换码（每个只能用一次），整批同一个 campaign。返回这一批的码。';


-- 撤回一个码。已经领走的收不回来（那要走退款流程，有据可查）。
create or replace function withdraw_redeem_code(p_code text) returns void
language plpgsql
as $$
begin
	update redeem_codes set withdrawn_at = now()
	 where code = glory_normalize_redeem_code(p_code) and withdrawn_at is null;
	if not found then
		raise exception '没有这个兑换码，或者它已经撤回过了：%', p_code;
	end if;
end;
$$;

comment on function withdraw_redeem_code(text) is
	'撤回一个兑换码。没领的人领不了了；已领走的收不回来。不删行。';


-- 撤回一整批（同一个 campaign 的全部码）。批量码泄漏时一个个撤不现实。返回撤了几个。
create or replace function withdraw_redeem_campaign(p_campaign text) returns integer
language plpgsql
as $$
declare
	v_count integer;
begin
	update redeem_codes set withdrawn_at = now()
	 where campaign = btrim(p_campaign) and withdrawn_at is null;
	get diagnostics v_count = row_count;
	if v_count = 0 then
		raise exception '这个活动下没有还没撤回的兑换码：%', p_campaign;
	end if;
	return v_count;
end;
$$;

comment on function withdraw_redeem_campaign(text) is
	'撤回同一个 campaign 下全部没撤回的兑换码，返回撤了几个。';


-- ============================================================================
-- 后台审批放行 redeem_code（018）
-- ============================================================================
--
-- 和 030 同一个形状：语句完全合法，要到真 insert 那一刻才被约束拒 —— 所以
-- backend/app/schema_check.py 有一条探针专门核它。

alter table admin_requests drop constraint if exists admin_request_kind;
alter table admin_requests add constraint admin_request_kind
	check (kind in ('grant_diamonds', 'grant_coin', 'mail', 'redeem_code'));
