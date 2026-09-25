"""网页运营后台（docs/运营后台设计.md，database/018_admin.sql）的行为用例。

分两半：
  · 接口层（登录两步、会话、防跨站、页面）—— 不连数据库，Supabase 用 MockTransport 顶替；
  · 业务层（审批、发钱、邮件、封号、公告、操作记录）—— 真 PostgreSQL（没设 GLORY_TEST_PG 就跳过）。

最要紧的几条，它们的失败模式都**不会报错**：
  1. 自己不能批自己；两个人同时点批准只执行一次；连点提交只建一条申请。
  2. 批准那一刻才执行，执行失败记成 failed —— 不能卡在 pending，也不能「批了没发」。
  3. 玩家的令牌进不了后台；没带 X-Glory-Admin 头的写请求一律拒绝。
  4. 操作记录只能追加。
"""

from __future__ import annotations

import asyncio
import base64
import json
import pathlib
import re
import uuid

import asyncpg
import httpx
import pytest
from fastapi.testclient import TestClient

from app import admin, admin_auth, bans, db, shop
from app.admin_auth import Admin
from app.config import get_settings
from app.main import app
from app.supabase_auth import SupabaseAdminAuth
from pg_harness import new_player, requires_pg, run_with_db

REPO = pathlib.Path(__file__).resolve().parents[2]
ADMIN_UID = uuid.UUID("aaaaaaaa-0000-0000-0000-000000000001")
SOLD = [i.grants for i in shop.items()]


def _jwt(claims: dict) -> str:
    body = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return "e30." + body + ".sig"


