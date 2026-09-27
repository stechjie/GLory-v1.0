#!/usr/bin/env python3
"""9.27 第二批（《bug提交和修复.docx》5 条）：变动文件同目录同路径备份到桌面，并附 sha256。

交付夹布局：**一个夹**（`9.27交付_02_代码`）装「代码 + README + docs」。
★ 2026-09-27 晚起按用户要求合并：**不再分「_资源」以外的两个夹**，
  只有**真的新增了资源文件**（图片/音频等）时才另开 `_资源` 夹。本轮没有资源改动。

★ 与 9.27 第一批（make_delivery_927.py，夹名 `9.27交付`）**刻意不重名** ——
那个夹是「大厅商店/公告图标预览」那一批的，重跑会把它清空。
★ 交付夹里的 _说明.txt / _sha256清单.txt 由本脚本写出：改说明要改**本文件内嵌的
NOTE_TEXT**，别手改交付夹（重跑即被覆盖）。
★ 清空重建：本脚本会先 rmtree 目标夹 —— 所以**只能**是这一个夹名，别改宽。
"""
import hashlib
import os
import shutil

PROJ = r"C:\Users\WINDOWS\Desktop\GLory-work"
DESK = r"C:\Users\WINDOWS\Desktop"

# 单一交付夹（代码 + 文档）。只有新增资源文件时才另开 "_资源" 夹。
OUT = "9.27交付_02_代码"

FILES = [
    # --- 第 1 条：末日守卫 ---
    r"scripts\battle\BattleSimulator.gd",
    r"scripts\ui\UnitDetailFormat.gd",
    # --- 第 2 条：房间邀请（含第二轮订正）---
    r"scripts\multiplayer\RoomInvite.gd",
    r"scenes\menu\Team3v3Lobby.gd",
    r"scenes\menu\ChatScreen.gd",
    r"scenes\main\Main.gd",
    r"scripts\autoload\AccountManager.gd",
    r"tools\room_invite_check.gd",
    r"tools\room_invite_check.tscn",
    r"database\020_room_invite.sql",
    r"backend\app\chat.py",
    r"backend\app\routes\chat.py",
    # --- 第 3 条：重连刷新费用 ---
    r"scripts\autoload\NetworkService.gd",
    # --- 第 4/5 条：毒灵可达性选敌 / 隔断三层 ---
    r"scripts\battle\BattleSimShared.gd",
    r"scripts\battle\BattleSimSkills.gd",
    r"scenes\battle\BattleArena.gd",
    # --- 门禁 / 探针 / 变异 / 批跑清单 ---
    r"tools\cold_parse_chain_check.gd",
    r"work\_qa_922\run_gates.py",
    r"work\_qa_922\show_fails.py",
    # 打包/复核脚本本身也带上：交付夹因此可以**自检**（verify 会 import make_delivery）。
    r"work\_qa_922\make_delivery_927c.py",
    r"work\_qa_922\verify_delivery.py",
    r"work\_qa_922\mutate_room_invite_927.py",
    r"work\_qa_922\probe_blood_link_boss_immune_925.gd",
    r"work\_qa_922\probe_blood_link_boss_immune_925.tscn",
    r"work\_qa_922\probe_shop_refresh_reconnect_927.gd",
    r"work\_qa_922\probe_shop_refresh_reconnect_927.tscn",
    r"work\_qa_922\probe_poison_reach_927.gd",
    r"work\_qa_922\probe_poison_reach_927.tscn",
    r"work\_qa_922\probe_lane_partition_927.gd",
    r"work\_qa_922\probe_lane_partition_927.tscn",
    # --- 文档 ---
    r"README.md",
    r"docs\9.27bug文档5条修复记录.md",
    r"docs\9.27毒灵被队友阻挡问题记录.md",
    r"docs\9.27战场隔断越界修复思路.md",
    r"docs\9.27商店刷新重连费用调查.md",
]

