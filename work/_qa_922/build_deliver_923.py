# -*- coding: utf-8 -*-
"""构建 / 刷新 9.23 两个「同目录同路径镜像」交付夹（桌面）。

  01_音效BGM资源_同路径备份  —— 16 个音频 + 16 个 .import
  02_代码修改_同路径备份      —— 产品源码 + 门禁/探针 + 本轮 docs/README + work/_qa_922 脚本

两个夹都带 `_说明.txt`（逐文件说明）与 `_sha256清单.txt`（逐文件 sha256）。
★ 二进制读写、只复制不移动、不删除任何东西。

用法
    python build_deliver_923.py            # 首次构建（目标夹已存在则中止，不覆盖）
    python build_deliver_923.py restage    # 刷新：目标夹已存在，按同一份文件清单
                                           # 从工程重新复制内容，并重写 _说明 / _sha256清单
                                           # （2026-09-23 订正轮用它把「人王交换」根因描述改对；
                                           #   2026-09-23 第五批用它把 boss 技能音的双通道
                                           #   订正覆盖进同一对夹子）

★ `restage` 只**覆盖清单内**的文件，不动夹里其它东西；也从不删文件。
  夹里多出来的文件（清单外）会在结尾被报出来，由人决定，不自动处理。

★ 第五批（boss 技能音双通道）相对第四批新增进清单的文件：
    scripts/battle/BattleSimShared.gd
    scripts/battle/BattleSimSkills.gd
    scripts/battle/BattleSimTreasures.gd
    tools/ui_feedback_check.gd
  第四批已在清单里的 `SfxService.gd` / `BattleVfx.gd` / `BattleSimulator.gd` /
  `audio_sfx_check.gd` / `audio_0922_check.gd` 同时被本批改写，内容以工程为准重新复制。
"""
import hashlib
import os
import shutil
import sys

PROJ = r"C:\Users\WINDOWS\Desktop\GLory-work"
DESK = r"C:\Users\WINDOWS\Desktop"
OUT_RES = os.path.join(DESK, "9.23交付_01_音效BGM资源_同路径备份")
OUT_CODE = os.path.join(DESK, "9.23交付_02_代码修改_同路径备份")

BATTLE = "assets/audio/sfx/battle"
AUDIO_NAMES = [
    "boss_mirror_lord_skill", "boss_thunder_core_skill",
    "boss_apocalypse_charge", "boss_apocalypse_impact",
    "boss_holy_priest_skill", "boss_soul_devourer_skill",
    "boss_twin_gate_revive", "boss_meteor_caster_skill", "boss_blood_demon_skill",
    "merc_gemini_assassin_skill", "merc_libra_judge_proc",
    "star4_spike_proc", "star4_poison_proc", "star4_titan_proc", "star4_motong_proc",
    "final_round_pvp_intro",
]
AUDIO_NOTE = {
    "boss_mirror_lord_skill": "镜像魔君技能（`mirror_clone`）★ 与双生守门人/镜像刺客同一个源文件",
    "boss_thunder_core_skill": "雷怒核心技能（`overload_counter`）",
    "boss_apocalypse_charge": "灭世裁决者**蓄力开始**（被打断时同步 stop_cue）",
    "boss_apocalypse_impact": "灭世裁决者**蓄力完成 + 全场伤害**",
    "boss_holy_priest_skill": "圣愈祭司技能（`holy_purify`）",
    "boss_soul_devourer_skill": "噬魂领主技能（`soul_devour`）",
    "boss_twin_gate_revive": "双生守门人复活那一帧 ★ 与镜像魔君同一个源文件",
    "boss_meteor_caster_skill": "天罚投星者技能（`element_meteor`）",
    "boss_blood_demon_skill": "血怒魔王技能（`blood_rage`）",
    "merc_gemini_assassin_skill": "佣兵镜像刺客技能（`twin_strike`）★ 与镜像魔君同一个源文件",
    "merc_libra_judge_proc": "佣兵审判剑士「增伤那次普攻」触发音（`balance_judge`）★ 与四星刺灵同一个源文件",
    "star4_spike_proc": "四星刺灵「破防那次普攻」触发音（`defense_down_attack`）",
    "star4_poison_proc": "四星毒灵 / 四星飞灵「中毒那次普攻」触发音（`poison_attack`）★ 与四星巨甲灵同一个源文件",
    "star4_titan_proc": "四星巨甲灵「反弹生效」触发音（`poison_reflect_armor_stack`）",
    "star4_motong_proc": "四星魔童「减速那次普攻」触发音（`curse_attack`）",
    "final_round_pvp_intro": "★★ **覆盖**既有同路径文件 —— 最终回合 PVP 开局号角（用户口径：播完棋子才行动）",
}

