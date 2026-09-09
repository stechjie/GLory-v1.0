"""交友系统的行为用例。

这里**不连数据库** —— 判据全是纯函数、静态一致性与路由接线，所以能在任何机器上跑。
需要真库的部分（并发下的好友数上限、交叉请求的主键裁决、每日配额的滑窗）
归真机/线上验证 —— 同 test_profile.py 的分工。

最重要的两组：

  1. **配额与上限的判据必须在数据库层**（friend_request_log / count + 事务），
     不能落回 app/rate_limit.py。那是进程内窗口，重启即清零、多 worker 各算各的。
  2. **「一段关系一行」这个不变量由表结构保证**，不是靠代码自觉。
     破了不会报错，只会表现为「他的列表里有我，我的列表里没他」。

跑（必须从 backend/ 目录，pytest.ini 在那里）：
    cd backend && .venv/Scripts/python -m pytest -q tests/test_friends.py
"""

from __future__ import annotations

import datetime as dt
import pathlib
import re
import uuid

import pytest

from app import friends, presence
from app.main import app
from app.routes.friends import _STATUS_BY_CODE, _norm

REPO = pathlib.Path(__file__).resolve().parents[2]
SQL_005 = (REPO / "database" / "005_friends.sql").read_text(encoding="utf-8")
SQL_006 = (REPO / "database" / "006_room_visits.sql").read_text(encoding="utf-8")

NEW_TABLES = (
    "player_friendships",
    "player_blocks",
    "friend_request_log",
    "player_presence",
)


# --- canonical 排序 -----------------------------------------------------------


def test_pair_is_order_independent() -> None:
    """(a, b) 和 (b, a) 必须得到同一个 key。

    这是 005 那张表的全部前提：一段关系一行。如果 _pair 不稳定，
    同一对玩家会插出两行（low/high 互换），而两行不一致正是
    「他有我、我没他」那个静默 bug。
    """
    a, b = uuid.uuid4(), uuid.uuid4()
    assert friends._pair(a, b) == friends._pair(b, a)
    low, high = friends._pair(a, b)
    assert low < high


def test_pair_matches_the_check_constraint() -> None:
    """_pair 的输出必须满足 SQL 里那条 low_id < high_id。

    两边各改各的话，插入会被约束挡下来，但错误信息完全看不出是排序问题。
    """
    assert "check (low_id < high_id)" in SQL_005
    for _ in range(50):
        low, high = friends._pair(uuid.uuid4(), uuid.uuid4())
        assert low < high


# --- 在线判定 -----------------------------------------------------------------


def _ago(seconds: float) -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=seconds)


def test_ttl_must_exceed_heartbeat_interval() -> None:
    """TTL 必须大于心跳间隔，否则丢一个包就显示离线。

    这条写成断言而不是注释，是因为两个常量分开改时不会有任何症状 ——
    只会让在线状态开始闪烁，而那看起来像网络问题。
    """
    assert friends.PRESENCE_TTL.total_seconds() > friends.HEARTBEAT_INTERVAL_SEC
    # 至少要能容忍丢一次心跳，否则等于没有余量。
    assert friends.PRESENCE_TTL.total_seconds() >= friends.HEARTBEAT_INTERVAL_SEC * 2


def test_fresh_heartbeat_is_online() -> None:
    assert friends._online(_ago(5), "friends") is True


def test_stale_heartbeat_is_offline() -> None:
    stale = friends.PRESENCE_TTL.total_seconds() + 1
    assert friends._online(_ago(stale), "friends") is False


def test_never_seen_is_offline() -> None:
    """从没上报过心跳的玩家 presence 行不存在，last_seen 是 None。

    好友列表用 left join 就是为了不把这些人整个弄丢 —— 他们只是离线。
    """
    assert friends._online(None, "friends") is False


def test_hidden_presence_is_offline_to_friends() -> None:
    """隐身 = 对好友也显示离线。没有「半隐身」这一档。"""
    assert friends._online(_ago(1), "nobody") is False


def test_presence_visibility_values_match_the_database() -> None:
    """Python 的白名单与 SQL 的 check 约束必须一致。

    两边漂了不会报错：Python 放行的值会被数据库拒收，
    表现是「设置保存失败」而日志里只有一条约束违反。
    """
    for column in ("presence_visibility", "room_visibility"):
        pattern = r"check \(%s\s+in \(([^)]+)\)\)" % column
        match = re.search(pattern, SQL_005)
        assert match, "SQL 里找不到 %s 的 check 约束" % column
        allowed = set(re.findall(r"'([a-z]+)'", match.group(1)))
        assert allowed == presence.VISIBILITIES, "%s 的取值两边不一致" % column


