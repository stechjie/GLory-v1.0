# Glory 战斗模型资产预算（E2-2A）

状态：`desktop_provisional_android_pending`。本表是桌面基线上的第一版硬门禁；Android 导出与真机 GPU/内存预算按当前安排暂不执行，后续必须用目标机数据重新收紧或分档。

## 为什么需要这道门禁

战斗镜头目前为 960×540、正交尺寸 7.2，普通角色约 70 像素高。这个观看距离下，超高面数通常不会转化为可见品质，却会增加加载时间、内存、蒙皮和渲染成本。当前动作包装器还会同时加载 idle、attack、run 三个子模型；未显示的动作虽然不可见，仍属于 resident geometry，不能只统计屏幕上那一个模型。

E2-2A 不会自动改模型、贴图、材质或动画。它只把超预算资产变成可重复、可被 CI 读取的失败结果，后续再逐项决定减面、共享骨架/网格、调整导入上限或保留例外。

## 预算档位

正式数值在 `data/presentation/model_asset_budgets.json`，以下为当前摘要：

| 角色档位 | 单个可见动作顶点 hard | 三动作常驻顶点 hard | 三动作常驻三角面 hard |
|---|---:|---:|---:|
| 普通单位 / 怪物 | 20,000 | 60,000 | 120,000 |
| 三阶英雄 / 佣兵 | 30,000 | 90,000 | 180,000 |
| Boss / 阵型盟友 | 60,000 | 180,000 | 360,000 |

所有档位同时检查：最多 6 个常驻 surface、4 个唯一材质、3 套常驻骨架、单骨架最多 142 根骨骼、运行时贴图边长 hard 1024。soft 超标只记录提示；hard 超标返回退出码 1。

贴图检查读取 Godot 实际加载后的尺寸，而不是 DCC/source 图片的原始边长。源文件可以为 2K/4K，但进入战斗的导入结果通常应限制到 512；英雄、Boss 或确实需要近景辨识的资产最多 1024。是否保留更高分辨率必须由画面收益和目标机数据共同证明。

## 当前已知风险

建立门禁前的只读审计已确认：

- `formation_ally_5` 的 idle/attack/run 每个约 687,628 顶点，当前包装方式约 206 万常驻顶点。
- `formation_ally_4` 的 idle/attack 各约 440,241 顶点，当前包装方式约 88.5 万常驻顶点。
- `dark_doom` 的最终显示跨度约 0.019；`merc_virgo_heal` 使用 0.01 的数据缩放且最终跨度也约 0.019。这两项由 `model_bounds_check` 列为尺寸异常候选，但 E2-2A 不自动修改数据。
- 现有桌面性能基线只覆盖 21/24 人常规阵容，没有覆盖阵型盟友 4/5 的最坏组合，因此不能用现有平均帧率替代资产预算。

这些是门禁应该暴露的真实问题，不应通过放宽数值或空检查集伪装成绿色。

## 运行方法

模型预算门禁：

```powershell
Godot_v4.7-stable_win64_console.exe --headless --path "<Glory 项目根>" res://tools/model_asset_budget_check.tscn
```

模型尺寸检查：

```powershell
Godot_v4.7-stable_win64_console.exe --headless --path "<Glory 项目根>" res://tools/model_bounds_check.tscn
```

动作包装检查：

```powershell
Godot_v4.7-stable_win64_console.exe --headless --path "<Glory 项目根>" --script res://tools/verify_merged_models.gd
```

完整 FBX CSV 审计（默认安全写入 `user://fbx_audit.csv`）：

```powershell
Godot_v4.7-stable_win64_console.exe --headless --path "<Glory 项目根>" --script res://tools/audit_fbx.gd
```

指定输出位置可使用环境变量 `GLORY_FBX_AUDIT_PATH`，或在 `--` 后传入 `--output <path>`。CSV 包含 mesh、surface、顶点、索引、三角面、唯一材质、骨骼、动画、贴图尺寸、源文件体积和 Godot 导入缓存体积。

## 判定与后续校准

- `CHECK_RESULT ... status=PASS`：所有已引用战斗模型都在 hard 预算内。
- `status=FAIL`：至少一个 hard 超标、资源无法加载、预算配置损坏，或检查集为空。
- soft 提示：不是构建失败，但应在下一轮资产优化中排队。
- Android 恢复后，用至少一台低档和一台目标档真机记录峰值内存、GPU frame time、加载时间和温度降频，再更新 JSON 的状态与数值。

任何预算调整都应说明测量场景和依据；不能仅为了让检查变绿而提高上限。
