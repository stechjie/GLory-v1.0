"""变异测试：证明 probe_doom_thunder_924 真的会因为「修复被改坏」而变红。

为什么必须做：本仓的教训是「新门禁全绿 != 对」。一条只会绿的判据等于没有判据。
上一轮（⑩ 金属箭）就是因为没有第二道独立核对，改错了地方还报"完成"。

每个变异：改坏 -> 跑探针期望变红 -> 还原 -> 校验 sha256 与原文逐字节相同。
"""
import hashlib, os, subprocess, sys

PROJ = r"C:\Users\WINDOWS\Desktop\GLory-work"
EXE = r"C:\Users\WINDOWS\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
ENV_PATH = r"C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem"
SCENE = "work/_qa_922/probe_doom_thunder_924.tscn"
PROBE_LOG = os.path.join(PROJ, "work", "_qa_922", "raw_probe_doom_thunder_924.txt")

COMPOSER = os.path.join(PROJ, "effects", "vfx3d", "units", "UnitSkillVFXComposer3D.gd")
SCREEN = os.path.join(PROJ, "scenes", "battle", "BattleScreen.gd")
RENDERER = os.path.join(PROJ, "scenes", "battle", "BattleRenderer.gd")
SKILLS = os.path.join(PROJ, "scripts", "battle", "BattleSimSkills.gd")
VFX = os.path.join(PROJ, "scenes", "battle", "BattleVfx.gd")

MUTATIONS = [
    # A. 神王技能退回"剑气/贴图"路由 —— 用户报的「无显示」就是这么来的。
    ("A_king_revert_to_oga_melee", COMPOSER,
     '\t\t"global_divine_blast":_aoe_thunder(origin,target,context)',
     '\t\t"global_divine_blast":_oga_pack_multi_melee("global_divine_blast",origin,target,context)',
     "神王落雷"),

    # B. 锁存函数认错技能 id —— 策反关系就还原不出来（回放里永远是红条）。
    ("B_latch_wrong_skill_id", SCREEN,
     'if str(caster_def.get("skill_id", "")) != "shared_hp_link":',
     'if str(caster_def.get("skill_id", "")) != "__never_matches__":',
     "从回放里还原出策反关系"),

    # C. 写回函数退化成"永不写回" —— 锁存白做，血条还是首帧快照那套（用户的红条）。
    #
    # ★ 这条变异是**上一版的遗留问题**的活证据：
    #   第一版把 `f.team = converted_team` 内联在 `_apply_replay_frame` 里，探针只能用
    #   源码文本断言兜底。把条件改成 `if false and ...` 时，源码里那两行**一个字都没变**,
    #   文本断言照样绿 —— 变异测试实测 C 当时是 FAIL（没被抓到）。假绿。
    #   现在这两行已抽成纯函数 `apply_latched_team`，探针**直接调它**，判据落在行为上。
    ("C_skip_team_writeback", SCREEN,
     '\tvar converted_team := str(conversions.get(uid, ""))\n\tif not converted_team.is_empty():\n\t\tf["team"] = converted_team',
     '\tvar converted_team := str(conversions.get(uid, ""))\n\tif false and not converted_team.is_empty():\n\t\tf["team"] = converted_team',
     "写回行为"),

    # D. 血条颜色退回"只在建节点时定死" —— 策反后不会变绿。
    ("D_bar_color_static", RENDERER,
     "\t\t\tvar want_color: Color = _hp_color_for_team(_display_team(f))",
     "\t\t\tvar want_color: Color = hp_bar.color",
     "每帧按当前队伍重算血条颜色"),

    # E. 解码时**不再调用**写回（把调用点整行注释掉）—— 锁存出来了但没人用。
    #
    # ★ 这条变异抓到过一个**假绿**：第一版判据是裸 `src.contains("apply_latched_team(...)")`，
    #   而注释掉的行里照样含这个子串 —— 变异 E 当时是 FAIL（没被抓到）。
    #   现在判据换成注释感知的 `_has_live_code`，注释掉的行不算数。
    ("E_drop_writeback_callsite", SCREEN,
     "\t\tapply_latched_team(f, str(entry[0]), _converted_ally_ids)",
     "\t\t# apply_latched_team(f, str(entry[0]), _converted_ally_ids)",
     "解码时把锁存队伍写回"),

    # F. 锁存函数**不再被调用** —— 策反关系根本不会进锁存表。
    ("F_drop_latch_callsite", SCREEN,
     "\tvar frame_conversions := latched_conversions_in_frame(frames[i], _replay_by_uid)",
     "\tvar frame_conversions := {}",
     "解码时调用锁存函数"),

    # --- 第四轮：神王「非技能目标也落雷」-----------------------------------------
    #
    # G. 神王技能**不再记录**真实目标 —— 表现层拿不到记录，只能退回猜。用户看到的
    #    「劈错人」与「无显示」都从这条退化开始。
    ("G_drop_target_record", SKILLS,
     "\t_mark_vfx_targets(caster, struck)",
     "\t# _mark_vfx_targets(caster, struck)",
     "[record] 生产实现确实写下了技能目标"),

    # H. 记录成**全部对手**而不是「本路被选中的」—— 正是旧写法的第二个来源
    #    （退回「全部存活敌人」），多目标技变全屏技。判据是「每条记录都得落在神王那一路」。
    ("H_record_all_opponents", SKILLS,
     "\t_mark_vfx_targets(caster, struck)",
     "\t_mark_vfx_targets(caster, opponents)",
     "记录的每个目标都在神王那一路"),

    # I. 退回旧口径的开关被放开（`recorded.is_empty()` -> `if true:`）—— 有记录也照样
    #    把「帧级伤害事件」的目标叠加上去，于是非技能目标又有雷了。
    #    ★ 这条**只有** Part 7 的结构断言能抓：Part 6 直接调纯函数，绕过了这个开关。
    #      两类断言互补 —— 上一轮 C/E 的教训就是「只有一类断言时必然漏」。
    ("I_fallback_always_on", VFX,
     "\t\tif recorded.is_empty():",
     "\t\tif true:",
     "只有**没有记录**时才退回旧口径"),

    # J. 目标解析重新按 `alive` 过滤 —— 把「被这道雷劈死的目标」从落点里删掉。
    #    那样目标是无声倒下、头顶没雷；而那道雷恰恰是最该看见的一道。
    ("J_filter_dead_targets", VFX,
     '\t\tif hit.is_empty():\n\t\t\tcontinue\n\t\tout.append(hit.get("world_foot",Vector3.ZERO))',
     '\t\tif hit.is_empty() or not bool(hit.get("alive",false)):\n\t\t\tcontinue\n\t\tout.append(hit.get("world_foot",Vector3.ZERO))',
     "被劈死的目标仍出落点"),
]


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run_probe():
    env = dict(os.environ)
    env["PATH"] = ENV_PATH
    p = subprocess.run([EXE, "--headless", "--path", PROJ, SCENE],
                       capture_output=True, timeout=900, env=env, cwd=PROJ)
    raw = (p.stdout + p.stderr).decode("utf-8", "replace")
    with open(PROBE_LOG, "w", encoding="utf-8") as fh:
        fh.write(raw)
    return p.returncode, raw