def test_presence_has_no_public_tier() -> None:
    """已确认：在线状态**只对好友可见**，没有 'public' 档。

    留着文本枚举是为了以后加档位时不用写迁移（同 004），
    但现在不许有 public —— 加了就等于默认把行为轨迹公开。
    """
    assert "public" not in presence.VISIBILITIES


# --- 产品决策被钉在结构上 -----------------------------------------------------


def test_no_rejected_status_exists() -> None:
    """已确认：拒绝 = 删记录，不留 'rejected'。

    留 rejected 的话误拒的人永远加不回来。这条决定要么写进 check 约束、
    要么迟早有人顺手加回来。
    """
    match = re.search(r"check \(status in \(([^)]+)\)\)", SQL_005)
    assert match, "找不到 status 的 check 约束"
    assert set(re.findall(r"'(\w+)'", match.group(1))) == {"pending", "accepted"}


def test_quota_has_its_own_log_table() -> None:
    """「拒绝就删记录」的直接代价：配额没有可数的东西了，必须单开日志表。

    漏掉它的症状是配额永远数出 0 —— 代码看起来是写了的，
    但任何人都能无限重发请求，而且不报错。
    """
    assert "create table friend_request_log" in SQL_005
    assert "friend_request_log" in (REPO / "backend" / "app" / "friends.py").read_text(
        encoding="utf-8"
    )


def test_quota_is_not_delegated_to_the_in_process_limiter() -> None:
    """配额判据不能落回 app/rate_limit.py（进程内、重启清零、多 worker 各算各的）。

    friends.py 里出现 rate_limit 就说明有人把业务配额挪回去了。
    心跳那种「防刷接口」的限流在 routes/presence.py，不在这里。
    """
    import ast

    tree = ast.parse((REPO / "backend" / "app" / "friends.py").read_text(encoding="utf-8"))
    # 用 AST 而不是字符串匹配：friends.py 的注释里**故意**提到 rate_limit
    # （就是那条"不要用它"的说明）。按字符串判会把注释当成违规，
    # 于是这条门禁的第一反应是被人删掉 —— 假红和假绿一样有害。
    imported: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.update(a.name.split(".")[0] for a in node.names)
        elif isinstance(node, ast.ImportFrom):
            imported.update(a.name for a in node.names)
            if node.module:
                imported.add(node.module.split(".")[0])
    assert "rate_limit" not in imported, "friends.py 不该 import rate_limit"


def test_friend_limit_is_one_hundred() -> None:
    assert friends.MAX_FRIENDS == 100


# --- 数据库硬规则 -------------------------------------------------------------


@pytest.mark.parametrize("table", NEW_TABLES)
def test_every_new_table_enables_rls(table: str) -> None:
    """database/README.md 的硬规则：所有表一律开 RLS 且默认零 policy。

    漏一张就是通过 Data API 谁都能读 —— 而 Supabase 建项目时
    `Automatically expose new tables` 的默认值恰好是开着的。
    """
    assert "alter table %s enable row level security" % table in SQL_005
    assert "create policy" not in SQL_005


@pytest.mark.parametrize("table", NEW_TABLES)
def test_new_tables_are_registered_for_schema_inspection(table: str) -> None:
    """db.EXPECTED_TABLES 必须包含新表。

    它是 /v1/debug/schema 的判据 —— 漏登记就等于那张表的 RLS 状态没人检查，
    而这正是 db.py 里那句注释警告的事。**这条差点被漏掉过。**
    """
    from app import db

    assert table in db.EXPECTED_TABLES


def test_migration_only_adds_tables() -> None:
    """005 不许改动 001–004 建的东西。编号只增不改（database/README.md）。

    alter table 出现在这个文件里就是危险信号：本批次只加新表。
    """
    assert "alter table" in SQL_005  # enable row level security 用的
    for line in SQL_005.splitlines():
        stripped = line.strip()
        if stripped.startswith("alter table"):
            assert "enable row level security" in stripped, (
                "005 只应通过 alter table 开 RLS，不应修改既有表：%s" % stripped
            )


# --- 最近一起玩过（批次 3）---------------------------------------------------


def test_room_visits_table_is_registered_and_locked_down() -> None:
    from app import db

    assert "player_room_visits" in db.EXPECTED_TABLES
    assert "alter table player_room_visits enable row level security" in SQL_006
    assert "create policy" not in SQL_006


def test_room_visits_migration_only_adds_a_table() -> None:
    """006 不许改动 001–005 建的东西。编号只增不改。"""
    for line in SQL_006.splitlines():
        stripped = line.strip()
        if stripped.startswith("alter table"):
            assert "enable row level security" in stripped, stripped


