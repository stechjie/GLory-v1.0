"""把 AI 生成的宠物颜色贴图整理成 BA 风格的平涂底色，并派生 BA Body(Layer4) 用的 Mask。

只读原图，输出新文件；原贴图不改。

BA 实测（见参考包 STYLE_MEASUREMENTS / SHADER_FINDINGS）：
  - 颜色贴图是干净的平涂色块，不含光影；明暗交给 Shader。
  - Body 的 _MaskTex：G 参与 (1-2G)*_MaskGSensitivity 的明暗偏移（G>0.5 更容易进阴影），
    B 是发光，A 用 0.25/0.5/0.75 三个边界选四层参数；R 在无关键词基线里没有被采样。

为宠物做的设计选择（不是 BA 实测）：
  - 原图烘焙的毛发噪点和光影 → 去掉，同色区域合并成平涂色块（Lab 空间 k-means）。
  - 原图烘焙的 AO（局部比平涂色暗多少）→ 换算进 Mask G，让凹处更容易进阴影，而不是画死在颜色里。
  - A 的四层：0=毛（皮肤式暖阴影、几乎不进阴影）1=深色布料 2=金属 3=眼睛等不进阴影的细节。

用法：
  python -I tools/ba_pet_texture/flatten_albedo.py <src.png> <out_albedo.png> <out_mask.png> \
      [--size 1024] [--k 28] [--debug-dir DIR] [--eye-rect x0,y0,x1,y1 ...]
--eye-rect 用 0..1 的 UV 坐标（左上原点，与 PNG 一致），可多次给。不给时自动找眼睛圆块。
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

LAYER_FUR, LAYER_CLOTH, LAYER_METAL, LAYER_DETAIL = 0, 1, 2, 3
# A 通道取各段中点，离 0.25/0.5/0.75 边界最远
LAYER_ALPHA = {0: 32, 1: 96, 2: 160, 3: 224}


def srgb_to_lab(rgb: np.ndarray) -> np.ndarray:
    c = rgb.astype(np.float64) / 255.0
    c = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    m = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    xyz = c @ m.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > 216 / 24389, np.cbrt(xyz), (24389 / 27 * xyz + 16) / 116)
    L = 116 * f[..., 1] - 16
    a = 500 * (f[..., 0] - f[..., 1])
    b = 200 * (f[..., 1] - f[..., 2])
    return np.stack([L, a, b], axis=-1)


def lab_to_srgb(lab: np.ndarray) -> np.ndarray:
    L, a, b = lab[..., 0], lab[..., 1], lab[..., 2]
    fy = (L + 16) / 116
    fx = fy + a / 500
    fz = fy - b / 200
    def finv(f):
        return np.where(f ** 3 > 216 / 24389, f ** 3, (116 * f - 16) / (24389 / 27))
    xyz = np.stack([finv(fx), finv(fy), finv(fz)], -1) * np.array([0.95047, 1.0, 1.08883])
    m = np.array([[3.2406, -1.5372, -0.4986], [-0.9689, 1.8758, 0.0415], [0.0557, -0.2040, 1.0570]])
    c = np.clip(xyz @ m.T, 0, 1)
    c = np.where(c <= 0.0031308, 12.92 * c, 1.055 * c ** (1 / 2.4) - 0.055)
    return (c * 255).round().astype(np.uint8)


def _masked_blur(v: np.ndarray, m: np.ndarray, sigma: float) -> np.ndarray:
    """只在有效区域内模糊，不把图集空隙的 0 混进来。"""
    num = ndimage.gaussian_filter(np.where(m, v, 0.0), sigma)
    den = ndimage.gaussian_filter(m.astype(np.float64), sigma)
    return np.where(m, num / np.maximum(den, 1e-6), v)


def kmeans(x: np.ndarray, k: int, iters: int = 25, seed: int = 7) -> np.ndarray:
    rng = np.random.default_rng(seed)
    # k-means++ 初始化
    centers = [x[rng.integers(len(x))]]
    for _ in range(1, k):
        d = np.min(((x[:, None, :] - np.array(centers)[None]) ** 2).sum(-1), axis=1)
        centers.append(x[rng.choice(len(x), p=d / d.sum())])
    c = np.array(centers)
    for _ in range(iters):
        lab = np.argmin(((x[:, None, :] - c[None]) ** 2).sum(-1), axis=1)
        for j in range(k):
            sel = x[lab == j]
            if len(sel):
                c[j] = sel.mean(0)
    return c


def assign(x: np.ndarray, c: np.ndarray, chunk: int = 262144) -> np.ndarray:
    out = np.empty(len(x), dtype=np.int32)
    for i in range(0, len(x), chunk):
        out[i:i + chunk] = np.argmin(((x[i:i + chunk, None, :] - c[None]) ** 2).sum(-1), axis=1)
    return out


def classify_center(lab: np.ndarray) -> int:
    L, a, b = lab
    chroma = float(np.hypot(a, b))
    hue = float(np.degrees(np.arctan2(b, a))) % 360
    if L < 42:
        return LAYER_CLOTH
    # 金色：黄橙色相、够饱和
    if 55 <= hue <= 100 and chroma > 22 and L > 45:
        return LAYER_METAL
    if L >= 62 and chroma < 30:
        return LAYER_FUR
    # 浅粉（内耳、鼻子、腮红）按毛处理：同样的暖阴影
    if L >= 60 and (hue < 55 or hue > 330):
        return LAYER_FUR
    return LAYER_CLOTH


def find_eye_blobs(labels_img: np.ndarray, lab_img: np.ndarray, valid: np.ndarray) -> list[tuple[slice, slice]]:
    """找「被毛包围的深色圆块、里面有白色高光」——画在贴图上的眼睛。"""
    dark = (lab_img[..., 0] < 45) & valid
    comp, n = ndimage.label(dark)
    h, w = dark.shape
    out = []
    for i, sl in enumerate(ndimage.find_objects(comp), start=1):
        if sl is None:
            continue
        ys, xs = sl
        bh, bw = ys.stop - ys.start, xs.stop - xs.start
        area = int((comp[sl] == i).sum())
        if not (0.0008 * h * w < area < 0.01 * h * w):
            continue
        if not (0.6 < bw / max(bh, 1) < 1.7):
            continue
        fill = area / (bh * bw)
        if fill < 0.5:
            continue
        # 外圈一圈像素应该大多是浅色毛
        pad = max(3, bh // 6)
        y0, y1 = max(0, ys.start - pad), min(h, ys.stop + pad)
        x0, x1 = max(0, xs.start - pad), min(w, xs.stop + pad)
        ring = np.ones((y1 - y0, x1 - x0), bool)
        ring[ys.start - y0:ys.stop - y0, xs.start - x0:xs.stop - x0] = False
        ring_light = (lab_img[y0:y1, x0:x1, 0][ring] > 70).mean()
        # 里面有高光
        inner = lab_img[ys, xs, 0]
        has_spec = (inner > 85).sum() >= 4
        if ring_light > 0.45 and has_spec:
            out.append((slice(y0, y1), slice(x0, x1)))
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("out_albedo")
    ap.add_argument("out_mask")
    ap.add_argument("--size", type=int, default=1024)
    ap.add_argument("--k", type=int, default=28)
    ap.add_argument("--ao-strength", type=float, default=0.9)
    ap.add_argument("--ab-median", type=int, default=5)
    ap.add_argument("--median", type=int, default=3)
    ap.add_argument("--mode-size", type=int, default=3)
    ap.add_argument("--border-px", type=int, default=2)
    ap.add_argument("--debug-dir", default="")
    ap.add_argument("--eye-rect", action="append", default=[])
    args = ap.parse_args()

    src = Image.open(args.src).convert("RGB")
    src = src.resize((args.size, args.size), Image.LANCZOS)
    rgb = np.asarray(src)
    h, w, _ = rgb.shape

    # 图集空隙是纯黑：不参与聚类，最后用最近岛屿颜色填补，防止 mipmap 渗黑边
    valid = rgb.max(-1) > 12
    valid = ndimage.binary_opening(valid, iterations=1)

    # 去毛发噪点：保边的中值滤波
    smooth = np.asarray(src.filter(ImageFilter.MedianFilter(args.median)))
    lab_s = srgb_to_lab(smooth)

    samp = lab_s[valid]
    rng = np.random.default_rng(3)
    pick = samp[rng.choice(len(samp), size=min(40000, len(samp)), replace=False)]
    centers = kmeans(pick, args.k)
    labels = np.full((h, w), -1, np.int32)
    labels[valid] = assign(lab_s[valid], centers)

    # 去碎点：标签图上做众数滤波（PIL ModeFilter 对 L 图有效，k<=255）
    lab_img_u8 = Image.fromarray(np.where(labels < 0, 255, labels).astype(np.uint8), "L")
    lab_img_u8 = lab_img_u8.filter(ImageFilter.ModeFilter(args.mode_size))
    labels = np.asarray(lab_img_u8).astype(np.int32)
    labels[labels == 255] = -1
    labels[~valid] = -1

    # 每个簇的平涂色：取簇内原图（平滑后）颜色的中位数，偏亮一点去掉烘焙阴影
    flat_rgb = np.zeros((args.k, 3), np.float64)
    for j in range(args.k):
        sel = smooth[labels == j]
        if len(sel):
            lum = sel.mean(-1)
            # 用亮的那一半：烘焙的阴影只会让颜色更暗
            bright = sel[lum >= np.percentile(lum, 50)]
            flat_rgb[j] = np.median(bright, axis=0)
    flat_lab = srgb_to_lab(flat_rgb[None].astype(np.uint8))[0]

    # 亮度取簇的平涂值（去掉烘焙光影），色度 a/b 取原图大半径中值（保留腮红一类的颜色渐变）。
    # 只用 k-means 硬分色会把腮红切成一圈圈色环、把布料切成多边形碎块。
    has0 = valid & (labels >= 0)
    L_map = np.zeros((h, w))
    L_map[has0] = flat_lab[labels[has0], 0]
    L_map = _masked_blur(L_map, has0, 1.2)
    ab = np.stack([ndimage.median_filter(lab_s[..., i], size=args.ab_median) for i in (1, 2)], -1)
    out = np.zeros_like(rgb)
    out[has0] = lab_to_srgb(np.concatenate([L_map[..., None], ab], -1)[has0])

    # 眼睛区域：保留原图细节（只做轻度平滑），属于「不进阴影」层
    eye_regions: list[tuple[slice, slice]] = []
    for r in args.eye_rect:
        x0, y0, x1, y1 = (float(v) for v in r.split(","))
        eye_regions.append((slice(int(y0 * h), int(y1 * h)), slice(int(x0 * w), int(x1 * w))))
    auto = not eye_regions
    if auto:
        eye_regions = find_eye_blobs(labels, lab_s, valid)

    eye_mask = np.zeros((h, w), bool)
    for ys, xs in eye_regions:
        sub = np.zeros((h, w), bool)
        sub[ys, xs] = True
        # 只取区域里非毛色的像素（眼眶、虹膜、高光、睫毛）
        not_fur = lab_s[..., 0] < 80
        e = sub & valid & ndimage.binary_dilation(sub & not_fur, iterations=2)
        eye_mask |= e
    # 不滤波：嘴线、睫毛只有 1~2 像素宽，任何中值滤波都会抹掉
    out[eye_mask] = rgb[eye_mask]

    # ---- Mask ----
    layer = np.full((h, w), LAYER_FUR, np.int32)
    center_layer = np.array([classify_center(c) for c in flat_lab])
    has = labels >= 0
    layer[has] = center_layer[labels[has]]
    layer[eye_mask] = LAYER_DETAIL

    # 金饰的花纹、星星只有几个像素宽，平涂会糊成斑块 → 和眼睛一样保留原图像素（G 仍按 AO 算）
    metal = (layer == LAYER_METAL) & valid
    out[metal] = rgb[metal]

    # G：烘焙 AO → 阴影倾向。原图（大尺度平滑后）比平涂色暗多少，就让该处更容易进阴影。
    L_orig = ndimage.gaussian_filter(srgb_to_lab(rgb)[..., 0], 2.0)
    L_flat = srgb_to_lab(out)[..., 0]
    ratio = np.clip(L_orig / np.maximum(L_flat, 1.0), 0.0, 1.5)
    # 以中位数为基准：平涂色取的是偏亮的一半，原图整体比它暗，绝对值会让全身偏向进阴影
    ref = float(np.median(ratio[valid]))
    g = 0.5 + (ref - ratio) * args.ao_strength
    g = np.clip(ndimage.gaussian_filter(np.where(valid, g, 0.5), 3.0), 0.3, 0.85)
    g[eye_mask] = 0.5

    mask = np.zeros((h, w, 4), np.uint8)
    mask[..., 0] = 0
    mask[..., 1] = (g * 255).round().astype(np.uint8)
    mask[..., 2] = 0
    mask[..., 3] = np.vectorize(LAYER_ALPHA.get)(layer).astype(np.uint8)

    # 空隙填最近岛屿的值（颜色和 Mask 都填，避免过滤时混进黑色 / 错层）
    # 原图每个 UV 岛边缘自带一圈烘焙渗出的暗边（模型上是接缝处的细黑线）：
    # 岛向内收 border_px 像素，边缘用岛内颜色重填。眼口区域不收，保留睫毛。
    keep = ndimage.binary_erosion(valid & has, iterations=args.border_px) | eye_mask
    _, (iy, ix) = ndimage.distance_transform_edt(~keep, return_indices=True)
    out = out[iy, ix]
    mask = mask[iy, ix]

    Path(args.out_albedo).parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(out, "RGB").save(args.out_albedo)
    Image.fromarray(mask, "RGBA").save(args.out_mask)

    report = {
        "src": args.src, "size": args.size, "k": args.k,
        "eye_regions_uv": [[xs.start / w, ys.start / h, xs.stop / w, ys.stop / h] for ys, xs in eye_regions],
        "eye_regions_auto": auto,
        "clusters": [
            {"rgb": [int(v) for v in flat_rgb[j]], "lab": [round(float(v), 1) for v in flat_lab[j]],
             "layer": int(center_layer[j]), "px": int((labels == j).sum())}
            for j in range(args.k)
        ],
        "layer_px": {str(i): int((layer[valid] == i).sum()) for i in range(4)},
    }
    print(json.dumps({k: report[k] for k in ("eye_regions_uv", "eye_regions_auto", "layer_px")}))
    if args.debug_dir:
        d = Path(args.debug_dir)
        d.mkdir(parents=True, exist_ok=True)
        (d / "flatten_report.json").write_text(json.dumps(report, indent=1), encoding="utf-8")
        pal = np.array([[235, 225, 210], [70, 50, 110], [220, 180, 60], [255, 40, 160]], np.uint8)
        Image.fromarray(pal[layer], "RGB").save(d / "mask_layers.png")
        Image.fromarray(mask[..., 1], "L").save(d / "mask_g.png")


if __name__ == "__main__":
    main()
