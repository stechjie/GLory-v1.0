// 把 pixelfx 的 Painter 改成「高分辨率 + 真透明」绘制，让像素特效变平滑。
// 思路：pixelfx 的形状（圆、光束、弧、多边形……）本来就是按数学公式逐像素判定的，
// 只要在 局部坐标 → 屏幕坐标 这一步乘上缩放 S，形状就会在 S 倍分辨率下重新算一遍，边缘自然变顺；
// 再把「有序抖动表示半透明」换成真正的 alpha 混合，把 1 像素的点/线换成软圆点/圆头线。
// 最后由调用方按超采样倍数缩小一次，得到抗锯齿边缘。
// 不改 third_party/pixelfx 里的原文件：作用在 prepare_src.mjs 生成的 _gen 副本上。

import { Painter } from "./_gen/src/core/painter.js";

const P = Painter.prototype;
const orig = {
  reset: P.reset,
  glow: P.glow,
  glowLine: P.glowLine,
  glowRing: P.glowRing,
};
const call = (v, ...args) => (typeof v === "function" ? v(...args) : v);

P.reset = function () {
  orig.reset.call(this);
  this.S = this.frame.S ?? 1;
  return this;
};

// 坐标变换：tx/ty 仍是原分辨率的帧坐标，屏幕坐标统一乘 S
P.toX = function (x, y) { return this.S * (this.tx + x * this.fx * this.cs - y * this.sn); };
P.toY = function (x, y) { return this.S * (this.ty + x * this.fx * this.sn + y * this.cs); };
P.fromX = function (sx, sy) { const dx = sx / this.S - this.tx, dy = sy / this.S - this.ty; return (dx * this.cs + dy * this.sn) * this.fx; };
P.fromY = function (sx, sy) { const dx = sx / this.S - this.tx, dy = sy / this.S - this.ty; return -dx * this.sn + dy * this.cs; };
// 少数特效自己算屏幕格子再 put：给出格子中心，至少位置对
P.cellX = function (x, y) { return Math.floor(this.toX(x, y)); };
P.cellY = function (x, y) { return Math.floor(this.toY(x, y)); };

// 半透明不再用抖动，改成真 alpha 混合
P.put = function (sx, sy, c, a = 1) {
  if (!c) return;
  const af = a * this.fade;
  if (af >= 0.999) {
    const x = sx - this.ox, y = sy - this.oy;
    if (x < 0 || y < 0 || x >= this.w || y >= this.h) return;
    this.C[y * this.w + x] = c;
    return;
  }
  // blendPx 内部会再乘一次 fade，这里先除掉
  this.blendPx(sx, sy, c, this.fade > 0 ? af / this.fade : 0);
};

