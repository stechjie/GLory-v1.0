# -*- coding: utf-8 -*-
"""把 音乐/0922 的 16 个素材放到工程里的正确位置（同目录同路径风格）。

15 条新增 -> assets/audio/sfx/battle/<english_snake_case>.mp3
 1 条替换 -> assets/audio/sfx/battle/final_round_pvp_intro.mp3（覆盖，先存原件）

同时输出两份清单：
  * _map.txt        源文件 -> 目标文件名 / cue id
  * _sources.sha256 源文件 sha256（同尺寸的文件会被标出来）
"""
import hashlib
import os
import shutil

SRC = r"C:\Users\WINDOWS\Desktop\音乐\0922"
PROJ = r"C:\Users\WINDOWS\Desktop\GLory-work"
DST = os.path.join(PROJ, "assets", "audio", "sfx", "battle")
PRE = os.path.join(PROJ, "audio_0922_prechange_20260921")
OUT = os.path.join(PROJ, "work", "_qa_922")

# 源文件名 -> (目标文件名, cue_id, 说明)
NEW = [
    ("boss技能/镜像魔君技能.mp3", "boss_mirror_lord_skill.mp3",
     "boss_mirror_lord_skill", "镜像魔君 boss_mirror_lord / mirror_clone"),
    ("boss技能/雷怒核心技能.mp3", "boss_thunder_core_skill.mp3",
     "boss_thunder_core_skill", "雷怒核心 boss_thunder_core / overload_counter"),
    ("boss技能/灭世裁决者技能蓄力2秒.mp3", "boss_apocalypse_charge.mp3",
     "boss_apocalypse_charge", "灭世裁决者蓄力开始（被打断则 stop_cue）"),
    ("boss技能/灭世裁决者技能蓄力完成后的全场伤害.mp3", "boss_apocalypse_impact.mp3",
     "boss_apocalypse_impact", "灭世裁决者蓄力完成 + 打出全场伤害"),
    ("boss技能/圣愈祭司技能.mp3", "boss_holy_priest_skill.mp3",
     "boss_holy_priest_skill", "圣愈祭司 boss_holy_priest / holy_purify"),
    ("boss技能/噬魂领主技能.mp3", "boss_soul_devourer_skill.mp3",
     "boss_soul_devourer_skill", "噬魂领主 boss_soul_devourer / soul_devour"),
    ("boss技能/双生守门人复活.mp3", "boss_twin_gate_revive.mp3",
     "boss_twin_gate_revive", "双生守门人复活那一帧"),
    ("boss技能/天罚投星者技能.mp3", "boss_meteor_caster_skill.mp3",
     "boss_meteor_caster_skill", "天罚投星者 boss_meteor_caster / element_meteor"),
    ("boss技能/血怒魔王技能.mp3", "boss_blood_demon_skill.mp3",
     "boss_blood_demon_skill", "血怒魔王 boss_blood_demon / blood_rage"),
    ("战斗、特效/镜像刺客技能.mp3", "merc_gemini_assassin_skill.mp3",
     "merc_gemini_assassin_skill", "佣兵镜像刺客 merc_gemini_assassin / twin_strike"),
    ("战斗、特效/审判剑士技能触发.mp3", "merc_libra_judge_proc.mp3",
     "merc_libra_judge_proc", "佣兵审判剑士 balance_judge 增伤那次普攻"),
    ("战斗、特效/四星刺灵技能触发.mp3", "star4_spike_proc.mp3",
     "star4_spike_proc", "四星刺灵 defense_down_attack 破防那次普攻"),
    ("战斗、特效/四星毒灵、四星飞灵技能触发.mp3", "star4_poison_proc.mp3",
     "star4_poison_proc", "四星毒灵 / 四星飞灵 poison_attack 中毒那次普攻"),
    ("战斗、特效/四星巨甲灵技能触发.mp3", "star4_titan_proc.mp3",
     "star4_titan_proc", "四星巨甲灵 poison_reflect_armor_stack 反弹"),
    ("战斗、特效/四星魔童技能触发.mp3", "star4_motong_proc.mp3",
     "star4_motong_proc", "四星魔童 curse_attack 减速那次普攻"),
]

REPLACE = ("战斗、特效/最终回合pvp战斗场景开局播放.mp3",
           "final_round_pvp_intro.mp3", "final_round_pvp_intro",
           "替换既有最终回合 pvp 开局音（覆盖同路径文件）")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    os.makedirs(DST, exist_ok=True)
    os.makedirs(PRE, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)

    lines = []
    digests = {}
    for rel, target, cue, note in NEW + [REPLACE]:
        src = os.path.join(SRC, rel.replace("/", os.sep))
        dst = os.path.join(DST, target)
        if not os.path.isfile(src):
            lines.append("MISSING|%s" % rel)
            continue
        src_sha = sha256(src)
        if os.path.isfile(dst):
            # 旧文件先存一份（替换件用；新增件正常不该已存在）
            shutil.copy2(dst, os.path.join(PRE, target))
            old_note = "  [已存在，原件存入 prechange]"
        else:
            old_note = ""
        shutil.copy2(src, dst)
        digests.setdefault(src_sha, []).append(rel)
        lines.append("OK|%s|%s|%s|%d|%s%s" % (
            rel, target, cue, os.path.getsize(dst), note, old_note))

    with open(os.path.join(OUT, "_map.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    with open(os.path.join(OUT, "_sources.sha256"), "w", encoding="utf-8") as f:
        for rel, target, cue, note in NEW + [REPLACE]:
            src = os.path.join(SRC, rel.replace("/", os.sep))
            if os.path.isfile(src):
                f.write("%s  %s\n" % (sha256(src), target))

    print("\n".join(lines))
    print("---- 内容完全相同的源文件组（逐字节相同）----")
    for sha, rels in digests.items():
        if len(rels) > 1:
            print("  " + " == ".join(rels))


if __name__ == "__main__":
    main()
