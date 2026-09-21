-- 013: 对局历史（排位系统第 1 步）
--
-- 设计见 docs/排位系统设计.md 第七、八节。配套 backend/app/battle_report.py。
--
-- 001-012 一个字都不改 —— 编号只增不改，见 database/README.md。
--
--
-- ## 这一步只做历史，不做分
--
-- 排位的分、段位、信誉分都还没有表。这一张先把「一局打完了，谁在里面，最后是什么样」
-- 记下来 —— 它能独立上线、能被真实对局压测，而且不依赖任何还没拍板的东西。
-- 排位分以后是另一个编号，读这张表。
--
--
-- ## 🔴 数据是战斗服务器签过章的，不是客户端说的
--
-- 战斗服务器用自己的私钥签一份「战报」，客户端只负责转交（它连看都不用看）。
-- 账号服务器验章通过才写这里。验不过就整份丢掉，一个字都不写。
--
-- 这条和「最近一起玩过」（006_room_visits.sql）正好相反 —— 那张表是客户端自报的，
-- 靠「两边都得报、时间窗重叠」这个结构防伪造。那套撑得住交友，撑不住战绩：
-- 战绩要用来发排位分，自报的分等于没有分。
--
--
-- ## 一局只存一行，谁交的都一样
--
-- 一份战报里有全场六个座位的结果，所以**六个人里只要有一个交上来就够**。
-- match_uid 是主键 = 天然幂等：第二个人交上来是 on conflict do nothing，不报错、不重复。
--
-- 赢的那三个有动力交，输的不交也没用。
--
--
-- ## 🔴 金币不是权威的，列里要说清楚
--
-- 写这张表的时候 ServerFlags 是：
--   carrot_economy_enabled        = true   萝卜是服务端权威的
--   economy_ledger_enabled        = true   金币账本在记，但只做影子比对
--   economy_ledger_authoritative  = false  **战后结算的起点金币仍是客户端自报的**
--
-- ⚠️ 影子期里**没有**一份「服务端自己算的金币」可以拿来记。
-- NetworkService 那边是 `_room_prep(room, slot)["gold"] = gold_after`，
-- 而 `gold_after` 的种子是客户端自报的 `snap.gold` —— 账本每回合被覆盖一次。
-- 所以这里记的就是结算用的那个数，**它的可信度等于客户端**。
--
-- 每一行都带 gold_authoritative 标明当时的口径（= ServerFlags 的
-- economy_ledger_authoritative）。以后翻了那个开关，老记录能一眼分出来
-- 是哪个口径 —— 不回填、不假装。萝卜那一列是真的服务端权威。
--
--
-- ## 历史不删
--
-- 同 009 「流水永不裁剪」那条。玩家删号时 player_id 置空（见下面的外键），
-- 行留着 —— 同一局里其他五个人的历史不能因为一个人删号就缺一块。

create table match_records (
  -- 战斗服务器生成的 32 位十六进制（Crypto.generate_random_bytes(16)）。
  -- **不是** room_id —— 房间号会被回收重用，六位数字早晚撞。
  -- 它同时是去重键：同一份战报交几次都只有一行。
  match_uid    text primary key,
  constraint match_uid_format check (match_uid ~ '^[0-9a-f]{32}$'),

  -- 'custom' = 自定义房间（现在只有这个）。以后是 'ranked' / 'casual'。
  -- 用 text 不用 enum：加一个模式不该是一次迁移。
  mode         text   not null,
  constraint match_mode_known check (mode in ('custom', 'casual', 'ranked')),

  -- 当时的协议号与服务器代数。对不上的老数据以后要能认出来。
  protocol     int    not null,
  server_epoch int    not null,
  room_id      bigint not null,

  started_at   timestamptz not null,
  ended_at     timestamptz not null,
  constraint match_time_order check (ended_at >= started_at),

  -- 打完到第几回合。21 = 打满（data/rounds/round_schedule.json 的 final_round）。
  rounds       int    not null,
  constraint match_rounds_range check (rounds between 1 and 100),

  -- 整局归属。口径是战斗服务器的 TeamOutcome.run_outcome()，
  -- 客户端字幕、服务端结算用的是同一个函数 —— 三处不能各判各的。
  outcome      text   not null,
  constraint match_outcome_known check (outcome in ('team_a', 'team_b', 'draw')),

  -- 两队最终法阵 HP。起始 50（GameState.START_FORMATION_HP）。
  team_a_hp    int    not null,
  team_b_hp    int    not null,

  -- 见上面「金币不是权威的」。写进行里，不是写进文档里 ——
  -- 文档会过期，列不会。
  gold_authoritative   boolean not null,
  carrot_authoritative boolean not null,

  reported_at  timestamptz not null default now()
);

