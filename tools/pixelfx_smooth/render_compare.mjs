// 渲染 pixelfx 特效的「原像素版」或「平滑版」，抽几帧拼成横条，存成原始 RGBA 供 compose 用。
//   node tools/pixelfx_smooth/render_compare.mjs --mode pixel  --out DIR fire/fireball melee/sword-slash
//   node tools/pixelfx_smooth/render_compare.mjs --mode smooth --out DIR fire/fireball melee/sword-slash
//   node tools/pixelfx_smooth/render_compare.mjs --compose --out DIR fire/fireball ...
// 平滑版 = 按 OUT*SS 倍分辨率绘制，再 SS 倍盒式缩小抗锯齿；像素版 = 原分辨率最近邻放大 OUT 倍。

import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { mkdirSync, writeFileSync, readFileSync } from "node:fs";

const HERE = dirname(fileURLToPath(import.meta.url));
const PFX = join(HERE, "..", "..", "third_party", "pixelfx");
const args = process.argv.slice(2), flags = {}, ids = [];
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--compose") flags.compose = true;
  else if (a.startsWith("--")) flags[a.slice(2)] = args[++i];
  else ids.push(a);
}
const OUT = +(flags.scale ?? 5), SS = +(flags.ss ?? 3), NFR = +(flags.frames ?? 6);
const outDir = flags.out;
mkdirSync(outDir, { recursive: true });
const BG = [26, 30, 42];

const { encodePNG } = await import(pathToFileURL(join(PFX, "tools", "lib", "png.mjs")).href);

if (flags.compose) {
  for (const id of ids) {
    const name = id.replace("/", "__");
    const a = JSON.parse(readFileSync(join(outDir, name + ".pixel.json")));
    const b = JSON.parse(readFileSync(join(outDir, name + ".smooth.json")));
    const pa = readFileSync(join(outDir, name + ".pixel.rgba")), pb = readFileSync(join(outDir, name + ".smooth.rgba"));
    const W = Math.max(a.w, b.w), gap = 8, H = a.h + gap + b.h;
    const img = Buffer.alloc(W * H * 4);
    for (let i = 0; i < W * H; i++) { img[i * 4] = 12; img[i * 4 + 1] = 12; img[i * 4 + 2] = 16; img[i * 4 + 3] = 255; }
    const blit = (src, w, h, oy) => { for (let y = 0; y < h; y++) src.copy(img, ((oy + y) * W) * 4, y * w * 4, (y + 1) * w * 4); };
    blit(pa, a.w, a.h, 0);
    blit(pb, b.w, b.h, a.h + gap);
    writeFileSync(join(outDir, name + ".compare.png"), encodePNG(W, H, img));
    console.log(join(outDir, name + ".compare.png"));
  }
  process.exit(0);
}

const smooth = flags.mode === "smooth";
const flushCells = smooth ? (await import(pathToFileURL(join(HERE, "smooth_painter.mjs")).href)).flushCells : null;
const SRC = smooth ? join(HERE, "_gen", "src") : join(PFX, "src");
const core = await import(pathToFileURL(join(SRC, "core", "index.js")).href);
const { createFrame, clearFrame, createFx, composite, painterFor } = core;

for (const id of ids) {
  const mod = await import(pathToFileURL(join(SRC, "fx", id + ".js")).href);
  const meta = { fps: 30, loop: false, duration: 1, options: {}, ...mod.meta };
  const [W, H] = meta.size, [OX, OY] = meta.origin;
  const n = Math.max(1, Math.round(meta.duration * meta.fps) + (meta.loop ? 0 : 1));
  const picks = new Set(Array.from({ length: NFR }, (_, k) => Math.round(((k + 0.5) / NFR) * (n - 1))));
  const S = smooth ? OUT * SS : 1;
  const frame = createFrame(W * S, H * S, 0, 0);
  frame.S = S;
  const inst = createFx({ ...mod, meta }, { x: OX, y: OY, seed: 7 });
  const tw = W * OUT, th = H * OUT, strip = Buffer.alloc(tw * NFR * th * 4);
  let col = 0;
  const raw = new Uint8ClampedArray(W * S * H * S * 4);
  for (let i = 0; i < n && col < NFR; i++) {
    if (i > 0) inst.update(1 / meta.fps);
    if (!picks.has(i)) continue;
    clearFrame(frame);
    inst.draw(frame);
    if (flushCells) flushCells(painterFor(frame));
    composite(frame, raw, null);
    // 缩到 OUT 倍：平滑版盒式平均（预乘 alpha），像素版最近邻
    const k = smooth ? SS : 1 / OUT;
    for (let y = 0; y < th; y++)
      for (let x = 0; x < tw; x++) {
        let r = 0, g = 0, b = 0, al = 0, cnt = 0;
        if (smooth) {
          for (let yy = 0; yy < SS; yy++)
            for (let xx = 0; xx < SS; xx++) {
              const j = ((y * SS + yy) * W * S + (x * SS + xx)) * 4, aa = raw[j + 3] / 255;
              r += raw[j] * aa; g += raw[j + 1] * aa; b += raw[j + 2] * aa; al += aa; cnt++;
            }
        } else {
          const j = ((Math.floor(y * k)) * W + Math.floor(x * k)) * 4, aa = raw[j + 3] / 255;
          r = raw[j] * aa; g = raw[j + 1] * aa; b = raw[j + 2] * aa; al = aa; cnt = 1;
        }
        const A = al / cnt, o = (y * tw * NFR + col * tw + x) * 4;
        // 预乘色叠到深色底上
        strip[o] = Math.min(255, r / cnt + BG[0] * (1 - A));
        strip[o + 1] = Math.min(255, g / cnt + BG[1] * (1 - A));
        strip[o + 2] = Math.min(255, b / cnt + BG[2] * (1 - A));
        strip[o + 3] = 255;
      }
    col++;
  }
  const name = id.replace("/", "__");
  writeFileSync(join(outDir, `${name}.${flags.mode}.rgba`), strip);
  writeFileSync(join(outDir, `${name}.${flags.mode}.json`), JSON.stringify({ w: tw * NFR, h: th }));
  console.log(`${id} ${flags.mode} ${n} frames, size ${W}x${H}`);
}
