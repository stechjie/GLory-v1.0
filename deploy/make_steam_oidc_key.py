"""生成 Steam 登录的签名私钥（backend/app/steam_oidc.py，docs/三方登录设计.md 第八节）。

一般不用手动跑：deploy/update.sh 发现没有这把钥匙时会自动调它。手动跑：

    sudo /opt/glory/venv/bin/python /opt/glory/repo/deploy/make_steam_oidc_key.py \\
        /opt/glory/steam_oidc_key.pem --owner glory

生成 EC P-256 私钥，权限 600、属主改成 --owner（后端以这个用户跑）。
公钥不用单独发给谁：账号服务器自己在 /oidc/steam/jwks.json 公开，Supabase 去那里取。

## 私钥

**不进 git、不贴进聊天、不发给任何人。** 谁拿到它谁就能冒充任意 Steam 玩家登录。

## 可以重新生成吗

**可以**，加 --force。身份证明是签完当场就交给 Supabase 用掉的，换钥匙不影响任何已登录的人；
Supabase 遇到不认识的钥匙编号会重新取公钥。默认拒绝覆盖已有文件。
"""

from __future__ import annotations

import argparse
import os
import pathlib
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description="生成 Steam 登录的签名私钥")
    parser.add_argument("path", help="私钥写到哪里，例如 /opt/glory/steam_oidc_key.pem")
    parser.add_argument("--owner", default="", help="私钥文件的属主（后端的运行用户，生产上是 glory）")
    parser.add_argument("--force", action="store_true", help="覆盖已有的私钥（= 轮换）")
    args = parser.parse_args()

    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    path = pathlib.Path(args.path)
    if path.exists() and not args.force:
        print("✗ %s 已经存在。要换钥匙请加 --force（不影响已登录的人）。" % path, file=sys.stderr)
        return 1
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption())
    path.parent.mkdir(parents=True, exist_ok=True)
    # 先建成 600 再写内容：不留「内容已写、权限还是 644」的空档。
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as out:
        out.write(pem)
    os.chmod(path, 0o600)
    if args.owner:
        import pwd

        entry = pwd.getpwnam(args.owner)
        os.chown(path, entry.pw_uid, entry.pw_gid)
    print("✓ 已生成 %s" % path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
