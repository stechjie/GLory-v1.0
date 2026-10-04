# 大祭司模型精修：本地接入与复现

对象为 `god_priestess` 大祭司，神族、`ren` 元素、1 费 20 金、远程辅助，技能 `nearest_ally_bless`。保留小体型、白袍、暖金刺绣与高冠造型；同族比较对象为神侍（头后圆环）与天使（横向袖翼）。本次只更改 `race_units.json` 的大祭司 `model`，玩法、朝向、缩放与攻击同步参数不变。

## 模型与改进

- 原路径：`res://assets/models/units/god_priestess_animated/god_priestess_animated.tscn`。
- 新路径：`res://assets/models/units/god_priestess_refined/god_priestess_refined.tscn`。
- 主体仍来自原三份 FBX、`skin`、UV、骨架与表情形变，三者与旧版是**同一资源实例**（契约逐动作断言 `old.mesh == new.mesh and old.skin == new.skin`）。本精修**不重建网格、不改动作**，属于材质 + 挂件级的精修。
- 新材质 `priestess_body.tres` 继承 `shaders/character_toon.gdshader`：`shadow_tint` 由旧版偏蓝 `Color(0.543, 0.604, 0.774)` 改为偏灰 `Color(0.70, 0.72, 0.77)`，`light_energy` 由 `1.35` 降到 `1.05`，并**去掉旧材质的 `next_pass` 描边**（旧版挂 `character_outline.gdshader`、宽度 0.024）。白袍纹理与暖金刺绣保留。
- Blender 制作冠冕与襟扣两件独立饰品：`priestess_mitre.glb`（3 surface / 204 三角面）与 `priestess_clasp.glb`（2 surface / 76 三角面），材质由 `priestess_ornament.gdshader` 生成，按原材质 `resource_name` 含 `gold` / `sapphire` 着色。
- 挂点走 `BoneAttachment3D`：冠冕 → `CC_Base_Head`（节点名 `MitreInlay`）、襟扣 → `CC_Base_Spine02`（节点名 `BlessingClasp`）。饰品在骨架 rest 坐标里制作，绑定时乘一次 `skeleton.get_bone_global_rest(index).affine_inverse()` 抵消 rest，之后自然跟随姿态；三套骨架各自挂一份。
- 贴图 `priestess_albedo.png` 是原 `god_priestess_texture.png` 的逐字节副本（`f256e553…`、8032752 B）；运行上限 1024、VRAM 压缩、开启 mipmap。

| 每个动作可见资源 | 原版 | 新版 |
|---|---:|---:|
| 主体三角面 | 3046 | 3046 |
| 饰件三角面 | 0 | 280 |
| 合计三角面 | 3046 | 3326 |
| Mesh surface | 1 | 6 |
| 可见材质绘制层 | 身体 + 描边 | 身体 + 冠冕 + 襟扣 |
| 最大运行贴图边长 | 512 | 1024 |

三套动作常驻共 3326 三角面 / 6 surfaces / 83 骨每套 / 1 表情形变。项目资源预算硬限制通过；1024 贴图超过 512 软建议，换取面部与刺绣可读性。此表不能替代帧时间测量。

实测（`perf.json`，RTX 3080、`gl_compatibility`、1440×900、隔离动画模型工作负载，**非整场战斗或手机结论**）：6 单位 old `mean 6.066960 ms / p95 6.069`、new `mean 6.067081 ms / p95 6.070`；12 单位 old `mean 6.066890 ms / p95 6.063`、new `mean 6.066882 ms / p95 6.070`。峰值 draw call 6 单位 68→92、12 单位 80→128（两件饰品带来的 2 surface/实例）。帧时间无回退。

## 复现与回退

复用 Godot 4.7 与 Blender 4.5；不需要联网或付费工具。先设置当前机器路径，工作目录为项目根：

```bash
GODOT_BIN="/实际路径/Godot"
BLENDER_BIN="/实际路径/Blender"
PRIESTESS_OUT="/实际路径/大祭司交付目录"
"$GODOT_BIN" --headless --path . --script tools/model_refinement/priestess_inventory.gd -- --out "$PRIESTESS_OUT"
"$BLENDER_BIN" --background --python-exit-code 1 --python tools/model_refinement/build_priestess.py -- --source "$PRIESTESS_OUT/source-idle.glb" --texture "$PWD/assets/models/units/god_priestess_animated/god_priestess_texture.png" --out "$PRIESTESS_OUT/source"
# 检查导出成功后，把 source/priestess_mitre.glb、source/priestess_clasp.glb 复制到
# assets/models/units/god_priestess_refined/。
"$GODOT_BIN" --headless --path . --import
"$GODOT_BIN" --headless --path . --script tools/model_refinement/priestess_contract_check.gd -- --out "$PRIESTESS_OUT/contract.json"
"$GODOT_BIN" --editor --path . res://scenes/debug/PriestessModelRefinementPreview.tscn
```

