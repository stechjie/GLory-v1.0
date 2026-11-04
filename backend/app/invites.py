"""邀请码（database/043_invites.sql，2026-11-03 用户逐条拍板）。

码 = players.friend_code。新玩家填邀请人的码；被邀请人达到 invite_reward_level 时，
在同一个事务里给两边各发一封带钻石的系统邮件（钻石进赠送列，领取走 mail.claim）。
数字全在 .env（config.invite_*）。

## 两个发奖入口，同一个函数

  · 对局结算加经验之后（progression.award_match / award_tutorial）
  · 填码那一刻 —— 填的时候已经够级了就当场发

判定是「**达到或超过**」门槛，不是「刚好跨过」：总闸关着时达标的人、门槛调低之后
早就过线的人，都会在下一局补上。代价是够级的玩家每局多一次主键查询。

## 🔴 发奖出错不能拖垮对局结算

maybe_reward 包在保存点里（asyncpg 嵌套 transaction = SAVEPOINT）。出错只回滚这一段、
记 error 日志，结算照常提交；rewarded_at 还是 null，下一局再试。
不这么做的话，一个 .env 填错的数（被约束拒）会让**所有被邀请人的每一局**整份战报回滚。

## 并发

  · 同一个被邀请人被两处同时发奖（两个事务）：`… where rewarded_at is null for update`，
    后到的等前一个提交，再判一次条件就不成立了。
  · 同一个邀请人的上限是「先 count 再发」：两个被邀请人同时达标会都数到 19 → 发出 21 份。
    所以先拿邀请人的事务级 advisory lock（不锁 players 行，理由同 friends._lock_players）。
    一局里两个被邀请人、各自的邀请人在另一局里顺序相反时，理论上会互等 ——
    PostgreSQL 会掐掉其中一个，那一笔在保存点里回滚、下一局补发，不影响结算。

## 不限流

好友码是公开的查找键（004）：加好友、拉黑按码查人一样会告诉你码在不在。
这里多一道限流挡不住任何东西。防爆破只在兑换码（app/redeem.py）—— 那边猜中就给钱。
"""

from __future__ import annotations

import dataclasses
import logging
import re
import unicodedata
import uuid

import asyncpg

from app import db
from app.config import get_settings

log = logging.getLogger("glory.invites")

# 与 database/004_profile_display.sql 的 friend_code_format 一致。
FRIEND_CODE_RE = re.compile(r"[2-9A-HJKMNP-Z]{8}")

# advisory lock 键前缀。邀请人的上限锁和填码的排队锁分开：
# 一个事务只持有一个填码锁、只等一个上限锁，两种锁之间就成不了环。
_LOCK_BIND = "invite_bind:"
_LOCK_CAP = "invite_cap:"

INVITEE_TITLE = ("邀请奖励", "Invite reward")
INVITER_TITLE = ("邀请奖励", "Invite reward")


