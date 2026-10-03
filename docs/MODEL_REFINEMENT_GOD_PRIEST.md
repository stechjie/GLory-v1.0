# 神侍模型精修：本地接入与复现

对象为 `god_priest` 神侍，神族、`ren` 元素、远程治疗/净化辅助，技能 `lowest_ally_heal`。保留小体型、白袍、暖金细节和头后圆环；同族比较对象为大祭司（高冠）与天使（横向袖翼）。本次只更改 `race_units.json` 的神侍 `model`，玩法、朝向、缩放与攻击同步参数不变。

## 模型与改进

- 原路径：`res://assets/models/units/god_priest_halo_animated/god_priest_animated.tscn`。
- 新路径：`res://assets/models/units/god_priest_refined/god_priest_refined.tscn`。
- 真实主体仍来自原三份 FBX；精确移除独立的旧光环连通部件，保留其他顶点、UV、权重、骨架及 `V_None` 表情形变。新身体 `.res` 用脚本从原资源生成，不是静态替代动作。
- Blender 制作连续、有厚度的白金双环和四枚简洁星芒，挂接三套骨架各自的 `CC_Base_Head`。主体网格不叠加旧环，新环没有透明发光层。
- 使用角色专属材质，减弱硬分段阴影，去掉粗描边，保留白袍纹理和暖金刺绣。贴图是原图的独立副本，运行上限 1024；共享原材质和原图导入参数不变。不是全套 PBR/法线重制。
- 动作仍是三套常驻 FBX、83 骨/套：代理 idle/run 均 1 秒、attack 0.85 秒；内部实际片段分别为 `male-idle_279398` 5.7 秒、`walk-relaxed-loop-378936` 4.866667 秒、`dual_gun_draw_gun_behind_back_279371` 3.35 秒。不更名、不裁剪、不改技能节奏。

| 每个动作可见资源 | 原版 | 新版 |
|---|---:|---:|
| 顶点 | 4978 | 4766 |
| 三角面 | 2965 | 4406 |
| Mesh surface | 1 | 2 |
| 可见材质绘制层 | 身体+描边 | 身体+圆环 |
| 最大运行贴图边长 | 512 | 1024 |

三套动作常驻共 14298 顶点、13218 三角面、6 surfaces、2 唯一材质、3 骨架。项目资源预算硬限制通过；1024 贴图超过 512 软建议，换取面部/刺绣可读性。此表不能替代帧时间测量。

## 复现与回退

复用 Godot 4.7 和 Blender 4.5；不需要联网或付费工具。先设置当前机器路径，工作目录为项目根：

```bash
GODOT_BIN="/实际路径/Godot"
BLENDER_BIN="/实际路径/Blender"
PRIEST_OUT="/实际路径/神侍交付目录"
"$GODOT_BIN" --headless --path . --script tools/model_refinement/priest_inventory.gd -- --out "$PRIEST_OUT"
"$BLENDER_BIN" --background --python-exit-code 1 --python tools/model_refinement/build_priest_halo.py -- --source "$PRIEST_OUT/source-idle.glb" --rig "$PRIEST_OUT/inventory.json" --out "$PRIEST_OUT/source"
# 检查导出成功后，把 source/priest_halo.glb 复制到 assets/models/units/god_priest_refined/。
"$GODOT_BIN" --headless --path . --script tools/model_refinement/build_priest_body.gd
"$GODOT_BIN" --headless --editor --path . --import
"$GODOT_BIN" --headless --path . --script tools/model_refinement/priest_contract_check.gd -- --out "$PRIEST_OUT/contract.json"
"$GODOT_BIN" --editor --path . res://scenes/debug/PriestModelRefinementPreview.tscn
```

编辑器打开专用场景后按 F6，可循环切换三动作、正侧背、旧新对照、同族同屏与 6/12 单位。资源在 `_ready()` 加载，因此编辑器静态视口不会完整显示模型，必须运行场景。Windows 用 PowerShell 的 `&` 调用实际 EXE，并按本机改路径。

回退只需将 `god_priest.model` 恢复原路径。新版继承原包装场景，原目录及其依赖仍必须保留。`assets/models` 在此仓库主要由资源包管理，普通 Git diff 不显示所有新资产；不能只交付 JSON 和脚本。

