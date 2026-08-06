# GLORY 宣传片 分镜表 v1

> 给你批改用的。每个镜头都标了**素材从哪来**、**要拍什么**、**AI 镜头的 prompt 草案**。
> 有异议直接在行里改，我按改完的版本去拍。

## 0. 本版前提（你没定的我先默认了，要改就说）

| 项 | 本版取值 | 理由 |
|---|---|---|
| 时长 | **68 秒** | 商店页主片的甜点区间。<60s 讲不完 21 回合的结构，>90s 完播率掉 |
| 画幅 | **1920×1080 / 16:9** 为主 | Steam、官网、B站。竖版 30s 从同素材再剪一版，见 §6 |
| 帧率 | 60fps 拍摄，30fps 交付 | 60fps 拍是为了留慢放余量（S14 要 0.5× 慢放） |
| 语言 | 中文主字幕 + 英文小字 | 双语一次做完，省得出两版 |
| 正片比例 | 真实游戏画面 **43s / 68s（63%）** | 商店审核和玩家预期的底线，不能再低 |

## 1. 素材来源图例

| 标记 | 含义 | 怎么来 |
|---|---|---|
| 🎬**CAP** | Godot Movie Maker 锁帧截帧 | 扩现有 [tools/vfx_capture.ps1](../vfx_capture.ps1) 管线。无掉帧、可 2K、可任意 fps、可定种子重拍 |
| 📹**REC** | OBS 实录 | 只用于"要有手感"的操作段（拖拽、点击、UI 转场） |
| 🤖**HF** | Higgsfield 图生视频 | `--start-image` 喂**项目里已有的成品图**，模型只做运镜和微动，画风必定是你的 |
| ✏️**GFX** | 后期图形 | 字幕、标题卡、黑场 |

## 2. 主时间轴（68s）

### ACT 0 — 钩子（0:00–0:05）

| # | 时间码 | 时长 | 来源 | 画面 | 摄影 / 处理 | 字幕 |
|---|---|---|---|---|---|---|
| S01 | 0:00.0–0:02.5 | 2.5s | 🎬CAP | 黑龙 `dark_dragon` 放 `black_hole`，全屏吞噬 | 从特写起，0.5× 慢放，最后 6 帧骤停 | — |
| S02 | 0:02.5–0:05.0 | 2.5s | ✏️GFX | 骤停后切纯黑，只剩低频余震 | 黑场 0.4s 再上字 | **21 个回合。你的法阵只有 50 点血。**<br><sub>21 rounds. Your crystal has 50 HP.</sub> |

> S01 用 `black_hole` 是因为它是全库最大的一记特效，起手就要最猛的。截帧管线已经能单独触发任意技能，不用真打一局等它转出来。

### ACT 1 — 世界建立（0:05–0:14）

| # | 时间码 | 时长 | 来源 | 画面 | 摄影 / 处理 | 字幕 |
|---|---|---|---|---|---|---|
| S03 | 0:05.0–0:10.0 | 5.0s | 🤖HF | 低多边形草地棋盘全景，河流发光流动，云影掠过 | 缓推 + 极轻微俯角下压 | — |
| S04 | 0:10.0–0:14.0 | 4.0s | 🤖HF | 雪原战场，飘雪，远处山脊 | 横移（左→右），景深浅 | — |

**S03 起始图**：`assets/board/prep_2_5d/glory_grass_base_2560x1440.png`
**S04 起始图**：`assets/board/2_5d/battlefield_snow_pvp.png`

### ACT 2 — 四族亮相（0:14–0:22）

四镜同构，每镜 2s：族徽在前景，身后立绘微动（呼吸、布料、光效）。

| # | 时间码 | 族 | 起始图 | 字幕 |
|---|---|---|---|---|
| S05 | 0:14–0:16 | 神族 | `race_logos/god.png` + `unit_portraits/god_king.png` | **神族**<br><sub>Divine</sub> |
| S06 | 0:16–0:18 | 暗族 | `race_logos/dark.png` + `unit_portraits/dark_dragon.png` | **暗族**<br><sub>Dark</sub> |
| S07 | 0:18–0:20 | 亡灵 | `race_logos/undead.png` + `unit_portraits/undead_mother.png` | **亡灵**<br><sub>Undead</sub> |
| S08 | 0:20–0:22 | 人族 | `race_logos/human.png` + `unit_portraits/human_king.png` | **人族**<br><sub>Human</sub> |

段末压一行总字幕（0:21.0–0:22.0）：**4 族 · 32 名单位**

> 每镜生成 5s，剪的时候只取最好的 2s。四镜的运镜必须**完全一致**（同样的推速、同样的落幅），否则并排看会散。

