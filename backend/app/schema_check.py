"""启动自检：线上数据库的结构，和这份代码要用的，对不对得上。

## 为什么要有它（2026-10-11）

漏跑迁移在这个项目里**已经发生三次**，每次都是同一个形状：

    10-07  030 没跑  ->  排位里点「邀请好友」 HTTP 500
    10-11  032 没跑  ->  朋友页 HTTP 500，而且**所有人一起显示离线**（心跳也写那一列）
    （031 可能也没跑 -> 老玩家赤律族归属没补发）

根因不是谁粗心，是**流程里没有防漏的环节**：`database/README.md` 的跑法是
「Supabase Dashboard → SQL Editor，按编号顺序逐个执行」，纯手工；31 个迁移文件
**零台账**，没有任何地方知道线上跑到第几号；`deploy/update.sh` 明说只更新代码、
不动结构；而 `/health` 只看配置填没填、**完全不看表结构**。

于是漏跑的代价是「玩家先踩到 500，你再回头查」。这个模块把代价挪到**部署那一刻**。

## 做法：拿**真的 SQL** 去 prepare，而不是维护一张「需要哪些列」的清单

清单会腐烂 —— 加列的人很容易忘了同步更新它，那时自检就变成假绿。

所以第一类检查直接把各模块**已经在用的那条语句**拿过来 `prepare()`：asyncpg 会把
它送给 PostgreSQL 做语法与名字解析，**但不执行**。列不存在就当场抛
`UndefinedColumnError`，而且错误里带着列名。语句改了，检查跟着改，不可能漂移。

## 🔴 它抓不到什么（别指望它挡住全部）

`prepare` 只校验**名字解析**（表、列、函数在不在）。抓不到：

  · **check 约束放宽**类的迁移 —— 030 就是这种：`chat_messages.kind` 的约束没放行
    `party_invite`，语句本身完全合法，要到真 insert 那一刻才被拒。
  · 数据层面的迁移（031 的一次性补发）。

这两类只能靠第二类检查：直接问系统表「那个东西在不在」。那份清单**会腐烂**，
但它只需要收录「不是加列」的迁移，条目很少，加迁移的人顺手补一条即可。
"""

from __future__ import annotations

import logging

from app import db, friends, iap, presence, ranked, sanctions, service_control, shop, skin_draw

log = logging.getLogger("glory.schema")

# 第一类：各模块**正在用的**语句，原样拿来 prepare。不另抄一份 —— 抄了就会漂。
_PREPARED: list[tuple[str, str]] = [
    # 朋友页（GET /v1/me/friends）。10-11 的 500 就出在这条：它引用 032 的 in_match。
    ("friends._LIST_FRIENDS", friends._LIST_FRIENDS),
    # 心跳（PUT /v1/me/presence）。同样引用 in_match ——
    # 这条挂了的症状是**所有人一起显示离线**，比朋友页报错更难往「漏跑迁移」上想。
    ("presence._HEARTBEAT", presence._HEARTBEAT),
    # 服务控制（035）。这条挂了的症状最隐蔽：service_control.read() 会把
    # 「表不存在」当成「功能没部署」而**放行一切** —— 也就是维护开关悄悄失效，
    # 后台按了也没用，而且没有任何报错。所以必须在启动时喊出来。
    ("service_control._READ_STATE", service_control._READ_STATE),
    # 入场名册（035）。这条挂了维护会把正在打的人也踢掉。
    ("service_control._CLEAR_MATCH", service_control._CLEAR_MATCH),
    # 人工处罚（036）。这条 prepare 得过不代表能用 —— 它只校验列名，
    # 而 036 真正改的是 check 约束（见下面的探针）。
    ("sanctions._LIVE_SANCTION", sanctions._LIVE_SANCTION),
    # 钱包（040 加了 diamond_debt）。这条挂了不只是充值：商城、抽宠物、邮件领取、七日登录、
    # 升级奖励**一起 500** —— 它们都经过 shop._lock_wallet。
    ("shop.LOCK_WALLET", shop.LOCK_WALLET),
    # 真钱订单（040）。挂了的症状是玩家付了钱、confirm 500、钻石不到账。
    ("iap.LOCK_ORDER", iap.LOCK_ORDER),
    # 樱花祈愿（042）。挂了的症状是打开祈愿页 500、抽不了。
    ("skin_draw._PROGRESS", skin_draw._PROGRESS),
]

