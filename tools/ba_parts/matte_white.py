"""White-background image -> RGBA cutout (flood fill from border), optionally split into separate objects.

python tools/ba_parts/matte_white.py in.png out.png            # whole image, one cutout
python tools/ba_parts/matte_white.py in.png out_dir --split    # one RGBA per connected object, centered on a square canvas
"""
import sys, os
import numpy as np
from PIL import Image
from scipy import ndimage

src, dst = sys.argv[1], sys.argv[2]
split = "--split" in sys.argv
im = np.asarray(Image.open(src).convert("RGB")).astype(np.float32)
white = (im.min(axis=2) > 236) & (im.max(axis=2) - im.min(axis=2) < 18)
lab, n = ndimage.label(white)
border = set(np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))) - {0}
sizes = ndimage.sum(np.ones_like(lab), lab, range(1, n + 1))
holes = {i + 1 for i, a in enumerate(sizes) if a > 1500}  # enclosed big white areas (handle loops) are background too
bg = np.isin(lab, list(border | holes))
fg = ~bg
fg = ndimage.binary_opening(fg, iterations=1)
# soft edge: 1px feather
alpha = ndimage.gaussian_filter(fg.astype(np.float32), 0.7)
alpha = np.clip((alpha - 0.15) / 0.7, 0, 1)
rgba = np.dstack([im, alpha * 255]).astype(np.uint8)
if not split:
    Image.fromarray(rgba).save(dst)
    print("SAVED", dst)
else:
    os.makedirs(dst, exist_ok=True)
    objs, m = ndimage.label(ndimage.binary_dilation(fg, iterations=6))
    sizes = ndimage.sum(np.ones_like(objs), objs, range(1, m + 1))
    keep = [i + 1 for i, s in enumerate(sizes) if s > 2000]
    for k, li in enumerate(sorted(keep, key=lambda l: tuple(int(v) for v in np.argwhere(objs == l).mean(0) // 300))):
        ys, xs = np.where(objs == li)
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
        crop = rgba[y0:y1, x0:x1].copy()
        crop[..., 3] = (crop[..., 3] * (objs[y0:y1, x0:x1] == li)).astype(np.uint8)
        side = int(max(crop.shape[:2]) * 1.25)
        can = np.zeros((side, side, 4), np.uint8)
        oy, ox = (side - crop.shape[0]) // 2, (side - crop.shape[1]) // 2
        can[oy:oy + crop.shape[0], ox:ox + crop.shape[1]] = crop
        out = Image.fromarray(can).resize((1024, 1024), Image.LANCZOS)
        p = os.path.join(dst, "part_%d.png" % k)
        out.save(p)
        print("PART", p, (x0, y0, x1, y1))
