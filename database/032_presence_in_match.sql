-- 032: 在线状态加「在对局中」标记（player_presence.in_match）
--
-- 配套：backend/app/presence.py（心跳写入）、backend/app/friends.py（好友列表带出来）、
-- backend/app/routes/presence.py（PUT /v1/me/presence 的 body 字段）、
-- backend/app/routes/friends.py（FriendItem），以及客户端 AccountManager 的上报与解析。
--
-- ## 为什么这次要把它放进数据库（2026-10-11 用户拍板，**推翻 2026-09-29 的决定**）
--
-- 9.29 撤掉了 022（player_presence.room_started），理由写得很清楚：房间开没开局由
-- 战斗服务器在加入时判，不进账号服务器。**那一条至今仍然成立** —— 「加入房间时能不能
-- 进」的拦截还在战斗服务器上（ACTIVE_MATCH_HINT），没有搬过来。
--
-- 这次加 in_match 解决的是**另一个**问题：好友列表要显示「他正在对局中」，
-- 于是邀请按钮要变灰、列表要按「可邀请 → 对局中 → 离线」分档（10.11 bug 第 3/9 条）。
-- 而这个信息只有**玩家自己的客户端**知道（它就在那一局里）：
-- 房间还没开局时好友也在同一个 room_id 上，单看 room_id 分不出「在大厅等」和「已开打」。
--
-- 所以这是一个**展示用的自报字段**，与 room_id 同一个信任级别：
-- 谎报只能让自己的好友看到一个错的状态，拿不到任何东西。
-- ⚠️ 同 presence 那条边界：战绩、排行、奖励一律不能建在这张表上。
--
-- ## 🔴 部署：跑完这个文件**必须**重启后端
--
-- 与 030 一样两步缺一不可：① 在 Supabase SQL Editor 跑本文件 ② 重启账号服务器。
-- 只做 ② 不做 ① 的话，新代码往一张没有该列的表中写 in_match，心跳会直接 500 ——
-- 而心跳 500 的症状是**所有人**一起显示离线。
--
-- 幂等：add column if not exists，手工跑两遍也安全（🟢 加一列，不锁表）。

alter table player_presence
  add column if not exists in_match boolean not null default false;

comment on column player_presence.in_match is
  '客户端自报：该玩家是否正在一局对局中（备战 / 战斗 / 结算都算）。'
  '只用于好友列表的展示与邀请按钮，不承载任何结算数据。';
