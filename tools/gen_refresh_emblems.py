"""商店刷新键中间的四个图案（11.05 重做）。

第一版在 Godot 里每帧用 draw_colored_polygon 画：多边形没有抗锯齿、轮廓只有 5~6 个点、
还套了「低多边形切面」的随机明暗和深色描边 —— 30px 大小下又碎又糙。
这一版照樱花瓣贴图（scenes/prep/effects/PrepPetalTexture.gd）的思路：
光滑曲线 + 柔和渐变，在 4 倍大的画布上画好再缩小（等于超采样抗锯齿），烘成 PNG。
游戏里 PrepRefreshEmblem.gd 只负责摆放和动（呼吸 / 摇摆 / 点击转圈），不再画形状。

用法（工程根目录）：python tools/gen_refresh_emblems.py [输出目录]
默认输出到 assets/ui/buttons/refresh_emblem_<kind>.png（256×256）+ refresh_firefly.png。
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = 256
SS = 4                      # 超采样倍数
W = OUT * SS
R = W * 0.46                # 单位半径（图案外缘约在 1.0）
CX = CY = W / 2


def px(x, y):
    return (CX + x * R, CY + y * R)


def grid():
    ys, xs = np.mgrid[0:W, 0:W].astype(np.float32)
    return (xs - CX) / R, (ys - CY) / R


GX, GY = grid()


def blank():
    return np.zeros((W, W, 4), np.float32)


def over(dst, rgb, alpha):
    """把颜色 rgb (H,W,3 或 3) 按 alpha (H,W, 0..1) 叠到 dst 上（预乘前的普通 over）。"""
    a = np.clip(alpha, 0, 1)[..., None]
    rgb = np.broadcast_to(np.asarray(rgb, np.float32), dst[..., :3].shape)
    out_a = a + dst[..., 3:4] * (1 - a)
    safe = np.where(out_a > 1e-6, out_a, 1)
    dst[..., :3] = (rgb * a + dst[..., :3] * dst[..., 3:4] * (1 - a)) / safe
    dst[..., 3:4] = out_a


def mask_from_poly(points):
    img = Image.new("L", (W, W), 0)
    ImageDraw.Draw(img).polygon([px(*p) for p in points], fill=255)
    return np.asarray(img, np.float32) / 255.0


def smooth_mask(mask, blur):
    """并集后高斯模糊再取阈值：拼起来的形状变成一整团圆润的轮廓。"""
    img = Image.fromarray((mask * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(blur * SS))
    return (np.asarray(img, np.float32) > 127).astype(np.float32)


def blur(mask, radius):
    img = Image.fromarray((np.clip(mask, 0, 1) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(radius * SS))
    return np.asarray(img, np.float32) / 255.0


def shift(mask, dx, dy):
    return np.roll(np.roll(mask, int(dy * SS), axis=0), int(dx * SS), axis=1)


def lerp(c0, c1, t):
    t = np.clip(t, 0, 1)[..., None]
    return np.asarray(c0, np.float32) * (1 - t) + np.asarray(c1, np.float32) * t


def rgb(h):
    h = h.lstrip("#")
    return [int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]


def drop_shadow(dst, mask, strength=0.45, radius=5, dy=5):
    """深梅色软阴影：让图案从深紫底上「浮」起来一点，不用描边。"""
    over(dst, rgb("1a0510"), blur(shift(mask, 0, dy), radius) * strength)


def glow(dst, mask, color, strength, radius):
    over(dst, color, blur(mask, radius) * strength)


def save(arr, path):
    img = Image.fromarray((np.clip(arr, 0, 1) * 255).astype(np.uint8), "RGBA")
    img = img.resize((OUT, OUT), Image.LANCZOS)
    img.save(path)


# ─────────────────────────── 樱花 ───────────────────────────
# 花瓣形状与 PrepPetalTexture 同一个公式：根部窄、往上变宽、顶端圆、正中一个 V 缺口。

def petal_mask(angle, root=0.10, length=0.92, half_w=0.42):
    d = np.array([math.cos(angle), math.sin(angle)], np.float32)
    n = np.array([-d[1], d[0]], np.float32)
    along = GX * d[0] + GY * d[1]
    across = GX * n[0] + GY * n[1]
    v = (along - root) / length
    u = across / (half_w * length / 0.80)
    hw = np.where(v < 0.62, 0.80 * np.power(np.clip(np.sin(np.pi * 0.5 * np.clip(v, 0, 1) / 0.62), 0, 1), 0.6),
                  0.80 * np.sqrt(np.clip(1.0 - ((v - 0.62) / 0.40) ** 2, 0, 1)))
    inside = (v >= 0) & (v <= 1) & (np.abs(u) <= hw) & ~(v > 0.88 + 0.42 * np.abs(u))
    return inside.astype(np.float32), u, v


def draw_sakura():
    out = blank()
    base, tip, vein_c = rgb("fff0f5"), rgb("f7a0bf"), rgb("e7799f")
    union = np.zeros((W, W), np.float32)
    petals = []
    for k in range(5):
        a = -math.pi / 2 + k * 2 * math.pi / 5
        m, u, v = petal_mask(a)
        petals.append((m, u, v, a))
        union = np.maximum(union, m)
    drop_shadow(out, union, 0.5, 6, 6)
    for m, u, v, a in petals:
        # 根部粉白 → 尖端粉；朝左上的半边略亮（光从左上），正中一条淡瓣脉
        col = lerp(base, tip, np.clip((v - 0.05) / 0.9, 0, 1) ** 0.9)
        light = np.array([math.cos(a + math.pi / 2), math.sin(a + math.pi / 2)])
        # 用连续的 u（不是正负号）做左右明暗：不然花瓣正中会出一条硬折痕
        side = np.clip(u / 0.6, -1, 1) * (light @ np.array([-0.6, -0.8]))
        col = col * (1 + 0.07 * side[..., None])
        vein = (1 - np.clip(np.abs(u) / 0.06, 0, 1)) * (1 - np.clip((v - 0.15) / 0.6, 0, 1)) * 0.35
        col = col * (1 - vein[..., None]) + np.asarray(vein_c) * vein[..., None]
        # 花瓣边缘往里一点点更粉，形状更清楚（代替描边）
        edge = m - blur(m, 1.2)
        col = col * (1 - 0.25 * np.clip(edge * 3, 0, 1)[..., None]) + np.asarray(tip) * 0.25 * np.clip(edge * 3, 0, 1)[..., None]
        over(out, col, m)
    # 花心：深粉软圆 + 花蕊
    r = np.hypot(GX, GY)
    over(out, rgb("d9507e"), np.clip(1 - (r - 0.10) / 0.10, 0, 1) * 0.9)
    img = Image.new("L", (W, W), 0)
    dr = ImageDraw.Draw(img)
    dots = []
    for k in range(8):
        a = -math.pi / 2 + k * 2 * math.pi / 8 + math.pi / 8
        rr = 0.30 if k % 2 == 0 else 0.25
        end = (math.cos(a) * rr, math.sin(a) * rr)
        dr.line([px(0, 0), px(*end)], fill=255, width=int(0.028 * R))
        dots.append(end)
    over(out, rgb("c94a76"), np.asarray(img, np.float32) / 255.0 * 0.85)
    for (x, y) in dots:
        d = np.hypot(GX - x, GY - y)
        over(out, rgb("ffcf4a"), np.clip(1 - (d - 0.045) / 0.012, 0, 1))
        d2 = np.hypot(GX - x + 0.012, GY - y + 0.012)
        over(out, rgb("fff3b8"), np.clip(1 - (d2 - 0.016) / 0.010, 0, 1))
    return out


# ─────────────────────────── 雪花 ───────────────────────────

def capsule(draw, a, b, width):
    w = int(width * R)
    draw.line([px(*a), px(*b)], fill=255, width=w)
    for p in (a, b):
        x, y = px(*p)
        draw.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=255)


def draw_snowflake():
    out = blank()
    body = Image.new("L", (W, W), 0)
    core = Image.new("L", (W, W), 0)
    db, dc = ImageDraw.Draw(body), ImageDraw.Draw(core)
    for k in range(6):
        a = -math.pi / 2 + k * math.pi / 3
        d = (math.cos(a), math.sin(a))
        tip = (d[0] * 0.92, d[1] * 0.92)
        capsule(db, (0, 0), tip, 0.13)
        capsule(dc, (d[0] * 0.18, d[1] * 0.18), (d[0] * 0.86, d[1] * 0.86), 0.045)
        for at, ln in ((0.46, 0.34), (0.70, 0.22)):
            base = (d[0] * at, d[1] * at)
            for s in (-1, 1):
                b = a + s * math.radians(55)
                end = (base[0] + math.cos(b) * ln, base[1] + math.sin(b) * ln)
                capsule(db, base, end, 0.10)
                capsule(dc, base, (base[0] + math.cos(b) * ln * 0.8, base[1] + math.sin(b) * ln * 0.8), 0.035)
    hexpts = [(math.cos(-math.pi / 2 + k * math.pi / 3) * 0.24, math.sin(-math.pi / 2 + k * math.pi / 3) * 0.24) for k in range(6)]
    db.polygon([px(*p) for p in hexpts], fill=255)
    m = smooth_mask(np.asarray(body, np.float32) / 255.0, 1.5)
    glow(out, m, rgb("9fd8ff"), 0.45, 9)
    drop_shadow(out, m, 0.45, 5, 5)
    r = np.hypot(GX, GY)
    col = lerp(rgb("ffffff"), rgb("8cc9f2"), np.clip((r - 0.1) / 0.85, 0, 1))
    # 左上亮、右下暗一点
    col = col * (1 + 0.08 * np.clip(-(GX * 0.6 + GY * 0.8), -1, 1)[..., None])
    over(out, col, m)
    c = blur(np.asarray(core, np.float32) / 255.0, 0.6)
    over(out, rgb("ffffff"), c * 0.75)
    # 中心一颗小亮点
    over(out, rgb("ffffff"), np.clip(1 - (r - 0.06) / 0.05, 0, 1) * 0.9)
    return out


# ─────────────────────────── 火焰 ───────────────────────────

def tongue(points_center, widths):
    """沿中线给宽度，拼成一条两头尖的火舌多边形（点很密，再经 smooth_mask 变圆润）。"""
    left, right = [], []
    n = len(points_center)
    for i, (p, w) in enumerate(zip(points_center, widths)):
        q = points_center[min(i + 1, n - 1)]
        o = points_center[max(i - 1, 0)]
        tx, ty = q[0] - o[0], q[1] - o[1]
        ln = math.hypot(tx, ty) or 1
        nx, ny = -ty / ln, tx / ln
        left.append((p[0] + nx * w, p[1] + ny * w))
        right.append((p[0] - nx * w, p[1] - ny * w))
    return left + right[::-1]


def bez(p0, p1, p2, p3, n=40):
    pts = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        pts.append((u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
                    u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1]))
    return pts


def flame_layer(scale, dy, tongues):
    m = np.zeros((W, W), np.float32)
    # 圆底
    base = Image.new("L", (W, W), 0)
    bx, by = px(0, 0.42 * scale + dy)
    rr = 0.46 * scale * R
    ImageDraw.Draw(base).ellipse([bx - rr, by - rr, bx + rr, by + rr], fill=255)
    m = np.maximum(m, np.asarray(base, np.float32) / 255.0)
    for (p0, p1, p2, p3, w) in tongues:
        cl = bez(*[(x * scale, y * scale + dy) for (x, y) in (p0, p1, p2, p3)])
        widths = [w * scale * (1 - (i / (len(cl) - 1)) ** 1.4) for i in range(len(cl))]
        m = np.maximum(m, mask_from_poly(tongue(cl, widths)))
    return smooth_mask(m, 6 * scale)


def draw_flame():
    out = blank()
    outer = flame_layer(1.0, 0.0, [
        ((0.0, 0.45), (-0.30, 0.0), (0.25, -0.45), (0.05, -1.0), 0.40),     # 中间大火舌
        ((-0.25, 0.45), (-0.65, 0.20), (-0.60, -0.20), (-0.50, -0.55), 0.22),  # 左小火舌
        ((0.25, 0.45), (0.65, 0.15), (0.62, -0.30), (0.48, -0.66), 0.22),    # 右小火舌
    ])
    mid = flame_layer(0.72, 0.20, [
        ((0.0, 0.45), (-0.30, 0.0), (0.25, -0.45), (0.05, -1.0), 0.40),
        ((-0.25, 0.45), (-0.60, 0.15), (-0.55, -0.20), (-0.42, -0.50), 0.20),
        ((0.25, 0.45), (0.60, 0.15), (0.58, -0.25), (0.45, -0.55), 0.20),
    ])
    core = flame_layer(0.42, 0.42, [
        ((0.0, 0.45), (-0.25, 0.0), (0.20, -0.45), (0.0, -0.95), 0.42),
    ])
    glow(out, outer, rgb("ff7a1f"), 0.55, 10)
    drop_shadow(out, outer, 0.35, 5, 5)
    over(out, lerp(rgb("ff8b2b"), rgb("e2401b"), np.clip((-GY + 0.9) / 1.9, 0, 1)), outer)
    over(out, lerp(rgb("ffd04a"), rgb("ff9a2e"), np.clip((-GY + 0.9) / 1.6, 0, 1)), mid)
    over(out, lerp(rgb("fffbe0"), rgb("ffe27a"), np.clip((-GY + 0.8) / 1.2, 0, 1)), core)
    return out


# ─────────────────────────── 月牙 ───────────────────────────

def draw_moon():
    out = blank()
    c1, r1 = (-0.10, 0.05), 0.82
    c2, r2 = (0.26, -0.20), 0.70
    d1 = np.hypot(GX - c1[0], GY - c1[1])
    d2 = np.hypot(GX - c2[0], GY - c2[1])
    aa = 1.0 / R * SS * 0.5
    m = np.clip((r1 - d1) / aa, 0, 1) * np.clip((d2 - r2) / aa, 0, 1)
    glow(out, m, rgb("ffd36e"), 0.55, 12)
    drop_shadow(out, m, 0.35, 5, 5)
    # 左上亮 → 右下金；靠内缘（明暗交界）压暗一点，像有体积
    t = np.clip((GX * 0.6 + GY * 0.8 + 0.8) / 1.6, 0, 1)
    col = lerp(rgb("fff8d6"), rgb("f2b845"), t)
    inner = np.clip(1 - (d2 - r2) / 0.18, 0, 1)
    col = col * (1 - 0.18 * inner[..., None])
    over(out, col, m)
    # 外缘一圈极淡的亮边，月亮更「亮」（不画环形坑：小尺寸下像污点）
    rim = np.clip(1 - np.abs(d1 - r1 + 0.03) / 0.03, 0, 1) * m
    over(out, rgb("fffbe8"), rim * 0.45)
    return out


def draw_firefly():
    """月牙旁边的萤火：小图，代码里叠 3 颗、按相位一亮一暗。"""
    out = blank()
    r = np.hypot(GX, GY)
    over(out, rgb("ffcc55"), np.clip(1 - r / 1.0, 0, 1) ** 2.2 * 0.85)
    over(out, rgb("fff3b0"), np.clip(1 - (r - 0.22) / 0.10, 0, 1))
    over(out, rgb("ffffff"), np.clip(1 - (np.hypot(GX + 0.07, GY + 0.07) - 0.09) / 0.06, 0, 1))
    return out


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "assets", "ui", "buttons")
    os.makedirs(out_dir, exist_ok=True)
    for kind, fn in (("petal", draw_sakura), ("frost", draw_snowflake), ("fire", draw_flame), ("wisp", draw_moon)):
        save(fn(), os.path.join(out_dir, "refresh_emblem_%s.png" % kind))
        print("wrote", kind)
    save(draw_firefly(), os.path.join(out_dir, "refresh_firefly.png"))
    print("wrote firefly")


if __name__ == "__main__":
    main()
