#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""房间邀请门禁（tools/room_invite_check）的变异测试 —— 证明它真的会红。

本仓规矩（MEMORY / docs/CHECKS.md）：
  * 每条变异都要有**唯一命中**的锚点；命不中直接硬失败，绝不 SKIP
    （锚点找不到若被当 SKIP，变异测试会静默失效 —— 那比不做还糟）。
  * 改坏 → 跑门禁 → 期望 rc != 0 → 按 sha256 **逐字节还原** → 复跑确认全绿。
  * 文本断言必须是**注释感知**的：9.24 的坑就是「把调用点整行注释掉」时裸 contains 照样绿。
    下面 M5 专打这条。

## 第二轮（2026-09-27 晚）新增 M7 起（含 M9b）

用户回执：邀请在收件人那头是**普通文本、没有「立即参与」、出现两条重复**。
根因全在「客户端传了 kind，后端根本没读」这条链上（SendBody 没字段 / history 丢 kind /
send 返回丢 kind / routes 不转发），以及客户端把「已经邀请过了」弹给了玩家、
点击反馈排在限流判定之后。M7 起就是把这些**新加的判据**逐条打红。
"""
import hashlib
import os
import re
import subprocess
import sys

PROJ = r"C:\Users\WINDOWS\Desktop\GLory-work"
EXE = r"C:\Users\WINDOWS\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
GATE = "tools/room_invite_check.tscn"
ENV_PATH = r"C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem"

INVITE = os.path.join(PROJ, "scripts", "multiplayer", "RoomInvite.gd")
CHAT = os.path.join(PROJ, "scenes", "menu", "ChatScreen.gd")
LOBBY = os.path.join(PROJ, "scenes", "menu", "Team3v3Lobby.gd")
CHAT_PY = os.path.join(PROJ, "backend", "app", "chat.py")
ROUTES_PY = os.path.join(PROJ, "backend", "app", "routes", "chat.py")


def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def read(path):
    with open(path, "rb") as fh:
        return fh.read().decode("utf-8")


def write(path, text):
    with open(path, "wb") as fh:
        fh.write(text.encode("utf-8"))


def eol(text):
    return "\r\n" if "\r\n" in text else "\n"


def nl(text, *lines):
    return eol(text).join(lines)


def run_gate():
    env = dict(os.environ)
    env["PATH"] = ENV_PATH
    p = subprocess.run([EXE, "--headless", "--path", PROJ, GATE],
                       capture_output=True, timeout=300, env=env, cwd=PROJ)
    raw = (p.stdout + p.stderr).decode("utf-8", "replace")
    fails = re.findall(r"FAIL \[([^\]]+)\]", raw)
    return p.returncode, fails


# (名字, 文件, 旧锚点行[], 新锚点行[], 期望变红的失败码)
# 锚点一律写成**行数组**，由 nl() 按该文件的行尾拼 —— CRLF 仓里手写 \n 会命不中就硬失败。
MUTATIONS = [
    ("M1_expire_60s", INVITE,
     ["const EXPIRE_SEC := 20 * 60"],
     ["const EXPIRE_SEC := 60"],
     {"expire_const", "boundary_1199", "boundary_1200"}),

    ("M2_drop_left_room", INVITE,
     ["\tif inviter_room_id != UNKNOWN_ROOM and inviter_room_id != payload_room_id:"],
     ["\tif false and inviter_room_id != UNKNOWN_ROOM and inviter_room_id != payload_room_id:"],
     {"expired_left_room", "expired_left_all"}),

    ("M3_drop_duplicate", INVITE,
     ["\tif same_room_already_sent:"],
     ["\tif false and same_room_already_sent:"],
     {"block_duplicate"}),

    ("M4_drop_rate_limit", INVITE,
     ["\tif last_sent_sec > 0 and now_sec - last_sent_sec < RATE_LIMIT_SEC:"],
     ["\tif false and last_sent_sec > 0 and now_sec - last_sent_sec < RATE_LIMIT_SEC:"],
     {"block_rate_9s"}),

    # ★ 专打「注释掉调用点」：源码文本里 RoomInvite.is_invite(msg) 还在，只是被注释了。
    #   裸 contains 会照绿 —— 这条就是门禁必须做注释感知的理由。
    ("M5_comment_out_branch", CHAT,
     ["\tif RoomInvite.is_invite(msg):"],
     ["\t# if RoomInvite.is_invite(msg):"],
     {"chat_branch"}),

    ("M6_text_drift", INVITE,
     ['const TEXT_ZH := "我开启了新的房间，一起来玩吧"'],
     ['const TEXT_ZH := "我开启了新的房间"'],
     {"text_zh"}),

    # --- 第二轮：后端管道（用户实测的症状之源）--------------------------------

    # 邀请落库要 json.dumps(payload)、读出来要 json.loads —— 漏 import 就 NameError。
    # （删掉整行；注意不能用 "import json"->"import json5" 之类的改法：
    #  "import json5" 里照样含 "import json"，裸 contains 会照绿。）
    ("M7_no_json_import", CHAT_PY,
     ["import json", ""],
     [""],
     {"backend_json_import"}),

    # history 的 select 又把 kind/payload 丢掉 —— 收件人重进聊天就看不到邀请按钮。
    ("M8_history_drops_kind", CHAT_PY,
     ["            select message_id, sender_id, body, created_at, kind, payload from chat_messages"],
     ["            select message_id, sender_id, body, created_at from chat_messages"],
     {"backend_history_select"}),

    # SendBody 不认 kind —— 客户端传了也白传（本次实测的真 bug）。
    # 锚点必须带上**上一行注释**：`kind: str = "text"` 这个字面量在 MessageItem 里
    # 也有一份，单行锚点会命中 2 次（M9 第一版就是这么 ANCHOR_FAIL 的）；
    # 也正是这一撞，暴露出门禁原来的断言会被 MessageItem 顶上 —— 已改成类体内判定。
    ("M9_sendbody_no_kind", ROUTES_PY,
     ['    # text / room_invite。老客户端不传 → 默认 "text"，既有行为一个字都不变。',
      '    kind: str = "text"'],
     ['    # text / room_invite。老客户端不传 → 默认 "text"，既有行为一个字都不变。',
      "    kind: str = KIND_TEXT_DEFAULT"],
     {"backend_sendbody_kind"}),

    ("M9b_sendbody_no_payload", ROUTES_PY,
     ['    # 只有 room_invite 用（{"room_id": int}）。其余 kind 一律忽略 —— 见 send_message。',
      "    payload: dict | None = None"],
     ['    # 只有 room_invite 用（{"room_id": int}）。其余 kind 一律忽略 —— 见 send_message。',
      "    payload = None"],
     {"backend_sendbody_payload"}),

    # routes 不把 kind/payload 转发给 chat.send —— 等于「传了没人读」。
    ("M10_no_pass_through", ROUTES_PY,
     ["            me.player_id, _norm(code), text, body.client_msg_id, kind, payload,"],
     ["            me.player_id, _norm(code), text, body.client_msg_id,"],
     {"backend_pass_through"}),

    # --- 第二轮：客户端显示与交互 ---------------------------------------------

    # 渲染前不再去重 —— 同房重复邀请又会出现两条。
    ("M11_drop_dedupe_call", CHAT,
     ["\t\tfor msg in RoomInvite.dedupe_for_display(_messages):"],
     ["\t\tfor msg in _messages:"],
     {"chat_dedupe"}),

    # 去重改成「保留第一条」—— 与「保留最新」的口径相反。
    ("M12_dedupe_keeps_first", INVITE,
     ["\t\tif rid > 0:", "\t\t\tlast_at[rid] = i"],
     ["\t\tif rid > 0 and not last_at.has(rid):", "\t\t\tlast_at[rid] = i"],
     {"dedupe_keeps_latest"}),

    # 点击反馈又排到限流判定之后 —— 已经邀请过时点了没反应（实测症状）。
    ("M13_flash_after_check", LOBBY,
     ["\t_flash_row(row)",
      "\tvar blocked := RoomInvite.send_blocked_reason(now, _invite_last_sec, _invited_pairs.has(key))"],
     ["\tvar blocked := RoomInvite.send_blocked_reason(now, _invite_last_sec, _invited_pairs.has(key))",
      "\t_flash_row(row)"],
     {"lobby_flash_first"}),

    # 「已经邀请过了」又被弹出来 —— 用户明说不想要这句。
    ("M14_dup_toast_back", LOBBY,
     ['\tif blocked == "rate_limited":'],
     ['\tif blocked == "rate_limited":',
      "\t\tGloryToastScript.show_text(RoomInvite.send_blocked_text(blocked))"],
     {"lobby_no_dup_toast"}),
]


def main():
    originals = {}
    for _, path, _, _, _ in MUTATIONS:
        originals.setdefault(path, (read(path), sha(path)))

    rc0, fails0 = run_gate()
    print("baseline: rc=%s fails=%s" % (rc0, fails0))
    if rc0 != 0:
        print("!! 基线不绿，先修好再谈变异")
        return 2

    all_ok = True
    for name, path, old_lines, new_lines, want in MUTATIONS:
        text = originals[path][0]
        old = nl(text, *old_lines)
        new = nl(text, *new_lines)
        if text.count(old) != 1:
            print("ANCHOR_FAIL %s: 命中 %d 次（要求恰好 1 次）" % (name, text.count(old)))
            all_ok = False
            continue
        write(path, text.replace(old, new))
        rc, fails = run_gate()
        got = set(fails) & want
        ok = rc != 0 and bool(got)
        print("%-24s rc=%-3s red=%-5s got=%s" % (name, rc, str(bool(got)), sorted(got)))
        if not ok:
            print("   !! 期望命中 %s，实得 %s" % (sorted(want), sorted(fails)))
            all_ok = False
        # 还原（逐字节）
        write(path, originals[path][0])
        if sha(path) != originals[path][1]:
            print("   !! 还原失败：%s" % path)
            all_ok = False

    # 收尾复跑：必须回到全绿
    rc1, fails1 = run_gate()
    print("restored: rc=%s fails=%s" % (rc1, fails1))
    if rc1 != 0 or fails1:
        all_ok = False

    for path, (_, digest) in originals.items():
        actual = sha(path)
        print("sha %s %s %s" % (os.path.relpath(path, PROJ), actual,
                                "OK" if actual == digest else "MISMATCH"))
        if actual != digest:
            all_ok = False

    print("MUTATION_ALL_RED" if all_ok else "MUTATION_FAILED")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
