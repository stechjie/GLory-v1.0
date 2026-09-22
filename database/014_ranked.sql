-- 014: 排位分、段位与信誉分（排位系统第 5 步）
--
-- 设计见 docs/排位系统设计.md 第三、四节。配套 backend/app/ranked.py。
--
-- 001-013 一个字都不改 —— 编号只增不改，见 database/README.md。
--
--
-- ## 🔴 段位不存，它是分数的显示切片
--
-- 段位 = clamp(score / 100, 0, 7)，八段，第 8 段不封顶（分数继续往上涨）。
--
-- **不加 tier 列。** 加了就有两个真相：改段位宽窄时要写数据迁移，而且迁移漏掉
-- 一部分行的话，那些人的段位和分数会**永久对不上、且不报错**。
-- 现在改宽窄只是改 backend/app/ranked.py 里的一个常量，一条玩家数据都不动。
--
--
-- ## 分数从哪来：战报，不是客户端
--
-- 只有 match_records 里记下一局（013，战斗服务器签过章）时才结算。
-- 结算与那条记录在**同一个事务**里，所以 013 的 match_uid 主键顺带保证了
-- 「一局只结算一次」—— 六个人各交一份战报，第二份起整个事务是 no-op。
--
--
-- ## 信誉分：懒惰发放，不跑定时任务
--
-- 「每天 +5」不是一个扫全表的定时任务，而是**读到的时候现算**：
-- 按 last_daily_grant 到今天差几天补几个 +5，封顶 100。
--
-- 好处很实在：几万个玩家里绝大多数当天没上线，给他们跑一遍加分是纯浪费；
-- 而且定时任务漏跑一天，补起来要另写脚本。懒惰发放没有这个问题 ——
-- 它天然自愈，一个月没上线的人下次登录一次性补到 100。
--
--
-- ## 惩罚计数：滚动 7 天，靠事件表数出来
--
-- 「7 天内第 N 次」是 credit_events 上的一次 count，不是一个计数器列。
--
-- 用计数器的话就要回答「什么时候清零」，而那个问题两种直觉答案都是错的
-- （docs/排位系统设计.md 第四节算过账）。事件表天然滚动、天然衰减，
-- 而且出了争议能查「他到底哪几次跑了」。

create table player_ranked (
  player_id uuid primary key references players(player_id) on delete cascade,

  -- 赛季编号。赛季长度还没拍板（第 6 步），现在所有人都在第 1 赛季。
  -- 有了这一列，赛季重置就是「插新一行」而不是「改结构」。
  season   int not null default 1,

  -- 🔴 **段位是这个数除以 100，不另存。** 见文件头。
  -- 不封顶：第 8 段（>=700）之后继续涨，靠分数排行榜区分高手。
  score    int not null default 0,
  constraint ranked_score_floor check (score >= 0),

  games    int not null default 0,
  wins     int not null default 0,

  -- 连胜。3 连胜起每局加成 +20%、上限 +60%（第三节）。
  -- 输一局归零；**不记连败** —— 设计里没有连败惩罚，存一个没人读的数是留给
  -- 下一个人的地雷（docs/排位系统设计.md 之外的规矩，见项目里「只要没用就删除」）。
  win_streak int not null default 0,
  constraint ranked_streak_floor check (win_streak >= 0),

  updated_at timestamptz not null default now()
);

comment on table player_ranked is '排位分。段位 = score/100，不另存，见 backend/app/ranked.py';

-- 排行榜：第 8 段不封顶，高手之间只能靠分数排。
create index player_ranked_leaderboard_idx on player_ranked (season, score desc);


create table player_credit (
  player_id uuid primary key references players(player_id) on delete cascade,

  -- 起始 100。<85 警告，<70 禁排位，<60 禁普通匹配（第四节）。
  score int not null default 100,
  constraint credit_score_range check (score between 0 and 100),

  -- 禁排位到什么时候。null = 没禁。
  --
  -- ⚠️ 这一列**只管禁赛**，不管「信誉分太低不让排」—— 后者是拿 score 和阈值比出来的，
  -- 没有到期时间。两件事混在一列里的话，禁赛到期会把信誉分那条限制一起解除。
  banned_until timestamptz,

  -- 「每天 +5」发到哪一天了。懒惰发放的游标，见文件头。
  -- null = 从没发过（新玩家本来就是 100，不需要补）。
  last_daily_grant date,

  updated_at timestamptz not null default now()
);

comment on table player_credit is '信誉分。每天 +5 是读到时现算的，不跑定时任务';


-- 信誉分的每一次增减。**只追加，不删不改**，同 009 的钱包流水。
--
-- 两个用途：
--   1. 「7 天内第 N 次」的计数（滚动窗口，见文件头）
--   2. 出了争议能查「他到底哪几次跑了、什么时候」
create table credit_events (
  id        bigint generated always as identity primary key,
  player_id uuid not null references players(player_id) on delete cascade,

  -- 'abandon'    对局结束时人不在（跑路，第四节的判定线）
  -- 'no_accept'  匹配确认框没点（第 5b 步接）
  -- 'match'      正常打完一局 +2
  -- 'daily'      每天 +5
  kind      text not null,
  constraint credit_event_kind_known
    check (kind in ('abandon', 'no_accept', 'match', 'daily')),

  -- 正数是加，负数是扣。
  delta     int not null,

  -- 关联的对局（abandon / match 有，daily / no_accept 没有）。
  -- 不加外键：match_records 的行以后可能因为清理而不在，而这条流水要一直留着。
  match_uid text,

  created_at timestamptz not null default now()
);

comment on table credit_events is '信誉分流水。只追加 —— 「7 天内第 N 次」是在这张表上数出来的';

-- 滚动窗口的计数查询：where player_id = ? and kind = ? and created_at > now() - 7 days
create index credit_events_window_idx on credit_events (player_id, kind, created_at desc);


-- 所有表一律开 RLS 且零 policy（database/README.md 末尾那条硬规则）。
alter table player_ranked  enable row level security;
alter table player_credit  enable row level security;
alter table credit_events  enable row level security;