-- 🔴 这张表**刻意不存「谁交的战报」**。
--
-- 第一版写过一个 reported_by uuid references players。它是死路：
--   * 按 on delete cascade（test_profile 那条门禁要求的）—— 交战报的人注销账号，
--     **整局记录连同另外五个人的座位一起没了**；
--   * 按 on delete set null —— 过不了那条门禁，而门禁是对的：
--     一条不 cascade 的外键靠人记住「这个是例外」，早晚被漏掉。
--
-- 而它本来就只是排查用（「这局是谁报的」），没有任何查询读它 ——
-- 战报的可信度**全部来自签名**，和谁交上来的无关。所以它归日志，不归表：
-- backend/app/routes/battle_report.py 记一行 `记下一局 ... by=<player_id>`。

comment on table match_records is '一局一行。数据来自战斗服务器签章的战报，见 docs/排位系统设计.md 第七节';

-- 「最近的对局」按时间倒序翻页。
create index match_records_ended_at_idx on match_records (ended_at desc);


create table match_seats (
  match_uid  text     not null references match_records(match_uid) on delete cascade,

  -- 0..5。slot < 3 是 A 队，slot >= 3 是 B 队（GameConstants.team_of_slot）。
  -- team 列是冗余的，但查询里到处要用，省得每次再算一遍。
  slot       smallint not null,
  team       smallint not null,
  constraint match_seat_slot_range check (slot between 0 and 5),
  constraint match_seat_team_range check (team between 0 and 1),
  constraint match_seat_team_matches_slot check (team = (case when slot < 3 then 0 else 1 end)),

  -- null = 这个座位不是真人（房主加的 AI，或者入座时没带名片）。
  --
  -- on delete cascade 是 test_profile.test_every_table_referencing_players_cascades
  -- 要求的，而且对这一列是对的：注销账号就该把他打过的局从他名下抹掉。
  -- 代价是同局其他人的历史会少一格（六个座位里显示五个）—— 接受，
  -- 「注销 = 数据删掉」比「历史永远完整」优先。
  --
  -- ⚠️ 六个人全注销时 match_records 会剩一行没有任何座位的孤儿。
  -- 它只有几百字节，暂时不清理；真要清是 backend/app/maintenance.py 的活。
  player_id  uuid references players(player_id) on delete cascade,

  -- 🔴 排位的跑路判定线就是 online_at_end —— 不是 was_ai。
  --
  -- 座位断线 20 秒（RESERVE_GRACE_SEC）就转 AI，但转了之后玩家**还能回来**
  -- （NetworkService._resume_seat）。手机切后台、过隧道都超过 20 秒，
  -- 拿 was_ai 当跑路线会误伤一大片正常玩家。
  --
  -- ai_rounds 先只记不判：等有真实数据再决定要不要按「AI 代打了多少回合」分级。
  was_ai        boolean not null,
  online_at_end boolean not null,
  ai_rounds     int     not null default 0,

  -- 最终金币 / 剩余萝卜 / 花掉的萝卜。金币的口径见 match_records.gold_authoritative。
  gold          int not null,
  carrots       int not null,
  carrots_spent int not null,

  -- 最终棋盘与佣兵位。每条是 {slot, id, star, is_mercenary}。
  --
  -- **刻意不存 uid 和 race_relations**：uid 是一局之内的运行时编号，出了这一局没有意义；
  -- race_relations 从单位 id 就能查出来，存进来只是让每一行大一倍。
  board      jsonb not null default '[]'::jsonb,

  -- 这一局拿到的宝藏 id。
  treasures  jsonb not null default '[]'::jsonb,

  primary key (match_uid, slot)
);

comment on table match_seats is '一局六行。board 是最终棋盘，不是每回合的过程 —— 过程走不了这条路，见 docs/排位系统设计.md 第八节';

-- 「我的对局历史」：按玩家找他打过的局，再按时间倒序。
create index match_seats_player_idx on match_seats (player_id) where player_id is not null;


-- 所有表一律开 RLS 且零 policy（database/README.md 末尾那条硬规则）。
-- Godot 不直连 Supabase，一切经过 FastAPI（secret key 绕过 RLS）。
alter table match_records enable row level security;
alter table match_seats   enable row level security;
