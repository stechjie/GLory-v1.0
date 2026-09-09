"""玩家资料的行为用例。

这里**不连数据库** —— 判据全是纯函数与静态一致性，所以能在任何机器上跑。
需要真库的部分（改名冷却的并发、生日只设一次、好友码唯一）归真机/线上验证。

最重要的一组是「公开视图裁剪」：判据是**隐藏字段在 JSON 里连 key 都没有**，
不是「有 key 但值为 null」，更不是「返回全量让客户端别显示」。
这条一旦破了不会报错、不会崩溃，只会安静地把玩家藏起来的生日发给陌生人。

跑（必须从 backend/ 目录，pytest.ini 在那里）：
    cd backend && .venv/Scripts/python -m pytest -q
"""

from __future__ import annotations

import datetime as dt
import json
import pathlib
import re

import pytest

from app import avatar_catalog, text_guard
from app.profile import RENAME_COOLDOWN, SelfProfile
from app.routes.profile import to_public

REPO = pathlib.Path(__file__).resolve().parents[2]


def make_row(**overrides) -> SelfProfile:
    base = dict(
        player_id="00000000-0000-4000-8000-000000000000",
        friend_code="7K2M9Q4B",
        player_name="Leno",
        avatar="preset:avatar_001",
        avatar_frame="preset:frame_default",
        showcase_pet="pet_rabbit",
        created_at=dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=10),
        name_changed_at=None,
        gender="male",
        birth_month=3,
        birth_day=14,
        region="MY",
        signature="今天也要加油",
        gender_visibility="public",
        birth_visibility="public",
        region_visibility="public",
    )
    base.update(overrides)
    return SelfProfile(**base)


def public_json(row: SelfProfile) -> dict:
    """按接口上挂的 response_model_exclude_none=True 走一遍，拿到真正发出去的 JSON。"""
    return to_public(row).model_dump(exclude_none=True)


# --- 公开视图裁剪 -------------------------------------------------------------


def test_public_view_includes_public_fields() -> None:
    body = public_json(make_row())
    assert body["gender"] == "male"
    assert body["birth_month"] == 3 and body["birth_day"] == 14
    assert body["region"] == "MY"
    assert body["signature"] == "今天也要加油"


@pytest.mark.parametrize(
    "flag, hidden_keys",
    [
        ("gender_visibility", ["gender"]),
        ("birth_visibility", ["birth_month", "birth_day"]),
        ("region_visibility", ["region"]),
    ],
)
def test_private_fields_have_no_key_at_all(flag: str, hidden_keys: list[str]) -> None:
    body = public_json(make_row(**{flag: "private"}))
    for key in hidden_keys:
        assert key not in body, "%s 被设为 private，但它仍出现在公开响应里" % key


def test_hidden_and_never_filled_look_identical() -> None:
    """观众不该能分辨「没填生日」和「填了但不给你看」。

    这是刻意的隐私性质，不是巧合 —— 如果两者响应不同，
    「他隐藏了生日」本身就成了一条泄漏出去的信息。
    """
    hidden = public_json(make_row(birth_visibility="private"))
    never = public_json(make_row(birth_month=None, birth_day=None))
    assert hidden == never


def test_public_view_never_leaks_internal_fields() -> None:
    """player_id 与可见性开关本身都不该出现在公开响应里。

    player_id 是内部身份（好友码才是对外的查找键）；
    可见性开关是玩家的隐私设置，别人无权知道。
    """
    body = public_json(make_row())
    for leaked in [
        "player_id",
        "created_at",
        "name_changed_at",
        "gender_visibility",
        "birth_visibility",
        "region_visibility",
    ]:
        assert leaked not in body


def test_signature_has_no_visibility_switch() -> None:
    """签名清空即隐藏，没有开关 —— 见 docs/玩家资料系统设计.md 第三节。"""
    assert "signature" not in public_json(make_row(signature=None))
    assert public_json(make_row(signature="在线"))["signature"] == "在线"


# --- 注册天数与改名冷却 -------------------------------------------------------