// ---- 逐格点画（px / dot / light / blend）：先收进原分辨率的「格子层」，
// 下一次别的绘制前（或帧结束 flush）再整体放大：覆盖度双线性插值后取阈值得到平滑轮廓，颜色双线性过渡。
// 这样一片相邻的格子会合成一块边缘圆顺的形状，而不是一颗颗珠子；孤立的单格变成小圆点。
function cells(p) {
  const f = p.frame;
  let g = f._cells;
  const w0 = Math.round(p.w / p.S), h0 = Math.round(p.h / p.S);
  if (!g || g.w !== w0 || g.h !== h0) {
    g = f._cells = { w: w0, h: h0, col: new Float32Array(w0 * h0 * 4), cov: new Float32Array(w0 * h0), lit: new Float32Array(w0 * h0 * 3), dirty: false, x0: 0, y0: 0, x1: 0, y1: 0 };
  }
  return g;
}
function cellIndex(p, g, x, y) {
  const S = p.S, fx0 = Math.floor(x) + 0.5, fy0 = Math.floor(y) + 0.5;
  const cx = Math.floor(p.toX(fx0, fy0) / S - p.ox / S), cy = Math.floor(p.toY(fx0, fy0) / S - p.oy / S);
  if (cx < 0 || cy < 0 || cx >= g.w || cy >= g.h) return -1;
  if (!g.dirty) { g.dirty = true; g.x0 = g.x1 = cx; g.y0 = g.y1 = cy; }
  else { if (cx < g.x0) g.x0 = cx; if (cx > g.x1) g.x1 = cx; if (cy < g.y0) g.y0 = cy; if (cy > g.y1) g.y1 = cy; }
  return cy * g.w + cx;
}
function cellPut(p, x, y, c, a) {
  const g = cells(p), i = cellIndex(p, g, x, y);
  if (i < 0) return;
  const r = (c & 255) / 255, gg = ((c >>> 8) & 255) / 255, b = ((c >>> 16) & 255) / 255, j = i * 4;
  const col = g.col, k = a; // a 已含 fade
  // premultiplied over
  col[j] = r * k + col[j] * (1 - k);
  col[j + 1] = gg * k + col[j + 1] * (1 - k);
  col[j + 2] = b * k + col[j + 2] * (1 - k);
  col[j + 3] = k + col[j + 3] * (1 - k);
  g.cov[i] = 1;
}
function cellLight(p, x, y, c, k) {
  const g = cells(p), i = cellIndex(p, g, x, y);
  if (i < 0) return;
  g.lit[i * 3] += (c & 255) * k; g.lit[i * 3 + 1] += ((c >>> 8) & 255) * k; g.lit[i * 3 + 2] += ((c >>> 16) & 255) * k;
  g.cov[i] = Math.max(g.cov[i], 0); // 光不影响轮廓
}
const smooth01 = (e0, e1, v) => { const t = Math.min(1, Math.max(0, (v - e0) / (e1 - e0))); return t * t * (3 - 2 * t); };
function flushCells(p) {
  const g = p.frame._cells;
  if (!g || !g.dirty) return;
  g.dirty = false;
  const S = p.S, W = p.w, C = p.C, L = p.L, { w: w0, h: h0, col, cov, lit } = g;
  const sx0 = Math.max(0, (g.x0 - 1) * S), sx1 = Math.min(W - 1, (g.x1 + 2) * S - 1);
  const sy0 = Math.max(0, (g.y0 - 1) * S), sy1 = Math.min(p.h - 1, (g.y1 + 2) * S - 1);
  const at = (arr, n, x, y, ch) => (x < 0 || y < 0 || x >= w0 || y >= h0 ? 0 : arr[(y * w0 + x) * n + ch]);
  for (let sy = sy0; sy <= sy1; sy++) {
    const v = (sy + 0.5) / S - 0.5, y0 = Math.floor(v), fy = v - y0;
    for (let sx = sx0; sx <= sx1; sx++) {
      const u = (sx + 0.5) / S - 0.5, x0 = Math.floor(u), fx = u - x0;
      const w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy;
      const bil = (arr, n, ch) => at(arr, n, x0, y0, ch) * w00 + at(arr, n, x0 + 1, y0, ch) * w10 + at(arr, n, x0, y0 + 1, ch) * w01 + at(arr, n, x0 + 1, y0 + 1, ch) * w11;
      const i = sy * W + sx;
      // 光：直接双线性相加
      const lr = bil(lit, 3, 0), lg = bil(lit, 3, 1), lb = bil(lit, 3, 2);
      if (lr + lg + lb > 0.5) {
        const d = L[i];
        const r = Math.min(255, (d & 255) + lr) | 0, gg = Math.min(255, ((d >>> 8) & 255) + lg) | 0, b = Math.min(255, ((d >>> 16) & 255) + lb) | 0;
        L[i] = (255 << 24) | (b << 16) | (gg << 8) | r;
      }
      const cv = bil(cov, 1, 0);
      if (cv < 0.3) continue;
      const edge = smooth01(0.4, 0.6, cv);
      if (edge <= 0) continue;
      const pa = bil(col, 4, 3);
      if (pa <= 0.002) continue;
      // 颜色 = 预乘色 / alpha；透明度 = 平均 alpha / 覆盖度 × 轮廓
      const cr = bil(col, 4, 0) / pa, cg = bil(col, 4, 1) / pa, cb = bil(col, 4, 2) / pa;
      const a = Math.min(1, pa / cv) * edge;
      const d = C[i], da = (d >>> 24) / 255, oa = a + da * (1 - a), kk = oa > 0 ? a / oa : 0;
      const mix = (s, cc) => Math.min(255, cc * 255 * kk + ((d >>> s) & 255) * (1 - kk)) & 255;
      C[i] = (((oa * 255) & 255) << 24) | (mix(16, cb) << 16) | (mix(8, cg) << 8) | mix(0, cr);
    }
  }
  // 清掉用过的区域
  for (let y = Math.max(0, g.y0); y <= Math.min(h0 - 1, g.y1); y++)
    for (let x = Math.max(0, g.x0); x <= Math.min(w0 - 1, g.x1); x++) {
      const i = y * w0 + x;
      cov[i] = 0; col[i * 4] = col[i * 4 + 1] = col[i * 4 + 2] = col[i * 4 + 3] = 0; lit[i * 3] = lit[i * 3 + 1] = lit[i * 3 + 2] = 0;
    }
}
export { flushCells };

P.px = function (x, y, c) { if (c && this.fade > 0) cellPut(this, x, y, c, Math.min(1, this.fade)); };
P.dot = function (x, y, c, a = 1) { if (c && a > 0 && this.fade > 0) cellPut(this, x, y, c, Math.min(1, a * this.fade)); };
P.light = function (x, y, c, k = 1) { const kk = k * this.fade * this.lightK; if (c && kk > 0.004) cellLight(this, x, y, c, kk); };
P.blend = function (x, y, c, a) { if (c && a * this.fade > 0.004) cellPut(this, x, y, c, Math.min(1, a * this.fade)); };

// 任何直接写屏幕缓冲的操作之前，先把格子层落下去，保持前后顺序
for (const name of ["put", "add", "blendPx"]) {
  const fn = P[name];
  P[name] = function (...args) { const g = this.frame._cells; if (g && g.dirty) flushCells(this); return fn.apply(this, args); };
}

// 1 像素线 → 圆头细光束
P.line = function (x0, y0, x1, y1, c, a = 1) {
  this.beam(x0 + 0.5, y0 + 0.5, x1 + 0.5, y1 + 0.5, 1.15, (u) => call(c, u), (u) => call(a, u));
};

// 轴对齐矩形原本逐格 put，改走 shade（局部坐标判定，边缘随 S 变细）
P.rect = function (x, y, w, h, c, a = 1) {
  this.shade(x, y, x + w, y + h, (lx, ly, o) => {
    if (lx < x || ly < y || lx >= x + w || ly >= y + h) return;
    o.c = c; o.a = a;
  });
};

// 光晕半径是屏幕像素，跟着 S 放大
P.glow = function (x, y, r, c, k) { return orig.glow.call(this, x, y, r * this.S, c, k); };
P.glowLine = function (x0, y0, x1, y1, r, c, k) { return orig.glowLine.call(this, x0, y0, x1, y1, r * this.S, c, k); };
P.glowRing = function (x, y, R, r, c, k) { return orig.glowRing.call(this, x, y, R * this.S, r * this.S, c, k); };

export { Painter };
