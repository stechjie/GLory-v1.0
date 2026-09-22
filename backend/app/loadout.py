"""出战名片：账号服务器盖章、战斗服务器认章。

配套 `database/011_loadout.sql`、`scripts/multiplayer/BattleCard.gd`（战斗服务器验章），
设计见 `docs/商城系统设计.md` 第五节。

## 为什么需要它

战斗服务器不认识玩家。它不知道你是谁、买过什么，以前只能信手机报上来的 ——
手机被改了就能用没买的，手机重开忘了就用不上买了的。更糟的是同一件事有三种做法：
宠物跟着棋盘每回合报一次、种族准备时报一次、名字头像则是把**登录令牌**交给战斗服务器
让它回头去问账号服务器（那个令牌从商城上线起能花钻石）。

出战名片把这三条收成一条：

    账号服务器把它记着的「你这局带进去的东西」签个名发给你
    → 你连战斗服务器时把名片交上去
    → 战斗服务器用公钥验签，整张名片记在座位上，**整局都以它为准**

重连回到同一个座位，名片还在，宠物 / 种族 / 头像全都一样。以后加皮肤、加要解锁的种族，
就是往名片里加一个字段，**不再发明第四种做法**。

## 分工

- 账号服务器（这里）：「你有没有资格用」—— 每一样都过 `shop.requires_entitlement`，
  没资格的直接不写进名片（或换成默认值）。
- 战斗服务器（BattleCard.gd / RacePick.gd）：「这个组合合不合规则」—— 例如种族必须正好 4 个。
  那边有棋子表，这边没有；两边各写一个「4」迟早会分叉。

## 线格式

    <base64(名片 JSON 的原始字节)>.<base64(RSA 签名)>

**签的是 JSON 的原始字节，验的也是同一串字节** —— 战斗服务器先验签、再解析，
从不重新序列化。这样就没有「两边 JSON 排版不一样导致验签失败」这一类问题。

签名算法：RSA-2048 / PKCS#1 v1.5 / SHA-256。**不能换成 PSS** —— Godot 底下的 mbedtls
对 RSA 默认走 PKCS#1 v1.5，2026-09-16 实测过（见设计文档第五节）。
"""

from __future__ import annotations

import base64
import dataclasses
import json
import logging
import os
import pathlib
import re
import secrets
import time
import uuid

from app import avatar_catalog, db, ranked, shop

log = logging.getLogger("glory.loadout")

# 名片格式版本。战斗服务器只认它认识的版本（BattleCard.VERSION）。
# 往名片里**加**字段不用升它（战斗服务器按名取、缺了用默认）；
# **改**某个字段的含义才要升。
CARD_VERSION = 1

# 名片有效期。玩家是在「马上要连战斗服务器」那一刻才拿的，连上只要几秒。
#
# 刻意很短：名片在网络上跑（虽然有 DTLS），被截走的话能冒充的时间就是这么长。
# 重连**不需要**新名片 —— 名片在第一次入座时就记在座位上了，见 BattleCard.gd。
CARD_TTL_SEC = 60

# 种族 id 的格式。与 database/011_loadout.sql 的约束一致 —— 这里先挡，
# 那边是最后一道（报 500），这里能给出 400 和一句人话。
_RACE_ID = re.compile(r"^[a-z0-9_]{1,32}$")
MAX_RACES = 16


