"""Steam 登录第 0 步验证：Supabase 认不认账号服务器自己签的 Steam 身份证明（docs/三方登录设计.md 第八节）。

**在账号服务器那台机器上跑**（要用那里的私钥和 backend.env），不需要 Steam：

    sudo /opt/glory/venv/bin/python /opt/glory/repo/deploy/check_steam_oidc.py

前提：update.sh 已经跑过（有私钥、有签发方地址），Supabase 里已经登记了自定义提供方 custom:steam。

用假的 SteamID（glorytest-随机串）验：公开地址能取到、用证明登录会建号、再登一次回到同一个号、
同一个 Steam 绑第二个号会被拒，以及「游客号绑 Steam」要带哪种假邮箱 Supabase 才收（10-23 第 3 项的后续）。**跑完自动删掉这次建的测试用户**（只删它自己建的那几个），
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

    def sign_in(subject: str, jwt: str | None = None, email: str = "") -> tuple[int, dict]:
        body = {"provider": PROVIDER, "id_token": steam_oidc.mint(subject, name="Glory Test", email=email)}
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

        # 3. 游客号（没有邮箱）绑 Steam。不带邮箱时 Supabase 会拿空串回填邮箱、报 email_address_invalid
        #    （10-23 实测），所以试两种「收不到信、但格式合法」的假邮箱，看它收哪一种。
        host = iss.split("//", 1)[1].split("/", 1)[0]
        guest_for_conflict = None
        accepted: list[str] = []
        variants = [
            ("3a. 不带邮箱（已知会失败，看 Supabase 修没修）", lambda sub: ""),
            ("3b. 假邮箱用自己的域名", lambda sub: f"steam-{sub}@{host}"),
            ("3c. 假邮箱用保留域名 .invalid", lambda sub: f"steam-{sub}@steam.invalid"),
        ]
        for label, make_email in variants:
            st, guest = call("POST", "/auth/v1/signup", {})
            if st != 200:
                report(False, label, f"建游客号失败 HTTP {st} {err(guest)}")
                continue
            uid_g = note(guest)
            sub = "glorytest-" + secrets.token_hex(6)
            email = make_email(sub)
            st, linked = sign_in(sub, guest["access_token"], email)
            user = linked.get("user") or {}
            ok = st == 200 and str(user.get("id")) == uid_g and PROVIDER in providers_of(linked)
            if not email:
                # 只是记录现状：失败是预期的，不算没过。
                print(("INFO " if not ok else "NOTE ") + label + " | " +
                      (f"HTTP {st} {err(linked)}" if not ok else "居然成功了：Supabase 可能已经修了这个毛病"), flush=True)
                continue
            # 两种写法是在「试」：收一种就够，不收的那种不算没过，只记下来。
            ok = ok and user.get("is_anonymous") is False
            if ok:
                accepted.append(email.split("@", 1)[1])
                guest_for_conflict = guest_for_conflict or linked
            print(("OK   " if ok else "NO   ") + label + " | HTTP " + str(st) + " " +
                  (f"编号不变，邮箱 {user.get('email')}，is_anonymous={user.get('is_anonymous')}" if ok else err(linked)),
                  flush=True)
        report(bool(accepted), "3. 游客号能绑 Steam（至少收一种假邮箱）", f"Supabase 收的域名：{accepted or '一个都不收'}")

        # 3d. 已经有邮箱的号（相当于绑过 Google 的手机号）绑一个不带邮箱的 Steam → 应该直接成功
        st, owner = sign_in("glorytest-" + secrets.token_hex(6), None, f"steam-owner-{secrets.token_hex(4)}@{host}")
        if st == 200:
            note(owner)
            st, linked = sign_in(b_sub, owner["access_token"])
            same = st == 200 and str((linked.get("user") or {}).get("id")) == str(owner["user"]["id"])
            report(same, "3d. 有邮箱的号绑不带邮箱的 Steam", f"HTTP {st} " + ("编号不变" if same else err(linked)))
        else:
            report(False, "3d. 有邮箱的号绑不带邮箱的 Steam", f"建号失败 HTTP {st} {err(owner)}")

        # 4. 已经属于 A 的 Steam 再绑到别的号 → 必须被拒
        target = guest_for_conflict or (owner if owner.get("access_token") else None)
        if target is None:
            report(False, "4. 冲突被拒", "前面没有一个能用的号，测不了")
            return 1
        st, conflict = sign_in(a_sub, target["access_token"])
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