### ACT 3 — 核心循环（0:22–0:43.5）·全真实画面

| # | 时间码 | 时长 | 来源 | 画面 | 备注 |
|---|---|---|---|---|---|
| S09 | 0:22.0–0:25.0 | 3.0s | 📹REC | 商店刷新 → 拖一个单位上棋盘 | 必须实录，鼠标/手指轨迹是"可玩"的唯一证据 |
| S10 | 0:25.0–0:27.0 | 2.0s | 📹REC | 三合一升星，金光起 | 卡在升星光效峰值切走 |
| S11 | 0:27.0–0:29.5 | 2.5s | 🎬CAP | 羁绊连线依次点亮（`PrepRelationLink3D`） | 摄影机沿棋盘缓慢横移，让连线一条条进画 |
| S12 | 0:29.5–0:31.5 | 2.0s | 📹REC | 点「开战」→ 镜头压低推进战场 | 转场靠游戏自己的推镜，不要加后期擦除 |
| S13a | 0:31.5–0:32.7 | 1.2s | 🎬CAP | `human_swordsman` — `front_cone_stun` 扇形击晕 | 快切段，四镜同节奏 |
| S13b | 0:32.7–0:33.9 | 1.2s | 🎬CAP | `god_arbiter` — `judgement_strike` 裁决落下 | |
| S13c | 0:33.9–0:35.1 | 1.2s | 🎬CAP | `undead_bomb` — `death_poison_explosion` 自爆毒云 | |
| S13d | 0:35.1–0:36.3 | 1.2s | 🎬CAP | `god_king` — `global_divine_blast` 全场神罚 | |
| S14 | 0:36.3–0:39.0 | 2.7s | 🎬CAP | 与 S01 同一记 `black_hole`，这次给完整过程 | 与开头呼应；0.75× 慢放 |
| S15 | 0:39.0–0:41.0 | 2.0s | 🎬CAP | 佣兵登场：`merc_leo_sun` 炎阳王者 | 字幕：**12 星座佣兵**<br><sub>12 Zodiac Mercenaries</sub> |
| S16 | 0:41.0–0:43.5 | 2.5s | 📹REC | 宝物三选一界面 → 选中 `atk_blood_pact` 血契之刃 | 字幕：**25 件宝物 · 套装与联动**<br><sub>25 Treasures</sub> |

> S13 四镜的技能都能用截帧管线单独触发，还能指定施法者真模型（`-Owners`）。这是这条片子最省事的一段。

### ACT 4 — 升级与压力（0:43.5–0:57）

| # | 时间码 | 时长 | 来源 | 画面 | 字幕 |
|---|---|---|---|---|---|
| S17 | 0:43.5–0:47.0 | 3.5s | 🎬CAP | Boss `boss_apocalypse` 灭世裁决者出场，仰角，压满画幅 | **第 20 回合**<br><sub>Round 20</sub> |
| S18 | 0:47.0–0:48.5 | 1.5s | 🎬CAP | 法阵水晶掉血，裂纹扩散，血条转红 | — |
| S19 | 0:48.5–0:52.0 | 3.5s | 🎬CAP | 守护者 `ally_eternal_night` 深渊魔君·厄夜 落地 → `eternal_night` 陨石 | **血越少，守护者越强**<br><sub>The lower your HP, the stronger your guardian</sub> |
| S20 | 0:52.0–0:54.5 | 2.5s | 📹REC | PvP 对局，两侧同屏开战 | **第 6/12/18/21 回合 · 真人对战**<br><sub>PvP</sub> |
| S21 | 0:54.5–0:57.0 | 2.5s | 📹REC | 胜利结算，金币与奖励飞入 | — |

> S19 是这条片子里唯一一句需要解释的机制（`hp_band` 越低给越强的守护者），值得单独一镜。它也是"逆风翻盘"的情绪点，正好接在 S18 掉血之后。

### ACT 5 — 收尾（0:57–1:08）

| # | 时间码 | 时长 | 来源 | 画面 | 字幕 |
|---|---|---|---|---|---|
| S22 | 0:57.0–1:02.0 | 5.0s | 🤖HF | 标题卡：GLORY 标志缓推，背后光晕流动 | **GLORY** |
| S23 | 1:02.0–1:06.0 | 4.0s | ✏️GFX | 定版：标志 + 平台图标 + 二维码/预约 | 平台、上线信息（**你给文案**） |
| S24 | 1:06.0–1:08.0 | 2.0s | 🎬CAP | 黑场中留一记 VFX 余光，缓慢熄灭 | — |