编辑器打开专用场景后按 F6，可循环切换三动作、正侧背、旧新对照、同族同屏与 6/12 单位；`--close` 为近景正交 1.25。资源在 `_ready()` 加载，因此编辑器静态视口不会完整显示模型，必须运行场景。Windows 用 PowerShell 的 `&` 调用实际 EXE，并按本机改路径。BLENDER 一步把两件饰品的 `.glb` 与可编辑 `.blend` 都写进 `--out`（即 `$PRIESTESS_OUT/source/`）；原始可编辑源随艺术资源包交付，不在仓库。

回退只需将 `god_priestess.model` 恢复原路径。新版继承原包装场景，原目录及其依赖仍必须保留。`assets/models` 在此仓库主要由资源包管理，普通 Git diff 不显示所有新资产；不能只交付 JSON 和脚本。

技术检查覆盖三个动作的网格/皮肤资源同一性、材质路由、剪辑名与剪辑资源、代理计时、83 骨 rest、8 个时间点的全部全局姿态、两件饰品的挂点跟随、几何预算、运行贴图 1024 上限、正式 run 根位移策略一致，以及 `race_units.json` 的正式映射；共 **2313 项**，`PRIESTESS_CONTRACT 2313 failures=[]`。变异「把 `race_units.json` 的大祭司 `model` 改回原路径」实测转红（`failures=["formal mapping"]`，退出码 1），还原后该文件 sha256 与基线逐字节相同。

贴图探针 `tools/model_refinement/priestess_texture_probe.gd` 直接用 `Image.load_from_file` 读**源 PNG**（导入后的 VRAM 压缩纹理上逐点 `get_pixel()` 会每个纹素报一次错），并断言运行时材质确实接在修复图上：`WIRED_TEXTURE .../priestess_albedo_repaired.png 1024x1024`、全图近黑 8031、三动作各 3046 个三角面中心近黑采样均为 11。性能基线用 `tools/model_refinement/priestess_perf_run.gd`（非 headless，`--rendering-driver opengl3 --resolution 1440x900`）复现上文 `perf.json`。正式路线截图为 `tools/model_refinement/priestess_battle_review.tscn`（`Node` 根，直接跑场景）与 `tools/model_refinement/priestess_prep_capture.gd`；两者都要求 `application/config/custom_user_dir_name` 以 `GLoryPriestReview` 开头，在用户目录名不符时直接 `quit(2)`，避免污染正式数据。

本机截图（前/侧/背 × 待机/移动/攻击、近景、备战、战斗回放）与性能原始记录在项目外层 `其他/大祭司精修_20261004/`。手机与联机未纳入本次，不用桌面表现代替真机结论。

## 2026-10-04 黑斑修复追加验收

用户箭头标记的裙摆黑块（run 姿势下前裙摆与侧裙摆之间的内侧，最常见落点在 x[648..766] y[633..735]）**不是精修引入的**：同一块暗区在原版模型上同样存在，且两者的贴图是逐字节同一张图。诊断过程与证据：

1. **先例掩码对本图无效**。先例 `repair_priest_atlas.py` 的判据是「RGB 最大通道 ≤ 12」。本图这类像素有 468750 个，但经 UV 覆盖栅格化（56.72%）核对，其中 **99.46% 落在 UV 足迹之外**（即图集背景/gutter）。实测：只跑先例脚本后，3046 个主体三角面中心**没有一个**被改动，渲染图与原图仅差 158/1296000 像素 —— 对可见画面是 no-op。
2. **黑斑来自反照率**，不是材质。把旧材质的 `shadow_tint` / `light_energy` 还原后重渲染，黑斑区逐像素不变；把 albedo 换成纯洋红后，黑斑**整片变洋红**，确认成因是贴图。
3. **成因是「未绘制的岛内暗区」**。本图存在 `max ∈ 13..96` 的大块暗区（连通域 3.8K~41K 像素，远大于「<256＝墨线/眼睛应保留」的量级），其中三块分别在 UV 足迹内占 40.5% / 98.5% / 22.4%。