def test_recent_players_requires_both_sides() -> None:
    """🔴 「最近同玩」的关联必须是**双向**的。

    这条是整个批次 3 唯一的防伪造机制：只有两边都留下访问记录、
    且时间窗重叠才算。改成单边匹配的话，谎报房间号就能把自己塞进
    陌生人的列表 = 定向骚扰入口 —— 而且不会报错。

    所以判据钉在 SQL 上：必须 join 到 my_visits、必须比时间区间、
    必须排掉自己。
    """
    sql = friends._RECENT_PLAYERS
    assert "join my_visits m" in sql, "关联必须 join 到我自己的访问记录（双向要求）"
    assert "tstzrange" in sql and "&&" in sql, "必须比较时间区间是否重叠"
    assert "v.player_id <> $1" in sql, "必须排掉自己"


@pytest.mark.parametrize(
    "must_exclude, why",
    [
        ("player_friendships", "已经是好友或有待处理请求的人不该再出现在加人列表里"),
        ("player_blocks", "互相拉黑的人绝不能出现"),
        ("presence_visibility", "设了隐身的人不该还能从这里被翻出来"),
    ],
)
def test_recent_players_excludes(must_exclude: str, why: str) -> None:
    assert must_exclude in friends._RECENT_PLAYERS, why


def test_recent_players_has_bounds() -> None:
    """响应体必须有上界，时间窗必须有限 —— 否则「最近」会翻到开服第一天。"""
    assert "limit $3" in friends._RECENT_PLAYERS
    assert friends.RECENT_LIMIT <= 50
    assert 1 <= friends.RECENT_WINDOW_DAYS <= 30


def test_left_at_null_is_treated_as_still_inside() -> None:
    """未闭合的访问记录（客户端崩溃/被杀）必须当成「还在里面」。

    查询里少一处 coalesce，那些记录就会被整个漏掉 ——
    表现是「明明一起打了一局，列表里没有他」，而且不报错。
    """
    assert friends._RECENT_PLAYERS.count("coalesce(") >= 3


# --- 路由接线 -----------------------------------------------------------------


EXPECTED_ROUTES = {
    "/v1/me/friends": {"get"},
    "/v1/me/friends/requests": {"get", "post"},
    "/v1/me/friends/requests/{code}": {"delete"},
    "/v1/me/friends/requests/{code}/accept": {"post"},
    "/v1/me/friends/{code}": {"delete"},
    "/v1/me/recent-players": {"get"},
    "/v1/me/blocks": {"get", "post"},
    "/v1/me/blocks/{code}": {"delete"},
    "/v1/me/presence": {"put"},
    "/v1/me/presence/visibility": {"get", "put"},
}


def test_all_routes_are_registered() -> None:
    paths = app.openapi()["paths"]
    for path, methods in EXPECTED_ROUTES.items():
        assert path in paths, "路由没注册：%s" % path
        assert set(paths[path]) >= methods, "%s 缺方法：%s" % (path, methods - set(paths[path]))


def test_no_endpoint_returns_a_top_level_array() -> None:
    """任何接口都不许返回顶层 JSON 数组。

    **这不是风格问题，是一个静默失效**：客户端的 AccountManager._request
    解析响应体时只接受 Dictionary（`typeof(json.data) == TYPE_DICTIONARY`），
    顶层数组会被丢成 `{}` —— 好友列表变成空，不报错、不崩溃。

    顺带也保住了扩展性：顶层数组以后要加分页/总数就得破坏性改接口。
    """
    paths = app.openapi()["paths"]
    offenders = []
    for path, methods in paths.items():
        for method, spec in methods.items():
            for status, resp in (spec.get("responses") or {}).items():
                schema = ((resp.get("content") or {}).get("application/json") or {}).get(
                    "schema"
                ) or {}
                if schema.get("type") == "array":
                    offenders.append("%s %s -> %s" % (method.upper(), path, status))
    assert not offenders, "这些接口返回顶层数组，客户端会静默收到空：%s" % offenders


def test_every_rejection_code_has_a_status() -> None:
    """friends.py 里 raise 的每一个 code 都必须在 _STATUS_BY_CODE 里登记。

    漏登记的会静默落到 400。对「配额超了」这种应当是 429 的情况，
    客户端就没法区分「我填错了」和「我发太多了」—— 而这不会报错。
    """
    source = (REPO / "backend" / "app" / "friends.py").read_text(encoding="utf-8")
    raised = set(re.findall(r'FriendsRejected\(\s*"(\w+)"', source))
    assert raised, "没扫到任何 FriendsRejected，正则可能过期了"
    missing = raised - set(_STATUS_BY_CODE)
    assert not missing, "这些拒绝码没登记状态码：%s" % sorted(missing)


