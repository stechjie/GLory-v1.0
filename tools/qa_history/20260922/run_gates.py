"""9.22 批次门禁批跑。只跑与本批改动相关的门禁。

用法: python run_gates.py [门禁名 ...]
输出: 每个门禁一行 PASS/FAIL + 结果行原文；结果写 gate_results.json。

本批改动面：
  * ui/services/SfxService.gd          —— 15 条新 cue + 3 张派发表 + 音量覆盖表
  * scenes/battle/BattleVfx.gd         —— boss 技能音 / 灭世裁决者三段 / sfx_proc 派发
  * scripts/battle/BattleSimulator.gd  —— 5 处 sfx_proc 事件
  * scripts/battle/BattlePresentationEvent.gd —— 登记 sfx_proc
  * scenes/prep/PrepBoardController.gd —— 人王交换 bug 修复（4 处）
  * tools/audio_sfx_check.gd           —— cue 计数 60 → 75 + 豁免名单
  * tools/audio_0921_check.gd          —— 区间化 proc 分支断言
"""
import subprocess, sys, os, re, json, time

EXE = r"C:\Users\WINDOWS\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
PROJ = r"C:\Users\WINDOWS\Desktop\GLory-work"
ENV_PATH = r"C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem"

GATES = [
    # 本批新增
    "audio_0922_check",
    "prep_swap_check",
    # ★ 本批事故后补进批跑：解析链门禁。
    #   9.22 我第一次批跑时**漏了这条**，结果 BattleVfx.gd 的解析期错误
    #   （`elif _owned:` 只剩注释）整批跑没抓到，是 voice_check 顺手抓出来的。
    #   凡改动 `scenes/battle/**` 或任何被继承的脚本，这条必跑。
    "cold_parse_chain_check",
    # 本批改动直接命中
    "audio_sfx_check",
    # 9.26 新增：大厅宠物脚步声（独立播放 + 步频行为 + 静音门）。
    "pet_footstep_check",
    "audio_0921_check",
    "battle_presentation_event_check",
    "merge_rule_parity_check",
    "boss_battle_bgm_check",
    # 相邻回归
    "four_star_values_check",
    "synergy_activation_sfx_check",
    "team_merc_summon_sfx_check",
    "ui_feedback_check",
    "battle_cue_profile_check",
    # ★ 9.24 订正 #2 新增：钉住「玩家棋子普攻弹体的权威表是 OGA 目录」这个 precedence，
    #   以及神侍↔极光射手「只换模型、不换飞行速度」的口径。
    #   加它的理由：第一版把对换写在了死表上，编译通过 + 全批绿 + 用户肉眼无变化，
    #   **没有任何既有门禁会红**。这条就是补上的那道闸。
    "oga_projectile_swap_check",
    # ★ 9.24 第三轮新增：行为探针（先红后绿）。
    #   钉住两条用户回执：① 神王技能落雷（与裁决者同一实现，逐目标各落一道）；
    #   ② 血之契约策反**跨回放边界**后血条必须变己方色（回放帧里没有 team 列，
    #   只能靠锁存）。仓里有 4 个变异证明它真的会红，见 mutate_doom_thunder_924.py。
    "probe_doom_thunder_924",
    # ★ 9.25 新增行为探针（先红后绿）。钉住提交文档第 1 条：
    #   末日守卫的血链不能把 boss_* / ally_*（法阵 boss）策反过来。
    #   仓里有实证：`_link_targets_without_doom` 少一个 `_is_boss_fighter(o)`
    #   时，探针 Part 2 立刻红 2 条（候选池里还留着 boss）。见报告 §1。
    "probe_blood_link_boss_immune_925",
    # ★ 9.27 本批（bug提交和修复.docx 5 条）新增/更新的行为探针。
    #   进批跑的理由同 9.25：行为探针就是判据，散在手工跑里必然有一条被忘掉。
    #   - probe_shop_refresh_reconnect_927：重连后商店刷新费用被服务端 roomstate
    #     覆盖回 0 的 bug（第 3 条）。含「客户端同步点存在 + 被 has() 守卫」的结构断言。
    #   - probe_poison_reach_927：毒灵被友军挡住导致永远走不到攻击距离（第 4 条）。
    #     含 L5/L6：可达性感知的选敌（_first_contact 射线）与端到端伤害。
    #   - probe_lane_partition_927：隔断越界（第 5 条）。含 A/B/C 三层判据 +
    #     §13/§14 行为断言（边界 α/β/γ/δ + 可跨层技能过滤）。
    #   见 work/_qa_922/mutate_927_five_fixes.py（6 条变异全红并已还原）。
    "probe_shop_refresh_reconnect_927",
    "probe_poison_reach_927",
    "probe_lane_partition_927",
    # ★ 9.27 第三批：房间邀请好友（第 2 条）。行为 + 结构两类断言；
    #   仓里有变异实证 work/_qa_922/mutate_room_invite_927.py（6 条全红并已还原），
    #   其中 M5 专打「注释掉调用点」这条 —— 说明结构断言是注释感知的。
    "room_invite_check",
    # ★ 9.25 追加订正（用户回执：教程里刷新刷几次就点不动了）。这条钉的是**判据同源**：
    #   凡是算 shop 刷新费用的地方都只能接 TutorialMode.shop_refresh_all_free()。
    #   它是唯一能抓住「第三处手抄条件漂移」的判据 —— A/B 两组行为断言都不管同源。
    #   仓里有变异实证：把 PrepUI 那行退回旧写法，立刻红 2 条并指名到函数。
    #   见 tools/qa_history/20260922/mutate_shop_refresh_925.py。
    "shop_refresh_free_source_check",
    "voice_check",
    "settings_locale_live_check",
    "prep_detail_overlay_check",
    "procedural_ui_ratchet_check",
    "prep_text_coverage_check",
    "dynamic_call_check",
    # ★ 9.25 相关性：这一批改了 TutorialMode.gd 的文案与步骤机，这几条教学门禁
    #   直接命中，必须进批跑（此前它们只在手工跑）。
    "tutorial_text_leak_check",
    "tutorial_step15_flow_check",
    "tutorial_checkpoint_check",
    "tutorial_overlay_layout_check",
    "tutorial_target_check",
    "tutorial_carrot_flow_check",
]


