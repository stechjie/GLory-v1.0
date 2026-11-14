// 把 pixelfx 特效按「平滑版」渲染并导出成 Godot 用的网格序列帧（透明 PNG + JSON 参数）。
//   node tools/pixelfx_smooth/prepare_src.mjs                      # 先生成打过补丁的副本
//   node tools/pixelfx_smooth/export_sheet.mjs <jobs.json> [名字...]  # 不写名字 = 全部导出
//
// jobs.json: { "out_dir": "res 相对路径或绝对路径", "preview_dir": "...", "jobs": [ {
//   "name": "输出文件名（不含 .png）", "fx": "holy/heal",
//   "opts": { 传给特效的参数，如 palette / seed },
//   "fps": 15,            // 输出帧率（从特效 30fps 里等间隔抽帧）
//   "scale": 3,           // 每个源像素输出几个像素
//   "t0": 0, "t1": null,  // 截取的时间段（秒），默认整段；循环特效必须给 t1
//   "pad": 0.2,           // 每边留白占内容尺寸的比例（播放模块四周 28% 会淡出）
//   "body": false,        // false = 不画特效里贴着替身小人轮廓的部分（我们的棋子轮廓不一样）
//   "crop": [x0,y0,x1,y1] // 可选：只保留源坐标里这块区域
// } ] }
// 每个 job 写出 <name>.png 和 <name>.json（列数、行数、帧数、帧率、单格尺寸、轴心在单格里的位置）。

