"""Steam 沙盒充值走一遍：不经过游戏，走真的建单 → 扣款 → 入账代码（docs/充值系统设计.md 第八节）。

**在账号服务器那台机器上跑**（要用那里的 backend.env 和数据库）：

    sudo /opt/glory/venv/bin/python /opt/glory/repo/deploy/check_iap_steam.py \\
        --friend-code ABCD2345 --steam-id 7656119XXXXXXXXXX --ip 你电脑的公网IP

  --friend-code  钻石进哪个游戏号（游戏资料页上的好友码）
  --steam-id     付款的 Steam 测试账号。🔴 **必须在 GLORY_STEAM_SANDBOX_STEAM_IDS 里，不在就直接退出** ——
                 这个脚本绝不下真钱的单
  --ip           你打开网址那台电脑的公网 IP（浏览器打开 https://api.ipify.org 就能看到）。Steam 对浏览器确认的单要求带上
  --product      档位，默认 diamond_pack_1

过程：
  1. 建一张单，在 Steam 沙盒里下单（浏览器确认那种），打印一个网址；
  2. 你在浏览器里用那个 Steam 测试账号登录、打开网址、点确认（沙盒，不扣钱）；
  3. 脚本每 5 秒问一次 Steam，看到批准就扣款（沙盒）、入账，打印这张单和那个号的余额、流水。
     等满 --wait 秒（默认 600）还没确认就把单取消。

入的是**测试单**：钻石进赠送列、流水名目 iap_test、不占首充资格，算进「每个号 24 小时测试单上限」
（GLORY_IAP_TEST_ORDERS_PER_DAY，默认 1；超了这张会被取消）。充值开关关着也能跑。

验得出来：发行商密钥有没有微交易权限、App 能不能用微交易、沙盒流程通不通、我们的建单 → 扣款 → 入账 → 流水。
验不出来：游戏里的 overlay 弹不弹得出来（第 4 步）。
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
import time
import uuid
from pathlib import Path

ENV_FILE = Path("/opt/glory/backend.env")
BACKEND = Path("/opt/glory/repo/backend")


def load_env(path: Path) -> None:
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def report(ok: bool, name: str, detail: str) -> None:
    print(("PASS " if ok else "FAIL ") + name + " | " + detail, flush=True)


async def run(args: argparse.Namespace) -> int:
    from app import db, iap, iap_steam, shop
    from app.config import get_settings

    if args.steam_id not in iap.steam_sandbox_ids():
        report(False, "测试员名单", "%s 不在 GLORY_STEAM_SANDBOX_STEAM_IDS 里。这个脚本只下沙盒单，先把它加进 backend.env"
               % args.steam_id)
        return 1
    await db.connect(get_settings().database_url)
    if not db.is_connected():
        report(False, "数据库", "连不上（GLORY_DATABASE_URL 是空的？）")
        return 1
    try:
        async with db.pool().acquire() as conn:
            player = await conn.fetchval(
                "select player_id from players where friend_code = $1", args.friend_code.strip().upper())
        if player is None:
            report(False, "游戏号", "没有这个好友码：%s" % args.friend_code)
            return 1

        try:
            outcome, url = await iap_steam.begin_in_browser(
                player, uuid.uuid4(), args.product, args.steam_id, "en", args.ip, even_if_closed=True)
        except Exception as exc:  # noqa: BLE001 - 原样把原因打出来，这正是要验的
            report(False, "Steam 沙盒下单", "%s：%s" % (type(exc).__name__, exc))
            return 1
        order = outcome.order
        report(bool(url), "Steam 沙盒下单", "订单 #%d（%s %s）" % (order.order_no, order.price_currency, order.price_amount))
        if not url:
            return 1
        print("\n  用 Steam 测试账号 %s 在浏览器里打开下面这个网址，点确认（沙盒，不扣钱）：\n\n  %s\n" % (args.steam_id, url),
              flush=True)

        deadline = time.monotonic() + args.wait
        status = "Init"
        while time.monotonic() < deadline and status == "Init":
            await asyncio.sleep(5)
            status = (await iap_steam.query_txn(order.order_no, True)).status
        report(status != "Init", "玩家确认", "Steam 那边的状态：%s" % status)
        if status == "Init":
            await iap.cancel(order.order_id, "check_script_timeout")
            print("等了 %d 秒还没确认，这张单已取消。" % args.wait)
            return 1

        fresh = await iap.order_by_id(order.order_id)
        settled = await iap_steam.settle(fresh)
        done = settled.order
        report(done.status == "credited", "扣款并入账",
               "状态 %s，环境 %s，付费列 +%d，赠送列 +%d%s" % (
                   done.status, done.environment, done.diamond_paid, done.diamond_free,
                   "（%s）" % done.note if done.note else ""))
        async with db.pool().acquire() as conn:
            rows = await conn.fetch(
                "select currency, delta, balance_after, source from wallet_ledger where order_id = $1 order by id",
                done.order_id)
            wallet = await shop.read_wallet_in(conn, player)
        for row in rows:
            print("  流水  %-13s %+6d  余额 %d  名目 %s" % (row["currency"], row["delta"], row["balance_after"], row["source"]))
        print("  这个号现在：钻石 %d（付费 %d / 赠送 %d / 欠账 %d）" % (
            wallet.diamond, wallet.diamond_paid, wallet.diamond_free, wallet.diamond_debt))
        ok = done.status == "credited" and done.environment == iap.SANDBOX and all(r["source"] == "iap_test" for r in rows)
        report(ok, "记成测试单", "沙盒单必须进赠送列、名目 iap_test")
        return 0 if ok else 1
    finally:
        await db.disconnect()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--friend-code", required=True)
    parser.add_argument("--steam-id", required=True)
    parser.add_argument("--ip", required=True)
    parser.add_argument("--product", default="diamond_pack_1")
    parser.add_argument("--wait", type=int, default=600)
    args = parser.parse_args()
    load_env(ENV_FILE)
    sys.path.insert(0, str(BACKEND))
    return asyncio.run(run(args))


if __name__ == "__main__":
    sys.exit(main())
