-- 011: 出战种族搬到账号服务器
--
-- 配套 backend/app/loadout.py 与 docs/商城系统设计.md 第五节「出战名片」。
--
-- ## 为什么要搬
--
-- 出战种族原本只存在手机本地（user://profile.json）。战斗服务器要用它摇商店，
-- 于是只能信手机报上来的那份 —— 手机被改了就能选没解锁的族，
-- 手机重装了就得重选。
--
-- 出战名片的规则只有一条：**对局里用到的账号级东西，一律以账号服务器盖过章的为准。**
-- 账号服务器不知道的东西没法盖章，所以种族也得存在这里。
-- 宠物（players.showcase_pet）、头像、头像框本来就在 players 表上。
--
-- ## 分工
--
-- 账号服务器只管「你有没有资格用这一族」（backend/app/shop.py 的 requires_entitlement ——
-- 不在商品目录里的族一律免费）。**「必须正好 4 个」这类组合规则归战斗服务器**
-- （scripts/units/RacePick.gd），那边有棋子表、知道一共有哪些族。
-- 两边各写一个「4」的话，迟早会出现账号服务器收下、战斗服务器不认的组合。

alter table players add column selected_races text[];

-- null = 从没选过，战斗服务器用默认（RacePick.default_races）。
--
-- 这里只管格式：数量有上限、每个 id 是短小写串、不许有空元素。
-- 这是最后一道防线（任何写进库的字符串都要有上限，同 players.player_name），
-- 业务校验在 backend/app/loadout.py。
alter table players add constraint selected_races_shape check (
  selected_races is null
  or (
    cardinality(selected_races) between 1 and 16
    and array_to_string(selected_races, ',') ~ '^[a-z0-9_]{1,32}(,[a-z0-9_]{1,32})*$'
  )
);

comment on column players.selected_races is
  '出战种族（内容 id）。null = 没选过，用默认。组合规则（必须几个）归战斗服务器，这里只存。';
