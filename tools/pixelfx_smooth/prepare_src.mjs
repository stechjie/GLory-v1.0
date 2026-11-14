// 把 third_party/pixelfx/src 复制到 tools/pixelfx_smooth/_gen/src，并给少数「自己按屏幕像素画」的库函数打补丁，
// 让它们的半径跟着平滑渲染的缩放 S 放大。原始下载目录保持不动；_gen 是生成物，不进 git。
//   node tools/pixelfx_smooth/prepare_src.mjs

import { cpSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = join(HERE, "..", "..", "third_party", "pixelfx", "src");
const GEN = join(HERE, "_gen", "src");

rmSync(GEN, { recursive: true, force: true });
cpSync(SRC, GEN, { recursive: true });

// [文件, 原文, 替换, 期望出现次数]
const PATCHES = [
  // solid / soft：屏幕空间圆盘，半径要乘 S
  ["fx/fire/_lib.js",
    "const cx = p.toX(x, y), cy = p.toY(x, y), r2 = r * r;",
    "const cx = p.toX(x, y), cy = p.toY(x, y); r *= p.S ?? 1; const r2 = r * r;", 2],
  // 孢子云：opts.toadstool=false 时不画蘑菇本体，只留毒云（毒灵/飞灵的中毒用）
  ["fx/nature/spore-burst.js",
    "    draw(p) {\n      const [sx, sy] = shape()",
    "    draw(p, _t, o) {\n      const [sx, sy] = shape()", 1],
  ["fx/nature/spore-burst.js",
    "      toadstool(p, K, Sm, Cs, g(), sx, sy, gl,",
    "      if (!o || o.toadstool !== false) toadstool(p, K, Sm, Cs, g(), sx, sy, gl,", 1],
  // 魅惑爱心：原来用 5x5 / 7x6 小位图逐格点，放大后是方块。改成按 heartShape 连续判定画（vheart），
  // 心形波纹同理；opts.eyes=false 时不画替身小人脸上的粉眼睛和腮红（魅魔眩晕用）。
  ["fx/status/charmed.js",
    "const HEART5 = bitmap(",
    `// 平滑版：按心形公式逐点判定，描边 / 亮边 / 暗边都是连续的
function vheart(p, x, y, s, R, a = 1) {
  const E = s * 1.6 + 2, inside = (lx, ly, k) => heartShape((lx - x) / k, (ly - y) / k);
  p.shade(x - E, y - E, x + E, y + E, (lx, ly, o) => {
    if (inside(lx, ly, s)) {
      const lit = !inside(lx - 0.9, ly - 0.9, s), dark = !inside(lx + 0.9, ly + 0.9, s);
      o.c = lit ? R[3] : dark ? R[1] : R[2];
    } else if (R[0] && inside(lx, ly, s + 1.0)) o.c = R[0];
    else return;
    o.a = a;
  });
}
const HEART5 = bitmap(`, 1],
  ["fx/status/charmed.js",
    "    icon(p, x, y, 4, big ? HEART7 : HEART5, R, k);",
    "    vheart(p, x, y, big ? 3.3 : 2.5, R, k);", 1],
  ["fx/status/charmed.js",
    "    for (let dy = -E; dy <= E; dy++)\n      for (let dx = -E; dx <= E; dx++) if (outer(dx, dy) && !inner(dx, dy)) p.dot(hx + dx, hy + dy, u < 0.3 ? C[5] : C[4], (1 - u) * kk * 1.3);",
    "    p.shade(hx - E, hy - E, hx + E, hy + E, (lx, ly, q) => {\n      const U = lx - hx, V = ly - hy;\n      if (heartShape(U / S1, V / S1) && !heartShape(U / (S1 - 1.3), V / (S1 - 1.3))) { q.c = u < 0.3 ? C[5] : C[4]; q.a = Math.min(1, (1 - u) * kk * 1.3); }\n    });", 1],
  ["fx/status/charmed.js",
    "  icon(p, hx, hy, 9, shaped(heartShape, s), [C[0], C[2], C[3], C[4]]);",
    "  vheart(p, hx, hy, s, [C[0], C[2], C[3], C[4]]);", 1],
  ["fx/status/charmed.js",
    "  for (const e of eyes(a)) {",
    "  for (const e of (o.eyes === false ? [] : eyes(a))) {", 1],
];

let bad = 0;
for (const [file, from, to, count] of PATCHES) {
  // git 在 Windows 上检出成 CRLF，统一成 LF 再匹配
  const path = join(GEN, file), text = readFileSync(path, "utf8").split("\r\n").join("\n");
  const n = text.split(from).length - 1;
  if (n !== count) { console.error(`${file}: 期望 ${count} 处，找到 ${n} 处（上游代码可能改了）`); bad++; continue; }
  writeFileSync(path, text.split(from).join(to));
}
if (bad) process.exit(1);
console.log(`已生成 ${GEN}（${PATCHES.length} 个补丁）`);