def _scene_for(name: str) -> str:
    """门禁场景的解析：`tools/` 优先，找不到再看 `tools/qa_history/20260922/`。

    为什么允许探针进批跑：行为探针（先红后绿那种）和门禁一样是**判据**，
    分两个地方跑就等于总有一条会被忘掉。本仓已经吃过一次亏 ——
    探针只在手工跑，于是"接线还在不在"没人守。
    `work/_qa_922` 下的探针用 `PROBE_DONE checks=N fail=0` 作为通过行，
    `run_one` 本来就会把它捞出来，所以这里只需解决路径。
    """
    local = os.path.join(PROJ, "tools", "qa_history", "20260922", "%s.tscn" % name)
    if os.path.isfile(local):
        return "tools/qa_history/20260922/%s.tscn" % name
    return "tools/%s.tscn" % name


def run_one(name: str, timeout: int = 300):
    env = dict(os.environ)
    env["PATH"] = ENV_PATH
    scene = _scene_for(name)
    cmd = [EXE, "--headless", "--path", PROJ, scene]
    t0 = time.time()
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout, env=env, cwd=PROJ)
    except subprocess.TimeoutExpired:
        return name, None, "TIMEOUT(%.0fs)" % (time.time() - t0), []
    raw = p.stdout.decode("utf-8", "replace") + p.stderr.decode("utf-8", "replace")
    lines = [l for l in raw.splitlines() if "CHECK_RESULT" in l or "PROBE_DONE" in l]
    return name, p.returncode, "%.1fs" % (time.time() - t0), lines


def main():
    only = sys.argv[1:] or GATES
    summary = {}
    for g in only:
        name, rc, dur, lines = run_one(g)
        verdict = "TIMEOUT" if rc is None else ("PASS" if rc == 0 else "FAIL")
        summary[name] = {"rc": rc, "verdict": verdict, "dur": dur, "lines": lines}
        print("%-34s %-6s rc=%-5s %s" % (name, verdict, str(rc), dur))
        for l in lines:
            print("      " + l.strip()[:220])
        sys.stdout.flush()
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gate_results.json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(summary, fh, ensure_ascii=False, indent=2)
    print("\nWROTE", out)


if __name__ == "__main__":
    main()
