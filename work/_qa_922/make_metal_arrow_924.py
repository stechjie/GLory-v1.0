# -*- coding: utf-8 -*-
"""9.24 #6：生成弓箭手「金属箭矢」弹道贴图（OGA flipbook 用）。

为什么是「生成贴图」而不是「程序化网格弹体」：
  弓箭手是**玩家棋子**，它走的是 OgaChessVFXCatalog.PROJECTILES 的 flipbook 管线
  （VFXFlipbookProjectile3D）。若改走 VFXRaceBasicAttack3D 的程序化弹体路径，
  飞行体固然变金属箭，但**命中特效会被一并替换掉** —— flipbook 自带的
  human_archer_hit.png（4x4 / 16 帧）会退化成程序化路径的通用 _spawn_linear_hit，
  而用户这条只要求改「投射物形态」。
  另外 12 只玩家棋子的弹道贴图全是手绘贴图，插一个硬边网格体反而「不贴合画风」。
  所以：**沿用 flipbook 管线，只把弹体那张图换成金属箭** ——
  影响面最小（速度 11.5 / 命中特效 / 帧率 / 世界尺寸全部不动）。

朝向：由原图 alpha 主轴实测得到 —— 箭尖恒在画面**右上 45°**（0=右, 90=上）。
        本脚本沿用同一轴，绝不改变朝向约定（否则飞行时会指错方向）。

输出：assets/vfx/oga/projectiles/human_archer_metal_arrow.png
      960x176 = 6 帧 x (160x176)，与原图同尺寸同分格。
"""

import math
import os
from PIL import Image, ImageDraw, ImageFilter

SHEET_W, SHEET_H = 960, 176
COLS, ROWS = 6, 1
CW, CH = SHEET_W // COLS, SHEET_H // ROWS   # 160 x 176

SS = 4  # 超采样倍率（画完再降采样做抗锯齿）

# 原图实测：箭尖 (131,48)、箭尾 (48,133) —— 主轴中点 (89.5, 90.5)，长 ~118px
CX, CY = 89.5, 90.5
HALF_LEN = 59.0
# 前向轴：画面右上 45°（图像坐标 y 向下，故 uy 为负）
UX, UY = math.cos(math.radians(45.0)), -math.sin(math.radians(45.0))
VX, VY = -UY, UX   # 垂直于主轴的横向单位向量

STEEL_DARK = (58, 63, 72)
STEEL_MID = (124, 132, 143)
STEEL_LIT = (198, 207, 218)
EDGE_HI = (242, 247, 255)
GLOW = (150, 172, 204)
FLETCH = (54, 59, 68)
FLETCH_LIT = (146, 154, 167)


def P(t, w):
    """主轴坐标 (t=前后, w=横向) -> 超采样画布像素坐标。"""
    x = (CX + UX * t + VX * w) * SS
    y = (CY + UY * t + VY * w) * SS
    return (x, y)


def scaled(t, w, k):
    return P(t * k, w * k)


def _poly(draw, pts, fill):
    draw.polygon(pts, fill=fill)


def _blade(t_tip, t_back, half_w, k):
    """三角镞：尖端朝前，尾端两个倒钩角。"""
    return [scaled(t_tip, 0.0, k), scaled(t_back, half_w, k), scaled(t_back, -half_w, k)]