class FakeGoTrue:
    """刚好够用的 Supabase Auth：邮箱密码、绑验证器、出题、验码。"""

    def __init__(self, has_factor: bool) -> None:
        self.has_factor = has_factor
        self.deleted: list[str] = []
        self.enrolled = False

    def handler(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path == "/auth/v1/token":
            body = json.loads(request.content)
            if (body["email"], body["password"]) != ("ops@glory.test", "right"):
                return httpx.Response(400, json={"error_code": "invalid_credentials"})
            factors = [{"id": "old-half", "factor_type": "totp", "status": "unverified"}]
            if self.has_factor:
                factors.append({"id": "f1", "factor_type": "totp", "status": "verified"})
            return httpx.Response(200, json={"access_token": _jwt({"aal": "aal1"}),
                                             "user": {"id": str(ADMIN_UID), "factors": factors}})
        if request.method == "DELETE" and path.startswith("/auth/v1/factors/"):
            self.deleted.append(path.rsplit("/", 1)[1])
            return httpx.Response(200, json={})
        if path == "/auth/v1/factors":
            self.enrolled = True
            return httpx.Response(200, json={"id": "f1", "totp": {"qr_code": "data:image/svg+xml;utf-8,<svg/>",
                                                                   "secret": "SECRET"}})
        if path == "/auth/v1/factors/f1/challenge":
            return httpx.Response(200, json={"id": "c1"})
        if path == "/auth/v1/factors/f1/verify":
            if json.loads(request.content)["code"] != "123456":
                return httpx.Response(422, json={"error_code": "mfa_verification_failed"})
            return httpx.Response(200, json={"access_token": _jwt({"aal": "aal2"})})
        return httpx.Response(404)


@pytest.fixture
def web(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("GLORY_SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("GLORY_SUPABASE_PUBLISHABLE_KEY", "pk_test")
    monkeypatch.setenv("GLORY_DATABASE_URL", "")
    monkeypatch.setenv("GLORY_ENVIRONMENT", "dev")
    get_settings.cache_clear()
    admin_auth.reset()
    monkeypatch.setattr(db, "is_connected", lambda: True)
    roster = {ADMIN_UID: "alice"}

    async def roster_name(uid):
        return roster.get(uid)

    monkeypatch.setattr(admin_auth, "roster_name", roster_name)
    gotrue = FakeGoTrue(has_factor=True)
    monkeypatch.setattr(admin_auth, "auth_client", lambda: SupabaseAdminAuth(
        "https://example.supabase.co", "pk_test", httpx.MockTransport(gotrue.handler)))
    # 登录限流是模块级的；每个用例一个新的，互不影响。
    monkeypatch.setattr(admin_auth, "_login_limiter", admin_auth.SlidingWindowLimiter(100, 900.0))
    yield TestClient(app), gotrue, roster
    admin_auth.reset()
    get_settings.cache_clear()


def _login(client: TestClient) -> None:
    r = client.post("/admin/api/login", json={"email": "ops@glory.test", "password": "right"})
    assert r.status_code == 200, r.text
    r = client.post("/admin/api/login/code", json={"code": "123456"})
    assert r.status_code == 200, r.text


# --- 登录 🔴 ----------------------------------------------------------------------


def test_login_needs_password_then_authenticator_code(web) -> None:
    client, _gotrue, _roster = web
    assert client.get("/admin/api/me").status_code == 401
    r = client.post("/admin/api/login", json={"email": "ops@glory.test", "password": "right"})
    assert r.json() == {"step": "code"}
    # 只过了第一步：还不算登录。
    assert client.get("/admin/api/me").status_code == 401
    assert client.post("/admin/api/login/code", json={"code": "000000"}).status_code == 401
    assert client.post("/admin/api/login/code", json={"code": "123456"}).json() == {"name": "alice"}
    assert client.get("/admin/api/me").json() == {"name": "alice", "environment": "dev"}


def test_first_login_enrolls_an_authenticator_and_clears_half_done_ones(web, monkeypatch) -> None:
    client, gotrue, _roster = web
    gotrue.has_factor = False
    r = client.post("/admin/api/login", json={"email": "ops@glory.test", "password": "right"})
    assert r.json()["step"] == "enroll"
    assert r.json()["qr_code"].startswith("data:image/svg+xml")
    assert gotrue.deleted == ["old-half"] and gotrue.enrolled
    assert client.post("/admin/api/login/code", json={"code": "123456"}).status_code == 200


def test_wrong_password_and_non_admins_get_the_same_answer(web) -> None:
    """不在名单里的人和密码错的人看到同一句话：不透露这个邮箱是不是管理员。"""
    client, _gotrue, roster = web
    wrong = client.post("/admin/api/login", json={"email": "ops@glory.test", "password": "nope"})
    roster.clear()
    outsider = client.post("/admin/api/login", json={"email": "ops@glory.test", "password": "right"})
    assert wrong.status_code == outsider.status_code == 401
    assert wrong.json() == outsider.json()


def test_deactivated_admin_is_out_on_the_next_request(web) -> None:
    client, _gotrue, roster = web
    _login(client)
    assert client.get("/admin/api/me").status_code == 200
    roster.clear()
    assert client.get("/admin/api/me").status_code == 401
    roster[ADMIN_UID] = "alice"
    assert client.get("/admin/api/me").status_code == 401, "停用过的会话恢复名单后也不能复活"


def test_player_tokens_cannot_reach_the_admin_api(web) -> None:
    client, _gotrue, _roster = web
    r = client.get("/admin/api/me", headers={"Authorization": "Bearer some-player-token"})
    assert r.status_code == 401


def test_writes_need_the_admin_header(web, monkeypatch) -> None:
    """★ 别的网站的页面发不出带自定义头的跨站请求；没这个头的写请求一律拒。"""
    client, _gotrue, _roster = web
    _login(client)
    called = []

    async def fake_ban(*args):
        called.append(args)
        return {"ban_id": 1, "kicked": False}

    monkeypatch.setattr(admin, "ban", fake_ban)
    url = "/admin/api/players/%s/ban" % uuid.uuid4()
    body = {"days": 1, "reason": "外挂"}
    assert client.post(url, json=body).status_code == 403
    assert called == []
    assert client.post(url, json=body, headers={"X-Glory-Admin": "1"}).status_code == 200
    assert len(called) == 1 and called[0][0] == Admin(ADMIN_UID, "alice")


def test_session_cookie_is_httponly_strict_and_scoped(web) -> None:
    client, _gotrue, _roster = web
    client.post("/admin/api/login", json={"email": "ops@glory.test", "password": "right"})
    r = client.post("/admin/api/login/code", json={"code": "123456"})
    cookie = [v for k, v in r.headers.multi_items() if k == "set-cookie" and v.startswith("glory_admin=")][0]
    assert "HttpOnly" in cookie and "SameSite=strict" in cookie and "Path=/admin" in cookie


def test_production_cookies_are_secure(monkeypatch) -> None:
    monkeypatch.setenv("GLORY_ENVIRONMENT", "prod")
    get_settings.cache_clear()
    try:
        assert admin_auth.cookie_kwargs()["secure"] is True
    finally:
        get_settings.cache_clear()


def test_business_rejections_come_back_as_readable_errors(web, monkeypatch) -> None:
    client, _gotrue, _roster = web
    _login(client)

    async def refuse(*_args):
        raise admin.AdminRejected("自己不能批自己的申请，要另一个管理员来批", 403)

    monkeypatch.setattr(admin, "decide", refuse)
    r = client.post("/admin/api/requests/7/approve", json={}, headers={"X-Glory-Admin": "1"})
    assert r.status_code == 403 and "自己不能批自己" in r.json()["detail"]


# --- 页面 -------------------------------------------------------------------------


def test_page_is_served_with_a_strict_content_policy(web) -> None:
    client, _gotrue, _roster = web
    r = client.get("/admin/")
    assert r.status_code == 200 and "admin.js" in r.text
    csp = r.headers["content-security-policy"]
    assert "script-src 'self'" in csp and "frame-ancestors 'none'" in csp
    assert client.get("/admin/static/admin.js").status_code == 200
    assert client.get("/admin/static/..%2Fapp%2Fconfig.py").status_code == 404
    assert client.get("/admin/static/index.html").status_code == 404


def test_page_never_writes_server_text_as_html() -> None:
    """★ 昵称、标题、原因都是别人填的字。拼进 innerHTML 就是现成的脚本注入口。"""
    source = (REPO / "backend" / "admin_web" / "admin.js").read_text(encoding="utf-8")
    js = "\n".join(line for line in source.splitlines() if not line.strip().startswith("//"))
    assert "innerHTML" not in js and "outerHTML" not in js and "insertAdjacentHTML" not in js
    assert "eval(" not in js and "new Function" not in js
    html = (REPO / "backend" / "admin_web" / "index.html").read_text(encoding="utf-8")
    assert "<script>" not in html, "内联脚本会被 CSP 挡掉，也不该有"


# --- 传图到 Storage -------------------------------------------------------------------


def _png_bytes() -> bytes:
    from PIL import Image
    import io

    buffer = io.BytesIO()
    Image.new("RGB", (640, 320), (40, 90, 160)).save(buffer, format="PNG")
    return buffer.getvalue()


@pytest.mark.parametrize("key,expect_auth", [("sb_secret_abc", False), ("eyJhbGciOi.legacy.jwt", True)])
def test_image_upload_uses_the_right_header_for_each_key_style(monkeypatch, key, expect_auth) -> None:
    monkeypatch.setenv("GLORY_SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("GLORY_SUPABASE_SECRET_KEY", key)
    get_settings.cache_clear()
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"Key": "announcements/x"})

    async def no_audit(*_a, **_k):
        return None

    class _Pool:
        def acquire(self):
            class _A:
                async def __aenter__(self):
                    return None

                async def __aexit__(self, *exc):
                    return False
            return _A()

    monkeypatch.setattr(db, "pool", lambda: _Pool())
    monkeypatch.setattr(admin, "_audit", no_audit)
    try:
        out = asyncio.run(admin.upload_announcement_image(Admin(ADMIN_UID, "alice"), _png_bytes(),
                                                          transport=httpx.MockTransport(handler)))
    finally:
        get_settings.cache_clear()
    assert re.fullmatch(r"admin/\d{4}-\d{2}/[0-9a-f]{24}\.png", out["path"])
    request = seen[0]
    assert request.url.path == "/storage/v1/object/announcements/" + out["path"]
    assert request.headers["apikey"] == key
    assert ("authorization" in request.headers) is expect_auth
    assert request.headers["x-upsert"] == "false"


def test_storage_unreachable_is_a_readable_error_not_a_500(monkeypatch) -> None:
    monkeypatch.setenv("GLORY_SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("GLORY_SUPABASE_SECRET_KEY", "sb_secret_abc")
    get_settings.cache_clear()

    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("down", request=request)

    try:
        with pytest.raises(admin.AdminRejected) as exc:
            asyncio.run(admin.upload_announcement_image(Admin(ADMIN_UID, "alice"), _png_bytes(),
                                                        transport=httpx.MockTransport(handler)))
    finally:
        get_settings.cache_clear()
    assert exc.value.status == 502 and "连不上 Storage" in exc.value.message


def test_supabase_unreachable_at_login_is_a_readable_error(web, monkeypatch) -> None:
    client, _gotrue, _roster = web

    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("down", request=request)

    monkeypatch.setattr(admin_auth, "auth_client", lambda: SupabaseAdminAuth(
        "https://example.supabase.co", "pk_test", httpx.MockTransport(handler)))
    r = client.post("/admin/api/login", json={"email": "ops@glory.test", "password": "right"})
    assert r.status_code == 502 and "连不上 Supabase" in r.json()["detail"]


def test_bad_images_are_refused_before_anything_is_uploaded(monkeypatch) -> None:
    with pytest.raises(admin.AdminRejected) as exc:
        asyncio.run(admin.upload_announcement_image(Admin(ADMIN_UID, "alice"), b"GIF89a....."))
    assert "PNG" in exc.value.message


# --- 真库：审批与发钱 🔴 ----------------------------------------------------------------

ALICE = Admin(uuid.uuid4(), "alice")
BOB = Admin(uuid.uuid4(), "bob")


async def _audit_actions(conn: asyncpg.Connection) -> list[tuple[str, str, bool]]:
    rows = await conn.fetch("select admin_name, action, ok from admin_audit order by audit_id")
    return [(r["admin_name"], r["action"], r["ok"]) for r in rows]


@requires_pg
def test_grant_needs_someone_else_to_approve_and_then_pays_once() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
        key = uuid.uuid4()
        req = await admin.request_grant(ALICE, "grant_diamonds", p, 500, "掉单补偿", key)
        assert req["status"] == "pending" and "500 钻石" in req["summary"]
        # 连点两次提交：同一条。
        again = await admin.request_grant(ALICE, "grant_diamonds", p, 500, "掉单补偿", key)
        assert again["request_id"] == req["request_id"] and again["replayed"]
        # 自己不能批自己。
        with pytest.raises(admin.AdminRejected) as exc:
            await admin.decide(ALICE, req["request_id"], True, "")
        assert exc.value.status == 403
        async with db.pool().acquire() as conn:
            assert (await shop.read_wallet_in(conn, p)).diamond_free == 0
        # 另一个人批：当场到账，流水写着两个人的名字。
        done = await admin.decide(BOB, req["request_id"], True, "核对过工单")
        assert done["status"] == "done" and done["result"]["balance_after"] == 500
        with pytest.raises(admin.AdminRejected) as exc:
            await admin.decide(BOB, req["request_id"], True, "")
        assert exc.value.status == 409
        async with db.pool().acquire() as conn:
            wallet = await shop.read_wallet_in(conn, p)
            assert (wallet.diamond_paid, wallet.diamond_free) == (0, 500)
            ledger = await conn.fetchrow("select source, actor, note from wallet_ledger where player_id = $1", p)
            assert ledger["source"] == "grant" and ledger["actor"] == "alice/bob"
            assert ledger["note"].startswith("后台#%d" % req["request_id"])
            assert await _audit_actions(conn) == [("alice", "request.create", True),
                                                  ("bob", "request.approve", True)]

    run_with_db(body)


@requires_pg
def test_two_approvers_at_once_execute_once() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
        req = await admin.request_grant(ALICE, "grant_coin", p, 70, "活动", uuid.uuid4())
        carol = Admin(uuid.uuid4(), "carol")
        results = await asyncio.gather(admin.decide(BOB, req["request_id"], True, ""),
                                       admin.decide(carol, req["request_id"], True, ""),
                                       return_exceptions=True)
        assert sum(1 for r in results if isinstance(r, dict)) == 1
        assert sum(1 for r in results if isinstance(r, admin.AdminRejected)) == 1
        async with db.pool().acquire() as conn:
            assert (await shop.read_wallet_in(conn, p)).coin == 70
            assert await conn.fetchval("select count(*) from wallet_ledger where player_id = $1", p) == 1

    run_with_db(body)


@requires_pg
def test_failed_execution_is_recorded_not_left_pending() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
        req = await admin.request_grant(ALICE, "grant_diamonds", p, 5, "x", uuid.uuid4())
        async with db.pool().acquire() as conn:
            # 模拟「申请之后、批准之前」数据出了问题：发放函数会拒绝。
            await conn.execute("delete from players where player_id = $1", p)
        with pytest.raises(admin.AdminRejected) as exc:
            await admin.decide(BOB, req["request_id"], True, "")
        assert "执行失败" in exc.value.message
        async with db.pool().acquire() as conn:
            row = await conn.fetchrow("select status, decided_by, result from admin_requests")
            assert row["status"] == "failed" and row["decided_by"] == "bob"
            assert "没有这个玩家" in json.loads(row["result"])["error"]
            assert (await _audit_actions(conn))[-1] == ("bob", "request.approve", False)

    run_with_db(body)


@requires_pg
def test_limits_reject_typos_before_anything_is_saved() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
        for kind, amount in [("grant_diamonds", 0), ("grant_diamonds", 100_001), ("grant_coin", -1)]:
            with pytest.raises(admin.AdminRejected):
                await admin.request_grant(ALICE, kind, p, amount, "x", uuid.uuid4())
        with pytest.raises(admin.AdminRejected):
            await admin.request_grant(ALICE, "grant_diamonds", p, 5, "  ", uuid.uuid4())
        async with db.pool().acquire() as conn:
            assert await conn.fetchval("select count(*) from admin_requests") == 0

    run_with_db(body)


@requires_pg
def test_cancel_only_by_the_requester() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
        req = await admin.request_grant(ALICE, "grant_diamonds", p, 5, "x", uuid.uuid4())
        with pytest.raises(admin.AdminRejected):
            await admin.cancel(BOB, req["request_id"])
        assert (await admin.cancel(ALICE, req["request_id"]))["status"] == "cancelled"
        with pytest.raises(admin.AdminRejected):
            await admin.decide(BOB, req["request_id"], True, "")

    run_with_db(body)


# --- 真库：邮件 ---------------------------------------------------------------------


def _draft(to: str, **kw) -> admin.MailDraft:
    base = dict(to=to, title_zh="补偿", body_zh="正文", title_en="", body_en="", diamond=0, coin=0,
                items=(), days=30, include_new_players=False, note="")
    base.update(kw)
    return admin.MailDraft(**base)


@requires_pg
def test_plain_mail_goes_out_now_and_paid_mail_waits_for_approval() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn, created_days_ago=1)
        plain = await admin.submit_mail(ALICE, _draft(str(p)), uuid.uuid4())
        assert plain["queued"] is False
        paid = await admin.submit_mail(ALICE, _draft("all", diamond=100, items=tuple(SOLD[:1]), note="开服补偿"),
                                       uuid.uuid4())
        assert paid["queued"] is True and paid["status"] == "pending"
        async with db.pool().acquire() as conn:
            assert await conn.fetchval("select count(*) from mails") == 1
        done = await admin.decide(BOB, paid["request_id"], True, "")
        async with db.pool().acquire() as conn:
            row = await conn.fetchrow("select player_id, diamond, items, actor, note from mails where mail_id = $1",
                                      done["result"]["mail_id"])
            assert row["player_id"] is None and row["diamond"] == 100 and list(row["items"]) == SOLD[:1]
            assert row["actor"] == "alice/bob"
        recent = await admin.recent_mails()
        assert [m["mail_id"] for m in recent] == [done["result"]["mail_id"], plain["mail_id"]]
        out = await admin.withdraw_mail(ALICE, plain["mail_id"])
        assert out["already_claimed"] == 0
        with pytest.raises(admin.AdminRejected):
            await admin.withdraw_mail(ALICE, plain["mail_id"])

    run_with_db(body)


@requires_pg
def test_mail_rules_are_checked_up_front() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
        bad = [
            _draft("all", diamond=5, include_new_players=True, note="x"),   # 带奖励给以后的新玩家：总量无上限
            _draft(str(p), include_new_players=True),                        # 单人邮件不该有这个开关
            _draft(str(p), items=("preset:avatar_001",)),                    # 免费内容，发了等于没发
            _draft(str(p), diamond=5),                                        # 带附件没写原因
            _draft(str(p), title_zh=" "),
        ]
        for draft in bad:
            with pytest.raises(admin.AdminRejected):
                await admin.submit_mail(ALICE, draft, uuid.uuid4())
        async with db.pool().acquire() as conn:
            assert await conn.fetchval("select count(*) from mails") == 0
            assert await conn.fetchval("select count(*) from admin_requests") == 0

    run_with_db(body)


# --- 真库：封号、找人、公告、操作记录 ------------------------------------------------------


@requires_pg
def test_admin_ban_and_unban_go_through_the_sql_functions(monkeypatch) -> None:
    kicked: list[uuid.UUID] = []

    async def fake_kick(pid):
        kicked.append(pid)
        return True

    monkeypatch.setattr(bans, "kick_now", fake_kick)

    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
        out = await admin.ban(ALICE, p, 7, "外挂", "举报 #3")
        assert out["kicked"] and kicked == [p]
        detail = await admin.player_detail(p)
        assert detail["ban"]["reason"] == "外挂" and detail["bans"][0]["actor"] == "alice"
        assert (await admin.unban(BOB, p, "误封"))["revoked"] == 1
        with pytest.raises(admin.AdminRejected):
            await admin.unban(BOB, p, "")
        detail = await admin.player_detail(p)
        assert detail["ban"] is None and detail["bans"][0]["revoked_by"] == "bob"
        assert [a["action"] for a in detail["audit"]] == ["unban", "ban"]

    run_with_db(body)


@requires_pg
def test_search_is_exact_for_codes_and_ids_and_escapes_name_wildcards() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            a = await new_player(conn)
            b = await new_player(conn)
            await conn.execute("update players set player_name = '100%胜率' where player_id = $1", a)
            await conn.execute("update players set player_name = '100分' where player_id = $1", b)
            code = await conn.fetchval("select friend_code from players where player_id = $1", a)
        assert [r["player_id"] for r in await admin.search_players(code.lower())] == [str(a)]
        assert [r["player_id"] for r in await admin.search_players(str(b))] == [str(b)]
        assert [r["player_id"] for r in await admin.search_players("100%")] == [str(a)]
        assert len(await admin.search_players("100")) == 2

    run_with_db(body)


@requires_pg
def test_announcement_save_detects_a_concurrent_edit() -> None:
    async def body() -> None:
        fields = {"kind": "news", "status": "draft", "title_zh": "维护通知", "starts_at": "2026-09-24T20:00:00+08:00"}
        created = await admin.save_announcement(ALICE, None, fields, None, False)
        row = (await admin.list_announcements())[0]
        await admin.save_announcement(ALICE, created["announcement_id"], {**fields, "title_zh": "改一"},
                                      row["version"], False)
        with pytest.raises(admin.AdminRejected) as exc:
            await admin.save_announcement(BOB, created["announcement_id"], {**fields, "title_zh": "改二"},
                                          row["version"], True)
        assert exc.value.status == 409
        fresh = (await admin.list_announcements())[0]
        bumped = await admin.save_announcement(BOB, created["announcement_id"], {**fields, "status": "published"},
                                               fresh["version"], True)
        assert bumped["revision"] == 2
        with pytest.raises(admin.AdminRejected):
            await admin.save_announcement(ALICE, None, {**fields, "starts_at": "2026-09-24T20:00:00"}, None, False)

    run_with_db(body)


@requires_pg
def test_audit_log_is_append_only() -> None:
    async def body() -> None:
        async with db.pool().acquire() as conn:
            p = await new_player(conn)
        await admin.request_grant(ALICE, "grant_diamonds", p, 5, "x", uuid.uuid4())
        async with db.pool().acquire() as conn:
            for sql in ("update admin_audit set ok = false", "delete from admin_audit", "truncate admin_audit"):
                with pytest.raises(asyncpg.RaiseError):
                    await conn.execute(sql)
            assert await conn.fetchval("select count(*) from admin_audit") == 1
        assert (await admin.recent_audit())[0]["action"] == "request.create"

    run_with_db(body)


@requires_pg
def test_add_admin_by_email_looks_up_the_supabase_user() -> None:
    """加管理员只填邮箱：函数去 Supabase 的 auth.users 换成 UID。本机没有 auth 这个 schema，建一个最小的替身。"""

    async def body() -> None:
        uid = uuid.uuid4()
        async with db.pool().acquire() as conn:
            await conn.execute("create schema auth; create table auth.users (id uuid primary key, email text)")
            await conn.execute("insert into auth.users (id, email) values ($1, 'Ops@Glory.test')", uid)
            assert await conn.fetchval("select add_admin(' ops@glory.test ', 'arvin')") == uid
            assert await admin_auth.roster_name(uid) == "arvin"
            with pytest.raises(asyncpg.RaiseError):
                await conn.fetchval("select add_admin('nobody@glory.test', 'x')")
            # 停用后再加一次 = 重新启用。
            await conn.execute("update admin_users set active = false")
            assert await admin_auth.roster_name(uid) is None
            await conn.fetchval("select add_admin('ops@glory.test', 'arvin')")
            assert await admin_auth.roster_name(uid) == "arvin"
            assert await conn.fetchval("select count(*) from admin_users") == 1

    run_with_db(body)
