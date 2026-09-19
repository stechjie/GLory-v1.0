-- 009: 账号钱包与流水
--
-- ⚠️ **这里的钱和局内金币完全无关。**
-- 局内金币是 GameState.gold / room.slot_gold，一局一清，属于战斗服务器
-- （docs/金币系统.md）。这张表是账号级持久货币，两本账不相通。
--
-- 代码里刻意不用同一个词：局内叫 gold，这里叫 coin。
-- 混了不会报错，表现是「钱对不上」—— 那是最难查的一类。
-- 设计见 docs/商城系统设计.md 第三节。

create table player_wallets (
  player_id    uuid primary key references players(player_id) on delete cascade,

  -- 钻石**分成付费与赠送两列**（2026-09-16 拍板）。
  --
  -- 「当前余额里有多少是花钱买的」是退款与对账要的数。它其实也能从 wallet_ledger
  -- 重放算出来（每笔入账带 source、花钱规则固定），所以这两列严格说是那个结果的
  -- **缓存**。选择缓存它的理由：退款时要的是一个能直接读的数，而不是一次全量重放；
  -- 而且这样「分账对不对」不依赖流水有没有被人动过。
  --
  -- ⚠️ 代价是多一条不变量：这两列的和必须始终等于流水重放的结果。
  -- 所有改钱的路径都只走 backend/app/shop.py 的 _apply()，就是为了守住它。
  --
  -- 对客户端**合并成一个数**下发（见 backend/app/routes/shop.py）：
  -- 游戏里从来只显示一个总数，分账纯粹是后台账目。
  diamond_paid bigint not null default 0,
  diamond_free bigint not null default 0,

  -- 黄金。**第一版没有任何产出口，恒为 0** —— 这是刻意的，不是漏做。
  -- 怎么赚（对局奖励？活动？）等想清楚再定，那时只改 data/shop.json
  -- 与客户端，不动这张表。
  coin         bigint not null default 0,

  updated_at   timestamptz not null default now(),

  -- 余额绝不能是负数。应用层已经查过一次，这里是最后一道。
  --
  -- 不是重复：应用层那次查与随后的写之间，同一个玩家的第二笔请求可能挤进来
  -- （两台设备、或者客户端重试）。扣款走 `select … for update` 把行锁住，
  -- 这条约束是锁没用对时的兜底 —— 宁可让那笔写失败回滚，也不能出现负余额。
  constraint wallet_non_negative
    check (diamond_paid >= 0 and diamond_free >= 0 and coin >= 0)
);

-- 钱包行是**惰性建的**：第一次要改钱时 insert … on conflict do nothing。
-- 不在注册时建，理由同 players 表不自动补建玩家 —— 少一条可以绕开的入口，
-- 而且绝大多数玩家在上商城之前根本不需要这一行。
-- 读钱包时没有行 = 余额全 0，不是错误。

alter table player_wallets enable row level security;

comment on table  player_wallets              is '账号级持久钱包。一行一个玩家。与局内金币无关。';
comment on column player_wallets.diamond_paid is '充值得来的钻石。退款与对账口径靠它。对客户端合并下发。';
comment on column player_wallets.diamond_free is '活动 / 补偿 / 手工发放的钻石。扣款时先扣这一列。';
comment on column player_wallets.coin         is '黄金。第一版无产出口，恒为 0。';


-- ============================================================================
-- 流水
-- ============================================================================
--
-- **只追加，永不 update / delete。** 对账、客服、退款、以及「这笔钱到底哪来的」
-- 全靠它。任何改余额的路径都必须同时写一条，且在同一个事务里 ——
-- 余额是结果，流水是过程，只有结果没有过程的账查不动。
--
-- 🔴 **这张表永远不许裁剪，一行都不许删。**
--
-- 这条比上面那句更硬，而且这个仓库有踩进去的先例：app/maintenance.py 会定期清
-- 过期私聊会话与好友请求日志，chat_messages 更是「每对好友只留最近 200 条」。
-- 谁照着那个模式给钱包流水也加一条清理，当天什么都不会发生 ——
-- 坏掉的是**以后**：
--
--   · 「这个号的钻石哪来的」再也答不出来，而这正是客服最常被问的一件事；
--   · player_wallets 那两列本质是这张表的缓存，对不上时没有东西可以拿来核对；
--   · 退款要回溯到具体哪一笔充值，裁掉就断了。
--
-- 要控体积就归档到别处（冷表 / 对象存储），不是删。
-- backend/tests/test_shop.py 有一条断言钉着 maintenance.py 不许出现 wallet_ledger。

