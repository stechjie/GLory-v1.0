# 11.16 棋盘皮肤萝卜 / 卷轴 / 打开的卷轴：GPT 出的纯色底图 → 抠成透明 PNG，并按旧图的画布比例和留边摆好。
#
# 用法：python -I key_and_fit.py <raw.png> <key: green|blue> <out.png> <W> <H> <pad L,T,R,B 比例>
#   W、H = 输出画布（照旧图尺寸，进游戏后显示大小不变）；pad = 物体外框到画布边的留白比例。
# 抠图：按「离底色多近」算透明度，再把边缘被底色染到的颜色还原（去溢色），避免一圈绿边 / 蓝边。
import sys
import numpy as np
from PIL import Image

raw, key, out, W, H, pad = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
pl, pt, pr, pb = [float(v) for v in pad.split(",")]

im = np.asarray(Image.open(raw).convert("RGB")).astype(np.float32) / 255.0
r, g, b = im[..., 0], im[..., 1], im[..., 2]
if key == "green":
    dom = g - np.maximum(r, b)          # 底色的「纯度」：绿比另外两个通道高多少
else:
    dom = b - np.maximum(r, g)
# dom 接近 1 = 纯底色 → 透明；<= 0.25 = 物体本身
alpha = 1.0 - np.clip((dom - 0.25) / (0.70 - 0.25), 0.0, 1.0)
# 去溢色：半透明边缘和贴着底色的像素，把底色那个通道压回另外两个通道的最大值
if key == "green":
    g = np.minimum(g, np.maximum(r, b) + 0.04)
else:
    b = np.minimum(b, np.maximum(r, g) + 0.04)
rgba = np.dstack([r, g, b, alpha])
# 去掉孤立的小噪点（alpha 太低的当全透明）
rgba[..., 3][rgba[..., 3] < 0.06] = 0.0
img = Image.fromarray((np.clip(rgba, 0, 1) * 255).astype(np.uint8), "RGBA")
bbox = img.getchannel("A").point(lambda v: 255 if v > 20 else 0).getbbox()
img = img.crop(bbox)
box_w, box_h = W * (1 - pl - pr), H * (1 - pt - pb)
# 打开的卷轴：游戏里按 STRETCH_SCALE 拉满显示框，比例不对会把两边的卷轴棍拉扁。
# 这里只拉宽中间那段空白羊皮纸（左右各留 25% 不动），让整张比例和旧图一样。
if len(sys.argv) > 7 and sys.argv[7] == "stretch-mid":
    want_w = round(img.height * box_w / box_h)
    if want_w > img.width:
        cut_l, cut_r = round(img.width * 0.25), round(img.width * 0.75)
        mid = img.crop((cut_l, 0, cut_r, img.height)).resize((want_w - cut_l - (img.width - cut_r), img.height), Image.LANCZOS)
        wide = Image.new("RGBA", (want_w, img.height), (0, 0, 0, 0))
        wide.alpha_composite(img.crop((0, 0, cut_l, img.height)), (0, 0))
        wide.alpha_composite(mid, (cut_l, 0))
        wide.alpha_composite(img.crop((cut_r, 0, img.width, img.height)), (want_w - (img.width - cut_r), 0))
        img = wide
# 按留白比例放进 W×H：物体框 = 画布去掉留白，等比缩放后居中
s =min(box_w / img.width, box_h / img.height)
img = img.resize((max(1, round(img.width * s)), max(1, round(img.height * s))), Image.LANCZOS)
canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
x = round(W * pl + (box_w - img.width) / 2)
y = round(H * pt + (box_h - img.height))     # 贴底：萝卜的底座落在同一条线上
canvas.alpha_composite(img, (x, y))
canvas.save(out, optimize=True)
print(out, canvas.size, "object", img.size)
