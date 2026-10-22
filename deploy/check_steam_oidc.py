"""Steam 登录第 0 步验证：Supabase 认不认账号服务器自己签的 Steam 身份证明（docs/三方登录设计.md 第八节）。

**在账号服务器那台机器上跑**（要用那里的私钥和 backend.env），不需要 Steam：

    sudo /opt/glory/venv/bin/python /opt/glory/repo/deploy/check_steam_oidc.py

前提：update.sh 已经跑过（有私钥、有签发方地址），Supabase 里已经登记了自定义提供方 custom:steam。

用假的 SteamID（glorytest-随机串）验五件事：公开地址能取到、用证明登录会建号、再登一次回到同一个号、
游客号能绑上、同一个 Steam 绑第二个号会被拒。**跑完自动删掉这次建的测试用户**（只删它自己建的那几个），
也不碰游戏数据库 —— 全程只和 Supabase 的登录服务打交道，游戏里不会多出玩家。
"""

from __future__ import annotations

import os
import secrets
import sys
from pathlib import Path

ENV_FILE = Path("/opt/glory/backend.env")
BACKEND = Path("/opt/glory/repo/backend")
PROVIDER = "custom:steam"


def load_env(path: Path) -> None:
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def main() -> int:
    load_env(ENV_FILE)
    sys.path.insert(0, str(BACKEND))
    import httpx

    from app import steam_oidc
    from app.config import get_settings

    s = get_settings()
    base = s.supabase_url.rstrip("/")
    pub = s.supabase_publishable_key
    secret = s.supabase_secret_key.strip()
    failures = 0
    created: list[str] = []

    def report(ok: bool, name: str, detail: str) -> None:
        nonlocal failures
        failures += 0 if ok else 1
        print(("PASS " if ok else "FAIL ") + name + " | " + detail, flush=True)

    def call(method: str, path: str, body: dict | None = None, jwt: str | None = None) -> tuple[int, dict]:
        headers = {"apikey": pub, "Authorization": f"Bearer {jwt or pub}"}
        resp = httpx.request(method, base + path, headers=headers, json=body, timeout=15)
        try:
            return resp.status_code, resp.json()
        except ValueError:
            return resp.status_code, {"msg": resp.text[:200]}

    def err(body: dict) -> str:
        return f"{body.get('error_code') or body.get('code') or ''} {str(body.get('msg') or body.get('message') or '')[:160]}"

    def sign_in(subject: str, jwt: str | None = None) -> tuple[int, dict]:
        body = {"provider": PROVIDER, "id_token": steam_oidc.mint(subject, name="Glory Test")}
        if jwt:
            body["link_identity"] = True
        return call("POST", "/auth/v1/token?grant_type=id_token", body, jwt)

    def providers_of(session: dict) -> list[str]:
        _, me = call("GET", "/auth/v1/user", jwt=session.get("access_token", ""))
        return [str(i.get("provider")) for i in me.get("identities") or []]

    def note(session: dict) -> str:
        uid = str((session.get("user") or {}).get("id", ""))
        if uid and uid not in created:
            created.append(uid)
        return uid

    try:
        # 0. Supabase 要能从公网取到说明文件和公钥。
        iss = steam_oidc.issuer()
        disc = httpx.get(f"{iss}/.well-known/openid-configuration", timeout=15)
        keys = httpx.get(f"{iss}/jwks.json", timeout=15)
        report(disc.status_code == 200 and disc.json().get("issuer") == iss and keys.status_code == 200
               and keys.json()["keys"][0]["kid"] == steam_oidc.signing_key().kid,
               "0. 公开地址", f"{iss} 说明 HTTP {disc.status_code}，公钥 HTTP {keys.status_code}")

        a_sub = "glorytest-" + secrets.token_hex(6)
        b_sub = "glorytest-" + secrets.token_hex(6)

        # 1. 用 Steam 证明登录 → 建一个新号
        st, a = sign_in(a_sub)
        if st != 200:
            report(False, "1. 用 Steam 证明登录", f"HTTP {st} {err(a)}")
            return 1
        uid_a = note(a)
        report(PROVIDER in providers_of(a), "1. 用 Steam 证明登录", f"建出 {uid_a}，登录方式 {providers_of(a)}")

        # 2. 同一个 Steam 再登一次 → 同一个号
        st, again = sign_in(a_sub)
        uid = note(again) if st == 200 else ""
        report(st == 200 and uid == uid_a, "2. 再登一次回到同一个号", f"HTTP {st} 得到 {uid or err(again)}")

        # 3. 游客号绑一个新的 Steam → 编号不变
        st, guest = call("POST", "/auth/v1/signup", {})
        if st != 200:
            report(False, "3. 游客号绑 Steam", f"建游客号失败 HTTP {st} {err(guest)}")
            return 1
        uid_b = note(guest)
        st, linked = sign_in(b_sub, guest["access_token"])
        ok = st == 200 and str((linked.get("user") or {}).get("id")) == uid_b
        report(ok and PROVIDER in providers_of(linked), "3. 游客号绑 Steam",
               f"HTTP {st} {('编号不变，登录方式 %s' % providers_of(linked)) if ok else err(linked)}")

        # 4. 已经属于 A 的 Steam 再绑到 B → 必须被拒
        st, conflict = sign_in(a_sub, (linked if st == 200 else guest)["access_token"])
        report(st != 200 and conflict.get("error_code") == "identity_already_exists", "4. 冲突被拒",
               f"HTTP {st} {err(conflict) if st != 200 else '居然成功了'}")
    finally:
        # 只删这次自己建的测试用户（要 secret key，和注销账号用的是同一个管理接口）。
        for uid in created:
            headers = {"apikey": secret}
            if not secret.startswith("sb_"):
                headers["Authorization"] = f"Bearer {secret}"
            resp = httpx.delete(f"{base}/auth/v1/admin/users/{uid}", headers=headers, timeout=15)
            print(f"清理测试用户 {uid}：HTTP {resp.status_code}", flush=True)
    print("全部通过" if failures == 0 else f"{failures} 项没过", flush=True)
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
