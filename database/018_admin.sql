-- 018: 网页运营后台
--
-- 设计见 docs/运营后台设计.md。配套 backend/app/admin_auth.py、admin.py、routes/admin.py、
-- backend/admin_web/。
--
-- 001-017 一个字都不改 —— 编号只增不改，见 database/README.md。
--
--
-- ## 后台只是给已有的入口套一层网页
--
-- 发钻石走 009 的 grant_diamonds、发邮件走 012 的 send_mail / send_mail_all / withdraw_mail、
-- 封号走 016 的 ban_player / unban_player、公告写 008 那张表 —— 规则都在那些函数里，
-- 后台不另写一套。这里只加三样东西：谁能进后台、发钱的审批、操作记录。
--
--
-- ## 2026-09-24 拍板
--
--   · 登录：Supabase 账号（邮箱 + 密码）+ 手机验证器 6 位码。不用 Google。
--   · 审批：**只有发钱要第二个人批准**（发钻石 / 黄金、带附件的邮件）。钱发出去被花掉就收不回；
--     封号、公告随时能撤，不用批，但都记操作记录。
--   · 所以**至少要两个管理员**，一个人的话发钱的申请永远批不了。


-- ============================================================================
-- 谁能进后台
-- ============================================================================
--
-- 加管理员两步：
--   1. Supabase Dashboard 左边栏 Authentication（锁头图标）→ Users → 右上角 Add user →
--      Create new user，填邮箱和密码，勾 Auto Confirm User。
--   2. SQL Editor 里一行（用第 1 步的邮箱，不用复制 UID）：
--        select add_admin('arvin@example.com', 'arvin');
--      第二个参数是以后所有操作记录、钱包流水 actor 列里写的名字。
-- 第一次登录后台时会要求绑定手机验证器（Google Authenticator / Microsoft Authenticator 都行）。
--
-- 停用：update admin_users set active = false where name = 'arvin';  —— 下一个请求起就进不去了。
-- **不要删行**：操作记录里写的是 name，删了就查不到那是谁。

