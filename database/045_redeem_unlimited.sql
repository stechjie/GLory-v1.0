-- 045: 兑换码可以不限人数
--
-- 2026-11-04 用户定：通用码「最多几人能领」可以留空 = 不限，靠截止时间收口。
-- 配套 backend/app/redeem.py（_TAKE）、backend/app/admin.py（建码审批）。
--
-- 为什么推翻 044 的「必填、不许无限」：
--   · 通用码本来就是要公开贴出去的，谈不上「泄漏」；
--   · 人数上限挡不住小号（匿名注册，一个号领一次），只会让晚来的真玩家看到「已领完」；
--   · 真正的刹车一直是截止时间（必填，最长 365 天）和撤回（一个人就能做）。
-- 批量单次码不受影响：每个仍是 max_uses = 1。
--
-- 🔴 部署：测试服已经跑过 044，只跑这一个；正式服按 044 → 045 的顺序跑。
--    都要在更新账号服务器之前跑 —— 没跑的话，批准一个不限人数的码会报错（没建出来，不会发错钱）。
--
-- 可重复执行。

alter table redeem_codes alter column max_uses drop not null;

alter table redeem_codes drop constraint if exists redeem_max_uses_range;
alter table redeem_codes add constraint redeem_max_uses_range
	check (max_uses is null or max_uses between 1 and 1000000);

-- 044 那条在 max_uses 为 null 时结果是 null，check 本来就会放行；重写一遍只是让意思写在明处。
alter table redeem_codes drop constraint if exists redeem_used_count_range;
alter table redeem_codes add constraint redeem_used_count_range
	check (used_count >= 0 and (max_uses is null or used_count <= max_uses));

comment on column redeem_codes.max_uses is
	'总共能被领多少次。null = 不限人数（只有通用码会这样，截止时间收口）。单次码是 1。';


-- 签名不变，只放开 p_max_uses 可以传 null。
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
	if p_max_uses is not null and (p_max_uses < 1 or p_max_uses > 1000000) then
		raise exception '总次数（p_max_uses）要么不填（不限人数），要么在 1 到 1000000 之间，现在是 %', p_max_uses;
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
	'建一个兑换码。返回 code_id。p_max_uses 传 null = 不限人数。操作人必填；码自动转大写、去空格和连字符。';
