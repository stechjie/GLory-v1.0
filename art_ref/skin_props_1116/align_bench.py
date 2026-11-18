# 11.16 冰雪待命台：新图的 8 个格子对齐旧图的格子（棋子按代码里的固定位置站，格子必须对上）。
import sys
import numpy as np
from PIL import Image
from scipy.ndimage import uniform_filter1d
from scipy.signal import find_peaks

def key(path):
    a = np.asarray(Image.open(path).convert('RGB')).astype(np.float32) / 255
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    dom = g - np.maximum(r, b)
    al = 1 - np.clip((dom - 0.25) / 0.45, 0, 1)
    g = np.minimum(g, np.maximum(r, b) + 0.04)
    al[al < 0.06] = 0
    return np.dstack([r, g, b, al])

def measure(rgba):
    al = rgba[..., 3]
    rows = np.where(al.mean(1) > 0.3)[0]
    cols = np.where(al.mean(0) > 0.1)[0]
    mid = (rows.min() + rows.max()) // 2
    band = rgba[mid - 30:mid + 30]
    lum = band[..., :3].mean(-1) * band[..., 3]
    p = uniform_filter1d(lum.mean(0), 9)
    pk, _ = find_peaks(-p, distance=int((cols.max() - cols.min()) / 12), prominence=0.03)
    return rows, cols, mid, pk

old = np.asarray(Image.open(sys.argv[1]).convert('RGBA')).astype(np.float32) / 255
new = key(sys.argv[2])
for n, arr in [('old', old), ('new', new)]:
    rows, cols, mid, pk = measure(arr)
    print(n, 'rows', rows.min(), rows.max(), 'cols', cols.min(), cols.max(), 'mid', mid, 'gaps', pk.tolist())

# 新图的 7 道格间缝对到旧图上：只平移（量出来两边间距几乎一样，不用缩放），画布改成旧图尺寸
if len(sys.argv) > 3:
    _, _, omid, ogaps = measure(old)
    _, _, nmid, ngaps = measure(new)
    inner = [g for g in ngaps if ngaps.min() < g < ngaps.max()] if len(ngaps) > 7 else list(ngaps)
    dx = round(float(np.mean(np.array(ogaps[:7]) - np.array(inner[:7]))))
    dy = int(omid - nmid)
    img = Image.fromarray((np.clip(new, 0, 1) * 255).astype(np.uint8), 'RGBA')
    canvas = Image.new('RGBA', (old.shape[1], old.shape[0]), (0, 0, 0, 0))
    canvas.alpha_composite(img, (dx, dy)) if dx >= 0 and dy >= 0 else canvas.paste(img, (dx, dy), img)
    canvas.save(sys.argv[3], optimize=True)
    check = np.asarray(canvas).astype(np.float32) / 255
    print('shift', dx, dy, '-> new gaps', measure(check)[3].tolist())
