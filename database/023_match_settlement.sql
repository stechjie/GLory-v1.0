-- 023: 对局历史的「详细战况」（2026-09-29）
--
-- 配套 backend/app/battle_report.py、scripts/multiplayer/BattleReport.gd、
-- scenes/menu/MatchHistoryPanel.gd。设计见 docs/排位系统设计.md 第八节「详细战况」。
--
-- 001–021 一个字都不改 —— 编号只增不改，见 database/README.md。（022 已作废，编号跳过。）
--
-- 只加一列，🟢。
--
-- ## 存的是什么
--
-- 打完那一刻给结算面板的那份数据（scripts/multiplayer/FinalSettlementData.gd），战斗服务器签进战报：
--   seats  [{stones: {sky, land, ren}, total_gold}] × 6   升级石、获得总金币
--   allies [A 队, B 队]                                    两边法阵守护的名字
--   stats  [{own, slot, id, name, star, merc, stack, dmg, taken, heal}]
--          最后一战的逐棋子统计（短键，含义见 BattleReport._clean_stats）
--
-- 棋子、佣兵、宝藏不在这里 —— match_seats 已经有了（board / treasures），不存两份。
-- **玩家名字也不在这里**：历史接口按 player_id 取**现在**的名字（改过名显示新名字）。
--
-- ## null = 这个版本之前打的局
--
-- 旧战斗服务器签的战报没有这几项，照收，这一列留空；客户端显示「没有详细战况」。
-- 不回填 —— 旧局本来就没有这份数据。

alter table match_records add column settlement jsonb;

comment on column match_records.settlement is
  '详细战况（结算面板那份：升级石、总金币、法阵守护、最后一战逐棋子统计）。null = 023 之前打的局。';