def test_days_since_created_starts_at_one() -> None:
    """刚注册就是「第 1 天」，不是第 0 天。"""
    row = make_row(created_at=dt.datetime.now(dt.timezone.utc))
    assert row.days_since_created == 1


def test_rename_is_free_before_first_change() -> None:
    assert make_row(name_changed_at=None).rename_available_at() is None


def test_rename_cooldown_is_seven_days() -> None:
    changed = dt.datetime.now(dt.timezone.utc)
    row = make_row(name_changed_at=changed)
    assert row.rename_available_at() == changed + RENAME_COOLDOWN
    assert RENAME_COOLDOWN == dt.timedelta(days=7)


# --- 昵称与签名 ---------------------------------------------------------------


# 攻击样本一律**用码位构造**，不写字面量 —— 同 app/text_guard.py 的理由：
# 没人能审查一段自己看不到的测试数据。看到 0x200B 才知道这一行在测什么。
ZERO_WIDTH_SPACE = chr(0x200B)
RTL_OVERRIDE = chr(0x202E)
COMBINING_GRAVE = chr(0x0300)
NEWLINE = chr(0x0A)


@pytest.mark.parametrize(
    "raw, code",
    [
        ("Leno" + ZERO_WIDTH_SPACE + "Master", "invisible_char"),  # 做出看起来一样的名字
        ("Leno" + RTL_OVERRIDE + "x", "bidi_override"),            # 伪造显示顺序
        ("a" + COMBINING_GRAVE * 4, "zalgo"),                      # 糊屏幕
        ("a" + NEWLINE + "b", "control_char"),                     # 破坏列表排版
        ("", "empty"),
        ("   ", "empty"),
        ("a" * 25, "length"),                                      # 与 001 的 player_name_length 一致
    ],
)
def test_player_name_rejections(raw: str, code: str) -> None:
    with pytest.raises(text_guard.TextRejected) as exc:
        text_guard.clean_player_name(raw)
    assert exc.value.code == code


def test_player_name_normalises_instead_of_rejecting() -> None:
    """能规范化的就规范化，别为难玩家：首尾空白、连续空白、全角空格。"""
    assert text_guard.clean_player_name("  Leno  ") == "Leno"
    assert text_guard.clean_player_name("Le  no") == "Le no"
    ideographic = chr(0x3000)  # 全角空格
    assert text_guard.clean_player_name("玩家" + ideographic + "一号") == "玩家 一号"


@pytest.mark.parametrize(
    "raw",
    [
        "加V: abc123",
        "QQ群 123456",
        "来 www.example.com 找我",
        "电话13812345678",
        "@somebody_here",
        "x" * 61,
    ],
)
def test_signature_rejects_contact_info_and_overlong(raw: str) -> None:
    with pytest.raises(text_guard.TextRejected):
        text_guard.clean_signature(raw)


def test_empty_signature_becomes_none() -> None:
    """清空即删除 —— 所以没有单独的「清空资料」接口。"""
    assert text_guard.clean_signature("") is None
    assert text_guard.clean_signature("   ") is None
    assert text_guard.clean_signature(None) is None


def test_text_guard_limits_match_database() -> None:
    """这一层的上限必须和 SQL 里的 check 约束一致。

    对不上会表现为「客户端说可以、后端 500」—— 数据库那层报的是 500，
    因为到那里已经没人接得住了。
    """
    sql_001 = (REPO / "database" / "001_players.sql").read_text(encoding="utf-8")
    assert "between 1 and 24" in sql_001
    assert (text_guard.NAME_MIN, text_guard.NAME_MAX) == (1, 24)

    sql_004 = (REPO / "database" / "004_profile_display.sql").read_text(encoding="utf-8")
    assert "char_length(signature) between 1 and 60" in sql_004
    assert text_guard.SIGNATURE_MAX == 60


# --- 头像清单 -----------------------------------------------------------------


def test_known_preset_is_accepted() -> None:
    assert avatar_catalog.check_avatar(avatar_catalog.default_avatar())
    assert avatar_catalog.check_frame(avatar_catalog.default_frame())


