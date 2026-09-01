#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""README A5 / work package C-01: third-party licence ledger.

Read-only. Joins assets.manifest.json (path / sha256 / size / class / required_by)
with the licence evidence that actually exists in the tree, and with the runtime
reachability facts parsed out of source.

Three conclusions only, never a fourth:

  proven                 an evidence file in this repo says so; path + lines cited
  awaiting_user_records  procured / commissioned / AI-generated; only the user can
                         supply the receipt or the generator's terms of service
  unknown                no evidence and no basis to classify

Guessing a licence, or promoting anything to `proven` without a citable file, is
the one failure mode this script exists to prevent.

Usage:  python tools/license_inventory.py [--check]
        --check exits 1 if the parsed runtime facts no longer match the source,
        which is how this report avoids going quietly stale.
"""

import argparse
import collections
import datetime
import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "assets.manifest.json")
OUT_JSON = os.path.join(ROOT, "reports", "third_party_license_inventory.json")
OUT_MD = os.path.join(ROOT, "docs", "THIRD_PARTY_LICENSE_GAPS.md")

PROVEN = "proven"
AWAITING = "awaiting_user_records"
UNKNOWN = "unknown"

# Where the runtime facts are parsed from. Kept as data so --check can prove the
# report still matches the tree instead of trusting a comment.
SRC_BINBUN = "effects/vfx3d/vfxv2/VFXBinbunReference3D.gd"
SRC_STARTER = "effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd"
SRC_BATTLE_MANIFEST = "scripts/assets/BattleAssetManifest.gd"
SRC_EXPORT = "export_presets.template.cfg"

VFX_ROOT = "res://effects/vfx3d/vfxv2/"
BINBUN_ROOT = VFX_ROOT + "binbun_reference/assets/"
REFPKG_ROOT = VFX_ROOT + "reference_packages/"


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8", errors="replace") as fh:
        return fh.read()


def parse_scene_table(rel, const_name):
    """Pull a `const NAME := { "key": ROOT + "tail", ... }` table out of GDScript."""
    src = read(rel)
    root_m = re.search(r'^const ROOT\s*:=\s*"([^"]+)"', src, re.M)
    root = root_m.group(1) if root_m else ""
    body = re.search(r"const %s\s*:=\s*\{(.*?)\n\}" % const_name, src, re.S)
    if not body:
        return root, {}
    out = {}
    for key, tail in re.findall(r'"([^"]+)"\s*:\s*ROOT\s*\+\s*"([^"]+)"', body.group(1)):
        out[key] = root + tail
    return root, out


def parse_battle_external_kinds():
    src = read(SRC_BATTLE_MANIFEST)
    body = re.search(r"const BATTLE_EXTERNAL_VFX\s*:=\s*\[(.*?)\n\]", src, re.S)
    if not body:
        return []
    return re.findall(r'"([^"]+)"', body.group(1))


def parse_export_excludes():
    src = read(SRC_EXPORT)
    m = re.search(r'^exclude_filter="([^"]*)"', src, re.M)
    return [p.strip() for p in m.group(1).split(",")] if m else []


def line_span(rel, needle):
    """1-indexed line numbers of every line containing `needle`.

    A missing evidence file returns [] rather than raising: losing the evidence
    must demote the group to `unknown`, not crash the report. Crashing would
    leave the previous JSON on disk still claiming `proven`.
    """
    hits = []
    path = os.path.join(ROOT, rel)
    if not os.path.isfile(path):
        return hits
    with open(path, encoding="utf-8", errors="replace") as fh:
        for i, line in enumerate(fh, 1):
            if needle in line:
                hits.append(i)
    return hits


# --- groups ------------------------------------------------------------------
# `root` is a res:// prefix. Order matters: first match wins, so the narrow
# sub-package roots come before the wide ones.
GROUPS = [
    {
        "id": "binbun_vol2_battlefx",
        "title": "BinbunVFX Vol 2 / BattleFX",
        "kind": "third_party_package",
        "root": BINBUN_ROOT + "BinbunVFX_Vol2/BattleFX/",
        "status": PROVEN,
        "license": {
            "id": "CC0-1.0",
            "name": "Creative Commons Zero v1.0 Universal",
            "commercial_use": True,
            "attribution_required": False,
        },
        "author": "Binbun3D (bun3d.com)",
        "source_url": "https://creativecommons.org/publicdomain/zero/1.0/",
        "evidence_file": "effects/vfx3d/vfxv2/binbun_reference/assets/BinbunVFX_Vol2/BattleFX/license.txt",
        "evidence_needle": "Creative Commons Zero",
    },
    {
        "id": "binbun_vol2_elemental",
        "title": "BinbunVFX Vol 2 / ElementalMagicFX",
        "kind": "third_party_package",
        "root": BINBUN_ROOT + "BinbunVFX_Vol2/ElementalMagicFX/",
        "status": PROVEN,
        "license": {
            "id": "CC0-1.0",
            "name": "Creative Commons Zero v1.0 Universal",
            "commercial_use": True,
            "attribution_required": False,
        },
        "author": "Binbun3D (bun3d.com)",
        "source_url": "https://creativecommons.org/publicdomain/zero/1.0/",
        "evidence_file": "effects/vfx3d/vfxv2/binbun_reference/assets/BinbunVFX_Vol2/ElementalMagicFX/license.txt",
        "evidence_needle": "Creative Commons Zero",
    },
    {
        "id": "binbun_vol2_shared",
        "title": "BinbunVFX Vol 2 / shared",
        "kind": "third_party_package",
        "root": BINBUN_ROOT + "BinbunVFX_Vol2/shared/",
        "status": UNKNOWN,
        "notes": [
            "Vol 2 ships its licence per sub-package; `shared/` carries no licence.txt of its own.",
            "Its only consumers are the two CC0 sub-packages above, so it is the single most "
            "likely candidate in this table to become `proven` — but 'probably covered' is not "
            "evidence, so it stays unknown until the Vol 2 download page is checked.",
        ],
        "missing_fields": ["license", "source_url"],
    },
    {
        "id": "binbun_vol1",
        "title": "BinbunVFX Vol 1",
        "kind": "third_party_package",
        "root": BINBUN_ROOT + "BinbunVFX/",
        "status": UNKNOWN,
        "notes": ["No licence file anywhere in the package."],
        "missing_fields": ["license", "author", "source_url", "redistributable"],
    },
    {
        "id": "starter_vfx",
        "title": "Starter_Vfx",
        "kind": "third_party_package",
        "root": REFPKG_ROOT + "Starter_Vfx/",
        "status": UNKNOWN,
        "notes": ["No licence file anywhere in the package."],
        "missing_fields": ["license", "author", "source_url", "redistributable"],
    },
    {
        "id": "demo_godotvfx",
        "title": "Demo_GodotVFX",
        "kind": "third_party_package",
        "root": REFPKG_ROOT + "Demo_GodotVFX/",
        "status": UNKNOWN,
        "notes": ["No licence file anywhere in the package."],
        "missing_fields": ["license", "author", "source_url", "redistributable"],
    },
    {
        "id": "font_knewave",
        "title": "Knewave 字体",
        "kind": "third_party_font",
        "root": "res://assets/fonts/",
        "status": PROVEN,
        "license": {
            "id": "OFL-1.1",
            "name": "SIL Open Font License 1.1",
            "commercial_use": True,
            "attribution_required": True,
        },
        "author": "Tyler Finck <hello@sursly.com>",
        "source_url": "http://scripts.sil.org/OFL",
        "evidence_file": "assets/fonts/Knewave-OFL.txt",
        "evidence_needle": "SIL Open Font License",
        "notes": [
            "OFL requires the licence text to travel with the font; Knewave-OFL.txt sits "
            "alongside the .ttf and is not caught by any exclude_filter.",
        ],
    },
    {
        "id": "assets_models",
        "title": "assets/models — 单位 / 佣兵 / Boss / PVE 怪 / 阵营援军",
        "kind": "produced_asset",
        "root": "res://assets/models/",
        "status": AWAITING,
        "missing_fields": ["source", "author", "license", "redistributable", "source_url"],
        "notes": [
            "The single largest block in the repo. Nothing in the tree records where these "
            "came from — purchased, commissioned, or AI-generated.",
            "AI-generated portions need the generating tool named plus its terms of service, "
            "not just a statement that the project made them.",
        ],
    },
    {
        "id": "assets_ui",
        "title": "assets/ui — 卡牌 / 图标 / 立绘 / 按钮",
        "kind": "produced_asset",
        "root": "res://assets/ui/",
        "status": AWAITING,
        "missing_fields": ["source", "author", "license", "redistributable", "source_url"],
    },
    {
        "id": "assets_board",
        "title": "assets/board — 棋盘与战场背景",
        "kind": "produced_asset",
        "root": "res://assets/board/",
        "status": AWAITING,
        "missing_fields": ["source", "author", "license", "redistributable", "source_url"],
    },
    {
        "id": "assets_audio",
        "title": "assets/audio — BGM 与 UI 音效",
        "kind": "produced_asset",
        "root": "res://assets/audio/",
        "status": AWAITING,
        "missing_fields": ["source", "author", "license", "redistributable", "source_url"],
        "notes": [
            "Music and sound effects carry their own rights, separate from art. Six mp3 files; "
            "one stock-library receipt would settle all six at once.",
        ],
    },
    {
        "id": "assets_vfx_textures",
        "title": "assets/vfx + assets/vfx_textures — 特效贴图",
        "kind": "produced_asset",
        "root": "res://assets/vfx",
        "status": AWAITING,
        "missing_fields": ["source", "author", "license", "redistributable", "source_url"],
        "notes": [
            "These ship through git (see the `!/assets/vfx/` exception in .gitignore) and are "
            "sampled by roughly 1080 references in effects/, so excluding them is not an option.",
        ],
    },
    {
        "id": "assets_shaders",
        "title": "assets/shaders — 三个 Prep 着色器",
        "kind": "project_authored_candidate",
        "root": "res://assets/shaders/",
        "status": AWAITING,
        "missing_fields": ["author"],
        "notes": [
            "Looks project-authored, but a file sitting in the repo is not proof of authorship. "
            "One line of confirmation from the user closes this group.",
        ],
    },
]

FALLBACK_GROUP = {
    "id": "vfxv2_glue",
    "title": "effects/vfx3d/vfxv2 的工程自有胶水层（registry / cache / recipes）",
    "kind": "project_authored_candidate",
    "root": None,
    "status": AWAITING,
    "missing_fields": ["author"],
    "notes": [
        "Everything under assets/ or effects/ that the group rules above did not claim. In "
        "practice this is the wrapper layer the project wrote *around* the third-party VFX "
        "packages: the two SCENES tables, VFXExternalCache, VFXStageComposerV2 and the eight "
        "recipe .tres files.",
        "Almost certainly written in this project, but authorship is asserted, not evidenced "
        "— same caveat as assets/shaders.",
        "Third-party *code* provenance is tracked separately in THIRD_PARTY_NOTICES.md "
        "section 4, which records four consulted repositories and states that no code was ported.",
    ],
}


def group_for(path, groups):
    for g in groups:
        if g["root"] and path.startswith(g["root"]):
            return g["id"]
    return FALLBACK_GROUP["id"]


def build():
    with open(MANIFEST, encoding="utf-8") as fh:
        manifest = json.load(fh)
    entries = manifest["entries"]

    _, binbun_scenes = parse_scene_table(SRC_BINBUN, "SCENES")
    _, starter_scenes = parse_scene_table(SRC_STARTER, "SCENES")
    battle_kinds = parse_battle_external_kinds()
    excludes = parse_export_excludes()

    all_scenes = dict(binbun_scenes)
    all_scenes.update(starter_scenes)

    groups = [dict(g) for g in GROUPS]
    by_id = {g["id"]: g for g in groups}
    for g in groups:
        g.setdefault("notes", [])
        g.setdefault("missing_fields", [])
        g["runtime"] = {"entry_points": []}

    # --- runtime reachability, parsed rather than asserted ---------------------
    for kind, scene_path in sorted(all_scenes.items()):
        g = by_id.get(group_for(scene_path, groups))
        if g is None:
            continue
        src = SRC_BINBUN if kind in binbun_scenes else SRC_STARTER
        lines = line_span(src, '"%s":' % kind)
        g["runtime"]["entry_points"].append({
            "kind": kind,
            "scene": scene_path,
            "declared_at": "%s:%s" % (src, ",".join(str(n) for n in lines) or "?"),
            "plays_in_real_battle": kind in battle_kinds,
            "reachable_only_via_debug": kind not in battle_kinds,
        })

    for g in groups:
        eps = g["runtime"]["entry_points"]
        g["runtime"]["plays_in_real_battle"] = any(e["plays_in_real_battle"] for e in eps)
        g["runtime"]["excluded_from_apk"] = bool(g["root"]) and any(
            pat.strip("*/") and pat.strip("*/") in g["root"] for pat in excludes)

    # --- per-entry rows -------------------------------------------------------
    rows = []
    agg = collections.defaultdict(lambda: {"files": 0, "bytes": 0})
    for e in entries:
        gid = group_for(e["path"], groups)
        g = by_id.get(gid, FALLBACK_GROUP)
        rows.append({
            "path": e["path"],
            "sha256": e.get("sha256", ""),
            "size": e.get("size", 0),
            "manifest_class": e.get("class", ""),
            "required_by_count": e.get("required_by_count", 0),
            "group": gid,
            "status": g["status"],
        })
        agg[gid]["files"] += 1
        agg[gid]["bytes"] += e.get("size", 0)

    fallback = dict(FALLBACK_GROUP)
    fallback["runtime"] = {"entry_points": [], "plays_in_real_battle": False,
                           "excluded_from_apk": False}

    out_groups = []
    for g in groups + [fallback]:
        g = dict(g)
        g["files"] = agg[g["id"]]["files"]
        g["bytes"] = agg[g["id"]]["bytes"]
        ev = g.pop("evidence_file", None)
        needle = g.pop("evidence_needle", None)
        g["evidence"] = []
        if ev:
            lines = line_span(ev, needle) if needle else []
            g["evidence"] = [{"path": ev, "lines": lines, "matched": needle}]
            if not lines:
                g["status"] = UNKNOWN
                g.pop("license", None)
                g["notes"] = list(g.get("notes", [])) + [
                    "DOWNGRADED: %s no longer contains %r, so the licence claim lost its "
                    "evidence and this group was demoted to unknown." % (ev, needle)]
        if g["status"] == PROVEN and not g["evidence"]:
            g["status"] = UNKNOWN
            g.pop("license", None)
        out_groups.append(g)

    # A group's status is the row status; recompute rows after any demotion.
    status_by_id = {g["id"]: g["status"] for g in out_groups}
    for r in rows:
        r["status"] = status_by_id.get(r["group"], UNKNOWN)

    by_status = collections.Counter(r["status"] for r in rows)
    bytes_by_status = collections.Counter()
    for r in rows:
        bytes_by_status[r["status"]] += r["size"]

    with open(MANIFEST, "rb") as fh:
        manifest_sha = hashlib.sha256(fh.read()).hexdigest()

    return {
        "schema": "glory.third_party_license_inventory/1",
        "generated_at": datetime.datetime.now(datetime.timezone.utc)
            .replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "generator": "tools/license_inventory.py",
        "source_manifest": {
            "path": "assets.manifest.json",
            "sha256": manifest_sha,
            "entries": len(entries),
            "license_id_field_present": all("license_id" in e for e in entries),
            "license_id_values": dict(collections.Counter(
                e.get("license_id", "<missing>") for e in entries)),
        },
        "caveats": [
            "assets.manifest.json carries a `license_id` field on every one of its %d entries "
            "and every single one is \"unknown\" — the column was created and never filled. "
            "This report is the sidecar that fills it; it does not write back into the manifest."
            % len(entries),
            "Do NOT read `class: third_party` (257 entries) as the number of files needing "
            "licence clearance. All 257 sit under effects/vfx3d/vfxv2/. The manifest's "
            "classifier answers 'is this an imported reference package', not 'is the licence "
            "clean'. The 2546.9 MiB of assets/models is classed runtime_required/import_meta "
            "and is entirely uncleared.",
            "`proven` requires a citable file in this repository. Three such files exist. "
            "Nothing was promoted on plausibility.",
            "COVERAGE: assets.manifest.json indexes only assets/ and effects/, so that is "
            "exactly what this ledger covers. Project source under scenes/, scripts/, ui/ and "
            "data/ is NOT enumerated here — for an *asset* licence ledger that is the right "
            "scope, but do not read '2658 entries' as 'every file in the repo'. Third-party "
            "code provenance lives in THIRD_PARTY_NOTICES.md section 4.",
        ],
        "statuses": {
            PROVEN: "An evidence file in this repo says so; path and line numbers cited.",
            AWAITING: "Procured, commissioned or AI-generated. Only the user can supply the "
                      "receipt, the commission agreement, or the generator's terms of service.",
            UNKNOWN: "No evidence in the tree and no basis to classify.",
        },
        "totals": {
            "entries": len(rows),
            "bytes": sum(r["size"] for r in rows),
            "by_status": dict(by_status),
            "bytes_by_status": dict(bytes_by_status),
        },
        "runtime_facts": {
            "parsed_from": [SRC_BINBUN, SRC_STARTER, SRC_BATTLE_MANIFEST, SRC_EXPORT],
            "battle_external_vfx_kinds": battle_kinds,
            "external_vfx_scene_count": len(all_scenes),
            "export_exclude_filter": excludes,
        },
        "groups": sorted(out_groups, key=lambda g: (-g["bytes"], g["id"])),
        "entries": sorted(rows, key=lambda r: r["path"]),
    }


def unlicensed_but_playing(doc):
    """The one number that decides whether this project can ship today."""
    out = []
    for g in doc["groups"]:
        if g["status"] == PROVEN:
            continue
        for ep in g["runtime"]["entry_points"]:
            if ep["plays_in_real_battle"]:
                out.append((g, ep))
    return out


def render_md(doc):
    lines = []
    w = lines.append
    t = doc["totals"]
    w("# 第三方许可缺口（README A5 / 工作包 C-01）")
    w("")
    w("> 由 `tools/license_inventory.py` 生成于 %s，可随时重跑。" % doc["generated_at"])
    w("> 机器可读版：`reports/third_party_license_inventory.json`。")
    w(">")
    w("> **这是缺口清单，不是授权证明。** 只有 `proven` 一档代表有据可查，")
    w("> 而且每一条都必须指到本仓库内的一个文件和行号。没有第四档。")
    w("")
    w("## 0. 一句话结论")
    w("")
    playing = unlicensed_but_playing(doc)
    w("**正式战斗里真的会播、但许可证未确认的外部 VFX 有 %d 个。**" % len(playing))
    w("在补齐来源之前这些不能随发布包分发；而直接排除它们会让对应特效失效。")
    w("")
    for g, ep in playing:
        w("- `%s` → **%s**（`%s`，声明于 `%s`）"
          % (ep["kind"], g["title"], g["status"], ep["declared_at"]))
    w("")
    w("## 1. 总账")
    w("")
    w("| 结论 | 文件数 | 字节 | 含义 |")
    w("| --- | ---: | ---: | --- |")
    for st in (PROVEN, AWAITING, UNKNOWN):
        w("| `%s` | %d | %s | %s |" % (
            st, t["by_status"].get(st, 0),
            "{:,}".format(t["bytes_by_status"].get(st, 0)),
            doc["statuses"][st]))
    w("| **合计** | **%d** | **%s** | 与 `assets.manifest.json` 逐条对齐 |"
      % (t["entries"], "{:,}".format(t["bytes"])))
    w("")
    w("## 2. 必须先说清楚的口径")
    w("")
    for c in doc["caveats"]:
        w("- %s" % c)
    w("")
    w("## 3. 分组")
    w("")
    w("| 组 | 结论 | 文件 | 体积 | 正式战斗会播 | 证据 | 缺哪些字段 |")
    w("| --- | --- | ---: | ---: | :---: | --- | --- |")
    for g in doc["groups"]:
        ev = "；".join("`%s`:%s" % (e["path"], ",".join(str(n) for n in e["lines"]))
                       for e in g["evidence"]) or "—"
        w("| %s | `%s` | %d | %.1f MiB | %s | %s | %s |" % (
            g["title"], g["status"], g["files"], g["bytes"] / 1048576.0,
            "✅" if g["runtime"]["plays_in_real_battle"] else "—",
            ev, "、".join(g.get("missing_fields", [])) or "—"))
    w("")
    w("## 4. 逐组说明")
    w("")
    for g in doc["groups"]:
        w("### %s" % g["title"])
        w("")
        w("- 结论：**`%s`**" % g["status"])
        if g.get("license"):
            lic = g["license"]
            w("- 许可证：**%s**（%s）；商用 %s；署名 %s" % (
                lic["name"], lic["id"],
                "允许" if lic["commercial_use"] else "不允许",
                "要求" if lic["attribution_required"] else "不要求"))
        if g.get("author"):
            w("- 作者：%s" % g["author"])
        if g.get("source_url"):
            w("- 来源：%s" % g["source_url"])
        for e in g["evidence"]:
            w("- 证据：`%s` 第 %s 行（匹配 %r）"
              % (e["path"], "、".join(str(n) for n in e["lines"]), e["matched"]))
        for ep in g["runtime"]["entry_points"]:
            tag = "正式战斗" if ep["plays_in_real_battle"] else "**仅 debug 路径**"
            w("- 运行时入口 `%s` → %s（%s，声明于 `%s`）"
              % (ep["kind"], ep["scene"].replace("res://effects/vfx3d/vfxv2/", ".../"),
                 tag, ep["declared_at"]))
        if g["runtime"]["excluded_from_apk"]:
            w("- **已被导出预设 exclude_filter 排除，不进 APK。**")
        if g.get("missing_fields"):
            w("- 缺失字段：%s" % "、".join(g["missing_fields"]))
        for n in g.get("notes", []):
            w("- %s" % n)
        w("")
    w("## 5. 要用户提供什么")
    w("")
    w("按能一次关掉最多缺口排序：")
    w("")
    w("1. **Binbun Vol 1 与 Starter_Vfx 的下载页与许可证。** 这两个包里有 5 个特效在正式")
    w("   战斗里真的会播。三条路任选：补证据（若同为 CC0 即转 `proven`）、换成已确认的")
    w("   Vol 2 等价效果、或改为工程内自制程序化效果。")
    w("2. **`assets/models` 与 `assets/ui` 的采购/委托记录。** 这两组占了包体的绝大部分。")
    w("   AI 生成的部分要单独说明生成工具及其服务条款。")
    w("3. **`assets/audio` 六个 mp3 的音乐库购买凭证。** 一张收据能一次关掉整组。")
    w("4. **Binbun Vol 2 的下载页**，用来确认 `shared/` 是否随 BattleFX / ElementalMagicFX")
    w("   一同 CC0。这组最有可能转绿，但「大概率覆盖」不是证据。")
    w("5. **一行确认**：`assets/shaders` 与工程源码是否全部为自有创作。")
    w("")
    w("## 6. 这份报告不做的事")
    w("")
    w("- 不猜许可证，不因为「看起来像免费素材」就转 `proven`")
    w("- 不写回 `assets.manifest.json` 的 `license_id`（该文件属 Codex）")
    w("- 不修改 `THIRD_PARTY_NOTICES.md`（按交接要求，需用户批准后才补）")
    w("- 不移动、删除或排除任何资产")
    w("")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="verify parsed runtime facts still match the source; exit 1 if not")
    args = ap.parse_args()

    doc = build()

    if args.check:
        problems = []
        rf = doc["runtime_facts"]
        if not rf["battle_external_vfx_kinds"]:
            problems.append("BATTLE_EXTERNAL_VFX parsed empty from %s" % SRC_BATTLE_MANIFEST)
        if rf["external_vfx_scene_count"] == 0:
            problems.append("no external VFX scene tables parsed")
        for g in doc["groups"]:
            if g["status"] == PROVEN and not g["evidence"]:
                problems.append("group %s is proven with no evidence" % g["id"])
            for e in g["evidence"]:
                if not e["lines"]:
                    problems.append("evidence %s no longer matches %r"
                                    % (e["path"], e["matched"]))
        if doc["totals"]["entries"] != doc["source_manifest"]["entries"]:
            problems.append("row count %d != manifest entries %d"
                            % (doc["totals"]["entries"], doc["source_manifest"]["entries"]))
        for p in problems:
            print("LICENSE_INVENTORY_CHECK fail: %s" % p)
        print("LICENSE_INVENTORY_CHECK status=%s problems=%d"
              % ("FAIL" if problems else "PASS", len(problems)))
        return 1 if problems else 0

    os.makedirs(os.path.dirname(OUT_JSON), exist_ok=True)
    with open(OUT_JSON, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=2, sort_keys=False)
        fh.write("\n")
    with open(OUT_MD, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(render_md(doc))

    t = doc["totals"]
    print("LICENSE_INVENTORY entries=%d groups=%d proven=%d awaiting=%d unknown=%d"
          % (t["entries"], len(doc["groups"]),
             t["by_status"].get(PROVEN, 0), t["by_status"].get(AWAITING, 0),
             t["by_status"].get(UNKNOWN, 0)))
    print("LICENSE_INVENTORY unlicensed_but_playing=%d" % len(unlicensed_but_playing(doc)))
    print("  -> %s" % os.path.relpath(OUT_JSON, ROOT))
    print("  -> %s" % os.path.relpath(OUT_MD, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
