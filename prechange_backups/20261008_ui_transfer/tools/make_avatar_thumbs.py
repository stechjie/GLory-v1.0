"""从 data/avatars.json 生成头像选择器用的缩略图，并可选出一张对照表。

为什么要缩略图：选择器要把**所有**可选头像同时铺出来给玩家挑，这是每个玩家
进资料页必做的第一个操作。原图 330x330、解码后每张约 435 KB 显存；20 张就是
8-9 MB 加一次明显的加载卡顿。128x128 把它压到约 1/6。资料页上的大图仍用原图。

用法：
    python tools/make_avatar_thumbs.py            # 生成缩略图
    python tools/make_avatar_thumbs.py --sheet    # 顺带出一张对照表供人工挑选

依赖 Pillow（pip install Pillow）。这是**构建期工具**，不进游戏运行时。

⚠️ 生成新 PNG 之后要让 Godot 重新导入一次，否则运行时读不到：
    Godot_v4.7.1-stable_win64.exe --headless --path . --import
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

from PIL import Image, ImageDraw

REPO = pathlib.Path(__file__).resolve().parent.parent
CATALOG = REPO / "data" / "avatars.json"

# 对照表的排版。只影响人工挑选那张图，不影响游戏。
SHEET_COLS = 5
SHEET_CELL = 160
SHEET_LABEL_H = 22
SHEET_BG = (28, 32, 44)
SHEET_FG = (232, 232, 232)


def res_to_path(res_path: str) -> pathlib.Path:
    """把 res://a/b.png 换成仓库里的实际路径。"""
    if not res_path.startswith("res://"):
        raise ValueError(f"不是 res:// 路径：{res_path}")
    return REPO / res_path[len("res://") :]


def load_catalog() -> dict:
    return json.loads(CATALOG.read_text(encoding="utf-8"))


def build_thumbs(catalog: dict) -> list[tuple[str, pathlib.Path]]:
    size = int(catalog["thumb_size"])
    out_dir = res_to_path(catalog["thumb_dir"])
    out_dir.mkdir(parents=True, exist_ok=True)

    made: list[tuple[str, pathlib.Path]] = []
    for entry in catalog["avatars"]:
        src = res_to_path(entry["source"])
        if not src.exists():
            # 不静默跳过：清单指向不存在的图，是这套 id 映射唯一会坏的方式。
            raise SystemExit(f"源图不存在：{entry['id']} -> {src}")
        img = Image.open(src).convert("RGBA")
        img = img.resize((size, size), Image.LANCZOS)
        dst = out_dir / f"{entry['id']}.png"
        img.save(dst, "PNG")
        made.append((entry["id"], dst))
    return made


def build_sheet(catalog: dict, out: pathlib.Path) -> None:
    """人工挑选用的对照表：每格一张缩略图 + id 与中文名。"""
    entries = catalog["avatars"]
    cols = SHEET_COLS
    rows = (len(entries) + cols - 1) // cols
    cell_h = SHEET_CELL + SHEET_LABEL_H
    sheet = Image.new("RGB", (cols * SHEET_CELL, rows * cell_h), SHEET_BG)
    draw = ImageDraw.Draw(sheet)

    for i, entry in enumerate(entries):
        cx = (i % cols) * SHEET_CELL
        cy = (i // cols) * cell_h
        img = Image.open(res_to_path(entry["source"])).convert("RGBA")
        img = img.resize((SHEET_CELL - 16, SHEET_CELL - 16), Image.LANCZOS)
        sheet.paste(img, (cx + 8, cy + 4), img)
        draw.text(
            (cx + 8, cy + SHEET_CELL),
            f"{entry['id']}  {entry['name']}",
            fill=SHEET_FG,
        )

    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out, "PNG")


def main() -> int:
    # 仓库路径里有中文（…/桌面/GLory-v1.0），Windows 控制台默认 cp1252 编码不下，
    # 打印路径时会直接抛 UnicodeEncodeError —— 图已经生成完了，却报了个失败。
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")

    parser = argparse.ArgumentParser()
    parser.add_argument("--sheet", action="store_true", help="顺带生成人工挑选用的对照表")
    parser.add_argument("--sheet-out", default=str(REPO / "reports" / "avatar_sheet.png"))
    args = parser.parse_args()

    catalog = load_catalog()

    ids = [e["id"] for e in catalog["avatars"]]
    if len(ids) != len(set(ids)):
        raise SystemExit("data/avatars.json 里有重复 id")
    if catalog["default_id"] not in ids:
        raise SystemExit(f"default_id 不在清单里：{catalog['default_id']}")

    made = build_thumbs(catalog)
    print(f"AVATAR_THUMBS ok count={len(made)} dir={res_to_path(catalog['thumb_dir'])}")

    if args.sheet:
        out = pathlib.Path(args.sheet_out)
        build_sheet(catalog, out)
        print(f"AVATAR_SHEET ok path={out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
