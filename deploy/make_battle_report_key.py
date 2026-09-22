"""生成战报的签名密钥对（docs/排位系统设计.md 第七节）。

## 🔴 这个在**战斗服务器**那台机器上跑，不是账号服务器

和 make_battle_card_key.py **方向正好相反**，两个别搞混：

| | 私钥在哪 | 公钥在哪 | 谁签 | 谁验 |
|---|---|---|---|---|
| 出战名片 | 账号服务器 | 战斗服务器 | 账号服务器 | 战斗服务器 |
| **战报** | **战斗服务器** | **账号服务器** | **战斗服务器** | **账号服务器** |

战斗服务器是 Godot headless，没有 Python 环境，所以这个脚本在**任意**一台有
cryptography 的机器上跑都行 —— 但生成出来的**私钥要放到战斗服务器上**，
公钥放到账号服务器上。最省事的做法是在账号服务器上跑（那台有 venv），
然后把私钥拷到战斗服务器、**立刻从账号服务器上删掉**。

    sudo /opt/glory/venv/bin/python /opt/glory/repo/deploy/make_battle_report_key.py \\
        /tmp/battle_report_key.pem

它做三件事：

1. 生成 RSA-2048 密钥对
2. 私钥写到你给的路径，权限 600、属主改成 --owner（不给就是当前用户）
3. 公钥写到同一个目录的 battle_report_public.pem（权限 644），并打印出来

## 私钥

**不进 git、不贴进聊天、不发给任何人。** 谁拿到它，谁就能签出任意内容的战报 ——
给自己造一整页赢来的对局历史（以后接了排位分，就是直接刷分）。

⚠️ **不要把它放进项目的 tools/ 目录** —— make_server_zip.ps1 会把整个 tools/
打进战斗服务器包，等于把私钥发给每一个拿到包的人。放 user:// 下或用
--battle-report-key= 指到包外面（见 scripts/multiplayer/BattleReport.gd）。

## 可以重新生成吗

**可以**，这是轮换，而且比名片那把更宽松：战报没有有效期，只是签发之后
一般几秒内就交上来了。步骤：这里加 --force 重跑 → 新私钥放到战斗服务器并重启
→ 新公钥放到账号服务器（不用重启，它按 mtime 热加载）。

两边换好之前那几分钟，交上来的战报会被拒（`report_bad_signature`），
**对局本身不受影响，只是那几局不记历史**。

这和战斗服务器那把 DTLS 私钥**不是一回事** —— 那把绝不能重生成
（deploy/BATTLE_SERVER_KEY.md），重生成等于所有已发出去的客户端立刻连不上。

默认拒绝覆盖已有的密钥文件；确实要轮换就加 --force。
"""

from __future__ import annotations

import argparse
import os
import pathlib
import sys

# 与 backend/app/config.py 的 battle_report_public_key_file 配套。
PUBLIC_NAME = "battle_report_public.pem"


def main() -> int:
    parser = argparse.ArgumentParser(description="生成战报的签名密钥对")
    parser.add_argument("path", help="私钥写到哪里。⚠️ 它要放到**战斗服务器**上")
    parser.add_argument("--owner", default="", help="私钥文件的属主")
    parser.add_argument("--force", action="store_true", help="覆盖已有的私钥（= 轮换密钥）")
    args = parser.parse_args()

    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    path = pathlib.Path(args.path)
    if path.exists() and not args.force:
        print("✗ %s 已经存在。要轮换密钥请加 --force（换好之前交上来的战报会被拒，"
              "对局不受影响、只是那几局不记历史）。" % path, file=sys.stderr)
        return 1

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    public_pem = key.public_key().public_bytes(
        serialization.Encoding.PEM,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode("ascii")

    # 先以 600 创建再写入，不给「写完再 chmod」留一个世界可读的窗口。
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, private_pem)
    finally:
        os.close(fd)
    os.chmod(path, 0o600)

    public_path = path.parent / PUBLIC_NAME
    public_path.write_text(public_pem, encoding="ascii")
    os.chmod(public_path, 0o644)

    if args.owner:
        import pwd  # 只有 Linux 有；放这里是为了这个文件在开发机上也能被导入检查

        try:
            entry = pwd.getpwnam(args.owner)
        except KeyError:
            print("✗ 系统里没有用户 %s。私钥已写入，但属主没改。" % args.owner, file=sys.stderr)
            return 1
        os.chown(path, entry.pw_uid, entry.pw_gid)

    print("✓ 私钥已写入 %s（权限 600%s）" % (path, "，属主 %s" % args.owner if args.owner else ""))
    print("✓ 公钥已写入 %s" % public_path)
    print()
    print("下一步（顺序要紧 —— 先战斗服务器，再账号服务器）：")
    print("  1. 把**私钥** %s 放到战斗服务器上，然后重启战斗服务器" % path)
    print("     （默认读 user://battle_report_key.pem，或用 --battle-report-key= 指定）")
    print("  2. 把**公钥** %s 放到账号服务器上，" % public_path)
    print("     在 glory-backend.service 里设 GLORY_BATTLE_REPORT_PUBLIC_KEY_FILE 指过去")
    print("     （公钥按 mtime 热加载，换文件即可，不用重启）")
    print("  3. 如果私钥是在账号服务器上生成的，**拷走之后立刻把它删掉**")
    print()
    print(public_pem)
    return 0


if __name__ == "__main__":
    sys.exit(main())