## 3. ⚠️ 现在缺的东西

1. **没有游戏标题 Logo**。`assets/ui/` 里只有族徽和宝物徽记，`start_menu/` 是空的，找不到任何 "GLORY" 标志。S22/S23 没它就无法定版。
   → 建议：用 Higgsfield 的图像模型按低多边形卡通风格生成 3–4 版标题字，你挑一版，顺便也能进游戏主菜单。**这个要先做，否则片尾是空的。**
2. **CTA 文案未定**：上线平台、上线时间、预约/愿望单入口，S23 全靠这个。
3. **音乐授权**：片子准备用 `assets/audio/bgm/fighting_music.mp3`。如果这是买的授权曲，要确认授权范围**含宣传视频**——很多游戏内音乐授权只覆盖游戏本体，不含独立发布的宣传物料。

## 4. 音乐与音效

- **主轨**：`assets/audio/bgm/fighting_music.mp3`。0:00–0:14 只留低频与环境，0:14 起主题进，0:31.5（S13 快切段）落在鼓点上，0:57 收。
- **拍点**：装好 ffmpeg 后我先测 BPM，把 S13a–S13d 的切点对齐到拍上——这四刀对不对拍，是整条片子看起来专业与否的分水岭。
- **音效**：S01 的骤停、S18 的水晶裂纹、S22 的标志落幅各需要一记独立音效。项目里 `assets/audio/ui/` 有现成的可以试，不够就用 Higgsfield 的音频模型补。

## 5. Higgsfield 镜头 prompt 草案

原则：**只写摄影语言，绝不写世界观**。一旦写"魔幻战场""恶魔",模型就会自己编内容，画风立刻脱离你的美术。起始图已经把内容定死了，prompt 的唯一任务是描述镜头怎么动。

| # | 模型 | 参数 | prompt 草案 |
|---|---|---|---|
| S03 | `kling2_6` | 5s, 16:9 | `slow forward dolly, camera drifts in over the terrain, gentle cloud shadows sweeping across the ground, water surface flowing softly, everything else static, no new objects appear, no style change` |
| S04 | `kling2_6` | 5s, 16:9 | `slow lateral tracking shot left to right, fine snow particles drifting down, shallow depth of field, background subtly parallaxing, no new objects appear, no style change` |
| S05–S08 | `kling2_6` | 5s, 16:9 | `very slow push-in on the centered emblem, subtle breathing motion on the character behind it, cloth and hair drifting slightly, soft light sweep across the surface, camera locked on center, no new objects appear, no style change` |
| S22 | `kling2_6` | 5s, 16:9 | `slow push-in on the logo, volumetric light rays drifting behind it, faint particles rising, logo itself perfectly static and sharp, no deformation of letterforms, no new objects appear` |

**每镜末尾统一追加负面约束**：`no camera shake, no zoom punch, no added characters, no text, no watermark`

> 关于文字：模型会把 logo 上的字母改坏。S22 的稳妥做法是让它只生成**背景光效**，logo 本体在后期以静止图层叠上去。我按这个做。

## 6. 竖版 30s（9:16）

不重拍，从同素材再剪一版：

- 保留：S01 → S02 → S05–S08（压到各 1.2s）→ S13a–S13d → S14 → S17 → S19 → S22
- 砍掉：S03/S04 世界建立、S09–S12 布阵流程、S20/S21 结算
- 处理：16:9 素材转 9:16 靠**重新构图**（按每镜主体位置定裁切中心），不是无脑居中裁——布阵棋盘居中裁会把两侧单位切掉

## 7. 预算与产能

| 项 | 数量 | 单价 | 小计 |
|---|---|---|---|
| Higgsfield 视频镜头 | 7 镜 × 3 次重出 = 21 次 | Kling 2.6 / 5s = 10cr | 210 cr |
| 标题 Logo 生成 | 约 8 次图像生成 | ~2–4cr | ~30 cr |
| 机动余量 | | | ~100 cr |
| **合计** | | | **~340 / 576 cr** |

额度够，还剩得下一轮大改。真实画面（CAP/REC）零成本。

## 8. 待你拍板

1. **分镜本身**：结构、镜序、每镜时长，有没有要砍要换的。
2. **标题 Logo**：现在就让我生成几版？（片尾等它）
3. **CTA 文案**：S23 写什么。
4. **谁来剪**：我用 ffmpeg 脚本出成片，还是我交素材 + 这份表，你自己精修。
5. **ffmpeg 安装许可**（测 BPM、合成、转码都要）。

改完这份表我就开工：先拍 CAP 段（不花钱、可反复重拍），同步跑 Higgsfield 的 7 个镜头。
