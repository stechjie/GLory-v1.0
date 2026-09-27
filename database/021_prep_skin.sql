-- 021: 棋盘皮肤（对局里的摆放界面用哪一套图）
--
-- 配套 backend/app/loadout.py 的「棋盘皮肤」一节、data/prep_skins.json（客户端的皮肤目录）、
-- docs/棋盘皮肤.md。
--
-- 换皮肤在主界面的「备战」页，皮肤显示在对局里的摆放界面。
-- **只有自己看得见**（游戏里没有看别人摆放界面的功能），所以它不进出战名片，
-- 战斗服务器不知道它。存在这里只是为了换手机、重装之后还是那张。
--
-- 只加一列，🟢。

alter table players add column prep_skin text;

-- null = 默认皮肤（青草地）。选回默认也存 null，不存 prep_skin_default ——
-- 同一个意思只有一种写法。
--
-- 这里只管格式，是最后一道防线（同 selected_races_shape）；「买了没有」在 backend/app/loadout.py。
-- 长度上限 64 与 player_entitlements.item_id 一致：卖的皮肤要能写进归属表。
alter table players add constraint prep_skin_shape check (
  prep_skin is null or prep_skin ~ '^prep_skin_[a-z0-9_]{1,54}$'
);

comment on column players.prep_skin is
  '棋盘皮肤（内容 id）。null = 默认。只有自己看得见，不进出战名片。';
