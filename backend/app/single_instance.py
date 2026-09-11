"""单实例断言。

**这个文件存在的唯一理由是 WebSocket 连接表在进程内存里。**

② 在加 WebSocket 之前是完全无状态的：每个请求独立，随便哪个 worker 处理都行，
想加并发就 `--workers N`。加了 WebSocket 之后不行 —— 服务器必须记住
「哪条连接属于哪个玩家」，而那张表活在进程内存里。

开两个 worker 的后果：A 进程上的玩家发消息，B 进程上的玩家**收不到**。
不报错、不掉线、日志里什么都没有，就是收不到。

这与 `app/rate_limit.py` 注释里那个坑是同一个根因（进程内状态），
但后果完全不在一个量级：

| | 多进程之后的表现 |
|---|---|
| `rate_limit` | 额度翻倍。软失败，能忍 |
| WS 连接表 | **消息投递不到**。硬失败，且只在扩容那天才暴露 |

所以这里**主动让第二个进程起不来**，而不是靠人记得别加 worker ——
这类错误的代价是静默的，靠记性挡不住。见 `docs/聊天系统设计.md` 第二节。

## 为什么是抢端口，不是读配置

uvicorn 的 `--workers N` 会 fork 出 N 个子进程，而**子进程看不到这个 N**：
没有对应的环境变量，`sys.argv` 是主进程的。所以「读一下配置里写了几个 worker」
这条路根本走不通 —— 那正是最容易想到、也最容易写出**假保护**的做法
（写了，看着像挡住了，实际上永远返回 1）。

抢一个只监听回环的端口则是真的互斥：第二个进程 bind 会拿到 EADDRINUSE，
无论它是 fork 出来的、是手工再起的一份、还是同一台机器上另一个部署。

## 已知的取舍，两条都要知道

1. **端口被无关程序占用时会误判成「已有实例」。** 错误消息里把两种可能都写了，
   否则排查的人会盯着"另一个实例"找半天，而机器上根本没有第二个。
2. **它挡不住「两台机器各跑一个实例」。** 那种情况需要的是跨实例路由
   （Redis pub/sub 或粘性会话），本文件挡的是**同机误配**，不是分布式部署。
   真要扩到多机时，删掉它不是解法 —— 先把路由做了。
"""

from __future__ import annotations

import logging
import socket

log = logging.getLogger("glory.single_instance")

# 只监听回环，不对外暴露任何东西。它不是服务，是一把锁。
_LOOPBACK = "127.0.0.1"


class SingleInstanceError(RuntimeError):
    """已经有一个实例在跑（或者那个端口被别的程序占了）。"""


def claim(port: int) -> socket.socket:
    """抢占单实例令牌。成功返回 socket，**调用方必须一直持有它**。

    socket 被 GC 掉就等于把锁放了，下一个进程会照常起来 —— 这个 bug
    不会有任何症状，直到有人加了 worker 才暴露。所以返回值要挂在
    应用状态上活到进程结束，不能写成 `claim(port)` 就扔。
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    # ⛔ **绝不要设 SO_REUSEADDR。**
    #
    # 那个选项在两个平台上的语义不一样：Linux 上它只影响 TIME_WAIT 的旧连接，
    # 而 **Windows 上它允许直接绑到一个已经被别人监听的端口**。
    # 设了它，这把锁在开发机（Windows）上会静默失效 —— 两个进程都 bind 成功、
    # 都以为自己是唯一实例，而这正是本文件要挡的那件事。
    #
    # 不设的话两个平台行为一致：端口被占就 bind 失败。
    try:
        sock.bind((_LOOPBACK, port))
        sock.listen(1)
    except OSError as exc:
        sock.close()
        raise SingleInstanceError(
            f"拿不到单实例令牌（{_LOOPBACK}:{port}）：{exc}。\n"
            "两种可能，都要排查：\n"
            "  1. 已经有一个 glory 后端在跑（最常见的是 uvicorn --workers 开了 >1，"
            "或者上一次没退干净）。WebSocket 的连接表在进程内存里，"
            "多开一个进程就会让一部分玩家收不到消息，所以这里直接拒绝启动。\n"
            f"  2. {port} 被一个完全无关的程序占了。换一个端口："
            "环境变量 GLORY_INSTANCE_LOCK_PORT。"
        ) from None
    log.info("单实例令牌已持有：%s:%d", _LOOPBACK, port)
    return sock


def release(sock: socket.socket | None) -> None:
    """还锁。进程正常退出时调用；崩溃时由操作系统回收，不用兜底。"""
    if sock is None:
        return
    try:
        sock.close()
    except OSError:
        # 关一个已经坏掉的 socket 不值得让关停流程失败。
        log.warning("释放单实例令牌时出错，忽略", exc_info=True)