create table wallet_ledger (
  id            bigint generated always as identity primary key,
  player_id     uuid not null references players(player_id) on delete cascade,

  -- 与 player_wallets 的列名一一对应。约束在这里，是因为写错列名不会报错 ——
  -- 只会让这笔流水永远对不上任何一列余额，而且要到对账时才发现。
  currency      text not null,
  constraint wallet_ledger_currency
    check (currency in ('diamond_paid', 'diamond_free', 'coin')),

  delta         bigint not null,   -- 正入账、负出账
  constraint wallet_ledger_delta_nonzero check (delta <> 0),

  -- 写这一笔之后该列的余额。冗余，但对账时不用把整条流水累加一遍，
  -- 而且能一眼看出「从哪一笔开始对不上」。
  balance_after bigint not null,

  -- 这笔钱从哪来 / 到哪去：shop / iap / grant / refund / starter_pick / match_reward …
  --
  -- **刻意不加 check 约束。** 加了以后运营手工发一种新名目的补偿就要先跑迁移，
  -- 而那通常发生在出事故的当天。合法值的唯一真相在 backend/app/shop.py 的
  -- SOURCES，由应用层校验；数据库这层只保证非空。
  source        text not null,
  constraint wallet_ledger_source_length check (char_length(source) between 1 and 32),

  order_id      uuid,   -- 关联订单。手工发放没有订单，可空。

  -- 🔴 手工发放时**必须**填是谁操作的，不许留空。
  --
  -- 公告那套拍的是「管理员直接改 Supabase 后台」，商城延续同一条 ——
  -- 但商城改的是钱。没有这一列，「谁给这个号发了 10000 钻」永远查不出来。
  -- 约束只能管到格式，「不许留空」靠 backend/app/shop.py 与流程纪律。
  actor         text,
  constraint wallet_ledger_actor_length check (actor is null or char_length(actor) between 1 and 64),

  note          text,
  constraint wallet_ledger_note_length check (note is null or char_length(note) <= 200),

  created_at    timestamptz not null default now()
);

-- 客服查一个玩家的流水（倒序翻页）走它。
create index wallet_ledger_by_player on wallet_ledger (player_id, id desc);

alter table wallet_ledger enable row level security;

comment on table  wallet_ledger        is '钱包流水。只追加，永不改。任何改余额的路径都必须在同一事务里写一条。';
comment on column wallet_ledger.source is '来源名目。合法值在 backend/app/shop.py 的 SOURCES，刻意不在数据库加 check。';
comment on column wallet_ledger.actor  is '手工发放的操作人。自动路径为空，手工路径不许为空。';


-- ============================================================================
-- 手工发放
-- ============================================================================
--
-- 拍板是「管理员直接改 Supabase 后台」，没有正式后台（docs/商城系统设计.md 第一节）。
-- 但**手改两条语句迟早会漏掉流水那条** —— 改完余额、忘了 insert，
-- 于是「这个号的钻石哪来的」永远查不出来，而且当时毫无症状。
--
-- 所以手工路径也只给一个入口：一次调用，原子，忘不掉流水，且强制填操作人。
--
--     select grant_diamonds('52c7027a-…'::uuid, 500, '补偿 9/20 掉单', 'arvin');
--
-- 发的是 **diamond_free**（赠送），永远不是 diamond_paid —— 手工发的钱不是玩家付的，
-- 混进付费列就把退款口径弄脏了，而那一列的全部意义就是「他到底花过多少钱」。
-- 流水的 source 同理记 'grant'，不许图省事记成 'iap'。

create function grant_diamonds(
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
	-- 负数不从这里走。回收要走退款流程（有订单可查），
	-- 而不是偷偷把余额改小 —— 后者玩家会当成扣错钱来投诉，客服无从解释。
	if p_amount is null or p_amount <= 0 then
		raise exception '发放数量必须是正数；回收请走退款流程，不要在这里发负数';
	end if;
	if p_actor is null or btrim(p_actor) = '' then
		raise exception '必须填操作人：以后要查「谁给这个号发了钱」';
	end if;
	-- 粘错 uuid 是手工操作最常见的失误。不先判的话，报出来的是钱包表的
	-- 外键违例 —— 那句话不会告诉运维「你贴的这个号不存在」。
	if not exists (select 1 from players where player_id = p_player) then
		raise exception '没有这个玩家：%', p_player;
	end if;

	insert into player_wallets (player_id) values (p_player) on conflict do nothing;

	-- 走到这里钱包行一定存在（上一句保证），所以 v_after 不会是 null。
	update player_wallets
	   set diamond_free = diamond_free + p_amount, updated_at = now()
	 where player_id = p_player
	returning diamond_free into v_after;

	insert into wallet_ledger
		(player_id, currency, delta, balance_after, source, actor, note)
	values
		(p_player, 'diamond_free', p_amount, v_after, 'grant', p_actor, p_note);

	return v_after;
end;
$$;

comment on function grant_diamonds(uuid, bigint, text, text) is
	'手工发放钻石。一次调用同时改余额与流水，强制填操作人。只进 diamond_free，source 记 grant。';