class LoadoutRejected(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class CardKeyMissing(RuntimeError):
    """没配私钥。路由层转 503 —— 这是服务器配置问题，不是玩家的错。"""


# --- 出战种族 -----------------------------------------------------------------


def clean_races(value: object) -> list[str]:
    """格式校验。**不校验「必须几个」**，那是战斗服务器的规则（见模块开头）。

    去重但保序 —— 玩家点选的顺序对他有意义，战斗服务器会自己按棋子表排。
    """
    if not isinstance(value, list):
        raise LoadoutRejected("bad_races", "种族选择的格式不对")
    if not value or len(value) > MAX_RACES:
        raise LoadoutRejected("bad_races", "种族数量不对")
    out: list[str] = []
    for raw in value:
        if not isinstance(raw, str) or not _RACE_ID.match(raw):
            raise LoadoutRejected("bad_races", "种族 id 格式不对")
        if raw in out:
            raise LoadoutRejected("bad_races", "种族重复了")
        out.append(raw)
    return out


async def read_races(player_id: uuid.UUID) -> list[str] | None:
    async with db.pool().acquire() as conn:
        value = await conn.fetchval(
            "select selected_races from players where player_id = $1", player_id)
    return list(value) if value else None


async def save_races(player_id: uuid.UUID, races: list[str]) -> list[str]:
    """存出战种族。**每一族都要有资格用** —— 今天所有族都免费，
    以后某一族放进商城卖，没买的人就存不进去。"""
    clean = clean_races(races)
    owned = set(await shop.read_entitlements(player_id))
    for race in clean:
        if shop.requires_entitlement(race) and race not in owned:
            raise LoadoutRejected("race_not_owned", "你还没有解锁这个种族")
    async with db.pool().acquire() as conn:
        await conn.execute(
            "update players set selected_races = $2 where player_id = $1",
            player_id, clean)
    return clean


# --- 名片内容 -----------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Loadout:
    player_id: str
    friend_code: str
    player_name: str
    avatar: str
    avatar_frame: str
    pet: str
    races: list[str]
    # 段位（0..7）。**-1 = 没打过排位**，不是 0 —— 0 是第一段（黑铁），
    # 默认成 0 会让所有新玩家在房间里顶着一个没打过的段位。
    tier: int = -1


async def build_loadout(player_id: uuid.UUID) -> Loadout:
    """从账号服务器记着的状态组出名片内容。

    🔴 **每一样都在这里再过一遍资格。** 写入时（换头像、换宠物、存种族）已经校验过，
    但那之后可能发生退款收回 —— 名片是战斗服务器唯一认的东西，这里是最后一道。
    没资格的一律**换成默认 / 去掉**，不报错：玩家该能继续玩，只是用不上那一样。
    """
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(
            "select friend_code, player_name, avatar, avatar_frame, showcase_pet, selected_races"
            " from players where player_id = $1",
            player_id,
        )
        # 段位（第 6 步）。**打过至少一局排位才带** —— 一局没打就顶着「黑铁」
        # 在房间里被人看见，是把「还没开始」显示成「打得很差」。
        rank_row = await conn.fetchrow(
            "select score, games from player_ranked where player_id = $1", player_id)
    if row is None:
        raise LoadoutRejected("player_not_found", "该身份没有对应的玩家，请重新登录")
    owned = set(await shop.read_entitlements(player_id))

    def entitled(content_id: str) -> bool:
        return bool(content_id) and (
            not shop.requires_entitlement(content_id) or content_id in owned)

    avatar = str(row["avatar"] or "")
    if not entitled(avatar):
        avatar = avatar_catalog.default_avatar()
    frame = str(row["avatar_frame"] or "")
    if not entitled(frame):
        frame = avatar_catalog.default_frame()

    pet = str(row["showcase_pet"] or "")
    # 宠物全部在商品目录里（新手三选一也是经归属表发的），所以这里一定会查归属。
    if pet and not (shop.is_pet(pet) and entitled(pet)):
        pet = ""

    # 种族：有资格的留下，没资格的去掉。去掉之后凑不够数的话，
    # 战斗服务器按 RacePick 规则会整份换成默认 —— 那是它的事，这里不猜。
    races = [r for r in (row["selected_races"] or []) if entitled(r)]

    return Loadout(
        player_id=str(player_id),
        friend_code=str(row["friend_code"] or ""),
        player_name=str(row["player_name"] or ""),
        avatar=avatar,
        avatar_frame=frame,
        pet=pet,
        races=races,
        # 换算口径只有一处：ranked.tier_of。客户端和这里都不许再除一遍。
        tier=ranked.tier_of(int(rank_row["score"]))
            if rank_row is not None and int(rank_row["games"]) > 0 else -1,
    )


def card_payload(
    loadout: Loadout,
    now: float | None = None,
    match_uid: str = "",
    team: int = -1,
) -> dict:
    """名片的 JSON 结构。字段名与 BattleCard.gd 一一对应（test_loadout 钉着）。

    `match_uid` / `team` 是**匹配出来的对局**才有的（app/matchmaking.py）。
    自己建房、加房间号进去的那条路不带它们，字段根本不出现 ——
    战斗服务器按名取、缺了就走原来的自定义房间那条路。

    🔴 **加字段不升 CARD_VERSION。** 见上面那条常量的注释：战斗服务器按名取、
    缺了用默认，所以加字段是向后兼容的。升版本会让**旧战斗服务器拒掉所有新名片**
    —— 那才是真正的破坏性变更，留给「改某个字段的含义」时用。
    """
    issued = int(time.time() if now is None else now)
    payload = {
        "v": CARD_VERSION,
        "pid": loadout.player_id,
        "code": loadout.friend_code,
        "name": loadout.player_name,
        "avatar": loadout.avatar,
        "frame": loadout.avatar_frame,
        "pet": loadout.pet,
        "races": list(loadout.races),
        "iat": issued,
        "exp": issued + CARD_TTL_SEC,
        # 一次性编号。战斗服务器在有效期内记着用过的，同一张名片交第二次就拒 ——
        # 被截走的名片不能拿去再占一个座位。
        "jti": secrets.token_hex(12),
    }
    # 段位：房间里给别人看的（协议 32 起，第 6 步）。没打过排位就不带这个字段，
    # 战斗服务器按名取、缺了不显示徽章。
    if loadout.tier >= 0:
        payload["tier"] = int(loadout.tier)
    if match_uid and team >= 0:
        # 会合键：六个人拿着同一个 match 各自连上去，谁先到谁建房，后到的进同一间。
        # 账号服务器说不出「去几号房」—— 房间是客户端连上去才建的（第 4a 步的发现）。
        payload["match"] = match_uid
        payload["team"] = int(team)
    return payload


# --- 签名 ---------------------------------------------------------------------

_key_cache: tuple[str, float, object] | None = None


def _key_path() -> str:
    from app.config import get_settings

    return get_settings().battle_card_key_file.strip()


def _private_key():
    """读私钥，按 (路径, mtime) 缓存。轮换密钥时换文件即可，不用重启。"""
    global _key_cache
    path = _key_path()
    if not path:
        raise CardKeyMissing("没有配置 GLORY_BATTLE_CARD_KEY_FILE")
    try:
        mtime = os.stat(path).st_mtime
    except OSError as exc:
        raise CardKeyMissing("读不到名片私钥 %s" % path) from exc
    if _key_cache is not None and _key_cache[0] == path and _key_cache[1] == mtime:
        return _key_cache[2]

    from cryptography.hazmat.primitives import serialization

    key = serialization.load_pem_private_key(pathlib.Path(path).read_bytes(), password=None)
    _key_cache = (path, mtime, key)
    return key


def sign(payload: dict) -> str:
    """把名片序列化并签名，返回线格式。"""
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import padding

    # 紧凑、不转义中文 —— 名字里的中文按 UTF-8 原样进去，名片更短。
    # 顺序无所谓：战斗服务器验的是这串字节本身，不会重新序列化。
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    signature = _private_key().sign(body, padding.PKCS1v15(), hashes.SHA256())
    return "%s.%s" % (
        base64.b64encode(body).decode("ascii"),
        base64.b64encode(signature).decode("ascii"),
    )


async def issue_card(player_id: uuid.UUID, match_uid: str = "", team: int = -1) -> str:
    return sign(card_payload(await build_loadout(player_id), match_uid=match_uid, team=team))