CODE_FILES = [
    ("ui/services/SfxService.gd",
     "★ 核心：15 条新 cue 常量 + `CUES` 登记 + `BOSS_SKILL_CUES`（7 条，狂战灾兽故意不在）"
     "+ `MERC_PROC_SKILL_CUES` + `STAR4_PROC_SKILL_CUES` 扩 4 条 + `boss_skill_cue_for()` / "
     "`merc_proc_cue_for()` + **按 cue 的音量覆盖表 `CUE_VOLUME_DB`**（黄金重骑 +6dB）；"
     "`play()` 里 `voice.volume_db = volume_db + cue_volume_db(cue)`"),
    ("scenes/battle/BattleVfx.gd",
     "★ boss 技能音派发（**不做归属门控**，缩进在函数体层级）+ 灭世裁决者三拍"
     "（蓄力上升沿播 / `apocalypse_ended` 里先 stop 再分两支 / 完成支播全场伤害音）"
     "+ 新事件类型 `sfx_proc` 的派发 `_maybe_play_sfx_proc()`（**只出声，不加特效**）"),
    ("scripts/battle/BattleSimulator.gd",
     "5 处 `_emit_sfx_proc()`：`_perform_attack` 的 `balance_judge` 支、`_apply_attack_statuses` 的 "
     "`curse_attack` / `poison_attack` / `defense_down_attack` 三支、`_apply_defender_reaction` 里巨甲灵那条；"
     "外加静态方法 `_emit_sfx_proc()`"),
    ("scripts/battle/BattleSimShared.gd",
     "★ 9.23 第五批：`_emit_sfx_proc()` **搬到这里**（原本在 BattleSimulator，"
     "但 SimSkills / SimTreasures 两个兄弟模块也要用；放在共享基类上避免循环依赖）。"
     "另外它是 `sfx_proc` 事件穿过**回放边界**的起点 —— 事件进 `state.visual_events`，"
     "回放采集时进 `frame_events`，所以真机（播回放）路径上音效派发才成立"),
    ("scripts/battle/BattleSimSkills.gd",
     "★ 9.23 第五批：`_skill_apocalypse_charge` 返回类型 `void` → `bool`"
     "（true = 这次真的开始蓄力，不是「已经在蓄力」）；"
     "`_skill_mirror_clone` 返回类型 `void` → `int`（这次真的召唤出几个分身）。"
     "两个返回值就是调用方补事件的**判据** —— 没有它，「开始蓄力响一次」会退化成"
     "「每次 match 都响」、镜像魔君会退化成「每秒响一次」"),
    ("scripts/battle/BattleSimTreasures.gd",
     "★ 9.23 第五批：`_apply_boss_attacker_passives(attacker, state)` 加 `state` 形参；"
     "`blood_rage` 支里补 `sfx_proc` 事件 —— 挂在 `not blood_rage_active` 这个守卫**里面**，"
     "所以「进入暴走的那一次、且仅一次」由代码结构保证，不是靠调用方自觉"),
    ("scripts/battle/BattlePresentationEvent.gd",
     "`KNOWN_TYPES` 登记 `sfx_proc` + `_default_visibility()` 给它 `VISIBILITY_IMPORTANT`"
     "（不登记会产生 `unknown_type:` 校验错）"),
    ("scenes/prep/PrepBoardController.gd",
     "★ **bug 修复主文件**：四个搬运 handler 的「合不成就退回交换」"
     "（`elif can_merge_cells(...) and _merge_copies_into_cell(...):`）"
     "—— 修掉「两个同星级人王交换无效」"),
    ("tools/audio_sfx_check.gd",
     "cue 计数 60 → 75；`INDIRECT_CUES` 补 15 条新 cue + 9.23 第五批再补 "
     "`CUE_BOSS_APOCALYPSE_CHARGE/IMPACT`；`INDIRECT_ENTRIES` 把 `boss_skill_cue_for` "
     "换成 `boss_cast_edge_cue_for` / `boss_event_action_for`（派发入口一拆为二，"
     "旧入口已不再是派发表）"),
    ("tools/ui_feedback_check.gd",
     "★ 9.23 第五批：`_check_reject` 除 `screen_shake` 外**快照并按需关掉 "
     "`reduced_motion`**、收尾一并还原。原来只快照 screen_shake，于是"
     "「降低动态效果」开着的机器上必红（环境态，不是回归）；更要紧的是它同时"
     "制造假绿 —— `shake()` 提前返回 false 时不建 tween、不动控件，"
     "三条还原类断言「什么都没抖所以什么都没坏」全部通过"),
    ("tools/audio_0921_check.gd",
     "`vfx_proc_wrong_branch` 断言由「按顺序」改成「按区间」（新的 `sfx_proc` 派发排在 "
     "`unit_skill_proc` 之前，旧判据会被自己的新代码判红）"),
    ("tools/audio_0922_check.gd", "★ 本批新增行为探针（**104 项**），断言见 `docs/CHECKS.md`"),
    ("tools/audio_0922_check.tscn", "上面那条探针的入口场景"),
    ("tools/audio_0922_check.gd.uid", "Godot 4 的脚本 UID（`--import` 生成）"),
    ("tools/prep_swap_check.gd",
     "★ 本批新增行为探针（**30 项**）：四条搬运路径上「同星人王合不成就该交换」，"
     "另含**星级边界**用例（1 星该合成 / 3 星该交换）"),
    ("tools/prep_swap_check.tscn", "上面那条探针的入口场景"),
    ("tools/prep_swap_check.gd.uid", "Godot 4 的脚本 UID（`--import` 生成）"),
    ("tools/cold_parse_chain_check.gd",
     "★★ **加厚**：战斗继承链每一层单列成 target；script 类判据从「`load()` 非 null」升级为 "
     "**`can_instantiate()`**（解析失败的 GDScript 也是非 null 的，只有它能判出来）。读数 25 → 41"),
    ("docs/9.23第四批战斗音效与人王交换bug修复记录.md", "★ 本轮完整记录（含过程事故、教训与第七节订正）；§二/§三 已加「被第五批推翻」横幅"),
    ("docs/9.23第五批boss技能音双通道订正记录.md",
     "★★ 9.23 第五批：boss 技能音「挂错时刻」的完整订正记录 —— 用户逐条口径、"
     "两条通道的设计、回放边界那条根因、变异测试证据、探针自身的假绿事故"),
    ("docs/CHECKS.md", "门禁变更日志（本轮增补与加厚）"),
    ("README.md", "追加「2026-09-23」小节"),
]
QA_FILES = [
    "run_gates.py", "mutate_audio_fix.py", "mutate_swap_fix.py", "mutate_cold_parse_922.py",
    "attribute_ui_feedback_922.py", "restore_prep_swap_922.py", "place_0922_audio.py",
    "probe_bench_bytes.py", "read_docx_text.py",
    "build_deliver_923.py", "verify_deliver_923.py", "resync_manifest.py",
    "_map.txt", "_sources.sha256", "gate_results.json",
]