create table admin_users (
  -- Supabase Auth 的用户 id。**和玩家不是同一批人**：玩家是匿名用户，走 player_identities。
  auth_uid   uuid primary key,
  name       text not null,
  constraint admin_name_shape check (name ~ '^[A-Za-z0-9_.-]{2,32}$'),
  constraint admin_name_unique unique (name),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

alter table admin_users enable row level security;

comment on table admin_users is '能进网页后台的人。name 写进所有操作记录。停用改 active，不删行。';


-- 按邮箱加管理员（上面第 2 步）。邮箱查 Supabase Auth 的 auth.users 换成 UID —— 名单里存的还是 UID，
-- 邮箱在 Supabase 里改了也不影响。同一个人再加一次 = 重新启用（被停用过的），名字按这次的。
create function add_admin(p_email text, p_name text) returns uuid
language plpgsql
as $$
declare
	v_uid uuid;
begin
	select id into v_uid from auth.users where lower(email) = lower(btrim(p_email));
	if v_uid is null then
		raise exception '没有这个邮箱的用户：%（先在 Authentication → Users → Add user 建好）', p_email;
	end if;
	insert into admin_users (auth_uid, name) values (v_uid, btrim(p_name))
	on conflict (auth_uid) do update set name = excluded.name, active = true;
	return v_uid;
end;
$$;

comment on function add_admin(text, text) is
	'按邮箱把 Supabase Auth 里的用户加进后台管理员名单。再加一次 = 重新启用。';


-- ============================================================================
-- 发钱的审批
-- ============================================================================
--
-- 申请人填好 → 另一个管理员点「批准」→ **当场执行**（同一个事务：改状态 + 发钱 + 记操作记录）。
-- 没有「批了但还没执行」的中间态 —— 少一个状态就少一类「批了却没发 / 发了两次」。
--
-- 🔴 两道防重：
--   · 同一个人连点两次「提交」：页面每次生成一个 request_key，(requested_by, request_key) 唯一；
--   · 两个人同时点「批准」：`update … where status = 'pending'`，只有一个能改到。

create table admin_requests (
  request_id   bigint generated always as identity primary key,

  -- grant_diamonds 发钻石 / grant_coin 发黄金 / mail 带附件的邮件
  kind         text not null,
  constraint admin_request_kind check (kind in ('grant_diamonds', 'grant_coin', 'mail')),

  -- 收的人。全服邮件为空。**不加外键**：这是记录，不跟着别的表变。
  player_id    uuid,

  -- 执行时要的全部参数。**批的就是这一份**：申请之后不能改，要改就撤回重新申请。
  payload      jsonb not null,

  -- 给审批人看的一句人话（例如「给 ABCD2345 发 500 钻石」）。
  summary      text not null,
  constraint admin_request_summary_length check (char_length(summary) between 1 and 300),

  reason       text not null,
  constraint admin_request_reason_length check (char_length(btrim(reason)) between 1 and 200),

  request_key  uuid not null,
  requested_by text not null,
  requested_at timestamptz not null default now(),
  constraint admin_request_key_unique unique (requested_by, request_key),

  -- pending 等批 / done 已批并执行 / rejected 被拒 / cancelled 申请人撤回 / failed 批了但执行失败
  status       text not null default 'pending',
  constraint admin_request_status check (status in ('pending', 'done', 'rejected', 'cancelled', 'failed')),

  decided_by   text,
  decided_at   timestamptz,
  decision_note text,
  constraint admin_request_decision_note_length check (decision_note is null or char_length(decision_note) <= 200),

  -- 🔴 自己不能批自己。撤回例外（那本来就是申请人自己的事）。
  constraint admin_request_no_self_approval
    check (status in ('pending', 'cancelled') or decided_by is distinct from requested_by),

  -- 执行结果（邮件编号、发完后的余额）或失败原因。
  result       jsonb
);

create index admin_requests_pending on admin_requests (request_id) where status = 'pending';
create index admin_requests_recent on admin_requests (request_id desc);

alter table admin_requests enable row level security;

comment on table admin_requests is '发钱的审批。批准即执行；自己不能批自己；申请后内容不能改。';


-- ============================================================================
-- 操作记录
-- ============================================================================
--
-- 后台里每一次改东西的操作（成功和失败都记）。**只追加**：下面的触发器拒绝改和删。
-- 真要清（例如测试库），只能由数据库管理员先 drop 触发器 —— 那一步本身就是明摆着的动作。

create table admin_audit (
  audit_id   bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  admin_name text not null,
  -- 例如 ban / unban / mail.send / request.create / request.approve / announcement.save
  action     text not null,
  constraint admin_audit_action_length check (char_length(action) between 1 and 64),
  -- 相关的玩家。不加外键，理由同 admin_requests.player_id。
  player_id  uuid,
  detail     jsonb not null default '{}'::jsonb,
  ok         boolean not null
);

create index admin_audit_by_player on admin_audit (player_id, audit_id desc) where player_id is not null;

alter table admin_audit enable row level security;

create function admin_audit_append_only() returns trigger
language plpgsql
as $$
begin
	raise exception '操作记录只能追加，不能修改或删除';
end;
$$;

create trigger admin_audit_no_update_delete
	before update or delete on admin_audit
	for each row execute function admin_audit_append_only();

create trigger admin_audit_no_truncate
	before truncate on admin_audit
	for each statement execute function admin_audit_append_only();

comment on table admin_audit is '后台操作记录。只追加（触发器拒绝改删）。';


-- ============================================================================
-- 手工发黄金
-- ============================================================================
--
-- 同 009 的 grant_diamonds：一次调用同时改余额与流水，强制填操作人。
-- 黄金第一版还没有常规产出口（009 的注释），这里只是给运营补偿一个入口。

create function grant_coin(
	p_player uuid,
	p_amount bigint,
	p_note   text,
	p_actor  text
) returns bigint
language plpgsql
as $$
declare
	v_after bigint;
begin
	if p_amount is null or p_amount <= 0 then
		raise exception '发放数量必须是正数；回收请走退款流程，不要在这里发负数';
	end if;
	if p_actor is null or btrim(p_actor) = '' then
		raise exception '必须填操作人：以后要查「谁给这个号发了钱」';
	end if;
	if not exists (select 1 from players where player_id = p_player) then
		raise exception '没有这个玩家：%', p_player;
	end if;

	insert into player_wallets (player_id) values (p_player) on conflict do nothing;

	update player_wallets
	   set coin = coin + p_amount, updated_at = now()
	 where player_id = p_player
	returning coin into v_after;

	insert into wallet_ledger
		(player_id, currency, delta, balance_after, source, actor, note)
	values
		(p_player, 'coin', p_amount, v_after, 'grant', p_actor, p_note);

	return v_after;
end;
$$;

comment on function grant_coin(uuid, bigint, text, text) is
	'手工发放黄金。一次调用同时改余额与流水，强制填操作人。source 记 grant。';
