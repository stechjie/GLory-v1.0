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
    "voice_check",
    "settings_locale_live_check",
    "prep_detail_overlay_check",
    "procedural_ui_ratchet_check",
    "prep_text_coverage_check",
    "dynamic_call_check",
]


def run_one(name: str, timeout: int = 300):
    env = dict(os.environ)
    env["PATH"] = ENV_PATH
    scene = "tools/%s.tscn" % name
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