def sha(p: str) -> str:
    with open(p, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def copy(rel: str, out_root: str) -> str:
    src = os.path.join(PROJ, rel.replace("/", os.sep))
    if not os.path.isfile(src):
        raise SystemExit("[abort] 缺文件: " + rel)
    dst = os.path.join(out_root, rel.replace("/", os.sep))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    return dst


def res_note(res_lines) -> str:
    body = []
    body.append("=" * 72)
    body.append("9.23 批次交付 —— 音效 / BGM 资源部分（同目录同路径镜像）")
    body.append("=" * 72)
    body.append("")
    body.append("用途")
    body.append("    把本夹里的文件按**相同的相对路径**覆盖到你工程对应位置即可。")
    body.append("")
    body.append("覆盖方法（示例）")
    body.append("    本夹\\assets\\audio\\sfx\\battle\\boss_blood_demon_skill.mp3")
    body.append("    覆盖 你的工程\\assets\\audio\\sfx\\battle\\boss_blood_demon_skill.mp3")
    body.append("")
    body.append("本夹内容：%d 个文件（16 个音频 + 16 个 .import）" % len(res_lines))
    body.append("")
    body.append("【音频】assets\\audio\\sfx\\battle\\")
    for name in AUDIO_NAMES:
        body.append("    %s.mp3" % name)
        body.append("        %s" % AUDIO_NOTE[name])
    body.append("")
    body.append("★ 6 组素材本身是**逐字节相同的重复文件**（镜像魔君 / 双生守门人 / 镜像刺客 同一个源；")
    body.append("  审判剑士 / 四星刺灵 同一个源；四星毒灵飞灵 / 四星巨甲灵 同一个源）。")
    body.append("  **刻意没有去重** —— 语义上是「不同棋子各有一段」，将来单独换素材不会互相牵连。")
    body.append("")
    body.append("★ `final_round_pvp_intro.mp3` 是**覆盖**，不是新增：它是本轮的新号角。")
    body.append("  替换前的原件存在工程内 `audio_0922_prechange_20260921/`，不在本夹里。")
    body.append("")
    body.append("★ 狂战灾兽（`boss_rage_beast`）本批**没有素材**，按用户口径**先留空、不播放**，")
    body.append("  所以本夹里没有它的音，代码里也故意没登记（将来补素材时加一行即可）。")
    body.append("")
    body.append("校验")
    body.append("    _sha256清单.txt 里逐文件列出了 sha256，可自行核对。")
    body.append("")
    body.append("注意")
    body.append("    * 覆盖音频后**建议重导一次**，让 .import 与资源对上：")
    body.append("        Godot_v4.7.2-stable_win64_console.exe --headless --path <你的工程> --import")
    body.append("      （`.import` 文件本夹也一起给了，正常情况下覆盖后不需要额外处理）")
    body.append("    * 本批 `project.godot` **逐字节未变**，不需要动它。")
    return "\r\n".join(body)


def code_note(code_lines) -> str:
    body = []
    body.append("=" * 72)
    body.append("9.23 批次交付 —— 代码部分（同目录同路径镜像）")
    body.append("=" * 72)
    body.append("")
    body.append("用途")
    body.append("    把本夹里的文件按**相同的相对路径**覆盖到你工程对应位置即可。")
    body.append("")
    body.append("本夹内容：%d 个文件" % len(code_lines))
    body.append("")
    body.append("【本批的核心 —— 请务必覆盖这两个】")
    body.append("    scenes\\prep\\PrepBoardController.gd")
    body.append("        bug 文档第 1 条「两个同星级人王交换无效」的修复。")
    body.append("        现场：两只**同星**人王**都在备战区**，互换位置无效；**不同星**的能换 ——")
    body.append("        变量是**星级**，不是「在不在场上」。")
    body.append("        根因：`elif can_merge_cells(...): if not _merge_copies_into_cell(...): return`")
    body.append("        —— `can_merge_cells` 判的是「同 id + 同星 + 未满星」，两只同星人王满足它；")
    body.append("        可「满足它」不等于「这一下合得成」：升星要几份看")
    body.append("        `STAR_UPGRADE_COPIES = {1: 2, 2: 3}`，**2 星还得再凑第 3 份**。")
    body.append("        两只人王互换时凑不出第 3 份 → 返回 false → **静默 return**，既不合成也不交换。")
    body.append("        星级边界正好解释「不同星级可以换」：1 星只要 2 份、旧写法真的**合成**；")
    body.append("        2 星缺第 3 份 → **交换无效**；3 星已到合成上限（`MAX_MERGE_STAR = 3`）、")
    body.append("        `can_merge_cells` 为假 → 本来就走交换。")
    body.append("        → 改成 `elif can_merge_cells(...) and _merge_copies_into_cell(...):`，合不成就落到交换分支。")
    body.append("        四个 handler 都改了（一个 handler 只覆盖一种拖动方向）。")
    body.append("    ui\\services\\SfxService.gd")
    body.append("        15 条新 cue + 3 张派发表 + 按 cue 的音量覆盖表（黄金重骑 +6dB）。")
    body.append("")
    body.append("【16 个音效的接线】")
    for rel, note in CODE_FILES:
        if not rel.endswith(".md") and not rel.endswith(".tscn") and not rel.endswith(".uid") \
                and not rel.endswith("README.md"):
            body.append("    %s" % rel.replace("/", "\\"))
            body.append("        %s" % note)
    body.append("")
    body.append("【门禁 / 探针（不是产品代码，但建议一起收进来，方便你自己复跑）】")
    body.append("    tools\\audio_0922_check.gd / .tscn / .gd.uid  本批专用行为探针（104 项）")
    body.append("    tools\\prep_swap_check.gd / .tscn / .gd.uid   人王交换修复的探针（30 项，含星级边界）")
    body.append("    tools\\cold_parse_chain_check.gd              ★ 已加厚：script 类判据改用 can_instantiate()")
    body.append("    tools\\audio_sfx_check.gd                     音效门禁（cue 计数 60 → 75）")
    body.append("    tools\\audio_0921_check.gd                    上一批探针，本批改了它的 proc 分支断言")
    body.append("    work\\_qa_922\\*                              批跑脚本 / 变异脚本 / 归因脚本 / 映射表")
    body.append("")
    body.append("【文档】")
    body.append("    docs\\9.23第四批战斗音效与人王交换bug修复记录.md")
    body.append("    docs\\CHECKS.md     门禁变更日志")
    body.append("    README.md          追加了「2026-09-23」小节")
    body.append("")
    body.append("★ 订正（2026-09-23 同日，用户指出方向有误后）")
    body.append("    第一版把现场写成「人王 unique_on_board，所以两只同星必然一只在场一只在待命区」，")
    body.append("    并据此归因到唯一性 —— **错了**：唯一性限的是场上，备战区不限；")
    body.append("    这个洞跟唯一性无关，跟**星级**有关（见上「星级边界」）。")
    body.append("    已订正四处：源码注释、`tools/prep_swap_check.gd` 文件头、")
    body.append("    `docs\\9.23...记录.md` 第七节、本工程 README 的 2026-09-23 小节。")
    body.append("    同时给 `prep_swap_check` 补了**星级边界用例**（1 星该合成 / 3 星该交换），")
    body.append("    把「为什么只在 2 星暴露」钉成可执行断言（读数 26 → 30）。")
    body.append("")
    body.append("★ 一处必须知道的坑（本轮自己踩的）")
    body.append("    加 boss 派发时曾把 `elif _owned:` 的语句体整段抬出缩进，只剩注释 ——")
    body.append("    GDScript 里这是**解析期错误**，整份 BattleVfx.gd 加载失败，沿继承链把")
    body.append("    BattleResult / BattleScreen 一起带塌。**已修好**，并且给族里补了防线：")
    body.append("      · `cold_parse_chain_check` 已进批跑，且判据从「load() 非 null」换成 `can_instantiate()`")
    body.append("        （实测解析失败的脚本 `load()` 照样返回非 null 对象，只有它能判出来）")
    body.append("      · `audio_0922_check` 补了 `vfx_merc_dispatch_dedented`（缩进判据）")
    body.append("")
    body.append("校验")
    body.append("    _sha256清单.txt 里逐文件列出了 sha256，可自行核对。")
    body.append("")
    body.append("注意")
    body.append("    * 覆盖代码后**建议重跑**这几条：")
    body.append("        Godot_v4.7.2-stable_win64_console.exe --headless --path <你的工程> tools\\cold_parse_chain_check.tscn")
    body.append("        Godot_v4.7.2-stable_win64_console.exe --headless --path <你的工程> tools\\audio_0922_check.tscn")
    body.append("        Godot_v4.7.2-stable_win64_console.exe --headless --path <你的工程> tools\\prep_swap_check.tscn")
    body.append("      期望最后一行分别是 PASS 41、PASS 104、PASS 30。")
    body.append("    * 五条既存红与本次改动无关（voice 8 / ui_feedback 1 / procedural_ui_ratchet 3 /")
    body.append("      prep_text_coverage 1 / dynamic_call 4），逐条归因见 docs 记录第十节。")
    body.append("    * 本批 `project.godot` **逐字节未变**。")
    return "\r\n".join(body)


def write_manifest(root: str, rels) -> int:
    lines = ["%s  %s" % (sha(os.path.join(root, r.replace("/", os.sep))), r.replace("/", "\\"))
             for r in sorted(set(rels))]
    with open(os.path.join(root, "_sha256清单.txt"), "wb") as fh:
        fh.write("\r\n".join(lines).encode("utf-8"))
    return len(lines)


def stray(root: str, rels) -> list:
    """夹里存在、但不在清单上的文件（_说明 / _sha256清单 除外）。不自动处理。"""
    known = set(r.replace("/", os.sep) for r in rels)
    known |= {"_说明.txt", "_sha256清单.txt"}
    out = []
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            rel = os.path.relpath(os.path.join(dirpath, f), root)
            if rel not in known:
                out.append(rel)
    return sorted(out)


def main() -> int:
    restage = len(sys.argv) > 1 and sys.argv[1] == "restage"
    for root in (OUT_RES, OUT_CODE):
        if os.path.isdir(root):
            if not restage:
                print("[abort] 目标夹已存在，先手工处置（或用 restage）：", root)
                return 3
        else:
            if restage:
                print("[abort] restage 需要目标夹已存在：", root)
                return 3
            os.makedirs(root)

    res_lines = []
    for name in AUDIO_NAMES:
        for ext in (".mp3", ".mp3.import"):
            rel = "%s/%s%s" % (BATTLE, name, ext)
            copy(rel, OUT_RES)
            res_lines.append(rel)
    code_lines = []
    for rel, _note in CODE_FILES:
        copy(rel, OUT_CODE)
        code_lines.append(rel)
    for name in QA_FILES:
        rel = "work/_qa_922/" + name
        copy(rel, OUT_CODE)
        code_lines.append(rel)

    with open(os.path.join(OUT_RES, "_说明.txt"), "wb") as fh:
        fh.write(res_note(res_lines).encode("utf-8"))
    n_res = write_manifest(OUT_RES, res_lines)

    with open(os.path.join(OUT_CODE, "_说明.txt"), "wb") as fh:
        fh.write(code_note(code_lines).encode("utf-8"))
    n_code = write_manifest(OUT_CODE, code_lines)

    for root, rels, n in ((OUT_RES, res_lines, n_res), (OUT_CODE, code_lines, n_code)):
        extra = stray(root, rels)
        print("[%s] %s  %d 文件 / 清单 %d 条 / 清单外 %d %s"
              % ("restage" if restage else "build", os.path.basename(root), len(rels), n, len(extra), extra[:5]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
