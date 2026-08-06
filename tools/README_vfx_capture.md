# 技能特效截帧与回归比对

## 为什么要这个

改一个特效以前要：开游戏 → 布阵 → 开战 → 等技能真的触发（`every_fourth_combo`
这类还是按次数/RNG 门控的）。循环太慢，导致迭代方式退化成了存 `.bak` 快照。

这套工具把循环压到一条命令：锁帧跑一遍，所有技能各出 24 帧 PNG，然后和基线做像素 diff。

## 用法

```bash
# 截一份基线（全部技能，约 1690 帧 / 1 分钟）
powershell -File tools/vfx_capture.ps1 -Out captures/baseline

# 改完代码再截一份
powershell -File tools/vfx_capture.ps1 -Out captures/after

# 比对：只回答"画面变了没有"
python tools/vfx_diff.py captures/baseline captures/after
```

只截几个技能：`-Skills "black_hole,arrow_rain"`
压到低画质档看并发上限会砍掉什么：`-Tier low`

单目录模式做空表现检查（哪些技能什么都没画出来）：

```bash
python tools/vfx_diff.py captures/baseline
```

## 三个必须知道的点

1. **不能加 `--headless`。** Movie Maker 模式要真实渲染上下文，headless 不出画面。
   跑的时候会闪一个窗口，这是 Godot 的限制。

2. **锁帧是全部前提。** `--fixed-fps` 让每帧 delta 恒为 1/fps，与机器负载无关；
   再配合 `vfx_capture.gd` 里的 `seed(RANDOM_SEED)` 定死模块内的 `randf_range`，
   两次运行才能逐帧一致。实测 6 个技能里 5 个是逐位相同（0.000%）。

3. **GPU 粒子不完全确定。** 用了 Binbun 引用场景的技能（`element_meteor` 等）
   会有 ~0.1% 的抖动，因为 `GPUParticles3D` 在 GPU 上自行演算。
   默认阈值 0.2% 就是为了容忍这个抖动、同时还能抓到真实改动。

## 空表现检查的结论

**70 个技能没有一个是完全没画面的。** 一开始报出来的"21 个渲染为空"全是测量问题，
逐个修掉之后清单是空的：

1. 帧号 0 基 vs 1 基差一位 —— 参照帧其实是第一个技能的首帧，不是空场景
2. 用全局空场景帧当参照 —— 舞台长时间运行有约 0.09% 的恒定渲染漂移，
   给每个技能垫了底噪。改成就近取"本技能开播前那一帧"后消失
3. 清场和放下一个技能在同一帧 —— `queue_free()` 延迟到帧末，上一个技能的块
   还活着。现在每个窗口首帧专门用来清场，第二帧才放技能

剩下 7 个在 0.003%–0.02% 区间：`defense_down_attack`、`guardian_shield_taunt`、
`nearest_ally_bless`、`random_ally_damage_reduction`、`rage_stack`、`twin_strike`、
`wind_bleed`。查过都是**按设计就很小**——非传奇单位的护盾会被压成 `size*0.52` 且
`edge_only`，双刃斩/风刃的 `width` 只有 0.05～0.085。它们不是 bug。

但这是一条值得注意的**设计**信息：这 7 个在战斗取景下只占 30–180 像素，
搬到手机屏上基本等于看不见。要不要放大是美术判断，工具只负责把数量摆出来。

## 阈值怎么选

特效大小跨了 300 倍（`bubble_dream` 37.6% vs `random_ally_damage_reduction` 0.003%），
所以没有一个万能阈值：

- 回归比对（双目录）：默认 0.2%，按 GPU 粒子抖动校准，不用改
- 空表现检查（单目录）：用 `--threshold 0.02`，低于这个基本可以认为真没画出东西

## 帧号约定

Movie Maker 从 `frame00000000.png` 开始编号，所以 `manifest.json` 里的帧号是 0 基的。
`empty_frame` 是最后一帧预热，此时还没有任何技能开播，空表现检查拿它当参照。

## 用真模型截帧 + 量挂位

替身默认还是胶囊，但可以换成真实战斗模型：

```bash
powershell -File tools/vfx_capture.ps1 -Out captures/x -Skills "stun,poison_attack" `
  -Owners "basic_attack_ranged_god=god_priest"
# 或直接调 godot，带 --unit / --target-unit
```

`--unit <id>` / `--target-unit <id>` 会按 BattleRenderer 的同一套缩放链摆上真模型，
并**冻结动画**（不冻的话 idle 动作会污染像素 diff，量出来的全是模型自己）。

manifest 里会写一份屏幕标尺（每个替身的脚/头像素坐标）。配合：

```bash
python tools/vfx_where.py captures/x
```

输出每个技能的特效**在目标身高的百分之多少**：0% = 脚底，100% = 头顶，>100% = 飘在头上。
这是判断"斩击到底挂在身上还是头上"的唯一可靠办法——肉眼看截图判断不了。

⚠️ 单位高度**不能**用 mesh AABB 量。这些是蒙皮模型，`get_aabb()` 只框住一部分躯干，
实测低估 1.15×–3.5× 且每个模型倍数不同。真实高度用上面的轮廓法量，实测集中在
0.71–1.08，所以代码里用名义常量 `BattleRenderer.NOMINAL_UNIT_HEIGHT = 0.98`。