import { join, dirname, isAbsolute, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";

const HERE = dirname(fileURLToPath(import.meta.url));
const PROJECT = resolve(HERE, "..", "..");
const GEN = join(HERE, "_gen", "src");
if (!existsSync(GEN)) { console.error("先运行 node tools/pixelfx_smooth/prepare_src.mjs"); process.exit(1); }

const { flushCells } = await import(pathToFileURL(join(HERE, "smooth_painter.mjs")).href);
const core = await import(pathToFileURL(join(GEN, "core", "index.js")).href);
const { createFrame, clearFrame, createFx, composite, painterFor, stockActor } = core;
const { encodePNG } = await import(pathToFileURL(join(PROJECT, "third_party", "pixelfx", "tools", "lib", "png.mjs")).href);

const [jobsPath, ...only] = process.argv.slice(2);
const cfg = JSON.parse(readFileSync(jobsPath, "utf8"));
const abs = (p) => (isAbsolute(p) ? p : join(PROJECT, p));
const outDir = abs(cfg.out_dir), previewDir = cfg.preview_dir ? abs(cfg.preview_dir) : null;
const metaDir = cfg.meta_dir ? abs(cfg.meta_dir) : outDir; // 参数 JSON 可以放到 assets 之外
mkdirSync(metaDir, { recursive: true });
mkdirSync(outDir, { recursive: true });
if (previewDir) mkdirSync(previewDir, { recursive: true });

const MAX_SIDE = 2048, ALPHA_MIN = 6;
// 超采样倍数：至少 3，且 scale*SS 为整数（绘制分辨率必须是整数倍）
const ssFor = (scale) => { for (let k = 3; k < 40; k++) if (Math.abs(scale * k - Math.round(scale * k)) < 1e-6) return k; throw new Error(`scale ${scale} 不合适`); };

// 替身轮廓全空：特效仍能读到头顶/胸口位置，但贴身轮廓的部分不会画出来
function emptyActor(k) {
  const a = stockActor(k);
  return { ...a, mask: { ...a.mask, data: new Uint8Array(a.mask.data.length) }, pixels: new Uint32Array(a.pixels.length) };
}

let failed = 0;
for (const job of cfg.jobs) {
  if (only.length && !only.includes(job.name)) continue;
  try { await exportJob(job); } catch (e) { failed++; console.error(`${job.name}: 失败 ${e.message}`); }
}
process.exit(failed ? 1 : 0);

async function exportJob(job) {
  const mod = await import(pathToFileURL(join(GEN, "fx", job.fx + ".js")).href);
  const meta = { fps: 30, loop: false, duration: 1, options: {}, ...mod.meta };
  const [W, H] = meta.size, [OX, OY] = meta.origin;
  const scale = job.scale ?? 2, SS = ssFor(scale), S = Math.round(scale * SS), fpsOut = job.fps ?? 15;
  const t0 = job.t0 ?? 0, t1 = job.t1 ?? (meta.loop ? null : meta.duration);
  if (t1 == null) throw new Error(`${job.name}: 循环特效要给 t1`);
  const opts = { x: OX, y: OY, seed: 7, ...(job.opts ?? {}) };
  if (meta.actor && job.body !== true) opts.actor = emptyActor(meta.actor === 2 ? 2 : 1);
  const inst = createFx({ ...mod, meta }, opts);
  const frame = createFrame(W * S, H * S, 0, 0);
  frame.S = S;
  const raw = new Uint8ClampedArray(W * S * H * S * 4);
  const ow = Math.floor((W * S) / SS), oh = Math.floor((H * S) / SS);
  const frames = [];
  const step = 1 / meta.fps;
  const nSrc = Math.round(t1 * meta.fps);
  let nextOut = t0;
  for (let i = 0; i <= nSrc; i++) {
    if (i > 0) inst.update(step);
    const t = i * step;
    if (t + 1e-6 < nextOut || t > t1 + 1e-6) continue;
    nextOut += 1 / fpsOut;
    clearFrame(frame);
    inst.draw(frame);
    flushCells(painterFor(frame));
    composite(frame, raw, null);
    // 盒式缩小 SS 倍（预乘 alpha 平均，存直通 alpha）
    const img = new Uint8ClampedArray(ow * oh * 4);
    for (let y = 0; y < oh; y++)
      for (let x = 0; x < ow; x++) {
        let r = 0, g = 0, b = 0, a = 0;
        for (let yy = 0; yy < SS; yy++)
          for (let xx = 0; xx < SS; xx++) {
            const j = ((y * SS + yy) * W * S + (x * SS + xx)) * 4, aa = raw[j + 3];
            r += raw[j] * aa; g += raw[j + 1] * aa; b += raw[j + 2] * aa; a += aa;
          }
        const o = (y * ow + x) * 4;
        if (a > 0) { img[o] = r / a; img[o + 1] = g / a; img[o + 2] = b / a; img[o + 3] = a / (SS * SS); }
      }
    frames.push(img);
  }
  // 内容包围盒
  let bx0 = ow, by0 = oh, bx1 = -1, by1 = -1;
  if (job.crop) [bx0, by0, bx1, by1] = job.crop.map((v) => Math.round(v * scale));
  else for (const img of frames)
    for (let y = 0; y < oh; y++)
      for (let x = 0; x < ow; x++)
        if (img[(y * ow + x) * 4 + 3] > ALPHA_MIN) { if (x < bx0) bx0 = x; if (x > bx1) bx1 = x; if (y < by0) by0 = y; if (y > by1) by1 = y; }
  if (bx1 < 0) throw new Error(`${job.name}: 什么都没画出来`);
  // 左右对称到轴心：播放时单格水平居中就是轴心位置，不用再算水平偏移
  if (job.symmetric_x !== false && !job.crop) {
    const pxo = OX * scale, half = Math.max(pxo - bx0, bx1 - pxo);
    bx0 = Math.max(0, Math.floor(pxo - half)); bx1 = Math.min(ow - 1, Math.ceil(pxo + half));
  }
  const pad = job.pad ?? 0.2, cw0 = bx1 - bx0 + 1, ch0 = by1 - by0 + 1;
  const px = Math.ceil(cw0 * pad), py = Math.ceil(ch0 * pad);
  const cw = cw0 + px * 2, ch = ch0 + py * 2, cx0 = bx0 - px, cy0 = by0 - py;
  // 网格：在不超过 MAX_SIDE 的前提下取最接近正方形的排法
  const n = frames.length;
  let best = null;
  for (let cols = 1; cols <= n; cols++) {
    const rows = Math.ceil(n / cols), sw = cols * cw, sh = rows * ch;
    if (sw > (job.max_side ?? MAX_SIDE) || sh > (job.max_side ?? MAX_SIDE)) continue;
    const score = Math.max(sw, sh) * 4 + sw * sh / 1e4;
    if (!best || score < best.score) best = { cols, rows, sw, sh, score };
  }
  if (!best) throw new Error(`${job.name}: ${n} 帧 ${cw}x${ch} 放不进 ${MAX_SIDE}，把 scale 或 fps 调小`);
  const sheet = new Uint8ClampedArray(best.sw * best.sh * 4);
  frames.forEach((img, k) => {
    const gx = (k % best.cols) * cw, gy = Math.floor(k / best.cols) * ch;
    for (let y = 0; y < ch; y++) {
      const sy = cy0 + y;
      if (sy < 0 || sy >= oh) continue;
      for (let x = 0; x < cw; x++) {
        const sx = cx0 + x;
        if (sx < 0 || sx >= ow) continue;
        // 指定了 crop：区域外一律透明（留白只是空边，不把区域外的内容带进来）
        if (job.crop && (sx < bx0 || sx > bx1 || sy < by0 || sy > by1)) continue;
        const s = (sy * ow + sx) * 4, d = ((gy + y) * best.sw + gx + x) * 4;
        // crop_feather（源像素）：裁切边缘往里渐隐，避免被裁掉的火花留下一条硬边
        let fa = 1;
        if (job.crop && job.crop_feather) {
          const fpx = job.crop_feather * scale, e = Math.min(sx - bx0, bx1 - sx, sy - by0, by1 - sy);
          fa = Math.max(0, Math.min(1, e / fpx));
        }
        sheet[d] = img[s]; sheet[d + 1] = img[s + 1]; sheet[d + 2] = img[s + 2]; sheet[d + 3] = img[s + 3] * fa;
      }
    }
  });
  writeFileSync(join(outDir, job.name + ".png"), encodePNG(best.sw, best.sh, sheet));
  const info = {
    fx: job.fx, columns: best.cols, rows: best.rows, frame_count: n, fps: fpsOut, duration: +(n / fpsOut).toFixed(3),
    cell_px: [cw, ch], cell_src_px: [+(cw / scale).toFixed(2), +(ch / scale).toFixed(2)],
    // 特效轴心（meta.origin）在单格里的位置，0..1，左上为 0
    pivot: [+((OX * scale - cx0) / cw).toFixed(4), +((OY * scale - cy0) / ch).toFixed(4)],
    sheet_px: [best.sw, best.sh],
  };
  writeFileSync(join(metaDir, job.name + ".json"), JSON.stringify(info, null, 1));
  // 预览：深色底上的横条，最多 8 帧
  if (previewDir) {
    const picks = Math.min(8, n), pw = cw * picks, prev = Buffer.alloc(pw * ch * 4);
    for (let k = 0; k < picks; k++) {
      const f = Math.round((k / Math.max(1, picks - 1)) * (n - 1));
      const gx = (f % best.cols) * cw, gy = Math.floor(f / best.cols) * ch;
      for (let y = 0; y < ch; y++)
        for (let x = 0; x < cw; x++) {
          const s = ((gy + y) * best.sw + gx + x) * 4, d = (y * pw + k * cw + x) * 4, a = sheet[s + 3] / 255;
          const edge = x === 0 ? 1 : 0;
          prev[d] = sheet[s] * a + (edge ? 60 : 26) * (1 - a); prev[d + 1] = sheet[s + 1] * a + (edge ? 60 : 30) * (1 - a);
          prev[d + 2] = sheet[s + 2] * a + (edge ? 70 : 42) * (1 - a); prev[d + 3] = 255;
        }
    }
    writeFileSync(join(previewDir, job.name + ".preview.png"), encodePNG(pw, ch, prev));
  }
  console.log(`${job.name}: ${job.fx} ${n} 帧 ${best.cols}x${best.rows} 单格 ${cw}x${ch} → ${best.sw}x${best.sh}`);
}