class InviteRejected(RuntimeError):
    """业务拒绝。code 进 X-Glory-Reason，message 可以直接给玩家看。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def normalize(code: str) -> str:
    """玩家抄码时常见的全角、空格、连字符、小写都去掉。

    NFKC 把中文输入法打出来的全角「ＡＢＣ２３４５」变回半角 —— 马来西亚华语玩家
    用拼音输入法填码很常见，不转的话他看着一模一样、却永远「没有这个邀请码」。
    """
    text = unicodedata.normalize("NFKC", code or "")
    return re.sub(r"[\s-]", "", text).upper()


@dataclasses.dataclass(frozen=True)
class Status:
    can_bind: bool         # 现在能不能填码：总闸开着、没填过、在注册窗口内
    bound: bool            # 已经填过
    rewarded: bool         # 已经发过奖
    reward_level: int      # 客户端显示「到 N 级」用；改 .env 就变，不用出包
    invitee_diamond: int
    inviter_diamond: int


_STATUS = (
    "select p.created_at > now() - make_interval(days => $2) as in_window,"
    "       i.inviter, i.rewarded_at"
    "  from players p left join player_invites i on i.invitee = p.player_id"
    " where p.player_id = $1"
)

# 只取没发过奖的那一行并锁住。已经发过 = 返回空，后到的并发事务在锁上等完再判一次也是空。
_LOCK_PENDING = (
    "select inviter from player_invites"
    " where invitee = $1 and rewarded_at is null for update"
)

_INVITER = (
    "select p.deleted_at is not null as deleted,"
    "       (select count(*) from player_invites"
    "         where inviter = p.player_id and rewarded_at is not null) as rewarded"
    "  from players p where p.player_id = $1"
)

_SEND = (
    "insert into mails (player_id, title_zh, body_zh, title_en, body_en, diamond, actor, note)"
    " values ($1, $2, $3, $4, $5, $6, 'invite', $7) returning mail_id"
)


def _status(row: asyncpg.Record | None) -> Status:
    s = get_settings()
    bound = row is not None and row["inviter"] is not None
    return Status(
        can_bind=bool(s.invite_enabled and row is not None and row["in_window"] and not bound),
        bound=bound,
        rewarded=bound and row["rewarded_at"] is not None,
        reward_level=s.invite_reward_level,
        invitee_diamond=s.invite_invitee_diamond,
        inviter_diamond=s.invite_inviter_diamond,
    )


async def status(player_id: uuid.UUID) -> Status:
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(_STATUS, player_id, get_settings().invite_bind_window_days)
    return _status(row)


async def _lock(conn: asyncpg.Connection, key: str) -> None:
    # 只能用 xact 版本：Supabase 的 Transaction pooler 下会话级锁释放不掉（同 friends）。
    await conn.execute("select pg_advisory_xact_lock(hashtextextended($1, 0))", key)


async def bind(player_id: uuid.UUID, raw_code: str) -> Status:
    s = get_settings()
    if not s.invite_enabled:
        raise InviteRejected("invite_disabled", "邀请功能暂时关闭")
    code = normalize(raw_code)
    if not FRIEND_CODE_RE.fullmatch(code):
        raise InviteRejected("invite_code_invalid", "邀请码是 8 位字母和数字")
    async with db.pool().acquire() as conn, conn.transaction():
        # 同一个人连点两下：第二下在锁上等第一下提交，然后看见「已经填过」，而不是撞主键 500。
        await _lock(conn, _LOCK_BIND + str(player_id))
        me = await conn.fetchrow(_STATUS, player_id, s.invite_bind_window_days)
        if me is None:
            raise InviteRejected("invite_no_player", "账号不存在，请重新登录")
        if me["inviter"] is not None:
            raise InviteRejected("invite_already_bound", "你已经填过邀请码了")
        if not me["in_window"]:
            raise InviteRejected(
                "invite_window_closed", "只有注册 %d 天内的新账号能填邀请码" % s.invite_bind_window_days)
        inviter = await conn.fetchval(
            "select player_id from players where friend_code = $1 and deleted_at is null", code)
        if inviter is None:
            raise InviteRejected("invite_code_not_found", "没有这个邀请码，检查一下有没有抄错")
        if inviter == player_id:
            raise InviteRejected("invite_self", "不能填自己的邀请码")
        await conn.execute(
            "insert into player_invites (invitee, inviter) values ($1, $2)", player_id, inviter)
        level = await conn.fetchval(
            "select level from player_progression where player_id = $1", player_id)
        await maybe_reward(conn, player_id, int(level or 1))
        row = await conn.fetchrow(_STATUS, player_id, s.invite_bind_window_days)
    log.info("邀请绑定 invitee=%s inviter=%s", player_id, inviter)
    return _status(row)


async def maybe_reward(conn: asyncpg.Connection, invitee: uuid.UUID, level: int) -> bool:
    """够级就发。**自己不抛异常**：出错回滚自己那一段，调用方的事务照常走。

    返回这次有没有发。调用方不需要看它（测试和日志用）。
    """
    s = get_settings()
    if not s.invite_enabled or level < s.invite_reward_level:
        return False
    try:
        async with conn.transaction():
            return await _reward(conn, invitee)
    except Exception:  # noqa: BLE001 - 见模块说明「发奖出错不能拖垮对局结算」
        log.exception("邀请发奖失败（已回滚这一笔，结算照常；下一局再试） invitee=%s", invitee)
        return False


async def _reward(conn: asyncpg.Connection, invitee: uuid.UUID) -> bool:
    s = get_settings()
    inviter = await conn.fetchval(_LOCK_PENDING, invitee)
    if inviter is None:
        return False
    await _lock(conn, _LOCK_CAP + str(inviter))
    level = s.invite_reward_level
    note = "invite invitee=%s" % invitee
    invitee_mail = await conn.fetchval(
        _SEND, invitee, INVITEE_TITLE[0],
        "你填写了好友的邀请码，账号达到 %d 级，送你 %d 钻石。" % (level, s.invite_invitee_diamond),
        INVITEE_TITLE[1],
        "You joined with a friend's invite code and reached level %d. Here are %d diamonds."
        % (level, s.invite_invitee_diamond),
        s.invite_invitee_diamond, note)

    other = await conn.fetchrow(_INVITER, inviter)
    inviter_mail = None
    skipped = None
    if other is None or other["deleted"]:
        skipped = "deleted"
    elif int(other["rewarded"]) >= s.invite_max_rewarded:
        skipped = "capped"
    else:
        inviter_mail = await conn.fetchval(
            _SEND, inviter, INVITER_TITLE[0],
            "你邀请的一位好友达到了 %d 级，送你 %d 钻石。谢谢你把 Glory 分享给朋友！"
            % (level, s.invite_inviter_diamond),
            INVITER_TITLE[1],
            "A friend you invited reached level %d. Here are %d diamonds. Thanks for sharing Glory!"
            % (level, s.invite_inviter_diamond),
            s.invite_inviter_diamond, note)

    await conn.execute(
        "update player_invites set rewarded_at = now(), invitee_mail = $2, inviter_mail = $3,"
        " inviter_skipped = $4 where invitee = $1",
        invitee, invitee_mail, inviter_mail, skipped)
    log.info("邀请发奖 invitee=%s inviter=%s invitee_mail=%s inviter_mail=%s skipped=%s",
             invitee, inviter, invitee_mail, inviter_mail, skipped)
    return True
