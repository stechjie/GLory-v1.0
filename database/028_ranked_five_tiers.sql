-- Five ranked tiers share the same stored points. Historical archived tier values
-- are left intact; they describe the rules of the season in which they were earned.
-- Configure season reward rows for tier 0..4 before settling a five-tier season.
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
           case when r.score >= 700 then 4
                when r.score >= 500 then 3
                when r.score >= 300 then 2
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