技术检查覆盖三个动作的主体顶点/UV/权重、表情、原动画资源、骨架/rest、18 个实际姿态采样和头骨跟随、正式映射与预算。Godot 重建法线/切线的编码量化最大误差记录在报告中，检查阈值 0.0002；顶点/UV/权重保持精确一致。

本机证据、可编辑 `.blend`、原三动作 GLB 和源文件备份在项目外层 `delivery/model-god_priest-20261003/`。最终验收范围、帧时间、失败记录、运行命令见该目录的 `REPORT.md`。手机与联机未纳入本次，不用桌面表现代替真机结论。未提交、推送或同步远端。

完整角色 `.blend`（含主体/骨架/表情/新环）也可重建：

```bash
"$GODOT_BIN" --headless --path . --script tools/model_refinement/priest_inventory.gd -- --refined --out "$PRIEST_OUT/editable-final"
"$BLENDER_BIN" --background --python-exit-code 1 --python tools/model_refinement/export_priest_editable.py -- --source "$PRIEST_OUT/editable-final/source-idle.glb" --albedo "$PWD/assets/models/units/god_priest_refined/priest_albedo_repaired.png" --out "$PRIEST_OUT/source/god_priest_refined_editable.blend"
```

正式路线工具为 `tools/model_refinement/priest_battle_review.tscn` 和 `priest_prep_capture.gd`，只能在用户目录名以 `GLoryPriestReview` 开头的隔离项目运行。战斗工具 `--round 6 --movement` 使用两个远距离合法阵容让神侍自然移动；没有改变角色数值。默认阵容中神侍可能始终位于射程内，因此不能把未出现 run 当作已验证移动。


## 2026-10-03 黑斑修复追加验收

后续制作按 [CODEX_MODEL_WORKFLOW.md 第 3.3 节](CODEX_MODEL_WORKFLOW.md#33-黑点黑块与贴图空白的排查和预防) 执行，黑斑检查已列入第 7.2 节视觉验收。不能因材质加载与动画检查通过而跳过贴图内容复查。

用户箭头标记的面颊/领口、肩袖与裙摆黑块，来自原贴图不透明纯黑空白区被模型 UV 采样。新增独立 `priest_albedo_repaired.png`，以相邻已绘制区域颜色补齐大块黑色空白及其边缘；`priest_body.tres` 已切换到修复图。原贴图保留，未改 UV、网格、骨架、动作或 Shader。

修复工具为 `tools/model_refinement/repair_priest_atlas.py`（Python、Pillow、NumPy）。只修改选定空白和边缘像素，其他像素与透明度保持逐像素一致，小面积深色细节保留。13 个原先落入黑色区的三角形中心重新采样，剩余黑色为 0；见 `blackspot-fix/uv-recheck.json`。三动作契约复验 337 项通过，正侧背及待机/移动/攻击画面已复查，见该目录 front、side、back。

运行贴图仍为 1024 上限、VRAM 压缩和 mipmap，纹理数量、几何数量与绘制层数不变。本次未重跑整组性能；上文性能数值与旧录像 `priest-comparison.mp4` 是黑斑修复前的记录，不能当作此次新增测量或最终外观。当前截图、完整可编辑 `.blend` 和交付 ZIP 已更新。

重建修复贴图（项目根目录，Python 需安装 Pillow 与 NumPy）：

```bash
python3 tools/model_refinement/repair_priest_atlas.py --source assets/models/units/god_priest_refined/priest_albedo.png --out assets/models/units/god_priest_refined/priest_albedo_repaired.png --report /实际路径/atlas-repair.json
```

脚本参数为本图专用：RGB 最大通道值不超过 12、四邻接连通区域至少 256 像素作为候选空白，再向最大通道值低于 80 的邻接像素扩边 3 次；从有效边界传播颜色，仅平滑新填充区域。它不是通用去黑算法，换角色或重绘原图后应重新审查掩码，避免误伤眼睛和暗色图案。

再次导出或恢复资源时，检查 `priest_body.tres` 仍引用 `priest_albedo_repaired.png`，可编辑模型也打包同一修复图；不要误接回保留作原始备份的 `priest_albedo.png`。重新导入后检查运行尺寸上限 1024、VRAM 压缩与 mipmap，并复查正侧背、近景/战斗距离及三动作。13 个缺陷中心采样为零黑色仅覆盖这些采样点，不代表全图自动验收。