NOTE_TEXT = (
    "9.27 第二批《bug提交和修复.docx》5 条 —— 交付清单（同目录同路径备份）\n"
    "==================================================================\n"
    "用户文档 5 条：1 条技能调整、1 条新功能（房间邀请好友）、3 条按既有调查/思路修复。\n"
    "★ 本夹将「代码」与「文档」合在一起（2026-09-27 晚用户要求）。本轮没有资源改动。\n"
    "\n"
    "① 末日守卫：技能目标不得高于自身星级（_link_targets_without_doom 加 maxi(1,star)\n"
    "   比较，两处都取 maxi 防 star 缺失变 0 星）；技能说明 zh/en 改成需求原句。\n"
    "\n"
    "② 房间邀请好友（新功能，本轮最大一块）：\n"
    "   ★ 关键决定 —— 邀请做成 kind='room_invite' 的私聊（payload={'room_id':N}）。\n"
    "     要求里「在聊天朋友消息里收到 + 音效 + 红点」因此全部白拿（发送走既有 HTTPS、\n"
    "     推送走 ② WebSocket 的 dm 分支、红点音效在 ChatService._on_dm_push），\n"
    "     不新开推送类型。代价：给 chat_messages 加 kind/payload 两列（020 迁移，🟢）。\n"
    "   ★ 判据源只有一份：scripts/multiplayer/RoomInvite.gd（纯 static，不碰界面/网络）。\n"
    "     要求 (4) 限流、(5) 四个失效条件全收在里面，不在界面散着写。\n"
    "   ★ 两处「写反了不报错」被专门钉住：\n"
    "     (a) UNKNOWN_ROOM(-1)「查不到」vs 0「确定不在房间」必须分开；\n"
    "     (b) 「我开启了新的房间，一起来玩吧」「邀请已过时」只许一处拼法（注释感知扫全目录）。\n"
    "   ★ Team3v3Lobby 朋友列表每行改可点，刻意**不用 Button.new()**（棘轮基线恰好 3）；\n"
    "     点击后过限流 → 发邀请 → _flash_row 亮一下。\n"
    "   ★ ChatScreen：_bubble 分流邀请 → 邀请框 + 右下角「立即参与」；失效走\n"
    "     GloryToast.show_text(RoomInvite.expired_text())（与「上阵棋子数目少于 N」同出口）。\n"
    "   ★ 后端：两条限流判在**数据库**上（rate_limit.py 是进程内窗口，重启清零、多 worker\n"
    "     各算各的）；kind 白名单 + payload 收敛成 {'room_id': int>0}；邀请仍走 dm 推送。\n"
    "\n"
    "②-2 第二轮订正（2026-09-27 晚，用户回执 4 个问题）——\n"
    "   问题：① 点朋友 ID 没有「亮一下」；② 不想要「你已经邀请过了」；\n"
    "         ③ 被邀请方收到两条同房间重复邀请；④ 邀请要方框 + 右下角「立即参与」。\n"
    "   根因：**客户端传了 kind，后端根本没读** —— 这是上一轮一条从未打通的管道。\n"
    "     · routes/chat.py 的 SendBody **没有 kind/payload 字段**（pydantic 对多余字段\n"
    "       默认忽略、不报错），send_message 也从不转发它们；\n"
    "     · chat.py 的 history() 没 select kind/payload（收件人重进聊天就丢字段）；\n"
    "     · chat.py 的 send() 返回 Message **没带 kind/payload**（回包与 dm 推送都靠它）；\n"
    "     · chat.py **没有 import json**，而 _decode_payload/send 用 json.loads/dumps\n"
    "       —— 只在真有 payload 时触发，邀请一进库就 NameError(500)。\n"
    "   做法：后端补 import json / history 补列 / send 返回补字段 / SendBody 加字段并转发\n"
    "         （不认识的 kind→400；邀请 payload 收敛成 room_id int>0；非邀请不带 payload）。\n"
    "         客户端：_flash_row 提到限流判定**之前**（点击必亮）且亮度 1.6x/0.28s →\n"
    "         2.6x/0.45s；duplicate 与服务端 409 一律**静默**（只有换房间的 rate_limited 提示）；\n"
    "         新增 RoomInvite.dedupe_for_display()，渲染前把同一 room_id 的重复邀请收敛成\n"
    "         一条、保留最新（后端去重只防未来，旧两条只能靠显示层收拾，兼作兜底）；\n"
    "         _invite_bubble 改成金边方框 + 小标题「房间邀请」+ 底右「立即参与」。\n"
    "   判据：room_invite_check 49 → 65；变异 6 → 15 条。\n"
    "\n"
    "③ 重连后商店刷新费用变少：NetworkService._apply_server_shop 有 refresh_uses 时同步回\n"
    "   GameState.shop_refresh_uses_this_round。**has() 守卫必须有** —— 回执路径传的 shop\n"
    "   不带这个键，不加守卫会把计数打回 0（正是要修的 bug，反过来又造一个）。\n"
    "\n"
    "④ 毒灵被队友挡住：选敌从「最近」改成「可达性感知」（_first_contact 圆射线扫掠），\n"
    "   只对目标被友军挡住的单位启用（用户口径）。\n"
    "\n"
    "⑤ 战场隔断越界：A 层单一真源 _lane_has_living_opponent（门禁/晶柱/宝物 1/4 共用）、\n"
    "   B 层 _lane_ever_occupied 替掉 own_survivor 口径、C 层跨层技能改看\n"
    "   _opponents_in_reachable_lanes。\n"
    "\n"
    "验证（第二轮后复跑）：批跑 34 条 → 27 PASS / 7 FAIL；7 条红全部与本批改动文件无关，\n"
    "     且逐条单跑复核过原因（audio_0922/audio_0921 = 对应 .mp3 在本检出里缺失；\n"
    "     four_star_values 属另一批；voice/procedural_ui_ratchet/prep_text_coverage/\n"
    "     dynamic_call 为既存红）。procedural_ui_ratchet 的落点是 BattleScreen.gd /\n"
    "     FourStarUpgradePanel.gd / scripts/qa/voice_device_probe.gd，不含本批文件。\n"
    "     没有跑 --update-baseline 刷绿。cold_parse_chain 110 PASS。\n"
    "     门禁 room_invite_check 65 项；变异 mutate_room_invite_927.py 15/15 全红并按 sha256 还原。\n"
    "\n"
    "★ 未做真机/观感验收，未重新导出 EXE/APK。\n"
    "★ 第 2 条如实缺口：\n"
    "   (a) 要求 (5) 的「该房间对局已开始」客户端拿不到（presence 只报房间号），现由加入流程\n"
    "       兜底，不会显示成「邀请已过时」；is_expired 已留 room_started 形参备用。\n"
    "   (b) 邀请真实联网往返需两台设备+后端+真库；本轮后端只做了 py_compile 与结构断言，\n"
    "       backend/tests 没跑、database/020 没在真库执行过。\n"
    "   (c) 邀请框的位置/宽度没有出图核对。\n"
    "   (d) **后端必须重启/重新部署才生效** —— 正在跑的旧进程不会自己变成新逻辑。\n"
)