@pytest.mark.parametrize(
    "value, code",
    [
        ("preset:avatar_999", "unknown_id"),   # 格式合法但不存在
        ("upload:whatever", "upload_not_supported"),  # 功能没做就必须拒
        ("avatar_001", "format"),
        ("preset:超级限定", "format"),
    ],
)
def test_avatar_rejections(value: str, code: str) -> None:
    """**正则是格式检查，不是授权检查。**

    preset:avatar_999 这一条尤其重要：数据库的 avatar_format 完全放行它，
    只有这一层能挡。今天最坏结果是头像空白；等头像变成活动奖励，
    同一个洞就是白嫖限定头像。
    """
    with pytest.raises(avatar_catalog.AvatarRejected) as exc:
        avatar_catalog.check_avatar(value)
    assert exc.value.code == code


def test_catalog_sources_all_exist() -> None:
    """清单指向不存在的图，是这套 id 映射唯一会坏的方式。"""
    data = json.loads((REPO / "data" / "avatars.json").read_text(encoding="utf-8"))
    for entry in data["avatars"] + data["frames"]:
        rel = entry["source"].removeprefix("res://")
        assert (REPO / rel).exists(), "%s 指向不存在的图：%s" % (entry["id"], rel)


def test_catalog_ids_are_decoupled_from_unit_ids() -> None:
    """头像 id 必须是 avatar_NNN，**不能直接用单位 id**。

    用单位 id 的话，美术把 dark_dragon 重做改名成 dark_wyrm，
    所有选了这个头像的玩家会一起变空白 —— SaveSchema.PET_ID_RENAMES
    里那条 pet_duck -> pet_rabbit 就是同类事故留下的。
    """
    data = json.loads((REPO / "data" / "avatars.json").read_text(encoding="utf-8"))
    ids = [e["id"] for e in data["avatars"]]
    assert len(ids) == len(set(ids))
    for entry in data["avatars"]:
        assert re.fullmatch(r"avatar_\d{3}", entry["id"]), entry["id"]
        stem = pathlib.PurePosixPath(entry["source"]).stem
        assert entry["id"] != stem, "头像 id 不能等于单位 id：%s" % entry["id"]


# --- 迁移文件的静态一致性 -----------------------------------------------------


def test_friend_code_alphabet_matches_its_check_constraint() -> None:
    """好友码的字母表与 check 约束必须逐字符对应。

    这条挡的是一个已经发生过一次的错误：约束写成 [2-9A-HJ-NP-Z] 时会放进 L，
    而 L 正是字母表里被排掉的易混字符之一。两边各改各的，
    结果是「生成不出来、但手写能存进去」的码。
    """
    sql = (REPO / "database" / "004_profile_display.sql").read_text(encoding="utf-8")

    alphabet = re.search(r"alphabet constant text := '([^']+)'", sql).group(1)
    pattern = re.search(r"friend_code ~ '\^(\[[^\]]+\])\{8\}\$'", sql).group(1)
    rx = re.compile("^%s$" % pattern)

    assert len(alphabet) == len(set(alphabet)), "字母表里有重复字符"
    for ch in alphabet:
        assert rx.match(ch), "字母表里的 %r 会被 check 约束挡掉" % ch
    for ch in "0O1IL":
        assert not rx.match(ch), "易混字符 %r 不该被约束放行" % ch
    allowed = [chr(c) for c in range(0x30, 0x5B) if rx.match(chr(c))]
    assert set(allowed) == set(alphabet), "约束放行了字母表之外的字符"


def test_migration_does_not_touch_earlier_files() -> None:
    """004 只能加东西。改 001/002/003 的结构会让已经建过表的机器悄悄对不上。"""
    sql = (REPO / "database" / "004_profile_display.sql").read_text(encoding="utf-8")
    forbidden = ["drop table", "drop column", "alter column player_id", "drop constraint"]
    lowered = sql.lower()
    for phrase in forbidden:
        assert phrase not in lowered, "004 里出现了破坏性语句：%s" % phrase


# --- 部署一致性 ---------------------------------------------------------------