修法：两步都走同一个新增工具 `tools/model_refinement/pad_priestess_atlas.py`。第一步用**默认 gutter 模式**（等价于先例 `repair_priest_atlas.py`）补齐图集背景：填 `max ≤ 12`、连通域 ≥ 256 像素的纯黑空洞，并向 `max < 80` 的邻接像素扩边 3 次。第二步用 `--keep-gutter`，只填**UV 足迹内**：先把覆盖掩码膨胀 3px、与暗区求交，**然后**才做四邻接连通域标记（顺序很关键——否则暗岛会与图集背景连成一块、被尺寸过滤整片滤掉，实测 33 个含黑斑的暗岛会全部漏掉），填 `max ≤ 96`、连通域 ≥ 800 像素的暗区；从边界已绘制色传播，仅平滑新填区域，**小于 800 像素的小暗点（眼睛/墨线）原样保留**。两步都声明 `painted_pixels_unchanged = true` / `alpha_unchanged = true`。

| 指标 | 修复前（原图） | 第一步 gutter 单独 | 最终修复图 |
|---|---:|---:|---:|
| 三角面中心采样近黑（每动作，共 3046） | 82 | 82 | **11** |
| 全图近黑像素（sum<0.08，共 4194304） | 468750* | 8337 | **8031** |
| 渲染近黑像素（裙摆取样框） | 4723 | 4723 | **145** |
| 渲染暗像素 <120 | 6603 | 6603 | **302** |

\* 该行为「`max ≤ 12` 的像素数」；其余为该阈值的 sum 定义。

交付物 `priestess_albedo_repaired.png`（`a0b7b018…`，7345359 B）替换原先那张 no-op 修复图，`priestess_body.tres` 指向它；原图 `priestess_albedo.png` 保留作备份。**未改 UV、网格、骨架、动作或 Shader**。运行贴图仍为 1024 上限、VRAM 压缩与 mipmap，纹理数量、几何数量与绘制层数不变。修复后三动作契约复验 **2313 项通过**；脸部与眼睛裁剪逐像素一致。

重建修复贴图（项目根目录，Python 需安装 Pillow 与 NumPy）：

```bash
"$GODOT_BIN" --headless --path . --script tools/model_refinement/priestess_uv_dump.gd -- --out /实际路径/tri_uv.json
python3 tools/model_refinement/pad_priestess_atlas.py \
  --source assets/models/units/god_priestess_refined/priestess_albedo.png \
  --tri-uv /实际路径/tri_uv.json \
  --out /实际路径/step1_gutter.png \
  --report /实际路径/step1_gutter.json
python3 tools/model_refinement/pad_priestess_atlas.py \
  --source /实际路径/step1_gutter.png --keep-gutter \
  --tri-uv /实际路径/tri_uv.json \
  --out assets/models/units/god_priestess_refined/priestess_albedo_repaired.png \
  --report /实际路径/atlas-repair.json
```

脚本参数为**本图专用**：`--dark-threshold 96`、`--min-size 800`、`--coverage-dilate 3`，第一步用默认的 `--gutter-threshold 12` / `--gutter-min-size 256` / `--gutter-fringe 80`。它不是通用去黑算法；换角色或重绘原图后必须重新审查掩码（先出叠加图看填了哪里），避免误伤眼睛和暗色图案。填充区是「从边界传播的颜色」，在放大近景下会呈现较柔和的渐变，这是有意的取舍（原为纯黑空洞）。

UV 覆盖掩码由 `--tri-uv`（`priestess_uv_dump.gd` 的输出）在工具内部栅格化：顶点落在 `(u*w, v*h)`，用 Pillow `ImageDraw.polygon` 填充（Godot 贴图原点在左上，不做 v 翻转）。该栅格化与交付时用的 `coverage_mask.png` **逐像素相同**（IoU 1.000，覆盖率 0.56723）。按上面两条命令原样重跑，`step1_gutter.png`（`bc520121…`，7471985 B）与 `priestess_albedo_repaired.png`（`a0b7b018…`，7345359 B）与仓库里的文件**逐字节相同**，第二步统计（31 个连通域 / 169927 核心像素 / 173353 含边缘）也逐项一致。为避免误用，工具也接受 `--coverage <png>` 直接读现成掩码。

再次导出或恢复资源时，检查 `priestess_body.tres` 仍引用 `priestess_albedo_repaired.png`；不要误接回保留作原始备份的 `priestess_albedo.png`。重新导入后检查运行尺寸上限 1024、VRAM 压缩与 mipmap，并复查正侧背、近景/战斗距离及三动作。11 个残留中心只是采样点口径，不代表全图自动验收。