TREE_NOTE = (
    "\n"
    "目录结构（相对工程根，与源工程一致）：\n"
    "  scripts/battle/BattleSimulator.gd\n"
    "  scripts/battle/BattleSimShared.gd\n"
    "  scripts/battle/BattleSimSkills.gd\n"
    "  scenes/battle/BattleArena.gd\n"
    "  scripts/ui/UnitDetailFormat.gd\n"
    "  scripts/autoload/NetworkService.gd\n"
    "  scripts/autoload/AccountManager.gd\n"
    "  scripts/multiplayer/RoomInvite.gd            （新增）\n"
    "  scenes/menu/Team3v3Lobby.gd\n"
    "  scenes/menu/ChatScreen.gd\n"
    "  scenes/main/Main.gd\n"
    "  tools/room_invite_check.gd                    （新增门禁）\n"
    "  tools/room_invite_check.tscn                  （新增）\n"
    "  tools/cold_parse_chain_check.gd\n"
    "  database/020_room_invite.sql                  （新增迁移）\n"
    "  backend/app/chat.py\n"
    "  backend/app/routes/chat.py\n"
    "  work/_qa_922/run_gates.py\n"
    "  work/_qa_922/show_fails.py                    （新增：打印失败明细）\n"
    "  work/_qa_922/mutate_room_invite_927.py        （新增变异，15 条）\n"
    "  work/_qa_922/probe_blood_link_boss_immune_925.gd / .tscn\n"
    "  work/_qa_922/probe_shop_refresh_reconnect_927.gd / .tscn\n"
    "  work/_qa_922/probe_poison_reach_927.gd / .tscn\n"
    "  work/_qa_922/probe_lane_partition_927.gd / .tscn\n"
    "  README.md\n"
    "  docs/9.27bug文档5条修复记录.md                 （本轮记录，§9 = 第二轮订正）\n"
    "  docs/9.27毒灵被队友阻挡问题记录.md\n"
    "  docs/9.27战场隔断越界修复思路.md\n"
    "  docs/9.27商店刷新重连费用调查.md\n"
)


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    d = os.path.join(DESK, OUT)
    # 清空重建，保证「重跑即最新」（也顺手清掉上一版留下的、本批已不再交付的文件）。
    if os.path.isdir(d):
        shutil.rmtree(d)

    records = []
    for rel in FILES:
        src = os.path.join(PROJ, rel)
        if not os.path.isfile(src):
            raise SystemExit("源文件不存在，无法交付：%s" % src)
        dst = os.path.join(d, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
        records.append((rel, sha256_of(src)))

    with open(os.path.join(d, "_说明.txt"), "w", encoding="utf-8") as fh:
        fh.write(NOTE_TEXT)
        fh.write(TREE_NOTE)
    with open(os.path.join(d, "_sha256清单.txt"), "w", encoding="utf-8") as fh:
        fh.write("# 9.27 第二批 交付 sha256 清单（相对工程根路径）\n")
        for rel, sha in records:
            fh.write("%s  %s\n" % (sha, rel.replace("\\", "/")))

    print("交付完成：%s  共 %d 个文件" % (OUT, len(records)))
    for rel, sha in records:
        print("  %s  %s" % (sha[:16], rel.replace("\\", "/")))


if __name__ == "__main__":
    main()
