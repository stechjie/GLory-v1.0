"""烘焙漏射线的像素（纯黑）用最近的有效颜色填上；UV 空白区也一并填，免得 mipmap 渗黑。

python tools/ba_parts/fill_bake_holes.py <basecolor.png> [...]
"""
import sys
import numpy as np
from PIL import Image
from scipy import ndimage

for p in sys.argv[1:]:
    im = Image.open(p)
    rgba = np.asarray(im.convert("RGBA"))
    a = rgba[..., :3]
    bad = (rgba[..., 3] < 128) | (a.max(axis=2) < 30)
    # 有效区域边缘一圈也不可信（采样落在三角面外沿），一起重填
    bad = ndimage.binary_dilation(bad, iterations=2)
    idx = ndimage.distance_transform_edt(bad, return_distances=False, return_indices=True)
    out = a[idx[0], idx[1]]
    Image.fromarray(out).save(p)
    print("filled", p, "%.1f%%" % (bad.mean() * 100))
