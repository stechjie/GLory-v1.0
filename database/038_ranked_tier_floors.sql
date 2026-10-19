-- 038: 段位门槛改成每段上限 100 / 200 / 400 / 800 / 1600（2026-10-15 用户定）
--
--   初誓 0–99 · 森卫 100–199 · 星铸 200–399 · 天曜 400–799 · 荣耀之冠 800 以上
--   （原来 028 是 0 / 100 / 300 / 500 / 700 起）
--
-- 原名 037_ranked_tier_floors.sql，没提交过；10-19 和同一天进库的 037_progression.sql 撞号，改成 038。
-- 🔴 必须在 037_progression.sql 之后跑：文件下半段改的触发器和列是它建的。
--
-- 配套：backend/app/ranked.py 的 TIER_FLOORS。玩家平时看到的段位是那边按分数现算的，
-- 一更新账号服务器就变；**只有赛季结算归档 / 发奖**走这里的 settle_season，
-- 而 SQL 调不到 Python，所以门槛在这里另抄了一份。
--
-- 🔴 不跑这个文件的后果：赛季结算按旧门槛归档发奖，和玩家结算前看到的段位对不上
-- （比如 750 分的人平时显示天曜，结算却按荣耀之冠发奖）；星铸保底也停在旧的 300。
-- 账号服务器启动自检会报「038 settle_season 用新段位门槛」「038 星铸保底跟新门槛」缺失。
--
-- 上半段 settle_season：只换 case 那五行，其余和 028 一字不差（认领、旧八档奖励拦截、
-- 只给打过的人发奖、清零）。已经归档的赛季不重算：归档里的 tier 是那个赛季当时的规则。
-- 整个文件手工跑两遍也安全；不改表结构，不用重启账号服务器。

create or replace function settle_season(p_season int, p_actor text)
returns int
language plpgsql
as $$
declare
    v_claimed int;
    v_mails int := 0;
    v_title text;
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception '必须填操作人（p_actor）：以后要查「这个赛季是谁结算的」';
    end if;

    -- Old eight-tier reward rows must be reviewed, not silently paid at new ranks.
    if exists (select 1 from ranked_season_rewards
                where season = p_season and tier > 4) then
        raise exception '赛季 % 仍有旧八档奖励配置，请先核对并改为五档', p_season;
    end if;

    update ranked_seasons
       set settled_at = now()
     where season = p_season and settled_at is null;
    get diagnostics v_claimed = row_count;
    if v_claimed = 0 then
        return -1;
    end if;

    select coalesce(title_zh, '第 ' || p_season || ' 赛季') into v_title
      from ranked_seasons where season = p_season;

    insert into player_ranked_history (season, player_id, score, tier, games, wins)
    select p_season, r.player_id, r.score,
           case when r.score >= 800 then 4
                when r.score >= 400 then 3
                when r.score >= 200 then 2
                when r.score >= 100 then 1
                else 0 end,
           r.games, r.wins
      from player_ranked r
     where r.season = p_season
    on conflict (season, player_id) do nothing;

    insert into mails (player_id, title_zh, body_zh, title_en, body_en,
                       diamond, coin, items, actor, note, expires_at)
    select h.player_id,
           v_title || ' 奖励',
           '恭喜你在' || v_title || '达到' ||
             (array['初誓','森卫','星铸','天曜','荣耀之冠'])[h.tier + 1] ||
             '，积分 ' || h.score || '。',
           'Season ' || p_season || ' Rewards',
           'You finished Season ' || p_season || ' at ' ||
             (array['Oathbound','Verdant Guard','Starforged','Celestial','Crown of Glory'])[h.tier + 1] ||
             ' with ' || h.score || ' points.',
           w.diamond, w.coin, w.items,
           btrim(p_actor), 'season=' || p_season,
           now() + interval '30 days'
      from player_ranked_history h
      join ranked_season_rewards w on w.season = h.season and w.tier = h.tier
     where h.season = p_season and h.games > 0;
    get diagnostics v_mails = row_count;

    update player_ranked
       set score = 0, games = 0, wins = 0, win_streak = 0,
           season = p_season + 1, updated_at = now()
     where season = p_season;

    update ranked_seasons set settled_mails = v_mails where season = p_season;
    return v_mails;
end;
$$;

-- ---------------------------------------------------------------------------
-- 下半段：森卫 / 星铸永久保底跟新门槛走（10-19 用户定：以新门槛为准，300 改 200）
--
-- 037_progression.sql（lenoliew 10-18 的进阶）是按旧门槛写的：「突破森卫」= 分数到 300，
-- 突破后保底也是 300。新门槛下星铸从 200 起，300 落在星铸中间。这里：
--   1. 重定义 keep_ranked_stage_floor：只把 300 换成 200，其余和 037_progression 一字不差。
--   2. 给 200 分以上、还没记突破的人补记 breakthrough_complete（037 当时只补了 300 以上）。
--      不补的话，这些人只要不到 4 族，下一局结算就会被当成「没突破」压回 199。
--      顺手清掉他们的 breakthrough_ready（「卡在门口等第 4 族」），人已经算突破了。
-- 配套：backend/app/ranked.py 的 FOREST_FLOOR / STARFORGE_FLOOR（= TIER_FLOORS[1] / [2]）。
--
-- 🔴 顺序不能反：先换函数、再补记。触发器在每次 update player_ranked 时都跑，
--    要是先 update，旧函数会把 200–299 分的人直接抬到 300。

create or replace function keep_ranked_stage_floor() returns trigger
language plpgsql as $$
begin
  new.forest_unlocked := new.forest_unlocked or old.forest_unlocked or new.score >= 100;
  new.breakthrough_complete := new.breakthrough_complete or old.breakthrough_complete
    or new.score >= 200;
  if new.breakthrough_complete then
    new.score := greatest(new.score, 200);
  elsif new.forest_unlocked then
    new.score := greatest(new.score, 100);
  end if;
  return new;
end
$$;

update player_ranked
   set breakthrough_complete = true, breakthrough_ready = false
 where score >= 200 and not breakthrough_complete;