# 第二类：prepare 看不见的东西。只收「不是加列」的迁移，一条迁移一行。
#   sql 回一行 = 在；回零行 = 缺。
_PROBES: list[tuple[str, str, str]] = [
    (
        "041 ranked_reward_receipts.coin supports 20 coins",
        "select 1 from pg_constraint"
        " where conrelid = to_regclass('public.ranked_reward_receipts')"
        "   and conname = 'ranked_reward_receipts_coin_check'"
        "   and pg_get_constraintdef(oid) like '%<= 20%'",
        "排位胜利奖励16至20金币会被旧约束拒绝，整场积分、金币和经验一起回滚",
    ),
    (
        "037 等级、升级事件与森卫突破",
        "select 1 where to_regclass('public.player_progression') is not null"
        " and to_regclass('public.level_up_events') is not null"
        " and exists (select 1 from information_schema.columns"
        " where table_name = 'player_ranked' and column_name = 'breakthrough_ready')"
        " and exists (select 1 from information_schema.columns"
        " where table_name = 'player_ranked' and column_name = 'breakthrough_complete')"
        " and exists (select 1 from pg_trigger"
        " where tgname = 'ranked_stage_floor' and not tgisinternal)",
        "新账号初始化、对局经验与排位结算会失败",
    ),
    (
        "030 chat_messages.kind 放行 party_invite",
        "select 1 from pg_constraint"
        " where conname = 'chat_message_kind_allowed'"
        "   and pg_get_constraintdef(oid) like '%party_invite%'",
        "组队/排位房点「邀请好友」会 HTTP 500（10-07 踩过一次）",
    ),
    (
        "036 player_mutes.scope 放行 voice / ranked",
        "select 1 from pg_constraint"
        " where conname = 'mute_scope'"
        "   and pg_get_constraintdef(oid) like '%voice%'"
        "   and pg_get_constraintdef(oid) like '%ranked%'",
        "后台下「禁语音」「禁排位」会失败；和 030 同一个形状 —— 语句完全合法，"
        "要到真 insert 那一刻才被约束拒，prepare 看不见",
    ),
    (
        "036 unmute_player 带 scope 参数",
        "select 1 from pg_proc where proname = 'unmute_player' and pronargs = 4",
        "🔴 解除世界频道禁言会**连带解除禁语音和禁排位**（旧版函数不分 scope 全撤）",
    ),
    (
        "040 wallet_ledger.currency 放行 diamond_debt",
        "select 1 from pg_constraint"
        " where conname = 'wallet_ledger_currency'"
        "   and pg_get_constraintdef(oid) like '%diamond_debt%'",
        "退款扣不回的钻石记不进欠账：退款那一笔整个失败（同 030 的毛病：约束拦在 insert 那一刻）",
    ),
    (
        "031 one_time_grants 表",
        "select 1 where to_regclass('public.one_time_grants') is not null",
        "老玩家的赤律族归属没补发，出战名片可能把赤律族去掉",
    ),
    (
        "033 chat_messages.kind 放行 voice",
        "select 1 from pg_constraint"
        " where conname = 'chat_message_kind_allowed'"
        "   and pg_get_constraintdef(oid) like '%voice%'",
        "私聊发语音会 HTTP 500（同 030 那次组队邀请的毛病：约束拦在 insert 那一刻）",
    ),
    (
        "033 world_messages.kind / payload 两列与放宽后的 body 约束",
        "select 1 from pg_constraint"
        " where conname = 'world_body_length'"
        "   and pg_get_constraintdef(oid) like '%voice%'",
        "世界频道发语音会 HTTP 500（旧约束要求 body 1–100 字，语音的 body 是服务端写的占位）",
    ),
    (
        # 门槛 = ranked.TIER_FLOORS 最高档起点，改段位时探针跟着走。
        "038 settle_season 用新段位门槛",
        "select 1 from pg_proc where proname = 'settle_season'"
        "   and prosrc like '%%r.score >= %d then 4%%'" % ranked.TIER_FLOORS[-1],
        "赛季结算会按旧门槛归档发奖，和玩家平时看到的段位对不上（不报错，结算那天才发现）",
    ),
    (
        # 保底分 = ranked.STARFORGE_FLOOR；037_progression 原版写死的是旧门槛 300。
        "038 星铸保底跟新门槛",
        "select 1 from pg_proc where proname = 'keep_ranked_stage_floor'"
        "   and prosrc like '%%greatest(new.score, %d)%%'" % ranked.STARFORGE_FLOOR,
        "突破森卫后的保底停在旧的 300：星铸 200–299 分的人打完一局会被直接抬到 300",
    ),
]


async def verify() -> list[str]:
    """核一遍。返回人话描述的缺失项；空列表 = 结构和代码对得上。

    **自己不抛异常。** 它是启动路径上的检查，不该因为自己出错就把服务拖垮；
    连不上库时直接返回空（那种情况由 db.connect 那边报）。
    """
    if not db.is_connected():
        return []
    problems: list[str] = []
    try:
        async with db.pool().acquire() as conn:
            for name, sql in _PREPARED:
                try:
                    await conn.prepare(sql)
                except Exception as exc:  # noqa: BLE001 - 原样把数据库的话带出来
                    problems.append("%s 对不上当前表结构：%s" % (name, exc))
            for label, sql, hurts in _PROBES:
                try:
                    if await conn.fetchval(sql) is None:
                        problems.append("%s 缺失 —— %s" % (label, hurts))
                except Exception as exc:  # noqa: BLE001
                    problems.append("%s 没法核对：%s" % (label, exc))
    except Exception as exc:  # noqa: BLE001
        log.warning("结构自检没能跑起来：%s", exc, exc_info=True)
        return []
    return problems


async def verify_and_log() -> list[str]:
    """启动时调它。

    🔴 **只报警，不拒绝启动。** 理由同 main.py 里那条「配置没填也让它起来」：
    结构不对时拒绝启动，受影响的接口照样不可用，却把登录 / 聊天 / 匹配一起拖下水。
    报警要**足够大声**才有意义 —— 用 error 级别、一行一条、带上「漏了会怎样」，
    这样 `journalctl -u glory-backend | grep SCHEMA` 一眼就能看到。
    """
    problems = await verify()
    if not problems:
        log.info("SCHEMA ok：数据库结构与代码一致")
        return problems
    log.error("SCHEMA 不一致 —— 很可能是漏跑了 database/ 下的迁移（%d 项）：", len(problems))
    for item in problems:
        log.error("SCHEMA   · %s", item)
    log.error("SCHEMA 修法：Supabase SQL Editor 按编号跑缺的那几个，**跑完必须重启本服务**"
              "（DDL 之后旧连接的查询计划会报 cached plan must not change result type）")
    return problems
