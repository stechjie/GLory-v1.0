# 赤律族棋子法线与小尺寸描边修复

日期：2026-10-06。范围：赤卫、赤舞者、战鼓使、血猎者、破甲者、霜印使、穿云弩手、赤灯使，共 8 个角色、13 个网格表面。

## 原因与修复

当前运行资源是 `assets/models/units/crimson_refined` 下的 GLB，并非此前女王的 FBX。源资源在同一曲面的 UV 接缝处保留了大量不连续的角点法线，卡通明暗分段使这些断裂更明显。关闭描边、关闭法线贴图的对照不能单独消除表面面片感；纯灰材质也能看到三角面明暗断裂。压缩、LOD 和 UV 翻转探针没有证明它们是本次的修复方向，未将这些探针改动写入工程。

- 只在连续共享边、绕序一致、折角不超过 75 度、蒙皮权重相同的表面之间进行角度加权法线平滑。保留原先的自定义法线信息，不把头发/衣片的相反面相互平均。
- 8 个 GLB **只有 NORMAL accessor 的字节变化**。文件长度、三角面、位置、UV、蒙皮、绑定矩阵、节点及动画数据逐字节不变。
- 赤律独立材质的描边上限设为 0.55 像素，法线贴图深度由 0.35 降为 0.15，明暗过渡宽度由 0.03 增至 0.08，减轻小棋子上的黑缝与闪碎细节。没有修改其他种族或公共 shader。
- `crimson_refine.py` 与 `dark_race_materials.py` 已接入同样的处理，重新生成资源不会覆盖掉本次修复。

共 50,165 个三角面中，三角面内法线完全一致的数量从 16,376 降至 4,092。这个数字是几何检查指标，不等于画面质量评分；真实折边仍允许保持硬法线。原贴图的高频花纹和模型轮廓细节仍然保留，本次没有重新绘制贴图或重建造型。

## 验证与边界

- 4 项算法回归检查通过：UV 接缝连续、不同蒙皮权重隔离、正反薄片不抵消、锐折边保留。
- 8 个角色与原始 GLB 的节点、骨骼、动画通道及关键帧、绑定修正检查通过。
- Godot 4.7 / Compatibility / Apple M4：待机、攻击、移动共 24 个动作，每个动作 3 个时间点，共 72 张修复后截图；另有同设置的修复前截图。
- 生产工程重新导入通过，无 ERROR / SCRIPT ERROR / Parse Error。
- 已同步本地 `res/assets/models/units/crimson_refined` 的 22 个修改资源，并校验源副本未包含其他更新后才覆盖。
- ADB 未连接设备，本次尚未完成 Android 真机验收；未生成新 APK，未提交或推送 Git，未上传云盘。

## 复现

```sh
python tools/model_refinement/test_repair_crimson_normals.py
python tools/model_refinement/repair_crimson_normals.py \
  --source-dir /path/to/baseline/crimson_refined \
  --output-dir /path/to/repaired/crimson_refined \
  --report /path/to/repair.json
```

Python 需要 NumPy；资源生成链路另需其已有的 Pillow 依赖。修复脚本从未修复的基线生成到独立输出目录。运行截图工具须使用独立测试工程，用户目录名称包含 `CrimsonNormalReview`，并设置 `CAPTURE_OUT`；不能以 headless 模式作视觉验收。

机器可读结果：[crimson_normal_repair_20261006.json](crimson_normal_repair_20261006.json)。

同姿势对照：[角色 1–4](../../../delivery/crimson-normal-fix-20261006/comparison-1.png)、[角色 5–8](../../../delivery/crimson-normal-fix-20261006/comparison-2.png)。左为修复前，右为修复后。全部动作截图与日志位于外层 `delivery/crimson-normal-fix-20261006/`。
