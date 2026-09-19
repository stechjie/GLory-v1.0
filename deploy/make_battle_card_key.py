"""生成出战名片的签名密钥对（docs/商城系统设计.md 第五节）。

在**账号服务器那台机器**上跑（要用后端 venv 里的 cryptography）：

    sudo /opt/glory/venv/bin/python /opt/glory/repo/deploy/make_battle_card_key.py \\
        /opt/glory/battle_card_key.pem --owner glory

它做三件事：

1. 生成 RSA-2048 密钥对
2. 私钥写到你给的路径，权限 600、属主改成 --owner（后端以这个用户跑）
3. 公钥写到同一个目录的 battle_card_public.pem（公钥不用保密，权限 644），并打印出来

公钥要送到**战斗服务器**上 —— 放法见 deploy/BATTLE_SERVER_KEY.md 的「出战名片公钥」一节。
公钥不进仓库、不进 APK（手机从不验章），所以换钥匙**不用重发 APK**。

## 私钥

**不进 git、不贴进聊天、不发给任何人。** 它只该存在于账号服务器上这一个文件里。
谁拿到它，谁就能签发任意内容的名片 —— 给自己发没买过的宠物。

## 可以重新生成吗

**可以**，这是轮换。代价：旧公钥签出的名片在新公钥下验不过，
已经签出去、还没用掉的名片（最多一个有效期，60 秒）作废。
步骤：这里加 --force 重跑 → 重启账号服务器 → 新公钥换到战斗服务器上 → 重启战斗服务器。
两边换好之前的那几分钟，新开的对局会失败（玩家看到「暂时进不了对局」），已经在打的不受影响。

这和战斗服务器那把 DTLS 私钥**不是一回事** —— 那把绝不能重生成
（deploy/BATTLE_SERVER_KEY.md），重生成等于所有已发出去的客户端立刻连不上。

默认拒绝覆盖已有的密钥文件；确实要轮换就加 --force。
"""

from __future__ import annotations

import argparse
import os
import pathlib
import sys

# 与 scripts/multiplayer/BattleCard.gd 的 DEFAULT_KEY_PATH 同名。
PUBLIC_NAME = "battle_card_public.pem"


def main() -> int:
    parser = argparse.ArgumentParser(description="生成出战名片的签名密钥对")
    parser.add_argument("path", help="私钥写到哪里，例如 /opt/glory/battle_card_key.pem")
    parser.add_argument("--owner", default="", help="私钥文件的属主（后端的运行用户，生产上是 glory）")
    parser.add_argument("--force", action="store_true", help="覆盖已有的私钥（= 轮换密钥）")
    args = parser.parse_args()

    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    path = pathlib.Path(args.path)
    if path.exists() and not args.force:
        print("✗ %s 已经存在。要轮换密钥请加 --force（旧名片会作废，战斗服务器要换上新公钥再重启；不用重发 APK）。"
              % path, file=sys.stderr)
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
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    fd = os.open(path, flags, 0o600)
    try:
        os.write(fd, private_pem)
    finally:
        os.close(fd)
    os.chmod(path, 0o600)

    # 公钥就放在私钥旁边，文件名就是战斗服务器要的那个名字，下载下来直接传过去即可。
    public_path = path.parent / PUBLIC_NAME
    public_path.write_text(public_pem, encoding="ascii")
    os.chmod(public_path, 0o644)

    if args.owner:
        import pwd  # 只有 Linux 有；放这里是为了这个文件在开发机上也能被导入检查

        try:
            entry = pwd.getpwnam(args.owner)
        except KeyError:
            print("✗ 系统里没有用户 %s。私钥已写入，但属主没改 —— 后端可能读不到它。"
                  % args.owner, file=sys.stderr)
            return 1
        os.chown(path, entry.pw_uid, entry.pw_gid)

    print("✓ 私钥已写入 %s（权限 600%s）" % (path, "，属主 %s" % args.owner if args.owner else ""))
    print("✓ 公钥已写入 %s" % public_path)
    print()
    print("下一步：")
    print("  1. 重启账号服务器：sudo systemctl restart glory-backend")
    print("  2. 把 %s 放到战斗服务器上（deploy/BATTLE_SERVER_KEY.md「出战名片公钥」），" % public_path)
    print("     然后重启战斗服务器")
    print()
    print(public_pem)
    return 0


if __name__ == "__main__":
    sys.exit(main())