def test_status_map_has_no_dead_entries() -> None:
    """反过来：登记了但没人 raise 的条目要删掉，否则这张表会烂掉。"""
    source = (REPO / "backend" / "app" / "friends.py").read_text(encoding="utf-8")
    raised = set(re.findall(r'FriendsRejected\(\s*"(\w+)"', source))
    # bad_friend_code 由路由层的长度校验产生，不经过 FriendsRejected。
    dead = set(_STATUS_BY_CODE) - raised - {"bad_friend_code"}
    assert not dead, "这些条目已经没人用了：%s" % sorted(dead)


# --- 公开视图上的关系字段 -----------------------------------------------------


def test_optional_claims_returns_none_without_header() -> None:
    """没有 Authorization 头 = 匿名，不是错误。

    这个接口是**公开视图**，身份只是增强。
    """
    import asyncio

    from app.routes.me import optional_claims

    assert asyncio.run(optional_claims(None)) is None
    assert asyncio.run(optional_claims("")) is None


@pytest.mark.parametrize(
    "header", ["Basic abc", "Bearer", "Bearer ", "garbage", "bearer"]
)
def test_optional_claims_returns_none_for_malformed_header(header: str) -> None:
    """畸形的头一律当匿名。**不抛异常、不 401。**"""
    import asyncio

    from app.routes.me import optional_claims

    assert asyncio.run(optional_claims(header)) is None


def test_optional_claims_never_raises() -> None:
    """静态断言：optional_claims 里不许有 raise。

    它的全部价值就是「永不抛异常」—— 一旦有人往里加一个 raise，
    带着过期令牌的玩家点开别人资料页会看到整页失败，
    而那看起来完全不像是这个函数造成的。

    用 AST 而不是读文档：注释会过期，这条不会。
    """
    import ast

    tree = ast.parse((REPO / "backend" / "app" / "routes" / "me.py").read_text(
        encoding="utf-8"))
    target = None
    for node in ast.walk(tree):
        if isinstance(node, ast.AsyncFunctionDef) and node.name == "optional_claims":
            target = node
    assert target is not None, "找不到 optional_claims —— 测试的锚点过期了"
    raises = [n for n in ast.walk(target) if isinstance(n, ast.Raise)]
    assert not raises, "optional_claims 里出现了 raise，它必须永不抛异常"


def test_anonymous_public_view_has_no_relation_key() -> None:
    """匿名调用者拿不到 relation 键 —— 不是「有键但为 null」。

    与 docs/玩家资料系统设计.md 第六节第 1 条同一条纪律：
    裁剪在服务端做，隐藏的字段连键都不出现。
    """
    from app.routes.profile import PublicProfileResponse

    body = PublicProfileResponse(
        friend_code="7K2M9Q4B", player_name="Leno", avatar="preset:avatar_001",
        avatar_frame="preset:frame_default", days_since_created=1,
    ).model_dump(exclude_none=True)
    assert "relation" not in body


def test_relation_values_match_between_backend_and_response_model() -> None:
    """friends.relation_to 返回的取值必须与响应模型注释里列的那一组一致。

    两边漂了不报错：客户端按注释写 if/else，遇到没列出的值就走到 else，
    于是按钮显示成「加好友」——而对方其实已经是好友了。
    """
    import ast

    source = (REPO / "backend" / "app" / "friends.py").read_text(encoding="utf-8")
    tree = ast.parse(source)
    target = None
    for node in ast.walk(tree):
        if isinstance(node, ast.AsyncFunctionDef) and node.name == "relation_to":
            target = node
    assert target is not None
    # 只走「返回值分支」，不进条件表达式。
    #
    # 两个坑都踩过：直接看 Return.value 会漏掉三元表达式返回的
    # pending_out / pending_in；而无脑 ast.walk(Return) 又会把条件里的
    # row["requested_by"] 那个字典键也收进来。所以要显式递归 IfExp 的
    # body / orelse，跳过 test。
    def value_strings(node: ast.AST) -> set[str]:
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return {node.value}
        if isinstance(node, ast.IfExp):
            return value_strings(node.body) | value_strings(node.orelse)
        return set()

    returned: set[str] = set()
    for node in ast.walk(target):
        if isinstance(node, ast.Return) and node.value is not None:
            returned |= value_strings(node.value)
    documented = {"none", "pending_out", "pending_in", "friends", "blocked", "self"}
    assert returned == documented, "relation_to 的取值与文档不一致：%s" % sorted(returned)


# --- 好友码归一 ---------------------------------------------------------------


@pytest.mark.parametrize("raw", ["7k2m9q4b", " 7K2M9Q4B ", "7K2m9Q4b"])
def test_friend_code_is_case_and_space_insensitive(raw: str) -> None:
    """玩家会照着截图手抄，不该因为按了大写锁或多打一个空格失败。库里一律大写（004）。"""
    assert _norm(raw) == "7K2M9Q4B"
