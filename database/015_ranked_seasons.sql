-- 015: 赛季与赛季奖励（排位系统第 6 步）
--
-- 设计见 docs/排位系统设计.md 第九节。配套 backend/app/seasons.py。
--
-- 001-014 一个字都不改 —— 编号只增不改，见 database/README.md。
--
--
-- ## 🔴 赛季长度不写进代码，是表里的一行
--
-- 赛季多长还没拍板（设计文档第十节 10.1）。写死成「4 周」的话，改一次要发一次后端。
--
-- 所以赛季是**管理员插的一行**：`started_at` / `ends_at` 自己填。
-- 第一个赛季多长、第二个要不要长一点，都是插行时的决定，不是代码里的常量。
-- 同 008 公告那张表「管理员在 Supabase 后台直接改行」的路子。
--
--
-- ## 结算整个放在数据库函数里
--
-- `settle_season()` 一个事务做完四件事：认领 → 归档 → 发奖邮件 → 清零。
--
-- 为什么不放在 Python 里：赛季结算是几千行的**集合操作**（insert ... select），
-- 拉进 Python 再一行行写回去，既慢又要自己处理「写到一半挂了」。
-- 放在函数里，事务边界就是天然的原子性。
--
--
-- ## 🔴 幂等靠「认领」那一步
--
-- 函数第一句是 `update ranked_seasons set settled_at = now() where season = ? and settled_at is null`。
-- 认领不到（已经结算过）就直接返回 0，后面一行都不跑。
--
-- 这一条是全文最要紧的：**后台任务会重复跑**（进程重启、两个实例、手动再点一次），
-- 而重复跑一次赛季结算 = 所有人**收到两份奖励**、分数被清两次。

create table ranked_seasons (
  season     int primary key,
  constraint ranked_season_positive check (season >= 1),

  -- 管理员自己填。长度是插行时的决定，不是代码里的常量。
  started_at timestamptz not null,
  ends_at    timestamptz not null,
  constraint ranked_season_order check (ends_at > started_at),

  -- 给玩家看的名字（可空 = 显示「第 N 赛季」）。
  title_zh   text,
  title_en   text,

  -- null = 还没结算。**认领用的就是这一列**，见文件头。
  settled_at timestamptz,
  -- 结算时发出去多少封奖励邮件。0 也是有效结果（那个赛季没人打排位）。
  settled_mails int,

  created_at timestamptz not null default now()
);

comment on table ranked_seasons is '赛季表。长度是管理员插行时决定的，不写进代码';


-- 赛季奖励：按段位一行。没有对应行的段位 = 不发奖（不是发空邮件）。
--
-- 每个赛季一份而不是全局一份：奖励要能逐赛季调，而调完不该影响已经结算过的赛季
-- （历史邮件里写的是什么就是什么）。
create table ranked_season_rewards (
  season  int      not null references ranked_seasons(season) on delete cascade,
  tier    smallint not null,
  constraint season_reward_tier_range check (tier between 0 and 7),

  -- 奖励内容。与 012 的 mails 那三列同形状、同上限 —— 对不上的话结算时才会撞约束，
  -- 而那时候已经是半夜的后台任务了。
  diamond bigint not null default 0,
  coin    bigint not null default 0,
  items   text[] not null default '{}',
  constraint season_reward_diamond_range check (diamond between 0 and 100000),
  constraint season_reward_coin_range    check (coin between 0 and 1000000),
  constraint season_reward_items_shape check (
    cardinality(items) <= 10
    and (cardinality(items) = 0
         or array_to_string(items, ',') ~ '^[a-z0-9_:]{1,64}(,[a-z0-9_:]{1,64})*$')
  ),

  primary key (season, tier)
);

comment on table ranked_season_rewards is '按段位的赛季奖励。没有行的段位不发奖，不是发空邮件';


