# 猫宠物 · BA 风格改造（A 档：不动几何）

2026-11-13。参考包：`C:\Users\Leno\Desktop\rea BA\analysis\shiroko\`（白子 / 星野 / 优香，Steam 构建）。

## 对照图（Godot 4.7 mobile 渲染器，正交，同一裁切框）

- `../../pets_ba_baseline_20261113.png`：改前 5 只宠物四视图基线
- `review/cat_stages.png`：行 = 改前 / 灰模 / 平涂贴图无光照 / 新材质无描边 / 新材质 + 描边；列 = 正 / 侧 / 背 / 四分之三
- `review/cat_face_closeup.png`：正面特写，左改前、右改后
- `debug/mask_layers.png`、`debug/mask_g.png`、`debug/flatten_report.json`：Mask 分层、G 通道、聚类结果

截图来自离线渲染脚本，不是游戏内画面；菜单、营地、战斗相机下的实际观感和手机真机还没验证。

## 逐文件修改清单

| 文件 | 状态 | 内容 |
|---|---|---|
| `shaders/ba_pet_body.gdshader` | 新增 | 按 BA `MX/C-General/Layer4` 无关键词基线像素程序复现的身体着色 |
| `shaders/ba_pet_outline.gdshader` | 新增 | 按 BA Outline 基线顶点程序复现的描边（TANGENT 外扩 × 顶点 Alpha） |
| `scripts/pets/BAOutlineDataImport.gd` | 新增 | 导入后处理：TANGENT = 平滑法线（描边方向），COLOR = 白、Alpha 1；重建 LOD |
| `tools/ba_pet_texture/flatten_albedo.py` | 新增 | 生成平涂底色 + BA Body Mask；只读原图 |
| `assets/models/pets/pet_cat/pet_cat_ba_albedo.png` (+.import) | 新增 | 1024² 平涂底色，VRAM 压缩、mipmap |
| `assets/models/pets/pet_cat/pet_cat_ba_mask.png` (+.import) | 新增 | 1024² Mask（G=阴影倾向，A=四层），VRAM 压缩、无 mipmap |
| `assets/models/pets/pet_cat/pet_cat_body_material.tres` | 改 | 换成新 Shader 与新贴图；路径、资源名不变 |
| `assets/models/pets/pet_cat/pet_cat_attack.fbx.import`、`pet_cat_run.fbx.import` | 改 | `import_script/path` 指向导入后处理脚本 |

**不变**：FBX 网格与骨骼、UV、`PetCatAnimated.gd`、场景 `pet_cat_animated.tscn`、动画接口（idle/attack/run）、`data/pets/pets.json`、其他 4 只宠物、`ba_toon` / `ba_outline`（松鼠、老虎、蘑菇、兔子仍在用）。

`assets/models/pets/*` 被 `.gitignore` 排除，上面 `assets/` 下的改动不会进 git，需要按现有方式同步美术资源。

**备份**：`art_source/backup/pets_before_ba_20261113/`（整个 `assets/models/pets/` + 旧 `ba_toon`/`ba_outline`/`ImportedPetAnimated.gd`）。目录里放了 `.gdignore`，Godot 不会扫描它；已加进本地 `.git/info/exclude`。还原 = 把备份的 `pets/pet_cat/` 拷回去，删除两份 `.fbx.import` 里的 `import_script/path` 并重新导入。

## 来源对应表

| 本项目 | BA 证据 | 等级 |
|---|---|---|
| 四层 floor/ceil 选择、q = gBias + 0.77·N·V + N·L、阴影系数 -10、视角光 / 逆视角光 / 底亮 / 边缘光 / 背面公式 | `MX_C-General_Layer4/p4_blob_0084.asm.txt` + `parsed_form.json` 常量布局（cb1[1]…cb1[16]、cb0[126…129]） | 编译程序实测 |
| 描边：TANGENT 方向、rsqrt(max(·,0.000061))、clip.w × alpha × 0.002、Y × 屏宽/屏高、Front Cull、顶点处采样贴图 × _OutlineTint | `SHADER_FINDINGS.md` §1，`p4_blob_0141` / Hair `p4_blob_0076` | 编译程序实测 |
| 颜色类属性（_Tint、_TwoSideTint、_GlowTint、_OutlineTint）在 Linear 工程转线性 → Godot `source_color`；_ShadowTint*4 是 Vector 原值 | `parsed_form.json` m_Props：m_Type 0 / 1，flags 16 = HDR（非 Gamma） | 资源实测 + Unity 规则推断 |
| 毛层：阈值 0.15、阴影 (0.92,0.78,0.80) | 三人皮肤层阈值 0.13~0.17、阴影约 (0.94~0.98, 0.71~0.82, 0.69~0.79) | 设计选择（取规律） |
| 布料层：阈值 0.45、阴影 (0.40,0.30,0.62)、视角光 offset 0.5 / power 30 / 0.2 / edge 0.25 | 白子 / 星野深色衣物层阈值 0.4~0.5、强饱和深色阴影（原作偏蓝）；白子第 1 层视角光 | 设计选择 |
| 金饰层：视角光 offset -0.4、power 64、强度 0.6、edge 0.15 | 白子第 2 层 offset -0.4 / power 256 / 1.0 / edge 0.147 | 设计选择（调软） |
| 眼口层：阈值 -5（永不进阴影）、无边缘光 | 原作眼口单独用 EyesMouth Shader，不受明暗影响 | 设计选择（替代） |
| _OutlineTint 0.4 | 白子 0.274，星野 / 优香 0.5 | 设计选择 |
| 假光源固定在视角空间、光色白、无球谐环境光 | 原作的 _MxCharLight* 为运行时全局值，静态包里没有 | 设计选择 |
| 明暗用平滑法线（`shade_with_smooth_normal`） | 原作用美术调过的法线；猫网格 4513 顶点只有 1554 个位置，原始法线明暗碎 | 设计选择 |
| Mask G 由原图烘焙 AO 换算（以中位数为 0.5） | 原作 G 是手绘的阴影倾向 | 设计选择 |

## 骨骼 / 动画兼容

- 骨骼 40 根（使用 32），蒙皮 4 权重，未改。导入脚本只改顶点属性，`MeshInstance3D.skin` 和骨架路径保持。
- 描边方向存在 TANGENT 里，会跟着骨骼蒙皮。idle（attack 首帧冻住）/ attack / run 三个子模型共用同一个材质。
- 导入脚本重建网格后用 `ImporterMesh.generate_lods` 重新生成 LOD；原来的阴影代理网格（create_shadow_meshes）不再单独生成，不影响显示。

## 移动端预算（估算，未上真机）

| 项 | 改前 | 改后 |
|---|---|---|
| 三角面 / 子网格 / 材质 | 3110 / 1 / 1 | 不变 |
| Pass | 身体 + 描边 = 2 | 不变 |
| 每像素采样 | 1（颜色） | 2（颜色 + Mask）；描边每顶点 1 次 |
| 颜色贴图 | 2048² RGBA | 1024² RGB |
| Mask | 无 | 1024² RGBA，无 mipmap |
| 贴图显存（ASTC 4×4 估算） | 约 5.6 MB | 约 1.4 + 1.0 = 2.4 MB |
| 透明叠加 | 无（不写 ALPHA） | 不变 |

像素着色的计算量比 `ba_toon` 多（两次 pow、四层 dot），宠物同屏通常 1 只、屏占比小。实际帧时间需要在真机上测。

## 已知问题与未验证项

- 腿和胸口的细暗线：在「平涂无光照」和「无描边」两行里同样存在，来自原网格的接缝或裂缝，不是描边造成的。要修得改模型（B 档）。
- 眼睛和嘴的位置是手动指定的 UV 矩形（见 `debug/flatten_report.json`）；其他宠物要重新找。
- 嘴线是原图像素，1024 下比原来细。
- 正对镜头时阴影很少：这是 BA 公式本身的特性（0.77·N·V 项），换光源方向可以调整 `light_dir_view`。
- 菜单透明背景 SubViewport、营地、战斗准备三个场景的实际观感还没截图验证；真机性能未测。
- 已跑的检查：`pet_feature_check` 通过；`bag_pet_layout_check`（5 只宠物的 2D 立绘都没贴图）和 `pet_footstep_check`（音效 cue 表条数）失败，都和这次改动无关。