def render_frame(scale, alpha, streak_len):
    """一帧：scale=整体缩放(绕轴中点), alpha=整体不透明度, streak_len=残影长度。"""
    W, H = CW * SS, CH * SS
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))

    # ---------- 1) 柔光层（独立层再模糊，做暗场可读性） ----------
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    _poly(gd, _blade(HALF_LEN, HALF_LEN - 32, 10.0, scale), GLOW + (150,))
    gd.line([scaled(-HALF_LEN + 20, 0, scale), scaled(HALF_LEN - 34, 0, scale)],
            fill=GLOW + (120,), width=int(4.0 * SS))
    glow = glow.filter(ImageFilter.GaussianBlur(7.0 * SS))
    img.alpha_composite(glow)

    d = ImageDraw.Draw(img)

    # ---------- 2) 箭尾残影（动能感，越靠后越长） ----------
    if streak_len > 0.5:
        d.line([scaled(-HALF_LEN, 0, scale), scaled(-HALF_LEN - streak_len, 0, scale)],
               fill=GLOW + (78,), width=int(2.6 * SS))
        d.line([scaled(-HALF_LEN, 0, scale), scaled(-HALF_LEN - streak_len * 0.62, 0, scale)],
               fill=EDGE_HI + (54,), width=int(1.1 * SS))

    # ---------- 3) 箭杆（深钢，带一条高光边） ----------
    shaft_front = HALF_LEN - 40.0
    shaft_back = -HALF_LEN + 20.0
    d.line([scaled(shaft_back, 0, scale), scaled(shaft_front, 0, scale)],
           fill=STEEL_DARK + (255,), width=int(4.6 * SS))
    d.line([scaled(shaft_back, 0, scale), scaled(shaft_front, 0, scale)],
           fill=STEEL_MID + (235,), width=int(2.6 * SS))
    # 上缘高光（偏 -w 侧，模拟侧上方来光）
    d.line([scaled(shaft_back, -1.0, scale), scaled(shaft_front, -1.0, scale)],
           fill=STEEL_LIT + (190,), width=int(1.0 * SS))

    # ---------- 4) 箭羽（两片后掠羽片） ----------
    for sgn in (-1.0, 1.0):
        vane = [
            scaled(-HALF_LEN + 23.0, 2.0 * sgn, scale),
            scaled(-HALF_LEN + 2.0, 8.8 * sgn, scale),
            scaled(-HALF_LEN + 1.0, 2.6 * sgn, scale),
        ]
        _poly(d, vane, FLETCH + (255,))
        edge = [
            scaled(-HALF_LEN + 23.0, 2.0 * sgn, scale),
            scaled(-HALF_LEN + 2.0, 8.8 * sgn, scale),
            scaled(-HALF_LEN + 2.0, 6.0 * sgn, scale),
        ]
        _poly(d, edge, FLETCH_LIT + (210,))
    # 尾帽
    _poly(d, [scaled(-HALF_LEN + 1.0, 3.0, scale), scaled(-HALF_LEN - 2.0, 3.0, scale),
              scaled(-HALF_LEN - 2.0, -3.0, scale), scaled(-HALF_LEN + 1.0, -3.0, scale)],
          STEEL_DARK + (255,))

    # ---------- 5) 箭镞（主金属块 + 前缘高光 + 中脊） ----------
    _poly(d, _blade(HALF_LEN, HALF_LEN - 32.0, 10.0, scale), STEEL_MID + (255,))
    _poly(d, _blade(HALF_LEN, HALF_LEN - 22.0, 6.6, scale), STEEL_LIT + (250,))
    # 前缘两条高光棱
    for sgn in (-1.0, 1.0):
        d.line([scaled(HALF_LEN, 0.0, scale), scaled(HALF_LEN - 31.0, 9.2 * sgn, scale)],
               fill=EDGE_HI + (235,), width=int(1.3 * SS))
    # 中脊
    _poly(d, [scaled(HALF_LEN - 1.5, 0.0, scale), scaled(HALF_LEN - 24.0, 1.5, scale),
              scaled(HALF_LEN - 24.0, -1.5, scale)], EDGE_HI + (205,))
    # 镞座（连接镞与杆）
    _poly(d, [scaled(HALF_LEN - 31.0, 3.6, scale), scaled(HALF_LEN - 40.0, 3.2, scale),
              scaled(HALF_LEN - 40.0, -3.2, scale), scaled(HALF_LEN - 31.0, -3.6, scale)],
          STEEL_DARK + (255,))

    # 降采样回 1x
    frame = img.resize((CW, CH), Image.LANCZOS)

    # 整体不透明度
    if alpha < 1.0:
        a = frame.split()[3].point(lambda v: int(v * alpha))
        frame.putalpha(a)
    return frame


def main():
    # 帧序：出膛瞬间略小略暗 -> 迅速满尺寸 -> 保持实体（末帧不做成消散残渣，
    # 因为 flipbook 是 loop=false，飞行时长可能长于 6 帧，末帧会被长时间保持）。
    plan = [
        (0.72, 0.80, 0.0),
        (0.90, 0.94, 6.0),
        (1.00, 1.00, 10.0),
        (1.00, 1.00, 13.0),
        (1.00, 0.98, 16.0),
        (1.00, 0.96, 18.0),
    ]
    assert len(plan) == COLS, "帧数与 columns 不符"

    sheet = Image.new("RGBA", (SHEET_W, SHEET_H), (0, 0, 0, 0))
    for i, (sc, al, st) in enumerate(plan):
        sheet.alpha_composite(render_frame(sc, al, st), (i * CW, 0))

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "..", "assets", "vfx", "oga", "projectiles",
                       "human_archer_metal_arrow.png")
    out = os.path.abspath(out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    sheet.save(out, "PNG", optimize=True)

    # ---- 自检：尺寸 / 分格 / 朝向 ----
    px = sheet.load()
    print("wrote", out, sheet.size)
    for c in range(COLS):
        xs, ys = [], []
        for y in range(CH):
            for x in range(CW):
                if px[c * CW + x, y][3] > 12:
                    xs.append(x); ys.append(y)
        if not xs:
            print("  frame %d EMPTY" % c); continue
        cx = sum(xs) / len(xs); cy = sum(ys) / len(ys)
        bx = by = None; bd = -1
        for x, y in zip(xs, ys):
            dd = (x - cx) ** 2 + (y - cy) ** 2
            if dd > bd:
                bd = dd; bx, by = x, y
        ang = math.degrees(math.atan2(-(by - cy), bx - cx))
        print("  frame %d bbox x[%d,%d] y[%d,%d] tip=(%d,%d) forward=%.1f deg"
              % (c, min(xs), max(xs), min(ys), max(ys), bx, by, ang))


if __name__ == "__main__":
    main()