-- 赛季结束时把 player_ranked 的那一行原样存下来。
--
-- **只追加**。玩家问「我上赛季到底什么段位」时，这是唯一能回答的地方 ——
-- player_ranked 已经被清零了。
create table player_ranked_history (
  season     int  not null references ranked_seasons(season) on delete cascade,
  player_id  uuid not null references players(player_id) on delete cascade,

  score      int not null,
  -- 段位在这里**存下来**了 —— 这是 014 那条「段位不存」的唯一例外。
  --
  -- 理由：014 里不存是因为 score 还在变，存了就有两个真相。归档行的 score **不再变**，
  -- 而「当时的段位」要按**当时的**切片算 —— 以后改段位宽窄时，历史段位不该跟着变。
  tier       smallint not null,
  constraint history_tier_range check (tier between 0 and 7),

  games      int not null,
  wins       int not null,
  settled_at timestamptz not null default now(),

  primary key (season, player_id)
);

comment on table player_ranked_history is '赛季归档。tier 在这里存下来 —— 历史段位不该因为以后改切片而变';

create index player_ranked_history_player_idx on player_ranked_history (player_id, season desc);


-- 结算一个赛季。返回发出去多少封奖励邮件；**已经结算过返回 -1**（不是 0 ——
-- 0 是「结算了但没人打排位」，两件事要分得开）。
--
-- 管理员手动跑：
--     select settle_season(1, 'arvin');
-- 后台任务自动跑：backend/app/seasons.py，actor 填 'auto'
create function settle_season(p_season int, p_actor text)
returns int
language plpgsql
as $$
declare
	v_claimed int;
	v_mails   int := 0;
	v_title   text;
begin
	if p_actor is null or btrim(p_actor) = '' then
		raise exception '必须填操作人（p_actor）：以后要查「这个赛季是谁结算的」';
	end if;

	-- 🔴 认领。认不到 = 已经结算过，一行都不许再跑。
	-- 重复结算 = 所有人收到两份奖励、分数被清两次（见文件头）。
	update ranked_seasons
	   set settled_at = now()
	 where season = p_season and settled_at is null;
	get diagnostics v_claimed = row_count;
	if v_claimed = 0 then
		return -1;
	end if;

	select coalesce(title_zh, '第 ' || p_season || ' 赛季') into v_title
	  from ranked_seasons where season = p_season;

	-- 归档。段位按**当时的**切片算死（见 player_ranked_history.tier 的注释）。
	insert into player_ranked_history (season, player_id, score, tier, games, wins)
	select p_season, r.player_id, r.score, least(r.score / 100, 7), r.games, r.wins
	  from player_ranked r
	 where r.season = p_season
	on conflict (season, player_id) do nothing;

	-- 发奖邮件。**只发有奖励行的段位** —— 没配的段位不发空邮件。
	-- 也只发**打过至少一局**的人：一局没打就收到「赛季奖励」是噪音。
	insert into mails (player_id, title_zh, body_zh, title_en, body_en,
	                   diamond, coin, items, actor, note, expires_at)
	select h.player_id,
	       v_title || ' 奖励',
	       '恭喜你在' || v_title || '达到第 ' || (h.tier + 1) || ' 段，积分 ' || h.score || '。',
	       'Season ' || p_season || ' Rewards',
	       'You finished Season ' || p_season || ' at tier ' || (h.tier + 1)
	         || ' with ' || h.score || ' points.',
	       w.diamond, w.coin, w.items,
	       btrim(p_actor), 'season=' || p_season,
	       now() + interval '30 days'
	  from player_ranked_history h
	  join ranked_season_rewards w on w.season = h.season and w.tier = h.tier
	 where h.season = p_season and h.games > 0;
	get diagnostics v_mails = row_count;

	-- 清零，进下一个赛季。
	--
	-- ⚠️ **不删行、不重建行。** 删了的话第一场排位又要走「没有就建」那条路，
	-- 而 player_credit 是另一张表、不跟着清 —— 信誉分是跨赛季的，那是设计如此。
	update player_ranked
	   set score = 0, games = 0, wins = 0, win_streak = 0,
	       season = p_season + 1, updated_at = now()
	 where season = p_season;

	update ranked_seasons set settled_mails = v_mails where season = p_season;
	return v_mails;
end;
$$;

comment on function settle_season(int, text) is
	'结算一个赛季：归档 + 按段位发奖邮件 + 清零。已结算过返回 -1。重复调用安全';


-- 所有表一律开 RLS 且零 policy（database/README.md 末尾那条硬规则）。
alter table ranked_seasons        enable row level security;
alter table ranked_season_rewards enable row level security;
alter table player_ranked_history enable row level security;