def test_deploy_ships_the_files_the_backend_reads() -> None:
    """后端从仓库根的 data/ 读文件，而部署脚本**只**同步 backend/ 和 deploy/。

    这两件事各自都是对的（运行目录少一份暴露面），合起来就是一个陷阱：
    代码在本机跑得好好的，上线之后第一个换头像的玩家拿到 500。
    第一次部署就踩了。以后再有「后端要读仓库根的某个文件」时，这条会把它挡住。
    """
    for script in ["update.sh", "bootstrap.sh"]:
        text = (REPO / "deploy" / script).read_text(encoding="utf-8")
        assert "avatars.json" in text, (
            "deploy/%s 没有把 data/avatars.json 复制到运行目录，"
            "avatar_catalog.py 上线后会读不到" % script
        )


def test_backend_only_reads_files_deploy_actually_copies() -> None:
    """反向锁：后端里每一处指向仓库根 data/ 的文件，部署脚本都要复制。"""
    import re as _re

    copied = set()
    for script in ["update.sh", "bootstrap.sh"]:
        copied |= set(
            _re.findall(r"[\w-]+\.(?:json|txt)", (REPO / "deploy" / script).read_text(encoding="utf-8"))
        )
    for module in ["avatar_catalog.py", "text_guard.py"]:
        source = (REPO / "backend" / "app" / module).read_text(encoding="utf-8")
        for name in _re.findall(r'"data"\s*/\s*"([^"]+)"', source):
            assert name in copied, (
                "backend/app/%s 要读 data/%s，但 deploy 的脚本没复制它" % (module, name)
            )


# --- 注销账号 -----------------------------------------------------------------


def test_every_table_referencing_players_cascades() -> None:
    """引用 players 的表**必须**带 on delete cascade。

    delete_player() 只发一句 `delete from players`，它成立的**全部前提**就是这条。
    哪天有人加一张新表引用 players 却忘了 cascade，注销会变成：
    玩家看到「账号已删除」，而他的数据还在那张新表里 —— 不报错、不回滚，
    只是没删干净。这正是最不该靠人记住的那类约束。
    """
    seen = 0
    for path in sorted((REPO / "database").glob("*.sql")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            stripped = line.strip().lower()
            # 注释里提到 references 不算
            if stripped.startswith("--") or "references players" not in stripped:
                continue
            seen += 1
            # 逐行判断而不是用正则跨行匹配：这个仓库里外键约束都写在一行上，
            # 真有人拆成多行的话这条会**大声地误报**，而不是悄悄漏掉一张表 ——
            # 对一条守着「删干净」的断言来说，宁可误报。
            assert "on delete cascade" in stripped, (
                "%s:%d 引用了 players(player_id) 却没有 on delete cascade，"
                "注销账号会漏掉这张表的数据" % (path.name, number)
            )
    assert seen >= 2, "没扫到引用 players 的外键 —— 这条断言可能已经失效"


def test_delete_route_is_registered() -> None:
    """注销接口必须真的挂上去了。

    路由文件写好了但忘了 include_router，表现是客户端拿到 404 而不是删除 ——
    而 404 在客户端那边和「玩家不存在」是同一个分支。
    """
    from app.main import app

    # 走 openapi() 而不是遍历 app.routes：这个 FastAPI 版本把 include_router
    # 进来的东西包成 _IncludedRouter，上面没有 .path，遍历出来是空的 ——
    # 第一版就是这么写的，结果断言在「路由明明注册了」的情况下失败。
    # schema 里的 paths 是客户端真正能看到的那份清单，才是权威。
    paths = app.openapi()["paths"]
    for expected in ["/v1/me/profile", "/v1/me/bio", "/v1/me/delete"]:
        assert expected in paths, "%s 没有注册" % expected
    assert "post" in paths["/v1/me/delete"], "/v1/me/delete 不接受 POST"


def test_delete_requires_friend_code_field() -> None:
    """确认载荷不能是可选的。

    如果 friend_code 有默认值，一个空 body 就能把号删了 ——
    而这个接口没有撤销。
    """
    from app.routes.profile import DeleteRequest

    assert DeleteRequest.model_fields["friend_code"].is_required()