def run_named(label):
    """返回 (整体 rc, 该条断言是否出现 FAIL, 探针是否跑完)。"""
    rc, raw = run_probe()
    failed = False
    finished = "PROBE_DONE" in raw
    for line in raw.splitlines():
        if line.strip().startswith("FAIL") and label in line:
            failed = True
    return rc, failed, finished


failures = []
for name, path, old, new, label in MUTATIONS:
    original = open(path, encoding="utf-8", newline="").read()
    before_sha = sha(path)
    # ★ 本仓 .gd 是 CRLF。多行锚点必须跟着换算，否则永远"锚点找不到" ——
    #   而"锚点找不到"会被当成 SKIP（跳过），于是**变异测试静默失效**、假绿。
    if "\r\n" in original:
        old = old.replace("\n", "\r\n")
        new = new.replace("\n", "\r\n")
    if old not in original:
        print("  SKIP %-28s 锚点找不到（源码已漂移）：%s" % (name, old[:60]))
        failures.append(name + "(anchor-missing)")
        continue
    if original.count(old) != 1:
        print("  SKIP %-28s 锚点不唯一（%d 处）" % (name, original.count(old)))
        failures.append(name + "(anchor-ambiguous)")
        continue

    mutated = original.replace(old, new)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(mutated)
    try:
        rc, failed, finished = run_named(label)
    finally:
        with open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write(original)
    after_sha = sha(path)
    restored = before_sha == after_sha

    ok = failed and finished and restored
    print("  %s %-28s 探针判定为红=%-5s 跑到结束=%-5s 还原逐字节=%-5s (rc=%s)"
          % ("PASS" if ok else "FAIL", name, str(failed), str(finished), str(restored), rc))
    if not ok:
        failures.append(name)

print()
if failures:
    print("MUTATION_DONE FAIL %d 条没有被判据覆盖：%s" % (len(failures), ", ".join(failures)))
    sys.exit(1)
print("MUTATION_DONE PASS 全部 %d 个变异都被探针抓到，且还原逐字节一致" % len(MUTATIONS))
